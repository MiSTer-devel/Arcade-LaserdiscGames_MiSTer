//============================================================================
// GP World (Sega, 1984) — Z80 + LD-V1000.
//
// Memory:  0x0000-0xBFFF ROM (48K)      0xC000-0xC7FF sprite RAM (64 x 8)
//          0xC800-0xCFFF colour RAM     0xD000-0xD7FF tile RAM (64x32 codes)
//          0xD800 LD-V1000 latch        0xDA00-0xDA03 8255 (sound board)
//          0xDA20 pedal ADC             0xE000-0xFFFF work RAM
// Ports:   OUT 01 b6 NMI enable, b2 start lamp
//          IN  80 shifter  81 coins/start/test  82 DSW1  83 DSW2
// LDP:     at each command strobe the output latch goes to the player and the
//          status comes back into the input latch, then NMI (MAME gpworld.cpp).
// IRQ:     once per field, after the NMI; cleared by the interrupt acknowledge.
// Video:   tiles 2bpp 8x8, visible columns 19-63 = 360 px, drawn over 4bpp
//          sprites (gpw_sprites.sv, graphics in DDR via gpw_spr_mem.sv).
// Sound:   discrete analog on the sound board, not implemented (disc audio only).
//============================================================================

module GPWorld
#(
    parameter [31:0] CLK_HZ = 32'd80_000_000,
    // Both emulators guess 5 MHz from Astron Belt; no schematic yet.
    parameter [31:0] CPU_HZ = 32'd5_000_000
)
(
    input                reset,        // active LOW
    input                clk_sys,

    input          [7:0] p1,           // {test,gear,brake,gas, right,left,down,up} active HIGH
    input          [3:0] cab,          // {coin2, coin1, start2, start1} active HIGH
    input                service,
    input         [15:0] dsw,          // dsw[7:0] = DSW1, dsw[15:8] = DSW2

    output signed [15:0] sound_l,
    output signed [15:0] sound_r,

    // ---- shared program ROM ----
    output        [15:0] rom_addr,
    input          [7:0] rom_data,

    // ---- shared graphics ROM (tile generator, 4K) ----
    output        [12:0] chr_rom_a,
    input          [7:0] chr_rom_q,

    // ---- sprite graphics (DDR, see gpw_spr_mem.sv) ----
    output               spr_rd_req,
    output        [17:0] spr_rd_addr,
    input                spr_rd_valid,
    input         [15:0] spr_rd_data,

    input                pause,
    input                disc_hold,
    input          [3:0] post_seek_frames,
    input                disc_2997,
    input         [16:0] disc_leader,

    output               ld_search_cmd_o,
    output               ld_play_end_o,
    output        [16:0] ld_frame_o,
    output               ld_playing_o,

    // ---- overlay ----
    // hraw is the 512-wide raster column: 360 source columns do not fit the
    // shared 320 space without dropping every ninth one.
    input         [15:0] ovl_hraw,
    input         [15:0] ovl_vpos,
    input                ovl_ce_pix,
    output reg    [23:0] ovl_rgb,
    output reg           ovl_opaque,

    // Sticky: solid once the CPU writes port 0x01.
    output               dbg_led
);

    //--------------------------------------------------------- clocking ------
    localparam [5:0] CDIV = CLK_HZ / CPU_HZ;
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
    reg         n_irq, n_nmi;

    T80s cpu (
        .RESET_n(reset), .CLK(clk_sys), .CEN(cpu_ce),
        .WAIT_n(1'b1), .INT_n(n_irq), .NMI_n(n_nmi), .BUSRQ_n(1'b1),
        .M1_n(n_m1), .MREQ_n(n_mreq), .IORQ_n(n_iorq),
        .RD_n(n_rd), .WR_n(n_wr),
        .A(cpu_A), .DI(cpu_Din), .DO(cpu_Dout)
    );

    wire mem_access = ~n_mreq;
    wire io_access  = ~n_iorq & n_m1;
    wire int_ack    = ~n_iorq & ~n_m1;
    wire [7:0] io_A = cpu_A[7:0];

    //--------------------------------------------------------- memory --------
    wire cs_rom  = mem_access & (cpu_A <  16'hC000);
    wire cs_spr  = mem_access & (cpu_A[15:11] == 5'b11000);      // C000-C7FF
    wire cs_pal  = mem_access & (cpu_A[15:11] == 5'b11001);      // C800-CFFF
    wire cs_vram = mem_access & (cpu_A[15:11] == 5'b11010);      // D000-D7FF
    wire cs_ldp  = mem_access & (cpu_A == 16'hD800);
    wire cs_ppi  = mem_access & (cpu_A[15:2] == 14'h3680);       // DA00-DA03
    wire cs_adc  = mem_access & (cpu_A == 16'hDA20);
    wire cs_ram  = mem_access & (cpu_A[15:13] == 3'b111);        // E000-FFFF

    wire [7:0] spr_cpu_D, pal_lo_cpu_D, pal_hi_cpu_D, vram_cpu_D, ram_D;

    assign rom_addr = cpu_A;

    dpram_dc #(.widthad_a(13)) u_ram (
        .clock_a(clk_sys), .address_a(cpu_A[12:0]), .q_a(ram_D),
        .wren_a(cs_ram & ~n_wr), .data_a(cpu_Dout),
        .clock_b(clk_sys), .address_b(13'd0), .data_b(8'd0), .wren_b(1'b0), .q_b()
    );

    wire [10:0] spr_eng_A;
    wire  [7:0] spr_eng_D;
    dpram_dc #(.widthad_a(11)) u_spr (
        .clock_a(clk_sys), .address_a(cpu_A[10:0]), .q_a(spr_cpu_D),
        .wren_a(cs_spr & ~n_wr), .data_a(cpu_Dout),
        .clock_b(clk_sys), .address_b(spr_eng_A), .data_b(8'd0), .wren_b(1'b0), .q_b(spr_eng_D)
    );

    // Colour RAM split by byte lane so the renderer reads a whole 12-bit entry at once.
    wire [9:0] pal_rd_A;
    wire [7:0] pal_lo_D, pal_hi_D;
    dpram_dc #(.widthad_a(10)) u_pal_lo (
        .clock_a(clk_sys), .address_a(cpu_A[10:1]), .q_a(pal_lo_cpu_D),
        .wren_a(cs_pal & ~n_wr & ~cpu_A[0]), .data_a(cpu_Dout),
        .clock_b(clk_sys), .address_b(pal_rd_A), .data_b(8'd0), .wren_b(1'b0), .q_b(pal_lo_D)
    );
    dpram_dc #(.widthad_a(10)) u_pal_hi (
        .clock_a(clk_sys), .address_a(cpu_A[10:1]), .q_a(pal_hi_cpu_D),
        .wren_a(cs_pal & ~n_wr &  cpu_A[0]), .data_a(cpu_Dout),
        .clock_b(clk_sys), .address_b(pal_rd_A), .data_b(8'd0), .wren_b(1'b0), .q_b(pal_hi_D)
    );

    // Second copy for sprite colour lookups ($CA00-$CBFF), so tiles and sprites resolve together.
    wire [9:0] spal_rd_A;
    wire [7:0] spal_lo_D, spal_hi_D;
    dpram_dc #(.widthad_a(10)) u_spal_lo (
        .clock_a(clk_sys), .address_a(cpu_A[10:1]), .q_a(),
        .wren_a(cs_pal & ~n_wr & ~cpu_A[0]), .data_a(cpu_Dout),
        .clock_b(clk_sys), .address_b(spal_rd_A), .data_b(8'd0), .wren_b(1'b0), .q_b(spal_lo_D)
    );
    dpram_dc #(.widthad_a(10)) u_spal_hi (
        .clock_a(clk_sys), .address_a(cpu_A[10:1]), .q_a(),
        .wren_a(cs_pal & ~n_wr &  cpu_A[0]), .data_a(cpu_Dout),
        .clock_b(clk_sys), .address_b(spal_rd_A), .data_b(8'd0), .wren_b(1'b0), .q_b(spal_hi_D)
    );

    wire [10:0] vram_rd_A;
    wire  [7:0] vram_rd_D;
    dpram_dc #(.widthad_a(11)) u_vram (
        .clock_a(clk_sys), .address_a(cpu_A[10:0]), .q_a(vram_cpu_D),
        .wren_a(cs_vram & ~n_wr), .data_a(cpu_Dout),
        .clock_b(clk_sys), .address_b(vram_rd_A), .data_b(8'd0),
        .wren_b(1'b0), .q_b(vram_rd_D)
    );

    // Tile generator lives in the top-level shared graphics pool.
    wire [12:0] char_A;
    wire  [7:0] char_D;
    assign chr_rom_a = char_A;
    assign char_D    = chr_rom_q;

    //--------------------------------------------------------- I/O -----------
    wire cs_io01_w = io_access & ~n_wr & (io_A == 8'h01);

    reg [7:0] io01;
    reg       io_w_seen;
    always @(posedge clk_sys) begin
        if (!reset) begin io01 <= 8'd0; io_w_seen <= 1'b0; end
        else if (cpu_ce && cs_io01_w) begin
            io01      <= cpu_Dout;
            io_w_seen <= 1'b1;
        end
    end
    assign dbg_led = io_w_seen;
    wire nmi_en = io01[6];

    // Shifter is a two-position lever; the gear button toggles it. 1 = LOW gear.
    reg gear_low, gear_q;
    always @(posedge clk_sys) begin
        if (!reset) begin gear_low <= 1'b1; gear_q <= 1'b0; end
        else begin
            gear_q <= p1[6];
            if (p1[6] & ~gear_q) gear_low <= ~gear_low;
        end
    end

    // IN0 b4 SHIFT; IN1 b0 COIN1, b1 COIN2, b2 TEST, b3 SERVICE, b4 START (MAME).
    wire [7:0] in0 = {3'b111, gear_low, 4'b1111};
    wire [7:0] in1 = ~{3'b000, cab[0], service, p1[7], cab[3], cab[2]};

    // Wheel, active LOW: b3..b0 right slight..fierce, b4..b7 left slight..fierce.
    // Digital stick drives the "strong" positions, as Daphne does.
    wire [7:0] wheel = ~{1'b0, p1[2], 3'b000, p1[3], 2'b00};

    // 8255 (control $98): A in = wheel, B out = sound, C low out (b0 pedal select).
    reg [7:0] ppi_b, ppi_c;
    always @(posedge clk_sys) begin
        if (!reset) begin ppi_b <= 8'hFF; ppi_c <= 8'h00; end
        else if (cpu_ce && cs_ppi && ~n_wr) begin
            case (cpu_A[1:0])
                2'd1: ppi_b <= cpu_Dout;
                2'd2: ppi_c <= cpu_Dout;
                default: ;
            endcase
        end
    end
    reg [7:0] ppi_D;
    always @(*) begin
        case (cpu_A[1:0])
            2'd0:    ppi_D = wheel;
            2'd1:    ppi_D = ppi_b;
            2'd2:    ppi_D = ppi_c;
            default: ppi_D = 8'hFF;
        endcase
    end

    // Pedals: b0 of port C selects gas (1) or brake (0). Digital buttons, full travel.
    wire [7:0] pedal = ppi_c[0] ? {8{p1[4]}} : {8{p1[5]}};

    //--------------------------------------------------------- LD player -----
    wire [7:0] ld_status;
    wire       ld_cmd_strobe;
    reg  [7:0] ld_out_latch, ld_in_latch;

    always @(posedge clk_sys) begin
        if (!reset) ld_out_latch <= 8'hFF;
        else if (cpu_ce && cs_ldp && ~n_wr) ld_out_latch <= cpu_Dout;
    end

    // Exchange on the falling edge of the command strobe: send the latch, wait for the
    // front-end (a C2 reply needs ~20 clocks of BCD conversion), capture the status,
    // pop it, then NMI. The IRQ follows at the strobe's rising edge, after the NMI.
    reg       ld_cmd_stb, ld_status_rd, strobe_q;
    reg [5:0] xch_cnt;
    always @(posedge clk_sys) begin
        ld_cmd_stb   <= 1'b0;
        ld_status_rd <= 1'b0;
        if (!reset) begin
            n_nmi <= 1'b1; n_irq <= 1'b1; strobe_q <= 1'b1;
            xch_cnt <= 6'd0; ld_in_latch <= 8'hFF;
        end else begin
            strobe_q <= ld_cmd_strobe;
            if (strobe_q & ~ld_cmd_strobe & nmi_en) begin
                ld_cmd_stb <= 1'b1;
                xch_cnt    <= 6'd40;
            end else if (xch_cnt != 6'd0) begin
                xch_cnt <= xch_cnt - 6'd1;
                if (xch_cnt == 6'd1) begin
                    ld_in_latch  <= ld_status;
                    ld_status_rd <= 1'b1;
                    n_nmi        <= 1'b0;
                end
            end
            if (~strobe_q & ld_cmd_strobe) begin
                n_nmi <= 1'b1;
                n_irq <= 1'b0;
            end else if (int_ack) n_irq <= 1'b1;
        end
    end

    ldp_top #(.CLK_HZ(CLK_HZ)) u_ldp (
        .clk(clk_sys), .reset_n(reset),
        .player_sel(4'd0),              // PLAYER_LDV1000
        .cmd_stb(ld_cmd_stb), .cmd_byte(ld_out_latch),
        .blip(1'b0),
        .status(ld_status), .status_strobe(), .command_strobe(ld_cmd_strobe),
        .ready_n(), .frame_valid(),
        .tx_valid(), .tx_byte(), .tx_pop(1'b0),
        .search_cmd_o(ld_search_cmd_o), .play_end_o(ld_play_end_o),
        .curr_frame(ld_frame_o),
        .pause(pause), .disc_hold(disc_hold), .playing(ld_playing_o),
        .dbg_seek_frame(), .dbg_end_frame(), .dbg_flags(),
        .post_seek_frames(post_seek_frames),
        .disc_2997(disc_2997),
        .park_frame(disc_leader), .status_rd(ld_status_rd)
    );

    //--------------------------------------------------------- sound ---------
    assign sound_l = 16'sd0;
    assign sound_r = 16'sd0;

    //--------------------------------------------------------- CPU read mux --
    always @(*) begin
        if      (cs_rom)  cpu_Din = rom_data;
        else if (cs_ram)  cpu_Din = ram_D;
        else if (cs_spr)  cpu_Din = spr_cpu_D;
        else if (cs_pal)  cpu_Din = cpu_A[0] ? pal_hi_cpu_D : pal_lo_cpu_D;
        else if (cs_vram) cpu_Din = vram_cpu_D;
        else if (cs_ldp)  cpu_Din = ld_in_latch;
        else if (cs_ppi)  cpu_Din = ppi_D;
        else if (cs_adc)  cpu_Din = pedal;
        else if (io_access & ~n_rd) begin
            case (io_A)
                8'h80:   cpu_Din = in0;
                8'h81:   cpu_Din = in1;
                8'h82:   cpu_Din = dsw[7:0];
                8'h83:   cpu_Din = dsw[15:8];
                default: cpu_Din = 8'hFF;
            endcase
        end
        else              cpu_Din = 8'hFF;
    end

    //--------------------------------------------------------- renderer ------
    // 360 source columns across the 512 raster (x45/64); 240 visible rows starting
    // at tile row 2 (Daphne shifts the overlay up 16 lines).
    localparam [7:0] V_OFS = 8'd16;
    // Sprites sit 28 lines lower than the tiles (tuned on HW: player car flush with the bottom edge).
    localparam signed [8:0] SPR_V_OFS = -9'sd12;
    wire [21:0] sx_mul = ovl_hraw[9:0] * 12'd45;
    wire  [8:0] src_x  = sx_mul[14:6];
    wire  [7:0] src_y  = ovl_vpos[7:0] + V_OFS;
    wire        in_win = (ovl_vpos < 16'd240);

    // Fetch one cell ahead and adopt only a completed pass at the cell boundary.
    wire [8:0] px_pf = src_x + 9'd8;

    reg  [2:0]  fs;
    reg  [7:0]  pf_code, pf_p0;
    reg  [5:0]  pf_cell;
    reg  [7:0]  pf_py;
    reg  [7:0]  done_code, done_p0, done_p1;
    reg  [5:0]  done_cell;
    reg  [7:0]  done_py;
    reg         done_valid;
    reg  [7:0]  cur_code, cur_p0, cur_p1;
    reg  [5:0]  cur_cell;
    reg  [7:0]  cur_py;

    reg  [10:0] vram_A_r;
    reg  [12:0] char_A_r;
    assign vram_rd_A = vram_A_r;
    assign char_A    = char_A_r;

    always @(posedge clk_sys) begin
        if (!reset) begin
            fs <= 3'd0; done_valid <= 1'b0;
            done_cell <= 6'h3F; done_py <= 8'hFF;
            cur_cell <= 6'h3F; cur_py <= 8'hFF;
            cur_p0 <= 8'd0; cur_p1 <= 8'd0; cur_code <= 8'd0;
        end else begin
            // dpram_dc reads are registered: each capture waits one cycle after its address.
            case (fs)
                3'd0: begin
                    vram_A_r <= {src_y[7:3], px_pf[8:3] + 6'd19};
                    pf_cell  <= px_pf[8:3];
                    pf_py    <= src_y;
                    fs       <= 3'd1;
                end
                3'd1: fs <= 3'd2;
                3'd2: begin pf_code <= vram_rd_D; fs <= 3'd3; end
                // Plane 0 at +0x000, plane 1 at +0x800, 8 bytes per code.
                3'd3: begin char_A_r <= {2'b00, pf_code, pf_py[2:0]}; fs <= 3'd4; end
                3'd4: begin char_A_r <= {2'b01, pf_code, pf_py[2:0]}; fs <= 3'd5; end
                3'd5: begin pf_p0 <= char_D; fs <= 3'd6; end
                3'd6: begin
                    done_p0    <= pf_p0;
                    done_p1    <= char_D;
                    done_code  <= pf_code;
                    done_cell  <= pf_cell;
                    done_py    <= pf_py;
                    done_valid <= 1'b1;
                    fs <= 3'd0;
                end
                default: fs <= 3'd0;
            endcase

            if (done_valid && (src_x[8:3] == done_cell) && (src_y == done_py) &&
                ((src_x[8:3] != cur_cell) || (src_y != cur_py))) begin
                cur_p0   <= done_p0;
                cur_p1   <= done_p1;
                cur_code <= done_code;
                cur_cell <= src_x[8:3];
                cur_py   <= src_y;
            end
        end
    end

    // MSB is the leftmost pixel; colour = {code[7:2], pixel} into the first 256 entries.
    wire [2:0] bsel = ~src_x[2:0];
    wire [1:0] pix  = {cur_p1[bsel], cur_p0[bsel]};
    assign pal_rd_A = {2'b00, cur_code[7:2], pix};

    //--------------------------------------------------------- sprites -----
    wire [7:0] spx;                 // {colour, pen}; pen 0 = none
    gpw_sprites u_sprites (
        .clk(clk_sys), .reset(reset),
        .spr_a(spr_eng_A), .spr_q(spr_eng_D),
        .rd_req(spr_rd_req), .rd_addr(spr_rd_addr),
        .rd_valid(spr_rd_valid), .rd_data(spr_rd_data),
        .vpos(ovl_vpos), .v_ofs(SPR_V_OFS), .src_x(src_x),
        .px(spx)
    );
    assign spal_rd_A = {2'b01, spx};

    // Daphne gpworld::palette_calculate: R = lo[3:0], G = lo[7:4], B = hi[3:0].
    // MAME swaps R and B; both are guesses -- flip PAL_RB_SWAP to try MAME's.
    localparam PAL_RB_SWAP = 1'b0;
    wire [3:0] c_r = PAL_RB_SWAP ? pal_hi_D[3:0] : pal_lo_D[3:0];
    wire [3:0] c_g = pal_lo_D[7:4];
    wire [3:0] c_b = PAL_RB_SWAP ? pal_lo_D[3:0] : pal_hi_D[3:0];
    // Daphne maps a black entry to the transparent pen, as well as pixel 0.
    wire       c_black = ({pal_hi_D[3:0], pal_lo_D} == 12'd0);
    wire [3:0] s_r = PAL_RB_SWAP ? spal_hi_D[3:0] : spal_lo_D[3:0];
    wire [3:0] s_g = spal_lo_D[7:4];
    wire [3:0] s_b = PAL_RB_SWAP ? spal_lo_D[3:0] : spal_hi_D[3:0];

    // Tiles over sprites (Daphne draws sprites first). Sprite pixels are opaque even when black.
    wire tile_op = (pix != 2'd0) && !c_black;
    wire spr_op  = (spx[3:0] != 4'd0);

    always @(posedge clk_sys) begin
        if (!reset) begin ovl_rgb <= 24'd0; ovl_opaque <= 1'b0; end
        else if (ovl_ce_pix) begin
            ovl_rgb    <= tile_op ? {c_r, c_r, c_g, c_g, c_b, c_b} : {s_r, s_r, s_g, s_g, s_b, s_b};
            ovl_opaque <= in_win && (tile_op || spr_op);
        end
    end

endmodule
