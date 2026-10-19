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
    parameter [31:0] CLK_HZ = 32'd80_000_000,
    // PR-8210 one/zero bit boundary, microseconds.  Default suits Cliff Hanger
    // and Goal To Go, which bit-bang the blip (~705us zero / ~1035us one).
    // Gottlieb drives it from a 555: 998us = 0, 1996us = 1, boundary ~1497.
    parameter [31:0] BIT_ONE_US = 32'd870,
    // Boundary used while pr8210_555 is high (Gottlieb / M.A.C.H. 3 board).
    parameter [31:0] BIT_ONE_US_555 = 32'd1497,
    parameter  [7:0] LDV_ROM_INDEX = 8'd5,       // firmware ROM ioctl index
    parameter  [3:0] LDV_FILM_PHASE = 4'd0,      // ldv_mech FILM_PHASE
    parameter [15:0] LDV_MOTOR_STOP_MS = 16'd0,  // ldv1000_fw MOTOR_STOP_MS (0 = MAME)
    parameter  [0:0] LDV_VSYNC_GATE = 1'b0,      // ldv1000_fw VSYNC_GATE (0 = MAME)
    parameter  [0:0] LDV_LIVE_CMD = 1'b0,        // ldv1000_fw LIVE_CMD (0 = MAME)
    parameter  [9:0] LDV_SEEK_FAST = 10'd133     // ldv1000_fw SEEK_FAST (133 = MAME)
)
(
    input             clk,
    input             reset_n,

    input      [3:0]  player_sel,      // see PLAYER_* below
    input             pr8210_555,      // PR-8210 blips come from a 555 (BIT_ONE_US_555)

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
    output      [1:0] audio_en,         // {channel 1, channel 2} on, from the transport
    output     [16:0] dbg_seek_frame,
    output     [19:0] dbg_end_frame,
    output      [3:0] dbg_flags,
    input       [3:0] post_seek_frames,
    input             disc_2997,       // .dlv encode rate -> transport film tick
    input      [16:0] park_frame,      // disc's first content frame; 0 = rest at frame 1
    input             status_rd,       // 1-cyc at the END of a CPU status read

    // ---- text overlay feed (LDP-1450 family only; inert for the others) ----
    // The character generator belongs to the PLAYER, not the game: any board on
    // an LDP-1450 gets on-screen text without contributing anything.
    output            txt_we,
    output      [1:0] txt_line,
    output      [5:0] txt_col,
    output      [7:0] txt_glyph,
    output            txt_on,
    output      [7:0] txt_x,
    output      [7:0] txt_y,
    // ---- LD-V1000 on its real firmware ----
    input             ldv_fw_en,       // sampled while reset_n is low
    input             cmd_oe,          // host is driving the LD bus (else it floats: pull-ups -> FF)
    output            ldv_fw,
    input             ioctl_download,
    input      [7:0]  ioctl_index,
    input      [24:0] ioctl_addr,
    input      [7:0]  ioctl_dout,
    input             ioctl_wr,
    output chip_pool_pkg::z80_i_t z80_i,
    input  chip_pool_pkg::z80_o_t z80_o,
    output            z80_rst_n
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
        .disc_2997(disc_2997), .park_frame(park_frame),
        .search_cmd_o(search_cmd_o), .play_end_o(play_end_o), .playing(playing),
        .dbg_seek_frame(dbg_seek_frame),
        .audio_en(audio_en)
    );

    // ---- LD-V1000: firmware or HLE ----
    reg         fw_req;
    wire        fw_ready;
    always @(posedge clk) if (!reset_n) fw_req <= ldv_fw_en;
    wire        use_fw = sel_ldv1000 & fw_req & fw_ready;
    assign      ldv_fw = use_fw;

    wire [7:0]  status_ldv, status_hle, status_fw;
    wire        sstrobe_ldv, cstrobe_ldv, sstrobe_hle, cstrobe_hle, sstrobe_fw, cstrobe_fw;
    wire [19:0] digits_ldv, digits_hle, digits_fw;
    wire        act_hle, act_fw;
    wire [3:0]  op_hle, op_fw;
    wire [16:0] arg_hle, arg_fw;
    assign act_ldv     = use_fw ? act_fw     : act_hle;
    assign op_ldv      = use_fw ? op_fw      : op_hle;
    assign arg_ldv     = use_fw ? arg_fw     : arg_hle;
    assign status_ldv  = use_fw ? status_fw  : status_hle;
    assign sstrobe_ldv = use_fw ? sstrobe_fw : sstrobe_hle;
    assign cstrobe_ldv = use_fw ? cstrobe_fw : cstrobe_hle;
    assign digits_ldv  = use_fw ? digits_fw  : digits_hle;

    ldp_ldv1000 #(.CLK_HZ(CLK_HZ)) u_ldv1000 (
        .clk(clk), .reset_n(reset_n), .pause(pause), .sel(sel_ldv1000 & ~use_fw),
        .cmd_stb(cmd_stb), .cmd_byte(cmd_byte),
        .cmd_action(act_hle), .cmd_op(op_hle), .cmd_arg(arg_hle),
        .search_done(search_done), .autostop_done(autostop_done), .field_phase(field_phase),
        .curr_frame(curr_frame), .status_rd(status_rd),
        .status(status_hle), .status_strobe(sstrobe_hle), .command_strobe(cstrobe_hle),
        .dbg_digits(digits_hle)
    );

    // frozen through the seek hold, like the transport (its head would run ahead otherwise)
    ldv1000_fw #(.CLK_HZ(CLK_HZ), .ROM_INDEX(LDV_ROM_INDEX), .ROM_BASE(25'h0), .FILM_PHASE(LDV_FILM_PHASE),
                 .MOTOR_STOP_MS(LDV_MOTOR_STOP_MS), .VSYNC_GATE(LDV_VSYNC_GATE), .LIVE_CMD(LDV_LIVE_CMD),
                 .SEEK_FAST(LDV_SEEK_FAST)) u_ldv1000_fw (
        .clk(clk), .reset_n(reset_n), .pause(pause | disc_hold), .sel(sel_ldv1000 & fw_req),
        .cmd_stb(cmd_stb), .cmd_byte(cmd_byte),
        .cmd_action(act_fw), .cmd_op(op_fw), .cmd_arg(arg_fw),
        .search_done(search_done), .autostop_done(autostop_done), .field_phase(field_phase),
        .status_rd(status_rd), .curr_frame(curr_frame),
        .status(status_fw), .status_strobe(sstrobe_fw), .command_strobe(cstrobe_fw),
        .dbg_digits(digits_fw),
        .t_mode(mode), .field_tick(frame_tick), .disc_last_frame(17'd0), .film(~disc_2997),
        .ioctl_download(ioctl_download), .ioctl_index(ioctl_index), .ioctl_addr(ioctl_addr),
        .ioctl_dout(ioctl_dout), .ioctl_wr(ioctl_wr), .cmd_oe(cmd_oe),
        .z80_i(z80_i), .z80_o(z80_o), .z80_rst_n(z80_rst_n), .fw_ready(fw_ready),
        .video_squelch(), .audio_squelch(),
        .dbg_track(), .dbg_ctl_rd(), .dbg_ctl_val(), .dbg_disp_we(), .dbg_disp_sel(), .dbg_disp_dat(),
        .dbg_fieldnum(), .dbg_class(), .dbg_irq(), .dbg_ppi0_pa(), .dbg_ppi0_pc(), .dbg_ppi1_pb(),
        .dbg_ppi1_pc(), .dbg_counter(), .dbg_fetch()
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
    ldp_pr8210 #(.CLK_HZ(CLK_HZ), .BIT_ONE_US(BIT_ONE_US), .BIT_ONE_US_ALT(BIT_ONE_US_555)) u_pr8210 (
        .clk(clk), .reset_n(reset_n), .pause(pause), .sel(sel_pr8210), .alt_bit(pr8210_555),
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
        // DIAG-REVERT-2026-10-15: original below, uncomment to restore
        // .mode(mode), .curr_frame(curr_frame), .autostop_done(autostop_done),
        .mode(mode), .curr_frame(curr_frame), .autostop_done(autostop_done), .search_done(search_done),   // DIAG
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
