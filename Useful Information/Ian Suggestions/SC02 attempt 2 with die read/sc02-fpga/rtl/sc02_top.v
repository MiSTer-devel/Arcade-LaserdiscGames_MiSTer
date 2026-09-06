// ---------------------------------------------------------------------------
// sc02_top -- pin-compatible wrapper.
//
// Presents the SSI-263 / SC-02 pin behaviour to the outside world: a
// bidirectional D7, an open-collector A/R, and the same register semantics.
// Everything else is a normal synchronous FPGA design clocked by clk.
//
// Drop-in notes for a Mockingboard / arcade sound board:
//   * D0..D6 are inputs on the real part; only D7 is bidirectional.
//   * A/R must be open collector -- the board pulls it up and may wire-OR it.
//   * XCK is the board's clock; feed it straight in, set DIV2 to match.
//   * clk must be comfortably faster than XCK.  50 MHz is plenty: the filter
//     needs 35 clocks per audio sample and has ~2500 available.
// ---------------------------------------------------------------------------
`default_nettype none

module sc02_top #(
    parameter ROMFILE = "rom/sc02_phoneme_rom.bin"
) (
    input  wire        clk,
    input  wire        rst_n,

    inout  wire [7:0]  d,
    input  wire [2:0]  rs,
    input  wire        r_w,
    input  wire        cs0,
    input  wire        cs1_n,
    input  wire        pd_rst_n,
    input  wire        xck,
    input  wire        div2,
    inout  wire        ar_n,

    output wire        audio_sd,          // 1-bit out, RC filter to an amp
    output wire signed [15:0] audio_pcm,  // for an I2S / parallel codec
    output wire        audio_valid,

    input  wire        rom_row_flip       // bring-up switch, see README
);

    wire d7_out, d7_oe, ar_oe;

    assign d    = d7_oe ? {d7_out, 7'bzzz_zzzz} : 8'bzzzz_zzzz;
    assign ar_n = ar_oe ? 1'b0 : 1'bz;         // open collector

    sc02_core #(.ROMFILE(ROMFILE)) u_core (
        .clk(clk), .rst_n(rst_n),
        .d_in(d), .d7_out(d7_out), .d7_oe(d7_oe),
        .rs(rs), .r_w(r_w), .cs0(cs0), .cs1_n(cs1_n),
        .pd_rst_n(pd_rst_n), .xck(xck), .div2(div2),
        .ar_n(), .ar_oe(ar_oe),
        .audio_pcm(audio_pcm), .audio_valid(audio_valid), .audio_sd(audio_sd),
        .rom_row_flip(rom_row_flip)
    );

endmodule
`default_nettype wire
