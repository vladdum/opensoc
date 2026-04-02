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

CORES_ROOT_BASE := --cores-root=. \
                   --cores-root=hw/ip/ibex \
                   --cores-root=hw/ip/ibex/vendor/lowrisc_ip \
                   --cores-root=hw/ip/common_cells \
                   --cores-root=hw/ip/pulp_axi \
                   --cores-root=hw/ip/pio \
                   --cores-root=hw/ip/i2c_controller \
                   --cores-root=hw/ip/uart
CORES_ROOT_ACCELS := --cores-root=hw/ip/relu_accel \
                     --cores-root=hw/ip/vec_mac \
                     --cores-root=hw/ip/sg_dma \
                     --cores-root=hw/ip/softmax \
                     --cores-root=hw/ip/opentitan_aes

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

ifneq ($(TOP),opensoc_top_lean)
FUSESOC_FLAGS := \
  $(if $(filter 1,$(ENABLE_RELU)),--flag enable_relu,) \
  $(if $(filter 1,$(ENABLE_VMAC)),--flag enable_vmac,) \
  $(if $(filter 1,$(ENABLE_SGDMA)),--flag enable_sgdma,) \
  $(if $(filter 1,$(ENABLE_SOFTMAX)),--flag enable_softmax,) \
  $(if $(filter 1,$(ENABLE_CRYPTO)),--flag enable_crypto,)

FUSESOC_DEFINES := \
  --EnableReLU $(ENABLE_RELU) \
  --EnableVMAC $(ENABLE_VMAC) \
  --EnableSgDma $(ENABLE_SGDMA) \
  --EnableSoftmax $(ENABLE_SOFTMAX) \
  --EnableCrypto $(ENABLE_CRYPTO)
endif

SW_ARCH  := rv32imc_zicsr_zifencei
GTKW_DIR := dv/verilator

SIM_TRACE_FLAGS := $(if $(or $(TRACE),$(WAVES)),--trace,)

# ── Paths ─────────────────────────────────────────────────────────────────────

SW_DIR         := hw/ip/ibex/examples/sw/simple_system
SW_TEST_DIR    := sw/tests

SIM_DIR        := build/opensoc_soc_$(TOP)_0/sim-verilator

SYNTH_SRC_DIR_ARTY := build/opensoc_fpga_arty_a7_0/synth-vivado/src

# ── Per-test registry ─────────────────────────────────────────────────────────

SW_DIR_hello   := $(SW_DIR)/hello_test
SW_DIR_uart    := $(SW_TEST_DIR)/uart_test
SW_DIR_pio     := $(SW_TEST_DIR)/pio_test
SW_DIR_pio-sdk := $(SW_TEST_DIR)/pio_sdk_test
SW_DIR_pio-i2c := $(SW_TEST_DIR)/pio_i2c_test
SW_DIR_i2c     := $(SW_TEST_DIR)/i2c_test
SW_DIR_relu    := $(SW_TEST_DIR)/relu_test
SW_DIR_vmac    := $(SW_TEST_DIR)/vmac_test
SW_DIR_sg-dma      := $(SW_TEST_DIR)/sg_dma_test
SW_DIR_softmax     := $(SW_TEST_DIR)/softmax_test
SW_DIR_aes         := $(SW_TEST_DIR)/aes_test
SW_DIR_i2c-loopback := $(SW_TEST_DIR)/i2c_loopback_test

ELF_hello   := $(SW_DIR)/hello_test/hello_test.elf
ELF_uart    := $(SW_TEST_DIR)/uart_test/uart_test.elf
ELF_pio     := $(SW_TEST_DIR)/pio_test/pio_test.elf
ELF_pio-sdk := $(SW_TEST_DIR)/pio_sdk_test/pio_sdk_test.elf
ELF_pio-i2c := $(SW_TEST_DIR)/pio_i2c_test/pio_i2c_test.elf
ELF_i2c     := $(SW_TEST_DIR)/i2c_test/i2c_test.elf
ELF_relu    := $(SW_TEST_DIR)/relu_test/relu_test.elf
ELF_vmac    := $(SW_TEST_DIR)/vmac_test/vmac_test.elf
ELF_sg-dma      := $(SW_TEST_DIR)/sg_dma_test/sg_dma_test.elf
ELF_softmax     := $(SW_TEST_DIR)/softmax_test/softmax_test.elf
ELF_aes         := $(SW_TEST_DIR)/aes_test/aes_test.elf
ELF_i2c-loopback := $(SW_TEST_DIR)/i2c_loopback_test/i2c_loopback_test.elf

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
	@echo ""
	@echo "Regression"
	@echo "  regression                  Build sim + run all tests in parallel"
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
	@echo "  TOP=opensoc_top_lean        Build lean core (default, no IPs)"
	@echo "  TOP=opensoc_top             Build full core (use with ENABLE_* flags)"
	@echo "  ENABLE_RELU=1               Include ReLU accelerator"
	@echo "  ENABLE_VMAC=1               Include vector MAC accelerator"
	@echo "  ENABLE_SGDMA=1              Include scatter-gather DMA"
	@echo "  ENABLE_SOFTMAX=1            Include softmax accelerator"
	@echo "  ENABLE_CRYPTO=1             Include crypto cluster (OpenTitan AES)"
	@echo "  TRACE=1                     Enable FST waveform dump"
	@echo "  WAVES=1                     Enable waveform dump and open GTKWave"
	@echo "  CXX='ccache g++'            Use ccache (default if ccache installed)"

# ── Utilities ─────────────────────────────────────────────────────────────────

.PHONY: clean
clean:
	rm -rf build

# ── Regression ────────────────────────────────────────────────────────────────

# i2c-loopback excluded pending fix — see issue #14
REGRESSION_TESTS := hello uart pio pio-sdk pio-i2c i2c \
                    relu vmac sg-dma softmax aes

# Per-test extra simulator flags (empty unless overridden)
SIM_FLAGS_i2c-loopback := -c 500000

REGTEST_DIR := $(SIM_DIR)/regression

# Top-level regression: build sim if needed, build all SW in parallel, run all sims in parallel
.PHONY: regression
regression: $(SIM_DIR)/Vopensoc_top_wrapper
	$(MAKE) $(addprefix _reg-sw-,$(REGRESSION_TESTS))
	$(MAKE) -j -k $(addprefix _reg-run-,$(REGRESSION_TESTS)); true
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
	$(FUSESOC) $(CORES_ROOT) run --target=lint $(FUSESOC_FLAGS) opensoc:soc:opensoc_top $(FUSESOC_DEFINES)

# ── Simulator build ───────────────────────────────────────────────────────────

.PHONY: build
build:
	@test -n "$(BUILD_CORE_$(TOP))" || \
	  { echo "Unknown TOP='$(TOP)'. Valid: opensoc_top"; exit 1; }
	$(FUSESOC) $(CORES_ROOT) run --target=sim --setup --build $(FUSESOC_FLAGS) $(BUILD_CORE_$(TOP)) $(FUSESOC_DEFINES)

# ── Run targets ───────────────────────────────────────────────────────────────

# Generic pattern rule for standard opensoc_top tests
.PHONY: run-%
run-%:
	@test -n "$(ELF_$*)" || \
	  { echo "Unknown test '$*'. Run 'make help' for available tests."; exit 1; }
	$(MAKE) -C $(SW_DIR_$*) ARCH=$(SW_ARCH)
	cd $(SIM_DIR) && \
	  ./Vopensoc_top_wrapper --meminit=ram,$(CURDIR)/$(ELF_$*) $(SIM_TRACE_FLAGS)
	@echo "--- Program output ---"
	@cat $(SIM_DIR)/opensoc_top.log
	$(if $(WAVES),gtkwave $(SIM_DIR)/sim.fst $(wildcard $(GTKW_DIR)/opensoc_top.gtkw) &,)

# Explicit overrides for tests that need non-default run flags
.PHONY: run-i2c-loopback
run-i2c-loopback:
	$(MAKE) -C $(SW_TEST_DIR)/i2c_loopback_test ARCH=$(SW_ARCH)
	cd $(SIM_DIR) && \
	  ./Vopensoc_top_wrapper \
	    --meminit=ram,$(CURDIR)/$(SW_TEST_DIR)/i2c_loopback_test/i2c_loopback_test.elf \
	    -c 500000 \
	    $(SIM_TRACE_FLAGS)
	@echo "--- I2C Loopback output ---"
	@cat $(SIM_DIR)/opensoc_top.log
	$(if $(WAVES),gtkwave $(SIM_DIR)/sim.fst &,)

# ── Synthesis ─────────────────────────────────────────────────────────────────

.PHONY: synth synth-setup-arty
synth:
ifeq ($(FLOW),fpga-arty)
	$(MAKE) synth-setup-arty
	$(VIVADO) -mode batch -source hw/fpga/arty_a7/synth.tcl
else ifeq ($(FLOW),yosys)
	bash hw/asic/synth.sh
else ifeq ($(FLOW),ol2)
	$(MAKE) synth-setup-arty
	bash hw/asic/openlane2/run.sh
else
	$(error Unknown FLOW=$(FLOW). Use: fpga-arty, ol2, or yosys)
endif

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
	    $(FUSESOC) $(CORES_ROOT) run --target=synth --setup opensoc:fpga:arty_a7; \
	  fi; \
	  exec 9>&-; \
	fi
