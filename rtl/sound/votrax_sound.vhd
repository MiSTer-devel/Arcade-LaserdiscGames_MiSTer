library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity VotraxSound is
    generic (
        CLK_HZ  : integer := 50_000_000
    );
    port (
        clk : in std_logic;
        reset_n : in std_logic;
        phoneme : in std_logic_vector(5 downto 0);
        inflection : in std_logic_vector(1 downto 0);
        stb: in std_logic;
        ar : out std_logic;
        clk_dac : in std_logic_vector(7 downto 0);
        audio_out : out signed(15 downto 0);
        audio_valid : out std_logic
    );
end entity VotraxSound;

architecture RTL of VotraxSound is
    constant DEN_SC01 : integer := 18 * CLK_HZ;

    signal inc_sc01       : unsigned(31 downto 0);
    signal phase_sc01     : unsigned(31 downto 0) := (others => '0');
    signal sclock      : std_logic := '0';
    signal cclock      : std_logic := '0';

    signal sc01_audio    : signed(17 downto 0);
    signal sc01_av       : std_logic;

    signal rc_amp         : signed(18 downto 0); -- *1.5 intermediate

begin
    -- ================================================================
    -- DDS: SC01 sample tick generator
    -- ================================================================
    process (clk)
        variable sum : unsigned(32 downto 0);
        variable toggle : std_logic := '0';
    begin
        if rising_edge(clk) then
            if reset_n = '0' then
                phase_sc01 <= (others => '0');
                sclock <= '0';
                cclock <= '0';
                toggle := '0';
            else
                sum := ('0' & phase_sc01) + ('0' & inc_sc01);
                phase_sc01 <= sum(31 downto 0);
                sclock <= sum(32);
                cclock <= '0';
                if sum(32) = '1' then
                    toggle := not toggle;
                    if toggle = '1' then
                        cclock <= '1';
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- ================================================================
    -- Clock DAC → DDS increment + speech_clock for resampler
    -- DEN_SC01 = 18 * CLK_HZ, auto-computed from generic
    -- ================================================================
    process (clk)
        variable dac_i : integer;
        variable sc_hz : integer;
        variable numerator : unsigned(63 downto 0);
    begin
        if rising_edge(clk) then
            if reset_n = '0' then
                inc_sc01 <= (others => '0');
            else
                dac_i := to_integer(unsigned(clk_dac));
                if dac_i < 16#40# then
                    dac_i := 16#40#;
                end if;
                sc_hz := 950000 + (dac_i - 16#A0#) * 5500;
                numerator := to_unsigned(sc_hz, 64) sll 32;
                inc_sc01 <= resize(numerator / DEN_SC01, 32);
            end if;
        end if;
    end process;

    -- ================================================================
    -- SC01-A core
    -- ================================================================
    U_SC01A : entity work.sc01a
        generic map (
            IS_SC01A => 0
        )
        port map (
            clk        => clk,
            reset_n    => reset_n,
            p          => phoneme,
            inflection => inflection,
            stb        => stb,
            ar         => ar,
            sclock_en  => sclock,
            cclock_en  => cclock,
            audio_out  => sc01_audio,
            audio_valid => sc01_av
        );

    -- ================================================================
    -- Output
    -- ================================================================

    -- x1.5 gain (rc_out + rc_out>>1), saturate to 16-bit
    rc_amp <= resize(sc01_audio, 19) + resize(shift_right(sc01_audio, 1), 19);

    audio_out <= to_signed( 32767, 16) when rc_amp >  65535 else
                      to_signed(-32768, 16) when rc_amp < -65536 else
                      rc_amp(16 downto 1);
    audio_valid <= sc01_av;

end architecture RTL;
