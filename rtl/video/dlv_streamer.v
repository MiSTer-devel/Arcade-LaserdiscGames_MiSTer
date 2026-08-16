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
    parameter [16:0] START_FRAME = 17'd1000,  // first film frame (skip black leader); free-runs from here
    // CLOCK-80M-2026-08-15: core clock rate, driven from CORE_CLK_HZ in Arcade-DragonsLair.sv.
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
    input             ld_playing,

    // --- SEEK-HOLD-2026-07-20 step 1 (authentic LD seek latency) -----------------------------
    // A real LD player stalls visibly while the head moves; the games were built around that
    // pause. We hold BOTH streams on a seek, refill, then release together so they restart in
    // sync instead of video racing to catch up.
    output            aud_primed,   // ring has enough buffered to resume cleanly
    input             hold_play,    // 1 = freeze audio playout (silence + HOLD aud_rd)
    // SEEK-FLUSH-2026-07-20: 1-cycle pulse on the Z80's SEARCH command. EMPTIES the audio ring
    // (aud_wr=aud_rd=0) so the old segment's buffered tail is DISCARDED and the ring refills with
    // ONLY the new segment. Without this the hold merely paused aud_rd and then drained the stale
    // old-segment audio on release -- i.e. it held but did NOT align. Flush + refill-while-held +
    // release-with-video = the actual alignment the user asked for. (The existing seek_req/jump_w
    // machinery re-points aud_lba to the new segment, so the refill sources the correct audio.)
    input             seek_flush
);
    //------------------------------------------------------------------------
    // Compressed-frame BRAM (video)
    //------------------------------------------------------------------------
    // FBUF-GROW-2026-07-24: 15 -> 17 (32 KB -> 128 KB).
    // The q3 320x240 encode peaks at 30,051 B = 92% of the old 32 KB buffer, so ANY quality or
    // resolution increase overflowed it -- and the overflow is SILENT: `fbuf[bytes_got[FBUF_AW-1:0]]`
    // wraps and `frm_size[FBUF_AW-1:0]-1` truncates, feeding the decoder a corrupt JPEG with no
    // error anywhere. 128 KB costs ~77 M10K of the 348 free (block memory 26% -> ~39%) and covers
    // any 320x240 quality plus a later resolution bump. pack_dlv.py now hard-fails at pack time if a
    // frame does not fit, and names the FBUF_AW required.
    // localparam FBUF_AW = 15;              // ORIGINAL, 32 KB -- uncomment to revert
    localparam FBUF_AW = 17;                 // 128 KB
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
    // DLV-V2-2026-07-24: header@24 (mpeg_fpks) is GONE -- pack_dlv.py writes 0 there now. It was
    // derived by assuming audio duration == video duration (impossible 41.218 fps for Space Ace) and
    // nothing has read it since the disc->video map was established as 1:1. This reg is repurposed
    // for the field that replaces it.
    // reg [31:0] mpeg_fpks;    // ORIGINAL header@24 -- uncomment to revert
    reg [31:0] spf_q16_hdr;     // header@96: samples per DISC frame, 16.16 fixed point (.dlv v2)
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
    // SEEK-HOLD-2026-07-20: "enough audio buffered to resume after a seek". Deliberately deeper
    // than FILL_LOW (which only gates STARTING a video frame) so playback resumes with margin
    // rather than on the edge of underrun. 3072 words = ~70 ms @44.1 kHz.
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
    // WEDGE-WATCHDOG-2026-07-24 -- ROOT CAUSE OF THE UNRECOVERABLE HARD LOCK.
    //
    // THE TRAP (structural, independent of what triggers it):
    //   dec_reset was `reset | frame_fetch`, and frame_fetch is set ONLY in S_READY.
    //   S_STRM_VLD blocks forever on out_ready (= jpeg_frame_decoder.in_ready =
    //   !wfull_next, low whenever core_jpeg stops accepting), and S_RD_ISSUE blocks
    //   forever on sd_ack.  So the ONLY signal that can un-wedge the decoder is
    //   generated by the FSM that the decoder is blocking.  Closed loop:
    //       decoder stalls -> S_STRM_VLD never completes -> S_READY unreachable
    //       -> frame_fetch never re-pulses -> dec_reset never fires -> decoder
    //       stays stalled.  FOREVER.
    //   And because this same FSM also owns the audio ring fill (S_READY ->
    //   S_AUD_DONE), the audio dies with it -- while the Z80, which touches none of
    //   this, runs on.  That is EXACTLY the reported symptom: "video + audio dead,
    //   Z80 still alive, lives keep decrementing".
    //
    // WHY THE ddram DOUT_READY FIX HELPED BUT DID NOT CURE IT (2026-07-20: "much
    // better, takes a very long time now"): that fix removed the dominant TRIGGER.
    // It did not remove the TRAP.  Any remaining stall of any origin -- a rarer
    // read-return loss, an SD hiccup, a long px_ready backpressure excursion -- still
    // lands in the same closed loop and is still permanent.  Chasing triggers one at a
    // time cannot close this bug; the loop has to be broken.
    //
    // THE FIX: bound the three blocking waits.  On timeout, abort to S_READY AND pulse
    // the decoder reset directly (wd_rst), so recovery does NOT depend on reaching the
    // state we could not reach.  Cost of a fire is one dropped frame (~42 ms).
    //
    // Timeout sizing: the longest LEGITIMATE wait here is one SD sector (<< 1 ms) or one
    // byte handed to a decoder that is backpressured by fb_writer's fill_idle gate --
    // fill_idle goes high once per raster line (3072 clk = 77 us), so no legitimate gap
    // approaches 50 ms.  That is ~650x the worst real wait: it cannot fire spuriously,
    // and it still recovers inside 2 film frames.
    //
    // wd_state/wd_frame/wd_trips latch WHICH wait wedged, at WHICH disc frame, and HOW
    // OFTEN -- this is the measurement that names the remaining trigger.  STEP 2 (not
    // done here, deliberately one variable per build) is to surface wd_trips/wd_state on
    // the LED band; that needs led_digits_flat, which currently carries the real
    // score/lives, so it is the user's call.  Until then Quartus will strip these three
    // and report them unused -- expected, not a mistake.  The FIX above works regardless.
    // CLOCK-80M-2026-08-15: was `localparam [21:0] WD_LIMIT = 22'd2000000;` / `reg [21:0] wd_cnt;`
    // DERIVED, not hardcoded: at 2x clock a fixed 2,000,000 would fire at 25 ms -- SHORTER than a
    // film frame -- aborting every legitimate fetch so no frame ever completes (one of the two
    // width/derivation bugs that blanked VCR-Robots).  Widened to [23:0] with headroom.
    localparam [23:0] WD_LIMIT = CLK_HZ / 32'd20;   // 50 ms at CLK_HZ (= 4,000,000 @ 80 MHz)
    reg  [23:0] wd_cnt;
    reg  [3:0]  wd_rst_cnt;                     // holds dec_reset for 16 clk after an abort
    reg  [3:0]  wd_state;                       // state that timed out
    reg  [16:0] wd_frame;                       // ld_curr_frame at the wedge
    reg  [15:0] wd_trips;                       // total aborts since reset
    wire        wd_rst  = (wd_rst_cnt != 4'd0);
    // Armed ONLY in the two genuinely unbounded waits: S_RD_ISSUE (waits sd_ack, no transfer in
    // flight yet -- dropping sd_rd cleanly retracts an unacked request) and S_STRM_VLD (waits
    // out_ready, touches no SD state at all).  Both are safe to abandon.
    // S_RD_XFER is DELIBERATELY NOT ARMED: it waits on !sd_ack for a transfer hps_io has ALREADY
    // acked, so aborting it would leave us issuing a fresh sd_rd while the old sd_ack is still
    // high -- i.e. it would trade a rare wedge for a desynced block handshake, which is a NEW
    // hard-lock source.  Not a trade worth making; if wd_state ever latches S_RD_XFER we will know
    // (that is what the latch is for) and can drain it properly then.
    wire        wd_arm  = (state == S_RD_ISSUE) || (state == S_STRM_VLD);
    // any forward progress re-arms the timer: SD data landing, or a byte accepted
    wire        wd_prog = sd_buff_wr || (out_valid && out_ready);
    wire        wd_fire = (wd_cnt == WD_LIMIT);

    // WEDGE-WATCHDOG-2026-07-24: original below, uncomment (and delete wd_rst) to revert.
    // assign dec_reset = reset | frame_fetch;   // per-frame decoder reset (decoder only)
    assign dec_reset = reset | frame_fetch | wd_rst;

    wire [31:0] idx_byte = index_off + {cur_frame, 3'b000};   // cur_frame*8

    //------------------------------------------------------------------------
    // 30 fps frame pacer + pending latch (single-driver on frame_pending)
    //------------------------------------------------------------------------
    // 🚨 CLOCK-80M-2026-08-15: was `localparam [20:0] FRAME_DIV = 21'd1333333;` / `reg [20:0] frame_cnt;`.
    // NOT in the upgrade recipe's table -- found by sweeping for "40e6".  At 80 MHz this is
    // 2666666, which needs 22 bits; [20:0] tops out at 2097151 so it would have SILENTLY truncated
    // to 569514 -- the 30 Hz pacer free-running at ~140 Hz, i.e. the watchdog re-fetch/re-mount
    // safety net hammering the fetch path.  Widened to [21:0]; form is exact at 40 MHz too.
    localparam [21:0] FRAME_DIV = (64'd1333333 * CLK_HZ) / 64'd40_000_000;   // CLK_HZ/30
    reg [21:0] frame_cnt;
    reg        frame_tick;
    reg        frame_pending;
    // FETCH-PHASE-LOCK-2026-07-25: content-change detect, driven below (after vid_target is
    // declared).  Declared HERE so frame_pending's block can read it without a forward reference
    // -- this is a .v file, elaborated as Verilog-2001.
    reg [16:0] vid_target_q;
    reg        vid_chg;
    // FRAME-TICK-SWALLOW-FIX-2026-07-24: frame_start CLEARS frame_pending (below), but it was
    // testing only "would S_READY like to fetch?" while the S_READY case chain could still take an
    // EARLIER branch and fetch nothing -- so the 30 Hz tick was consumed with no frame fetched.
    // The seek_req branch was the worst offender (it fired exactly at scene changes, i.e. when a
    // fresh frame matters most); that one is fixed properly by lifting seek_req out of the chain in
    // S_READY.  The re-mount branch remains exclusive, so it is excluded here.
    // Original: `wire frame_start = (state == S_READY) && header_valid && frame_pending
    //                               && (aud_level >= FILL_LOW);`
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
            // FETCH-PHASE-LOCK-2026-07-25: revert = uncomment orig, delete the line below + the
            // vid_target_q/vid_chg regs and their always block.
            // BUG: pacer free-ran at 30 Hz (FRAME_DIV) while content advances at 23.938 (FILM_PERIOD)
            // => changes detected 0-33 ms late, phase walking => +/-0.8 frame jitter at segment ends.
            // ADDITIVE: frame_tick KEPT as safety net (watchdog re-fetch + re-mount rely on it);
            // vid_chg just means we stop WAITING. Rate still bounded by fetch duration, not this tick.
            // if (frame_tick)  frame_pending <= 1'b1;
            if (frame_tick || vid_chg) frame_pending <= 1'b1;
            if (frame_start) frame_pending <= 1'b0;   // clear wins if same cycle
        end
    end

    //------------------------------------------------------------------------
    // 44.1 kHz sample tick (fractional accumulator: exact average rate)
    //------------------------------------------------------------------------
    // CLOCK-80M-2026-08-15: was [25:0] ACC_INC/ACC_MOD/samp_acc with ACC_MOD = 26'd40000000.
    // 80,000,000 needs 27 bits and [25:0] tops out at 67,108,863 -- it would have silently
    // truncated (legal Verilog, clean lint) and destroyed the sample rate.  Widened to [27:0].
    localparam [27:0] ACC_INC = 28'd44100;
    localparam [27:0] ACC_MOD = CLK_HZ;              // one 44.1 kHz tick per CLK_HZ clocks
    reg [27:0] samp_acc;
    reg        samp_tick;
    always @(posedge clk) begin
        samp_tick <= 1'b0;
        if (reset) samp_acc <= 28'd0;
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
        // SEEK-FLUSH-2026-07-20: empty the ring's write side on a seek. Priority over the fill so
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

    // LEADER-GATE-2026-07-05: dlair.txt (Daphne framefile) says disc frame 151 is where the ONE
    // captured mpeg begins -- frames 0..150 are the pre-content leader, nothing was captured there.
    // ld_curr_frame starts at 0 and free-runs up through the leader during the very first PLAY at
    // boot, so without this the disc_rel clamp-to-0 (below) aliases the whole 5s leader traversal
    // to "frame 0 of real content" and plays the movie's true opening audio 5s early.
    wire on_leader = (ld_curr_frame < ld_leader);   // ld_leader now header-driven, see HEADER-FIELDS-2026-07-05 below

    // SAMP-PER-FRAME-2026-07-20: COMPUTED from ACTUAL DATA COUNTS, not hardcoded and NOT from
    // mpeg_fpks. ⚠️ mpeg_fpks is UNRELIABLE -- Space Ace's is garbage (41218 = impossible fps), and
    // the whole 2026-07-05 "RATE != MAP" mess was about not trusting it. The self-consistent source
    // is total_samples / frame_count (independently corroborated 1842 for DL:
    // 81343495/44154 = 1842.28). total_samples = aud_size/4 (stereo s16 = 4 bytes/sample), and BOTH
    // aud_size and frame_count are already parsed -- so:
    //     samp_per_frame = (aud_size >> 2) / frame_count
    // This is garbage-fps-proof (it derives from the blob's own extents) and tracks any re-encode.
    // Used by BOTH the frame-lock credit AND the seek re-point (aud_prod) -- one source.
    // (If a re-encode also changes the audio sample rate, ACC_INC -- the 44.1 kHz drain divider --
    //  must change too; the fully general endpoint is pack_dlv.py writing samples/frame into the
    //  header directly, removing this divide.)
    wire [31:0] spf_q = (frame_count != 32'd0) ? ((aud_size >> 2) / frame_count) : 32'd1842;
    wire [13:0] samp_per_frame = (header_valid && spf_q >= 32'd256 && spf_q <= 32'd8191)
                                 ? spf_q[13:0] : 14'd1842;   // fallback = DL's 1842

    // ---- FRAME-LOCK-2026-07-20 -----------------------------------------------------------------
    // Slave the audio drain to the DISC FRAME POSITION instead of a free 44.1 kHz clock, so audio
    // and video share ONE master (the disc, which the Z80 controls) and cannot drift.
    // ROOT CAUSE this fixes: video content = f(ld_curr_frame) (it STALLS if the disc stalls), but
    // audio was draining at a fixed 44.1 kHz regardless -- so any video/disc hiccup let audio pull
    // ahead ("audio blasting away"). Attract played fine only because the disc there advances
    // smoothly; gameplay's SEARCH/PLAY cycling stalls the disc while audio free-wheeled.
    // MECHANISM (credit / leaky-bucket): each disc frame the LDV1000 advances is worth 1842 samples
    // of credit (= SAMP_PER_FRAME, defined below; hardcoded here only because it is textually later
    // -- keep the two equal). A drain spends one sample. Audio drains at 44.1 kHz WHILE it has
    // credit and STALLS the instant the disc stalls -- exactly how audio+video are frame-locked on
    // the physical disc. A frame JUMP (>2, i.e. a seek fwd or a backward wrap) auto-resets credit,
    // so this stays correct even if the CMD_SEARCH flush pulse is mistimed.
    reg  [16:0] aud_prev_frame;
    reg  [13:0] aud_credit;                       // samples the disc position currently permits
    localparam [13:0] AUD_CREDIT_MAX = 14'd7368;  // 4 frames -- anti-burst cap on catch-up
    wire [16:0] aud_fadv  = ld_curr_frame - aud_prev_frame;    // unsigned; a large value = a jump
    wire        aud_jump  = (aud_fadv > 17'd2);                // >2 frames/cycle = seek, not 1x play
    wire        aud_muted = hold_play || !ld_playing || on_leader || !header_valid;
    wire        aud_drain = samp_tick && (aud_wr != aud_rd) && (aud_credit != 14'd0) && !aud_muted;

    // ---- FRAME-LOCK-SPF-FIX-2026-07-25 ---------------------------------------------------------
    // HW 2026-07-25, Space Ace: *"absolutely a stuttery trash mess"* -- AFTER `ace.dlv` header @96
    // was corrected to the film-rate 1839.3375. That patch fixed the WRONG CONSUMER: @96
    // (`spf_q16`) feeds ONLY `aud_prod_q16`/`aud_target_lba`, i.e. WHERE a seek lands. The
    // FRAME-LOCK drain credit below used `samp_per_frame`, which is `(aud_size>>2)/frame_count`
    // (line ~341) -- the AUDIO-BLOB RATIO, not the header -- so Space Ace kept granting 1069
    // samples per disc frame and the bucket still ran dry every frame. The comment at
    // SEEK-Q16 even names "samp_per_frame's other user (the credit adder)"; it was not acted on.
    // It also left the two INCONSISTENT (land at 1839.34, drain at 1069), which plausibly sounded
    // worse than the original bug.
    //
    // THE KEY INSIGHT -- these two numbers answer DIFFERENT questions and must NOT share a source:
    //   * the SEEK re-point pairs with the BLOB : samples per film frame AS PACKED = 1839.3375
    //     (= SRATE * 1001/24000). Container-derived, per game. That is `spf_q16` @96. Correct.
    //   * the DRAIN CREDIT pairs with the TICK  : it must let the ring drain at real-time 44100 Hz
    //     given the rate `curr_frame` ACTUALLY advances, which is FILM_PERIOD in
    //     DragonsLair_LDV1000.sv = 1,670,983 cyc = 23.93798 fps. So credit = 44100/23.93798 =
    //     1842.27 -> 1842. Because FILM_PERIOD is a CONSTANT, this must be a constant too:
    //     deriving it from the container is wrong BY DESIGN, which is what
    //     SAMP-PER-FRAME-2026-07-20 got wrong and why Space Ace regressed while DL/TQ survived
    //     (their blob ratios happen to equal ~1842).
    // Supply becomes 23.93798 * 1842 = 44,094 /s = 99.99% of drain -- identical to DL, which is
    // HW-confirmed good. Space Ace goes 58.1% -> 99.99%.
    // Residual: credit (1842) vs blob (1839.34) differ 0.16%, so within one continuous scene audio
    // creeps ~1.6 ms/s ahead of the seek map (~96 ms over 60 s), re-anchored at every SEARCH. Same
    // class of residual the 2026-07-16 note already accepted. Closing it properly means making
    // FILM_PERIOD the TRUE 23.976 fps -- do NOT do that now: it would also shift the display
    // cadence ratio and the CADENCE-FIX-2026-07-24 refresh change is HW-CONFIRMED GOOD.
    // ⚠️ If FILM_PERIOD is ever changed, THIS CONSTANT MUST CHANGE WITH IT (= 44100/film_fps).
    localparam [13:0] SAMP_PER_TICK = 14'd1842;
    // ORIGINAL (credit came from the container ratio -- the regression):
    // wire [14:0] aud_add   = (aud_jump)          ? 15'd0 :
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
            aud_prev_frame <= 17'd0;    // FRAME-LOCK-2026-07-20
            aud_credit     <= 14'd0;
        // SEEK-FLUSH-2026-07-20: empty the ring's read side on a seek (matches aud_wr flush).
        // aud_rd=0 with aud_wr=0 => ring empty => aud_level=0 => not primed => held until it
        // refills past SEEK_FILL, at which point drain resumes from word 0 = the new segment's
        // first sample, released together with the first new video frame.
        // SEEK-FLUSH-2026-07-20: empty the ring's read side on a seek (matches the aud_wr flush) so
        // old-segment audio is discarded and refill starts clean. FRAME-LOCK: also zero the credit
        // and re-anchor prev_frame so the jump adds no spurious credit.
        end else if (seek_flush) begin
            aud_rd <= {AUD_AW{1'b0}};
            pcm_l  <= 16'sd0;
            pcm_r  <= 16'sd0;
            aud_prev_frame <= ld_curr_frame;
            aud_credit     <= 14'd0;
        end else begin
            // FRAME-LOCK-2026-07-20: credit + prev_frame advance EVERY cycle (independent of the
            // mute/drain branch below). A frame jump auto-flushes the credit.
            aud_prev_frame <= ld_curr_frame;
            aud_credit     <= aud_jump ? 14'd0 : aud_cred_cap;

            // AUDIO-GATE-2026-07-05: not PLAYing / on the leader / header not parsed / SEEK-HOLD ->
            // silence + HOLD aud_rd (resume from the same point). SEEK-HOLD-2026-07-20 folded in via
            // aud_muted. !header_valid is load-bearing (ld_leader_off powers up ~0 -> on_leader
            // false pre-mount); see HEADER-FIELDS-2026-07-05.
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
    // SAMP_PER_FRAME is now the COMPUTED `samp_per_frame` wire (SAMP-PER-FRAME-2026-07-20 above),
    // derived from the header's mpeg_fpks so it tracks a re-encode. (Old: localparam 12'd1842.)

    // ---- SIGNED-LEADER-2026-07-24 -------------------------------------------------------------
    // header@28 is a SIGNED s32. Dragon's Lair is +151 and Space Ace +2, but **Thayer's Quest is
    // -16** -- its capture begins BEFORE disc frame 0. Read unsigned, -16 became 0x1FFF0 = 131056,
    // so `ld_curr_frame > ld_leader` was never true (disc_rel pinned at 0 = permanently frame 0) and
    // `on_leader` was always true (audio permanently muted). Both are fixed by reading it signed.
    // A negative offset means there is no leader at all, hence the clamp to 0.
    // ORIGINAL: wire [16:0] ld_leader = ld_leader_off[16:0];
    wire signed [31:0] ld_leader_s = ld_leader_off;
    wire [16:0] ld_leader  = (ld_leader_s <= 32'sd0)      ? 17'd0     :
                             (ld_leader_s > 32'sd131071)  ? 17'h1FFFF : ld_leader_s[16:0];
    // ORIGINAL: wire [16:0] disc_rel = (ld_curr_frame > ld_leader) ? (ld_curr_frame - ld_leader) : 17'd0;
    wire signed [31:0] disc_rel_s = $signed({15'd0, ld_curr_frame}) - ld_leader_s;
    wire [16:0] disc_rel   = (disc_rel_s <= 32'sd0)       ? 17'd0     :
                             (disc_rel_s > 32'sd131071)   ? 17'h1FFFF : disc_rel_s[16:0];

    // ---- SEEK-Q16-2026-07-24: EXACT audio seek re-point ----------------------------------------
    // THE BUG THIS FIXES (root cause of "some segments start off out of sync IMMEDIATELY"):
    // samp_per_frame is an INTEGER divide, 1842 for DL, but the true value is
    // 81343495/44154 = 1842.267858. The seek re-point MULTIPLIES that 0.267858 error by the frame
    // number, so the landing error grows LINEARLY with disc position -- 6.07 ms per 1000 disc frames:
    //     disc_rel  5,000 ->  30 ms   (attract loops back to a low frame => looked perfect)
    //     disc_rel 35,000 -> 213 ms   (whirlpools/rapids => audibly wrong the instant they land)
    //     disc_rel 44,003 -> 267 ms   (end of disc)
    // Fix: take samples-per-disc-frame from the .dlv v2 header as 16.16 fixed point (@96) instead of
    // recomputing a truncated integer. Residual error: 267 ms -> 0.005 ms.
    //
    // BACKWARD COMPATIBLE: a v1 image has 0 at @96 (the old packer zero-filled the header), which
    // fails the range test and falls back to `samp_per_frame << 16` -- i.e. EXACTLY today's
    // behaviour. An un-repacked Space Ace / Thayer's Quest still boots and behaves as it does now.
    // ⚠️ That fallback is why the (aud_size>>2)/frame_count divider is KEPT rather than deleted as
    // originally planned -- deleting it would silently desync any image not yet repacked to v2.
    // Once every game is v2 it can go, along with samp_per_frame's other user (the credit adder).
    wire        spf_hdr_ok = header_valid && (spf_q16_hdr >= 32'd1048576)      // >= 16.0 samp/frame
                                          && (spf_q16_hdr <  32'd134217728);   // <  2048.0
    wire [29:0] spf_q16    = spf_hdr_ok ? spf_q16_hdr[29:0] : {samp_per_frame, 16'd0};

    // audio target sector = aud_lba_start + (disc_rel * samples_per_frame) / 128 samples-per-sector
    // >>16 undoes the Q16 scaling and >>7 converts samples to sectors, hence >>23.
    wire [46:0] aud_prod_q16   = disc_rel * spf_q16;
    wire [31:0] aud_target_lba = aud_lba_start + {8'd0, aud_prod_q16[46:23]};

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

    // FETCH-PHASE-LOCK-2026-07-25: 1-cycle pulse when the mapped frame changes. Declared up with the
    // pacer regs; driven here, where vid_target exists. Delete this block to revert.
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
    // SEEK-TRIGGER-2026-07-20: the audio re-point fires on the REAL SEEK COMMAND (seek_flush =
    // CMD_SEARCH), and ONLY that. jump_w (fdiff>16, a head-movement heuristic) is GONE as a trigger
    // -- it silently missed any seek <=16 frames, which is exactly why resets were inconsistent.
    // THE GAME SEEKS CONSTANTLY to non-sequential frames (death-skips, randomized order); every one
    // is a CMD_SEARCH, and every one MUST reset+resync both streams. This is the single trigger for
    // ALL of that: ring flush (seek_flush, above), video buffer reset + hold (top level), and this
    // audio re-point.
    // TIMING: the command byte precedes the atomic frame LAND by a few cycles, and aud_target_lba
    // needs the LANDED ld_curr_frame -- so ARM on the command and fire the re-point on the first
    // frame change after (= the land). seek_armed is set ONLY by the command, so normal per-frame
    // play advances never trigger it.
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

    //------------------------------------------------------------------------
    // Main SD/stream FSM
    //------------------------------------------------------------------------
    always @(posedge clk) begin
        if (reset) begin
            state <= S_IDLE;
            sd_rd <= 1'b0; sd_lba <= 32'd0; sd_blk_cnt <= 6'd0;
            out_valid <= 1'b0; out_last <= 1'b0;
            header_valid <= 1'b0; frame_fetch <= 1'b0;
            // DLV-V2-2026-07-24: 0 => "absent", so a v1 image deterministically takes the
            // samp_per_frame fallback instead of powering up on an undefined value.
            spf_q16_hdr  <= 32'd0;
            // DEAD-TEST-VALUE-FIX-2026-07-15: was START_FRAME (hardcoded 1000, a leftover
            // free-run test value from before ld_curr_frame-driven fetching existed). Meaningless
            // here anyway -- superseded below the instant header_valid inits (which now uses the
            // REAL vid_target) or a genuine fetch fires. 0 carries no false meaning; 1000 did.
            cur_frame <= 17'd0;
            // sentinel, not 17'd0: a real vid_target of 0 is legitimate (first mapped frame), so
            // resetting to 0 here could skip the very first genuine fetch if vid_target happens to
            // compute to 0 at boot.
            last_fetched_frame <= {17{1'b1}};
            // WEDGE-WATCHDOG-2026-07-24
            wd_cnt <= 24'd0; wd_rst_cnt <= 4'd0;   // CLOCK-80M-2026-08-15: wd_cnt widened 22->24
            wd_state <= 4'd0; wd_frame <= 17'd0; wd_trips <= 16'd0;
        end else begin
            // WEDGE-WATCHDOG-2026-07-24: run the timer BEFORE the case, so a state change or a
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
                // FRAME-TICK-SWALLOW-FIX-2026-07-24: the audio re-point does NOT change `state` and
                // does NOT consume the SD port -- it is a single aud_lba assignment.  Sitting in the
                // else-if chain it nonetheless BLOCKED the video-fetch branch for that cycle while
                // frame_start (above) still cleared frame_pending => the tick was swallowed and NO
                // frame was fetched, at exactly the moment a seek needs one.  Lifted out of the
                // chain: it now runs alongside, and the header-init branch below still overrides
                // aud_lba on a coincident cycle (later assignment wins), as before.
                // Original position: `end else if (seek_req) begin <this line> end else if (img_...`
                if (header_valid && seek_req)
                    aud_lba <= (aud_target_lba >= aud_lba_end) ? (aud_lba_end - 32'd1) : aud_target_lba;

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
                // FRAME-TICK-SWALLOW-FIX-2026-07-24: seek_req branch moved above the chain.
                // HLE-DRIVE-2026-07-04: SEARCH jump -> re-point audio to the mapped sector.
                // Ring keeps playing (no flush); new-scene audio lands after ~1 ring depth (~93 ms).
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
                        // DLV-V2-2026-07-24: @24 (mpeg_fpks) no longer parsed -- it is RESERVED=0.
                        // The v2 field below replaces it. Original:
                        //   9'd24: mpeg_fpks[7:0]  <= sd_buff_dout;  ... 9'd27: mpeg_fpks[31:24] <= ...
                        9'd96:  spf_q16_hdr[7:0]   <= sd_buff_dout;   // samples/disc-frame, Q16
                        9'd97:  spf_q16_hdr[15:8]  <= sd_buff_dout;
                        9'd98:  spf_q16_hdr[23:16] <= sd_buff_dout;
                        9'd99:  spf_q16_hdr[31:24] <= sd_buff_dout;
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

            // WEDGE-WATCHDOG-2026-07-24: abort. Placed AFTER the case so its assignments win any
            // coincidence -- whatever the wedged state was about to do, it has already failed to do
            // for 50 ms.  Drops the in-flight frame and re-enters the arbiter cleanly:
            //   - sd_rd low       : release the hps_io block request (S_RD_ISSUE/S_RD_XFER wedge)
            //   - out_valid/last  : retract the byte the decoder would not take (S_STRM_VLD wedge)
            //   - wd_rst_cnt      : 16 clk of dec_reset RIGHT NOW -- this is the part that actually
            //                       breaks the closed loop; do NOT rely on the next frame_fetch,
            //                       that is the very thing the wedge was preventing.
            //   - last_fetched_frame invalidated so the next tick genuinely re-fetches instead of
            //     seeing vid_target == last_fetched_frame and skipping.
            // frame_fetch is left to S_READY (which clears it next cycle) -- wd_rst already covers
            // the decoder, so pulsing it here would only double-drive the same reset.
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
