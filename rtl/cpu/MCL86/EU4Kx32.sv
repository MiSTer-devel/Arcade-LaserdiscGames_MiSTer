//============================================================================
// EU4Kx32.sv — MCL86 execution-unit microcode ROM, 4096 x 32.
//
// eu.v instantiates `EU4Kx32` but the MCL86 package does NOT contain it: in the
// author's Xilinx flow it is a generated Block Memory IP initialised from one of
// the Core/*.coe files. Quartus cannot read .coe, so this is the replacement --
// an inferred ROM initialised from mcl86_microcode.hex, which was converted
// verbatim from MCL86_Microcode_Xilinx_Version_4.coe (the newest of the three;
// v4 differs from v3 in 3 words, v3 from v2 in 5).
//
// Port list matches eu.v's instantiation exactly: .clka / .addra / .douta.
// Read is registered (1-cycle latency), which is what a Xilinx BRAM in its
// default "no output register, registered address" mode also gives.
//============================================================================
module EU4Kx32
#(
    // Relative to the Quartus project root (where the .qpf lives). A testbench
    // running from another directory should override this.
    parameter MICROCODE_HEX = "rtl/cpu/MCL86/mcl86_microcode.hex"
)
(
    input             clka,
    input      [11:0] addra,
    output reg [31:0] douta
);
    (* ram_init_file = "" *) reg [31:0] rom [0:4095];

    initial $readmemh(MICROCODE_HEX, rom);

    always @(posedge clka) douta <= rom[addra];
endmodule
