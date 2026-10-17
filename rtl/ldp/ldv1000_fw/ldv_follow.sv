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
// Sampled once per field at the VBI fetch (3-sample window, h0 newest):
//   PLAY   h0 - h2 == 1 (one track per frame)        -> transport 1x PLAY at h0
//   STILL  h0 - h2 == 0, spread <= 1                 -> transport STOP at min(h0,h1)
//   MOVE   anything else (multi-jump, scan, settle)  -> follow h0 with a SEARCH,
//                                                       at most every COOLDOWN fields
// Only while video is NOT squelched and all three samples are program frames.
// (Slow-motion speeds alternate PLAY/STILL here -- not handled.)
// Video squelch starting while the transport plays -> OP_STOP (the real player
// blanks; the transport must at least not run on).
// A correction that needs a seek issues OP_SEARCH, waits for the transport to
// land (curr_frame == target, or LAND_TIMEOUT fields), then issues PLAY/STOP.
// Audio: PPI1 PC AUD1/AUD2/AUDIO ENABLE mapped to explicit OP_AUDIO1/2 sets.
//============================================================================
module ldv_follow
#(
    parameter [16:0] TOL          = 17'd3,    // |transport - head| allowed while playing
    parameter  [3:0] COOLDOWN     = 4'd4,     // fields between MOVE follow-seeks
    parameter  [5:0] LAND_TIMEOUT = 6'd60     // fields
)
(
    input             clk,
    input             reset_n,
    input             enable,         // selected && running

    input             fetch_done,     // 1-clk per field, frame below is fresh
    input             frame_valid,
    input      [16:0] frame,
    input             video_on,       // PPI1 PC3 (/VIDEO SQ high = not squelched)
    input             aud_en1,
    input             aud_en2,

    input       [2:0] t_mode,
    input      [16:0] t_frame,

    output reg        cmd_action,
    output reg  [3:0] cmd_op,
    output reg [16:0] cmd_arg,

    output reg  [1:0] dbg_class       // 0 none, 1 play, 2 still, 3 move
);
/* verilator lint_off UNUSED */
`include "ldp_bus.svh"
/* verilator lint_on UNUSED */

    reg [16:0] h [0:2];
    reg  [2:0] hv;

    localparam [1:0] C_NONE = 2'd0, C_PLAY = 2'd1, C_STILL = 2'd2, C_MOVE = 2'd3;
    localparam [1:0] S_IDLE = 2'd0, S_LAND = 2'd1;

    reg  [1:0] st;
    reg [16:0] land_tgt;
    reg  [3:0] land_op;           // OP_PLAY / OP_STOP / OP_NOP after landing
    reg  [5:0] land_cnt;
    reg  [3:0] cool;
    reg        vid_q;
    reg        aud1_sent, aud2_sent;
    reg        eval;              // one clock after fetch_done: history settled

    // ---- classification of the settled window ----
    wire [17:0] d    = {1'b0, h[0]} - {1'b0, h[2]};
    wire [16:0] hmin = (h[0] < h[1]) ? h[0] : h[1];
    reg  [16:0] wmin, wmax;
    integer k;
    always @(*) begin
        wmin = h[0]; wmax = h[0];
        for (k = 1; k < 3; k = k + 1) begin
            if (h[k] < wmin) wmin = h[k];
            if (h[k] > wmax) wmax = h[k];
        end
    end
    wire       win_ok = (&hv) && video_on;
    wire [1:0] cls = !win_ok                                 ? C_NONE  :
                     (d == 18'd1)                            ? C_PLAY  :
                     (d == 18'd0 && (wmax - wmin) <= 17'd1)  ? C_STILL : C_MOVE;

    function [16:0] absdiff(input [16:0] a, input [16:0] b);
        absdiff = (a > b) ? a - b : b - a;
    endfunction

    always @(posedge clk) begin
        cmd_action <= 1'b0;
        cmd_op     <= OP_NOP;
        cmd_arg    <= 17'd0;
        eval       <= 1'b0;
        if (!reset_n) begin
            for (k = 0; k < 3; k = k + 1) h[k] <= 17'd0;
            hv <= 3'd0;
            st <= S_IDLE; land_tgt <= 17'd0; land_op <= OP_NOP; land_cnt <= 6'd0;
            cool <= 4'd0; vid_q <= 1'b0;
            aud1_sent <= 1'b1; aud2_sent <= 1'b1;   // transport resets with both enabled
            dbg_class <= C_NONE;
        end else if (enable) begin
            vid_q <= video_on;

            if (fetch_done) begin
                for (k = 2; k > 0; k = k - 1) h[k] <= h[k-1];
                h[0] <= frame;
                hv   <= {hv[1:0], frame_valid};
                eval <= 1'b1;
                if (cool != 4'd0) cool <= cool - 4'd1;
                if (st == S_LAND && land_cnt != 6'd0) land_cnt <= land_cnt - 6'd1;
            end

            case (st)
                S_IDLE: begin
                    if (vid_q && !video_on && t_mode == M_PLAY) begin
                        cmd_action <= 1'b1; cmd_op <= OP_STOP;
                    end else if (eval) begin
                        dbg_class <= cls;
                        case (cls)
                            C_PLAY: begin
                                if (absdiff(t_frame, h[0]) > TOL) begin
                                    cmd_action <= 1'b1; cmd_op <= OP_SEARCH; cmd_arg <= h[0];
                                    st <= S_LAND; land_tgt <= h[0]; land_op <= OP_PLAY;
                                    land_cnt <= LAND_TIMEOUT;
                                end else if (t_mode != M_PLAY) begin
                                    cmd_action <= 1'b1; cmd_op <= OP_PLAY;
                                end
                            end
                            C_STILL: begin
                                if (t_frame != hmin) begin
                                    cmd_action <= 1'b1; cmd_op <= OP_SEARCH; cmd_arg <= hmin;
                                    st <= S_LAND; land_tgt <= hmin; land_op <= OP_STOP;
                                    land_cnt <= LAND_TIMEOUT;
                                end else if (t_mode == M_PLAY) begin
                                    cmd_action <= 1'b1; cmd_op <= OP_STOP;
                                end
                            end
                            C_MOVE: begin
                                if (cool == 4'd0 && absdiff(t_frame, h[0]) > TOL) begin
                                    cmd_action <= 1'b1; cmd_op <= OP_SEARCH; cmd_arg <= h[0];
                                    st <= S_LAND; land_tgt <= h[0]; land_op <= OP_NOP;
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
                default: begin   // S_LAND
                    if (t_frame == land_tgt || land_cnt == 6'd0) begin
                        st <= S_IDLE;
                        if (land_op != OP_NOP) begin
                            cmd_action <= 1'b1; cmd_op <= land_op;
                        end
                    end
                end
            endcase
        end
    end
endmodule
