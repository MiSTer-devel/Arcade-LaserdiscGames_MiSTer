//============================================================================
//
//  Dragon's Lair / Space Ace (US set) top-level game module
//  Copyright (C) 2026 Rodimus
//  Based on MAME dlair.cpp
//
//  Thin wrapper around DragonsLair_CPU (which now contains the Z80, AY-3-8910,
//  work RAM, program ROM, the LaserDisc HLE, the LED latches and the periodic
//  IRQ0).  There is no separate sound board — the AY is driven directly from
//  the main Z80 inside DragonsLair_CPU. No video output of its own — all game
//  video is on the LaserDisc, decoded/composited in the top file (rtl/video/).
//
//============================================================================

module DragonsLair
(
    input                reset,       // active LOW
    input                clk_sys,

    // Player inputs (active HIGH)
    input          [7:0] p1,          // {skill3,skill2,skill1, btn1, right, left, down, up}
    input          [3:0] cab,         // {coin2, coin1, start2, start1}

    // Option switches: dsw[7:0]=DSW1 (AY port A), dsw[15:8]=DSW2 (AY port B)
    input         [15:0] dsw,

    // Audio
    output signed [15:0] sound_l,
    output signed [15:0] sound_r,

    // ROM loading
    input         [24:0] ioctl_addr,
    input          [7:0] ioctl_data,
    input                ioctl_wr,
    input          [7:0] ioctl_index,

    input                pause,
    input                disc_hold,   // LD-HOLD-SYNC-2026-08-13: video path priming -> freeze disc motion

    output        [63:0] led_digits_o,
    output               dbg_led,
    output               ld_search_cmd_o, // SEEK-HOLD-2026-07-20: Z80's CMD_SEARCH accepted (1-cyc)
    output        [16:0] ld_frame_o,   // HLE-DRIVE-2026-07-04: LD disc frame -> streamer
    output               ld_playing_o  // AUDIO-GATE-2026-07-05: LD playing flag -> streamer audio gate
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

    .sound(snd),

    .rom_cs_i(rom_cs),
    .ioctl_addr(ioctl_addr),
    .ioctl_data(ioctl_data),
    .ioctl_wr(ioctl_wr),

    .pause(pause),
    .disc_hold(disc_hold),   // LD-HOLD-SYNC-2026-08-13

    .led_digits_o(led_digits_o),
    .dbg_led(dbg_led),
    .search_cmd_o(ld_search_cmd_o),   // SEEK-HOLD-2026-07-20
    .ld_frame_o(ld_frame_o),
    .ld_playing_o(ld_playing_o)
);

// Mono -> stereo
assign sound_l = snd;
assign sound_r = snd;

endmodule
