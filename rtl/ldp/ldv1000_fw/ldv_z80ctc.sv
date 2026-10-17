//============================================================================
// ldv_z80ctc.sv -- Z80 CTC (4 channels + daisy-chain IRQ), port of MAME z80ctc.cpp.
//
// Behaviour follows MAME, including its quirks, because MAME is the reference
// the LD-V1000 firmware is known to run against:
//   * Channel clock is unconfigured in MAME, so COUNTER mode counts only TRG
//     edges and a timer waiting for its trigger waits for a real edge.
//   * TRG edges decrement a counter-mode channel even while RESET is set.
//   * Reset write: the present count is kept, the timer stops, a pending INT
//     is NOT cleared; writing a control word with D7=0 clears a pending INT.
//   * Counter->timer without reset and without a constant restarts the timer
//     with the old constant.
//   * Vector register is written through channel 0 only (D0=0), low 3 bits
//     forced 0; channel n acknowledges with vector + 2n.
//   * Daisy: channel 0 highest.  A channel in service (IEO) blocks itself and
//     every lower-priority channel until RETI.
// Timer down count is a real counter (prescaler 16/256 on ce), which reads back
// the same values as MAME's remaining-time calculation.
// Bus strobes are 1-clk pulses supplied by the caller.
//============================================================================
module ldv_z80ctc (
    input             clk,
    input             reset_n,
    input             ce,          // CTC phi: 2.5 MHz enable, gated by the caller's run

    input             wr_stb,      // 1-clk register write
    input       [1:0] wsel,
    input       [7:0] wdata,
    input       [1:0] rsel,        // combinational read
    output      [7:0] dout,

    input       [3:0] trg,         // trigger / clock inputs (level)
    input             trg_en,      // trigger edges are sampled only while running

    input             inta,        // 1-clk: interrupt acknowledge cycle started
    input             reti,        // 1-clk: RETI decoded on the bus
    output            int_n,
    output reg  [7:0] ack_vector   // vector latched at inta, drive during INTA
);
    reg  [7:0] mode   [0:3];
    reg        waitt  [0:3];       // WAITING_FOR_TRIG
    reg        run    [0:3];       // timer running (MAME m_timer enabled & periodic)
    reg  [7:0] tconst [0:3];       // 0 encodes 256
    reg  [7:0] down   [0:3];
    reg  [7:0] presc  [0:3];
    reg        extclk [0:3];
    reg        ipend  [0:3];       // Z80_DAISY_INT
    reg        isvc   [0:3];       // Z80_DAISY_IEO
    reg  [4:0] vector;             // bits 7:3

    assign dout = down[rsel];

    // daisy: INT is visible only from channels ahead of the first in-service one
    wire [3:0] ip = {ipend[3], ipend[2], ipend[1], ipend[0]};
    wire [3:0] is = {isvc[3],  isvc[2],  isvc[1],  isvc[0]};
    wire       irq = (ip[0]) |
                     (!is[0] && ip[1]) |
                     (!is[0] && !is[1] && ip[2]) |
                     (!is[0] && !is[1] && !is[2] && ip[3]);
    assign int_n = ~irq;

    integer i;
    reg [1:0] ack_ch;
    reg       ack_hit;
    reg [1:0] reti_ch;
    reg       reti_hit;
    always @(*) begin
        ack_hit = 1'b0; ack_ch = 2'd0;
        for (i = 3; i >= 0; i = i - 1)
            if (ip[i]) begin ack_hit = 1'b1; ack_ch = i[1:0]; end
        reti_hit = 1'b0; reti_ch = 2'd0;
        for (i = 3; i >= 0; i = i - 1)
            if (is[i]) begin reti_hit = 1'b1; reti_ch = i[1:0]; end
    end

    // per-channel next state
    always @(posedge clk) begin
        if (!reset_n) begin
            for (i = 0; i < 4; i = i + 1) begin
                mode[i] <= 8'h02; waitt[i] <= 1'b0; run[i] <= 1'b0;
                tconst[i] <= 8'h00; down[i] <= 8'h00; presc[i] <= 8'h00;
                extclk[i] <= 1'b0; ipend[i] <= 1'b0; isvc[i] <= 1'b0;
            end
            vector <= 5'd0;
            ack_vector <= 8'h00;
        end else begin
            for (i = 0; i < 4; i = i + 1) begin
                // ---- timer prescaler / down count ----
                if (ce && run[i] && !waitt[i] && !mode[i][6]) begin
                    if (presc[i] == (mode[i][5] ? 8'd255 : 8'd15)) begin
                        presc[i] <= 8'd0;
                        if (down[i] == 8'd1) begin
                            down[i] <= tconst[i];
                            if (mode[i][7]) ipend[i] <= 1'b1;
                        end else
                            down[i] <= down[i] - 8'd1;
                    end else
                        presc[i] <= presc[i] + 8'd1;
                end

                // ---- trigger edge ----
                if (trg_en && (trg[i] != extclk[i])) begin
                    extclk[i] <= trg[i];
                    if (mode[i][4] ? trg[i] : !trg[i]) begin
                        if (waitt[i] && !mode[i][6]) begin
                            run[i] <= 1'b1; presc[i] <= 8'd0;
                        end
                        waitt[i] <= 1'b0;
                        if (mode[i][6]) begin
                            if (down[i] == 8'd1) begin
                                down[i] <= tconst[i];
                                if (mode[i][7]) ipend[i] <= 1'b1;
                            end else
                                down[i] <= down[i] - 8'd1;
                        end
                    end
                end
            end

            // ---- register write (overrides the counting above) ----
            if (wr_stb) begin
                if (mode[wsel][2]) begin
                    // time constant
                    tconst[wsel] <= wdata;
                    down[wsel]   <= wdata;
                    mode[wsel]   <= mode[wsel] & 8'hF9;          // ~CONSTANT, ~RESET
                    presc[wsel]  <= 8'd0;
                    if (mode[wsel][6] || !mode[wsel][3]) begin
                        run[wsel] <= 1'b1; waitt[wsel] <= 1'b0;
                    end else begin
                        run[wsel] <= 1'b0; waitt[wsel] <= 1'b1;
                    end
                end else if (!wdata[0]) begin
                    if (wsel == 2'd0) vector <= wdata[7:3];
                end else begin
                    // control word
                    mode[wsel]  <= wdata;
                    waitt[wsel] <= 1'b0;                          // m_mode = data drops bit 8
                    if (wdata[1]) begin
                        run[wsel] <= 1'b0;                        // count kept (m_down = read())
                    end else if (!mode[wsel][6] && wdata[6]) begin
                        run[wsel] <= 1'b0;                        // timer -> counter, no reset
                    end else if (mode[wsel][6] && !wdata[6] && !wdata[2]) begin
                        // counter -> timer, no reset, no constant: start with the old constant
                        down[wsel]  <= tconst[wsel];
                        presc[wsel] <= 8'd0;
                        if (!wdata[3]) begin run[wsel] <= 1'b1; end
                        else begin run[wsel] <= 1'b0; waitt[wsel] <= 1'b1; end
                    end
                    if (!wdata[7]) ipend[wsel] <= 1'b0;
                end
            end

            // ---- daisy chain ----
            if (inta) begin
                ack_vector <= {vector, ack_ch, 1'b0};
                if (ack_hit) begin
                    ipend[ack_ch] <= 1'b0;
                    isvc[ack_ch]  <= 1'b1;
                end
            end
            if (reti && reti_hit)
                isvc[reti_ch] <= 1'b0;
        end
    end
endmodule
