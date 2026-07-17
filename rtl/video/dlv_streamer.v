//============================================================================
// dlv_streamer.v — .dlv block streamer (SD -> BRAM -> JPEG decoder + PCM audio)
//----------------------------------------------------------------------------
// Reads a mounted .dlv over the MiSTer hps_io block interface (sd_lba/sd_rd/
// sd_ack/sd_buff_*), parses the 512-byte header, and CONTINUOUSLY streams:
//   * VIDEO: free-running baseline-JPEG frames (paced ~30 fps) out to
//            jpeg_frame_decoder's byte feed, with a per-frame decoder reset.
//   * AUDIO: interleaved s16le stereo PCM from the audio blob into a ring
//            buffer, drained at 44.1 kHz to pcm_l/pcm_r for muxing with the AY.
//
// A SINGLE FSM owns the one SD slot and time-shares it: it keeps the audio ring
// topped up, and fetches the next video frame on the 30 fps tick only when the
// ring is comfortably full (audio has priority — an underrun is audible, a
// video hitch is not).  The 44.1 kHz consumer drains the ring in its own always
// block, so audio keeps playing even if the video decoder is wedged (this is
// what makes audio a valid isolation test of the file/stream path).
//
// .dlv header (little-endian, sector 0) — see pack_dlv.py:
//   [16] u32 frame_count  [48] u64 index_off  [64] u64 video_off
//   [80] u64 audio_off    [88] u64 audio_size
// frame index @ index_off: frame_count * { u32 off_in_video_blob, u32 size }.
//
// STREAMING-2026-07-04: reworked from the one-shot fetcher into continuous
// video+audio (user directive — build the real streaming path, drop the hack).
//============================================================================
module dlv_streamer #(
    parameter [16:0] START_FRAME = 17'd1000   // first film frame (skip black leader); free-runs from here
)(
    input             clk,               // = CLK_40M
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

    // --- per-frame decoder reset: assert while fetching a frame, deassert as
    //     streaming begins.  Route to jpeg_frame_decoder.rst ONLY (NOT fb_writer,
    //     or the framebuffer would re-clear every frame). ---
    output            dec_reset,

    // --- audio PCM out (44.1 kHz, s16 signed) -> mux with AY ---
    output reg signed [15:0] pcm_l,
    output reg signed [15:0] pcm_r,

    // HLE-DRIVE-2026-07-04: LD disc frame (same clock). Video: fetch mapped mjpeg frame.
    // Audio: re-seek the ring on a SEARCH-sized jump.  pause: freeze audio playback (stay in sync).
    input      [16:0] ld_curr_frame,
    input             pause,

    // AUDIO-GATE-2026-07-05: 1 = LD in PLAY mode AND both LDV1000 AUDIO1/2 channels enabled
    // (AUDIO-CMD-2026-07-05, real game-driven mute -- CMD_AUDIO1/CMD_AUDIO2). Gates the ring
    // DRAIN (not the fill) so audio stays silent + the read pointer holds during PARK/SEARCH/STOP
    // or an explicit AUDIO-off command, instead of free-running from the blob start the instant
    // the .dlv mounts (was: audible immediately, wrong scene at PLAY).
    input             ld_playing
);
    //------------------------------------------------------------------------
    // Compressed-frame BRAM (video)
    //------------------------------------------------------------------------
    localparam FBUF_AW = 15;                 // 32 KB (largest q3 320x240 JPEG ~24 KB)
    reg [7:0] fbuf [0:(1<<FBUF_AW)-1];
    reg [7:0] fbuf_q;
    assign out_byte = fbuf_q;

    //------------------------------------------------------------------------
    // Header fields
    //------------------------------------------------------------------------
    reg [31:0] index_off, video_off, frame_count;
    reg [31:0] aud_off, aud_size;
    // HEADER-FIELDS-2026-07-05: pack_dlv.py already computes + stores these per-game (from the
    // Daphne framefile + the real measured audio duration) at header@24/@28 -- previously parsed by
    // NOTHING, so the RTL hardcoded LD_LEADER=151 (right for DL by luck only) and a 1:1 video ratio
    // (known wrong per the handoff, root cause was just never traced back to "read the header field").
    reg [31:0] ld_leader_off;   // header@28: disc frame where the captured content begins (was: LD_LEADER const)
    reg [31:0] mpeg_fpks;       // header@24: this capture's true fps*1000, scales vid_target (VIDEO-RATIO-2026-07-05)
    reg        header_valid;

    // current frame index entry
    reg [31:0] frm_off, frm_size, frm_start;
    reg [16:0] cur_frame;                     // free-running film frame

    // REDUNDANT-REDRAW-FIX-2026-07-15: last mjpeg frame index actually fetched/decoded/written.
    // mpeg_fpks (this capture's true fps, e.g. 23.938 for DL) is LOWER than both the 30Hz pacing
    // tick below and the 29.97fps disc rate, so vid_target legitimately repeats the SAME value
    // across several consecutive ticks -- without this check, every one of those repeats still
    // re-fetched/re-decoded/re-wrote the IDENTICAL frame to DDR, redundantly flipping fb_buf_sel
    // and hammering fb_writer with a fresh 76800-pixel write pass for content that hadn't changed
    // at all. User's diagnosis (2026-07-15): "the problem is too much data is being thrown at it,
    // and it's getting out of sync and freaking out" -- this was the actual source of the
    // black-line-comb/roll/resolution-flicker bugs, not a raster-read-side throughput deficit.
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
    assign dec_reset = reset | frame_fetch;   // per-frame decoder reset (decoder only)

    wire [31:0] idx_byte = index_off + {cur_frame, 3'b000};   // cur_frame*8

    //------------------------------------------------------------------------
    // 30 fps frame pacer + pending latch (single-driver on frame_pending)
    //------------------------------------------------------------------------
    localparam [20:0] FRAME_DIV = 21'd1333333;   // 40e6/30
    reg [20:0] frame_cnt;
    reg        frame_tick;
    reg        frame_pending;
    wire       frame_start = (state == S_READY) && header_valid && frame_pending
                             && (aud_level >= FILL_LOW);

    always @(posedge clk) begin
        frame_tick <= 1'b0;
        if (reset) frame_cnt <= FRAME_DIV;
        else if (frame_cnt == 21'd0) begin frame_cnt <= FRAME_DIV; frame_tick <= 1'b1; end
        else frame_cnt <= frame_cnt - 1'b1;
    end

    always @(posedge clk) begin
        if (reset) frame_pending <= 1'b0;
        else begin
            if (frame_tick)  frame_pending <= 1'b1;
            if (frame_start) frame_pending <= 1'b0;   // clear wins if same cycle
        end
    end

    //------------------------------------------------------------------------
    // 44.1 kHz sample tick (fractional accumulator: exact average rate)
    //------------------------------------------------------------------------
    localparam [25:0] ACC_INC = 26'd44100;
    localparam [25:0] ACC_MOD = 26'd40000000;
    reg [25:0] samp_acc;
    reg        samp_tick;
    always @(posedge clk) begin
        samp_tick <= 1'b0;
        if (reset) samp_acc <= 26'd0;
        else if (!pause) begin                       // HLE-DRIVE-2026-07-04: freeze audio position on pause
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

    // LEADER-GATE-2026-07-05: dlair.txt (Daphne framefile) says disc frame 151 is where the ONE
    // captured mpeg begins -- frames 0..150 are the pre-content leader, nothing was captured there.
    // ld_curr_frame starts at 0 and free-runs up through the leader during the very first PLAY at
    // boot, so without this the disc_rel clamp-to-0 (below) aliases the whole 5s leader traversal
    // to "frame 0 of real content" and plays the movie's true opening audio 5s early.
    wire on_leader = (ld_curr_frame < ld_leader);   // ld_leader now header-driven, see HEADER-FIELDS-2026-07-05 below

    always @(posedge clk) begin
        if (reset) begin
            aud_rd <= {AUD_AW{1'b0}};
            pcm_l  <= 16'sd0;
            pcm_r  <= 16'sd0;
        end else if (!ld_playing || on_leader || !header_valid) begin
            // AUDIO-GATE-2026-07-05: not PLAYing (PARK/SEARCH/STOP), OR still on the pre-content
            // leader, OR the header hasn't been parsed yet -> silence, and HOLD aud_rd so playback
            // resumes from the same point instead of having drained ahead while muted. (The fill
            // side still tops the ring up in the background, capped at FILL_HIGH.)
            // HEADER-FIELDS-2026-07-05: !header_valid is load-bearing, not defensive filler --
            // ld_leader_off has no reset value, so before the .dlv is mounted+parsed it powers up
            // ~0, making on_leader permanently FALSE (ld_curr_frame can't be < 0). Every other header
            // field in this file is protected because its only consumer already checks header_valid
            // first (see S_READY); this one wasn't, so the leader-mute silently did nothing for
            // however long boot-to-mount takes -- exactly the "still plays too early" window.
            pcm_l <= 16'sd0;
            pcm_r <= 16'sd0;
        end else if (samp_tick && (aud_wr != aud_rd)) begin   // sample due & not empty
            pcm_l  <= aud_rd_q[15:0];      // aud_rd steady ~907 cyc -> aud_rd_q settled to current word
            pcm_r  <= aud_rd_q[31:16];
            aud_rd <= aud_rd + 1'b1;
        end
        // underrun (empty at tick while playing): hold last pcm
    end

    //------------------------------------------------------------------------
    // HLE-DRIVE-2026-07-04: disc frame -> video-frame + audio-sector maps, SEARCH-jump detect
    //------------------------------------------------------------------------
    // HEADER-FIELDS-2026-07-05: LD_LEADER used to be a hardcoded 17'd151 constant (right for DL by
    // luck); now reads header@28 (ld_leader_off), which pack_dlv.py computes per-game from that
    // game's own Daphne framefile -- Space Ace / Thayer's Quest will have their own real values.
    // AUDIO-TIMEBASE-FIX-2026-07-16: was 12'd1471 (= 44100/29.97). Uncomment to revert.
    // localparam [11:0] SAMP_PER_FRAME = 12'd1471;    // 44100 / 29.97 samples per disc frame
    //
    // The audio map MUST share a timebase with the video map, and ONE-TO-ONE-FIX-2026-07-16
    // changed the video's. They used to agree BY ACCIDENT -- both were wrong in the same way:
    //     old video: vid = disc_rel*mpeg/disc  -> position in the m2v = disc_rel/29.97 s
    //     audio:     disc_rel*1471 samples     -> position           = disc_rel/29.97 s   (agreed)
    // Now video is 1:1 (vid = disc_rel), so the video sits at disc_rel/23.938 s while 1471 still
    // points the audio at disc_rel/29.97 s => they diverge ~25% and every seek re-lands them apart
    // (HW-observed 2026-07-16: "audio is getting out of sync again on seeks").
    //
    // One video frame is now one DISC frame, and the m2v runs at 23.938fps, so a disc frame is
    // worth 44100/23.938 = 1842.26 samples. The header agrees independently -- this is NOT a
    // fudge factor: total_samples/frame_count = 81343495/44154 = 1842.28 for DL.
    //
    // Corroboration: at 1471, disc_rel*1471 over all 44154 frames reaches only ~79% of the audio
    // blob -- 21% of the track was UNREACHABLE. At 1842 it spans it almost exactly. The blob was
    // packed for 1842.
    //
    // ⚠️ NOT PER-GAME YET -- 1842 is DL's value. The correct general form is
    // round(total_samples/frame_count), both of which are already in the header (@40 and @16), so
    // this should become header-derived before Space Ace / Thayer's Quest (whose ratios differ, and
    // whose containers are separately known-bad -- see the pack_dlv.py mpeg_fpks note in the vault).
    // Hardcoded for now to keep this a one-variable change against the 1:1 fix.
    //
    // Precision: 1842 vs 1842.28 drifts 0.28 samples/frame, but every SEARCH re-points aud_lba
    // (seek_req -> aud_target_lba), so drift only accumulates within one scene: ~11 ms over a 60 s
    // continuous play. Inaudible. Widths unchanged: SAMP_PER_FRAME still fits 12 bits (1842<4095),
    // and disc_rel*1842 max 241M still fits aud_prod's 32 bits.
    localparam [11:0] SAMP_PER_FRAME = 12'd1842;    // 44100 / 23.938 = total_samples/frame_count

    wire [16:0] ld_leader = ld_leader_off[16:0];
    wire [16:0] disc_rel = (ld_curr_frame > ld_leader) ? (ld_curr_frame - ld_leader) : 17'd0;

    // audio target sector = aud_lba_start + (disc_rel * 1471 samples) / 128 samples-per-sector
    wire [31:0] aud_prod       = disc_rel * SAMP_PER_FRAME;
    wire [31:0] aud_target_lba = aud_lba_start + (aud_prod >> 7);

    // VIDEO-RATIO-2026-07-05: real ratio applied (was a 1:1 placeholder). video_frame =
    // round(disc_rel * mpeg_fpks / DISC_FPKS). mpeg_fpks is header@24 (this capture's true
    // fps*1000, e.g. DL = 23938); DISC_FPKS = 29970 (29.97 fps NTSC, fixed -- pack_dlv.py always
    // writes the disc side at this rate, see the disc_fpks/srate/chans note above). mpeg_fpks is
    // truncated to 17 bits (any real fps*1000 comfortably fits; header garbage is caught by the
    // frame_count clamp below regardless). +DISC_FPKS/2 before the divide = round-to-nearest, not
    // truncate. User-accepted tradeoff: this is a real runtime 32-bit-class divide (mpeg_fpks is
    // not a compile-time constant) whose LE/timing cost is UNVERIFIED until compiled -- can't be
    // tested against real video yet either (decoder still separately broken). If STA flags this
    // path, it's the first place to look; NOT a cosmetic CE-gated warning (see
    // feedback_dont_rathole_timing) since there's no clock-enable gating this combinational logic.
    localparam [31:0] DISC_FPKS = 32'd29970;

    //------------------------------------------------------------------------
    // ONE-TO-ONE-FIX-2026-07-16 -- HW-EVIDENCED (two exact, independent predictions).
    //
    // disc -> video is **1:1**:   video_frame = disc_frame - ld_leader = disc_rel
    //
    // The fps-RATIO map below (VIDEO-RATIO-2026-07-05) is a FABRICATION and was the
    // "seeks to entirely the wrong frame" bug.  Its own comment called the 1:1 code it
    // replaced "a 1:1 placeholder" -- it was not a placeholder, it was CORRECT.
    //
    // AUTHORITY: Daphne's framefile IS the disc->film map, and it is a single offset:
    //     _Arcade/laserdiscs/dragonslair/dlair.txt  ->  "151  lair.m2v"
    // Daphne's VLDP seeks the m2v BY FRAME NUMBER, so mpeg_frame = disc_frame - 151.
    // There is no time/fps scaling anywhere in Daphne's model, because the m2v is
    // captured frame-per-frame off the disc.  (Our whole asset chain is Daphne-derived;
    // MAME is NOT a valid reference here -- it reads frame numbers from disc VBI/gap
    // data that our .dlv does not encode at all.)
    //
    // HW EVIDENCE (2026-07-16, user browsed the .dlv with _Arcade/laserdiscs/browse_dlv.py
    // and visually identified each screen -- both predictions made BEFORE the lookup):
    //     FPGA showed video 36  => ratio map implies DL asked disc 196 => 1:1 predicts 45
    //                              -> video 45 IS the "insert coins" screen.   EXACT
    //     FPGA showed video 124 => ratio map implies DL asked disc 306 => 1:1 predicts 155
    //                              -> video 155 IS the "instructions" screen.  EXACT
    // The error was 0 at the leader and grew linearly with frame number, which is exactly
    // why the first attract seek always "worked" and everything deeper was wrong.
    //
    // WHY THE "attract timing is correct" OBSERVATION DID NOT CONTRADICT THIS: the attract
    // LOOP is paced by the Z80's own script and by curr_frame advancing at 29.97 via the
    // LD-V1000's frame_tick -- neither depends on this map.  Only the fetched CONTENT did.
    //
    // DEAD CONSTANTS AFTER THIS FIX (verified by grep, not assumed):
    //   * `mpeg_fpks` (header@24) is now WRITTEN by the header parser and never READ.  It
    //     reads 23938 for DL, which pack_dlv.py:119 derives by ASSUMING audio duration ==
    //     video duration -- the same bad assumption that gives Space Ace an impossible
    //     41.218fps.  **Do not resurrect it as a video scaler.**  Left parsed only because
    //     it is part of the on-disk header layout.
    //   * `DISC_FPKS` is now referenced ONLY by its own localparam below -- fully dead.
    //     Both may draw "unused" warnings from Quartus; that is expected, not a mistake.
    // The AUDIO map above is untouched and uses SAMP_PER_FRAME (=1471) only -- it is
    // genuinely time-based (44100 samples/s / 29.97 disc fps) and is HW-CONFIRMED in sync.
    // Do not touch it.
    //
    // The frame_count clamp is KEPT: it bounds a corrupt/over-range disc frame to the last
    // real frame instead of indexing off the end of the index table.
    //
    // REVERT: delete the two lines below and uncomment the ratio block.
    // wire [16:0] mpeg_fpks_17 = mpeg_fpks[16:0];
    // wire [33:0] vid_prod   = (disc_rel * mpeg_fpks_17) + (DISC_FPKS >> 1);
    // wire [33:0] vid_scaled = vid_prod / DISC_FPKS;
    // wire [16:0] vid_ratio  = vid_scaled[16:0];
    wire [16:0] vid_ratio  = disc_rel;                       // 1:1, per Daphne's framefile
    wire [16:0] vid_target = (vid_ratio >= frame_count[16:0]) ? (frame_count[16:0] - 17'd1) : vid_ratio;

    // SEARCH-sized jump detect: PLAY advances +1/frame -> no jump; SEARCH ramps in big steps -> jump.
    reg  [16:0] prev_ld;
    always @(posedge clk) prev_ld <= ld_curr_frame;
    wire [16:0] fdiff  = (ld_curr_frame > prev_ld) ? (ld_curr_frame - prev_ld) : (prev_ld - ld_curr_frame);
    wire        jump_w = (fdiff > 17'd16);

    reg  seek_req;
    wire seek_consume = (state == S_READY) && header_valid && seek_req;
    // SEEK-REQ-RACE-FIX-2026-07-16: original two-if body commented below, uncomment to revert.
    // BUG: both ifs are in ONE always block, so when jump_w and seek_consume coincide the LAST
    // assignment wins and seek_req <= 1'b0 -- the jump is SILENTLY LOST and the audio never
    // re-points for that seek.  jump_w is only a 1-cycle pulse (prev_ld tracks ld_curr_frame with a
    // 1-cycle delay), so the coincidence window is narrow but real.
    // THIS WAS SURVIVABLE ONLY BY ACCIDENT: the old LD-V1000 halving ramp emitted ~14 jumps per
    // seek, so losing one still left 13.  DAPHNE-ATOMIC-SEEK-2026-07-16 makes the seek a single
    // atomic jump => there is now exactly ONE jump_w per seek, and losing it means audio never
    // re-points AT ALL.  The two fixes must ship together.
    // Giving jump_w priority is correct in both directions: a jump arriving on a consume cycle
    // leaves seek_req set, so the request is simply serviced on the next S_READY pass rather than
    // dropped.  No jump can be lost; at worst one is serviced a cycle late.
    always @(posedge clk) begin
        if (reset) seek_req <= 1'b0;
        else begin
            // if (jump_w)       seek_req <= 1'b1;
            // if (seek_consume) seek_req <= 1'b0;
            if (jump_w)            seek_req <= 1'b1;   // jump ALWAYS wins -- never drop a seek
            else if (seek_consume) seek_req <= 1'b0;
        end
    end

    //------------------------------------------------------------------------
    // Main SD/stream FSM
    //------------------------------------------------------------------------
    always @(posedge clk) begin
        if (reset) begin
            state <= S_IDLE;
            sd_rd <= 1'b0; sd_lba <= 32'd0; sd_blk_cnt <= 6'd0;
            out_valid <= 1'b0; out_last <= 1'b0;
            header_valid <= 1'b0; frame_fetch <= 1'b0;
            // DEAD-TEST-VALUE-FIX-2026-07-15: was START_FRAME (hardcoded 1000, a leftover
            // free-run test value from before ld_curr_frame-driven fetching existed). Meaningless
            // here anyway -- superseded below the instant header_valid inits (which now uses the
            // REAL vid_target) or a genuine fetch fires. 0 carries no false meaning; 1000 did.
            cur_frame <= 17'd0;
            // sentinel, not 17'd0: a real vid_target of 0 is legitimate (first mapped frame), so
            // resetting to 0 here could skip the very first genuine fetch if vid_target happens to
            // compute to 0 at boot.
            last_fetched_frame <= {17{1'b1}};
        end else begin
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
                if (!header_valid) begin
                    // one-time init once the header sector has been latched
                    header_valid  <= 1'b1;
                    aud_lba       <= aud_off  >> 9;
                    aud_lba_start <= aud_off  >> 9;
                    aud_lba_end   <= (aud_off + aud_size) >> 9;
                    // DEAD-TEST-VALUE-FIX-2026-07-15: was START_FRAME (hardcoded 1000). This
                    // branch re-fires every time header_valid gets cleared (incl. the img_mounted
                    // re-mount path) -- hardcoding cur_frame here meant EVERY re-init snapped
                    // playback back to a meaningless fixed frame instead of the real current LD
                    // position. vid_target (from the live ld_curr_frame) is valid here since the
                    // header (frame_count/mpeg_fpks) was just parsed.
                    cur_frame     <= vid_target;
                end else if (seek_req) begin
                    // HLE-DRIVE-2026-07-04: SEARCH jump -> re-point audio to the mapped sector.
                    // Ring keeps playing (no flush); new-scene audio lands after ~1 ring depth (~93 ms).
                    aud_lba <= (aud_target_lba >= aud_lba_end) ? (aud_lba_end - 32'd1) : aud_target_lba;
                end else if (img_mounted && img_size != 0) begin
                    // re-mount: re-read header
                    cap_mode <= 2'd0; cur_sec <= 32'd0; ret_state <= S_READY;
                    header_valid <= 1'b0;
                    state <= S_RD_ISSUE;
                end else if (frame_pending && (aud_level >= FILL_LOW)) begin
                    // REDUNDANT-REDRAW-FIX-2026-07-15: only actually fetch/decode/write if the
                    // mapped mjpeg frame has genuinely changed since the last one we drew. frame_
                    // pending still clears every tick regardless (frame_start, below, doesn't
                    // depend on this check) -- ticks where the content hasn't changed just do
                    // nothing instead of redundantly redrawing identical pixels.
                    if (vid_target != last_fetched_frame) begin
                        // ---- start a video frame fetch (audio comfortable) ----
                        frame_fetch        <= 1'b1;      // decoder held in reset through the fetch
                        cur_frame          <= vid_target;   // HLE-DRIVE: fetch the mapped mjpeg frame
                        last_fetched_frame <= vid_target;
                        state <= S_IDX;
                    end
                end else if (aud_level < FILL_HIGH) begin
                    // ---- top up the audio ring: read one audio sector ----
                    cur_sec  <= aud_lba;
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
                        9'd24: mpeg_fpks[7:0]     <= sd_buff_dout;   // HEADER-FIELDS-2026-07-05
                        9'd25: mpeg_fpks[15:8]    <= sd_buff_dout;
                        9'd26: mpeg_fpks[23:16]   <= sd_buff_dout;
                        9'd27: mpeg_fpks[31:24]   <= sd_buff_dout;
                        9'd28: ld_leader_off[7:0]  <= sd_buff_dout;   // HEADER-FIELDS-2026-07-05
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
        end
    end

endmodule
