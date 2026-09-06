// ---------------------------------------------------------------------------
// sc02_rom -- 64 x 27 phoneme parameter ROM.
//
// The contents come from an external file so the community die-shot read can
// be swapped in without touching RTL.  Two orientation escapes are provided
// because the read "might be flipped 180 degrees":
//
//   row_flip  (input pin, changeable at runtime)  addresses ~phoneme instead
//             of phoneme, i.e. tests "last row is phoneme 0" without a rebuild
//   bit order (build time)  handled by tools/rom_build.py --bit-reverse
//
// Wire row_flip to a DIP switch / spare register bit, play a known phrase both
// ways, keep whichever is speech.
// ---------------------------------------------------------------------------
`default_nettype none

module sc02_rom #(
    parameter ROMFILE = "rom/sc02_phoneme_rom.bin"
) (
    input  wire        clk,
    input  wire [5:0]  phoneme,
    input  wire        row_flip,

    output reg  [3:0]  f1,
    output reg  [4:0]  f2,
    output reg  [2:0]  f2q,
    output reg  [3:0]  f3,
    output reg  [3:0]  fa,
    output reg  [3:0]  va,
    output reg         closure,
    output reg         voiced,
    output reg         pause
);

    reg [26:0] mem [0:63];
    initial $readmemb(ROMFILE, mem);

    wire [5:0]  addr = row_flip ? ~phoneme : phoneme;
    wire [26:0] w    = mem[addr];

    // Field map -- must match FIELDS in tools/rom_build.py
    always @(posedge clk) begin
        f1      <= w[26:23];
        f2      <= w[22:18];
        f2q     <= w[17:15];
        f3      <= w[14:11];
        fa      <= w[10:7];
        va      <= w[6:3];
        closure <= w[2];
        voiced  <= w[1];
        pause   <= w[0];
    end

endmodule
`default_nettype wire
