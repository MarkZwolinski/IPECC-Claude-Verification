--
-- tb_ecc.vhd — standalone black-box AXI-level testbench for the ecc entity.
--
-- Uses the small 21-bit test curve from sim/ecc_vec_in.txt (nn=21) with
-- blinding disabled at runtime so simulation finishes in seconds instead
-- of minutes.  nn is set dynamically via W_PRIME_SIZE (requires
-- nn_dynamic=TRUE in ecc_customize.vhd, which is the default).
--
-- Build:  cd tb && make
-- Run:    make run
--
-- Copyright (C) 2023 - This file is part of IPECC project
-- SPDX-License-Identifier: GPL-2.0-only
--

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

use work.ecc_customize.all; -- nn, ww, axi32or64, nn_dynamic, blinding, ...
use work.ecc_utils.all;     -- div(), log2(), ...
use work.ecc_pkg.all;       -- AXIAW, ADB, rat, FP_ADDR_MSB, CST_ADDR_*, ...
use work.ecc_vars.all;      -- LARGE_NB_*_ADDR
use work.ecc_software.all;  -- W_CTRL, R_STATUS, CTRL_KP, STATUS_BUSY, ...

entity tb_ecc is
end entity tb_ecc;

architecture bench of tb_ecc is

  constant AXIDW : integer := axi32or64; -- 32 from ecc_customize

  -- Security level for this run.  21 <= static nn in ecc_customize (528).
  -- One 32-bit AXI word covers 21 bits (NW=1), so each large-number
  -- transfer is a single write/read — very fast in simulation.
  constant NN_TB : positive := 21;
  constant NW    : positive := div(NN_TB, AXIDW); -- = 1

  -- Carrier type: 32-bit words (NW=1 means we only ever touch bits 31..0)
  subtype word32 is std_logic_vector(31 downto 0);

  -- -----------------------------------------------------------------------
  -- AXI-lite bus types (local — no dependency on sim/ package)
  -- -----------------------------------------------------------------------
  type axi_ms_type is record
    awaddr  : std_logic_vector(AXIAW - 1 downto 0);
    awvalid : std_logic;
    wdata   : std_logic_vector(AXIDW - 1 downto 0);
    wstrb   : std_logic_vector(AXIDW/8 - 1 downto 0);
    wvalid  : std_logic;
    bready  : std_logic;
    araddr  : std_logic_vector(AXIAW - 1 downto 0);
    arvalid : std_logic;
    rready  : std_logic;
  end record;

  type axi_sm_type is record
    awready : std_logic;
    wready  : std_logic;
    bresp   : std_logic_vector(1 downto 0);
    bvalid  : std_logic;
    arready : std_logic;
    rdata   : std_logic_vector(AXIDW - 1 downto 0);
    rresp   : std_logic_vector(1 downto 0);
    rvalid  : std_logic;
  end record;

  -- -----------------------------------------------------------------------
  -- Clock & reset
  -- -----------------------------------------------------------------------
  constant CLK_PERIOD : time := 6667 ps; -- ~150 MHz

  signal clk     : std_logic := '0';
  signal aresetn : std_logic := '0';

  -- -----------------------------------------------------------------------
  -- AXI bus signals
  -- -----------------------------------------------------------------------
  signal ms : axi_ms_type := (
    awaddr  => (others => '0'), awvalid => '0',
    wdata   => (others => '0'), wstrb   => (others => '1'), wvalid  => '0',
    bready  => '1',
    araddr  => (others => '0'), arvalid => '0', rready  => '0');

  signal sm : axi_sm_type;

  -- -----------------------------------------------------------------------
  -- Misc UUT ports
  -- -----------------------------------------------------------------------
  signal irq        : std_logic;
  signal busy       : std_logic;
  signal dbgtrigger : std_logic;
  signal dbghalted  : std_logic;
  signal dbgptrdy   : std_logic;
  signal clkdivo    : std_logic;
  signal clkmmdivo  : std_logic;

  -- -----------------------------------------------------------------------
  -- 21-bit test curve parameters (from sim/ecc_vec_in.txt, curve #0)
  -- All constants are 32 bits wide; actual field values sit in bits [20:0].
  -- -----------------------------------------------------------------------
  constant C_P  : word32 := x"001ce54b"; -- prime p
  constant C_A  : word32 := x"000ec20f"; -- curve coefficient a
  constant C_B  : word32 := x"001bb973"; -- curve coefficient b
  constant C_Q  : word32 := x"001ce256"; -- group order q

  -- Test 1 — [k]P: k·(Px,Py) = (kPx, kPy)
  constant T1_K   : word32 := x"001c0ac1";
  constant T1_PX  : word32 := x"0000851a";
  constant T1_PY  : word32 := x"000a0e0f";
  constant T1_RX  : word32 := x"000acc93";
  constant T1_RY  : word32 := x"000e007f";

  -- Test 2 — ptadd: (T2_PX,T2_PY) + (T2_QX,T2_QY) = (T2_RX,T2_RY)
  constant T2_PX  : word32 := x"000e58a7";
  constant T2_PY  : word32 := x"000b0eb7";
  constant T2_QX  : word32 := x"0007136d";
  constant T2_QY  : word32 := x"00032a06";
  constant T2_RX  : word32 := x"000c11ee";
  constant T2_RY  : word32 := x"0007c882";

  -- Test 3 — ptdbl: 2·(T3_PX,T3_PY) = (T3_RX,T3_RY)
  constant T3_PX  : word32 := x"000adc61";
  constant T3_PY  : word32 := x"0014fae0";
  constant T3_RX  : word32 := x"001462de";
  constant T3_RY  : word32 := x"000cfb3a";

  -- Test 4 — ptneg: -(T4_PX,T4_PY) = (T4_RX,T4_RY)  (negY = p − PY)
  constant T4_PX  : word32 := x"000a3f63";
  constant T4_PY  : word32 := x"0016043d"; -- note: 0x1ce54b − 0x16043d = 0x06e10e
  constant T4_RX  : word32 := x"000a3f63";
  constant T4_RY  : word32 := x"0006e10e";

  -- Test 5 — on-curve check (Px,Py): this point is NOT on the curve
  constant T5_PX  : word32 := x"00041730";
  constant T5_PY  : word32 := x"0019233e";

  -- Cross-check scalars
  constant K_QMIN1 : word32 := x"001ce255"; -- q − 1 = 0x1ce255
  constant K_TWO   : word32 := x"00000002";

  -- -----------------------------------------------------------------------
  -- BFM procedures
  -- -----------------------------------------------------------------------

  procedure axi_write(
    constant reg  : in  rat;
    constant data : in  word32;
    signal   clk  : in  std_logic;
    signal   ms   : out axi_ms_type;
    signal   sm   : in  axi_sm_type) is
  begin
    wait until clk'event and clk = '1';
    ms.awaddr  <= reg & "000";
    ms.awvalid <= '1';
    wait until clk'event and clk = '1' and sm.awready = '1';
    ms.awaddr  <= (others => 'X');
    ms.awvalid <= '0';
    ms.wdata   <= data;
    ms.wvalid  <= '1';
    wait until clk'event and clk = '1' and sm.wready = '1';
    ms.wdata   <= (others => 'X');
    ms.wvalid  <= '0';
  end procedure;

  procedure axi_read(
    constant reg  : in  rat;
    variable data : out word32;
    signal   clk  : in  std_logic;
    signal   ms   : out axi_ms_type;
    signal   sm   : in  axi_sm_type) is
  begin
    wait until clk'event and clk = '1';
    ms.araddr  <= reg & "000";
    ms.arvalid <= '1';
    wait until clk'event and clk = '1' and sm.arready = '1';
    ms.araddr  <= (others => 'X');
    ms.arvalid <= '0';
    ms.rready  <= '1';
    wait until clk'event and clk = '1' and sm.rvalid = '1';
    data       := sm.rdata;
    ms.rready  <= '0';
  end procedure;

  procedure poll_ready(
    signal clk : in  std_logic;
    signal ms  : out axi_ms_type;
    signal sm  : in  axi_sm_type) is
    variable d : word32;
  begin
    loop
      axi_read(R_STATUS, d, clk, ms, sm);
      exit when d(STATUS_BUSY) = '0';
    end loop;
  end procedure;

  -- Write a 21-bit (NW=1 word) large number to fp_dram address 'addr'
  procedure write_nn(
    constant addr : in  natural range 0 to nblargenb - 1;
    constant val  : in  word32;
    signal   clk  : in  std_logic;
    signal   ms   : out axi_ms_type;
    signal   sm   : in  axi_sm_type) is
    variable ctrl : word32 := (others => '0');
  begin
    poll_ready(clk, ms, sm);
    ctrl := (others => '0');
    ctrl(CTRL_WRITE_NB) := '1';
    ctrl(CTRL_NBADDR_LSB + FP_ADDR_MSB - 1 downto CTRL_NBADDR_LSB) :=
      std_logic_vector(to_unsigned(addr, FP_ADDR_MSB));
    axi_write(W_CTRL, ctrl, clk, ms, sm);
    -- NW=1: one word covers all 21 bits
    poll_ready(clk, ms, sm);
    axi_write(W_WRITE_DATA, val, clk, ms, sm);
  end procedure;

  procedure write_k(
    constant val  : in  word32;
    signal   clk  : in  std_logic;
    signal   ms   : out axi_ms_type;
    signal   sm   : in  axi_sm_type) is
    variable ctrl : word32;
  begin
    poll_ready(clk, ms, sm);
    ctrl := (others => '0');
    ctrl(CTRL_WRITE_NB) := '1';
    ctrl(CTRL_WRITE_K)  := '1';
    ctrl(CTRL_NBADDR_LSB + FP_ADDR_MSB - 1 downto CTRL_NBADDR_LSB) := CST_ADDR_K;
    axi_write(W_CTRL, ctrl, clk, ms, sm);
    poll_ready(clk, ms, sm);
    axi_write(W_WRITE_DATA, val, clk, ms, sm);
  end procedure;

  procedure read_nn(
    constant addr  : in  natural range 0 to nblargenb - 1;
    variable val   : out word32;
    signal   clk   : in  std_logic;
    signal   ms    : out axi_ms_type;
    signal   sm    : in  axi_sm_type) is
    variable ctrl  : word32;
  begin
    poll_ready(clk, ms, sm);
    ctrl := (others => '0');
    ctrl(CTRL_READ_NB) := '1';
    ctrl(CTRL_NBADDR_LSB + FP_ADDR_MSB - 1 downto CTRL_NBADDR_LSB) :=
      std_logic_vector(to_unsigned(addr, FP_ADDR_MSB));
    axi_write(W_CTRL, ctrl, clk, ms, sm);
    -- NW=1
    axi_read(R_READ_DATA, val, clk, ms, sm);
  end procedure;

  -- Obtain token (required for hwsecure=TRUE result unmasking).
  -- Returns zero when hwsecure=FALSE, harmless XOR either way.
  procedure get_token(
    variable tok  : out word32;
    signal   clk  : in  std_logic;
    signal   ms   : out axi_ms_type;
    signal   sm   : in  axi_sm_type) is
    variable ctrl : word32;
    variable zero : word32 := (others => '0');
  begin
    axi_write(W_TOKEN, zero, clk, ms, sm);
    poll_ready(clk, ms, sm);
    ctrl := (others => '0');
    ctrl(CTRL_READ_NB)  := '1';
    ctrl(CTRL_RD_TOKEN) := '1';
    axi_write(W_CTRL, ctrl, clk, ms, sm);
    -- NW=1
    axi_read(R_READ_DATA, tok, clk, ms, sm);
  end procedure;

  -- Disable blinding (write BLD_EN=0 to W_BLINDING).
  -- Must be called before the first [k]P to avoid poll_enough_rnd stall.
  procedure disable_blinding(
    signal clk : in  std_logic;
    signal ms  : out axi_ms_type;
    signal sm  : in  axi_sm_type) is
    variable zero : word32 := (others => '0');
  begin
    axi_write(W_BLINDING, zero, clk, ms, sm);
  end procedure;

  -- Set dynamic prime size (W_PRIME_SIZE); requires nn_dynamic=TRUE
  procedure set_nn_dyn(
    constant valnn : in  positive;
    signal   clk   : in  std_logic;
    signal   ms    : out axi_ms_type;
    signal   sm    : in  axi_sm_type) is
  begin
    poll_ready(clk, ms, sm);
    axi_write(W_PRIME_SIZE,
              std_logic_vector(to_unsigned(valnn, AXIDW)),
              clk, ms, sm);
    poll_ready(clk, ms, sm); -- wait for Montgomery constants to be recomputed
  end procedure;

  -- Load the small test-curve parameters (p, a, b, q)
  procedure load_curve(
    signal clk : in  std_logic;
    signal ms  : out axi_ms_type;
    signal sm  : in  axi_sm_type) is
  begin
    write_nn(LARGE_NB_P_ADDR, C_P, clk, ms, sm);
    write_nn(LARGE_NB_A_ADDR, C_A, clk, ms, sm);
    write_nn(LARGE_NB_B_ADDR, C_B, clk, ms, sm);
    write_nn(LARGE_NB_Q_ADDR, C_Q, clk, ms, sm);
  end procedure;

  -- Full [k]P: write k and point, trigger, poll, read back (XOR token to unmask),
  -- assert against expected values.
  procedure check_kp(
    constant k        : in  word32;
    constant px       : in  word32;
    constant py       : in  word32;
    constant exp_x    : in  word32;
    constant exp_y    : in  word32;
    constant test_name: in  string;
    signal   clk      : in  std_logic;
    signal   ms       : out axi_ms_type;
    signal   sm       : in  axi_sm_type) is
    variable tok      : word32;
    variable rx, ry   : word32;
    variable stat     : word32;
    variable ctrl     : word32;
    variable zero     : word32 := (others => '0');
  begin
    get_token(tok, clk, ms, sm);
    write_k(k, clk, ms, sm);
    write_nn(LARGE_NB_XR1_ADDR, px, clk, ms, sm);
    write_nn(LARGE_NB_YR1_ADDR, py, clk, ms, sm);
    axi_write(W_R1_NULL, zero, clk, ms, sm);
    poll_ready(clk, ms, sm);
    ctrl := (others => '0');
    ctrl(CTRL_KP) := '1';
    axi_write(W_CTRL, ctrl, clk, ms, sm);
    poll_ready(clk, ms, sm);
    axi_read(R_STATUS, stat, clk, ms, sm);
    assert stat(31 downto 16) = x"0000"
      report test_name & ": error bits set 0x" &
             integer'image(to_integer(unsigned(stat(31 downto 16))))
      severity failure;
    assert stat(STATUS_R1_IS_NULL) = '0'
      report test_name & ": unexpected point-at-infinity" severity failure;
    read_nn(LARGE_NB_XR1_ADDR, rx, clk, ms, sm);
    read_nn(LARGE_NB_YR1_ADDR, ry, clk, ms, sm);
    rx := rx xor tok;
    ry := ry xor tok;
    assert rx = exp_x
      report test_name & ": X mismatch" severity failure;
    assert ry = exp_y
      report test_name & ": Y mismatch" severity failure;
    report test_name & ": PASSED";
  end procedure;

  -- Note: double.s reads input from R0 (not R1); result is written to R1.
  procedure run_ptdbl(
    constant px    : in  word32;
    constant py    : in  word32;
    variable res_x : inout word32;
    variable res_y : inout word32;
    signal   clk   : in  std_logic;
    signal   ms    : out axi_ms_type;
    signal   sm    : in  axi_sm_type) is
    variable ctrl  : word32;
    variable zero  : word32 := (others => '0');
    variable stat  : word32;
  begin
    write_nn(LARGE_NB_XR0_ADDR, px, clk, ms, sm);
    write_nn(LARGE_NB_YR0_ADDR, py, clk, ms, sm);
    axi_write(W_R0_NULL, zero, clk, ms, sm);
    poll_ready(clk, ms, sm);
    ctrl := (others => '0');
    ctrl(CTRL_PT_DBL) := '1';
    axi_write(W_CTRL, ctrl, clk, ms, sm);
    poll_ready(clk, ms, sm);
    axi_read(R_STATUS, stat, clk, ms, sm);
    assert stat(31 downto 16) = x"0000"
      report "ptdbl: error bits set" severity failure;
    read_nn(LARGE_NB_XR1_ADDR, res_x, clk, ms, sm);
    read_nn(LARGE_NB_YR1_ADDR, res_y, clk, ms, sm);
  end procedure;

  procedure run_ptadd(
    constant px    : in  word32;
    constant py    : in  word32;
    constant qx    : in  word32;
    constant qy    : in  word32;
    variable res_x : inout word32;
    variable res_y : inout word32;
    signal   clk   : in  std_logic;
    signal   ms    : out axi_ms_type;
    signal   sm    : in  axi_sm_type) is
    variable ctrl  : word32;
    variable zero  : word32 := (others => '0');
    variable stat  : word32;
  begin
    write_nn(LARGE_NB_XR0_ADDR, px, clk, ms, sm);
    write_nn(LARGE_NB_YR0_ADDR, py, clk, ms, sm);
    axi_write(W_R0_NULL, zero, clk, ms, sm);
    write_nn(LARGE_NB_XR1_ADDR, qx, clk, ms, sm);
    write_nn(LARGE_NB_YR1_ADDR, qy, clk, ms, sm);
    axi_write(W_R1_NULL, zero, clk, ms, sm);
    poll_ready(clk, ms, sm);
    ctrl := (others => '0');
    ctrl(CTRL_PT_ADD) := '1';
    axi_write(W_CTRL, ctrl, clk, ms, sm);
    poll_ready(clk, ms, sm);
    axi_read(R_STATUS, stat, clk, ms, sm);
    assert stat(31 downto 16) = x"0000"
      report "ptadd: error bits set" severity failure;
    read_nn(LARGE_NB_XR1_ADDR, res_x, clk, ms, sm);
    read_nn(LARGE_NB_YR1_ADDR, res_y, clk, ms, sm);
  end procedure;

  -- negative.s reads input from R0; result is in R1.
  procedure run_ptneg(
    constant px    : in  word32;
    constant py    : in  word32;
    variable res_x : inout word32;
    variable res_y : inout word32;
    signal   clk   : in  std_logic;
    signal   ms    : out axi_ms_type;
    signal   sm    : in  axi_sm_type) is
    variable ctrl  : word32;
    variable zero  : word32 := (others => '0');
    variable stat  : word32;
  begin
    write_nn(LARGE_NB_XR0_ADDR, px, clk, ms, sm);
    write_nn(LARGE_NB_YR0_ADDR, py, clk, ms, sm);
    axi_write(W_R0_NULL, zero, clk, ms, sm);
    poll_ready(clk, ms, sm);
    ctrl := (others => '0');
    ctrl(CTRL_PT_NEG) := '1';
    axi_write(W_CTRL, ctrl, clk, ms, sm);
    poll_ready(clk, ms, sm);
    axi_read(R_STATUS, stat, clk, ms, sm);
    assert stat(31 downto 16) = x"0000"
      report "ptneg: error bits set" severity failure;
    read_nn(LARGE_NB_XR1_ADDR, res_x, clk, ms, sm);
    read_nn(LARGE_NB_YR1_ADDR, res_y, clk, ms, sm);
  end procedure;

  -- is_on_curve.s reads input from R0.
  procedure check_on_curve(
    constant px        : in  word32;
    constant py        : in  word32;
    constant expected  : in  boolean;
    constant test_name : in  string;
    signal   clk       : in  std_logic;
    signal   ms        : out axi_ms_type;
    signal   sm        : in  axi_sm_type) is
    variable ctrl : word32;
    variable zero : word32 := (others => '0');
    variable stat : word32;
  begin
    write_nn(LARGE_NB_XR0_ADDR, px, clk, ms, sm);
    write_nn(LARGE_NB_YR0_ADDR, py, clk, ms, sm);
    axi_write(W_R0_NULL, zero, clk, ms, sm);
    poll_ready(clk, ms, sm);
    ctrl := (others => '0');
    ctrl(CTRL_PT_CHK) := '1';
    axi_write(W_CTRL, ctrl, clk, ms, sm);
    poll_ready(clk, ms, sm);
    axi_read(R_STATUS, stat, clk, ms, sm);
    if expected then
      assert stat(STATUS_YES) = '1'
        report test_name & ": expected YES (on curve) but got NO" severity failure;
    else
      assert stat(STATUS_YES) = '0'
        report test_name & ": expected NO (off curve) but got YES" severity failure;
    end if;
    report test_name & ": PASSED";
  end procedure;

begin

  -- -----------------------------------------------------------------------
  -- Unit under test
  -- -----------------------------------------------------------------------
  uut : entity work.ecc
    port map (
      s_axi_aclk    => clk,
      s_axi_aresetn => aresetn,
      s_axi_awaddr  => ms.awaddr,
      s_axi_awprot  => "000",
      s_axi_awvalid => ms.awvalid,
      s_axi_awready => sm.awready,
      s_axi_wdata   => ms.wdata,
      s_axi_wstrb   => ms.wstrb,
      s_axi_wvalid  => ms.wvalid,
      s_axi_wready  => sm.wready,
      s_axi_bresp   => sm.bresp,
      s_axi_bvalid  => sm.bvalid,
      s_axi_bready  => ms.bready,
      s_axi_araddr  => ms.araddr,
      s_axi_arprot  => "000",
      s_axi_arvalid => ms.arvalid,
      s_axi_arready => sm.arready,
      s_axi_rdata   => sm.rdata,
      s_axi_rresp   => sm.rresp,
      s_axi_rvalid  => sm.rvalid,
      s_axi_rready  => ms.rready,
      clkmm         => clk,
      irq           => irq,
      busy          => busy,
      dbgtrigger    => dbgtrigger,
      dbghalted     => dbghalted,
      dbgptdata     => (others => '0'),
      dbgptvalid    => '0',
      dbgptrdy      => dbgptrdy,
      clkdivo       => clkdivo,
      clkmmdivo     => clkmmdivo
    );

  clk <= not clk after CLK_PERIOD / 2;

  -- -----------------------------------------------------------------------
  -- Stimulus
  -- -----------------------------------------------------------------------
  stimulus : process is
    variable dbl_x, dbl_y  : word32;
    variable add_x, add_y  : word32;
    variable neg_x, neg_y  : word32;
    variable kpn_x, kpn_y  : word32;
    variable tok            : word32;
    variable ctrl           : word32;
    variable zero           : word32 := (others => '0');
    variable stat           : word32;
  begin
    -- Reset
    aresetn <= '0';
    wait for CLK_PERIOD * 10;
    aresetn <= '1';
    wait for CLK_PERIOD * 2;
    poll_ready(clk, ms, sm);

    -- Disable blinding so we do not need to wait for TRNG entropy
    disable_blinding(clk, ms, sm);

    -- Set prime size to 21 bits (nn_dynamic=TRUE required)
    assert nn_dynamic
      report "nn_dynamic must be TRUE in ecc_customize.vhd for this testbench"
      severity failure;
    set_nn_dyn(NN_TB, clk, ms, sm);

    -- Load curve parameters
    report "Loading 21-bit test curve...";
    load_curve(clk, ms, sm);
    poll_ready(clk, ms, sm);
    report "Curve loaded.";

    -- -------------------------------------------------------------------
    -- Test 1: [k]P with known vector
    -- k=0x1c0ac1, P=(0x00851a, 0x0a0e0f)
    -- expected result = (0x0acc93, 0x0e007f)
    -- -------------------------------------------------------------------
    check_kp(T1_K, T1_PX, T1_PY, T1_RX, T1_RY,
             "Test 1 [k]P", clk, ms, sm);

    -- -------------------------------------------------------------------
    -- Test 2: point addition
    -- P=(0x0e58a7,0x0b0eb7) + Q=(0x07136d,0x032a06) = (0x0c11ee,0x07c882)
    -- -------------------------------------------------------------------
    run_ptadd(T2_PX, T2_PY, T2_QX, T2_QY, add_x, add_y, clk, ms, sm);
    assert add_x = T2_RX
      report "Test 2 ptadd: X mismatch" severity failure;
    assert add_y = T2_RY
      report "Test 2 ptadd: Y mismatch" severity failure;
    report "Test 2 ptadd: PASSED";

    -- -------------------------------------------------------------------
    -- Test 3: point doubling  2·(0x0adc61, 0x14fae0) = (0x1462de, 0x0cfb3a)
    -- -------------------------------------------------------------------
    run_ptdbl(T3_PX, T3_PY, dbl_x, dbl_y, clk, ms, sm);
    assert dbl_x = T3_RX
      report "Test 3 ptdbl: X mismatch" severity failure;
    assert dbl_y = T3_RY
      report "Test 3 ptdbl: Y mismatch" severity failure;
    report "Test 3 ptdbl: PASSED";

    -- -------------------------------------------------------------------
    -- Test 4: ptadd(P,P) must equal ptdbl(P)  [consistency check]
    -- -------------------------------------------------------------------
    run_ptadd(T3_PX, T3_PY, T3_PX, T3_PY, add_x, add_y, clk, ms, sm);
    assert add_x = dbl_x
      report "Test 4 ptadd(P,P)=ptdbl(P): X mismatch" severity failure;
    assert add_y = dbl_y
      report "Test 4 ptadd(P,P)=ptdbl(P): Y mismatch" severity failure;
    report "Test 4 ptadd(P,P)=ptdbl(P): PASSED";

    -- -------------------------------------------------------------------
    -- Test 5: [2]P via kP must equal ptdbl(P)  [consistency check]
    -- -------------------------------------------------------------------
    check_kp(K_TWO, T3_PX, T3_PY, dbl_x, dbl_y,
             "Test 5 [2]P=ptdbl", clk, ms, sm);

    -- -------------------------------------------------------------------
    -- Test 6: point negation
    -- -(0x0a3f63, 0x16043d) = (0x0a3f63, 0x06e10e)
    -- -------------------------------------------------------------------
    run_ptneg(T4_PX, T4_PY, neg_x, neg_y, clk, ms, sm);
    assert neg_x = T4_RX
      report "Test 6 ptneg: X mismatch" severity failure;
    assert neg_y = T4_RY
      report "Test 6 ptneg: Y mismatch" severity failure;
    report "Test 6 ptneg: PASSED";

    -- -------------------------------------------------------------------
    -- Test 7: [q-1]·P = -P  [kP vs ptneg cross-check]
    -- k = q-1 = 0x1ce255, same input point as test 6
    -- -------------------------------------------------------------------
    get_token(tok, clk, ms, sm);
    write_k(K_QMIN1, clk, ms, sm);
    write_nn(LARGE_NB_XR1_ADDR, T4_PX, clk, ms, sm);
    write_nn(LARGE_NB_YR1_ADDR, T4_PY, clk, ms, sm);
    axi_write(W_R1_NULL, zero, clk, ms, sm);
    poll_ready(clk, ms, sm);
    ctrl := (others => '0');
    ctrl(CTRL_KP) := '1';
    axi_write(W_CTRL, ctrl, clk, ms, sm);
    poll_ready(clk, ms, sm);
    axi_read(R_STATUS, stat, clk, ms, sm);
    assert stat(31 downto 16) = x"0000"
      report "Test 7: error bits set" severity failure;
    read_nn(LARGE_NB_XR1_ADDR, kpn_x, clk, ms, sm);
    read_nn(LARGE_NB_YR1_ADDR, kpn_y, clk, ms, sm);
    kpn_x := kpn_x xor tok;
    kpn_y := kpn_y xor tok;
    assert kpn_x = neg_x
      report "Test 7 [q-1]P=-P: X mismatch" severity failure;
    assert kpn_y = neg_y
      report "Test 7 [q-1]P=-P: Y mismatch" severity failure;
    report "Test 7 [q-1]P=-P cross-check: PASSED";

    -- -------------------------------------------------------------------
    -- Test 8: on-curve check — this point is NOT on the curve
    -- -------------------------------------------------------------------
    check_on_curve(T5_PX, T5_PY, false,
                   "Test 8 off-curve", clk, ms, sm);

    -- -------------------------------------------------------------------
    -- Test 9: on-curve check — kP input point IS on the curve
    -- -------------------------------------------------------------------
    check_on_curve(T1_PX, T1_PY, true,
                   "Test 9 on-curve", clk, ms, sm);

    -- -------------------------------------------------------------------
    report "All 9 tests PASSED.";
    assert FALSE report "SIMULATION DONE" severity failure;
    wait;
  end process stimulus;

end architecture bench;
