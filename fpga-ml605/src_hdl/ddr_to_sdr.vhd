-------------------------------------------------------------------------------
--  CRUSH
--  Cognitive Radio Universal Software Hardware
--  http://www.coe.neu.edu/Research/rcl//projects/CRUSH.php
-- 
--  File: ddr_to_sdr.vhd
--  Description: Converts DDR input data (data transitions on both rising and 
--               falling edges) to SDR data (data transition only on rising
--               edge). Uses a phase shifted clock derived from a MMCM
--               to properly clock the DDR data in at the center of the 
--               eye. As a consequence of this design method, the MMCM's
--               phase shift must be calibrated (as described below) and
--               and the MMCM MUST BE LOCKED down with a location
--               constraint.
--               
--               Note: It is expected that clk_sdr freq > clk_ddr freq.
--               
--               How to calibrate?
--               
--               
--               Customization?
--               Input data is assumed to be no more than 18 bits wide. This 
--               can be changed, but the FIFO buffer must be regenerated with 
--               the proper bit width.
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library unisim;
use unisim.vcomponents.all;

entity ddr_to_sdr is
  generic (
    BIT_WIDTH         : integer;                                      -- Input data width
    USE_PHASE_SHIFT   : boolean;                                      -- Set MMCM phase shift with PHASE_SHIFT
    PHASE_SHIFT       : integer);                                     -- MMCM phase shift tap setting
  port (
    reset             : in    std_logic;                              -- Active high reset
    -- DDR interface
    ddr_data_clk      : in    std_logic;                              -- DDR data clock (from pin)
    ddr_data          : in    std_logic_vector(BIT_WIDTH-1 downto 0); -- DDR data (from pin)
    clk_ddr           : out   std_logic;                              -- MMCM derived DDR clock
    clk_ddr_locked    : out   std_logic;                              -- MMCM DDR data clock locked
    -- SDR interface
    clk_sdr           : in    std_logic;                              -- SDR data clock
    sdr_data_vld      : out   std_logic;
    sdr_data          : out   std_logic_vector((2*BIT_WIDTH)-1 downto 0));
end entity;

architecture RTL of ddr_to_sdr is

-------------------------------------------------------------------------------
-- Component Declaration
-------------------------------------------------------------------------------
  component BUFR is
    generic (
      BUFR_DIVIDE               : string;           -- "BYPASS", "1", "2", "3", "4", "5", "6", "7", "8"
      SIM_DEVICE                : string);          -- Specify target device, "VIRTEX4", "VIRTEX5", "VIRTEX6"
    port (
      O                         : out   std_logic;  -- Clock buffer output
      CE                        : in    std_logic;  -- Clock enable input
      CLR                       : in    std_logic;  -- Clock buffer reset input
      I                         : in    std_logic); -- Clock buffer input
  end component;

  component mmcm_ddr_to_sdr is
    port (
      CLKIN_100MHz              : in     std_logic;
      CLKOUT_100MHz             : out    std_logic;
      -- Dynamic phase shift ports
      PSCLK                     : in     std_logic;
      PSEN                      : in     std_logic;
      PSINCDEC                  : in     std_logic;
      PSDONE                    : out    std_logic;
      -- Status and control signals
      RESET                     : in     std_logic;
      LOCKED                    : out    std_logic);
  end component;

  component IDDR is
    generic (
      DDR_CLK_EDGE              : string;           -- "OPPOSITE_EDGE", "SAME_EDGE"
                                                    -- or "SAME_EDGE_PIPELINED"
      INIT_Q1                   : std_logic;        -- Initial value of Q1: '0' or '1'
      INIT_Q2                   : std_logic;        -- Initial value of Q2: '0' or '1'
      SRTYPE                    : string);          -- Set/Reset type: "SYNC" or "ASYNC"
    port (
      Q1                        : out   std_logic;  -- Output for positive edge of clock
      Q2                        : out   std_logic;  -- Output for negative edge of clock
      C                         : in    std_logic;  -- Clock input
      CE                        : in    std_logic;  -- Clock enable input
      D                         : in    std_logic;  -- DDR data input
      R                         : in    std_logic;  -- Reset
      S                         : in    std_logic); -- Set
  end component;

  component fifo_36x16 is
    port (
      rst                       : in std_logic;
      wr_clk                    : in std_logic;
      rd_clk                    : in std_logic;
      din                       : in std_logic_vector(35 downto 0);
      wr_en                     : in std_logic;
      rd_en                     : in std_logic;
      dout                      : out std_logic_vector(35 downto 0);
      full                      : out std_logic;
      almost_full               : out std_logic;
      empty                     : out std_logic;
      almost_empty              : out std_logic;
      valid                     : out std_logic;
      underflow                 : out std_logic);
  end component;

-------------------------------------------------------------------------------
-- Signal Declaration
-------------------------------------------------------------------------------
  signal ddr_data_clk_bufr      : std_logic;
  signal clk_ddr_locked_int     : std_logic;
  signal psclk                  : std_logic;
  signal psen                   : std_logic;
  signal psincdec               : std_logic;
  signal psdone                 : std_logic;
  signal ddr_data_rising        : std_logic_vector(BIT_WIDTH-1 downto 0);
  signal ddr_data_falling       : std_logic_vector(BIT_WIDTH-1 downto 0);
  signal ddr_data_concatenated  : std_logic_vector((2*BIT_WIDTH)-1 downto 0);
  signal ddr_data_fifo          : std_logic_vector(35 downto 0);


begin


  BUFR_inst : BUFR
    generic map (
      BUFR_DIVIDE               => "BYPASS",
      SIM_DEVICE                => "VIRTEX6")
    port map (
      I                         => ddr_data_clk,
      CE                        => '1',
      CLR                       => '0',
      O                         => ddr_data_clk_bufr);

  mmcm_ddr_to_sdr_inst : mmcm_ddr_to_sdr
    port map (
      CLKIN_100MHz              => ddr_data_clk_bufr,
      CLKOUT_100MHz             => clk_ddr,
      PSCLK                     => psclk,
      PSEN                      => psen,
      PSINCDEC                  => psincdec,
      PSDONE                    => psdone,
      RESET                     => reset,
      LOCKED                    => clk_ddr_locked_int);

  clk_ddr_locked                <= clk_ddr_locked_int;

  for i in 0 to BIT_WIDTH-1 generate
    IDDR_gen : IDDR
      generic map (
        DDR_CLK_EDGE            => "SAME_EDGE_PIPELINED",
        INIT_Q1                 => '0',
        INIT_Q2                 => '0',
        SRTYPE                  => "ASYNC")
      port map (
        Q1                      => ddr_data_rising(i),
        Q2                      => ddr_data_falling(i),
        C                       => clk_ddr_mmcm,
        CE                      => '1',
        D                       => ddr_data(i),
        R                       => clk_ddr_locked_int,
        S                       => '0');
  end generate;

  ddr_data_concatenated         <= ddr_data_rising & ddr_data_falling;
  for j in 0 to 35 generate
    if (j < 2*BIT_WIDTH) then
      ddr_data_fifo(j)          <= ddr_data_concatenated(j);
    else
      ddr_data_fifo(j)          <= '0';
    end if;
  end generate

  almost_full_n                 <= NOT(almost_full);
  almost_empty_n                <= NOT(almost_empty);

  fifo_36x16_inst : fifo_36x16
    port map (
      rst                       => clk_ddr_locked_int,
      wr_clk                    => clk_ddr,
      rd_clk                    => clk_sdr,
      din                       => ddr_data_fifo,
      wr_en                     => almost_full_n,
      rd_en                     => almost_empty,
      dout                      => sdr_data_fifo,
      full                      => open,
      almost_full               => almost_full,
      empty                     => open,
      almost_empty              => almost_empty,
      valid                     => open,
      underflow                 => open);

  sdr_data_reg_proc : process(clk_sdr)
  begin
    if rising_edge(clk_sdr) then
      sdr_data_vld              <= almost_empty_n;
      sdr_data                  <= sdr_data_fifo((2*BIT_WIDTH)-1 downto 0);
    end if;
  end process;

end architecture