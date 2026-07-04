//============================================================================
//
//  Dragon's Lair / Space Ace (US set) top-level game module
//  Copyright (C) 2026 Rodimus
//  Based on MAME dlair.cpp
//
//  Thin wrapper around DragonsLair_CPU (which now contains the Z80, AY-3-8910,
//  work RAM, program ROM, the LaserDisc stub, the LED latches and the periodic
//  IRQ0).  There is no separate sound board — the AY is driven directly from
//  the main Z80 inside DragonsLair_CPU.
//
//============================================================================

module DragonsLair
(
    input                reset,       // active LOW
    input                clk_sys,

    // Player inputs (active HIGH)
    input          [7:0] p1,          // {3'b0, btn1, right, left, down, up}
    input          [3:0] cab,         // {coin2, coin1, start2, start1}

    // Option switches: dsw[7:0]=DSW1 (AY port A), dsw[15:8]=DSW2 (AY port B)
    input         [15:0] dsw,

    // Video outputs
    output               video_hsync, video_vsync,
    output               video_hblank, video_vblank,
    output               ce_pix,
    output         [7:0] video_r, video_g, video_b,

    // Audio
    output signed [15:0] sound_l,
    output signed [15:0] sound_r,

    // ROM loading
    input         [24:0] ioctl_addr,
    input          [7:0] ioctl_data,
    input                ioctl_wr,
    input          [7:0] ioctl_index,

    input                pause,

    output               dbg_led
);

//------------------------------------------------------- ROM Selector --------------------------------------------------------//

// Main CPU program ROMs = ioctl index 0, loaded contiguously 0x0000-0x9FFF.
wire rom_cs = (ioctl_index == 8'd0);

//------------------------------------------------------- CPU Board -----------------------------------------------------------//

wire signed [15:0] snd;

DragonsLair_CPU cpu_board
(
    .reset(reset),
    .clk_sys(clk_sys),

    .p1(p1),
    .cab(cab),
    .dsw(dsw),

    .video_r(video_r),
    .video_g(video_g),
    .video_b(video_b),
    .video_hsync(video_hsync),
    .video_vsync(video_vsync),
    .video_hblank(video_hblank),
    .video_vblank(video_vblank),
    .ce_pix(ce_pix),

    .sound(snd),

    .rom_cs_i(rom_cs),
    .ioctl_addr(ioctl_addr),
    .ioctl_data(ioctl_data),
    .ioctl_wr(ioctl_wr),

    .pause(pause),

    .dbg_led(dbg_led)
);

// Mono -> stereo
assign sound_l = snd;
assign sound_r = snd;

endmodule
