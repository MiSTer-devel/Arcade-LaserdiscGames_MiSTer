//============================================================================
//
//  sdram_phase_cal.sv — SDRAM clock phase calibration, SDRAM clock domain.
//  Ported from Arcade-UPLFramebuffer upl_rom.sv (HW-confirmed 2026-10-13).
//
//  One SDRAM ROM region is checksummed (CRC-32 over 16-bit words) as it
//  downloads. Once the load has gone quiet, every DPS position of SDRAM_CLK is
//  tried: the region is read back (repeated until >= 16K reads), checksummed at
//  all four latch points, and a position passes for a latch when every pass
//  matches. The centre of the widest passing run (circular, per latch in
//  LATCH_MASK) is requested. Nothing passes, or everything does -> 0, the
//  pre-calibration clock. Ack of each move comes back as ph_ack.
//
//============================================================================

module sdram_phase_cal #(
    parameter [6:0] POS        = 7'd80,   // DPS positions per clock period = 8 * VCO / fclk
    parameter [3:0] LATCH_MASK = 4'hF,    // latches the arbiter can use {Later, Late, Normal, Early}
    parameter       QUIET_BITS = 21       // 2^QUIET_BITS idle cycles after the load before sweeping
)(
    input             clk,
    input             por_reset,

    // reference: the region's bytes as they download, in address order
    input             ref_clr,            // region byte 0 arriving
    input             ref_wd,             // odd byte arriving: a 16-bit word completes
    input      [15:0] ref_w,              // {odd byte, even byte}

    input             ph_auto,            // OSD phase = Auto
    input             ld_busy,            // ioctl_download | status[0] (Main holds it across the MRA)
    input             dl_active,          // ioctl_download
    input             blocked,            // arbiter busy with its own probe

    // phase handshake with sdram_phase_ctl
    output reg  [6:0] ph_req_val,
    output reg        ph_req_tgl,
    input             ph_ack,             // pulse: requested move done

    // read port into the arbiter
    output            rd_go,              // wants word rd_word of the region read
    output     [14:0] rd_word,
    input             rd_take,            // arbiter issued it this cycle
    input             rd_cpl,             // that read completed this cycle
    input      [15:0] sd_dout,            // controller output
    input      [15:0] sd_dout_d1,         // one-deep delay of it

    output reg        busy,               // sweep running: gate clients/probe, hold ioctl_wait
    output            hold                // sweep pending or running: hold the game in reset
);

    // CRC-32 (0x04C11DB7), 16 bits per step. Order-sensitive: a wrong latch returns
    // each 4-word burst rotated, which additive sums can miss on regular data.
    function automatic [31:0] crc_step(input [31:0] c, input [15:0] d);
        integer i;
        reg [31:0] r;
        begin
            r = c;
            for (i = 15; i >= 0; i = i - 1)
                r = {r[30:0], 1'b0} ^ ((r[31] ^ d[i]) ? 32'h04C11DB7 : 32'd0);
            crc_step = r;
        end
    endfunction

    // ---- reference checksum -------------------------------------------------
    reg  [31:0] ref_crc;
    reg  [14:0] ref_cnt;
    wire        ref_take = ref_wd && !ref_cnt[14];       // first 16K words
    wire        ref_ok   = (ref_cnt[14:4] != 11'd0);    // at least 16 words
    always_ff @(posedge clk) begin
        if (ref_clr) begin
            ref_crc <= 32'hFFFFFFFF; ref_cnt <= 15'd0;
        end else if (ref_take) begin
            ref_crc <= crc_step(ref_crc, ref_w); ref_cnt <= ref_cnt + 15'd1;
        end
    end

    // ---- sweep ---------------------------------------------------------------
    localparam [2:0] CS_IDLE = 3'd0, CS_REQ = 3'd1, CS_TGL = 3'd2, CS_WACK = 3'd3,
                     CS_SETTLE = 3'd4, CS_READ = 3'd5, CS_EVAL = 3'd6, CS_PICK = 3'd7;
    reg   [2:0] st;
    reg         pend, fin, abrt, inflight, auto_d;
    reg   [6:0] p, home, tgt;
    reg  [14:0] w;
    reg  [14:0] reads;                     // reads done at this position, saturating at 16K
    reg   [7:0] settle;
    reg  [21:0] wdog;
    reg  [QUIET_BITS-1:0] quiet;
    reg   [1:0] dly;
    reg  [15:0] s_e, s_n, s_l;
    reg  [31:0] crc [0:3];
    reg   [3:0] okacc;                     // every pass so far matched, per latch
    // run trackers per latch (0 Early, 1 Normal, 2 Late, 3 Later)
    reg   [6:0] t_cur [0:3], t_curs [0:3], t_first [0:3], t_best [0:3], t_bests [0:3];
    reg   [3:0] t_open;
    integer     li;

    assign hold    = busy || (pend && ph_auto && ref_ok);
    assign rd_go   = busy && (st == CS_READ) && !inflight && (w != ref_cnt) && (dly == 2'd0);
    assign rd_word = w;

    wire [15:0] cw [0:3];
    assign cw[0] = s_e;       // completion -1
    assign cw[1] = s_n;       // completion
    assign cw[2] = s_l;       // completion +1
    assign cw[3] = sd_dout;   // completion +2 (valid when dly == 1)

    wire [3:0] pass_now = {crc[3] == ref_crc, crc[2] == ref_crc,
                           crc[1] == ref_crc, crc[0] == ref_crc};
    wire [3:0] pass_pos = okacc & pass_now & LATCH_MASK;

    // widest run per latch, including one that wraps POS-1 -> 0
    reg  [6:0] pk_len [0:3];
    reg  [6:0] pk_st  [0:3];
    reg  [6:0] pk_blen, pk_bst;
    reg  [7:0] pk_mid;
    always_comb begin
        for (li = 0; li < 4; li = li + 1) begin
            if ((t_cur[li] != 7'd0) && (t_first[li] != 7'd0) && (t_first[li] != POS) &&
                ((t_cur[li] + t_first[li]) > t_best[li])) begin
                pk_len[li] = t_cur[li] + t_first[li];
                pk_st[li]  = t_curs[li];
            end else begin
                pk_len[li] = t_best[li];
                pk_st[li]  = t_bests[li];
            end
        end
        // tie preference: Normal, Early, Late, Later
        pk_blen = pk_len[1]; pk_bst = pk_st[1];
        if (pk_len[0] > pk_blen) begin pk_blen = pk_len[0]; pk_bst = pk_st[0]; end
        if (pk_len[2] > pk_blen) begin pk_blen = pk_len[2]; pk_bst = pk_st[2]; end
        if (pk_len[3] > pk_blen) begin pk_blen = pk_len[3]; pk_bst = pk_st[3]; end
        pk_mid = {1'b0, pk_bst} + {2'b00, pk_blen[6:1]};
        if (pk_mid >= {1'b0, POS}) pk_mid = pk_mid - {1'b0, POS};
    end

    always_ff @(posedge clk) begin
        if (por_reset) begin
            st <= CS_IDLE; busy <= 1'b0; pend <= 1'b0; fin <= 1'b0; abrt <= 1'b0;
            inflight <= 1'b0; dly <= 2'd0; home <= 7'd0; quiet <= '0; auto_d <= 1'b0;
            wdog <= 22'd0; ph_req_val <= 7'd0; ph_req_tgl <= 1'b0;
        end else begin
            auto_d <= ph_auto;
            quiet  <= ld_busy ? '0 : (quiet + {{(QUIET_BITS-1){1'b0}}, ~&quiet});
            if (ref_take || (ph_auto && !auto_d)) pend <= 1'b1;
            if (busy) wdog <= wdog + 22'd1;

            // sample pipeline: completion -1/0 now, +1 next cycle, +2 the cycle after
            if (rd_take) inflight <= 1'b1;
            if (rd_cpl) begin
                s_e <= sd_dout_d1; s_n <= sd_dout; dly <= 2'd2;
            end else if (dly == 2'd2) begin
                s_l <= sd_dout; dly <= 2'd1;
            end else if (dly == 2'd1) begin
                for (li = 0; li < 4; li = li + 1) crc[li] <= crc_step(crc[li], cw[li]);
                dly <= 2'd0; inflight <= 1'b0; w <= w + 15'd1;
                if (!reads[14]) reads <= reads + 15'd1;
            end

            if (busy && (!ph_auto || &wdog)) begin
                // manual phase selected, or an ack never came: stop, release the game
                busy <= 1'b0; st <= CS_IDLE;
            end else if (busy && dl_active && !abrt) begin
                // new load mid-sweep: back to the last good position before any write lands
                // (busy holds ioctl_wait), then sweep again once it is quiet
                abrt <= 1'b1; fin <= 1'b1; tgt <= home; st <= CS_REQ;
            end else begin
                case (st)
                    CS_IDLE:
                        if (pend && ph_auto && ref_ok && (&quiet) && !blocked && !dl_active && !ld_busy) begin
                            pend <= 1'b0; busy <= 1'b1; fin <= 1'b0; abrt <= 1'b0; wdog <= 22'd0;
                            p <= 7'd0; tgt <= 7'd0; t_open <= 4'hF;
                            for (li = 0; li < 4; li = li + 1) begin
                                t_cur[li] <= 7'd0; t_curs[li] <= 7'd0; t_first[li] <= 7'd0;
                                t_best[li] <= 7'd0; t_bests[li] <= 7'd0;
                            end
                            st <= CS_REQ;
                        end
                    CS_REQ: begin
                        ph_req_val <= tgt; wdog <= 22'd0;
                        st <= CS_TGL;
                    end
                    CS_TGL: begin   // value settled a cycle before the toggle crosses
                        ph_req_tgl <= ~ph_req_tgl;
                        st <= CS_WACK;
                    end
                    CS_WACK:
                        if (ph_ack) begin
                            if (fin) begin
                                busy <= 1'b0; st <= CS_IDLE;
                                if (abrt) pend <= 1'b1;
                                else      home <= tgt;
                            end else begin
                                settle <= 8'd0; st <= CS_SETTLE;
                            end
                        end
                    CS_SETTLE: begin
                        settle <= settle + 8'd1;
                        if (&settle) begin
                            w <= 15'd0; reads <= 15'd0; okacc <= 4'hF;
                            for (li = 0; li < 4; li = li + 1) crc[li] <= 32'hFFFFFFFF;
                            st <= CS_READ;
                        end
                    end
                    CS_READ:
                        if ((w == ref_cnt) && !inflight && (dly == 2'd0)) begin
                            if (reads[14]) st <= CS_EVAL;
                            else begin   // short region: another pass, every pass must match
                                okacc <= okacc & pass_now;
                                w <= 15'd0;
                                for (li = 0; li < 4; li = li + 1) crc[li] <= 32'hFFFFFFFF;
                            end
                        end
                    CS_EVAL: begin
                        for (li = 0; li < 4; li = li + 1) begin
                            if (pass_pos[li]) begin
                                t_cur[li] <= t_cur[li] + 7'd1;
                                if (t_cur[li] == 7'd0) t_curs[li] <= p;
                                if (t_open[li]) t_first[li] <= t_first[li] + 7'd1;
                                if ((t_cur[li] + 7'd1) > t_best[li]) begin
                                    t_best[li]  <= t_cur[li] + 7'd1;
                                    t_bests[li] <= (t_cur[li] == 7'd0) ? p : t_curs[li];
                                end
                            end else begin
                                t_cur[li] <= 7'd0; t_open[li] <= 1'b0;
                            end
                        end
                        if (p == POS - 7'd1) st <= CS_PICK;
                        else begin p <= p + 7'd1; tgt <= p + 7'd1; st <= CS_REQ; end
                    end
                    CS_PICK: begin
                        tgt <= ((pk_blen == 7'd0) || (pk_blen == POS)) ? 7'd0 : pk_mid[6:0];
                        fin <= 1'b1;
                        st  <= CS_REQ;
                    end
                endcase
            end
        end
    end

endmodule
