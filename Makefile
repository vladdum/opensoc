# Copyright OpenSoC contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

FUSESOC        := fusesoc
export CXX     ?= ccache g++
TRACE  ?=
WAVES  ?=
FLOW   ?= fpga-arty
VIVADO ?= vivado
TOP    ?= opensoc_top_lean
JOBS   ?= $(shell nproc)
CPU    ?= ibex

CORES_ROOT_BASE := --cores-root=. \
                   --cores-root=hw/ip/ibex \
                   --cores-root=hw/ip/ibex/vendor/lowrisc_ip \
                   --cores-root=hw/ip/common_cells \
                   --cores-root=hw/ip/pulp_axi \
                   --cores-root=hw/ip/pio \
                   --cores-root=hw/ip/i2c_controller \
                   --cores-root=hw/ip/uart \
                   --cores-root=hw/ip/ram

ifeq ($(CPU),kronos)
CORES_ROOT_BASE += --cores-root=hw/ip/kronos_riscv
LINT_TARGET     := lint-kronos
SIM_TARGET      := sim-kronos
SYNTH_TARGET    := synth-kronos
KRONOS_DEFINES  := --USE_KRONOS 1
else
LINT_TARGET     := lint
SIM_TARGET      := sim
SYNTH_TARGET    := synth
KRONOS_DEFINES  :=
endif
CORES_ROOT_ACCELS := --cores-root=hw/ip/relu_accel \
                     --cores-root=hw/ip/vec_mac \
                     --cores-root=hw/ip/sg_dma \
                     --cores-root=hw/ip/softmax \
                     --cores-root=hw/ip/opentitan_aes \
                     --cores-root=hw/ip/conv1d \
                     --cores-root=hw/ip/conv2d \
                     --cores-root=hw/ip/gemm

ifeq ($(TOP),opensoc_top_lean)
CORES_ROOT := $(CORES_ROOT_BASE)
else
CORES_ROOT := $(CORES_ROOT_BASE) $(CORES_ROOT_ACCELS)
endif

# ── IP enable flags (sim/lint only; FPGA/ASIC use config_pkg defaults) ────────
ENABLE_RELU    ?= 0
ENABLE_VMAC    ?= 0
ENABLE_SGDMA   ?= 0
ENABLE_SOFTMAX ?= 0
ENABLE_CRYPTO  ?= 0
ENABLE_CONV1D  ?= 0
ENABLE_CONV2D  ?= 0
ENABLE_GEMM    ?= 0

ifneq ($(TOP),opensoc_top_lean)
FUSESOC_FLAGS := \
  $(if $(filter 1,$(ENABLE_RELU)),--flag enable_relu,) \
  $(if $(filter 1,$(ENABLE_VMAC)),--flag enable_vmac,) \
  $(if $(filter 1,$(ENABLE_SGDMA)),--flag enable_sgdma,) \
  $(if $(filter 1,$(ENABLE_SOFTMAX)),--flag enable_softmax,) \
  $(if $(filter 1,$(ENABLE_CRYPTO)),--flag enable_crypto,) \
  $(if $(filter 1,$(ENABLE_CONV1D)),--flag enable_conv1d,) \
  $(if $(filter 1,$(ENABLE_CONV2D)),--flag enable_conv2d,) \
  $(if $(filter 1,$(ENABLE_GEMM)),--flag enable_gemm,)

FUSESOC_DEFINES := \
  --EnableReLU $(ENABLE_RELU) \
  --EnableVMAC $(ENABLE_VMAC) \
  --EnableSgDma $(ENABLE_SGDMA) \
  --EnableSoftmax $(ENABLE_SOFTMAX) \
  --EnableCrypto $(ENABLE_CRYPTO) \
  --EnableConv1d $(ENABLE_CONV1D) \
  --EnableConv2d $(ENABLE_CONV2D) \
  --EnableGemm $(ENABLE_GEMM)
endif

SW_ARCH  := rv32imc_zicsr_zifencei
GTKW_DIR := dv/verilator

SIM_TRACE_FLAGS := $(if $(or $(TRACE),$(WAVES)),--trace,)

# ── Paths ─────────────────────────────────────────────────────────────────────

SW_DIR         := hw/ip/ibex/examples/sw/simple_system

SIM_DIR        := build/opensoc_soc_$(TOP)_0/sim-verilator

# run-* targets always use the full simulator (built by build-full)
RUN_SIM_DIR    := build/opensoc_soc_opensoc_top_0/sim-verilator

SYNTH_SRC_DIR_ARTY := build/opensoc_fpga_arty_a7_0/synth-vivado/src
SYNTH_SRC_DIR_ASIC := build/opensoc_soc_opensoc_top_0/synth-verilator/src

# ── Per-test registry (sw/tests/tests.mk) ────────────────────────────────────
# Single source of truth for all SW test metadata (SW_TEST_DIR, SW_BUILD_DIR,
# SW_DIR_*, ELF_*, SIM_FLAGS_*, REGRESSION_TESTS, RUN_TESTS). Edit that file
# to add or remove tests.

include sw/tests/tests.mk

# ── Simulator top registry ────────────────────────────────────────────────────

BUILD_CORE_opensoc_top      := opensoc:soc:opensoc_top
BUILD_CORE_opensoc_top_lean := opensoc:soc:opensoc_top_lean

# ── Help ──────────────────────────────────────────────────────────────────────

.PHONY: help
help:
	@echo "Usage: make <target> [OPTIONS]"
	@echo ""
	@echo "Lint"
	@echo "  lint                        Run Verilator lint (lean by default)"
	@echo ""
	@echo "Simulator build"
	@echo "  build                       Build lean simulator (no IPs, fast)"
	@echo "  build TOP=opensoc_top       Build full simulator with enabled IPs"
	@echo "  build-full                  Build full simulator (all IPs)"
	@echo ""
	@echo "Regression"
	@echo "  regression                  Run tests for currently enabled IPs"
	@echo "  regression-full             Build full sim + run all tests (CI)"
	@echo ""
	@echo "Run (builds SW then runs simulation)"
	@echo "  run-hello        Print hex values and test timer interrupts"
	@echo "  run-uart         Send 'Hello UART' over the UART peripheral"
	@echo "  run-pio          GPIO, FIFO, clock divider, MOV and JMP via PIO"
	@echo "  run-pio-sdk      PIO SDK compat: sidesets, program management, EXEC"
	@echo "  run-pio-i2c      PIO-based I2C: program load, byte send, ACK readback"
	@echo "  run-i2c          Hardware I2C controller: START/addr/data/STOP sequence"
	@echo "  run-relu         ReLU accelerator: large array DMA and output verify"
	@echo "  run-vmac         Vector MAC: 12 tests incl. saturation and multi-kick"
	@echo "  run-sg-dma       SG-DMA: chaining, zero-length descriptors, throughput"
	@echo "  run-softmax      Softmax: uniform, one-hot, accuracy vs. C reference"
	@echo "  run-aes          AES-128 ECB encrypt/decrypt with NIST test vector"
	@echo "  run-conv1d       1D convolution: FIR filter and same-padding mode verify"
	@echo "  run-conv1d-relu-stream  Conv1D→ReLU stream pipeline: end-to-end and throughput"
	@echo "  run-conv2d       2D convolution: 3x3 kernel on 8x8, 16x16, 32x32 images"
	@echo "  run-gemm         GEMM systolic array: 4x4, 8x8 matmul, identity, saturation"
	@echo "  run-i2c-loopback I2C master + PIO slave: write, read, clock stretching"
	@echo ""
	@echo "Synthesis"
	@echo "  synth                       Synthesize (default FLOW=fpga-arty)"
	@echo "  synth FLOW=fpga-arty        Vivado / Arty A7-100T XC7A100T"
	@echo "  synth FLOW=yosys            sv2v + Yosys generic gates"
	@echo "  synth FLOW=ol2              OpenLane 2 / Sky130"
	@echo ""
	@echo "Other"
	@echo "  clean                       Remove build directory"
	@echo ""
	@echo "Options"
	@echo "  CPU=ibex                    Use Ibex CPU (default)"
	@echo "  CPU=kronos                  Use Kronos single-cycle CPU (Stage 0)"
	@echo "  TOP=opensoc_top_lean        Build lean core (default, no IPs)"
	@echo "  TOP=opensoc_top             Build full core (use with ENABLE_* flags)"
	@echo "  ENABLE_RELU=1               Include ReLU accelerator"
	@echo "  ENABLE_VMAC=1               Include vector MAC accelerator"
	@echo "  ENABLE_SGDMA=1              Include scatter-gather DMA"
	@echo "  ENABLE_SOFTMAX=1            Include softmax accelerator"
	@echo "  ENABLE_CRYPTO=1             Include crypto cluster (OpenTitan AES)"
	@echo "  ENABLE_CONV1D=1             Include 1D convolution engine"
	@echo "  ENABLE_CONV2D=1             Include 2D convolution engine"
	@echo "  ENABLE_GEMM=1               Include GEMM systolic array accelerator"
	@echo "  TRACE=1                     Enable FST waveform dump"
	@echo "  WAVES=1                     Enable waveform dump and open GTKWave"
	@echo "  CXX='ccache g++'            Use ccache (default if ccache installed)"

# ── Utilities ─────────────────────────────────────────────────────────────────

.PHONY: clean
clean:
	rm -rf build

# ── Regression ────────────────────────────────────────────────────────────────
# REGRESSION_TESTS, REGRESSION_FULL_TESTS, and RUN_TESTS are defined in
# sw/tests/tests.mk (included above).

FULL_FLAGS := TOP=opensoc_top \
              ENABLE_RELU=1 ENABLE_VMAC=1 ENABLE_SGDMA=1 ENABLE_SOFTMAX=1 ENABLE_CRYPTO=1 \
              ENABLE_CONV1D=1 ENABLE_CONV2D=1 ENABLE_GEMM=1

REGTEST_DIR := $(SIM_DIR)/regression

# Top-level regression: build sim if needed, build all SW in parallel, run all sims in parallel
.PHONY: regression
regression: $(SIM_DIR)/Vopensoc_top_wrapper
	$(MAKE) -j$(JOBS) $(addprefix _reg-sw-,$(REGRESSION_TESTS))
	$(MAKE) -j$(JOBS) -k $(addprefix _reg-run-,$(REGRESSION_TESTS)); true
	@echo ""
	@echo "=== Regression Summary ==="
	@pass=0; fail=0; \
	for t in $(REGRESSION_TESTS); do \
	  if [ -f "$(REGTEST_DIR)/$$t/.passed" ]; then \
	    echo "  PASS: $$t"; pass=$$((pass+1)); \
	  else \
	    echo "  FAIL: $$t"; fail=$$((fail+1)); \
	  fi; \
	done; \
	echo ""; echo "  $$pass passed, $$fail failed"; \
	[ $$fail -eq 0 ]

# Full build + regression (all IPs) — used by CI
.PHONY: build-full
build-full:
	$(MAKE) build $(FULL_FLAGS)

.PHONY: regression-full
regression-full:
	$(MAKE) regression $(FULL_FLAGS)

.PHONY: FORCE

_reg-sw-%: FORCE
	$(MAKE) -C $(SW_DIR_$*) ARCH=$(SW_ARCH)

_reg-run-%: FORCE
	@mkdir -p $(REGTEST_DIR)/$*
	cd $(REGTEST_DIR)/$* && \
	  $(CURDIR)/$(SIM_DIR)/Vopensoc_top_wrapper \
	    --meminit=ram,$(CURDIR)/$(ELF_$*) \
	    $(SIM_FLAGS_$*) && \
	  touch .passed
	@echo "=== $* ==="
	@cat $(REGTEST_DIR)/$*/opensoc_top.log

.PHONY: lint
lint:
	$(FUSESOC) $(CORES_ROOT_BASE) $(CORES_ROOT_ACCELS) run --target=$(LINT_TARGET) \
	    --flag enable_relu --flag enable_vmac --flag enable_sgdma --flag enable_softmax \
	    --flag enable_crypto --flag enable_conv1d --flag enable_conv2d --flag enable_gemm \
	    opensoc:soc:opensoc_top \
	    --EnableReLU 1 --EnableVMAC 1 --EnableSgDma 1 --EnableSoftmax 1 \
	    --EnableCrypto 1 --EnableConv1d 1 --EnableConv2d 1 --EnableGemm 1 \
	    $(KRONOS_DEFINES)

# ── Simulator build ───────────────────────────────────────────────────────────

.PHONY: build
build:
	@test -n "$(BUILD_CORE_$(TOP))" || \
	  { echo "Unknown TOP='$(TOP)'. Valid: opensoc_top"; exit 1; }
	@_build_start=$$(date +%s); \
	( while true; do \
	    sleep 60; \
	    _now=$$(date +%s); \
	    echo "[build] $$(( (_now - _build_start) / 60 ))m elapsed..."; \
	  done ) & \
	_timer_pid=$$!; \
	MAKEFLAGS="-j$(JOBS)" $(FUSESOC) $(CORES_ROOT) run --target=$(SIM_TARGET) --setup --build $(FUSESOC_FLAGS) $(BUILD_CORE_$(TOP)) $(FUSESOC_DEFINES) $(KRONOS_DEFINES); \
	kill $$_timer_pid 2>/dev/null; wait $$_timer_pid 2>/dev/null; \
	_build_end=$$(date +%s); \
	_elapsed=$$(( _build_end - _build_start )); \
	echo "Build completed in $$(( _elapsed / 60 ))m $$(( _elapsed % 60 ))s"

# ── Run targets ───────────────────────────────────────────────────────────────

# Standard run targets — static pattern rule so each target is explicit
# (visible to bash completion) while sharing a single recipe.
# RUN_TESTS is defined in sw/tests/tests.mk.

.PHONY: $(addprefix run-,$(RUN_TESTS))
$(addprefix run-,$(RUN_TESTS)): run-%:
	$(MAKE) -C $(SW_DIR_$*) ARCH=$(SW_ARCH)
	cd $(RUN_SIM_DIR) && \
	  ./Vopensoc_top_wrapper --meminit=ram,$(CURDIR)/$(ELF_$*) $(SIM_FLAGS_$*) $(SIM_TRACE_FLAGS)
	@echo "--- Program output ---"
	@cat $(RUN_SIM_DIR)/opensoc_top.log
	$(if $(WAVES),gtkwave $(RUN_SIM_DIR)/sim.fst $(wildcard $(GTKW_DIR)/opensoc_top.gtkw) &,)

# ── Synthesis ─────────────────────────────────────────────────────────────────

.PHONY: synth synth-setup-arty synth-setup-asic
synth:
ifeq ($(FLOW),fpga-arty)
	$(MAKE) synth-setup-arty
	time $(VIVADO) -mode batch -source hw/fpga/arty_a7/synth.tcl
else ifeq ($(FLOW),yosys)
	$(MAKE) synth-setup-asic
	time bash hw/asic/synth.sh
else ifeq ($(FLOW),ol2)
	$(MAKE) synth-setup-asic
	time bash hw/asic/openlane2/run.sh
else
	$(error Unknown FLOW=$(FLOW). Use: fpga-arty, ol2, or yosys)
endif

synth-setup-asic:
	@if [ -d "$(SYNTH_SRC_DIR_ASIC)" ]; then \
	  echo "synth-setup-asic: $(SYNTH_SRC_DIR_ASIC) exists, skipping (use 'make clean' to force)"; \
	else \
	  LOCK=build/.synth-setup-asic.lock; \
	  mkdir -p build; \
	  exec 9>"$$LOCK"; \
	  flock 9; \
	  if [ -d "$(SYNTH_SRC_DIR_ASIC)" ]; then \
	    echo "synth-setup-asic: completed by another process, skipping"; \
	  else \
	    $(FUSESOC) $(CORES_ROOT_BASE) $(CORES_ROOT_ACCELS) run --target=$(SYNTH_TARGET) --setup \
	      --flag enable_relu --flag enable_vmac --flag enable_sgdma --flag enable_softmax \
	      --flag enable_conv1d --flag enable_conv2d --flag enable_gemm \
	      opensoc:soc:opensoc_top \
	      --EnableReLU 1 --EnableVMAC 1 --EnableSgDma 1 --EnableSoftmax 1 \
	      --EnableConv1d 1 --EnableConv2d 1 --EnableGemm 1 $(KRONOS_DEFINES); \
	  fi; \
	  exec 9>&-; \
	fi

synth-setup-arty:
	@if [ -d "$(SYNTH_SRC_DIR_ARTY)" ]; then \
	  echo "synth-setup-arty: $(SYNTH_SRC_DIR_ARTY) exists, skipping (use 'make clean' to force)"; \
	else \
	  LOCK=build/.synth-setup-arty.lock; \
	  mkdir -p build; \
	  exec 9>"$$LOCK"; \
	  flock 9; \
	  if [ -d "$(SYNTH_SRC_DIR_ARTY)" ]; then \
	    echo "synth-setup-arty: completed by another process, skipping"; \
	  else \
	    $(FUSESOC) $(CORES_ROOT_BASE) $(CORES_ROOT_ACCELS) run --target=synth --setup opensoc:fpga:arty_a7 \
	      --flag enable_relu --flag enable_vmac --flag enable_sgdma --flag enable_softmax \
	      --flag enable_conv1d --flag enable_conv2d --flag enable_gemm \
	      --EnableReLU 1 --EnableVMAC 1 --EnableSgDma 1 --EnableSoftmax 1 \
	      --EnableConv1d 1 --EnableConv2d 1 --EnableGemm 1; \
	  fi; \
	  exec 9>&-; \
	fi
