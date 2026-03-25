# Copyright OpenSoC contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

FUSESOC = fusesoc
CORES_ROOT = --cores-root=. --cores-root=hw/ip/ibex --cores-root=hw/ip/ibex/vendor/lowrisc_ip \
             --cores-root=hw/ip/common_cells --cores-root=hw/ip/pulp_axi \
             --cores-root=hw/ip/relu_accel \
             --cores-root=hw/ip/vec_mac \
             --cores-root=hw/ip/sg_dma \
             --cores-root=hw/ip/softmax \
             --cores-root=hw/ip/pio

.PHONY: help
help:
	@echo "OpenSoC build targets:"
	@echo "  make lint            - Run Verilator lint"
	@echo "  make sim             - Build Verilator simulator"
	@echo "  make sw-hello        - Build hello_test SW binary"
	@echo "  make run-hello       - Build and run hello_test on simulator"
	@echo "  make sw-uart         - Build uart_test SW binary"
	@echo "  make run-uart        - Build and run uart_test on simulator"
	@echo "  make sw-pio          - Build pio_test SW binary"
	@echo "  make run-pio         - Build and run pio_test on simulator"
	@echo "  make sw-pio-sdk      - Build pio_sdk_test SW binary"
	@echo "  make run-pio-sdk     - Build and run pio_sdk_test on simulator"
	@echo "  make sw-pio-i2c      - Build pio_i2c_test SW binary"
	@echo "  make run-pio-i2c     - Build and run pio_i2c_test on simulator"
	@echo "  make sw-i2c          - Build i2c_test SW binary"
	@echo "  make run-i2c         - Build and run i2c_test on simulator"
	@echo "  make sw-relu         - Build relu_test SW binary"
	@echo "  make run-relu        - Build and run relu_test on simulator"
	@echo "  make sw-vmac         - Build vmac_test SW binary"
	@echo "  make run-vmac        - Build and run vmac_test on simulator"
	@echo "  make sw-sg-dma       - Build sg_dma_test SW binary"
	@echo "  make run-sg-dma      - Build and run sg_dma_test on simulator"
	@echo "  make sw-softmax      - Build softmax_test SW binary"
	@echo "  make run-softmax     - Build and run softmax_test on simulator"
	@echo "  make sim-dual-uart   - Build dual-UART Verilator simulator"
	@echo "  make sw-uart-send    - Build uart_send SW binary"
	@echo "  make sw-uart-recv    - Build uart_recv SW binary"
	@echo "  make run-dual-uart   - Build and run dual-UART test"
	@echo "  make sim-i2c-loopback - Build I2C loopback Verilator simulator"
	@echo "  make sw-i2c-loopback  - Build I2C loopback test SW binary"
	@echo "  make run-i2c-loopback - Build and run I2C loopback test"
	@echo "  make synth           - Synthesize for Basys 3 FPGA (Vivado)"
	@echo "  make clean           - Remove build directory"
	@echo ""
	@echo "Options:"
	@echo "  TRACE=1              - Enable FST waveform dump (e.g. make run-hello TRACE=1)"
	@echo "  WAVES=1              - Enable trace + open GTKWave after sim (e.g. make run-dual-uart WAVES=1)"

.PHONY: clean
clean:
	rm -rf build

.PHONY: lint
lint:
	$(FUSESOC) $(CORES_ROOT) run --target=lint opensoc:soc:opensoc_top

.PHONY: sim
sim:
	$(FUSESOC) $(CORES_ROOT) run --target=sim --setup --build opensoc:soc:opensoc_top

SW_DIR = hw/ip/ibex/examples/sw/simple_system
SW_ARCH = rv32imc_zicsr_zifencei
SIM_BIN = build/opensoc_soc_opensoc_top_0/sim-verilator/Vopensoc_top
SIM_DIR = build/opensoc_soc_opensoc_top_0/sim-verilator

# Pass TRACE=1 to enable FST waveform dump (e.g. make run-hello TRACE=1)
# Pass WAVES=1 to also open GTKWave after simulation (implies TRACE=1)
SIM_TRACE_FLAGS = $(if $(or $(TRACE),$(WAVES)),--trace,)
GTKW_DIR = dv/verilator

.PHONY: sw-hello
sw-hello:
	$(MAKE) -C $(SW_DIR)/hello_test ARCH=$(SW_ARCH)

.PHONY: run-hello
run-hello: sw-hello
	cd $(SIM_DIR) && \
	  ./Vopensoc_top --meminit=ram,$(CURDIR)/$(SW_DIR)/hello_test/hello_test.elf $(SIM_TRACE_FLAGS)
	@echo "--- Program output ---"
	@cat $(SIM_DIR)/opensoc_top.log
	$(if $(WAVES),gtkwave $(SIM_DIR)/sim.fst $(wildcard $(GTKW_DIR)/opensoc_top.gtkw) &,)

SW_TEST_DIR = sw/tests

.PHONY: sw-uart
sw-uart:
	$(MAKE) -C $(SW_TEST_DIR)/uart_test ARCH=$(SW_ARCH)

.PHONY: run-uart
run-uart: sw-uart
	cd $(SIM_DIR) && \
	  ./Vopensoc_top --meminit=ram,$(CURDIR)/$(SW_TEST_DIR)/uart_test/uart_test.elf $(SIM_TRACE_FLAGS)
	@echo "--- Program output ---"
	@cat $(SIM_DIR)/opensoc_top.log
	$(if $(WAVES),gtkwave $(SIM_DIR)/sim.fst $(wildcard $(GTKW_DIR)/opensoc_top.gtkw) &,)

.PHONY: sw-pio
sw-pio:
	$(MAKE) -C $(SW_TEST_DIR)/pio_test ARCH=$(SW_ARCH)

.PHONY: run-pio
run-pio: sw-pio
	cd $(SIM_DIR) && \
	  ./Vopensoc_top --meminit=ram,$(CURDIR)/$(SW_TEST_DIR)/pio_test/pio_test.elf $(SIM_TRACE_FLAGS)
	@echo "--- Program output ---"
	@cat $(SIM_DIR)/opensoc_top.log
	$(if $(WAVES),gtkwave $(SIM_DIR)/sim.fst $(wildcard $(GTKW_DIR)/opensoc_top.gtkw) &,)

.PHONY: sw-pio-sdk
sw-pio-sdk:
	$(MAKE) -C $(SW_TEST_DIR)/pio_sdk_test ARCH=$(SW_ARCH)

.PHONY: run-pio-sdk
run-pio-sdk: sw-pio-sdk
	cd $(SIM_DIR) && \
	  ./Vopensoc_top --meminit=ram,$(CURDIR)/$(SW_TEST_DIR)/pio_sdk_test/pio_sdk_test.elf $(SIM_TRACE_FLAGS)
	@echo "--- Program output ---"
	@cat $(SIM_DIR)/opensoc_top.log
	$(if $(WAVES),gtkwave $(SIM_DIR)/sim.fst $(wildcard $(GTKW_DIR)/opensoc_top.gtkw) &,)

.PHONY: sw-pio-i2c
sw-pio-i2c:
	$(MAKE) -C $(SW_TEST_DIR)/pio_i2c_test ARCH=$(SW_ARCH)

.PHONY: run-pio-i2c
run-pio-i2c: sw-pio-i2c
	cd $(SIM_DIR) && \
	  ./Vopensoc_top --meminit=ram,$(CURDIR)/$(SW_TEST_DIR)/pio_i2c_test/pio_i2c_test.elf $(SIM_TRACE_FLAGS)
	@echo "--- Program output ---"
	@cat $(SIM_DIR)/opensoc_top.log
	$(if $(WAVES),gtkwave $(SIM_DIR)/sim.fst $(wildcard $(GTKW_DIR)/opensoc_top.gtkw) &,)

.PHONY: sw-i2c
sw-i2c:
	$(MAKE) -C $(SW_TEST_DIR)/i2c_test ARCH=$(SW_ARCH)

.PHONY: run-i2c
run-i2c: sw-i2c
	cd $(SIM_DIR) && \
	  ./Vopensoc_top --meminit=ram,$(CURDIR)/$(SW_TEST_DIR)/i2c_test/i2c_test.elf $(SIM_TRACE_FLAGS)
	@echo "--- Program output ---"
	@cat $(SIM_DIR)/opensoc_top.log
	$(if $(WAVES),gtkwave $(SIM_DIR)/sim.fst $(wildcard $(GTKW_DIR)/opensoc_top.gtkw) &,)

.PHONY: sw-relu
sw-relu:
	$(MAKE) -C $(SW_TEST_DIR)/relu_test ARCH=$(SW_ARCH)

.PHONY: run-relu
run-relu: sw-relu
	cd $(SIM_DIR) && \
	  ./Vopensoc_top --meminit=ram,$(CURDIR)/$(SW_TEST_DIR)/relu_test/relu_test.elf $(SIM_TRACE_FLAGS)
	@echo "--- Program output ---"
	@cat $(SIM_DIR)/opensoc_top.log
	$(if $(WAVES),gtkwave $(SIM_DIR)/sim.fst $(wildcard $(GTKW_DIR)/opensoc_top.gtkw) &,)

.PHONY: sw-vmac
sw-vmac:
	$(MAKE) -C $(SW_TEST_DIR)/vmac_test ARCH=$(SW_ARCH)

.PHONY: run-vmac
run-vmac: sw-vmac
	cd $(SIM_DIR) && \
	  ./Vopensoc_top --meminit=ram,$(CURDIR)/$(SW_TEST_DIR)/vmac_test/vmac_test.elf $(SIM_TRACE_FLAGS)
	@echo "--- Program output ---"
	@cat $(SIM_DIR)/opensoc_top.log
	$(if $(WAVES),gtkwave $(SIM_DIR)/sim.fst $(wildcard $(GTKW_DIR)/opensoc_top.gtkw) &,)

.PHONY: sw-sg-dma
sw-sg-dma:
	$(MAKE) -C $(SW_TEST_DIR)/sg_dma_test ARCH=$(SW_ARCH)

.PHONY: run-sg-dma
run-sg-dma: sw-sg-dma
	cd $(SIM_DIR) && \
	  ./Vopensoc_top --meminit=ram,$(CURDIR)/$(SW_TEST_DIR)/sg_dma_test/sg_dma_test.elf $(SIM_TRACE_FLAGS)
	@echo "--- Program output ---"
	@cat $(SIM_DIR)/opensoc_top.log
	$(if $(WAVES),gtkwave $(SIM_DIR)/sim.fst $(wildcard $(GTKW_DIR)/opensoc_top.gtkw) &,)

.PHONY: sw-softmax
sw-softmax:
	$(MAKE) -C $(SW_TEST_DIR)/softmax_test ARCH=$(SW_ARCH)

.PHONY: run-softmax
run-softmax: sw-softmax
	cd $(SIM_DIR) && \
	  ./Vopensoc_top --meminit=ram,$(CURDIR)/$(SW_TEST_DIR)/softmax_test/softmax_test.elf $(SIM_TRACE_FLAGS)
	@echo "--- Program output ---"
	@cat $(SIM_DIR)/opensoc_top.log
	$(if $(WAVES),gtkwave $(SIM_DIR)/sim.fst $(wildcard $(GTKW_DIR)/opensoc_top.gtkw) &,)

# Dual-UART targets
DUAL_SIM_BIN = build/opensoc_soc_opensoc_dual_uart_0/sim-verilator/Vopensoc_dual_uart
DUAL_SIM_DIR = build/opensoc_soc_opensoc_dual_uart_0/sim-verilator

.PHONY: sim-dual-uart
sim-dual-uart:
	$(FUSESOC) $(CORES_ROOT) run --target=sim --setup --build opensoc:soc:opensoc_dual_uart

.PHONY: sw-uart-send
sw-uart-send:
	$(MAKE) -C $(SW_TEST_DIR)/uart_send ARCH=$(SW_ARCH)

.PHONY: sw-uart-recv
sw-uart-recv:
	$(MAKE) -C $(SW_TEST_DIR)/uart_recv ARCH=$(SW_ARCH)

.PHONY: run-dual-uart
run-dual-uart: sw-uart-send sw-uart-recv
	cd $(DUAL_SIM_DIR) && \
	  ./Vopensoc_dual_uart \
	    --meminit=ram0,$(CURDIR)/$(SW_TEST_DIR)/uart_send/uart_send.elf \
	    --meminit=ram1,$(CURDIR)/$(SW_TEST_DIR)/uart_recv/uart_recv.elf \
	    $(SIM_TRACE_FLAGS)
	@echo "--- SoC0 output ---"
	@cat $(DUAL_SIM_DIR)/opensoc_top.log
	$(if $(WAVES),gtkwave $(DUAL_SIM_DIR)/sim.fst $(wildcard $(GTKW_DIR)/opensoc_dual_uart.gtkw) &,)

# I2C loopback targets
I2C_LB_SIM_BIN = build/opensoc_soc_opensoc_i2c_loopback_0/sim-verilator/Vopensoc_i2c_loopback
I2C_LB_SIM_DIR = build/opensoc_soc_opensoc_i2c_loopback_0/sim-verilator

.PHONY: sim-i2c-loopback
sim-i2c-loopback:
	$(FUSESOC) $(CORES_ROOT) run --target=sim --setup --build opensoc:soc:opensoc_i2c_loopback

.PHONY: sw-i2c-loopback
sw-i2c-loopback:
	$(MAKE) -C $(SW_TEST_DIR)/i2c_loopback_test ARCH=$(SW_ARCH)

.PHONY: run-i2c-loopback
run-i2c-loopback: sw-i2c-loopback
	cd $(I2C_LB_SIM_DIR) && \
	  ./Vopensoc_i2c_loopback \
	    --meminit=ram,$(CURDIR)/$(SW_TEST_DIR)/i2c_loopback_test/i2c_loopback_test.elf \
	    -c 500000 \
	    $(SIM_TRACE_FLAGS)
	@echo "--- I2C Loopback output ---"
	@cat $(I2C_LB_SIM_DIR)/opensoc_top.log
	$(if $(WAVES),gtkwave $(I2C_LB_SIM_DIR)/sim.fst &,)

# FPGA synthesis (Basys 3)
.PHONY: synth synth-setup
synth:
	$(FUSESOC) $(CORES_ROOT) run --target=synth opensoc:fpga:basys3

synth-setup:
	$(FUSESOC) $(CORES_ROOT) run --target=synth --setup opensoc:fpga:basys3
