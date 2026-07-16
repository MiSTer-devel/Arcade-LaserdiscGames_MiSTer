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
    parameter [15:0] STRIDE_HW  = 16'd320,   // halfwords per row (= width for tight 16bpp)
    // DIAG-REVERT-2026-07-04: clear-FB-on-reset. Disambiguates "decoder wrote garbage" vs "decoder wrote
    // NOTHING and we're staring at uninitialised DDR" (DDR3 is NOT zeroed on power-up; banding is its natural
    // uninitialised signature). After this: solid CLEAR_COLOR = zero writes; any other pixels = it wrote them.
    // Set CLEAR_ON_RESET=0 to disable (exact prior behaviour). CLEAR_COLOR: white=FFFF, black=0000, magenta=F81F.
    parameter        CLEAR_ON_RESET = 1'b1,
    parameter [15:0] CLEAR_ROWS     = 16'd240,   // rows to pre-clear (= FB read region height)
    parameter [15:0] CLEAR_COLOR    = 16'hFFFF   // solid fill so any decoder write is unmistakable
)(
    input             clk,          // DDRAM_CLK domain
    input             reset,        // active-high

    // FB-DOUBLEBUF-2026-07-15: halfword offset of the buffer to write, in the 0x30000000 region.
    // Was a fixed parameter; now a live input so the top level can ping-pong it per frame (see
    // Arcade-DragonsLair.sv fb_buf_sel) instead of writing into the same buffer the raster reader
    // is scanning out of.
    input      [26:0] base_hw,

    // WRITE-GATE-2026-07-16 (new port, no original to restore -- delete on revert): from
    // fb_raster_reader.fill_idle.  High = the raster reader's line fetch has landed and it is not
    // using ddram.sv's read2 port, so we may write.  Low = it is fetching; yield the bus.
    input             fill_idle,

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

    // DIAG-REVERT-2026-07-04: clear-FB-on-reset sweep state (write-vs-no-write disambiguation)
    localparam [26:0] CLEAR_WORDS = STRIDE_HW * CLEAR_ROWS;   // 320*240 = 76800 halfwords
    reg         clearing;
    reg  [26:0] clear_idx;

    // DIAG-REVERT-2026-07-04: original 'assign px_ready = ~busy;' below; new line also stalls the
    // decoder drain (px_ready low) for the whole clear sweep so no pixel write can race the fill.
    // assign px_ready = ~busy;
    //
    // WRITE-GATE-2026-07-16 -- HYPOTHESIS, NOT A CONFIRMED FIX.  2026-07-04 line kept below;
    // uncomment it and delete the fill_idle line + port to revert.
    //
    // Theory being tested (fits the evidence, NOT proven -- ~30 HW builds have fit-and-failed
    // before, so treat with suspicion until HW says otherwise):
    //   ddram.sv CODE FACTS (verified by reading it, independent of this theory):
    //     - state 1 (write completion) does `cache_addr2 <= '1` UNCONDITIONALLY, with no compare
    //       against the write address => EVERY write invalidates the read2 cache.
    //     - state 0 checks we_req BEFORE rd_req2 => writes always win arbitration.
    //     - dout2 slices a 64-bit cached word 4 halfwords at a time + has a next-word prefetch,
    //       so an UNDISTURBED sequential line scan is ~3-of-4 one-cycle cache hits (fast).
    //   Hypothesised consequence: one DDR write per pixel x 76800/frame keeps we_req pending
    //   almost every cycle (starves read2) AND re-poisons cache_addr2 continuously (turns each
    //   surviving read into a full burst-2 miss).  Reader then can't finish a line inside its
    //   3072-cycle line-time, fb_raster_reader repeats the line, and repeated stalls accumulate
    //   into the progressive vertical stretch (mild top / severe bottom) seen on HW.  Consistent
    //   with static content being rock solid (no decode => no writes => cache stays hot).
    //
    // Why this is NOT the reverted DDR-YIELD-2026-07-15 idea (fixed idle cycle after each write,
    // HW result: "jittering is slightly worse"): that yielded blindly, on a timer, with no idea
    // whether the reader wanted the bus -- it bought a read that was GUARANTEED to miss (the
    // just-completed write had invalidated the cache) while stretching the write burst's
    // wall-clock, so it paid both costs and bought nothing.  This yields on the reader's ACTUAL
    // state instead: no write is ever issued while a line fetch is in flight, so a fetch runs with
    // a hot cache AND an uncontended arbiter -- addressing both mechanisms rather than one.
    //
    // Budget: reader needs ~1000-1500 of each 3072-cycle line, leaving ~1500/line x 268 lines
    // ~= 400K cycles/frame for writes vs the ~230-300K needed.  Failure mode is deliberately the
    // safe one: if the reader ever needs a whole line, the writer just starves and DECODE slows
    // (it runs ~8x real-time, see header) -- this cannot corrupt video, only slow the decoder.
    //
    // px_ready alone is sufficient to gate: jpeg_frame_decoder drives px_we = out_valid_o &
    // px_ready and ties core_jpeg's outport_accept_i to px_ready, so px_we structurally cannot
    // assert while this is low => no pixel can be dropped, the decoder just stalls.
    // assign px_ready = ~busy & ~clearing;
    assign px_ready = ~busy & ~clearing & fill_idle;

    // halfword index = base_hw + y*STRIDE_HW + x
    wire [26:0] hw_index = base_hw + (px_y * STRIDE_HW) + {11'd0, px_x};

    always @(posedge clk) begin
        if (reset) begin
            busy      <= 1'b0;
            we_req    <= 1'b0;
            wraddr    <= 27'd0;
            din       <= 16'd0;
            // DIAG-REVERT-2026-07-04: arm the clear sweep on every reset
            clearing  <= CLEAR_ON_RESET;
            clear_idx <= 27'd0;
        end else if (clearing) begin
            // DIAG-REVERT-2026-07-04: fill FB_BASE_HW .. +CLEAR_WORDS-1 with CLEAR_COLOR, one halfword per
            // DDR write, reusing the exact we_req/we_ack handshake. Then drop 'clearing' and hand off below.
            if (!busy) begin
                wraddr <= base_hw + clear_idx;
                din    <= CLEAR_COLOR;
                we_req <= ~we_req;
                busy   <= 1'b1;
            end else if (we_ack == we_req) begin
                busy <= 1'b0;
                if (clear_idx == CLEAR_WORDS - 27'd1)
                    clearing <= 1'b0;
                else
                    clear_idx <= clear_idx + 27'd1;
            end
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
