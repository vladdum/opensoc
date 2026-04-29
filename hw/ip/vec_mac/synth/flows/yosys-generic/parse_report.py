#!/usr/bin/env python3
"""Parse Yosys 'stat -tech cmos' output into a CSV row.

Yosys 0.63 stat -tech cmos prints multiple stat sections.  The final
'=== design hierarchy ===' section (after abc technology mapping) contains
the post-mapping cell count.  We find the LAST such section and extract
the total cell count from the second 'Count including submodules' block
(which lists wires, cells, etc.).
"""
import re
import sys
import pathlib

def parse(text):
    lines = text.splitlines()
    # Find indices of all '=== design hierarchy ===' occurrences; take the last.
    hier_idx = [i for i, ln in enumerate(lines) if "=== design hierarchy ===" in ln]
    if not hier_idx:
        return {"cells": 0}
    start = hier_idx[-1]
    # Within that section, find the second 'Count including submodules' block,
    # then look for a line matching '   NNNN cells'.
    count = 0
    in_block = False
    for ln in lines[start:]:
        if "Count including submodules" in ln:
            count += 1
            if count == 2:
                in_block = True
            continue
        if in_block:
            m = re.match(r"^\s+(\d+)\s+cells\s*$", ln)
            if m:
                return {"cells": int(m.group(1))}
    return {"cells": 0}

if __name__ == "__main__":
    log = pathlib.Path(sys.argv[1]).read_text()
    p = parse(log)
    print(f"{p['cells']},,")  # cells, fmax_mhz (empty), power_mw (empty)
