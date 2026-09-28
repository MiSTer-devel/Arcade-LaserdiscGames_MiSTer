//============================================================================
// gpw_sprites.sv — GP World sprite line renderer (Daphne gpworld::draw_sprite).
//
// Double-buffered line buffer: while overlay line V is on screen, line V+1 is
// cleared and every sprite crossing it is drawn into the other half. A new
// overlay line swaps the halves and restarts, so an unfinished line shows
// whatever was drawn in time (sprites missing on the right), never a hang.
//
// Sprite list: 64 x 8 bytes {y_top, y_bot, x_lo, x_hi, skip_lo, skip_hi,
// src_lo, src_hi}. A sprite covers rows y_top+1 .. y_bot. Each row starts at
// src + skip*(row+1); src bit 15 walks the row backwards with the pixel order
// reversed. One 16-bit graphics word = {plane1 byte, plane0 byte} = 4 pixels,
// read from bank x_hi[3:1]. The row ends on pen F in the last pixel read
// (low nibble of plane 0 forwards, high nibble of plane 1 backwards). Pens 0
// and F are transparent. Later sprites overwrite earlier ones.
//
// Output px = {colour, pen}; pen 0 = no sprite at this column.
//============================================================================
module gpw_sprites
(
    input             clk,
    input             reset,        // active LOW

    // ---- sprite RAM, registered read (dpram_dc port B) ----
    output reg [10:0] spr_a,
    input       [7:0] spr_q,

    // ---- graphics words: {bank[2:0], addr[14:0]} -> {plane1, plane0} ----
    output reg        rd_req,       // 1-cycle
    output reg [17:0] rd_addr,
    input             rd_valid,     // 1-cycle
    input      [15:0] rd_data,

    // ---- raster ----
    input      [15:0] vpos,         // overlay line, 0..239 visible
    input signed [8:0] v_ofs,       // sprite row = overlay line + v_ofs; rows outside 0..255 are empty
    input       [8:0] src_x,        // 0..359
    output      [7:0] px
);
    localparam [10:0] X_ORG = 11'd152;   // 19 tile columns

    //------------------------------------------------------ line buffer ------
    reg        front;
    reg  [8:0] lb_wa;
    reg  [7:0] lb_wd;
    reg        lb_we;
    dpram_dc #(.widthad_a(10), .width_a(8)) u_lb (
        .clock_a(clk), .address_a({~front, lb_wa}), .data_a(lb_wd), .wren_a(lb_we), .q_a(),
        .clock_b(clk), .address_b({front, src_x}), .data_b(8'd0), .wren_b(1'b0), .q_b(px)
    );

    //------------------------------------------------------ renderer ---------
    localparam [3:0] S_IDLE = 4'd0, S_CLR = 4'd1, S_RD = 4'd2, S_EV1 = 4'd3, S_EV2 = 4'd4,
                     S_FETCH = 4'd5, S_WAIT = 4'd6, S_PUT = 4'd7;
    reg  [3:0]  st;
    reg  [15:0] vpos_q;
    reg  [7:0]  tgt_y;              // sprite-space row being drawn
    reg         tgt_ok;             // tgt_y is inside the sprite space
    reg  [5:0]  idx;
    reg  [3:0]  k;
    reg  [7:0]  b [0:7];
    reg  [7:0]  row1;               // row + 1
    reg         vis;
    reg  [15:0] prod;
    reg         dir;
    reg  [14:0] a;
    reg  [2:0]  bank;
    reg  [3:0]  colour;
    reg signed [11:0] x;
    reg  [6:0]  grp;
    reg  [15:0] pix4;               // four pens, first-drawn in [15:12]
    reg         row_end;
    reg  [1:0]  j;
    reg         rd_pend, rd_drop;

    // Next line to draw: V+1, and line 0 is drawn during the lines after the last visible one.
    wire [15:0] vnext   = (vpos >= 16'd239) ? 16'd0 : vpos + 16'd1;
    wire signed [10:0] ty = $signed({3'b000, vnext[7:0]}) + $signed({{2{v_ofs[8]}}, v_ofs});
    wire [3:0]  pen     = pix4[15:12];
    wire signed [11:0] xj = x + $signed({10'd0, j});
    wire [31:0] prod_w   = {b[5], b[4]} * {8'd0, row1};
    wire [15:0] rowsrc   = {b[7], b[6]} + prod;
    // Row continues after this group: the SAME test gates the prefetch and the write stage.
    wire        end_now  = dir ? (rd_data[15:12] == 4'hF) : (rd_data[3:0] == 4'hF);
    wire        row_more = !(end_now || (grp == 7'd127) || (x + 12'sd4 >= 12'sd360));

    always @(posedge clk) begin
        rd_req <= 1'b0;
        lb_we  <= 1'b0;
        if (!reset) begin
            st <= S_IDLE; front <= 1'b0; vpos_q <= 16'hFFFF;
            rd_pend <= 1'b0; rd_drop <= 1'b0;
        end else begin
            if (rd_valid) begin rd_pend <= 1'b0; rd_drop <= 1'b0; end

            vpos_q <= vpos;
            if (vpos != vpos_q) begin
                front <= ~front;
                tgt_y  <= ty[7:0];
                tgt_ok <= (ty >= 11'sd0) && (ty < 11'sd256);
                lb_wa <= 9'd0;
                st    <= S_CLR;
                if (rd_pend && !rd_valid) rd_drop <= 1'b1;
            end else case (st)
                S_IDLE: ;

                // Only columns 0..359 are ever displayed.
                S_CLR: begin
                    lb_we <= 1'b1; lb_wd <= 8'd0;
                    if (lb_we) lb_wa <= lb_wa + 9'd1;
                    if (lb_we && lb_wa == 9'd358) begin
                        idx <= 6'd0; k <= 4'd0; st <= tgt_ok ? S_RD : S_IDLE;
                    end
                end

                // Registered read: the byte addressed at step k arrives at step k+2.
                S_RD: begin
                    if (k < 4'd8) spr_a <= {2'b00, idx, k[2:0]};
                    if (k >= 4'd2) b[k[2:0] - 3'd2] <= spr_q;
                    k <= k + 4'd1;
                    if (k == 4'd9) st <= S_EV1;
                    // y_top has arrived and y_bot is on spr_q: skip a sprite that misses this line.
                    if (k == 4'd3 && !((spr_q != 8'd0) && (spr_q > b[0]) && (tgt_y > b[0]) && (tgt_y <= spr_q))) begin
                        k <= 4'd0;
                        if (idx == 6'd63) st <= S_IDLE; else idx <= idx + 6'd1;
                    end
                end

                S_EV1: begin
                    vis  <= (b[1] != 8'd0) && (b[1] > b[0]) && (tgt_y > b[0]) && (tgt_y <= b[1]);
                    row1 <= tgt_y - b[0];
                    st   <= S_EV2;
                end

                S_EV2: begin
                    if (!vis) st <= S_FETCH;          // S_FETCH with vis=0 moves to the next sprite
                    else begin
                        prod <= prod_w[15:0];
                        st   <= S_FETCH;
                    end
                    bank   <= b[3][3:1];
                    colour <= b[3][7:4];
                    x      <= $signed({3'b000, b[3][0], b[2]}) - $signed({1'b0, X_ORG});
                    grp    <= 7'd0;
                    k      <= 4'd0;                   // 0 = row start not yet computed
                end

                S_FETCH: begin
                    if (!vis) begin
                        if (idx == 6'd63) st <= S_IDLE;
                        else begin idx <= idx + 6'd1; k <= 4'd0; st <= S_RD; end
                    end else if (k == 4'd0) begin
                        // row start = src + skip*(row+1); only the low 16 bits matter
                        dir <= rowsrc[15];
                        a   <= rowsrc[14:0];
                        k   <= 4'd1;
                    end else if (!rd_pend && !rd_drop) begin
                        rd_addr <= {bank, a};
                        rd_req  <= 1'b1;
                        rd_pend <= 1'b1;
                        st      <= S_WAIT;
                    end
                end

                S_WAIT: begin
                    if (rd_valid && !rd_drop) begin
                        pix4    <= dir ? {rd_data[3:0], rd_data[7:4], rd_data[11:8], rd_data[15:12]}
                                       : rd_data;
                        row_end <= !row_more;
                        a       <= dir ? a - 15'd1 : a + 15'd1;
                        j       <= 2'd0;
                        st      <= S_PUT;
                        // Fetch the next group while this one is written.
                        if (row_more) begin
                            rd_addr <= {bank, dir ? a - 15'd1 : a + 15'd1};
                            rd_req  <= 1'b1;
                            rd_pend <= 1'b1;
                        end
                    end
                end

                S_PUT: begin
                    if ((pen != 4'h0) && (pen != 4'hF) && (xj >= 12'sd0) && (xj < 12'sd360)) begin
                        lb_wa <= xj[8:0];
                        lb_wd <= {colour, pen};
                        lb_we <= 1'b1;
                    end
                    pix4 <= {pix4[11:0], 4'h0};
                    j    <= j + 2'd1;
                    if (j == 2'd3) begin
                        x   <= x + 12'sd4;
                        grp <= grp + 7'd1;
                        // row done: vis=0 makes S_FETCH advance; otherwise the next group is in flight
                        if (row_end) begin vis <= 1'b0; st <= S_FETCH; end
                        else st <= S_WAIT;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
