//============================================================================
// tms9928a_render.sv -- TMS9928A display-side renderer: TEXT and GRAPHICS II.
//
// This is the counterpart to tms9928a_regs.sv (which implements everything
// the CPU can see: registers, VRAM access, the status/interrupt latch).
// This module implements the far side: given a pixel/line coordinate and the
// eight VDP registers, produce the colour that pixel should show. Graphics I,
// Graphics II, Multicolor and sprites are NOT implemented here.
//
// Text mode: 40 columns x 24 rows of 6x8-pixel cells (240x192 active pixels),
// two colours only (register 7), no sprites.
//   Name table entry (col,row)     = nameBase    + row*40 + col
//   Pattern byte (charcode,line)   = patternBase + charcode*8 + line
//   nameBase    = reg2[3:0] * 0x400   (forms the upper 4 bits of the address)
//   patternBase = reg4[2:0] * 0x800   (forms the upper 3 bits of the address)
// Only the leftmost 6 bits of each pattern byte (bits 7:2) are displayed;
// bits 1:0 are never fetched-as-pixels because a cell is 6 pixels wide, not 8.
//
// ---- VRAM fetch pipeline --------------------------------------------------
// VRAM is external (single read port, 1-cycle synchronous-read latency, same
// contract as tms9928a_regs.sv's vram_dout: change the address, the data for
// it appears one clock later). Resolving one pixel needs TWO dependent reads
// (name byte, then pattern byte), so this module is a small 3-state FSM, not
// a free-running per-pixel pipeline:
//
//   state ISSUE_NAME : vram_addr = name_addr(px,py)            [live px,py]
//   state WAIT_NAME  : vram_data == name byte;
//                      vram_addr = pattern_addr(vram_data,line) [issued now]
//   state DECODE     : vram_data == pattern byte; colour/transparent
//                      are computed and registered; back to ISSUE_NAME.
//
// PIPELINE DEPTH: 3 ce pulses per query. The caller must hold px/py stable
// for the ISSUE_NAME cycle (its live value is latched there) and pulse `ce`
// three times; `color`/`transparent` update at the end of the third pulse
// and hold until the next round completes. This is a query core, not a
// continuously-streaming one-pixel-per-clock pipeline: it does NOT cache the
// name/pattern byte across the 6 pixels of a cell, so it re-fetches both for
// every single pixel query. Wiring it into a live, continuously-advancing
// pixel counter (6 pixels/cell) would need either `ce` run at several times
// the pixel rate, or a per-cell cache added on top -- neither exists yet;
// that integration work is outside this module.
//============================================================================
module tms9928a_render
(
    input             clk,
    input             reset_n,
    input             ce,             // pixel-domain clock enable (see pipeline note above)

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

    output reg [3:0]  color,          // TMS colour index for (px,py), see pipeline note
    output reg        transparent,    // 1 when color==0 (mixer shows video underneath)

    // external VRAM read port (1-cycle synchronous-read latency)
    output reg [13:0] vram_addr,
    input      [7:0]  vram_data
);
    localparam [1:0] S_ISSUE_NAME = 2'd0,
                      S_WAIT_NAME  = 2'd1,
                      S_WAIT_PAT   = 2'd3,   // graphics II only: colour-table read
                      S_DECODE     = 2'd2;

    // TIMING MARGIN. Text takes 3 states per pixel, Graphics II 4 (it needs the
    // extra colour-table read). One source pixel spans 512/320 * 8 = 12.8 clocks
    // at CE_DIV_LOG2=3, and a px change mid-pass costs at most two passes to
    // flush, so Graphics II needs up to 8 -- inside 12.8, but tighter than text.
    reg [1:0] state;
    reg [2:0] pix_in_cell_l;   // latched pixel-within-cell (0..5 text, 0..7 gfx2)
    reg [2:0] line_l;          // latched scanline-within-cell (0..7)
    reg       border_l;        // latched "outside the active area" flag
    reg [9:0] charcode_l;      // gfx2: name byte + bank, needed for TWO reads
    reg [7:0] pattern_l;       // gfx2: pattern byte, held while colour is fetched
    reg       gfx2_l;          // mode latched with the rest, so it cannot change mid-cell

    // ---- live combinational decode of the CURRENT px/py --------------------
    // Only valid/used while in S_ISSUE_NAME (that's when px/py get sampled).
    // NO `/` or `%` here. Quartus 17.0 does no CSE between them, so `px/6` and
    // `px%6` would infer TWO separate lpm_divide instances -- see the vault note
    // "Divide and modulo infer two separate dividers", where that cost thousands
    // of ALMs. px is at most 255, and (px*171)>>10 equals px/6 exactly over that
    // whole range (verified for 0..255), so one small multiply replaces both:
    // the remainder then falls out as px - col*6, and *6 is just shifts.
    wire [15:0] col_mul         = {7'd0, px} * 16'd171;
    wire  [8:0] col_now         = col_mul[15:10];                   // = px / 6
    wire  [8:0] col_x6          = {col_now[6:0], 2'b00}             // col*4
                                + {col_now[7:0], 1'b0};             // + col*2
    wire  [8:0] rem9            = px - col_x6;                      // 0..5
    wire  [2:0] pix_in_cell_now = rem9[2:0];
    wire [4:0] row_now         = py[7:3];        // 0..23
    wire [2:0] line_now        = py[2:0];        // 0..7
    wire       border_now      = ~active;

    // Mode select. M1 = reg1[4], M2 = reg1[3], M3 = reg0[1].
    //   text = 1,0,0   graphics II = 0,0,1
    wire mode_text = reg1[4] & ~reg1[3] & ~reg0[1];
    wire mode_gfx2 = ~reg1[4] & ~reg1[3] & reg0[1];

    // Graphics II: 8-wide cells, 32 columns -- both are shifts, no divide.
    wire [5:0] g_col_now       = px[8:3];
    wire [2:0] g_pix_now       = px[2:0];

    // name_addr: upper 4 bits = table base, lower 10 bits = row*40+col (text)
    // or row*32+col (graphics II, a concatenation rather than a multiply).
    wire [13:0] row_x40    = {9'd0, row_now} * 14'd40;
    wire [13:0] name_off14 = row_x40 + {5'd0, col_now};
    wire  [9:0] name_off   = mode_gfx2 ? {row_now, g_col_now[4:0]} : name_off14[9:0];
    wire [13:0] name_addr  = {reg2[3:0], name_off};

    // ---- Graphics II tables ------------------------------------------------
    // Bases and masks per MAME tms9928a.cpp (update_table_masks + the mode-2
    // draw loop). NOTE these are NOT the Graphics I formulas: pattern is
    // (R4 & 0x04) << 11 and colour is (R3 & 0x80) << 6, not R4*0x800 / R3<<6.
    // For Cliff (R2=0F, R3=FF, R4=03) that gives name 0x3C00, pattern 0x0000,
    // colour 0x2000, both masks 0x3FF -- all three banks live.
    wire  [9:0] patternmask = {reg4[1:0], 8'hFF};        // ((R4 & 3) << 8) | 0xFF
    wire  [9:0] colourmask  = {reg3[6:0], 3'b111};       // ((R3 & 0x7F) << 3) | 7

    // charcode = name byte + ((y >> 6) << 8); py[7:6] IS the 0/1/2 bank index.
    wire  [9:0] charcode_now = {py[7:6], vram_data};
    wire  [9:0] cc_pat       = charcode_l & patternmask;
    wire  [9:0] cc_col       = charcode_l & colourmask;

    // pattern_addr: text = {base[2:0], charcode[7:0], line}; graphics II uses
    // the masked 10-bit charcode against a single A13 base bit.
    wire [13:0] pattern_addr_txt = {reg4[2:0], vram_data, line_l};
    wire [13:0] pattern_addr_g2  = {reg4[2], cc_pat, line_l};
    wire [13:0] colour_addr_g2   = {reg3[7], cc_col, line_l};
    wire [13:0] pattern_addr     = mode_gfx2 ? pattern_addr_g2 : pattern_addr_txt;

    always @* begin
        case (state)
            S_ISSUE_NAME: vram_addr = name_addr;
            S_WAIT_NAME:  vram_addr = mode_gfx2 ? pattern_addr_g2 : pattern_addr_txt;
            S_WAIT_PAT:   vram_addr = colour_addr_g2;   // graphics II only
            default:      vram_addr = pattern_addr;     // S_DECODE: hold
        endcase
    end

    // Pattern-bit lookup: bit7=leftmost pixel (pixel 0) ... bit2=pixel 5.
    // Bits 1:0 of the byte are never selected -- a cell is 6 pixels, not 8.
    // Explicit case (not a computed part-select) per Quartus 17 house rules.
    // Text reads the pattern live off the bus in S_DECODE; graphics II held it in
    // pattern_l one state earlier, because S_DECODE's bus carries the colour byte.
    wire [7:0] pat_byte = gfx2_l ? pattern_l : vram_data;
    reg pat_bit;
    always @* begin
        case (pix_in_cell_l)
            3'd0: pat_bit = pat_byte[7];
            3'd1: pat_bit = pat_byte[6];
            3'd2: pat_bit = pat_byte[5];
            3'd3: pat_bit = pat_byte[4];
            3'd4: pat_bit = pat_byte[3];
            3'd5: pat_bit = pat_byte[2];
            // bits 1:0 are only reachable in graphics II, whose cells are 8 wide
            3'd6: pat_bit = gfx2_l ? pat_byte[1] : 1'b0;
            default: pat_bit = gfx2_l ? pat_byte[0] : 1'b0;
        endcase
    end

    // Graphics II takes fg/bg per 8-pixel strip from the colour table, which is
    // on the bus in S_DECODE. A zero nibble means "use the backdrop", as MAME's
    // mode-2 loop does. Text uses reg7's fixed pair.
    wire [3:0] g2_fg = (vram_data[7:4] != 4'd0) ? vram_data[7:4] : reg7[3:0];
    wire [3:0] g2_bg = (vram_data[3:0] != 4'd0) ? vram_data[3:0] : reg7[3:0];
    wire [3:0] fg_now = gfx2_l ? g2_fg : reg7[7:4];
    wire [3:0] bg_now = gfx2_l ? g2_bg : reg7[3:0];

    // BLANK (reg1[6]==0) or outside the active area -> backdrop only.
    wire [3:0] color_next       = (!reg1[6] || border_l) ? reg7[3:0]
                                 : (pat_bit ? fg_now : bg_now);
    // Colour 0 is treated as transparent so the laserdisc shows through. MAME
    // makes that conditional on EXTVID (reg0[0]) and otherwise paints colour 0
    // as a real pen; we do not, deliberately. This board is genlocked and Cliff
    // sets EV in its $2114 config, and gating on it would paint the disc black
    // during any window where EV has not been set yet.
    //
    // NOTE the BLANK case above is NOT forced transparent. It resolves to the
    // backdrop, and a non-zero backdrop really does cover the picture on a real
    // TMS -- MAME only makes pen 0 transparent, never the backdrop as such. So
    // if a blanked Cliff covers the screen, the fix is not here: it is whatever
    // left reg7's low nibble non-zero.
    wire       transparent_next = (color_next == 4'd0);

    always @(posedge clk) begin
        if (!reset_n) begin
            state         <= S_ISSUE_NAME;
            pix_in_cell_l <= 3'd0;
            line_l        <= 3'd0;
            border_l      <= 1'b0;
            charcode_l    <= 10'd0;
            pattern_l     <= 8'd0;
            gfx2_l        <= 1'b0;
            color         <= 4'd0;
            transparent   <= 1'b1;
        end else if (ce) begin
            case (state)
                S_ISSUE_NAME: begin
                    // name_addr (built from live px/py) is on the bus this
                    // cycle; snapshot what later stages will need.
                    pix_in_cell_l <= mode_gfx2 ? g_pix_now : pix_in_cell_now;
                    line_l        <= line_now;
                    border_l      <= border_now;
                    gfx2_l        <= mode_gfx2;
                    state         <= S_WAIT_NAME;
                end
                S_WAIT_NAME: begin
                    // vram_data == name byte this cycle; the pattern address
                    // (built from it combinationally above) is already on the bus.
                    charcode_l <= charcode_now;
                    state      <= gfx2_l ? S_WAIT_PAT : S_DECODE;
                end
                S_WAIT_PAT: begin
                    // graphics II: vram_data == pattern byte; hold it while the
                    // colour address goes out, since S_DECODE's bus is the colour.
                    pattern_l <= vram_data;
                    state     <= S_DECODE;
                end
                S_DECODE: begin
                    // vram_data == pattern byte this cycle.
                    color       <= color_next;
                    transparent <= transparent_next;
                    state       <= S_ISSUE_NAME;
                end
                default: state <= S_ISSUE_NAME;
            endcase
        end
    end
endmodule
