//============================================================================
// ldp_ldp1450.sv — Sony LDP-1450 protocol front-end (Dragon's Lair II et al).
//
// Ported from Daphne ldp-in/ldp1000.cpp.
//
// Unlike the Pioneer players this one TALKS BACK: almost every command pushes
// an ACK (0x0a) onto a reply queue the game reads byte by byte, and 0x60
// answers with the current frame as five ASCII digits. The game side owns the
// UART; this module sees whole bytes in (cmd_stb/cmd_byte) and offers whole
// bytes out (tx_valid/tx_byte/tx_pop).
//
// SEARCH is a three-part sequence: 0x43 arms it, ASCII digits accumulate, and
// 0x40 (Enter) executes. The ACK latencies are real protocol -- Daphne notes
// Bega's Battle depends on the delay after a clear -- so they are modelled.
//
// NOT implemented, deliberately: the LDP-1450 text overlay (0x00/0x01/0x02,
// 0x0a/0x14/0x1a, 0x80/0x81/0x82) and Repeat (0x44). They ACK and are inert.
//============================================================================
module ldp_ldp1450
#(
    parameter [31:0] CLK_HZ = 32'd80_000_000
)
(
    input             clk,
    input             reset_n,
    input             pause,
    input             sel,

    input             cmd_stb,          // 1-cyc: a byte arrived from the game
    input      [7:0]  cmd_byte,

    // ---- transport ----
    output reg        cmd_action,
    output reg [3:0]  cmd_op,
    output reg [16:0] cmd_arg,
    input      [2:0]  mode,
    input      [16:0] curr_frame,

    // ---- reply queue to the game ----
    output            tx_valid,
    output     [7:0]  tx_byte,
    input             tx_pop,

    output     [19:0] dbg_digits
);
`include "ldp_bus.svh"

    localparam [7:0] C_MUTE_ON=8'h24, C_MUTE_OFF=8'h25,
                     C_PLAY=8'h3a, C_ENTER=8'h40, C_SEARCH=8'h43,
                     C_CH1_ON=8'h46, C_CH1_OFF=8'h47,
                     C_CH2_ON=8'h48, C_CH2_OFF=8'h49,
                     C_STILL=8'h4f, C_CLEAR=8'h56,
                     C_ADDR_INQ=8'h60, C_STATUS_INQ=8'h67;
    localparam [7:0] ACK = 8'h0a;

    // ACK latencies from the LDP-1000A programming manual (ldp1000.cpp:99-102).
    localparam [31:0] US = CLK_HZ / 64'd1_000_000;
    localparam [31:0] T_CLEAR = US * 32'd4300;
    localparam [31:0] T_NUM   = US * 32'd1200;
    localparam [31:0] T_ENTER = US * 32'd2600;

    wire is_digit = (cmd_byte >= 8'h30) && (cmd_byte <= 8'h39);
    wire [3:0] dig = cmd_byte[3:0];          // ASCII '0'..'9' -> 0..9

    reg  [16:0] number;
    reg         search_armed;
    reg  [19:0] dig_sr, dig_latched;
    assign dbg_digits = dig_latched;

    // ---- reply queue (8 deep; the deepest response is the 5-byte status) ----
    reg  [7:0] q [0:7];
    reg  [2:0] qw, qr;
    reg  [3:0] qn;
    assign tx_valid = (qn != 4'd0);
    assign tx_byte  = q[qr];

    reg        push_en;
    reg  [7:0] push_val;
    wire       q_pop  = tx_pop && tx_valid;
    wire       q_push = push_en && (qn != 4'd8);   // full queue drops, never wraps

    // ---- delayed ACK ----
    reg  [31:0] ack_timer;
    reg         ack_pending;

    // ---- multi-byte response sequencer ----
    localparam [1:0] S_IDLE=2'd0, S_BCD=2'd1, S_ADDR=2'd2, S_STATUS=2'd3;
    reg  [1:0]  seq;
    reg  [2:0]  seq_i;
    reg  [19:0] bcd;        // 5 BCD nibbles
    reg  [16:0] bin;
    reg  [4:0]  bcd_i;

    // double-dabble adjust, unrolled: Quartus 17.0 is happier without a
    // variable part-select, and there are only five nibbles.
    function [3:0] adj1(input [3:0] n);
        adj1 = (n >= 4'd5) ? (n + 4'd3) : n;
    endfunction
    function [19:0] dd_adj(input [19:0] v);
        dd_adj = {adj1(v[19:16]), adj1(v[15:12]), adj1(v[11:8]),
                  adj1(v[7:4]),   adj1(v[3:0])};
    endfunction

    // Hoisted: a bit-select applied straight to a function call is not legal here.
    wire [19:0] bcd_adj = dd_adj(bcd);

    always_comb begin
        cmd_action = 1'b0;
        cmd_op     = OP_NOP;
        cmd_arg    = 17'd0;
        if (sel && cmd_stb && !is_digit) begin
            case (cmd_byte)
                C_PLAY:    begin cmd_action = 1'b1; cmd_op = OP_PLAY; end
                C_STILL:   begin cmd_action = 1'b1; cmd_op = OP_STOP; end
                C_CH1_ON:  begin cmd_action = 1'b1; cmd_op = OP_AUDIO1; cmd_arg = 17'b11; end
                C_CH1_OFF: begin cmd_action = 1'b1; cmd_op = OP_AUDIO1; cmd_arg = 17'b10; end
                C_CH2_ON:  begin cmd_action = 1'b1; cmd_op = OP_AUDIO2; cmd_arg = 17'b11; end
                C_CH2_OFF: begin cmd_action = 1'b1; cmd_op = OP_AUDIO2; cmd_arg = 17'b10; end
                C_ENTER: if (search_armed) begin
                             cmd_action = 1'b1; cmd_op = OP_SEARCH; cmd_arg = number;
                         end
                default: ;   // arming, inquiries, text, repeat: no transport op
            endcase
        end
    end

    integer i;
    always @(posedge clk) begin
        push_en <= 1'b0;
        if (!reset_n) begin
            qw <= 3'd0; qr <= 3'd0; qn <= 4'd0;
            number <= 17'd0; search_armed <= 1'b0;
            dig_sr <= 20'd0; dig_latched <= 20'd0;
            ack_timer <= 32'd0; ack_pending <= 1'b0;
            seq <= S_IDLE; seq_i <= 3'd0; bcd <= 20'd0; bin <= 17'd0; bcd_i <= 5'd0;
        end else if (!pause) begin
            // ---- queue maintenance: push and pop are independent ----
            if (q_push) begin q[qw] <= push_val; qw <= qw + 3'd1; end
            if (q_pop)  qr <= qr + 3'd1;
            case ({q_push, q_pop})
                2'b10:   qn <= qn + 4'd1;
                2'b01:   qn <= qn - 4'd1;
                default: ;   // both or neither: depth unchanged
            endcase

            // ---- delayed ACK ----
            if (ack_pending) begin
                if (ack_timer != 32'd0) ack_timer <= ack_timer - 32'd1;
                else begin
                    ack_pending <= 1'b0;
                    push_en <= 1'b1; push_val <= ACK;
                end
            end

            // ---- multi-byte responses ----
            case (seq)
                S_BCD: begin
                    if (bcd_i == 5'd17) begin
                        seq <= S_ADDR; seq_i <= 3'd0;
                    end else begin
                        bcd   <= {bcd_adj[18:0], bin[16]};
                        bin   <= {bin[15:0], 1'b0};
                        bcd_i <= bcd_i + 5'd1;
                    end
                end
                S_ADDR: begin
                    // five ASCII digits, most significant first
                    push_en  <= 1'b1;
                    case (seq_i)
                        3'd0: push_val <= 8'h30 + {4'd0, bcd[19:16]};
                        3'd1: push_val <= 8'h30 + {4'd0, bcd[15:12]};
                        3'd2: push_val <= 8'h30 + {4'd0, bcd[11:8]};
                        3'd3: push_val <= 8'h30 + {4'd0, bcd[7:4]};
                        default: push_val <= 8'h30 + {4'd0, bcd[3:0]};
                    endcase
                    if (seq_i == 3'd4) seq <= S_IDLE; else seq_i <= seq_i + 3'd1;
                end
                S_STATUS: begin
                    push_en <= 1'b1;
                    case (seq_i)
                        3'd0: push_val <= 8'h80;
                        3'd1: push_val <= 8'h00;
                        3'd2: push_val <= 8'h10;
                        3'd3: push_val <= 8'h00;   // disc in, door closed
                        default: push_val <= (mode == M_PLAY) ? 8'h01 : 8'h20;
                    endcase
                    if (seq_i == 3'd4) seq <= S_IDLE; else seq_i <= seq_i + 3'd1;
                end
                default: ;
            endcase

            // ---- command reception ----
            if (sel && cmd_stb) begin
                if (is_digit) begin
                    number      <= (number * 17'd10) + {13'd0, dig};
                    dig_sr      <= {dig_sr[15:0], dig};
                    ack_pending <= 1'b1; ack_timer <= T_NUM;
                end else begin
                    case (cmd_byte)
                        C_SEARCH: begin
                            search_armed <= 1'b1; number <= 17'd0; dig_sr <= 20'd0;
                            ack_pending <= 1'b1; ack_timer <= T_ENTER;
                        end
                        C_ENTER: begin
                            if (search_armed) begin
                                dig_latched <= dig_sr; dig_sr <= 20'd0;
                                search_armed <= 1'b0; number <= 17'd0;
                            end
                            ack_pending <= 1'b1; ack_timer <= T_ENTER;
                        end
                        C_CLEAR: begin
                            search_armed <= 1'b0; number <= 17'd0; dig_sr <= 20'd0;
                            ack_pending <= 1'b1; ack_timer <= T_CLEAR;
                        end
                        C_ADDR_INQ: begin
                            // no ACK: the five frame digits ARE the reply
                            bin <= curr_frame; bcd <= 20'd0; bcd_i <= 5'd0; seq <= S_BCD;
                        end
                        C_STATUS_INQ: begin
                            seq <= S_STATUS; seq_i <= 3'd0;
                        end
                        C_PLAY, C_STILL, C_CH1_ON, C_CH1_OFF, C_CH2_ON, C_CH2_OFF,
                        C_MUTE_ON, C_MUTE_OFF: begin
                            number <= 17'd0;
                            push_en <= 1'b1; push_val <= ACK;   // immediate
                        end
                        // Text overlay and Repeat: ACK and do nothing (see header).
                        default: begin
                            push_en <= 1'b1; push_val <= ACK;
                        end
                    endcase
                end
            end
        end
    end
endmodule
