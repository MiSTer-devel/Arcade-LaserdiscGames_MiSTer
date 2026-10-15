//============================================================================
//
//  Dragon's Lair II main RAM in SDRAM, through sdram.sv (Sorgelig), with the
//  fleet SDRAM clock-phase calibrator and read-latch auto-detect.
//  Derived from Arcade-Pacman_MiSTer rtl/ram_rom/pacman_sdrom.sv; changes are tagged "DL2:".
//
//============================================================================

module dl2_sdram
#(
    parameter [24:0] RAM_BASE = 25'h0100000    // DL2: SDRAM byte address of the CPU's RAM (above the ROM region)
)
(
    input               clk,            // DL2: 80 MHz CLK_CORE
    input               por_reset,      // power-on only: a download must not idle this FSM

    input               ioctl_download,
    input               ioctl_wr2,      // DL2: program ROM byte (index 0, below 64K) = calibration reference
    input        [24:0] ioctl_addr,
    input         [7:0] ioctl_dout,
    output              ioctl_wait,

    // read latch: rd_auto measures which burst word completion holds; rd_mode overrides and is the fallback
    input               rd_auto,        // 1 = use the detected latch when detection succeeded
    input         [1:0] rd_mode,        // 0 Early, 1 Normal, 2 Late, 3 Later

    // DL2: the board's RAM port -- 1-cycle rd/wr strobes, busy held until the access is done
    input        [23:0] ram_addr,
    input         [7:0] ram_din,
    input               ram_rd,
    input               ram_wr,
    output        [7:0] ram_dout,
    output              ram_busy,

    input               recal,          // pulse: SDRAM clock phase moved (re-probe the latch)
    input               ph_auto,        // OSD phase = Auto
    input               ld_hold,        // status[0], held across the MRA load
    output        [6:0] ph_req_val,     // requested DPS position
    output              ph_req_tgl,     // request strobe (toggle); recal is the ack
    output              cal_hold,       // hold the game in reset while calibrating

    inout        [15:0] SDRAM_DQ,
    output       [12:0] SDRAM_A,
    output              SDRAM_DQML,
    output              SDRAM_DQMH,
    output        [1:0] SDRAM_BA,
    output              SDRAM_nCS,
    output              SDRAM_nWE,
    output              SDRAM_nRAS,
    output              SDRAM_nCAS,
    output              SDRAM_CKE,
    output              SDRAM_CLK
);

localparam [1:0] RD_EARLY = 2'd0, RD_NORMAL = 2'd1, RD_LATE = 2'd2, RD_LATER = 2'd3;

reg  [26:1] sd_addr = 26'd0;
reg  [15:0] sd_din = 16'd0;
reg   [1:0] sd_bs = 2'b11;
reg         sd_rd = 1'b0, sd_wr = 1'b0, sd_busy = 1'b0, sd_was_rd = 1'b0, sd_lsb = 1'b0;
reg         sd_refresh = 1'b0, sd_old_ready = 1'b1;
reg   [9:0] sd_refresh_cnt = 10'd0;     // DL2: 625 clocks per refresh at 80 MHz needs 10 bits
wire [15:0] sd_dout;
wire        sd_ready;

// sd_dout is a register of SDRAM_DQ, so a one-deep delay gives burst word 0
reg  [15:0] sd_dout_d1 = 16'd0;
always @(posedge clk) sd_dout_d1 <= sd_dout;

reg         wr_pend = 1'b0;
reg  [19:0] wr_addr = 20'd0;
reg   [7:0] wr_data = 8'd0;

// DL2: the board strobes; the Pacman core underneath wants a held request
reg         cpu_req = 1'b0;
reg  [24:0] cpu_addr = 25'd0;           // SDRAM byte address
reg   [7:0] cpu_data = 8'd0;
reg         cpu_wr_pend = 1'b0, cw_issued = 1'b0;
reg  [24:0] cw_addr = 25'd0;
reg   [7:0] cw_data = 8'd0;

reg  [24:0] have_addr = 25'h1FFFFFF;    // byte currently held in cpu_data
reg         have_ok = 1'b0;
reg         rd_pend = 1'b0;             // Late / Later capture after completion
reg   [1:0] rd_cnt = 2'd0;

// ---- read-latch auto-detect ------------------------------------------------
// Reads wrap inside the aligned 4-word block, so one block of four distinct words tells the sample points apart;
// falls back to rd_mode if no such block is seen or a read hangs
reg  [63:0] dl_blk = 64'd0;
reg  [18:0] blk_wa = 19'd0;
reg         blk_rdy = 1'b0;
always @(posedge clk) begin
    if (ioctl_wr2) dl_blk <= {dl_blk[55:0], ioctl_dout};
    if (ioctl_wr2 && ioctl_addr[2:0] == 3'd7) blk_wa <= {ioctl_addr[19:3], 2'b00};
    blk_rdy <= ioctl_wr2 && ioctl_addr[2:0] == 3'd7;
end

// dl_blk holds b0..b7 oldest-first once the 8th byte has shifted in
wire [15:0] blk_w0 = {dl_blk[55:48], dl_blk[63:56]};
wire [15:0] blk_w1 = {dl_blk[39:32], dl_blk[47:40]};
wire [15:0] blk_w2 = {dl_blk[23:16], dl_blk[31:24]};
wire [15:0] blk_w3 = {dl_blk[ 7: 0], dl_blk[15: 8]};
wire blk_distinct = (blk_w0 != blk_w1) && (blk_w0 != blk_w2) && (blk_w0 != blk_w3)
                 && (blk_w1 != blk_w2) && (blk_w1 != blk_w3) && (blk_w2 != blk_w3);

reg  [18:0] ref_wa = 19'd0;
reg  [15:0] ref_w[4];
reg         ref_vld = 1'b0;
always @(posedge clk) begin
    if (por_reset) ref_vld <= 1'b0;
    else if (blk_rdy && !ref_vld && blk_distinct) begin
        ref_wa   <= blk_wa;
        ref_w[0] <= blk_w0; ref_w[1] <= blk_w1;
        ref_w[2] <= blk_w2; ref_w[3] <= blk_w3;
        ref_vld  <= 1'b1;
    end
end

reg         probing = 1'b0, sd_probe = 1'b0, det_ok = 1'b0, dl_d = 1'b0, prb_req = 1'b0;
reg   [1:0] prb_dly = 2'd0, prb_ph = 2'd0, rd_det = RD_NORMAL;
reg   [3:0] prb_ok = 4'hF;              // {Later, Late, Normal, Early} still matching
reg  [15:0] prb_wd, prb_e, prb_n, prb_l;
reg  [15:0] prb_to = 16'd0;

wire  [3:0] prb_ok_nxt = {prb_ok[3] && (sd_dout == prb_wd),     // completion +2
                          prb_ok[2] && (prb_l   == prb_wd),     // completion +1
                          prb_ok[1] && (prb_n   == prb_wd),     // completion
                          prb_ok[0] && (prb_e   == prb_wd)};    // completion -1

wire  [1:0] rd_sel      = (rd_auto && det_ok) ? rd_det : rd_mode;
wire [15:0] sd_dout_sel = (rd_sel == RD_EARLY) ? sd_dout_d1 : sd_dout;

// ---- SDRAM clock phase calibration ----
// Reference = the DL2 program ROM region (SDRAM word 0 up), checksummed as it downloads.
wire        cal_busy, cal_rd_go;
wire [14:0] cal_rd_word;
reg         sd_cal = 1'b0;
wire        cal_take = !sd_busy && !wr_pend && cal_rd_go && !rd_pend;
wire        cal_cpl  = sd_busy && sd_ready && !sd_rd && !sd_wr && sd_was_rd && sd_cal;

// DL2: 80 positions = 8 x 800 MHz VCO / 80 MHz; 2^22 quiet cycles = 52 ms at 80 MHz
sdram_phase_cal #(.POS(7'd80), .LATCH_MASK(4'hF), .QUIET_BITS(22)) phase_cal
(
    .clk(clk), .por_reset(por_reset),
    .ref_clr(ioctl_wr2 && (ioctl_addr[19:0] == 20'd0)),
    .ref_wd(ioctl_wr2 && ioctl_addr[0]),
    .ref_w({ioctl_dout, dl_blk[7:0]}),
    .ph_auto(ph_auto), .ld_busy(ioctl_download | ld_hold), .dl_active(ioctl_download),
    .blocked(probing),
    .ph_req_val(ph_req_val), .ph_req_tgl(ph_req_tgl), .ph_ack(recal),
    .rd_go(cal_rd_go), .rd_word(cal_rd_word), .rd_take(cal_take), .rd_cpl(cal_cpl),
    .sd_dout(sd_dout), .sd_dout_d1(sd_dout_d1),
    .busy(cal_busy), .hold(cal_hold)
);

// cal_busy holds the HPS while an aborted sweep restores the phase
assign ioctl_wait = sd_busy | wr_pend | cal_busy;
wire   cpu_busy   = cpu_req & ~(have_ok & have_addr == cpu_addr);
assign ram_busy   = cpu_busy | cpu_wr_pend;     // DL2
assign ram_dout   = cpu_data;                   // DL2

always @(posedge clk) begin
    if (por_reset) begin
        sd_rd <= 1'b0; sd_wr <= 1'b0; sd_busy <= 1'b0; sd_refresh <= 1'b0; sd_refresh_cnt <= 10'd0;
        sd_old_ready <= 1'b1; wr_pend <= 1'b0; have_ok <= 1'b0; rd_pend <= 1'b0; rd_cnt <= 2'd0;
        probing <= 1'b0; sd_probe <= 1'b0; prb_dly <= 2'd0; det_ok <= 1'b0; dl_d <= 1'b0;
        prb_req <= 1'b0; sd_cal <= 1'b0;
        cpu_req <= 1'b0; cpu_wr_pend <= 1'b0; cw_issued <= 1'b0;   // DL2
    end
    else begin
        // Probe once the download's last write has drained
        dl_d <= ioctl_download;
        // Held until it can start (the edge-only trigger skipped the probe when sd_busy was
        // high that cycle); a phase move re-runs it. The probe read waits for !sd_busy below.
        if ((dl_d && !ioctl_download) || recal) prb_req <= 1'b1;
        else if (prb_req && ref_vld && !probing && !ioctl_download && !cal_busy) begin
            prb_req <= 1'b0;
            probing <= 1'b1; prb_ph <= 2'd0; prb_ok <= 4'hF; prb_to <= 16'd0;
        end
        if (probing) begin
            prb_to <= prb_to + 16'd1;
            if (&prb_to) begin              // never leave the CPU blocked
                probing <= 1'b0; sd_probe <= 1'b0; prb_dly <= 2'd0; det_ok <= 1'b0;
            end
        end

        // AUTO REFRESH: 8192 rows / 64 ms = 7.8125 us = 625 clocks at 80 MHz   (DL2: was 384 at 49.152 MHz)
        if (sd_refresh_cnt == 10'd624) begin
            sd_refresh_cnt <= 10'd0;
            sd_refresh     <= ~sd_refresh;
        end
        else sd_refresh_cnt <= sd_refresh_cnt + 10'd1;

        sd_old_ready <= sd_ready;
        // a phase move invalidates the held byte
        if (ioctl_download || recal) have_ok <= 1'b0;

        if (ioctl_wr2) begin
            wr_pend <= 1'b1;
            wr_addr <= ioctl_addr[19:0];
            wr_data <= ioctl_dout;
        end

        // DL2: board strobes -> held read request / pending write
        if (ram_rd) begin
            cpu_req  <= 1'b1;
            cpu_addr <= RAM_BASE + {1'b0, ram_addr};
        end
        else if (cpu_req && have_ok && have_addr == cpu_addr) cpu_req <= 1'b0;   // byte delivered
        if (ram_wr) begin
            cpu_wr_pend <= 1'b1;
            cw_addr     <= RAM_BASE + {1'b0, ram_addr};
            cw_data     <= ram_din;
            if (have_addr == RAM_BASE + {1'b0, ram_addr}) have_ok <= 1'b0;      // held byte is now stale
        end

        // accepted: ready fell, drop the strobe so the operation runs once
        if (sd_old_ready && !sd_ready) begin
            sd_rd <= 1'b0;
            sd_wr <= 1'b0;
        end

        if (sd_busy) begin
            if (sd_ready && !sd_rd && !sd_wr) begin
                if (sd_was_rd) begin
                    if (sd_probe) begin
                        prb_e <= sd_dout_d1; prb_n <= sd_dout;
                        prb_dly <= 2'd2; sd_probe <= 1'b0;
                    end
                    // calibration read (sampled inside sdram_phase_cal)
                    else if (sd_cal) sd_cal <= 1'b0;
                    else if (rd_sel >= RD_LATE) begin
                        rd_pend <= 1'b1;
                        rd_cnt  <= (rd_sel == RD_LATER) ? 2'd2 : 2'd1;
                    end
                    else begin
                        cpu_data <= sd_lsb ? sd_dout_sel[15:8] : sd_dout_sel[7:0];
                        have_ok  <= 1'b1;
                    end
                end
                else if (cw_issued) begin       // DL2: the CPU write has landed
                    cpu_wr_pend <= 1'b0;
                    cw_issued   <= 1'b0;
                end
                sd_busy <= 1'b0;
            end
        end
        else if (wr_pend) begin
            sd_addr <= {7'd0, wr_addr[19:1]};
            sd_din  <= {wr_data, wr_data};
            sd_bs   <= wr_addr[0] ? 2'b10 : 2'b01;
            sd_wr   <= 1'b1; sd_busy <= 1'b1; sd_was_rd <= 1'b0;
            wr_pend <= ioctl_wr2;                 // keep a byte arriving this cycle
        end
        else if (cpu_wr_pend && !cw_issued && !probing && !cal_busy) begin   // DL2: CPU write
            sd_addr   <= {2'd0, cw_addr[24:1]};
            sd_din    <= {cw_data, cw_data};
            sd_bs     <= cw_addr[0] ? 2'b10 : 2'b01;
            sd_wr     <= 1'b1; sd_busy <= 1'b1; sd_was_rd <= 1'b0;
            cw_issued <= 1'b1;
        end
        else if (cal_take) begin
            sd_addr <= {11'd0, cal_rd_word};
            sd_rd   <= 1'b1; sd_busy <= 1'b1; sd_was_rd <= 1'b1; sd_cal <= 1'b1;
        end
        else if (probing && prb_dly == 2'd0) begin
            sd_addr <= {7'd0, ref_wa + {17'd0, prb_ph}};
            prb_wd  <= ref_w[prb_ph];
            sd_rd   <= 1'b1; sd_busy <= 1'b1; sd_was_rd <= 1'b1; sd_probe <= 1'b1;
        end
        else if (cpu_busy && !ioctl_download && !probing && !cal_busy && !rd_pend) begin
            sd_addr   <= {2'd0, cpu_addr[24:1]};   // DL2: 25-bit byte address
            sd_lsb    <= cpu_addr[0];
            have_addr <= cpu_addr;
            have_ok   <= 1'b0;
            sd_rd     <= 1'b1; sd_busy <= 1'b1; sd_was_rd <= 1'b1;
        end

        // Late / Later: capture one / two clocks after completion
        if (rd_pend && rd_cnt > 2'd1) rd_cnt <= rd_cnt - 2'd1;
        else if (rd_pend) begin
            cpu_data <= sd_lsb ? sd_dout[15:8] : sd_dout[7:0];
            have_ok  <= 1'b1;
            rd_pend  <= 1'b0;
        end

        // Late sample lands one clock after completion; all candidates are then in hand
        if (prb_dly == 2'd2) begin
            prb_l   <= sd_dout;                   // completion +1
            prb_dly <= 2'd1;
        end
        else if (prb_dly == 2'd1) begin
            prb_ok  <= prb_ok_nxt;                // sd_dout is now completion +2
            prb_dly <= 2'd0;
            if (prb_ph == 2'd3) begin
                probing <= 1'b0;
                if      (prb_ok_nxt[1]) begin rd_det <= RD_NORMAL; det_ok <= 1'b1; end
                else if (prb_ok_nxt[0]) begin rd_det <= RD_EARLY;  det_ok <= 1'b1; end
                else if (prb_ok_nxt[2]) begin rd_det <= RD_LATE;   det_ok <= 1'b1; end
                else if (prb_ok_nxt[3]) begin rd_det <= RD_LATER;  det_ok <= 1'b1; end
                else                          det_ok <= 1'b0;
            end
            else prb_ph <= prb_ph + 2'd1;
        end
    end
end

// DL2: 100 us startup = 8000 clocks at 80 MHz; refresh comes from the toggle above
sdram #(.sdram_startup_cycles(14'd8040), .cycles_per_refresh(14'd624)) sdram_i
(
    .init       (por_reset),
    .clk        (clk),
    .SDRAM_DQ   (SDRAM_DQ),   .SDRAM_A   (SDRAM_A),   .SDRAM_DQML(SDRAM_DQML),
    .SDRAM_DQMH (SDRAM_DQMH), .SDRAM_BA  (SDRAM_BA),  .SDRAM_nCS (SDRAM_nCS),
    .SDRAM_nWE  (SDRAM_nWE),  .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS),
    .SDRAM_CKE  (SDRAM_CKE),  .SDRAM_CLK (SDRAM_CLK), .SDRAM_EN  (1'b1),
    .sel        (1'b1),
    .addr       (sd_addr),    .dout      (sd_dout),   .din       (sd_din),
    .wr         (sd_wr),      .bs        (sd_bs),     .rd        (sd_rd),
    .ready      (sd_ready),   .refresh   (sd_refresh),
    .cpsel(1'b0), .cpaddr(26'd0), .cpdin(16'd0), .cprd(), .cpreq(1'b0), .cpbusy()
);

endmodule
