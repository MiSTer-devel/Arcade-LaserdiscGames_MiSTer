//============================================================================
// bin17_to_bcd5.sv — 17-bit binary to 5 BCD digits, sequential double-dabble.
//
// Cliff Hanger reads the disc frame as a Philips VBI picture code, which is
// BCD. The frame changes at 23.976 Hz, so a 17-step conversion restarted on
// every change is far faster than the game can sample it, and costs a great
// deal less area than an unrolled combinational chain.
//============================================================================
module bin17_to_bcd5
(
    input             clk,
    input             reset_n,
    input      [16:0] bin,
    output reg [19:0] bcd
);
    reg [16:0] bin_q, sh;
    reg [19:0] acc;
    reg  [4:0] step;
    reg        busy;

    function [3:0] adj1(input [3:0] n);
        adj1 = (n >= 4'd5) ? (n + 4'd3) : n;
    endfunction
    wire [19:0] acc_adj = {adj1(acc[19:16]), adj1(acc[15:12]), adj1(acc[11:8]),
                           adj1(acc[7:4]),   adj1(acc[3:0])};

    always @(posedge clk) begin
        if (!reset_n) begin
            bcd <= 20'd0; bin_q <= 17'd0; busy <= 1'b0;
            acc <= 20'd0; sh <= 17'd0; step <= 5'd0;
        end else begin
            if (bin != bin_q && !busy) begin
                bin_q <= bin; sh <= bin; acc <= 20'd0; step <= 5'd0; busy <= 1'b1;
            end else if (busy) begin
                if (step == 5'd17) begin
                    bcd  <= acc;
                    busy <= 1'b0;
                end else begin
                    acc  <= {acc_adj[18:0], sh[16]};
                    sh   <= {sh[15:0], 1'b0};
                    step <= step + 5'd1;
                end
            end
        end
    end
endmodule
