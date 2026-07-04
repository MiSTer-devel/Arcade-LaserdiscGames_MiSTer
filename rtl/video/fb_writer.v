//============================================================================
// fb_writer.v — framebuffer writer (decoder RGB pixels -> DDR3 via ddram.sv)
//----------------------------------------------------------------------------
// Takes the jpeg_frame_decoder pixel stream (block-order, with x/y) and writes
// RGB565 to the MISTER_FB framebuffer in HPS DDR3 through the write port of
// rtl/ram_rom/ddram.sv (Sorgelig, 16-bit: RAM based at 0x30000000, halfword
// address wraddr[27:1], toggle we_req/we_ack handshake).
//
// Address: the FB is 16bpp tight, so byte = FB_BASE + y*STRIDE + x*2, and the
// halfword index (what ddram.sv wants) = FB_BASE_HW + y*STRIDE_HW + x, where
// FB_BASE_HW/STRIDE_HW are in halfwords.  Put the FB at the base of ddram.sv's
// 0x30000000 region => FB_BASE_HW = 0, and set the top-level FB_BASE = 0x30000000.
//
// One DDR write per pixel (burst-1).  Decoder output is stalled via px_ready
// while a write is in flight.  ~77k px/frame * a few DDR cycles each is well
// under the 33 ms frame budget (decode itself is ~8x real-time).
//
// The scaler reads the FB independently (framework ascal), so this module only
// uses ddram.sv's WRITE port; the rom/read ports stay for ROM caching if ever
// needed.  NOT yet instantiated at top.
//============================================================================
module fb_writer #(
    parameter [26:0] FB_BASE_HW = 27'd0,     // halfword offset of FB within the 0x30000000 region
    parameter [15:0] STRIDE_HW  = 16'd320    // halfwords per row (= width for tight 16bpp)
)(
    input             clk,          // DDRAM_CLK domain
    input             reset,        // active-high

    // --- pixel input (from jpeg_frame_decoder drain) ---
    input             px_we,        // pixel valid
    input      [15:0] px_x,
    input      [15:0] px_y,
    input       [7:0] px_r,
    input       [7:0] px_g,
    input       [7:0] px_b,
    output            px_ready,     // -> decoder px_ready (backpressure)

    // --- ddram.sv write port ---
    output reg [27:1] wraddr,       // halfword address
    output reg [15:0] din,          // RGB565
    output reg        we_req,       // toggle to request a write
    input             we_ack        // ddram raises to == we_req when done
);
    reg busy;
    assign px_ready = ~busy;

    // halfword index = FB_BASE_HW + y*STRIDE_HW + x
    wire [26:0] hw_index = FB_BASE_HW + (px_y * STRIDE_HW) + {11'd0, px_x};

    always @(posedge clk) begin
        if (reset) begin
            busy   <= 1'b0;
            we_req <= 1'b0;
            wraddr <= 27'd0;
            din    <= 16'd0;
        end else if (!busy) begin
            if (px_we) begin
                wraddr <= hw_index;
                din    <= {px_r[7:3], px_g[7:2], px_b[7:3]};   // RGB565
                we_req <= ~we_req;                              // request a write
                busy   <= 1'b1;
            end
        end else if (we_ack == we_req) begin
            busy <= 1'b0;                                       // write complete
        end
    end
endmodule
