//============================================================================
// Mach3.sv — M.A.C.H. 3 (Mylstar 1983) main board.
//
// Gottlieb/Mylstar rev-2 video hardware + Pioneer PR-8210 laserdisc.
// MAME gottlieb/gottlieb.cpp `g2laser`; schematics in
// Useful Information/schematics/mach3_s.pdf (Logic Board A1, Interface A2).
//
//  CPU     8088 @ XTAL(15MHz)/3 = 5.0 MHz, flat 64K (map.global_mask(0xffff)).
//  VIDEO   20MHz/4 dot clock, 318x256 counts, 256x240 active, 16-colour palette.
//  IRQ     VBLANK -> NMI. No interrupt controller.
//  SOUND   rev-2 board: 2x M6502 + 2x AY8913 + SP0250 + AD7528 (not yet fitted).
//
//  MEMORY MAP
//    0000-0FFF  RAM, battery-backed (nvram, default all-1)
//    1000-2FFF  RAM
//    3000-30FF  sprite RAM        (mirror 0700)
//    3800-3BFF  video RAM         (mirror 0400)
//    4000-4FFF  character RAM
//    5000-501F  palette           (mirror 07E0)
//    5800-5807  I/O               (mirror 07F8)
//    6000-FFFF  ROM (40K)
//
//  The laserdisc link is NOT a byte bus. A write to 5805 latches a byte and the
//  board clocks 12 bits out to the player as pulse INTERVALS: 998us = 0,
//  1996us = 1 (555 at 40083Hz /10, then /4 or /8 — gottlieb.cpp:876). That is
//  the same wire ldp_pr8210 already decodes for Cliff Hanger, but Cliff
//  bit-bangs its blips at roughly half these intervals, so the front-end's
//  BIT_ONE_US threshold must be selected per board, not shared.
//============================================================================
module Mach3
#(
    parameter [31:0] CLK_HZ = 32'd80_000_000
)
(
    input                core_clk,        // CLK_CORE, 80 MHz
    input                reset_n,

    // ---- controls (active HIGH here; inverted at the port) ----
    input          [7:0] in1,
    input          [7:0] in4,
    input          [7:0] dsw,
    input          [7:0] track_h,         // trackball H counter
    input          [7:0] track_v,         // trackball V counter

    // ---- ROM download, ioctl index 0 ----
    input         [24:0] ioctl_addr,
    input          [7:0] ioctl_data,
    input                ioctl_wr,
    input          [7:0] ioctl_index,

    // ---- shared program ROM ----
    output        [15:0] rom_addr,
    input          [7:0] rom_data,

    // ---- laserdisc ----
    output               ld_blip,         // 1-cyc pulse per bit boundary -> ldp_pr8210
    input         [16:0] ld_frame,        // transport curr_frame
    input                ld_video_active, // disc producing a picture
    output               ld_overlay_en,   // genlock: 1 = show the disc picture
    output               bg_priority,     // $5803 b0: 0 = tiles behind sprites
    output               spritebank,      // $5803 b1
    output               video_en,        // $5803 b2: 0 = game layer black

    // ---- target data (m3target.bin, served 1KB per 53 frames) ----
    output        [19:0] tgt_addr,
    input          [7:0] tgt_data,
    output               tgt_rd,
    input                tgt_ready,

    // ---- sound latch -> rev-2 board ----
    output         [7:0] snd_data,
    output               snd_stb,

    // ---- video read ports, driven by the renderer ----
    input         [11:0] vram_rd_a,
    output         [7:0] vram_rd_d,
    input         [11:0] chram_rd_a,
    output         [7:0] chram_rd_d,
    input          [7:0] spram_rd_a,
    output         [7:0] spram_rd_d,
    output               pal_we,          // palette is WRITE-ONLY to the CPU
    output         [4:0] pal_wa,
    output         [7:0] pal_wd,
    input                vblank,          // from the renderer, rising edge = NMI

    // ---- telemetry ----
    output        [19:0] dbg_addr,
    output         [2:0] dbg_type,
    output               dbg_halt
);
    //--------------------------------------------------- 8088 pin clock ------
    // 5.0 MHz = core_clk / 16, 50% duty (8 high, 8 low).
    reg [2:0] clkdiv;
    reg       cpu_clk;
    always @(posedge core_clk) begin
        if (!reset_n) begin clkdiv <= 3'd0; cpu_clk <= 1'b0; end
        else if (clkdiv == 3'd7) begin clkdiv <= 3'd0; cpu_clk <= ~cpu_clk; end
        else clkdiv <= clkdiv + 3'd1;
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

    // VBLANK is the only interrupt source on this board and it drives NMI, not
    // INTR. DL2 ties this input low, so it is exercised here for the first time.
    reg  vblank_q;
    wire nmi_pulse = vblank & ~vblank_q;
    always @(posedge core_clk) vblank_q <= vblank;

    biu_max BIU (
        .CORE_CLK_INT(core_clk),
        .CLK(cpu_clk), .RESET_INT(~reset_n), .READY_IN(ready_in),
        .NMI(nmi_pulse), .INTR(1'b0),
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

    // Shared with the DL2 board: this decodes the 8088 S2-S0 status lines and is
    // board-independent.
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

    // Flat 64K: the board decodes A0-A15 only.
    wire [15:0] a = req_addr[15:0];

    wire in_nvram = (a <  16'h1000);
    wire in_ram   = (a >= 16'h1000) && (a < 16'h3000);
    wire in_spr   = (a >= 16'h3000) && (a < 16'h3800);   // 3000-30FF mirror 0700
    wire in_vram  = (a >= 16'h3800) && (a < 16'h4000);   // 3800-3BFF mirror 0400
    wire in_chram = (a >= 16'h4000) && (a < 16'h5000);
    wire in_pal   = (a >= 16'h5000) && (a < 16'h5800);   // 5000-501F mirror 07E0
    wire in_io    = (a >= 16'h5800) && (a < 16'h6000);   // 5800-5807 mirror 07F8
    wire in_rom   = (a >= 16'h6000);

    wire [2:0] io_a = a[2:0];

    //--------------------------------------------------- ROM / RAM -----------
    // ioctl index 0 packing, mirrored by the MRA:
    //   00000-09FFF  maincpu 40K   -> CPU 6000-FFFF
    //   0A000-0AFFF  sound dcpu 4K
    //   0B000-0BFFF  sound ycpu 4K
    //   0C000-0DFFF  bg tiles 8K
    //   0E000-15FFF  sprites 32K

    wire [7:0] rom_q, nvram_q, ram_q, spr_q, vram_q, chram_q;

    // Program ROM lives at TOP LEVEL and is shared by every board: only one
    // board runs at a time, so private 64K copies cost 192 M10K for nothing.
    // Mach 3: 40K at CPU 6000-FFFF, loaded from ioctl 0.
    assign rom_addr = a - 16'h6000;
    assign rom_q = rom_data;
    dpram_dc #(.widthad_a(12)) u_nvram (
        .clock_a(core_clk), .address_a(a[11:0]), .q_a(nvram_q),
        .wren_a(req & req_ack & is_memwr & in_nvram), .data_a(req_wdata),
        .clock_b(core_clk), .address_b(12'd0), .data_b(8'd0), .wren_b(1'b0), .q_b()
    );
    wire [12:0] ram_a = a[12:0] - 13'h1000;   // 1000-2FFF -> 0000-1FFF
    dpram_dc #(.widthad_a(13)) u_ram (
        .clock_a(core_clk), .address_a(ram_a), .q_a(ram_q),
        .wren_a(req & req_ack & is_memwr & in_ram), .data_a(req_wdata),
        .clock_b(core_clk), .address_b(13'd0), .data_b(8'd0), .wren_b(1'b0), .q_b()
    );
    dpram_dc #(.widthad_a(8)) u_spram (
        .clock_a(core_clk), .address_a(a[7:0]), .q_a(spr_q),
        .wren_a(req & req_ack & is_memwr & in_spr), .data_a(req_wdata),
        .clock_b(core_clk), .address_b(spram_rd_a), .data_b(8'd0),
        .wren_b(1'b0), .q_b(spram_rd_d)
    );
    dpram_dc #(.widthad_a(10)) u_vram (
        .clock_a(core_clk), .address_a(a[9:0]), .q_a(vram_q),
        .wren_a(req & req_ack & is_memwr & in_vram), .data_a(req_wdata),
        .clock_b(core_clk), .address_b(vram_rd_a[9:0]), .data_b(8'd0),
        .wren_b(1'b0), .q_b(vram_rd_d)
    );
    dpram_dc #(.widthad_a(12)) u_chram (
        .clock_a(core_clk), .address_a(a[11:0]), .q_a(chram_q),
        .wren_a(req & req_ack & is_memwr & in_chram), .data_a(req_wdata),
        .clock_b(core_clk), .address_b(chram_rd_a), .data_b(8'd0),
        .wren_b(1'b0), .q_b(chram_rd_d)
    );
    assign pal_we = req & req_ack & is_memwr & in_pal;
    assign pal_wa = a[4:0];
    assign pal_wd = req_wdata;

    //--------------------------------------------------- watchdog ------------
    // Cleared by a write to 5800; fires after 16 vblanks without one.
    reg [4:0] wd_cnt;
    wire      wd_pet = req & req_ack & is_memwr & in_io & (io_a == 3'd0);
    wire      wd_rst = (wd_cnt >= 5'd16);
    always @(posedge core_clk) begin
        if (!reset_n)     wd_cnt <= 5'd0;
        else if (wd_pet)  wd_cnt <= 5'd0;
        else if (nmi_pulse && !wd_rst) wd_cnt <= wd_cnt + 5'd1;
    end

    //--------------------------------------------------- sound latch ---------
    reg [7:0] snd_latch;
    reg       snd_stb_r;
    always @(posedge core_clk) begin
        snd_stb_r <= 1'b0;
        if (req & req_ack & is_memwr & in_io & (io_a == 3'd2)) begin
            snd_latch <= req_wdata;
            snd_stb_r <= 1'b1;
        end
    end
    assign snd_data = snd_latch;
    assign snd_stb  = snd_stb_r;

    //--------------------------------------------------- LD bit serialiser ---
    // 12 bits, MSB first. The line asserts for ~249us and the INTERVAL to the
    // next assert carries the bit: 998us = 0, 1996us = 1. ldp_pr8210 recovers
    // the bit from that interval, so only the assert edge is published as blip.
    localparam [31:0] US       = CLK_HZ / 32'd1_000_000;
    localparam [31:0] T_ZERO   = US * 32'd998;
    localparam [31:0] T_ONE    = US * 32'd1996;

    reg [11:0] ld_sr;
    reg  [3:0] ld_bits;
    reg [31:0] ld_tmr;
    reg        ld_blip_r;
    reg        ld_tx_ready;                       // status bit 4

    wire ld_cmd_wr = req & req_ack & is_memwr & in_io & (io_a == 3'd5);

    always @(posedge core_clk) begin
        ld_blip_r <= 1'b0;
        if (!reset_n) begin
            ld_bits <= 4'd0; ld_tmr <= 32'd0; ld_sr <= 12'd0; ld_tx_ready <= 1'b1;
        end else if (ld_cmd_wr) begin
            // A write latches the byte into the top of a 12-bit frame and clears
            // the ready bit until the last one is clocked out.
            ld_sr       <= {req_wdata, 4'd0};
            ld_bits     <= 4'd12;
            ld_tmr      <= T_ZERO;                // first edge one bit-time later
            ld_tx_ready <= 1'b0;
        end else if (ld_bits != 4'd0) begin
            if (ld_tmr != 32'd0) ld_tmr <= ld_tmr - 32'd1;
            else begin
                ld_blip_r <= 1'b1;
                ld_tmr    <= ld_sr[11] ? T_ONE : T_ZERO;
                ld_sr     <= {ld_sr[10:0], 1'b0};
                ld_bits   <= ld_bits - 4'd1;
                if (ld_bits == 4'd1) ld_tx_ready <= 1'b1;
            end
        end
    end
    assign ld_blip = ld_blip_r;

    //--------------------------------------------------- LD readback ---------
    // 5805/5806 return the low and middle BCD digit pairs of the disc frame;
    // 5807 returns the top digit plus status when select=1, else target data.
    reg  ld_select;
    reg [3:0] vctrl;
    always @(posedge core_clk) begin
        if (!reset_n) begin ld_select <= 1'b0; vctrl <= 4'b1100; end
        else begin
            if (req & req_ack & is_memwr & in_io & (io_a == 3'd6))
                ld_select <= req_wdata[0];
            if (req & req_ack & is_memwr & in_io & (io_a == 3'd3))
                vctrl <= req_wdata[3:0];
        end
    end
    assign bg_priority   = vctrl[0];
    assign spritebank    = vctrl[1];
    assign video_en      = vctrl[2];
    assign ld_overlay_en = vctrl[3];   // genlock: pen 0 transparent, disc shows through

    // Binary frame -> 5 BCD digits.  SEQUENTIAL double-dabble, the same shape as
    // ldp_ldv1000.sv: unrolling 17 iterations into one combinational path puts
    // ~17 levels of conditional add-3 between the frame counter and the CPU read
    // mux.  The frame changes at most 30 times a second, so a 17-clock conversion
    // that free-runs is invisible.
    reg [16:0] dd_bin;
    reg [19:0] dd_bcd;
    reg  [4:0] dd_cnt;
    reg [19:0] fbcd;

    wire [3:0] q0 = (dd_bcd[3:0]   >= 4'd5) ? dd_bcd[3:0]   + 4'd3 : dd_bcd[3:0];
    wire [3:0] q1 = (dd_bcd[7:4]   >= 4'd5) ? dd_bcd[7:4]   + 4'd3 : dd_bcd[7:4];
    wire [3:0] q2 = (dd_bcd[11:8]  >= 4'd5) ? dd_bcd[11:8]  + 4'd3 : dd_bcd[11:8];
    wire [3:0] q3 = (dd_bcd[15:12] >= 4'd5) ? dd_bcd[15:12] + 4'd3 : dd_bcd[15:12];
    wire [3:0] q4 = (dd_bcd[19:16] >= 4'd5) ? dd_bcd[19:16] + 4'd3 : dd_bcd[19:16];
    wire [19:0] dd_next = {q4[2:0], q3, q2, q1, q0, dd_bin[16]};

    always @(posedge core_clk) begin
        if (!reset_n) begin
            dd_bin <= 17'd0; dd_bcd <= 20'd0; dd_cnt <= 5'd0; fbcd <= 20'd0;
        end else if (dd_cnt == 5'd0) begin
            dd_bin <= ld_frame; dd_bcd <= 20'd0; dd_cnt <= 5'd17;
        end else begin
            dd_bcd <= dd_next;
            dd_bin <= {dd_bin[15:0], 1'b0};
            dd_cnt <= dd_cnt - 5'd1;
            if (dd_cnt == 5'd1) fbcd <= dd_next;
        end
    end

    wire [7:0] ld_status = {2'b00,                // audio clock lost / break
                            ld_video_active,      // b5 disc ready
                            ld_tx_ready,          // b4 ready for a new command
                            tgt_ready,            // b3 target buffer ready
                            fbcd[18:16]};         // b0-2 frame MSN

    //--------------------------------------------------- I/O read ------------
    reg [7:0] io_rdata;
    always @(*) begin
        case (io_a)
            // MAME reads these ports straight through; the top level assembles
            // them with the right polarity (SERVICE b0 and TILT b5 of IN1 are
            // active LOW, everything else active HIGH).  IN2/IN3 are the
            // trackball, unused by all three games, and idle at FF.
            3'd0:    io_rdata = dsw;
            3'd1:    io_rdata = in1;
            3'd2:    io_rdata = track_h;
            3'd3:    io_rdata = track_v;
            3'd4:    io_rdata = in4;
            3'd5:    io_rdata = fbcd[7:0];
            3'd6:    io_rdata = fbcd[15:8];
            default: io_rdata = ld_select ? ld_status : tgt_data;
        endcase
    end
    assign tgt_addr = 20'd0;                      // driven by the target server
    assign tgt_rd   = req & req_ack & is_memrd & in_io & (io_a == 3'd7) & ~ld_select;

    //--------------------------------------------------- response ------------
    // Every memory here is dpram_dc, which REGISTERS its output: the address
    // presented this cycle is only valid on the next one. Acking immediately
    // returns the previous byte and the CPU executes garbage.
    reg mem_wait;
    always @(posedge core_clk) begin
        req_ack <= 1'b0;
        if (!reset_n) begin
            req_rdata <= 8'hFF; mem_wait <= 1'b0;
        end else begin
            if (!req) mem_wait <= 1'b0;
            if (req && !req_ack) begin
                if (in_io && is_memrd) begin
                    req_rdata <= io_rdata;
                    req_ack   <= 1'b1;
                end else if (is_memwr || in_io) begin
                    req_ack   <= 1'b1;            // writes land in the same cycle
                end else if (is_memrd) begin
                    if (!mem_wait) mem_wait <= 1'b1;
                    else begin
                        req_rdata <= in_rom   ? rom_q   :
                                     in_nvram ? nvram_q :
                                     in_ram   ? ram_q   :
                                     in_spr   ? spr_q   :
                                     in_vram  ? vram_q  :
                                     in_chram ? chram_q :
                                     8'hFF;
                        req_ack   <= 1'b1;
                    end
                end else begin
                    req_rdata <= 8'hFF;
                    req_ack   <= 1'b1;
                end
            end
        end
    end
endmodule
