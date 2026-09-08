//============================================================================
// text_overlay.sv — character-cell overlay renderer, composited over video.
//
// Deliberately game-agnostic: it knows nothing about Dragon's Lair II, the
// LDP-1450 or any protocol. A source writes GLYPH INDICES into the buffer and
// gives an origin; this walks the output raster and says whether the current
// pixel is part of a character. The caller picks the colour.
//
// COORDINATE SPACE.  Positions are in the shared 320x240 overlay space that
// every Daphne game in this core declares (DL2, Cliff/TMS9128NL, Dragon's Lair,
// Thayer's all agree). The caller converts the raster into it once and passes
// sx/sy; this module never sees the output resolution.
//
// That keeps the font at its native size: a 15px advance in 320-space lands on
// 24 output pixels, which is what a real LDP-1450 cabinet measures. No font
// resampling anywhere.
//============================================================================
module text_overlay #(
    parameter        N_LINE     = 3,      // text rows
    parameter        N_COL      = 32,     // buffer columns (>= any clear a source sends)
    parameter        N_SHOW     = 11,     // columns actually displayed
    parameter        ADVANCE    = 15,     // per-character step, in 320-space
    parameter        LINE_PITCH = 16,     // per-row step, in 320-space
    parameter        GLYPH_W    = 16,
    parameter        GLYPH_H    = 16,
    parameter        N_GLYPH    = 51,
    // Untyped, matching EU4Kx32.sv which already builds under Quartus 17.0 --
    // `parameter string` is SystemVerilog its front end does not reliably take.
    parameter        FONT_HEX   = "rtl/video/ldp1450_font.hex"
)(
    input             clk,

    // ---- position in the SHARED 320x240 overlay space ----
    // The 512x480 -> 320x240 conversion is done once, at the top level, and
    // handed to every overlay source. Doing it per-source is how both this and
    // Cliff's TMS overlay independently ended up in the wrong place.
    input      [15:0] sx,
    input      [15:0] sy,

    // ---- character buffer write port (glyph indices, not ASCII) ----
    input             wr,
    input       [1:0] wr_line,
    input       [5:0] wr_col,
    input       [7:0] wr_glyph,

    // ---- placement, in 320x240 space ----
    input       [8:0] org_x,
    input       [8:0] org_y,
    input             enable,

    output            lit
);
    wire [15:0] rx = sx - {7'd0, org_x};
    wire [15:0] ry = sy - {7'd0, org_y};

    wire in_x = enable && (sx >= {7'd0, org_x}) && (rx < N_SHOW * ADVANCE);
    wire in_y = enable && (sy >= {7'd0, org_y}) && (ry < N_LINE * LINE_PITCH);

    // Row: LINE_PITCH is a power of two, so these are slices.
    wire [1:0] t_line = ry[5:4];
    wire [3:0] g_row  = ry[3:0];

    // Column: ADVANCE is 15, so divide by reciprocal multiply rather than
    // instantiating a divider. 1/15 ~= 137/2048, exact over the range rx spans.
    wire [15:0] colq_m = (rx * 16'd137) >> 11;
    wire  [5:0] t_col  = colq_m[5:0];
    wire [15:0] g_col  = rx - (colq_m * ADVANCE);

    // ---- character buffer: N_LINE x N_COL glyph indices --------------------
    // N_COL is a power of two, so the row base is a concatenation, not a
    // multiply. Written by the source, read by the raster.
    // Address widths are written out rather than derived with $clog2: nothing
    // else in this build uses it, and Quartus 17.0's front end has already
    // rejected one construct here that Verilator was happy with. Arrays are
    // rounded up to the address width so an index can never run past the end.
    //   cbuf : N_LINE(3) x N_COL(32) = 96 -> 7 bits  ({line[1:0], col[4:0]})
    localparam CB_AW = 7;
    reg  [7:0] cbuf [0:127];
    // Both sides must address as line*N_COL + col. Concatenating the full 6-bit
    // wr_col and truncating drops wr_line's MSB, which aliases line 2 onto
    // line 0 -- so slice the column to log2(N_COL) instead of truncating after.
    wire [CB_AW-1:0] cbuf_wa = {wr_line, wr_col[4:0]};
    wire [CB_AW-1:0] cbuf_ra = {t_line,  t_col[4:0]};
    wire             cbuf_we = wr && (wr_col < N_COL);
    reg  [7:0] glyph_q;

    // ---- pipeline ----------------------------------------------------------
    // The buffer read is registered and the font read after it, so the raster
    // position has to be delayed by the same two clocks or every glyph renders
    // a character-cell stale.
    reg  [3:0] g_row_q;
    reg [15:0] g_col_q;
    reg        in_q;

    always @(posedge clk) begin
        if (cbuf_we) cbuf[cbuf_wa] <= wr_glyph;
        glyph_q <= cbuf[cbuf_ra];
        g_row_q <= g_row;
        g_col_q <= g_col;
        in_q    <= in_x & in_y;
    end

    // ---- font ROM: N_GLYPH x GLYPH_H words, bit15 = leftmost pixel ---------
    //   font : N_GLYPH(51) x GLYPH_H(16) = 816 -> 10 bits
    // Glyph 0 is BLANK in the hex on purpose. Nothing in the character map can
    // select it, and BRAM powers up as zeros -- so an un-written cell renders as
    // a space instead of flashing '!' before the game's first write.
    localparam FA_AW = 10;
    reg [15:0] font [0:1023];
    initial $readmemh(FONT_HEX, font);
    reg  [15:0] font_q;
    // Quartus 17.0 rejects a bit-select applied to a concatenation (error 10170)
    // even in a .sv file, though Verilator accepts it. Name it, then slice.
    wire [11:0]      font_addr_full = {glyph_q, g_row_q};
    wire [FA_AW-1:0] font_addr      = font_addr_full[FA_AW-1:0];
    always @(posedge clk) font_q <= font[font_addr];

    // font_q trails by one more clock, so the mask does too.
    reg        in_q2;
    reg [15:0] g_col_q2;
    always @(posedge clk) begin
        in_q2    <= in_q;
        g_col_q2 <= g_col_q;
    end

    wire [3:0] gx = g_col_q2[3:0];
    assign lit = in_q2 && (g_col_q2 < GLYPH_W) && font_q[4'd15 - gx];
endmodule
