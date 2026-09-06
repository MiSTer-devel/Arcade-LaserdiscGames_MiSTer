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
    output  [3:0] cop_d
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

t400_por #(.delay_g(4), .cnt_width_g(2)) u_por
(
    .clk_i   (clk_sys),
    .por_n_o (por_n)
);

// Generic overrides: opt_type_g = t400_opt_type_421_c (1),
// opt_ck_div_g = t400_opt_ck_div_32_c (3), opt_cko_g = t400_opt_cko_crystal_c (0).
t400_core #(.opt_type_g(1), .opt_ck_div_g(3), .opt_cko_g(0)) u_cop
(
    .ck_i      (clk_sys),
    .ck_en_i   (cen_2m),
    .por_n_i   (por_n),
    .reset_n_i (reset_n),
    .cko_i     (1'b0),

    .pm_addr_o (pm_addr),
    .pm_data_i (pm_data),

    .dm_addr_o (dm_addr),
    .dm_we_o   (dm_we),
    .dm_data_o (dm_data_o),
    .dm_data_i (dm_data_i),

    .io_l_i    (z80_to_cop),
    .io_l_o    (l_from_cop),
    .io_l_en_o (l_en),

    .io_d_o    (cop_d),
    .io_d_en_o (d_en),

    .io_g_i    (g_latch),
    .io_g_o    (g_from_cop),
    .io_g_en_o (g_en),

    .io_in_i   (4'hF),
    .si_i      (1'b0),
    .so_o      (),
    .so_en_o   (),
    .sk_o      (),
    .sk_en_o   ()
);

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
