-- sc01a.vhd
-- Votrax SC01-A Formant Speech Synthesizer
--
-- Copyright (c) 2026 shufps
-- https://github.com/shufps/votrax-sc01a-vhdl
--
-- BSD 3-Clause License
--
-- Based on the Votrax SC01-A simulation from MAME
-- Copyright (c) Olivier Galibert
--
-- Key differences from MAME reference:
--   - All arithmetic in s(2.15) fixed-point (no floating point)
--   - Filter coefficients pre-computed as static ROM tables
--   - IIR filters implemented as sequential state machines
--   - Clock enables (sclock_en, cclock_en) provided externally
--   - Designed for FPGA synthesis (Quartus/Intel)
--
-- Developed with Claude (Anthropic): rubber duck without equal,
-- tireless code parrot, and occasional voice of reason when
-- fixed-point overflow struck at 2 AM.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity sc01a is
    generic (
        ENABLE_F2N  : boolean := false;     -- F2N injection filter
        IS_SC01A    : integer := 1          -- 1=SC01-A ROM, 0=SC01 ROM
    );
    port (
        -- System
        clk     : in std_logic;
        reset_n : in std_logic;

        -- Phoneme interface
        p          : in std_logic_vector(5 downto 0);
        inflection : in std_logic_vector(1 downto 0);
        stb        : in std_logic;

        ar : out std_logic;

        -- Clock enables from external DDS
        sclock_en : in std_logic;   -- sample tick  (~sc01_hz/18)
        cclock_en : in std_logic;   -- coarse tick  (~sc01_hz/36)

        -- Audio output (18-bit, raw filter sample)
        audio_out   : out signed(17 downto 0);
        audio_valid : out std_logic
    );
end entity;

architecture rtl of sc01a is

    -- ================================================================
    -- Phoneme ROM
    -- ================================================================
    signal phoneme_reg    : std_logic_vector(5 downto 0) := (others => '0');
    signal commit_phone   : std_logic := '0';
    signal sc01a_rom_data : std_logic_vector(63 downto 0);

    -- ================================================================
    -- Core signals
    -- ================================================================
    signal pitch     : unsigned(7 downto 0) := (others => '0');
    signal closure   : unsigned(7 downto 0) := (others => '0');
    signal cur_noise : std_logic := '0';

    -- ================================================================
    -- Filter commit signals
    -- ================================================================
    signal filt_fa  : unsigned(3 downto 0) := (others => '0');
    signal filt_fc  : unsigned(3 downto 0) := (others => '0');
    signal filt_va  : unsigned(3 downto 0) := (others => '0');

    signal f1_addr  : unsigned(6 downto 0)  := (others => '0');
    signal f2v_addr : unsigned(11 downto 0) := (others => '0');
    signal f3_addr  : unsigned(6 downto 0)  := (others => '0');

    -- ================================================================
    -- ROM addr/data buses
    -- ================================================================
    signal rom_addr_f1  : unsigned(6 downto 0);
    signal rom_data_f1  : signed(17 downto 0);
    signal rom_addr_f2v : unsigned(11 downto 0);
    signal rom_data_f2v : signed(17 downto 0);
    signal rom_addr_f3  : unsigned(6 downto 0);
    signal rom_data_f3  : signed(17 downto 0);
    signal rom_addr_f4  : unsigned(2 downto 0);
    signal rom_data_f4  : signed(17 downto 0);
    signal rom_addr_fx  : unsigned(2 downto 0);
    signal rom_data_fx  : signed(17 downto 0);
    signal rom_addr_fn  : unsigned(2 downto 0);
    signal rom_data_fn  : signed(17 downto 0);
    signal rom_addr_f2n : unsigned(11 downto 0);
    signal rom_data_f2n : signed(17 downto 0);

    signal rom_duration : unsigned(6 downto 0) := (others => '0');

    -- ================================================================
    -- Filter pipeline
    -- ================================================================
    signal filt_start  : std_logic;
    signal filt_sample : signed(17 downto 0);
    signal filt_done   : std_logic;
    signal filt_flush  : std_logic := '0';  -- 1-cycle reset on pause phoneme

    -- ================================================================
    -- AR timer
    -- ================================================================
    signal stb_prev : std_logic := '0';

    -- 2-FF synchronizer for stb
    signal stb_sync : std_logic_vector(1 downto 0) := "00";

    function interpolate(
        reg_val : unsigned(7 downto 0);
        target  : unsigned(3 downto 0)
    ) return unsigned is
        variable tmp : unsigned(7 downto 0);
    begin
        tmp := reg_val - (reg_val srl 3) + (resize(target, 8) sll 1);
        return tmp;
    end function;

begin

    -- ================================================================
    -- Phoneme ROM
    -- ================================================================
SC01A_ROM: if IS_SC01A = 1 generate
    u_rom : entity work.sc01a_rom
        port map(phoneme => phoneme_reg, data => sc01a_rom_data);
end generate SC01A_ROM;

SC01_ROM: if IS_SC01A = 0 generate
    u_rom : entity work.sc01_rom
        port map(phoneme => phoneme_reg, data => sc01a_rom_data);
end generate SC01_ROM;

    -- ================================================================
    -- Coefficient ROMs
    -- ================================================================
    u_f1_rom  : entity work.f1_rom
        port map(clk => clk, addr => rom_addr_f1,  data => rom_data_f1);
    u_f2v_rom : entity work.f2v_rom
        port map(clk => clk, addr => rom_addr_f2v, data => rom_data_f2v);
    u_f3_rom  : entity work.f3_rom
        port map(clk => clk, addr => rom_addr_f3,  data => rom_data_f3);
    u_f4_rom  : entity work.f4_rom
        port map(clk => clk, addr => rom_addr_f4,  data => rom_data_f4);
    u_fx_rom  : entity work.fx_rom
        port map(clk => clk, addr => rom_addr_fx,  data => rom_data_fx);
    u_fn_rom  : entity work.fn_rom
        port map(clk => clk, addr => rom_addr_fn,  data => rom_data_fn);
    u_f2n_rom : entity work.f2n_rom
        port map(clk => clk, addr => rom_addr_f2n, data => rom_data_f2n);

    -- ================================================================
    -- Filter pipeline
    -- ================================================================
    u_filter : entity work.sc01a_filter_pipe
        generic map(ENABLE_F2N => ENABLE_F2N)
        port map(
            clk       => clk,
            reset_n   => reset_n AND NOT filt_flush,
            start     => filt_start,
            f1_addr   => f1_addr,
            f2v_addr  => f2v_addr,
            f3_addr   => f3_addr,
            filt_va   => filt_va,
            filt_fa   => filt_fa,
            filt_fc   => filt_fc,
            pitch     => pitch,
            closure   => closure(4 downto 0),
            cur_noise => cur_noise,
            rom_addr_f1  => rom_addr_f1,  rom_data_f1  => rom_data_f1,
            rom_addr_f2v => rom_addr_f2v, rom_data_f2v => rom_data_f2v,
            rom_addr_f3  => rom_addr_f3,  rom_data_f3  => rom_data_f3,
            rom_addr_f4  => rom_addr_f4,  rom_data_f4  => rom_data_f4,
            rom_addr_fx  => rom_addr_fx,  rom_data_fx  => rom_data_fx,
            rom_addr_fn  => rom_addr_fn,  rom_data_fn  => rom_data_fn,
            rom_addr_f2n => rom_addr_f2n, rom_data_f2n => rom_data_f2n,
            sample_out => filt_sample,
            done       => filt_done
        );

    filt_start  <= sclock_en;
    audio_out   <= filt_sample;
    audio_valid <= filt_done;

    -- ================================================================
    -- 2-FF synchronizer for stb
    -- ================================================================
    process (clk)
    begin
        if rising_edge(clk) then
            if reset_n = '0' then
                stb_sync <= "00";
            else
                stb_sync <= stb_sync(0) & stb;
            end if;
        end if;
    end process;

    -- ================================================================
    -- Phoneme latch
    -- ================================================================
    process (clk)
        variable last_stb : std_logic := '0';
    begin
        if rising_edge(clk) then
            if reset_n = '0' then
                phoneme_reg  <= (others => '0');
                commit_phone <= '0';
                filt_flush   <= '0';
            else
                commit_phone <= '0';
                filt_flush   <= '0';
                if stb_sync(1) = '1' and last_stb = '0' then
                    phoneme_reg  <= p;
                    commit_phone <= '1';
                    -- PA0 (0x03), PA1 (0x3E), STOP (0x3F): flush IIR filter state
                    if p = "000011" or p = "111110" or p = "111111" then
                        filt_flush <= '1';
                    end if;
                end if;
                last_stb := stb_sync(1);
            end if;
        end if;
    end process;

    -- ================================================================
    -- Main chip update process
    -- ================================================================
    process (clk)
        variable tick_625_v : std_logic := '0';
        variable tick_208_v : std_logic := '0';
        variable ticks_v : unsigned(7 downto 0) := x"10";
        variable phonetick_v : unsigned(8 downto 0) := (others => '0');
        variable update_counter_v : unsigned(7 downto 0) := (others => '0');
        variable val_v : std_logic_vector(63 downto 0) := (others => '0');
        variable rom_closure_v : std_logic := '0';
        variable cur_closure_v : std_logic := '0';
        variable rom_pause_v : std_logic := '0';
        variable rom_f1_v  : unsigned(3 downto 0) := (others => '0');
        variable rom_va_v  : unsigned(3 downto 0) := (others => '0');
        variable rom_f2_v  : unsigned(3 downto 0) := (others => '0');
        variable rom_fc_v  : unsigned(3 downto 0) := (others => '0');
        variable rom_f2q_v : unsigned(3 downto 0) := (others => '0');
        variable rom_f3_v  : unsigned(3 downto 0) := (others => '0');
        variable rom_fa_v  : unsigned(3 downto 0) := (others => '0');
        variable rom_cld_v : unsigned(3 downto 0) := (others => '0');
        variable rom_vd_v  : unsigned(3 downto 0) := (others => '0');
        variable cur_fc_v  : unsigned(7 downto 0) := (others => '0');
        variable cur_f1_v  : unsigned(7 downto 0) := (others => '0');
        variable cur_f2_v  : unsigned(7 downto 0) := (others => '0');
        variable cur_f2q_v : unsigned(7 downto 0) := (others => '0');
        variable cur_f3_v  : unsigned(7 downto 0) := (others => '0');
        variable cur_fa_v  : unsigned(7 downto 0) := (others => '0');
        variable cur_va_v  : unsigned(7 downto 0) := (others => '0');
        variable closure_v : unsigned(7 downto 0) := (others => '0');
        variable pitch_v   : unsigned(7 downto 0) := (others => '0');
        variable pitch_reset_val_v : unsigned(7 downto 0) := (others => '0');
        variable noise_inp_v : std_logic := '0';
        variable filt_f1_v  : unsigned(3 downto 0) := (others => '0');
        variable filt_f2_v  : unsigned(4 downto 0) := (others => '0');
        variable filt_f2q_v : unsigned(3 downto 0) := (others => '0');
        variable filt_f3_v  : unsigned(3 downto 0) := (others => '0');
        variable filt_fa_v  : unsigned(3 downto 0) := (others => '0');
        variable filt_fc_v  : unsigned(3 downto 0) := (others => '0');
        variable filt_va_v  : unsigned(3 downto 0) := (others => '0');
        variable f1_addr_v  : unsigned(6 downto 0)  := (others => '0');
        variable f2v_addr_v : unsigned(11 downto 0) := (others => '0');
        variable f3_addr_v  : unsigned(6 downto 0)  := (others => '0');
        variable rom_duration_v : unsigned(6 downto 0) := (others => '0');
        variable noise_v    : unsigned(15 downto 0) := (others => '0');
        variable cur_noise_v : std_logic := '0';
        variable ar_v : std_logic := '1';
    begin
        if rising_edge(clk) then
            if reset_n = '0' then
                pitch <= (others => '0');
                closure <= (others => '0');
                cur_noise <= '0';
                filt_fa <= (others => '0');
                filt_fc <= (others => '0');
                filt_va <= (others => '0');
                f1_addr <= (others => '0');
                f2v_addr <= (others => '0');
                f3_addr <= (others => '0');
                rom_duration <= (others => '0');
                ticks_v := x"10";
                phonetick_v := (others => '0');
                update_counter_v := (others => '0');
                closure_v := (others => '0');
                pitch_v := (others => '0');
                noise_v := (others => '0');
                cur_noise_v := '0';
                ar_v := '1';
            else
                if commit_phone = '1' then
                    ticks_v := (others => '0');
                    phonetick_v := (others => '0');
                    val_v := sc01a_rom_data;
                    rom_f1_v  := val_v(0)  & val_v(7)  & val_v(14) & val_v(21);
                    rom_va_v  := val_v(1)  & val_v(8)  & val_v(15) & val_v(22);
                    rom_f2_v  := val_v(2)  & val_v(9)  & val_v(16) & val_v(23);
                    rom_fc_v  := val_v(3)  & val_v(10) & val_v(17) & val_v(24);
                    rom_f2q_v := val_v(4)  & val_v(11) & val_v(18) & val_v(25);
                    rom_f3_v  := val_v(5)  & val_v(12) & val_v(19) & val_v(26);
                    rom_fa_v  := val_v(6)  & val_v(13) & val_v(20) & val_v(27);
                    rom_cld_v := val_v(34) & val_v(32) & val_v(30) & val_v(28);
                    rom_vd_v  := val_v(35) & val_v(33) & val_v(31) & val_v(29);
                    rom_closure_v := val_v(36);
                    rom_duration_v := not (val_v(37) & val_v(38) & val_v(39) &
                                      val_v(40) & val_v(41) & val_v(42) & val_v(43));
                    rom_pause_v := '0';
                    if phoneme_reg = "000011" or phoneme_reg = "111110" then
                        rom_pause_v := '1';
                    end if;
                    if rom_cld_v = "0000" then
                        cur_closure_v := rom_closure_v;
                    end if;
                    ar_v := '0';
                else
                    if cclock_en = '1' then
                        -- 1) Phoneme timing
                        if ticks_v /= x"10" then
                            phonetick_v := phonetick_v + 1;
                            if phonetick_v = rom_duration(6 downto 0) & "01" then
                                phonetick_v := (others => '0');
                                ticks_v := ticks_v + 1;
                                if ticks_v = rom_cld_v then
                                    cur_closure_v := rom_closure_v;
                                end if;
                            end if;
                        else
                            ar_v := '1';
                        end if;

                        -- 2) Update counter (0..47)
                        if update_counter_v = x"2F" then
                            update_counter_v := (others => '0');
                        else
                            update_counter_v := update_counter_v + 1;
                        end if;

                        tick_625_v := '0';
                        if update_counter_v(3 downto 0) = "0000" then
                            tick_625_v := '1';
                        end if;

                        tick_208_v := '0';
                        if update_counter_v = x"28" then
                            tick_208_v := '1';
                        end if;

                        -- 3) Interpolation @ 208Hz
                        if tick_208_v = '1' then
                            if rom_pause_v = '0' or not (filt_fa /= 0 or filt_va /= 0) then
                                cur_fc_v  := interpolate(cur_fc_v,  rom_fc_v);
                                cur_f1_v  := interpolate(cur_f1_v,  rom_f1_v);
                                cur_f2_v  := interpolate(cur_f2_v,  rom_f2_v);
                                cur_f2q_v := interpolate(cur_f2q_v, rom_f2q_v);
                                cur_f3_v  := interpolate(cur_f3_v,  rom_f3_v);
                            end if;
                        end if;

                        -- 4) Interpolation @ 625Hz
                        if tick_625_v = '1' then
                            if ticks_v >= rom_vd_v then
                                cur_fa_v := interpolate(cur_fa_v, rom_fa_v);
                            end if;
                            if ticks_v >= rom_cld_v then
                                cur_va_v := interpolate(cur_va_v, rom_va_v);
                            end if;
                        end if;

                        -- 5) Closure ramp
                        if cur_closure_v = '0' and (filt_fa /= 0 or filt_va /= 0) then
                            closure_v := (others => '0');
                        elsif closure_v /= to_unsigned(7 * 4, 8) then
                            closure_v := closure_v + 1;
                        end if;

                        -- 6) Pitch counter
                        pitch_v := pitch_v + 1;
                        pitch_reset_val_v := x"e0"
                                             xor unsigned("0" & inflection & "00000")
                                             xor ("000" & filt_f1_v & "0");
                        if pitch_v = pitch_reset_val_v + 2 then
                            pitch_v := (others => '0');
                        end if;

                        -- 7) Filter commit
                        if (pitch_v and x"F9") = x"08" then
                            filt_fa_v  := cur_fa_v(7 downto 4);
                            filt_fc_v  := cur_fc_v(7 downto 4);
                            filt_va_v  := cur_va_v(7 downto 4);
                            filt_f1_v  := cur_f1_v(7 downto 4);
                            filt_f2_v  := cur_f2_v(7 downto 3);
                            filt_f2q_v := cur_f2q_v(7 downto 4);
                            filt_f3_v  := cur_f3_v(7 downto 4);
                            f1_addr_v  := filt_f1_v & "000";
                            f2v_addr_v := (filt_f2q_v & filt_f2_v) & "000";
                            f3_addr_v  := filt_f3_v & "000";
                        end if;

                        -- 8) Noise LFSR
                        if cur_noise_v = '1' and noise_v /= x"7FFF" then
                            noise_inp_v := '1';
                        else
                            noise_inp_v := '0';
                        end if;

                        noise_v := (noise_v(14 downto 0) & noise_inp_v) and x"7FFF";
                        cur_noise_v := not (noise_v(14) xor noise_v(13));

                        -- Signal assignments
                        pitch     <= pitch_v;
                        closure   <= closure_v;
                        cur_noise <= cur_noise_v;
                        filt_fa   <= filt_fa_v;
                        filt_fc   <= filt_fc_v;
                        filt_va   <= filt_va_v;
                        f1_addr   <= f1_addr_v;
                        f2v_addr  <= f2v_addr_v;
                        f3_addr   <= f3_addr_v;
                        rom_duration <= rom_duration_v;
                    end if; -- cclock_en
                end if;
                ar <= ar_v;
            end if;
        end if;
    end process;

end architecture;
