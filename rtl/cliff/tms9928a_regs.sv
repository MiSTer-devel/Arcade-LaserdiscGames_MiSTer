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

    input             port0_rd,      // 1-cyc strobe
    input             port0_wr,
    input             port1_rd,
    input             port1_wr,
    input      [7:0]  din,
    output reg [7:0]  dout,

    input             vblank_tick,   // 1-cyc, once per field (59.94 Hz)
    output            irq_n,         // active low -> Z80 NMI source

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
    reg  [7:0]  read_buf;        // TMS9918 prefetch buffer

    assign vram_addr = addr;
    assign vram_din  = din;
    // Interrupt is the flag ANDed with register 1 bit 5 (GINT).
    assign irq_n = ~(int_flag & regs[1][5]);

    integer i;
    always @(posedge clk) begin
        vram_we <= 1'b0;
        if (!reset_n) begin
            addr <= 14'd0; second <= 1'b0; first <= 8'd0;
            int_flag <= 1'b0; read_buf <= 8'd0; dout <= 8'd0;
            for (i = 0; i < 8; i = i + 1) regs[i] <= 8'd0;
        end else begin
            if (vblank_tick) int_flag <= 1'b1;

            if (ce) begin
                // ---- port 0: VRAM data ----
                if (port0_wr) begin
                    vram_we  <= 1'b1;
                    read_buf <= din;
                    addr     <= addr + 14'd1;
                    second   <= 1'b0;
                end
                if (port0_rd) begin
                    dout     <= read_buf;   // prefetched byte
                    read_buf <= vram_dout;
                    addr     <= addr + 14'd1;
                    second   <= 1'b0;
                end

                // ---- port 1: address / register setup ----
                if (port1_wr) begin
                    if (!second) begin
                        first  <= din;
                        second <= 1'b1;
                    end else begin
                        second <= 1'b0;
                        if (din[7])       regs[din[2:0]] <= first;
                        else begin
                            addr <= {din[5:0], first};
                            // a read setup prefetches the first byte
                            if (!din[6]) read_buf <= vram_dout;
                        end
                    end
                end

                // ---- port 1: status read ----
                if (port1_rd) begin
                    dout     <= {int_flag, 7'd0};   // sprite flags not modelled
                    int_flag <= 1'b0;
                    second   <= 1'b0;
                end
            end
        end
    end
endmodule
