//============================================================================
// DragonsLair_LDV1000.sv — Pioneer LD-V1000 command/status controller (HLE)
//----------------------------------------------------------------------------
// Replaces the constant "parked/ready" stub with a real command-processing
// state machine, ported from MAME pioneer_ldv1000hle_device
// (Useful Stuff/ldv1000hle.cpp).  It decodes the Z80's digit/SEARCH/PLAY/STOP/
// AUTOSTOP stream, tracks the current disc frame, and reports real status codes
// + a per-frame strobe back to the game — which is what the game waits on after
// START (the stub could never seek/play, so a game could never begin).
//
// curr_frame is exposed for the (future) video path:
//   film_frame = round((curr_frame - 151) * mpeg_fpks / disc_fpks)   [disc->film]
//
// Command bytes arrive as `cmd_stb` pulses carrying `cmd_byte` = the 0xE020
// data latch, strobed by the Z80's misc_w b5 1->0 ("OUT DISC DATA").  Digit
// opcodes accumulate a decimal frame number; action opcodes consume it.
//
// Signal polarity matches the old stub / MAME: status_strobe & command_strobe
// idle HIGH and assert LOW.  SYSTEM b6 = status_strobe, SYSTEM b7 = ~command_strobe
// (so b7=0 == "ready to accept a command").
//
// Simplification vs MAME (revisit if the HW handshake misbehaves): a command is
// accepted whenever strobed, not gated on STATUS_READY(bit7).  The DL ROM only
// emits a byte when it sees the ready strobe, so this cannot drop a valid
// command and it sidesteps a READY-deadlock risk in an unsimulated first port.
//
// AUDIO-CMD-2026-07-05: CMD_AUDIO1(0xF4)/CMD_AUDIO2(0xFC) are real per-channel
// audio-enable commands (ldv1000hle.cpp process_command: no digit -> toggle,
// digit N -> set to N&1), gated into MAME's update_audio_enable() alongside
// mode==PLAY && speed==1x. These used to fall into the unhandled default
// (silently dropped); `playing` now reflects the real command-driven mute, not
// just PLAY mode. Simplification vs MAME: our streamer drains one combined
// stereo PCM stream, so there's no way to squelch channel 1/2 independently --
// `playing` requires BOTH channels enabled. Revisit if a game mutes only one
// channel on purpose.
//
// OPCODE-SWEEP-2026-07-05: full command set now implemented (every opcode
// MAME's is_command_byte() recognizes), byte values cross-checked against
// ldv1000hle.h:
//   - CMD_SCAN_FWD/REV: continuous fast traverse (~2000 fps, SCAN_PERIOD tick)
//     until interrupted by STOP/PLAY/SEARCH/REJECT -- new M_SCAN_FWD/M_SCAN_REV
//     modes (mode widened 2b -> 3b).
//   - CMD_STEP_FWD/REV: single-frame step then STOP.
//   - CMD_REJECT: -> PARK. CMD_NO_ENTRY: sets the READY status bit only.
//   - CMD_FWD_X0/X1_4/X1_2/X1/X2/X3/X4/X5: variable-speed forward play. Tracked
//     as `play_speed_q4` (fixed-point, 4=1x) with a fractional accumulator
//     (`speed_acc`, same pattern as dlv_streamer's 44.1kHz tick) so sub-1x
//     speeds advance less than 1 frame/tick and multi-x speeds advance several.
//     CMD_PLAY always resets to 1x (matches MAME's cmd_play->set_playing(...,1.0)).
//     `playing` requires speed==1x too (MAME: update_audio_enable only unmutes
//     at m_play_speed==1.0) -- FWD_X2 etc. are correctly silent even with both
//     audio channels enabled.
//   - CMD_SKIP_FWD_10..100: simplified vs MAME (which reuses its own scan-speed
//     internals) to `search_frame <= curr_frame + N`, reusing our existing
//     SEARCH ramp -- same real-world effect (jump forward N frames), no need to
//     replicate MAME's internal skip machinery we don't otherwise model.
//   - CMD_STORE/CMD_RECALL/CMD_DISPLAY/CMD_DISPLAY_ENABLE/CMD_DISPLAY_DISABLE/
//     CMD_GET_FRAME_NUM/CMD_GET_1ST_DISPLAY/CMD_GET_2ND_DISPLAY/
//     CMD_TRANSFER_MEMORY/CMD_LOAD: accepted (clear the digit accumulator) but
//     inert -- this MATCHES MAME, which leaves every one of these as a
//     "not yet implemented" log-only stub itself (OSD/register-recall features
//     with no gameplay-visible effect even upstream; CMD_STORE writes a
//     register nothing ever reads back since CMD_RECALL is unimplemented).
//     Grouped explicitly so they read as "known inert," not silently folded
//     into the same default as a truly-unrecognized byte.
//============================================================================
module DragonsLair_LDV1000
(
    input             clk,            // 40 MHz clk_sys
    input             reset_n,        // active-low (core `reset`)
    input             cmd_stb,        // 1-cyc: a data/command byte was strobed out
    input      [7:0]  cmd_byte,       // that byte (0xE020 latch)
    output reg [7:0]  status,         // -> 0xC020 laserdisc_r
    output reg        status_strobe,  // -> SYSTEM b6   (idle 1, asserts low)
    output reg        command_strobe, // SYSTEM b7 = ~command_strobe (idle 1 => b7=0 ready)
    // SEEK-HOLD-2026-07-20: 1-cycle pulse when the Z80's SEARCH command (CMD_SEARCH, 0xF7) is
    // ACCEPTED. This is the REAL event -- the command from the CPU -- NOT an inference from head
    // movement (a frame-delta threshold) and NOT a mode transition. A delta heuristic both guesses
    // and misses: a seek shorter than its threshold would never register.
    output reg        search_cmd_o,
    output reg [16:0] curr_frame,     // current disc frame (0..54000) for the video path
    input             pause,          // HLE-DRIVE-2026-07-04: freeze disc motion + strobes during pause
    output            playing         // AUDIO-GATE-2026-07-05: mode==M_PLAY, speed==1x, AND both AUDIO1/2
                                       // channels enabled (AUDIO-CMD-2026-07-05) -- gates the .dlv audio ring
);
    // ---- status codes (ldv1000hle.h) ----
    localparam [7:0] ST_PARK=8'h7c, ST_PLAY=8'h64, ST_STOP=8'h65,
                     ST_SEARCH=8'h50, ST_SEARCH_FIN=8'hd0, ST_READY=8'h80,
                     ST_SCAN=8'h4c, ST_FORWARD=8'h2e;         // OPCODE-SWEEP-2026-07-05
    // ---- modes (widened 2b->3b for SCAN, OPCODE-SWEEP-2026-07-05) ----
    localparam [2:0] M_PARK=3'd0, M_SEARCH=3'd1, M_PLAY=3'd2, M_STOP=3'd3,
                     M_SCAN_FWD=3'd4, M_SCAN_REV=3'd5;
    // ---- action opcodes (byte values cross-checked vs ldv1000hle.h) ----
    localparam [7:0] CMD_CLEAR=8'hbf, CMD_SEARCH=8'hf7, CMD_PLAY=8'hfd,
                     CMD_STOP=8'hfb, CMD_AUTOSTOP=8'hf3,
                     CMD_AUDIO1=8'hf4, CMD_AUDIO2=8'hfc,      // AUDIO-CMD-2026-07-05
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
    // DAPHNE-ATOMIC-SEEK-2026-07-16: busy-report countdown, in frame_ticks (~30Hz).  Daphne's
    // g_ldv1000_seconds_per_search = 0.5 => ~15 ticks.  This times the STATUS report only; the disc
    // POSITION lands atomically (see the M_SEARCH block).
    localparam [4:0] SEARCH_TICKS = 5'd15;
    reg  [4:0]  search_delay;
    reg  [16:0] stop_frame;
    reg         stop_valid;
    reg         audio_en1, audio_en2;   // AUDIO-CMD-2026-07-05: per-channel enable, MAME default = both on
    reg         has_digit;              // distinguishes "no digits typed" (toggle) from "digit typed" (explicit set)
    reg  [4:0]  play_speed_q4;          // OPCODE-SWEEP-2026-07-05: fixed-point x4 (4=1x), CMD_FWD_X*
    reg  [1:0]  speed_acc;              // fractional remainder for sub/multi-1x frame advance

    // OPCODE-SWEEP-2026-07-05: MAME's update_audio_enable() only unmutes at mode==PLAY && speed==1.0
    assign playing = (mode == M_PLAY) && (play_speed_q4 == 5'd4) && audio_en1 && audio_en2;

    // frame-period / strobe generator: PARK 21 ms (matches the POST-proven stub),
    // active ~33.37 ms = 1/29.97 s so the game sees one strobe per disc frame.
    // SCAN modes tick at ~2000 fps per MAME's comment ("moves the optical head at
    // the rate of approximately 2000 frames per second") -- OPCODE-SWEEP-2026-07-05.
    localparam [20:0] PARK_PERIOD = 21'd840000;    // 21 ms    @ 40 MHz
    localparam [20:0] PLAY_PERIOD = 21'd1334667;   // 33.367 ms = 1/29.97 s  (VSYNC/strobe rate)
    localparam [20:0] SCAN_PERIOD = 21'd20000;     // 500 us = 1/2000 s
    localparam [20:0] STAT_LOW    = 21'd1040;      // 26 us status-strobe low
    localparam [20:0] CMD_LO_S    = 21'd2160;      // 54 us command-strobe start
    localparam [20:0] CMD_LO_E    = 21'd3160;      // 79 us command-strobe end (25 us)
    wire [20:0] period = (mode==M_PARK) ? PARK_PERIOD :
                         ((mode==M_SCAN_FWD || mode==M_SCAN_REV) ? SCAN_PERIOD : PLAY_PERIOD);
    reg  [20:0] fcnt;
    wire        frame_tick = (fcnt >= period - 21'd1);   // strobe/vsync tick -- UNCHANGED (29.97)

    //------------------------------------------------------------------------
    // FILM-RATE-FIX-2026-07-16: advance the DISC FRAME at the FILM's rate, not the vsync rate.
    //
    // BUG: curr_frame was advanced by frame_tick (29.97/s), so with the 1:1 disc->video map
    // (ONE-TO-ONE-FIX-2026-07-16, HW-proven by still frames landing correctly) the video advanced
    // 29.97 frames/s -- but the captured film is 23.938 fps.  We played it ~25% FAST, dropping
    // roughly every 4th frame's worth of film, and the audio (which drains in real time at 44100Hz)
    // could not follow.  HW 2026-07-16, user (owned a real DL cabinet ~30 years): stills are correct
    // but "once the playback/play starts it just goes off the rails... it is too fast, it's skipping
    // frames... the audio is mismatched, not because of when it started, but because it's just
    // screaming along too quickly."
    //
    // THE FILM RATE IS NOT A GUESS -- the container states it, independent of any assumption of mine:
    //     total_samples / frame_count = 81343495 / 44154 = 1842.28 samples per frame
    //     44100 / 1842.28            = 23.938 fps
    // (Daphne's .ogg and .m2v are one capture of one duration, so frame_count and total_samples
    // describe the same 1844.5 s.  This is the SAME 23.938 that pack_dlv.py writes as mpeg_fpks --
    // that value was always right ABOUT THE FILM; the 2026-07-05 mistake was using it to SCALE the
    // frame MAP, when what it actually describes is the film's PLAYBACK RATE.)
    //
    // WHY TWO CLOCKS, AND WHY NOT JUST SLOW PLAY_PERIOD: Daphne keeps these separate and so must we.
    // The status/command strobes are VSYNC-driven -- Daphne's ldv1000.cpp strobe section says "call
    // ldv1000_report_vsync on every vsync pulse", and lair.cpp polls those strobes (SYSTEM b6/b7) to
    // sequence its command bytes.  The DISC FRAME, by contrast, comes from VLDP's playback position,
    // i.e. it advances at the film's own rate.  Slowing PLAY_PERIOD would drag the strobes down with
    // it and wreck the command channel DL polls.  So: strobes stay on frame_tick (29.97), the disc
    // frame moves to film_tick (23.938).
    //
    // ⚠️ DL-SPECIFIC CONSTANT -- must become header-derived (round(SRATE*frame_count/total_samples),
    // both already in the .dlv header @32/@16/@40) before Space Ace / Thayer's Quest, whose films
    // differ and whose containers are separately known-bad (see pack_dlv.py mpeg_fpks note in vault).
    //
    // ⚠️ WATCH ON HW: this makes the disc advance 25% slower, so DL's own scene/attract timing (paced
    // by autostop on curr_frame) gets ~25% LONGER.  The user previously measured the attract loop as
    // matching MAME within ~1s at 29.97 -- if the loop now runs visibly long, that measurement and
    // this fix are in conflict and BOTH need re-examining.  Do not dismiss it if it shows up.
    localparam [20:0] FILM_PERIOD = 21'd1670983;   // 41.774 ms = 1/23.938 s @ 40 MHz
    reg  [20:0] vcnt;
    wire        film_tick = (vcnt >= FILM_PERIOD - 21'd1);

    wire [3:0]  dig = digit_of(cmd_byte);

    // OPCODE-SWEEP-2026-07-05: variable-speed PLAY advance this tick, q4 fixed-point.
    // At 1x (play_speed_q4=4) this always resolves to +1/tick, remainder 0 -- identical
    // to the original always-+1 behaviour, so the HW-proven 1x path is unchanged.
    wire [4:0] speed_sum = {3'd0, speed_acc} + play_speed_q4;
    wire [2:0] speed_adv = speed_sum[4:2];
    wire [1:0] speed_rem = speed_sum[1:0];

    always @(posedge clk) begin
        // SEEK-HOLD-2026-07-20: default LOW here, OUTSIDE the reset/pause branches, so
        // search_cmd_o is ALWAYS a 1-cycle pulse. If this default lived inside the `!pause`
        // branch, a pause asserting just after a SEARCH would FREEZE the pulse HIGH for the whole
        // pause -- which downstream would read as a permanent seek and hold playback forever.
        search_cmd_o <= 1'b0;
        if (!reset_n) begin
            mode <= M_PARK; status <= ST_PARK | ST_READY;   // 0xFC
            number <= 17'd0; search_frame <= 17'd0; stop_frame <= 17'd0;
            stop_valid <= 1'b0; curr_frame <= 17'd0; fcnt <= 21'd0;
            search_delay <= 5'd0;   // DAPHNE-ATOMIC-SEEK-2026-07-16
            vcnt <= 21'd0;          // FILM-RATE-FIX-2026-07-16
            status_strobe <= 1'b1; command_strobe <= 1'b1;
            audio_en1 <= 1'b1; audio_en2 <= 1'b1; has_digit <= 1'b0;   // AUDIO-CMD-2026-07-05
            play_speed_q4 <= 5'd4; speed_acc <= 2'd0;                  // OPCODE-SWEEP-2026-07-05
        end else if (!pause) begin     // HLE-DRIVE-2026-07-04: paused -> hold all state (disc frozen, in sync)
            // ---- strobe generator (idle high, assert low) ----
            if (frame_tick) fcnt <= 21'd0; else fcnt <= fcnt + 21'd1;
            status_strobe  <= ~(fcnt < STAT_LOW);
            command_strobe <= ~((fcnt >= CMD_LO_S) & (fcnt < CMD_LO_E));

            // FILM-RATE-FIX-2026-07-16: free-running film-rate tick (23.938 fps), independent of
            // the strobe/vsync counter above.  Drives PLAY's disc-frame advance only.
            if (film_tick) vcnt <= 21'd0; else vcnt <= vcnt + 21'd1;

            // FILM-RATE-FIX-2026-07-16: PLAY's disc-frame advance, on the FILM tick (23.938), NOT
            // the strobe/vsync tick (29.97).  This is the whole fix: with the 1:1 disc->video map,
            // curr_frame IS the video frame, so it must step at the film's rate or we play fast and
            // drop frames.  Kept in its own block (not the case below) so the strobe generator and
            // the other modes are untouched.  M_SEARCH's busy countdown deliberately stays on
            // frame_tick -- it is a ~0.5s wall-clock timer, not disc motion.  M_SCAN also stays:
            // it models head slew (SCAN_PERIOD), which is not film playback either.
            if (film_tick && (mode == M_PLAY)) begin
                curr_frame <= curr_frame + {14'd0, speed_adv};
                speed_acc  <= speed_rem;
                if (stop_valid && ((curr_frame + {14'd0, speed_adv}) >= stop_frame)) begin
                    mode <= M_STOP; status <= ST_STOP | ST_READY;
                    stop_valid <= 1'b0;
                end
            end

            // ---- per-frame disc motion, locked to the strobe the game reads ----
            if (frame_tick) begin
                case (mode)
                    // FILM-RATE-FIX-2026-07-16: original M_PLAY body commented out -- it now lives in
                    // the film_tick block ABOVE.  To revert: uncomment this, delete that block, plus
                    // vcnt / film_tick / FILM_PERIOD.
                    // M_PLAY: begin
                    //     curr_frame <= curr_frame + {14'd0, speed_adv};
                    //     speed_acc  <= speed_rem;
                    //     if (stop_valid && ((curr_frame + {14'd0, speed_adv}) >= stop_frame)) begin
                    //         mode <= M_STOP; status <= ST_STOP | ST_READY;
                    //         stop_valid <= 1'b0;
                    //     end
                    // end
                    // DAPHNE-ATOMIC-SEEK-2026-07-16: original halving RAMP commented out below --
                    // uncomment it (and delete this block + search_delay) to revert.
                    //
                    // WHY THE RAMP WAS WRONG: it walked the DISC POSITION toward the target by halving
                    // the distance once per frame_tick -- ~14-17 intermediate values of curr_frame over
                    // ~0.5s.  A real LD-V1000 head LANDS; it does not scan.  Those intermediates are
                    // live on ld_curr_frame, and dlv_streamer.v chases them: every step is a jump >16
                    // so it re-fetches vid_target (~14 WRONG frames per seek => "entirely the wrong data
                    // displayed") and re-points aud_lba ~14 times to wrong sectors (=> audio unsync).
                    // HW-observed exactly that on 2026-07-16 once SEARCH first started working.
                    //
                    // AUTHORITY: Daphne ldp-in/ldv1000.cpp:299-346 (case 0xF7) -- it calls
                    // g_ldp->pre_search(...) which lands the disc ATOMICALLY, then merely REPORTS busy:
                    // g_ldv1000_output = 0x50 while g_ldv1000_search_pending, flipping to 0xD0 once
                    // elapsed_cycles >= g_ldv1000_cycles_per_search (ldv1000.cpp:90-115,
                    // g_ldv1000_seconds_per_search = 0.5).  The seek "taking time" is a STATUS fiction;
                    // the POSITION is instant.  So: position and timing are decoupled here.
                    //
                    // curr_frame <= search_frame is idempotent, so it lands on the first tick after any
                    // M_SEARCH entry and then holds -- ld_curr_frame makes exactly ONE jump.  Doing it
                    // here (rather than at each command) covers every M_SEARCH entry point uniformly:
                    // CMD_SEARCH, CMD_AUTOSTOP's search-back path, and the CMD_SKIP_FWD_* group.
                    M_SEARCH: begin
                        curr_frame <= search_frame;              // atomic land (Daphne: pre_search)
                        if (search_delay != 5'd0) begin
                            search_delay <= search_delay - 5'd1; // still "busy": status stays ST_SEARCH (0x50)
                        end else begin
                            mode <= M_STOP; status <= ST_SEARCH_FIN;   // 0xd0 (ready) -- Daphne's "search succeeded d0"
                        end
                    end
                    // ---- ORIGINAL (halving ramp), REVERT TARGET ----
                    // M_SEARCH: begin
                    //     if (curr_frame == search_frame) begin
                    //         mode <= M_STOP; status <= ST_SEARCH_FIN;   // 0xd0 (ready)
                    //     end else if (search_frame > curr_frame) begin
                    //         curr_frame <= curr_frame +
                    //             (((search_frame - curr_frame) > 17'd1)
                    //              ? ((search_frame - curr_frame) >> 1) : 17'd1);
                    //     end else begin
                    //         curr_frame <= curr_frame -
                    //             (((curr_frame - search_frame) > 17'd1)
                    //              ? ((curr_frame - search_frame) >> 1) : 17'd1);
                    //     end
                    // end
                    M_SCAN_FWD: curr_frame <= curr_frame + 17'd1;   // OPCODE-SWEEP-2026-07-05
                    M_SCAN_REV: if (curr_frame > 17'd0) curr_frame <= curr_frame - 17'd1;
                    default: ; // PARK / STOP: hold frame
                endcase
            end

            // ---- command reception ----
            // DAPHNE-NOENTRY-FIX-2026-07-16: 0xFF (NO ENTRY) must be FULLY INERT.  The Z80 writes a
            // command byte every vsync and sends 0xFF on every idle one, so 0xFF lands BETWEEN the
            // digits of a SEARCH sequence (CLEAR -> 0xFF.. -> digit -> 0xFF.. -> digit -> .. -> SEARCH).
            // It was previously handled in the case block below, where it did `number <= 17'd0` and
            // (via the shared `has_digit <= 1'b0` on this else-branch) also cleared has_digit -- so the
            // accumulator was wiped between EVERY digit and CMD_SEARCH fired with number==0
            // => search_frame=0 => disc_rel clamps to 0 => video frame 0.
            //
            // AUTHORITY = Daphne's own LD-V1000 sim (Useful Stuff/daphne/ldp-in/ldv1000.cpp:411-414),
            // NOT MAME -- our whole asset chain (m2v/ogg, framefile, ldoff=151) is Daphne-derived, and
            // per the user MAME's LDV1000 semantics differ around the vsync/frame-decode boundary and
            // will misbehave here.  Daphne, verbatim:
            //     case 0xFF:  // NO ENTRY
            //         // it's legal to send the LD-V1000 as many of these as you want, we just ignore 'em
            //         g_ldv1000_output |= 0x80;   // set highbit just in case
            //         break;
            // i.e. ready-highbit ONLY.  Daphne's clear() (ldv1000.cpp:579) is called from six explicit
            // sites (0xBF clear, 0xF3 autostop, ...) and NEVER from 0xFF.
            //
            // Original CMD_NO_ENTRY handler is left commented in the case block below; to revert,
            // restore it and delete this branch.
            // DAPHNE-READY-GATE-2026-07-16: the LD-V1000 accepts EXACTLY ONE byte per ready window.
            // This gate was NEVER IMPLEMENTED -- we accepted every cmd_stb unconditionally, so any
            // byte the real player would have IGNORED got processed.  For a multi-strobe digit that
            // means accumulating it repeatedly ('1' seen 3x => number=111), i.e. a wrong-but-plausible
            // SEARCH target => "jumping all over the place instead of playing the proper segments"
            // (HW 2026-07-16).  The old 0xFF bug hid this completely by flattening every target to 0.
            //
            // AUTHORITY -- Daphne ldp-in/ldv1000.cpp:173-179 + 422-436, structure verbatim:
            //     if (g_ldv1000_output & 0x80) {      // READY
            //         g_ldv1000_output &= 0x7F;       //   accept ONE byte, immediately go NOT ready
            //         switch (value) { ...dispatch... }
            //     } else {                            // NOT READY
            //         if (value == 0xFF) g_ldv1000_output |= 0x80;  // only 0xFF re-arms
            //         else               g_ldv1000_output &= 0x7F;  // everything else IGNORED
            //     }
            // So 0xFF is NOT idle filler -- it is the handshake ACK, structurally required between
            // every pair of real commands.  A real SEARCH is:
            //     0xBF, 0xFF, d, 0xFF, d, 0xFF, d, 0xFF, d, 0xFF, d, 0xFF, 0xF7
            // and any repeated byte in between is dropped BY DESIGN.
            //
            // This works out because our status constants are already the real LD-V1000 codes and
            // match Daphne's: ST_PLAY=0x64, ST_SEARCH=0x50, ST_PARK=0x7c -- all bit-7 CLEAR, so the
            // player naturally goes deaf after each command; ST_SEARCH_FIN=0xd0 has bit 7 SET, so a
            // completed search re-arms, exactly as Daphne's 0xD0 does.
            //
            // NOTE ON ORDERING: `status <= status & 8'h7f` below is overridden by any explicit
            // `status <=` inside the case (later assignment wins in the same always block).  That is
            // precisely Daphne's own sequence (`&= 0x7F;` then e.g. `= 0x64;`), not an accident.
            //
            // REVERT: delete the CMD_NO_ENTRY / !status[7] branches and the `status <= status & 8'h7f`
            // line, leaving the bare `if (dig != 4'hf)` chain.
            if (cmd_stb) begin
                if (cmd_byte == CMD_NO_ENTRY) begin
                    // Daphne: 0xFF always ends READY -- line 413 (when ready) / line 428 (when not).
                    status <= status | ST_READY;
                end else if (!status[7]) begin
                    // NOT READY + non-0xFF => ignore the byte ENTIRELY (Daphne lines 431-435).
                    status <= status & 8'h7f;
                end else if (dig != 4'hf) begin
                    status <= status & 8'h7f;                     // Daphne line 176: consumed => not ready
                    number <= (number * 17'd10) + {13'd0, dig};   // decimal accumulate
                    has_digit <= 1'b1;                            // AUDIO-CMD-2026-07-05
                end else begin
                    status <= status & 8'h7f;   // Daphne line 176 (case below may override, as it does there)
                    has_digit <= 1'b0;   // AUDIO-CMD-2026-07-05: every action opcode consumes the accumulator
                    // DAPHNE-ATOMIC-SEEK-2026-07-16: arm the busy-report countdown.  Covers all 12
                    // `mode <= M_SEARCH` entry points (CMD_SEARCH, CMD_AUTOSTOP's search-back,
                    // CMD_SKIP_FWD_*) with one assignment instead of 12; nothing in the case below
                    // writes search_delay.
                    //
                    // HANG-FIX-2026-07-16 (`mode != M_SEARCH` guard): the first version of this line
                    // was UNGUARDED, justified as "search_delay is only READ in M_SEARCH so arming it
                    // elsewhere is inert."  THAT WAS WRONG -- it is not inert if we are ALREADY in
                    // M_SEARCH: a command arriving mid-search re-armed the countdown to 15, so it
                    // never reached 0, `status` stayed pinned at ST_SEARCH (0x50 = busy),
                    // ST_SEARCH_FIN (0xd0) never fired, and the Z80 polled for a completion that
                    // could not arrive => WHOLE CORE HANGS (HW-observed 2026-07-16).  The old halving
                    // ramp could not do this: it terminated on curr_frame==search_frame, not a timer.
                    //
                    // The guard makes re-arming impossible once a search is running.  (The
                    // DAPHNE-READY-GATE above independently prevents it too -- during a search
                    // status=0x50, bit 7 clear => not ready => every non-0xFF byte is ignored and
                    // never reaches here.  Belt and braces: do NOT rely on that invariant alone,
                    // it is far away and easy to break.)  A genuinely new SEARCH arriving mid-search
                    // simply retargets without extending the busy window -- a shorter report, never a
                    // stuck one; the gate means that can't happen anyway.
                    if (mode != M_SEARCH) search_delay <= SEARCH_TICKS;
                    case (cmd_byte)
                        CMD_CLEAR:   number <= 17'd0;
                        CMD_SEARCH: begin
                            search_frame <= number; mode <= M_SEARCH;
                            status <= ST_SEARCH;              // 0x50 busy
                            stop_valid <= 1'b0; number <= 17'd0;
                            search_cmd_o <= 1'b1;             // SEEK-HOLD-2026-07-20: the REAL event
                        end
                        CMD_PLAY: begin
                            mode <= M_PLAY; status <= ST_PLAY; // 0x64
                            stop_valid <= 1'b0; number <= 17'd0;
                            play_speed_q4 <= 5'd4; speed_acc <= 2'd0;   // OPCODE-SWEEP-2026-07-05: always 1x
                        end
                        CMD_STOP: begin
                            mode <= M_STOP; status <= ST_STOP | ST_READY;
                            number <= 17'd0;
                        end
                        CMD_AUTOSTOP: begin
                            // stop when play reaches `number` (ahead); else search back
                            if (number < curr_frame) begin
                                search_frame <= number; mode <= M_SEARCH;
                                status <= ST_SEARCH;
                            end else begin
                                stop_frame <= number; stop_valid <= 1'b1;
                                mode <= M_PLAY; status <= ST_PLAY;
                            end
                            number <= 17'd0;
                        end
                        CMD_AUDIO1: begin   // AUDIO-CMD-2026-07-05: no digit -> toggle, digit N -> set to N&1
                            audio_en1 <= has_digit ? number[0] : ~audio_en1;
                            number <= 17'd0;
                        end
                        CMD_AUDIO2: begin
                            audio_en2 <= has_digit ? number[0] : ~audio_en2;
                            number <= 17'd0;
                        end

                        // ---- OPCODE-SWEEP-2026-07-05: SCAN / STEP / REJECT / NO_ENTRY ----
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
                        // DAPHNE-NOENTRY-FIX-2026-07-16: original below, moved to a fully-inert branch
                        // ABOVE this case block (0xFF must not touch number OR has_digit).  To revert:
                        // uncomment this, delete the `cmd_byte == CMD_NO_ENTRY` branch above.
                        // CMD_NO_ENTRY: begin
                        //     status <= status | ST_READY;
                        //     number <= 17'd0;
                        // end

                        // ---- OPCODE-SWEEP-2026-07-05: variable-speed forward play ----
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

                        // ---- OPCODE-SWEEP-2026-07-05: relative skip, simplified to a SEARCH (see header) ----
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

                        // DAPHNE-NOENTRY-FIX-2026-07-16: original below, uncomment to revert.
                        // Zeroing the accumulator on an unrecognized byte is OUR invention -- Daphne's
                        // LD-V1000 default (ldv1000.cpp:415-418) only PRINTS "Unsupported LD-V1000
                        // Command Received" and changes no state.  Any byte we haven't decoded (this
                        // core's opcode table is not proven exhaustive against the real Z80 traffic)
                        // would otherwise silently destroy a SEARCH target mid-entry -- the same class
                        // of bug as the 0xFF one above.  Inert is the faithful behaviour.
                        // default: number <= 17'd0;             // truly unrecognized byte
                        default: ;                               // Daphne: log only, touch nothing
                    endcase
                end
            end
        end
    end
endmodule
