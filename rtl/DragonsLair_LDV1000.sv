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
    localparam [20:0] PLAY_PERIOD = 21'd1334667;   // 33.367 ms = 1/29.97 s
    localparam [20:0] SCAN_PERIOD = 21'd20000;     // 500 us = 1/2000 s
    localparam [20:0] STAT_LOW    = 21'd1040;      // 26 us status-strobe low
    localparam [20:0] CMD_LO_S    = 21'd2160;      // 54 us command-strobe start
    localparam [20:0] CMD_LO_E    = 21'd3160;      // 79 us command-strobe end (25 us)
    wire [20:0] period = (mode==M_PARK) ? PARK_PERIOD :
                         ((mode==M_SCAN_FWD || mode==M_SCAN_REV) ? SCAN_PERIOD : PLAY_PERIOD);
    reg  [20:0] fcnt;
    wire        frame_tick = (fcnt >= period - 21'd1);

    wire [3:0]  dig = digit_of(cmd_byte);

    // OPCODE-SWEEP-2026-07-05: variable-speed PLAY advance this tick, q4 fixed-point.
    // At 1x (play_speed_q4=4) this always resolves to +1/tick, remainder 0 -- identical
    // to the original always-+1 behaviour, so the HW-proven 1x path is unchanged.
    wire [4:0] speed_sum = {3'd0, speed_acc} + play_speed_q4;
    wire [2:0] speed_adv = speed_sum[4:2];
    wire [1:0] speed_rem = speed_sum[1:0];

    always @(posedge clk) begin
        if (!reset_n) begin
            mode <= M_PARK; status <= ST_PARK | ST_READY;   // 0xFC
            number <= 17'd0; search_frame <= 17'd0; stop_frame <= 17'd0;
            stop_valid <= 1'b0; curr_frame <= 17'd0; fcnt <= 21'd0;
            status_strobe <= 1'b1; command_strobe <= 1'b1;
            audio_en1 <= 1'b1; audio_en2 <= 1'b1; has_digit <= 1'b0;   // AUDIO-CMD-2026-07-05
            play_speed_q4 <= 5'd4; speed_acc <= 2'd0;                  // OPCODE-SWEEP-2026-07-05
        end else if (!pause) begin     // HLE-DRIVE-2026-07-04: paused -> hold all state (disc frozen, in sync)
            // ---- strobe generator (idle high, assert low) ----
            if (frame_tick) fcnt <= 21'd0; else fcnt <= fcnt + 21'd1;
            status_strobe  <= ~(fcnt < STAT_LOW);
            command_strobe <= ~((fcnt >= CMD_LO_S) & (fcnt < CMD_LO_E));

            // ---- per-frame disc motion, locked to the strobe the game reads ----
            if (frame_tick) begin
                case (mode)
                    M_PLAY: begin
                        curr_frame <= curr_frame + {14'd0, speed_adv};
                        speed_acc  <= speed_rem;
                        if (stop_valid && ((curr_frame + {14'd0, speed_adv}) >= stop_frame)) begin
                            mode <= M_STOP; status <= ST_STOP | ST_READY;
                            stop_valid <= 1'b0;
                        end
                    end
                    M_SEARCH: begin
                        if (curr_frame == search_frame) begin
                            mode <= M_STOP; status <= ST_SEARCH_FIN;   // 0xd0 (ready)
                        end else if (search_frame > curr_frame) begin
                            curr_frame <= curr_frame +
                                (((search_frame - curr_frame) > 17'd1)
                                 ? ((search_frame - curr_frame) >> 1) : 17'd1);
                        end else begin
                            curr_frame <= curr_frame -
                                (((curr_frame - search_frame) > 17'd1)
                                 ? ((curr_frame - search_frame) >> 1) : 17'd1);
                        end
                    end
                    M_SCAN_FWD: curr_frame <= curr_frame + 17'd1;   // OPCODE-SWEEP-2026-07-05
                    M_SCAN_REV: if (curr_frame > 17'd0) curr_frame <= curr_frame - 17'd1;
                    default: ; // PARK / STOP: hold frame
                endcase
            end

            // ---- command reception ----
            if (cmd_stb) begin
                if (dig != 4'hf) begin
                    number <= (number * 17'd10) + {13'd0, dig};   // decimal accumulate
                    has_digit <= 1'b1;                            // AUDIO-CMD-2026-07-05
                end else begin
                    has_digit <= 1'b0;   // AUDIO-CMD-2026-07-05: every action opcode consumes the accumulator
                    case (cmd_byte)
                        CMD_CLEAR:   number <= 17'd0;
                        CMD_SEARCH: begin
                            search_frame <= number; mode <= M_SEARCH;
                            status <= ST_SEARCH;              // 0x50 busy
                            stop_valid <= 1'b0; number <= 17'd0;
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
                        CMD_NO_ENTRY: begin
                            status <= status | ST_READY;
                            number <= 17'd0;
                        end

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

                        default: number <= 17'd0;             // truly unrecognized byte
                    endcase
                end
            end
        end
    end
endmodule
