#!/bin/bash
# Copyright OpenSoC contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# OpenLane 2 ASIC synthesis for OpenSoC (synthesis + STA, no P&R)
#
# Prerequisites:
#   sv2v                       # SystemVerilog → Verilog converter
#   Nix with flakes enabled    # provides OpenLane 2 + Yosys + OpenROAD
#   make synth-setup           # FuseSoC source collection
#
# Usage: make synth  (or make synth FLOW=ol2)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SV2V_OUT="$REPO_ROOT/build/yosys/opensoc_top.v"

# ============================================================================
# Preflight checks
# ============================================================================
for cmd in sv2v nix; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: $cmd not found. Please install it first."
        exit 1
    fi
done

# ============================================================================
# Step 1: sv2v — SystemVerilog → Verilog
# ============================================================================
echo "=========================================="
echo " Step 1: sv2v preprocessing"
echo "=========================================="
bash "$REPO_ROOT/hw/asic/synth.sh" --sv2v-only

if [ ! -f "$SV2V_OUT" ]; then
    echo "ERROR: sv2v output not found at $SV2V_OUT"
    exit 1
fi
echo "  sv2v output: $SV2V_OUT ($(wc -l < "$SV2V_OUT") lines)"

# ============================================================================
# Step 2: OpenLane 2 — synthesis + STA (Sky130)
# ============================================================================
echo ""
echo "=========================================="
echo " Step 2: OpenLane 2 synthesis (Sky130)"
echo "=========================================="
echo "  Flow:   SynthesisOnly (Yosys → STA, no P&R)"
echo "  Config: $SCRIPT_DIR/config.json"
echo ""

# Run inside OpenLane's Nix flake shell — bundles matched Yosys + OpenROAD + Python.
# First run downloads ~2 GB; subsequent runs use the Nix store cache.
# Requires: 'experimental-features = nix-command flakes' in /etc/nix/nix.conf
OL2_OUT="$REPO_ROOT/build/openlane2"
mkdir -p "$OL2_OUT"

nix develop github:efabless/openlane2 --command \
    python3 "$SCRIPT_DIR/synth_flow.py" "$SCRIPT_DIR/config.json"
FLOW_EXIT=$?

if [ "$FLOW_EXIT" -ne 0 ]; then
    echo ""
    echo "ERROR: OpenLane 2 flow failed (exit $FLOW_EXIT). See $LOG_FILE"
    exit "$FLOW_EXIT"
fi

# ============================================================================
# Summary
# ============================================================================
# OpenLane 2 writes results to build/openlane2/runs/<tag>/
RUN_DIR=$(ls -td "$OL2_OUT/runs"/*/ 2>/dev/null | head -1)
if [ -n "$RUN_DIR" ]; then
    echo ""
    echo "=========================================="
    echo " Results"
    echo "=========================================="
    echo "  Run directory: $RUN_DIR"

    # Print synthesis stats if available
    SYNTH_STAT="$RUN_DIR/02-yosys-synthesis/reports/stat.rpt"
    if [ -f "$SYNTH_STAT" ]; then
        echo ""
        echo "--- Synthesis Statistics ---"
        cat "$SYNTH_STAT"
    fi

    # Print STA summary if available
    STA_RPT=$(find "$RUN_DIR" -name "summary.rpt" -path "*sta*" 2>/dev/null | head -1)
    if [ -n "$STA_RPT" ] && [ -f "$STA_RPT" ]; then
        echo ""
        echo "--- STA Summary ---"
        cat "$STA_RPT"
    fi
fi
