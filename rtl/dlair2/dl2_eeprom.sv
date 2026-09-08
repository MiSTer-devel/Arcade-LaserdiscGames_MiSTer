//============================================================================
// dl2_eeprom.sv — Dragon's Lair II serial EEPROM (NS9536 / 93C56 class).
//
// 128 x 16 bits. DL2 has NO DIP switches: every operator setting -- attract
// sound, free play, pricing, bookkeeping totals -- lives in here and is set
// from the game's own service mode. Without this chip the game cannot read its
// settings, cannot write them, and cannot INITIALISE them, so it can never get
// itself out of a bad configuration even from service mode.
//
// Interface, from Daphne game/lair2.cpp `lair2::EEPROM_9536_write` (which is
// the authority here -- this is a faithful port of it, quirks included):
//
//   port 0x202 WRITE:  b0 = DI   b1 = CLK   b2 = CS   b3 = PRE   b7:4 unknown
//   port 0x202 READ :  b0 = DO, which doubles as the busy/ready flag
//
// Protocol: while CS is high, DI is shifted in on each RISING CLK edge.
//   phase 1  accumulate until the start bit reaches bit 2, then the low 2 bits
//            are the opcode:  0 = extended (EWEN/EWDS/ERAL/WRAL, ignored here
//            exactly as Daphne ignores them), 1 = WRITE, 2 = READ, 3 = ERASE
//   phase 2  8 address bits (Daphne's `9 - org` with org = 1)
//   phase 3  16 data bits: READ shifts the stored word out MSB first, WRITE
//            shifts DI into the word MSB first and holds DO high (not busy)
//   CS low resets the whole state machine.
//
// NOTE: contents are volatile. Daphne persists this to an nvram file; doing the
// same on MiSTer needs save/restore plumbing and is NOT done here, so operator
// settings will not survive a power cycle yet. The array powers up all zero,
// which is the state a fresh Daphne install starts in and the game copes with.
//============================================================================
module dl2_eeprom
(
    input             clk,
    input             reset_n,

    input             wr_stb,        // 1-cycle: the CPU wrote port 0x202
    input      [7:0]  wr_data,       // the byte it wrote

    output            do_bit         // -> port 0x202 read, bit 0
);
    localparam OP_NONE = 2'd3;       // sentinel: no opcode captured yet

    reg [15:0] mem [0:127];
    reg  [7:0] prev;                 // Daphne's `old`, for CLK edge detection

    reg  [2:0] shreg;                // start bit + opcode, phase 1
    reg  [1:0] opcode;
    reg        have_op;
    reg  [7:0] addr;
    reg  [3:0] addr_cnt;             // counts to 8
    reg  [4:0] bit_cnt;              // counts to 16
    reg        do_q;

    assign do_bit = do_q;

    wire cs      = wr_data[2];
    wire clk_hi  = wr_data[1];
    wire di      = wr_data[0];
    wire clk_rise = clk_hi & ~prev[1];

    wire [6:0] a7 = addr[6:0];       // 128 words

    // Power-on contents only. The array is deliberately NOT cleared on reset:
    // this is non-volatile storage, and a real EEPROM keeps its contents across
    // a logic reset. (It also avoids a 2048-flop reset network.)
    integer j;
    initial for (j = 0; j < 128; j = j + 1) mem[j] = 16'd0;

    always @(posedge clk) begin
        if (!reset_n) begin
            prev <= 8'd0; shreg <= 3'd0; opcode <= OP_NONE; have_op <= 1'b0;
            addr <= 8'd0; addr_cnt <= 4'd0; bit_cnt <= 5'd0; do_q <= 1'b1;
        end else if (wr_stb) begin
            prev <= wr_data;

            if (!cs) begin
                // CS low: reset the sequencer (Daphne's else branch).
                shreg <= 3'd0; opcode <= OP_NONE; have_op <= 1'b0;
                addr <= 8'd0; addr_cnt <= 4'd0; bit_cnt <= 5'd0;
            end
            else if (clk_rise) begin
                if (!have_op) begin
                    // Shift until the start bit lands in bit 2.
                    if (shreg[1]) begin           // this shift puts it at bit 2
                        opcode  <= {shreg[0], di};
                        have_op <= 1'b1;
                    end
                    shreg <= {shreg[1:0], di};
                end
                else if (addr_cnt < 4'd8) begin
                    addr     <= {addr[6:0], di};
                    addr_cnt <= addr_cnt + 4'd1;
                    // Daphne presents the stored word's MSB while the address
                    // is still forming; harmless, and kept for fidelity.
                    do_q     <= mem[{addr[5:0], di}][15];
                end
                else begin
                    case (opcode)
                        2'd2: begin                       // READ, MSB first
                            do_q <= mem[a7][15 - bit_cnt[3:0]];
                        end
                        2'd1: begin                       // WRITE, MSB first
                            if (bit_cnt == 5'd0) mem[a7] <= {15'd0, di};
                            else                 mem[a7] <= {mem[a7][14:0], di};
                            do_q <= 1'b1;                 // not busy
                        end
                        default: do_q <= 1'b1;            // extended / erase: ignored
                    endcase
                    if (bit_cnt < 5'd16) bit_cnt <= bit_cnt + 5'd1;
                end
            end
        end
    end
endmodule
