# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

IPECC is a synthesizable VHDL hardware IP block that computes elliptic curve scalar multiplication $[k]P$ over short Weierstrass curves on finite fields of characteristic $p > 3$. It targets SRAM-based FPGAs (Xilinx Series7/UltraScale, Intel-Altera) and ASIC, exposes an AXI-lite interface, and includes several side-channel countermeasures. The software side is a C driver that hooks IPECC into the [libecc](https://github.com/libecc/libecc) library.

## Repository Layout

```
hdl/common/          Main synthesizable VHDL (technology-independent)
hdl/techno-specific/ Vendor-specific black-box components (DSP, TRNG, shift registers)
sim/                 GHDL simulation testbench + test vectors
driver/              C software driver (standalone / Linux devmem / UIO / socket emul)
sage/                SageMath scripts for test vector generation
syn/                 Xilinx synthesis constraints
doc/                 PDF documentation (ipecc.pdf)
```

## Key Customization File

**`hdl/common/ecc_customize.vhd`** is the single file users edit before synthesis or simulation. Critical parameters:

| Parameter | Meaning |
|-----------|---------|
| `nn` | Security parameter: bit-size of field prime (e.g. 256 for P-256) |
| `nn_dynamic` | Allow runtime-configurable prime size up to `nn` |
| `techno` | Target: `series7`, `ultrascale`, `ialtera`, `asic` |
| `nbmult` | Number of Montgomery multipliers (1 or 2) |
| `nbdsp` | DSP blocks per multiplier |
| `hwsecure` | `TRUE` = production-hardened; `FALSE` = full debug/SCA research mode |
| `blinding` | Size of scalar blinding random (0 = disabled) |
| `shuffle` | Enable memory shuffling countermeasure |
| `notrng` | Must be `FALSE` for synthesis; simulation overrides this via `pragma translate_off/on` |
| `simvecfile` | Input vector file path for simulation (default `/tmp/ecc_vec_in.txt`) |
| `simtrngfile` | TRNG entropy source file for simulation (default `/tmp/random.txt`) |

## RTL Architecture (hdl/common/)

The design is hierarchical; top-level is `ecc.vhd`:

- **`ecc_axi.vhd`** — AXI-lite register bank; software interface; issues commands to scalar controller
- **`ecc_scalar.vhd`** — Scalar multiplication control (double-and-add-always, Co-Z arithmetic)
- **`ecc_curve.vhd`** — Microcode execution engine; fetches/decodes instructions from `ecc_curve_iram`
- **`ecc_curve_iram/`** — Microcode ROM; assembled from custom assembly sources (`.s` files) by Python assembler
- **`ecc_fp.vhd`** — Field arithmetic processor; dispatches field operations to Montgomery multiplier
- **`ecc_fp_dram.vhd`** / **`ecc_fp_dram_sh_*.vhd`** — Data RAM holding intermediate point coordinates; shuffle variants implement address randomization
- **`mm_ndsp.vhd`** — Montgomery multiplier; instantiates vendor DSP black-boxes (`macc_*.vhd`, `maccx_*.vhd`)
- **`ecc_trng/`** — ES-TRNG from KU-Leuven; used in synthesis; replaced by file-based PRNG in simulation
- **`ecc_pkg.vhd`**, **`ecc_customize.vhd`**, **`ecc_utils.vhd`** — Shared packages and helper functions
- **`virt_to_phys_ram.vhd`** / **`virt_to_phys_ram_async.vhd`** — Address translation for shuffle feature

Technology-specific files (DSP wrappers, TRNG oscillator rings, shift registers) live under `hdl/techno-specific/<vendor>/`.

## Building the Microcode

The microcode ROM (`ecc_curve_iram.vhd`) is assembled from hand-written assembly in `hdl/common/ecc_curve_iram/asm_src/`. This step also generates C headers consumed by the driver.

```bash
cd hdl/common/ecc_curve_iram
make          # assemble → ecc_curve_iram.vhd, ecc_addr.h, ecc_vars.h, ecc_states.h, ecc_platform.h
make disass   # disassemble for inspection
make clean
```

The assembler is `ipecc_assembler.py` (Python 3) and reads `ecc_customize.vhd` and `ecc_pkg.vhd` to resolve constants.

## Running Simulation (GHDL)

Prerequisite: generate a random entropy file for the simulated TRNG before first run:

```bash
od -t u1 -w1 -v /dev/urandom | awk '{print $2}' | head -$((128*1024*1024)) > /tmp/random.txt
```

Then copy/symlink the test vector input file:

```bash
cp sim/ecc_vec_in.txt /tmp/ecc_vec_in.txt
```

Build and elaborate (uses ASIC techno-specific files; TRNG is replaced by a stub):

```bash
cd sim
make          # compile + elaborate
ghdl-llvm -r ecc_tb --ieee-asserts=disable    # run simulation
```

The sim Makefile uses `ghdl-llvm` with `--std=93c -fsynopsys`. Compilation order matters; all dependencies are encoded in the Makefile.

## Building the C Driver

The driver targets ARM (Zynq by default). `VHD_DIR` must point to the absolute path of `hdl/common/ecc_curve_iram` so that the generated `.h` headers are found.

```bash
cd driver
make                  # builds ecc-test-linux-uio, ecc-test-linux-devmem, ecc-test-stdalone
make emulator         # builds test_emul (socket emulation, runs on host PC)
make clean
```

Override the cross-compiler via `ARM_CC=<compiler>`. Platform modes are selected at compile time via `-DWITH_EC_HW_STANDALONE`, `-DWITH_EC_HW_DEVMEM`, `-DWITH_EC_HW_UIO`, or `-DWITH_EC_HW_SOCKET_EMUL`.

### Socket emulation (no hardware required)

Start the Python emulator server:

```bash
python3 driver/emulator_server/hw_driver_socket_emul_server.py
# Listens on 127.0.0.1:8080
```

Then run `./test_emul` to exercise the driver API against the software emulator.

## Driver API

The public API is in `driver/hw_accelerator_driver.h`. Key operations:
- Set curve parameters (prime, a, b, order q, base point)
- Point operations: scalar multiplication, addition, doubling, negation, comparison, on-curve check

Platform abstraction is in `hw_accelerator_driver_ipecc_platform.{c,h}`. Linux test application entry points are in `driver/linux/ecc-test-linux.c`.

## SageMath Scripts

`sage/generate-tests.sage` generates test vectors. Run with SageMath:

```bash
cd sage
sage generate-tests.sage
```

`sage/kp.sage` / `kp.py` implement the scalar multiplication reference in SageMath for cross-checking.
