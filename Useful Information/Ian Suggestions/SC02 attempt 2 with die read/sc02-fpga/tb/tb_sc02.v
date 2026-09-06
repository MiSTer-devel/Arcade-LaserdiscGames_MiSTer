// ---------------------------------------------------------------------------
// tb_sc02 -- drives the core exactly the way a 6502 on a Mockingboard would:
// initialise the five registers, drop CTL to leave power-down, then feed one
// phoneme per A/R request.  Captures audio_pcm to build/out.pcm.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_sc02;

    localparam CLK_HALF = 25;          // 20 MHz fabric
    localparam XCK_HALF = 279.365;     // 3.579545 MHz colourburst / 2

    reg clk = 0, xck = 0, rst_n = 0;
    always #CLK_HALF clk = ~clk;
    always #XCK_HALF xck = ~xck;

    reg  [7:0] d_in = 8'h00;
    reg  [2:0] rs   = 3'b000;
    reg        r_w = 1'b1, cs0 = 1'b0, cs1_n = 1'b1, pd_rst_n = 1'b0;
    wire       ar_n, ar_oe, d7_out, d7_oe, audio_valid, audio_sd;
    wire signed [15:0] audio_pcm;

    sc02_core #(.ROMFILE("rom/sc02_phoneme_rom.bin")) dut (
        .clk(clk), .rst_n(rst_n),
        .d_in(d_in), .d7_out(d7_out), .d7_oe(d7_oe),
        .rs(rs), .r_w(r_w), .cs0(cs0), .cs1_n(cs1_n), .pd_rst_n(pd_rst_n),
        .xck(xck), .div2(1'b0),
        .ar_n(ar_n), .ar_oe(ar_oe),
        .audio_pcm(audio_pcm), .audio_valid(audio_valid), .audio_sd(audio_sd),
        .rom_row_flip(1'b0)
    );

    // ---- host write cycle --------------------------------------------------
    task wr;
        input [2:0] a;
        input [7:0] v;
        begin
            @(posedge clk);
            rs = a; d_in = v; r_w = 1'b0; cs0 = 1'b1; cs1_n = 1'b0;  // select
            #300;
            cs0 = 1'b0;                                              // latch
            #300;
            r_w = 1'b1; cs1_n = 1'b1;
            #200;
        end
    endtask

    task say;
        input [7:0] v;          // {DR1,DR0,P5..P0}
        begin
            wait (ar_n == 1'b0);
            wr(3'b000, v);
            @(posedge clk);
        end
    endtask

    // ---- phoneme codes we need --------------------------------------------
    localparam PA=6'h00, E=6'h01, AY=6'h05, I=6'h07, A=6'h08, EH=6'h0A,
               AE=6'h0C, AH=6'h0E, AW=6'h10, OU=6'h12, OO=6'h13, U=6'h16,
               UH=6'h18, ER=6'h1C, R=6'h1D, L=6'h20, W=6'h23, B=6'h24,
               D=6'h25, T=6'h28, K=6'h29, HF=6'h2C, S=6'h30, SCH=6'h32,
               V=6'h33, F=6'h34, M=6'h37, N=6'h38;

    integer fh, n;
    initial begin
        fh = $fopen("build/out.pcm", "w");
        n  = 0;
        if ($test$plusargs("vcd")) begin
            $dumpfile("build/tb.vcd");
            $dumpvars(0, tb_sc02);
        end

        #2000 rst_n = 1'b1;
        #2000 pd_rst_n = 1'b1;
        #2000;

        // --- power-up init, in the order the datasheet recommends -----------
        wr(3'b100, 8'hD3);   // filter frequency -> ~20 kHz sample clock
        wr(3'b010, 8'hE8);   // rate = E (fast, keeps the sim short), I11=1
        wr(3'b001, 8'h17);   // inflection I10:I3, I = 2232 -> ~116 Hz
        wr(3'b000, 8'hC0);   // DR = 11 so the mode latch picks the common mode
        wr(3'b011, 8'h5C);   // CTL=0, articulation=5, amplitude=C  -> speaks

        // --- "hello world" --------------------------------------------------
        say({2'b00, HF});  say({2'b00, EH});  say({2'b01, L});
        say({2'b00, OU});  say({2'b01, OO});  say({2'b00, PA});
        say({2'b00, W});   say({2'b00, ER});  say({2'b01, L});
        say({2'b10, D});   say({2'b00, PA});

        // --- vowel sweep: proves the formant path and the interpolators -----
        say({2'b00, E});   say({2'b00, I});   say({2'b00, EH});
        say({2'b00, AE});  say({2'b00, AH});  say({2'b00, AW});
        say({2'b00, OU});  say({2'b00, U});   say({2'b00, PA});

        // --- fricatives and a stop -----------------------------------------
        say({2'b00, S});   say({2'b00, SCH}); say({2'b00, F});
        say({2'b00, V});   say({2'b00, T});   say({2'b00, K});
        say({2'b00, PA});

        wait (ar_n == 1'b0);
        #20000000;                       // let the tail ring out
        $fclose(fh);
        $display("[tb] captured %0d samples", n);
        $finish;
    end

    always @(posedge clk) begin
        if (audio_valid) begin
            $fwrite(fh, "%0d %0d\n", audio_pcm, dut.ph);
            n = n + 1;
        end
    end

    initial begin
        #4000000000;
        $display("[tb] TIMEOUT");
        $fclose(fh);
        $finish;
    end

endmodule
`default_nettype wire
