//============================================================================
//  Dragon's Lair / Space Ace (US set) Main CPU Board
//  Based on MAME dlair.cpp (dlus_map / dlair_ldv1000) by Aaron Giles
//  Single Z80 @ (real 4 MHz) + AY-3-8910 (real 2 MHz) + Pioneer LD-V1000
//  laserdisc.  The LD is a real command/status HLE (rtl/ldp/,
//  see "LaserDisc" section below) — replaced the
//  earlier constant-ready stub. This module has NO video output of its own;
//  all game video is on the LaserDisc, decoded/composited in the top file
//  (rtl/video/) — an earlier standalone LED-band raster that lived here was
//  superseded by that pipeline and removed (, see led_band.v).
//  Memory map (dlus_map), reads mirror 0x1FC7 / writes mirror 0x1FC7,
//  device-select = A5:A3, bank-select = A15:A13:
//    0x0000-0x9FFF  R   ROM (region size 0xA000)
//    0xA000-0xA7FF  RW  Work RAM (2KB, mirror 0x1800 -> 0xA000-0xBFFF)
//    0xC000  R  AY-3-8910 data_r          (bank 110, dev 000)
//    0xC008  R  P1 input                  (bank 110, dev 001)
//    0xC010  R  SYSTEM input (+LD status) (bank 110, dev 010)
//    0xC020  R  laserdisc_r (LD status)   (bank 110, dev 100)
//    0xE000  W  AY-3-8910 data_w          (bank 111, dev 000)
//    0xE008  W  misc_w (LD strobe/enter)  (bank 111, dev 001)
//    0xE010  W  AY-3-8910 address_w       (bank 111, dev 010)
//    0xE020  W  laserdisc_w (data latch)  (bank 111, dev 100)
//    0xE038-0xE03F W led_den1 (7-seg 0-7)  (bank 111, dev 111, A2:A0 = digit)
//    0xE030-0xE037 W led_den2 (7-seg 8-15) (bank 111, dev 110, A2:A0 = digit)
//  Thayer's Quest (RDI board, is_thayers=1) shares this Z80, LaserDisc and program
//  ROM but is a different machine: the ROM/RAM split differs and every peripheral
//  is I/O-mapped rather than memory-mapped.
//    0x0000-0x7FFF R ROM (tq_u33)   0x8000-0xBFFF RW RAM 16KB   0xC000-0xDFFF R ROM (tq_u1)
//    IN  0x40 irq status   IN 0x80 COP data    IN 0xF0 LD data
//    IN  0xF1 DSWB/coins/strobes    IN 0xF2 DSWA
//    OUT 0x20 COP G2:G0    OUT 0x80 COP data   OUT 0xA0/0xC0/0xF3 interrupt acks
//    OUT 0xF4 LD data      OUT 0xF5 LD ctrl    OUT 0xF6/0xF7 scoreboard
//  Its interrupts are LATCHED and cleared only by those port acks -- an interrupt
//  acknowledge cycle does NOT clear them, unlike Dragon's Lair below.
//  Interrupt: single periodic IRQ0 @ ~30.5 Hz (hold), cleared on Z80 INTA
//  (M1 + IORQ).  AY needs a 1 T-state WAIT when addressed.
//  CLOCK (fixed; re-based): the core runs in the single
//  CLK_CORE domain from the PLL, whose rate arrives as the CLK_HZ parameter
//  (CORE_CLK_HZ in Arcade-LaserdiscGames.sv, 80 MHz today; was 40 MHz).  The Z80
//  and AY rates are REAL-HARDWARE constants and never change — only the
//  dividers do: Z80 = 4.00 MHz, AY = 2.00 MHz, both derived from CLK_HZ below.
//  Real-time signals (IRQ ~30.5 Hz, LD strobes) are counted in absolute
//  CLK_CORE cycles, scaled from CLK_HZ, so they stay wall-clock accurate.
//============================================================================

module DragonsLair_CPU
#(
    // core clock rate, threaded down from CORE_CLK_HZ in
    // Arcade-LaserdiscGames.sv.  The Z80/AY clock enables derive from it -- never re-hardcode 40e6.
    parameter [31:0] CLK_HZ = 32'd80_000_000
)
(
    input         reset,             // active LOW (fed to RESET_n)
    input         clk_sys,           // master clock (80 MHz as of ; was 40 MHz)

    // Player inputs (active HIGH; inverted to active-low bus internally)
    input   [7:0] p1,                // {skill3,skill2,skill1, btn1, right, left, down, up}
    input   [3:0] cab,               // {coin2, coin1, start2, start1}

    // Option switches, read through the AY I/O ports:
    //   dsw[7:0]  = DSW1 -> AY port A
    //   dsw[15:8] = DSW2 -> AY port B
    input  [15:0] dsw,

    // Board select: 0 = Dragon's Lair / Space Ace (dlus_map), 1 = Thayer's Quest (RDI)
    input         is_thayers,
    input         is_spaceace,

    // Audio (AY-3-8910)
    output signed [15:0] sound,

    // Main program ROM download (index 0) -> 0x0000-0x9FFF
    input         rom_cs_i,
    input         cop_rom_cs_i,    // MRA index 2 -> COP421 program ROM
    input  [24:0] ioctl_addr,
    input   [7:0] ioctl_data,
    input         ioctl_wr,

    input         pause,
    input         disc_hold,      // video path priming -> freeze disc motion

    // LED score/status digits (16 x 4-bit, flattened) for the top-level FB compositor
    output [63:0] led_digits_o,
    // Space Ace skill level, latched from the game's own scoreboard write
    output  [1:0] skill_o,       // 0 = none yet, 1 = Cadet, 2 = Captain, 3 = Space Ace

    // Bring-up "core alive" heartbeat LED
    output        dbg_led,

    // LDV1000 HLE current disc frame -> streamer video/audio position
    output        search_cmd_o,   // Z80's CMD_SEARCH accepted (1-cycle)
    output        play_end_o,     // playback stopped (1-cycle)
    output [16:0] ld_frame_o,

    // LDV1000 HLE playing flag -> streamer audio ring gate
    output        ld_playing_o,
    // MRA-tunable post-seek tail drain (index 1, byte 1). 0 = instant flush.
    input   [3:0] post_seek_frames
);

//------------------------------------------------------- Clock Enables -------------------------------------------------------//

// clk_sys -> cen_4m (Z80, 4 MHz) and cen_2m (AY, 2 MHz).  Both are REAL-HARDWARE rates and do
// not change with the core clock -- only the divider does.
localparam [5:0] CDIV_MOD  = CLK_HZ / 32'd2_000_000;   // 40 @ 80 MHz -> AY  = 2 MHz
localparam [5:0] CDIV_HALF = CLK_HZ / 32'd4_000_000;   // 20 @ 80 MHz -> Z80 = 4 MHz
reg [5:0] cdiv = 6'd0;
always_ff @(posedge clk_sys) cdiv <= (cdiv == CDIV_MOD - 6'd1) ? 6'd0 : cdiv + 6'd1;
wire cen_4m = (cdiv == 6'd0) | (cdiv == CDIV_HALF);   // 4.00 MHz  (Z80)
wire cen_2m = (cdiv == 6'd0);                          // 2.00 MHz  (AY)

//------------------------------------------------------------ CPU -------------------------------------------------------------//

wire [15:0] cpu_A;
wire  [7:0] cpu_Dout;
wire        n_m1, n_mreq, n_iorq, n_rd, n_wr, n_rfsh;

T80s #(.Mode(0), .T2Write(1), .IOWait(1)) main_cpu
(
    .RESET_n(reset),
    .CLK(clk_sys),
    // CEN is gated by disc_hold to freeze GAME TIME while the video path primes after a seek:
    // the Z80 runs on a real-time ~30.5 Hz IRQ, so if the picture is held but the CPU keeps
    // counting it schedules the segment end from a moment the player has not seen yet.
    .CEN(cen_4m & ~pause & ~disc_hold),
    .WAIT_n(cpu_wait_n),
    .INT_n(n_irq),
    .NMI_n(1'b1),
    .BUSRQ_n(1'b1),
    .M1_n(n_m1),
    .MREQ_n(n_mreq),
    .IORQ_n(n_iorq),
    .RD_n(n_rd),
    .WR_n(n_wr),
    .RFSH_n(n_rfsh),
    .A(cpu_A),
    .DI(cpu_Din),
    .DO(cpu_Dout)
);

//------------------------------------------------------ Address Decoding ------------------------------------------------------//

wire mem_access = ~n_mreq & n_rfsh;
wire io_access  = ~n_iorq & n_m1;    // M1 high excludes the interrupt-acknowledge cycle

// Bank select = A15:A13, device select = A5:A3 (A3/A4/A5 per the schematics)
wire [2:0] dev = cpu_A[5:3];

wire dl_rom = mem_access & (cpu_A[15:13] <= 3'b100);   // 0x0000-0x9FFF
wire dl_ram = mem_access & (cpu_A[15:13] == 3'b101);   // 0xA000-0xBFFF (2KB mirrored x4)
wire bankC  = mem_access & (cpu_A[15:13] == 3'b110) & ~is_thayers;   // 0xC000 read strobes
wire bankE  = mem_access & (cpu_A[15:13] == 3'b111) & ~is_thayers;   // 0xE000 write strobes

// Thayer's: ROM either side of a 16KB RAM window.
wire tq_rom = mem_access & (~cpu_A[15] | (cpu_A[15:13] == 3'b110));
wire tq_ram = mem_access & (cpu_A[15:14] == 2'b10);

wire cs_rom = is_thayers ? tq_rom : dl_rom;
wire cs_ram = is_thayers ? tq_ram : dl_ram;

// Read strobes (0xC0xx)
wire cs_ay_data_r = bankC & ~n_rd & (dev == 3'b000);   // 0xC000
wire cs_p1        = bankC & ~n_rd & (dev == 3'b001);   // 0xC008
wire cs_system    = bankC & ~n_rd & (dev == 3'b010);   // 0xC010
wire cs_ld_r      = bankC & ~n_rd & (dev == 3'b100);   // 0xC020

// Write strobes (0xE0xx)
wire cs_ay_data_w = bankE & ~n_wr & (dev == 3'b000);   // 0xE000
wire cs_misc_w    = bankE & ~n_wr & (dev == 3'b001);   // 0xE008
wire cs_ay_addr_w = bankE & ~n_wr & (dev == 3'b010);   // 0xE010
wire cs_ld_w      = bankE & ~n_wr & (dev == 3'b100);   // 0xE020
wire cs_led2_w    = bankE & ~n_wr & (dev == 3'b110);   // 0xE030-0xE037
wire cs_led1_w    = bankE & ~n_wr & (dev == 3'b111);   // 0xE038-0xE03F

// Thayer's I/O ports
wire       tq_io = io_access & is_thayers;
wire [7:0] io_A  = cpu_A[7:0];
wire cs_tq_irqst = tq_io & ~n_rd & (io_A == 8'h40);
wire cs_tq_coprd = tq_io & ~n_rd & (io_A == 8'h80);
wire cs_tq_ldrd  = tq_io & ~n_rd & (io_A == 8'hF0);
wire cs_tq_f1    = tq_io & ~n_rd & (io_A == 8'hF1);
wire cs_tq_f2    = tq_io & ~n_rd & (io_A == 8'hF2);
wire cs_tq_copg  = tq_io & ~n_wr & (io_A == 8'h20);
wire cs_tq_copwr = tq_io & ~n_wr & (io_A == 8'h80);
wire cs_tq_ackt  = tq_io & ~n_wr & (io_A == 8'hA0);   // TIMER INT ack
wire cs_tq_ackd  = tq_io & ~n_wr & (io_A == 8'hC0);   // DATA RDY INT ack
wire cs_tq_ackp  = tq_io & ~n_wr & (io_A == 8'hF3);   // periodic INT ack + re-arm
wire cs_tq_ldwr  = tq_io & ~n_wr & (io_A == 8'hF4);
wire cs_tq_ldctl = tq_io & ~n_wr & (io_A == 8'hF5);
wire cs_tq_den1  = tq_io & ~n_wr & (io_A == 8'hF6);
wire cs_tq_den2  = tq_io & ~n_wr & (io_A == 8'hF7);

//--------------------------------------------------------- CPU Data Mux -------------------------------------------------------//

wire [7:0] rom_D;
wire [7:0] workram_D;
wire [7:0] ay_dout;

// P1 (0xC008): active-low. Daphne calls this the "joystick/spaceace skill query" (lair.cpp:771).
// b5/b6/b7 are NOT unused -- they are Space Ace's Cadet/Captain/Space Ace
// skill-level buttons (daughter board; lair.cpp:1055-1063). Dragon's Lair just never reads them.
wire [7:0] p1_bus = ~p1;

// SYSTEM (0xC010): b0 START1, b1 START2, b2 COIN1, b3 COIN2 (active-low),
// b4/b5 unused (high), b6 LD status-strobe, b7 LD command/ready (active-high,
// from the LD stub below).
// LD Player DIP.  Each ROM dispatches its LD send routine on its OWN bit and polarity at
// $0213 (bit tested on $A011 = AY port B = dsw[15:8]):
//   Dragon's Lair  bit 3,(hl) / jp z,$026E  -> dsw[11] CLEAR = PR-7820
//   Space Ace      bit 0,(hl) / jp nz,$026E -> dsw[8]  SET   = PR-7820
// Both MRAs default their bit to LD-V1000.  Thayer's is LD-V1000 only and uses dsw[11:8] as
// its own DIP bank B, so it must never be decoded as a player select.
wire pr7820_mode = is_thayers  ? 1'b0   :
                   is_spaceace ? dsw[8] : ~dsw[11];

// SYSTEM (0xC010) b7: the LD-V1000 reports its command strobe here; the PR-7820 has no strobes
// at all and instead drives its /READY line onto the same bit (Daphne lair.cpp m_misc_val 0x80).
// b6 is the LD-V1000 status strobe; the PR-7820 never asserts it, so it idles high.
wire [7:0] system_bus = pr7820_mode ? {ld_ready_n, 1'b1, 2'b11, ~cab}
                                    : {~ld_command_strobe, ld_status_strobe, 2'b11, ~cab};

// Thayer's 0xF1: b7/b6 are the LD strobes straight from the HLE (idle high, assert low) --
// unlike SYSTEM b7 above, which inverts the command strobe.  b5/b4 coin 2/1 active low,
// b3:0 DIP bank B (the board only returns the low nibble of that switch).
wire [7:0] tq_f1_bus = {ld_command_strobe, ld_status_strobe, ~cab[3], ~cab[2], dsw[11:8]};

wire [7:0] cpu_Din =
    cs_rom            ? rom_D       :
    (cs_ram & ~n_rd)  ? workram_D   :
    cs_ay_data_r      ? ay_dout     :
    cs_p1             ? p1_bus      :
    cs_system         ? system_bus  :
    cs_ld_r           ? ld_status   :   // 0xC020 laserdisc_r
    cs_tq_irqst       ? irq_status  :   // 0x40 interrupt status
    cs_tq_coprd       ? cop_rd      :   // 0x80 COP data
    cs_tq_ldrd        ? ld_status   :   // 0xF0 laserdisc data
    cs_tq_f1          ? tq_f1_bus   :   // 0xF1
    cs_tq_f2          ? dsw[7:0]    :   // 0xF2 DSWA
    8'hFF;

//----------------------------------------------------- AY 1 T-state WAIT ------------------------------------------------------//

// The GI sound chip requires the Z80 to insert one T-state WAIT (~250 ns)
// whenever the AY is addressed (read or write).  Bounded generator: drives
// WAIT_n low for exactly one CPU clock-enable on the first cycle of an AY
// access, then releases and disarms until the access ends.  It can only ever
// add 0 or 1 wait states, never hang.
reg  cpu_wait_n   = 1'b1;
reg  ay_wait_done = 1'b0;
wire ay_access    = cs_ay_data_r | cs_ay_data_w | cs_ay_addr_w;

always_ff @(posedge clk_sys) begin
    if (!reset) begin
        cpu_wait_n   <= 1'b1;
        ay_wait_done <= 1'b0;
    end
    else begin
        if (cen_4m) begin
            if (ay_access & ~ay_wait_done) begin
                cpu_wait_n   <= 1'b0;   // one wait state
                ay_wait_done <= 1'b1;
            end
            else begin
                cpu_wait_n <= 1'b1;
            end
        end
        if (~ay_access) ay_wait_done <= 1'b0;  // rearm once the access ends
    end
end

//-------------------------------------------------------- Program ROM ---------------------------------------------------------//

// Single 64KB dpram covering the 0x0000-0x9FFF program space.  Loaded directly
// by ioctl (index 0); read side gated by cs_rom in the data mux above.
dpram_dc #(.widthad_a(16)) prog_rom
(
    .clock_a(clk_sys),
    .address_a(cpu_A[15:0]),
    .data_a(8'd0),
    .wren_a(1'b0),
    .q_a(rom_D),

    .clock_b(clk_sys),
    .address_b(ioctl_addr[15:0]),
    .data_b(ioctl_data),
    .wren_b(ioctl_wr & rom_cs_i),
    .q_b()
);

//---------------------------------------------------------- Work RAM ----------------------------------------------------------//

// 16KB work RAM.  Dragon's Lair / Space Ace use only the low 2KB (A[10:0], so 0xA000-0xBFFF
// still mirrors x4 exactly as before); Thayer's uses all of it linearly across 0x8000-0xBFFF.
wire [13:0] ram_A = is_thayers ? cpu_A[13:0] : {3'b000, cpu_A[10:0]};

dpram_dc #(.widthad_a(14)) work_ram
(
    .clock_a(clk_sys),
    .wren_a(cs_ram & ~n_wr),
    .address_a(ram_A),
    .data_a(cpu_Dout),
    .q_a(workram_D),

    .clock_b(clk_sys),
    .wren_b(1'b0),
    .address_b(14'b0),
    .data_b(8'b0),
    .q_b()
);

//-------------------------------------------------------- AY-3-8910 -----------------------------------------------------------//

// Driven directly from the main Z80:
//   0xE010 address_w -> {bdir,bc1} = 2'b11 (latch register address)
//   0xE000 data_w    -> {bdir,bc1} = 2'b10 (write data)
//   0xC000 data_r    -> read dout (bdir/bc1 idle; jt49 dout tracks reg)
// Ports A/B are inputs = DSW1/DSW2.
wire ay_bdir = cs_ay_data_w | cs_ay_addr_w;
wire ay_bc1  = cs_ay_addr_w;

wire [7:0] ay_A, ay_B, ay_C;

jt49_bus #(.COMP(3'b010)) ay_chip
(
    .rst_n(reset),
    .clk(clk_sys),
    .clk_en(cen_2m),
    .bdir(ay_bdir),
    .bc1(ay_bc1),
    .din(cpu_Dout),
    .sel(1'b1),
    .dout(ay_dout),
    .sound(),
    .A(ay_A),
    .B(ay_B),
    .C(ay_C),
    .sample(),
    .IOA_in(dsw[7:0]),   .IOA_out(),
    .IOB_in(dsw[15:8]),  .IOB_out()
);

// Mix three unsigned 8-bit channels -> signed 16-bit (as in the Kangaroo copy).
wire [9:0] ay_sum = {2'b00, ay_A} + {2'b00, ay_B} + {2'b00, ay_C};
wire signed [15:0] ay_signed = {1'b0, ay_sum, 5'd0} - 16'sd12288;
assign sound = ay_signed;


// Laserdisc player: one shared transport (rtl/ldp/ldp_transport.sv) plus a protocol
// front-end per player, selected at runtime by player_sel (see rtl/ldp/ldp_top.sv).
wire  [7:0] ld_status;
wire        ld_status_strobe, ld_command_strobe, ld_ready_n;
wire [16:0] ld_curr_frame;   // routed to the video path via ld_frame_o below (disc->film map, dlv_streamer.v)
wire        ld_playing_w;    // mode==M_PLAY, for the streamer's audio ring gate
wire [16:0] dbg_seek_frame_w;
wire [19:0] dbg_end_frame_w;   // raw SEARCH digits (5 nibbles)   // segment start/end frame probe
wire  [3:0] dbg_flags_w;                         // sticky autostop telemetry

ldp_top #(.CLK_HZ(CLK_HZ)) u_ldp (   // thread the core clock down
    .clk            (clk_sys),
    .reset_n        (reset),          // core reset is active-low
    .cmd_stb        (ld_cmd_stb),
    .cmd_byte       (ld_data_latch),
    .status         (ld_status),
    .status_strobe  (ld_status_strobe),
    .command_strobe (ld_command_strobe),
    .player_sel     ({3'd0, pr7820_mode}),   // 0 = LD-V1000, 1 = PR-7820
    .blip           (1'b0),                 // PR-8210 only
    .tx_pop         (1'b0),                 // LDP-1450 only
    .ready_n        (ld_ready_n),
    .search_cmd_o   (search_cmd_o),
    .play_end_o     (play_end_o),
    .curr_frame     (ld_curr_frame),
    .pause          (pause),            // freeze disc motion during pause
    .disc_hold      (disc_hold),        // video path still priming
    .playing        (ld_playing_w),
    .dbg_seek_frame (dbg_seek_frame_w), // segment START frame
    .dbg_end_frame  (dbg_end_frame_w), // segment END frame
    .dbg_flags      (dbg_flags_w),     // autostop armed/fired
    .post_seek_frames(post_seek_frames)
);

// expose disc frame to the top (streamer maps -> mjpeg frame + audio sample)
assign ld_frame_o    = ld_curr_frame;
assign ld_playing_o  = ld_playing_w;

//------------------------------------------------- misc_w / LD data latch -----------------------------------------------------//
// misc_w (0xE008): b4 coin counter, b5 1->0 = strobe latched byte to LD,
//                  b6 = LD ENTER (0 = assert), b7 = INT/EXT.
// laserdisc_w (0xE020): latch the byte to send to the LD.
// The stub does not act on the command; ld_cmd_captured records the last byte
// strobed out for future real-LD command processing.
reg [7:0] misc_reg       = 8'd0;
reg [7:0] ld_data_latch  = 8'd0;
reg [7:0] ld_cmd_captured= 8'd0;   // last byte strobed to the LD (misc b5 1->0)
reg       ld_cmd_stb     = 1'b0;   // 1-cyc pulse -> LDV1000 controller (byte = ld_data_latch)
reg       tq_wr_busy     = 1'b0;   // OUT 0xF4 spans many clk_sys cycles; latch once per access
reg       tq_send        = 1'b0;   // defers the strobe a cycle so cmd_byte is settled

always_ff @(posedge clk_sys) begin
    if (!reset) begin
        misc_reg        <= 8'd0;
        ld_data_latch   <= 8'd0;
        ld_cmd_captured <= 8'd0;
        ld_cmd_stb      <= 1'b0;
        tq_wr_busy      <= 1'b0;
        tq_send         <= 1'b0;
    end
    else begin
        ld_cmd_stb <= 1'b0;                            // default: no strobe this cycle
        if (cs_ld_w) ld_data_latch <= cpu_Dout;        // 0xE020 laserdisc_w
        if (cs_misc_w) begin
            if (misc_reg[5] & ~cpu_Dout[5]) begin      // b5 1->0 = OUT DISC DATA
                ld_cmd_captured <= ld_data_latch;
                ld_cmd_stb      <= 1'b1;               // hand the byte to the LDV1000
            end
            misc_reg <= cpu_Dout;
        end

        // Thayer's sends on the data write itself (Daphne port 0xF4 -> write_ldv1000); the
        // 0xF5 latch carries the coin counter / ENTER / INT-EXT bits but does not gate it.
        if (cs_tq_ldwr) begin
            if (~tq_wr_busy) begin
                ld_data_latch <= cpu_Dout;
                tq_wr_busy    <= 1'b1;
                tq_send       <= 1'b1;
            end
        end
        else tq_wr_busy <= 1'b0;

        if (tq_send) begin
            tq_send         <= 1'b0;
            ld_cmd_captured <= ld_data_latch;
            ld_cmd_stb      <= 1'b1;
        end

        if (cs_tq_ldctl) misc_reg <= cpu_Dout;
    end
end

//------------------------------------------------- Thayer's COP421 + interrupts -----------------------------------------------//
// The COP is Thayer's only MCU: its D port drives the timer tick (D0) and keyboard data-ready
// (D1), both active low (Daphne thayers_write_d_port / MAME cop_d_w).
wire [3:0] cop_d;
wire [7:0] cop_rd;

Thayers_COP #(.CLK_HZ(CLK_HZ)) u_cop
(
    .clk_sys(clk_sys), .reset_n(reset),
    .rom_cs_i(cop_rom_cs_i), .ioctl_addr(ioctl_addr), .ioctl_data(ioctl_data), .ioctl_wr(ioctl_wr),
    .z80_dout(cpu_Dout), .wr_g(cs_tq_copg), .wr_data(cs_tq_copwr), .rd_data(cop_rd),
    .cop_d(cop_d)
);

// Four LATCHED active-low sources ORed onto the Z80 IRQ.  Each is asserted by its hardware and
// cleared ONLY by the matching port ack -- an interrupt acknowledge does NOT clear them.
// The periodic source is a board one-shot: T = 1.1 * R30 * C53 = 8.25 ms (MAME thayers.cpp).
// It is ASSERTED at reset, so Thayer's first EI takes an interrupt immediately, and OUT 0xF3
// both acks it and re-arms the one-shot.
localparam [19:0] PERIODIC_TICKS = (CLK_HZ / 32'd1_000_000) * 20'd8250;
localparam        ssi_req        = 1'b1;   // SSI-263 A/_R -- not implemented, held inactive
localparam        cart_present   = 1'b1;   // _CART PRES -- no cartridge fitted

reg        timer_int    = 1'b1;
reg        data_rdy_int = 1'b1;
reg        periodic_int = 1'b0;
reg [19:0] periodic_cnt = 20'd0;
reg        periodic_run = 1'b0;
reg  [3:0] cop_d_q      = 4'hF;

// IN (0x40): b7 and b1:0 read 0, b3 is tied to +5V (MAME irqstate_r).
wire [7:0] irq_status = {1'b0, cart_present, data_rdy_int, timer_int, 1'b1, ssi_req, 2'b00};
wire       n_irq_tq   = timer_int & data_rdy_int & periodic_int & ssi_req;

always_ff @(posedge clk_sys) begin
    if (!reset) begin
        timer_int <= 1'b1; data_rdy_int <= 1'b1; periodic_int <= 1'b0;
        periodic_cnt <= 20'd0; periodic_run <= 1'b0; cop_d_q <= 4'hF;
    end
    else begin
        cop_d_q <= cop_d;
        // Acks first, so a source re-asserting in the same cycle is not lost.
        if (cs_tq_ackt) timer_int    <= 1'b1;
        if (cs_tq_ackd) data_rdy_int <= 1'b1;
        if (cs_tq_ackp) begin
            periodic_int <= 1'b1;
            periodic_cnt <= 20'd0;
            periodic_run <= 1'b1;
        end
        if (periodic_run) begin
            if (periodic_cnt >= PERIODIC_TICKS - 20'd1) begin
                periodic_run <= 1'b0;
                periodic_int <= 1'b0;
            end
            else periodic_cnt <= periodic_cnt + 20'd1;
        end
        // The COP asserts on the falling edge of its D pins, matching MAME's cop_d_w.
        if (cop_d_q[0] & ~cop_d[0]) timer_int    <= 1'b0;
        if (cop_d_q[1] & ~cop_d[1]) data_rdy_int <= 1'b0;
    end
end

//----------------------------------------------------- LED digit latches ------------------------------------------------------//
// Two banks of 8 common-anode 7-seg digits.  Z80 writes a 4-bit digit code:
//   0xE038-0xE03F (led_den1) -> digits[0..7]   (MAME led_den1_w: m_digits[0|off])
//   0xE030-0xE037 (led_den2) -> digits[8..15]  (MAME led_den2_w: m_digits[8|off])
// The 7-seg lookup (led_map in MAME) is applied at render time by led_band.v
// (rtl/video/), fed via led_digits_o below — the top file's score/status band.
reg [3:0] led_digits [0:15];
integer li;
initial for (li = 0; li < 16; li = li + 1) led_digits[li] = 4'd0;

always_ff @(posedge clk_sys) begin
    if (cs_led1_w) led_digits[{1'b0, cpu_A[2:0]}] <= cpu_Dout[3:0];  // den1 (E038) -> digits 0..7  (MAME dlair.cpp:332)
    if (cs_led2_w) led_digits[{1'b1, cpu_A[2:0]}] <= cpu_Dout[3:0];  // den2 (E030) -> digits 8..15 (MAME dlair.cpp:338)
    // Thayer's packs the digit select into the DATA byte, not the address (Daphne
    // write_scoreboard).  #unverified -- slot mapping still needs checking on a running game.
    if (cs_tq_den1) led_digits[{1'b0, cpu_Dout[6:4]}] <= cpu_Dout[3:0];
    if (cs_tq_den2) led_digits[{1'b1, cpu_Dout[6:4]}] <= cpu_Dout[3:0];
end

// Expose the 16 digits (flattened) to the top-level compositor: led_digits_o[i*4 +: 4] =
// led_digits[i], digit 0 in the low nibble.
reg [1:0] skill_lat;
always @(posedge clk_sys) begin
    if (!reset) skill_lat <= 2'd0;                       // reset is active LOW on this module
    else if (cs_led1_w && (cpu_Dout == 8'hCC)) begin
        case (cpu_A[2:0])
            3'd6:    skill_lat <= 2'd1;                  // Cadet
            3'd5:    skill_lat <= 2'd2;                  // Captain
            3'd3:    skill_lat <= 2'd3;                  // Space Ace
            default: ;                                   // digit 7 = the common marker, ignore
        endcase
    end
end
assign skill_o = skill_lat;

assign led_digits_o = {led_digits[15], led_digits[14], led_digits[13], led_digits[12],
                       led_digits[11], led_digits[10], led_digits[ 9], led_digits[ 8],
                       led_digits[ 7], led_digits[ 6], led_digits[ 5], led_digits[ 4],
                       led_digits[ 3], led_digits[ 2], led_digits[ 1], led_digits[ 0]};

// Segment-boundary frame probe, displayed as 5 hex digits per score field.

//------------------------------------------------------ Periodic IRQ0 ---------------------------
// Single periodic IRQ0 @ ~30.5 Hz (hold), cleared on Z80 interrupt-acknowledge (M1 + IORQ).
localparam [21:0] IRQ_PERIOD = (64'd1310720 * CLK_HZ) / 64'd40_000_000;  // clk_sys / 30.518 Hz

reg n_irq_dl = 1'b1;
wire n_irq = is_thayers ? n_irq_tq : n_irq_dl;
reg [21:0] irq_cnt = 22'd0;
always_ff @(posedge clk_sys) begin
    if (!reset) begin
        n_irq_dl <= 1'b1;
        irq_cnt  <= 22'd0;
    end
    // the IRQ counter IS game-time -- it must freeze with the CPU, or the
    // interrupt phase walks by the hold duration on every seek even though the Z80 is stopped.
    else begin
        // Only the TIMER freezes. The INTA clear below stays ungated: if the hold happened to
        // assert during an interrupt-acknowledge cycle, gating it would drop the clear and the
        // Z80 would re-enter the ISR on resume.
        if (!disc_hold && !is_thayers) begin
            if (irq_cnt >= IRQ_PERIOD - 22'd1) begin
                irq_cnt <= 22'd0;
                n_irq_dl <= 1'b0;             // assert (hold)
            end
            else begin
                irq_cnt <= irq_cnt + 22'd1;
            end
        end
        if (~n_m1 & ~n_iorq) n_irq_dl <= 1'b1;  // INTA clears the hold (Dragon's Lair only)
    end
end

//---------------------------------------------------- Heartbeat LED -----------------------------------------------------------//

reg [23:0] hb_cnt = 24'd0;
always_ff @(posedge clk_sys) hb_cnt <= hb_cnt + 24'd1;
assign dbg_led = hb_cnt[23];   // ~0.6 Hz "core alive" blink

endmodule
