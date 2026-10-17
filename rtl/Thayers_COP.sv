//============================================================================
//  Thayer's Quest COP421 keyboard / timer MCU subsystem
//  Wraps freecores/t400 (rtl/cpu/t400, VHDL) running the real tq_cop.bin.
//  The COP is the machine's ONLY interrupt source: its D port drives both the
//  timer tick (D0) and the keyboard data-ready (D1), which the Z80 board turns
//  into IRQs (Daphne game/thayers.cpp thayers_write_d_port).
//  t400_core is driven directly rather than via the t421 wrapper so the program
//  ROM can come from the MRA (ioctl index 2) instead of being baked into the
//  bitstream.  COP421 = t400_opt_type_421_c, CKI divisor 32, crystal CKO,
//  clocked at 2 MHz (4 MHz crystal divided by 2 externally on the real board).
//============================================================================

module Thayers_COP
#(
    parameter [31:0] CLK_HZ = 32'd80_000_000
)
(
    input         clk_sys,
    input         reset_n,

    // COP program ROM download (MRA <rom index="2">, tq_cop.bin, 1KB)
    input         rom_cs_i,
    input  [24:0] ioctl_addr,
    input   [7:0] ioctl_data,
    input         ioctl_wr,

    // Z80 <-> COP data path
    input   [7:0] z80_dout,
    input         wr_g,          // OUT ($20): b7:b5 -> COP G2:G0
    input         wr_data,       // OUT ($80): byte to the COP L port
    output  [7:0] rd_data,       // IN  ($80): last byte the COP drove on L

    // D port, as the COP drives it (active low). b0 = timer, b1 = data ready.
    output  [3:0] cop_d,

    // 40-key panel matrix, 10 rows x 4 bits, active HIGH. Row r bit b = keys[r*4+b].
    input  [39:0] keys,

    // ---- the shared COP421 (t400_0) in the dispatcher's chip pool ----
    output chip_pool_pkg::t400_i_t t400_0_i,
    input  chip_pool_pkg::t400_o_t t400_0_o
);

// 2 MHz enable for the COP (the core divides by 32 internally for CKI/32).
localparam [5:0] CDIV = CLK_HZ / 32'd2_000_000;
reg [5:0] cdiv = 6'd0;
always_ff @(posedge clk_sys) cdiv <= (cdiv == CDIV - 6'd1) ? 6'd0 : cdiv + 6'd1;
wire cen_2m = (cdiv == 6'd0);

// ---- Z80 <-> COP latches ----
reg [7:0] z80_to_cop = 8'd0;   // Z80 OUT ($80) -> COP reads on L
reg [7:0] cop_to_z80 = 8'd0;   // COP drives L  -> Z80 IN  ($80)
reg [3:0] g_latch    = 4'hF;   // Z80 OUT ($20) b7:b5 -> G2:G0
reg       wr_g_busy  = 1'b0;
reg       wr_d_busy  = 1'b0;

wire [7:0] l_from_cop, l_en;

always_ff @(posedge clk_sys) begin
    if (!reset_n) begin
        z80_to_cop <= 8'd0;
        cop_to_z80 <= 8'd0;
        g_latch    <= 4'hF;
        wr_g_busy  <= 1'b0;
        wr_d_busy  <= 1'b0;
    end
    else begin
        // Both strobes span many clk_sys cycles; latch once per access.
        if (wr_data) begin
            if (!wr_d_busy) begin z80_to_cop <= z80_dout; wr_d_busy <= 1'b1; end
        end
        else wr_d_busy <= 1'b0;

        if (wr_g) begin
            if (!wr_g_busy) begin g_latch <= {1'b1, z80_dout[7:5]}; wr_g_busy <= 1'b1; end
        end
        else wr_g_busy <= 1'b0;

        // Capture whatever the COP drives onto L.
        if (|l_en) cop_to_z80 <= l_from_cop;
    end
end

assign rd_data = cop_to_z80;

// ---- COP421 core ----
wire [9:0] pm_addr;
wire [7:0] pm_data;
wire [5:0] dm_addr;
wire       dm_we;
wire [3:0] dm_data_o, dm_data_i;
wire [3:0] d_en, g_from_cop, g_en;
wire       por_n;

// The shared COP421 core (t400_0, with its power-on reset) lives in the dispatcher.
assign t400_0_i.ck_en   = cen_2m;
assign t400_0_i.pm_data = pm_data;
assign t400_0_i.dm_data = dm_data_i;
assign t400_0_i.io_l    = z80_to_cop;
assign t400_0_i.io_g    = g_latch;
assign pm_addr     = t400_0_o.pm_addr;
assign dm_addr     = t400_0_o.dm_addr;
assign dm_we       = t400_0_o.dm_we;
assign dm_data_o   = t400_0_o.dm_data;
assign l_from_cop  = t400_0_o.io_l;
assign l_en        = t400_0_o.io_l_en;
assign cop_d       = t400_0_o.io_d;
assign d_en        = t400_0_o.io_d_en;
assign g_from_cop  = t400_0_o.io_g;
assign g_en        = t400_0_o.io_g_en;

//------------------------------------------------------- Keyboard -------------------------------------------------------------//
// The panel is a SERIAL device on the COP's SK/SI pins, not a Z80 port.  The COP
// free-runs SK; on each FALLING edge the panel shifts out one bit of a 10-bit
// frame (Daphne/MAME thayers.cpp kbclk_w):
//
//     1, 0, 1, Q9, P3, P2, P1, P0, 0, <wrap>
//
// Q9 is high only while row 9 is being shifted -- that is the frame sync the COP
// locks onto, so it must be driven even when no key is down.  After bit 10 the
// row advances and the NEW row is latched, which is also the row Q9 describes.
wire       sk_from_cop;
reg        sk_q     = 1'b0;
reg  [3:0] rx_bit   = 4'd0;    // 0..10
reg  [3:0] keylatch = 4'd0;    // current row 0..9
reg  [3:0] keydata  = 4'd0;    // row bits, shifted out MSB first
reg        kbdata   = 1'b1;    // -> SI, idles high
assign t400_0_i.si = kbdata;     // keyboard serial data -> the shared COP421
assign sk_from_cop = t400_0_o.sk; // keyboard serial clock, driven by the COP

wire [3:0] rx_nxt  = rx_bit + 4'd1;
wire [3:0] kl_nxt  = (keylatch == 4'd9) ? 4'd0 : keylatch + 4'd1;
wire [3:0] row_nxt = keys[{kl_nxt, 2'b00} +: 4];

always_ff @(posedge clk_sys) begin
    if (!reset_n) begin
        sk_q <= 1'b0; rx_bit <= 4'd0; keylatch <= 4'd0;
        keydata <= 4'd0; kbdata <= 1'b1;
    end
    else begin
        sk_q <= sk_from_cop;
        if (sk_q & ~sk_from_cop) begin          // falling edge of SK only
            case (rx_nxt)
                4'd1, 4'd3: begin kbdata <= 1'b1;                  rx_bit <= rx_nxt; end
                4'd2, 4'd9: begin kbdata <= 1'b0;                  rx_bit <= rx_nxt; end
                4'd4:       begin kbdata <= (keylatch == 4'd9);    rx_bit <= rx_nxt; end
                4'd10: begin                                       // wrap + advance row
                    kbdata   <= 1'b1;
                    rx_bit   <= 4'd0;
                    keylatch <= kl_nxt;
                    keydata  <= row_nxt;
                end
                default: begin                                     // bits 5..8 = P3..P0
                    kbdata  <= keydata[3];
                    keydata <= {keydata[2:0], 1'b0};
                    rx_bit  <= rx_nxt;
                end
            endcase
        end
    end
end

// Program ROM: 1KB, MRA index 2.
dpram_dc #(.widthad_a(10)) cop_rom
(
    .clock_a   (clk_sys),
    .address_a (pm_addr),
    .data_a    (8'd0),
    .wren_a    (1'b0),
    .q_a       (pm_data),

    .clock_b   (clk_sys),
    .address_b (ioctl_addr[9:0]),
    .data_b    (ioctl_data),
    .wren_b    (ioctl_wr & rom_cs_i),
    .q_b       ()
);

// Data RAM: COP421 = 64 x 4.
generic_ram_ena #(.addr_width_g(6), .data_width_g(4)) cop_ram
(
    .clk_i (clk_sys),
    .a_i   (dm_addr),
    .we_i  (dm_we),
    .ena_i (cen_2m),
    .d_i   (dm_data_o),
    .d_o   (dm_data_i)
);

endmodule
