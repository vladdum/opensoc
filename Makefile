# Copyright OpenSoC contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

FUSESOC    := fusesoc
CORES_ROOT := --cores-root=. \
              --cores-root=hw/ip/ibex \
              --cores-root=hw/ip/ibex/vendor/lowrisc_ip \
              --cores-root=hw/ip/common_cells \
              --cores-root=hw/ip/pulp_axi \
              --cores-root=hw/ip/relu_accel \
              --cores-root=hw/ip/vec_mac \
              --cores-root=hw/ip/sg_dma \
              --cores-root=hw/ip/softmax \
              --cores-root=hw/ip/pio

TRACE  ?=
WAVES  ?=
FLOW   ?= fpga-arty
VIVADO ?= vivado
TOP    ?= opensoc_top

SW_ARCH  := rv32imc_zicsr_zifencei
GTKW_DIR := dv/verilator

SIM_TRACE_FLAGS := $(if $(or $(TRACE),$(WAVES)),--trace,)

# ── Paths ─────────────────────────────────────────────────────────────────────

SW_DIR         := hw/ip/ibex/examples/sw/simple_system
SW_TEST_DIR    := sw/tests

SIM_DIR        := build/opensoc_soc_opensoc_top_0/sim-verilator
DUAL_SIM_DIR   := build/opensoc_soc_opensoc_dual_uart_0/sim-verilator
I2C_LB_SIM_DIR := build/opensoc_soc_opensoc_i2c_loopback_0/sim-verilator

SYNTH_SRC_DIR      := build/opensoc_fpga_basys3_0/synth-vivado/src
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
SW_DIR_sg-dma  := $(SW_TEST_DIR)/sg_dma_test
SW_DIR_softmax := $(SW_TEST_DIR)/softmax_test

ELF_hello   := $(SW_DIR)/hello_test/hello_test.elf
ELF_uart    := $(SW_TEST_DIR)/uart_test/uart_test.elf
ELF_pio     := $(SW_TEST_DIR)/pio_test/pio_test.elf
ELF_pio-sdk := $(SW_TEST_DIR)/pio_sdk_test/pio_sdk_test.elf
ELF_pio-i2c := $(SW_TEST_DIR)/pio_i2c_test/pio_i2c_test.elf
ELF_i2c     := $(SW_TEST_DIR)/i2c_test/i2c_test.elf
ELF_relu    := $(SW_TEST_DIR)/relu_test/relu_test.elf
ELF_vmac    := $(SW_TEST_DIR)/vmac_test/vmac_test.elf
ELF_sg-dma  := $(SW_TEST_DIR)/sg_dma_test/sg_dma_test.elf
ELF_softmax := $(SW_TEST_DIR)/softmax_test/softmax_test.elf

# ── Simulator top registry ────────────────────────────────────────────────────

BUILD_CORE_opensoc_top  := opensoc:soc:opensoc_top
BUILD_CORE_dual_uart    := opensoc:soc:opensoc_dual_uart
BUILD_CORE_i2c_loopback := opensoc:soc:opensoc_i2c_loopback

# ── Help ──────────────────────────────────────────────────────────────────────

.PHONY: help
help:
	@echo "Usage: make <target> [OPTIONS]"
	@echo ""
	@echo "Lint"
	@echo "  lint                        Run Verilator lint"
	@echo ""
	@echo "Simulator build"
	@echo "  build                       Build simulator (default TOP=opensoc_top)"
	@echo "  build TOP=dual_uart         Build dual-UART simulator"
	@echo "  build TOP=i2c_loopback      Build I2C loopback simulator"
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
	@echo "  run-dual-uart    Two-SoC UART handshake and 8-round data exchange"
	@echo "  run-i2c-loopback I2C master + PIO slave: write, read, clock stretching"
	@echo ""
	@echo "Synthesis"
	@echo "  synth                       Synthesize (default FLOW=fpga-arty)"
	@echo "  synth FLOW=fpga-arty        Vivado / Arty A7-100T XC7A100T"
	@echo "  synth FLOW=fpga-basys3      Vivado / Basys 3 XC7A35T"
	@echo "  synth FLOW=yosys            sv2v + Yosys generic gates"
	@echo "  synth FLOW=ol2              OpenLane 2 / Sky130"
	@echo ""
	@echo "Other"
	@echo "  clean                       Remove build directory"
	@echo ""
	@echo "Options"
	@echo "  TRACE=1                     Enable FST waveform dump"
	@echo "  WAVES=1                     Enable waveform dump and open GTKWave"

# ── Utilities ─────────────────────────────────────────────────────────────────

.PHONY: clean
clean:
	rm -rf build

.PHONY: lint
lint:
	$(FUSESOC) $(CORES_ROOT) run --target=lint opensoc:soc:opensoc_top

# ── Simulator build ───────────────────────────────────────────────────────────

.PHONY: build
build:
	@test -n "$(BUILD_CORE_$(TOP))" || \
	  { echo "Unknown TOP='$(TOP)'. Valid: opensoc_top, dual_uart, i2c_loopback"; exit 1; }
	$(FUSESOC) $(CORES_ROOT) run --target=sim --setup --build $(BUILD_CORE_$(TOP))

# ── Run targets ───────────────────────────────────────────────────────────────

# Generic pattern rule for standard opensoc_top tests
.PHONY: run-%
run-%:
	@test -n "$(ELF_$*)" || \
	  { echo "Unknown test '$*'. Run 'make help' for available tests."; exit 1; }
	$(MAKE) -C $(SW_DIR_$*) ARCH=$(SW_ARCH)
	cd $(SIM_DIR) && \
	  ./Vopensoc_top --meminit=ram,$(CURDIR)/$(ELF_$*) $(SIM_TRACE_FLAGS)
	@echo "--- Program output ---"
	@cat $(SIM_DIR)/opensoc_top.log
	$(if $(WAVES),gtkwave $(SIM_DIR)/sim.fst $(wildcard $(GTKW_DIR)/opensoc_top.gtkw) &,)

# Explicit overrides for multi-ELF / alternate-top tests
.PHONY: run-dual-uart
run-dual-uart:
	$(MAKE) -C $(SW_TEST_DIR)/uart_send ARCH=$(SW_ARCH)
	$(MAKE) -C $(SW_TEST_DIR)/uart_recv ARCH=$(SW_ARCH)
	cd $(DUAL_SIM_DIR) && \
	  ./Vopensoc_dual_uart \
	    --meminit=ram0,$(CURDIR)/$(SW_TEST_DIR)/uart_send/uart_send.elf \
	    --meminit=ram1,$(CURDIR)/$(SW_TEST_DIR)/uart_recv/uart_recv.elf \
	    $(SIM_TRACE_FLAGS)
	@echo "--- SoC0 output ---"
	@cat $(DUAL_SIM_DIR)/opensoc_top.log
	$(if $(WAVES),gtkwave $(DUAL_SIM_DIR)/sim.fst $(wildcard $(GTKW_DIR)/opensoc_dual_uart.gtkw) &,)

.PHONY: run-i2c-loopback
run-i2c-loopback:
	$(MAKE) -C $(SW_TEST_DIR)/i2c_loopback_test ARCH=$(SW_ARCH)
	cd $(I2C_LB_SIM_DIR) && \
	  ./Vopensoc_i2c_loopback \
	    --meminit=ram,$(CURDIR)/$(SW_TEST_DIR)/i2c_loopback_test/i2c_loopback_test.elf \
	    -c 500000 \
	    $(SIM_TRACE_FLAGS)
	@echo "--- I2C Loopback output ---"
	@cat $(I2C_LB_SIM_DIR)/opensoc_top.log
	$(if $(WAVES),gtkwave $(I2C_LB_SIM_DIR)/sim.fst &,)

# ── Synthesis ─────────────────────────────────────────────────────────────────

.PHONY: synth synth-setup synth-setup-arty
synth:
ifeq ($(FLOW),fpga-arty)
	$(MAKE) synth-setup-arty
	$(VIVADO) -mode batch -source hw/fpga/arty_a7/synth.tcl
else ifeq ($(FLOW),fpga-basys3)
	$(MAKE) synth-setup
	$(VIVADO) -mode batch -source hw/fpga/basys3/synth.tcl
else ifeq ($(FLOW),yosys)
	bash hw/asic/synth.sh
else ifeq ($(FLOW),ol2)
	$(MAKE) synth-setup
	bash hw/asic/openlane2/run.sh
else
	$(error Unknown FLOW=$(FLOW). Use: fpga-arty, fpga-basys3, ol2, or yosys)
endif

synth-setup:
	@if [ -d "$(SYNTH_SRC_DIR)" ]; then \
	  echo "synth-setup: $(SYNTH_SRC_DIR) exists, skipping (use 'make clean' to force)"; \
	else \
	  LOCK=build/.synth-setup.lock; \
	  mkdir -p build; \
	  exec 9>"$$LOCK"; \
	  flock 9; \
	  if [ -d "$(SYNTH_SRC_DIR)" ]; then \
	    echo "synth-setup: completed by another process, skipping"; \
	  else \
	    $(FUSESOC) $(CORES_ROOT) run --target=synth --setup opensoc:fpga:basys3; \
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
	    $(FUSESOC) $(CORES_ROOT) run --target=synth --setup opensoc:fpga:arty_a7; \
	  fi; \
	  exec 9>&-; \
	fi
