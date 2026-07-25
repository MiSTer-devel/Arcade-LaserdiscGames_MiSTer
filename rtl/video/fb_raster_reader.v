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
    parameter [15:0] V_FP = 16'd8, V_SYNC = 16'd4,  V_BP = 16'd16,
    // RES-512x480-2026-07-24: ce_pix = clk / 2^CE_DIV_LOG2.  Was hardwired to clk/8, which at
    // 320x240 gave 384*280*8 = 860,160 cyc = 21.5 ms = 46.5 Hz.  At 512x480 the raster is
    // 576*520, so clk/8 would be 59.9 ms = 16.7 Hz -- BELOW the 23.938 fps content rate, i.e. we
    // would drop frames at the display.  clk/2 gives 14.98 ms = 66.8 Hz, comfortably above it.
    // This is also the BANDWIDTH DIAL: DDR read traffic scales directly with refresh rate, so if
    // 512x480 turns out to be bandwidth-starved, raise this to 3'd2 (clk/4 = 33.4 Hz) and halve
    // the read load before touching anything structural.
    parameter [2:0]  CE_DIV_LOG2 = 3'd3
)(
    input             clk,            // CLK_40M (= DDRAM_CLK)
    input             reset,          // active-high
    input      [26:0] frame_base_hw,  // DDR halfword base of the frame to display

    // ddram.sv read port 2
    output reg [26:0] rdaddr2,
    input      [15:0] dout2,
    input      [63:0] dout2_64,     // READ-COALESCE-2026-07-20: whole cached word (4 halfwords)
    output reg        rd_req2,
    input             rd_ack2,

    // WRITE-GATE-2026-07-16 (new port, no original to restore -- delete on revert): high while the
    // fill FSM is PARKED, i.e. this line's fetch already landed and is just waiting for the
    // end-of-line swap, so there is no read2 traffic in flight and fb_writer may use the DDR bus.
    // Low while a fetch is running => fb_writer must yield.  See fb_writer.v's matching tag.
    output            fill_idle,

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

    // pixel clock enable = clk / 2^CE_DIV_LOG2  (RES-512x480-2026-07-24; was hardwired clk/8).
    // The counter still free-runs over its full 3 bits; only the compare mask narrows, so
    // CE_DIV_LOG2=3 reproduces the original clk/8 exactly. Mask is built 4 bits wide first because
    // (3'd1 << 3) would wrap to 0 in 3 bits.
    localparam [3:0] CE_MASK4 = (4'd1 << CE_DIV_LOG2) - 4'd1;
    localparam [2:0] CE_MASK  = CE_MASK4[2:0];
    reg [2:0] cediv = 3'd0;
    always @(posedge clk) cediv <= cediv + 3'd1;
    assign ce_pix = ((cediv & CE_MASK) == 3'd0);

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
    // READ-COALESCE-2026-07-20: one DDR request now yields FOUR halfwords.
    // WHY: ddram.sv caches a 64-bit word per read port and dout2 slices ONE halfword out of it, so
    // the old one-request-per-pixel loop issued 320 requests/line where 80 suffice. dout2_64 (an
    // ADDITIVE output on ddram.sv, no behaviour change there) exposes the whole cached word, so we
    // request every 4th halfword and unpack locally.
    // ALIGNMENT (checked, load-bearing): STRIDE=320 and H_ACT=320 are both /4, and every framebuffer
    // base (0, 76800, 153600) is /4, so rdaddr2[2:1]==00 on every request we issue => ram_q2 holds
    // exactly linebuf[fidx..fidx+3], low halfword in bits [15:0]. If H_ACT or STRIDE ever stops
    // being a multiple of 4, or a base becomes unaligned, THIS BREAKS -- add a tail path first.
    // linebuf is single-write-port BRAM, so the 4 halfwords are stored over 4 cycles (F_ST1..3)
    // from a latched copy; that costs cycles but NOT DDR transactions, which is the point (it frees
    // arbiter bandwidth for fb_writer, whose px_ready is gated on this FSM being idle).
    localparam F_IDLE = 2'd0, F_REQ = 2'd1, F_WAIT = 2'd2, F_STORE = 2'd3;
    reg [1:0]  fst  = F_IDLE;
    reg [47:0] fw_hold;      // halfwords 1..3 awaiting store (hw0 is written directly on ack)
    reg [1:0]  fw_cnt;       // which of the remaining 3 is being stored
    reg [15:0] fw_idx;       // linebuf index for the current F_STORE write (named reg on purpose:
                             // Quartus 17 elaborates .v as Verilog-2001, where (expr)[8:0] is illegal)
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
            fw_hold <= 48'd0; fw_cnt <= 2'd0; fw_idx <= 16'd0;   // READ-COALESCE-2026-07-20
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
                if (rd_ack2 == rd_req2) begin               // dout2/dout2_64 valid
                    // READ-COALESCE-2026-07-20: store halfword 0 now, hold 1..3 for F_STORE.
                    linebuf[{fill_buf, fidx[8:0]}] <= dout2_64[15:0];
                    fw_hold <= dout2_64[63:16];
                    fw_cnt  <= 2'd0;
                    fw_idx  <= fidx + 16'd1;     // named reg: NO expression bit-select in a .v file
                    fst     <= F_STORE;
                end
            F_STORE: begin
                // write halfwords 1,2,3 of the fetched word on successive cycles
                linebuf[{fill_buf, fw_idx[8:0]}] <= fw_hold[15:0];
                fw_hold <= {16'd0, fw_hold[47:16]};
                fw_idx  <= fw_idx + 16'd1;
                if (fw_cnt == 2'd2) begin
                    if (fidx + 16'd4 >= H_ACT) begin        // whole line landed
                        fst         <= F_IDLE;
                        fill_done_q <= 1'b1;
                    end else begin
                        fidx <= fidx + 16'd4;
                        fst  <= F_REQ;
                    end
                end else begin
                    fw_cnt <= fw_cnt + 2'd1;
                end
            end
            default: fst <= F_IDLE;
            endcase
        end
    end

    // WRITE-GATE-2026-07-16: fill_done_q is set only when a line's fetch has fully landed, and the
    // F_IDLE state does nothing while it's high -- so it is exactly "the fill FSM is not touching
    // read2 right now".  (Delete this assign + the port on revert.)
    assign fill_idle = fill_done_q;

    assign vid_r = active_q ? {pix_q[15:11], pix_q[15:13]} : 8'd0;  // 5->8
    assign vid_g = active_q ? {pix_q[10:5],  pix_q[10:9]}  : 8'd0;  // 6->8
    assign vid_b = active_q ? {pix_q[4:0],   pix_q[4:2]}   : 8'd0;  // 5->8
endmodule
