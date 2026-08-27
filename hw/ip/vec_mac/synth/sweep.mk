# vec-mac per-module synth sweep — invoked by top-level Makefile
SYNTH_DIR := $(REPO_ROOT)/hw/ip/vec_mac/synth
BUILD_DIR := $(REPO_ROOT)/build/synth/vec_mac

ADDS_DEFAULT  := operator,ripple,cla,kogge_stone,brent_kung,sklansky
MULS_DEFAULT  := operator,array,booth4,wallace,dadda
PIPES_DEFAULT := 0,1

ADDS  := $(or $(ADDS),$(ADDS_DEFAULT))
MULS  := $(or $(MULS),$(MULS_DEFAULT))
PIPES := $(or $(PIPES),$(PIPES_DEFAULT))
FLOW  := $(or $(FLOW),yosys)

WRAPPER_DIR := $(BUILD_DIR)/wrappers

.PHONY: vec-mac-sweep vec-mac-wrappers vec-mac-report yosys-sweep ol2-sweep vivado-sweep

vec-mac-wrappers:
	mkdir -p $(WRAPPER_DIR)
	$(SYNTH_DIR)/gen_wrappers.py --out $(WRAPPER_DIR) \
	  --adds "$(ADDS)" --muls "$(MULS)" --pipes "$(PIPES)" > $(BUILD_DIR)/cells.txt

vec-mac-sweep: vec-mac-wrappers
	@if [ "$(FLOW)" = "yosys" ]; then \
	  $(MAKE) -f $(SYNTH_DIR)/sweep.mk REPO_ROOT=$(REPO_ROOT) yosys-sweep; \
	elif [ "$(FLOW)" = "ol2" ]; then \
	  $(MAKE) -f $(SYNTH_DIR)/sweep.mk REPO_ROOT=$(REPO_ROOT) ol2-sweep; \
	elif [ "$(FLOW)" = "fpga" ]; then \
	  $(MAKE) -f $(SYNTH_DIR)/sweep.mk REPO_ROOT=$(REPO_ROOT) vivado-sweep; \
	else \
	  echo "Unknown FLOW=$(FLOW); use yosys, ol2, or fpga"; exit 1; \
	fi

# sv2v v0.0.12 does not support `(* attr *)` between `module` and `#(`.
# Strip these attributes into temp files before running sv2v.
STRIP_ATTRS = sed 's/([*][^*]*[*])//g'

CORE_SV_FILES = \
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

yosys-sweep:
	@mkdir -p $(BUILD_DIR)/yosys
	@echo "cell,cells,fmax_mhz,power_mw" > $(BUILD_DIR)/yosys/results.csv
	@for cell in `cat $(BUILD_DIR)/cells.txt`; do \
	  outdir=$(BUILD_DIR)/yosys/$$cell; \
	  mkdir -p $$outdir; \
	  stripped=$$outdir/stripped; \
	  mkdir -p $$stripped; \
	  for f in $(CORE_SV_FILES) $(WRAPPER_DIR)/vec_mac_core_$$cell.sv; do \
	    base=$$(basename $$f); \
	    sed 's/([*][^*]*[*])//g' $$f > $$stripped/$$base; \
	  done; \
	  sv2v \
	    $$stripped/arith_pkg.sv \
	    $$stripped/adder_ripple.sv \
	    $$stripped/adder_cla.sv \
	    $$stripped/adder_kogge_stone.sv \
	    $$stripped/adder_brent_kung.sv \
	    $$stripped/adder_sklansky.sv \
	    $$stripped/adder.sv \
	    $$stripped/mul_array.sv \
	    $$stripped/mul_booth4.sv \
	    $$stripped/mul_wallace.sv \
	    $$stripped/mul_dadda.sv \
	    $$stripped/mul_signed.sv \
	    $$stripped/vec_mac_core.sv \
	    $$stripped/vec_mac_core_$$cell.sv \
	    > $$outdir/design.v 2>$$outdir/sv2v.log \
	    || { echo "FAIL sv2v: $$cell"; cat $$outdir/sv2v.log; exit 1; }; \
	  sed -e "s|@TOP@|vec_mac_core_$$cell|g" \
	      -e "s|@OUTDIR@|$$outdir|g" \
	      $(SYNTH_DIR)/flows/yosys-generic/synth.ys.in > $$outdir/synth.ys; \
	  cd $(REPO_ROOT) && yosys -q -l $$outdir/synth.log $$outdir/synth.ys || { echo "FAIL yosys: $$cell"; tail -20 $$outdir/synth.log; exit 1; }; \
	  row=`$(SYNTH_DIR)/flows/yosys-generic/parse_report.py $$outdir/synth.log`; \
	  echo "$$cell,$$row" >> $(BUILD_DIR)/yosys/results.csv; \
	done
	@echo "Yosys sweep complete: $(BUILD_DIR)/yosys/results.csv"

ol2-sweep:
	@mkdir -p $(BUILD_DIR)/ol2
	@echo "cell,area_um2,fmax_mhz,power_mw" > $(BUILD_DIR)/ol2/results.csv
	@for cell in `cat $(BUILD_DIR)/cells.txt`; do \
	  outdir=$(BUILD_DIR)/ol2/$$cell; \
	  mkdir -p $$outdir; \
	  stripped=$$outdir/stripped; \
	  mkdir -p $$stripped; \
	  for f in $(CORE_SV_FILES) $(WRAPPER_DIR)/vec_mac_core_$$cell.sv; do \
	    base=$$(basename $$f); \
	    sed 's/([*][^*]*[*])//g' $$f > $$stripped/$$base; \
	  done; \
	  sv2v \
	    $$stripped/arith_pkg.sv \
	    $$stripped/adder_ripple.sv \
	    $$stripped/adder_cla.sv \
	    $$stripped/adder_kogge_stone.sv \
	    $$stripped/adder_brent_kung.sv \
	    $$stripped/adder_sklansky.sv \
	    $$stripped/adder.sv \
	    $$stripped/mul_array.sv \
	    $$stripped/mul_booth4.sv \
	    $$stripped/mul_wallace.sv \
	    $$stripped/mul_dadda.sv \
	    $$stripped/mul_signed.sv \
	    $$stripped/vec_mac_core.sv \
	    $$stripped/vec_mac_core_$$cell.sv \
	    > $$outdir/design.v 2>$$outdir/sv2v.log \
	    || { echo "FAIL sv2v: $$cell"; cat $$outdir/sv2v.log; exit 1; }; \
	  printf '{\n  "DESIGN_NAME": "vec_mac_core_%s",\n  "VERILOG_FILES": ["%s/design.v"],\n  "CLOCK_PORT": "clk_i",\n  "CLOCK_PERIOD": 5.0,\n  "SYNTH_STRATEGY": "AREA 0",\n  "ERROR_ON_SYNTH_CHECKS": false\n}\n' \
	    $$cell $$outdir > $$outdir/config.json; \
	  cd $(REPO_ROOT) && nix develop github:efabless/openlane2 --command \
	    python3 $(SYNTH_DIR)/flows/openlane2/synth_flow.py $$outdir/config.json \
	    > $$outdir/run.log 2>&1 || { echo "FAIL: $$cell (see $$outdir/run.log)"; exit 1; }; \
	  ROW=$$($(SYNTH_DIR)/flows/openlane2/parse_report.py $$outdir 2>/dev/null | head -1); \
	  echo "$$cell,$$ROW" >> $(BUILD_DIR)/ol2/results.csv; \
	  echo "OK: $$cell"; \
	done

vivado-sweep:
	@mkdir -p $(BUILD_DIR)/vivado
	@echo "cell,luts,ffs,fmax_mhz" > $(BUILD_DIR)/vivado/results.csv
	@for cell in `cat $(BUILD_DIR)/cells.txt`; do \
	  outdir=$(BUILD_DIR)/vivado/$$cell; \
	  mkdir -p $$outdir; \
	  stripped=$$outdir/stripped; \
	  mkdir -p $$stripped; \
	  for f in $(CORE_SV_FILES) $(WRAPPER_DIR)/vec_mac_core_$$cell.sv; do \
	    base=$$(basename $$f); \
	    sed 's/([*][^*]*[*])//g' $$f > $$stripped/$$base; \
	  done; \
	  sv2v \
	    $$stripped/arith_pkg.sv \
	    $$stripped/adder_ripple.sv \
	    $$stripped/adder_cla.sv \
	    $$stripped/adder_kogge_stone.sv \
	    $$stripped/adder_brent_kung.sv \
	    $$stripped/adder_sklansky.sv \
	    $$stripped/adder.sv \
	    $$stripped/mul_array.sv \
	    $$stripped/mul_booth4.sv \
	    $$stripped/mul_wallace.sv \
	    $$stripped/mul_dadda.sv \
	    $$stripped/mul_signed.sv \
	    $$stripped/vec_mac_core.sv \
	    $$stripped/vec_mac_core_$$cell.sv \
	    > $$outdir/design.v 2>$$outdir/sv2v.log \
	    || { echo "FAIL sv2v: $$cell"; cat $$outdir/sv2v.log; exit 1; }; \
	  sed -e "s|@SOURCES@|$$outdir/design.v|g" \
	      -e "s|@TOP@|vec_mac_core_$$cell|g" \
	      -e "s|@OUTDIR@|$$outdir|g" \
	      $(SYNTH_DIR)/flows/vivado-loose/synth.tcl.in > $$outdir/synth.tcl; \
	  cd $$outdir && vivado -mode batch -source synth.tcl -log vivado.log -journal vivado.jou \
	    > /dev/null 2>&1 || { echo "FAIL: $$cell (see $$outdir/vivado.log)"; exit 1; }; \
	  ROW=$$($(SYNTH_DIR)/flows/vivado-loose/parse_report.py $$outdir); \
	  echo "$$cell,$$ROW" >> $(BUILD_DIR)/vivado/results.csv; \
	  echo "OK: $$cell"; \
	done

vec-mac-report:
	@cat $(BUILD_DIR)/$(FLOW)/results.csv
