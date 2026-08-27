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

$(eval $(call TB_TEMPLATE,arith-unit,\
    $(REPO_ROOT)/hw/ip/arith/rtl/arith_pkg.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/adder_ripple.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/adder_cla.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/adder_kogge_stone.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/adder_brent_kung.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/adder_sklansky.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/adder.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/mul_array.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/mul_booth4.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/mul_wallace.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/mul_dadda.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/mul_signed.sv,\
    $(TB_DIR)/tb_arith_unit.sv))

.PHONY: tb-arith-unit-sweep
tb-arith-unit-sweep:
	@for unit in 0 1; do \
	  if [ "$$unit" = "0" ]; then kids="0 1 2 3 4 5"; else kids="0 1 2 3 4"; fi; \
	  for kid in $$kids; do \
	    for pipe in 0 1; do \
	      out=$(BUILD_DIR)/arith-unit-$$unit-$$kid-$$pipe; \
	      mkdir -p $$out; \
	      echo "=== UNIT=$$unit KID=$$kid PIPE=$$pipe ==="; \
	      $(VERILATOR) $(VERILATOR_FLAGS) -Wno-UNUSEDSIGNAL -Wno-SELRANGE \
	        -GUNIT_KIND=$$unit -GK_ID=$$kid -GPIPE=$$pipe \
	        --Mdir $$out -o Vtb_arith_unit \
	        $(REPO_ROOT)/hw/ip/arith/rtl/arith_pkg.sv \
	        $(REPO_ROOT)/hw/ip/arith/rtl/adder_ripple.sv \
	        $(REPO_ROOT)/hw/ip/arith/rtl/adder_cla.sv \
	        $(REPO_ROOT)/hw/ip/arith/rtl/adder_kogge_stone.sv \
	        $(REPO_ROOT)/hw/ip/arith/rtl/adder_brent_kung.sv \
	        $(REPO_ROOT)/hw/ip/arith/rtl/adder_sklansky.sv \
	        $(REPO_ROOT)/hw/ip/arith/rtl/adder.sv \
	        $(REPO_ROOT)/hw/ip/arith/rtl/mul_array.sv \
	        $(REPO_ROOT)/hw/ip/arith/rtl/mul_booth4.sv \
	        $(REPO_ROOT)/hw/ip/arith/rtl/mul_wallace.sv \
	        $(REPO_ROOT)/hw/ip/arith/rtl/mul_dadda.sv \
	        $(REPO_ROOT)/hw/ip/arith/rtl/mul_signed.sv \
	        $(TB_DIR)/tb_arith_unit.sv >/dev/null 2>&1; \
	      $$out/Vtb_arith_unit || exit 1; \
	    done; \
	  done; \
	done

$(eval $(call TB_TEMPLATE,vec-mac-core,\
    $(REPO_ROOT)/hw/ip/arith/rtl/arith_pkg.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/adder_ripple.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/adder_cla.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/adder_kogge_stone.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/adder_brent_kung.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/adder_sklansky.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/adder.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/mul_array.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/mul_booth4.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/mul_wallace.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/mul_dadda.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/mul_signed.sv \
    $(REPO_ROOT)/hw/ip/vec_mac/rtl/vec_mac_core.sv,\
    $(TB_DIR)/tb_vec_mac_core.sv))

# vec_mac_core uses a generate-loop tree array that Verilator flags as
# UNOPTFLAT (false positive on the combinational adder tree structure).
# Override the build recipe for this TB to suppress it.
VEC_MAC_CORE_SRCS := \
    $(REPO_ROOT)/hw/ip/arith/rtl/arith_pkg.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/adder_ripple.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/adder_cla.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/adder_kogge_stone.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/adder_brent_kung.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/adder_sklansky.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/adder.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/mul_array.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/mul_booth4.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/mul_wallace.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/mul_dadda.sv \
    $(REPO_ROOT)/hw/ip/arith/rtl/mul_signed.sv \
    $(REPO_ROOT)/hw/ip/vec_mac/rtl/vec_mac_core.sv

$(BUILD_DIR)/vec-mac-core/Vtb_vec_mac_core: $(VEC_MAC_CORE_SRCS) $(TB_DIR)/tb_vec_mac_core.sv | $(BUILD_DIR)/vec-mac-core
	$(VERILATOR) $(VERILATOR_FLAGS) -Wno-UNOPTFLAT -Wno-UNUSEDSIGNAL -Wno-SELRANGE \
		--Mdir $(BUILD_DIR)/vec-mac-core \
		-o Vtb_vec_mac_core \
		$(VEC_MAC_CORE_SRCS) $(TB_DIR)/tb_vec_mac_core.sv

.PHONY: tb-vec-mac-core-sweep
tb-vec-mac-core-sweep:
	@for add in 0 1 2 3 4 5; do \
	  for mul in 0 1 2 3 4; do \
	    for pipe in 0 1; do \
	      out=$(BUILD_DIR)/vec-mac-core-$$add-$$mul-$$pipe; \
	      mkdir -p $$out; \
	      echo "=== ADD=$$add MUL=$$mul PIPE=$$pipe ==="; \
	      $(VERILATOR) $(VERILATOR_FLAGS) -Wno-UNOPTFLAT -Wno-UNUSEDSIGNAL -Wno-SELRANGE \
	        -GADD_KID=$$add -GMUL_KID=$$mul \
	        -GMUL_PIPE=$$pipe -GADD_PIPE=$$pipe \
	        --Mdir $$out -o Vtb_vec_mac_core \
	        $(REPO_ROOT)/hw/ip/arith/rtl/arith_pkg.sv \
	        $(REPO_ROOT)/hw/ip/arith/rtl/adder_ripple.sv \
	        $(REPO_ROOT)/hw/ip/arith/rtl/adder_cla.sv \
	        $(REPO_ROOT)/hw/ip/arith/rtl/adder_kogge_stone.sv \
	        $(REPO_ROOT)/hw/ip/arith/rtl/adder_brent_kung.sv \
	        $(REPO_ROOT)/hw/ip/arith/rtl/adder_sklansky.sv \
	        $(REPO_ROOT)/hw/ip/arith/rtl/adder.sv \
	        $(REPO_ROOT)/hw/ip/arith/rtl/mul_array.sv \
	        $(REPO_ROOT)/hw/ip/arith/rtl/mul_booth4.sv \
	        $(REPO_ROOT)/hw/ip/arith/rtl/mul_wallace.sv \
	        $(REPO_ROOT)/hw/ip/arith/rtl/mul_dadda.sv \
	        $(REPO_ROOT)/hw/ip/arith/rtl/mul_signed.sv \
	        $(REPO_ROOT)/hw/ip/vec_mac/rtl/vec_mac_core.sv \
	        $(TB_DIR)/tb_vec_mac_core.sv >/dev/null 2>&1; \
	      $$out/Vtb_vec_mac_core || exit 1; \
	    done; \
	  done; \
	done

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
