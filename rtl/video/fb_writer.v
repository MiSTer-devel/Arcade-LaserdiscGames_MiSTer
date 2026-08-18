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
    parameter [15:0] CLEAR_COLOR    = 16'hFFFF,  // solid fill so any decoder write is unmistakable
    // FB-RANGE-GUARD-2026-07-20: visible framebuffer extent; writes outside are DISCARDED
    parameter [15:0] FB_COLS        = 16'd320,
    parameter [15:0] FB_ROWS        = 16'd240,
    // WRITE-COALESCE-2026-07-24 isolation switch. 1 = merge the 4 halfwords sharing a 64-bit DDR
    // word (19,200 writes/frame). 0 = one write per pixel, EXACTLY the prior behaviour (76,800),
    // with no code removed -- so a bad HW result is attributable by flipping this, not by reverting.
    parameter        COALESCE       = 1'b1
)(
    input             clk,          // DDRAM_CLK domain
    input             reset,        // active-high

    // FB-DOUBLEBUF-2026-07-15: halfword offset of the buffer to write, in the 0x30000000 region.
    // Was a fixed parameter; now a live input so the top level can ping-pong it per frame (see
    // Arcade-LaserdiscGames.sv fb_buf_sel) instead of writing into the same buffer the raster reader
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
    output reg [15:0] din,          // RGB565 (legacy; ddram no longer uses it for the write port)
    // WRITE-STAGE-A-2026-07-20: full 64-bit write word + byte enables, computed HERE instead of
    // inside ddram. Stage A drives EXACTLY what ddram used to derive (one halfword, 2 lanes
    // enabled) => provably identical DDR traffic and the same 76,800 writes/frame. It exists so
    // stage B can widen a write to 4 pixels without any further change to ddram.
    output reg [63:0] din64,
    output reg  [7:0] be64,
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
    // WRITE-COALESCE-2026-07-24: the decoder no longer stalls for EVERY write -- that is the whole
    // throughput win. A pixel is accepted while a DDR write is in flight whenever it does not need
    // the bus: either it merges into the group being accumulated (acc_hit), or the accumulator is
    // empty. Only a pixel belonging to a DIFFERENT 64-bit word must wait, since that forces a flush.
    // ORIGINAL (one stall per pixel), uncomment + set COALESCE=0 to revert:
    // assign px_ready = ~busy & ~clearing & fill_idle;
    // The new assign lives BELOW the coalescing wires it depends on -- Quartus 17 elaborates .v as
    // Verilog-2001, where using a net before its declaration is not reliable (already a known
    // sim-vs-synthesis divergence on this project), so declaration order here is load-bearing.

    // halfword index = base_hw + y*STRIDE_HW + x
    wire [26:0] hw_index = base_hw + (px_y * STRIDE_HW) + {11'd0, px_x};

    // WRITE-STAGE-A-2026-07-20: named wires -- Quartus 17 elaborates .v as Verilog-2001, where a
    // bit-select of an EXPRESSION, e.g. (base_hw+clear_idx)[1:0], is illegal (error 10170).
    wire [26:0] clear_addr = base_hw + clear_idx;
    wire [15:0] px565      = {px_r[7:3], px_g[7:2], px_b[7:3]};
    // byte enables for one halfword: 2 lanes, selected by the halfword's position in the 64-bit
    // word. Identical to ddram's old `8'd3<<{wraddr[2:1],1'b0}` because wraddr[2:1] == addr[1:0].
    wire  [7:0] be_pix     = 8'd3 << {hw_index[1:0],   1'b0};
    wire  [7:0] be_clr     = 8'd3 << {clear_addr[1:0], 1'b0};

    // ---- FB-RANGE-GUARD-2026-07-20 -----------------------------------------------------------
    // ROOT CAUSE OF THE TOP-OF-FRAME CORRUPTION (found in the full-subsystem co-sim, 2026-07-20).
    // The decoder emits MORE pixels than the frame contains: measured px_we up to 77,000 for a
    // 76,800-pixel frame, with **max_y = 255** on a 240-row image, 0 duplicates, all excess
    // out-of-range. Cause: 240 is not a multiple of 16, so the last 4:2:0 MCU row runs to y=255
    // and core_jpeg does not clip it to frame_height.
    // Consequence WITHOUT this guard: hw_index = base_hw + y*320 + x for y >= 240 runs PAST the
    // end of this buffer. Buffers are 76,800 halfwords apart, so those writes land at the START
    // of the NEXT buffer -- i.e. its TOP ROWS -- which is exactly the observed artifact:
    // MCU-aligned garbage in the first 16 rows, real decoded content (so it differs per frame),
    // and worse on Space Ace (135-200 stray px/frame) than Dragon's Lair (0-135).
    // Why every previous fix missed it: triple buffering, read coalescing and write batching all
    // change TIMING/BANDWIDTH; this is an ADDRESS-RANGE bug and none of them touch it.
    // Clipping here (rather than in core_jpeg) keeps the third-party decoder untouched.
    wire in_range = (px_x < FB_COLS) && (px_y < FB_ROWS);

    // ---- WRITE-COALESCE-2026-07-24 (5th attempt) ---------------------------------------------
    // 76,800 single-halfword DDR writes per frame, each a serialised we_req/we_ack round trip, is
    // the dominant term in decode latency (~41 ms of pure DDR latency at 20-cycle f2h latency --
    // the entire frame budget, before any decoding). Merging the 4 halfwords that share a 64-bit
    // word cuts that to 19,200 transactions. Measured previously: 934k -> 310k cycles, latency
    // tolerance ~10 -> ~25 cycles, px_ready duty 8.5% -> 25%.
    //
    // core_jpeg emits in 8x8 BLOCK order, so consecutive px_we events walk x by 1 for 8 pixels.
    // Blocks start on multiples of 8 and FB_COLS is a multiple of 4, so each block row yields
    // exactly two COMPLETE 4-halfword groups -- coalescing is a natural 4:1 here, not opportunistic.
    //
    // *** WHY THIS ATTEMPT IS WRITTEN DIFFERENTLY FROM THE FOUR THAT FAILED ***
    // All four previous versions passed every Verilator test and came back DEAD on hardware. Two
    // structural reasons, both now addressed:
    //  1. Their harness bypassed dlv_streamer, where the closed-loop dec_reset trap lived, so any
    //     transient stall they introduced became a permanent wedge that sim could not model. That
    //     trap is gone (WEDGE-WATCHDOG-2026-07-24) -- a stall now recovers and counts wd_trips.
    //  2. A slot-mask accumulator naturally wants to be written as a full-vector NBA plus a
    //     partial-select NBA to the SAME reg (acc_data <= 0; acc_data[slot*16 +: 16] <= px).
    //     Quartus 17 and the simulator do NOT agree on that construct, and it has already bitten
    //     this project once. So: EVERY register below gets EXACTLY ONE full-vector NBA, with the next
    //     value computed in combinational wires. The construct cannot occur.
    //
    // COALESCE=0 restores one-write-per-pixel exactly (every pixel forces a flush of the previous
    // single-pixel group) without removing any code -- the isolation switch, so a bad HW result can
    // be attributed with a parameter change instead of a revert.
    wire [24:0] px_grp  = hw_index[26:2];          // 64-bit word address
    wire [63:0] px_dat  = {4{px565}};              // replicated; be_pix selects the live lane
    wire [63:0] lane_m  = {{8{be_pix[7]}}, {8{be_pix[6]}}, {8{be_pix[5]}}, {8{be_pix[4]}},
                           {8{be_pix[3]}}, {8{be_pix[2]}}, {8{be_pix[1]}}, {8{be_pix[0]}}};
    reg  [63:0] acc_data;
    reg   [7:0] acc_be;
    reg  [24:0] acc_grp;
    reg         acc_valid;
    reg   [7:0] acc_idle;
    localparam [7:0] ACC_IDLE_MAX = 8'd255;        // tail flush; see below

    // px_we is (out_valid & px_ready), so px_ready must NOT depend on px_we or it forms a
    // combinational loop. px_grp comes from px_x/px_y, which the decoder drives independently of
    // px_ready, so gating on it is safe. When out_valid is low px_grp is don't-care and may assert
    // this stall spuriously -- harmless, no pixel is being offered, and it clears when busy does.
    wire        acc_hit   = acc_valid && (px_grp == acc_grp) && (COALESCE != 1'b0);
    wire        grp_diff  = acc_valid && !acc_hit;
    wire [63:0] acc_mrg   = (acc_data & ~lane_m) | (px_dat & lane_m);   // single expression
    wire        acc_take  = px_we && in_range;
    // Flush when an incoming pixel belongs to a different 64-bit word, or when the decoder has gone
    // quiet (the frame's LAST group never sees a group change, so it needs this). A mid-frame stall
    // longer than ACC_IDLE_MAX just flushes a partial group as a MASKED write -- correct, only
    // slightly less efficient, at most one extra write per raster line.
    wire        do_flush  = acc_valid && ((acc_take && grp_diff) || (acc_idle == ACC_IDLE_MAX));

    assign px_ready = ~clearing & fill_idle & ~(busy & grp_diff);

    always @(posedge clk) begin
        if (reset) begin
            busy      <= 1'b0;
            we_req    <= 1'b0;
            wraddr    <= 27'd0;
            din       <= 16'd0;
            din64     <= 64'd0;      // WRITE-STAGE-A-2026-07-20
            be64      <= 8'd0;
            // DIAG-REVERT-2026-07-04: arm the clear sweep on every reset
            clearing  <= CLEAR_ON_RESET;
            clear_idx <= 27'd0;
            acc_data  <= 64'd0;   // WRITE-COALESCE-2026-07-24
            acc_be    <= 8'd0;
            acc_grp   <= 25'd0;
            acc_valid <= 1'b0;
            acc_idle  <= 8'd0;
        end else if (clearing) begin
            // DIAG-REVERT-2026-07-04: fill FB_BASE_HW .. +CLEAR_WORDS-1 with CLEAR_COLOR, one halfword per
            // DDR write, reusing the exact we_req/we_ack handshake. Then drop 'clearing' and hand off below.
            if (!busy) begin
                wraddr <= clear_addr;
                din    <= CLEAR_COLOR;
                din64  <= {4{CLEAR_COLOR}};   // WRITE-STAGE-A: same value ddram used to replicate
                be64   <= be_clr;             //                same lanes ddram used to select
                we_req <= ~we_req;
                busy   <= 1'b1;
            end else if (we_ack == we_req) begin
                busy <= 1'b0;
                if (clear_idx == CLEAR_WORDS - 27'd1)
                    clearing <= 1'b0;
                else
                    clear_idx <= clear_idx + 27'd1;
            end
        end else begin
            // WRITE-COALESCE-2026-07-24. ORIGINAL one-write-per-pixel body, uncomment to revert
            // (and restore the px_ready assign above):
            // end else if (!busy) begin
            //     if (px_we && in_range) begin      // FB-RANGE-GUARD-2026-07-20
            //         wraddr <= hw_index;
            //         din    <= px565;
            //         din64  <= {4{px565}};
            //         be64   <= be_pix;
            //         we_req <= ~we_req;
            //         busy   <= 1'b1;
            //     end
            // end else if (we_ack == we_req) begin
            //     busy <= 1'b0;
            // end
            //
            // EVERY register below is written by exactly ONE full-vector NBA per branch -- no
            // partial-select assignment to a reg that also takes a whole-vector one. That construct
            // is where Verilator and Quartus 17 diverge, and it is the most likely reason four
            // sim-clean attempts came back dead on hardware.
            if (busy && (we_ack == we_req)) busy <= 1'b0;       // retire the in-flight write

            if (acc_take)                                    acc_idle <= 8'd0;
            else if (acc_valid && (acc_idle != ACC_IDLE_MAX)) acc_idle <= acc_idle + 8'd1;

            if (!busy && do_flush) begin
                wraddr    <= {acc_grp, 2'b00};                  // group -> halfword address
                din       <= acc_data[15:0];                    // legacy port, kept driven
                din64     <= acc_data;
                be64      <= acc_be;                            // masked: partial groups are safe
                we_req    <= ~we_req;
                busy      <= 1'b1;
                // this same cycle may also carry the first pixel of the NEXT group
                acc_valid <= acc_take;
                acc_grp   <= px_grp;
                acc_data  <= px_dat;
                acc_be    <= be_pix;
                acc_idle  <= 8'd0;
            end else if (acc_take) begin
                // merge into the open group, or open a new one. Needs no DDR either way, which is
                // why px_ready lets this happen while a write is still in flight.
                acc_valid <= 1'b1;
                acc_grp   <= px_grp;
                acc_data  <= acc_hit ? acc_mrg          : px_dat;
                acc_be    <= acc_hit ? (acc_be | be_pix) : be_pix;
            end
        end
    end
endmodule
