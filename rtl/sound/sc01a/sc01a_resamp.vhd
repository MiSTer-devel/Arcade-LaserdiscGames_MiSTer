-- sc01a_resamp.vhd
-- Votrax SC01-A Output Resampler: variable rate → 48 kHz
--
-- Copyright (c) 2026 shufps
-- https://github.com/shufps/votrax-sc01a-vhdl
--
-- BSD 3-Clause License
--
-- Converts the SC01-A variable sample rate (~52 kHz, clk_dac-dependent)
-- to a fixed 48 kHz output using linear interpolation.
--
-- Key design decisions:
--   - phase_inc pre-computed as 256-entry LUT indexed by clk_dac
--     (avoids any runtime division)
--   - 48 kHz DDS increment derived from CLK_HZ generic
--   - Pipelined interpolation (2 stages) for timing closure
--
-- Developed with Claude (Anthropic): rubber duck without equal,
-- tireless code parrot, and sounding board for the great
-- "do we really need runtime division?" debate (we did not).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sc01a_resamp is
    generic (
        CLK_HZ      : integer := 40_000_000;
        SAMPLE_BITS : integer := 16
    );
    port (
        clk : in std_logic;
        reset_n : in std_logic;
        s_in : in signed(SAMPLE_BITS-1 downto 0);
        s_valid      : in std_logic;
        phase_inc_in : in unsigned(15 downto 0);   -- 32768 * 48000 * 18 / sc01_hz
        s_out        : out signed(SAMPLE_BITS-1 downto 0);
        s_out_valid : out std_logic
    );
end entity;

architecture rtl of sc01a_resamp is

    -- 48kHz DDS: inc = 48000 * 2^32 / CLK_HZ
    constant INC_48K : unsigned(31 downto 0) :=
                                               to_unsigned(integer(48000.0 * 4294967296.0 / real(CLK_HZ)), 32);

    -- phase_inc = 32768 * 48000 * 18 / sc01_hz  (provided externally)

    signal phase_48k : unsigned(32 downto 0) := (others => '0');
    signal tick_48k : std_logic := '0';

    signal sample_prev : signed(SAMPLE_BITS-1 downto 0) := (others => '0');
    signal sample_curr : signed(SAMPLE_BITS-1 downto 0) := (others => '0');

    signal interp_phase : unsigned(15 downto 0) := (others => '0');
    signal phase_inc : unsigned(15 downto 0) := to_unsigned(29792, 16);

    -- Pipeline stage 1 registers
    signal p1_diff : signed(SAMPLE_BITS downto 0) := (others => '0');
    signal p1_phase : unsigned(15 downto 0) := (others => '0');
    signal p1_sample_prev : signed(SAMPLE_BITS-1 downto 0) := (others => '0');
    signal p1_valid : std_logic := '0';

begin

    -- phase_inc from external input (registered, 1 cycle latency)
    process (clk)
    begin
        if rising_edge(clk) then
            if reset_n = '0' then
                phase_inc <= (others => '0');
            else
                phase_inc <= phase_inc_in;
            end if;
        end if;
    end process;

    -- 48kHz DDS
    process (clk)
        variable sum : unsigned(32 downto 0);
    begin
        if rising_edge(clk) then
            if reset_n = '0' then
                phase_48k <= (others => '0');
                tick_48k <= '0';
            else
                sum := ('0' & phase_48k(31 downto 0)) + ('0' & INC_48K);
                phase_48k <= sum;
                tick_48k <= sum(32);
            end if;
        end if;
    end process;

    -- Sample FIFO + interp_phase + Pipeline Stage 1
    process (clk)
        variable next_phase : unsigned(15 downto 0);
    begin
        if rising_edge(clk) then
            if reset_n = '0' then
                sample_prev <= (others => '0');
                sample_curr <= (others => '0');
                interp_phase <= (others => '0');
                p1_diff <= (others => '0');
                p1_phase <= (others => '0');
                p1_sample_prev <= (others => '0');
                p1_valid <= '0';
            else
                next_phase := interp_phase;
                p1_valid <= '0';

                if s_valid = '1' then
                    sample_prev <= sample_curr;
                    sample_curr <= s_in;
                    if next_phase >= 32768 then
                        next_phase := next_phase - 32768;
                    else
                        next_phase := (others => '0');
                    end if;
                end if;

                if tick_48k = '1' then
                    p1_diff <= resize(sample_curr, SAMPLE_BITS+1) - resize(sample_prev, SAMPLE_BITS+1);
                    p1_phase <= next_phase;
                    p1_sample_prev <= sample_prev;
                    p1_valid <= '1';
                    next_phase := next_phase + phase_inc;
                end if;

                interp_phase <= next_phase;
            end if;
        end if;
    end process;

    -- Pipeline Stage 2: multiply + add → output
    -- p1_diff is SAMPLE_BITS+1 bits, p1_phase is 17 bits (signed) → product is SAMPLE_BITS+18 bits
    -- p1_phase represents fraction in Q15 (0..32767), so shift right 15 to get SAMPLE_BITS bits
    process (clk)
        variable interp : signed(SAMPLE_BITS+17 downto 0);
        variable result : signed(SAMPLE_BITS-1 downto 0);
    begin
        if rising_edge(clk) then
            if reset_n = '0' then
                s_out <= (others => '0');
                s_out_valid <= '0';
            else
                s_out_valid <= '0';
                if p1_valid = '1' then
                    interp := p1_diff * signed('0' & p1_phase);
                    result := p1_sample_prev + interp(SAMPLE_BITS+14 downto 15);
                    s_out <= result;
                    s_out_valid <= '1';
                end if;
            end if;
        end if;
    end process;

end architecture;
