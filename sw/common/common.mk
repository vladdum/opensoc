# Copyright OpenSoC contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Drop-in replacement for ibex's simple_system common.mk.
# Compiles ibex's common sources locally so there are no shared pre-built
# objects that can silently carry stale addresses.
# All artifacts are written to build/sw/<test_name>/ so that `make clean`
# (which removes build/) wipes SW outputs too.
#
# Usage in a test Makefile:
#   PROGRAM      = my_test
#   PROGRAM_DIR := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))
#   INCS        += -I$(PROGRAM_DIR)/../../include   # test-specific headers
#   include $(PROGRAM_DIR)/../../common/common.mk

SW_COMMON_MK  := $(lastword $(MAKEFILE_LIST))
SW_COMMON_DIR := $(dir $(SW_COMMON_MK))
REPO_ROOT     := $(abspath $(SW_COMMON_DIR)../..)
IBEX_COMMON   := $(REPO_ROOT)/hw/ip/ibex/examples/sw/simple_system/common

BUILD_DIR := $(REPO_ROOT)/build/sw/$(notdir $(CURDIR))

CC      := riscv32-unknown-elf-gcc
OBJCOPY := riscv32-unknown-elf-objcopy

ARCH ?= rv32imc_zicsr_zifencei

CFLAGS := -march=$(ARCH) -mabi=ilp32 -static -mcmodel=medany -Wall -g -Os \
           -fvisibility=hidden -nostdlib -nostartfiles -ffreestanding \
           -include $(SW_COMMON_DIR)simple_system_regs.h \
           $(PROGRAM_CFLAGS)

# ibex common provides simple_system_common.h/.c.
# The -include flag above forces sw/common/simple_system_regs.h first so that
# the quoted #include "simple_system_regs.h" inside simple_system_common.h is
# suppressed by header guards — preventing ibex's old addresses from winning.
INCS := -I$(SW_COMMON_DIR) -I$(IBEX_COMMON) $(INCS)

OBJS := $(BUILD_DIR)/simple_system_common.o \
        $(BUILD_DIR)/crt0.o \
        $(BUILD_DIR)/$(PROGRAM).o

all: $(BUILD_DIR)/$(PROGRAM).elf $(BUILD_DIR)/$(PROGRAM).vmem

$(BUILD_DIR)/$(PROGRAM).elf: $(OBJS) $(SW_COMMON_DIR)link.ld
	@mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) -T $(SW_COMMON_DIR)link.ld $(OBJS) -o $@

$(BUILD_DIR)/simple_system_common.o: $(IBEX_COMMON)/simple_system_common.c $(SW_COMMON_DIR)simple_system_regs.h
	@mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) -c $(INCS) -o $@ $<

$(BUILD_DIR)/crt0.o: $(SW_COMMON_DIR)crt0.S $(SW_COMMON_DIR)simple_system_regs.h $(SW_COMMON_DIR)link.ld
	@mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) -c $(INCS) -o $@ $<

$(BUILD_DIR)/$(PROGRAM).o: $(PROGRAM).c
	@mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) -c $(INCS) -o $@ $<

%.o: %.c
	@mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) -c $(INCS) -o $@ $<

%.o: %.S
	@mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) -c $(INCS) -o $@ $<

$(BUILD_DIR)/$(PROGRAM).bin: $(BUILD_DIR)/$(PROGRAM).elf
	$(OBJCOPY) -O binary $< $@

$(BUILD_DIR)/$(PROGRAM).vmem: $(BUILD_DIR)/$(PROGRAM).bin
	srec_cat $< -binary -offset 0x0000 -byte-swap 4 -o $@ -vmem

clean:
	rm -rf $(BUILD_DIR)
	rm -f *.d
