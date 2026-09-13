//============================================================================
// ldp_ldv1000.sv — Pioneer LD-V1000 protocol front-end.
//
// Ported from MAME pioneer_ldv1000hle_device. Owns everything player-specific:
// the ready-window handshake, the status byte at 0xC020, the per-field status
// and command strobes, and the digit accumulator. Disc motion lives in
// ldp_transport.sv.
//
// Strobes idle HIGH and assert LOW: SYSTEM b6 = status_strobe, b7 = ~command_strobe.
// One byte per ready window: accepting a command clears bit 7 and only 0xFF
// re-arms it. 0xFF is the handshake ACK, not idle filler -- it must be fully
// inert or a multi-digit SEARCH accumulates wrong. A real SEARCH is
// 0xBF, 0xFF, d, 0xFF, d, 0xFF, d, 0xFF, d, 0xFF, d, 0xFF, 0xF7.
//============================================================================
module ldp_ldv1000
#(
    parameter [31:0] CLK_HZ = 32'd80_000_000
)
(
    input             clk,
    input             reset_n,
    input             pause,
    input             sel,              // this front-end drives the transport

    input             cmd_stb,          // 1-cyc: a byte was strobed out by the CPU
    input      [7:0]  cmd_byte,

    // ---- transport ----
    output reg        cmd_action,
    output reg [3:0]  cmd_op,
    output reg [16:0] cmd_arg,
    input             search_done,
    input             autostop_done,
    input      [21:0] field_phase,

    // ---- CPU side ----
    input      [16:0] curr_frame,       // picture number, for the 0xC2 readback
    input             status_rd,        // 1-cyc at the END of a CPU status read
    output     [7:0]  status,           // -> 0xC020 laserdisc_r
    output reg        status_strobe,    // -> SYSTEM b6 (idle 1, asserts low)
    output reg        command_strobe,   // SYSTEM b7 = ~command_strobe
    output     [19:0] dbg_digits        // raw SEARCH digits, 5 nibbles
);
`include "ldp_bus.svh"

    reg [7:0] status_r;                 // player state byte, behind the 0xC2 queue

    // ---- status codes (ldv1000hle.h) ----
    localparam [7:0] ST_PARK=8'h7c, ST_PLAY=8'h64, ST_STOP=8'h65,
                     ST_SEARCH=8'h50, ST_SEARCH_FIN=8'hd0, ST_READY=8'h80,
                     ST_SCAN=8'h4c, ST_FORWARD=8'h2e;

    // ---- action opcodes (cross-checked vs ldv1000hle.h) ----
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
                     // known-inert group (matches MAME's own unimplemented stubs)
                     CMD_STORE=8'hf5, CMD_RECALL=8'h7f, CMD_DISPLAY=8'hf1,
                     CMD_DISPLAY_ENABLE=8'hce, CMD_DISPLAY_DISABLE=8'hcd,
                     CMD_GET_FRAME_NUM=8'hc2, CMD_GET_2ND_DISPLAY=8'hc3, CMD_GET_1ST_DISPLAY=8'hc4,
                     CMD_TRANSFER_MEMORY=8'hc8, CMD_LOAD=8'hcc;

    // Strobe timing, LD-V1000-specific. The player strobes once per FIELD (59.94 Hz),
    // not per frame (Daphne ldp.cpp:703).
    localparam [21:0] STAT_LOW = (64'd1040 * CLK_HZ) / 64'd40_000_000;  // 26 us status_r-strobe low
    localparam [21:0] CMD_LO_S = (64'd2160 * CLK_HZ) / 64'd40_000_000;  // 54 us command-strobe start
    localparam [21:0] CMD_LO_E = (64'd3160 * CLK_HZ) / 64'd40_000_000;  // 79 us command-strobe end

    // digit opcode -> 0..9 (0xf = not a digit)
    function [3:0] digit_of(input [7:0] op);
        case (op)
            8'h3f: digit_of=4'd0; 8'h0f: digit_of=4'd1; 8'h8f: digit_of=4'd2;
            8'h4f: digit_of=4'd3; 8'h2f: digit_of=4'd4; 8'haf: digit_of=4'd5;
            8'h6f: digit_of=4'd6; 8'h1f: digit_of=4'd7; 8'h9f: digit_of=4'd8;
            8'h5f: digit_of=4'd9; default: digit_of=4'hf;
        endcase
    endfunction

    reg  [16:0] number;        // accumulated entered frame number
    reg         has_digit;     // "no digits typed" (toggle) vs "digit typed" (explicit set)
    reg  [19:0] dig_sr;        // raw digit nibbles as received, newest low
    reg  [19:0] dig_latched;   // frozen at CMD_SEARCH
    assign dbg_digits = dig_latched;

    wire [3:0] dig = digit_of(cmd_byte);
    // The ready window: one byte accepted per arming, only 0xFF re-arms.
    wire accepted  = sel && cmd_stb && !pause && (cmd_byte != CMD_NO_ENTRY) && status_r[7];
    wire is_digit  = accepted && (dig != 4'hf);
    wire is_action = accepted && (dig == 4'hf);

    // Combinational so the transport acts in the same cycle the byte is decoded.
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
                CMD_SCAN_FWD: cmd_op = OP_SCAN_FWD;
                CMD_SCAN_REV: cmd_op = OP_SCAN_REV;
                CMD_STEP_FWD: cmd_op = OP_STEP_FWD;
                CMD_STEP_REV: cmd_op = OP_STEP_REV;
                CMD_REJECT:   cmd_op = OP_PARK;
                CMD_FWD_X0:   begin cmd_op = OP_PLAY_SPD; cmd_arg = 17'd0;  end
                CMD_FWD_X1_4: begin cmd_op = OP_PLAY_SPD; cmd_arg = 17'd1;  end
                CMD_FWD_X1_2: begin cmd_op = OP_PLAY_SPD; cmd_arg = 17'd2;  end
                CMD_FWD_X1:   begin cmd_op = OP_PLAY_SPD; cmd_arg = 17'd4;  end
                CMD_FWD_X2:   begin cmd_op = OP_PLAY_SPD; cmd_arg = 17'd8;  end
                CMD_FWD_X3:   begin cmd_op = OP_PLAY_SPD; cmd_arg = 17'd12; end
                CMD_FWD_X4:   begin cmd_op = OP_PLAY_SPD; cmd_arg = 17'd16; end
                CMD_FWD_X5:   begin cmd_op = OP_PLAY_SPD; cmd_arg = 17'd20; end
                CMD_SKIP_FWD_10:  begin cmd_op = OP_SKIP; cmd_arg = 17'd10;  end
                CMD_SKIP_FWD_20:  begin cmd_op = OP_SKIP; cmd_arg = 17'd20;  end
                CMD_SKIP_FWD_30:  begin cmd_op = OP_SKIP; cmd_arg = 17'd30;  end
                CMD_SKIP_FWD_40:  begin cmd_op = OP_SKIP; cmd_arg = 17'd40;  end
                CMD_SKIP_FWD_50:  begin cmd_op = OP_SKIP; cmd_arg = 17'd50;  end
                CMD_SKIP_FWD_60:  begin cmd_op = OP_SKIP; cmd_arg = 17'd60;  end
                CMD_SKIP_FWD_70:  begin cmd_op = OP_SKIP; cmd_arg = 17'd70;  end
                CMD_SKIP_FWD_80:  begin cmd_op = OP_SKIP; cmd_arg = 17'd80;  end
                CMD_SKIP_FWD_90:  begin cmd_op = OP_SKIP; cmd_arg = 17'd90;  end
                CMD_SKIP_FWD_100: begin cmd_op = OP_SKIP; cmd_arg = 17'd100; end
                default: ;   // CLEAR, the inert group and unrecognized bytes: OP_NOP
            endcase
        end
    end

    // 0xC2 answers the next five status reads with the picture number in ASCII,
    // high digit first, then falls back to the state byte (Daphne ldv1000.cpp
    // read_ldv1000 pops its output stack ahead of the status, and
    // framenum_to_frame is sprintf "%05d").  Super Don polls this every main-loop
    // pass at $15AB and masks each reply with 0x0F to rebuild the frame in BCD.
    reg [15:0] dd_bin;
    reg [19:0] dd_bcd;
    reg  [4:0] dd_cnt;
    reg [19:0] fq;                      // five BCD digits left to hand back
    reg  [2:0] fq_cnt;

    wire [3:0] a0 = (dd_bcd[3:0]   >= 4'd5) ? dd_bcd[3:0]   + 4'd3 : dd_bcd[3:0];
    wire [3:0] a1 = (dd_bcd[7:4]   >= 4'd5) ? dd_bcd[7:4]   + 4'd3 : dd_bcd[7:4];
    wire [3:0] a2 = (dd_bcd[11:8]  >= 4'd5) ? dd_bcd[11:8]  + 4'd3 : dd_bcd[11:8];
    wire [3:0] a3 = (dd_bcd[15:12] >= 4'd5) ? dd_bcd[15:12] + 4'd3 : dd_bcd[15:12];
    wire [3:0] a4 = (dd_bcd[19:16] >= 4'd5) ? dd_bcd[19:16] + 4'd3 : dd_bcd[19:16];

    wire load_frame = accepted && (cmd_byte == CMD_GET_FRAME_NUM);

    always @(posedge clk) begin
        if (!reset_n) begin
            dd_bin <= 16'd0; dd_bcd <= 20'd0; dd_cnt <= 5'd0;
            fq     <= 20'd0; fq_cnt <= 3'd0;
        end else begin
            if (load_frame) begin
                dd_bin <= curr_frame[15:0]; dd_bcd <= 20'd0; dd_cnt <= 5'd16;
                fq_cnt <= 3'd0;
            end else if (dd_cnt != 5'd0) begin
                dd_bcd <= {a4[2:0], a3, a2, a1, a0, dd_bin[15]};
                dd_bin <= {dd_bin[14:0], 1'b0};
                dd_cnt <= dd_cnt - 5'd1;
                if (dd_cnt == 5'd1) begin
                    fq     <= {a4[2:0], a3, a2, a1, a0, dd_bin[15]};
                    fq_cnt <= 3'd5;
                end
            end else if (status_rd && (fq_cnt != 3'd0)) begin
                fq     <= {fq[15:0], 4'd0};
                fq_cnt <= fq_cnt - 3'd1;
            end
        end
    end

    assign status = (fq_cnt != 3'd0) ? {4'h3, fq[19:16]} : status_r;

    always @(posedge clk) begin
        if (!reset_n) begin
            status_r <= ST_PARK | ST_READY;   // 0xFC
            status_strobe <= 1'b1; command_strobe <= 1'b1;
            number <= 17'd0; has_digit <= 1'b0;
            dig_sr <= 20'd0; dig_latched <= 20'd0;
        end else if (!pause) begin
            status_strobe  <= ~(field_phase < STAT_LOW);
            command_strobe <= ~((field_phase >= CMD_LO_S) & (field_phase < CMD_LO_E));

            // Mechanism-driven status changes, before the byte below so a command in the
            // same cycle still wins (matching the pre-split ordering).
            if (search_done)   status_r <= ST_SEARCH_FIN;         // 0xd0, "search succeeded"
            if (autostop_done) status_r <= ST_STOP | ST_READY;

            if (sel && cmd_stb) begin
                if (cmd_byte == CMD_NO_ENTRY) begin
                    status_r <= status_r | ST_READY;                // the only thing that re-arms
                end else if (!status_r[7]) begin
                    status_r <= status_r & 8'h7f;                   // not ready => byte ignored entirely
                end else if (dig != 4'hf) begin
                    status_r <= status_r & 8'h7f;                   // consumed => not ready
                    number <= (number * 17'd10) + {13'd0, dig};
                    has_digit <= 1'b1;
                    dig_sr <= {dig_sr[15:0], dig};              // raw digits, as received
                end else begin
                    status_r    <= status_r & 8'h7f;                // case below may override
                    has_digit <= 1'b0;                          // every action consumes the accumulator
                    case (cmd_byte)
                        CMD_CLEAR: begin number <= 17'd0; dig_sr <= 20'd0; end
                        CMD_SEARCH: begin
                            dig_latched <= dig_sr; dig_sr <= 20'd0;
                            status_r <= ST_SEARCH;                // 0x50 busy -- seen immediately
                            number <= 17'd0;
                        end
                        CMD_PLAY:     begin status_r <= ST_PLAY;             number <= 17'd0; end
                        // STOP clears READY like every accepted command; only 0xFF re-arms.
                        CMD_STOP:     begin status_r <= ST_STOP;             number <= 17'd0; end
                        CMD_AUTOSTOP: begin status_r <= ST_PLAY;             number <= 17'd0; end
                        CMD_AUDIO1, CMD_AUDIO2: number <= 17'd0;
                        CMD_SCAN_FWD, CMD_SCAN_REV: begin
                            status_r <= ST_SCAN; number <= 17'd0;
                        end
                        // REJECT must leave READY clear: the ready bit IS the
                        // "command consumed" ack, and only 0xFF re-arms it. Super Don
                        // Quix-ote parks the player at $14DB and resends until it clears.
                        CMD_STEP_FWD, CMD_STEP_REV, CMD_REJECT: begin
                            status_r <= (cmd_byte == CMD_REJECT) ? ST_PARK
                                                               : (ST_STOP | ST_READY);
                            number <= 17'd0;
                        end
                        CMD_FWD_X0, CMD_FWD_X1_4, CMD_FWD_X1_2, CMD_FWD_X1,
                        CMD_FWD_X2, CMD_FWD_X3, CMD_FWD_X4, CMD_FWD_X5: begin
                            status_r <= ST_FORWARD; number <= 17'd0;
                        end
                        CMD_SKIP_FWD_10, CMD_SKIP_FWD_20, CMD_SKIP_FWD_30, CMD_SKIP_FWD_40,
                        CMD_SKIP_FWD_50, CMD_SKIP_FWD_60, CMD_SKIP_FWD_70, CMD_SKIP_FWD_80,
                        CMD_SKIP_FWD_90, CMD_SKIP_FWD_100: begin
                            status_r <= ST_SEARCH; number <= 17'd0;
                        end
                        CMD_STORE, CMD_RECALL, CMD_DISPLAY, CMD_DISPLAY_ENABLE,
                        CMD_DISPLAY_DISABLE, CMD_GET_FRAME_NUM, CMD_GET_1ST_DISPLAY,
                        CMD_GET_2ND_DISPLAY, CMD_TRANSFER_MEMORY, CMD_LOAD:
                            number <= 17'd0;
                        // Unrecognized bytes are INERT (Daphne only logs them): clearing
                        // `number` here would silently destroy a SEARCH target mid-entry.
                        default: ;
                    endcase
                end
            end
        end
    end
endmodule
