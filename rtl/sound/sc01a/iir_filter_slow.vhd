-- iir_filter_slow.vhd
-- Votrax SC01-A: Sequential IIR Biquad Filter
--
-- Copyright (c) 2026 shufps
-- https://github.com/shufps/votrax-sc01a-vhdl
--
-- BSD 3-Clause License
--
-- "Ein gutes Pferd springt nur so hoch es muss."
--
-- Generic sequential state machine: one MAC per clock cycle,
-- coefficients read from an external synchronous ROM (1-cycle latency).
-- Infers a single DSP block. Generics N_X/N_Y control tap count.
-- Designed for FPGA synthesis (Quartus/Intel).
--
-- Developed with Claude (Anthropic): rubber duck without equal,
-- tireless code parrot, and occasional voice of reason when
-- accumulator widths threatened to spiral out of control.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity iir_filter_slow is
    generic (
        N_X         : integer := 4;   -- number of feedforward taps (x history)
        N_Y         : integer := 4;   -- number of feedback history values (Ny-1 coeffs used)
        FP_FRAC_A       : integer := 15;  -- right shift for A (feedforward) taps
        FP_FRAC_B       : integer := 15;  -- right shift for B (feedback) taps
        INPUT_GAIN_POW2 : integer := 0;   -- intentional input gain: effective A shift = FP_FRAC_A - INPUT_GAIN_POW2
        ROM_LATENCY     : integer := 1;   -- synchronous ROM latency in cycles (usually 1)
        MUL_LATENCY : integer := 0;   -- 0=combinational mult, 1=registered mult result
        FILTER_NAME : string  := "?"
    );
    port (
        clk : in std_logic;
        reset_n : in std_logic;

        start : in std_logic; -- pulse starts one complete filter run
        x_in : in signed(17 downto 0);

        rom_addr : out unsigned(2 downto 0); -- 0..7
        rom_data : in signed(17 downto 0); -- valid after ROM_LATENCY cycles

        y_out : out signed(17 downto 0);
        done : out std_logic -- 1-cycle pulse when result is ready
    );
end entity;

architecture rtl of iir_filter_slow is

    -- History buffers
    type hist_t is array (natural range <>) of signed(17 downto 0);
    signal x_hist : hist_t(0 to N_X - 1) := (others => (others => '0'));
    signal y_hist : hist_t(0 to N_Y - 1) := (others => (others => '0'));

    -- Internal registers (separate accumulators for A and B groups)
    signal acc_a : signed(63 downto 0) := (others => '0');
    signal acc_b : signed(63 downto 0) := (others => '0');
    signal coeff_reg : signed(17 downto 0) := (others => '0');
    signal sample_reg : signed(17 downto 0) := (others => '0');

    signal mul_a : signed(17 downto 0) := (others => '0');
    signal mul_b : signed(17 downto 0) := (others => '0');
    signal mul_r_reg : signed(35 downto 0) := (others => '0');

    signal rom_addr_r : unsigned(2 downto 0) := (others => '0');

    -- Tap bookkeeping
    constant N_B : integer := (N_Y - 1); -- number of b coeffs used: b1..b(Ny-1)
    constant N_TAPS : integer := N_X + N_B; -- total MAC steps

    signal tap_idx : integer range 0 to 15 := 0;

    -- Wait counters
    signal rom_wait : integer range 0 to 31 := 0;
    signal mul_wait : integer range 0 to 31 := 0;


    -- FSM
    type state_t is (
        S_IDLE,
        S_SET_ADDR,
        S_WAIT_ROM,
        S_LATCH_COEFF,
        S_SETUP_MUL,
        S_WAIT_MUL,
        S_ACCUMULATE,
        S_COMMIT
    );
    signal state : state_t := S_IDLE;

    -- Helper: compute ROM address for current tap
    function addr_for_tap(tap : integer) return unsigned is
        variable a : integer;
    begin
        -- A taps: tap 0..N_X-1 => addr 1..(1+N_X-1)
        if tap < N_X then
            a := 1 + tap;
        else
            -- B taps: tap N_X..N_TAPS-1 => b index = tap-N_X => addr 5 + b_index
            a := 5 + (tap - N_X);
        end if;

        if a < 0 then
            a := 0;
        elsif a > 7 then
            a := 7;
        end if;

        return to_unsigned(a, 3);
    end function;

    -- Helper: pick sample for tap (x history or y history)
    function sample_for_tap(tap : integer;
        xh : hist_t;
        yh : hist_t) return signed is
        variable s : signed(17 downto 0);
        variable bi : integer;
    begin
        if tap < N_X then
            s := xh(tap);
        else
            bi := tap - N_X; -- 0..N_B-1 corresponds to y[0..]
            s := yh(bi);
        end if;
        return s;
    end function;

begin

    rom_addr <= rom_addr_r;

    -- Optional registered multiplier result
    process (clk)
        variable mul_tmp : signed(35 downto 0);
    begin
        if rising_edge(clk) then
            if reset_n = '0' then
                mul_r_reg <= (others => '0');
            else
                mul_tmp := mul_a * mul_b;
                if MUL_LATENCY = 0 then
                    -- still register it for observability; latency handled by mul_wait=0
                    mul_r_reg <= mul_tmp;
                else
                    -- registered result (1-cycle)
                    mul_r_reg <= mul_tmp;
                end if;
            end if;
        end if;
    end process;

    process (clk)
        variable result    : signed(17 downto 0);
        variable prod64    : signed(63 downto 0);
        variable shifted_a : signed(63 downto 0);
        variable shifted_b : signed(63 downto 0);
        variable shifted   : signed(63 downto 0);
    begin
        if rising_edge(clk) then
            if reset_n = '0' then
                state <= S_IDLE;
                done  <= '0';
                y_out <= (others => '0');
                rom_addr_r <= (others => '0');
                acc_a <= (others => '0');
                acc_b <= (others => '0');
                coeff_reg <= (others => '0');
                sample_reg <= (others => '0');
                mul_a <= (others => '0');
                mul_b <= (others => '0');
                tap_idx <= 0;
                rom_wait <= 0;
                mul_wait <= 0;
                x_hist <= (others => (others => '0'));
                y_hist <= (others => (others => '0'));

            else
                case state is

                    when S_IDLE =>
                        -- park ROM addr for clean waves
                        rom_addr_r <= (others => '0');
                        done <= '0';

                        if start = '1' then

                            -- shift x history and insert new sample
                            for i in N_X - 1 downto 1 loop
                                x_hist(i) <= x_hist(i - 1);
                            end loop;
                            x_hist(0) <= x_in;

                            -- init accumulators / tap index
                            acc_a <= (others => '0');
                            acc_b <= (others => '0');
                            tap_idx <= 0;

                            state <= S_SET_ADDR;
                        end if;

                    when S_SET_ADDR =>
                        -- request coefficient for this tap
                        rom_addr_r <= addr_for_tap(tap_idx);
                        rom_wait <= ROM_LATENCY;
                        state <= S_WAIT_ROM;

                    when S_WAIT_ROM =>
                        if rom_wait = 0 then
                            state <= S_LATCH_COEFF;
                        else
                            rom_wait <= rom_wait - 1;
                        end if;

                    when S_LATCH_COEFF =>
                        -- latch coefficient that arrived
                        coeff_reg <= rom_data;
                        -- latch corresponding sample (from histories)
                        sample_reg <= sample_for_tap(tap_idx, x_hist, y_hist);
                        state <= S_SETUP_MUL;

                    when S_SETUP_MUL =>
                        mul_a <= sample_reg;
                        mul_b <= coeff_reg;

                        -- Wait for multiplier latency (0 => can go straight to ACCUMULATE next state)
                        mul_wait <= 1;--MUL_LATENCY;
                        state <= S_WAIT_MUL;

                    when S_WAIT_MUL =>
                        if mul_wait = 0 then
                            state <= S_ACCUMULATE;
                        else
                            mul_wait <= mul_wait - 1;
                        end if;

                    when S_ACCUMULATE =>
                        -- mul_r_reg currently holds mul_a*mul_b (registered each cycle)
                        prod64 := signed(resize(mul_r_reg, 64));

                        if tap_idx < N_X then
                            acc_a <= acc_a + prod64;  -- feedforward
                        else
                            acc_b <= acc_b + prod64;  -- feedback (subtracted at commit)
                        end if;

                        -- Next tap or commit
                        if tap_idx = (N_TAPS - 1) then
                            state <= S_COMMIT;
                        else
                            tap_idx <= tap_idx + 1;
                            state <= S_SET_ADDR;
                        end if;

                    when S_COMMIT =>
                        -- result = (acc_a >> FP_FRAC_A) - (acc_b >> FP_FRAC_B)
                        shifted_a := shift_right(acc_a, FP_FRAC_A - INPUT_GAIN_POW2);
                        shifted_b := shift_right(acc_b, FP_FRAC_B);
                        shifted   := shifted_a - shifted_b;
                        if shifted > to_signed(131071, 64) then
                            report "IIR[" & FILTER_NAME & "] CLIP HIGH: shifted=" & integer'image(to_integer(shifted)) &
                                   " clipped to 131071, diff=" & integer'image(to_integer(shifted) - 131071)
                                severity warning;
                            result := to_signed(131071, 18);
                        elsif shifted < to_signed(-131072, 64) then
                            report "IIR[" & FILTER_NAME & "] CLIP LOW: shifted=" & integer'image(to_integer(shifted)) &
                                   " clipped to -131072, diff=" & integer'image(to_integer(shifted) - (-131072))
                                severity warning;
                            result := to_signed(-131072, 18);
                        else
                            result := shifted(17 downto 0);
                        end if;

                        -- shift y history
                        for i in N_Y - 1 downto 1 loop
                            y_hist(i) <= y_hist(i - 1);
                        end loop;

                        y_hist(0) <= result;
                        y_out <= result;
                        done  <= '1';
                        state <= S_IDLE;

                    when others =>
                        state <= S_IDLE;

                end case;
            end if;
        end if;
    end process;
end architecture;
