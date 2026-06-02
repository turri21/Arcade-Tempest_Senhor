-- tb_pokeypot.vhd -- does our pokey.vhd pot read produce the value Tempest's spinner
-- routine expects?  MAME: pot[i] = (knob & (1<<i)) ? 0 : 228.  We drive PIN[3:0] with a
-- known knob nibble, run a POTGO scan, read pot_val[0..3], and compare.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_pokeypot is end entity;
architecture sim of tb_pokeypot is
  signal clk   : std_logic := '0';
  signal ena   : std_logic := '1';
  signal addr  : std_logic_vector(3 downto 0) := (others=>'0');
  signal din   : std_logic_vector(7 downto 0) := (others=>'0');
  signal dout  : std_logic_vector(7 downto 0);
  signal rw_l  : std_logic := '1';
  signal cs    : std_logic := '1';
  signal cs_l  : std_logic := '0';
  signal pin   : std_logic_vector(7 downto 0) := (others=>'0');
  signal aud   : std_logic_vector(7 downto 0);
  constant TCK : time := 83 ns;  -- ~12MHz feed; pokey divides internally
begin
  dut: entity work.pokey port map (
    ADDR=>addr, DIN=>din, DOUT=>dout, DOUT_OE_L=>open, RW_L=>rw_l,
    CS=>cs, CS_L=>cs_l, AUDIO_OUT=>aud, PIN=>pin, ENA=>ena, CLK=>clk);
  clk <= not clk after TCK/2;

  stim: process
    -- write a pokey register
    procedure pwr(a: in integer; d: in integer) is
    begin
      wait until rising_edge(clk);
      addr <= std_logic_vector(to_unsigned(a,4));
      din  <= std_logic_vector(to_unsigned(d,8));
      rw_l <= '0'; cs_l <= '0';
      wait until rising_edge(clk);
      rw_l <= '1'; cs_l <= '1';
    end procedure;
    -- read a pokey register (pot)
    procedure prd(a: in integer; v: out integer) is
    begin
      wait until rising_edge(clk);
      addr <= std_logic_vector(to_unsigned(a,4));
      rw_l <= '1'; cs_l <= '0';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      v := to_integer(unsigned(dout));
      cs_l <= '1';
    end procedure;
    variable potv : integer;
    variable knob : integer;
    variable expect : integer;
    variable fails : integer := 0;
    variable l : line;
  begin
    -- enable fast-scan (SKCTL bit2 = '1') via ADDR $F
    pwr(15, 16#04#);
    -- test knob nibbles 0..15
    for knob in 0 to 15 loop
      pin <= "0000" & std_logic_vector(to_unsigned(knob,4));  -- PIN[3:0]=knob, [7:4]=0
      pwr(11, 0);                 -- POTGO (ADDR $B) starts scan
      -- let the scan complete (228 counts of the internal pot clock; give plenty)
      for w in 0 to 4000 loop wait until rising_edge(clk); end loop;
      for i in 0 to 3 loop
        prd(i, potv);
        -- MAME: bit set -> 0, bit clear -> 228
        if ((knob / (2**i)) mod 2) = 1 then expect := 0; else expect := 228; end if;
        write(l, string'("knob=")); write(l, knob);
        write(l, string'(" pot[")); write(l, i); write(l, string'("]="));
        write(l, potv); write(l, string'(" expect=")); write(l, expect);
        if potv = expect then write(l, string'("  OK"));
        else write(l, string'("  MISMATCH")); fails := fails + 1; end if;
        writeline(output, l);
      end loop;
    end loop;
    write(l, string'("=== POKEY POT: ")); write(l, fails); write(l, string'(" mismatches ==="));
    writeline(output, l);
    if fails = 0 then write(l, string'("PASS: pot matches MAME spec"));
    else write(l, string'("FAIL: pot does NOT match -> spinner read is broken here")); end if;
    writeline(output, l);
    wait;
  end process;
end architecture;
