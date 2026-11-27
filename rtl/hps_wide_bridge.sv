module hps_wide_bridge
(
	input             clk,
	input             reset,

	input             w_ioctl_wr,
	input      [26:0] w_ioctl_addr,
	input      [15:0] w_ioctl_dout,
	output            w_ioctl_wait,

	output reg        b_ioctl_wr,
	output reg [26:0] b_ioctl_addr,
	output reg  [7:0] b_ioctl_dout,
	input             b_ioctl_wait,

	input             w_sd_ack,
	input      [12:0] w_sd_buff_addr,
	input      [15:0] w_sd_buff_dout,
	input             w_sd_buff_wr,

	output            b_sd_ack,
	output reg [13:0] b_sd_buff_addr,
	output reg  [7:0] b_sd_buff_dout,
	output reg        b_sd_buff_wr
);

localparam IO_IDLE = 3'd0, IO_B0 = 3'd1, IO_GAP = 3'd2, IO_B1 = 3'd3, IO_HOLD = 3'd4;
reg  [2:0] io_st;
reg  [1:0] io_gap;
reg [26:0] io_addr;
reg [15:0] io_word;

assign w_ioctl_wait = (io_st != IO_IDLE) | b_ioctl_wait;

always @(posedge clk) begin
	b_ioctl_wr <= 1'b0;
	if (reset) begin
		io_st  <= IO_IDLE;
		io_gap <= 2'd0;
	end else begin
		case (io_st)
		IO_IDLE:
			if (w_ioctl_wr) begin
				io_addr <= w_ioctl_addr;
				io_word <= w_ioctl_dout;
				io_st   <= IO_B0;
			end
		IO_B0:
			if (!b_ioctl_wait) begin
				b_ioctl_wr   <= 1'b1;
				b_ioctl_addr <= io_addr;
				b_ioctl_dout <= io_word[7:0];
				io_gap       <= 2'd3;
				io_st        <= IO_GAP;
			end
		IO_GAP:
			if (io_gap != 2'd0) io_gap <= io_gap - 2'd1;
			else io_st <= IO_B1;
		IO_B1:
			if (!b_ioctl_wait) begin
				b_ioctl_wr   <= 1'b1;
				b_ioctl_addr <= io_addr + 27'd1;
				b_ioctl_dout <= io_word[15:8];
				io_gap       <= 2'd3;
				io_st        <= IO_HOLD;
			end
		IO_HOLD:
			if (io_gap != 2'd0) io_gap <= io_gap - 2'd1;
			else io_st <= IO_IDLE;
		default: io_st <= IO_IDLE;
		endcase
	end
end

reg        sd_pend;
reg  [7:0] sd_hi;
reg  [2:0] ack_dly;

assign b_sd_ack = w_sd_ack | (|ack_dly);

always @(posedge clk) begin
	b_sd_buff_wr <= 1'b0;
	ack_dly <= {ack_dly[1:0], w_sd_ack};
	if (reset) begin
		sd_pend <= 1'b0;
		ack_dly <= 3'd0;
	end else if (w_sd_buff_wr) begin
		b_sd_buff_wr   <= 1'b1;
		b_sd_buff_addr <= {w_sd_buff_addr, 1'b0};
		b_sd_buff_dout <= w_sd_buff_dout[7:0];
		sd_hi          <= w_sd_buff_dout[15:8];
		sd_pend        <= 1'b1;
	end else if (sd_pend) begin
		b_sd_buff_wr   <= 1'b1;
		b_sd_buff_addr <= b_sd_buff_addr + 14'd1;
		b_sd_buff_dout <= sd_hi;
		sd_pend        <= 1'b0;
	end
end

endmodule
