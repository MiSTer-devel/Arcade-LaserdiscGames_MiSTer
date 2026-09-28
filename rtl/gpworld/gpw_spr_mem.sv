//============================================================================
// gpw_spr_mem.sv — GP World sprite graphics in DDR, over ddram.sv's "rom" port.
//
// 160K of sprite ROM does not fit the remaining block RAM. The download writes
// it into DDR (stalling the HPS with ioctl_wait), and the renderer reads it
// back one 16-bit word at a time.
//
// DDR layout interleaves the two planes of a bank: byte {bank, addr[14:0],
// plane}. One word read then carries both bytes of a 4-pixel group, and a row
// walks consecutive words, so the port's 64-bit cache and next-word prefetch
// serve most reads.
//
// Download: ioctl index 0, 0x10000-0x3FFFF = MAME's gfx2 region (0x8000 bytes
// of plane 0 then 0x8000 of plane 1, per 64K bank).
//
// The port uses a toggle handshake (start = req != ack). req follows ack while
// disabled, so taking the port over from another user never looks complete.
//============================================================================
module gpw_spr_mem
#(
    parameter [27:0] BASE = 28'h2000000     // byte base; clear of the framebuffer at 0x30000000
)
(
    input             clk,
    input             en,                   // GP World selected

    // ---- ROM download ----
    input             ioctl_wr,
    input      [24:0] ioctl_addr,
    input       [7:0] ioctl_dout,
    input       [7:0] ioctl_index,
    output            ioctl_wait,

    // ---- renderer ----
    input             rd_req,               // 1-cycle
    input      [17:0] rd_addr,              // {bank[2:0], addr[14:0]}
    output reg        rd_valid,             // 1-cycle
    output reg [15:0] rd_data,              // {plane1, plane0}

    // ---- ddram.sv "rom" port ----
    output reg [27:1] mem_addr,
    output reg [15:0] mem_din,
    output reg  [1:0] mem_be,
    output reg        mem_we,
    output reg        mem_req,
    input             mem_ack,
    input      [15:0] mem_dout
);
    wire        in_spr = en && ioctl_wr && (ioctl_index == 8'd0) &&
                         (ioctl_addr >= 25'h10000) && (ioctl_addr < 25'h40000);
    wire [17:0] off    = ioctl_addr[17:0] - 18'h10000;

    reg        busy;
    reg        is_rd;
    reg        ld_pend;
    reg [17:0] ld_word;
    reg        ld_plane;
    reg  [7:0] ld_byte;
    reg        rd_pend;
    reg [17:0] rd_word;

    assign ioctl_wait = ld_pend | (busy & ~is_rd);

    always @(posedge clk) begin
        rd_valid <= 1'b0;
        if (!en) begin
            busy <= 1'b0; is_rd <= 1'b0; ld_pend <= 1'b0; rd_pend <= 1'b0;
            mem_req <= mem_ack; mem_we <= 1'b0;
        end else begin
            if (in_spr) begin
                ld_pend  <= 1'b1;
                ld_word  <= {1'b0, off[17:16], off[14:0]};
                ld_plane <= off[15];
                ld_byte  <= ioctl_dout;
            end
            if (rd_req) begin
                rd_pend <= 1'b1;
                rd_word <= rd_addr;
            end

            if (!busy) begin
                if (ld_pend && !in_spr) begin
                    mem_addr <= BASE[27:1] + {9'd0, ld_word};
                    mem_din  <= {2{ld_byte}};
                    mem_be   <= ld_plane ? 2'b10 : 2'b01;
                    mem_we   <= 1'b1;
                    mem_req  <= ~mem_req;
                    busy     <= 1'b1; is_rd <= 1'b0;
                    ld_pend  <= 1'b0;
                end else if (rd_pend && !rd_req) begin
                    mem_addr <= BASE[27:1] + {9'd0, rd_word};
                    mem_we   <= 1'b0;
                    mem_req  <= ~mem_req;
                    busy     <= 1'b1; is_rd <= 1'b1;
                    rd_pend  <= 1'b0;
                end
            end else if (mem_ack == mem_req) begin
                busy   <= 1'b0;
                mem_we <= 1'b0;
                if (is_rd) begin
                    rd_data  <= mem_dout;
                    rd_valid <= 1'b1;
                end
            end
        end
    end
endmodule
