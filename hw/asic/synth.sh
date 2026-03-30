#!/bin/bash
# Copyright OpenSoC contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Yosys ASIC synthesis for OpenSoC (sv2v + Yosys)
#
# Prerequisites: make synth-setup, sv2v, yosys
# Usage: make yosys-synth

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_DIR="$REPO_ROOT/build/opensoc_fpga_basys3_0/synth-vivado/src"
OUT_DIR="$REPO_ROOT/build/yosys"
FILELIST="$REPO_ROOT/hw/synth/sources.f"

mkdir -p "$OUT_DIR"

if [ ! -d "$SRC_DIR" ]; then
    echo "ERROR: Source directory not found. Run 'make synth-setup' first."
    exit 1
fi

# ============================================================================
# Read shared filelist (sections: includes, packages, rtl)
# ============================================================================
read_filelist() {
    local section="$1"
    local in_section=0
    while IFS= read -r line; do
        line="${line%%#*}"          # strip comments
        line="${line#"${line%%[![:space:]]*}"}"  # trim leading whitespace
        line="${line%"${line##*[![:space:]]}"}"  # trim trailing whitespace
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            [[ "${BASH_REMATCH[1]}" == "$section" ]] && in_section=1 || in_section=0
            continue
        fi
        [[ $in_section -eq 1 ]] && echo "$line"
    done < "$FILELIST"
}

# ============================================================================
# Include paths (for .svh headers)
# ============================================================================
INC_FLAGS=()
while IFS= read -r dir; do
    INC_FLAGS+=(-I"$SRC_DIR/$dir")
done < <(read_filelist includes)

# ============================================================================
# Defines (ASIC: no FPGA_XILINX, all accelerators enabled)
# ============================================================================
DEFINES=(
    -DSYNTHESIS=1
    -DVERILATOR=1
    -DRegFile=ibex_pkg::RegFileFF
    -DPRIM_DEFAULT_IMPL=prim_pkg::ImplGeneric
)

# ============================================================================
# Collect source files (order: packages first, then RTL)
# ============================================================================
PKG_FILES=()
while IFS= read -r f; do
    PKG_FILES+=("$SRC_DIR/$f")
done < <(read_filelist packages)

RTL_FILES=()
while IFS= read -r pattern; do
    for f in $SRC_DIR/$pattern; do   # glob expansion
        RTL_FILES+=("$f")
    done
done < <(read_filelist rtl)

# Filter out files incompatible with sv2v / not needed for synthesis
ALL_FILES=("${PKG_FILES[@]}" "${RTL_FILES[@]}")
FILTERED_FILES=()
for f in "${ALL_FILES[@]}"; do
    case "$f" in
        *axi_test.sv)         ;;  # uses randomize(), not synthesizable
        *axi_chan_compare.sv) ;;  # sim-only (dynamic queues)
        *axi_sim_mem.sv)      ;;  # sim-only (dynamic queues)
        *axi_dumper.sv)       ;;  # sim-only (file I/O)
        *axi_slave_compare.sv) ;; # sim-only (instantiates axi_chan_compare)
        *stream_delay.sv)     ;;  # sim-only (dynamic queues)
        *ibex_tracer.sv)      ;;  # sim-only (static, final, $fclose)
        *ibex_tracer_pkg.sv)  ;;  # only needed by ibex_tracer
        *ibex_top_tracing.sv) ;;  # opensoc_top uses ibex_top directly under SYNTHESIS
        *) FILTERED_FILES+=("$f") ;;
    esac
done

# ============================================================================
# Patch sources for sv2v compatibility
# sv2v v0.0.12 does not support typedef inside function bodies
# ============================================================================
AXI_PKG="$SRC_DIR/pulp-platform.org__axi_0.39.9/src/axi_pkg.sv"
if grep -q 'typedef shortint unsigned SU;' "$AXI_PKG"; then
    echo "Patching axi_pkg.sv (local typedef unsupported by sv2v)..."
    sed -i '/typedef shortint unsigned SU;/d' "$AXI_PKG"
    sed -i "s/return SU'/return 16'/g" "$AXI_PKG"
fi

# ============================================================================
# Step 1: sv2v — convert SystemVerilog to Verilog
# ============================================================================
echo "=========================================="
echo " sv2v: SystemVerilog → Verilog"
echo "=========================================="
sv2v --top=opensoc_top "${DEFINES[@]}" "${INC_FLAGS[@]}" "${FILTERED_FILES[@]}" \
    > "$OUT_DIR/opensoc_top.v" 2>"$OUT_DIR/sv2v.log"
echo "  Output: $OUT_DIR/opensoc_top.v"
if [ -s "$OUT_DIR/sv2v.log" ]; then
    echo "  Warnings: $OUT_DIR/sv2v.log ($(wc -l < "$OUT_DIR/sv2v.log") lines)"
fi

# If --sv2v-only flag, stop here (used by OpenLane 2 flow)
if [[ "${1:-}" == "--sv2v-only" ]]; then
    echo "  sv2v-only mode: stopping after conversion"
    exit 0
fi

# ============================================================================
# Step 2: Yosys — synthesize to generic gates
# ============================================================================
echo "=========================================="
echo " Yosys: ASIC synthesis"
echo "=========================================="
yosys -q -p "
    read_verilog -sv -defer $OUT_DIR/opensoc_top.v
    synth -top opensoc_top -flatten
    stat
    write_verilog $OUT_DIR/opensoc_top_netlist.v
" -l "$OUT_DIR/yosys.log"

echo ""
echo "=========================================="
echo " Synthesis complete"
echo "=========================================="
echo "  Log:     $OUT_DIR/yosys.log"
echo "  Netlist: $OUT_DIR/opensoc_top_netlist.v"
echo ""
echo "  Quick stats:"
grep -A 20 "Printing statistics" "$OUT_DIR/yosys.log" | head -25
