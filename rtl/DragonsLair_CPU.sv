//============================================================================
//
//  Dragon's Lair / Space Ace (US set) Main CPU Board
//  Based on MAME dlair.cpp (dlus_map / dlair_ldv1000) by Aaron Giles
//
//  Single Z80 @ (real 4 MHz) + AY-3-8910 (real 2 MHz) + Pioneer LD-V1000
//  laserdisc.  The LD is a real command/status HLE (DragonsLair_LDV1000.sv,
//  see "LaserDisc" section below) — LDV1000-UPGRADE-2026-07-04 replaced the
//  earlier constant-ready stub. This module has NO video output of its own;
//  all game video is on the LaserDisc, decoded/composited in the top file
//  (rtl/video/) — an earlier standalone LED-band raster that lived here was
//  superseded by that pipeline and removed (DEAD-CODE-2026-07-05, see led_band.v).
//
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
//
//  Interrupt: single periodic IRQ0 @ ~30.5 Hz (hold), cleared on Z80 INTA
//  (M1 + IORQ).  AY needs a 1 T-state WAIT when addressed.
//
//  CLOCK (fixed 2026-07-03): the core runs in the 40 MHz domain (CLK_40M from
//  the PLL).  Z80 = 40/10 = 4.00 MHz, AY = 40/20 = 2.00 MHz — both
//  real-hardware-correct (previously ran on CLK_10M at 62.5% speed).
//  Real-time signals (IRQ ~30.5 Hz, LD strobes) are counted in absolute
//  40 MHz cycles so they stay wall-clock accurate.
//
//============================================================================

module DragonsLair_CPU
(
    input         reset,             // active LOW (fed to RESET_n)
    input         clk_sys,           // 40 MHz master clock (CLK_40M from PLL)

    // Player inputs (active HIGH; inverted to active-low bus internally)
    input   [7:0] p1,                // {3'b0, btn1, right, left, down, up}
    input   [3:0] cab,               // {coin2, coin1, start2, start1}

    // Option switches, read through the AY I/O ports:
    //   dsw[7:0]  = DSW1 -> AY port A
    //   dsw[15:8] = DSW2 -> AY port B
    input  [15:0] dsw,

    // Audio (AY-3-8910)
    output signed [15:0] sound,

    // Main program ROM download (index 0) -> 0x0000-0x9FFF
    input         rom_cs_i,
    input  [24:0] ioctl_addr,
    input   [7:0] ioctl_data,
    input         ioctl_wr,

    input         pause,

    // LED score/status digits (16 x 4-bit, flattened) for the top-level FB compositor
    output [63:0] led_digits_o,

    // Bring-up "core alive" heartbeat LED
    output        dbg_led,

    // HLE-DRIVE-2026-07-04: LDV1000 HLE current disc frame -> streamer video/audio position
    output [16:0] ld_frame_o,

    // AUDIO-GATE-2026-07-05: LDV1000 HLE playing flag -> streamer audio ring gate
    output        ld_playing_o
);

//------------------------------------------------------- Clock Enables -------------------------------------------------------//

// 40 MHz master -> cen_4m (Z80, /10 = 4 MHz), cen_2m (AY, /20 = 2 MHz).
// One mod-20 counter yields both the Z80 tick (at 0 and 10) and the AY tick (at 0, coincident with a Z80 tick).
reg [4:0] cdiv = 5'd0;
always_ff @(posedge clk_sys) cdiv <= (cdiv == 5'd19) ? 5'd0 : cdiv + 5'd1;
wire cen_4m = (cdiv == 5'd0) | (cdiv == 5'd10);   // 40/10 = 4.00 MHz  (Z80)
wire cen_2m = (cdiv == 5'd0);                      // 40/20 = 2.00 MHz  (AY)

//------------------------------------------------------------ CPU -------------------------------------------------------------//

wire [15:0] cpu_A;
wire  [7:0] cpu_Dout;
wire        n_m1, n_mreq, n_iorq, n_rd, n_wr, n_rfsh;

T80s #(.Mode(0), .T2Write(1), .IOWait(1)) main_cpu
(
    .RESET_n(reset),
    .CLK(clk_sys),
    .CEN(cen_4m & ~pause),
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

// Bank select = A15:A13, device select = A5:A3 (A3/A4/A5 per the schematics)
wire [2:0] dev = cpu_A[5:3];

wire cs_rom = mem_access & (cpu_A[15:13] <= 3'b100);   // 0x0000-0x9FFF
wire cs_ram = mem_access & (cpu_A[15:13] == 3'b101);   // 0xA000-0xBFFF (2KB mirrored x4)
wire bankC  = mem_access & (cpu_A[15:13] == 3'b110);   // 0xC000-0xDFFF read strobes
wire bankE  = mem_access & (cpu_A[15:13] == 3'b111);   // 0xE000-0xFFFF write strobes

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

//--------------------------------------------------------- CPU Data Mux -------------------------------------------------------//

wire [7:0] rom_D;
wire [7:0] workram_D;
wire [7:0] ay_dout;

// P1 (0xC008): active-low, bits 5-7 unused (pulled high)
wire [7:0] p1_bus = ~p1;

// SYSTEM (0xC010): b0 START1, b1 START2, b2 COIN1, b3 COIN2 (active-low),
// b4/b5 unused (high), b6 LD status-strobe, b7 LD command/ready (active-high,
// from the LD stub below).
wire [7:0] system_bus = {~ld_command_strobe, ld_status_strobe, 2'b11, ~cab};

wire [7:0] cpu_Din =
    cs_rom            ? rom_D       :
    (cs_ram & ~n_rd)  ? workram_D   :
    cs_ay_data_r      ? ay_dout     :
    cs_p1             ? p1_bus      :
    cs_system         ? system_bus  :
    cs_ld_r           ? ld_status   :   // 0xC020 laserdisc_r
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

// 2KB work RAM at 0xA000-0xA7FF.  Port B unused (hiscore removed 2026-07-04).
dpram_dc #(.widthad_a(11)) work_ram
(
    .clock_a(clk_sys),
    .wren_a(cs_ram & ~n_wr),
    .address_a(cpu_A[10:0]),
    .data_a(cpu_Dout),
    .q_a(workram_D),

    .clock_b(clk_sys),
    .wren_b(1'b0),
    .address_b(11'b0),
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

//======================================================= LaserDisc stub =======================================================//
//
// Pioneer LD-V1000 (HLE) minimal stub, modelled on MAME ldv1000hle.cpp.  The
// real player continuously emits a status byte per video frame; the Z80 syncs
// to the status strobe, reads the status byte, and issues commands via
// latch(0xE020) + strobe(misc b5) + enter(misc b6).  To keep the Z80 from
// hanging on the LD handshake — and, crucially, to make the Dragon's Lair POST
// reach its "2nd beep = disc player initialized" — this stub:
//
//   * reports the player READY on SYSTEM b7 (command/ready strobe, 0 = ready);
//   * pulses the status-strobe on SYSTEM b6 at the LD-V1000 "park" rate;
//   * returns a constant "parked / ready / idle / no-error" status byte at
//     0xC020 = STATUS_PARK(0x7C) | STATUS_READY(0x80) = 0xFC.
//
// Timing replicates the HLE's device_reset() park cadence exactly:
//   park_strobe_tick every 21 ms:  status_strobe asserted (low) for 26 us,
//   then 54 us after the tick command_strobe asserted (low) for 25 us.
// In MAME the strobe bools sit TRUE(=high) and dip FALSE(=low) during a pulse;
// SYSTEM b6 = m_status_strobe, SYSTEM b7 = (ready==ASSERT)?0:1 = ~m_command_strobe.
//
// This is the note's recommended "first attempt: constant ready + idle status
// + ~frame-rate strobe."  It does NOT process commands (search/play), so real
// LD playback is not possible yet — that is the separate later effort.
// TODO(dlair): process ld_cmd_captured (search/play/stop) + drive real status
// codes (SEARCH_FINISH, PLAY, ...) once LD-on-FPGA video is added.
//
// LDV1000-UPGRADE-2026-07-04: the constant "parked/ready" stub below is REPLACED
// by the real DragonsLair_LDV1000 command/status controller (instanced further
// down).  Kept commented (not deleted) as a fallback — it was the POST-proven
// stub.  To revert: uncomment this block and delete the u_ldv1000 instance.
// localparam LD_STATUS_PARK  = 8'h7C;
// localparam LD_STATUS_READY = 8'h80;
//
// localparam [19:0] PARK_PERIOD = 20'd840000;  // 21 ms  @ 40 MHz
// localparam [19:0] STAT_LOW    = 20'd1040;    // 26 us  status-strobe low window
// localparam [19:0] CMD_START   = 20'd2160;    // 54 us  command-strobe start
// localparam [19:0] CMD_END     = 20'd3160;    // 79 us  command-strobe end (25 us wide)
//
// reg  [19:0] park_cnt          = 20'd0;
// reg         ld_status_strobe  = 1'b1;   // MAME m_status_strobe  (idle high)
// reg         ld_command_strobe = 1'b1;   // MAME m_command_strobe (idle high)
//
// always_ff @(posedge clk_sys) begin
//     if (!reset) begin
//         park_cnt          <= 18'd0;
//         ld_status_strobe  <= 1'b1;
//         ld_command_strobe <= 1'b1;
//     end
//     else begin
//         if (park_cnt >= PARK_PERIOD - 20'd1) park_cnt <= 20'd0;
//         else                                 park_cnt <= park_cnt + 20'd1;
//         ld_status_strobe  <= ~(park_cnt < STAT_LOW);
//         ld_command_strobe <= ~((park_cnt >= CMD_START) & (park_cnt < CMD_END));
//     end
// end
// wire [7:0] ld_status = LD_STATUS_PARK | LD_STATUS_READY;   // 0xFC

// Real LD-V1000 controller: processes the Z80's SEARCH/PLAY/STOP stream, tracks
// the disc frame, and reports real status + per-frame strobe (see DragonsLair_LDV1000.sv).
wire  [7:0] ld_status;
wire        ld_status_strobe, ld_command_strobe;
wire [16:0] ld_curr_frame;   // routed to the video path via ld_frame_o below (disc->film map, dlv_streamer.v)
wire        ld_playing_w;    // AUDIO-GATE-2026-07-05: mode==M_PLAY, for the streamer's audio ring gate

DragonsLair_LDV1000 u_ldv1000 (
    .clk            (clk_sys),
    .reset_n        (reset),          // core reset is active-low
    .cmd_stb        (ld_cmd_stb),
    .cmd_byte       (ld_data_latch),
    .status         (ld_status),
    .status_strobe  (ld_status_strobe),
    .command_strobe (ld_command_strobe),
    .curr_frame     (ld_curr_frame),
    .pause          (pause),            // HLE-DRIVE-2026-07-04: freeze disc motion during pause
    .playing        (ld_playing_w)      // AUDIO-GATE-2026-07-05
);

// HLE-DRIVE-2026-07-04: expose disc frame to the top (streamer maps -> mjpeg frame + audio sample)
assign ld_frame_o    = ld_curr_frame;
assign ld_playing_o  = ld_playing_w;   // AUDIO-GATE-2026-07-05

//------------------------------------------------- misc_w / LD data latch -----------------------------------------------------//
//
// misc_w (0xE008): b4 coin counter, b5 1->0 = strobe latched byte to LD,
//                  b6 = LD ENTER (0 = assert), b7 = INT/EXT.
// laserdisc_w (0xE020): latch the byte to send to the LD.
// The stub does not act on the command; ld_cmd_captured records the last byte
// strobed out for future real-LD command processing.
reg [7:0] misc_reg       = 8'd0;
reg [7:0] ld_data_latch  = 8'd0;
reg [7:0] ld_cmd_captured= 8'd0;   // last byte strobed to the LD (misc b5 1->0)
reg       ld_cmd_stb     = 1'b0;   // 1-cyc pulse -> LDV1000 controller (byte = ld_data_latch)

always_ff @(posedge clk_sys) begin
    if (!reset) begin
        misc_reg        <= 8'd0;
        ld_data_latch   <= 8'd0;
        ld_cmd_captured <= 8'd0;
        ld_cmd_stb      <= 1'b0;
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
    end
end

//----------------------------------------------------- LED digit latches ------------------------------------------------------//
//
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
end

// Expose the 16 digits (flattened) to the top-level FB compositor (led_band).
// led_digits_o[i*4 +: 4] = led_digits[i]  (digit 0 in the low nibble).
assign led_digits_o = {led_digits[15], led_digits[14], led_digits[13], led_digits[12],
                       led_digits[11], led_digits[10], led_digits[ 9], led_digits[ 8],
                       led_digits[ 7], led_digits[ 6], led_digits[ 5], led_digits[ 4],
                       led_digits[ 3], led_digits[ 2], led_digits[ 1], led_digits[ 0]};

//------------------------------------------------------ Periodic IRQ0 ---------------------------------------------------------//
//
// Single periodic IRQ0 @ ~30.5 Hz (hold), cleared on Z80 interrupt-acknowledge
// (M1 + IORQ).  MAME: set_periodic_int(irq0_line_hold, MASTER_CLOCK_US/8/16^4)
// = 16 MHz/8/65536 = 30.517 Hz.  The Operation Manual: RTC ~33 ms square wave,
// held until INTA (M1- + IORQ- together) removes it — required to keep the Z80
// in sync with the videodisc.  Counted in absolute 40 MHz cycles (wall-clock),
// matching the (real-time) LD-stub strobes.
localparam [20:0] IRQ_PERIOD = 21'd1310720;  // 40 MHz / 30.518 Hz

reg n_irq = 1'b1;
reg [20:0] irq_cnt = 21'd0;
always_ff @(posedge clk_sys) begin
    if (!reset) begin
        n_irq   <= 1'b1;
        irq_cnt <= 21'd0;
    end
    else begin
        if (irq_cnt >= IRQ_PERIOD - 21'd1) begin
            irq_cnt <= 21'd0;
            n_irq   <= 1'b0;              // assert (hold)
        end
        else begin
            irq_cnt <= irq_cnt + 21'd1;
        end
        if (~n_m1 & ~n_iorq) n_irq <= 1'b1;  // INTA clears the hold
    end
end

//---------------------------------------------------- Heartbeat LED -----------------------------------------------------------//

reg [23:0] hb_cnt = 24'd0;
always_ff @(posedge clk_sys) hb_cnt <= hb_cnt + 24'd1;
assign dbg_led = hb_cnt[23];   // ~0.6 Hz "core alive" blink

endmodule
