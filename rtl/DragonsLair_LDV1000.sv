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
// Unhandled opcodes (scan/skip/step/audio/store/display/get-frame) are ignored.
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
    output reg [16:0] curr_frame      // current disc frame (0..54000) for the video path
);
    // ---- status codes (ldv1000hle.h) ----
    localparam [7:0] ST_PARK=8'h7c, ST_PLAY=8'h64, ST_STOP=8'h65,
                     ST_SEARCH=8'h50, ST_SEARCH_FIN=8'hd0, ST_READY=8'h80;
    // ---- modes ----
    localparam [1:0] M_PARK=2'd0, M_SEARCH=2'd1, M_PLAY=2'd2, M_STOP=2'd3;
    // ---- action opcodes ----
    localparam [7:0] CMD_CLEAR=8'hbf, CMD_SEARCH=8'hf7, CMD_PLAY=8'hfd,
                     CMD_STOP=8'hfb, CMD_AUTOSTOP=8'hf3;

    // digit opcode -> 0..9 (0xf = not a digit)
    function [3:0] digit_of(input [7:0] op);
        case (op)
            8'h3f: digit_of=4'd0; 8'h0f: digit_of=4'd1; 8'h8f: digit_of=4'd2;
            8'h4f: digit_of=4'd3; 8'h2f: digit_of=4'd4; 8'haf: digit_of=4'd5;
            8'h6f: digit_of=4'd6; 8'h1f: digit_of=4'd7; 8'h9f: digit_of=4'd8;
            8'h5f: digit_of=4'd9; default: digit_of=4'hf;
        endcase
    endfunction

    reg  [1:0]  mode;
    reg  [16:0] number;         // accumulated entered frame number
    reg  [16:0] search_frame;
    reg  [16:0] stop_frame;
    reg         stop_valid;

    // frame-period / strobe generator: PARK 21 ms (matches the POST-proven stub),
    // active ~33.37 ms = 1/29.97 s so the game sees one strobe per disc frame.
    localparam [20:0] PARK_PERIOD = 21'd840000;    // 21 ms    @ 40 MHz
    localparam [20:0] PLAY_PERIOD = 21'd1334667;   // 33.367 ms = 1/29.97 s
    localparam [20:0] STAT_LOW    = 21'd1040;      // 26 us status-strobe low
    localparam [20:0] CMD_LO_S    = 21'd2160;      // 54 us command-strobe start
    localparam [20:0] CMD_LO_E    = 21'd3160;      // 79 us command-strobe end (25 us)
    wire [20:0] period = (mode==M_PARK) ? PARK_PERIOD : PLAY_PERIOD;
    reg  [20:0] fcnt;
    wire        frame_tick = (fcnt >= period - 21'd1);

    wire [3:0]  dig = digit_of(cmd_byte);

    always @(posedge clk) begin
        if (!reset_n) begin
            mode <= M_PARK; status <= ST_PARK | ST_READY;   // 0xFC
            number <= 17'd0; search_frame <= 17'd0; stop_frame <= 17'd0;
            stop_valid <= 1'b0; curr_frame <= 17'd0; fcnt <= 21'd0;
            status_strobe <= 1'b1; command_strobe <= 1'b1;
        end else begin
            // ---- strobe generator (idle high, assert low) ----
            if (frame_tick) fcnt <= 21'd0; else fcnt <= fcnt + 21'd1;
            status_strobe  <= ~(fcnt < STAT_LOW);
            command_strobe <= ~((fcnt >= CMD_LO_S) & (fcnt < CMD_LO_E));

            // ---- per-frame disc motion, locked to the strobe the game reads ----
            if (frame_tick) begin
                case (mode)
                    M_PLAY: begin
                        curr_frame <= curr_frame + 17'd1;
                        if (stop_valid && (curr_frame + 17'd1 >= stop_frame)) begin
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
                    default: ; // PARK / STOP: hold frame
                endcase
            end

            // ---- command reception ----
            if (cmd_stb) begin
                if (dig != 4'hf) begin
                    number <= (number * 17'd10) + {13'd0, dig};   // decimal accumulate
                end else begin
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
                        default: number <= 17'd0;             // ignore unhandled cmd
                    endcase
                end
            end
        end
    end
endmodule
