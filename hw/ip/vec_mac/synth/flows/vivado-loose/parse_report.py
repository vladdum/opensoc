#!/usr/bin/env python3
"""Extract LUT/FF count and Fmax from Vivado reports."""
import re
import sys
import pathlib


def parse(run_dir):
    run = pathlib.Path(run_dir)
    util_path = run / "util.rpt"
    tim_path = run / "timing.rpt"

    luts = ffs = 0
    if util_path.exists():
        text = util_path.read_text()
        for ln in text.splitlines():
            m = re.match(r"\|\s*(?:CLB LUTs|Slice LUTs|LUT as Logic)\s*\|\s*(\d+)", ln)
            if m:
                luts = int(m.group(1))
            m = re.match(r"\|\s*(?:CLB Registers|Slice Registers|Register as Flip Flop)\s*\|\s*(\d+)", ln)
            if m:
                ffs = int(m.group(1))

    fmax = None
    if tim_path.exists():
        text = tim_path.read_text()
        target_ns = 10.0
        slack_match = re.search(r"Slack\s+\(\w+\):\s+(-?\d+\.\d+)\s*ns", text)
        if slack_match:
            slack = float(slack_match.group(1))
            achieved_period = target_ns - slack if slack < 0 else target_ns
            fmax = 1000.0 / achieved_period

    return {"luts": luts, "ffs": ffs, "fmax_mhz": fmax}


if __name__ == "__main__":
    p = parse(sys.argv[1])
    print(f"{p['luts']},{p['ffs']},{p['fmax_mhz']}")
