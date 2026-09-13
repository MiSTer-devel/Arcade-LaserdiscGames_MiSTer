// ---------------------------------------------------------------------------
// sc02_excite -- the two excitation sources feeding the vocal tract.
//
//   glottal   pitch pulse train, period = 8 * (4096 - I) XCK cycles, exactly
//             the datasheet's inflection frequency formula.  Emitted as a
//             one-sample impulse.  The cascade has unity DC gain per section,
//             so the impulse train's mean shows up as a DC offset; a first
//             order DC blocker in sc02_core removes it.  (A doublet kills the
//             DC without the blocker, but its spectrum nulls at 0 Hz and rolls
//             OFF towards the formants, which starves F1 -- do not do that.)
//   noise     pseudo-random source for fricatives, a 17-bit maximal LFSR
//             clocked at the filter sample rate.
//
// The ROM's voiced flag picks which source dominates, but both amplitudes are
// live at once so voiced fricatives (Z, V, THV, J) come out mixed, which is
// what the phoneme chart needs.
// ---------------------------------------------------------------------------
`default_nettype none

module sc02_excite (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               xck_en,
    input  wire               fs_en,        // filter sample tick

    input  wire [11:0]        pitch,        // I11:I0
    input  wire [3:0]         va,           // voiced amplitude
    input  wire [3:0]         fa,           // fricative amplitude
    input  wire [3:0]         amp,          // global A3:A0
    input  wire               mute,

    output reg signed [15:0]  x             // excitation sample, valid at fs_en
);

    // ---- pitch divider: 8 * (4096 - I) -------------------------------------
    wire [12:0] inv    = 13'd4096 - {1'b0, pitch};
    wire [15:0] period = {inv, 3'b000};

    reg  [15:0] pcnt;
    reg         pulse;         // one filter sample wide

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pcnt <= 16'd0; pulse <= 1'b0;
        end else begin
            if (xck_en) begin
                if (pcnt >= period - 16'd1) begin
                    pcnt  <= 16'd0;
                    pulse <= 1'b1;
                end else pcnt <= pcnt + 1'b1;
            end
            if (fs_en && pulse) pulse <= 1'b0;
        end
    end

    // ---- noise -------------------------------------------------------------
    reg [16:0] lfsr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) lfsr <= 17'h1ACE1;
        else if (fs_en) lfsr <= {lfsr[15:0], lfsr[16] ^ lfsr[13]};
    end

    // ---- mix ---------------------------------------------------------------
    // gain staging: the cascade's per-section input gain A = 1-B+C is small
    // for a narrow formant, so drive the tract hard and keep the headroom in
    // the 22-bit filter state rather than at the excitation.
    wire signed [15:0] glot = pulse ? {1'b0, va, 11'h000} : 16'sd0;

    wire signed [15:0] noiz = lfsr[16] ?  {3'b000, fa, 9'h000}
                                       : -{3'b000, fa, 9'h000};

    wire signed [16:0] sum  = glot + noiz;
    wire signed [21:0] scal = sum * $signed({1'b0, amp});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) x <= 16'sd0;
        else if (fs_en) x <= mute ? 16'sd0 : scal[19:4];
    end

endmodule
`default_nettype wire
