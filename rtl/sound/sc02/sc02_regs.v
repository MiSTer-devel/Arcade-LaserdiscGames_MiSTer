// ---------------------------------------------------------------------------
// sc02_regs -- host bus interface and the five attribute registers.
//
// Datasheet behaviour reproduced here:
//   * write is armed when {R/W, CS0, CS1} == {0,1,0} and DATA IS LATCHED ON
//     THE FIRST EDGE THAT LEAVES THAT STATE (the datasheet's "valid data
//     latched on first rise or fall of R/W, CS0 or CS1 into inactive").
//   * D7 becomes an output, the inverse of A/R, when R/W=1 and the chip is
//     selected (CS1=0, CS0=1).  Register address bits are ignored on read.
//   * PD/RST low sets the CTL bit and disables A/R without touching registers.
//   * the CTL 1->0 transition samples DR1/DR0 to pick the operating mode.
//
// All chip pins are treated as asynchronous and are double-synchronised into
// the FPGA clock domain.
// ---------------------------------------------------------------------------
`default_nettype none

module sc02_regs (
    input  wire        clk,
    input  wire        rst_n,

    // --- chip pins ---------------------------------------------------------
    input  wire [7:0]  d_in,
    output wire        d7_out,
    output wire        d7_oe,
    input  wire [2:0]  rs,
    input  wire        r_w,        // 1 = read, 0 = write
    input  wire        cs0,        // active high
    input  wire        cs1_n,      // active low
    input  wire        pd_rst_n,   // active low power down / reset
    input  wire        ar_n_in,    // current A/R state from the sequencer

    // --- register outputs --------------------------------------------------
    output reg  [1:0]  dr,         // DR1:DR0   phoneme duration
    output reg  [5:0]  ph,         // P5:P0     phoneme select
    output wire [11:0] infl,       // I11:I0    inflection
    output reg  [3:0]  rate,       // R3:R0     speech rate
    output reg  [2:0]  artic,      // T2:T0     articulation rate
    output reg  [3:0]  amp,        // A3:A0     amplitude
    output reg  [7:0]  ff,         // F7:F0     filter frequency
    output reg         ctl,        // CTL       power down

    // --- events ------------------------------------------------------------
    output reg         wr_phoneme, // 1-cycle: DR/P register written
    output reg         mode_load,  // 1-cycle: CTL fell, latch mode from dr
    output reg         pd_pulse    // 1-cycle: PD/RST asserted
);

    // ---- pin synchronisers -------------------------------------------------
    reg [1:0] s_rw, s_cs0, s_cs1n, s_pd;
    reg [7:0] s_d0, s_d1;
    reg [2:0] s_rs0, s_rs1;

    always @(posedge clk) begin
        s_rw   <= {s_rw[0],   r_w};
        s_cs0  <= {s_cs0[0],  cs0};
        s_cs1n <= {s_cs1n[0], cs1_n};
        s_pd   <= {s_pd[0],   pd_rst_n};
        s_d0   <= d_in;   s_d1 <= s_d0;
        s_rs0  <= rs;     s_rs1 <= s_rs0;
    end

    wire wr_active = (s_rw[1] == 1'b0) && (s_cs0[1] == 1'b1) && (s_cs1n[1] == 1'b0);
    wire rd_active = (s_rw[1] == 1'b1) && (s_cs0[1] == 1'b1) && (s_cs1n[1] == 1'b0);

    reg  wr_active_d;
    always @(posedge clk) wr_active_d <= wr_active;
    wire wr_stb = wr_active_d && !wr_active;   // deselect edge latches the data

    // ---- read path ---------------------------------------------------------
    assign d7_out = ~ar_n_in;
    assign d7_oe  = rd_active;

    // ---- inflection is split across two registers --------------------------
    reg [7:0] r_infl;      // I10..I3
    reg [3:0] r_i_low;     // {I11, I2, I1, I0}
    assign infl = {r_i_low[3], r_infl, r_i_low[2:0]};

    reg ctl_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dr <= 2'b11; ph <= 6'h00; r_infl <= 8'h00; r_i_low <= 4'h0;
            rate <= 4'hA; artic <= 3'd5; amp <= 4'h0; ff <= 8'hD3;
            ctl <= 1'b1;                       // powers up in power-down
            ctl_d <= 1'b1;
            wr_phoneme <= 1'b0; mode_load <= 1'b0; pd_pulse <= 1'b0;
        end else begin
            wr_phoneme <= 1'b0;
            mode_load  <= 1'b0;
            pd_pulse   <= 1'b0;

            if (s_pd[1] == 1'b0) begin         // PD/RST asserted
                ctl      <= 1'b1;
                pd_pulse <= 1'b1;
            end else if (wr_stb) begin
                case (s_rs1)
                    3'b000: begin
                        dr <= s_d1[7:6];
                        ph <= s_d1[5:0];
                        wr_phoneme <= 1'b1;
                    end
                    3'b001: r_infl <= s_d1;                 // I10..I3
                    3'b010: begin
                        rate    <= s_d1[7:4];               // R3..R0
                        r_i_low <= s_d1[3:0];               // I11,I2,I1,I0
                    end
                    3'b011: begin
                        ctl   <= s_d1[7];
                        artic <= s_d1[6:4];
                        amp   <= s_d1[3:0];
                    end
                    default: ff <= s_d1;                    // RS2 high = filter
                endcase
            end

            ctl_d <= ctl;
            if (ctl_d && !ctl) mode_load <= 1'b1;           // CTL 1 -> 0
        end
    end

endmodule
`default_nettype wire
