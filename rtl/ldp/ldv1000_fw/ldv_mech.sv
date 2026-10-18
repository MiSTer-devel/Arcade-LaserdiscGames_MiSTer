//============================================================================
// ldv_mech.sv -- LD-V1000 disc mechanics + VBI decoder, as the firmware sees them.
//
// Port of the mechanics half of MAME ldv1000.cpp and laserdsc.cpp:
//   track       m_curtrack, clamped 1..MAXTRACK-1.  Track 1 = SLIDER_MINIMUM
//               (INSIDE), MAXTRACK-1 = SLIDER_MAXIMUM (OUTSIDE).  Tracks
//               1..LEADIN are virtual lead-in (VBI = lead-in code).  Program
//               frame f lives on track f + LEADIN (track LEADIN+1 = frame 1).
//   advance     +1 track at the VBI fetch of every field-1 (player_update
//               returns fieldnum), unconditionally -- the firmware holds a still
//               frame by jumping back itself.
//   JUMP TRIG   PPI1 PB2 falling edge: one track, direction PB5 (1 = outward).
//   MULTI JUMP  PPI0 PC0 rising edge loads the 8-bit down counter from PPI0 PA;
//               PPI0 PC1 falling edge starts it: one track per 50 us until the
//               counter reaches 0 (counter 0 => 256 tracks).  Counter on PPI0 PB.
//   SCAN        PPI1 PB3 low: slider moves at 66 (PB4=1) or 133 (PB4=0)
//               tracks per field (MAME's integer 2000/30 and 4000/30), dir PB5.
//   field       field_tick = start of field (MAME vblank).  VSYNC flag for 4
//               lines; track fetch at +33 lines; VBI ready at +39 lines (MAME
//               NTSC screen: 525 lines x 910 clk @ 28.636 MHz per FIELD).  The
//               fetch / VBI positions are parameters -- see FETCH_LINES/VBI_LINES.
//   VBI         21 bytes, 3 lines x 7 (lines 17/18, 17, 16).  Lines 17/18 and 17
//               carry the code for the field just read; line 16 is zero.  The
//               CAV picture number is on the FIRST field of a track only (field 0,
//               the one read right after the advance) -- MAME's read_track_data
//               uses exactly that code to detect a frame's first field; the
//               second field carries no code.  PIC_FIELD selects 0 / 1 / 2 = both
//               (a CHD captured odd-field-first has the code on field 1).
//               Lead-in is forced on both fields (MAME), lead-out likewise.  Only
//               lead-in, lead-out and CAV picture codes are decoded; all zero
//               unless focus_on && laser_on at the VBI moment.
//   FILM        film = 1 (a 23.976 disc: Dragon's Lair, Space Ace): film-source CAV
//               with 3:2 pulldown, 4 picture numbers per 5 tracks (Pioneer interface
//               manual p.10; Daphne hitachi.cpp x1.25).  Program field n (n = 0 =
//               field 0 of track LEADIN+1) shows film frame
//               f(n) = floor((2n + FILM_PHASE) / 5) + 1; only the FIRST field of
//               each picture carries its code (MAME is_start_of_frame: a frame
//               code marks the start of a frame), the others carry none.
//               `frame` is then the picture on the track's field 1 -- the one a
//               still on that track was searched to.  The picture comes from the
//               transport / .dlv at film rate, never from here: this is only what
//               the firmware reads.
//   Frame / code / lead-in-out are registered 2 clocks behind the track; the
//   code latch and the fetch_done output wait for them.
// Port-select 4 + offset-3 reads return the VBI stream (handled by the caller,
// which supplies vbi_idx and gets vbi_byte).
//============================================================================
module ldv_mech
#(
    parameter [31:0] CLK_HZ   = 32'd80_000_000,
    parameter [16:0] LEADIN   = 17'd900,     // VIRTUAL_LEAD_IN_TRACKS
    parameter [16:0] MAXTRACK = 17'd56100,   // m_maxtrack (lead-in + 54000 + 1200 lead-out)
    parameter  [1:0] PIC_FIELD = 2'd0,        // field of a track carrying the picture code: 0, 1, 2 = both
    // Positions after VSYNC in MAME screen lines (31.8 us).  MAME uses 33 / 39, but with
    // VBI ready at >= 34 lines the firmware never completes a SEARCH (it reacts one field
    // late and holds target+1); <= 32 lines it does (bench sweep 2026-10-16).  Line 17/18
    // data on a real player is ready ~0.95 ms (~30 lines) after the VSYNC edge.
    parameter  [7:0] FETCH_LINES = 8'd20,     // track update (revolution boundary)
    parameter  [7:0] VBI_LINES   = 8'd26,     // VBI ready (decoder IRQ, PPI0 PC5)
    parameter  [3:0] FILM_PHASE  = 4'd0,      // film: C in f(n) = floor((2n + C) / 5) + 1, 0..9
    parameter  [0:0] VSYNC_GATE  = 1'b0,      // 1: no field timing (VSYNC / fetch / VBI) unless the spindle
                                              // runs -- a stopped disc has no video (park cycle 21 ms vs
                                              // 16.6 ms playing, interface manual fig. 6).  0 = MAME.
    parameter  [9:0] SEEK_FAST   = 10'd133    // fast-scan tracks/field (PB4=0).  MAME 4000/30 per vsync = 133;
                                              // a full-disc search then takes ~7 s, manual says max ~3 s
)
(
    input             clk,
    input             reset_n,
    input             run,            // !pause: freezes every timer and the slider
    input             film,           // 1 = film-source disc (3:2 pulldown), 0 = 29.97
    input             field_tick,     // 1-clk start of field
    input      [16:0] last_frame,     // last program frame; beyond it = lead-out

    input       [7:0] ppi0_pa,        // pins
    input       [7:0] ppi0_pc,
    input       [7:0] ppi1_pb,

    output reg  [7:0] counter,        // -> PPI0 PB
    output reg        vsync,          // -> PPI0 PC4 inverted by caller
    output reg        vbiready,       // -> PPI0 PC5 inverted by caller
    input             vbi_consume,    // 1-clk: a VBI byte was read (clears ready, idx++)
    output      [7:0] vbi_byte,
    output            at_min,         // INSIDE
    output            at_max,         // OUTSIDE
    output reg        trg_min,        // CTC TRG1, sampled at VSYNC
    output reg        trg_max,        // CTC TRG2, sampled at VSYNC

    output reg [16:0] track,
    output reg        fieldnum,
    output reg        fetch_done,     // 1-clk once the fetch's track / frame are settled
    output            frame_valid,    // track is inside program material
    output     [16:0] frame,          // program frame number under the head
    output reg [19:0] vbi_bcd,        // BCD digits of the picture code (dbg)
    output reg [16:0] pic_code        // last CAV picture number the decoder delivered (focus && laser)
);
    // ---- timing constants (MAME NTSC laserdisc screen) ----
    localparam [63:0] PIX_HZ     = 64'd28_636_363;
    localparam [63:0] LINE_64    = (64'd910 * {32'd0, CLK_HZ}) / PIX_HZ;
    localparam [63:0] FIELD_64   = (64'd1001 * {32'd0, CLK_HZ}) / 64'd60_000;
    localparam [31:0] LINE_CLKS  = LINE_64[31:0];
    localparam [31:0] VSYNC_END  = 32'd4  * LINE_CLKS;
    localparam [31:0] FETCH_AT   = {24'd0, FETCH_LINES} * LINE_CLKS;
    localparam [31:0] VBI_AT     = {24'd0, VBI_LINES}   * LINE_CLKS;
    localparam [31:0] MJ_CLKS    = CLK_HZ / 32'd20_000;                  // 50 us
    localparam [31:0] FIELD_CLKS = FIELD_64[31:0];

    // ---- PPI-driven controls (MAME helper names) ----
    wire focus_on = ~ppi1_pb[0];
    wire laser_on =  ppi1_pb[6];
    wire dir_out  =  ppi1_pb[5];
    wire scanning = ~ppi1_pb[3];
    wire [9:0] scan_spd = ppi1_pb[4] ? 10'd66 : SEEK_FAST;

    reg       pb1_q2;                 // PPI1 PB2 last
    reg [1:0] pc0_q;                  // PPI0 PC1..0 last
    wire jump_trig  =  pb1_q2   & ~ppi1_pb[2];
    wire preload    = ~pc0_q[0] &  ppi0_pc[0];
    wire mj_start   =  pc0_q[1] & ~ppi0_pc[1];

    assign at_min = (track == 17'd1);
    assign at_max = (track >= MAXTRACK - 17'd1);

    // ---- frame under the head (registered, 2 clocks behind track) ----
    // 29.97: frame = track - LEADIN.  Film: x0 = 2n + C for field 0 of the track
    // (n = 2p), k = floor(x / 5) via x * 209716 >> 20 (exact for x < 2^18; x0 <= 4*56099+9).
    wire [16:0] p_trk  = track - LEADIN - 17'd1;               // program track index
    wire [17:0] x0     = {p_trk[15:0], 2'b00} + {14'd0, FILM_PHASE};
    reg  [17:0] x0_q;
    reg  [37:0] mul_q;
    reg  [16:0] trk_q;
    wire [17:0] k0     = mul_q[37:20];
    wire [17:0] r0w    = x0_q - ({k0[15:0], 2'b00} + k0);       // x0 mod 5
    wire  [2:0] rem0   = r0w[2:0];
    wire        c1     = (rem0 >= 3'd3);                       // field 1 is in the next picture
    wire  [2:0] rem1   = c1 ? rem0 - 3'd3 : rem0 + 3'd2;
    reg         lin_r;                                         // in lead-in
    reg  [16:0] ff0_r, ff1_r;                                  // picture on field 0 / field 1
    reg         fc0_r, fc1_r;                                  // field 0 / 1 carries a code
    always @(posedge clk) begin
        x0_q  <= x0;
        mul_q <= {20'd0, x0} * 38'd209716;
        trk_q <= track;
        lin_r <= (trk_q <= LEADIN);
        if (film) begin
            ff0_r <= k0[16:0] + 17'd1;
            ff1_r <= k0[16:0] + {16'd0, c1} + 17'd1;
            fc0_r <= (rem0 < 3'd2);
            fc1_r <= (rem1 < 3'd2);
        end else begin
            ff0_r <= trk_q - LEADIN;
            ff1_r <= trk_q - LEADIN;
            fc0_r <= (PIC_FIELD == 2'd2) || (PIC_FIELD[0] == 1'b0);
            fc1_r <= (PIC_FIELD == 2'd2) || (PIC_FIELD[0] == 1'b1);
        end
    end
    wire        in_leadin  = lin_r;
    wire [16:0] f_raw      = ff1_r;                            // picture of the track
    wire        in_leadout = !in_leadin && (f_raw > last_frame);
    assign frame       = f_raw;
    assign frame_valid = !in_leadin && !in_leadout;
    reg   [2:0] fd_q;                                          // fetch -> pipeline settled

    // ---- field position ----
    reg [31:0] fpos;
    reg        fpos_run;

    // ---- multi-jump / scan state ----
    reg        mj_active;
    reg [31:0] mj_cnt;
    reg [31:0] scan_acc;

    // ---- VBI latch ----
    reg  [1:0] code_kind;      // 0 none, 1 picture, 2 lead-in, 3 lead-out (latched at fetch)
    reg        vbi_valid;      // focus && laser at VBI time
    reg  [1:0] vbi_kind;
    reg [19:0] vbi_dig;
    reg  [4:0] vbi_idx;
    reg [16:0] pend_pic;       // picture number of the field just read (latched with code_kind)

    // binary -> BCD (double dabble), restarted at each fetch
    reg [16:0] bb_bin;
    reg [19:0] bb_bcd;
    reg  [4:0] bb_cnt;
    wire [3:0] d0 = (bb_bcd[3:0]   >= 4'd5) ? bb_bcd[3:0]   + 4'd3 : bb_bcd[3:0];
    wire [3:0] d1 = (bb_bcd[7:4]   >= 4'd5) ? bb_bcd[7:4]   + 4'd3 : bb_bcd[7:4];
    wire [3:0] d2 = (bb_bcd[11:8]  >= 4'd5) ? bb_bcd[11:8]  + 4'd3 : bb_bcd[11:8];
    wire [3:0] d3 = (bb_bcd[15:12] >= 4'd5) ? bb_bcd[15:12] + 4'd3 : bb_bcd[15:12];
    wire [3:0] d4 = (bb_bcd[19:16] >= 4'd5) ? bb_bcd[19:16] + 4'd3 : bb_bcd[19:16];

    // track delta this clock: natural advance + jump + multi-jump + scan
    reg        fetch_now;
    reg        adv_now;
    reg        mj_step;
    reg        scan_step;
    reg signed [3:0] delta;
    reg signed [18:0] nt;

    always @(*) begin
        fetch_now = run && fpos_run && (fpos == FETCH_AT);
        adv_now   = fetch_now && fieldnum;
        mj_step   = run && mj_active && (mj_cnt == MJ_CLKS - 32'd1);
        scan_step = run && scanning && (scan_acc + {22'd0, scan_spd} >= FIELD_CLKS);
        delta = 4'sd0;
        if (adv_now)                 delta = delta + 4'sd1;
        if (run && jump_trig)        delta = dir_out ? delta + 4'sd1 : delta - 4'sd1;
        if (mj_step)                 delta = dir_out ? delta + 4'sd1 : delta - 4'sd1;
        if (scan_step)               delta = dir_out ? delta + 4'sd1 : delta - 4'sd1;
        nt = $signed({2'b00, track}) + {{15{delta[3]}}, delta};
        if (nt < 19'sd1)                              nt = 19'sd1;
        if (nt > $signed({2'b00, MAXTRACK - 17'd1}))  nt = $signed({2'b00, MAXTRACK - 17'd1});
    end

    // the field being read now (fieldnum toggled at the fetch)
    wire [16:0] fld_frame = fieldnum ? ff1_r : ff0_r;
    wire        fld_code  = fieldnum ? fc1_r : fc0_r;
    wire        fld_lout  = !in_leadin && (fld_frame > last_frame);

    always @(posedge clk) begin
        fetch_done <= 1'b0;
        if (!reset_n) begin
            fd_q <= 3'd0;
            track <= 17'd1; fieldnum <= 1'b0;
            fpos <= 32'd0; fpos_run <= 1'b0;
            vsync <= 1'b0; vbiready <= 1'b0;
            counter <= 8'd0; mj_active <= 1'b0; mj_cnt <= 32'd0; scan_acc <= 32'd0;
            pb1_q2 <= 1'b1; pc0_q <= 2'b11;
            trg_min <= 1'b0; trg_max <= 1'b0;
            code_kind <= 2'd2; vbi_valid <= 1'b0; vbi_kind <= 2'd0; vbi_dig <= 20'd0;
            vbi_idx <= 5'd0; vbi_bcd <= 20'd0; pend_pic <= 17'd0; pic_code <= 17'd0;
            bb_bin <= 17'd0; bb_bcd <= 20'd0; bb_cnt <= 5'd0;
        end else if (run) begin
            pb1_q2 <= ppi1_pb[2];
            pc0_q  <= ppi0_pc[1:0];

            // ---- field timing ----
            if (field_tick) begin            // slider comparators, not video: never gated
                trg_min <= at_min;           // player_vsync: ctc->trg1/trg2
                trg_max <= at_max;
            end
            if (field_tick && (!VSYNC_GATE || !ppi1_pb[1])) begin
                fpos <= 32'd0; fpos_run <= 1'b1;
                vsync <= 1'b1;
            end else if (fpos_run) begin
                fpos <= fpos + 32'd1;
                if (fpos == VSYNC_END) vsync <= 1'b0;
            end

            // ---- slider ----
            track <= nt[16:0];

            if (fetch_now)
                fieldnum <= ~fieldnum;
            // track updates with the fetch; the frame pipeline settles 3 clocks later
            fd_q <= {fd_q[1:0], fetch_now};
            if (fd_q[2]) fetch_done <= 1'b1;
            // latch the code for the field just read, once the pipeline has settled
            if (fd_q[2]) begin
                // fieldnum has already toggled: it is the field being read now
                code_kind <= in_leadin ? 2'd2 :
                             fld_lout  ? 2'd3 :
                             fld_code  ? 2'd1 : 2'd0;
                bb_bin <= fld_frame; bb_bcd <= 20'd0; bb_cnt <= 5'd17;
                pend_pic <= fld_frame;
            end else if (bb_cnt != 5'd0) begin
                bb_bcd <= {d4[2:0], d3, d2, d1, d0, bb_bin[16]};
                bb_bin <= {bb_bin[15:0], 1'b0};
                bb_cnt <= bb_cnt - 5'd1;
                if (bb_cnt == 5'd1) vbi_bcd <= {d4[2:0], d3, d2, d1, d0, bb_bin[16]};
            end

            // VBI ready (process_vbi_data)
            if (fpos_run && fpos == VBI_AT) begin
                vbi_valid <= focus_on && laser_on;
                vbi_kind  <= code_kind;
                vbi_dig   <= vbi_bcd;
                vbiready  <= 1'b1;
                if (focus_on && laser_on && code_kind == 2'd1) pic_code <= pend_pic;
                vbi_idx   <= 5'd0;
            end

            // multi-jump
            if (preload) counter <= ppi0_pa;
            if (mj_start) begin
                mj_active <= 1'b1; mj_cnt <= 32'd0;
            end else if (mj_active) begin
                if (mj_cnt == MJ_CLKS - 32'd1) begin
                    mj_cnt  <= 32'd0;
                    counter <= counter - 8'd1;
                    if (counter == 8'd1) mj_active <= 1'b0;
                end else
                    mj_cnt <= mj_cnt + 32'd1;
            end

            // scan accumulator: one step per FIELD_CLKS/scan_spd clocks
            if (!scanning)      scan_acc <= 32'd0;
            else if (scan_step) scan_acc <= scan_acc + {22'd0, scan_spd} - FIELD_CLKS;
            else                scan_acc <= scan_acc + {22'd0, scan_spd};
        end

        // VBI read consumes regardless of run (bus side effect of a CPU that is running)
        if (reset_n && vbi_consume) begin
            vbiready <= 1'b0;
            vbi_idx  <= (vbi_idx == 5'd20) ? 5'd0 : vbi_idx + 5'd1;
        end
    end

    // ---- VBI byte stream ----
    // low 20 bits of the 24-bit code (the top nibble is only the type mask)
    wire [19:0] code = (vbi_kind == 2'd2) ? 20'h8FFFF :     // VBI_CODE_LEADIN  0x88FFFF
                       (vbi_kind == 2'd3) ? 20'h0EEEE :     // VBI_CODE_LEADOUT 0x80EEEE
                                            vbi_dig;        // VBI_CODE_CAV_PICTURE | BCD
    wire        code_ok = vbi_valid && (vbi_kind != 2'd0);
    wire  [4:0] idx_m7  = vbi_idx - 5'd7;
    wire  [4:0] idx_m14 = vbi_idx - 5'd14;
    wire  [2:0] pos  = (vbi_idx < 5'd7)  ? vbi_idx[2:0] :
                       (vbi_idx < 5'd14) ? idx_m7[2:0] : idx_m14[2:0];
    wire        line16 = (vbi_idx >= 5'd14);
    reg  [7:0]  vb;
    always @(*) begin
        case (pos)
            3'd0: vb = 8'h09 | ((vbi_kind == 2'd1) ? 8'h02 : 8'h00);
            3'd1: vb = 8'h08;
            3'd2: vb = {4'h0, code[19:16]};
            3'd3: vb = {4'h0, code[15:12]};
            3'd4: vb = {4'h0, code[11:8]};
            3'd5: vb = {4'h0, code[7:4]};
            default: vb = {4'h0, code[3:0]};
        endcase
    end
    assign vbi_byte = (code_ok && !line16) ? vb : 8'h00;
    /* verilator lint_off UNUSED */
    wire unused_ok = &{1'b0, d4[3], idx_m7[4:3], idx_m14[4:3], ppi0_pc[7:2], ppi1_pb[7], ppi1_pb[1],
                       p_trk[16], mul_q[19:0], r0w[17:3]};
    /* verilator lint_on UNUSED */
endmodule
