# Makefile for standalone module-level testbenches (Verilator)
#
# Usage:
#   make tb-axi-lite-to-tlul        # build & run
#   make tb-axi-lite-to-tlul-build  # build only
#   make all                        # build & run all testbenches
#   make clean                      # remove build artifacts

REPO_ROOT := $(realpath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
RTL_DIR   := $(REPO_ROOT)/hw/rtl
TB_DIR    := $(REPO_ROOT)/dv/sv
BUILD_DIR := $(REPO_ROOT)/build/sim

VERILATOR       := verilator
VERILATOR_FLAGS := --binary --timing -Wall

TB_NAMES :=

# -----------------------------------------------------------------------
# Testbench template
# -----------------------------------------------------------------------
# $(1) = target name (e.g. axi-lite-to-tlul)
# $(2) = RTL source files (space-separated)
# $(3) = testbench source file
#
# Each testbench gets:
#   tb-<name>-build  — compile only
#   tb-<name>        — compile and run

define TB_TEMPLATE

TB_NAMES += $(1)

$(BUILD_DIR)/$(1)/V$(notdir $(basename $(3))): $(2) $(3) | $(BUILD_DIR)/$(1)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		--Mdir $(BUILD_DIR)/$(1) \
		-o V$(notdir $(basename $(3))) \
		$(2) $(3)

$(BUILD_DIR)/$(1):
	mkdir -p $$@

.PHONY: tb-$(1)-build tb-$(1)
tb-$(1)-build: $(BUILD_DIR)/$(1)/V$(notdir $(basename $(3)))

tb-$(1): $(BUILD_DIR)/$(1)/V$(notdir $(basename $(3)))
	$(BUILD_DIR)/$(1)/V$(notdir $(basename $(3)))

endef

# -----------------------------------------------------------------------
# Register testbenches — add new entries here
# -----------------------------------------------------------------------

$(eval $(call TB_TEMPLATE,axi-lite-to-tlul,\
	$(RTL_DIR)/axi_lite_to_tlul.sv,\
	$(TB_DIR)/tb_axi_lite_to_tlul.sv))

# Add more testbenches here, e.g.:
# $(eval $(call TB_TEMPLATE,my-module,\
# 	$(RTL_DIR)/my_module.sv,\
# 	$(TB_DIR)/tb_my_module.sv))

# -----------------------------------------------------------------------
# Aggregate targets
# -----------------------------------------------------------------------

.PHONY: all build-all list clean help

all: $(addprefix tb-,$(TB_NAMES))

build-all: $(addsuffix -build,$(addprefix tb-,$(TB_NAMES)))

list:
	@echo "Available testbenches:"
	@$(foreach t,$(TB_NAMES),echo "  make tb-$(t)";)

clean:
	rm -rf $(BUILD_DIR)

help:
	@echo "Usage:"
	@echo "  make tb-<name>        Build and run a testbench"
	@echo "  make tb-<name>-build  Build only"
	@echo "  make all              Build and run all testbenches"
	@echo "  make build-all        Build all testbenches"
	@echo "  make list             List available testbenches"
	@echo "  make clean            Remove build artifacts"
	@echo ""
	@echo "Available testbenches:"
	@$(foreach t,$(TB_NAMES),echo "  tb-$(t)";)
