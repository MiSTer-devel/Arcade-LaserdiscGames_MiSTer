//============================================================================
//
//  Kangaroo ROM loader
//  ROM layout matched to MAME kangaroo.cpp
//
//============================================================================

// ROM layout for Kangaroo:
//
// Index 0 — Main CPU program ROMs (24KB):
//   0x0000 - 0x0FFF = tvg_75 (IC7)
//   0x1000 - 0x1FFF = tvg_76 (IC8)
//   0x2000 - 0x2FFF = tvg_77 (IC9)
//   0x3000 - 0x3FFF = tvg_78 (IC10)
//   0x4000 - 0x4FFF = tvg_79 (IC16)
//   0x5000 - 0x5FFF = tvg_80 (IC17)
//
// Index 1 — Sound CPU program ROM (4KB):
//   0x0000 - 0x0FFF = tvg_81 (IC24)
//
// Index 2 — Blitter GFX ROMs (16KB):
//   0x0000 - 0x0FFF = tvg_83/v0 (IC76)
//   0x1000 - 0x1FFF = tvg_85/v2 (IC77)
//   0x2000 - 0x2FFF = tvg_84/v1 (IC52)
//   0x3000 - 0x3FFF = tvg_86/v3 (IC53)

// Main CPU ROM selector (active during ioctl_index == 0)
module selector
(
    input  logic [24:0] ioctl_addr,
    output logic rom0_cs, rom1_cs, rom2_cs, rom3_cs, rom4_cs, rom5_cs
);
    always_comb begin
        {rom0_cs, rom1_cs, rom2_cs, rom3_cs, rom4_cs, rom5_cs} = 0;

        if(ioctl_addr < 'h1000)      rom0_cs = 1;
        else if(ioctl_addr < 'h2000) rom1_cs = 1;
        else if(ioctl_addr < 'h3000) rom2_cs = 1;
        else if(ioctl_addr < 'h4000) rom3_cs = 1;
        else if(ioctl_addr < 'h5000) rom4_cs = 1;
        else if(ioctl_addr < 'h6000) rom5_cs = 1;
    end
endmodule

// Blitter ROM selector (active during ioctl_index == 2)
module blit_selector
(
    input  logic [24:0] ioctl_addr,
    output logic blit0_cs, blit1_cs, blit2_cs, blit3_cs
);
    always_comb begin
        {blit0_cs, blit1_cs, blit2_cs, blit3_cs} = 0;

        if(ioctl_addr < 'h1000)      blit0_cs = 1;
        else if(ioctl_addr < 'h2000) blit1_cs = 1;
        else if(ioctl_addr < 'h3000) blit2_cs = 1;
        else if(ioctl_addr < 'h4000) blit3_cs = 1;
    end
endmodule

////////////
// EPROMS //
////////////

// Generic 4KB ROM module (12-bit address)
module eprom_4k
(
    input  logic        CLK,
    input  logic        CLK_DL,
    input  logic [11:0] ADDR,
    input  logic [24:0] ADDR_DL,
    input  logic  [7:0] DATA_IN,
    input  logic        CS_DL,
    input  logic        WR,
    output logic  [7:0] DATA
);
    dpram_dc #(.widthad_a(12)) rom
    (
        .clock_a(CLK),
        .address_a(ADDR[11:0]),
        .q_a(DATA[7:0]),

        .clock_b(CLK_DL),
        .address_b(ADDR_DL[11:0]),
        .data_b(DATA_IN),
        .wren_b(WR & CS_DL)
    );
endmodule
