//============================================================================
//
// Dragon's Lair / Space Ace (US set) for MiSTer
// Copyright (C) 2026 Rodimus
// Based on MAME dlair.cpp; converted in place from the Kangaroo core copy
//
//  Permission is hereby granted, free of charge, to any person obtaining a
//  copy of this software and associated documentation files (the "Software"),
//  to deal in the Software without restriction, including without limitation
//  the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  and/or sell copies of the Software, and to permit persons to whom the
//  Software is furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  DEALINGS IN THE SOFTWARE.
//
//============================================================================

module emu
(
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [48:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	//if VIDEO_ARX[12] or VIDEO_ARY[12] is set then [11:0] contains scaled size instead of aspect ratio.
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER, // Force VGA scaler
	output        VGA_DISABLE, // analog out is off

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
	// Use framebuffer in DDRAM (USE_FB=1 in qsf)
	// FB_FORMAT:
	//    [2:0] : 011=8bpp(palette) 100=16bpp 101=24bpp 110=32bpp
	//    [3]   : 0=16bits 565 1=16bits 1555
	//    [4]   : 0=RGB  1=BGR (for 16/24/32 modes)
	//
	// FB_STRIDE either 0 (rounded to 256 bytes) or multiple of pixel size (in bytes)
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,

`ifdef MISTER_FB_PALETTE
	// Palette control for 8bit modes.
	// Ignored for other video modes.
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	// I/O board button press simulation (active high)
	// b[1]: user button
	// b[0]: osd button
	output  [1:0] BUTTONS,

	input         CLK_AUDIO, // 24.576 MHz
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

	//ADC
	inout   [3:0] ADC_BUS,

	//SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	//Secondary SDRAM
	//Set all output SDRAM_* signals to Z ASAP if SDRAM2_EN is 0
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	// Open-drain User port.
	// 0 - D+/RX
	// 1 - D-/TX
	// 2..6 - USR2..USR6
	// Set USER_OUT to 1 to read from USER_IN.
	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;

assign VGA_F1 = 0;
assign VGA_SCALER = 0;
assign VGA_DISABLE = 0;
assign FB_FORCE_BLANK = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

wire signed [15:0] audio_l, audio_r;
assign AUDIO_L = pause_cpu ? 16'd0 : audio_l;
assign AUDIO_R = pause_cpu ? 16'd0 : audio_r;
assign AUDIO_S = 1;   // signed
assign AUDIO_MIX = 0; // no mix, true stereo

assign LED_DISK  = 0;
assign LED_POWER = 0;
wire dbg_led;
assign LED_USER  = dbg_led;  // ~0.6 Hz "core alive" heartbeat from DragonsLair_CPU
assign BUTTONS = 0;

///////////////////////////////////////////////////

wire [1:0] ar = status[14:13];

// ROT0-FIX-2026-07-03: Dragon's Lair / Space Ace are HORIZONTAL-only.  This core was
// inherited from Kangaroo (vertical, ROT90) and defaulted to Vert (status[12]=0), which
// rotated the raster onto the right edge and used a portrait 3:4 aspect.  Force horizontal
// orientation + 4:3 aspect everywhere status[12] was used, and drop the (now inert)
// Orientation toggle from the OSD.  (Was: status[12] selected Vert/Horz.)
wire horz = 1'b1;

assign VIDEO_ARX = horz ? ((!ar) ? 12'd4 : (ar - 1'd1)) : ((!ar) ? 12'd3 : (ar - 1'd1));
assign VIDEO_ARY = horz ? ((!ar) ? 12'd3 : 12'd0) : ((!ar) ? 12'd4 : 12'd0);

`include "build_id.v"
localparam CONF_STR = {
	"DRAGONSLAIR;;",
	"ODE,Aspect Ratio,Original,Full screen,[ARC1],[ARC2];",
	// "OC,Orientation,Vert,Horz;",  // ROT0-FIX-2026-07-03: removed — DL/SA horizontal-only, orientation hardcoded (see horz)
	"OB,Flip Vertical,Off,On;",
	"OFH,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"-;",
	"P1,Pause Options;",
	"P1OP,Pause when OSD is open,On,Off;",
	"P1OQ,Dim video after 10s,On,Off;",
	"-;",
	"DIP;",
	"-;",
	"R0,Reset;",
	"J1,Button1,Button2,Button3,Button4,Coin,Start 1P,Start 2P,Pause;",
	"jn,A,B,X,Y,Select,Start,R,L;",
	"V,v",`BUILD_DATE
};

wire        forced_scandoubler;
wire  [1:0] buttons;
wire [31:0] status;
wire [10:0] ps2_key;

wire        ioctl_download;
wire        ioctl_upload;
wire        ioctl_upload_req;
wire  [7:0] ioctl_index;
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire  [7:0] ioctl_din;

wire [15:0] joystick_0, joystick_1;
wire [15:0] joy = joystick_0 | joystick_1;

wire [21:0] gamma_bus;
wire        direct_video;
wire        video_rotated = 1'b0;   // screen_rotate removed (ROT0) — video is never rotated

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(CLK_10M),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),
	.direct_video(direct_video),
	.video_rotated(video_rotated),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask({direct_video}),

	.ioctl_download(ioctl_download),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_din(ioctl_din),
	.ioctl_index(ioctl_index),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.ps2_key(ps2_key)
);

////////////////////   CLOCKS   ///////////////////
wire CLK_40M;
wire CLK_10M;
wire locked;

pll pll
(
    .refclk(CLK_50M),
    .rst(0),
    .outclk_0(CLK_40M),
    .outclk_1(CLK_10M),
    .locked(locked)
);

assign CLK_VIDEO = CLK_40M;   // HDMI needs the 40 MHz reference

wire reset = RESET | status[0] | buttons[1] | ioctl_download;

///////////////////         Keyboard           //////////////////

reg btn_up       = 0;
reg btn_down     = 0;
reg btn_left     = 0;
reg btn_right    = 0;
reg btn_fire     = 0;
reg btn_fire2    = 0;
reg btn_coin1    = 0;
reg btn_coin2    = 0;
reg btn_1p_start = 0;
reg btn_2p_start = 0;
reg btn_pause    = 0;
reg btn_service  = 0;

wire pressed = ~ps2_key[9];
wire [7:0] code = ps2_key[7:0];
always @(posedge CLK_10M) begin
	reg old_state;
	old_state <= ps2_key[10];
	if(old_state != ps2_key[10]) begin
		case(code)
			'h16: btn_1p_start <= pressed; // 1 = Player 1 Start
			'h1E: btn_2p_start <= pressed; // 2 = Player 2 Start
			'h2E: btn_coin1    <= pressed; // 5 = Coin Input 1
			'h36: btn_coin2    <= pressed; // 6 = Coin Input 2
			'h4D: btn_pause    <= pressed; // P = Pause
			'h46: btn_service  <= pressed; // 9 = Test Advance

			'h75: btn_up       <= pressed; // up         = Up
			'h72: btn_down     <= pressed; // down       = Down
			'h6B: btn_left     <= pressed; // left       = Left
			'h74: btn_right    <= pressed; // right      = Right
			'h14: btn_fire     <= pressed; // ctrl       = Draw Slow
			'h12: btn_fire2    <= pressed; // left shift = Draw Fast
		endcase 
	end
end

//////////////////  Arcade Buttons/Interfaces   ///////////////////////////

// Dragon's Lair / Space Ace: 4-way joystick + one action button (SWORD).
//Player 1
wire m_up1      = btn_up        | joystick_0[3];
wire m_down1    = btn_down      | joystick_0[2];
wire m_left1    = btn_left      | joystick_0[1];
wire m_right1   = btn_right     | joystick_0[0];
wire m_action1  = btn_fire      | joystick_0[4];
// Cadet, Captain, Space Ace buttons 5-7

//Start/Coin
wire m_start1   = btn_1p_start  | joystick_0[9];
wire m_start2   = btn_2p_start  | joystick_0[10];
wire m_coin1    = btn_coin1     | joystick_0[8];
wire m_coin2    = btn_coin2     | joystick_1[8];
wire m_pause    = btn_pause     | joystick_0[11];

// PAUSE SYSTEM
wire pause_cpu;
wire [23:0] rgb_out;
pause #(8,8,8,10) pause
(
	.*,
	.clk_sys(CLK_10M),
	.user_button(m_pause),
	.pause_request(1'b0),   // hiscore removed 2026-07-04
	.options(~status[26:25])
);

///////////////                 Video                  ////////////////

wire hblank, vblank;
wire hs, vs;
wire [7:0] r, g, b;
wire ce_pix;

// ---- Raster video path (DDR framebuffer -> arcade_video) : FB-PIVOT-2026-07-04 ----
wire [63:0] led_digits_flat;
wire        rr_ce_pix, rr_hs, rr_vs, rr_hblank, rr_vblank;
wire [15:0] rr_hpos, rr_vpos;
wire  [7:0] rr_r, rr_g, rr_b;
wire        led_lit;
wire  [7:0] comp_r = led_lit ? 8'hFF : rr_r;   // LED band = red over the video
wire  [7:0] comp_g = led_lit ? 8'h00 : rr_g;
wire  [7:0] comp_b = led_lit ? 8'h00 : rr_b;
wire [26:0] rr_rdaddr2;
wire [15:0] rr_dout2;
wire        rr_rd_req2, rr_rd_ack2;

// DIAG-2026-06-18: 2x pixel clock for "double the size then reduce". arcade_video now renders 512 px/line
// (each of the 256 source columns doubled -> MAME-style dimmed-copy interleave); screen_rotate + the
// scaler then shrink the 512-wide framebuffer back to the display ("reduce the resolution/size").
// ce_pix MUST be a CLK_40M-domain pulse: the core's 5 MHz ce_pix lives in the 10 MHz domain and can't be
// cleanly doubled there. Phase (==2) samples mid-period after the core's RGB settles; if pixels shimmer
// or smear horizontally, try ==1 or ==3. To revert: arcade_video back to #(256,24) and drop .ce_pix below.
reg [1:0] ce_pix_div = 2'd0;
always @(posedge CLK_40M) ce_pix_div <= ce_pix_div + 1'd1;
wire ce_pix_2x = (ce_pix_div == 2'd2);   // 10 MHz, 1-in-4 of CLK_40M

// TODO(dlair): Dragon's Lair / Space Ace are ROT0 (horizontal). The video path
// below is inherited from the Kangaroo (ROT90) copy and still rotates. It only
// rotates a BLANK bring-up raster for now, so it is cosmetically irrelevant
// until real LD video is added — revisit orientation (and drop the 512-wide
// doubling / screen_rotate) when that lands.
wire rotate_ccw = 0;
// ROT0-FIX-2026-07-03: was `status[12] | direct_video` (rotated when Vert). DL/SA horizontal-only → never rotate.
wire no_rotate = horz | direct_video;   // = 1
wire flip = status[11] | ~no_rotate;
// SCREEN_ROTATE-REMOVED-2026-07-04: DL/SA are ROT0 (no_rotate=1), so screen_rotate only
// rotated a BLANK raster — and it drives FB_*/DDRAM_*, which our LD-video framebuffer now
// owns (see the STAGE-2 VIDEO block near endmodule).  Removed to resolve the multiple-driver
// conflict on FB_*/DDRAM_*.  video_rotated (its only other output) is tied off at its decl.
// To restore rotation: uncomment this and delete the FB_* assigns + STAGE-2 VIDEO block.
// screen_rotate screen_rotate(.*);

// RASTER PATH (FB-PIVOT-2026-07-04): arcade_video is now driven by fb_raster_reader
// (DDR framebuffer) with the LED band composited over it — replaces the old core LED
// raster + 512-wide doubling.  Everything is on the standard core-video path, so the
// LED band shows AND the MiSTer screenshot captures it.
arcade_video #(320,24) arcade_video
(
	.*,

	.clk_video(CLK_40M),
	.ce_pix(rr_ce_pix),

	.RGB_in({comp_r, comp_g, comp_b}),
	.HBlank(rr_hblank),
	.VBlank(rr_vblank),
	.HSync(rr_hs),
	.VSync(rr_vs),

	.fx(status[17:15])
);

// DIP switches — arrive from the OSD via ioctl index 254 (standard MiSTer DIP
// download). The MRA <switches> writes DSW1 -> byte 0, DSW2 -> byte 1.
// dsw[7:0] = DSW1 (AY port A), dsw[15:8] = DSW2 (AY port B).
reg [7:0] dip_sw[8] = '{8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00};
always @(posedge CLK_10M) begin
	if (ioctl_wr && (ioctl_index == 8'd254) && !ioctl_addr[24:3])
		dip_sw[ioctl_addr[2:0]] <= ioctl_dout;
end
wire [15:0] dsw = {dip_sw[1], dip_sw[0]};

//Instantiate Dragon's Lair top-level game module
DragonsLair dl_inst
(
	.reset(~reset),       // MiSTer reset is active-high; invert for active-low game modules

	.clk_sys(CLK_40M),   // 40 MHz: Z80=/10=4MHz, AY=/20=2MHz, pixel=/8=5MHz (real-hardware speed)

	// P1 (0xC008): {3'b0, action, right, left, down, up} active-high (inverted to active-low bus inside)
	.p1({3'b000, m_action1, m_right1, m_left1, m_down1, m_up1}),
	// SYSTEM (0xC010) cabinet bits: {coin2, coin1, start2, start1} active-high
	.cab({m_coin2, m_coin1, m_start2, m_start1}),
	// dsw[7:0] = DSW1 (AY port A), dsw[15:8] = DSW2 (AY port B)
	.dsw(dsw),

	.video_hsync(hs),
	.video_vsync(vs),
	.video_vblank(vblank),
	.video_hblank(hblank),
	.ce_pix(ce_pix),

	.video_r(r),
	.video_g(g),
	.video_b(b),

	.sound_l(audio_l),
	.sound_r(audio_r),

	.ioctl_addr(ioctl_addr),
	.ioctl_data(ioctl_dout),
	.ioctl_wr(ioctl_wr),
	.ioctl_index(ioctl_index),

	.pause(pause_cpu),

	.led_digits_o(led_digits_flat),
	.dbg_led(dbg_led)
);

// HISCORE REMOVED 2026-07-04 — Dragon's Lair / Space Ace / Thayer's Quest do not
// persist high scores.  The hiscore module was the SOLE driver of ioctl_din and
// ioctl_upload_req, so tie them off to keep hps_io happy.
assign ioctl_din        = 8'd0;
assign ioctl_upload_req = 1'b0;

//============================================================================
// STAGE-2 VIDEO CHECKPOINT (FB-TESTPATTERN-2026-07-04)
//----------------------------------------------------------------------------
// Enable the MISTER_FB framebuffer in HPS DDR3 (via rtl/ram_rom/ddram.sv @
// 0x30000000) and drive it with a test pattern to prove the ddram -> DDR3 FB ->
// ascal scaler path BEFORE the real streamer/decoder are hung on it.
// NOTE: while FB_EN=1 the scaler shows the framebuffer, so the LED-band /
// arcade_video output is NOT displayed during this checkpoint.
// TO REVERT to the LED-band display: set FB_EN back to 1'b0 (the DDR block below
// is then harmless/idle).  All of this runs in the CLK_40M domain (= DDRAM_CLK),
// so there is no hps_io/CDC involved yet.
//============================================================================
// FB-PIVOT-2026-07-04: MISTER_FB DISPLAY DISABLED.  It bypasses the core-video/
// arcade_video path where the LED band AND the screenshot both live, so it dropped
// the score and wasn't captured.  Switching to the RASTER path: the decoder writes
// frames to DDR (ddram/fb_writer below, kept), a raster reader reads them back in
// scan order into arcade_video, LED band composited in.  FB_EN stays 0.
assign FB_EN     = 1'b0;
assign FB_FORMAT = 5'b00100;      // (ignored while FB_EN=0) [2:0]=100 16bpp, [3]=0 565, [4]=0 RGB
assign FB_WIDTH  = 12'd320;
assign FB_HEIGHT = 12'd240;
assign FB_BASE   = 32'h30000000;  // must match ddram.sv region base
assign FB_STRIDE = 14'd640;       // 320 px * 2 B (tight 16bpp)

assign DDRAM_CLK = CLK_40M;

wire [27:1] fb_wraddr;
wire [15:0] fb_din;
wire        fb_we_req, fb_we_ack;
wire        tp_we, tp_ready;
wire [15:0] tp_x, tp_y;
wire  [7:0] tp_r, tp_g, tp_b;

fb_testpattern tp_gen (
    .clk(CLK_40M), .reset(reset),
    .ready(tp_ready), .we(tp_we),
    .x(tp_x), .y(tp_y), .r(tp_r), .g(tp_g), .b(tp_b)
);

fb_writer #(.FB_BASE_HW(27'd0), .STRIDE_HW(16'd320)) fb_wr (
    .clk(CLK_40M), .reset(reset),
    .px_we(tp_we), .px_x(tp_x), .px_y(tp_y),
    .px_r(tp_r), .px_g(tp_g), .px_b(tp_b),
    .px_ready(tp_ready),
    .wraddr(fb_wraddr), .din(fb_din),
    .we_req(fb_we_req), .we_ack(fb_we_ack)
);

ddram ddram_fb (
    .DDRAM_CLK(CLK_40M),
    .DDRAM_BUSY(DDRAM_BUSY),
    .DDRAM_BURSTCNT(DDRAM_BURSTCNT),
    .DDRAM_ADDR(DDRAM_ADDR),
    .DDRAM_DOUT(DDRAM_DOUT),
    .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
    .DDRAM_RD(DDRAM_RD),
    .DDRAM_DIN(DDRAM_DIN),
    .DDRAM_BE(DDRAM_BE),
    .DDRAM_WE(DDRAM_WE),
    // write port (fb_writer)
    .wraddr(fb_wraddr), .din(fb_din), .we_req(fb_we_req), .we_ack(fb_we_ack),
    // rom read/write port — unused
    .rdaddr(27'd0), .dout(), .rom_din(16'd0), .rom_be(2'd0),
    .rom_we(1'b0), .rom_req(1'b0), .rom_ack(),
    // second read port — raster reader (DDR framebuffer -> video)
    .rdaddr2(rr_rdaddr2), .dout2(rr_dout2), .rd_req2(rr_rd_req2), .rd_ack2(rr_rd_ack2)
);

// Read the framebuffer back in scan order, then composite the LED band over it.
fb_raster_reader rr (
    .clk(CLK_40M), .reset(reset),
    .frame_base_hw(27'd0),                  // test frame at DDR halfword base 0
    .rdaddr2(rr_rdaddr2), .dout2(rr_dout2),
    .rd_req2(rr_rd_req2), .rd_ack2(rr_rd_ack2),
    .ce_pix(rr_ce_pix),
    .hsync(rr_hs), .vsync(rr_vs), .hblank(rr_hblank), .vblank(rr_vblank),
    .hpos(rr_hpos), .vpos(rr_vpos),
    .vid_r(rr_r), .vid_g(rr_g), .vid_b(rr_b)
);

led_band led_band_i (
    .hc(rr_hpos), .vc(rr_vpos),
    .led_digits(led_digits_flat),
    .seg_lit(led_lit)
);

endmodule
