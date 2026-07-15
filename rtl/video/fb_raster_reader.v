//============================================================================
// fb_raster_reader.v — DDR framebuffer -> raster video (for arcade_video)
//----------------------------------------------------------------------------
// Reads a 320x240 RGB565 framebuffer out of HPS DDR3 (written by fb_writer via
// ddram.sv) in RASTER scan order and produces a standard video raster
// (ce_pix + hs/vs/hblank/vblank + RGB888) to feed the core's normal
// arcade_video path.  This is the screenshot-friendly route: everything goes
// through the same core-video pipeline the LED band + capture already use
// (MISTER_FB is NOT used).
//
// DDR reads use ddram.sv's second read port (rdaddr2/dout2/rd_req2/rd_ack2 —
// 16-bit halfword, toggle handshake).  A ping-pong line buffer hides DDR
// latency: line N is displayed from one buffer while line N+1 is fetched into
// the other (a full line-time of slack, so timing is not tight).
//
// REVERT-2026-07-15: an intermediate version of this file cached two COMPLETE
// on-chip frame buffers (~150KB each) to avoid re-reading DDR every raster
// refresh -- reverted, way too much BRAM, and it was solving the wrong
// problem. The actual root cause (found the same session, user's diagnosis):
// dlv_streamer.v was redundantly re-fetching/re-decoding/re-writing the SAME
// mjpeg frame to DDR several times per real content frame (its 30Hz pacing
// tick didn't check whether the mapped frame had actually changed), hammering
// fb_writer and the DDR bus far more than a genuine ~24fps content rate ever
// would. That's fixed at the source now (see dlv_streamer.v, tag
// REDUNDANT-REDRAW-FIX-2026-07-15) -- this file goes back to the cheap 2-line
// buffer, which only needs to keep up with genuine content updates now.
//
// The caller composites the LED band over the RGB output.  Instantiated
// feeding arcade_video #(320,24), frame_base_hw = the DDR halfword base of
// the frame to display (top level toggles this via fb_buf_sel).
//============================================================================
module fb_raster_reader #(
    parameter [15:0] H_ACT  = 16'd320,
    parameter [15:0] V_ACT  = 16'd240,
    parameter [15:0] STRIDE = 16'd320,     // halfwords per row (= H_ACT, tight)
    parameter [15:0] V_BAND = 16'd0,       // LAYOUT-2026-07-04 (Option B, grow canvas): reserved top strip for the LED band.
                                           //   Total active height becomes V_ACT + V_BAND.  Display rows 0..V_BAND-1 are
                                           //   forced black (band lives there); rows V_BAND..V_BAND+V_ACT-1 show the FULL
                                           //   video (row R -> framebuffer row R-V_BAND).  Video is NEVER cropped/scaled.
                                           //   V_BAND=0 => old behaviour (no band).
    parameter [15:0] H_FP = 16'd8, H_SYNC = 16'd32, H_BP = 16'd24,
    parameter [15:0] V_FP = 16'd8, V_SYNC = 16'd4,  V_BP = 16'd16
)(
    input             clk,            // CLK_40M (= DDRAM_CLK)
    input             reset,          // active-high
    input      [26:0] frame_base_hw,  // DDR halfword base of the frame to display

    // ddram.sv read port 2
    output reg [26:0] rdaddr2,
    input      [15:0] dout2,
    output reg        rd_req2,
    input             rd_ack2,

    // video raster out (-> arcade_video)
    output            ce_pix,
    output reg        hsync,
    output reg        vsync,
    output reg        hblank,
    output reg        vblank,
    output reg [15:0] hpos,           // aligned (x,y) of the pixel now on vid_*
    output reg [15:0] vpos,           //   (for the LED-band compositor)
    output     [7:0]  vid_r,
    output     [7:0]  vid_g,
    output     [7:0]  vid_b
);
    // Option B (grow canvas): total active rows = full video rows + the reserved band.  The video
    // keeps ALL V_ACT rows (never cropped/scaled); the band just adds V_BAND rows of active height.
    localparam [15:0] V_DISP  = V_ACT + V_BAND;
    localparam [15:0] H_TOTAL = H_ACT + H_FP + H_SYNC + H_BP;
    localparam [15:0] V_TOTAL = V_DISP + V_FP + V_SYNC + V_BP;

    // pixel clock enable = clk/8 (~5 MHz)
    reg [2:0] cediv = 3'd0;
    always @(posedge clk) cediv <= cediv + 3'd1;
    assign ce_pix = (cediv == 3'd0);

    // raster counters
    reg [15:0] hcnt = 16'd0, vcnt = 16'd0;
    wire h_last = (hcnt == H_TOTAL - 16'd1);
    wire v_last = (vcnt == V_TOTAL - 16'd1);
    wire h_active = (hcnt < H_ACT);
    wire v_active = (vcnt < V_DISP);   // active rows 0..V_DISP-1 = band strip + full video (Option B)

    // ping-pong line buffer: 2 lines, 512-halfword stride (matches the
    // {buf, hcnt[8:0]} / {buf, fidx[8:0]} index — H_ACT<=512).
    reg  [15:0] linebuf [0:1023];
    reg         disp_buf = 1'b0;
    wire        fill_buf = ~disp_buf;

    // display read (registered BRAM read) + aligned timing, MERGED with the DDR fill FSM below into
    // one always block -- FILL-STALL-FIX-2026-07-15: fill_done_q is shared state between the two
    // (display consumes/clears it, fill FSM sets it), and Verilog requires a reg to be written from
    // exactly one always block -- can't split them and assign fill_done_q from both.
    reg [15:0] pix_q;
    reg        active_q;

    // ---- DDR fill FSM state: fetch fline into fill_buf, self-paced (NOT tied to a one-line
    // deadline). Previously gated on a once-per-raster-line pulse and always targeted `vcnt+1` --
    // i.e. assumed the fetch would always finish inside one line-time. Under DDR write contention
    // that assumption could fail, and the old unconditional end-of-line buffer swap then exposed a
    // half-filled buffer -- the black-line-comb bug. Now the FSM keeps fetching the SAME target for
    // as long as it takes (it doesn't return to F_IDLE until done, so it's immune to line-boundary
    // pressure) and the swap below only fires once fill_done_q confirms the target actually landed.
    // Worst case under contention: a line repeats for a few extra line-times -- never a torn buffer.
    localparam F_IDLE = 2'd0, F_REQ = 2'd1, F_WAIT = 2'd2;
    reg [1:0]  fst  = F_IDLE;
    reg [15:0] fidx;
    reg [15:0] fline;
    reg        fill_done_q;    // 1 once fline's data is fully loaded into fill_buf, awaiting the swap below
    wire [15:0] fline_next = (fline == V_TOTAL - 16'd1) ? 16'd0 : fline + 16'd1;

    // VSYNC-RESYNC-2026-07-15: the fill FSM's content-row target (fline) runs decoupled from raster
    // timing (vcnt) so a stalled fetch can be repeated instead of torn -- but with no periodic
    // resync, any single stall would permanently offset fline's own wrap point from vcnt's forever
    // after (both free-run mod V_TOTAL independently). Force a hard resync once per raster frame
    // (`resync_pending`, set on `v_last`). Applied ONLY at F_IDLE with no fetch outstanding -- never
    // abandons an unacknowledged rd_req2 mid-flight, which would desync ddram.sv's toggle handshake
    // (stock third-party file, must not be touched, and its protocol must not be violated from our
    // side either) -- so at most one halfword's delay before it takes effect, never unbounded drift.
    reg        resync_pending;

    // FB-DOUBLEBUF-2026-07-15: latch the buffer base once per raster frame, tied to the same
    // resync_pending pulse above -- not the raw frame_base_hw port, which the top level toggles live
    // as the decoder finishes frames (see Arcade-DragonsLair.sv fb_buf_sel). Without this latch,
    // frame_base_hw could flip mid-scan and different lines of the SAME displayed frame would be
    // fetched from two different buffers -- root cause of the original black-line-comb bug:
    // fb_writer and this reader used to share one hardcoded buffer with no swap at all.
    reg [26:0] frame_base_hw_q;

    always @(posedge clk) begin
        if (reset) begin
            hcnt <= 0; vcnt <= 0; disp_buf <= 1'b0;
            hsync <= 0; vsync <= 0; hblank <= 1; vblank <= 1; active_q <= 0;
            hpos <= 16'd0; vpos <= 16'd0;
            fst <= F_IDLE; fidx <= 16'd0; rd_req2 <= 1'b0; rdaddr2 <= 27'd0;
            frame_base_hw_q <= 27'd0;
            fline <= 16'd0; fill_done_q <= 1'b0; resync_pending <= 1'b0;
        end else begin
            // ---- display timing (ce_pix-gated) ----
            if (ce_pix) begin
                // read this pixel and register the aligned timing flags
                pix_q    <= linebuf[{disp_buf, hcnt[8:0]}];
                active_q <= h_active & v_active & (vcnt >= V_BAND);  // reserved top strip -> black (LED band composites there)
                hpos     <= hcnt;   vpos <= vcnt;
                hblank   <= ~h_active;
                vblank   <= ~v_active;
                hsync    <= (hcnt >= H_ACT + H_FP) && (hcnt < H_ACT + H_FP + H_SYNC);
                vsync    <= (vcnt >= V_DISP + V_FP) && (vcnt < V_DISP + V_FP + V_SYNC);
                // advance counters -- raster/hsync/vsync timing ALWAYS advances on schedule,
                // independent of fetch progress (never stall the video timing itself, that's a
                // framework/HDMI risk).
                if (h_last) begin
                    hcnt <= 16'd0;
                    vcnt <= v_last ? 16'd0 : vcnt + 16'd1;
                    // FILL-STALL-FIX-2026-07-15: only swap to the other buffer if its fetch actually
                    // finished. If still running, repeat the current line's content for one more
                    // line-time instead of tearing -- a rare stutter, not corruption.
                    if (fill_done_q) begin
                        disp_buf    <= ~disp_buf;
                        fill_done_q <= 1'b0;
                    end
                    if (v_last) resync_pending <= 1'b1;   // VSYNC-RESYNC-2026-07-15: request a resync, applied below when safe
                end else begin
                    hcnt <= hcnt + 16'd1;
                end
            end

            // ---- DDR fill FSM (runs every clk, not just ce_pix -- needs the full bandwidth) ----
            case (fst)
            F_IDLE:
                if (!fill_done_q) begin
                    fidx <= 16'd0;
                    fst  <= F_REQ;
                    if (resync_pending) begin
                        // VSYNC-RESYNC-2026-07-15: hard-realign to the new frame instead of continuing
                        // fline's own (possibly drifted) sequence -- fline=1 matches the steady-state
                        // "always one row ahead of what's on screen" convention used elsewhere.
                        fline           <= 16'd1;
                        frame_base_hw_q <= frame_base_hw;
                        resync_pending  <= 1'b0;
                    end else begin
                        fline <= fline_next;
                    end
                end
            F_REQ:
                // display line `fline` shows framebuffer row (fline - V_BAND); rows inside the
                // reserved band (fline < V_BAND) fetch nothing (they're blanked to black anyway).
                if (fline >= V_BAND && (fline - V_BAND) < V_ACT) begin
                    rdaddr2 <= frame_base_hw_q + (fline - V_BAND)*STRIDE + fidx;
                    rd_req2 <= ~rd_req2;                    // issue read
                    fst     <= F_WAIT;
                end else begin
                    fst         <= F_IDLE;                  // band line or off-screen: nothing to fetch
                    fill_done_q <= 1'b1;
                end
            F_WAIT:
                if (rd_ack2 == rd_req2) begin               // dout2 valid
                    linebuf[{fill_buf, fidx[8:0]}] <= dout2;
                    if (fidx == H_ACT - 16'd1) begin
                        fst         <= F_IDLE;
                        fill_done_q <= 1'b1;
                    end else begin
                        fidx <= fidx + 16'd1;
                        fst  <= F_REQ;
                    end
                end
            default: fst <= F_IDLE;
            endcase
        end
    end

    assign vid_r = active_q ? {pix_q[15:11], pix_q[15:13]} : 8'd0;  // 5->8
    assign vid_g = active_q ? {pix_q[10:5],  pix_q[10:9]}  : 8'd0;  // 6->8
    assign vid_b = active_q ? {pix_q[4:0],   pix_q[4:2]}   : 8'd0;  // 5->8
endmodule
