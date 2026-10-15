//============================================================================
//
//  sdram_phase_ctl.sv — steps the SDRAM_CLK PLL counter through sys/pll_cfg
//  (dynamic phase shift). Runs on pll_cfg's mgmt clock (CLK_50M).
//  Ported from Arcade-UPLFramebuffer (HW-confirmed 2026-10-13).
//
//  sel 0 = Auto: follow sdram_phase_cal's requests. sel 1-15 = fixed position
//  (sel-1)*MAN_STEP. Position 0 is the PLL's built-in phase. ack_tgl flips once
//  per finished request, moved or not.
//
//============================================================================

module sdram_phase_ctl #(
    parameter [4:0] CNT_SEL  = 5'd1,      // PLL C counter that drives SDRAM_CLK
    parameter [6:0] MAN_STEP = 7'd5       // DPS steps per manual OSD entry
)(
    input             clk,                // pll_cfg mgmt clock
    input       [3:0] sel,                // OSD, from another domain (quasi-static)
    input       [6:0] cal_val,            // stable around cal_tgl
    input             cal_tgl,
    output reg        ack_tgl = 1'b0,

    input             cfg_waitrequest,
    output reg        cfg_write = 1'b0,
    output reg  [5:0] cfg_address = 6'd0,
    output reg [31:0] cfg_data = 32'd0
);

    reg   [3:0] sel_s1 = 4'd0, sel_s2 = 4'd0;
    reg   [6:0] cur = 7'd0, tgt = 7'd0;
    reg   [2:0] st = 3'd0;
    reg   [3:0] dly = 4'd0;
    reg   [2:0] rq_s = 3'd0;
    reg         rq_pend = 1'b0;
    reg   [6:0] rq_val = 7'd0;

    wire        is_auto  = (sel_s2 == 4'd0);
    wire  [3:0] km1      = sel_s2 - 4'd1;
    wire [10:0] man_full = km1 * MAN_STEP;
    wire  [6:0] man_want = man_full[6:0];
    wire  [6:0] want     = is_auto ? rq_val : man_want;
    wire        go       = is_auto ? rq_pend : (man_want != cur);

    always @(posedge clk) begin
        sel_s1 <= sel;
        sel_s2 <= sel_s1;
        if (cfg_write) begin
            if (!cfg_waitrequest) cfg_write <= 1'b0;   // held until accepted
        end else begin
            case (st)
                3'd0: if (!cfg_waitrequest && go) begin
                    if (is_auto) rq_pend <= 1'b0;
                    if (want == cur) ack_tgl <= ~ack_tgl;   // already there: ack only
                    else begin
                        tgt <= want;
                        cfg_address <= 6'd0; cfg_data <= 32'd0; cfg_write <= 1'b1;   // waitrequest mode
                        st <= 3'd1;
                    end
                end
                3'd1: begin   // DPS: [15:0] shifts, [20:16] counter, [21] up
                    cfg_address <= 6'd6;
                    cfg_data    <= (tgt > cur) ? {10'd0, 1'b1, CNT_SEL, 9'd0, tgt - cur}
                                               : {10'd0, 1'b0, CNT_SEL, 9'd0, cur - tgt};
                    cfg_write   <= 1'b1;
                    st <= 3'd2;
                end
                3'd2: begin
                    cfg_address <= 6'd2; cfg_data <= 32'd0; cfg_write <= 1'b1;   // start
                    dly <= 4'd0;
                    st <= 3'd3;
                end
                3'd3: begin   // give waitrequest time to rise before trusting it low
                    dly <= dly + 4'd1;
                    if (&dly) st <= 3'd4;
                end
                3'd4: if (!cfg_waitrequest) begin
                    cur <= tgt;
                    ack_tgl <= ~ack_tgl;
                    st <= 3'd0;
                end
                default: st <= 3'd0;
            endcase
        end
        rq_s <= {rq_s[1:0], cal_tgl};
        if (rq_s[2] ^ rq_s[1]) begin rq_pend <= 1'b1; rq_val <= cal_val; end
    end

endmodule
