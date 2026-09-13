//============================================================================
// mach3_video.sv — Gottlieb/Mylstar rev-2 tile + sprite renderer.
//
// Shared by M.A.C.H. 3, Cobra Command and Us vs Them: MAME's cobram3 machine
// config differs from g2laser only in sound-board mods, so the video hardware
// is identical across all three.
//
//  BACKGROUND  32x32 map of 8x8 4bpp tiles from the 8K bgtile ROM, packed MSB
//              (two pixels per byte, left pixel in the high nibble).  Codes
//              come straight from video RAM; init_romtiles points both the low
//              and high code ranges at the ROM, so char RAM is unused here.
//  SPRITES     64 entries of 4 bytes, 16x16 4bpp, pen 0 transparent.
//              y = ram[0]-13, x = ram[1]-4, code = (255 ^ ram[2]) + 256*bank.
//              The four bitplanes live in quarters of a 64K region, MSB plane
//              first.  Mach 3 only fills 32K of that, so the MRA pads its
//              planes up to the 16K stride and the RTL stays one shape.
//  PRIORITY    $5803 b0: 0 = tiles behind sprites, 1 = tiles in front with
//              pen 0 transparent.
//  PALETTE     16 entries x 2 bytes, WRITE-ONLY to the CPU.  Even byte holds
//              green in 7:4 and blue in 3:0, odd byte holds red in 3:0.  The
//              four bits drive a 2000/1000/470/240 ohm ladder into a 180 ohm
//              pulldown, so the level is WEIGHTED, not a linear 4-bit ramp.
//              Values below are that ladder normalised to full scale; they come
//              from MAME's documented resistances (gottlieb.cpp video_start) —
//              sweep these first if colours look wrong on hardware, since the
//              Logic Board A1 sheet was not available to confirm them.
//
// The board renders on demand into the shared overlay bus rather than owning a
// raster: the top level presents ovl_hpos/ovl_vpos and pulses ovl_ce_pix, and
// the reads below settle in the idle clocks between pulses.
//============================================================================
module mach3_video
(
    input                core_clk,
    input                reset_n,

    // ---- ROM download, ioctl index 0 ----
    input         [24:0] ioctl_addr,
    input          [7:0] ioctl_data,
    input                ioctl_wr,
    input          [7:0] ioctl_index,

    // ---- control, from $5803 ----
    input                bg_priority,
    input                spritebank,
    input                video_en,
    input                genlock,        // pen 0 transparent, disc shows through

    // ---- palette writes ----
    input                pal_we,
    input          [4:0] pal_wa,
    input          [7:0] pal_wd,

    // ---- board RAM read ports ----
    output        [11:0] vram_rd_a,
    input          [7:0] vram_rd_d,
    output         [7:0] spram_rd_a,
    input          [7:0] spram_rd_d,

    // ---- overlay bus ----
    input         [15:0] ovl_hpos,
    input         [15:0] ovl_vpos,
    input                ovl_ce_pix,
    output reg    [23:0] ovl_rgb,
    output reg           ovl_opaque
);
    //--------------------------------------------------- ROMs ----------------
    // bgtiles 8K; sprites 64K as four 16K planes.
    wire rom_ld = (ioctl_index == 8'd0) & ioctl_wr;
    wire ld_bg  = rom_ld & (ioctl_addr >= 25'h0C000) & (ioctl_addr < 25'h0E000);
    wire ld_spr = rom_ld & (ioctl_addr >= 25'h0E000) & (ioctl_addr < 25'h1E000);

    wire [12:0] bg_ld_a  = ioctl_addr[12:0];              // 0C000 is 0x2000-aligned
    wire [16:0] spr_off  = ioctl_addr[16:0] - 17'h0E000;
    wire [15:0] spr_ld_a = spr_off[15:0];

    wire [12:0] bg_a;
    wire [15:0] spr_a;
    wire  [7:0] bg_q, spr_q;

    dpram_dc #(.widthad_a(13)) u_bgrom (
        .clock_a(core_clk), .address_a(bg_a), .q_a(bg_q),
        .wren_a(1'b0), .data_a(8'd0),
        .clock_b(core_clk), .address_b(bg_ld_a), .data_b(ioctl_data),
        .wren_b(ld_bg), .q_b()
    );
    dpram_dc #(.widthad_a(16)) u_sprrom (
        .clock_a(core_clk), .address_a(spr_a), .q_a(spr_q),
        .wren_a(1'b0), .data_a(8'd0),
        .clock_b(core_clk), .address_b(spr_ld_a), .data_b(ioctl_data),
        .wren_b(ld_spr), .q_b()
    );

    //--------------------------------------------------- palette -------------
    reg [7:0] pal [0:31];
    always @(posedge core_clk) if (pal_we) pal[pal_wa] <= pal_wd;

    // 4-bit ladder -> 8-bit level.  Weights 16.36 / 32.72 / 69.61 / 136.31.
    function [7:0] dac(input [3:0] v);
        case (v)
            4'h0: dac = 8'd0;   4'h1: dac = 8'd16;  4'h2: dac = 8'd33;  4'h3: dac = 8'd49;
            4'h4: dac = 8'd70;  4'h5: dac = 8'd86;  4'h6: dac = 8'd102; 4'h7: dac = 8'd119;
            4'h8: dac = 8'd136; 4'h9: dac = 8'd153; 4'hA: dac = 8'd169; 4'hB: dac = 8'd185;
            4'hC: dac = 8'd206; 4'hD: dac = 8'd222; 4'hE: dac = 8'd239; default: dac = 8'd255;
        endcase
    endfunction

    //--------------------------------------------------- raster mapping ------
    // The overlay bus is 320 wide; this picture is 256.  Vertical is 1:1.
    wire [23:0] sx_mul = ovl_hpos * 16'd205;      // 320 -> 256
    wire  [7:0] sx     = sx_mul[15:8];
    wire  [7:0] sy     = ovl_vpos[7:0];
    wire        in_win = (ovl_vpos < 16'd240);

    //--------------------------------------------------- background ----------
    // Addresses are driven straight from the overlay position; both reads settle
    // in the idle clocks before ovl_ce_pix, so nothing is sampled mid-fetch.
    assign vram_rd_a = {2'b00, sy[7:3], sx[7:3]};
    assign bg_a      = {vram_rd_d, sy[2:0], sx[2:1]};
    wire [3:0] bg_pen = sx[0] ? bg_q[3:0] : bg_q[7:4];

    //--------------------------------------------------- sprite line buffer --
    // Built one line ahead into the inactive bank; 64 sprites x 16 pixels plus
    // the clear pass fits comfortably in a line at 8 core clocks per pixel.
    reg        bank;
    reg  [7:0] line_q;
    wire       line_new = (sy != line_q);

    reg  [3:0] st;
    localparam S_IDLE=4'd0, S_CLR=4'd1, S_R0=4'd2, S_R1=4'd3, S_R2=4'd4,
               S_CHK=4'd5, S_ROM=4'd6, S_EMIT=4'd7, S_NEXT=4'd8;

    reg  [7:0] clr_i;
    reg  [5:0] spr_i;
    reg signed [9:0] s_y;
    reg        [9:0] s_x;
    reg  [8:0] s_code;
    reg  [3:0] s_row;
    reg  [3:0] rom_i;
    reg [15:0] pl0, pl1, pl2, pl3;
    reg  [4:0] emit_i;
    reg        lb_we;
    reg  [8:0] lb_wa;
    reg  [3:0] lb_wd;
    reg  [1:0] wait_c;

    // Sprite RAM: 4 bytes per entry.
    reg [1:0] spram_sel;
    assign spram_rd_a = {spr_i, spram_sel};

    // Sprite ROM: plane in the top two bits, then code*32 + row*2 + byte.
    assign spr_a = {rom_i[2:1], s_code, s_row, rom_i[0]};

    wire signed [9:0] row_s = $signed({2'b00, line_q}) - s_y;
    wire [3:0] ei       = 4'd15 - emit_i[3:0];    // pixel 0 is the MSB of the plane word
    wire [3:0] emit_pen = {pl0[ei], pl1[ei], pl2[ei], pl3[ei]};
    wire [9:0] emit_x   = s_x + {6'd0, emit_i[3:0]};

    always @(posedge core_clk) begin
        lb_we <= 1'b0;
        if (!reset_n) begin
            st <= S_IDLE; bank <= 1'b0; line_q <= 8'hFF;
            clr_i <= 8'd0; spr_i <= 6'd0; spram_sel <= 2'd0; wait_c <= 2'd0;
        end else begin
            case (st)
                S_IDLE: if (line_new) begin
                    line_q <= sy; bank <= ~bank; clr_i <= 8'd0; st <= S_CLR;
                end
                S_CLR: begin
                    lb_we <= 1'b1; lb_wa <= {~bank, clr_i}; lb_wd <= 4'd0;
                    if (clr_i == 8'hFF) begin spr_i <= 6'd0; spram_sel <= 2'd0; wait_c <= 2'd0; st <= S_R0; end
                    else clr_i <= clr_i + 8'd1;
                end
                // dpram_dc registers its output, so each read costs a wait cycle.
                S_R0: if (wait_c != 2'd1) wait_c <= wait_c + 2'd1;
                      else begin s_y <= $signed({2'b00, spram_rd_d}) - 10'sd13; spram_sel <= 2'd1; wait_c <= 2'd0; st <= S_R1; end
                S_R1: if (wait_c != 2'd1) wait_c <= wait_c + 2'd1;
                      else begin s_x <= {2'b00, spram_rd_d} - 10'd4;  spram_sel <= 2'd2; wait_c <= 2'd0; st <= S_R2; end
                S_R2: if (wait_c != 2'd1) wait_c <= wait_c + 2'd1;
                      else begin s_code <= {spritebank, ~spram_rd_d}; wait_c <= 2'd0; st <= S_CHK; end
                S_CHK: begin
                    // Does this sprite cover the line being built?
                    if ((row_s >= 10'sd0) && (row_s < 10'sd16)) begin
                        s_row <= row_s[3:0]; rom_i <= 4'd0; wait_c <= 2'd0; st <= S_ROM;
                    end else st <= S_NEXT;
                end
                S_ROM: if (wait_c != 2'd1) wait_c <= wait_c + 2'd1;
                       else begin
                           wait_c <= 2'd0;
                           case (rom_i[2:0])
                               3'd0: pl0[15:8] <= spr_q;  3'd1: pl0[7:0] <= spr_q;
                               3'd2: pl1[15:8] <= spr_q;  3'd3: pl1[7:0] <= spr_q;
                               3'd4: pl2[15:8] <= spr_q;  3'd5: pl2[7:0] <= spr_q;
                               3'd6: pl3[15:8] <= spr_q;  default: pl3[7:0] <= spr_q;
                           endcase
                           if (rom_i == 4'd7) begin emit_i <= 5'd0; st <= S_EMIT; end
                           else rom_i <= rom_i + 4'd1;
                       end
                S_EMIT: begin
                    // Pen 0 is transparent, and the hardware clips the left 8 pixels.
                    if ((emit_pen != 4'd0) && (emit_x < 10'd256) && (emit_x >= 10'd8)) begin
                        lb_we <= 1'b1; lb_wa <= {~bank, emit_x[7:0]}; lb_wd <= emit_pen;
                    end
                    if (emit_i == 5'd15) st <= S_NEXT;
                    else emit_i <= emit_i + 5'd1;
                end
                S_NEXT: begin
                    if (spr_i == 6'd63) st <= S_IDLE;
                    else begin spr_i <= spr_i + 6'd1; spram_sel <= 2'd0; wait_c <= 2'd0; st <= S_R0; end
                end
                default: st <= S_IDLE;
            endcase
        end
    end

    // 8 bits wide, not 4: dpram_dc sizes byteena as width_a/8, which is a null
    // range at 4.  512x8 is still one M10K, so the spare nibble costs nothing.
    wire [7:0] lb_q;
    wire [8:0] lb_ra = {bank, sx};
    wire [3:0] spr_pen = lb_q[3:0];
    dpram_dc #(.width_a(8), .widthad_a(9)) u_linebuf (
        .clock_a(core_clk), .address_a(lb_wa), .data_a({4'd0, lb_wd}),
        .wren_a(lb_we), .q_a(),
        .clock_b(core_clk), .address_b(lb_ra), .data_b(8'd0), .wren_b(1'b0), .q_b(lb_q)
    );

    //--------------------------------------------------- compose -------------
    // bg_priority 0: tiles are the opaque floor and sprites land on top.
    // bg_priority 1: tiles sit in front, transparent on pen 0.
    wire [3:0] pen = bg_priority ? (bg_pen  != 4'd0 ? bg_pen  : spr_pen)
                                 : (spr_pen != 4'd0 ? spr_pen : bg_pen);

    wire [7:0] pal_even = pal[{pen, 1'b0}];
    wire [7:0] pal_odd  = pal[{pen, 1'b1}];

    always @(posedge core_clk) begin
        if (!reset_n) begin ovl_rgb <= 24'd0; ovl_opaque <= 1'b0; end
        else if (ovl_ce_pix) begin
            ovl_rgb <= {dac(pal_odd[3:0]), dac(pal_even[7:4]), dac(pal_even[3:0])};
            // Genlock makes pen 0 transparent so the disc shows through; with it
            // clear the game layer covers the disc in black instead.
            ovl_opaque <= in_win & video_en & (genlock ? (pen != 4'd0) : 1'b1);
        end
    end
endmodule
