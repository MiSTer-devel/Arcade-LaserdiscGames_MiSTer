//============================================================================
// ldp_pr8210.sv — Pioneer PR-8210 protocol front-end (Cliff Hanger et al).
//
// Ported from Daphne ldp-in/pr8210.cpp + game/cliff.cpp blip timing.
//
// This player has NO byte bus. The game strobes a single "blip" line and the
// INTERVAL between blips carries the bit (PR-8210A service manual, serial
// section p.37): ~1.05 ms = 0, ~2.11 ms = 1. Ten blips form one word framed
// 001?????00; the 5-bit command sits in bits [6:2]. An interval longer than
// the timeout means the sender gave up mid-word, so the bit count resets.
//
// Two behaviours that look like bugs but are not:
//   * A word identical to the previous one is IGNORED. Cliff Hanger relies on
//     this and sends the all-zero filler word to separate two equal commands.
//   * SEEK (0x1A) is not a plain command. The FIRST one ever seen only opens
//     digit entry; every one after that executes the accumulated digits. The
//     arming latch is never cleared (Daphne g_pr8210_seek_received), so
//     treating it as a toggle drops every other seek.
//============================================================================
module ldp_pr8210
#(
    parameter [31:0] CLK_HZ = 32'd80_000_000,
    // Interval thresholds in microseconds.
    //
    // NOT the manual's nominal 1.05/2.11 ms -- Cliff Hanger's ROM bit-bangs its
    // blips and its real gaps are about half that. From the ROM: the shared
    // delay loop at $23F4 is 33 T/iteration, entered with BC=$3C (60) for a 0
    // and BC=$64 (100) for a 1, on top of a common ~840 T unrolled pulse in
    // $1F8F. At the 4 MHz CPU clock that is ~705 us for a 0 and ~1035 us for a
    // 1, so the boundary sits at their midpoint. The 330 us DIFFERENCE between
    // them is exact (it falls out of the two BC constants); the absolute values
    // carry an estimate of the pulse duration, so this is the number to sweep
    // first if words fail to frame.
    parameter [31:0] BIT_ONE_US  = 32'd870,
    // Kept at Daphne's figure (12000 Z80 cycles @ 4 MHz); comfortably above a 1.
    parameter [31:0] TIMEOUT_US  = 32'd3000
)
(
    input             clk,
    input             reset_n,
    input             pause,
    input             sel,

    input             blip,             // 1-cyc pulse per blip from the game

    // ---- transport ----
    output reg        cmd_action,
    output reg [3:0]  cmd_op,
    output reg [16:0] cmd_arg,
    input      [2:0]  mode,

    // ---- CPU side ----
    // Daphne's pr8210_get_current_frame() returns 0 unless the disc is playing
    // or paused; games are told to use it rather than reading the frame raw.
    output            frame_valid,
    output     [9:0]  dbg_word          // last accepted 10-blip word
);
`include "ldp_bus.svh"

    localparam [4:0] C_PLAY=5'h14, C_STEP_FWD=5'h04, C_STEP_REV=5'h12,
                     C_PAUSE=5'h0a, C_AUDIO1=5'h0e, C_AUDIO2=5'h16,
                     C_REJECT=5'h1e, C_SEEK=5'h1a, C_FILLER=5'h00;

    // 5-bit command -> 0..9, 4'hf = not a digit.
    function [3:0] digit_of(input [4:0] c);
        case (c)
            5'h01: digit_of=4'd0; 5'h11: digit_of=4'd1; 5'h09: digit_of=4'd2;
            5'h19: digit_of=4'd3; 5'h05: digit_of=4'd4; 5'h15: digit_of=4'd5;
            5'h0d: digit_of=4'd6; 5'h1d: digit_of=4'd7; 5'h03: digit_of=4'd8;
            5'h13: digit_of=4'd9; default: digit_of=4'hf;
        endcase
    endfunction

    // Multiply before dividing, and divide by a literal -- the idiom the rest of
    // the LD modules use. Dividing first truncates CLK_HZ to whole MHz.
    localparam [31:0] ONE_TICKS = (BIT_ONE_US * CLK_HZ) / 64'd1_000_000;
    localparam [31:0] TMO_TICKS = (TIMEOUT_US * CLK_HZ) / 64'd1_000_000;

    reg [31:0] gap;            // clocks since the previous blip
    reg [9:0]  sr;             // blip shift register
    reg [3:0]  nbits;
    reg [9:0]  last_word;      // repeat suppression
    reg        have_last;

    reg [16:0] number;
    reg        have_digits;    // digits arrived since the last execute (Daphne digit_count > 0)
    // STICKY. Daphne's g_pr8210_seek_received is set by the first SEEK ever and
    // is never cleared again (only reset_pr8210 clears it). So the first SEEK
    // merely opens digit entry; EVERY later SEEK executes. Toggling this off
    // after an execute makes only every OTHER seek land, and the disc then sails
    // past its stop points -- it plays straight through, deaths and all.
    reg        seek_received;
    reg        word_stb;       // 1-cyc: a framed word was accepted
    reg [4:0]  word_cmd;
    reg [9:0]  word_raw;
    assign dbg_word = word_raw;

    // A CAV laserdisc puts a Philips picture number on VBI lines 17/18 of EVERY
    // field while the platter is spinning -- including parked on a still frame.
    // Only an in-flight seek has no valid code.
    //
    // This was M_PLAY||M_STOP, which excluded the transport's M_PARK reset state
    // and deadlocked Cliff Hanger: no valid code -> Philips bit 23 clear -> the
    // board's IRQ never fires -> the interrupt-driven main loop never runs -> the
    // game never issues the command that would start the disc in the first place.
    // POST completed and then nothing happened.
    assign frame_valid = (mode != M_SEARCH);

    // The bit for THIS blip comes from the interval that preceded it.
    wire [9:0] new_word = {sr[8:0], (gap >= ONE_TICKS)};

    wire [3:0] dig = digit_of(word_cmd);

    // Combinational so the transport acts the cycle the word is decoded.
    always_comb begin
        cmd_action = 1'b0;
        cmd_op     = OP_NOP;
        cmd_arg    = 17'd0;
        if (sel && word_stb) begin
            cmd_action = 1'b1;
            if (dig == 4'hf) begin
                case (word_cmd)
                    C_PLAY:     cmd_op = OP_PLAY;
                    C_PAUSE:    cmd_op = OP_STOP;      // still-frame
                    C_STEP_FWD: cmd_op = OP_STEP_FWD;
                    C_STEP_REV: cmd_op = OP_STEP_REV;
                    C_AUDIO1:   cmd_op = OP_AUDIO1;    // toggle (arg[1]=0)
                    C_AUDIO2:   cmd_op = OP_AUDIO2;
                    // Second SEEK with digits executes; everything else inert.
                    // Reject is ignored on purpose (pr8210.cpp: it would eject).
                    // Execute on any SEEK once the first one has been seen and
                    // at least one digit has arrived (Daphne: digit_count > 0).
                    C_SEEK: if (seek_received && have_digits) begin
                                cmd_op  = OP_SEARCH;
                                cmd_arg = number;
                            end
                    default: ;   // filler, reject, unsupported speeds: OP_NOP
                endcase
            end
        end
    end

    always @(posedge clk) begin
        word_stb <= 1'b0;
        if (!reset_n) begin
            gap <= 32'd0; sr <= 10'd0; nbits <= 4'd0;
            last_word <= 10'd0; have_last <= 1'b0;
            number <= 17'd0; seek_received <= 1'b0; have_digits <= 1'b0;
            word_cmd <= 5'd0; word_raw <= 10'd0;
        end else if (!pause) begin
            // ---- blip interval timing ----
            // The bit belongs to the interval BEFORE this blip, so a blip that
            // arrives after the timeout contributes nothing and just resets the
            // word (Daphne cliff.cpp: m_blips_count = 0, no shift).
            if (blip) begin
                gap <= 32'd0;
                if (gap >= TMO_TICKS) begin
                    nbits <= 4'd0;
                end else begin
                    sr    <= new_word;
                    nbits <= nbits + 4'd1;
                    if (nbits == 4'd9) begin
                        nbits <= 4'd0;
                        // Framing check 001?????00, then repeat suppression.
                        if ((new_word & 10'h383) == 10'h080) begin
                            if (!have_last || (new_word != last_word)) begin
                                word_raw <= new_word;
                                word_cmd <= new_word[6:2];
                                word_stb <= 1'b1;
                            end
                        end
                        last_word <= new_word;
                        have_last <= 1'b1;
                    end
                end
            end else if (~&gap) begin
                gap <= gap + 32'd1;             // saturate rather than wrap
            end

            // ---- digit accumulator / seek toggle ----
            if (sel && word_stb) begin
                if (dig != 4'hf) begin
                    // Daphne gates pr8210_add_digit on seek_received too.
                    if (seek_received) begin
                        number      <= (number * 17'd10) + {13'd0, dig};
                        have_digits <= 1'b1;
                    end
                end else if (word_cmd == C_SEEK) begin
                    // First SEEK ever: just open digit entry, and latch forever.
                    // Every SEEK after that executes (above) and clears the digits.
                    seek_received <= 1'b1;
                    number        <= 17'd0;
                    have_digits   <= 1'b0;
                end
            end
        end
    end
endmodule
