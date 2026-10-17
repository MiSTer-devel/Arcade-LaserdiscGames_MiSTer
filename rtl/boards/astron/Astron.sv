//============================================================================
// Astron Belt (Sega, 1983) — Pioneer main board 834-5174: Z80 + LD-V1000.
// Schematic: Useful Information/schematics/AstronBelt.sch.pdf; facts and the
// Daphne differences are in Claude/astron_schematic_facts.md.
//
// Memory:  0000-7FFF ROM               8000-BFFF banked ROM (bank = D0 of ANY OUT)
//          C000-C7FF OBJ (sprite) RAM  C800-CFFF LD-V1000 latches
//          D000-D003 DSW A, DSW B, IN0, IN1 (active low)
//          D800-D803 8255 "OUT": A sound, B {FADE,NMIE,CHC,lamps,meters}, C unused
//          E000-E1FF colour RAM (12-bit, sprites only)
//          E800-E803 2nd 8255 "COORD" (unused connector; read back as written)
//          F000-F7FF FIX (tile) RAM, only F000-F3FF is displayed
//          F800-FFFF work RAM
// IRQ:     the VBLANK level itself. Our raster is not genlocked to the disc, so
//          a VBLANK-length window is opened once per field at the LD-V1000
//          command strobe, as GP World times its IRQ.
// NMI:     LD-V1000 strobe, gated by NMIE (8255 PB6).
// Video:   32x32 tiles, 2bpp, colour straight from PROM 5279; drawn over the disc
//          wherever the colour is non-zero. Sprites: not yet (step 2).
// Sound:   discrete analog board 834-5195, not implemented (disc audio only).
//============================================================================

module Astron
#(
    parameter [31:0] CLK_HZ = 32'd80_000_000,
    parameter [31:0] CPU_HZ = 32'd5_000_000      // 20 MHz XTAL / 4 (sheet 1, IC44)
)
(
    input                reset,        // active LOW
    input                clk_sys,

    input          [7:0] p1,           // {-,-,cont,fire, right,left,down,up} active HIGH
    input          [3:0] cab,          // {coin2, coin1, start2, start1} active HIGH
    input                service,
    input         [15:0] dsw,          // dsw[7:0] = DSW A ($D000), dsw[15:8] = DSW B ($D001)

    output signed [15:0] sound_l,
    output signed [15:0] sound_r,

    // ---- shared program ROM (64K: 5282, 5283, 5284 = bank 0, 5285 = bank 1) ----
    output        [15:0] rom_addr,
    input          [7:0] rom_data,

    // ---- shared graphics ROM (char generator 5280/5281, 4K) ----
    output        [12:0] chr_rom_a,
    input          [7:0] chr_rom_q,

    // ---- ROM download, for the tile colour PROM ----
    input         [24:0] ioctl_addr,
    input          [7:0] ioctl_data,
    input                ioctl_wr,
    input          [7:0] ioctl_index,

    input                pause,
    input                disc_hold,
    input          [3:0] post_seek_frames,
    input                disc_2997,
    input         [16:0] disc_leader,

    output               ld_search_cmd_o,
    output               ld_play_end_o,
    output        [16:0] ld_frame_o,
    output               ld_playing_o,

    // ---- overlay ----
    input         [15:0] ovl_hraw,     // 512-wide raster column
    input         [15:0] ovl_vpos,
    input         [15:0] ovl_vnext,    // ovl_vpos of the next raster line (hblank prefetch)
    input                ovl_ce_pix,
    output reg    [23:0] ovl_rgb,
    output reg           ovl_opaque,

    // Sticky: solid once the CPU writes the OUT 8255.
    output               dbg_led,

    // ---- shared chip pool (Arcade-LaserdiscGames.sv) ----
    output chip_pool_pkg::z80w_i_t z80w_0_i,
    input  chip_pool_pkg::z80w_o_t z80w_0_o,
    output chip_pool_pkg::ldp_i_t  ldp_0_i,
    input  chip_pool_pkg::ldp_o_t  ldp_0_o,
    output chip_pool_pkg::ram_i_t  ram0_i,      // work RAM
    input  chip_pool_pkg::ram_o_t  ram0_o,
    output chip_pool_pkg::ram_i_t  ram1_i,      // FIX (tile) RAM
    input  chip_pool_pkg::ram_o_t  ram1_o,
    output chip_pool_pkg::ram_i_t  ram2_i,      // OBJ (sprite) RAM
    input  chip_pool_pkg::ram_o_t  ram2_o,
    output chip_pool_pkg::ram_i_t  ram3_i,      // colour RAM, even bytes
    input  chip_pool_pkg::ram_o_t  ram3_o,
    output chip_pool_pkg::ram_i_t  ram4_i,      // colour RAM, odd bytes
    input  chip_pool_pkg::ram_o_t  ram4_o
);

    // Schematic: the video side of FIX RAM sees only F000-F3FF. Daphne instead
    // copies writes to F400-F7FF onto F000-F3FF. 1 = Daphne's behaviour.
    localparam FIX_MIRROR = 1'b0;

    // Tile colour PROM 5279 lands at this offset of ioctl index 0 (see the MRA).
    localparam [24:0] PROM_5279 = 25'h11000;

    //--------------------------------------------------------- clocking ------
    localparam [5:0] CDIV = CLK_HZ / CPU_HZ;
    reg [5:0] cdiv;
    reg       cpu_ce;
    always @(posedge clk_sys) begin
        if (!reset) begin cdiv <= 6'd0; cpu_ce <= 1'b0; end
        else if (pause) cpu_ce <= 1'b0;
        else begin
            cpu_ce <= (cdiv == CDIV - 6'd1);
            cdiv   <= (cdiv == CDIV - 6'd1) ? 6'd0 : cdiv + 6'd1;
        end
    end

    //--------------------------------------------------------- CPU -----------
    wire [15:0] cpu_A;
    wire  [7:0] cpu_Dout;
    reg   [7:0] cpu_Din;
    wire        n_rd, n_wr, n_mreq, n_iorq, n_m1;
    reg         n_nmi;
    wire        n_irq;

    // The shared T80 (z80w_0).
    assign z80w_0_i.ce = cpu_ce;  assign z80w_0_i.wait_n = 1'b1;
    assign z80w_0_i.int_n = n_irq;  assign z80w_0_i.nmi_n = n_nmi;  assign z80w_0_i.di = cpu_Din;
    assign cpu_A = z80w_0_o.a;  assign cpu_Dout = z80w_0_o.dout;
    assign n_m1 = z80w_0_o.m1_n;  assign n_mreq = z80w_0_o.mreq_n;  assign n_iorq = z80w_0_o.iorq_n;
    assign n_rd = z80w_0_o.rd_n;  assign n_wr = z80w_0_o.wr_n;

    wire mem_access = ~n_mreq;
    wire io_access  = ~n_iorq & n_m1;

    //--------------------------------------------------------- memory --------
    wire cs_rom   = mem_access & ~(cpu_A[15] & cpu_A[14]);         // 0000-BFFF
    wire cs_obj   = mem_access & (cpu_A[15:11] == 5'b11000);       // C000-C7FF
    wire cs_ldp   = mem_access & (cpu_A[15:11] == 5'b11001);       // C800-CFFF
    wire cs_sw    = mem_access & (cpu_A[15:11] == 5'b11010);       // D000-D7FF
    wire cs_out   = mem_access & (cpu_A[15:11] == 5'b11011);       // D800-DFFF
    wire cs_col   = mem_access & (cpu_A[15:11] == 5'b11100);       // E000-E7FF
    wire cs_coord = mem_access & (cpu_A[15:11] == 5'b11101);       // E800-EFFF
    wire cs_fix   = mem_access & (cpu_A[15:11] == 5'b11110);       // F000-F7FF
    wire cs_ram   = mem_access & (cpu_A[15:11] == 5'b11111);       // F800-FFFF

    // Bank flip-flop IC45a: D0 of any OUT, no port decode. Reset selects 5284.
    reg bank;
    always @(posedge clk_sys) begin
        if (!reset) bank <= 1'b0;
        else if (cpu_ce && io_access && ~n_wr) bank <= cpu_Dout[0];
    end

    assign rom_addr = cpu_A[15] ? {1'b1, bank, cpu_A[13:0]} : cpu_A;

    wire [7:0] obj_cpu_D, col_lo_cpu_D, col_hi_cpu_D, fix_cpu_D, ram_D;

    // Work RAM: the shared ram0 block.
    assign ram0_i.a_addr = {3'd0, cpu_A[10:0]};  assign ram0_i.a_we = cs_ram & ~n_wr;
    assign ram0_i.a_din = cpu_Dout;  assign ram0_i.b_addr = 14'd0;
    assign ram_D = ram0_o.a_q;

    // OBJ RAM: the shared ram2 block; port B is the sprite engine's (step 2).
    assign ram2_i.a_addr = {3'd0, cpu_A[10:0]};  assign ram2_i.a_we = cs_obj & ~n_wr;
    assign ram2_i.a_din = cpu_Dout;  assign ram2_i.b_addr = 14'd0;
    assign obj_cpu_D = ram2_o.a_q;

    // Colour RAM, 256 x 12, split by byte lane (even = G/R, odd = B): the shared ram3 / ram4
    // blocks. Sprites only (step 2).
    assign ram3_i.a_addr = {6'd0, cpu_A[8:1]};  assign ram3_i.a_we = cs_col & ~n_wr & ~cpu_A[0];
    assign ram3_i.a_din = cpu_Dout;  assign ram3_i.b_addr = 14'd0;
    assign col_lo_cpu_D = ram3_o.a_q;
    assign ram4_i.a_addr = {6'd0, cpu_A[8:1]};  assign ram4_i.a_we = cs_col & ~n_wr &  cpu_A[0];
    assign ram4_i.a_din = cpu_Dout;  assign ram4_i.b_addr = 14'd0;
    assign col_hi_cpu_D = ram4_o.a_q;

    // FIX RAM (IC69 2016): the shared ram1 block. FIX_MIRROR folds the upper 1K onto the displayed half.
    wire [10:0] fix_cpu_A = FIX_MIRROR ? {1'b0, cpu_A[9:0]} : cpu_A[10:0];
    wire  [9:0] fix_rd_A;
    wire  [7:0] fix_rd_D;
    assign ram1_i.a_addr = {3'd0, fix_cpu_A};  assign ram1_i.a_we = cs_fix & ~n_wr;
    assign ram1_i.a_din = cpu_Dout;  assign ram1_i.b_addr = {4'd0, fix_rd_A};
    assign fix_cpu_D = ram1_o.a_q;  assign fix_rd_D = ram1_o.b_q;

    // Tile colour PROM 5279 (IC92 82S141, 512 x 8).
    wire [8:0] prom_rd_A;
    wire [7:0] prom_D;
    wire prom_we = ioctl_wr & (ioctl_index == 8'd0) &
                   (ioctl_addr >= PROM_5279) & (ioctl_addr < PROM_5279 + 25'h200);
    dpram_dc #(.widthad_a(9)) u_prom (
        .clock_a(clk_sys), .address_a(prom_rd_A), .q_a(prom_D),
        .wren_a(1'b0), .data_a(8'd0),
        .clock_b(clk_sys), .address_b(ioctl_addr[8:0]), .data_b(ioctl_data),
        .wren_b(prom_we), .q_b()
    );

    //--------------------------------------------------------- 8255s ---------
    // OUT (IC102). Reset and every mode-set word clear the outputs; until the ROM
    // programs it the ports float, and NMIE's pull-down (R17) holds NMI off.
    reg [7:0] pa, pb, pc;
    reg       out_seen;
    always @(posedge clk_sys) begin
        if (!reset) begin pa <= 8'd0; pb <= 8'd0; pc <= 8'd0; out_seen <= 1'b0; end
        else if (cpu_ce && cs_out && ~n_wr) begin
            out_seen <= 1'b1;
            case (cpu_A[1:0])
                2'd0: pa <= cpu_Dout;
                2'd1: pb <= cpu_Dout;
                2'd2: pc <= cpu_Dout;
                2'd3: if (cpu_Dout[7]) begin pa <= 8'd0; pb <= 8'd0; pc <= 8'd0; end
                      else pc[cpu_Dout[3:1]] <= cpu_Dout[0];
            endcase
        end
    end
    assign dbg_led = out_seen;
    wire chc    = pb[5];        // tile colour PROM A7
    wire nmi_en = pb[6];        // NMIE
    // pa = sound board command, pb[7] = disc FADE, pb[4:0] = lamps / coin meters: unused here.

    reg [7:0] out_D;
    always @(*) begin
        case (cpu_A[1:0])
            2'd0:    out_D = pa;
            2'd1:    out_D = pb;
            2'd2:    out_D = pc;
            default: out_D = 8'hFF;
        endcase
    end

    // COORD (IC91) drives a connector nothing on Astron uses. Read back as written (Daphne).
    reg [7:0] coord [0:3];
    always @(posedge clk_sys)
        if (cpu_ce && cs_coord && ~n_wr) coord[cpu_A[1:0]] <= cpu_Dout;

    //--------------------------------------------------------- inputs --------
    // IN0: b0 COIN1, b1 COIN2, b2 TEST, b3 SERVICE, b4 START1, b6 START2/CONTINUE.
    // IN1: b0 RIGHT, b1 LEFT, b2 UP, b3 DOWN, b4 FIRE.  (MAME segald, Daphne astron)
    wire [7:0] in0 = ~{1'b0, cab[1] | p1[5], 1'b0, cab[0], service, 1'b0, cab[3], cab[2]};
    // DIAG-REVERT-2026-10-16: original (MAME: b2 UP, b3 DOWN) below
    // wire [7:0] in1 = ~{3'b000, p1[4], p1[1], p1[0], p1[2], p1[3]};
    // DIAG: Daphne astron.cpp input_enable -- UP clears 0x08, DOWN clears 0x04 (MAME has them swapped).
    wire [7:0] in1 = ~{3'b000, p1[4], p1[0], p1[1], p1[2], p1[3]};

    reg [7:0] sw_D;
    always @(*) begin
        case (cpu_A[1:0])
            2'd0: sw_D = dsw[7:0];
            2'd1: sw_D = dsw[15:8];
            2'd2: sw_D = in0;
            2'd3: sw_D = in1;
        endcase
    end

    //--------------------------------------------------------- LD player -----
    wire [7:0] ld_status;
    wire       ld_cmd_strobe;
    reg  [7:0] ld_out_latch, ld_in_latch;

    always @(posedge clk_sys) begin
        if (!reset) ld_out_latch <= 8'hFF;
        else if (cpu_ce && cs_ldp && ~n_wr) ld_out_latch <= cpu_Dout;
    end

    // Same exchange as GP World: on the falling edge of the command strobe send the
    // latch, wait for the front-end, capture the status, NMI. The strobe's rising
    // edge ends the NMI and opens the VBLANK-length IRQ window.
    localparam [31:0] VBL_CLKS = (CLK_HZ / 32'd1000) * 32'd1271 / 32'd1000;   // 20 NTSC lines
    reg       ld_cmd_stb, ld_status_rd, strobe_q;
    reg [5:0] xch_cnt;
    reg [16:0] vbl_cnt;
    always @(posedge clk_sys) begin
        ld_cmd_stb   <= 1'b0;
        ld_status_rd <= 1'b0;
        if (!reset) begin
            n_nmi <= 1'b1; strobe_q <= 1'b1; vbl_cnt <= 17'd0;
            xch_cnt <= 6'd0; ld_in_latch <= 8'hFF;
        end else begin
            strobe_q <= ld_cmd_strobe;
            if (strobe_q & ~ld_cmd_strobe & nmi_en) begin
                ld_cmd_stb <= 1'b1;
                xch_cnt    <= 6'd40;
            end else if (xch_cnt != 6'd0) begin
                xch_cnt <= xch_cnt - 6'd1;
                if (xch_cnt == 6'd1) begin
                    ld_in_latch  <= ld_status;
                    ld_status_rd <= 1'b1;
                    n_nmi        <= 1'b0;
                end
            end
            if (~strobe_q & ld_cmd_strobe) begin
                n_nmi   <= 1'b1;
                vbl_cnt <= VBL_CLKS[16:0];
            end else if (vbl_cnt != 17'd0 && !pause) vbl_cnt <= vbl_cnt - 17'd1;
        end
    end
    assign n_irq = (vbl_cnt == 17'd0);

    // The shared laserdisc player (ldp_0), as an LD-V1000.
    assign ldp_0_i.player_sel = 4'd0;   // PLAYER_LDV1000
    assign ldp_0_i.pr8210_555 = 1'b0;
    assign ldp_0_i.cmd_stb = ld_cmd_stb;  assign ldp_0_i.cmd_byte = ld_out_latch;
    assign ldp_0_i.blip = 1'b0;  assign ldp_0_i.tx_pop = 1'b0;
    assign ldp_0_i.pause = pause;  assign ldp_0_i.disc_hold = disc_hold;
    assign ldp_0_i.post_seek_frames = post_seek_frames;  assign ldp_0_i.disc_2997 = disc_2997;
    assign ldp_0_i.park_frame = disc_leader;  assign ldp_0_i.status_rd = ld_status_rd;
    assign ld_status = ldp_0_o.status;  assign ld_cmd_strobe = ldp_0_o.command_strobe;
    assign ld_search_cmd_o = ldp_0_o.search_cmd;  assign ld_play_end_o = ldp_0_o.play_end;
    assign ld_frame_o = ldp_0_o.curr_frame;  assign ld_playing_o = ldp_0_o.playing;

    //--------------------------------------------------------- sound ---------
    assign sound_l = 16'sd0;
    assign sound_r = 16'sd0;

    //--------------------------------------------------------- CPU read mux --
    always @(*) begin
        if      (cs_rom)   cpu_Din = rom_data;
        else if (cs_ram)   cpu_Din = ram_D;
        else if (cs_fix)   cpu_Din = fix_cpu_D;
        else if (cs_obj)   cpu_Din = obj_cpu_D;
        else if (cs_col)   cpu_Din = cpu_A[0] ? col_hi_cpu_D : col_lo_cpu_D;
        else if (cs_ldp)   cpu_Din = ld_in_latch;
        else if (cs_sw)    cpu_Din = sw_D;
        else if (cs_out)   cpu_Din = out_D;
        else if (cs_coord) cpu_Din = coord[cpu_A[1:0]];
        else               cpu_Din = 8'hFF;   // also the IM0/IM1 interrupt-acknowledge byte
    end

    //--------------------------------------------------------- renderer ------
    // 256 source columns across the 512 raster; 240 visible rows starting at
    // tile row 2 (Daphne shifts the overlay up 16 lines).
    localparam [7:0] V_OFS = 8'd16;
    wire [7:0] src_x  = ovl_hraw[8:1];
    wire [7:0] src_y  = ovl_vpos[7:0] + V_OFS;
    // DIAG-REVERT-2026-10-16: original below -- adopted cells 0..7 of the ended line in hblank
    // (hraw 512..635 wraps src_x to 0..61), so cell 0 showed cell 7: the left-column phantom.
    // wire       in_win = (ovl_vpos < 16'd240) && (ovl_hraw < 16'd512);
    //
    // // Fetch one cell ahead and adopt only a completed pass at the cell boundary (GP World).
    // wire [7:0] px_pf = src_x + 8'd8;
    // DIAG: Super Don 10-14 fix -- no adoption in hblank; hblank prefetches the next line's cell 0.
    wire       h_act   = (ovl_hraw < 16'd512);
    wire       in_win  = (ovl_vpos < 16'd240) && h_act;
    wire [7:0] src_yn  = ovl_vnext[7:0] + V_OFS;
    wire [4:0] pf_tgt  = h_act ? (src_x[7:3] + 5'd1) : 5'd0;
    wire [7:0] pf_ytgt = h_act ? src_y : src_yn;

    reg  [2:0]  fs;
    reg  [7:0]  pf_code, pf_p0;
    reg  [4:0]  pf_cell;
    reg  [7:0]  pf_py;
    reg  [7:0]  done_code, done_p0, done_p1;
    reg  [4:0]  done_cell;
    reg  [7:0]  done_py;
    reg         done_valid;
    reg  [7:0]  cur_code, cur_p0, cur_p1;
    reg  [4:0]  cur_cell;
    reg  [7:0]  cur_py;

    reg  [9:0]  fix_A_r;
    reg  [12:0] char_A_r;
    assign fix_rd_A  = fix_A_r;
    assign chr_rom_a = char_A_r;

    always @(posedge clk_sys) begin
        if (!reset) begin
            fs <= 3'd0; done_valid <= 1'b0;
            done_cell <= 5'h1F; done_py <= 8'hFF;
            cur_cell <= 5'h1F; cur_py <= 8'hFF;
            cur_p0 <= 8'd0; cur_p1 <= 8'd0; cur_code <= 8'd0;
        end else begin
            // dpram_dc reads are registered: each capture waits one cycle after its address.
            case (fs)
                3'd0: begin
                    // DIAG-REVERT-2026-10-16: original below
                    // fix_A_r <= {src_y[7:3], px_pf[7:3]};
                    // pf_cell <= px_pf[7:3];
                    // pf_py   <= src_y;
                    fix_A_r <= {pf_ytgt[7:3], pf_tgt};   // DIAG
                    pf_cell <= pf_tgt;                   // DIAG
                    pf_py   <= pf_ytgt;                  // DIAG
                    fs      <= 3'd1;
                end
                3'd1: fs <= 3'd2;
                3'd2: begin pf_code <= fix_rd_D; fs <= 3'd3; end
                // 5280 = plane 0 at +0x000, 5281 = plane 1 at +0x800, 8 bytes per code.
                3'd3: begin char_A_r <= {2'b00, pf_code, pf_py[2:0]}; fs <= 3'd4; end
                3'd4: begin char_A_r <= {2'b01, pf_code, pf_py[2:0]}; fs <= 3'd5; end
                3'd5: begin pf_p0 <= chr_rom_q; fs <= 3'd6; end
                3'd6: begin
                    done_p0    <= pf_p0;
                    done_p1    <= chr_rom_q;
                    done_code  <= pf_code;
                    done_cell  <= pf_cell;
                    done_py    <= pf_py;
                    done_valid <= 1'b1;
                    fs <= 3'd0;
                end
                default: fs <= 3'd0;
            endcase

            // DIAG-REVERT-2026-10-16: original below
            // if (done_valid && (src_x[7:3] == done_cell) && (src_y == done_py) &&
            //     ((src_x[7:3] != cur_cell) || (src_y != cur_py))) begin
            if (done_valid && h_act && (src_x[7:3] == done_cell) && (src_y == done_py) &&   // DIAG
                ((src_x[7:3] != cur_cell) || (src_y != cur_py))) begin
                cur_p0   <= done_p0;
                cur_p1   <= done_p1;
                cur_code <= done_code;
                cur_cell <= src_x[7:3];
                cur_py   <= src_y;
            end
        end
    end

    // MSB is the leftmost pixel. PROM 5279: A0-1 pixel, A2-6 code[7:3], A7 CHC,
    // A8 = jumper (0, as Daphne).
    wire [2:0] bsel = ~src_x[2:0];
    wire [1:0] pix  = {cur_p1[bsel], cur_p0[bsel]};
    assign prom_rd_A = {1'b0, chc, cur_code[7:3], pix};

    // FCD0-2 -> red bits 1-3, FCD3-5 -> green bits 1-3, FCD6-7 -> blue bits 2-3.
    // Per gun: bit3 220R, bit2 470R, bit1 1K, bit0 2.2K -> 8F/43/1F/0E (as Daphne).
    function [7:0] dac(input [3:0] v);
        dac = (v[3] ? 8'h8F : 8'h00) + (v[2] ? 8'h43 : 8'h00) +
              (v[1] ? 8'h1F : 8'h00) + (v[0] ? 8'h0E : 8'h00);
    endfunction
    wire [7:0] t_r = dac({prom_D[2:0], 1'b0});
    wire [7:0] t_g = dac({prom_D[5:3], 1'b0});
    wire [7:0] t_b = dac({prom_D[7:6], 2'b00});

    // Overlay keys over the disc wherever the colour is non-zero (PLY, sheet 6).
    always @(posedge clk_sys) begin
        if (!reset) begin ovl_rgb <= 24'd0; ovl_opaque <= 1'b0; end
        else if (ovl_ce_pix) begin
            ovl_rgb    <= {t_r, t_g, t_b};
            ovl_opaque <= in_win && (prom_D != 8'd0);
        end
    end

endmodule
