//============================================================================
// ldv_follow.sv -- makes ldp_transport show the frame under the modelled head.
//
// The firmware closes its own servo loop against ldv_mech's track, so the
// track is the truth for the PLAYER.  The transport (and the .dlv streamer
// behind it) is the truth for the PICTURE.  This block keeps the picture on
// the track without copying every mechanical jitter: a still frame is a
// +1 / -1 track oscillation every frame, which must become one OP_STOP, not
// sixty seeks a second.
//
// Sampled once per field at the VBI fetch (3-sample window, 0 newest).  Motion is
// classified on the TRACK, targets are the picture numbers (frame) of those tracks:
// on a 23.976 film disc 5 tracks hold 4 pictures, so the picture number does not
// step once per revolution, the track does.  (29.97: frame = track - lead-in.)
//   PLAY   t0 - t2 == 1 (one track per frame)        -> transport 1x PLAY at h0
//   STILL  t0 - t2 == 0, spread <= 1                 -> transport STOP at min(h0,h1)
//   MOVE   anything else (multi-jump, scan, settle)  -> follow h0 with a SEARCH,
//                                                       at most every COOLDOWN fields
// Only while video is NOT squelched and all three samples are program frames.
// (Slow-motion speeds alternate PLAY/STILL here -- not handled.)
// Video squelch starting while the transport plays -> OP_STOP (the real player
// blanks; the transport must at least not run on).
// A correction that needs a seek issues OP_SEARCH and waits for the transport to
// land (curr_frame == target, or LAND_TIMEOUT fields).  The landing issues
// nothing: the transport lands in STOP and the next field's classification
// starts PLAY (or leaves the still) from what the head is doing THEN -- the
// class chosen before the seek hold can be stale (a search's final settle steps
// read as PLAY).
// PLAY with the transport playing and the head CATCHUP+1..SKIP_MAX frames AHEAD (a multi-track
// skip: SDQ's SKIP commands) -> OP_SKIP, as the HLE does (HW-validated SDQ path, 2026-10-14).
// PLAY with the transport 1..CATCHUP frames BEHIND the head (every PLAY start:
// the transport's first film tick comes a full period after motion) steps it
// forward with OP_STEP_FWD and then PLAYs -- no SEARCH, because in the core
// every search_cmd_o arms the seek hold (picture + audio re-prime).
// Audio: PPI1 PC AUD1/AUD2/AUDIO ENABLE mapped to explicit OP_AUDIO1/2 sets.
// While the firmware's own status is SEARCH ($50, busy) its head settles are intermediate (a search lands
// one picture off and corrects: Space Ace 361->149->148), so no follow-SEARCH is issued until the status
// moves on (SEARCH FINISH $D0 / ERROR $90 / anything else): one search_cmd_o = one seek hold per search.
// On $50 -> $D0 the transport goes to pic_code, the picture number the firmware's decoder just matched
// (= the host's target), not to the track's picture: on a film disc the track a search stops on can hold
// the target on field 0 and the next picture on field 1 (target 30000 -> track picture 30001).  That
// still is then left alone (no follow ops at all: the still's jump-back reads as PLAY for a window) for as
// long as the firmware's status stays SEARCH FINISH -- the host's next command (PLAY ...) changes it.
// If that command is PLAY (status $64/$E4) the transport PLAYs at once from the searched picture, as the
// head does: waiting for a 3-sample PLAY class would start it a picture late and the STEP that catches up
// drops the scene's first picture (and its audio).  The next 3 fields are not classified (the window
// still holds pre-PLAY samples, which read as STILL -> a spurious STOP).
//============================================================================
module ldv_follow
#(
    parameter [16:0] TOL          = 17'd3,    // |transport - head| allowed while playing
    parameter  [3:0] COOLDOWN     = 4'd4,     // fields between MOVE follow-seeks
    parameter  [5:0] LAND_TIMEOUT = 6'd60,    // fields
    parameter  [3:0] CATCHUP      = 4'd8,     // max frames behind fixed by stepping, not seeking
    parameter [16:0] SKIP_MAX     = 17'd255,  // max forward jump during play taken as OP_SKIP, not SEARCH
    parameter  [0:0] SEARCH_WAIT  = 1'b1      // 1: no follow-SEARCH while fw_status == $50 (see header)
)
(
    input             clk,
    input             reset_n,
    input             enable,         // selected && running

    input             fetch_done,     // 1-clk per field, frame below is fresh
    input             frame_valid,
    input      [16:0] frame,          // picture number of the track (the transport's frame)
    input      [16:0] track,
    input             video_on,       // PPI1 PC3 (/VIDEO SQ high = not squelched)
    input             aud_en1,
    input             aud_en2,

    input       [2:0] t_mode,
    input      [16:0] t_frame,
    input       [7:0] fw_status,      // the status byte the firmware last latched (Z7)
    input      [16:0] pic_code,       // last picture number the decoder delivered

    output reg        cmd_action,
    output reg  [3:0] cmd_op,
    output reg [16:0] cmd_arg,

    output reg  [1:0] dbg_class       // 0 none, 1 play, 2 still, 3 move
);
/* verilator lint_off UNUSED */
`include "ldp_bus.svh"
/* verilator lint_on UNUSED */

    reg [16:0] h [0:2];               // picture numbers
    reg [16:0] ht [0:2];              // tracks
    reg  [2:0] hv;

    localparam [1:0] C_NONE = 2'd0, C_PLAY = 2'd1, C_STILL = 2'd2, C_MOVE = 2'd3;
    localparam [1:0] S_IDLE = 2'd0, S_LAND = 2'd1, S_STEP = 2'd2;

    reg  [1:0] st;
    reg [16:0] land_tgt;
    reg  [5:0] land_cnt;
    reg  [3:0] cool;
    reg  [3:0] step_n;            // S_STEP: OP_STEP_FWDs still to issue, then OP_PLAY
    reg        vid_q;
    reg        aud1_sent, aud2_sent;
    reg        eval;              // one clock after fetch_done: history settled
    reg  [7:0] fws_q;             // fw_status one clock ago
    reg        held;              // transport parked on a search's pic_code: leave the still alone
    reg        fin_pend;          // $50 -> $D0 seen, not yet acted on (may arrive during S_LAND)
    reg        play_pend;         // left a held still on the firmware's PLAY status: PLAY now
    reg  [1:0] grace;             // fields to skip classifying after that PLAY

    // ---- classification of the settled window ----
    wire [17:0] d    = {1'b0, ht[0]} - {1'b0, ht[2]};
    wire [16:0] hmin = (h[0] < h[1]) ? h[0] : h[1];
    reg  [16:0] wmin, wmax;
    integer k;
    always @(*) begin
        wmin = ht[0]; wmax = ht[0];
        for (k = 1; k < 3; k = k + 1) begin
            if (ht[k] < wmin) wmin = ht[k];
            if (ht[k] > wmax) wmax = ht[k];
        end
    end
    wire       win_ok = (&hv) && video_on;
    wire [1:0] cls = !win_ok                                 ? C_NONE  :
                     (d == 18'd1)                            ? C_PLAY  :
                     (d == 18'd0 && (wmax - wmin) <= 17'd1)  ? C_STILL : C_MOVE;

    function [16:0] absdiff(input [16:0] a, input [16:0] b);
        absdiff = (a > b) ? a - b : b - a;
    endfunction

    wire [16:0] lag    = h[0] - t_frame;                         // valid when h[0] > t_frame
    wire        behind = (h[0] > t_frame) && (lag <= {13'd0, CATCHUP});
    // a forward jump past the step range while the transport plays = a multi-track skip
    wire        seek_ok  = !(SEARCH_WAIT && fw_status == 8'h50);   // firmware not mid-search
    wire        skip_fwd = (t_mode == M_PLAY) && (h[0] > t_frame) && (lag > {13'd0, CATCHUP}) && (lag <= SKIP_MAX);

    always @(posedge clk) begin
        cmd_action <= 1'b0;
        cmd_op     <= OP_NOP;
        cmd_arg    <= 17'd0;
        eval       <= 1'b0;
        if (!reset_n) begin
            for (k = 0; k < 3; k = k + 1) begin h[k] <= 17'd0; ht[k] <= 17'd0; end
            hv <= 3'd0;
            st <= S_IDLE; land_tgt <= 17'd0; land_cnt <= 6'd0;
            cool <= 4'd0; vid_q <= 1'b0; step_n <= 4'd0;
            aud1_sent <= 1'b1; aud2_sent <= 1'b1;   // transport resets with both enabled
            dbg_class <= C_NONE;
            fws_q <= 8'h00; held <= 1'b0; fin_pend <= 1'b0; play_pend <= 1'b0; grace <= 2'd0;
        end else if (enable) begin
            vid_q <= video_on;
            fws_q <= fw_status;
            if (SEARCH_WAIT && fws_q == 8'h50 && fw_status == 8'hD0) fin_pend <= 1'b1;
            if (held && !fin_pend && fw_status != 8'hD0) begin
                held <= 1'b0;
                play_pend <= (fw_status[6:0] == 7'h64);
            end

            if (fetch_done) begin
                for (k = 2; k > 0; k = k - 1) begin h[k] <= h[k-1]; ht[k] <= ht[k-1]; end
                h[0] <= frame;
                ht[0] <= track;
                hv   <= {hv[1:0], frame_valid};
                eval <= 1'b1;
                if (cool != 4'd0) cool <= cool - 4'd1;
                if (grace != 2'd0) grace <= grace - 2'd1;
                if (st == S_LAND && land_cnt != 6'd0) land_cnt <= land_cnt - 6'd1;
            end

            case (st)
                S_IDLE: begin
                    if (vid_q && !video_on && t_mode == M_PLAY) begin
                        cmd_action <= 1'b1; cmd_op <= OP_STOP;
                    end else if (play_pend) begin            // PLAY from the held search result
                        play_pend <= 1'b0; grace <= 2'd3;
                        if (t_mode != M_PLAY) begin cmd_action <= 1'b1; cmd_op <= OP_PLAY; end
                    end else if (fin_pend) begin             // the firmware's search finished
                        fin_pend <= 1'b0; held <= 1'b1;
                        if (t_frame != pic_code) begin
                            cmd_action <= 1'b1; cmd_op <= OP_SEARCH; cmd_arg <= pic_code;
                            st <= S_LAND; land_tgt <= pic_code; land_cnt <= LAND_TIMEOUT;
                        end else if (t_mode == M_PLAY) begin
                            cmd_action <= 1'b1; cmd_op <= OP_STOP;
                        end
                    end else if (eval && (held || grace != 2'd0)) begin
                        dbg_class <= cls;                   // parked on the search result
                    end else if (eval) begin
                        dbg_class <= cls;
                        case (cls)
                            C_PLAY: begin
                                if (behind && (t_mode != M_PLAY || lag > TOL)) begin
                                    st <= S_STEP; step_n <= lag[3:0];
                                end else if (skip_fwd) begin
                                    cmd_action <= 1'b1; cmd_op <= OP_SKIP; cmd_arg <= lag;
                                    st <= S_LAND; land_tgt <= h[0]; land_cnt <= LAND_TIMEOUT;
                                end else if (seek_ok && absdiff(t_frame, h[0]) > TOL) begin
                                    cmd_action <= 1'b1; cmd_op <= OP_SEARCH; cmd_arg <= h[0];
                                    st <= S_LAND; land_tgt <= h[0];
                                    land_cnt <= LAND_TIMEOUT;
                                end else if (t_mode != M_PLAY) begin
                                    cmd_action <= 1'b1; cmd_op <= OP_PLAY;
                                end
                            end
                            C_STILL: begin
                                if (seek_ok && t_frame != hmin) begin
                                    cmd_action <= 1'b1; cmd_op <= OP_SEARCH; cmd_arg <= hmin;
                                    st <= S_LAND; land_tgt <= hmin;
                                    land_cnt <= LAND_TIMEOUT;
                                end else if (t_mode == M_PLAY) begin
                                    cmd_action <= 1'b1; cmd_op <= OP_STOP;
                                end
                            end
                            C_MOVE: begin
                                if (skip_fwd) begin      // multi-track skip while playing (SDQ SKIP)
                                    cmd_action <= 1'b1; cmd_op <= OP_SKIP; cmd_arg <= lag;
                                    st <= S_LAND; land_tgt <= h[0]; land_cnt <= LAND_TIMEOUT;
                                end else if (seek_ok && cool == 4'd0 && absdiff(t_frame, h[0]) > TOL) begin
                                    cmd_action <= 1'b1; cmd_op <= OP_SEARCH; cmd_arg <= h[0];
                                    st <= S_LAND; land_tgt <= h[0];
                                    land_cnt <= LAND_TIMEOUT;
                                    cool <= COOLDOWN;
                                end
                            end
                            default: ;
                        endcase
                    end else if ((aud_en1 != aud1_sent)) begin
                        cmd_action <= 1'b1; cmd_op <= OP_AUDIO1; cmd_arg <= {15'd0, 1'b1, aud_en1};
                        aud1_sent <= aud_en1;
                    end else if ((aud_en2 != aud2_sent)) begin
                        cmd_action <= 1'b1; cmd_op <= OP_AUDIO2; cmd_arg <= {15'd0, 1'b1, aud_en2};
                        aud2_sent <= aud_en2;
                    end
                end
                S_STEP: begin    // one STEP per clock: the transport applies each the same cycle
                    cmd_action <= 1'b1;
                    if (step_n != 4'd0) begin
                        cmd_op <= OP_STEP_FWD; step_n <= step_n - 4'd1;
                    end else begin
                        cmd_op <= OP_PLAY; st <= S_IDLE;
                    end
                end
                default: begin   // S_LAND
                    if (t_frame == land_tgt || land_cnt == 6'd0)
                        st <= S_IDLE;
                end
            endcase
        end
    end
endmodule
