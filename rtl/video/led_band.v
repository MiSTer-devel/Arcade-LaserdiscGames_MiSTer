//============================================================================
// led_band.v — Dragon's Lair LED score/status band at framebuffer (x,y) coords
//----------------------------------------------------------------------------
// Ported from the raster renderer in DragonsLair_CPU.sv so the band can be
// composited over the 320-wide video (that renderer used the 256-wide core
// raster).  Given the current pixel (hc,vc) + the 16 LED digits, outputs
// seg_lit = this pixel is a lit segment of the band.  The caller paints it red.
//
// Layout: 33 char-slots x 6px pitch, 5x7 glyphs, band rows BAND_Y0..+7.
// X_START recentred for 320: (320 - 33*6)/2 = 61.
// Digit map (led_digits[i*4 +: 4]): 0-5 P1 score, 6 P1 lives, 7 P2 lives,
// 8-13 P2 score, 14-15 credits.  (matches MAME dlair.lay / DragonsLair_CPU)
//============================================================================
module led_band #(
    parameter [15:0] X_START = 16'd61,   // (320 - N_SLOT*PITCH)/2, centred
    parameter [15:0] BAND_Y0 = 16'd2
)(
    input      [15:0] hc,
    input      [15:0] vc,
    input      [63:0] led_digits,        // 16 x 4-bit, digit i = [i*4 +: 4]
    output            seg_lit
);
    localparam FH = 7, PITCH = 6, N_SLOT = 33;

    // 5x7 font, packed 35 bits/glyph: row0(top)=[34:30] .. row6=[4:0], bit4=left.
    function [34:0] glyph(input [4:0] ch);
        case (ch)
            5'd0:  glyph = 35'b01110_10001_10011_10101_11001_10001_01110; // 0
            5'd1:  glyph = 35'b00100_01100_00100_00100_00100_00100_01110; // 1
            5'd2:  glyph = 35'b01110_10001_00001_00010_00100_01000_11111; // 2
            5'd3:  glyph = 35'b11111_00010_00100_00010_00001_10001_01110; // 3
            5'd4:  glyph = 35'b00010_00110_01010_10010_11111_00010_00010; // 4
            5'd5:  glyph = 35'b11111_10000_11110_00001_00001_10001_01110; // 5
            5'd6:  glyph = 35'b00110_01000_10000_11110_10001_10001_01110; // 6
            5'd7:  glyph = 35'b11111_00001_00010_00100_01000_01000_01000; // 7
            5'd8:  glyph = 35'b01110_10001_10001_01110_10001_10001_01110; // 8
            5'd9:  glyph = 35'b01110_10001_10001_01111_00001_00010_01100; // 9
            5'd10: glyph = 35'b01110_10001_10001_11111_10001_10001_10001; // A
            5'd11: glyph = 35'b11110_10001_10001_11110_10001_10001_11110; // B
            5'd12: glyph = 35'b01110_10001_10000_10000_10000_10001_01110; // C
            5'd13: glyph = 35'b11110_10001_10001_10001_10001_10001_11110; // D
            5'd14: glyph = 35'b11111_10000_10000_11110_10000_10000_11111; // E
            5'd16: glyph = 35'b11110_10001_10001_11110_10000_10000_10000; // P
            5'd17: glyph = 35'b10000_10000_10000_10000_10000_10000_11111; // L
            5'd18: glyph = 35'b11110_10001_10001_11110_10100_10010_10001; // R
            default: glyph = 35'd0;                                       // 15 = blank
        endcase
    endfunction

    wire [15:0] bx   = hc - X_START;
    wire [5:0]  slot = bx[15:0] / PITCH;         // 0..32
    wire [2:0]  fx   = bx - slot*PITCH;           // 0..5 (5 = inter-char gap)
    wire [2:0]  fy   = vc - BAND_Y0;              // 0..6 within the glyph
    wire in_band = (hc >= X_START) && (hc < X_START + N_SLOT*PITCH) &&
                   (vc >= BAND_Y0) && (vc < BAND_Y0 + FH);

    // slot -> character (font code).  Dynamic slots pull led_digits[].
    reg [4:0] ch;
    always @* case (slot)
        6'd0:  ch = 5'd16;                             6'd1:  ch = 5'd1;                            // "P1"
        6'd3:  ch = {1'b0, led_digits[ 0*4 +: 4]};     6'd4:  ch = {1'b0, led_digits[ 1*4 +: 4]};
        6'd5:  ch = {1'b0, led_digits[ 2*4 +: 4]};     6'd6:  ch = {1'b0, led_digits[ 3*4 +: 4]};
        6'd7:  ch = {1'b0, led_digits[ 4*4 +: 4]};     6'd8:  ch = {1'b0, led_digits[ 5*4 +: 4]};   // P1 score 0-5
        6'd10: ch = 5'd17;                                                                          // "L"
        6'd11: ch = {1'b0, led_digits[ 6*4 +: 4]};                                                  // P1 lives
        6'd14: ch = 5'd16;                             6'd15: ch = 5'd2;                            // "P2"
        6'd17: ch = {1'b0, led_digits[ 8*4 +: 4]};     6'd18: ch = {1'b0, led_digits[ 9*4 +: 4]};
        6'd19: ch = {1'b0, led_digits[10*4 +: 4]};     6'd20: ch = {1'b0, led_digits[11*4 +: 4]};
        6'd21: ch = {1'b0, led_digits[12*4 +: 4]};     6'd22: ch = {1'b0, led_digits[13*4 +: 4]};   // P2 score 8-13
        6'd24: ch = 5'd17;                                                                          // "L"
        6'd25: ch = {1'b0, led_digits[ 7*4 +: 4]};                                                  // P2 lives
        6'd28: ch = 5'd12;                             6'd29: ch = 5'd18;                           // "CR"
        6'd31: ch = {1'b0, led_digits[14*4 +: 4]};     6'd32: ch = {1'b0, led_digits[15*4 +: 4]};   // credits 14,15
        default: ch = 5'd15;                                                                        // blank
    endcase

    wire [34:0] gbits = glyph(ch);
    reg  [4:0]  rowbits;
    always @* case (fy)
        3'd0: rowbits = gbits[34:30];  3'd1: rowbits = gbits[29:25];
        3'd2: rowbits = gbits[24:20];  3'd3: rowbits = gbits[19:15];
        3'd4: rowbits = gbits[14:10];  3'd5: rowbits = gbits[9:5];
        3'd6: rowbits = gbits[4:0];    default: rowbits = 5'd0;
    endcase

    wire pix = (fx < 3'd5) & rowbits[4 - fx];
    assign seg_lit = in_band & pix;
endmodule
