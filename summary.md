# Session Summary

## What Was Done

### 1. CLAUDE.md — Codebase Documentation
Created `/home/mark/Projects/IPECC/CLAUDE.md` with:
- Project overview (hardware ECC IP, AXI-lite interface, side-channel countermeasures)
- Key customization parameters in `ecc_customize.vhd`
- RTL architecture hierarchy
- Build workflows for microcode, simulation, and C driver

### 2. New Testbench: `tb/tb_ecc.vhd` + `tb/Makefile`

A standalone, self-checking AXI-level testbench for the `ecc` top-level entity. No dependency on the existing `sim/` package.

**Configuration choices:**
- nn = 21 (set dynamically at runtime via `W_PRIME_SIZE`) — keeps simulation fast (seconds vs. minutes for P-256)
- Blinding disabled at runtime (`W_BLINDING = 0`) — avoids waiting for TRNG entropy
- ASIC techno-specific components (same as existing `sim/Makefile`)
- hwsecure = TRUE, shuffle = FALSE (in `ecc_customize.vhd` as left after debugging)

**Test cases (all passing):**
| # | Operation | Description |
|---|-----------|-------------|
| 1 | `[k]P` | Known scalar multiply with token unmask |
| 2 | `ptadd` | P+Q with known expected result |
| 3 | `ptdbl` | 2P with known expected result |
| 4 | `ptadd(P,P) = ptdbl(P)` | Consistency cross-check |
| 5 | `[2]P via kP` | kP(k=2) matches ptdbl result |
| 6 | `ptneg` | -P with known expected result |
| 7 | `[q-1]P = ptneg(P)` | kP cross-check vs negation |
| 8 | Off-curve check | Point not on curve → NO |
| 9 | On-curve check | Valid point → YES |

**To run:**
```bash
cd tb && make run
```

---

## Key Findings / Protocol Bugs Discovered

Reading `double.s`, `negative.s`, and the C driver (`hw_accelerator_driver_ipecc.c`) revealed the correct register protocol for each point operation — which differs from what the existing sim testbench implied:

| Operation | Input register | Result register |
|-----------|---------------|----------------|
| `kP` | R1 (XR1, YR1) | R1 |
| `ptadd` | P→R0, Q→R1 | R1 |
| `ptdbl` | **R0** | R1 |
| `ptneg` | **R0** | R1 |
| `on-curve` | **R0** | STATUS_YES bit |

The existing `sim/ecc_tb_pkg.vhd` writes `ptdbl`/`ptneg` input to R1, which silently produces wrong results (the microcode `double.s` reads from XR0 and uses whatever R0 happens to contain from a previous operation).

## Tools

- `ghdl` (GCC backend, v5.0.1) — `ghdl-llvm` is **not** installed
- `python3` 3.13.7
- `make` 4.4.1

## Files Modified / Created

| File | Change |
|------|--------|
| `CLAUDE.md` | Created — codebase guide |
| `tb/Makefile` | Created — build/run testbench |
| `tb/tb_ecc.vhd` | Created — standalone testbench |
| `hdl/common/ecc_customize.vhd` | `shuffle` set to `FALSE` (left from debugging; safe to restore to `TRUE`) |
| `prompts.md` | Running log of user prompts |
