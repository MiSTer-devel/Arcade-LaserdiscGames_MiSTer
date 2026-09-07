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
//   * SEEK (0x1A) is a TOGGLE, not a command: the first one opens digit entry,
//     the second executes the search. A second seek with no digits is a reset.
//============================================================================
module ldp_pr8210
#(
    parameter [31:0] CLK_HZ = 32'd80_000_000,
    // Interval thresholds in microseconds. Boundary sits between the manual's
    // 1.05 ms (0) and 2.11 ms (1); anything past the timeout aborts the word.
    parameter [31:0] BIT_ONE_US  = 32'd1580,
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
    reg        seek_armed;     // first SEEK seen, collecting digits
    reg        word_stb;       // 1-cyc: a framed word was accepted
    reg [4:0]  word_cmd;
    reg [9:0]  word_raw;
    assign dbg_word = word_raw;

    assign frame_valid = (mode == M_PLAY) || (mode == M_STOP);

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
                    C_SEEK: if (seek_armed && number != 17'd0) begin
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
            number <= 17'd0; seek_armed <= 1'b0;
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
                    if (seek_armed) number <= (number * 17'd10) + {13'd0, dig};
                end else if (word_cmd == C_SEEK) begin
                    if (!seek_armed) begin
                        seek_armed <= 1'b1; number <= 17'd0;   // open digit entry
                    end else begin
                        seek_armed <= 1'b0; number <= 17'd0;   // executed (or reset)
                    end
                end
            end
        end
    end
endmodule
