//============================================================================
// tms9928a_regs.sv — TMS9928A CPU-side interface: VRAM, registers, interrupt.
//
// Cliff Hanger's overlay chip. This module implements everything the Z80 can
// SEE -- the two-write address protocol, 16 KB VRAM with auto-increment, the
// eight write-only registers and the status register -- plus the vblank
// interrupt, which the game depends on for timing (it drives the Z80 NMI).
//
// It does NOT render. Nothing is scanned out of VRAM yet, so the overlay is
// invisible; the game still runs, seeks and plays disc video. Rendering
// (text mode 1, graphics II, sprites) is the remaining piece.
//
// Port protocol (standard TMS9918A family):
//   port0 (Cliff 0x44 W / 0x45 R): VRAM data, address auto-increments
//   port1 (Cliff 0x54 W):  written twice. first byte = low address/data,
//                          second: b7=1 -> write data to register b2:0
//                                  b7=0,b6=1 -> set VRAM write address
//                                  b7=0,b6=0 -> set VRAM read address
//   port1 (Cliff 0x55 R):  status; reading clears the INT flag and the
//                          first/second-byte latch.
//============================================================================
module tms9928a_regs
(
    input             clk,
    input             reset_n,
    input             ce,            // CPU-rate clock enable

    // Chip selects. These are LEVELS from CliffHanger, not pulses -- the module
    // edge-detects them internally. dout still uses the level, because the CPU
    // samples it combinationally during the same IO cycle.
    input             port0_rd,
    input             port0_wr,
    input             port1_rd,
    input             port1_wr,
    input      [7:0]  din,
    output     [7:0]  dout,

    input             vblank_tick,   // 1-cyc, once per field (59.94 Hz)
    output            irq_n,         // active low -> Z80 NMI source

    // The eight write-only registers, packed { reg7, reg6, ... reg0 }, for the
    // display side (tms9928a_render) which needs the mode and table bases.
    output     [63:0] regs_o,

    // VRAM backing store (external, so it can infer BRAM)
    output     [13:0] vram_addr,
    output     [7:0]  vram_din,
    output reg        vram_we,
    input      [7:0]  vram_dout
);
    reg  [7:0]  regs [0:7];
    reg  [13:0] addr;
    reg         second;          // second-byte latch for port1 writes
    reg  [7:0]  first;
    reg         int_flag;        // status b7, set at vblank, cleared on status read

    assign vram_addr = addr;
    assign vram_din  = din;
    assign regs_o = {regs[7], regs[6], regs[5], regs[4],
                     regs[3], regs[2], regs[1], regs[0]};
    // Interrupt is the flag ANDed with register 1 bit 5 (GINT).
    assign irq_n = ~(int_flag & regs[1][5]);

    // Read data must be COMBINATIONAL. The Z80 samples this during the same I/O
    // cycle that asserts the read strobe, so a registered `dout` hands it the
    // PREVIOUS read's byte -- VRAM readback can then never match and the board's
    // video-RAM verify at $050F (`in a,($45)` / `cp h` / `jr nz,$`) spins forever.
    // Only the side effects below (address increment, flag/latch clears) are
    // clocked; the data itself is driven live.
    assign dout = port1_rd ? {int_flag, 7'd0}   // status: sprite flags not modelled
                           : vram_dout;

    // The chip selects arrive as LEVELS -- CliffHanger builds them combinationally
    // (io_access & ~n_wr & addr match), so they stay high for the whole Z80 IO
    // cycle, which is several `ce` ticks. Acting on the level walks the
    // first/second byte machine more than once per write: `first` gets clobbered
    // by the select byte and every register ends up holding 0x80|index. That is
    // why R7 read back 0x87, painting the backdrop cyan instead of the real red.
    // Act on the RISING EDGE only. Same shape as ld_tx_stb in DragonsLair2.sv.
    reg  p0w_q, p0r_q, p1w_q, p1r_q;
    wire p0w = port0_wr & ~p0w_q;
    wire p0r = port0_rd & ~p0r_q;
    wire p1w = port1_wr & ~p1w_q;
    wire p1r = port1_rd & ~p1r_q;
    // ...and the END of each port-0 access. The auto-increment must happen when
    // the access finishes, NOT when it starts: vram_addr is `addr` combinationally
    // and vram_we is registered, so incrementing at the start puts the write one
    // byte past where the CPU aimed, and makes a read return addr+1's data.
    wire p0w_end = ~port0_wr & p0w_q;
    wire p0r_end = ~port0_rd & p0r_q;

    integer i;
    always @(posedge clk) begin
        vram_we <= 1'b0;
        if (!reset_n) begin
            addr <= 14'd0; second <= 1'b0; first <= 8'd0;
            int_flag <= 1'b0;
            p0w_q <= 1'b0; p0r_q <= 1'b0; p1w_q <= 1'b0; p1r_q <= 1'b0;
            for (i = 0; i < 8; i = i + 1) regs[i] <= 8'd0;
        end else begin
            if (vblank_tick) int_flag <= 1'b1;

            if (ce) begin
                p0w_q <= port0_wr; p0r_q <= port0_rd;
                p1w_q <= port1_wr; p1r_q <= port1_rd;

                // ---- port 0: VRAM data ----
                if (p0w) begin
                    vram_we  <= 1'b1;      // written AT addr, which still holds
                    second   <= 1'b0;
                end
                // The data itself is driven combinationally above; only the
                // auto-increment happens here. `ce` runs at the Z80 T-state rate,
                // ~20 clk_sys cycles apart, so vram_dout has long settled to
                // mem[addr] before the CPU samples it.
                if (p0r) second <= 1'b0;

                // Pointer advances once the access is over, for both directions.
                if (p0w_end || p0r_end) addr <= addr + 14'd1;

                // ---- port 1: address / register setup ----
                if (p1w) begin
                    if (!second) begin
                        first  <= din;
                        second <= 1'b1;
                    end else begin
                        second <= 1'b0;
                        if (din[7]) regs[din[2:0]] <= first;
                        else        addr <= {din[5:0], first};   // b6: 1=write, 0=read
                    end
                end

                // ---- port 1: status read ----
                if (p1r) begin
                    int_flag <= 1'b0;               // reading status clears F
                    second   <= 1'b0;               // ...and the byte latch
                end
            end
        end
    end
endmodule
