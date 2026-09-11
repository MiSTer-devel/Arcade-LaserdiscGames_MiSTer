//============================================================================
// Super Don Quix-ote (Universal, 1984) — Z80 + LD-V1000.
//
// Memory:  0x0000-0x3FFF ROM (16K)   0x4000-0x47FF RAM (2K)
//          0x5C00-0x5FFF video RAM (1K, 32x32 tile codes)
// Ports:   IN  00 joystick  01 buttons/coins  02 DSW1  03 DSW2  04 LD status
//          OUT 00 LD command  04 SN76496  08 latch  0C/0D HD46505 (fixed timing)
// Video:   32x32 cells of 8x8 (CRTC displays 32x28), packed 4bpp, 256 chars.
//          Colour = {color_bank, pixel} into a 32-entry PROM, 3-3-2 RGB.
// IRQ:     the LD-V1000 command strobe; cleared by port 0x08 bit 6.
//============================================================================

module SuperDon
#(
    parameter [31:0] CLK_HZ = 32'd80_000_000,
    // X1 is 20 MHz into an LS161; the Z80 clock is taken from pin 13 (QB, /4)
    // via an LS04 and R7 330R to pin 6. Read off the Main PCB (1) schematic --
    // MAME's MASTER_CLOCK/8 is wrong, Daphne's 5 MHz is right.
    parameter [31:0] CPU_HZ = 32'd5_000_000
)
(
    input                reset,        // active LOW
    input                clk_sys,

    input          [7:0] p1,           // {b3,b2,b1,action, right,left,down,up} active HIGH
    input          [3:0] cab,          // {coin2, coin1, start2, start1} active HIGH
    input         [15:0] dsw,          // dsw[7:0] = DSW1, dsw[15:8] = DSW2

    output signed [15:0] sound_l,
    output signed [15:0] sound_r,

    input         [24:0] ioctl_addr,
    input          [7:0] ioctl_data,
    input                ioctl_wr,
    input          [7:0] ioctl_index,

    input                pause,
    input                disc_hold,
    input          [3:0] post_seek_frames,
    input                disc_2997,

    output               ld_search_cmd_o,
    output               ld_play_end_o,
    output        [16:0] ld_frame_o,
    output               ld_playing_o,

    // ---- overlay, already in the core's shared 320x240 space ----
    input         [15:0] ovl_hpos,
    input         [15:0] ovl_vpos,
    input                ovl_ce_pix,
    output reg    [23:0] ovl_rgb,
    output reg           ovl_opaque,

    // Sticky liveness, NOT a blink: goes solid once the CPU makes its first
    // port-0x08 write. A blinking LED means this board is not selected at all
    // (the Dragon's Lair heartbeat is showing through), so the three states are
    // visually distinct: blinking = not selected, solid = alive, dark = dead.
    output               dbg_led
);

    //--------------------------------------------------------- clocking ------
    localparam [5:0] CDIV  = CLK_HZ / CPU_HZ;
    // The SN76496 runs at half the CPU rate, so it gets its own divider rather
    // than borrowing CDIV -- they are separate quantities that must not drift.
    localparam [5:0] SNDIV = CLK_HZ / (CPU_HZ / 32'd2);
    reg [5:0] cdiv;
    reg       cpu_ce;
    always @(posedge clk_sys) begin
        if (!reset) begin cdiv <= 6'd0; cpu_ce <= 1'b0; end
        else if (pause) cpu_ce <= 1'b0;
        else begin
            cpu_ce <= (cdiv == CDIV - 6'd1);
            cdiv   <= (cdiv == CDIV - 6'd1) ? 6'd0 : cdiv + 6'd1;
        end
    end

    //--------------------------------------------------------- CPU -----------
    wire [15:0] cpu_A;
    wire  [7:0] cpu_Dout;
    reg   [7:0] cpu_Din;
    wire        n_rd, n_wr, n_mreq, n_iorq, n_m1;
    reg         n_irq;

    T80s cpu (
        .RESET_n(reset), .CLK(clk_sys), .CEN(cpu_ce),
        .WAIT_n(1'b1), .INT_n(n_irq), .NMI_n(1'b1), .BUSRQ_n(1'b1),
        .M1_n(n_m1), .MREQ_n(n_mreq), .IORQ_n(n_iorq),
        .RD_n(n_rd), .WR_n(n_wr),
        .A(cpu_A), .DI(cpu_Din), .DO(cpu_Dout)
    );

    wire mem_access = ~n_mreq;
    wire io_access  = ~n_iorq & n_m1;
    wire [7:0] io_A = cpu_A[7:0];

    //--------------------------------------------------------- memory --------
    wire cs_rom  = mem_access & (cpu_A <  16'h4000);
    wire cs_ram  = mem_access & (cpu_A >= 16'h4000) & (cpu_A < 16'h4800);
    wire cs_vram = mem_access & (cpu_A >= 16'h5C00) & (cpu_A < 16'h6000);

    // MRA index 0 packs: prog 0x0000, char 0x4000, colour PROM 0x6000.
    wire rom_ld  = (ioctl_index == 8'd0) & ioctl_wr;
    wire ld_prog = rom_ld & (ioctl_addr <  25'h4000);
    wire ld_char = rom_ld & (ioctl_addr >= 25'h4000) & (ioctl_addr < 25'h6000);
    wire ld_prom = rom_ld & (ioctl_addr >= 25'h6000) & (ioctl_addr < 25'h6020);

    wire [7:0] rom_D, ram_D, vram_cpu_D;

    dpram_dc #(.widthad_a(14)) u_rom (
        .clock_a(clk_sys), .address_a(cpu_A[13:0]), .q_a(rom_D),
        .wren_a(1'b0), .data_a(8'd0),
        .clock_b(clk_sys), .address_b(ioctl_addr[13:0]), .data_b(ioctl_data),
        .wren_b(ld_prog), .q_b()
    );

    dpram_dc #(.widthad_a(11)) u_ram (
        .clock_a(clk_sys), .address_a(cpu_A[10:0]), .q_a(ram_D),
        .wren_a(cs_ram & ~n_wr), .data_a(cpu_Dout),
        .clock_b(clk_sys), .address_b(11'd0), .data_b(8'd0), .wren_b(1'b0), .q_b()
    );

    // Port A is the CPU, port B is the renderer -- the renderer never writes.
    wire  [9:0] vram_rd_A;
    wire  [7:0] vram_rd_D;
    dpram_dc #(.widthad_a(10)) u_vram (
        .clock_a(clk_sys), .address_a(cpu_A[9:0]), .q_a(vram_cpu_D),
        .wren_a(cs_vram & ~n_wr), .data_a(cpu_Dout),
        .clock_b(clk_sys), .address_b(vram_rd_A), .data_b(8'd0),
        .wren_b(1'b0), .q_b(vram_rd_D)
    );

    wire [12:0] char_A;
    wire  [7:0] char_D;
    dpram_dc #(.widthad_a(13)) u_char (
        .clock_a(clk_sys), .address_a(char_A), .q_a(char_D),
        .wren_a(1'b0), .data_a(8'd0),
        .clock_b(clk_sys), .address_b(ioctl_addr[12:0]), .data_b(ioctl_data),
        .wren_b(ld_char), .q_b()
    );

    wire  [4:0] prom_A;
    wire  [7:0] prom_D;
    dpram_dc #(.widthad_a(5)) u_prom (
        .clock_a(clk_sys), .address_a(prom_A), .q_a(prom_D),
        .wren_a(1'b0), .data_a(8'd0),
        .clock_b(clk_sys), .address_b(ioctl_addr[4:0]), .data_b(ioctl_data),
        .wren_b(ld_prom), .q_b()
    );

    //--------------------------------------------------------- I/O decode ----
    wire cs_ld_w   = io_access & ~n_wr & (io_A == 8'h00);
    wire cs_snd_w  = io_access & ~n_wr & (io_A == 8'h04);
    wire cs_io_w   = io_access & ~n_wr & (io_A == 8'h08);
    wire cs_ld_r   = io_access & ~n_rd & (io_A == 8'h04);

    // Active-LOW banks (MAME superdq INPUT_PORTS).  p1 is
    // {b3,b2,b1,action, right,left,down,up}; cab is {coin2,coin1,start2,start1}.
    // IN0 joystick: b7 UP, b5 RIGHT, b3 DOWN, b1 LEFT; even bits unused, read 1.
    wire [7:0] in0 = ~{p1[0], 1'b0, p1[3], 1'b0, p1[1], 1'b0, p1[2], 1'b0};
    // IN1: b7 START1, b6 START2, b5 P1 B1, b4 P2 B1, b3 COIN1, b2 COIN2, b1 TEST, b0 SERVICE
    wire [7:0] in1 = ~{cab[0], cab[1], p1[4], 1'b0, cab[2], cab[3], 2'b00};

    reg [7:0] io_reg;
    reg       io_w_seen;
    always @(posedge clk_sys) begin
        if (!reset) begin io_reg <= 8'd0; io_w_seen <= 1'b0; end
        else if (cpu_ce && cs_io_w) begin
            io_reg    <= cpu_Dout;
            io_w_seen <= 1'b1;
        end
    end
    assign dbg_led = io_w_seen;
    wire color_bank = io_reg[1];

    //--------------------------------------------------------- LD player -----
    wire [7:0] ld_status;
    wire       ld_cmd_strobe;
    reg  [7:0] ld_cmd_latch;
    reg        ld_cmd_stb;
    always @(posedge clk_sys) begin
        ld_cmd_stb <= 1'b0;
        if (!reset) ld_cmd_latch <= 8'd0;
        else if (cpu_ce && cs_ld_w) begin
            ld_cmd_latch <= cpu_Dout;
            ld_cmd_stb   <= 1'b1;
        end
    end

    ldp_top #(.CLK_HZ(CLK_HZ)) u_ldp (
        .clk(clk_sys), .reset_n(reset),
        .player_sel(4'd0),              // PLAYER_LDV1000
        .cmd_stb(ld_cmd_stb), .cmd_byte(ld_cmd_latch),
        .blip(1'b0),
        .status(ld_status), .status_strobe(), .command_strobe(ld_cmd_strobe),
        .ready_n(), .frame_valid(),
        .tx_valid(), .tx_byte(), .tx_pop(1'b0),
        .search_cmd_o(ld_search_cmd_o), .play_end_o(ld_play_end_o),
        .curr_frame(ld_frame_o),
        .pause(pause), .disc_hold(disc_hold), .playing(ld_playing_o),
        .dbg_seek_frame(), .dbg_end_frame(), .dbg_flags(),
        .post_seek_frames(post_seek_frames),
        .disc_2997(disc_2997)
    );

    // IRQ is the LD-V1000 command strobe (Daphne superd.cpp); port 0x08 b6 acks.
    reg ld_cmd_strobe_q;
    always @(posedge clk_sys) begin
        if (!reset) begin n_irq <= 1'b1; ld_cmd_strobe_q <= 1'b0; end
        else begin
            ld_cmd_strobe_q <= ld_cmd_strobe;
            if (ld_cmd_strobe && !ld_cmd_strobe_q) n_irq <= 1'b0;
            else if (cpu_ce && cs_io_w && cpu_Dout[6]) n_irq <= 1'b1;
        end
    end

    //--------------------------------------------------------- sound ---------
    reg sn_ce;
    reg [5:0] sndiv;
    always @(posedge clk_sys) begin
        if (!reset) begin sndiv <= 6'd0; sn_ce <= 1'b0; end
        else begin
            sn_ce <= (sndiv == SNDIV - 6'd1);
            sndiv <= (sndiv == SNDIV - 6'd1) ? 6'd0 : sndiv + 6'd1;
        end
    end

    reg       sn_wr_n;
    reg [7:0] sn_din;
    always @(posedge clk_sys) begin
        if (!reset) begin sn_wr_n <= 1'b1; sn_din <= 8'd0; end
        else if (cpu_ce && cs_snd_w) begin sn_din <= cpu_Dout; sn_wr_n <= 1'b0; end
        else if (sn_ce) sn_wr_n <= 1'b1;
    end

    wire signed [10:0] sn_snd;
    jt89 u_sn (
        .rst(~reset), .clk(clk_sys), .clk_en(sn_ce),
        .wr_n(sn_wr_n), .cs_n(1'b0), .din(sn_din),
        .sound(sn_snd), .ready()
    );
    wire signed [15:0] sn_out = {sn_snd, 5'd0};
    assign sound_l = sn_out;
    assign sound_r = sn_out;

    //--------------------------------------------------------- CPU read mux --
    always @(*) begin
        if      (cs_rom)  cpu_Din = rom_D;
        else if (cs_ram)  cpu_Din = ram_D;
        else if (cs_vram) cpu_Din = vram_cpu_D;
        else if (io_access & ~n_rd) begin
            case (io_A)
                8'h00:   cpu_Din = in0;
                8'h01:   cpu_Din = in1;
                8'h02:   cpu_Din = dsw[7:0];
                8'h03:   cpu_Din = dsw[15:8];
                8'h04:   cpu_Din = ld_status;
                default: cpu_Din = 8'hFF;
            endcase
        end
        else              cpu_Din = 8'hFF;
    end

    //--------------------------------------------------------- renderer ------
    // The CRTC table the ROM writes from $0200 sets R1=32 columns and R6=28 rows,
    // so the DISPLAYED picture is 256x224, not 256x256: 256 is the frame total
    // including blanking (R4/R5), and VRAM rows 28..31 are never scanned out.
    // Both axes are therefore a stretch onto the shared 320x240 overlay space,
    // so no source row or column is ever dropped.
    wire [23:0] sx_mul = ovl_hpos * 16'd205;   // 320 -> 256 columns
    wire [23:0] sy_mul = ovl_vpos * 16'd239;   // 240 -> 224 rows
    wire  [7:0] src_x  = sx_mul[15:8];
    wire  [7:0] src_y  = sy_mul[15:8];
    wire        in_win = (sx_mul[23:16] == 8'd0) && (sy_mul[23:16] == 8'd0);

    // Free-run the fetch one cell ahead and adopt it at the cell boundary; the
    // displayed pixel is a bit-select from the latched row. Sampling a pass in
    // flight returns the previous cell -- see the Cliff Hanger renderer.
    wire [7:0] px_pf = src_x + 8'd8;

    reg  [3:0]  fs;
    reg  [7:0]  pf_code;
    reg  [31:0] pf_row, cur_row;
    reg  [4:0]  pf_cell, cur_cell;
    reg  [7:0]  pf_py,   cur_py;
    // A pass is published only once COMPLETE, carrying the cell it describes.
    reg  [31:0] done_row;
    reg  [4:0]  done_cell;
    reg  [7:0]  done_py;
    reg         done_valid;

    reg  [9:0]  vram_A_r;
    reg  [12:0] char_A_r;
    assign vram_rd_A = vram_A_r;
    assign char_A    = char_A_r;

    always @(posedge clk_sys) begin
        if (!reset) begin
            // Rows reset to all-Fs, not zero: pen 15 is transparent and pen 0 is
            // YELLOW, so a not-yet-fetched cell must read as 15 or it paints a
            // solid yellow block (seen at cell 0,0, which the prefetch never covers).
            fs <= 4'd0; pf_row <= {32{1'b1}}; cur_row <= {32{1'b1}};
            pf_cell <= 5'd0; cur_cell <= 5'h1F; pf_py <= 8'd0; cur_py <= 8'hFF;
            done_row <= {32{1'b1}}; done_cell <= 5'h1F; done_py <= 8'hFF; done_valid <= 1'b0;
        end else begin
            // dpram_dc is a 1-cycle REGISTERED read: an address presented at edge N
            // shows up on q at edge N+1, so every capture needs a wait state after
            // its address. Without them the row assembles as {prev_b3,b0,b1,b2} --
            // the glyph shifted right one byte and its last two pixels lost.
            case (fs)
                4'd0: begin
                    vram_A_r <= {src_y[7:3], px_pf[7:3]};
                    pf_cell  <= px_pf[7:3];
                    pf_py    <= src_y;
                    fs       <= 4'd1;
                end
                4'd1: fs <= 4'd2;                                  // vram read in flight
                4'd2: begin pf_code <= vram_rd_D; fs <= 4'd3; end
                // pf_py, not src_y: the row must come from the line this pass began on,
                // or a pass straddling a line boundary mixes rows of the glyph.
                4'd3: begin char_A_r <= {pf_code, pf_py[2:0], 2'd0}; fs <= 4'd4; end
                4'd4: begin char_A_r <= {pf_code, pf_py[2:0], 2'd1}; fs <= 4'd5; end
                4'd5: begin pf_row <= {pf_row[23:0], char_D};   // b0
                            char_A_r <= {pf_code, pf_py[2:0], 2'd2}; fs <= 4'd6; end
                4'd6: begin pf_row <= {pf_row[23:0], char_D};   // b1
                            char_A_r <= {pf_code, pf_py[2:0], 2'd3}; fs <= 4'd7; end
                4'd7: begin pf_row <= {pf_row[23:0], char_D}; fs <= 4'd8; end   // b2
                4'd8: begin
                    done_row   <= {pf_row[23:0], char_D};       // b3
                    done_cell  <= pf_cell;
                    done_py    <= pf_py;
                    done_valid <= 1'b1;
                    fs <= 4'd0;
                end
                default: fs <= 4'd0;
            endcase

            // Adopt only a COMPLETED pass that describes the cell being entered.
            // Testing pf_* instead samples a fetch in flight: the row then holds
            // bytes from two different cells, and because the FSM's phase drifts
            // against the raster the mix changes every cell and every frame.
            if (done_valid && (src_x[7:3] == done_cell) && (src_y == done_py) &&
                ((src_x[7:3] != cur_cell) || (src_y != cur_py))) begin
                cur_row  <= done_row;
                cur_cell <= src_x[7:3];
                cur_py   <= src_y;
            end
        end
    end

    // Pixel 0 sits in the high nibble of the first byte.
    wire  [4:0] shift    = {2'd0, ~src_x[2:0]} << 2;
    wire [31:0] row_shft = cur_row >> shift;
    wire  [3:0] pix      = row_shft[3:0];
    wire [4:0] pal_i = {color_bank, pix};
    // Daphne superd::palette_calculate, weights 0x24/0x4a/0x91 low-to-high:
    // red bit7 is the MSB, green bit4, blue bit1 -- and blue's low bit is tied 0.
    wire [2:0] c_r = prom_D[7:5];
    wire [2:0] c_g = prom_D[4:2];
    wire [2:0] c_b = {prom_D[1], prom_D[0], 1'b0};
    assign prom_A = pal_i;

    // Pen 15 is the transparent one, NOT pen 0: Daphne superd.cpp sets
    // palette_set_transparency(0,false) with the comment "color 0 is yellow",
    // and SUPERDON_TRANSPARENT_COLOR is 15. Most of this game's text IS pen 0.

    always @(posedge clk_sys) begin
        if (!reset) begin ovl_rgb <= 24'd0; ovl_opaque <= 1'b0; end
        else if (ovl_ce_pix) begin
            ovl_rgb    <= { c_r, c_r, c_r[2:1],
                            c_g, c_g, c_g[2:1],
                            c_b, c_b, c_b[2:1] };
            ovl_opaque <= in_win && (pix != 4'd15);
        end
    end

endmodule
