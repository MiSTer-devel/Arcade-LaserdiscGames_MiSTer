//============================================================================
// ldp_pr7820.sv — Pioneer PR-7820 protocol front-end.
//
// Ported from Daphne ldp-in/pr7820.cpp. The opcode set is a subset of the
// LD-V1000's with identical digit encoding, but the handshake is completely
// different and that is the whole reason this is its own file:
//
//   * NO ready window. write_pr7820() acts on every byte unconditionally.
//     The ROM's PR-7820 send routine ($026E) emits the raw byte with no 0xFF
//     prefix, so an LD-V1000-style accept gate swallows every command after
//     the first and the disc never seeks.
//   * NO status byte and NO strobes. The ROM's wait loop ($01F9) polls
//     SYSTEM b7 (/READY) and nothing else -- there is no status to recover with.
//   * /READY is a LEVEL, not a latch: busy only while the head is moving. A
//     latch that clears on search-success leaves it stuck busy at power-up.
//   * 0xFF (NO ENTRY) and 0xF9 (Reject) are inert here; on the LD-V1000 they
//     re-arm the gate and park the head respectively.
//============================================================================
module ldp_pr7820
(
    input             clk,
    input             reset_n,
    input             pause,
    input             sel,              // this front-end drives the transport

    input             cmd_stb,
    input      [7:0]  cmd_byte,

    // ---- transport ----
    output reg        cmd_action,
    output reg [3:0]  cmd_op,
    output reg [16:0] cmd_arg,
    input             search_busy,

    // ---- CPU side ----
    output            ready_n,          // -> SYSTEM b7. 1 = busy, 0 = ready.
    output     [7:0]  status,           // no status byte on this player: idle bus
    output     [19:0] dbg_digits
);
`include "ldp_bus.svh"

    localparam [7:0] CMD_SEARCH=8'hf7, CMD_PLAY=8'hfd, CMD_STOP=8'hfb,
                     CMD_AUTOSTOP=8'hf3, CMD_AUDIO1=8'hf4, CMD_AUDIO2=8'hfc,
                     CMD_PLAY_X1=8'ha3, CMD_REJECT=8'hf9, CMD_NO_ENTRY=8'hff;

    function [3:0] digit_of(input [7:0] op);
        case (op)
            8'h3f: digit_of=4'd0; 8'h0f: digit_of=4'd1; 8'h8f: digit_of=4'd2;
            8'h4f: digit_of=4'd3; 8'h2f: digit_of=4'd4; 8'haf: digit_of=4'd5;
            8'h6f: digit_of=4'd6; 8'h1f: digit_of=4'd7; 8'h9f: digit_of=4'd8;
            8'h5f: digit_of=4'd9; default: digit_of=4'hf;
        endcase
    endfunction

    reg  [16:0] number;
    reg         has_digit;
    reg  [19:0] dig_sr;
    reg  [19:0] dig_latched;
    assign dbg_digits = dig_latched;

    assign ready_n = search_busy;   // LEVEL, per the header
    assign status  = 8'hff;         // never read by the PR-7820 ROM path

    wire [3:0] dig = digit_of(cmd_byte);
    // No gate: every byte is acted on. 0xFF is inert rather than an ACK.
    wire accepted  = sel && cmd_stb && !pause && (cmd_byte != CMD_NO_ENTRY);
    wire is_digit  = accepted && (dig != 4'hf);
    wire is_action = accepted && (dig == 4'hf);

    always_comb begin
        cmd_action = is_action;
        cmd_op     = OP_NOP;
        cmd_arg    = 17'd0;
        if (is_action) begin
            case (cmd_byte)
                CMD_SEARCH:   begin cmd_op = OP_SEARCH;   cmd_arg = number; end
                CMD_PLAY:     cmd_op = OP_PLAY;
                CMD_STOP:     cmd_op = OP_STOP;
                CMD_AUTOSTOP: begin cmd_op = OP_AUTOSTOP; cmd_arg = number; end
                CMD_AUDIO1:   begin cmd_op = OP_AUDIO1;   cmd_arg = {15'd0, has_digit, number[0]}; end
                CMD_AUDIO2:   begin cmd_op = OP_AUDIO2;   cmd_arg = {15'd0, has_digit, number[0]}; end
                // Daphne pre_change_speed(1,1). Kept as a speed op so behaviour matches what
                // this byte did while PR-7820 was routed through the LD-V1000 decoder.
                CMD_PLAY_X1:  begin cmd_op = OP_PLAY_SPD; cmd_arg = 17'd4; end
                // 0xF9 Reject is explicitly IGNORED on this player (pr7820.cpp), unlike the
                // LD-V1000 where it parks the head.
                default: ;   // Reject and unsupported bytes: inert
            endcase
        end
    end

    always @(posedge clk) begin
        if (!reset_n) begin
            number <= 17'd0; has_digit <= 1'b0;
            dig_sr <= 20'd0; dig_latched <= 20'd0;
        end else if (!pause) begin
            if (sel && cmd_stb && (cmd_byte != CMD_NO_ENTRY)) begin
                if (dig != 4'hf) begin
                    number    <= (number * 17'd10) + {13'd0, dig};
                    has_digit <= 1'b1;
                    dig_sr    <= {dig_sr[15:0], dig};
                end else begin
                    has_digit <= 1'b0;
                    case (cmd_byte)
                        CMD_SEARCH: begin
                            dig_latched <= dig_sr; dig_sr <= 20'd0;
                            number <= 17'd0;
                        end
                        CMD_PLAY, CMD_STOP, CMD_AUTOSTOP, CMD_AUDIO1, CMD_AUDIO2, CMD_PLAY_X1:
                            number <= 17'd0;
                        // Unrecognized bytes are inert: clearing `number` would silently
                        // destroy a SEARCH target mid-entry.
                        default: ;
                    endcase
                end
            end
        end
    end
endmodule
