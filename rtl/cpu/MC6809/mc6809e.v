`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date:    08:11:34 09/23/2016 
// Design Name: 
// Module Name:    mc6809e 
// Project Name: 
// Target Devices: 
// Tool versions: 
// Description: 
//
// Dependencies: 
//
// Revision: 
// Revision 0.01 - File Created
// Additional Comments: 
//
//////////////////////////////////////////////////////////////////////////////////
module mc6809e(
    input   [7:0] D,
    output  [7:0] DOut,
    output  [15:0] ADDR,
    output  RnW,
    input   CLK_ROOT,
    input   CE_E_FALL,
    input   CE_Q_FALL,
    output  BS,
    output  BA,
    input   nIRQ,
    input   nFIRQ,
    input   nNMI,
    output  AVMA,
    output  BUSY,
    output  LIC,
    input   nHALT,
    input   nRESET

    );

    wire [111:0] regdata;

    mc6809is cpucore (.CLK(CLK_ROOT), .fallE_en(CE_E_FALL), .fallQ_en(CE_Q_FALL),
                .D(D), .DOut(DOut), .ADDR(ADDR), .RnW(RnW), .BS(BS), .BA(BA),
                .nIRQ(nIRQ), .nFIRQ(nFIRQ), .nNMI(nNMI), .AVMA(AVMA), .BUSY(BUSY),
                .LIC(LIC), .nHALT(nHALT), .nRESET(nRESET), .nDMABREQ(1'b1), .RegData(regdata)
                );

endmodule