//============================================================================
// DragonsLair_LDV1000.sv — Pioneer LD-V1000 command/status controller (HLE)
//
// Ported from MAME pioneer_ldv1000hle_device (Useful Information/ldv1000hle.cpp).
// Decodes the Z80's digit/SEARCH/PLAY/STOP/AUTOSTOP stream, tracks the disc frame and
// returns status codes plus a per-field strobe.
//
// Strobes idle HIGH and assert LOW: SYSTEM b6 = status_strobe, b7 = ~command_strobe.
// A command is accepted whenever strobed rather than gated on STATUS_READY; the DL ROM only
// emits a byte after seeing the ready strobe, so this cannot drop one.
// `playing` requires BOTH audio channels enabled and speed == 1x, matching MAME's
// update_audio_enable().  The STORE/RECALL/DISPLAY/GET_* opcodes are accepted but inert,
// which is what MAME does too.
//============================================================================
module DragonsLair_LDV1000
#(
    // Core clock rate from CORE_CLK_HZ; FILM_PERIOD derives from it.
    parameter [31:0] CLK_HZ = 32'd80_000_000
)
(
    input             clk,            // clk_sys (80 MHz as of ; was 40 MHz)
    input             reset_n,        // active-low (core `reset`)
    input             cmd_stb,        // 1-cyc: a data/command byte was strobed out
    input      [7:0]  cmd_byte,       // that byte (0xE020 latch)
    output reg [7:0]  status,         // -> 0xC020 laserdisc_r
    output reg        status_strobe,  // -> SYSTEM b6   (idle 1, asserts low)
    output reg        command_strobe, // SYSTEM b7 = ~command_strobe (idle 1 => b7=0 ready)
    // 1-cycle pulse when a SEARCH command is ACCEPTED -- the command itself, not a frame-delta guess.
    output reg        search_cmd_o,
    // 1-cycle pulse when playback stops by any mechanism (CMD_STOP, CMD_REJECT, 0X, next SEARCH).
    output reg        play_end_o,
    output reg [16:0] curr_frame,     // current disc frame (0..54000) for the video path
    input             pause,          // freeze disc motion + strobes during pause
    // High while the video path primes after a seek.  Freezes ONLY disc motion, not the strobes.
    input             disc_hold,
    output            playing,        // mode==M_PLAY, speed==1x, AND both AUDIO1/2
                                       // channels enabled () -- gates the .dlv audio ring

    // Segment-boundary frame probe: dbg_seek_frame = where a SEARCH landed, dbg_end_frame =
    // curr_frame when playback stopped.  Each latches once per segment and holds.
    output reg [16:0] dbg_seek_frame,
    output     [19:0] dbg_end_frame,      // REPURPOSED -> raw SEARCH digits (5 nibbles)
    // Sticky autostop telemetry: bit0 = armed at least once, bit1 = compare has fired.
    output      [3:0] dbg_flags,
    // MRA-tunable tail drain length.  0 = old instant behaviour, 5 ≈ 5 film frames ≈ 208 ms.
    // Loaded from MRA index 1, byte 1 at startup.  Default 0 if MRA omits it.
    input       [3:0] post_seek_frames
);
    // ---- status codes (ldv1000hle.h) ----
    localparam [7:0] ST_PARK=8'h7c, ST_PLAY=8'h64, ST_STOP=8'h65,
                     ST_SEARCH=8'h50, ST_SEARCH_FIN=8'hd0, ST_READY=8'h80,
                     ST_SCAN=8'h4c, ST_FORWARD=8'h2e;
    // ---- modes (widened 2b->3b for SCAN, ) ----
    localparam [2:0] M_PARK=3'd0, M_SEARCH=3'd1, M_PLAY=3'd2, M_STOP=3'd3,
                     M_SCAN_FWD=3'd4, M_SCAN_REV=3'd5;
    // ---- action opcodes (byte values cross-checked vs ldv1000hle.h) ----
    localparam [7:0] CMD_CLEAR=8'hbf, CMD_SEARCH=8'hf7, CMD_PLAY=8'hfd,
                     CMD_STOP=8'hfb, CMD_AUTOSTOP=8'hf3,
                     CMD_AUDIO1=8'hf4, CMD_AUDIO2=8'hfc,
                     CMD_SCAN_FWD=8'hf0, CMD_SCAN_REV=8'hf8,
                     CMD_STEP_FWD=8'hf6, CMD_STEP_REV=8'hfe,
                     CMD_REJECT=8'hf9, CMD_NO_ENTRY=8'hff,
                     CMD_FWD_X0=8'ha0, CMD_FWD_X1_4=8'ha1, CMD_FWD_X1_2=8'ha2, CMD_FWD_X1=8'ha3,
                     CMD_FWD_X2=8'ha4, CMD_FWD_X3=8'ha5, CMD_FWD_X4=8'ha6, CMD_FWD_X5=8'ha7,
                     CMD_SKIP_FWD_10=8'hb1, CMD_SKIP_FWD_20=8'hb2, CMD_SKIP_FWD_30=8'hb3,
                     CMD_SKIP_FWD_40=8'hb4, CMD_SKIP_FWD_50=8'hb5, CMD_SKIP_FWD_60=8'hb6,
                     CMD_SKIP_FWD_70=8'hb7, CMD_SKIP_FWD_80=8'hb8, CMD_SKIP_FWD_90=8'hb9,
                     CMD_SKIP_FWD_100=8'hba,
                     // known-inert group (matches MAME's own unimplemented stubs, see header)
                     CMD_STORE=8'hf5, CMD_RECALL=8'h7f, CMD_DISPLAY=8'hf1,
                     CMD_DISPLAY_ENABLE=8'hce, CMD_DISPLAY_DISABLE=8'hcd,
                     CMD_GET_FRAME_NUM=8'hc2, CMD_GET_2ND_DISPLAY=8'hc3, CMD_GET_1ST_DISPLAY=8'hc4,
                     CMD_TRANSFER_MEMORY=8'hc8, CMD_LOAD=8'hcc;

    // digit opcode -> 0..9 (0xf = not a digit)
    function [3:0] digit_of(input [7:0] op);
        case (op)
            8'h3f: digit_of=4'd0; 8'h0f: digit_of=4'd1; 8'h8f: digit_of=4'd2;
            8'h4f: digit_of=4'd3; 8'h2f: digit_of=4'd4; 8'haf: digit_of=4'd5;
            8'h6f: digit_of=4'd6; 8'h1f: digit_of=4'd7; 8'h9f: digit_of=4'd8;
            8'h5f: digit_of=4'd9; default: digit_of=4'hf;
        endcase
    endfunction

    reg  [2:0]  mode;
    reg  [16:0] number;         // accumulated entered frame number
    reg  [16:0] search_frame;
    // Busy-report countdown in frame_ticks, holding Daphne's 0.5 s search fiction (ticks are
    // 59.94 Hz, so 30).  Times the STATUS report only -- the disc POSITION lands atomically.
    localparam [4:0] SEARCH_TICKS = 5'd30;   // 0.5 s at 59.94 Hz
    reg  [4:0]  search_delay;

    // ---- POST-SEEK TAIL DRAIN ----
    // When CMD_SEARCH (0xF7) is received the Z80 protocol requires status to immediately
    // report ST_SEARCH (busy), but the real LD-V1000 disc keeps spinning until the head
    // physically lifts.  The game software and animation were authored around that: the last
    // ~5 film frames of every scene play out during the command-entry sequence BEFORE 0xF7,
    // but the video/audio pipeline has 60-100 ms of latency, so those frames are still in
    // flight when we would normally commit the seek.
    //
    // post_seek_frames: extra film ticks to hold curr_frame advancing and playing=1 after
    // CMD_SEARCH, before committing the atomic land and firing search_cmd_o.
    // The Z80 sees ST_SEARCH immediately (status is set at command-receive time below).
    // Tune by ear: 0 = old instant behaviour, 5 ≈ 208 ms ≈ 5 film frames.
    // Value comes from the post_seek_frames port (MRA index 1, byte 1).
    // (was: localparam [3:0] post_seek_frames = 4'd3)
    reg  [3:0]  seek_tail_cnt;   // counts down film ticks remaining before committing the seek
    reg  [16:0] stop_frame;
    reg         stop_valid;
    reg         audio_en1, audio_en2;   // per-channel enable, MAME default = both on
    reg         has_digit;              // distinguishes "no digits typed" (toggle) from "digit typed" (explicit set)
    // raw SEARCH digit capture (5 nibbles, newest in the low 4 bits)
    reg  [19:0] dig_sr;                 // shifts in every digit opcode as received
    reg  [19:0] dig_latched;            // frozen at CMD_SEARCH -> P2
    reg  [4:0]  play_speed_q4;          // fixed-point x4 (4=1x), CMD_FWD_X*
    reg  [1:0]  speed_acc;              // fractional remainder for sub/multi-1x frame advance

    // MAME's update_audio_enable() only unmutes at mode==PLAY && speed==1.0
    // Also stay "playing" during the post-seek tail drain so audio doesn't mute prematurely.
    assign playing = ((mode == M_PLAY) || (mode == M_SEARCH && seek_tail_cnt != 4'd0))
                     && (play_speed_q4 == 5'd4) && audio_en1 && audio_en2;

    // Wall-clock periods, scaled from CLK_HZ -- mind the register widths, a narrow one truncates
    // silently.  The LD-V1000 strobes once per FIELD (59.94 Hz), not per frame (Daphne ldp.cpp:703).
    localparam [21:0] PARK_PERIOD = (64'd1001 * CLK_HZ) / 64'd60000;          // FABLE-D1: 16.683 ms
    localparam [21:0] PLAY_PERIOD = (64'd1001 * CLK_HZ) / 64'd60000;          // 16.683 ms = 1/59.94 s (Daphne vblank)
    localparam [21:0] SCAN_PERIOD = (64'd20000   * CLK_HZ) / 64'd40_000_000;  // 500 us = 1/2000 s
    localparam [21:0] STAT_LOW    = (64'd1040    * CLK_HZ) / 64'd40_000_000;  // 26 us status-strobe low
    localparam [21:0] CMD_LO_S    = (64'd2160    * CLK_HZ) / 64'd40_000_000;  // 54 us command-strobe start
    localparam [21:0] CMD_LO_E    = (64'd3160    * CLK_HZ) / 64'd40_000_000;  // 79 us command-strobe end (25 us)
    wire [21:0] period = (mode==M_PARK) ? PARK_PERIOD :
                         ((mode==M_SCAN_FWD || mode==M_SCAN_REV) ? SCAN_PERIOD : PLAY_PERIOD);
    reg  [21:0] fcnt;
    wire        frame_tick = (fcnt >= period - 22'd1);   // strobe/vsync tick -- UNCHANGED (29.97)

    // The DISC FRAME advances at the FILM rate (23.976 fps, Daphne game/lair.cpp m_disc_fps,
    // equal to the m2v's 24000/1001 so the map is a pure 1:1 offset), NOT the vsync rate.
    // Strobes stay on frame_tick because DL polls them to sequence command bytes.
    localparam [21:0] FILM_PERIOD = (64'd1001 * CLK_HZ) / 64'd24000;   // 41.708 ms = 1001/24000 s
    reg  [21:0] vcnt;
    wire        film_tick = (vcnt >= FILM_PERIOD - 22'd1);

    // Written as the SAME expression as the advance gate below so the two cannot drift apart.
    wire        disc_moving = (mode == M_PLAY) && !disc_hold;
    reg         disc_moving_q;
    wire        motion_rise = disc_moving && !disc_moving_q;

    // Segment-boundary probe: watches whether the disc is actually playing and latches the
    // frame at the two edges, so still-frame seeks never disturb it.
    localparam [16:0] MIN_SEG_FRAMES = 17'd12;

    wire seg_playing = (mode == M_PLAY) && (play_speed_q4 != 5'd0);
    reg  seg_playing_q;
    reg  [16:0] seg_start_frame;                        // PENDING -- not displayed
    wire [16:0] seg_len = curr_frame - seg_start_frame; // only meaningful when it ran forward

    always_ff @(posedge clk) begin
        play_end_o <= 1'b0;   // default low -> always a 1-cycle pulse
        if (!reset_n) begin
            seg_playing_q   <= 1'b0;
            seg_start_frame <= 17'd0;
            dbg_seek_frame  <= 17'd0;
        end else begin
            seg_playing_q <= seg_playing;
            // playback just stopped, by whatever mechanism.
            if (!seg_playing && seg_playing_q) play_end_o <= 1'b1;

        // P1 latches when playback STARTS, live, so the first frame shows while it plays.
        // Still-frame seeks park in M_STOP and never reach here.
            if (seg_playing && !seg_playing_q) begin
                seg_start_frame <= curr_frame;
                // P1 now shows what the Z80 ASKED FOR, not where we
                // happened to be when play started. search_frame holds the last SEARCH target
                // until the next SEARCH, so it is still valid here.
                dbg_seek_frame  <= search_frame;
            end

            // P2: playback ENDED -> only latch if this was a real SEGMENT, never a hold.
            // A hold advances ~0 frames and so cannot wipe the value you are still reading.
            if (!seg_playing && seg_playing_q) begin
                ; // P2 no longer shows segment end -- it shows raw digits
            end
        end
    end

    assign dbg_end_frame = dig_latched;   // raw digits -> P2
    assign dbg_flags     = 4'd0;          // P1 leading digit: unused, reads 0

    wire [3:0]  dig = digit_of(cmd_byte);

    // variable-speed PLAY advance this tick, q4 fixed-point.
    // At 1x (play_speed_q4=4) this always resolves to +1/tick, remainder 0 -- identical
    wire [4:0] speed_sum = {3'd0, speed_acc} + play_speed_q4;
    wire [2:0] speed_adv = speed_sum[4:2];
    wire [1:0] speed_rem = speed_sum[1:0];

    always @(posedge clk) begin
        // Defaulted LOW out here so search_cmd_o is always a 1-cycle pulse; inside the !pause
        // branch a pause just after a SEARCH would freeze it HIGH for the whole pause.
        search_cmd_o <= 1'b0;
        if (!reset_n) begin
            mode <= M_PARK; status <= ST_PARK | ST_READY;   // 0xFC
            number <= 17'd0; search_frame <= 17'd0; stop_frame <= 17'd0;
            stop_valid <= 1'b0; curr_frame <= 17'd0; fcnt <= 22'd0;   // fcnt/vcnt widened 21->22
            search_delay <= 5'd0;
            vcnt <= 22'd0;
            disc_moving_q <= 1'b0;  // (rev 2)
            status_strobe <= 1'b1; command_strobe <= 1'b1;
            audio_en1 <= 1'b1; audio_en2 <= 1'b1; has_digit <= 1'b0;
            dig_sr <= 20'd0; dig_latched <= 20'd0;
            play_speed_q4 <= 5'd4; speed_acc <= 2'd0;
            seek_tail_cnt <= 4'd0;
        end else if (!pause) begin     // paused -> hold all state (disc frozen, in sync)
    // ---- strobe generator (idle high, assert low) ----
    // Deliberately NOT frozen by disc_hold: freezing fcnt gates frame_tick, which gates the
    // atomic land, which releases the hold -- that is a deadlock.
            if (frame_tick) fcnt <= 22'd0; else fcnt <= fcnt + 22'd1;
            status_strobe  <= ~(fcnt < STAT_LOW);
            command_strobe <= ~((fcnt >= CMD_LO_S) & (fcnt < CMD_LO_E));

    // Free-running film-rate tick.  motion_rise re-zeros the phase ONCE at the start of motion,
    // matching Daphne (vldp_internal.c:272); it must not be held at 0 for the whole stopped state.
            if (film_tick)        vcnt <= 22'd0;
            else if (motion_rise) vcnt <= 22'd0;   // Daphne: s_timer = uMsTimer at play/seek
            else                  vcnt <= vcnt + 22'd1;
            disc_moving_q <= disc_moving;          // (rev 2)

        // PLAY advances on the FILM tick, not the strobe tick.  M_SEARCH's busy countdown and
        // M_SCAN's head slew stay on frame_tick -- they are wall-clock, not disc motion.
            if (film_tick && (mode == M_PLAY) && !disc_hold) begin
                curr_frame <= curr_frame + {14'd0, speed_adv};
                speed_acc  <= speed_rem;
                if (stop_valid && ((curr_frame + {14'd0, speed_adv}) >= stop_frame)) begin
                    mode <= M_STOP; status <= ST_STOP | ST_READY;
                    stop_valid <= 1'b0;
                end
            end

        // POST-SEEK TAIL DRAIN: after CMD_SEARCH we keep advancing curr_frame for
        // post_seek_frames film ticks so the video/audio pipeline drains naturally before
        // we commit the seek.  The Z80 already sees ST_SEARCH status; only the video path
        // (curr_frame, playing, search_cmd_o) is deferred.
            if (seek_tail_cnt != 4'd0) begin
                if (film_tick) begin
                    curr_frame <= curr_frame + {14'd0, speed_adv};   // keep disc moving
                    speed_acc  <= speed_rem;
                    if (seek_tail_cnt == 4'd1) begin
                        // Tail expired: commit the seek now.
                        search_cmd_o  <= 1'b1;   // fires seek_flush / fb_seek_hold arm
                        seek_tail_cnt <= 4'd0;
                        // From here the atomic land below takes over (mode == M_SEARCH).
                    end else begin
                        seek_tail_cnt <= seek_tail_cnt - 4'd1;
                    end
                end
            end

        // The land sits OUTSIDE the frame_tick gate on purpose: a hold must never freeze the clock
        // that satisfies its own release condition.  Daphne lands atomically at the command and only
        // REPORTS busy, so landing every clock while in M_SEARCH is idempotent.
        // Only land once the tail has expired (seek_tail_cnt == 0); while it is counting the disc
        // is still advancing above and curr_frame must not be overwritten.
            if (mode == M_SEARCH && seek_tail_cnt == 4'd0) curr_frame <= search_frame;

            // ---- per-frame disc motion, locked to the strobe the game reads ----
            if (frame_tick) begin
                case (mode)
                    // curr_frame is landed by the ungated assignment above regardless, so the
                    // streamer fetches and primes during this wait; it is not a deadlock.
                    // fb_seek_hold's own SEEK_TMO (~1 s) is the backstop if priming never completes.
                    M_SEARCH: begin
                        if (search_delay != 5'd0 || disc_hold) begin
                            if (search_delay != 5'd0)
                                search_delay <= search_delay - 5'd1; // still "busy": status stays ST_SEARCH (0x50)
                        end else begin
                            mode <= M_STOP; status <= ST_SEARCH_FIN;   // 0xd0 (ready) -- Daphne's "search succeeded d0"
                        end
                    end
                    M_SCAN_FWD: curr_frame <= curr_frame + 17'd1;
                    M_SCAN_REV: if (curr_frame > 17'd0) curr_frame <= curr_frame - 17'd1;
                    default: ; // PARK / STOP: hold frame
                endcase
            end

    // ---- command reception ----
    // ONE byte per ready window (Daphne ldp-in/ldv1000.cpp:173-179): accepting a command clears
    // bit 7, and only 0xFF re-arms it.  0xFF is the handshake ACK, not idle filler -- it must be
    // fully inert and must not touch `number` or `has_digit`, or a multi-digit SEARCH accumulates
    // wrong.  A real SEARCH is 0xBF, 0xFF, d, 0xFF, d, 0xFF, d, 0xFF, d, 0xFF, d, 0xFF, 0xF7.
            if (cmd_stb) begin
                if (cmd_byte == CMD_NO_ENTRY) begin
                    // Daphne: 0xFF always ends READY, in both the ready and not-ready paths.
                    status <= status | ST_READY;
                end else if (!status[7]) begin
                    // NOT READY + non-0xFF => ignore the byte ENTIRELY (Daphne lines 431-435).
                    status <= status & 8'h7f;
                end else if (dig != 4'hf) begin
                    status <= status & 8'h7f;                     // Daphne line 176: consumed => not ready
                    number <= (number * 17'd10) + {13'd0, dig};   // decimal accumulate
                    has_digit <= 1'b1;
                    // capture the RAW digit nibbles as received, BEFORE
                    // accumulation, so P2 shows what the Z80 actually sent rather than what we
                    // decoded it into. Shift-in keeps the last 5 digits; a SEARCH latches them.
                    dig_sr <= {dig_sr[15:0], dig};
                end else begin
                    status <= status & 8'h7f;   // Daphne line 176 (case below may override, as it does there)
                    has_digit <= 1'b0;   // every action opcode consumes the accumulator
        // Arms the busy countdown for all M_SEARCH entry points at once.  The `mode != M_SEARCH`
        // guard is required: re-arming mid-search pins status busy, ST_SEARCH_FIN never fires and
        // the core hangs waiting for a completion that cannot arrive.
                    if (mode != M_SEARCH) search_delay <= SEARCH_TICKS;
                    case (cmd_byte)
                        CMD_CLEAR:   begin number <= 17'd0; dig_sr <= 20'd0; end   // restart digit capture
                        CMD_SEARCH: begin
                            dig_latched <= dig_sr;   // freeze what the Z80 SENT
                            dig_sr      <= 20'd0;
                            search_frame <= number; mode <= M_SEARCH;
                            status <= ST_SEARCH;              // 0x50 busy -- Z80 sees this immediately
                            stop_valid <= 1'b0; number <= 17'd0;
                            // search_cmd_o (-> seek_flush, fb_seek_hold) is DEFERRED: the tail
                            // drain counts down post_seek_frames film ticks first so the video
                            // and audio pipeline drains on old-segment content.  When the counter
                            // hits 1->0 in the film_tick block above, search_cmd_o fires then.
                            // Only arm the tail when we were actually PLAYING -- hold-frame seeks
                            // arrive from M_STOP/M_SEARCH and must flush instantly (no audio to drain).
                            if (post_seek_frames == 4'd0 || mode != M_PLAY)
                                search_cmd_o <= 1'b1;
                            else
                                seek_tail_cnt <= post_seek_frames;
                        end
                        CMD_PLAY: begin
                            mode <= M_PLAY; status <= ST_PLAY; // 0x64
                            stop_valid <= 1'b0; number <= 17'd0;
                            play_speed_q4 <= 5'd4; speed_acc <= 2'd0;   // always 1x
                        end
                        CMD_STOP: begin
                            mode <= M_STOP; status <= ST_STOP | ST_READY;
                            number <= 17'd0;
                        end
                    // Unconditional, matching Daphne ldv1000.cpp:263-274 -- always arm the boundary
                    // and always play.  The old `number < curr_frame` search-back branch was an invention.
                        CMD_AUTOSTOP: begin
                            stop_frame <= number; stop_valid <= 1'b1;
                            mode <= M_PLAY; status <= ST_PLAY;
                            number <= 17'd0;
                        end
                        CMD_AUDIO1: begin   // no digit -> toggle, digit N -> set to N&1
                            audio_en1 <= has_digit ? number[0] : ~audio_en1;
                            number <= 17'd0;
                        end
                        CMD_AUDIO2: begin
                            audio_en2 <= has_digit ? number[0] : ~audio_en2;
                            number <= 17'd0;
                        end

                        // ---- SCAN / STEP / REJECT / NO_ENTRY ----
                        CMD_SCAN_FWD: begin
                            mode <= M_SCAN_FWD; status <= ST_SCAN;
                            stop_valid <= 1'b0; search_frame <= 17'd0; stop_frame <= 17'd0; number <= 17'd0;
                        end
                        CMD_SCAN_REV: begin
                            mode <= M_SCAN_REV; status <= ST_SCAN;
                            stop_valid <= 1'b0; search_frame <= 17'd0; stop_frame <= 17'd0; number <= 17'd0;
                        end
                        CMD_STEP_FWD: begin
                            curr_frame <= curr_frame + 17'd1;
                            mode <= M_STOP; status <= ST_STOP | ST_READY;
                            stop_valid <= 1'b0; search_frame <= 17'd0; stop_frame <= 17'd0; number <= 17'd0;
                        end
                        CMD_STEP_REV: begin
                            curr_frame <= (curr_frame > 17'd0) ? curr_frame - 17'd1 : curr_frame;
                            mode <= M_STOP; status <= ST_STOP | ST_READY;
                            stop_valid <= 1'b0; search_frame <= 17'd0; stop_frame <= 17'd0; number <= 17'd0;
                        end
                        CMD_REJECT: begin
                            mode <= M_PARK; status <= ST_PARK | ST_READY;
                            stop_valid <= 1'b0; search_frame <= 17'd0; stop_frame <= 17'd0; number <= 17'd0;
                        end

                        // ---- variable-speed forward play ----
                        CMD_FWD_X0: begin
                            mode <= M_PLAY; status <= ST_FORWARD; play_speed_q4 <= 5'd0; speed_acc <= 2'd0;
                            stop_valid <= 1'b0; number <= 17'd0;
                        end
                        CMD_FWD_X1_4: begin
                            mode <= M_PLAY; status <= ST_FORWARD; play_speed_q4 <= 5'd1; speed_acc <= 2'd0;
                            stop_valid <= 1'b0; number <= 17'd0;
                        end
                        CMD_FWD_X1_2: begin
                            mode <= M_PLAY; status <= ST_FORWARD; play_speed_q4 <= 5'd2; speed_acc <= 2'd0;
                            stop_valid <= 1'b0; number <= 17'd0;
                        end
                        CMD_FWD_X1: begin
                            mode <= M_PLAY; status <= ST_FORWARD; play_speed_q4 <= 5'd4; speed_acc <= 2'd0;
                            stop_valid <= 1'b0; number <= 17'd0;
                        end
                        CMD_FWD_X2: begin
                            mode <= M_PLAY; status <= ST_FORWARD; play_speed_q4 <= 5'd8; speed_acc <= 2'd0;
                            stop_valid <= 1'b0; number <= 17'd0;
                        end
                        CMD_FWD_X3: begin
                            mode <= M_PLAY; status <= ST_FORWARD; play_speed_q4 <= 5'd12; speed_acc <= 2'd0;
                            stop_valid <= 1'b0; number <= 17'd0;
                        end
                        CMD_FWD_X4: begin
                            mode <= M_PLAY; status <= ST_FORWARD; play_speed_q4 <= 5'd16; speed_acc <= 2'd0;
                            stop_valid <= 1'b0; number <= 17'd0;
                        end
                        CMD_FWD_X5: begin
                            mode <= M_PLAY; status <= ST_FORWARD; play_speed_q4 <= 5'd20; speed_acc <= 2'd0;
                            stop_valid <= 1'b0; number <= 17'd0;
                        end

                        // ---- relative skip, simplified to a SEARCH (see header) ----
                        CMD_SKIP_FWD_10:  begin mode<=M_SEARCH; search_frame<=curr_frame+17'd10;  status<=ST_SEARCH; stop_valid<=1'b0; number<=17'd0; end
                        CMD_SKIP_FWD_20:  begin mode<=M_SEARCH; search_frame<=curr_frame+17'd20;  status<=ST_SEARCH; stop_valid<=1'b0; number<=17'd0; end
                        CMD_SKIP_FWD_30:  begin mode<=M_SEARCH; search_frame<=curr_frame+17'd30;  status<=ST_SEARCH; stop_valid<=1'b0; number<=17'd0; end
                        CMD_SKIP_FWD_40:  begin mode<=M_SEARCH; search_frame<=curr_frame+17'd40;  status<=ST_SEARCH; stop_valid<=1'b0; number<=17'd0; end
                        CMD_SKIP_FWD_50:  begin mode<=M_SEARCH; search_frame<=curr_frame+17'd50;  status<=ST_SEARCH; stop_valid<=1'b0; number<=17'd0; end
                        CMD_SKIP_FWD_60:  begin mode<=M_SEARCH; search_frame<=curr_frame+17'd60;  status<=ST_SEARCH; stop_valid<=1'b0; number<=17'd0; end
                        CMD_SKIP_FWD_70:  begin mode<=M_SEARCH; search_frame<=curr_frame+17'd70;  status<=ST_SEARCH; stop_valid<=1'b0; number<=17'd0; end
                        CMD_SKIP_FWD_80:  begin mode<=M_SEARCH; search_frame<=curr_frame+17'd80;  status<=ST_SEARCH; stop_valid<=1'b0; number<=17'd0; end
                        CMD_SKIP_FWD_90:  begin mode<=M_SEARCH; search_frame<=curr_frame+17'd90;  status<=ST_SEARCH; stop_valid<=1'b0; number<=17'd0; end
                        CMD_SKIP_FWD_100: begin mode<=M_SEARCH; search_frame<=curr_frame+17'd100; status<=ST_SEARCH; stop_valid<=1'b0; number<=17'd0; end

                        // ---- known-inert group: matches MAME's own unimplemented stubs (see header) ----
                        CMD_STORE, CMD_RECALL, CMD_DISPLAY, CMD_DISPLAY_ENABLE, CMD_DISPLAY_DISABLE,
                        CMD_GET_FRAME_NUM, CMD_GET_1ST_DISPLAY, CMD_GET_2ND_DISPLAY,
                        CMD_TRANSFER_MEMORY, CMD_LOAD:
                            number <= 17'd0;

                    // Unrecognized bytes are INERT (Daphne only logs them): clearing `number` here
                    // would silently destroy a SEARCH target mid-entry.
                        default: ;                               // Daphne: log only, touch nothing
                    endcase
                end
            end
        end
    end
endmodule
