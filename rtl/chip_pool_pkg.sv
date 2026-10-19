//============================================================================
//
//  chip_pool_pkg — bus types for a multi-board core's shared CPU / sound chip pool (canonical; same file in every core)
//  Copyright (C) 2026 Rodimus
//
//  Only one board runs at a time, so the CPUs and sound chips are instanced once in the dispatcher (here Arcade-LaserdiscGames.sv)
//  and the active board drives them through these buses (selected by variant). *_i = board to chip,
//  *_o = chip to every board. Reset is the core reset.
//
//============================================================================

package chip_pool_pkg;

// Z80 (T80s, Mode 0, T2Write 1, IOWait 1; WAIT_n / BUSRQ_n inactive)
typedef struct packed {
    logic        ce;
    logic        int_n;
    logic        nmi_n;
    logic  [7:0] di;
} z80_i_t;

typedef struct packed {
    logic [15:0] a;
    logic  [7:0] dout;
    logic        m1_n;
    logic        mreq_n;
    logic        iorq_n;
    logic        rd_n;
    logic        wr_n;
    logic        rfsh_n;
} z80_o_t;

// MC6809E (mc6809is; HALT / DMABREQ inactive)
typedef struct packed {
    logic        fall_e;
    logic        fall_q;
    logic        irq_n;
    logic        firq_n;
    logic        nmi_n;
    logic  [7:0] d;
} m6809_i_t;

typedef struct packed {
    logic [15:0] a;
    logic  [7:0] dout;
    logic        rw;
    logic        lic;
} m6809_o_t;

// AY-3-8910 (jt49_bus, sel = 1)
typedef struct packed {
    logic        ce;
    logic        bdir;
    logic        bc1;
    logic  [7:0] din;
    logic  [7:0] ioa_in;
    logic  [7:0] iob_in;
} ay_i_t;

typedef struct packed {
    logic  [7:0] dout;
    logic  [7:0] a;
    logic  [7:0] b;
    logic  [7:0] c;
    logic  [7:0] iob_out;
    logic  [9:0] sound;                 // jt49 internal A+B+C mix (registered per accumulator cycle)
} ay_o_t;

// 8039 (T48 t8039_notri_extrom, EA low, program on pmem; T0 / T1 low, P1 / P2 inputs high)
typedef struct packed {
    logic        xtal_en;
    logic        int_n;
    logic  [7:0] db;
    logic  [7:0] pmem_d;
} mcs48_i_t;

typedef struct packed {
    logic  [7:0] p1;
    logic  [7:0] p2;
    logic [11:0] pmem_a;
    logic        rd_n;
} mcs48_o_t;

// Z80 (T80pa, Mode 0; BUSRQ_n inactive). RESET_n is on the bus: Lady Bug / 8203 hold their CPUs in reset ~48 ms past the core reset
typedef struct packed {
    logic        reset_n;
    logic        cen_p;
    logic        cen_n;
    logic        wait_n;
    logic        int_n;
    logic        nmi_n;
    logic  [7:0] di;
} z80pa_i_t;

typedef struct packed {
    logic [15:0] a;
    logic  [7:0] dout;
    logic        m1_n;
    logic        mreq_n;
    logic        iorq_n;
    logic        rd_n;
    logic        wr_n;
    logic        rfsh_n;
} z80pa_o_t;

// SN76489 (jt89, INTERPOL16 0, MODE 0). rst is on the bus: Lady Bug resets its pair on power-on only
typedef struct packed {
    logic        rst;
    logic        ce;
    logic        wr_n;
    logic        cs_n;
    logic  [7:0] din;
} sn76489_i_t;

typedef struct packed {
    logic [10:0] sound;                 // signed
    logic        ready;
} sn76489_o_t;

// MB88 (mb88 / mb88_core; STBY / SC inputs inactive, RAM clear = core reset)
typedef struct packed {
    logic        ena;
    logic        reset_n;
    logic  [3:0] k;
    logic [15:0] r_in;          // {R3, R2, R1, R0}
    logic        irq_n;
    logic        tc_n;
    logic        si_n;
    logic  [7:0] rom_d;
} mb88_i_t;

typedef struct packed {
    logic [15:0] r_out;         // {R3, R2, R1, R0}
    logic  [7:0] o;             // {OH, OL}
    logic        o_wr;
    logic  [3:0] p;
    logic [10:0] rom_a;
} mb88_o_t;

// ---- LaserdiscGames additions (2026-10-16) ----

// Z80 (T80s, Mode 0, T2Write 1, IOWait 1; BUSRQ_n inactive) with WAIT_n driven: Dragon's Lair inserts a wait state for the AY
typedef struct packed {
    logic        ce;
    logic        wait_n;
    logic        int_n;
    logic        nmi_n;
    logic  [7:0] di;
} z80w_i_t;

typedef struct packed {
    logic [15:0] a;
    logic  [7:0] dout;
    logic        m1_n;
    logic        mreq_n;
    logic        iorq_n;
    logic        rd_n;
    logic        wr_n;
    logic        rfsh_n;
} z80w_o_t;

// AY-3-8910 register core (jt49, no bus wrapper; sel = 1). rst_n is on the bus: Dragon's Lair II holds its board in reset during the SDRAM phase sweep
typedef struct packed {
    logic        rst_n;
    logic        ce;
    logic  [3:0] addr;
    logic        cs_n;
    logic        wr_n;
    logic  [7:0] din;
} jt49_i_t;

typedef struct packed {
    logic  [7:0] a;
    logic  [7:0] b;
    logic  [7:0] c;
} jt49_o_t;

// MCL86 8088 execution unit (mcl86_eu_core, TEST_N inactive). The bus unit (biu_max) stays on each board: its timing
// parameters differ per board. reset_n is on the bus: Dragon's Lair II holds its CPU in reset during the SDRAM phase sweep
typedef struct packed {
    logic        reset_n;
    logic        biu_done;
    logic        biu_clk_counter_zero;
    logic        biu_nmi_caught;
    logic        biu_intr;
    logic  [7:0] pfq_top_byte;
    logic        pfq_empty;
    logic [15:0] pfq_addr_out;
    logic [15:0] biu_es;
    logic [15:0] biu_ss;
    logic [15:0] biu_cs;
    logic [15:0] biu_ds;
    logic [15:0] biu_rm;
    logic [15:0] biu_reg;
    logic [15:0] biu_ret;
} mcl86eu_i_t;

typedef struct packed {
    logic [15:0] eu_biu_command;
    logic [15:0] eu_biu_dataout;
    logic [15:0] eu_register_r3;
    logic        eu_prefix_lock;
    logic        eu_flag_i;
    logic        biu_nmi_debounce;
} mcl86eu_o_t;

// Laserdisc player HLE (rtl/ldp/ldp_top.sv: shared transport + LD-V1000 / PR-7820 / PR-8210 / LDP-1450 front-ends)
typedef struct packed {
    logic  [3:0] player_sel;
    logic        pr8210_555;            // PR-8210 bit boundary: 0 = bit-banged (870 us), 1 = Gottlieb 555 (1497 us)
    logic        cmd_stb;
    logic  [7:0] cmd_byte;
    logic        blip;
    logic        tx_pop;
    logic        pause;
    logic        disc_hold;
    logic  [3:0] post_seek_frames;
    logic        disc_2997;
    logic [16:0] park_frame;
    logic        status_rd;
    logic        cmd_oe;                // host drives the LD data bus (DL: misc b5 low = U21 enabled)
} ldp_i_t;

typedef struct packed {
    logic  [7:0] status;
    logic        status_strobe;
    logic        command_strobe;
    logic        ready_n;
    logic        frame_valid;
    logic        tx_valid;
    logic  [7:0] tx_byte;
    logic        search_cmd;
    logic        play_end;
    logic [16:0] curr_frame;
    logic        playing;
    logic [16:0] dbg_seek_frame;
    logic [19:0] dbg_end_frame;
    logic  [3:0] dbg_flags;
    logic        txt_we;
    logic  [1:0] txt_line;
    logic  [5:0] txt_col;
    logic  [7:0] txt_glyph;
    logic        txt_on;
    logic  [7:0] txt_x;
    logic  [7:0] txt_y;
    logic        ldv_fw;                // LD-V1000 is running its real firmware (else HLE)
} ldp_o_t;

// Dual-port RAM block (dpram_dc, 8-bit, port A = CPU side read/write, port B = video side read-only)
typedef struct packed {
    logic [13:0] a_addr;
    logic        a_we;
    logic  [7:0] a_din;
    logic [13:0] b_addr;
} ram_i_t;

typedef struct packed {
    logic  [7:0] a_q;
    logic  [7:0] b_q;
} ram_o_t;

// COP421 (T400 t400_core, opt_type 421, CK divisor 32, crystal CKO; CKO low, IN port high; POR from t400_por)
typedef struct packed {
    logic        ck_en;
    logic  [7:0] pm_data;
    logic  [3:0] dm_data;
    logic  [7:0] io_l;
    logic  [3:0] io_g;
    logic        si;
} t400_i_t;

typedef struct packed {
    logic  [9:0] pm_addr;
    logic  [5:0] dm_addr;
    logic        dm_we;
    logic  [3:0] dm_data;
    logic  [7:0] io_l;
    logic  [7:0] io_l_en;
    logic  [3:0] io_d;
    logic  [3:0] io_d_en;
    logic  [3:0] io_g;
    logic  [3:0] io_g_en;
    logic        so;
    logic        so_en;
    logic        sk;
    logic        sk_en;
} t400_o_t;

endpackage
