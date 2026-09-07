//============================================================================
// ldp_top.sv — laserdisc player wrapper.
//
// One shared transport plus one protocol front-end per player, selected at
// runtime by player_sel. Adding a player is: write ldp_<name>.sv, instantiate
// it here, add its PLAYER_* code and its rows to the three muxes. The
// transport is never touched.
//
// Port list matches the old DragonsLair_LDV1000 so the CPU wrapper only
// changes the module name and swaps `pr7820` for `player_sel`.
//============================================================================
module ldp_top
#(
    parameter [31:0] CLK_HZ = 32'd80_000_000
)
(
    input             clk,
    input             reset_n,
    input             cmd_stb,
    input      [7:0]  cmd_byte,
    output     [7:0]  status,          // -> 0xC020 laserdisc_r
    output            status_strobe,   // -> SYSTEM b6
    output            command_strobe,  // SYSTEM b7 = ~command_strobe
    input      [3:0]  player_sel,      // see PLAYER_* below
    output            ready_n,         // PR-7820 /READY -> SYSTEM b7
    output            search_cmd_o,
    output            play_end_o,
    output     [16:0] curr_frame,
    input             pause,
    input             disc_hold,
    output            playing,
    output     [16:0] dbg_seek_frame,
    output     [19:0] dbg_end_frame,   // raw SEARCH digits
    output      [3:0] dbg_flags,
    input       [3:0] post_seek_frames
);
    localparam [3:0] PLAYER_LDV1000 = 4'd0,
                     PLAYER_PR7820  = 4'd1;

    wire sel_ldv1000 = (player_sel == PLAYER_LDV1000);
    wire sel_pr7820  = (player_sel == PLAYER_PR7820);

    // ---- shared mechanism ----
    wire [2:0]  mode;
    wire        search_busy, search_done, autostop_done;
    wire [21:0] field_phase;
    wire        frame_tick, film_tick;

    // ---- per-front-end command buses ----
    wire        act_ldv, act_pr;
    wire [3:0]  op_ldv,  op_pr;
    wire [16:0] arg_ldv, arg_pr;

    wire        cmd_action = sel_pr7820 ? act_pr : act_ldv;
    wire [3:0]  cmd_op     = sel_pr7820 ? op_pr  : op_ldv;
    wire [16:0] cmd_arg    = sel_pr7820 ? arg_pr : arg_ldv;

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
    wire [7:0]  status_pr;
    wire        ready_n_pr;
    wire [19:0] digits_pr;

    ldp_pr7820 u_pr7820 (
        .clk(clk), .reset_n(reset_n), .pause(pause), .sel(sel_pr7820),
        .cmd_stb(cmd_stb), .cmd_byte(cmd_byte),
        .cmd_action(act_pr), .cmd_op(op_pr), .cmd_arg(arg_pr),
        .search_busy(search_busy),
        .ready_n(ready_n_pr), .status(status_pr), .dbg_digits(digits_pr)
    );

    // ---- CPU-side muxes ----
    // A player that has no strobes idles them high; a player that has no /READY idles it low
    // (b7 = "ready"), so an unselected front-end can never assert a line the board would see.
    assign status         = sel_pr7820 ? status_pr  : status_ldv;
    assign status_strobe  = sel_pr7820 ? 1'b1       : sstrobe_ldv;
    assign command_strobe = sel_pr7820 ? 1'b1       : cstrobe_ldv;
    assign ready_n        = sel_pr7820 ? ready_n_pr : 1'b0;
    assign dbg_end_frame  = sel_pr7820 ? digits_pr  : digits_ldv;
    assign dbg_flags      = 4'd0;
endmodule
