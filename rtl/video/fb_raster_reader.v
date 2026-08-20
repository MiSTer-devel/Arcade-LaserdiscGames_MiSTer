//============================================================================
// fb_raster_reader.v — DDR framebuffer -> raster video (for arcade_video)
//----------------------------------------------------------------------------
// Reads a 320x240 RGB565 framebuffer out of HPS DDR3 (written by fb_writer via
// ddram.sv) in RASTER scan order and produces a standard video raster
// (ce_pix + hs/vs/hblank/vblank + RGB888) to feed the core's normal
// arcade_video path.  This is the screenshot-friendly route: everything goes
// through the same core-video pipeline the LED band + capture already use
// (MISTER_FB is NOT used).
// DDR reads use ddram.sv's second read port (rdaddr2/dout2/rd_req2/rd_ack2 —
// 16-bit halfword, toggle handshake).  A ping-pong line buffer hides DDR
// latency: line N is displayed from one buffer while line N+1 is fetched into
// the other (a full line-time of slack, so timing is not tight).
// an intermediate version of this file cached two COMPLETE
// on-chip frame buffers (~150KB each) to avoid re-reading DDR every raster
// refresh -- reverted, way too much BRAM, and it was solving the wrong
// problem. The actual root cause (found the same session, user's diagnosis):
// dlv_streamer.v was redundantly re-fetching/re-decoding/re-writing the SAME
// mjpeg frame to DDR several times per real content frame (its 30Hz pacing
// tick didn't check whether the mapped frame had actually changed), hammering
// fb_writer and the DDR bus far more than a genuine ~24fps content rate ever
// would. That's fixed at the source now (see dlv_streamer.v, tag
// ) -- this file goes back to the cheap 2-line
// buffer, which only needs to keep up with genuine content updates now.
// The caller composites the LED band over the RGB output.  Instantiated
// feeding arcade_video #(320,24), frame_base_hw = the DDR halfword base of
// the frame to display (top level toggles this via fb_buf_sel).
//============================================================================
module fb_raster_reader #(
    parameter [15:0] H_ACT  = 16'd320,
    parameter [15:0] V_ACT  = 16'd240,
    parameter [15:0] STRIDE = 16'd320,     // halfwords per row (= H_ACT, tight)
    parameter [15:0] V_BAND = 16'd0,       // top strip reserved for the LED band.  Always counted in V_TOTAL;
                                           //   the v_band input picks how much of it is ACTIVE this frame.
                                           //   Rows 0..v_band-1 are forced black (the band composites there);
                                           //   rows v_band..v_band+V_ACT-1 show the FULL video (row R ->
                                           //   framebuffer row R-v_band).  Video is NEVER cropped/scaled.
    parameter [15:0] H_FP = 16'd8, H_SYNC = 16'd32, H_BP = 16'd24,
    parameter [15:0] V_FP = 16'd8, V_SYNC = 16'd4,  V_BP = 16'd16,
    // ce_pix = clk / 2^CE_DIV_LOG2.  Refresh must stay ABOVE the content frame rate, and the
    // reader must still fetch a whole line inside one line-time or the picture cuts off.
    parameter [2:0]  CE_DIV_LOG2 = 3'd3
)(
    input             clk,            // CLK_CORE (= DDRAM_CLK); 80 MHz as of
    input             reset,          // active-high
    input      [26:0] frame_base_hw,  // DDR halfword base of the frame to display
    input      [15:0] v_band,         // active band height: V_BAND (band on) or 0 (full screen).  V_TOTAL
                                      //   reserves V_BAND either way, so the frame time never changes.

    // ddram.sv read port 2
    output reg [26:0] rdaddr2,
    input      [15:0] dout2,
    input      [63:0] dout2_64,     // whole cached word (4 halfwords)
    output reg        rd_req2,
    input             rd_ack2,

    // High while the fill FSM is PARKED: this line's fetch has landed, so there is no read2
    // traffic in flight and fb_writer may use the DDR bus.
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
    // Total active rows = full video rows + the active band.  The video keeps ALL V_ACT rows
    // (never cropped/scaled); the band just adds active height above them.
    // V_TOTAL always reserves V_BAND rows, so switching the band off shrinks the active window
    // WITHOUT changing the frame time -- V_BP is tuned to sit just above the film tick, and a
    // shorter frame would repeat a frame every ~36 ticks (visible lurch).
    localparam [15:0] H_TOTAL = H_ACT + H_FP + H_SYNC + H_BP;
    localparam [15:0] V_TOTAL = V_ACT + V_BAND + V_FP + V_SYNC + V_BP;

    // Latched once per frame: a mid-frame OSD toggle must not move the active window under the raster.
    reg  [15:0] v_band_q = V_BAND;
    wire [15:0] v_disp   = V_ACT + v_band_q;

    // pixel clock enable = clk / 2^CE_DIV_LOG2  (RES-512x480-; was hardwired clk/8).
    // The counter still free-runs over its full 3 bits; only the compare mask narrows, so
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
    wire v_active = (vcnt < v_disp);   // active rows 0..v_disp-1 = band strip + full video

    // ping-pong line buffer: 2 lines, 512-halfword stride (matches the
    // {buf, hcnt[8:0]} / {buf, fidx[8:0]} index — H_ACT<=512).
    reg  [15:0] linebuf [0:1023];
    reg         disp_buf = 1'b0;
    wire        fill_buf = ~disp_buf;

    // Display read and the DDR fill FSM share fill_done_q, so they must live in one always block.
    reg [15:0] pix_q;
    reg        active_q;

    // ---- DDR fill FSM: fetch fline into fill_buf, self-paced ----
    // NOT tied to a one-line deadline -- under DDR write contention a fetch can overrun a line,
    // and the old once-per-line gate assumed it never would.
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

    // The fill FSM's content-row target (fline) is decoupled from raster timing so a stalled
    // fetch can be repeated instead of torn; resync_pending realigns it once per frame.
    reg        resync_pending;

    // Latch the buffer base once per raster frame: the top level toggles frame_base_hw live as
    // the decoder finishes frames, so reading it raw would tear a frame across two buffers.
    reg [26:0] frame_base_hw_q;

    always @(posedge clk) begin
        if (reset) begin
            hcnt <= 0; vcnt <= 0; disp_buf <= 1'b0;
            hsync <= 0; vsync <= 0; hblank <= 1; vblank <= 1; active_q <= 0;
            hpos <= 16'd0; vpos <= 16'd0;
            fst <= F_IDLE; fidx <= 16'd0; rd_req2 <= 1'b0; rdaddr2 <= 27'd0;
            frame_base_hw_q <= 27'd0;
            fline <= 16'd0; fill_done_q <= 1'b0; resync_pending <= 1'b0;
            fw_hold <= 48'd0; fw_cnt <= 2'd0; fw_idx <= 16'd0; v_band_q <= v_band;
        end else begin
            // ---- display timing (ce_pix-gated) ----
            if (ce_pix) begin
                // read this pixel and register the aligned timing flags
                pix_q    <= linebuf[{disp_buf, hcnt[8:0]}];
                active_q <= h_active & v_active & (vcnt >= v_band_q);  // reserved top strip -> black (LED band composites there)
                hpos     <= hcnt;   vpos <= vcnt;
                hblank   <= ~h_active;
                vblank   <= ~v_active;
                hsync    <= (hcnt >= H_ACT + H_FP) && (hcnt < H_ACT + H_FP + H_SYNC);
                vsync    <= (vcnt >= v_disp + V_FP) && (vcnt < v_disp + V_FP + V_SYNC);
                // advance counters -- raster/hsync/vsync timing ALWAYS advances on schedule,
                // independent of fetch progress (never stall the video timing itself, that's a
                // framework/HDMI risk).
                if (h_last) begin
                    hcnt <= 16'd0;
                    vcnt <= v_last ? 16'd0 : vcnt + 16'd1;
                    // only swap to the other buffer if its fetch actually
                    // finished. If still running, repeat the current line's content for one more
                    // line-time instead of tearing -- a rare stutter, not corruption.
                    if (fill_done_q) begin
                        disp_buf    <= ~disp_buf;
                        fill_done_q <= 1'b0;
                    end
                    if (v_last) begin
                        resync_pending <= 1'b1;   // request a resync, applied below when safe
                        v_band_q       <= v_band; // adopt an OSD toggle only at the frame boundary
                    end
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
                        // hard-realign to the new frame instead of continuing
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
                // display line `fline` shows framebuffer row (fline - v_band_q); rows inside the
                // active band (fline < v_band_q) fetch nothing (they're blanked to black anyway).
                if (fline >= v_band_q && (fline - v_band_q) < V_ACT) begin
                    rdaddr2 <= frame_base_hw_q + (fline - v_band_q)*STRIDE + fidx;
                    rd_req2 <= ~rd_req2;                    // issue read
                    fst     <= F_WAIT;
                end else begin
                    fst         <= F_IDLE;                  // band line or off-screen: nothing to fetch
                    fill_done_q <= 1'b1;
                end
            F_WAIT:
                if (rd_ack2 == rd_req2) begin               // dout2/dout2_64 valid
                    // store halfword 0 now, hold 1..3 for F_STORE.
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

    // fill_done_q is set only when a line's fetch has fully landed, and the
    // F_IDLE state does nothing while it's high -- so it is exactly "the fill FSM is not touching
    // read2 right now".  (Delete this assign + the port on revert.)
    assign fill_idle = fill_done_q;

    assign vid_r = active_q ? {pix_q[15:11], pix_q[15:13]} : 8'd0;  // 5->8
    assign vid_g = active_q ? {pix_q[10:5],  pix_q[10:9]}  : 8'd0;  // 6->8
    assign vid_b = active_q ? {pix_q[4:0],   pix_q[4:2]}   : 8'd0;  // 5->8
endmodule
