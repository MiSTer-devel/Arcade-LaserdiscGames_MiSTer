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
// The text overlay (0x80/0x81/0x82 + 0x00/0x01/0x02 sub-modes, 0x1a terminator)
// is FRAMED but not rendered: its bytes are consumed so they cannot be mistaken
// for commands, and position/scale/on-off are latched. Drawing the characters
// needs a video overlay that does not exist yet. Repeat (0x44) still ACKs and is
// inert. ACK policy follows Daphne exactly -- a real player answers many
// commands with silence, and ACKing those injects bytes the game never expects.
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

    output     [19:0] dbg_digits,

    // ---- text overlay feed ----------------------------------------------
    // Glyph INDICES, not ASCII: the character set belongs to this player, so
    // the renderer downstream stays font- and game-agnostic.
    output reg        txt_we,
    output reg  [1:0] txt_line,
    output reg  [5:0] txt_col,
    output reg  [7:0] txt_glyph,
    output            txt_on,
    output      [7:0] txt_x,
    output      [7:0] txt_y
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

    // ---- text overlay framing (Daphne ldp1000.cpp write_ldp1000) ----
    // The DL2 board has NO video hardware: everything it puts on screen is sent
    // here as text. Without this state machine those payload bytes fall through
    // to the command decoder, where 'O' is STILL, 'V' is C.L. and ':' is PLAY --
    // so the game's own title screen stops and resets the disc.
    // Daphne draw_singleline_LDP1450's character map, reproduced exactly. Note
    // 0x3A..0x40 (': ; < = > ? @') all fall through to space -- which is why a
    // real cabinet renders "VERS 3.19" when the wire carries "VERS:3.19". The
    // font HAS glyphs at 0, 21 and 22 that no character can ever select.
    localparam [7:0] G_SPACE = 8'd49, G_INV = 8'd50;
    function [7:0] glyph_of(input [7:0] c);
        if      (c >= 8'h26 && c <= 8'h39) glyph_of = c - 8'h25;   //  & ' ( ) * + , - . / 0-9
        else if (c >= 8'h41 && c <= 8'h5A) glyph_of = c - 8'h2A;   //  A-Z
        else if (c == 8'h13)               glyph_of = G_INV;       //  inversed space
        else                               glyph_of = G_SPACE;
    endfunction

    localparam [1:0] TX_NONE = 2'd0, TX_XY = 2'd1, TX_STR = 2'd2, TX_WIN = 2'd3;
    reg  [1:0]  tmode;
    reg         tcmd;              // 0x80 seen; the next byte picks the sub-mode
    reg  [1:0]  xy_i;              // X, then Y, then scale
    reg         got_line;          // the 00/0a/14 line byte of a string
    reg  [7:0]  text_x, text_y, text_scale;
    reg  [1:0]  text_line;
    reg         text_on;
    reg  [5:0]  tcol;               // write cursor within the current line
    reg  [5:0]  space_cnt;          // spaces seen in the current string
    reg  [5:0]  fill_i;             // blank-fill cursor after a string ends
    reg  [1:0]  fill_line;
    reg         clear_all;          // fill spans all three lines, not just a tail
    reg         filling;
    assign txt_on = text_on;
    assign txt_x  = text_x;
    assign txt_y  = text_y;
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
        // Text payload must not reach the transport either: this block is
        // separate from the sequential decoder, so gating only there still let
        // 'O' in "CORP." issue OP_STOP and ':' in "VERS:3.19" issue OP_PLAY.
        if (sel && cmd_stb && !is_digit && (tmode == TX_NONE)) begin
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
            tmode <= TX_NONE; tcmd <= 1'b0; xy_i <= 2'd0; got_line <= 1'b0;
            tcol <= 6'd0; space_cnt <= 6'd0;
            fill_i <= 6'd0; fill_line <= 2'd0; clear_all <= 1'b0; filling <= 1'b0;
            txt_we <= 1'b0; txt_line <= 2'd0; txt_col <= 6'd0; txt_glyph <= G_SPACE;
            text_x <= 8'd0; text_y <= 8'd0; text_scale <= 8'd0;
            text_line <= 2'd0; text_on <= 1'b0;
            dig_sr <= 20'd0; dig_latched <= 20'd0;
            ack_timer <= 32'd0; ack_pending <= 1'b0;
            seq <= S_IDLE; seq_i <= 3'd0; bcd <= 20'd0; bin <= 17'd0; bcd_i <= 5'd0;
        end else if (!pause) begin
            txt_we <= 1'b0;

            // Blank-fill, one cell per clock: pads a finished line's tail, or walks
            // all three lines for a clear-all. Worst case is 96 clocks; serial
            // bytes arrive ~160,000 clocks apart at 4800 baud, so it always
            // completes between bytes. A byte landing mid-fill would win the
            // shared write port for that cycle -- it cannot happen at this baud,
            // but that is the assumption, not a guarantee of the logic.
            if (filling) begin
                txt_we    <= 1'b1;
                txt_line  <= fill_line;
                txt_col   <= fill_i;
                txt_glyph <= G_SPACE;
                if (fill_i == 6'd31) begin
                    // A clear-all walks on into the next line; a tail pad stops.
                    if (clear_all && (fill_line != 2'd2)) begin
                        fill_line <= fill_line + 2'd1;
                        fill_i    <= 6'd0;
                    end else filling <= 1'b0;
                end else fill_i <= fill_i + 6'd1;
            end

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
                // Text framing runs FIRST and consumes its bytes without ACKing:
                // the real player answers none of them.
                if (tmode == TX_XY) begin
                    if      (xy_i == 2'd0) begin text_x <= cmd_byte; xy_i <= 2'd1; end
                    else if (xy_i == 2'd1) begin text_y <= cmd_byte; xy_i <= 2'd2; end
                    else    begin text_scale <= cmd_byte; tmode <= TX_NONE; end
                end else if (tmode == TX_WIN) begin
                    tmode <= TX_NONE;                  // argument accepted and ignored
                end else if (tmode == TX_STR) begin
                    if (!got_line && (cmd_byte == 8'h00 || cmd_byte == 8'h0A || cmd_byte == 8'h14)) begin
                        text_line <= (cmd_byte == 8'h00) ? 2'd0 :
                                     (cmd_byte == 8'h0A) ? 2'd1 : 2'd2;
                        got_line  <= 1'b1;
                        tcol      <= 6'd0;             // cursor to start of line
                        space_cnt <= 6'd0;
                    end else if (cmd_byte == 8'h1A) begin
                        tmode   <= TX_NONE; got_line <= 1'b0;
                        filling <= 1'b1;
                        // A MOSTLY-BLANK STRING IS NOT A WRITE. Daphne counts the
                        // spaces in the completed string and, above 20, clears all
                        // three lines instead of storing to the addressed one.
                        // DL2 sends a 31-space string between screens, so without
                        // this the other two lines linger on screen.
                        if (space_cnt > 6'd20) begin
                            clear_all <= 1'b1; fill_line <= 2'd0; fill_i <= 6'd0;
                        end else begin
                            // ordinary string: pad its tail so a longer previous
                            // line cannot show through
                            clear_all <= 1'b0; fill_line <= text_line; fill_i <= tcol;
                        end
                    end else if (cmd_byte >= 8'h20 || cmd_byte == 8'h13) begin
                        // Daphne stores only these; anything lower is dropped
                        // WITHOUT advancing the cursor.
                        txt_we    <= 1'b1;
                        txt_line  <= text_line;
                        txt_col   <= tcol;
                        txt_glyph <= glyph_of(cmd_byte);
                        if (cmd_byte == 8'h20 && space_cnt != 6'd63)
                            space_cnt <= space_cnt + 6'd1;
                        if (tcol != 6'd63) tcol <= tcol + 6'd1;
                    end
                end else if (is_digit) begin
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
                        C_PLAY, C_STILL, C_CH1_ON, C_CH1_OFF, C_CH2_ON, C_CH2_OFF: begin
                            number <= 17'd0;
                            push_en <= 1'b1; push_val <= ACK;   // immediate
                        end
                        8'h80: tcmd    <= 1'b1;                 // USER INDEX CONTROL
                        8'h81: text_on <= 1'b1;                 // USER INDEX ON
                        8'h82: text_on <= 1'b0;                 // USER INDEX OFF
                        // Text sub-mode selectors, only meaningful right after
                        // 0x80. Daphne leaves the flag set through 0x02.
                        8'h00: if (tcmd) begin tmode <= TX_XY;  xy_i <= 2'd0;    tcmd <= 1'b0; end
                        8'h01: if (tcmd) begin tmode <= TX_STR; got_line <= 1'b0; tcmd <= 1'b0; end
                        8'h02: if (tcmd)       tmode <= TX_WIN;
                        // Answered by silence on a real player, so no ACK here:
                        // stray text framing bytes, audio mute, video on, stop
                        // codes, frame mode, motor on, CX on.
                        8'h0A, 8'h14, 8'h1A,
                        C_MUTE_ON, C_MUTE_OFF,
                        8'h27, 8'h28, 8'h29, 8'h55, 8'h62, 8'h6E: ;
                        default: begin
                            push_en <= 1'b1; push_val <= ACK;
                        end
                    endcase
                end
            end
        end
    end
endmodule
