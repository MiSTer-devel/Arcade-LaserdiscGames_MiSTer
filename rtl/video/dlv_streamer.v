//============================================================================
// dlv_streamer.v — .dlv block streamer (SD -> BRAM -> JPEG decoder + PCM audio)
//----------------------------------------------------------------------------
// Reads a mounted .dlv over the MiSTer hps_io block interface (sd_lba/sd_rd/
// sd_ack/sd_buff_*), parses the 512-byte header, and CONTINUOUSLY streams:
//   * VIDEO: free-running baseline-JPEG frames (paced ~30 fps) out to
//            jpeg_frame_decoder's byte feed, with a per-frame decoder reset.
//   * AUDIO: interleaved s16le stereo PCM from the audio blob into a ring
//            buffer, drained at 44.1 kHz to pcm_l/pcm_r for muxing with the AY.
// A SINGLE FSM owns the one SD slot and time-shares it: it keeps the audio ring
// topped up, and fetches the next video frame on the 30 fps tick only when the
// ring is comfortably full (audio has priority — an underrun is audible, a
// video hitch is not).  The 44.1 kHz consumer drains the ring in its own always
// block, so audio keeps playing even if the video decoder is wedged (this is
// what makes audio a valid isolation test of the file/stream path).
// .dlv header (little-endian, sector 0) — see pack_dlv.py:
//   [16] u32 frame_count  [48] u64 index_off  [64] u64 video_off
//   [80] u64 audio_off    [88] u64 audio_size
// frame index @ index_off: frame_count * { u32 off_in_video_blob, u32 size }.
// reworked from the one-shot fetcher into continuous
// video+audio (user directive — build the real streaming path, drop the hack).
//============================================================================
module dlv_streamer #(
    parameter [16:0] START_FRAME = 17'd1000,  // first film frame (skip black leader); free-runs from here
    // core clock rate, driven from CORE_CLK_HZ in Arcade-LaserdiscGames.sv.
    // Every clock-coupled constant below DERIVES from this -- do not re-hardcode 40e6.
    parameter [31:0] CLK_HZ      = 32'd80_000_000
)(
    input             clk,               // = CLK_CORE (rate given by the CLK_HZ parameter above)
    input             reset,             // active-high

    // --- HPS block/disk interface (-> hps_io sd_*[0], img_*) ---
    input             img_mounted,
    input      [63:0] img_size,
    output reg [31:0] sd_lba,
    output reg  [5:0] sd_blk_cnt,
    output reg        sd_rd,
    input             sd_ack,
    input       [8:0] sd_buff_addr,
    input       [7:0] sd_buff_dout,
    input             sd_buff_wr,

    // --- video byte stream out (-> jpeg_frame_decoder feed) ---
    output      [7:0] out_byte,
    output reg        out_valid,
    input             out_ready,
    output reg        out_last,

    // Per-frame decoder reset: route to jpeg_frame_decoder.rst ONLY, never fb_writer, or the
    // framebuffer re-clears every frame.
    output            dec_reset,

    // --- audio PCM out (44.1 kHz, s16 signed) -> mux with AY ---
    output reg signed [15:0] pcm_l,
    output reg signed [15:0] pcm_r,

    // LD disc frame (same clock). Video: fetch mapped mjpeg frame.
    // Audio: re-seek the ring on a SEARCH-sized jump.  pause: freeze audio playback (stay in sync).
    input      [16:0] ld_curr_frame,
    input             pause,

    // LD in PLAY mode AND both LDV1000 audio channels enabled.  Gates the ring DRAIN, not the
    // fill, so audio stays silent and the read pointer holds during PARK/SEARCH/STOP.
    input             ld_playing,

    // ---- authentic LD seek latency ----
    // A real player stalls visibly while the head moves and the games were built around that pause,
    // so hold BOTH streams on a seek, refill, then release them together.
    output            aud_primed,   // ring has enough buffered to resume cleanly
    input             hold_play,    // 1 = freeze audio playout (silence + HOLD aud_rd)
    // 1-cycle pulse on the Z80's SEARCH: EMPTIES the audio ring so the old segment's buffered
    // tail is discarded and the ring refills with only the new segment.
    input             seek_flush
);
    //------------------------------------------------------------------------
    // Compressed-frame BRAM (video)
    //------------------------------------------------------------------------
    // 15 -> 17 (32 KB -> 128 KB).
    // The q3 320x240 encode peaks at 30,051 B = 92% of the old 32 KB buffer, so ANY quality or
    // resolution increase overflowed it -- and the overflow is SILENT: `fbuf[bytes_got[FBUF_AW-1:0]]`
    // wraps and `frm_size[FBUF_AW-1:0]-1` truncates, feeding the decoder a corrupt JPEG with no
    // error anywhere. 128 KB costs ~77 M10K of the 348 free (block memory 26% -> ~39%) and covers
    // any 320x240 quality plus a later resolution bump. pack_dlv.py now hard-fails at pack time if a
    // frame does not fit, and names the FBUF_AW required.
    localparam FBUF_AW = 17;                 // 128 KB
    reg [7:0] fbuf [0:(1<<FBUF_AW)-1];
    reg [7:0] fbuf_q;
    assign out_byte = fbuf_q;

    //------------------------------------------------------------------------
    // Header fields
    //------------------------------------------------------------------------
    reg [31:0] index_off, video_off, frame_count;
    reg [31:0] aud_off, aud_size;
    // Per-game values from pack_dlv.py at header@24/@28 -- do NOT hardcode the leader.
    reg [31:0] ld_leader_off;   // header@28: disc frame where the captured content begins (was: LD_LEADER const)
    // header@24 is RESERVED=0 and this reg is repurposed for the v2 field.
    reg [31:0] spf_q16_hdr;     // header@96: samples per DISC frame, 16.16 fixed point (.dlv v2)
    reg        header_valid;

    // current frame index entry
    reg [31:0] frm_off, frm_size, frm_start;
    reg [16:0] cur_frame;                     // free-running film frame

    // Last mjpeg frame actually fetched/decoded/written; vid_target legitimately repeats.
    reg [16:0] last_fetched_frame;

    //------------------------------------------------------------------------
    // Audio ring buffer: 32-bit words, one stereo s16le sample per word
    //   word[15:0] = L (little-endian bytes 0,1), word[31:16] = R (bytes 2,3)
    // Simple dual-port: one write port (SD fill), one read port (44.1 kHz play).
    //------------------------------------------------------------------------
    localparam AUD_AW    = 12;                          // 4096 words = 16 KB = ~93 ms
    localparam [AUD_AW-1:0] FILL_HIGH = {AUD_AW{1'b1}} - 12'd128; // stop filling near-full
    localparam [AUD_AW-1:0] FILL_LOW  = 12'd2048;                 // require >= half before a video frame
    reg [31:0] aud_ring [0:(1<<AUD_AW)-1];
    reg [AUD_AW-1:0] aud_wr, aud_rd;
    wire [AUD_AW-1:0] aud_level = aud_wr - aud_rd;       // mod-2^AW occupancy (fill is capped so never wraps past)
    // "Enough audio buffered to resume after a seek" -- deliberately deeper than FILL_LOW so
    // playback resumes with margin rather than on the edge of underrun (~70 ms @ 44.1 kHz).
    localparam [AUD_AW-1:0] SEEK_FILL = 12'd3072;
    assign aud_primed = (aud_level >= SEEK_FILL);

    reg [23:0] aud_word_asm;                             // lanes 0..2 assembled during fill
    reg [31:0] aud_lba, aud_lba_start, aud_lba_end;      // audio sector cursor (+ loop bounds)

    //------------------------------------------------------------------------
    // Read engine FSM
    //------------------------------------------------------------------------
    localparam [3:0]
        S_IDLE     = 4'd0,
        S_HDR      = 4'd1,   // (unused label kept for dbg parity)
        S_READY    = 4'd2,   // arbiter/idle: top up audio, fetch a video frame on tick
        S_IDX      = 4'd3,   // read the index sector for cur_frame
        S_IDX_DONE = 4'd4,
        S_FRM_NEXT = 4'd5,   // read frame video sectors into fbuf
        S_STREAM   = 4'd6,   // fbuf -> decoder: issue read
        S_STRM_VLD = 4'd7,   // fbuf -> decoder: present byte
        S_AUD_DONE = 4'd8,   // audio sector captured -> advance aud_lba
        S_RD_ISSUE = 4'd9,   // generic: issue one sector read
        S_RD_XFER  = 4'd10;  // generic: capture the sector

    reg [3:0]  state, ret_state;
    reg [1:0]  cap_mode;                      // 0=header 1=index 2=frame 3=audio
    reg [31:0] cur_sec, sec_base_byte;
    reg [31:0] bytes_got;
    reg [8:0]  idx_in_sec;
    reg [FBUF_AW-1:0] stream_pos;

    reg  frame_fetch;                         // high while committing/fetching a frame

    //------------------------------------------------------------------------
    // Stall watchdog: any unbounded wait on an external handshake can hard-lock the whole video
    // and audio path, so the two that exist are bounded by a timeout that re-enters the arbiter.
    //------------------------------------------------------------------------
    localparam [23:0] WD_LIMIT = CLK_HZ / 32'd20;   // 50 ms at CLK_HZ (= 4,000,000 @ 80 MHz)
    reg  [23:0] wd_cnt;
    reg  [3:0]  wd_rst_cnt;                     // holds dec_reset for 16 clk after an abort
    reg  [3:0]  wd_state;                       // state that timed out
    reg  [16:0] wd_frame;                       // ld_curr_frame at the wedge
    reg  [15:0] wd_trips;                       // total aborts since reset
    wire        wd_rst  = (wd_rst_cnt != 4'd0);
    // Armed ONLY in the two genuinely unbounded waits -- S_RD_ISSUE (no transfer in flight yet)
    // and S_STRM_VLD (touches no SD state).  Both are safe to abandon.
    wire        wd_arm  = (state == S_RD_ISSUE) || (state == S_STRM_VLD);
    // any forward progress re-arms the timer: SD data landing, or a byte accepted
    wire        wd_prog = sd_buff_wr || (out_valid && out_ready);
    wire        wd_fire = (wd_cnt == WD_LIMIT);

    assign dec_reset = reset | frame_fetch | wd_rst;

    wire [31:0] idx_byte = index_off + {cur_frame, 3'b000};   // cur_frame*8

    //------------------------------------------------------------------------
    // 30 fps frame pacer + pending latch (single-driver on frame_pending)
    //------------------------------------------------------------------------
    // 🚨 was `localparam [20:0] FRAME_DIV = 21'd1333333;` / `reg [20:0] frame_cnt;`.
    // NOT in the upgrade recipe's table -- found by sweeping for "40e6".  At 80 MHz this is
    // 2666666, which needs 22 bits; [20:0] tops out at 2097151 so it would have SILENTLY truncated
    // to 569514 -- the 30 Hz pacer free-running at ~140 Hz, i.e. the watchdog re-fetch/re-mount
    // safety net hammering the fetch path.  Widened to [21:0]; form is exact at 40 MHz too.
    localparam [21:0] FRAME_DIV = (64'd1333333 * CLK_HZ) / 64'd40_000_000;   // CLK_HZ/30
    reg [21:0] frame_cnt;
    reg        frame_tick;
    reg        frame_pending;
    // Declared HERE so frame_pending's block can read it without a forward reference: this is a
    // .v file, elaborated as Verilog-2001.
    reg [16:0] vid_target_q;
    reg        vid_chg;
    // frame_start clears frame_pending only when a fetch actually starts -- testing S_READY's
    // intent alone consumed the tick on cycles where an earlier branch fetched nothing.
    wire       frame_start = (state == S_READY) && header_valid && frame_pending
                             && (aud_level >= FILL_LOW)
                             && !(img_mounted && (img_size != 64'd0));

    always @(posedge clk) begin
        frame_tick <= 1'b0;
        if (reset) frame_cnt <= FRAME_DIV;
        else if (frame_cnt == 22'd0) begin frame_cnt <= FRAME_DIV; frame_tick <= 1'b1; end
        else frame_cnt <= frame_cnt - 1'b1;
    end

    always @(posedge clk) begin
        if (reset) frame_pending <= 1'b0;
        else begin
    // The pacer must fire on CONTENT CHANGE, not free-run at 30 Hz: content advances at the film
    // rate, so a free-running tick fetches the same frame twice and then skips one.
            if (frame_tick || vid_chg) frame_pending <= 1'b1;
            if (frame_start) frame_pending <= 1'b0;   // clear wins if same cycle
        end
    end

    //------------------------------------------------------------------------
    // 44.1 kHz sample tick (fractional accumulator: exact average rate)
    //------------------------------------------------------------------------
    // was [25:0] ACC_INC/ACC_MOD/samp_acc with ACC_MOD = 26'd40000000.
    // 80,000,000 needs 27 bits and [25:0] tops out at 67,108,863 -- it would have silently
    // truncated (legal Verilog, clean lint) and destroyed the sample rate.  Widened to [27:0].
    localparam [27:0] ACC_INC = 28'd44100;
    localparam [27:0] ACC_MOD = CLK_HZ;              // one 44.1 kHz tick per CLK_HZ clocks
    reg [27:0] samp_acc;
    reg        samp_tick;
    always @(posedge clk) begin
        samp_tick <= 1'b0;
        if (reset) samp_acc <= 28'd0;
        else if (!pause) begin                       // freeze audio position on pause
            if (samp_acc + ACC_INC >= ACC_MOD) begin
                samp_acc  <= samp_acc + ACC_INC - ACC_MOD;
                samp_tick <= 1'b1;
            end else samp_acc <= samp_acc + ACC_INC;
        end
    end

    //------------------------------------------------------------------------
    // Audio ring WRITE port (SD fill): one word per 4 captured bytes
    //------------------------------------------------------------------------
    wire        aud_word_we = (state == S_RD_XFER) && (cap_mode == 2'd3)
                              && sd_buff_wr && (sd_buff_addr[1:0] == 2'd3);
    wire [31:0] aud_word     = {sd_buff_dout, aud_word_asm};   // {b3,b2,b1,b0}

    always @(posedge clk) begin
        if (reset) begin
            aud_wr <= {AUD_AW{1'b0}};
        // empty the ring's write side on a seek. Priority over the fill so
        // the pointer starts clean; the refill then begins from the re-pointed aud_lba.
        end else if (seek_flush) begin
            aud_wr <= {AUD_AW{1'b0}};
        end else if (aud_word_we) begin
            aud_ring[aud_wr] <= aud_word;
            aud_wr           <= aud_wr + 1'b1;
        end
    end

    //------------------------------------------------------------------------
    // Audio ring READ port (44.1 kHz play): registered read + underrun hold
    //------------------------------------------------------------------------
    reg [31:0] aud_rd_q;
    always @(posedge clk) aud_rd_q <= aud_ring[aud_rd];   // continuous registered read of current word

    // Disc frames 0..leader are the pre-content leader: nothing was captured there.
    wire on_leader = (ld_curr_frame < ld_leader);   // ld_leader now header-driven, see below

    // Computed from ACTUAL DATA COUNTS, not from mpeg_fpks -- that header field is unreliable
    // (Space Ace's is an impossible 41218).
    wire [31:0] spf_q = (frame_count != 32'd0) ? ((aud_size >> 2) / frame_count) : 32'd1842;
    wire [13:0] samp_per_frame = (header_valid && spf_q >= 32'd256 && spf_q <= 32'd8191)
                                 ? spf_q[13:0] : 14'd1842;   // fallback = DL's 1842

    // Slave the audio drain to the DISC FRAME POSITION rather than a free-running 44.1 kHz clock,
    // so audio and video share one master (the disc, which the Z80 controls) and cannot drift.
    reg  [16:0] aud_prev_frame;
    reg  [13:0] aud_credit;                       // samples the disc position currently permits
    // (coupled): 4 * SAMP_PER_TICK.
    localparam [13:0] AUD_CREDIT_MAX = 14'd7356;  // 4 frames -- anti-burst cap on catch-up
    wire [16:0] aud_fadv  = ld_curr_frame - aud_prev_frame;    // unsigned; a large value = a jump
    wire        aud_jump  = (aud_fadv > 17'd2);                // >2 frames/cycle = seek, not 1x play
    wire        aud_muted = hold_play || !ld_playing || on_leader || !header_valid;
    wire        aud_drain = samp_tick && (aud_wr != aud_rd) && (aud_credit != 14'd0) && !aud_muted;

    // ---- audio drain rate ----------------------------------------------------------------
    // SAMP_PER_TICK must be the FILM rate, not the container's nominal rate.
    localparam [13:0] SAMP_PER_TICK = 14'd1839;   // 44100/23.976
    //                         (aud_fadv == 17'd1) ? {1'b0, samp_per_frame} :
    //                         (aud_fadv == 17'd2) ? {samp_per_frame, 1'b0} : 15'd0;
    wire [14:0] aud_add   = (aud_jump)          ? 15'd0 :                  // SAMP_PER_TICK per frame
                            (aud_fadv == 17'd1) ? {1'b0, SAMP_PER_TICK} :
                            (aud_fadv == 17'd2) ? {SAMP_PER_TICK, 1'b0} : 15'd0;
    wire [15:0] aud_cred_nx  = {2'b0, aud_credit} + {1'b0, aud_add} - (aud_drain ? 16'd1 : 16'd0);
    wire [13:0] aud_cred_cap = (aud_cred_nx > {2'b0, AUD_CREDIT_MAX}) ? AUD_CREDIT_MAX : aud_cred_nx[13:0];

    always @(posedge clk) begin
        if (reset) begin
            aud_rd <= {AUD_AW{1'b0}};
            pcm_l  <= 16'sd0;
            pcm_r  <= 16'sd0;
            aud_prev_frame <= 17'd0;
            aud_credit     <= 14'd0;
        // Empty the ring's read side on a seek (matches the aud_wr flush) so the stale tail is
        // discarded and drain resumes at the new segment's first sample.
        end else if (seek_flush) begin
            aud_rd <= {AUD_AW{1'b0}};
            pcm_l  <= 16'sd0;
            pcm_r  <= 16'sd0;
            aud_prev_frame <= ld_curr_frame;
            aud_credit     <= 14'd0;
        end else begin
            // credit + prev_frame advance EVERY cycle (independent of the
            // mute/drain branch below). A frame jump auto-flushes the credit.
            aud_prev_frame <= ld_curr_frame;
            aud_credit     <= aud_jump ? 14'd0 : aud_cred_cap;

    // Not PLAYing / on the leader / header not parsed / seek hold -> silence, and HOLD aud_rd so
    // playback resumes from the same point.  !header_valid is load-bearing: ld_leader_off powers
    // up ~0, which would read as on_leader.
            if (aud_muted) begin
                pcm_l <= 16'sd0;
                pcm_r <= 16'sd0;
            end else if (aud_drain) begin   // FRAME-LOCK: 44.1 kHz drain, but only while the disc
                pcm_l  <= aud_rd_q[15:0];    // position has "paid" for the sample (aud_credit != 0).
                pcm_r  <= aud_rd_q[31:16];   // Disc stalls -> credit hits 0 -> audio holds with it.
                aud_rd <= aud_rd + 1'b1;
            end
            // underrun (empty OR out of credit while playing): hold last pcm
        end
    end

    //------------------------------------------------------------------------
    // disc frame -> video-frame + audio-sector maps, SEARCH-jump detect
    //------------------------------------------------------------------------

    // header@28 is a SIGNED s32 -- Thayer's Quest is -16 (its capture begins before disc frame 0).
    // Read unsigned it becomes 131056 and the disc never leaves the leader.
    wire signed [31:0] ld_leader_s = ld_leader_off;
    wire [16:0] ld_leader  = (ld_leader_s <= 32'sd0)      ? 17'd0     :
                             (ld_leader_s > 32'sd131071)  ? 17'h1FFFF : ld_leader_s[16:0];
    wire signed [31:0] disc_rel_s = $signed({15'd0, ld_curr_frame}) - ld_leader_s;
    wire [16:0] disc_rel   = (disc_rel_s <= 32'sd0)       ? 17'd0     :
                             (disc_rel_s > 32'sd131071)   ? 17'h1FFFF : disc_rel_s[16:0];

    // EXACT audio seek re-point: samp_per_frame is an integer divide, so re-pointing by
    // multiplication accumulates its error linearly with frame number (~6 ms per 1000 frames).
    // Use the Q16 fractional form instead.
    wire        spf_hdr_ok = header_valid && (spf_q16_hdr >= 32'd1048576)      // >= 16.0 samp/frame
                                          && (spf_q16_hdr <  32'd134217728);   // <  2048.0
    wire [29:0] spf_q16    = spf_hdr_ok ? spf_q16_hdr[29:0] : {samp_per_frame, 16'd0};

    // audio target sector = aud_lba_start + (disc_rel * samples_per_frame) / 128 samples-per-sector
    // >>16 undoes the Q16 scaling and >>7 converts samples to sectors, hence >>23.
    wire [46:0] aud_prod_q16   = disc_rel * spf_q16;
    wire [31:0] aud_target_lba = aud_lba_start + {8'd0, aud_prod_q16[46:23]};

    localparam [31:0] DISC_FPKS = 32'd29970;

    // disc -> video is 1:1: video_frame = disc_frame - ld_leader = disc_rel.  HW-evidenced.
    wire [16:0] vid_ratio  = disc_rel;                       // 1:1, per Daphne's framefile
    wire [16:0] vid_target = (vid_ratio >= frame_count[16:0]) ? (frame_count[16:0] - 17'd1) : vid_ratio;

    // 1-cycle pulse when the mapped frame changes.  Declared up with the pacer regs; driven
    // here, where vid_target exists.
    always @(posedge clk) begin
        if (reset) begin
            vid_target_q <= {17{1'b1}};
            vid_chg      <= 1'b0;
        end else begin
            vid_target_q <= vid_target;
            vid_chg      <= (vid_target != vid_target_q);
        end
    end

    // SEARCH-sized jump detect: PLAY advances +1/frame -> no jump; SEARCH ramps in big steps -> jump.
    reg  [16:0] prev_ld;
    always @(posedge clk) prev_ld <= ld_curr_frame;
    wire [16:0] fdiff  = (ld_curr_frame > prev_ld) ? (ld_curr_frame - prev_ld) : (prev_ld - ld_curr_frame);
    wire        jump_w = (fdiff > 17'd16);

    reg  seek_req;
    wire seek_consume = (state == S_READY) && header_valid && seek_req;
        // Both ifs live in ONE always block, so if jump_w and seek_consume coincide the last
        // assignment wins and the jump is silently lost.  Keep them mutually exclusive.
    reg  seek_armed;
    wire jump_any = (ld_curr_frame != prev_ld);
    always @(posedge clk) begin
        if (reset) begin
            seek_req   <= 1'b0;
            seek_armed <= 1'b0;
        end else begin
            if (seek_flush) seek_armed <= 1'b1;                 // CMD_SEARCH: arm (the ONLY trigger)
            if (seek_armed && jump_any) begin
                seek_req   <= 1'b1;                             // commanded frame landed -> re-point
                seek_armed <= 1'b0;
            end else if (seek_consume) seek_req <= 1'b0;
        end
    end

        // The consume cycle re-points aud_lba with a NONBLOCKING assign, so the fill branch in the
        // same cycle would read the OLD sector -- use the re-pointed value explicitly.
    wire [31:0] aud_lba_tgt = (aud_target_lba >= aud_lba_end) ? (aud_lba_end - 32'd1) : aud_target_lba;
    wire [31:0] aud_lba_eff = seek_consume ? aud_lba_tgt : aud_lba;

    //------------------------------------------------------------------------
    // Main SD/stream FSM
    //------------------------------------------------------------------------
    always @(posedge clk) begin
        if (reset) begin
            state <= S_IDLE;
            sd_rd <= 1'b0; sd_lba <= 32'd0; sd_blk_cnt <= 6'd0;
            out_valid <= 1'b0; out_last <= 1'b0;
            header_valid <= 1'b0; frame_fetch <= 1'b0;
            // 0 => "absent", so a v1 image deterministically takes the
            // samp_per_frame fallback instead of powering up on an undefined value.
            spf_q16_hdr  <= 32'd0;
            cur_frame <= 17'd0;
    // Sentinel, not 0: a real vid_target of 0 is legitimate (first mapped frame).
            last_fetched_frame <= {17{1'b1}};
            wd_cnt <= 24'd0; wd_rst_cnt <= 4'd0;   // wd_cnt widened 22->24
            wd_state <= 4'd0; wd_frame <= 17'd0; wd_trips <= 16'd0;
        end else begin
            // run the timer BEFORE the case, so a state change or a
            // progress event inside the case re-arms it on the NEXT cycle rather than this one.
            if (!wd_arm || wd_prog)     wd_cnt <= 24'd0;
            else if (wd_cnt != WD_LIMIT) wd_cnt <= wd_cnt + 24'd1;
            if (wd_rst_cnt != 4'd0)      wd_rst_cnt <= wd_rst_cnt - 4'd1;

            case (state)
            // ---- wait for image, then read header sector 0 ----
            S_IDLE: begin
                if (img_mounted && img_size != 0) begin
                    cap_mode <= 2'd0; cur_sec <= 32'd0; ret_state <= S_READY;
                    header_valid <= 1'b0;
                    state <= S_RD_ISSUE;
                end
            end

            // ---- arbiter/idle: keep audio full; fetch a frame on the 30 fps tick ----
            S_READY: begin
                frame_fetch <= 1'b0;
            // The audio re-point neither changes `state` nor uses the SD port, so it must not sit
            // in the else-if chain where it would block the video fetch for that cycle.
                if (header_valid && seek_req)
                    aud_lba <= aud_lba_tgt;

                if (!header_valid) begin
                    // one-time init once the header sector has been latched
                    header_valid  <= 1'b1;
                    aud_lba       <= aud_off  >> 9;
                    aud_lba_start <= aud_off  >> 9;
                    aud_lba_end   <= (aud_off + aud_size) >> 9;
            // Init from vid_target, not a constant: this re-fires on every re-mount.
                    cur_frame     <= vid_target;
            // SEARCH jump -> re-point audio to the mapped sector.  The ring keeps playing, so the
            // new scene's audio lands after about one ring depth.
                end else if (img_mounted && img_size != 0) begin
                    // re-mount: re-read header
                    cap_mode <= 2'd0; cur_sec <= 32'd0; ret_state <= S_READY;
                    header_valid <= 1'b0;
                    state <= S_RD_ISSUE;
                end else if (frame_pending && (aud_level >= FILL_LOW)) begin
            // Only fetch/decode/write if the mapped mjpeg frame has genuinely changed.
                    if (vid_target != last_fetched_frame) begin
                        // ---- start a video frame fetch (audio comfortable) ----
                        frame_fetch        <= 1'b1;      // decoder held in reset through the fetch
                        cur_frame          <= vid_target;   // HLE-DRIVE: fetch the mapped mjpeg frame
                        last_fetched_frame <= vid_target;
                        state <= S_IDX;
                    end
                end else if (aud_level < FILL_HIGH) begin
                    // ---- top up the audio ring: read one audio sector ----
                    // PRE-re-point sector on the consume cycle and skipped the seek target.
                    cur_sec  <= aud_lba_eff;
                    cap_mode <= 2'd3; ret_state <= S_AUD_DONE;
                    state <= S_RD_ISSUE;
                end
            end

            // ---- read the index sector holding entry cur_frame ----
            S_IDX: begin
                cur_sec    <= idx_byte[31:9];
                idx_in_sec <= idx_byte[8:0];
                cap_mode   <= 2'd1; ret_state <= S_IDX_DONE;
                state <= S_RD_ISSUE;
            end
            S_IDX_DONE: begin
                frm_start <= video_off + frm_off;
                bytes_got <= 32'd0;
                cur_sec   <= (video_off + frm_off) >> 9;
                cap_mode  <= 2'd2; ret_state <= S_FRM_NEXT;
                state <= S_RD_ISSUE;
            end

            // ---- read frame sectors into fbuf until fsize captured ----
            S_FRM_NEXT: begin
                if (bytes_got >= frm_size) begin
                    stream_pos <= 0; out_last <= 1'b0; out_valid <= 1'b0;
                    frame_fetch <= 1'b0;          // release decoder reset -> streaming begins
                    state <= S_STREAM;
                end else begin
                    cur_sec  <= cur_sec + 1'b1;
                    cap_mode <= 2'd2; ret_state <= S_FRM_NEXT;
                    state <= S_RD_ISSUE;
                end
            end

            // ---- stream fbuf[0..fsize-1] -> decoder (registered read) ----
            S_STREAM: begin
                fbuf_q   <= fbuf[stream_pos];
                out_last <= (stream_pos == frm_size[FBUF_AW-1:0] - 1'b1);
                state    <= S_STRM_VLD;
            end
            S_STRM_VLD: begin
                out_valid <= 1'b1;
                if (out_valid && out_ready) begin
                    out_valid <= 1'b0;
                    if (out_last) begin
                        out_last  <= 1'b0;
                        state     <= S_READY;   // HLE-DRIVE: next frame = vid_target(ld_curr_frame), set at fetch
                    end else begin
                        stream_pos <= stream_pos + 1'b1;
                        state      <= S_STREAM;
                    end
                end
            end

            // ---- audio sector captured: advance the audio sector cursor (loop) ----
            S_AUD_DONE: begin
                aud_lba <= (aud_lba + 1'b1 >= aud_lba_end) ? aud_lba_start : aud_lba + 1'b1;
                state   <= S_READY;
            end

            // ================= generic single-sector read =================
            S_RD_ISSUE: begin
                sd_lba        <= cur_sec;
                sd_blk_cnt    <= 6'd0;
                sec_base_byte <= {cur_sec, 9'd0};
                sd_rd         <= 1'b1;
                if (sd_ack) begin
                    sd_rd <= 1'b0;
                    state <= S_RD_XFER;
                end
            end
            S_RD_XFER: begin
                if (sd_buff_wr) begin
                    case (cap_mode)
                    2'd0: begin // header
                        case (sd_buff_addr)
                        9'd16: frame_count[7:0]   <= sd_buff_dout;
                        9'd17: frame_count[15:8]  <= sd_buff_dout;
                        9'd18: frame_count[23:16] <= sd_buff_dout;
                        9'd19: frame_count[31:24] <= sd_buff_dout;
                    // @24 is RESERVED=0; the v2 field below replaces it.
                        9'd96:  spf_q16_hdr[7:0]   <= sd_buff_dout;   // samples/disc-frame, Q16
                        9'd97:  spf_q16_hdr[15:8]  <= sd_buff_dout;
                        9'd98:  spf_q16_hdr[23:16] <= sd_buff_dout;
                        9'd99:  spf_q16_hdr[31:24] <= sd_buff_dout;
                        9'd28: ld_leader_off[7:0]  <= sd_buff_dout;
                        9'd29: ld_leader_off[15:8] <= sd_buff_dout;
                        9'd30: ld_leader_off[23:16]<= sd_buff_dout;
                        9'd31: ld_leader_off[31:24]<= sd_buff_dout;
                        9'd48: index_off[7:0]     <= sd_buff_dout;
                        9'd49: index_off[15:8]    <= sd_buff_dout;
                        9'd50: index_off[23:16]   <= sd_buff_dout;
                        9'd51: index_off[31:24]   <= sd_buff_dout;
                        9'd64: video_off[7:0]     <= sd_buff_dout;
                        9'd65: video_off[15:8]    <= sd_buff_dout;
                        9'd66: video_off[23:16]   <= sd_buff_dout;
                        9'd67: video_off[31:24]   <= sd_buff_dout;
                        9'd80: aud_off[7:0]       <= sd_buff_dout;
                        9'd81: aud_off[15:8]      <= sd_buff_dout;
                        9'd82: aud_off[23:16]     <= sd_buff_dout;
                        9'd83: aud_off[31:24]     <= sd_buff_dout;
                        9'd88: aud_size[7:0]      <= sd_buff_dout;
                        9'd89: aud_size[15:8]     <= sd_buff_dout;
                        9'd90: aud_size[23:16]    <= sd_buff_dout;
                        9'd91: aud_size[31:24]    <= sd_buff_dout;
                        default: ;
                        endcase
                    end
                    2'd1: begin // index entry (8 B at idx_in_sec)
                        if (sd_buff_addr == idx_in_sec + 9'd0) frm_off[7:0]    <= sd_buff_dout;
                        if (sd_buff_addr == idx_in_sec + 9'd1) frm_off[15:8]   <= sd_buff_dout;
                        if (sd_buff_addr == idx_in_sec + 9'd2) frm_off[23:16]  <= sd_buff_dout;
                        if (sd_buff_addr == idx_in_sec + 9'd3) frm_off[31:24]  <= sd_buff_dout;
                        if (sd_buff_addr == idx_in_sec + 9'd4) frm_size[7:0]   <= sd_buff_dout;
                        if (sd_buff_addr == idx_in_sec + 9'd5) frm_size[15:8]  <= sd_buff_dout;
                        if (sd_buff_addr == idx_in_sec + 9'd6) frm_size[23:16] <= sd_buff_dout;
                        if (sd_buff_addr == idx_in_sec + 9'd7) frm_size[31:24] <= sd_buff_dout;
                    end
                    2'd2: begin // frame bytes -> fbuf
                        if ((sec_base_byte + sd_buff_addr) >= frm_start && bytes_got < frm_size) begin
                            fbuf[bytes_got[FBUF_AW-1:0]] <= sd_buff_dout;
                            bytes_got <= bytes_got + 1'b1;
                        end
                    end
                    2'd3: begin // audio bytes -> assemble words (write on lane 3, see aud_word_we)
                        case (sd_buff_addr[1:0])
                        2'd0: aud_word_asm[7:0]   <= sd_buff_dout;
                        2'd1: aud_word_asm[15:8]  <= sd_buff_dout;
                        2'd2: aud_word_asm[23:16] <= sd_buff_dout;
                        2'd3: ;   // 4th byte + write handled by aud_word_we always block
                        endcase
                    end
                    default: ;
                    endcase
                end
                if (!sd_ack) state <= ret_state;   // sector transfer complete
            end
            default: state <= S_IDLE;
            endcase

    // Watchdog abort, placed AFTER the case so its assignments win: drops the in-flight frame
    // and re-enters the arbiter cleanly.
            if (wd_fire) begin
                wd_state  <= state;
                wd_frame  <= ld_curr_frame;
                wd_trips  <= wd_trips + 16'd1;
                wd_cnt    <= 24'd0;
                wd_rst_cnt<= 4'd15;
                sd_rd     <= 1'b0;
                out_valid <= 1'b0;
                out_last  <= 1'b0;
                last_fetched_frame <= {17{1'b1}};
                state     <= S_READY;
            end
        end
    end

endmodule
