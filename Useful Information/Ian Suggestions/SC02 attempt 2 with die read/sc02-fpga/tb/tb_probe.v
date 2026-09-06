`timescale 1ns/1ps
module tb_probe;
    localparam CLK_HALF = 25;
    localparam XCK_HALF = 279.365;
    reg clk=0, xck=0, rst_n=0;
    always #CLK_HALF clk=~clk;
    always #XCK_HALF xck=~xck;

    reg [7:0] d_in=0; reg [2:0] rs=0;
    reg r_w=1, cs0=0, cs1_n=1, pd_rst_n=0;
    wire ar_n, ar_oe, d7_out, d7_oe, audio_valid, audio_sd;
    wire signed [15:0] audio_pcm;

    sc02_core dut(.clk(clk),.rst_n(rst_n),.d_in(d_in),.d7_out(d7_out),.d7_oe(d7_oe),
      .rs(rs),.r_w(r_w),.cs0(cs0),.cs1_n(cs1_n),.pd_rst_n(pd_rst_n),.xck(xck),.div2(1'b0),
      .ar_n(ar_n),.ar_oe(ar_oe),.audio_pcm(audio_pcm),.audio_valid(audio_valid),
      .audio_sd(audio_sd),.rom_row_flip(1'b0));

    task wr; input [2:0] a; input [7:0] v;
    begin
        @(posedge clk); rs=a; d_in=v; r_w=0; cs0=1; cs1_n=0; #300; cs0=0; #300;
        r_w=1; cs1_n=1; #200;
    end endtask

    integer k;
    initial begin
        #2000 rst_n=1; #2000 pd_rst_n=1; #2000;
        wr(3'b100,8'hD3); wr(3'b010,8'hE8); wr(3'b001,8'h17);
        wr(3'b000,8'hC0); wr(3'b011,8'h5C);
        wr(3'b000,8'h0A);              // EH, longest duration
        $display("ff=%h fs_div=%0d rate=%h dr=%b ctl=%b mute=%b",
                 dut.ff, dut.fs_div, dut.rate, dut.dr, dut.ctl, dut.mute);
        $display("rom EH: f1=%0d f2=%0d f2q=%0d f3=%0d fa=%0d va=%0d cl=%b vd=%b pa=%b",
                 dut.rom_f1,dut.rom_f2,dut.rom_f2q,dut.rom_f3,dut.rom_fa,
                 dut.rom_va,dut.rom_closure,dut.rom_voiced,dut.rom_pause);
        for (k=0;k<12;k=k+1) begin
            #1000000;
            $display("t=%0t pitch=%0d va=%0d fa=%0d amp=%0d f1=%0d f2=%0d f3=%0d exc=%0d pcm=%0d y1_0=%0d",
              $time, dut.pitch_now, dut.va_now, dut.fa_now, dut.amp_now,
              dut.f1_now, dut.f2_now, dut.f3_now, dut.exc, audio_pcm,
              dut.u_filt.y1[0]);
        end
        $finish;
    end
endmodule
