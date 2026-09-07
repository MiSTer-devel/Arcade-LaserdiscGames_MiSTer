//============================================================================
// ddram_byte_port.sv — byte-wide CPU RAM over ddram.sv's spare "rom" port.
//
// Dragon's Lair II's RAM cannot live on-chip: the core is already at 75% of its
// M10K blocks (413/553). It goes to DDR instead. Bandwidth is a non-issue --
// measured disc traffic peaks at 2.0 MB/s and the framebuffer adds ~13 MB/s on
// a 64-bit bus at 80 MHz -- the constraint is purely block RAM.
//
// This uses ddram.sv's rom read/write port, which the core ties off as unused.
// Doing it this way means ddram.sv itself is NOT modified, so the framebuffer
// arbitration (and its DDR-DOUTREADY-FIX history) is left alone.
//
// That port is 16 bits wide with byte enables and a TOGGLE handshake: flip
// rom_req, wait until rom_ack equals it. ddram already keeps a 64-bit cache
// behind the port, so consecutive accesses inside one word never reach DDR.
// A 2-byte local latch is kept on top so the second byte of a 16-bit word is
// free even of the handshake.
//============================================================================
module ddram_byte_port
#(
    // Byte base inside DDR. Must not collide with the framebuffer at 0x30000000.
    parameter [27:0] BASE = 28'h1000000
)
(
    input             clk,
    input             reset_n,

    // ---- CPU side, byte wide ----
    input      [23:0] cpu_addr,
    input      [7:0]  cpu_din,
    input             cpu_rd,          // 1-cycle request
    input             cpu_wr,          // 1-cycle request
    output reg [7:0]  cpu_dout,
    output            busy,

    // ---- ddram.sv "rom" port ----
    output     [27:1] mem_addr,
    output     [15:0] mem_din,
    output     [1:0]  mem_be,
    output reg        mem_we,
    output reg        mem_req,         // toggle
    input             mem_ack,
    input      [15:0] mem_dout
);
    wire [27:1] word_addr = {BASE[27:1] + {3'd0, cpu_addr[23:1]}};

    reg  [22:0] tag;                   // cpu_addr[23:1] of the latched word
    reg         tag_valid;
    reg  [15:0] word_q;

    reg         pending;
    reg         pend_is_rd;
    reg  [2:0]  pend_lane;             // only bit 0 matters; kept wide for clarity
    reg  [22:0] pend_tag;

    assign busy     = pending;
    assign mem_addr = word_addr;
    assign mem_din  = {2{cpu_din}};
    assign mem_be   = cpu_addr[0] ? 2'b10 : 2'b01;

    always @(posedge clk) begin
        if (!reset_n) begin
            tag_valid <= 1'b0; tag <= 23'd0; word_q <= 16'd0;
            pending <= 1'b0; pend_is_rd <= 1'b0; pend_lane <= 3'd0; pend_tag <= 23'd0;
            mem_req <= 1'b0; mem_we <= 1'b0; cpu_dout <= 8'd0;
        end else begin
            if (!pending) begin
                if (cpu_rd) begin
                    if (tag_valid && (tag == cpu_addr[23:1])) begin
                        cpu_dout <= cpu_addr[0] ? word_q[15:8] : word_q[7:0];   // free
                    end else begin
                        pend_is_rd <= 1'b1; pend_lane <= {2'd0, cpu_addr[0]};
                        pend_tag   <= cpu_addr[23:1];
                        pending    <= 1'b1;
                        mem_we     <= 1'b0;
                        mem_req    <= ~mem_req;      // toggle to start
                    end
                end else if (cpu_wr) begin
                    pend_is_rd <= 1'b0; pend_lane <= {2'd0, cpu_addr[0]};
                    pend_tag   <= cpu_addr[23:1];
                    pending    <= 1'b1;
                    mem_we     <= 1'b1;
                    mem_req    <= ~mem_req;
                    // keep the latched word coherent instead of dropping it
                    if (tag_valid && (tag == cpu_addr[23:1])) begin
                        if (cpu_addr[0]) word_q[15:8] <= cpu_din;
                        else             word_q[7:0]  <= cpu_din;
                    end
                end
            end else if (mem_ack == mem_req) begin   // handshake complete
                pending <= 1'b0;
                mem_we  <= 1'b0;
                if (pend_is_rd) begin
                    word_q    <= mem_dout;
                    tag       <= pend_tag;
                    tag_valid <= 1'b1;
                    cpu_dout  <= pend_lane[0] ? mem_dout[15:8] : mem_dout[7:0];
                end
            end
        end
    end
endmodule
