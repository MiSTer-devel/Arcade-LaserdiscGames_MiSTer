// ---------------------------------------------------------------------------
// sc02_filter -- the vocal tract: five cascaded two-pole sections.
//
// The real part uses switched-capacitor filters, which are already a
// discrete-time system clocked at Fs = XCK / (2*(256-FF)).  We run digital
// biquads at that same rate, so the mapping is structural rather than an
// approximation of a continuous-time network.  Because formant frequencies and
// Fs both scale with FF, the coefficients depend only on the interpolated
// formant code -- the Filter Frequency register moves the sample rate and the
// whole spectrum with it, for free, exactly like the switched-cap original.
//
// Section:  y[n] = (A*x[n] + B*y[n-1] - C*y[n-2]) >> 14
//           B = 2*r*cos(theta)   C = r*r   A = 1 - B + C   (unity DC gain)
//
// Coefficients are Q21 in 24 bits.  A is a difference of two nearly equal
// numbers (A ~ 4e-4 for a narrow formant), so Q14 would round it to noise and
// mute the voiced path entirely -- that is a real bug this design hit.
//
// One signed multiplier is time-shared across all five sections: at 20 kHz
// with a 50 MHz fabric there are ~2500 clocks per sample and we need 35.
// ---------------------------------------------------------------------------
`default_nettype none

module sc02_filter #(
    parameter COSLUT    = "rtl/cos_lut.bin",
    parameter B2RLUT    = "rtl/b2r_lut.bin",
    parameter RSQLUT    = "rtl/rsq_lut.bin",
    parameter SW        = 22,      // internal state width
    parameter CQ        = 21,      // coefficient fractional bits
    parameter OUT_SHIFT = 0        // headroom given back at the output
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               fs_en,

    input  wire signed [15:0] x_in,
    input  wire [39:0]        freq_pk,   // 5 x 8-bit formant index
    input  wire [14:0]        q_pk,      // 5 x 3-bit bandwidth code

    output reg  signed [15:0] y_out,
    output reg                y_valid
);

    reg signed [15:0] cos_lut [0:255];
    reg signed [23:0] b2r_lut [0:7];
    reg signed [23:0] rsq_lut [0:7];
    initial begin
        $readmemb(COSLUT, cos_lut);
        $readmemb(B2RLUT, b2r_lut);
        $readmemb(RSQLUT, rsq_lut);
    end

    reg signed [SW-1:0] y1 [0:4];
    reg signed [SW-1:0] y2 [0:4];

    reg [2:0] sec;
    reg [2:0] st;
    reg       busy;

    reg signed [15:0]  cosv;
    reg signed [23:0]  b2v, cv, bv;
    reg signed [SW-1:0] xcur;
    reg signed [47:0]  acc;

    // shared signed multiplier, 24 x 24
    reg  signed [23:0] mul_a;
    reg  signed [23:0] mul_b;
    wire signed [47:0] mul_p = mul_a * mul_b;

    wire [7:0] fsel = freq_pk[sec*8 +: 8];
    wire [2:0] qsel = q_pk[sec*3 +: 3];

    wire signed [23:0] one_q  = 24'sd1 <<< CQ;
    wire signed [23:0] a_next = one_q - bv + cv;        // unity DC gain

    localparam signed [47:0] SAT_HI =  (48'sd1 <<< (SW-1)) - 48'sd1;
    localparam signed [47:0] SAT_LO = -(48'sd1 <<< (SW-1));

    function signed [SW-1:0] sat;
        input signed [47:0] v;
        begin
            if (v > SAT_HI)      sat = SAT_HI[SW-1:0];
            else if (v < SAT_LO) sat = SAT_LO[SW-1:0];
            else                 sat = v[SW-1:0];
        end
    endfunction

    function signed [15:0] sat16;
        input signed [SW-1:0] v;
        reg   signed [SW-1:0] s;
        begin
            s = v >>> OUT_SHIFT;
            if (s > 32767)       sat16 =  16'sd32767;
            else if (s < -32768) sat16 = -16'sd32768;
            else                 sat16 = s[15:0];
        end
    endfunction

    wire signed [47:0]   res  = acc - mul_p;
    wire signed [SW-1:0] ynew = sat(res >>> CQ);

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 5; i = i + 1) begin
                y1[i] <= 0; y2[i] <= 0;
            end
            sec <= 0; st <= 0; busy <= 1'b0;
            y_out <= 16'sd0; y_valid <= 1'b0;
            xcur <= 0; acc <= 0;
            cosv <= 0; b2v <= 0; cv <= 0; bv <= 0;
            mul_a <= 0; mul_b <= 0;
        end else begin
            y_valid <= 1'b0;

            if (fs_en && !busy) begin
                busy <= 1'b1;
                sec  <= 3'd0;
                st   <= 3'd0;
                xcur <= {{(SW-16){x_in[15]}}, x_in};
            end else if (busy) begin
                case (st)
                    3'd0: begin                        // coefficient fetch
                        cosv <= cos_lut[fsel];
                        b2v  <= b2r_lut[qsel];
                        cv   <= rsq_lut[qsel];
                        st   <= 3'd1;
                    end
                    3'd1: begin                        // queue B = 2r*cos
                        mul_a <= b2v;
                        mul_b <= {{8{cosv[15]}}, cosv};
                        st    <= 3'd2;
                    end
                    3'd2: begin
                        bv <= (mul_p >>> 15);          // back to Q21
                        st <= 3'd3;
                    end
                    3'd3: begin                        // queue A*x
                        mul_a <= a_next;
                        mul_b <= {{(24-SW){xcur[SW-1]}}, xcur};
                        st    <= 3'd4;
                    end
                    3'd4: begin                        // acc = A*x ; queue B*y1
                        acc   <= mul_p;
                        mul_a <= bv;
                        mul_b <= {{(24-SW){y1[sec][SW-1]}}, y1[sec]};
                        st    <= 3'd5;
                    end
                    3'd5: begin                        // acc += B*y1 ; queue C*y2
                        acc   <= acc + mul_p;
                        mul_a <= cv;
                        mul_b <= {{(24-SW){y2[sec][SW-1]}}, y2[sec]};
                        st    <= 3'd6;
                    end
                    3'd6: begin                        // acc -= C*y2, write back
                        y2[sec] <= y1[sec];
                        y1[sec] <= ynew;
                        xcur    <= ynew;
                        if (sec == 3'd4) begin
                            busy    <= 1'b0;
                            y_valid <= 1'b1;
                            y_out   <= sat16(ynew);
                        end else begin
                            sec <= sec + 1'b1;
                            st  <= 3'd0;
                        end
                    end
                    default: st <= 3'd0;
                endcase
            end
        end
    end

endmodule
`default_nettype wire
