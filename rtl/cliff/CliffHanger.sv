//============================================================================
//  Cliff Hanger (Stern, 1983) — top-level game module.
//  Based on MAME stern/cliffhgr.cpp (authoritative for the I/O map and the
//  discrete sound) and Daphne game/cliff.cpp (authoritative for PR-8210 use).
//
//  Z80 + TMS9928A overlay + Pioneer PR-8210. All game video is on the disc;
//  the TMS overlay adds score/lives on top (DIP32). The overlay's RENDERER is
//  not implemented yet -- see tms9928a_regs.sv -- so nothing is drawn over the
//  video, but the chip's interrupt still drives the Z80 NMI as the game expects.
//
//  Memory map (MAME mainmem):
//    0x0000-0x9FFF  program ROM (5 x 8KB; the map extends to 0xBFFF, unpopulated)
//    0xE000-0xE7FF  battery-backed NVRAM (5126)   -- volatile here, see note
//    0xE800-0xEFFF  RAM (2128)
//============================================================================
module CliffHanger
#(
    parameter [31:0] CLK_HZ = 32'd80_000_000
)
(
    input                reset,        // active LOW
    input                clk_sys,

    input          [7:0] p1,           // {b3,b2,b1,action, right,left,down,up} active HIGH
    input          [3:0] cab,          // {coin2, coin1, start2, start1} active HIGH
    input         [39:0] dsw,          // DIP banks 0..4, one byte each

    output signed [15:0] sound_l,
    output signed [15:0] sound_r,

    input         [24:0] ioctl_addr,
    input          [7:0] ioctl_data,
    input                ioctl_wr,
    input          [7:0] ioctl_index,

    input                pause,
    input                disc_hold,
    input          [3:0] post_seek_frames,

    output               ld_search_cmd_o,
    output               ld_play_end_o,
    output        [16:0] ld_frame_o,
    output               ld_playing_o,
    output               dbg_led,

    // ---- TMS9928A overlay, composited over the disc video by the core top ----
    // Cliff draws its score, lives and the "ACTION" gameplay cue through the VDP,
    // so without this the game is effectively unplayable.
    input         [15:0] ovl_hpos,     // raster position, core's active area
    input         [15:0] ovl_vpos,
    input                ovl_ce_pix,   // pixel clock enable, samples the result
    output reg     [3:0] ovl_color,    // TMS colour index (0 = transparent)
    output reg           ovl_opaque    // 1 = draw ovl_color, 0 = show video
);
    //--------------------------------------------------------- clocking ------
    // Z80 at 4 MHz (CLIFF_CPU_HZ) from the 80 MHz core clock.
    localparam [5:0] CDIV = CLK_HZ / 32'd4_000_000;
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

    //--------------------------------------------------------- Z80 ------------
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
    wire io_access  = ~n_iorq & n_m1;      // M1 high excludes the interrupt ack
    wire [7:0] io_A = cpu_A[7:0];

    //--------------------------------------------------------- memory ---------
    // ROM 0x0000-0x9FFF (40KB), RAM+NVRAM as one 4KB block at 0xE000-0xEFFF.
    // NOTE: the 0xE000-0xE7FF half is battery-backed on real hardware. It is
    // plain RAM here, so high scores and bookkeeping do not survive a reset.
    wire cs_rom = mem_access & (cpu_A < 16'hA000);
    wire cs_ram = mem_access & (cpu_A[15:12] == 4'hE);

    wire [7:0] rom_D, ram_D;
    wire rom_ld = (ioctl_index == 8'd0) & ioctl_wr;

    dpram_dc #(.widthad_a(16)) u_rom (
        .clock_a(clk_sys), .address_a(cpu_A), .q_a(rom_D),
        .wren_a(1'b0), .data_a(8'd0),
        .clock_b(clk_sys), .address_b(ioctl_addr[15:0]), .data_b(ioctl_data),
        .wren_b(rom_ld), .q_b()
    );

    dpram_dc #(.widthad_a(12)) u_ram (
        .clock_a(clk_sys), .address_a(cpu_A[11:0]), .q_a(ram_D),
        .wren_a(cs_ram & ~n_wr), .data_a(cpu_Dout),
        .clock_b(clk_sys), .address_b(12'd0), .data_b(8'd0), .wren_b(1'b0), .q_b()
    );

    //--------------------------------------------------------- I/O decode -----
    // MAME mainport (global mask 0xFF).
    wire cs_vram_w = io_access & ~n_wr & (io_A == 8'h44);
    wire cs_vram_r = io_access & ~n_rd & (io_A == 8'h45);
    wire cs_snd_w  = io_access & ~n_wr & (io_A == 8'h46);
    wire cs_phil_r = io_access & ~n_rd & (io_A[7:2] == 6'b010100) & (io_A[1:0] != 2'b11); // 0x50-0x52
    wire cs_irqack = io_access & ~n_rd & (io_A == 8'h53);
    wire cs_vreg_w = io_access & ~n_wr & (io_A == 8'h54);
    wire cs_vreg_r = io_access & ~n_rd & (io_A == 8'h55);
    wire cs_philcl = io_access & ~n_wr & (io_A == 8'h57);
    wire cs_bank_w = io_access & ~n_wr & (io_A == 8'h60);
    wire cs_port_r = io_access & ~n_rd & (io_A == 8'h62);
    wire cs_wire_w = io_access & ~n_wr & (io_A == 8'h66);
    wire cs_coin_w = io_access & ~n_wr & (io_A == 8'h68);
    wire cs_led_w  = io_access & ~n_wr & (io_A[7:1] == 7'b0110111);  // 0x6E-0x6F

    //--------------------------------------------------------- input banks ----
    // MAME port_r: banks 0..6 are mapped, anything above reads pulled-up 0xFF.
    // Banks 0-4 are DIP switches from the MRA; 5 and 6 are the controls.
    reg [3:0] bank_sel;
    always @(posedge clk_sys) begin
        if (!reset) bank_sel <= 4'd0;
        else if (cpu_ce && cs_bank_w)
            // writing 0x0F clears the LS174; only D3-D0 are connected
            bank_sel <= (cpu_Dout == 8'h0F) ? 4'd0 : cpu_Dout[3:0];
    end

    // Active-low, like every switch and button on the board.
    // Bit assignments are MAME's (INPUT_PORTS_START(cliffhgr) BANK5/BANK6);
    // Daphne only labels these "button data" / "joystick data".
    //   BANK5: b0 COIN1, b1 COIN2, b2 BTN2 P1, b3 BTN2 P2,
    //          b4 BTN1 P1, b5 BTN1 P2, b6 unused, b7 TILT
    //   BANK6: b0 UP, b1 RIGHT, b2 DOWN, b3 LEFT, b7:4 unused
    //
    // Cliff's two buttons are HAND and FOOT (Daphne cliff.cpp input_enable):
    //   BUTTON1 = HAND = bit 4  ("only press one of the hands buttons")
    //   BUTTON2 = FOOT = bit 2  -- and START1 drives the SAME bit, which is why
    //     Daphne notes "so player doesn't have to press start1 for feet".
    //   START2 = bit 3.
    // Hand is mapped to A (m_action1), Foot to B (m_skill1).
    // P2's own hand button and TILT have no input here, so they read not-pressed.
    wire [7:0] bank5 = ~{1'b0,            // b7 TILT
                         1'b0,            // b6 unused
                         1'b0,            // b5 BTN1 (hand) P2
                         p1[4],           // b4 BTN1 (hand) P1  <- A
                         cab[1],          // b3 BTN2 P2 / START2
                         p1[5] | cab[0],  // b2 BTN2 (foot) P1 / START1  <- B or Start
                         cab[3],          // b1 COIN2
                         cab[2]};         // b0 COIN1
    wire [7:0] bank6 = ~{4'b0000, p1[2], p1[1], p1[3], p1[0]};

    reg [7:0] bank_bus;
    always @(*) begin
        case (bank_sel)
            4'd0: bank_bus = dsw[7:0];
            4'd1: bank_bus = dsw[15:8];
            4'd2: bank_bus = dsw[23:16];
            4'd3: bank_bus = dsw[31:24];
            4'd4: bank_bus = dsw[39:32];
            4'd5: bank_bus = bank5;
            4'd6: bank_bus = bank6;
            default: bank_bus = 8'hFF;
        endcase
    end

    //--------------------------------------------------------- laserdisc ------
    // PR-8210: the game toggles one wire. Daphne blips on a write of 1 to
    // port 0x66 (cliff.cpp) -- that is what is known to work with these ROMs.
    //
    // Must be edge-triggered on the WRITE, not a level gated by cpu_ce. cpu_ce
    // runs at the Z80 T-state rate and a Z80 OUT holds IORQ+WR for about three
    // T-states, so gating the level emitted THREE blips per write ~250 ns apart
    // and the 10-blip framing could never line up.
    reg ld_blip;
    reg cs_wire_q;
    always @(posedge clk_sys) begin
        ld_blip <= 1'b0;
        if (!reset) begin
            cs_wire_q <= 1'b0;
        end else begin
            cs_wire_q <= cs_wire_w;
            if (cs_wire_w && !cs_wire_q && cpu_Dout[0]) ld_blip <= 1'b1;
        end
    end

    wire [16:0] ld_curr_frame;
    wire        ld_frame_valid;

    ldp_top #(.CLK_HZ(CLK_HZ)) u_ldp (
        .clk(clk_sys), .reset_n(reset),
        .player_sel(4'd2),              // PLAYER_PR8210
        .cmd_stb(1'b0), .cmd_byte(8'd0),
        .blip(ld_blip),
        .status(), .status_strobe(), .command_strobe(), .ready_n(),
        .frame_valid(ld_frame_valid),
        .tx_valid(), .tx_byte(), .tx_pop(1'b0),
        .search_cmd_o(ld_search_cmd_o), .play_end_o(ld_play_end_o),
        .curr_frame(ld_curr_frame),
        .pause(pause), .disc_hold(disc_hold), .playing(ld_playing_o),
        .dbg_seek_frame(), .dbg_end_frame(), .dbg_flags(),
        .post_seek_frames(post_seek_frames)
    );
    assign ld_frame_o = ld_curr_frame;

    // ---- Philips VBI picture code (MAME philips_code_r) ----
    // 24 bits: 0xF in the top nibble marks a valid picture number, so bit 23 is
    // set and the IRQ fires; the low 20 bits are the frame as 5 BCD digits.
    wire [19:0] frame_bcd;
    bin17_to_bcd5 u_bcd (.clk(clk_sys), .reset_n(reset), .bin(ld_curr_frame), .bcd(frame_bcd));

    wire [23:0] philips_code = ld_frame_valid ? {4'hF, frame_bcd} : 24'd0;

    // The READY flag on port 0x52 is FIVE bits, not four. Daphne cliff.cpp:
    //     result = frame_digit0 & 0x0F;
    //     if (m_frame_val != 0) result |= 0xf8;   // "if the LDP is busy though,
    //                                             //  the upper 5 bits must be clear"
    // Setting only [7:4] (a plain 0xF nibble) leaves bit 3 holding digit0's bit 3,
    // which is 0 for any frame below 80000 -- so the game reads "LDP busy" forever
    // and never goes on to fetch 0x51/0x50. Measured in verilator/cliff: port 0x52
    // read 414 times, 0x51 and 0x50 never.
    wire frame_ready = ld_frame_valid && (ld_curr_frame != 17'd0);

    reg  [7:0]  phil_bus;
    always @(*) begin
        case (io_A[1:0])
            2'd0:    phil_bus = philips_code[7:0];    // 0x50: BCD digits 3,4
            2'd1:    phil_bus = philips_code[15:8];   // 0x51: BCD digits 1,2
            // 0x52: digit 0 in the low nibble, ready flag in the upper FIVE bits.
            default: phil_bus = frame_ready ? (8'hF8 | {4'd0, frame_bcd[19:16]})
                                            : {4'd0, frame_bcd[19:16]};
        endcase
    end

    //--------------------------------------------------------- TMS9928A -------
    wire [13:0] vram_A;
    wire  [7:0] vram_D, vram_Q;
    wire        vram_we;
    wire  [7:0] tms_dout;
    wire        tms_int_n;

    // Port A is the CPU side; port B is the display side, read-only.
    wire [13:0] vram_rd_A;
    wire  [7:0] vram_rd_Q;
    dpram_dc #(.widthad_a(14)) u_vram (
        .clock_a(clk_sys), .address_a(vram_A), .q_a(vram_Q),
        .wren_a(vram_we), .data_a(vram_D),
        .clock_b(clk_sys), .address_b(vram_rd_A), .data_b(8'd0),
        .wren_b(1'b0), .q_b(vram_rd_Q)
    );

    // 59.94 Hz field tick for the VDP's vblank interrupt.
    localparam [21:0] FIELD_PERIOD = (64'd1001 * CLK_HZ) / 64'd60000;
    reg [21:0] fcnt;
    wire       vblank_tick = (fcnt == FIELD_PERIOD - 22'd1);
    always @(posedge clk_sys) begin
        if (!reset) fcnt <= 22'd0;
        else fcnt <= vblank_tick ? 22'd0 : fcnt + 22'd1;
    end

    wire [63:0] tms_regs;

    tms9928a_regs u_tms (
        .clk(clk_sys), .reset_n(reset), .ce(cpu_ce),
        .port0_rd(cs_vram_r), .port0_wr(cs_vram_w),
        .port1_rd(cs_vreg_r), .port1_wr(cs_vreg_w),
        .din(cpu_Dout), .dout(tms_dout),
        .vblank_tick(vblank_tick), .irq_n(tms_int_n),
        .regs_o(tms_regs),
        .vram_addr(vram_A), .vram_din(vram_D), .vram_we(vram_we), .vram_dout(vram_Q)
    );

    //--------------------------------------------------------- overlay --------
    // Text mode is 40x24 cells of 6x8 = 240x192 active pixels; the core's active
    // area is 320x240, so centre it. Cliff's LED band is forced off in the top,
    // so vpos maps straight onto the picture with no band rows to skip.
    // ovl_hpos/ovl_vpos arrive in the SHARED 320x240 overlay space (converted
    // once at the top level), so these centring constants are in that space too.
    // Text is 40x24 of 6x8 = 240x192; Graphics II is 32x24 of 8x8 = 256x192.
    // M1 = reg1[4] = tms_regs[12], M2 = reg1[3] = tms_regs[11], M3 = reg0[1].
    wire text_mode = tms_regs[12] & ~tms_regs[11] & ~tms_regs[1];
    wire gfx2_mode = ~tms_regs[12] & ~tms_regs[11] & tms_regs[1];

    // THE TMS ACTIVE AREA IS THE WHOLE PICTURE -- there is no visible border.
    // Graphics II's 256x192 is exactly 4:3 and the shared overlay space is
    // 320x240, also exactly 4:3, so one maps onto the other with a uniform 0.8
    // scale and nothing left over. Any margin letterboxes a 4:3 source into a
    // 4:3 frame, which is what put the graphics in a shrunken centred box with
    // disc video framing them.
    //
    // The ROM says the same thing: entering Graphics II it writes R0=02 with
    // **R7=00**, i.e. backdrop 0 (measured). It never colours a border, because
    // on the real cabinet the VDP's border region is entirely inside monitor
    // overscan and is never seen.
    //
    // Text is 40 columns of 6 = 240 active pixels rather than 256, so it scales
    // by 0.75 instead. Its margin would be invisible either way -- in text mode
    // the cell background and the border are both reg7[3:0], the same value --
    // but full-bleed keeps the two modes consistent.
    // No origin offset: the active area starts at the first pixel of the frame.
    localparam [15:0] OVL_W = 16'd320;
    localparam [15:0] OVL_H = 16'd240;

    wire in_ovl = (ovl_hpos < OVL_W) && (ovl_vpos < OVL_H);

    // video pixel -> TMS pixel. Horizontal: 256/320 = 0.8 (x205 >> 8) in
    // graphics, 240/320 = 0.75 (x192 >> 8) in text. Vertical: 192/240 = 0.8 both.
    wire [23:0] ovl_x_g2  = ovl_hpos * 16'd205;
    wire [23:0] ovl_x_tx  = ovl_hpos * 16'd192;
    wire [23:0] ovl_y_mul = ovl_vpos * 16'd205;
    wire [15:0] ovl_x     = gfx2_mode ? ovl_x_g2[23:8] : ovl_x_tx[23:8];
    wire [15:0] ovl_y     = ovl_y_mul[23:8];

    wire [3:0] rnd_color;
    wire       rnd_transparent;

    // ce is tied high: the renderer takes 3 core clocks per query and there are
    // ~13 per pixel, so it re-resolves the current pixel several times over and
    // the answer is settled well before ovl_ce_pix samples it below.
    tms9928a_render u_tms_render (
        .clk(clk_sys), .reset_n(reset), .ce(1'b1),
        .reg0(tms_regs[7:0]),   .reg1(tms_regs[15:8]),
        .reg2(tms_regs[23:16]), .reg3(tms_regs[31:24]),
        .reg4(tms_regs[39:32]), .reg5(tms_regs[47:40]),
        .reg6(tms_regs[55:48]), .reg7(tms_regs[63:56]),
        .px(ovl_x[8:0]), .py(ovl_y[7:0]),
        .active(in_ovl),                      // the window, not a magic px value
        .color(rnd_color), .transparent(rnd_transparent),
        .vram_addr(vram_rd_A), .vram_data(vram_rd_Q)
    );

    // Sample once per pixel. Text and Graphics II are rendered; any other mode
    // (Graphics I, Multicolor) stays fully transparent rather than drawing
    // garbage -- the ROM never selects them.
    always @(posedge clk_sys) begin
        if (!reset) begin
            ovl_color <= 4'd0; ovl_opaque <= 1'b0;
        end else if (ovl_ce_pix) begin
            ovl_color  <= rnd_color;
            // NOT gated on in_ovl. A real TMS drives the WHOLE screen: the
            // cell area, and the backdrop colour everywhere around it. Gating
            // on the cell window let the disc show through the border, which is
            // why the logo screen looked centred instead of edge to edge.
            // in_ovl now only tells the renderer where the cells are (`active`);
            // outside it the renderer emits the backdrop, and transparency comes
            // from colour 0 alone -- exactly as the hardware does it.
            // transp_en is deliberately NOT in this expression yet. Daphne makes
            // colour 0 opaque unless the board arms transparency, but a 14 s sim
            // shows Cliff's ROM never writing port 0x46 bit 4 in that window, so
            // gating on it would only turn see-through areas solid. The latch is
            // built and observable; wire it in once the ROM is seen to drive it.
            ovl_opaque <= (text_mode | gfx2_mode) & ~rnd_transparent;
        end
    end

    //--------------------------------------------------------- interrupts -----
    // IRQ: asserted when a valid Philips code arrives each field, cleared by
    // reading port 0x53 (MAME irq_ack_r). NMI follows the TMS interrupt.
    always @(posedge clk_sys) begin
        if (!reset) n_irq <= 1'b1;
        else begin
            if (vblank_tick && ld_frame_valid) n_irq <= 1'b0;
            else if (cpu_ce && cs_irqack)      n_irq <= 1'b1;
        end
    end
    always @(posedge clk_sys) n_nmi <= tms_int_n;

    //--------------------------------------------------------- sound ----------
    // Discrete: two gated 555 astables mixed (MAME cliffhgr_a.cpp).
    //   f = 1.44 / ((R1 + 2*R2) * C), R1 = 24k, R2 = 10k
    //   C = 0.047uF -> ~696 Hz ; C = 0.1uF -> ~327 Hz ; duty (R1+R2)/(R1+2R2) = 77%
    localparam [31:0] SND1_PERIOD = CLK_HZ / 32'd696;
    localparam [31:0] SND2_PERIOD = CLK_HZ / 32'd327;
    reg [31:0] s1_cnt, s2_cnt;
    reg        s1_out, s2_out;
    reg  [1:0] snd_en;

    always @(posedge clk_sys) begin
        if (!reset) begin
            s1_cnt <= 32'd0; s2_cnt <= 32'd0; s1_out <= 1'b0; s2_out <= 1'b0;
            snd_en <= 2'd0;
        end else begin
            if (cpu_ce && cs_snd_w) snd_en <= cpu_Dout[1:0];
            // 77% duty, matching the 555's charge/discharge ratio
            s1_cnt <= (s1_cnt >= SND1_PERIOD - 32'd1) ? 32'd0 : s1_cnt + 32'd1;
            s2_cnt <= (s2_cnt >= SND2_PERIOD - 32'd1) ? 32'd0 : s2_cnt + 32'd1;
            s1_out <= (s1_cnt < ((SND1_PERIOD * 32'd77) / 32'd100));
            s2_out <= (s2_cnt < ((SND2_PERIOD * 32'd77) / 32'd100));
        end
    end
    //------------------------------------------------------------------------
    // Board genlock. Port 0x46 bit 4 is NOT a sound bit: it tells the video
    // hardware to keep the overlay transparent. Daphne cliff.cpp:
    //     if ((Value & 0x10) == 0x10) tms9128nl_set_transparency();
    // and tms9128nl.cpp makes colour 0 see-through while it is set, opaque
    // background when it is not -- then clears it EVERY NMI, because "this has
    // to be set to true every pulse of the NMI in order to maintain the
    // transparency. The Cliff ROM does this." So a frame in which the ROM stops
    // asking goes solid, which is how the game covers the disc deliberately.
    reg transp_en;
    always @(posedge clk_sys) begin
        if (!reset) transp_en <= 1'b0;
        else begin
            if (vblank_tick)                          transp_en <= 1'b0;
            if (cpu_ce && cs_snd_w && cpu_Dout[4])    transp_en <= 1'b1;  // set wins
        end
    end


    wire signed [15:0] snd = ((snd_en[0] & s1_out) ? 16'sd6000 : 16'sd0)
                           + ((snd_en[1] & s2_out) ? 16'sd6000 : 16'sd0);
    assign sound_l = snd;
    assign sound_r = snd;

    //--------------------------------------------------------- board LED -------
    // The real Cliff Hanger PCB has a test LED next to the reset switch, driven
    // by a write to port 0x6E (on) or 0x6F (off); the data byte is ignored.
    // MAME stern/cliffhgr.cpp: `m_led = offset ^ 1`, offset 0 = 0x6E = lit.
    // Routed to the MiSTer USER LED so the board's own POST heartbeat is visible.
    // Idempotent set/clear, so no edge detect is needed.
    reg board_led;
    always @(posedge clk_sys) begin
        if (!reset)         board_led <= 1'b0;
        else if (cs_led_w)  board_led <= ~io_A[0];   // 0x6E -> 1, 0x6F -> 0
    end

    assign dbg_led = board_led;


    //--------------------------------------------------------- CPU data mux ---
    always @(*) begin
        if      (cs_rom)    cpu_Din = (cpu_A < 16'hA000) ? rom_D : 8'hFF;
        else if (cs_ram)    cpu_Din = ram_D;
        else if (cs_vram_r) cpu_Din = tms_dout;
        else if (cs_vreg_r) cpu_Din = tms_dout;
        else if (cs_phil_r) cpu_Din = phil_bus;
        else if (cs_port_r) cpu_Din = bank_bus;
        else if (cs_irqack) cpu_Din = 8'h00;      // MAME returns 0
        else                cpu_Din = 8'hFF;
    end

    // Unused writes, decoded so they do not fall through to a warning:
    // 0x57 philips clear, 0x60 bank (handled), 0x64/0x6A unused, 0x68 coin counter.
    // 0x6E/0x6F is the board LED and IS acted on, just above.
    wire _unused = &{1'b0, cs_philcl, cs_coin_w, n_m1, 1'b0};
endmodule
