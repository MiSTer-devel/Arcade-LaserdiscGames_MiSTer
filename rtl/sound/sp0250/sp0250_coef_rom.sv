//============================================================================
// SP0250 internal coefficient ROM (clocked, 2-cycle latency).
//
// 128-entry table of LPC filter coefficient magnitudes, lifted verbatim from
// MAME sp0250.cpp:122-129 (Olivier Galibert, BSD-3-Clause). These values are
// hardware-verified and not published in the GI SP0250 datasheet — do not
// "round" or "optimize" them.
//
// Byte layout (from MAME sp0250_gc):
//   idx[6:0] = 7-bit magnitude index into COEFS[]
//   idx[7]   = sign bit. bit7 SET  -> positive magnitude
//                        bit7 CLEAR -> negative magnitude (-mag)
//
// This module is clocked so Quartus can infer an M10K block ROM (~1280 bits).
// The previous combinational form got instantiated 12 times in sp0250.sv and
// blew the Cyclone V ALM budget. sp0250.sv now walks a single instance over
// 14 cycles in ST_COEF_LOAD.
//
// Latency: idx at cycle N -> val valid at cycle N+2.
//============================================================================

module sp0250_coef_rom (
    input                     clk,
    input         [7:0]       idx,
    output reg signed [15:0]  val
);

    (* ramstyle = "M10K" *) reg [9:0] COEFS [0:127];
    initial begin
        COEFS[  0]=10'd0;   COEFS[  1]=10'd9;   COEFS[  2]=10'd17;  COEFS[  3]=10'd25;
        COEFS[  4]=10'd33;  COEFS[  5]=10'd41;  COEFS[  6]=10'd49;  COEFS[  7]=10'd57;
        COEFS[  8]=10'd65;  COEFS[  9]=10'd73;  COEFS[ 10]=10'd81;  COEFS[ 11]=10'd89;
        COEFS[ 12]=10'd97;  COEFS[ 13]=10'd105; COEFS[ 14]=10'd113; COEFS[ 15]=10'd121;
        COEFS[ 16]=10'd129; COEFS[ 17]=10'd137; COEFS[ 18]=10'd145; COEFS[ 19]=10'd153;
        COEFS[ 20]=10'd161; COEFS[ 21]=10'd169; COEFS[ 22]=10'd177; COEFS[ 23]=10'd185;
        COEFS[ 24]=10'd193; COEFS[ 25]=10'd201; COEFS[ 26]=10'd209; COEFS[ 27]=10'd217;
        COEFS[ 28]=10'd225; COEFS[ 29]=10'd233; COEFS[ 30]=10'd241; COEFS[ 31]=10'd249;
        COEFS[ 32]=10'd257; COEFS[ 33]=10'd265; COEFS[ 34]=10'd273; COEFS[ 35]=10'd281;
        COEFS[ 36]=10'd289; COEFS[ 37]=10'd297; COEFS[ 38]=10'd301; COEFS[ 39]=10'd305;
        COEFS[ 40]=10'd309; COEFS[ 41]=10'd313; COEFS[ 42]=10'd317; COEFS[ 43]=10'd321;
        COEFS[ 44]=10'd325; COEFS[ 45]=10'd329; COEFS[ 46]=10'd333; COEFS[ 47]=10'd337;
        COEFS[ 48]=10'd341; COEFS[ 49]=10'd345; COEFS[ 50]=10'd349; COEFS[ 51]=10'd353;
        COEFS[ 52]=10'd357; COEFS[ 53]=10'd361; COEFS[ 54]=10'd365; COEFS[ 55]=10'd369;
        COEFS[ 56]=10'd373; COEFS[ 57]=10'd377; COEFS[ 58]=10'd381; COEFS[ 59]=10'd385;
        COEFS[ 60]=10'd389; COEFS[ 61]=10'd393; COEFS[ 62]=10'd397; COEFS[ 63]=10'd401;
        COEFS[ 64]=10'd405; COEFS[ 65]=10'd409; COEFS[ 66]=10'd413; COEFS[ 67]=10'd417;
        COEFS[ 68]=10'd421; COEFS[ 69]=10'd425; COEFS[ 70]=10'd427; COEFS[ 71]=10'd429;
        COEFS[ 72]=10'd431; COEFS[ 73]=10'd433; COEFS[ 74]=10'd435; COEFS[ 75]=10'd437;
        COEFS[ 76]=10'd439; COEFS[ 77]=10'd441; COEFS[ 78]=10'd443; COEFS[ 79]=10'd445;
        COEFS[ 80]=10'd447; COEFS[ 81]=10'd449; COEFS[ 82]=10'd451; COEFS[ 83]=10'd453;
        COEFS[ 84]=10'd455; COEFS[ 85]=10'd457; COEFS[ 86]=10'd459; COEFS[ 87]=10'd461;
        COEFS[ 88]=10'd463; COEFS[ 89]=10'd465; COEFS[ 90]=10'd467; COEFS[ 91]=10'd469;
        COEFS[ 92]=10'd471; COEFS[ 93]=10'd473; COEFS[ 94]=10'd475; COEFS[ 95]=10'd477;
        COEFS[ 96]=10'd479; COEFS[ 97]=10'd481; COEFS[ 98]=10'd482; COEFS[ 99]=10'd483;
        COEFS[100]=10'd484; COEFS[101]=10'd485; COEFS[102]=10'd486; COEFS[103]=10'd487;
        COEFS[104]=10'd488; COEFS[105]=10'd489; COEFS[106]=10'd490; COEFS[107]=10'd491;
        COEFS[108]=10'd492; COEFS[109]=10'd493; COEFS[110]=10'd494; COEFS[111]=10'd495;
        COEFS[112]=10'd496; COEFS[113]=10'd497; COEFS[114]=10'd498; COEFS[115]=10'd499;
        COEFS[116]=10'd500; COEFS[117]=10'd501; COEFS[118]=10'd502; COEFS[119]=10'd503;
        COEFS[120]=10'd504; COEFS[121]=10'd505; COEFS[122]=10'd506; COEFS[123]=10'd507;
        COEFS[124]=10'd508; COEFS[125]=10'd509; COEFS[126]=10'd510; COEFS[127]=10'd511;
    end

    reg  [9:0] mag_raw;
    reg        idx7_q;
    wire signed [15:0] mag = $signed({6'b0, mag_raw});

    always @(posedge clk) begin
        mag_raw <= COEFS[idx[6:0]];
        idx7_q  <= idx[7];
        val     <= idx7_q ? mag : -mag;
    end

endmodule