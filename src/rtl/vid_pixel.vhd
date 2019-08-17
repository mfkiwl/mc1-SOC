----------------------------------------------------------------------------------------------------
-- Copyright (c) 2019 Marcus Geelnard
--
-- This software is provided 'as-is', without any express or implied warranty. In no event will the
-- authors be held liable for any damages arising from the use of this software.
--
-- Permission is granted to anyone to use this software for any purpose, including commercial
-- applications, and to alter it and redistribute it freely, subject to the following restrictions:
--
--  1. The origin of this software must not be misrepresented; you must not claim that you wrote
--     the original software. If you use this software in a product, an acknowledgment in the
--     product documentation would be appreciated but is not required.
--
--  2. Altered source versions must be plainly marked as such, and must not be misrepresented as
--     being the original software.
--
--  3. This notice may not be removed or altered from any source distribution.
----------------------------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.vid_types.all;

----------------------------------------------------------------------------------------------------
-- Video pixel read/output pipeline.
--
-- The pixel pipeline reads pixel data from memory, according to the video configuration (given by
-- the VCR:s). The source pixels are transformed into 32-bit RGBA color values based on the video
-- mode, which may or may not involve color palette lookup.
--
-- The pipeline is as follows:
--
--   XCOORD -> PIXADDR -> PIXFETCH -> SHIFT -> PALFETCH -> COLOR
--
-- XCOORD:
--   Calculate the next x coordinate.
--
-- PIXADDR:
--   Calculate the source pixel word address.
--
-- PIXFETCH:
--   Fetch the pixel word from RAM.
--
-- SHIFT:
--   Shift the relevant bits from the pixel word into the least significant part, according to the
--   current CMODE and x coordinate. This effectively produces the palette lookup address.
--
-- PALFETCH:
--   Fetch the palette color value.
--
-- COLOR:
--   Final color step.
----------------------------------------------------------------------------------------------------

entity vid_pixel is
  generic(
    X_COORD_BITS : positive
  );
  port(
    i_rst : in std_logic;
    i_clk : in std_logic;

    -- Raster control signals.
    i_raster_x : in std_logic_vector(X_COORD_BITS-1 downto 0);

    -- RAM interface.
    o_mem_read_en : out std_logic;
    o_mem_read_addr : out std_logic_vector(23 downto 0);
    i_mem_data : in std_logic_vector(31 downto 0);

    -- Palette interface.
    o_pal_addr : out std_logic_vector(7 downto 0);
    i_pal_data : in std_logic_vector(31 downto 0);

    -- VCR:s.
    i_regs : in T_VID_REGS;

    -- Final output color.
    o_color : out std_logic_vector(31 downto 0)
  );
end vid_pixel;

architecture rtl of vid_pixel is
  -- Fixed point configuration (16.16 bits).
  constant C_FP_BITS : positive := 32;

  -- Color modes.
  constant C_CMODE_RGBA32 : std_logic_vector(3 downto 0) := 4X"0";
  constant C_CMODE_RGBA16 : std_logic_vector(3 downto 0) := 4X"1";
  constant C_CMODE_PAL8 : std_logic_vector(3 downto 0) := 4X"2";
  constant C_CMODE_PAL4 : std_logic_vector(3 downto 0) := 4X"3";
  constant C_CMODE_PAL2 : std_logic_vector(3 downto 0) := 4X"4";
  constant C_CMODE_PAL1 : std_logic_vector(3 downto 0) := 4X"5";

  signal s_xc_hpos : unsigned(23 downto 0);
  signal s_xc_next_active : std_logic;
  signal s_xc_active : std_logic;
  signal s_xc_next_pos : std_logic_vector(C_FP_BITS-1 downto 0);
  signal s_xc_pos : std_logic_vector(C_FP_BITS-1 downto 0);
  signal s_xc_pos_plus_incr : std_logic_vector(C_FP_BITS-1 downto 0);

  signal s_pa_offs_32 : std_logic_vector(23 downto 0);
  signal s_pa_offs_16 : std_logic_vector(23 downto 0);
  signal s_pa_offs_8 : std_logic_vector(23 downto 0);
  signal s_pa_offs_4 : std_logic_vector(23 downto 0);
  signal s_pa_offs_2 : std_logic_vector(23 downto 0);
  signal s_pa_offs_1 : std_logic_vector(23 downto 0);
  signal s_pa_offs : std_logic_vector(23 downto 0);
  signal s_pa_addr : std_logic_vector(23 downto 0);
  signal s_pa_next_shift_32 : std_logic_vector(4 downto 0);
  signal s_pa_next_shift_16 : std_logic_vector(4 downto 0);
  signal s_pa_next_shift_8 : std_logic_vector(4 downto 0);
  signal s_pa_next_shift_4 : std_logic_vector(4 downto 0);
  signal s_pa_next_shift_2 : std_logic_vector(4 downto 0);
  signal s_pa_next_shift_1 : std_logic_vector(4 downto 0);
  signal s_pa_next_shift : std_logic_vector(4 downto 0);
  signal s_pa_shift : std_logic_vector(4 downto 0);
  signal s_pa_active : std_logic;

  signal s_pf_data : std_logic_vector(31 downto 0);
  signal s_pf_shift : std_logic_vector(4 downto 0);
  signal s_pf_active : std_logic;

  signal s_sh_shifted_idx : std_logic_vector(7 downto 0);
  signal s_sh_shifted_rgba16 : std_logic_vector(15 downto 0);
  signal s_sh_next_data : std_logic_vector(31 downto 0);
  signal s_sh_data : std_logic_vector(31 downto 0);
  signal s_sh_next_is_truecolor : std_logic;
  signal s_sh_is_truecolor : std_logic;
  signal s_sh_active : std_logic;

  signal s_palf_next_data : std_logic_vector(31 downto 0);
  signal s_palf_data : std_logic_vector(31 downto 0);

  function xcoord_to_unsigned24(x: std_logic_vector) return unsigned is
    variable v_result : unsigned(23 downto 0);
  begin
    v_result(23 downto X_COORD_BITS) := (others => '0');
    v_result(X_COORD_BITS-1 downto 0) := unsigned(x);
    return v_result;
  end;

  function fp24_to_fp32(x: std_logic_vector) return std_logic_vector is
    variable v_result : std_logic_vector(31 downto 0);
  begin
    v_result(31 downto 24) := (others => x(23));
    v_result(23 downto 0) := x;
    return v_result;
  end;

  function rgba16_to_rgba32(x: std_logic_vector) return std_logic_vector is
    variable v_r : std_logic_vector(7 downto 0);
    variable v_g : std_logic_vector(7 downto 0);
    variable v_b : std_logic_vector(7 downto 0);
    variable v_a : std_logic_vector(7 downto 0);
  begin
    v_r := x(15 downto 11) & x(15 downto 13);
    v_g := x(10 downto 6) & x(10 downto 8);
    v_b := x(5 downto 1) & x(5 downto 3);
    v_a := (others => x(0));
    return v_r & v_g & v_b & v_a;
  end;

  function shr_8bits(x: std_logic_vector; s: std_logic_vector) return std_logic_vector is
    variable v_shift : integer;
    variable v_shr32 : unsigned(31 downto 0);
  begin
    v_shift := to_integer(unsigned(s));
    v_shr32 := shift_right(unsigned(x), v_shift);
    return std_logic_vector(v_shr32(7 downto 0));
  end;
begin
  -----------------------------------------------------------------------------
  -- XCOORD
  -----------------------------------------------------------------------------

  -- Determine if we're in the active region (i.e. between HSTRT and HSTOP).
  s_xc_hpos <= xcoord_to_unsigned24(i_raster_x);
  s_xc_next_active <= '1' when s_xc_hpos >= unsigned(i_regs.HSTRT) and
                               s_xc_hpos <  unsigned(i_regs.HSTOP) else
                      '0';

  -- Increment the x coordinate.
  s_xc_pos_plus_incr <= std_logic_vector(unsigned(s_xc_pos) +
                                         unsigned(fp24_to_fp32(i_regs.XINCR)));
  s_xc_next_pos <= fp24_to_fp32(i_regs.XOFFS) when unsigned(i_raster_x) = to_unsigned(0, X_COORD_BITS) else
                   s_xc_pos_plus_incr when s_xc_next_active = '1' else
                   s_xc_pos;

  -- XCOORD registers.
  process(i_clk, i_rst)
  begin
    if i_rst = '1' then
      s_xc_pos <= (others => '0');
      s_xc_active <= '0';
    elsif rising_edge(i_clk) then
      s_xc_pos <= s_xc_next_pos;
      s_xc_active <= s_xc_next_active;
    end if;
  end process;


  -----------------------------------------------------------------------------
  -- PIXADDR
  -----------------------------------------------------------------------------

  -- Determine the offset, taking into account the bits-per-pixel as a shift.
  s_pa_offs_32(23 downto 16) <= (others => s_xc_pos(31));
  s_pa_offs_32(15 downto 0)  <= s_xc_pos(31 downto 16);
  s_pa_offs_16(23 downto 15) <= (others => s_xc_pos(31));
  s_pa_offs_16(14 downto 0)  <= s_xc_pos(31 downto 17);
  s_pa_offs_8(23 downto 14) <= (others => s_xc_pos(31));
  s_pa_offs_8(13 downto 0)  <= s_xc_pos(31 downto 18);
  s_pa_offs_4(23 downto 13) <= (others => s_xc_pos(31));
  s_pa_offs_4(12 downto 0)  <= s_xc_pos(31 downto 19);
  s_pa_offs_2(23 downto 12) <= (others => s_xc_pos(31));
  s_pa_offs_2(11 downto 0)  <= s_xc_pos(31 downto 20);
  s_pa_offs_1(23 downto 11) <= (others => s_xc_pos(31));
  s_pa_offs_1(10 downto 0)  <= s_xc_pos(31 downto 21);

  OffsetMux: with i_regs.CMODE(3 downto 0) select
    s_pa_offs <=
        s_pa_offs_32 when C_CMODE_RGBA32,
        s_pa_offs_16 when C_CMODE_RGBA16,
        s_pa_offs_8 when C_CMODE_PAL8,
        s_pa_offs_4 when C_CMODE_PAL4,
        s_pa_offs_2 when C_CMODE_PAL2,
        s_pa_offs_1 when C_CMODE_PAL1,
        (others => '-') when others;

  -- Calculate the memory address.
  s_pa_addr <= std_logic_vector(unsigned(i_regs.ADDR) + unsigned(s_pa_offs));

  -- Determine the bit shift amount.
  s_pa_next_shift_32 <= "00000";
  s_pa_next_shift_16 <= s_xc_pos(16 downto 16) & "0000";
  s_pa_next_shift_8 <= s_xc_pos(17 downto 16) & "000";
  s_pa_next_shift_4 <= s_xc_pos(18 downto 16) & "00";
  s_pa_next_shift_2 <= s_xc_pos(19 downto 16) & "0";
  s_pa_next_shift_1 <= s_xc_pos(20 downto 16);

  ShiftMux: with i_regs.CMODE(3 downto 0) select
    s_pa_next_shift <=
        s_pa_next_shift_32 when C_CMODE_RGBA32,
        s_pa_next_shift_16 when C_CMODE_RGBA16,
        s_pa_next_shift_8 when C_CMODE_PAL8,
        s_pa_next_shift_4 when C_CMODE_PAL4,
        s_pa_next_shift_2 when C_CMODE_PAL2,
        s_pa_next_shift_1 when C_CMODE_PAL1,
        (others => '-') when others;

  -- Outputs to the memory read interface.
  -- TODO(m): Add a single-word cache to reduce the number of memory accesses.
  o_mem_read_addr <= s_pa_addr;
  o_mem_read_en <= s_xc_active;

  -- PIXADDR registers.
  process(i_clk, i_rst)
  begin
    if i_rst = '1' then
      s_pa_shift <= (others => '0');
      s_pa_active <= '0';
    elsif rising_edge(i_clk) then
      s_pa_shift <= s_pa_next_shift;
      s_pa_active <= s_xc_active;
    end if;
  end process;


  -----------------------------------------------------------------------------
  -- PIXFETCH
  -----------------------------------------------------------------------------

  -- PIXFETCH registers.
  process(i_clk, i_rst)
  begin
    if i_rst = '1' then
      s_pf_data <= (others => '0');
      s_pf_shift <= (others => '0');
      s_pf_active <= '0';
    elsif rising_edge(i_clk) then
      s_pf_data <= i_mem_data;
      s_pf_shift <= s_pa_shift;
      s_pf_active <= s_pa_active;
    end if;
  end process;


  -----------------------------------------------------------------------------
  -- SHIFT
  -----------------------------------------------------------------------------

  -- Determine the palette index by shifting and masking the data word.
  s_sh_shifted_idx <= shr_8bits(s_pf_data, s_pf_shift);

  -- Mask the palette index according to the current CMODE (i.e. only preserve
  -- the correct number of bits per pixel).
  IdxMaskMux: with i_regs.CMODE(3 downto 0) select
    o_pal_addr <=
        "0000"    & s_sh_shifted_idx(3 downto 0) when C_CMODE_PAL4,
        "000000"  & s_sh_shifted_idx(1 downto 0) when C_CMODE_PAL2,
        "0000000" & s_sh_shifted_idx(0 downto 0) when C_CMODE_PAL1,
        s_sh_shifted_idx when others;  -- C_CMODE_PAL8 (and others)

  -- Truecolor data transformation.
  -- NOTE: We select the correct half of the 32-bit word when the color mode is
  -- RGBA16, based on the shift amount (which can only be 0 or 16).
  s_sh_shifted_rgba16 <= s_pf_data(31 downto 16) when s_pf_shift(4) = '1' else
                         s_pf_data(15 downto 0);
  s_sh_next_data <= s_pf_data when i_regs.CMODE(3 downto 0) = C_CMODE_RGBA32 else
                    rgba16_to_rgba32(s_sh_shifted_rgba16);

  -- Is this a palette lookup or truecolor pixel?
  IsTruecolorMux: with i_regs.CMODE(3 downto 0) select
    s_sh_next_is_truecolor <=
        '1' when C_CMODE_RGBA32 | C_CMODE_RGBA16,
        '0' when others;

  -- SHIFT registers.
  process(i_clk, i_rst)
  begin
    if i_rst = '1' then
      s_sh_data <= (others => '0');
      s_sh_is_truecolor <= '0';
      s_sh_active <= '0';
    elsif rising_edge(i_clk) then
      s_sh_data <= s_sh_next_data;
      s_sh_is_truecolor <= s_sh_next_is_truecolor;
      s_sh_active <= s_pf_active;
    end if;
  end process;


  -----------------------------------------------------------------------------
  -- PALFETCH
  -----------------------------------------------------------------------------

  -- Select which color source to use (truecolor or palette).
  s_palf_next_data <= (others => '0') when s_sh_active = '0' else
                      s_sh_data when s_sh_is_truecolor = '1' else
                      i_pal_data;

  -- PALFETCH registers.
  process(i_clk, i_rst)
  begin
    if i_rst = '1' then
      s_palf_data <= (others => '0');
    elsif rising_edge(i_clk) then
      s_palf_data <= s_palf_next_data;
    end if;
  end process;


  -----------------------------------------------------------------------------
  -- COLOR
  -----------------------------------------------------------------------------

  -- Output the final color.
  o_color <= s_palf_data;
end rtl;
