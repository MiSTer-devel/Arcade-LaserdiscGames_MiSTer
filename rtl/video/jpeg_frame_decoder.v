//============================================================================
// jpeg_frame_decoder.v  --  DL/SA/TQ in-fabric MJPEG frame decoder wrapper
//----------------------------------------------------------------------------
// Thin adapter around ultraembedded/core_jpeg (Apache-2.0, rtl/video/core_jpeg).
// It turns a *byte* stream of one baseline JPEG frame (fed by the SDRAM ring /
// block streamer, TBD) into core_jpeg's 32-bit AXI-Stream input, and turns
// core_jpeg's 8x8-block-order RGB888 output into framebuffer pixel writes.
// Our stream is frozen: baseline, 4:2:0 (yuvj420p), standard Huffman
// (-huffman default), so SUPPORT_WRITABLE_DHT=0 (built-in tables, smaller/fast).
// core_jpeg does NOT support restart markers -> our ffmpeg encode emits none.
// IMPORTANT: core_jpeg emits pixels in 8x8-BLOCK order, not raster. The FB
// write MUST address by {px_x,px_y} (provided per pixel), never a linear count.
// Byte packing (verified vs jpeg_input.v:93-96): first JPEG byte -> data[7:0],
// then [15:8], [23:16], [31:24]; strb marks valid lanes on a partial final word.
// This module is standalone (not yet instantiated at top) — it compiles/syntax-
// checks in the project now; wire it up once the SDRAM ring + framebuffer land.
//============================================================================
module jpeg_frame_decoder
(
    input             clk,
    input             rst,          // active-high

    // ---- Feed: byte stream of ONE JPEG frame (from ring/streamer) ----------
    input      [7:0]  in_byte,
    input             in_valid,
    output            in_ready,
    input             in_last,      // asserted with the final byte of the frame

    // ---- Drain: framebuffer pixel writes -----------------------------------
    input             px_ready,     // FB can accept a write (tie 1 if always ready)
    output            px_we,        // pixel write strobe (px_valid & px_ready)
    output     [15:0] px_x,         // column 0..width-1   (FB address)
    output     [15:0] px_y,         // row    0..height-1  (FB address)
    output     [7:0]  px_r,
    output     [7:0]  px_g,
    output     [7:0]  px_b,

    // ---- Status ------------------------------------------------------------
    output     [15:0] frame_width,  // decoded dims (expect 320 x 240)
    output     [15:0] frame_height,
    output            frame_done,    // 1-cyc pulse: bottom-right pixel written
    output            idle
);

    //------------------------------------------------------------------------
    // Feed: byte -> 32-bit word packer (little-endian byte lanes)
    //------------------------------------------------------------------------
    reg  [1:0]  bcnt;          // which lane of wbuf_next fills next (0..3)
    reg  [31:0] wbuf,      wbuf_next;
    reg  [3:0]  sbuf,      sbuf_next;
    reg         wlast,     wlast_next;
    reg         wfull;         // wbuf holds a complete word presented to the core
    reg         wfull_next;    // wbuf_next holds a complete word awaiting promotion

    wire in_accept_o;     // core_jpeg inport_accept_o
    wire take = in_valid && in_ready;

    assign in_ready = !wfull_next;   // shadow slot is the only backpressure point

    always @(posedge clk) begin
        if (rst) begin
            bcnt <= 2'd0;
            wbuf <= 32'd0; wbuf_next <= 32'd0;
            sbuf <= 4'd0;  sbuf_next <= 4'd0;
            wfull <= 1'b0; wfull_next <= 1'b0;
            wlast <= 1'b0; wlast_next <= 1'b0;
        end else begin
            // Promote the shadow word the instant the core accepts the
            // presented one (or immediately fill an empty presented slot
            // at startup) -- this is what removes the inport_valid_i gap.
            if ((wfull && in_accept_o && wfull_next) ||
                (!wfull && wfull_next)) begin
                wbuf  <= wbuf_next;  sbuf  <= sbuf_next;  wlast  <= wlast_next;
                wfull <= 1'b1;
                wfull_next <= 1'b0; sbuf_next <= 4'd0; wlast_next <= 1'b0;
            end else if (wfull && in_accept_o) begin
                // shadow not ready yet (only possible right at start-of-stream) -> gap
                wfull <= 1'b0; sbuf <= 4'd0; wlast <= 1'b0;
            end

            // Accumulate the shadow word from the byte stream. Gated by
            // in_ready(=!wfull_next), so this never overwrites a shadow
            // word that's still waiting to be promoted.
            if (take) begin
                case (bcnt)
                    2'd0: begin wbuf_next[ 7:0 ] <= in_byte; sbuf_next[0] <= 1'b1; end
                    2'd1: begin wbuf_next[15:8 ] <= in_byte; sbuf_next[1] <= 1'b1; end
                    2'd2: begin wbuf_next[23:16] <= in_byte; sbuf_next[2] <= 1'b1; end
                    2'd3: begin wbuf_next[31:24] <= in_byte; sbuf_next[3] <= 1'b1; end
                endcase
                if (bcnt == 2'd3 || in_last) begin
                    bcnt  <= 2'd0;
                    wfull_next <= 1'b1;
                    wlast_next <= in_last;
                end else begin
                    bcnt <= bcnt + 2'd1;
                end
            end
        end
    end

    //------------------------------------------------------------------------
    // Drain: block-order RGB -> FB writes (address by x,y)
    //------------------------------------------------------------------------
    wire        out_valid_o;
    wire [15:0] out_x, out_y, out_w, out_h;
    wire [7:0]  out_r, out_g, out_b;

    assign px_we        = out_valid_o & px_ready;
    assign px_x         = out_x;
    assign px_y         = out_y;
    assign px_r         = out_r;
    assign px_g         = out_g;
    assign px_b         = out_b;
    assign frame_width  = out_w;
    assign frame_height = out_h;

    // frame_done must be a PULSE, not a level: core_jpeg holds outport_valid_o asserted at the
    // final pixel, so a combinational compare would stay high and re-trigger downstream.
    reg frame_done_r;
    reg frame_done_seen_q;
    always @(posedge clk) begin
        if (rst) begin
            frame_done_r      <= 1'b0;
            frame_done_seen_q <= 1'b0;
        end else begin
            frame_done_r <= 1'b0;
            if (px_we && (out_x == (out_w - 16'd1)) && (out_y == (out_h - 16'd1))
                      && !frame_done_seen_q) begin
                frame_done_r      <= 1'b1;
                frame_done_seen_q <= 1'b1;
            end
        end
    end
    assign frame_done = frame_done_r;

    //------------------------------------------------------------------------
    // core_jpeg instance  (fixed standard Huffman tables)
    //------------------------------------------------------------------------
    jpeg_core #(.SUPPORT_WRITABLE_DHT(0)) u_jpeg
    (
        .clk_i           (clk),
        .rst_i           (rst),

        .inport_valid_i  (wfull),
        .inport_data_i   (wbuf),
    // Full strobe, and NEVER assert inport_last_i: jpeg_input.v force-jumps to STATE_IDLE on it
    // ("End of data stream" override), which aborts the decode and yields zero pixels.
        .inport_strb_i   (4'hF),
        .inport_last_i   (1'b0),
        .inport_accept_o (in_accept_o),

        .outport_accept_i(px_ready),
        .outport_valid_o (out_valid_o),
        .outport_width_o (out_w),
        .outport_height_o(out_h),
        .outport_pixel_x_o(out_x),
        .outport_pixel_y_o(out_y),
        .outport_pixel_r_o(out_r),
        .outport_pixel_g_o(out_g),
        .outport_pixel_b_o(out_b),

        .idle_o          (idle)
    );

endmodule
