//============================================================================
// dlv_streamer.v — .dlv block streamer (SD -> compressed-frame BRAM -> decoder)
//----------------------------------------------------------------------------
// Reads a mounted .dlv image over the standard MiSTer hps_io block interface
// (sd_lba/sd_rd/sd_ack/sd_buff_*), parses the 512-byte header + the per-frame
// index, and on a fetch request streams one baseline JPEG frame's bytes out to
// jpeg_frame_decoder's feed port.
//
// .dlv header (little-endian, sector 0) — see pack_dlv.py:
//   [16] u32 frame_count   [48] u64 index_offset   [64] u64 video_offset
// frame index @ index_offset:  frame_count * { u32 off_in_video_blob, u32 size }
//   (8 B/entry, 64/sector, never straddles a 512-B sector)
//
// Flow: on img_mounted -> read sector 0, latch index_off/video_off.  On
// req_valid(req_frame N): read the index sector holding entry N -> {foff,fsize};
// read the video sectors covering [video_off+foff, +fsize) into a BRAM; then
// stream fsize bytes out (skipping the leading partial-sector bytes).
//
// One sector per sd_rd request (sd_blk_cnt=0) for protocol simplicity; decode
// is ~8x real-time so per-sector latency is irrelevant.  BRAM sized for the
// largest q3 320x240 JPEG (~20 KB) -> 32 KB.
//
// NOT yet instantiated at top — wire sd_* to hps_io[0] and out_* to the decoder
// feed in the integration step.
//============================================================================
module dlv_streamer
(
    input             clk,
    input             reset,            // active-high

    // --- HPS block/disk interface (-> hps_io sd_*[0], img_*) ---
    input             img_mounted,      // pulse when a new image is mounted
    input      [63:0] img_size,
    output reg [31:0] sd_lba,           // -> sd_lba[0]
    output reg  [5:0] sd_blk_cnt,       // -> sd_blk_cnt[0]  (blocks-1; we use 0)
    output reg        sd_rd,            // -> sd_rd[0]
    input             sd_ack,           // <- sd_ack[0]
    input       [8:0] sd_buff_addr,     // <- sd_buff_addr  (0..511)
    input       [7:0] sd_buff_dout,     // <- sd_buff_dout  (HPS -> core)
    input             sd_buff_wr,       // <- sd_buff_wr

    // --- fetch request ---
    input      [16:0] req_frame,        // film-frame number to fetch
    input             req_valid,        // pulse: begin fetching req_frame
    output reg        ready,            // header parsed; idle & able to accept a req
    output reg        busy,             // high while fetching/streaming

    // --- byte stream out (to jpeg_frame_decoder: in_byte/in_valid/in_ready/in_last) ---
    output      [7:0] out_byte,      // = fbuf_q (registered BRAM read)
    output reg        out_valid,
    input             out_ready,
    output reg        out_last
);
    // ---- compressed-frame BRAM (inferred) ----
    localparam FBUF_AW = 15;                 // 32 KB
    reg [7:0] fbuf [0:(1<<FBUF_AW)-1];
    reg [7:0] fbuf_q;                        // registered read data
    assign out_byte = fbuf_q;

    // ---- header fields (byte offsets in file) ----
    reg [31:0] index_off, video_off, frame_count;

    // ---- current-frame index entry ----
    reg [31:0] frm_off;      // offset within the video blob
    reg [31:0] frm_size;     // JPEG byte length
    reg [31:0] frm_start;    // absolute file byte offset = video_off + frm_off

    // ---- read engine ----
    localparam [3:0]
        S_IDLE     = 4'd0,   // waiting for mount
        S_HDR      = 4'd1,   // reading sector 0
        S_READY    = 4'd2,   // idle, header valid
        S_IDX      = 4'd3,   // reading the index sector
        S_IDX_DONE = 4'd4,
        S_FRM      = 4'd5,   // reading the frame's video sectors into fbuf
        S_FRM_NEXT = 4'd6,
        S_STREAM   = 4'd7,   // fbuf -> decoder: issue read
        S_RD_ISSUE = 4'd8,   // generic: issue one sector read
        S_RD_XFER  = 4'd9,   // generic: capture the sector
        S_STRM_VLD = 4'd10;  // fbuf -> decoder: present byte

    reg [3:0]  state, ret_state;   // ret_state = where to go after a sector read
    reg [1:0]  cap_mode;           // 0=header, 1=index, 2=frame
    reg [31:0] cur_sec;            // sector being read
    reg [31:0] sec_base_byte;      // file byte address of this sector's byte 0

    // frame read progress
    reg [31:0] bytes_got;          // frame bytes captured so far
    reg [8:0]  idx_in_sec;         // byte offset of entry N within the index sector

    // stream progress
    reg [FBUF_AW-1:0] stream_pos;

    wire [31:0] idx_byte = index_off + {req_frame_l, 3'b000}; // N*8
    reg  [16:0] req_frame_l;

    always @(posedge clk) begin
        if (reset) begin
            state <= S_IDLE; ready <= 1'b0; busy <= 1'b0;
            sd_rd <= 1'b0; sd_lba <= 32'd0; sd_blk_cnt <= 6'd0;
            out_valid <= 1'b0; out_last <= 1'b0;
        end else begin
            case (state)
            // -------- wait for image, then read header sector 0 --------
            S_IDLE: begin
                ready <= 1'b0; busy <= 1'b0;
                if (img_mounted && img_size != 0) begin
                    cap_mode <= 2'd0; cur_sec <= 32'd0; ret_state <= S_READY;
                    busy <= 1'b1; state <= S_RD_ISSUE;
                end
            end

            S_READY: begin
                ready <= 1'b1; busy <= 1'b0;
                if (req_valid) begin
                    req_frame_l <= req_frame;
                    ready <= 1'b0; busy <= 1'b1;
                    state <= S_IDX;
                end
                // a re-mount re-reads the header
                if (img_mounted && img_size != 0) begin
                    cap_mode <= 2'd0; cur_sec <= 32'd0; ret_state <= S_READY;
                    ready <= 1'b0; busy <= 1'b1; state <= S_RD_ISSUE;
                end
            end

            // -------- read the index sector holding entry N --------
            S_IDX: begin
                cur_sec    <= idx_byte[31:9];      // /512
                idx_in_sec <= idx_byte[8:0];       // %512  (entry never straddles)
                cap_mode   <= 2'd1; ret_state <= S_IDX_DONE;
                state <= S_RD_ISSUE;
            end
            S_IDX_DONE: begin
                frm_start <= video_off + frm_off;
                bytes_got <= 32'd0;
                // first sector = frm_start/512
                cur_sec   <= (video_off + frm_off) >> 9;
                cap_mode  <= 2'd2; ret_state <= S_FRM_NEXT;
                state <= S_RD_ISSUE;
            end

            // -------- read frame sectors into fbuf until fsize captured --------
            S_FRM_NEXT: begin
                if (bytes_got >= frm_size) begin
                    stream_pos <= 0; out_last <= 1'b0; out_valid <= 1'b0;
                    state <= S_STREAM;
                end else begin
                    cur_sec  <= cur_sec + 1'b1;
                    cap_mode <= 2'd2; ret_state <= S_FRM_NEXT;
                    state <= S_RD_ISSUE;
                end
            end

            // -------- stream fbuf[0..fsize-1] -> decoder (registered read) --------
            S_STREAM: begin                 // issue read of fbuf[stream_pos]
                fbuf_q   <= fbuf[stream_pos];
                out_last <= (stream_pos == frm_size[FBUF_AW-1:0] - 1'b1);
                state    <= S_STRM_VLD;
            end
            S_STRM_VLD: begin               // present byte; advance on accept
                out_valid <= 1'b1;
                if (out_valid && out_ready) begin
                    out_valid <= 1'b0;
                    if (out_last) begin
                        out_last <= 1'b0;
                        state    <= S_READY;
                    end else begin
                        stream_pos <= stream_pos + 1'b1;
                        state      <= S_STREAM;
                    end
                end
            end

            // ================= generic single-sector read =================
            S_RD_ISSUE: begin
                sd_lba        <= cur_sec;
                sd_blk_cnt    <= 6'd0;
                sec_base_byte <= {cur_sec, 9'd0};
                sd_rd         <= 1'b1;
                if (sd_ack) begin           // HPS accepted the request
                    sd_rd <= 1'b0;
                    state <= S_RD_XFER;
                end
            end
            S_RD_XFER: begin
                // capture bytes as hps streams them (sd_buff_wr, addr 0..511)
                if (sd_buff_wr) begin
                    case (cap_mode)
                    2'd0: begin // header: latch the u32 fields we care about
                        case (sd_buff_addr)
                        9'd16: frame_count[7:0]   <= sd_buff_dout;
                        9'd17: frame_count[15:8]  <= sd_buff_dout;
                        9'd18: frame_count[23:16] <= sd_buff_dout;
                        9'd19: frame_count[31:24] <= sd_buff_dout;
                        9'd48: index_off[7:0]     <= sd_buff_dout;
                        9'd49: index_off[15:8]    <= sd_buff_dout;
                        9'd50: index_off[23:16]   <= sd_buff_dout;
                        9'd51: index_off[31:24]   <= sd_buff_dout;
                        9'd64: video_off[7:0]     <= sd_buff_dout;
                        9'd65: video_off[15:8]    <= sd_buff_dout;
                        9'd66: video_off[23:16]   <= sd_buff_dout;
                        9'd67: video_off[31:24]   <= sd_buff_dout;
                        default: ;
                        endcase
                    end
                    2'd1: begin // index entry N: 8 bytes at idx_in_sec
                        if (sd_buff_addr == idx_in_sec + 9'd0) frm_off[7:0]    <= sd_buff_dout;
                        if (sd_buff_addr == idx_in_sec + 9'd1) frm_off[15:8]   <= sd_buff_dout;
                        if (sd_buff_addr == idx_in_sec + 9'd2) frm_off[23:16]  <= sd_buff_dout;
                        if (sd_buff_addr == idx_in_sec + 9'd3) frm_off[31:24]  <= sd_buff_dout;
                        if (sd_buff_addr == idx_in_sec + 9'd4) frm_size[7:0]   <= sd_buff_dout;
                        if (sd_buff_addr == idx_in_sec + 9'd5) frm_size[15:8]  <= sd_buff_dout;
                        if (sd_buff_addr == idx_in_sec + 9'd6) frm_size[23:16] <= sd_buff_dout;
                        if (sd_buff_addr == idx_in_sec + 9'd7) frm_size[31:24] <= sd_buff_dout;
                    end
                    2'd2: begin // frame: keep bytes within [frm_start, frm_start+frm_size)
                        // file byte position of this incoming byte
                        // (sec_base_byte + sd_buff_addr) compared to frm_start
                        if ((sec_base_byte + sd_buff_addr) >= frm_start &&
                            bytes_got < frm_size) begin
                            fbuf[bytes_got[FBUF_AW-1:0]] <= sd_buff_dout;
                            bytes_got <= bytes_got + 1'b1;
                        end
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
