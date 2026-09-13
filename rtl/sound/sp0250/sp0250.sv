//============================================================================
// GI SP0250 LPC speech synthesizer — SystemVerilog port of MAME sp0250.cpp.
//
// Authoritative reference: Useful Information/sp0250.cpp (Olivier Galibert,
// BSD-3-Clause). The datasheet (General_Instrument_SP0250_Datasheet.pdf)
// corroborates pinout and the 15-byte parameter frame layout but does NOT
// publish the internal coefficient ROM or LFSR polynomial — those come from
// MAME's hardware-verified traces.
//
// Non-PWM mode only: produces 14-bit signed PCM at ~10 kHz frame rate
// (ce_rom_1_56m ÷ 156). PWM Digital Out, Direct Data Mode, and ROM Test
// mode are not implemented — Sega speech board doesn't use them.
//
// Sample pipeline per frame:
//   ST_IDLE → wait for sample_tick (~10 kHz)
//   ST_PREP → repeat check (possibly load_values from FIFO), advance LFSR
//   ST_ST0..ST_ST5 → serialize 6-stage biquad cascade, one stage per clk
//   ST_DONE → clamp, output, advance pcount/rcount
//============================================================================

module sp0250 (
    input                clk,
    input                reset_n,

    // Clock enables. On Sega speech board: SP0250 XTAL = 3.12 MHz,
    // ROMCLOCK = XTAL/2 = 1.56 MHz. Only ce_rom_1_56m drives sample timing
    // internally; ce_3_12m is accepted for interface symmetry with T2.9.
    input                ce_3_12m,
    input                ce_rom_1_56m,

    // Parallel write from 8035 / host. `wr` is single-cycle sync to clk.
    input        [7:0]   data_in,
    input                wr,

    // DRQ: 1 = FIFO has space (needs more data), 0 = FIFO full.
    output               drq,

    // 14-bit signed PCM, audio_valid pulses high for 1 clk on new sample.
    output signed [13:0] audio_out,
    output               audio_valid
);

    // Reserved input; consumed for lint cleanliness.
    wire _unused_ce_3_12m = ce_3_12m;

    //------------------------------------------------------------------------
    // Parameter FIFO (15 bytes)
    //------------------------------------------------------------------------
    reg [7:0] fifo [0:14];
    reg [3:0] fifo_pos;             // 0..15 (15 = full, DRQ deasserted)
    assign drq = (fifo_pos != 4'd15);

    //------------------------------------------------------------------------
    // Frame state (mirror of MAME sp0250_device privates)
    //------------------------------------------------------------------------
    reg               voiced;
    reg signed [15:0] amp;
    reg        [14:0] lfsr;         // 15-bit LFSR, reset 0x7FFF
    reg        [7:0]  pitch;
    reg        [7:0]  pcount;
    reg        [5:0]  repeat_count;
    reg        [5:0]  rcount;

    // History and coefficient arrays. Initialized at declaration (Cyclone V
    // M10K supports power-on initialization) and explicitly cleared at the
    // start of each new frame in ST_PREP. Keeping them out of the global
    // reset path is what allows Quartus to infer M10K BRAM rather than
    // distributed register files. Saves ~400-600 ALMs.
    reg signed [15:0] filt_F  [0:5];
    reg signed [15:0] filt_B  [0:5];
    reg signed [15:0] filt_z1 [0:5];
    reg signed [15:0] filt_z2 [0:5];

    initial begin
        filt_F[0]  = 16'sd0; filt_F[1]  = 16'sd0; filt_F[2]  = 16'sd0;
        filt_F[3]  = 16'sd0; filt_F[4]  = 16'sd0; filt_F[5]  = 16'sd0;
        filt_B[0]  = 16'sd0; filt_B[1]  = 16'sd0; filt_B[2]  = 16'sd0;
        filt_B[3]  = 16'sd0; filt_B[4]  = 16'sd0; filt_B[5]  = 16'sd0;
        filt_z1[0] = 16'sd0; filt_z1[1] = 16'sd0; filt_z1[2] = 16'sd0;
        filt_z1[3] = 16'sd0; filt_z1[4] = 16'sd0; filt_z1[5] = 16'sd0;
        filt_z2[0] = 16'sd0; filt_z2[1] = 16'sd0; filt_z2[2] = 16'sd0;
        filt_z2[3] = 16'sd0; filt_z2[4] = 16'sd0; filt_z2[5] = 16'sd0;
    end

    //------------------------------------------------------------------------
    // Coefficient decode.
    //
    // gc(v): 128-entry signed ROM, bit 7 of v selects sign (MAME sp0250_gc).
    //        ONE shared clocked instance with 2-cycle latency. ST_COEF_LOAD
    //        walks the 12 fifo indices through it over 14 cycles and latches
    //        each result into the right filt_F/filt_B register. The previous
    //        code instantiated 12 combinational copies, which blew the
    //        Cyclone V ALM budget by ~20%.
    // ga(v): (v & 0x1f) << (v >> 5) — 3-bit exp × 5-bit mantissa, inline.
    //------------------------------------------------------------------------
    reg  [7:0]         coef_addr;
    wire signed [15:0] coef_val;

    sp0250_coef_rom u_coef (
        .clk (clk),
        .idx (coef_addr),
        .val (coef_val)
    );

    // Coef-load step counter: 0..13. Addresses issued in steps 0..11;
    // writebacks land 2 cycles later in steps 2..13.
    reg [3:0] coef_step;
    reg [2:0] clear_idx;             // 0..5 for ST_CLEAR_Z sequential clear
    reg [3:0] coef_widx;             // BRAM write index for filt_F/filt_B during load

    always @(*) begin
        case (coef_step)
            4'd0:  coef_addr = fifo[0];
            4'd1:  coef_addr = fifo[1];
            4'd2:  coef_addr = fifo[3];
            4'd3:  coef_addr = fifo[4];
            4'd4:  coef_addr = fifo[6];
            4'd5:  coef_addr = fifo[7];
            4'd6:  coef_addr = fifo[9];
            4'd7:  coef_addr = fifo[10];
            4'd8:  coef_addr = fifo[11];
            4'd9:  coef_addr = fifo[12];
            4'd10: coef_addr = fifo[13];
            4'd11: coef_addr = fifo[14];
            default: coef_addr = 8'd0;
        endcase
    end

    wire [4:0] amp_mant  = fifo[2][4:0];
    wire [2:0] amp_shift = fifo[2][7:5];
    wire signed [15:0] ga2 = $signed({11'b0, amp_mant}) << amp_shift;

    //------------------------------------------------------------------------
    // Sample pacing: 1 sample per 156 ROMCLOCKs = ~10 kHz frame rate.
    //------------------------------------------------------------------------
    reg [7:0] sample_divider;
    wire      sample_tick = ce_rom_1_56m && (sample_divider == 8'd0);

    //------------------------------------------------------------------------
    // FSM
    //------------------------------------------------------------------------
    localparam [3:0] ST_IDLE = 4'd0;
    localparam [3:0] ST_PREP = 4'd1;
    localparam [3:0] ST_ST0  = 4'd2;
    localparam [3:0] ST_ST1  = 4'd3;
    localparam [3:0] ST_ST2  = 4'd4;
    localparam [3:0] ST_ST3  = 4'd5;
    localparam [3:0] ST_ST4  = 4'd6;
    localparam [3:0] ST_ST5  = 4'd7;
    localparam [3:0] ST_DONE      = 4'd8;
    localparam [3:0] ST_COEF_LOAD = 4'd9;
    localparam [3:0] ST_CLEAR_Z   = 4'd10;  // sequential z1/z2 zero (6 cycles)
    reg [3:0] state;

    // reg_z0: stage output feeding the next stage. On ST_ST0 entry the
    // excitation (z0_excite) is used instead.
    reg signed [15:0] reg_z0;

    //------------------------------------------------------------------------
    // Excitation z0 (MAME next():
    //   voiced:   z0 = (pcount == 0) ? amp : 0;
    //   unvoiced: z0 = (lfsr & 1)    ? amp : -amp;
    // Uses the post-PREP lfsr/amp/voiced/pcount register values.
    //------------------------------------------------------------------------
    wire signed [15:0] z0_excite =
        voiced ? ((pcount == 8'd0) ? amp : 16'sd0)
               : (lfsr[0] ? amp : -amp);

    wire [2:0]         stage_idx = state[2:0] - 3'd2;   // 0..5 in ST_ST0..ST_ST5

    //------------------------------------------------------------------------
    // Stage datapath (MAME filter::apply):
    //   z0 = in + ((z1 * F) >> 8) + ((z2 * B) >> 9);
    // C promotes to 32-bit int then truncates to int16 on assignment — mirror
    // that with a 32-bit signed sum and take the low 16 bits.
    //------------------------------------------------------------------------
    //------------------------------------------------------------------------
    // BRAM-friendly registered reads. Quartus infers M10K blocks when
    // memory arrays are read through a registered output (clocked read).
    //
    // Stage timing becomes 3 cycles instead of 2:
    //   sub=0  READ:  issue array reads; *_q available next clock
    //   sub=1  MULT:  multiply *_q values into mul_f32/mul_b32
    //   sub=2  WRITE: compute stage_sum, write back to filt_z1/filt_z2,
    //                 advance state
    //
    // 6 stages × 3 cycles = 18 cycles per biquad cascade. Still far under
    // the ~150-cycle sample budget at 1.56 MHz / 10 kHz.
    //
    // Resource target: filt_F/filt_B/filt_z1/filt_z2 → M10K BRAMs.
    //------------------------------------------------------------------------
    reg signed [15:0] F_q, B_q, z1_q, z2_q;
    always @(posedge clk) begin
        F_q  <= filt_F [stage_idx];
        B_q  <= filt_B [stage_idx];
        z1_q <= filt_z1[stage_idx];
        z2_q <= filt_z2[stage_idx];
    end

    //------------------------------------------------------------------------
    // Registered multipliers — forces DSP block inference and breaks the
    // long combinational path. Always running; downstream gates by stage_sub.
    //------------------------------------------------------------------------
    reg signed [31:0] mul_f32, mul_b32;
    reg signed [15:0] stage_in_r;
    reg        [1:0]  stage_sub;     // 0=read, 1=mult, 2=write

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            mul_f32    <= 32'sd0;
            mul_b32    <= 32'sd0;
            stage_in_r <= 16'sd0;
        end else begin
            if (state == ST_ST0 || state == ST_ST1 || state == ST_ST2 ||
                state == ST_ST3 || state == ST_ST4 || state == ST_ST5) begin
                if (stage_sub == 2'd1) begin
                    // sub=1: multiply the values read in sub=0
                    mul_f32    <= z1_q * F_q;
                    mul_b32    <= z2_q * B_q;
                    stage_in_r <= (state == ST_ST0) ? z0_excite : reg_z0;
                end
            end
        end
    end

    wire signed [31:0] stage_sum32 =
        {{16{stage_in_r[15]}}, stage_in_r} + (mul_f32 >>> 8) + (mul_b32 >>> 9);

    wire signed [15:0] stage_out = stage_sum32[15:0];

    //------------------------------------------------------------------------
    // DAC (ST_DONE): (reg_z0 >>> 6) clamped to [-64,63], then <<7 to fill
    // 14-bit signed range. The MAME >>6 matches the hardware's 7-bit DAC;
    // the final <<7 is our FPGA-side scale for the mix bus.
    //------------------------------------------------------------------------
    wire signed [15:0] z_sr6 = reg_z0 >>> 6;
    // 7-bit signed range is -64..+63. `-7'sd64` triggers a constant-overflow
    // warning (7'sd64=64 doesn't fit in 7-bit signed; wraps to -64, negate
    // wraps again) — value happens to land right by accident. Use 8-bit
    // literals and let Quartus narrow on assignment to the 7-bit wire.
    wire signed [6:0]  dac_clamped =
        (z_sr6 < -16'sd64) ? -8'sd64 :
        (z_sr6 >  16'sd63) ?  8'sd63 :
                              z_sr6[6:0];
    wire signed [13:0] audio_next = {dac_clamped, 7'b0};

    reg signed [13:0] audio_reg;
    reg               audio_valid_reg;
    assign audio_out   = audio_reg;
    assign audio_valid = audio_valid_reg;

    //------------------------------------------------------------------------
    // Main sequential block
    //------------------------------------------------------------------------
    integer i;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            fifo_pos        <= 4'd0;
            voiced          <= 1'b0;
            amp             <= 16'sd0;
            lfsr            <= 15'h7FFF;
            pitch           <= 8'd0;
            pcount          <= 8'd0;
            repeat_count    <= 6'd0;
            rcount          <= 6'd0;
            sample_divider  <= 8'd155;
            state           <= ST_IDLE;
            coef_step       <= 4'd0;
            clear_idx       <= 3'd0;
            coef_widx       <= 4'd0;
            stage_sub       <= 2'd0;
            reg_z0          <= 16'sd0;
            audio_reg       <= 14'sd0;
            audio_valid_reg <= 1'b0;
            for (i = 0; i < 15; i = i + 1) begin
                fifo[i] <= 8'd0;
            end
        end else begin
            // Default: audio_valid is a 1-clk pulse asserted from ST_DONE.
            audio_valid_reg <= 1'b0;

            // Sample-rate divider.
            if (sample_tick)           sample_divider <= 8'd155;
            else if (ce_rom_1_56m)     sample_divider <= sample_divider - 8'd1;

            // Host FIFO write. Mutually exclusive with load_values (which
            // requires fifo_pos == 15) so both can be unconditionally active.
            if (wr && fifo_pos != 4'd15) begin
                fifo[fifo_pos] <= data_in;
                fifo_pos       <= fifo_pos + 4'd1;
            end

            case (state)
                ST_IDLE: begin
                    if (sample_tick) state <= ST_PREP;
                end

                ST_PREP: begin
                    // MAME next() top: check repeat/consume new frame.
                    if (rcount >= repeat_count) begin
                        if (fifo_pos == 4'd15) begin
                            // load_values(): non-ROM fields latch here; the
                            // 12 F/B coefs are loaded serially through one
                            // shared coef ROM in ST_COEF_LOAD (14 cycles).
                            amp          <= ga2;
                            pitch        <= fifo[5];
                            repeat_count <= fifo[8][5:0];
                            voiced       <= fifo[8][6];
                            pcount       <= 8'd0;
                            rcount       <= 6'd0;
                            // Sequential z1/z2 zero (BRAM-friendly).
                            clear_idx    <= 3'd0;
                            state        <= ST_CLEAR_Z;
                        end else begin
                            // Starved of input → "NOP" with repeat=1, pitch
                            // unchanged (cpcwiki SP0256 measured-timings ref
                            // cited in MAME).
                            repeat_count <= 6'd1;
                            pcount       <= 8'd0;
                            rcount       <= 6'd0;
                            lfsr         <= {lfsr[0] ^ lfsr[1], lfsr[14:1]};
                            stage_sub    <= 2'd0;
                            state        <= ST_ST0;
                        end
                    end else begin
                        // Repeat ongoing — reuse prior filter state.
                        lfsr      <= {lfsr[0] ^ lfsr[1], lfsr[14:1]};
                        stage_sub <= 2'd0;
                        state     <= ST_ST0;
                    end
                end

                ST_CLEAR_Z: begin
                    // Clear filt_z1[clear_idx] and filt_z2[clear_idx] over 6
                    // cycles. Single write port per BRAM — Quartus-friendly.
                    filt_z1[clear_idx] <= 16'sd0;
                    filt_z2[clear_idx] <= 16'sd0;
                    if (clear_idx == 3'd5) begin
                        coef_step <= 4'd0;
                        coef_widx <= 4'd0;
                        state     <= ST_COEF_LOAD;
                    end else begin
                        clear_idx <= clear_idx + 3'd1;
                    end
                end

                ST_COEF_LOAD: begin
                    // 14-cycle serial coef loader. coef_addr is driven combin-
                    // ationally from coef_step (see addr mux above). ROM has
                    // 2-cycle read latency, so addresses issued in steps 0..11
                    // yield writebacks in steps 2..13.
                    //
                    // BRAM-friendly: a single index drives the write port for
                    // each array. The pattern B0,F0,B1,F1,...,B5,F5 means the
                    // index alternates B/F on each step, with the array index
                    // advancing every two steps. coef_widx (0..5) tracks the
                    // array index; coef_step[0] selects F vs B.
                    coef_step <= coef_step + 4'd1;
                    if (coef_step >= 4'd2 && coef_step <= 4'd13) begin
                        // step 2 -> B[0], step 3 -> F[0], step 4 -> B[1], ...
                        if (coef_step[0])
                            filt_F[coef_widx] <= coef_val;
                        else
                            filt_B[coef_widx] <= coef_val;
                        // After F write (odd step), advance to next array idx
                        if (coef_step[0])
                            coef_widx <= coef_widx + 4'd1;
                    end
                    if (coef_step == 4'd13) begin
                        // Last writeback — clear FIFO, advance LFSR, dispatch.
                        fifo_pos  <= 4'd0;
                        lfsr      <= {lfsr[0] ^ lfsr[1], lfsr[14:1]};
                        stage_sub <= 2'd0;
                        state     <= ST_ST0;
                    end
                end

                ST_ST0, ST_ST1, ST_ST2, ST_ST3, ST_ST4, ST_ST5: begin
                    // 3-cycle stage:
                    //   sub=0 READ:  array reads in flight; *_q valid next clk
                    //   sub=1 MULT:  multipliers latch (separate always block)
                    //   sub=2 WRITE: stage_sum, writeback z1/z2, advance state
                    case (stage_sub)
                        2'd0: stage_sub <= 2'd1;
                        2'd1: stage_sub <= 2'd2;
                        2'd2: begin
                            reg_z0             <= stage_out;
                            filt_z2[stage_idx] <= z1_q;     // old z1 -> z2
                            filt_z1[stage_idx] <= stage_out;
                            stage_sub          <= 2'd0;
                            state              <= (state == ST_ST5) ? ST_DONE
                                                                    : state + 4'd1;
                        end
                    endcase
                end

                ST_DONE: begin
                    audio_reg       <= audio_next;
                    audio_valid_reg <= 1'b1;
                    // Post-increment: compare pcount against pitch, then
                    // either wrap + bump rcount or just increment pcount.
                    if (pcount == pitch) begin
                        pcount <= 8'd0;
                        rcount <= rcount + 6'd1;
                    end else begin
                        pcount <= pcount + 8'd1;
                    end
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
