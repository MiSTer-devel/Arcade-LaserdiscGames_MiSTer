//============================================================================
//  Dragon's Lair II / Space Ace '91 (Leland, 1991) — board.
//
//  I8088 in MAX mode at 10 MHz (MAME cinematronics/dlair2.cpp: XTAL(30MHz)/3,
//  "Schematics show I8088 'max' CPU"), Sony LDP-1450 on a serial port.
//
//  There is NO video hardware on this board. Daphne's lair2::video_repaint()
//  only resizes the overlay to match the disc; the on-screen text comes from
//  the LDP-1450's own text overlay. So this board is CPU + memory + IO only.
//
//  Memory map (MAME mainmem):
//    0x00000-0xEFFFF  RAM  -- external port, backed by DDR (ddram_cpu_ram);
//                            it cannot live on-chip, the core is at 75% of its
//                            M10K blocks.
//    0xF0000-0xFFFFF  ROM  -- 64KB dl2_319.bin. Reset vector is 0xFFFF0.
//
//  IO map (MAME, commented there; corroborated by Daphne lair2.cpp's header
//  "IO_PORT = 0x201, COIN_PORT = 0x202, CNTL_PORT = 0x202"):
//    0x020        interrupt controller
//    0x042/0x043, 0x061   sound
//    0x200-0x203  io / coin / eeprom
//    0x2F8-0x2FF  COM2 -> the LDP-1450
//
//  CLOCKS: MCL86 takes two. CLK is the 8088 pin clock and must be 10 MHz;
//  CORE_CLK_INT runs the microcode engine.
//
//  This board runs entirely in the 80 MHz core domain, so CLK = 80/8 = exactly
//  10 MHz. The MCL86 datasheet says CORE_CLK_INT should be 100 MHz for the
//  microcode's instruction timing to track a real 8088 (and is explicit that
//  even then it is "cycle compatible, not cycle exact"), so instructions here
//  run about 25% slow in wall-clock. That is a deliberate trade: putting the
//  CPU in its own 100 MHz domain would need clock-domain crossings on BOTH the
//  DDR RAM path and the LD player's single-cycle search/play-end strobes, and a
//  missed strobe is an intermittent video fault. A 100 MHz PLL output exists
//  (outclk_1) if the timing ever proves to matter.
//============================================================================
module DragonsLair2
(
    input                core_clk,        // CLK_CORE, 80 MHz
    input                reset_n,

    // ---- controls ----
    // DL2 has NO DIP switches: its settings live in an EEPROM (port 0x202 b0),
    // which is why MAME's dlair2 DIPs are explicit dummies and the OSD shows no
    // DIP page. Only these inputs exist.
    input          [7:0] p1,              // {b3,b2,b1,sword, right,left,down,up} active HIGH
    input          [3:0] cab,             // {coin2, coin1, start2, start1} active HIGH

    // ---- ROM download ----
    input         [24:0] ioctl_addr,
    input          [7:0] ioctl_data,
    input                ioctl_wr,
    input          [7:0] ioctl_index,

    // ---- main RAM, external (DDR-backed) ----
    output        [23:0] ram_addr,
    output         [7:0] ram_din,
    output               ram_rd,
    output               ram_wr,
    input          [7:0] ram_dout,
    input                ram_busy,

    // ---- LDP-1450 serial link (COM2) ----
    // The player itself lives in the 80 MHz core domain, NOT here: its
    // search/play-end strobes are single-cycle and would be dropped crossing
    // 100 -> 80 MHz. Only this byte-rate link crosses, through a toggle bridge.
    output               ld_tx_stb,
    output         [7:0] ld_tx_byte,
    input                ld_rx_valid,
    input          [7:0] ld_rx_byte,
    output               ld_rx_pop,

    // ---- telemetry ----
    output        [19:0] dbg_addr,
    output         [2:0] dbg_type,
    output               dbg_halt
);
    //--------------------------------------------------- 8088 pin clock ------
    // CLK = CORE_CLK_INT / 10 = 10 MHz, 50% duty (5 high, 5 low).
    // CLK = core_clk / 8 = 10 MHz, 50% duty (4 high, 4 low).
    reg [1:0] clkdiv;
    reg       cpu_clk;
    always @(posedge core_clk) begin
        if (!reset_n) begin clkdiv <= 2'd0; cpu_clk <= 1'b0; end
        else if (clkdiv == 2'd3) begin clkdiv <= 2'd0; cpu_clk <= ~cpu_clk; end
        else clkdiv <= clkdiv + 2'd1;
    end

    //--------------------------------------------------- MCL86 ---------------
    wire [15:0] eu_biu_command, eu_biu_dataout, eu_register_r3;
    wire        eu_prefix_lock, eu_flag_i;
    wire        biu_done, biu_clk_counter_zero, biu_nmi_caught, biu_nmi_debounce, biu_intr;
    wire  [1:0] biu_segment;
    wire  [7:0] pfq_top_byte;
    wire        pfq_empty;
    wire [15:0] pfq_addr_out;
    wire [15:0] biu_es, biu_ss, biu_cs, biu_ds, biu_rm, biu_reg, biu_ret;

    wire        ad_oe, lock_n, s6_3_mux;
    wire [19:0] ad_out;
    wire  [7:0] ad_in;
    wire  [2:0] s2_s0;
    wire        ready_in;

    biu_max BIU (
        .CORE_CLK_INT(core_clk),
        .CLK(cpu_clk), .RESET_INT(~reset_n), .READY_IN(ready_in),
        .NMI(1'b0), .INTR(1'b0),
        .LOCK_n(lock_n), .AD_OE(ad_oe), .AD_OUT(ad_out), .AD_IN(ad_in),
        .S6_3_MUX(s6_3_mux), .S2_S0_OUT(s2_s0),
        .EU_BIU_COMMAND(eu_biu_command), .EU_BIU_DATAOUT(eu_biu_dataout),
        .EU_REGISTER_R3(eu_register_r3), .EU_PREFIX_LOCK(eu_prefix_lock),
        .BIU_DONE(biu_done), .BIU_CLK_COUNTER_ZERO(biu_clk_counter_zero),
        .BIU_SEGMENT(biu_segment), .BIU_NMI_CAUGHT(biu_nmi_caught),
        .BIU_NMI_DEBOUNCE(biu_nmi_debounce), .BIU_INTR(biu_intr),
        .PFQ_TOP_BYTE(pfq_top_byte), .PFQ_EMPTY(pfq_empty), .PFQ_ADDR_OUT(pfq_addr_out),
        .BIU_REGISTER_ES(biu_es), .BIU_REGISTER_SS(biu_ss), .BIU_REGISTER_CS(biu_cs),
        .BIU_REGISTER_DS(biu_ds), .BIU_REGISTER_RM(biu_rm), .BIU_REGISTER_REG(biu_reg),
        .BIU_RETURN_DATA(biu_ret)
    );

    // BIU_CLK_COUNTER_ZERO is wired to the real counter, NOT tied to 1 as the
    // author's Lattice example does -- that tie-off is what disables the
    // microcode's instruction timing.
    mcl86_eu_core EU (
        .CORE_CLK_INT(core_clk), .RESET_INT(~reset_n), .TEST_N_INT(1'b1),
        .EU_BIU_COMMAND(eu_biu_command), .EU_BIU_DATAOUT(eu_biu_dataout),
        .EU_REGISTER_R3(eu_register_r3), .EU_PREFIX_LOCK(eu_prefix_lock),
        .EU_FLAG_I(eu_flag_i),
        .BIU_DONE(biu_done), .BIU_CLK_COUNTER_ZERO(biu_clk_counter_zero),
        .BIU_NMI_CAUGHT(biu_nmi_caught), .BIU_NMI_DEBOUNCE(biu_nmi_debounce),
        .BIU_INTR(biu_intr),
        .PFQ_TOP_BYTE(pfq_top_byte), .PFQ_EMPTY(pfq_empty), .PFQ_ADDR_OUT(pfq_addr_out),
        .BIU_REGISTER_ES(biu_es), .BIU_REGISTER_SS(biu_ss), .BIU_REGISTER_CS(biu_cs),
        .BIU_REGISTER_DS(biu_ds), .BIU_REGISTER_RM(biu_rm), .BIU_REGISTER_REG(biu_reg),
        .BIU_RETURN_DATA(biu_ret)
    );

    //--------------------------------------------------- bus glue ------------
    wire        req;
    wire  [2:0] req_type;
    wire [19:0] req_addr;
    wire  [7:0] req_wdata;
    reg   [7:0] req_rdata;
    reg         req_ack;

    dl2_bus BUSGLUE (
        .clk(core_clk), .reset_n(reset_n),
        .s2_s0(s2_s0), .s6_3_mux(s6_3_mux), .ad_out(ad_out),
        .ad_in(ad_in), .ready_in(ready_in),
        .req(req), .req_type(req_type), .req_addr(req_addr), .req_wdata(req_wdata),
        .req_rdata(req_rdata), .req_ack(req_ack)
    );

    assign dbg_addr = req_addr;
    assign dbg_type = req_type;
    assign dbg_halt = (s2_s0 == 3'b011);

    wire is_code  = (req_type == 3'b100);
    wire is_memrd = (req_type == 3'b101) | is_code;
    wire is_memwr = (req_type == 3'b110);
    wire is_iord  = (req_type == 3'b001);
    wire is_iowr  = (req_type == 3'b010);

    //--------------------------------------------------- ROM -----------------
    // 64KB at 0xF0000. Loaded from ioctl index 0.
    wire        in_rom = (req_addr[19:16] == 4'hF);
    wire [7:0]  rom_q;
    dpram_dc #(.widthad_a(16)) prog_rom (
        .clock_a(core_clk), .address_a(req_addr[15:0]), .data_a(8'd0),
        .wren_a(1'b0), .q_a(rom_q),
        .clock_b(core_clk), .address_b(ioctl_addr[15:0]), .data_b(ioctl_data),
        .wren_b(ioctl_wr & (ioctl_index == 8'd0)), .q_b()
    );

    //--------------------------------------------------- RAM (external) ------
    // req_addr is the 8088's 20-bit physical address; the RAM port is 24 bits.
    // Zero-extend -- do NOT slice [23:0], which is out of range (Quartus 10232).
    assign ram_addr = {4'd0, req_addr};
    assign ram_din  = req_wdata;
    // Fire once per cycle, only while the glue is asking and RAM is idle.
    reg ram_started;
    reg rom_wait;   // one-cycle wait for the registered ROM output
    assign ram_rd = req & is_memrd & ~in_rom & ~ram_started & ~ram_busy;
    assign ram_wr = req & is_memwr & ~in_rom & ~ram_started & ~ram_busy;

    //--------------------------------------------------- IO ------------------
    wire [15:0] io_a = req_addr[15:0];
    wire in_com2 = (io_a[15:3] == 13'h05F);        // 0x2F8-0x2FF
    wire in_io   = (io_a[15:2] == 14'h0080);       // 0x200-0x203
    wire in_icr  = (io_a == 16'h0020);

    // COM2 -> LDP-1450. 0x2F8 is the data register; 0x2FD is line status.
    // Must be gated on req_ack (a 1-cycle pulse), NOT on req alone. `req` is a
    // LEVEL held until the cycle is answered, and ldp_ldp1450 treats cmd_stb as
    // a level, so a single OUT would post the same byte on every clock the
    // request was outstanding. Same shape as the Cliff Hanger blip bug, where
    // `cs_wire_w & cpu_ce` emitted three blips per write.
    assign ld_tx_stb  = req & req_ack & is_iowr & in_com2 & (io_a[2:0] == 3'd0);

    //--------------------------------------------------- EEPROM --------------
    // Port 0x202 carries the serial EEPROM lines. DL2 has no DIPs; every
    // operator setting lives in this chip and is written from service mode.
    // Strobe on req_ack so one OUT clocks the EEPROM exactly once.
    wire eep_wr_stb = req & req_ack & is_iowr & in_io & (io_a[1:0] == 2'd2);
    wire eep_do;

    dl2_eeprom u_eeprom (
        .clk(core_clk), .reset_n(reset_n),
        .wr_stb(eep_wr_stb), .wr_data(req_wdata),
        .do_bit(eep_do)
    );
    assign ld_tx_byte = req_wdata;
    assign ld_rx_pop  = req & is_iord & in_com2 & (io_a[2:0] == 3'd0) & req_ack;

    reg [7:0] io_rdata;
    always @(*) begin
        if (in_com2) begin
            case (io_a[2:0])
                3'd0:    io_rdata = ld_rx_byte;                    // RBR
                3'd5:    io_rdata = {2'b01, 4'b0000, 1'b0, ld_rx_valid}; // LSR: THR empty, RX ready
                default: io_rdata = 8'h00;
            endcase
        end else if (in_io) begin
            // Bit assignments from Daphne lair2::input_enable:
            //   banks[0] (0x201, ACTIVE LOW): b0 UP, b1 DOWN, b2 LEFT, b3 RIGHT,
            //                                 b4 START1, b5 START2, b6 SWORD
            //   banks[1] (0x202, ACTIVE HIGH): b0 EEP data, b2-b5 coin 1-4
            // 0x200-0x203. These are NOT all pull-ups -- returning 0xFF for the
            // lot makes the game see four coins permanently inserted, which is
            // how it ended up somewhere unsupported. Daphne lair2.cpp:
            //   0x201 = banks[0], init 0xFF, ACTIVE LOW  (player controls)
            //   0x202 = banks[1], init 0x01, ACTIVE HIGH:
            //           b0 EEP data, b1 unknown, b2-b5 coin 1-4, b6-b7 unknown
            case (io_a[1:0])
                2'd1:    io_rdata = ~{1'b0, p1[4],   // b6 SWORD
                                      cab[1], cab[0],// b5 START2, b4 START1
                                      p1[3], p1[2],  // b3 RIGHT, b2 LEFT
                                      p1[1], p1[0]}; // b1 DOWN,  b0 UP
                2'd2:    io_rdata = {2'b00,          // b7:6 unknown
                                     2'b00,          // b5:4 coin 4, coin 3 (unwired)
                                     cab[3], cab[2], // b3 coin 2, b2 coin 1
                                     1'b0,           // b1 unknown
                                     eep_do};        // b0 EEPROM DO / not-busy
                default: io_rdata = 8'h00;
            endcase
        end
        else if (in_icr)     io_rdata = 8'h00;
        else                 io_rdata = 8'hFF;
    end

    //--------------------------------------------------- response ------------
    always @(posedge core_clk) begin
        req_ack <= 1'b0;
        if (!reset_n) begin
            ram_started <= 1'b0; req_rdata <= 8'hFF; rom_wait <= 1'b0;
        end else begin
            if (!req) begin ram_started <= 1'b0; rom_wait <= 1'b0; end

            if (req && !req_ack) begin
                if (is_iord || is_iowr) begin
                    req_rdata <= io_rdata;
                    req_ack   <= 1'b1;                     // IO answers immediately
                end else if (in_rom && is_memrd) begin
                    // dpram_dc REGISTERS its output, so rom_q trails req_addr by
                    // one clock. Sampling it the same cycle returns the previous
                    // byte and the CPU executes garbage. Give it the cycle.
                    if (!rom_wait) rom_wait <= 1'b1;
                    else begin
                        req_rdata <= rom_q;
                        req_ack   <= 1'b1;
                    end
                end else if (in_rom && is_memwr) begin
                    req_ack   <= 1'b1;                     // writes to ROM are dropped
                end else if (is_memrd || is_memwr) begin
                    if (ram_rd || ram_wr) ram_started <= 1'b1;
                    else if (ram_started && !ram_busy) begin
                        req_rdata <= ram_dout;
                        req_ack   <= 1'b1;
                    end
                end else begin
                    req_rdata <= 8'hFF;                    // INTA / halt: nothing to fetch
                    req_ack   <= 1'b1;
                end
            end
        end
    end
endmodule
