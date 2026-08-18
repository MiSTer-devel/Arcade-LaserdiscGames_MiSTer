//============================================================================
// fb_writer.v — framebuffer writer (decoder RGB pixels -> DDR3 via ddram.sv)
//----------------------------------------------------------------------------
// Takes the jpeg_frame_decoder pixel stream (block-order, with x/y) and writes
// RGB565 to the MISTER_FB framebuffer in HPS DDR3 through the write port of
// rtl/ram_rom/ddram.sv (Sorgelig, 16-bit: RAM based at 0x30000000, halfword
// address wraddr[27:1], toggle we_req/we_ack handshake).
// Address: the FB is 16bpp tight, so byte = FB_BASE + y*STRIDE + x*2, and the
// halfword index (what ddram.sv wants) = FB_BASE_HW + y*STRIDE_HW + x, where
// FB_BASE_HW/STRIDE_HW are in halfwords.  Put the FB at the base of ddram.sv's
// 0x30000000 region => FB_BASE_HW = 0, and set the top-level FB_BASE = 0x30000000.
// One DDR write per pixel (burst-1).  Decoder output is stalled via px_ready
// while a write is in flight.  ~77k px/frame * a few DDR cycles each is well
// under the 33 ms frame budget (decode itself is ~8x real-time).
// The scaler reads the FB independently (framework ascal), so this module only
// uses ddram.sv's WRITE port; the rom/read ports stay for ROM caching if ever
// needed.  NOT yet instantiated at top.
//============================================================================
module fb_writer #(
    parameter [15:0] STRIDE_HW  = 16'd320,   // halfwords per row (= width for tight 16bpp)
    // Clear the framebuffer on reset -- DDR3 is not zeroed at power-up, and its uninitialised
    // banding is otherwise indistinguishable from decoder output.
    parameter        CLEAR_ON_RESET = 1'b1,
    parameter [15:0] CLEAR_ROWS     = 16'd240,   // rows to pre-clear (= FB read region height)
    parameter [15:0] CLEAR_COLOR    = 16'hFFFF,  // solid fill so any decoder write is unmistakable
    // visible framebuffer extent; writes outside are DISCARDED
    parameter [15:0] FB_COLS        = 16'd320,
    parameter [15:0] FB_ROWS        = 16'd240,
    // isolation switch. 1 = merge the 4 halfwords sharing a 64-bit DDR
    // word (19,200 writes/frame). 0 = one write per pixel, EXACTLY the prior behaviour (76,800),
    // with no code removed -- so a bad HW result is attributable by flipping this, not by reverting.
    parameter        COALESCE       = 1'b1
)(
    input             clk,          // DDRAM_CLK domain
    input             reset,        // active-high

    // Halfword offset of the buffer to write: a live input so the top level can ping-pong it.
    input      [26:0] base_hw,

    // (new port, no original to restore -- delete on revert): from
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
    // Full 64-bit write word + byte enables are computed here rather than inside ddram.
    output reg [63:0] din64,
    output reg  [7:0] be64,
    output reg        we_req,       // toggle to request a write
    input             we_ack        // ddram raises to == we_req when done
);
    reg busy;

    // clear-FB-on-reset sweep state (write-vs-no-write disambiguation)
    localparam [26:0] CLEAR_WORDS = STRIDE_HW * CLEAR_ROWS;   // 320*240 = 76800 halfwords
    reg         clearing;
    reg  [26:0] clear_idx;

    // Hold the decoder off (px_ready low) for the whole clear sweep so no pixel write can race
    // the fill, and gate on fill_idle so the writer never contends with an in-flight read2.

    // halfword index = base_hw + y*STRIDE_HW + x
    wire [26:0] hw_index = base_hw + (px_y * STRIDE_HW) + {11'd0, px_x};

    // named wires -- Quartus 17 elaborates .v as Verilog-2001, where a
    // bit-select of an EXPRESSION, e.g. (base_hw+clear_idx)[1:0], is illegal (error 10170).
    wire [26:0] clear_addr = base_hw + clear_idx;
    wire [15:0] px565      = {px_r[7:3], px_g[7:2], px_b[7:3]};
    // byte enables for one halfword: 2 lanes, selected by the halfword's position in the 64-bit
    // word. Identical to ddram's old `8'd3<<{wraddr[2:1],1'b0}` because wraddr[2:1] == addr[1:0].
    wire  [7:0] be_pix     = 8'd3 << {hw_index[1:0],   1'b0};
    wire  [7:0] be_clr     = 8'd3 << {clear_addr[1:0], 1'b0};

    // The decoder emits MORE pixels than the frame contains, so writes must be range-checked or
    // the overflow corrupts the top of the next frame.
    wire in_range = (px_x < FB_COLS) && (px_y < FB_ROWS);

    // ---- write coalescing ----
    // 76,800 single-halfword DDR round trips per frame dominate decode latency, so accumulate a
    // full 64-bit word and issue one masked write per group of 4 pixels.
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

    // px_ready must NOT depend on px_we or it forms a combinational loop; px_grp comes from
    // px_x/px_y, which the decoder drives independently.
    wire        acc_hit   = acc_valid && (px_grp == acc_grp) && (COALESCE != 1'b0);
    wire        grp_diff  = acc_valid && !acc_hit;
    wire [63:0] acc_mrg   = (acc_data & ~lane_m) | (px_dat & lane_m);   // single expression
    wire        acc_take  = px_we && in_range;
    // Flush when an incoming pixel belongs to a different 64-bit word, or when the decoder goes
    // quiet -- the frame's LAST group never sees a group change.
    wire        do_flush  = acc_valid && ((acc_take && grp_diff) || (acc_idle == ACC_IDLE_MAX));

    assign px_ready = ~clearing & fill_idle & ~(busy & grp_diff);

    always @(posedge clk) begin
        if (reset) begin
            busy      <= 1'b0;
            we_req    <= 1'b0;
            wraddr    <= 27'd0;
            din       <= 16'd0;
            din64     <= 64'd0;
            be64      <= 8'd0;
            // arm the clear sweep on every reset
            clearing  <= CLEAR_ON_RESET;
            clear_idx <= 27'd0;
            acc_data  <= 64'd0;
            acc_be    <= 8'd0;
            acc_grp   <= 25'd0;
            acc_valid <= 1'b0;
            acc_idle  <= 8'd0;
        end else if (clearing) begin
            // fill FB_BASE_HW .. +CLEAR_WORDS-1 with CLEAR_COLOR, one halfword per
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
            // Every register below is written by exactly ONE full-vector NBA per branch: mixing a
            // partial-select assignment with a whole-vector one is where Verilator and Quartus 17
            // diverge.
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
