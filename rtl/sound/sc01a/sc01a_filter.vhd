-- sc01a_filter_pipe.vhd
-- Votrax SC01-A Filter Pipeline Sequencer (pipelined, no FSM)
--
-- Copyright (c) 2026 shufps
-- https://github.com/shufps/votrax-sc01a-vhdl
--
-- BSD 3-Clause License
--
-- Same interface as sc01a_filter. Filters are chained via direct
-- done→start wiring (possible because done is now a 1-cycle pulse
-- and y_out stays stable until the next start).
--
-- Concurrent wiring handles F1→F2V→F3 (and optional F2N).
-- Only stages with arithmetic (noise injection, closure) stay in
-- the clocked process.
--
-- Pipeline:
--   start → [reg] → F1 + FN (parallel)
--   F1.done ──────────────────→ F2V.start   (concurrent)
--   F2V.done ─────────────────→ F3.start    (concurrent, ENABLE_F2N=false)
--   F2V.done → F2N.start      → F3.start    (concurrent, ENABLE_F2N=true)
--   F3.done → [noise+reg] ────→ F4.start    (registered: 1 cycle)
--   F4.done → [closure+reg] ──→ FX.start    (registered: 1 cycle)
--   FX.done → output

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sc01a_coeff_scales.all;

entity sc01a_filter_pipe is
    generic (
        SIM_FILTER : boolean := false;
        ENABLE_F2N : boolean := false
    );
    port (
        clk     : in std_logic;
        reset_n : in std_logic;

        start : in std_logic;

        f1_addr  : in unsigned(6 downto 0);
        f2v_addr : in unsigned(11 downto 0);
        f3_addr  : in unsigned(6 downto 0);

        filt_va   : in unsigned(3 downto 0);
        filt_fa   : in unsigned(3 downto 0);
        filt_fc   : in unsigned(3 downto 0);
        pitch     : in unsigned(7 downto 0);
        closure   : in unsigned(4 downto 0);
        cur_noise : in std_logic;

        rom_addr_f1  : out unsigned(6 downto 0);
        rom_data_f1  : in  signed(17 downto 0);
        rom_addr_f2v : out unsigned(11 downto 0);
        rom_data_f2v : in  signed(17 downto 0);
        rom_addr_f3  : out unsigned(6 downto 0);
        rom_data_f3  : in  signed(17 downto 0);
        rom_addr_f4  : out unsigned(2 downto 0);
        rom_data_f4  : in  signed(17 downto 0);
        rom_addr_fx  : out unsigned(2 downto 0);
        rom_data_fx  : in  signed(17 downto 0);
        rom_addr_fn  : out unsigned(2 downto 0);
        rom_data_fn  : in  signed(17 downto 0);
        rom_addr_f2n : out unsigned(11 downto 0);
        rom_data_f2n : in  signed(17 downto 0);

        sample_out : out signed(17 downto 0);
        done       : out std_logic
    );
end entity;

architecture rtl of sc01a_filter_pipe is

    -- Glottal wave table s(2.15)
    type glottal_t is array(0 to 8) of signed(17 downto 0);
    constant GLOTTAL : glottal_t := (
        to_signed(0, 18),
        to_signed(-18725, 18),
        to_signed(32767, 18),
        to_signed(28101, 18),
        to_signed(23405, 18),
        to_signed(18725, 18),
        to_signed(14050, 18),
        to_signed(9362, 18),
        to_signed(4681, 18)
    );

    function fp_scale15(val : signed(17 downto 0); vol : unsigned(3 downto 0))
        return signed is
        variable step1 : signed(22 downto 0);
        variable step2 : signed(40 downto 0);
    begin
        step1 := val * signed(resize(vol, 5));
        step2 := step1 * to_signed(2185, 18);
        return step2(32 downto 15);
    end function;

    function fp_scale7(val : signed(17 downto 0); clos : unsigned(2 downto 0))
        return signed is
        variable step1 : signed(21 downto 0);
        variable step2 : signed(39 downto 0);
    begin
        step1 := val * signed(resize(clos, 4));
        step2 := step1 * to_signed(4681, 18);
        return step2(32 downto 15);
    end function;

    type filt_sig_t is record
        start    : std_logic;
        x_in     : signed(17 downto 0);
        rom_addr : unsigned(2 downto 0);
        rom_data : signed(17 downto 0);
        y_out    : signed(17 downto 0);
        done     : std_logic;
    end record;

    signal f1  : filt_sig_t;
    signal f2v : filt_sig_t;
    signal f2n : filt_sig_t;
    signal fn  : filt_sig_t;
    signal f3  : filt_sig_t;
    signal f4  : filt_sig_t;
    signal fx  : filt_sig_t;

    -- Registered input parameters (sampled at start)
    signal filt_fc_r  : unsigned(3 downto 0) := (others => '0');
    signal closure_r  : unsigned(4 downto 0) := (others => '0');

begin

    -- ================================================================
    -- IIR filter instances
    -- ================================================================
    u_f1 : entity work.iir_filter_slow
        generic map(N_X => 4, N_Y => 4, FP_FRAC_A => F1_FP_FRAC_A, FP_FRAC_B => F1_FP_FRAC_B, FILTER_NAME => "F1")
        port map(clk => clk, reset_n => reset_n,
                 start => f1.start, x_in => f1.x_in,
                 rom_addr => f1.rom_addr, rom_data => f1.rom_data,
                 y_out => f1.y_out, done => f1.done);

    u_f2v : entity work.iir_filter_slow
        generic map(N_X => 4, N_Y => 4, FP_FRAC_A => F2V_FP_FRAC_A, FP_FRAC_B => F2V_FP_FRAC_B, FILTER_NAME => "F2V")
        port map(clk => clk, reset_n => reset_n,
                 start => f2v.start, x_in => f2v.x_in,
                 rom_addr => f2v.rom_addr, rom_data => f2v.rom_data,
                 y_out => f2v.y_out, done => f2v.done);

    u_fn : entity work.iir_filter_slow
        generic map(N_X => 4, N_Y => 4, FP_FRAC_A => FN_FP_FRAC_A, FP_FRAC_B => FN_FP_FRAC_B, INPUT_GAIN_POW2 => 14, FILTER_NAME => "FN")
        port map(clk => clk, reset_n => reset_n,
                 start => fn.start, x_in => fn.x_in,
                 rom_addr => fn.rom_addr, rom_data => fn.rom_data,
                 y_out => fn.y_out, done => fn.done);

    u_f3 : entity work.iir_filter_slow
        generic map(N_X => 4, N_Y => 4, FP_FRAC_A => F3_FP_FRAC_A, FP_FRAC_B => F3_FP_FRAC_B, FILTER_NAME => "F3")
        port map(clk => clk, reset_n => reset_n,
                 start => f3.start, x_in => f3.x_in,
                 rom_addr => f3.rom_addr, rom_data => f3.rom_data,
                 y_out => f3.y_out, done => f3.done);

    u_f4 : entity work.iir_filter_slow
        generic map(N_X => 4, N_Y => 4, FP_FRAC_A => F4_FP_FRAC_A, FP_FRAC_B => F4_FP_FRAC_B, FILTER_NAME => "F4")
        port map(clk => clk, reset_n => reset_n,
                 start => f4.start, x_in => f4.x_in,
                 rom_addr => f4.rom_addr, rom_data => f4.rom_data,
                 y_out => f4.y_out, done => f4.done);

    u_f2n : entity work.iir_filter_slow
        generic map(N_X => 2, N_Y => 2, FP_FRAC_A => F2N_FP_FRAC_A, FP_FRAC_B => F2N_FP_FRAC_B, FILTER_NAME => "F2N")
        port map(clk => clk, reset_n => reset_n,
                 start => f2n.start, x_in => f2n.x_in,
                 rom_addr => f2n.rom_addr, rom_data => f2n.rom_data,
                 y_out => f2n.y_out, done => f2n.done);

    u_fx : entity work.iir_filter_slow
        generic map(N_X => 2, N_Y => 2, FP_FRAC_A => FX_FP_FRAC_A, FP_FRAC_B => FX_FP_FRAC_B, FILTER_NAME => "FX")
        port map(clk => clk, reset_n => reset_n,
                 start => fx.start, x_in => fx.x_in,
                 rom_addr => fx.rom_addr, rom_data => fx.rom_data,
                 y_out => fx.y_out, done => fx.done);

    -- ================================================================
    -- ROM address wiring
    -- ================================================================
    rom_addr_f1  <= f1_addr  or resize(f1.rom_addr,  7);
    rom_addr_f2v <= f2v_addr or resize(f2v.rom_addr, 12);
    rom_addr_f3  <= f3_addr  or resize(f3.rom_addr,  7);
    rom_addr_f4  <= f4.rom_addr;
    rom_addr_fx  <= fx.rom_addr;
    rom_addr_fn  <= fn.rom_addr;
    rom_addr_f2n <= f2v_addr or resize(f2n.rom_addr, 12);
    f1.rom_data  <= rom_data_f1;
    f2v.rom_data <= rom_data_f2v;
    fn.rom_data  <= rom_data_fn;
    f2n.rom_data <= rom_data_f2n;
    f3.rom_data  <= rom_data_f3;
    f4.rom_data  <= rom_data_f4;
    fx.rom_data  <= rom_data_fx;

    -- ================================================================
    -- Direct chaining: done→start, y_out→x_in
    -- y_out is stable between commits so concurrent wiring is safe.
    -- ================================================================

    -- F1 → F2V (F1 and FN finish together, equal tap count)
    -- halve F1 output to give 1-bit headroom in downstream filters
    f2v.start <= f1.done;
    f2v.x_in  <= shift_right(f1.y_out, 1);

    -- F2V → F3 (direct) or F2V → F2N → F3 (ENABLE_F2N)
    f2n.start <= f2v.done;
    f2n.x_in  <= fp_scale15(shift_right(fn.y_out, 1), filt_fc_r); -- fn.y_out halved for headroom

    f3.start  <= f2v.done when not ENABLE_F2N else f2n.done;
    f3.x_in   <= f2v.y_out when not ENABLE_F2N else f2v.y_out + f2n.y_out;

    -- output from fx
    sample_out <= fx.y_out;
    done       <= fx.done;

    -- ================================================================
    -- Clocked process: only stages that need arithmetic
    -- ================================================================
    -- Stage 0: register params, compute x_in, fire F1 + FN
    process(clk)
        variable noise_inp : signed(17 downto 0);
    begin
        if rising_edge(clk) then
            f1.start <= '0';
            fn.start <= '0';
            if reset_n = '0' then
                filt_fc_r <= (others => '0');
                closure_r <= (others => '0');
                f1.x_in   <= (others => '0');
                fn.x_in   <= (others => '0');
            elsif start = '1' then
                filt_fc_r <= filt_fc;
                closure_r <= closure;
                if pitch >= to_unsigned(9 * 8, 8) then
                    f1.x_in <= (others => '0');
                else
                    f1.x_in <= fp_scale15(GLOTTAL(to_integer(pitch(7 downto 3))), filt_va);
                end if;
                if pitch(6) = '1' and cur_noise = '1' then
                    noise_inp := to_signed(16384, 18);
                else
                    noise_inp := to_signed(-16384, 18);
                end if;
                --report "fn_in: " & integer'image(to_integer(noise_inp)) severity note;
                fn.x_in  <= fp_scale15(noise_inp, filt_fa);
                f1.start <= '1';
                fn.start <= '1';
            end if;
        end if;
    end process;

    -- Stage 3: F3 done → noise injection → fire F4
    process(clk)
        variable noise_scale : integer range 0 to 20;
        variable tmp         : signed(63 downto 0);
        variable noise_add   : signed(17 downto 0);
        variable sum32       : signed(31 downto 0);
    begin
        if rising_edge(clk) then
            f4.start <= '0';
            if reset_n = '0' then
                f4.x_in <= (others => '0');
            elsif f3.done = '1' then
                noise_scale := 5 + to_integer(to_unsigned(15, 4) xor filt_fc_r);
                -- halve FN output for 1-bit headroom (matches F1 output scaling)
                tmp         := resize(shift_right(fn.y_out, 1) * to_signed(noise_scale, 18), 64);
                noise_add   := signed(resize(
                               shift_right(tmp(32 downto 0) * to_signed(1638, 18), 15), 18));
                f4.x_in  <= f3.y_out + noise_add;
                f4.start <= '1';
            end if;
        end if;
    end process;

    -- Stage 4: F4 done → closure scaling → fire FX
    process(clk)
    begin
        if rising_edge(clk) then
            fx.start <= '0';
            if reset_n = '0' then
                fx.x_in <= (others => '0');
            elsif f4.done = '1' then
                fx.x_in  <= fp_scale7(f4.y_out,
                             unsigned(closure_r(4 downto 2)) xor "111");
                fx.start <= '1';
            end if;
        end if;
    end process;

    process(clk)
    begin
        if rising_edge(clk) then
            if fn.done = '1' then
                --report "fn_out: " & integer'image(to_integer(fn.y_out)) severity note;
            end if;
        end if;
    end process;

end architecture;
