//============================================================================
// ldp_top.sv — laserdisc player wrapper.
//
// One shared transport plus one protocol front-end per player, selected at
// runtime by player_sel. Adding a player is: write ldp_<name>.sv, instantiate
// it here, add its PLAYER_* code and its rows to the muxes below. The
// transport is never touched.
//
// Players do not share a CPU-side interface, so the wrapper carries the union
// of what they need and each game wires up only its own:
//   LD-V1000   cmd_stb/cmd_byte -> status byte + status/command strobes
//   PR-7820    cmd_stb/cmd_byte -> a single /READY level, no status byte
//   PR-8210    blip             -> nothing back; the game reads curr_frame
//   LDP-1450   cmd_stb/cmd_byte -> a byte reply queue (tx_valid/tx_byte/tx_pop)
//============================================================================
module ldp_top
#(
    parameter [31:0] CLK_HZ = 32'd80_000_000
)
(
    input             clk,
    input             reset_n,

    input      [3:0]  player_sel,      // see PLAYER_* below

    // ---- parallel / serial byte interface (LD-V1000, PR-7820, LDP-1450) ----
    input             cmd_stb,
    input      [7:0]  cmd_byte,

    // ---- blip interface (PR-8210) ----
    input             blip,

    // ---- CPU-side status ----
    output     [7:0]  status,          // LD-V1000: 0xC020 laserdisc_r
    output            status_strobe,   // LD-V1000: SYSTEM b6
    output            command_strobe,  // LD-V1000: SYSTEM b7 = ~command_strobe
    output            ready_n,         // PR-7820:  SYSTEM b7 /READY
    output            frame_valid,     // PR-8210:  curr_frame is meaningful
    output            tx_valid,        // LDP-1450: reply queue
    output     [7:0]  tx_byte,
    input             tx_pop,

    // ---- video / audio contract ----
    output            search_cmd_o,
    output            play_end_o,
    output     [16:0] curr_frame,
    input             pause,
    input             disc_hold,
    output            playing,
    output     [16:0] dbg_seek_frame,
    output     [19:0] dbg_end_frame,
    output      [3:0] dbg_flags,
    input       [3:0] post_seek_frames,

    // ---- text overlay feed (LDP-1450 family only; inert for the others) ----
    // The character generator belongs to the PLAYER, not the game: any board on
    // an LDP-1450 gets on-screen text without contributing anything.
    output            txt_we,
    output      [1:0] txt_line,
    output      [5:0] txt_col,
    output      [7:0] txt_glyph,
    output            txt_on,
    output      [7:0] txt_x,
    output      [7:0] txt_y
);
    localparam [3:0] PLAYER_LDV1000 = 4'd0,
                     PLAYER_PR7820  = 4'd1,
                     PLAYER_PR8210  = 4'd2,
                     PLAYER_LDP1450 = 4'd3;

    wire sel_ldv1000 = (player_sel == PLAYER_LDV1000);
    wire sel_pr7820  = (player_sel == PLAYER_PR7820);
    wire sel_pr8210  = (player_sel == PLAYER_PR8210);
    wire sel_ldp1450 = (player_sel == PLAYER_LDP1450);

    // ---- shared mechanism ----
    wire [2:0]  mode;
    wire        search_busy, search_done, autostop_done;
    wire [21:0] field_phase;
    wire        frame_tick, film_tick;

    // ---- per-front-end command buses ----
    wire        act_ldv, act_pr78, act_pr82, act_sony;
    wire [3:0]  op_ldv,  op_pr78,  op_pr82,  op_sony;
    wire [16:0] arg_ldv, arg_pr78, arg_pr82, arg_sony;

    wire        cmd_action = sel_pr7820  ? act_pr78 :
                             sel_pr8210  ? act_pr82 :
                             sel_ldp1450 ? act_sony : act_ldv;
    wire [3:0]  cmd_op     = sel_pr7820  ? op_pr78  :
                             sel_pr8210  ? op_pr82  :
                             sel_ldp1450 ? op_sony  : op_ldv;
    wire [16:0] cmd_arg    = sel_pr7820  ? arg_pr78 :
                             sel_pr8210  ? arg_pr82 :
                             sel_ldp1450 ? arg_sony : arg_ldv;

    ldp_transport #(.CLK_HZ(CLK_HZ)) u_transport (
        .clk(clk), .reset_n(reset_n),
        .cmd_action(cmd_action), .cmd_op(cmd_op), .cmd_arg(cmd_arg),
        .mode(mode), .curr_frame(curr_frame),
        .search_busy(search_busy), .search_done(search_done), .autostop_done(autostop_done),
        .field_phase(field_phase), .frame_tick(frame_tick), .film_tick(film_tick),
        .pause(pause), .disc_hold(disc_hold), .post_seek_frames(post_seek_frames),
        .search_cmd_o(search_cmd_o), .play_end_o(play_end_o), .playing(playing),
        .dbg_seek_frame(dbg_seek_frame)
    );

    // ---- LD-V1000 ----
    wire [7:0]  status_ldv;
    wire        sstrobe_ldv, cstrobe_ldv;
    wire [19:0] digits_ldv;
    ldp_ldv1000 #(.CLK_HZ(CLK_HZ)) u_ldv1000 (
        .clk(clk), .reset_n(reset_n), .pause(pause), .sel(sel_ldv1000),
        .cmd_stb(cmd_stb), .cmd_byte(cmd_byte),
        .cmd_action(act_ldv), .cmd_op(op_ldv), .cmd_arg(arg_ldv),
        .search_done(search_done), .autostop_done(autostop_done), .field_phase(field_phase),
        .status(status_ldv), .status_strobe(sstrobe_ldv), .command_strobe(cstrobe_ldv),
        .dbg_digits(digits_ldv)
    );

    // ---- PR-7820 ----
    wire [7:0]  status_pr78;
    wire        ready_n_pr78;
    wire [19:0] digits_pr78;
    ldp_pr7820 u_pr7820 (
        .clk(clk), .reset_n(reset_n), .pause(pause), .sel(sel_pr7820),
        .cmd_stb(cmd_stb), .cmd_byte(cmd_byte),
        .cmd_action(act_pr78), .cmd_op(op_pr78), .cmd_arg(arg_pr78),
        .search_busy(search_busy),
        .ready_n(ready_n_pr78), .status(status_pr78), .dbg_digits(digits_pr78)
    );

    // ---- PR-8210 ----
    wire        fvalid_pr82;
    wire [9:0]  word_pr82;
    ldp_pr8210 #(.CLK_HZ(CLK_HZ)) u_pr8210 (
        .clk(clk), .reset_n(reset_n), .pause(pause), .sel(sel_pr8210),
        .blip(blip),
        .cmd_action(act_pr82), .cmd_op(op_pr82), .cmd_arg(arg_pr82),
        .mode(mode),
        .frame_valid(fvalid_pr82), .dbg_word(word_pr82)
    );

    // ---- Sony LDP-1450 ----
    wire        txv_sony;
    wire [7:0]  txb_sony;
    wire [19:0] digits_sony;
    ldp_ldp1450 #(.CLK_HZ(CLK_HZ)) u_ldp1450 (
        .clk(clk), .reset_n(reset_n), .pause(pause), .sel(sel_ldp1450),
        .cmd_stb(cmd_stb), .cmd_byte(cmd_byte),
        .cmd_action(act_sony), .cmd_op(op_sony), .cmd_arg(arg_sony),
        .mode(mode), .curr_frame(curr_frame),
        .tx_valid(txv_sony), .tx_byte(txb_sony), .tx_pop(tx_pop && sel_ldp1450),
        .dbg_digits(digits_sony),
        .txt_we(txt_we_sony), .txt_line(txt_line), .txt_col(txt_col),
        .txt_glyph(txt_glyph), .txt_on(txt_on_sony),
        .txt_x(txt_x), .txt_y(txt_y)
    );
    // Gate on selection so a non-Sony game can never be given text to draw.
    wire txt_we_sony, txt_on_sony;
    assign txt_we = txt_we_sony & sel_ldp1450;
    assign txt_on = txt_on_sony & sel_ldp1450;

    // ---- CPU-side muxes ----
    // A player without strobes idles them high; one without /READY idles it low
    // (b7 = ready), so an unselected front-end can never assert a board line.
    assign status         = sel_pr7820 ? status_pr78 : status_ldv;
    assign status_strobe  = sel_ldv1000 ? sstrobe_ldv : 1'b1;
    assign command_strobe = sel_ldv1000 ? cstrobe_ldv : 1'b1;
    assign ready_n        = sel_pr7820 ? ready_n_pr78 : 1'b0;
    assign frame_valid    = sel_pr8210 ? fvalid_pr82  : 1'b1;
    assign tx_valid       = sel_ldp1450 ? txv_sony : 1'b0;
    assign tx_byte        = txb_sony;

    assign dbg_end_frame  = sel_pr7820  ? digits_pr78 :
                            sel_pr8210  ? {10'd0, word_pr82} :
                            sel_ldp1450 ? digits_sony : digits_ldv;
    assign dbg_flags      = 4'd0;
endmodule
