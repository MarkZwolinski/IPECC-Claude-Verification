##############################################
# IPECC standalone AXI testbench
##############################################

GHDL     := ghdl-llvm
GHDLFLAGS := --std=93c -fsynopsys --warn-no-hide --workdir=work

IRAM_DIR := ../hdl/common/ecc_curve_iram
HDL      := ../hdl/common
TECH     := ../hdl/techno-specific/asic

.PHONY: all microcode trng_file workdir compile elaborate run clean

all: elaborate

# -----------------------------------------------------------------
# Step 0: build microcode (generates ecc_vars.vhd, ecc_addr.vhd,
#         ecc_curve_iram.vhd, and C headers)
# -----------------------------------------------------------------
microcode:
	$(MAKE) -C $(IRAM_DIR)

# -----------------------------------------------------------------
# Step 1: create TRNG entropy file if absent (~2 MB is enough for
#         short simulations; ecc_customize.vhd simtrngfile=/tmp/random.txt)
# -----------------------------------------------------------------
trng_file:
	@if [ ! -f /tmp/random.txt ]; then \
		echo "[tb] Generating /tmp/random.txt ..."; \
		od -t u1 -w1 -v /dev/urandom | awk '{print $$2}' | head -2097152 > /tmp/random.txt; \
		echo "[tb] Done."; \
	fi

workdir:
	@if [ ! -d work ]; then mkdir work; fi

# -----------------------------------------------------------------
# Compilation — same order as sim/Makefile
# -----------------------------------------------------------------
compile: microcode workdir \
	work/ecc_customize.o \
	work/ecc_log.o \
	work/ecc_utils.o \
	work/ecc_vars.o \
	work/ecc_pkg.o \
	work/ecc_addr.o \
	work/ecc_software.o \
	work/ecc_shuffle_pkg.o \
	work/ecc_trng_pkg.o \
	work/mm_ndsp_pkg.o \
	work/syncram_sdp.o \
	work/sync2ram_sdp.o \
	work/fifo.o \
	work/large_shr_asic.o \
	work/macc_asic.o \
	work/maccx_asic.o \
	work/virt_to_phys_ram.o \
	work/virt_to_phys_ram_async.o \
	work/ecc_fp_dram.o \
	work/ecc_fp_dram_sh_linear.o \
	work/ecc_fp_dram_sh_fishy.o \
	work/ecc_fp_dram_sh_fishy_nb.o \
	work/ecc_fp.o \
	work/ecc_axi.o \
	work/ecc_curve_iram.o \
	work/ecc_curve.o \
	work/ecc_scalar.o \
	work/es_trng_sim.o \
	work/ecc_trng_pp.o \
	work/ecc_trng_srv.o \
	work/ecc_trng.o \
	work/ecc.o \
	work/tb_ecc.o

elaborate: compile
	@echo "[GHDL] -e tb_ecc"
	@$(GHDL) -e $(GHDLFLAGS) tb_ecc

run: elaborate trng_file
	@echo "[GHDL] -r tb_ecc"
	$(GHDL) -r $(GHDLFLAGS) tb_ecc --ieee-asserts=disable 2>&1 | \
	  tee /tmp/tb_ecc_run.log; \
	  grep -q "SIMULATION DONE" /tmp/tb_ecc_run.log && echo "[tb] PASS" || \
	  (echo "[tb] FAIL — see /tmp/tb_ecc_run.log"; exit 1)

clean:
	rm -rf work e~tb_ecc.o tb_ecc

# -----------------------------------------------------------------
# VHD → object rules
# -----------------------------------------------------------------
work/%.o :: $(HDL)/%.vhd
	@echo "[GHDL] $<"
	@$(GHDL) -a $(GHDLFLAGS) $<

work/%.o :: $(HDL)/ecc_trng/%.vhd
	@echo "[GHDL] $<"
	@$(GHDL) -a $(GHDLFLAGS) $<

work/%.o :: $(HDL)/ecc_curve_iram/%.vhd
	@echo "[GHDL] $<"
	@$(GHDL) -a $(GHDLFLAGS) $<

work/%.o :: $(TECH)/%.vhd
	@echo "[GHDL] $<"
	@$(GHDL) -a $(GHDLFLAGS) $<

work/%.o :: %.vhd
	@echo "[GHDL] $<"
	@$(GHDL) -a $(GHDLFLAGS) $<

# -----------------------------------------------------------------
# Inter-object dependency declarations (mirrors sim/Makefile)
# -----------------------------------------------------------------
work/ecc_utils.o: work/ecc_customize.o
work/ecc_pkg.o: work/ecc_customize.o work/ecc_utils.o work/ecc_vars.o work/ecc_log.o
work/ecc_addr.o: work/ecc_pkg.o
work/ecc_shuffle_pkg.o: work/ecc_customize.o work/ecc_pkg.o
work/mm_ndsp_pkg.o: work/ecc_customize.o work/ecc_utils.o work/ecc_pkg.o work/ecc_log.o
work/ecc_software.o: work/ecc_customize.o work/ecc_utils.o work/ecc_log.o work/ecc_pkg.o work/ecc_trng_pkg.o
work/ecc_axi.o: work/ecc_customize.o work/ecc_utils.o work/ecc_log.o work/ecc_pkg.o work/ecc_vars.o work/ecc_software.o work/mm_ndsp_pkg.o work/ecc_trng_pkg.o
work/ecc_curve.o: work/ecc_customize.o work/ecc_utils.o work/ecc_pkg.o
work/ecc_curve_iram.o: work/ecc_customize.o work/ecc_utils.o work/ecc_pkg.o
work/ecc_fp.o: work/ecc_customize.o work/ecc_utils.o work/ecc_log.o work/ecc_pkg.o work/ecc_vars.o work/ecc_shuffle_pkg.o work/ecc_addr.o work/large_shr_asic.o
work/ecc_fp_dram.o: work/ecc_customize.o work/ecc_utils.o work/ecc_pkg.o work/ecc_vars.o
work/ecc_fp_dram_sh_fishy.o: work/ecc_pkg.o work/ecc_utils.o work/ecc_log.o work/ecc_customize.o work/ecc_trng_pkg.o work/ecc_shuffle_pkg.o work/ecc_fp_dram.o work/virt_to_phys_ram.o
work/ecc_fp_dram_sh_fishy_nb.o: work/ecc_pkg.o work/ecc_utils.o work/ecc_customize.o work/ecc_trng_pkg.o work/ecc_shuffle_pkg.o work/ecc_log.o work/ecc_fp_dram.o work/virt_to_phys_ram_async.o
work/ecc_fp_dram_sh_linear.o: work/ecc_customize.o work/ecc_trng_pkg.o work/ecc_utils.o work/ecc_pkg.o work/ecc_fp_dram.o
work/ecc_scalar.o: work/ecc_customize.o work/ecc_utils.o work/ecc_log.o work/ecc_pkg.o work/ecc_addr.o
work/ecc_trng_pkg.o: work/ecc_utils.o work/ecc_customize.o work/ecc_pkg.o
work/ecc_trng.o: work/ecc_customize.o work/ecc_log.o work/ecc_utils.o work/ecc_pkg.o work/ecc_trng_pkg.o work/es_trng_sim.o work/ecc_trng_pp.o work/ecc_trng_srv.o
work/ecc_trng_pp.o: work/ecc_customize.o work/ecc_log.o work/ecc_utils.o work/ecc_pkg.o work/ecc_trng_pkg.o
work/ecc_trng_srv.o: work/ecc_pkg.o work/ecc_log.o work/ecc_customize.o work/ecc_utils.o work/ecc_trng_pkg.o work/fifo.o
work/es_trng_sim.o: work/ecc_pkg.o work/ecc_log.o work/ecc_customize.o work/ecc_trng_pkg.o
work/fifo.o: work/ecc_log.o work/syncram_sdp.o
work/mm_ndsp.o: work/ecc_customize.o work/ecc_utils.o work/ecc_log.o work/ecc_pkg.o work/mm_ndsp_pkg.o work/maccx_asic.o work/sync2ram_sdp.o work/syncram_sdp.o
work/sync2ram_sdp.o: work/ecc_log.o work/ecc_pkg.o work/ecc_customize.o
work/syncram_sdp.o: work/ecc_log.o
work/virt_to_phys_ram.o: work/ecc_pkg.o work/ecc_utils.o work/ecc_log.o work/ecc_customize.o work/ecc_shuffle_pkg.o
work/virt_to_phys_ram_async.o: work/ecc_log.o work/ecc_pkg.o work/ecc_customize.o work/ecc_shuffle_pkg.o
work/large_shr_asic.o: work/ecc_pkg.o
work/macc_asic.o: work/ecc_log.o work/ecc_pkg.o work/mm_ndsp_pkg.o
work/maccx_asic.o: work/ecc_log.o work/ecc_pkg.o work/mm_ndsp_pkg.o work/macc_asic.o
work/ecc.o: work/ecc_customize.o work/ecc_utils.o work/ecc_log.o work/ecc_pkg.o work/mm_ndsp_pkg.o work/ecc_trng_pkg.o work/ecc_shuffle_pkg.o work/ecc_axi.o work/ecc_scalar.o work/ecc_curve.o work/ecc_curve_iram.o work/ecc_fp.o work/ecc_trng.o work/ecc_fp_dram.o work/ecc_fp_dram_sh_linear.o work/ecc_fp_dram_sh_fishy_nb.o work/ecc_fp_dram_sh_fishy.o work/mm_ndsp.o
work/tb_ecc.o: work/ecc_customize.o work/ecc_utils.o work/ecc_pkg.o work/ecc_vars.o work/ecc_software.o work/ecc.o
