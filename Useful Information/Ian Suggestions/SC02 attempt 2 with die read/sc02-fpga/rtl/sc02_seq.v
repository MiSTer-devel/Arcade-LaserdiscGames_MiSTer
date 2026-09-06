// ---------------------------------------------------------------------------
// sc02_seq -- frame/phoneme timing, A/R handshake, and the linear target
//             interpolators that give the SC-02 its low host data rate.
//
// Datasheet relationships implemented:
//   frame duration   = 4096 * (16 - R)          XCK cycles
//   phoneme duration = frame * (4 - D)          XCK cycles   (phoneme timing)
//   inflection freq  = XCK / (8 * (4096 - I))   -- divider lives in sc02_excite
//
// "Control" data (rate, filter freq, articulation, duration, immediate
// inflection) takes effect at once.  "Target" data (phoneme, amplitude,
// transitioned inflection) is walked towards linearly, which is what this
// module does.  Articulation rate T2:T0 sets the formant slew and is
// deliberately NOT scaled by the speech rate, per the datasheet.
//
// Interpolated formants are carried as 8.4 fixed point; the integer part is
// the 8-bit index into cos_lut (256 == Nyquist).
// ---------------------------------------------------------------------------
`default_nettype none

module sc02_seq #(
    parameter F1MAP = "rtl/f1_map.bin",
    parameter F2MAP = "rtl/f2_map.bin",
    parameter F3MAP = "rtl/f3_map.bin",
    parameter ART_TICK_DIV = 64          // XCK cycles per interpolation tick
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        xck_en,

    // registers
    input  wire [1:0]  dr,
    input  wire [11:0] infl,
    input  wire [3:0]  rate,
    input  wire [2:0]  artic,
    input  wire [3:0]  amp,
    input  wire        ctl,

    // events
    input  wire        wr_phoneme,
    input  wire        mode_load,

    // raw phoneme parameters from the ROM
    input  wire [3:0]  rom_f1,
    input  wire [4:0]  rom_f2,
    input  wire [2:0]  rom_f2q,
    input  wire [3:0]  rom_f3,
    input  wire [3:0]  rom_fa,
    input  wire [3:0]  rom_va,
    input  wire        rom_closure,
    input  wire        rom_voiced,
    input  wire        rom_pause,

    // interpolated outputs
    output wire [7:0]  f1_now,
    output wire [7:0]  f2_now,
    output wire [7:0]  f3_now,
    output reg  [2:0]  f2q_now,
    output wire [3:0]  va_now,
    output wire [3:0]  fa_now,
    output wire [3:0]  amp_now,
    output reg  [11:0] pitch_now,
    output reg         mute,
    output reg         voiced_now,

    output reg         ar_n         // active low: "send me the next phoneme"
);

    // ---- mode latched on the CTL 1->0 transition ---------------------------
    reg ar_enable, phoneme_timing, transitioned;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ar_enable <= 1'b1; phoneme_timing <= 1'b1; transitioned <= 1'b1;
        end else if (mode_load) begin
            case (dr)
                2'b11: begin ar_enable<=1'b1; phoneme_timing<=1'b1; transitioned<=1'b1; end
                2'b10: begin ar_enable<=1'b1; phoneme_timing<=1'b1; transitioned<=1'b0; end
                2'b01: begin ar_enable<=1'b1; phoneme_timing<=1'b0; transitioned<=1'b0; end
                default:     ar_enable<=1'b0;   // 00: disable A/R only
            endcase
        end
    end

    // ---- frame / phoneme timing -------------------------------------------
    reg [11:0] fcnt;      // 0..4095 within a 4096-cycle block
    reg [3:0]  bcnt;      // blocks within a frame: 16 - R
    reg [1:0]  pcnt;      // frames within a phoneme: 4 - D
    wire [4:0] blocks    = 5'd16 - {1'b0, rate};
    wire [2:0] frames    = 3'd4  - {1'b0, dr};
    wire       frame_end = xck_en && (fcnt == 12'd4095) && (bcnt == blocks[3:0] - 4'd1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fcnt <= 0; bcnt <= 0; pcnt <= 0; ar_n <= 1'b1;
        end else begin
            if (wr_phoneme) begin
                fcnt <= 0; bcnt <= 0; pcnt <= 0;
                ar_n <= 1'b1;                       // request serviced
            end else if (xck_en) begin
                fcnt <= fcnt + 1'b1;
                if (fcnt == 12'd4095) begin
                    if (bcnt == blocks[3:0] - 4'd1) begin
                        bcnt <= 0;
                        if (!phoneme_timing) begin
                            if (ar_enable) ar_n <= 1'b0;
                        end else if (pcnt == frames[1:0] - 2'd1 || frames == 3'd1) begin
                            pcnt <= 0;
                            if (ar_enable) ar_n <= 1'b0;
                        end else begin
                            pcnt <= pcnt + 1'b1;
                        end
                    end else begin
                        bcnt <= bcnt + 1'b1;
                    end
                end
            end
        end
    end

    // ---- formant code -> 8-bit normalised frequency ------------------------
    reg [7:0] f1map [0:15];
    reg [7:0] f2map [0:31];
    reg [7:0] f3map [0:15];
    initial begin
        $readmemb(F1MAP, f1map);
        $readmemb(F2MAP, f2map);
        $readmemb(F3MAP, f3map);
    end

    wire [11:0] f1_tgt = {f1map[rom_f1], 4'b0};   // 8.4
    wire [11:0] f2_tgt = {f2map[rom_f2], 4'b0};
    wire [11:0] f3_tgt = {f3map[rom_f3], 4'b0};

    // ---- articulation tick -------------------------------------------------
    reg [6:0] artdiv;
    reg       art_tick;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin artdiv <= 0; art_tick <= 1'b0; end
        else begin
            art_tick <= 1'b0;
            if (xck_en) begin
                if (artdiv == ART_TICK_DIV[6:0] - 7'd1) begin
                    artdiv <= 0; art_tick <= 1'b1;
                end else artdiv <= artdiv + 1'b1;
            end
        end
    end

    // slew per tick: fast articulation code = big step
    wire [4:0] fstep = 5'd8 - {2'b0, artic};

    reg [11:0] f1c, f2c, f3c;
    reg [7:0]  vac, fac, ampc;                    // 4.4 fixed point

    function [11:0] slew12;
        input [11:0] cur; input [11:0] tgt; input [4:0] step;
        begin
            if (tgt > cur)      slew12 = (tgt - cur < {7'b0, step}) ? tgt : cur + {7'b0, step};
            else if (tgt < cur) slew12 = (cur - tgt < {7'b0, step}) ? tgt : cur - {7'b0, step};
            else                slew12 = cur;
        end
    endfunction

    function [7:0] slew8;
        input [7:0] cur; input [7:0] tgt;
        begin
            if (tgt > cur)      slew8 = cur + 8'd1;
            else if (tgt < cur) slew8 = cur - 8'd1;
            else                slew8 = cur;
        end
    endfunction

    wire [7:0] va_tgt  = mute ? 8'd0 : {rom_va,  4'b0};
    wire [7:0] fa_tgt  = mute ? 8'd0 : {rom_fa,  4'b0};
    wire [7:0] amp_tgt = mute ? 8'd0 : {amp,     4'b0};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            f1c <= 12'd0; f2c <= 12'd0; f3c <= 12'd0;
            vac <= 8'd0;  fac <= 8'd0;  ampc <= 8'd0;
            f2q_now <= 3'd4; voiced_now <= 1'b0;
        end else if (art_tick) begin
            f1c <= slew12(f1c, f1_tgt, fstep);
            f2c <= slew12(f2c, f2_tgt, fstep);
            f3c <= slew12(f3c, f3_tgt, fstep);
            vac  <= slew8(vac,  va_tgt);
            fac  <= slew8(fac,  fa_tgt);
            ampc <= slew8(ampc, amp_tgt);
            f2q_now    <= rom_f2q;                // bandwidth switches, no slew
            voiced_now <= rom_voiced;
        end
    end

    assign f1_now  = f1c[11:4];
    assign f2_now  = f2c[11:4];
    assign f3_now  = f3c[11:4];
    assign va_now  = vac[7:4];
    assign fa_now  = fac[7:4];
    assign amp_now = ampc[7:4];

    always @(*) mute = ctl | rom_pause | rom_closure;

    // ---- inflection --------------------------------------------------------
    // Immediate mode: the whole 12-bit value lands at once.
    // Transitioned mode: I10:I6 is the pitch target and I5:I3 the rate of
    // change, while I11 and I2:I0 stay immediate.  (The datasheet is terse
    // here; this is the reading that makes both sentences consistent.)
    reg [4:0] pitch_hi;
    reg [7:0] pdiv;
    wire [4:0] pitch_tgt = infl[10:6];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pitch_hi <= 5'd0; pdiv <= 8'd0; pitch_now <= 12'd0;
        end else begin
            if (!transitioned) begin
                pitch_hi  <= pitch_tgt;
                pitch_now <= infl;
            end else begin
                if (art_tick) begin
                    if (pdiv >= (8'd1 << infl[5:3]) - 8'd1) begin
                        pdiv <= 8'd0;
                        if (pitch_tgt > pitch_hi)      pitch_hi <= pitch_hi + 1'b1;
                        else if (pitch_tgt < pitch_hi) pitch_hi <= pitch_hi - 1'b1;
                    end else pdiv <= pdiv + 1'b1;
                end
                pitch_now <= {infl[11], pitch_hi, 3'b000, infl[2:0]};
            end
        end
    end

endmodule
`default_nettype wire
