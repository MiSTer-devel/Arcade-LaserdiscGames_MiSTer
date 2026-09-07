//============================================================================
// ldp_transport.sv — the disc mechanism, shared by every LD player front-end.
//
// Owns disc motion: frame counter, film tick, field tick, seek timing, the
// post-seek tail drain, autostop, per-channel audio enables and the video
// contract (search_cmd_o / play_end_o / curr_frame / playing).  None of this
// depends on which controller board is bolted to the player, so a new player
// is a new front-end and nothing here changes.
//
// Behaviour is a 1:1 port of the transport half of DragonsLair_LDV1000.sv;
// protocol bytes, status codes and strobes now live in the front-ends.
//============================================================================
module ldp_transport
#(
    parameter [31:0] CLK_HZ = 32'd80_000_000
)
(
    input             clk,
    input             reset_n,          // active-low

    // ---- command bus (from the selected front-end) ----
    input             cmd_action,       // 1-cyc: an action opcode was accepted
    input      [3:0]  cmd_op,
    input      [16:0] cmd_arg,

    // ---- mechanism state (to the front-ends) ----
    output reg [2:0]  mode,
    output reg [16:0] curr_frame,
    output            search_busy,      // mode == M_SEARCH; PR-7820 drives /READY from this
    output reg        search_done,      // 1-cyc: a search completed successfully
    output reg        autostop_done,    // 1-cyc: the autostop frame compare fired
    output     [21:0] field_phase,      // fcnt, for front-ends that generate strobes
    output            frame_tick,       // 59.94 Hz field tick
    output            film_tick,        // 23.976 Hz disc-frame tick

    // ---- core-side controls ----
    input             pause,            // freeze disc motion + phase
    input             disc_hold,        // video path priming; freezes motion, not the phase
    input      [3:0]  post_seek_frames, // MRA-tunable tail drain length

    // ---- video / audio contract ----
    output reg        search_cmd_o,     // 1-cyc when a SEARCH commits (after the tail drain)
    output reg        play_end_o,       // 1-cyc when playback stops by any mechanism
    output            playing,          // gates the .dlv audio ring
    output reg [16:0] dbg_seek_frame
);
`include "ldp_bus.svh"

    reg  [16:0] search_frame;
    reg  [16:0] stop_frame;
    reg         stop_valid;
    reg         audio_en1, audio_en2;
    reg  [4:0]  play_speed_q4;
    reg  [1:0]  speed_acc;
    reg  [3:0]  seek_tail_cnt;

    // Busy-report countdown in field ticks (59.94 Hz), holding Daphne's 0.5 s search fiction.
    // Times the STATUS report only -- the disc POSITION lands atomically.
    localparam [5:0] SEARCH_TICKS = 6'd30;
    reg  [5:0]  search_delay;

    assign search_busy = (mode == M_SEARCH);

    // MAME update_audio_enable(): unmute only at mode==PLAY && speed==1x && both channels on.
    // Stay "playing" through the tail drain so audio does not mute early.
    assign playing = ((mode == M_PLAY) || (mode == M_SEARCH && seek_tail_cnt != 4'd0))
                     && (play_speed_q4 == 5'd4) && audio_en1 && audio_en2;

    // Wall-clock periods scaled from CLK_HZ -- mind the widths, a narrow one truncates silently.
    // The field tick is 59.94 Hz (Daphne ldp.cpp:703); the disc frame advances at the FILM rate.
    localparam [21:0] PARK_PERIOD = (64'd1001 * CLK_HZ) / 64'd60000;
    localparam [21:0] PLAY_PERIOD = (64'd1001 * CLK_HZ) / 64'd60000;
    localparam [21:0] SCAN_PERIOD = (64'd20000 * CLK_HZ) / 64'd40_000_000;
    localparam [21:0] FILM_PERIOD = (64'd1001 * CLK_HZ) / 64'd24000;

    wire [21:0] period = (mode==M_PARK) ? PARK_PERIOD :
                         ((mode==M_SCAN_FWD || mode==M_SCAN_REV) ? SCAN_PERIOD : PLAY_PERIOD);
    reg  [21:0] fcnt;
    reg  [21:0] vcnt;
    assign frame_tick  = (fcnt >= period - 22'd1);
    assign film_tick   = (vcnt >= FILM_PERIOD - 22'd1);
    assign field_phase = fcnt;

    // Written as the SAME expression as the advance gate below so the two cannot drift apart.
    wire disc_moving = (mode == M_PLAY) && !disc_hold;
    reg  disc_moving_q;
    wire motion_rise = disc_moving && !disc_moving_q;

    // variable-speed PLAY advance this tick, q4 fixed-point.
    wire [4:0] speed_sum = {3'd0, speed_acc} + play_speed_q4;
    wire [2:0] speed_adv = speed_sum[4:2];
    wire [1:0] speed_rem = speed_sum[1:0];

    // Segment-boundary probe: latches at the play/stop edges so still-frame seeks never disturb it.
    wire seg_playing = (mode == M_PLAY) && (play_speed_q4 != 5'd0);
    reg  seg_playing_q;
    reg  [16:0] seg_start_frame;

    always_ff @(posedge clk) begin
        play_end_o <= 1'b0;   // default low -> always a 1-cycle pulse
        if (!reset_n) begin
            seg_playing_q   <= 1'b0;
            seg_start_frame <= 17'd0;
            dbg_seek_frame  <= 17'd0;
        end else begin
            seg_playing_q <= seg_playing;
            if (!seg_playing && seg_playing_q) play_end_o <= 1'b1;
            // Latches when playback STARTS, live, showing what the Z80 ASKED FOR.
            if (seg_playing && !seg_playing_q) begin
                seg_start_frame <= curr_frame;
                dbg_seek_frame  <= search_frame;
            end
        end
    end

    always @(posedge clk) begin
        // Defaulted out here so both stay 1-cycle pulses even across a pause.
        search_cmd_o <= 1'b0;
        search_done  <= 1'b0;
        autostop_done <= 1'b0;
        if (!reset_n) begin
            mode <= M_PARK;
            search_frame <= 17'd0; stop_frame <= 17'd0; stop_valid <= 1'b0;
            curr_frame <= 17'd0; fcnt <= 22'd0; vcnt <= 22'd0;
            search_delay <= 6'd0;
            disc_moving_q <= 1'b0;
            audio_en1 <= 1'b1; audio_en2 <= 1'b1;
            play_speed_q4 <= 5'd4; speed_acc <= 2'd0;
            seek_tail_cnt <= 4'd0;
        end else if (!pause) begin     // paused -> hold all state (disc frozen, in sync)

            // Field phase. Deliberately NOT frozen by disc_hold: freezing fcnt gates frame_tick,
            // which gates the atomic land, which releases the hold -- that is a deadlock.
            if (frame_tick) fcnt <= 22'd0; else fcnt <= fcnt + 22'd1;

            // Free-running film-rate tick. motion_rise re-zeros the phase ONCE at the start of
            // motion (Daphne vldp_internal.c:272); it must not be held at 0 while stopped.
            if (film_tick)        vcnt <= 22'd0;
            else if (motion_rise) vcnt <= 22'd0;
            else                  vcnt <= vcnt + 22'd1;
            disc_moving_q <= disc_moving;

            // PLAY advances on the FILM tick. M_SEARCH's busy countdown and M_SCAN's head slew
            // stay on frame_tick -- they are wall-clock, not disc motion.
            if (film_tick && (mode == M_PLAY) && !disc_hold) begin
                curr_frame <= curr_frame + {14'd0, speed_adv};
                speed_acc  <= speed_rem;
                if (stop_valid && ((curr_frame + {14'd0, speed_adv}) >= stop_frame)) begin
                    mode <= M_STOP;
                    stop_valid <= 1'b0;
                    autostop_done <= 1'b1;
                end
            end

            // POST-SEEK TAIL DRAIN: keep advancing for post_seek_frames film ticks after a
            // SEARCH so the video/audio pipeline drains on old-segment content. The front-end
            // already reported busy to the CPU; only the video path is deferred.
            if (seek_tail_cnt != 4'd0) begin
                if (film_tick) begin
                    curr_frame <= curr_frame + {14'd0, speed_adv};
                    speed_acc  <= speed_rem;
                    if (seek_tail_cnt == 4'd1) begin
                        search_cmd_o  <= 1'b1;   // fires seek_flush / fb_seek_hold arm
                        seek_tail_cnt <= 4'd0;
                    end else begin
                        seek_tail_cnt <= seek_tail_cnt - 4'd1;
                    end
                end
            end

            // The land sits OUTSIDE the frame_tick gate on purpose: a hold must never freeze the
            // clock that satisfies its own release condition. Landing every clock while in
            // M_SEARCH is idempotent, matching Daphne's atomic land.
            if (mode == M_SEARCH && seek_tail_cnt == 4'd0) curr_frame <= search_frame;

            // ---- per-field mechanism, locked to the tick the games poll ----
            if (frame_tick) begin
                case (mode)
                    M_SEARCH: begin
                        if (search_delay != 6'd0 || disc_hold) begin
                            if (search_delay != 6'd0)
                                search_delay <= search_delay - 6'd1;
                        end else begin
                            mode <= M_STOP;
                            search_done <= 1'b1;   // front-end turns this into its own status
                        end
                    end
                    M_SCAN_FWD: curr_frame <= curr_frame + 17'd1;
                    M_SCAN_REV: if (curr_frame > 17'd0) curr_frame <= curr_frame - 17'd1;
                    default: ; // PARK / STOP: hold frame
                endcase
            end

            // ---- command bus ----
            if (cmd_action) begin
                // Arms the busy countdown for every M_SEARCH entry point at once. The
                // `mode != M_SEARCH` guard is required: re-arming mid-search pins busy,
                // the completion never fires and the core hangs.
                if (mode != M_SEARCH)
                    search_delay <= SEARCH_TICKS;

                case (cmd_op)
                    OP_SEARCH: begin
                        search_frame <= cmd_arg; mode <= M_SEARCH;
                        stop_valid <= 1'b0;
                        // Only arm the tail when we were actually PLAYING -- hold-frame seeks
                        // arrive from M_STOP/M_SEARCH and must flush instantly (no audio to drain).
                        if (post_seek_frames == 4'd0 || mode != M_PLAY)
                            search_cmd_o <= 1'b1;
                        else
                            seek_tail_cnt <= post_seek_frames;
                    end
                    OP_PLAY: begin
                        mode <= M_PLAY; stop_valid <= 1'b0;
                        play_speed_q4 <= 5'd4; speed_acc <= 2'd0;
                    end
                    OP_PLAY_SPD: begin
                        mode <= M_PLAY; stop_valid <= 1'b0;
                        play_speed_q4 <= cmd_arg[4:0]; speed_acc <= 2'd0;
                    end
                    OP_STOP:  mode <= M_STOP;
                    OP_PARK: begin
                        mode <= M_PARK;
                        stop_valid <= 1'b0; search_frame <= 17'd0; stop_frame <= 17'd0;
                    end
                    // Unconditional, matching Daphne ldv1000.cpp:263-274 -- always arm the
                    // boundary and always play.
                    OP_AUTOSTOP: begin
                        stop_frame <= cmd_arg; stop_valid <= 1'b1;
                        mode <= M_PLAY;
                    end
                    OP_STEP_FWD: begin
                        curr_frame <= curr_frame + 17'd1;
                        mode <= M_STOP;
                        stop_valid <= 1'b0; search_frame <= 17'd0; stop_frame <= 17'd0;
                    end
                    OP_STEP_REV: begin
                        curr_frame <= (curr_frame > 17'd0) ? curr_frame - 17'd1 : curr_frame;
                        mode <= M_STOP;
                        stop_valid <= 1'b0; search_frame <= 17'd0; stop_frame <= 17'd0;
                    end
                    OP_SCAN_FWD: begin
                        mode <= M_SCAN_FWD;
                        stop_valid <= 1'b0; search_frame <= 17'd0; stop_frame <= 17'd0;
                    end
                    OP_SCAN_REV: begin
                        mode <= M_SCAN_REV;
                        stop_valid <= 1'b0; search_frame <= 17'd0; stop_frame <= 17'd0;
                    end
                    // arg[1] = explicit set (a digit was typed), arg[0] = value; else toggle.
                    OP_AUDIO1: audio_en1 <= cmd_arg[1] ? cmd_arg[0] : ~audio_en1;
                    OP_AUDIO2: audio_en2 <= cmd_arg[1] ? cmd_arg[0] : ~audio_en2;
                    // Relative skip, simplified to a search.
                    // NOTE: carried over verbatim from DragonsLair_LDV1000.sv -- this does NOT
                    // fire search_cmd_o, so the video path never flushes on a skip. Neither DL
                    // nor Space Ace issues one. Flagged, deliberately not changed in the split.
                    OP_SKIP: begin
                        mode <= M_SEARCH; search_frame <= curr_frame + cmd_arg;
                        stop_valid <= 1'b0;
                    end
                    default: ;   // OP_NOP: consumes the accumulator in the front-end only
                endcase
            end
        end
    end
endmodule
