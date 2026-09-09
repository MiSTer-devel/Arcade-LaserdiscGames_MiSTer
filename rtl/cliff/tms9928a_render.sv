//============================================================================
// tms9928a_render.sv -- TMS9928A display-side renderer: TEXT and GRAPHICS II.
//
// This is the counterpart to tms9928a_regs.sv (which implements everything
// the CPU can see: registers, VRAM access, the status/interrupt latch).
// This module implements the far side: given a pixel/line coordinate and the
// eight VDP registers, produce the colour that pixel should show. Graphics I,
// Multicolor and sprites are NOT implemented here.
//
// Text mode: 40 columns x 24 rows of 6x8-pixel cells (240x192 active pixels),
// two colours only (register 7), no sprites.
//   Name table entry (col,row)     = nameBase    + row*40 + col
//   Pattern byte (charcode,line)   = patternBase + charcode*8 + line
// Only the leftmost 6 bits of each pattern byte are displayed.
//
// Graphics II: 32 columns x 24 rows of 8x8 cells (256x192), three independent
// 256-entry banks selected by y[7:6], with a per-8-pixel-strip colour byte.
//
// ---- CELL PREFETCH --------------------------------------------------------
// VRAM is external (single read port, 1-cycle synchronous read: change the
// address, its data appears one clock later). Resolving a cell needs two
// dependent reads in text (name -> pattern) and three in Graphics II (name ->
// pattern -> colour), so the fetch is a small FSM, not a per-clock pipeline.
//
// The pixel output must NOT depend on when that FSM happens to finish. An
// earlier version updated `color` only at the end of a pass and restarted the
// pass on every px change; the result was valid for the tail of each pixel
// period only, so at cell boundaries the mixer sampled a pass that still
// belonged to the previous cell. Measured against MAME on the title screen:
// 453 wrong pixels, 86% of them at cell pixel 0 or 7.
//
// So the FSM does not chase px. It free-runs on a coordinate ONE CELL AHEAD
// (px_pf) and parks its answer in pf_*. A cell lasts 6 or 8 source pixels --
// ~77 or ~102 core clocks at the 512x480/CE_DIV_LOG2=3 raster -- against a
// 3-or-4-clock pass, so pf_* has re-resolved the same address dozens of times
// and is long stable before it is needed. At the cell boundary pf_* is copied
// into cur_*, and the displayed pixel is then a combinational bit-select out of
// cur_pat using the LIVE px. Timing no longer enters the picture.
//
// px is 9-bit and px_pf = px + cell width wraps within it, which is what makes
// the left edge of the window work: the caller passes px = hpos - X0, so the
// cells before the window sit at the top of the 9-bit range and px_pf reaches 0
// exactly one cell early -- cell 0 of each line is prefetched during the border.
//============================================================================
module tms9928a_render
(
    input             clk,
    input             reset_n,
    input             ce,             // clock enable; tie high to run at clk

    input      [7:0]  reg0,
    input      [7:0]  reg1,           // [6] = BLANK (0 = blanked, backdrop only)
    input      [7:0]  reg2,           // [3:0] = name table base
    input      [7:0]  reg3,
    input      [7:0]  reg4,           // [2:0] = pattern generator base
    input      [7:0]  reg5,
    input      [7:0]  reg6,
    input      [7:0]  reg7,           // [7:4] = fg colour, [3:0] = bg/backdrop colour

    input      [8:0]  px,             // pixel column within the active area
    input      [7:0]  py,             // 0..191, active display line
    // 1 while (px,py) is inside the mode's active area. Text is 240 wide and
    // Graphics II is 256, so the caller owns the window and this is not derived
    // from px -- in Graphics II, px==255 is a REAL column, not a border marker.
    input             active,

    output reg [3:0]  color,          // TMS colour index for (px,py)
    output reg        transparent,    // 1 when color==0 (mixer shows video underneath)

    // external VRAM read port (1-cycle synchronous-read latency)
    output reg [13:0] vram_addr,
    input      [7:0]  vram_data
);
    localparam [1:0] S_ISSUE_NAME = 2'd0,
                     S_WAIT_NAME  = 2'd1,
                     S_WAIT_PAT   = 2'd3,   // graphics II only: colour-table read
                     S_DECODE     = 2'd2;

    // Mode select. M1 = reg1[4], M2 = reg1[3], M3 = reg0[1].
    //   text = 1,0,0   graphics II = 0,0,1
    wire mode_gfx2 = ~reg1[4] & ~reg1[3] & reg0[1];

    //---------------------------------------------------------------------
    // Prefetch coordinate: one whole cell ahead of the pixel being displayed.
    //---------------------------------------------------------------------
    wire [8:0] px_pf = px + (mode_gfx2 ? 9'd8 : 9'd6);

    // NO `/` or `%` anywhere. Quartus 17.0 does no CSE between them, so `px/6`
    // and `px%6` would infer TWO separate lpm_divide instances -- see the vault
    // note "Divide and modulo infer two separate dividers". (px*171)>>10 equals
    // px/6 exactly over the whole 9-bit range (verified 0..511), so one small
    // multiply replaces both; the remainder falls out as px - col*6.
    wire [15:0] pf_col_mul = {7'd0, px_pf} * 16'd171;
    wire  [8:0] pf_col     = pf_col_mul[15:10];        // = px_pf / 6

    wire [15:0] cur_col_mul = {7'd0, px} * 16'd171;
    wire  [8:0] cur_col     = cur_col_mul[15:10];      // = px / 6
    wire  [8:0] cur_col_x6  = {cur_col[6:0], 2'b00}    // col*4
                            + {cur_col[7:0], 1'b0};    // + col*2
    wire  [8:0] cur_rem9    = px - cur_col_x6;         // 0..5

    wire [4:0] row_now  = py[7:3];        // 0..23
    wire [2:0] line_now = py[2:0];        // 0..7

    // Which cell the DISPLAYED pixel belongs to, and where inside it.
    wire [5:0] cell_now    = mode_gfx2 ? px[8:3] : cur_col[5:0];
    wire [2:0] pix_in_cell = mode_gfx2 ? px[2:0] : cur_rem9[2:0];

    // name_addr for the PREFETCH cell: upper 4 bits = table base, lower 10 bits
    // = row*40+col (text) or row*32+col (graphics II, a concatenation).
    wire [13:0] row_x40    = {9'd0, row_now} * 14'd40;
    wire [13:0] name_off14 = row_x40 + {5'd0, pf_col};
    wire  [9:0] name_off   = mode_gfx2 ? {row_now, px_pf[7:3]} : name_off14[9:0];
    wire [13:0] name_addr  = {reg2[3:0], name_off};

    // ---- Graphics II tables ------------------------------------------------
    // Bases and masks per MAME tms9928a.cpp (update_table_masks + the mode-2
    // draw loop). NOTE these are NOT the Graphics I formulas: pattern is
    // (R4 & 0x04) << 11 and colour is (R3 & 0x80) << 6, not R4*0x800 / R3<<6.
    // For Cliff (R2=0F, R3=FF, R4=03) that gives name 0x3C00, pattern 0x0000,
    // colour 0x2000, both masks 0x3FF -- all three banks live.
    wire  [9:0] patternmask = {reg4[1:0], 8'hFF};        // ((R4 & 3) << 8) | 0xFF
    wire  [9:0] colourmask  = {reg3[6:0], 3'b111};       // ((R3 & 0x7F) << 3) | 7

    reg  [2:0] line_l;         // scanline-within-cell latched with the name read
    reg  [9:0] charcode_l;     // name byte + bank, needed for TWO further reads
    reg  [7:0] pattern_hold;   // gfx2: pattern byte held while colour is fetched
    reg        gfx2_l;         // mode latched with the rest, cannot change mid-pass

    // charcode = name byte + ((y >> 6) << 8); py[7:6] IS the 0/1/2 bank index.
    wire  [9:0] charcode_now = {py[7:6], vram_data};
    wire  [9:0] cc_pat       = charcode_l & patternmask;
    wire  [9:0] cc_col       = charcode_l & colourmask;

    // pattern_addr: text = {base[2:0], charcode[7:0], line}; graphics II uses
    // the masked 10-bit charcode against a single A13 base bit.
    wire [13:0] pattern_addr_txt = {reg4[2:0], vram_data, line_l};
    wire [13:0] pattern_addr_g2  = {reg4[2], cc_pat, line_l};
    wire [13:0] colour_addr_g2   = {reg3[7], cc_col, line_l};

    reg [1:0] state;
    always @* begin
        case (state)
            S_ISSUE_NAME: vram_addr = name_addr;
            S_WAIT_NAME:  vram_addr = mode_gfx2 ? pattern_addr_g2 : pattern_addr_txt;
            S_WAIT_PAT:   vram_addr = colour_addr_g2;   // graphics II only
            default:      vram_addr = name_addr;        // S_DECODE: next name early
        endcase
    end

    //---------------------------------------------------------------------
    // Prefetch result (settled long before the cell it belongs to is reached)
    //---------------------------------------------------------------------
    reg [7:0] pf_pat;
    reg [3:0] pf_fg, pf_bg;

    // Graphics II takes fg/bg per 8-pixel strip from the colour table, which is
    // on the bus in S_DECODE. A zero nibble means "use the backdrop", as MAME's
    // mode-2 loop does. Text uses reg7's fixed pair.
    wire [3:0] g2_fg = (vram_data[7:4] != 4'd0) ? vram_data[7:4] : reg7[3:0];
    wire [3:0] g2_bg = (vram_data[3:0] != 4'd0) ? vram_data[3:0] : reg7[3:0];

    //---------------------------------------------------------------------
    // Displayed cell
    //---------------------------------------------------------------------
    reg [7:0] cur_pat;
    reg [3:0] cur_fg, cur_bg;
    reg [5:0] cell_q;
    reg [7:0] py_q;
    wire cell_changed = (cell_now != cell_q) || (py != py_q);

    // Pattern-bit lookup: bit7 = leftmost pixel. Bits 1:0 are unreachable in
    // text, whose cells are 6 pixels wide, not 8. Explicit case rather than a
    // computed part-select, per the Quartus 17 house rules.
    reg pat_bit;
    always @* begin
        case (pix_in_cell)
            3'd0: pat_bit = cur_pat[7];
            3'd1: pat_bit = cur_pat[6];
            3'd2: pat_bit = cur_pat[5];
            3'd3: pat_bit = cur_pat[4];
            3'd4: pat_bit = cur_pat[3];
            3'd5: pat_bit = cur_pat[2];
            3'd6: pat_bit = mode_gfx2 ? cur_pat[1] : 1'b0;
            default: pat_bit = mode_gfx2 ? cur_pat[0] : 1'b0;
        endcase
    end

    // BLANK (reg1[6]==0) or outside the active area -> backdrop only. `active`
    // is used LIVE here rather than latched through the fetch, so the window
    // edge lands on the exact pixel the caller nominated.
    wire [3:0] color_next = (!reg1[6] || !active) ? reg7[3:0]
                                                 : (pat_bit ? cur_fg : cur_bg);
    // Colour 0 is treated as transparent so the laserdisc shows through. MAME
    // makes that conditional on EXTVID (reg0[0]) and otherwise paints colour 0
    // as a real pen; we do not, deliberately. This board is genlocked and Cliff
    // sets EV in its $2114 config, and gating on it would paint the disc black
    // during any window where EV has not been set yet.
    //
    // NOTE the BLANK case above is NOT forced transparent. It resolves to the
    // backdrop, and a non-zero backdrop really does cover the picture on a real
    // TMS -- MAME only makes pen 0 transparent, never the backdrop as such.
    wire transparent_next = (color_next == 4'd0);

    always @(posedge clk) begin
        if (!reset_n) begin
            state        <= S_ISSUE_NAME;
            line_l       <= 3'd0;
            charcode_l   <= 10'd0;
            pattern_hold <= 8'd0;
            gfx2_l       <= 1'b0;
            pf_pat       <= 8'd0;
            pf_fg        <= 4'd0;
            pf_bg        <= 4'd0;
            cur_pat      <= 8'd0;
            cur_fg       <= 4'd0;
            cur_bg       <= 4'd0;
            cell_q       <= 6'd0;
            py_q         <= 8'd0;
            color        <= 4'd0;
            transparent  <= 1'b1;
        end else if (ce) begin
            // ---- free-running prefetch of the NEXT cell --------------------
            case (state)
                S_ISSUE_NAME: begin
                    // name_addr (built from px_pf/py) is on the bus this cycle.
                    line_l <= line_now;
                    gfx2_l <= mode_gfx2;
                    state  <= S_WAIT_NAME;
                end
                S_WAIT_NAME: begin
                    // vram_data == name byte; the pattern address it feeds is
                    // already on the bus combinationally.
                    charcode_l <= charcode_now;
                    state      <= gfx2_l ? S_WAIT_PAT : S_DECODE;
                end
                S_WAIT_PAT: begin
                    // graphics II: vram_data == pattern byte. Hold it -- next
                    // cycle the bus carries the colour byte instead.
                    pattern_hold <= vram_data;
                    state        <= S_DECODE;
                end
                default: begin   // S_DECODE
                    // text: vram_data == pattern byte, colours come from reg7.
                    // gfx2: vram_data == colour byte, pattern is in the hold reg.
                    pf_pat <= gfx2_l ? pattern_hold : vram_data;
                    pf_fg  <= gfx2_l ? g2_fg : reg7[7:4];
                    pf_bg  <= gfx2_l ? g2_bg : reg7[3:0];
                    state  <= S_ISSUE_NAME;
                end
            endcase

            // ---- adopt the prefetched cell at its boundary -----------------
            cell_q <= cell_now;
            py_q   <= py;
            if (cell_changed) begin
                cur_pat <= pf_pat;
                cur_fg  <= pf_fg;
                cur_bg  <= pf_bg;
            end

            // ---- pixel out (combinational select, registered once) ---------
            color       <= color_next;
            transparent <= transparent_next;
        end
    end
endmodule
