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
#(
    parameter [31:0] CLK_HZ = 32'd80_000_000
)
(
    input                core_clk,        // CLK_CORE, 80 MHz
    input                reset_n,

    // ---- controls ----
    // DL2 has NO DIP switches: its settings live in an EEPROM (port 0x202 b0),
    // which is why MAME's dlair2 DIPs are explicit dummies and the OSD shows no
    // DIP page. Only these inputs exist.
    input          [7:0] p1,              // {b3,b2,b1,sword, right,left,down,up} active HIGH
    input          [3:0] cab,             // {coin2, coin1, start2, start1} active HIGH
    input                service,         // service switch, active HIGH here

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

    // ---- PC speaker ----
    output signed [15:0] audio,

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
        .NMI(1'b0), .INTR(cpu_intr),
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

    wire cpu_intr;
    wire is_inta  = (req_type == 3'b000);
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
    wire in_pic  = (io_a[15:1] == 15'h0010);       // 0x020-0x021, the 8259
    wire in_pit  = (io_a[15:2] == 14'h0010);       // 0x040-0x043, the 8253
    wire in_spk  = (io_a == 16'h0061);             // PC speaker control

    // COM2 -> LDP-1450: an 8250/16450 register file at 0x2F8.
    //
    // The ROM's send routine (F379C) gates EVERY byte on MSR bit 4 (CTS) and
    // then LSR bit 5 (THRE), and gives up with AX=FFFF if either never sets.
    // It also read-modify-writes LCR, MCR and IER, so those must read back.
    //
    // Writes must be gated on req_ack (a 1-cycle pulse), NOT on req alone.
    // `req` is a LEVEL held until the cycle is answered, and ldp_ldp1450
    // treats cmd_stb as a level, so a single OUT would post the same byte on
    // every clock the request was outstanding. Same shape as the Cliff Hanger
    // blip bug, where `cs_wire_w & cpu_ce` emitted three blips per write.
    reg  [7:0] uart_ier, uart_lcr, uart_mcr, uart_dll, uart_dlm, uart_scr;
    wire       dlab    = uart_lcr[7];
    wire       com2_wr = req & req_ack & is_iowr & in_com2;

    always @(posedge core_clk) begin
        if (!reset_n) begin
            uart_ier <= 8'h00; uart_lcr <= 8'h00; uart_mcr <= 8'h00;
            uart_dll <= 8'h01; uart_dlm <= 8'h00; uart_scr <= 8'h00;
        end else if (com2_wr) begin
            case (io_a[2:0])
                3'd0: if (dlab) uart_dll <= req_wdata;
                3'd1: if (dlab) uart_dlm <= req_wdata; else uart_ier <= req_wdata;
                3'd3: uart_lcr <= req_wdata;
                3'd4: uart_mcr <= req_wdata;
                3'd7: uart_scr <= req_wdata;
                default: ;
            endcase
        end
    end

    // Interrupt identification. A constant "none pending" here makes the ISR read
    // IIR, find nothing to service, EOI and return -- while the level-triggered
    // IRQ3 immediately re-asserts, so the byte is never collected and the CPU
    // storms. Causes, highest first: RDA (0x04) then THRE (0x02), 0x01 = none.
    reg  thre_pend;
    wire irq_rda  = uart_ier[0] & ld_rx_valid;
    wire irq_thre = uart_ier[1] & thre_pend;
    wire [7:0] uart_iir = irq_rda  ? 8'h04 :
                          irq_thre ? 8'h02 : 8'h01;
    wire       iir_rd   = req & req_ack & is_iord & in_com2 & (io_a[2:0] == 3'd2);

    // THRE is cleared by reading IIR or by writing THR; the transmitter here is
    // never busy, so THR empties again the moment a byte is handed over.
    always @(posedge core_clk) begin
        if (!reset_n) thre_pend <= 1'b0;
        else begin
            if (com2_wr && (io_a[2:0] == 3'd0) && !dlab) thre_pend <= 1'b1;
            else if (com2_wr && (io_a[2:0] == 3'd1) && !dlab && req_wdata[1] && !uart_ier[1])
                thre_pend <= 1'b1;                       // IER bit 1 just enabled
            else if (iir_rd && !irq_rda && irq_thre) thre_pend <= 1'b0;
        end
    end

    // A write to 0x2F8 transmits only while DLAB is clear; with DLAB set the
    // same address is the baud divisor latch, and F3857 programs it there.
    assign ld_tx_stb  = com2_wr & (io_a[2:0] == 3'd0) & ~dlab;

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
    assign ld_rx_pop  = req & is_iord & in_com2 & (io_a[2:0] == 3'd0) & req_ack & ~dlab;

    //--------------------------------------------------- PC speaker ----------
    // DL2's boot status beeps are a stock PC beeper, and they are not decoration:
    // POST plays a ~84 ms / ~25 ms tic-toc heartbeat, attract plays a warble, so
    // an audible boot IS a progress indicator. Daphne drives its
    // SOUNDCHIP_PC_BEEPER from these same three ports (sound/pc_beeper.cpp
    // beeper_ctrl_data), and names the samples dl2_tic / dl2_toc / dl2_warble.
    //
    // MAME is no reference here: dlair2.cpp attaches SPEAKER with no sound
    // device, so it emulates none of this.
    //
    //   0x43 <- 0xB6   channel 2, LSB then MSB, mode 3 square wave
    //   0x42 <- lo, hi 16-bit divisor; tone = 1193182 / divisor
    //   0x61 bits 0,1  both high gates the speaker
    localparam [31:0] PIT_HZ  = 32'd1193182;
    localparam [31:0] PIT_DIV = CLK_HZ / PIT_HZ;   // 67 at 80 MHz, 0.07% high

    reg  [15:0] pit_pre;
    wire        pit_tick = (pit_pre == PIT_DIV[15:0] - 16'd1);

    reg  [15:0] pit2_div, pit2_cnt;
    reg         pit2_hi;        // next 0x42 write is the MSB
    reg         pit2_out;
    reg   [3:0] port61;
    reg   [4:0] rfsh_cnt;
    reg         rfsh;
    wire        spk_gate = &port61[1:0];

    // A zero divisor means 65536 on a real 8253; half of it is the toggle count.
    wire [15:0] pit2_half = (pit2_div == 16'd0) ? 16'h8000 : {1'b0, pit2_div[15:1]};

    wire pit_wr = req & req_ack & is_iowr & in_pit;
    wire spk_wr = req & req_ack & is_iowr & in_spk;

    always @(posedge core_clk) begin
        if (!reset_n) begin
            pit_pre <= 16'd0; pit2_div <= 16'd0; pit2_cnt <= 16'd0;
            pit2_hi <= 1'b0; pit2_out <= 1'b0; port61 <= 4'd0;
            rfsh_cnt <= 5'd0; rfsh <= 1'b0;
        end else begin
            pit_pre <= pit_tick ? 16'd0 : pit_pre + 16'd1;

            if (pit_tick) begin
                // Refresh toggles at PIT_HZ/18 on a real PC; BIOS timing loops
                // poll it, so a constant here can wedge one.
                if (rfsh_cnt == 5'd17) begin rfsh_cnt <= 5'd0; rfsh <= ~rfsh; end
                else rfsh_cnt <= rfsh_cnt + 5'd1;

                if (pit2_cnt <= 16'd1) begin
                    pit2_cnt <= pit2_half;
                    pit2_out <= ~pit2_out;
                end else pit2_cnt <= pit2_cnt - 16'd1;
            end

            if (pit_wr) begin
                case (io_a[1:0])
                    2'd2: begin                       // 0x42, channel 2 divisor
                        if (!pit2_hi) begin pit2_div[7:0]  <= req_wdata; pit2_hi <= 1'b1; end
                        else begin
                            pit2_div[15:8] <= req_wdata; pit2_hi <= 1'b0;
                            pit2_cnt <= 16'd1;        // reload on the next tick
                        end
                    end
                    2'd3: if (req_wdata == 8'hB6) pit2_hi <= 1'b0;   // expect LSB next
                    default: ;                        // ch0/ch1: timer and refresh
                endcase
            end

            if (spk_wr) port61 <= req_wdata[3:0];
        end
    end

    // ---- the beep is an AY tone, not a raw square wave ----------------------
    // DL2's beeps are also its in-game event beeps, so they need to sound like
    // DL/SA's and share their OSD "Beep Volume" control. That control lives at
    // the top level and acts on audio_l/audio_r, which this drives -- but it
    // expects the AY's DC convention (silence = -12288, see the ay_l_ac chain in
    // Arcade-LaserdiscGames.sv). A square wave centred on zero makes silence a
    // DC offset at anything above Normal.
    //
    // A second jt49 here rather than sharing DL's: that one lives inside
    // DragonsLair_CPU.sv, which is held in reset under DL2, so sharing it would
    // mean restructuring the sound path of a HW-confirmed working game.
    //
    // Tone period from the PIT divisor. jt49 at 2 MHz with sel=1 was MEASURED at
    // f = 125000/TP (TP=100 -> 1250.0 Hz), and the PIT tone is 1193182/divisor,
    // so TP = divisor * 125000/1193182 = divisor * 6866 >> 16 (0.004% error).
    reg  [5:0] ay_cdiv;
    wire       cen_2m = (ay_cdiv == 6'd0);

    wire [28:0] ay_tp_mul = pit2_div * 13'd6866;
    wire [12:0] ay_tp_q   = ay_tp_mul[28:16];
    wire [11:0] ay_tp     = (ay_tp_q == 13'd0)    ? 12'd1    :
                            (ay_tp_q >  13'd4095) ? 12'd4095 : ay_tp_q[11:0];

    reg  [15:0] ay_last_div;
    reg         ay_last_gate;
    reg   [3:0] ay_seq, ay_addr;
    reg   [7:0] ay_din;
    reg         ay_cs_n, ay_wr_n;

    // jt49 latches on the RISING edge of (!cs_n && !wr_n), so each register write
    // needs an idle cycle between it and the next -- hence the odd/even sequence.
    always @(posedge core_clk) begin
        if (!reset_n) begin
            ay_cdiv <= 6'd0; ay_seq <= 4'd0; ay_addr <= 4'd0; ay_din <= 8'd0;
            ay_cs_n <= 1'b1; ay_wr_n <= 1'b1;
            ay_last_div <= 16'd0; ay_last_gate <= 1'b0;
        end else begin
            ay_cdiv <= (ay_cdiv == 6'd39) ? 6'd0 : ay_cdiv + 6'd1;
            ay_cs_n <= 1'b1; ay_wr_n <= 1'b1;
            if (ay_seq == 4'd0) begin
                if (pit2_div != ay_last_div || spk_gate != ay_last_gate) begin
                    ay_last_div  <= pit2_div;
                    ay_last_gate <= spk_gate;
                    ay_seq       <= 4'd1;
                end
            end else begin
                case (ay_seq)
                    4'd1: begin ay_addr <= 4'd0; ay_din <= ay_tp[7:0];
                                ay_cs_n <= 1'b0; ay_wr_n <= 1'b0; end
                    4'd3: begin ay_addr <= 4'd1; ay_din <= {4'd0, ay_tp[11:8]};
                                ay_cs_n <= 1'b0; ay_wr_n <= 1'b0; end
                    4'd5: begin ay_addr <= 4'd7; ay_din <= 8'h3E;   // tone A only
                                ay_cs_n <= 1'b0; ay_wr_n <= 1'b0; end
                    4'd7: begin ay_addr <= 4'd8;                    // channel A level
                                ay_din <= ay_last_gate ? 8'h0F : 8'h00;
                                ay_cs_n <= 1'b0; ay_wr_n <= 1'b0; end
                    default: ;
                endcase
                ay_seq <= (ay_seq == 4'd8) ? 4'd0 : ay_seq + 4'd1;
            end
        end
    end

    wire [7:0] ay_A, ay_B, ay_C;
    jt49 #(.COMP(3'b010)) ay_beep (          // same COMP as DL's ay_chip
        .rst_n(reset_n), .clk(core_clk), .clk_en(cen_2m), .sel(1'b1),
        .addr(ay_addr), .cs_n(ay_cs_n), .wr_n(ay_wr_n), .din(ay_din),
        .dout(), .sound(), .A(ay_A), .B(ay_B), .C(ay_C), .sample(),
        .IOA_in(8'd0), .IOA_out(), .IOB_in(8'd0), .IOB_out()
    );

    // Identical mix and bias to DragonsLair_CPU.sv so both games present the
    // same thing to the shared volume chain.
    wire [9:0] ay_sum = {2'b00, ay_A} + {2'b00, ay_B} + {2'b00, ay_C};
    assign audio = {1'b0, ay_sum, 5'd0} - 16'sd12288;

    //--------------------------------------------------- 8259 + timer --------
    // MAME models two interrupts: a 60 Hz periodic one whose vector_r returns
    // 0x20/4 = 8, and a serial one at 0x2c/4 = 11. Those are IRQ0 and IRQ3 on a
    // standard PC 8259 with a vector base of 8, which is exactly what the ROM
    // programs -- F35DD unmasks IRQ3 (COM2) and F35D6 sets IER bit 0, so the
    // player's replies arrive by interrupt rather than by polling.
    //
    // The vector base is taken from the ICW2 the ROM writes, not hardcoded, so
    // a wrong assumption here shows up as a wrong vector instead of silently
    // working. POST writes ICW1 to 0x020 then ICW2/3/4 to 0x021, so plain OCW1
    // mask writes have to be told apart from the init sequence.
    localparam [31:0] TICK_60HZ = CLK_HZ / 32'd60;

    reg  [20:0] tick_cnt;
    reg         irq0_pend;
    reg   [7:0] pic_imr, pic_isr, pic_icw2;
    reg   [1:0] pic_icw_state;          // 0 OCW1, 1 want ICW2, 2 want ICW3, 3 want ICW4
    reg         pic_single, pic_need4;
    reg         inta_phase;             // the 8088 runs two INTA cycles per interrupt
    reg   [7:0] inta_vec;

    wire irq0 = irq0_pend;                          // 60 Hz timer
    wire irq3 = ~uart_iir[0];                       // COM2: any UART cause pending
    wire [7:0] irq_pending = {4'b0000, irq3, 2'b00, irq0};
    wire [7:0] irq_active  = irq_pending & ~pic_imr;
    wire [2:0] irq_num = irq_active[0] ? 3'd0 : irq_active[1] ? 3'd1 :
                         irq_active[2] ? 3'd2 : irq_active[3] ? 3'd3 :
                         irq_active[4] ? 3'd4 : irq_active[5] ? 3'd5 :
                         irq_active[6] ? 3'd6 : 3'd7;

    // One interrupt at a time: nothing new is offered while a level is still in
    // service, and nothing at all until the ICW sequence has finished.
    assign cpu_intr = (|irq_active) & ~(|pic_isr) & (pic_icw_state == 2'd0);

    wire [7:0] inta_vector = inta_phase ? inta_vec : {pic_icw2[7:3], irq_num};
    wire       pic_wr   = req & req_ack & is_iowr & in_pic;
    wire       inta_ack = req & req_ack & is_inta;

    always @(posedge core_clk) begin
        if (!reset_n) begin
            tick_cnt <= 21'd0; irq0_pend <= 1'b0;
            pic_imr <= 8'hFF; pic_isr <= 8'h00; pic_icw2 <= 8'h08;
            pic_icw_state <= 2'd0; pic_single <= 1'b0; pic_need4 <= 1'b0;
            inta_phase <= 1'b0; inta_vec <= 8'h08;
        end else begin
            if (tick_cnt == TICK_60HZ[20:0] - 21'd1) begin
                tick_cnt  <= 21'd0;
                irq0_pend <= 1'b1;
            end else tick_cnt <= tick_cnt + 21'd1;

            if (pic_wr) begin
                if (!io_a[0]) begin
                    if (req_wdata[4]) begin              // ICW1
                        pic_icw_state <= 2'd1;
                        pic_single    <= req_wdata[1];
                        pic_need4     <= req_wdata[0];
                        pic_imr       <= 8'hFF;
                        pic_isr       <= 8'h00;
                    end else if (req_wdata[5]) begin     // OCW2 non-specific EOI
                        pic_isr <= pic_isr & (pic_isr - 8'd1);
                    end
                end else begin
                    case (pic_icw_state)
                        2'd1: begin
                            pic_icw2      <= req_wdata;
                            pic_icw_state <= pic_single ? (pic_need4 ? 2'd3 : 2'd0) : 2'd2;
                        end
                        2'd2:    pic_icw_state <= pic_need4 ? 2'd3 : 2'd0;
                        2'd3:    pic_icw_state <= 2'd0;
                        default: pic_imr <= req_wdata;   // OCW1
                    endcase
                end
            end

            // Latch on the first INTA of the pair; the second re-reads the same
            // vector, so a tick landing between them cannot change it.
            if (inta_ack) begin
                if (!inta_phase) begin
                    inta_phase <= 1'b1;
                    inta_vec   <= {pic_icw2[7:3], irq_num};
                    pic_isr    <= pic_isr | (8'd1 << irq_num);
                    if (irq_num == 3'd0) irq0_pend <= 1'b0;
                end else inta_phase <= 1'b0;
            end
        end
    end

    //--------------------------------------------------- coinco -------------
    // DL2 does not read the coin buttons as levels. Daphne lair2.cpp leaves the
    // direct `banks[1] |= 0x04` COMMENTED OUT and only counts the insertion; the
    // coin bits are maintained by the game's own write handshake on 0x202:
    // bit 6 SET hides the status and CONSUMES one pending coin per slot, bit 6
    // clear shows a bit for every slot still holding one. Wiring the button
    // straight to the port bit never completes that handshake, so coins are
    // dropped -- which is why coin-up does nothing.
    reg  [2:0] coin_pend1, coin_pend2;
    reg  [1:0] coin_q, coin_vis;
    wire [1:0] coin_in      = {cab[3], cab[2]};        // coin2, coin1
    wire       coin1_edge   = coin_in[0] & ~coin_q[0];
    wire       coin2_edge   = coin_in[1] & ~coin_q[1];
    wire       coin_consume = eep_wr_stb & req_wdata[6];

    always @(posedge core_clk) begin
        if (!reset_n) begin
            coin_pend1 <= 3'd0; coin_pend2 <= 3'd0;
            coin_q <= 2'd0; coin_vis <= 2'd0;
        end else begin
            coin_q <= coin_in;

            case ({coin1_edge, coin_consume & (coin_pend1 != 3'd0)})
                2'b10:   if (coin_pend1 != 3'd7) coin_pend1 <= coin_pend1 + 3'd1;
                2'b01:   coin_pend1 <= coin_pend1 - 3'd1;
                default: ;
            endcase
            case ({coin2_edge, coin_consume & (coin_pend2 != 3'd0)})
                2'b10:   if (coin_pend2 != 3'd7) coin_pend2 <= coin_pend2 + 3'd1;
                2'b01:   coin_pend2 <= coin_pend2 - 3'd1;
                default: ;
            endcase

            if (eep_wr_stb) begin
                if (req_wdata[6]) coin_vis <= 2'b00;
                else coin_vis <= {(coin_pend2 != 3'd0), (coin_pend1 != 3'd0)};
            end
        end
    end

    reg [7:0] io_rdata;
    always @(*) begin
        if (in_com2) begin
            case (io_a[2:0])
                3'd0:    io_rdata = dlab ? uart_dll : ld_rx_byte;   // RBR / DLL
                3'd1:    io_rdata = dlab ? uart_dlm : uart_ier;     // IER / DLM
                3'd2:    io_rdata = uart_iir;
                3'd3:    io_rdata = uart_lcr;
                3'd4:    io_rdata = uart_mcr;
                // LSR: TEMT and THRE both set -- the transmit path is never
                // busy here, and F37CC polls THRE (bit 5), not TEMT.
                3'd5:    io_rdata = {1'b0, 2'b11, 4'b0000, ld_rx_valid};
                // MSR: DCD, DSR and CTS asserted. F37A7 tests CTS (bit 4)
                // before every byte, and F3938 tests DCD (bit 7) as a
                // player-present check. Delta bits read 0.
                3'd6:    io_rdata = 8'hB0;
                default: io_rdata = uart_scr;
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
                2'd1:    io_rdata = ~{service, p1[4],// b7 SERVICE, b6 SWORD
                                      cab[1], cab[0],// b5 START2, b4 START1
                                      p1[3], p1[2],  // b3 RIGHT, b2 LEFT
                                      p1[1], p1[0]}; // b1 DOWN,  b0 UP
                2'd2:    io_rdata = {2'b00,          // b7:6 unknown
                                     2'b00,          // b5:4 coin 4, coin 3 (unwired)
                                     coin_vis[1],    // b3 coin 2, from the coinco
                                     coin_vis[0],    // b2 coin 1
                                     1'b0,           // b1 unknown
                                     eep_do};        // b0 EEPROM DO / not-busy
                default: io_rdata = 8'h00;
            endcase
        end
        else if (in_pic)     io_rdata = io_a[0] ? pic_imr : 8'h00;
        // 0x61 is read-modify-written by the ROM, so it must read back. Bit 5 is
        // the channel-2 output and bit 4 the refresh toggle, as on a real PC.
        else if (in_spk)     io_rdata = {2'b00, pit2_out, rfsh, port61};
        else if (in_pit)     io_rdata = 8'h00;
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
                end else if (is_inta) begin
                    req_rdata <= inta_vector;
                    req_ack   <= 1'b1;
                end else begin
                    req_rdata <= 8'hFF;                    // halt: nothing to fetch
                    req_ack   <= 1'b1;
                end
            end
        end
    end
endmodule
