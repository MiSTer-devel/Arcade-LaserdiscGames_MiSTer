//============================================================================
// tms9928a_render.sv -- TMS9928A display-side renderer: TEXT MODE ONLY.
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

    input      [8:0]  px,             // 0..255, pixel column (240..255 = border)
    input      [7:0]  py,             // 0..191, active display line

    output reg [3:0]  color,          // TMS colour index for (px,py), see pipeline note
    output reg        transparent,    // 1 when color==0 (mixer shows video underneath)

    // external VRAM read port (1-cycle synchronous-read latency)
    output reg [13:0] vram_addr,
    input      [7:0]  vram_data
);
    localparam [1:0] S_ISSUE_NAME = 2'd0,
                      S_WAIT_NAME  = 2'd1,
                      S_DECODE     = 2'd2;

    reg [1:0] state;
    reg [2:0] pix_in_cell_l;   // latched pixel-within-cell (0..5), snapshotted at ISSUE_NAME
    reg [2:0] line_l;          // latched scanline-within-cell (0..7)
    reg       border_l;        // latched "outside the 240-wide active area" flag

    // ---- live combinational decode of the CURRENT px/py --------------------
    // Only valid/used while in S_ISSUE_NAME (that's when px/py get sampled).
    wire [8:0] col_now         = px / 9'd6;      // 0..39 for px<240
    wire [2:0] pix_in_cell_now = px % 9'd6;      // 0..5
    wire [4:0] row_now         = py[7:3];        // 0..23
    wire [2:0] line_now        = py[2:0];        // 0..7
    wire       border_now      = (px >= 9'd240); // outside the 40-column active area

    // name_addr: upper 4 bits = table base, lower 10 bits = row*40+col.
    wire [13:0] row_x40    = {9'd0, row_now} * 14'd40;
    wire [13:0] name_off14 = row_x40 + {5'd0, col_now};
    wire [13:0] name_addr  = {reg2[3:0], name_off14[9:0]};

    // pattern_addr: upper 3 bits = table base, next 8 = charcode, low 3 = line.
    // Only meaningful during S_WAIT_NAME, when vram_data == the name byte.
    wire [13:0] pattern_addr = {reg4[2:0], vram_data, line_l};

    always @* begin
        case (state)
            S_ISSUE_NAME: vram_addr = name_addr;
            S_WAIT_NAME:  vram_addr = pattern_addr;
            default:      vram_addr = pattern_addr; // S_DECODE: no new read issued, hold
        endcase
    end

    // Pattern-bit lookup: bit7=leftmost pixel (pixel 0) ... bit2=pixel 5.
    // Bits 1:0 of the byte are never selected -- a cell is 6 pixels, not 8.
    // Explicit case (not a computed part-select) per Quartus 17 house rules.
    reg pat_bit;
    always @* begin
        case (pix_in_cell_l)
            3'd0: pat_bit = vram_data[7];
            3'd1: pat_bit = vram_data[6];
            3'd2: pat_bit = vram_data[5];
            3'd3: pat_bit = vram_data[4];
            3'd4: pat_bit = vram_data[3];
            3'd5: pat_bit = vram_data[2];
            default: pat_bit = 1'b0;
        endcase
    end

    // BLANK (reg1[6]==0) or outside the active area -> backdrop only.
    wire [3:0] color_next       = (!reg1[6] || border_l) ? reg7[3:0]
                                 : (pat_bit ? reg7[7:4] : reg7[3:0]);
    wire       transparent_next = (color_next == 4'd0);

    always @(posedge clk) begin
        if (!reset_n) begin
            state         <= S_ISSUE_NAME;
            pix_in_cell_l <= 3'd0;
            line_l        <= 3'd0;
            border_l      <= 1'b0;
            color         <= 4'd0;
            transparent   <= 1'b1;
        end else if (ce) begin
            case (state)
                S_ISSUE_NAME: begin
                    // name_addr (built from live px/py) is on the bus this
                    // cycle; snapshot what later stages will need.
                    pix_in_cell_l <= pix_in_cell_now;
                    line_l        <= line_now;
                    border_l      <= border_now;
                    state         <= S_WAIT_NAME;
                end
                S_WAIT_NAME: begin
                    // vram_data == name byte this cycle; pattern_addr (built
                    // from it combinationally above) is already on the bus.
                    state <= S_DECODE;
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
