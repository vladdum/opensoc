# Copyright OpenSoC contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

FUSESOC = fusesoc
CORES_ROOT = --cores-root=. --cores-root=hw/ip/ibex --cores-root=hw/ip/ibex/vendor/lowrisc_ip \
             --cores-root=hw/ip/common_cells --cores-root=hw/ip/pulp_axi

.PHONY: help
help:
	@echo "OpenSoC build targets:"
	@echo "  make lint            - Run Verilator lint"
	@echo "  make sim             - Build Verilator simulator"
	@echo "  make sw-hello        - Build hello_test SW binary"
	@echo "  make run-hello       - Build and run hello_test on simulator"
	@echo "  make sw-uart         - Build uart_test SW binary"
	@echo "  make run-uart        - Build and run uart_test on simulator"
	@echo "  make sw-gpio         - Build gpio_test SW binary"
	@echo "  make run-gpio        - Build and run gpio_test on simulator"
	@echo "  make sw-i2c          - Build i2c_test SW binary"
	@echo "  make run-i2c         - Build and run i2c_test on simulator"
	@echo "  make sim-dual-uart   - Build dual-UART Verilator simulator"
	@echo "  make sw-uart-send    - Build uart_send SW binary"
	@echo "  make sw-uart-recv    - Build uart_recv SW binary"
	@echo "  make run-dual-uart   - Build and run dual-UART test"
	@echo "  make clean           - Remove build directory"

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

.PHONY: sw-hello
sw-hello:
	$(MAKE) -C $(SW_DIR)/hello_test ARCH=$(SW_ARCH)

.PHONY: run-hello
run-hello: sw-hello
	cd build/opensoc_soc_opensoc_top_0/sim-verilator && \
	  ./Vopensoc_top --meminit=ram,$(CURDIR)/$(SW_DIR)/hello_test/hello_test.elf
	@echo "--- Program output ---"
	@cat build/opensoc_soc_opensoc_top_0/sim-verilator/opensoc_top.log

SW_TEST_DIR = sw/tests

.PHONY: sw-uart
sw-uart:
	$(MAKE) -C $(SW_TEST_DIR)/uart_test ARCH=$(SW_ARCH)

.PHONY: run-uart
run-uart: sw-uart
	cd build/opensoc_soc_opensoc_top_0/sim-verilator && \
	  ./Vopensoc_top --meminit=ram,$(CURDIR)/$(SW_TEST_DIR)/uart_test/uart_test.elf
	@echo "--- Program output ---"
	@cat build/opensoc_soc_opensoc_top_0/sim-verilator/opensoc_top.log

.PHONY: sw-gpio
sw-gpio:
	$(MAKE) -C $(SW_TEST_DIR)/gpio_test ARCH=$(SW_ARCH)

.PHONY: run-gpio
run-gpio: sw-gpio
	cd build/opensoc_soc_opensoc_top_0/sim-verilator && \
	  ./Vopensoc_top --meminit=ram,$(CURDIR)/$(SW_TEST_DIR)/gpio_test/gpio_test.elf
	@echo "--- Program output ---"
	@cat build/opensoc_soc_opensoc_top_0/sim-verilator/opensoc_top.log

.PHONY: sw-i2c
sw-i2c:
	$(MAKE) -C $(SW_TEST_DIR)/i2c_test ARCH=$(SW_ARCH)

.PHONY: run-i2c
run-i2c: sw-i2c
	cd build/opensoc_soc_opensoc_top_0/sim-verilator && \
	  ./Vopensoc_top --meminit=ram,$(CURDIR)/$(SW_TEST_DIR)/i2c_test/i2c_test.elf
	@echo "--- Program output ---"
	@cat build/opensoc_soc_opensoc_top_0/sim-verilator/opensoc_top.log

# Dual-UART targets
DUAL_SIM_BIN = build/opensoc_soc_opensoc_dual_uart_0/sim-verilator/Vopensoc_dual_uart

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
	cd build/opensoc_soc_opensoc_dual_uart_0/sim-verilator && \
	  ./Vopensoc_dual_uart \
	    --meminit=ram0,$(CURDIR)/$(SW_TEST_DIR)/uart_send/uart_send.elf \
	    --meminit=ram1,$(CURDIR)/$(SW_TEST_DIR)/uart_recv/uart_recv.elf
	@echo "--- SoC0 output ---"
	@cat build/opensoc_soc_opensoc_dual_uart_0/sim-verilator/opensoc_top.log
