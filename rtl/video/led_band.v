//============================================================================
// led_band.v — Dragon's Lair LED score/status band at framebuffer (x,y) coords
//----------------------------------------------------------------------------
// Ported from the raster renderer in DragonsLair_CPU.sv so the band can be
// composited over the 320-wide video (that renderer used the 256-wide core
// raster).  Given the current pixel (hc,vc) + the 16 LED digits, outputs
// seg_lit = this pixel is a lit segment of the band.  The caller paints it red.
// Layout: 33 char-slots x 6px pitch, 5x7 glyphs, band rows BAND_Y0..+7.
// X_START recentred for 320: (320 - 33*6)/2 = 61.
// Digit map (led_digits[i*4 +: 4]): 0-5 P1 score, 6 P1 lives, 7 P2 lives,
// 8-13 P2 score, 14-15 credits.  (matches MAME dlair.lay / DragonsLair_CPU)
//============================================================================
module led_band #(
    // X_START centres the band: (W - N_SLOT*PITCH*2^SCALE_LOG2)/2.
    parameter [15:0] X_START = 16'd61,   // (320 - N_SLOT*PITCH)/2, centred
    parameter [1:0]  SCALE_LOG2 = 2'd0,  // glyph magnification = 2^SCALE_LOG2
    parameter [15:0] BAND_Y0 = 16'd2,
    // 0 = stock (code 15 blank, as DL has always been); 1 = code 15 renders 'F' for hex frame
    // values, moving blank to code 31.
    parameter        DIAG_HEX_F = 1'b0,
    // X origin when the Space Ace skill field is shown. The band grows
    // from 33 to 39 slots, so it is recentred: (512 - 39*6*2)/2 = 22.  Only used when skill_en=1.
    parameter [15:0] X_START_SKILL = 16'd22
)(
    input      [15:0] hc,
    input      [15:0] vc,
    // 240p halves the row count while the width is unchanged, so the glyph must NOT be magnified
    // vertically or it renders double-height relative to the picture.
    input             crt_240p,
    input      [63:0] led_digits,        // 16 x 4-bit, digit i = [i*4 +: 4]
    // Space Ace difficulty field. skill_en is the GAME ID (mod byte) and
    // controls the band WIDTH; skill is the latched selection and controls the letters.
    // Dragon's Lair drives skill_en=0 and is then bit-identical to the pre- band.
    input             skill_en,          // 1 = Space Ace: render "D CAD/CAP/ACE" at the far right
    input       [1:0] skill,             // 0=none yet, 1=Cadet, 2=Captain, 3=Space Ace
    output            seg_lit
);
    localparam FH = 7, PITCH = 6, N_SLOT = 33, N_SLOT_SKILL = 39;

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
            // Glyph taken from VCR-Robots' led_band.v.
            5'd15: glyph = DIAG_HEX_F
                         ? 35'b11111_10000_10000_11110_10000_10000_10000    // F
                         : 35'd0;                                          // stock: blank
            5'd16: glyph = 35'b11110_10001_10001_11110_10000_10000_10000; // P
            5'd17: glyph = 35'b10000_10000_10000_10000_10000_10000_11111; // L
            5'd18: glyph = 35'b11110_10001_10001_11110_10100_10010_10001; // R
            default: glyph = 35'd0;                                       // 15 = blank
        endcase
    endfunction

    // RES-512x480->> SCALE_LOG2 magnifies by replicating source pixels; the
    // origin and width switch with the game, so DL's geometry is untouched.
    wire [15:0] x_org   = skill_en ? X_START_SKILL : X_START;
    wire [15:0] n_slots = skill_en ? N_SLOT_SKILL  : N_SLOT;

    wire [15:0] hoff = hc - x_org;
    wire [15:0] voff = vc - BAND_Y0;
    wire [15:0] bx   = hoff >> SCALE_LOG2;
    wire [5:0]  slot = bx / PITCH;                // 0..32 (0..38 with skill field)
    wire [2:0]  fx   = bx - slot*PITCH;           // 0..5 (5 = inter-char gap)
    // Vertical scale only: 1x in 240p, 2^SCALE_LOG2 otherwise.  Named wires because Quartus 17
    // elaborates .v as Verilog-2001, where (expr)[2:0] is illegal.
    wire [15:0] gh     = crt_240p ? FH : (FH << SCALE_LOG2);   // glyph height in display rows
    wire [15:0] voff_s = crt_240p ? voff : (voff >> SCALE_LOG2);
    wire [2:0]  fy     = voff_s[2:0];             // 0..6 within the glyph
    wire in_band = (hc >= x_org) && (hc < x_org + ((n_slots*PITCH) << SCALE_LOG2)) &&
                   (vc >= BAND_Y0) && (vc < BAND_Y0 + gh);

    // Blank until a skill is latched, so the field does not show a lone "D" on the select screen.
    reg [4:0] sk0, sk1, sk2;
    always @* case (skill)
        2'd1:    begin sk0 = 5'd12; sk1 = 5'd10; sk2 = 5'd13; end   // C A D  (Cadet)
        2'd2:    begin sk0 = 5'd12; sk1 = 5'd10; sk2 = 5'd16; end   // C A P  (Captain)
        2'd3:    begin sk0 = 5'd10; sk1 = 5'd12; sk2 = 5'd14; end   // A C E  (Space Ace)
        default: begin sk0 = 5'd31; sk1 = 5'd31; sk2 = 5'd31; end   // not chosen yet -> blank
    endcase

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
        // Space Ace only (slots 33-38 exist only when skill_en=1).
        // Slot 33 and 35 are gaps -> "D CAD".  Hidden entirely until a skill is latched.
        6'd34: ch = (skill == 2'd0) ? 5'd31 : 5'd13;                                                // "D" label
        6'd36: ch = sk0;                               6'd37: ch = sk1;
        6'd38: ch = sk2;                                                                            // CAD/CAP/ACE
        // Empty slots use 31, not 15: code 15 is 'F' when DIAG_HEX_F=1.  31 has no glyph entry
        // and hits the font's own blank default in both modes.
        default: ch = 5'd31;                                                                        // blank
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
