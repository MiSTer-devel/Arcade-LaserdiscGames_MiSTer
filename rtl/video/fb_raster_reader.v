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
// The caller composites the LED band over the RGB output.  NOT yet wired —
// instantiate feeding arcade_video #(320,24), frame_base_hw = the DDR halfword
// base of the frame to display.
//============================================================================
module fb_raster_reader #(
    parameter [15:0] H_ACT  = 16'd320,
    parameter [15:0] V_ACT  = 16'd240,
    parameter [15:0] STRIDE = 16'd320,     // halfwords per row (= H_ACT, tight)
    parameter [15:0] V_BAND = 16'd0,       // LAYOUT-2026-07-04: reserved top strip for the LED band.
                                           //   Display rows 0..V_BAND-1 are forced black (band lives there);
                                           //   video is shifted DOWN — display row R shows framebuffer row R-V_BAND
                                           //   (bottom V_BAND rows of the frame are cropped). V_BAND=0 => old behaviour.
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
    localparam [15:0] H_TOTAL = H_ACT + H_FP + H_SYNC + H_BP;
    localparam [15:0] V_TOTAL = V_ACT + V_FP + V_SYNC + V_BP;

    // pixel clock enable = clk/8 (~5 MHz)
    reg [2:0] cediv = 3'd0;
    always @(posedge clk) cediv <= cediv + 3'd1;
    assign ce_pix = (cediv == 3'd0);

    // raster counters
    reg [15:0] hcnt = 16'd0, vcnt = 16'd0;
    wire h_last = (hcnt == H_TOTAL - 16'd1);
    wire v_last = (vcnt == V_TOTAL - 16'd1);
    wire h_active = (hcnt < H_ACT);
    wire v_active = (vcnt < V_ACT);

    // ping-pong line buffer: 2 lines, 512-halfword stride (matches the
    // {buf, hcnt[8:0]} / {buf, fidx[8:0]} index — H_ACT<=512).
    reg  [15:0] linebuf [0:1023];
    reg         disp_buf = 1'b0;
    wire        fill_buf = ~disp_buf;

    // display read (registered BRAM read) + aligned timing
    reg [15:0] pix_q;
    reg        active_q;
    always @(posedge clk) begin
        if (reset) begin
            hcnt <= 0; vcnt <= 0; disp_buf <= 1'b0;
            hsync <= 0; vsync <= 0; hblank <= 1; vblank <= 1; active_q <= 0;
            hpos <= 16'd0; vpos <= 16'd0;
        end else if (ce_pix) begin
            // read this pixel and register the aligned timing flags
            pix_q    <= linebuf[{disp_buf, hcnt[8:0]}];
            active_q <= h_active & v_active & (vcnt >= V_BAND);  // reserved top strip -> black (LED band composites there)
            hpos     <= hcnt;   vpos <= vcnt;
            hblank   <= ~h_active;
            vblank   <= ~v_active;
            hsync    <= (hcnt >= H_ACT + H_FP) && (hcnt < H_ACT + H_FP + H_SYNC);
            vsync    <= (vcnt >= V_ACT + V_FP) && (vcnt < V_ACT + V_FP + V_SYNC);
            // advance counters (+ swap the displayed buffer at end of line)
            if (h_last) begin
                hcnt <= 16'd0;
                vcnt <= v_last ? 16'd0 : vcnt + 16'd1;
                disp_buf <= ~disp_buf;
            end else begin
                hcnt <= hcnt + 16'd1;
            end
        end
    end

    assign vid_r = active_q ? {pix_q[15:11], pix_q[15:13]} : 8'd0;  // 5->8
    assign vid_g = active_q ? {pix_q[10:5],  pix_q[10:9]}  : 8'd0;  // 6->8
    assign vid_b = active_q ? {pix_q[4:0],   pix_q[4:2]}   : 8'd0;  // 5->8

    // ---- DDR fill FSM: fetch line (vcnt+1) into fill_buf, one line ahead ----
    // start-of-line pulse (hcnt just wrapped to 0)
    reg [15:0] hcnt_d;
    always @(posedge clk) if (ce_pix) hcnt_d <= hcnt;
    wire new_line = ce_pix && (hcnt == 16'd0) && (hcnt_d != 16'd0);

    localparam F_IDLE = 2'd0, F_REQ = 2'd1, F_WAIT = 2'd2;
    reg [1:0]  fst  = F_IDLE;
    reg [15:0] fidx;
    reg [15:0] fline;

    always @(posedge clk) begin
        if (reset) begin
            fst <= F_IDLE; fidx <= 16'd0; rd_req2 <= 1'b0; rdaddr2 <= 27'd0;
        end else begin
            case (fst)
            F_IDLE:
                if (new_line) begin
                    fline <= v_last ? 16'd0 : vcnt + 16'd1;  // next display line
                    fidx  <= 16'd0;
                    fst   <= F_REQ;
                end
            F_REQ:
                // display line `fline` shows framebuffer row (fline - V_BAND); rows inside the
                // reserved band (fline < V_BAND) fetch nothing (they're blanked to black anyway).
                if (fline >= V_BAND && (fline - V_BAND) < V_ACT) begin
                    rdaddr2 <= frame_base_hw + (fline - V_BAND)*STRIDE + fidx;
                    rd_req2 <= ~rd_req2;                    // issue read
                    fst     <= F_WAIT;
                end else begin
                    fst <= F_IDLE;                          // band line or off-screen: no fetch
                end
            F_WAIT:
                if (rd_ack2 == rd_req2) begin               // dout2 valid
                    linebuf[{fill_buf, fidx[8:0]}] <= dout2;
                    if (fidx == H_ACT - 16'd1) fst <= F_IDLE;
                    else begin fidx <= fidx + 16'd1; fst <= F_REQ; end
                end
            default: fst <= F_IDLE;
            endcase
        end
    end
endmodule
