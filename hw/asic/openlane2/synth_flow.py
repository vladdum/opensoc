#!/usr/bin/env python3
# Copyright OpenSoC contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
"""
OpenLane 2 synthesis-only flow for OpenSoC.

Runs Yosys synthesis (mapped to Sky130 standard cells) and pre-PNR static
timing analysis.  Stops before floorplanning / place & route.

Usage:
    python3 synth_flow.py [--pdk sky130A] config.json

Steps executed (from the Classic flow, truncated before P&R):
    1. Yosys.JsonHeader      — design metadata
    2. Yosys.Synthesis       — RTL → mapped netlist (Sky130 std cells)
    3. Checker.*             — unmapped-cell / netlist sanity checks
    4. OpenROAD.CheckSDCFiles — validate timing constraints
    5. OpenROAD.STAPrePNR    — static timing analysis (ideal clocks, no parasitics)
"""

from openlane.flows import SequentialFlow
from openlane.steps import Yosys, OpenROAD, Checker


class SynthesisOnly(SequentialFlow):
    Steps = [
        Yosys.JsonHeader,
        Yosys.Synthesis,
        Checker.YosysUnmappedCells,
        Checker.YosysSynthChecks,
        Checker.NetlistAssignStatements,
        OpenROAD.CheckSDCFiles,
        OpenROAD.STAPrePNR,
    ]


if __name__ == "__main__":
    import json
    import os
    import sys

    config_path = sys.argv[1] if len(sys.argv) > 1 else "config.json"

    # Resolve paths: put runs/ under build/openlane2/ so make clean works
    script_dir = os.path.dirname(os.path.abspath(config_path))
    repo_root = os.path.abspath(os.path.join(script_dir, "..", "..", ".."))
    design_dir = os.path.join(repo_root, "build", "openlane2")
    os.makedirs(design_dir, exist_ok=True)

    # Copy config with dir:: references resolved to absolute paths
    with open(config_path) as f:
        cfg = json.load(f)
    for key, val in cfg.items():
        if isinstance(val, str) and val.startswith("dir::"):
            cfg[key] = os.path.abspath(os.path.join(script_dir, val[5:]))
        elif isinstance(val, list):
            cfg[key] = [
                os.path.abspath(os.path.join(script_dir, v[5:])) if isinstance(v, str) and v.startswith("dir::") else v
                for v in val
            ]
    resolved_config = os.path.join(design_dir, "config.json")
    with open(resolved_config, "w") as f:
        json.dump(cfg, f, indent=4)

    flow = SynthesisOnly(resolved_config, pdk="sky130A", design_dir=design_dir)
    flow.start()
