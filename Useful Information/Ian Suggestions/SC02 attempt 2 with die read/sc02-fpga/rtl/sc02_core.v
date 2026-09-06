// ---------------------------------------------------------------------------
// sc02_core -- everything below the pins.
//
// Clock strategy: the design runs on a fast FPGA clock and treats XCK as data.
// Every datasheet timing formula is expressed in XCK cycles, so xck_en is the
// single reference; the filter sample tick fs_en is XCK / (2*(256-FF)), which
// is the switched-capacitor clock of the original.
// ---------------------------------------------------------------------------
`default_nettype none

module sc02_core #(
    parameter ROMFILE   = "rom/sc02_phoneme_rom.bin",
    parameter OUT_SHIFT = 0,
    // sections 4 and 5 are a fixed upper pole and spectral tilt, see README
    parameter [7:0] F4_FIX = 8'd92,    // ~3.6 kHz at nominal Fs
    parameter [7:0] F5_FIX = 8'd123,   // ~4.8 kHz
    parameter [2:0] Q_F1   = 3'd3,
    parameter [2:0] Q_F3   = 3'd4,
    parameter [2:0] Q_F4   = 3'd5,
    parameter [2:0] Q_F5   = 3'd6
) (
    input  wire        clk,
    input  wire        rst_n,

    // chip pins (already split into in/out/oe)
    input  wire [7:0]  d_in,
    output wire        d7_out,
    output wire        d7_oe,
    input  wire [2:0]  rs,
    input  wire        r_w,
    input  wire        cs0,
    input  wire        cs1_n,
    input  wire        pd_rst_n,
    input  wire        xck,
    input  wire        div2,
    output wire        ar_n,
    output wire        ar_oe,      // open collector: drive low only

    // audio
    output wire signed [15:0] audio_pcm,
    output wire               audio_valid,
    output wire               audio_sd,   // 1-bit sigma-delta for a pin + RC

    // debug / bring-up
    input  wire        rom_row_flip
);

    // ---- XCK edge detect ---------------------------------------------------
    reg [2:0] xs;
    reg       xtog;
    always @(posedge clk) xs <= {xs[1:0], xck};
    wire xck_edge = xs[1] & ~xs[2];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) xtog <= 1'b0;
        else if (xck_edge) xtog <= ~xtog;
    end
    wire xck_en = div2 ? (xck_edge & xtog) : xck_edge;

    // ---- registers ---------------------------------------------------------
    wire [1:0]  dr;
    wire [5:0]  ph;
    wire [11:0] infl;
    wire [3:0]  rate, amp;
    wire [2:0]  artic;
    wire [7:0]  ff;
    wire        ctl, wr_phoneme, mode_load, pd_pulse;
    wire        ar_n_i;

    sc02_regs u_regs (
        .clk(clk), .rst_n(rst_n),
        .d_in(d_in), .d7_out(d7_out), .d7_oe(d7_oe),
        .rs(rs), .r_w(r_w), .cs0(cs0), .cs1_n(cs1_n), .pd_rst_n(pd_rst_n),
        .ar_n_in(ar_n_i),
        .dr(dr), .ph(ph), .infl(infl), .rate(rate), .artic(artic),
        .amp(amp), .ff(ff), .ctl(ctl),
        .wr_phoneme(wr_phoneme), .mode_load(mode_load), .pd_pulse(pd_pulse)
    );

    assign ar_n  = ar_n_i;
    assign ar_oe = ~ar_n_i;          // open collector

    // ---- filter sample tick: XCK / (2*(256-FF)) ----------------------------
    wire [9:0] fs_div = {1'b0, (9'd256 - {1'b0, ff})} << 1;
    reg  [9:0] fs_cnt;
    reg        fs_en;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin fs_cnt <= 0; fs_en <= 1'b0; end
        else begin
            fs_en <= 1'b0;
            if (xck_en) begin
                if (fs_cnt >= fs_div - 10'd1) begin
                    fs_cnt <= 0; fs_en <= 1'b1;
                end else fs_cnt <= fs_cnt + 1'b1;
            end
        end
    end

    // ---- phoneme ROM -------------------------------------------------------
    wire [3:0] rom_f1, rom_f3, rom_fa, rom_va;
    wire [4:0] rom_f2;
    wire [2:0] rom_f2q;
    wire       rom_closure, rom_voiced, rom_pause;

    sc02_rom #(.ROMFILE(ROMFILE)) u_rom (
        .clk(clk), .phoneme(ph), .row_flip(rom_row_flip),
        .f1(rom_f1), .f2(rom_f2), .f2q(rom_f2q), .f3(rom_f3),
        .fa(rom_fa), .va(rom_va),
        .closure(rom_closure), .voiced(rom_voiced), .pause(rom_pause)
    );

    // ---- sequencer / interpolators -----------------------------------------
    wire [7:0]  f1_now, f2_now, f3_now;
    wire [2:0]  f2q_now;
    wire [3:0]  va_now, fa_now, amp_now;
    wire [11:0] pitch_now;
    wire        mute, voiced_now;

    sc02_seq u_seq (
        .clk(clk), .rst_n(rst_n), .xck_en(xck_en),
        .dr(dr), .infl(infl), .rate(rate), .artic(artic), .amp(amp), .ctl(ctl),
        .wr_phoneme(wr_phoneme), .mode_load(mode_load),
        .rom_f1(rom_f1), .rom_f2(rom_f2), .rom_f2q(rom_f2q), .rom_f3(rom_f3),
        .rom_fa(rom_fa), .rom_va(rom_va),
        .rom_closure(rom_closure), .rom_voiced(rom_voiced), .rom_pause(rom_pause),
        .f1_now(f1_now), .f2_now(f2_now), .f3_now(f3_now), .f2q_now(f2q_now),
        .va_now(va_now), .fa_now(fa_now), .amp_now(amp_now),
        .pitch_now(pitch_now), .mute(mute), .voiced_now(voiced_now),
        .ar_n(ar_n_i)
    );

    // ---- excitation --------------------------------------------------------
    wire signed [15:0] exc;

    sc02_excite u_exc (
        .clk(clk), .rst_n(rst_n), .xck_en(xck_en), .fs_en(fs_en),
        .pitch(pitch_now), .va(va_now), .fa(fa_now), .amp(amp_now),
        .mute(mute), .x(exc)
    );

    // ---- vocal tract -------------------------------------------------------
    wire [39:0] freq_pk = {F5_FIX, F4_FIX, f3_now, f2_now, f1_now};
    wire [14:0] q_pk    = {Q_F5, Q_F4, Q_F3, f2q_now, Q_F1};

    // one cycle of skew: excitation is registered on fs_en, so the cascade
    // consumes the previous sample. delay the tick by one clock.
    reg fs_en_d;
    always @(posedge clk) fs_en_d <= fs_en;

    wire filt_valid;
    sc02_filter #(.OUT_SHIFT(OUT_SHIFT)) u_filt (
        .clk(clk), .rst_n(rst_n), .fs_en(fs_en_d),
        .x_in(exc), .freq_pk(freq_pk), .q_pk(q_pk),
        .y_out(filt_pcm), .y_valid(filt_valid)
    );
    assign audio_valid = filt_valid;

    // ---- DC blocker --------------------------------------------------------
    // y[n] = x[n] - x[n-1] + (255/256) * y[n-1]
    wire signed [15:0] filt_pcm;
    reg  signed [15:0] dc_x1;
    reg  signed [23:0] dc_y;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin dc_x1 <= 0; dc_y <= 0; end
        else if (filt_valid) begin
            dc_x1 <= filt_pcm;
            dc_y  <= ((filt_pcm - dc_x1) <<< 8) + dc_y - (dc_y >>> 8);
        end
    end
    assign audio_pcm = (dc_y >>> 8 >  24'sd32767) ?  16'sd32767 :
                       (dc_y >>> 8 < -24'sd32768) ? -16'sd32768 : dc_y[23:8];

    // ---- 1st order sigma-delta ---------------------------------------------
    reg [17:0] sd_acc;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) sd_acc <= 0;
        else sd_acc <= sd_acc[16:0] + {~audio_pcm[15], audio_pcm[14:0], 1'b0};
    end
    assign audio_sd = sd_acc[17];

endmodule
`default_nettype wire
