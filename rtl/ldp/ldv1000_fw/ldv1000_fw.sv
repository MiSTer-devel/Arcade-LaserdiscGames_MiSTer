//============================================================================
// ldv1000_fw.sv -- Pioneer LD-V1000 running its REAL firmware (z03_1001_vyw-053_v1-0).
//
// Port of MAME src/devices/machine/ldv1000.cpp.  The player's Z80 is NOT in
// here: this module exports a chip-pool Z80 port (z80_i / z80_o, T80s Mode 0,
// single ce) and the dispatcher owns the T80 in a dedicated "LD player CPU"
// slot.  Inside: 8K firmware ROM (ioctl-loaded), 2K RAM, Z80 CTC, two 8255s,
// the decoder/display port, the controller latch and the mechanics model.
//
// Game side is the same as ldp_ldv1000.sv: cmd_stb/cmd_byte in, status byte +
// status/command strobes out, cmd_action/cmd_op/cmd_arg to ldp_transport.
//
// Z80 memory map (ldv1000_map)          Z80 I/O map (A7..A0, ldv1000_portmap)
//   0000-1FFF  ROM, mirror 6000           00-07 /38  decoder/display, offset A2..A0
//   8000-87FF  RAM, mirror 3800           40    /3F  read: controller latch ^ FF
//   C000-C003  PPI0, mirror 1FF0          80    /3F  write: status latch
//   C004-C007  PPI1, mirror 1FF0          C0-C3 /3C  CTC channel A1..A0
// Clock: Z80 and CTC at 5 MHz / 2 = 2.5 MHz.  CTC is the only IRQ source
// (daisy chain of one), INT_n to the CPU, vector on the bus during INTA.
//============================================================================
module ldv1000_fw
#(
    parameter [31:0] CLK_HZ     = 32'd80_000_000,
    parameter  [7:0] ROM_INDEX  = 8'd0,           // ioctl index carrying the firmware (TBD)
    parameter [24:0] ROM_BASE   = 25'h0,          // byte offset of the firmware in that index (TBD)
    parameter [16:0] LAST_FRAME = 17'd54000,      // used when disc_last_frame == 0
    parameter  [1:0] PIC_FIELD  = 2'd0,           // ldv_mech: field carrying the picture code
    parameter  [7:0] FETCH_LINES = 8'd20,         // ldv_mech: track update after VSYNC (MAME: 33)
    parameter  [7:0] VBI_LINES   = 8'd26          // ldv_mech: VBI ready after VSYNC (MAME: 39 -- search never completes)
)
(
    input             clk,
    input             reset_n,
    input             pause,
    input             sel,              // this front-end drives the transport

    // ---- game side (same as ldp_ldv1000) ----
    input             cmd_stb,
    input      [7:0]  cmd_byte,
    output            cmd_action,
    output     [3:0]  cmd_op,
    output     [16:0] cmd_arg,
    /* verilator lint_off UNUSED */
    input             search_done,      // interface parity with ldp_ldv1000; the
    input             autostop_done,    // firmware derives these itself
    input      [21:0] field_phase,
    input             status_rd,
    /* verilator lint_on UNUSED */
    input      [16:0] curr_frame,       // transport frame (what the picture shows)
    output     [7:0]  status,
    output            status_strobe,    // ~PPI1 PC5: idle 1, asserts 0 (as ldp_ldv1000)
    output            command_strobe,   // ~PPI1 PC4: idle 1, asserts 0 (as ldp_ldv1000)
    output     [19:0] dbg_digits,       // BCD picture number under the head

    // ---- extra transport inputs ----
    input      [2:0]  t_mode,           // ldp_transport mode
    input             field_tick,       // ldp_transport frame_tick (59.94 Hz field)
    input      [16:0] disc_last_frame,  // 0 = use LAST_FRAME

    // ---- firmware download ----
    input             ioctl_download,
    input      [7:0]  ioctl_index,
    input      [24:0] ioctl_addr,
    input      [7:0]  ioctl_dout,
    input             ioctl_wr,

    // ---- pooled Z80 ----
    output chip_pool_pkg::z80_i_t z80_i,
    input  chip_pool_pkg::z80_o_t z80_o,
    output            z80_rst_n,        // AND into the pooled LD CPU's RESET_n

    // ---- player outputs not yet consumed by the core ----
    output            video_squelch,
    output     [1:0]  audio_squelch,

    // ---- debug ----
    output     [16:0] dbg_track,
    output            dbg_ctl_rd,       // 1-clk: firmware read the controller latch
    output     [7:0]  dbg_ctl_val,      //        value it got
    output            dbg_disp_we,      // 1-clk: display write
    output     [7:0]  dbg_disp_sel,
    output     [7:0]  dbg_disp_dat,
    output            dbg_fieldnum,
    output     [1:0]  dbg_class,
    output            dbg_irq,
    output     [7:0]  dbg_ppi0_pa,      // multi-jump preset
    output     [7:0]  dbg_ppi0_pc,
    output     [7:0]  dbg_ppi1_pb,
    output     [7:0]  dbg_ppi1_pc,
    output     [7:0]  dbg_counter,
    output            dbg_fetch         // 1-clk: VBI fetch (track/fieldnum updated)
);
    // ------------------------------------------------------------------ clocks
    reg  [31:0] ce_acc;
    reg         ce25;
    wire        run = sel && !pause && z80_rst_n;
    always @(posedge clk) begin
        if (!reset_n) begin
            ce_acc <= 32'd0; ce25 <= 1'b0;
        end else if (ce_acc + 32'd2_500_000 >= CLK_HZ) begin
            ce_acc <= ce_acc + 32'd2_500_000 - CLK_HZ; ce25 <= 1'b1;
        end else begin
            ce_acc <= ce_acc + 32'd2_500_000; ce25 <= 1'b0;
        end
    end
    wire ce = ce25 && run;

    // ------------------------------------------------------- firmware download
    wire [25:0] rom_sub = {1'b0, ioctl_addr} - {1'b0, ROM_BASE};     // [25] = below the base
    wire [12:0] rom_off = rom_sub[12:0];
    wire        rom_dl  = ioctl_download && (ioctl_index == ROM_INDEX);
    wire        rom_we  = rom_dl && ioctl_wr && (rom_sub[25:13] == 13'd0);
    reg         rom_ok = 1'b0;          // power-up 0; NOT cleared by reset_n
    reg         rom_got = 1'b0;
    reg         rom_dl_q;
    always @(posedge clk) begin
        rom_dl_q <= rom_dl;
        if (rom_dl && !rom_dl_q) begin rom_ok <= 1'b0; rom_got <= 1'b0; end
        if (rom_we) rom_got <= 1'b1;
        if (!rom_dl && rom_dl_q && rom_got) rom_ok <= 1'b1;
    end
    assign z80_rst_n = reset_n && sel && rom_ok && !rom_dl;

    // ------------------------------------------------------------ bus decode
    wire [15:0] A    = z80_o.a;
    wire        m1   = ~z80_o.m1_n;
    wire        mreq = ~z80_o.mreq_n;
    wire        iorq = ~z80_o.iorq_n;
    wire        rd   = ~z80_o.rd_n;
    wire        wr   = ~z80_o.wr_n;
    wire        rfsh = ~z80_o.rfsh_n;

    wire mem_rd = mreq && rd && !rfsh;
    wire mem_wr = mreq && wr;
    wire io_rd  = iorq && rd && !m1;
    wire io_wr  = iorq && wr && !m1;
    wire inta_l = iorq && m1;
    wire fetch  = m1 && mreq && rd && !rfsh;

    wire cs_rom  = !A[15];
    wire cs_ram  = A[15:14] == 2'b10;
    wire cs_ppi  = (A[15:13] == 3'b110) && !A[3];
    wire cs_ppi0 = cs_ppi && !A[2];
    wire cs_ppi1 = cs_ppi &&  A[2];

    // end-of-cycle strobes: address/data captured during the cycle, acted on as it ends
    reg [15:0] ba_q;
    reg  [7:0] bd_q;
    reg        mw_q, iw_q, ir_q, ia_q, f_q;
    reg  [7:0] fop_q;
    reg        last_ed;
    wire [7:0] cpu_di;
    always @(posedge clk) begin
        if (mem_wr || io_wr || io_rd) begin ba_q <= A; bd_q <= z80_o.dout; end
        if (fetch) fop_q <= cpu_di;
        mw_q <= mem_wr; iw_q <= io_wr; ir_q <= io_rd; ia_q <= inta_l; f_q <= fetch;
    end
    wire mem_wr_end = mw_q && !mem_wr;
    wire io_wr_end  = iw_q && !io_wr;
    wire io_rd_end  = ir_q && !io_rd;
    wire inta_stb   = inta_l && !ia_q;
    wire fetch_end  = f_q && !fetch;
    wire reti_stb   = fetch_end && last_ed && (fop_q == 8'h4D);
    always @(posedge clk) begin
        if (!z80_rst_n)    last_ed <= 1'b0;
        else if (fetch_end) last_ed <= (fop_q == 8'hED);
    end

    wire bq_ppi  = (ba_q[15:13] == 3'b110) && !ba_q[3];
    wire ppi0_we = mem_wr_end && bq_ppi && !ba_q[2];
    wire ppi1_we = mem_wr_end && bq_ppi &&  ba_q[2];
    wire dec_we  = io_wr_end && (ba_q[7:6] == 2'b00);
    wire stat_we = io_wr_end && (ba_q[7:6] == 2'b10);
    wire ctc_we  = io_wr_end && (ba_q[7:6] == 2'b11);
    wire ctl_re  = io_rd_end && (ba_q[7:6] == 2'b01);
    wire dec_re  = io_rd_end && (ba_q[7:6] == 2'b00) && (ba_q[2:0] == 3'd3);

    // ------------------------------------------------------------ ROM / RAM
    wire [7:0] rom_q, ram_q, rom_qb, ram_qb;
    dpram_dc #(.widthad_a(13), .width_a(8)) u_rom (
        .clock_a(clk), .address_a(A[12:0]), .data_a(8'h00), .wren_a(1'b0), .q_a(rom_q),
        .clock_b(clk), .address_b(rom_off), .data_b(ioctl_dout), .wren_b(rom_we), .q_b(rom_qb)
    );
    dpram_dc #(.widthad_a(11), .width_a(8)) u_ram (
        .clock_a(clk), .address_a(A[10:0]), .data_a(z80_o.dout), .wren_a(mem_wr && cs_ram && z80_rst_n), .q_a(ram_q),
        .clock_b(clk), .address_b(11'd0), .data_b(8'h00), .wren_b(1'b0), .q_b(ram_qb)
    );

    // ------------------------------------------------------------ mechanics
    wire [7:0] ppi0_pa, ppi0_pb, ppi0_pc, ppi1_pa, ppi1_pb, ppi1_pc;
    wire [7:0] counter;
    wire       vsync, vbiready, at_min, at_max, trg_min, trg_max, fetch_done, frame_valid;
    wire [16:0] frame, track;
    wire       fieldnum;
    wire [19:0] vbi_bcd;
    wire [7:0] vbi_byte;
    reg  [7:0] portsel;
    ldv_mech #(.CLK_HZ(CLK_HZ), .PIC_FIELD(PIC_FIELD), .FETCH_LINES(FETCH_LINES), .VBI_LINES(VBI_LINES)) u_mech (
        .clk(clk), .reset_n(z80_rst_n), .run(run), .field_tick(field_tick),
        .last_frame((disc_last_frame != 17'd0) ? disc_last_frame : LAST_FRAME),
        .ppi0_pa(ppi0_pa), .ppi0_pc(ppi0_pc), .ppi1_pb(ppi1_pb),
        .counter(counter), .vsync(vsync), .vbiready(vbiready),
        .vbi_consume(dec_re && (portsel == 8'd4)), .vbi_byte(vbi_byte),
        .at_min(at_min), .at_max(at_max), .trg_min(trg_min), .trg_max(trg_max),
        .track(track), .fieldnum(fieldnum), .fetch_done(fetch_done),
        .frame_valid(frame_valid), .frame(frame), .vbi_bcd(vbi_bcd)
    );

    // ------------------------------------------------------------ PPIs
    // PPI0: PA out -> counter preset; PB in <- counter; PC hi in, lo out
    //   PC4 /VSYNC, PC5 /decoder IRQ (VBI ready), PC6 TRKG LOOP, PC7 DUMP (both 0 in MAME)
    // PPI1: PA in <- /FOCS LOCK, /SPDL LOCK, INSIDE, OUTSIDE, MOTOR STOP, +5V, /INT LOCK, 8"
    //   PB out -> mechanics; PC out -> AUD1, AUD2, AUDEN, /VIDEO SQ, COMMAND, STATUS, SIZE, /LED CAV
    wire [7:0] ppi0_do, ppi1_do;
    wire [7:0] ppi0_pc_in = {2'b00, ~vbiready, ~vsync, 4'h0};
    wire [7:0] ppi1_pa_in = {2'b00, 1'b1, 1'b0, at_max, at_min, ppi1_pb[1], ppi1_pb[0]};
    ldv_i8255 u_ppi0 (
        .clk(clk), .reset_n(z80_rst_n),
        .wr_stb(ppi0_we), .waddr(ba_q[1:0]), .wdata(bd_q), .raddr(A[1:0]), .dout(ppi0_do),
        .pa_i(8'hFF), .pb_i(counter), .pc_i(ppi0_pc_in),
        .pa_o(ppi0_pa), .pb_o(ppi0_pb), .pc_o(ppi0_pc)
    );
    ldv_i8255 u_ppi1 (
        .clk(clk), .reset_n(z80_rst_n),
        .wr_stb(ppi1_we), .waddr(ba_q[1:0]), .wdata(bd_q), .raddr(A[1:0]), .dout(ppi1_do),
        .pa_i(ppi1_pa_in), .pb_i(8'hFF), .pc_i(8'hFF),
        .pa_o(ppi1_pa), .pb_o(ppi1_pb), .pc_o(ppi1_pc)
    );

    // ------------------------------------------------------------ CTC
    wire [7:0] ctc_do, ctc_vec;
    wire       ctc_int_n;
    ldv_z80ctc u_ctc (
        .clk(clk), .reset_n(z80_rst_n), .ce(ce),
        .wr_stb(ctc_we), .wsel(ba_q[1:0]), .wdata(bd_q), .rsel(A[1:0]), .dout(ctc_do),
        .trg({1'b0, trg_max, trg_min, 1'b0}), .trg_en(run),
        .inta(inta_stb), .reti(reti_stb), .int_n(ctc_int_n), .ack_vector(ctc_vec)
    );

    // ------------------------------------------------------- decoder / display
    reg [7:0] command;
    reg [7:0] status_r;
    always @(posedge clk) begin
        if (!z80_rst_n) begin
            portsel <= 8'd0; command <= 8'h00; status_r <= 8'h00;
        end else begin
            if (dec_we && ba_q[2:0] == 3'd0) portsel <= bd_q;
            if (stat_we) status_r <= bd_q;
            // MAME z80_controller_r: return ~command, then command = 0xFF
            if (ctl_re) command <= 8'hFF;
            if (sel && cmd_stb) command <= cmd_byte;      // a fresh game byte wins
        end
    end
    wire [7:0] dec_do = (A[2:0] == 3'd3 && portsel == 8'd4) ? vbi_byte : 8'h00;

    // ------------------------------------------------------------ CPU data in
    reg [7:0] di;
    always @(*) begin
        di = 8'h00;
        if (inta_l)
            di = ctc_vec;
        else if (mem_rd) begin
            if (cs_rom)       di = rom_q;
            else if (cs_ram)  di = ram_q;
            else if (cs_ppi0) di = ppi0_do;
            else if (cs_ppi1) di = ppi1_do;
        end else if (io_rd) begin
            case (A[7:6])
                2'b00:   di = dec_do;
                2'b01:   di = ~command;
                2'b11:   di = ctc_do;
                default: di = 8'h00;
            endcase
        end
    end
    assign cpu_di = di;

    assign z80_i.ce    = ce;
    assign z80_i.int_n = ctc_int_n;
    assign z80_i.nmi_n = 1'b1;
    assign z80_i.di    = di;

    // ------------------------------------------------------------ game side
    assign status         = status_r;
    // PPI1 PC5/PC4 idle LOW and pulse HIGH (26 us each, command 54 us after status).
    // ldp_ldv1000 / MAME ldv1000hle -- which the games are validated against -- idle
    // HIGH and assert LOW with the same timing, so the game side gets them inverted.
    // (MAME's ldv1000.cpp returns the raw bits; its HLE is the inverse.)
    assign status_strobe  = sel ? ~ppi1_pc[5] : 1'b1;
    assign command_strobe = sel ? ~ppi1_pc[4] : 1'b1;
    assign video_squelch  = ~ppi1_pc[3];
    assign audio_squelch  = {~ppi1_pc[2] | ~ppi1_pc[1], ~ppi1_pc[2] | ~ppi1_pc[0]};

    ldv_follow u_follow (
        .clk(clk), .reset_n(z80_rst_n), .enable(run),
        .fetch_done(fetch_done), .frame_valid(frame_valid), .frame(frame),
        .video_on(ppi1_pc[3]),
        .aud_en1(ppi1_pc[2] & ppi1_pc[0]), .aud_en2(ppi1_pc[2] & ppi1_pc[1]),
        .t_mode(t_mode), .t_frame(curr_frame),
        .cmd_action(cmd_action), .cmd_op(cmd_op), .cmd_arg(cmd_arg),
        .dbg_class(dbg_class)
    );

    // ------------------------------------------------------------ debug
    assign dbg_digits   = frame_valid ? vbi_bcd : 20'h00000;
    assign dbg_track    = track;
    assign dbg_ctl_rd   = ctl_re;
    assign dbg_ctl_val  = ~command;
    assign dbg_disp_we  = dec_we && (ba_q[2:0] == 3'd2) && (portsel < 8'd2);
    assign dbg_disp_sel = portsel;
    assign dbg_disp_dat = bd_q;
    assign dbg_irq      = ~ctc_int_n;
    assign dbg_ppi0_pa  = ppi0_pa;
    assign dbg_ppi0_pc  = ppi0_pc;
    assign dbg_ppi1_pb  = ppi1_pb;
    assign dbg_ppi1_pc  = ppi1_pc;
    assign dbg_counter  = counter;
    assign dbg_fetch    = fetch_done;
    assign dbg_fieldnum = fieldnum;

    /* verilator lint_off UNUSED */
    wire unused_ok = &{1'b0, ppi0_pb, ppi1_pa, rom_qb, ram_qb, ba_q[12:8], ba_q[5:4], ppi1_pc[7:6]};
    /* verilator lint_on UNUSED */
endmodule
