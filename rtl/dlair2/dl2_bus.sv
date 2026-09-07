//============================================================================
// dl2_bus.sv — glue between MCL86's 8088 max-mode pins and the DL2 board.
//
// Max-mode status (S2_S0_OUT), 8088:
//   000 INTA   001 IO read   010 IO write   011 halt
//   100 code fetch   101 mem read   110 mem write   111 passive (idle)
//
// biu_max drives a cycle like this:
//   state 0x01  AD_OE=1, AD_OUT[19:0] = address, then S2_S0_OUT <- status
//   state 0x1A  S6_3_MUX=1; AD_OE <- s_bits[1] (so the bus floats on reads);
//               for writes AD_OUT[7:0] carries the data byte
//   state 0x36  samples READY_IN (extends the cycle while low)
//   state 0x3D  latches AD_IN
//
// So: the address is valid while S6_3_MUX is low, the write byte is valid once
// it is high, and holding READY_IN low stretches the cycle until we answer.
// This module presents that as a simple "req / type / addr / wdata -> rdata,
// ack" interface so the board itself never has to think about 8088 pin timing.
//============================================================================
module dl2_bus
(
    input             clk,            // CORE_CLK_INT
    input             reset_n,

    // ---- MCL86 pin side ----
    input      [2:0]  s2_s0,
    input             s6_3_mux,
    input      [19:0] ad_out,
    output     [7:0]  ad_in,
    output reg        ready_in,

    // ---- board side ----
    output reg        req,            // level: a bus cycle wants servicing
    output reg [2:0]  req_type,       // latched S2_S0 for this cycle
    output reg [19:0] req_addr,
    output reg [7:0]  req_wdata,
    input      [7:0]  req_rdata,
    input             req_ack         // 1-cycle: rdata valid / write taken
);
    localparam [2:0] ST_IDLE = 3'b111;

    reg [2:0] s2_s0_q;
    reg       served;                 // this cycle has already been answered
    reg [7:0] rdata_q;

    assign ad_in = rdata_q;

    wire cycle_active = (s2_s0 != ST_IDLE);
    wire cycle_start  = cycle_active && (s2_s0_q == ST_IDLE);

    always @(posedge clk) begin
        if (!reset_n) begin
            s2_s0_q <= ST_IDLE; served <= 1'b0; req <= 1'b0;
            req_type <= ST_IDLE; req_addr <= 20'd0; req_wdata <= 8'd0;
            rdata_q <= 8'hFF; ready_in <= 1'b1;
        end else begin
            s2_s0_q <= s2_s0;

            if (cycle_start) begin
                // Address is on AD_OUT now, before S6_3_MUX flips.
                req_addr <= ad_out;
                req_type <= s2_s0;
                served   <= 1'b0;
                ready_in <= 1'b0;                 // stall until we answer
                // Reads can be issued immediately; a write must wait for its
                // data byte, which only appears once S6_3_MUX goes high.
                req      <= (s2_s0 != 3'b010) && (s2_s0 != 3'b110);
            end else if (cycle_active && !served) begin
                // Writes: capture the byte as soon as the data phase starts.
                if (!req && s6_3_mux && ((req_type == 3'b010) || (req_type == 3'b110))) begin
                    req_wdata <= ad_out[7:0];
                    req       <= 1'b1;
                end
                if (req && req_ack) begin
                    rdata_q  <= req_rdata;
                    req      <= 1'b0;
                    served   <= 1'b1;
                    ready_in <= 1'b1;             // release the cycle
                end
            end else if (!cycle_active) begin
                req      <= 1'b0;
                served   <= 1'b0;
                ready_in <= 1'b1;
            end
        end
    end
endmodule
