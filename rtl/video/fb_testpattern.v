//============================================================================
// fb_testpattern.v — FB bring-up test pattern (feeds fb_writer)
//----------------------------------------------------------------------------
// Walks (x,y) over the 320x240 frame and emits a 2D gradient (R = horizontal,
// G = vertical, B = const).  Position-unique so orientation/offset bugs are
// obvious.  Uses the same px_we/px_ready handshake as jpeg_frame_decoder's
// drain, so it drops straight into fb_writer.  Continuous rewrite.
// Diagnostic only: proves the ddram -> DDR3 FB -> ascal display path.  Once the
// pattern shows correctly, swap this source for the real decoder output.
//============================================================================
module fb_testpattern #(parameter [15:0] W = 16'd320, parameter [15:0] H = 16'd240)
(
    input             clk,
    input             reset,       // active-high
    input             ready,       // fb_writer.px_ready (can accept a pixel)
    output            we,          // -> fb_writer.px_we
    output     [15:0] x,
    output     [15:0] y,
    output      [7:0] r,
    output      [7:0] g,
    output      [7:0] b
);
    reg [15:0] px, py;
    reg        done;               // fill the frame ONCE, then stop (frees DDR for the reader)

    // white 1-px border frames the exact 320x240 extent (so shift/crop/aspect
    // are unambiguous in a screenshot); gradient fills the interior.
    wire at_edge = (px == 16'd0) | (px == W - 16'd1) |
                   (py == 16'd0) | (py == H - 16'd1);
    assign we = ~done;
    assign x  = px;
    assign y  = py;
    assign r  = at_edge ? 8'hFF : {px[8:1]};   // border white; else NON-wrapping horiz red ramp (px/2)
    assign g  = at_edge ? 8'hFF : {py[7:0]};   // border white; else vert green gradient (py<240, no wrap)
    assign b  = at_edge ? 8'hFF : 8'h40;       // border white; else constant blue

    always @(posedge clk) begin
        if (reset) begin
            px <= 16'd0; py <= 16'd0; done <= 1'b0;
        end else if (ready && ~done) begin   // pixel accepted this cycle -> advance
            if (px == W - 16'd1) begin
                px <= 16'd0;
                if (py == H - 16'd1) done <= 1'b1;   // one full frame written -> stop
                else py <= py + 16'd1;
            end else begin
                px <= px + 16'd1;
            end
        end
    end
endmodule
