//============================================================================
// jpeg_frame_decoder.v  --  DL/SA/TQ in-fabric MJPEG frame decoder wrapper
//----------------------------------------------------------------------------
// Thin adapter around ultraembedded/core_jpeg (Apache-2.0, rtl/video/core_jpeg).
// It turns a *byte* stream of one baseline JPEG frame (fed by the SDRAM ring /
// block streamer, TBD) into core_jpeg's 32-bit AXI-Stream input, and turns
// core_jpeg's 8x8-block-order RGB888 output into framebuffer pixel writes.
//
// Our stream is frozen: baseline, 4:2:0 (yuvj420p), standard Huffman
// (-huffman default), so SUPPORT_WRITABLE_DHT=0 (built-in tables, smaller/fast).
// core_jpeg does NOT support restart markers -> our ffmpeg encode emits none.
//
// IMPORTANT: core_jpeg emits pixels in 8x8-BLOCK order, not raster. The FB
// write MUST address by {px_x,px_y} (provided per pixel), never a linear count.
//
// Byte packing (verified vs jpeg_input.v:93-96): first JPEG byte -> data[7:0],
// then [15:8], [23:16], [31:24]; strb marks valid lanes on a partial final word.
//
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
    // FIX-2026-07-15: double-buffered (shadow-word) packer. jpeg_input.v's
    // SOF0/DQT/DHT header-field captures are LEVEL-sensitive on state_q, not
    // gated on inport_valid_i (e.g. `else if (state_q==STATE_SOF_LENH)
    // length_q <= {data_r,8'b0};` — no valid check). That design implicitly
    // assumes a GAPLESS producer (true for FPGAmp's AXI-DMA source). Our old
    // single-buffer packer asserted in_ready=!wfull, so it stopped accepting
    // new bytes the instant a word became full and only resumed once the
    // core drained it — a real multi-cycle gap in inport_valid_i at EVERY
    // 4-byte word boundary while the shadow word refills from the byte-
    // serial source. Verilator co-sim (verilator/jpeg_decode/, 2026-07-15)
    // proved this corrupts header parsing: SOF0's length_q sampled the
    // marker's own stale 0xC0 byte instead of the length field, capturing
    // 0xFFFE (a huge bogus length); STATE_SOF_DATA's idx_q then free-runs
    // 0..63 forever, repeatedly re-latching img_width_q/img_height_q from
    // whatever unrelated byte is passing by, and the decoder never reaches
    // DHT/entropy data -> frame_done never fires, zero pixels ever written.
    // This is not a Quartus-only artifact; the real dlv_streamer/SD path
    // can't guarantee gapless supply either, so this likely explains the
    // original HW hang too, not just the sim reproduction.
    //
    // Old single-buffer packer (kept for reference/diff, do not restore):
    // reg  [1:0]  bcnt;
    // reg  [31:0] wbuf;
    // reg  [3:0]  sbuf;
    // reg         wlast;
    // reg         wfull;
    // wire in_accept_o;
    // wire take = in_valid && in_ready;
    // assign in_ready = !wfull;
    // always @(posedge clk) begin
    //     if (rst) begin
    //         bcnt <= 2'd0; wbuf <= 32'd0; sbuf <= 4'd0; wfull <= 1'b0; wlast <= 1'b0;
    //     end else begin
    //         if (wfull && in_accept_o) begin
    //             wfull <= 1'b0; sbuf <= 4'd0; wlast <= 1'b0;
    //         end
    //         if (take) begin
    //             case (bcnt)
    //                 2'd0: begin wbuf[ 7:0 ] <= in_byte; sbuf[0] <= 1'b1; end
    //                 2'd1: begin wbuf[15:8 ] <= in_byte; sbuf[1] <= 1'b1; end
    //                 2'd2: begin wbuf[23:16] <= in_byte; sbuf[2] <= 1'b1; end
    //                 2'd3: begin wbuf[31:24] <= in_byte; sbuf[3] <= 1'b1; end
    //             endcase
    //             if (bcnt == 2'd3 || in_last) begin
    //                 bcnt  <= 2'd0; wfull <= 1'b1; wlast <= in_last;
    //             end else begin
    //                 bcnt <= bcnt + 2'd1;
    //             end
    //         end
    //     end
    // end
    //
    // New double-buffered packer: wbuf is the word PRESENTED to the core
    // (inport_valid_i=wfull); wbuf_next is a SHADOW word accumulated from
    // the byte stream while wbuf is still being drained. The instant the
    // core accepts wbuf, wbuf_next (already full, since it had the same
    // ~4 cycles to fill as the core took to drain wbuf) is promoted with
    // ZERO gap cycles. in_ready now reflects the shadow slot, so bytes
    // keep flowing continuously instead of stalling every 4th byte.
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

    // FRAME-DONE-PULSE-FIX-2026-07-15: was a pure combinational `assign frame_done = px_we &&
    // (out_x==out_w-1) && (out_y==out_h-1)` -- a LEVEL condition, not a pulse. core_jpeg's output
    // handshake holds outport_valid_o (hence px_we, once accepted) asserted at the final pixel
    // across however many cycles fb_writer's px_ready backpressure takes to actually accept it,
    // and/or a few pipeline-settling cycles at end-of-frame -- each one re-satisfies this
    // condition, re-firing frame_done multiple times (confirmed on hardware: ~5-7x per real
    // decode, diagnosed by an external review after this project's own pacing-timer investigation
    // came up clean). fb_buf_sel (Arcade-DragonsLair.sv) toggles the DDR front/back buffer on
    // every frame_done pulse, so this was flipping buffers several times per actual decoded frame
    // instead of once -- root cause of the "moving content is a mess" bug chased through most of
    // 2026-07-15 (arbitration reorder, double-buffering, fill-stall, resync, redundant-redraw --
    // all real, all necessary, none of them were THIS bug).
    // Fix: latch "already signalled done for this decode" (frame_done_seen_q), cleared only by
    // rst (asserted once per real decode request, see dlv_streamer.v dec_reset). Guarantees
    // frame_done pulses at most once between resets, however many times the underlying condition
    // re-satisfies. (A plain one-cycle-delayed register of the same condition, without this latch,
    // would NOT fix it -- it would still re-pulse once per re-satisfaction, just cleaner-edged.)
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
        // DIAG-REVERT-2026-07-04: match FPGAmp's proven feed of jpeg_core — full strobe + NEVER assert
        // inport_last_i. jpeg_input.v force-jumps to STATE_IDLE whenever inport_last_i is asserted
        // ("End of data stream" override), which aborts decode -> zero pixels (solid-white FB on HW).
        // The JPEG's own EOI marker (FF D9, present in every frame) terminates decode instead.
        // .inport_strb_i   (sbuf),
        // .inport_last_i   (wlast),
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
