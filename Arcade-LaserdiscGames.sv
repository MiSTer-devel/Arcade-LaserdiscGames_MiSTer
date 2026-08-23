//============================================================================
// Dragon's Lair / Space Ace (US set) for MiSTer
// Copyright (C) 2026 Rodimus
// Based on MAME dlair.cpp; converted in place from the Kangaroo core copy
//  Permission is hereby granted, free of charge, to any person obtaining a
//  copy of this software and associated documentation files (the "Software"),
//  to deal in the Software without restriction, including without limitation
//  the rights to use, copy, modify, merge, publish, distribute, sublicense,
//  and/or sell copies of the Software, and to permit persons to whom the
//  Software is furnished to do so, subject to the following conditions:
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
//  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
//  DEALINGS IN THE SOFTWARE.
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
// AY beeps mixed with the .dlv PCM, saturating.  The AY arrives biased by -12288, so gain is
// applied to the SWING and the bias re-applied.
wire [1:0]         beep_vol = status[19:18];
wire signed [17:0] ay_l_w   = {{2{audio_l[15]}}, audio_l};
wire signed [17:0] ay_r_w   = {{2{audio_r[15]}}, audio_r};
wire signed [17:0] ay_l_ac  = ay_l_w + 18'sd12288;          // 0 .. 24480, silence = 0
wire signed [17:0] ay_r_ac  = ay_r_w + 18'sd12288;
wire signed [17:0] ay_l_g   = (beep_vol == 2'd0) ?  ay_l_ac                    - 18'sd12288 :
                              (beep_vol == 2'd1) ? (ay_l_ac + (ay_l_ac >>> 1)) - 18'sd12288 :
                              (beep_vol == 2'd2) ? (ay_l_ac <<< 1)             - 18'sd12288 :
                                                   18'sd0;
wire signed [17:0] ay_r_g   = (beep_vol == 2'd0) ?  ay_r_ac                    - 18'sd12288 :
                              (beep_vol == 2'd1) ? (ay_r_ac + (ay_r_ac >>> 1)) - 18'sd12288 :
                              (beep_vol == 2'd2) ? (ay_r_ac <<< 1)             - 18'sd12288 :
                                                   18'sd0;
wire signed [15:0] ay_l_s   = (ay_l_g >  18'sd32767) ?  16'sd32767 :
                              (ay_l_g < -18'sd32768) ? -16'sd32768 : ay_l_g[15:0];
wire signed [15:0] ay_r_s   = (ay_r_g >  18'sd32767) ?  16'sd32767 :
                              (ay_r_g < -18'sd32768) ? -16'sd32768 : ay_r_g[15:0];
wire signed [16:0] mix_l = ay_l_s + pcm_l;
wire signed [16:0] mix_r = ay_r_s + pcm_r;
wire signed [15:0] sat_l = (mix_l >  17'sd32767) ?  16'sd32767 :
                           (mix_l < -17'sd32768) ? -16'sd32768 : mix_l[15:0];
wire signed [15:0] sat_r = (mix_r >  17'sd32767) ?  16'sd32767 :
                           (mix_r < -17'sd32768) ? -16'sd32768 : mix_r[15:0];
assign AUDIO_L = pause_cpu ? 16'd0 : sat_l;
assign AUDIO_R = pause_cpu ? 16'd0 : sat_r;
assign AUDIO_S = 1;   // signed
assign AUDIO_MIX = 0; // no mix, true stereo

assign LED_DISK  = 0;
assign LED_POWER = 0;
wire dbg_led;
assign LED_USER  = dbg_led;  // ~0.6 Hz "core alive" heartbeat from DragonsLair_CPU
assign BUTTONS = 0;


wire [1:0] ar = status[14:13];
wire band_off = status[20];   // LED bar off -> the video gets the band's rows back (full screen)
wire crt_mode = (status[22:21] == 2'd0);   // default; 15 kHz 240p60 raster instead of the 480p24 film raster
wire flip     = status[11];   // 180 deg rotation for an inverted monitor, not a mirror

wire horz = 1'b1;   // DL/SA are horizontal-only

// "Original" AR is the DISPLAY ratio, not the pixel count: 512x480 is anamorphic, and the LED
// band adds BAND_H rows above the 480 video rows.  ARX:ARY = 4 : 3*(480+BAND_H)/480, so with the
// band off it collapses to a plain 4:3.
assign VIDEO_ARX = horz ? ((!ar) ? 12'd640 : (ar - 1'd1)) : ((!ar) ? 12'd3 : (ar - 1'd1));
assign VIDEO_ARY = horz ? ((!ar) ? (band_off ? 12'd480 : 12'd500) : 12'd0) : ((!ar) ? 12'd4 : 12'd0);

`include "build_id.v"
localparam CONF_STR = {
	// Entry 0 is the OSD title AND the .dlv folder name: both MRAs carry <setname same_dir="1">,
	"LaserdiscGames;;",
	"SC0,DLV,Load Disc;",
	"-;",
	"P1,Video;",
	"P1OLM,Video Timing,CRT 240p60,Film 24Hz;",
	"P1ODE,Aspect Ratio,Original,Full screen,[ARC1],[ARC2];",
	"P1OK,LED Bar,On,Off;",
	"P1OB,Flip Screen,Off,On;",
	"P1OFH,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"P2,Pause Options;",
	"P2OP,Pause when OSD is open,On,Off;",
	"P2OQ,Dim video after 10s,On,Off;",
	"-;",
	"OIJ,Beep Volume,Normal,Loud,Max,Off;",
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

// .dlv block-mount interface (hps_io SD slot 0, VDNUM=1) -> dlv_streamer.
// The .dlv is a mounted block device (CHD-style, read on demand), NOT an ioctl_download blob.
wire        dlv_img_mounted;        // [VD:0]=1 bit, pulses on a new mount
wire [63:0] dlv_img_size;
wire [31:0] dlv_sd_lba[1];          // unpacked array (VDNUM=1)
wire  [5:0] dlv_sd_blk_cnt[1];
wire        dlv_sd_rd;
wire        dlv_sd_wr;
wire        dlv_sd_ack;
wire  [8:0] dlv_sd_buff_addr;
wire  [7:0] dlv_sd_buff_dout;
wire  [7:0] dlv_sd_buff_din[1];
wire        dlv_sd_buff_wr;
assign dlv_sd_wr          = 1'b0;   // read-only image
assign dlv_sd_buff_din[0] = 8'd0;   // never write back

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(CLK_CORE),   // was CLK_10M (Kangaroo leftover); core is single-clock now
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
	.ps2_key(ps2_key),

	// .dlv block-mount (slot 0) -> dlv_streamer (all CLK_CORE, no CDC)
	.img_mounted(dlv_img_mounted),
	.img_readonly(),
	.img_size(dlv_img_size),
	.sd_lba(dlv_sd_lba),
	.sd_blk_cnt(dlv_sd_blk_cnt),
	.sd_rd(dlv_sd_rd),
	.sd_wr(dlv_sd_wr),
	.sd_ack(dlv_sd_ack),
	.sd_buff_addr(dlv_sd_buff_addr),
	.sd_buff_dout(dlv_sd_buff_dout),
	.sd_buff_din(dlv_sd_buff_din),
	.sd_buff_wr(dlv_sd_buff_wr)
);

////////////////////   CLOCKS   ///////////////////

// Core clock is 80 MHz.  Every clock-coupled constant DERIVES from CORE_CLK_HZ -- never
// re-hardcode a frequency: a too-wide literal in a narrow register truncates silently and lints
// clean.  100 MHz was rejected because it forces 45% vertical blanking and destabilises the scaler.
localparam [31:0] CORE_CLK_HZ = 32'd80_000_000;   // single source of truth for the core clock

// Deliberately frequency-agnostic: CORE_CLK_HZ is the one place the number appears.
wire CLK_CORE;                  // the core clock: CORE_CLK_HZ (80 MHz), = DDRAM_CLK = CLK_VIDEO
wire CLK_10M;                   // PLL outclk_1, genuinely 10 MHz, UNUSED by the core (Kangaroo leftover)
wire locked;

pll pll
(
    .refclk(CLK_50M),
    .rst(0),
    .outclk_0(CLK_CORE),
    .outclk_1(CLK_10M),
    .locked(locked)
);

assign CLK_VIDEO = CLK_CORE;   // scaler reference clock (paired with ce_pix from CE_DIV_LOG2)

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
always @(posedge CLK_CORE) begin
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
// Space Ace's skill-level daughter board on port $C008, active-low via p1_bus = ~p1.
// MRA button order (Fire,Cadet,Captain,SpaceAce) = joystick_0[4..7].  DL never reads these bits.
wire m_skill1   = joystick_0[5];   // Cadet      -> p1[5]
wire m_skill2   = joystick_0[6];   // Captain    -> p1[6]
wire m_skill3   = joystick_0[7];   // Space Ace  -> p1[7]

//Start/Coin
wire m_start1   = btn_1p_start  | joystick_0[9];
wire m_start2   = btn_2p_start  | joystick_0[10];
wire m_coin1    = btn_coin1     | joystick_0[8];
wire m_coin2    = btn_coin2     | joystick_1[8];
wire m_pause    = btn_pause     | joystick_0[11];

// PAUSE SYSTEM
wire pause_cpu;
wire [23:0] rgb_out;
// NOTE: rgb_out is not consumed by arcade_video (RGB_in comes from comp_r/g/b directly), so
// the dim-after-10s-paused feature is inert.  Known gap, left as-is deliberately.
pause #(8,8,8,CORE_CLK_HZ/32'd1_000_000) pause
(
	.*,
	.clk_sys(CLK_CORE),   // was CLK_10M
	.user_button(m_pause),
	.pause_request(1'b0),   // hiscore removed
	.options(~status[26:25]),
	.r(comp_r), .g(comp_g), .b(comp_b)
);

///////////////                 Video                  ////////////////

// ---- Raster video path (DDR framebuffer -> arcade_video) ----
wire [63:0] led_digits_flat;
wire        rr_ce_pix, rr_hs, rr_vs, rr_hblank, rr_vblank;
wire [15:0] rr_hpos, rr_vpos;
wire  [7:0] rr_r, rr_g, rr_b;
wire        led_lit;
// The LED band and the video are SEPARATE, never overlaid: rows 0..BAND_H-1 are the band, rows
// BAND_H.. are the full pixel-exact video.
localparam [15:0] BAND_H = 16'd20;             // reserved top strip height in rows (glyphs at rows 2..8)
// The band's rows stay reserved in the reader's V_TOTAL either way, so switching it off gives them
// to the video without changing the frame time.
wire [15:0] band_h_w = band_off ? 16'd0 : (crt_mode ? (BAND_H >> 1) : BAND_H);
wire        band_lit = led_lit & ~band_off;
wire  [7:0] comp_r = band_lit ? 8'hFF : rr_r;  // red band text in the strip, video below
wire  [7:0] comp_g = band_lit ? 8'h00 : rr_g;
wire  [7:0] comp_b = band_lit ? 8'h00 : rr_b;
wire [26:0] rr_rdaddr2;
wire [15:0] rr_dout2;
wire [63:0] rr_dout2_64;    // whole cached word from ddram read port 2
wire        rr_rd_req2, rr_rd_ack2;
// fb_raster_reader tells fb_writer when its line fetch has landed, so the writer never contends
// with an in-flight read2.  Declared here because fb_writer is instantiated ABOVE the reader.
wire        rr_fill_idle;


// Driven by fb_raster_reader with the LED band composited over it.  The first parameter is
// arcade_video's WIDTH and MUST be >= H_ACT or video_mixer's line buffers wrap mid-line.
arcade_video #(512,24) arcade_video
(
	.*,

    // Left unconnected on purpose: arcade_video declares `output CLK_VIDEO`, and the `.*` above
    // would make it a second driver of emu's CLK_VIDEO net (Quartus Error 12014).  The conflicting
    // connection is made by `.*`, so it is invisible to grep.
	.CLK_VIDEO(),

	.clk_video(CLK_CORE),
	.ce_pix(rr_ce_pix),

	.RGB_in({comp_r, comp_g, comp_b}),
	.HBlank(rr_hblank),
	.VBlank(rr_vblank),
	.HSync(rr_hs),
	.VSync(rr_vs),

	.forced_scandoubler(forced_scandoubler & ~crt_mode),
	.fx(crt_mode ? 3'd0 : status[17:15])
);

// DIP switches arrive from the OSD via ioctl index 254.  dsw[7:0] = DSW1 (AY port A),
// dsw[15:8] = DSW2 (AY port B).
reg [7:0] dip_sw[8] = '{8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00,8'h00};
always @(posedge CLK_CORE) begin
	if (ioctl_wr && (ioctl_index == 8'd254) && !ioctl_addr[24:3])
		dip_sw[ioctl_addr[2:0]] <= ioctl_dout;
end
wire [15:0] dsw = {dip_sw[1], dip_sw[0]};

// MRA <rom index="1"> mod byte: absent (Dragon's Lair) => 0, Space Ace's MRA writes 01.
// This is the ONLY thing that enables the skill field on the LED band.
reg [7:0] game_mod = 8'd0;
always @(posedge CLK_CORE) begin
    if (ioctl_wr && (ioctl_index == 8'd1)) game_mod <= ioctl_dout;
end
wire is_spaceace = (game_mod == 8'd1);
wire [1:0] skill_level;   // from DragonsLair_CPU's scoreboard snoop
wire [16:0] ld_curr_frame_top;   // LD disc frame from DragonsLair -> dlv_streamer

// ---- Seek hold ----
// A real LD player stalls visibly while the head moves and the games were built around it, so hold
// both streams on a seek, refill, then release together.  Release needs SEEK_PRIME post-seek frames
// decoded AND the audio ring primed.
wire       fb_seek_pulse;      // = the Z80's CMD_SEARCH, straight from the LDV1000
// 1-cycle pulse when playback STOPS (any mechanism).  Mirrors fb_seek_edge, for the END of a
// segment instead of the start.
wire       fb_play_end;
reg        fb_seek_q;          // edge-detect the arm. Belt-and-braces --
wire       fb_seek_edge = fb_seek_pulse & ~fb_seek_q;   // if the source ever stuck HIGH, a
                               // LEVEL-triggered arm would re-arm every cycle and the hold could
                               // never release (FSM-model-proven). An EDGE can only arm once.
wire       fb_aud_primed;      // from dlv_streamer (ring >= SEEK_FILL)
reg        fb_seek_hold;       // driven in the framebuffer block below

wire        ld_playing_top;      // LD mode==PLAY from DragonsLair -> dlv_streamer

//Instantiate Dragon's Lair top-level game module
DragonsLair #(.CLK_HZ(CORE_CLK_HZ)) dl_inst
(
	.reset(~reset),       // MiSTer reset is active-high; invert for active-low game modules

	.clk_sys(CLK_CORE),   // 80 MHz: Z80=/20=4MHz, AY=/40=2MHz (real-hardware speeds, dividers derived)

	// P1 (0xC008): {3'b0, action, right, left, down, up} active-high (inverted to active-low bus inside)
	.p1({m_skill3, m_skill2, m_skill1, m_action1, m_right1, m_left1, m_down1, m_up1}),
	// SYSTEM (0xC010) cabinet bits: {coin2, coin1, start2, start1} active-high
	.cab({m_coin2, m_coin1, m_start2, m_start1}),
	// dsw[7:0] = DSW1 (AY port A), dsw[15:8] = DSW2 (AY port B)
	.dsw(dsw),

	.sound_l(audio_l),
	.sound_r(audio_r),

	.ioctl_addr(ioctl_addr),
	.ioctl_data(ioctl_dout),
	.ioctl_wr(ioctl_wr),
	.ioctl_index(ioctl_index),

	.pause(pause_cpu),
// The seek hold freezes the DISC as well as the picture, so the game cannot execute frames it
// has not shown yet.  fb_seek_hold is already in the CLK_CORE domain, so no CDC is needed.
	.disc_hold(fb_seek_hold),

	.led_digits_o(led_digits_flat),
	.skill_o(skill_level),
	.dbg_led(dbg_led),
	.ld_frame_o(ld_curr_frame_top), .ld_search_cmd_o(fb_seek_pulse),   // HLE-DRIVE /
	.ld_play_end_o(fb_play_end),
	.ld_playing_o(ld_playing_top)
);

// Dragon's Lair / Space Ace / Thayer's Quest do not persist high scores, so there is no hiscore
// module.  It was the sole driver of ioctl_din and ioctl_upload_req -- tied off to keep hps_io happy.
assign ioctl_din        = 8'd0;
assign ioctl_upload_req = 1'b0;

// The MISTER_FB path is NOT used (FB_EN=0): it bypasses the arcade_video path where the LED band
// and the MiSTer screenshot live.
assign FB_EN     = 1'b0;
assign FB_FORMAT = 5'b00100;      // (ignored while FB_EN=0) [2:0]=100 16bpp, [3]=0 565, [4]=0 RGB
assign FB_WIDTH  = 12'd320;
assign FB_HEIGHT = 12'd240;
assign FB_BASE   = 32'h30000000;  // must match ddram.sv region base
assign FB_STRIDE = 14'd640;       // 320 px * 2 B (tight 16bpp)

assign DDRAM_CLK = CLK_CORE;

wire [27:1] fb_wraddr;
wire [15:0] fb_din;
wire        fb_we_req, fb_we_ack;
wire [63:0] fb_din64;
wire  [7:0] fb_be64;
wire        tp_we, tp_ready;
wire [15:0] tp_x, tp_y;
wire  [7:0] tp_r, tp_g, tp_b;

// .dlv -> block streamer -> JPEG decoder -> fb_writer.

// ---- .dlv block streamer (hps_io slot 0) — all CLK_CORE, single-clock, no CDC ----
wire  [7:0] strm_byte;
wire        strm_valid, strm_ready, strm_last;
wire        dec_reset_w;                // per-frame decoder reset (decoder only)
wire signed [15:0] pcm_l, pcm_r;        // .dlv PCM -> audio mux (see AUDIO_L/R above)

// Continuous video+audio streamer: free-runs film frames from START_FRAME and keeps a 44.1 kHz
// PCM ring topped up (audio has SD priority).
dlv_streamer #(.START_FRAME(17'd1000), .CLK_HZ(CORE_CLK_HZ)) dlv_strm (
    .clk(CLK_CORE), .reset(reset),
    .img_mounted(dlv_img_mounted), .img_size(dlv_img_size),
    .sd_lba(dlv_sd_lba[0]), .sd_blk_cnt(dlv_sd_blk_cnt[0]),
    .sd_rd(dlv_sd_rd), .sd_ack(dlv_sd_ack),
    .sd_buff_addr(dlv_sd_buff_addr), .sd_buff_dout(dlv_sd_buff_dout), .sd_buff_wr(dlv_sd_buff_wr),
    .out_byte(strm_byte), .out_valid(strm_valid), .out_ready(strm_ready), .out_last(strm_last),
    .dec_reset(dec_reset_w),
    .pcm_l(pcm_l), .pcm_r(pcm_r),
    .ld_curr_frame(ld_curr_frame_top), .pause(pause_cpu),
    .aud_primed(fb_aud_primed), .hold_play(fb_seek_hold), .seek_flush(fb_seek_pulse),   // SEEK-HOLD/
    .ld_playing(ld_playing_top)
);

// ---- JPEG frame decoder: byte stream -> px writes (block-order, addressed by x,y) ----
wire        dec_px_we, dec_px_ready;
wire [15:0] dec_px_x, dec_px_y, dec_w, dec_h;
wire  [7:0] dec_px_r, dec_px_g, dec_px_b;
wire        dec_frame_done, dec_idle;

jpeg_frame_decoder dec (
    .clk(CLK_CORE), .rst(dec_reset_w),   // per-frame reset, NOT global; fb_writer stays on global reset
    .in_byte(strm_byte), .in_valid(strm_valid), .in_ready(strm_ready), .in_last(strm_last),
    .px_ready(dec_px_ready), .px_we(dec_px_we),
    .px_x(dec_px_x), .px_y(dec_px_y), .px_r(dec_px_r), .px_g(dec_px_g), .px_b(dec_px_b),
    .frame_width(dec_w), .frame_height(dec_h), .frame_done(dec_frame_done), .idle(dec_idle)
);

// Three framebuffers with a ready/display handoff.  Invariant: wr_idx != disp_idx ALWAYS, so the
// writer can never target the displayed buffer -- two buffers cannot hold that, because the reader
// latches its base for a whole raster frame.

// ---- Framebuffer geometry, defined ONCE and passed everywhere ----
// 512x480 matches the Daphne source m2v exactly, so encoding is a pure re-compress, and 512 is
// fb_raster_reader's line-buffer ceiling.
localparam [15:0] FB_COLS_HW   = 16'd512;
localparam [15:0] FB_ROWS_HW   = 16'd480;
localparam [26:0] FB_BUF_HW    = 27'd245760;  // 512*480 halfwords per buffer (was 76800)
localparam [26:0] FB_BUF0_HW   = 27'd0;
localparam [26:0] FB_BUF1_HW   = FB_BUF_HW;
localparam [26:0] FB_BUF2_HW   = FB_BUF_HW * 2;

reg  [1:0] fb_wr_idx;      // buffer the decoder is writing
reg  [1:0] fb_disp_idx;    // buffer the raster reader is displaying
reg  [1:0] fb_ready_idx;   // most recently COMPLETED frame, waiting to be displayed
reg        fb_have_new;    // a completed frame is waiting for the next vblank

// ---- Seek-hold state ----
// TRIPLE_BUF=0 points the write and display bases at the same buffer.
localparam        TRIPLE_BUF = 1'b1;          // DIAG: 1'b0 = single buffer, 1'b1 = original
// SEEK_PRIME is 1: the hold freezes the disc, so vid_target is constant and the dedup gate
// fetches exactly ONE frame.  A larger value can never be reached.
localparam [2:0]  SEEK_PRIME = 3'd1;   // post-seek frames to bank before resuming
// SEEK_TMO/fb_seek_tmr must be wide enough for the core clock, or the compare never trips and
// the hold never releases -- blank screen, muted audio.
localparam [27:0] SEEK_TMO   = CORE_CLK_HZ;   // ~1 s at the core clock -- SAFETY, see below
reg  [2:0]  fb_prime_cnt;
reg  [27:0] fb_seek_tmr;
reg         fb_wr_stale;   // frame decoding when the seek hit -> finish it, but never publish it
// Window in which the display may still adopt PRE-seek frames, counted in vblanks so it is
// hard-bounded and can never extend the hold.
reg  [1:0]  fb_tail_adopt;
// The safety timeout is not optional.  It is NOT re-zeroed by a further seek while already
// holding, so a burst of seeks cannot keep the hold alive indefinitely.
wire fb_seek_release = (fb_prime_cnt >= SEEK_PRIME && fb_aud_primed) || (fb_seek_tmr >= SEEK_TMO);

reg        rr_vblank_q;
wire       fb_vbl_rise = rr_vblank & ~rr_vblank_q;
// Rising edge of the per-frame decoder reset (reset | frame_fetch | wd_rst).
reg        dec_reset_q;
wire       dec_reset_rise = dec_reset_w & ~dec_reset_q;

// The free-buffer choice must use the buffer displayed AFTER this cycle: adoption and completion
// can land together, and the stale fb_disp_idx is exactly what vblank is about to display.
wire       fb_adopt    = fb_vbl_rise & fb_have_new & (~fb_seek_hold | (fb_tail_adopt != 2'd0));
wire [1:0] fb_next_disp = fb_adopt ? fb_ready_idx : fb_disp_idx;
// the one index that is neither a nor b (0+1+2=3; valid because the invariant keeps them distinct)
wire [1:0] fb_free_idx  = 2'd3 - fb_wr_idx - fb_next_disp;

always @(posedge CLK_CORE) begin
    rr_vblank_q <= rr_vblank;
    dec_reset_q <= dec_reset_w;
    if (reset) begin
        fb_wr_idx    <= 2'd0;
        fb_disp_idx  <= 2'd1;
        fb_ready_idx <= 2'd1;
        fb_have_new  <= 1'b0;
        rr_vblank_q  <= 1'b0;
        dec_reset_q  <= 1'b0;
        fb_seek_q    <= 1'b0;
        fb_seek_hold <= 1'b0;
        fb_prime_cnt <= 3'd0;
        fb_seek_tmr  <= 28'd0;   // 28 bits: 80 MHz needs 27
        fb_wr_stale  <= 1'b0;
        fb_tail_adopt<= 2'd0;
    end else begin
        fb_seek_q <= fb_seek_pulse;
        // The tail window burns down on VBLANKS, not adoptions, so a frame still decoding gets its
        // chance and one that never arrives cannot hold the window open.
        if (fb_vbl_rise && (fb_tail_adopt != 2'd0)) fb_tail_adopt <= fb_tail_adopt - 2'd1;
        // start of vblank: adopt the newest completed frame, if any
        if (fb_adopt) begin
            fb_disp_idx   <= fb_ready_idx;
            fb_have_new   <= 1'b0;
        end
        // Ordered AFTER the adopt block so fb_have_new wins on a simultaneous cycle.
        if (dec_frame_done) begin
            fb_ready_idx <= fb_wr_idx;
            fb_wr_idx    <= fb_free_idx;   // != fb_next_disp by construction
            // Publish the in-flight frame too: its fetch only started because vid_target reached it.
            fb_have_new  <= 1'b1;
            fb_wr_stale  <= 1'b0;
            // bank post-seek frames (a stale one does not count toward priming)
            if (fb_seek_hold && !fb_wr_stale && fb_prime_cnt < SEEK_PRIME) begin
                fb_prime_cnt <= fb_prime_cnt + 3'd1;
                // First post-seek frame: close the time-gated tail window so the hold holds.
                fb_tail_adopt <= 2'd0;
            end
        end
        // SEEK-HOLD: run the safety timer and release once primed (or on timeout)
        if (fb_seek_hold) begin
            if (fb_seek_tmr < SEEK_TMO) fb_seek_tmr <= fb_seek_tmr + 28'd1;
            if (fb_seek_release)        fb_seek_hold <= 1'b0;
        end
        // Drop an orphaned stale tag: the post-seek fetch can kill the tagged decode before it
        // completes, which would otherwise block priming until the 1.0 s timeout.
        if (fb_seek_hold && fb_wr_stale && dec_reset_rise && !dec_frame_done)
            fb_wr_stale <= 1'b0;
        if (fb_seek_edge) begin
            // Keep the queued frame: it finished decoding and was waiting for a vblank, so it is
            // real content of the segment that just ended.
            fb_tail_adopt <= 2'd2;
            fb_wr_stale  <= ~dec_idle | dec_reset_w;   // tag anything IN FLIGHT: fetching or decoding
            fb_seek_hold <= 1'b1;
            fb_prime_cnt <= 3'd0;
            if (!fb_seek_hold) fb_seek_tmr <= 28'd0;
        end
    end
end

wire [26:0] fb_wr_base = !TRIPLE_BUF          ? FB_BUF0_HW :
                         (fb_wr_idx   == 2'd0) ? FB_BUF0_HW :
                         (fb_wr_idx   == 2'd1) ? FB_BUF1_HW : FB_BUF2_HW;
wire [26:0] fb_rd_base = !TRIPLE_BUF          ? FB_BUF0_HW :
                         (fb_disp_idx == 2'd0) ? FB_BUF0_HW :
                         (fb_disp_idx == 2'd1) ? FB_BUF1_HW : FB_BUF2_HW;

// Geometry passed explicitly -- CLEAR_ROWS especially, or only part of each buffer is cleared.
fb_writer #(
    .STRIDE_HW (FB_COLS_HW),
    .FB_COLS   (FB_COLS_HW),
    .FB_ROWS   (FB_ROWS_HW),
    .CLEAR_ROWS(FB_ROWS_HW)
) fb_wr (
    .clk(CLK_CORE), .reset(reset),
    .px_we(dec_px_we), .px_x(dec_px_x), .px_y(dec_px_y),
    .px_r(dec_px_r), .px_g(dec_px_g), .px_b(dec_px_b),
    .px_ready(dec_px_ready),
    .fill_idle(rr_fill_idle),       // yield DDR while the raster reader fetches (delete on revert)
    .base_hw(fb_wr_base),
    .wraddr(fb_wraddr), .din(fb_din),
    .din64(fb_din64), .be64(fb_be64),
    .we_req(fb_we_req), .we_ack(fb_we_ack)
);

ddram ddram_fb (
    .DDRAM_CLK(CLK_CORE),
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
    .wraddr(fb_wraddr), .din(fb_din),
    .din64(fb_din64), .be64(fb_be64),
    .we_req(fb_we_req), .we_ack(fb_we_ack),
    // rom read/write port — unused
    .rdaddr(27'd0), .dout(), .rom_din(16'd0), .rom_be(2'd0),
    .rom_we(1'b0), .rom_req(1'b0), .rom_ack(),
    // second read port — raster reader (DDR framebuffer -> video)
    .rdaddr2(rr_rdaddr2), .dout2(rr_dout2), .dout2_64(rr_dout2_64),
    .rd_req2(rr_rd_req2), .rd_ack2(rr_rd_ack2)
);

// Read the framebuffer back in scan order, then composite the LED band over it.
fb_raster_reader #(
    .H_ACT      (FB_COLS_HW),
    .V_ACT      (FB_ROWS_HW),
    .STRIDE     (FB_COLS_HW),
    .V_BAND     (BAND_H),
    // CE_DIV_LOG2 is the bandwidth dial: too fast and the reader cannot fetch a whole line in one
    // line-time (bottom of the picture cuts off); too slow drops below the content frame rate.
    .CE_DIV_LOG2(3'd3),

    // ---- video timing ----
    // ONE display refresh per film frame: any other ratio alternates one and two refreshes and the
    // picture visibly lurches.  V_BP is the knob, and the display must stay just FASTER than the
    // film tick -- slower silently DROPS a frame per beat, faster only repeats one.
    .V_BP       (16'd212)
) rr (
    .clk(CLK_CORE), .reset(reset),
    .frame_base_hw(fb_rd_base),             // was hardcoded 27'd0, see fb_buf_sel above
    .v_band(band_h_w),                      // 0 = LED bar off, video takes the band's rows
    .crt(crt_mode),
    .flip(flip),
    .rdaddr2(rr_rdaddr2), .dout2(rr_dout2), .dout2_64(rr_dout2_64),
    .rd_req2(rr_rd_req2), .rd_ack2(rr_rd_ack2),
    .fill_idle(rr_fill_idle),               // (delete on revert)
    .ce_pix(rr_ce_pix),
    .hsync(rr_hs), .vsync(rr_vs), .hblank(rr_hblank), .vblank(rr_vblank),
    .hpos(rr_hpos), .vpos(rr_vpos),
    .vid_r(rr_r), .vid_g(rr_g), .vid_b(rr_b)
);

// X_START centres the 33-slot band; X_START_SKILL centres Space Ace's 39-slot version.
led_band #(.X_START(16'd58), .SCALE_LOG2(2'd1), .X_START_SKILL(16'd22)) led_band_i (
    .hc(rr_hpos), .vc(rr_vpos), .crt_240p(crt_mode),
    .led_digits(led_digits_flat),   // real score/lives, restored
    .skill_en(is_spaceace),         // MRA mod byte, SA only
    .skill(skill_level),
    .seg_lit(led_lit)
);

endmodule
