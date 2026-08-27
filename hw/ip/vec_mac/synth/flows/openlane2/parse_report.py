#!/usr/bin/env python3
"""Extract area / Fmax / power from an OpenLane2 run directory."""
import sys
import pathlib


def parse(run_dir):
    run = pathlib.Path(run_dir)

    # Find the latest RUN_* subdirectory that has a final/ directory
    run_subdirs = sorted(
        [d for d in run.glob("runs/RUN_*") if (d / "final" / "metrics.csv").exists()],
        key=lambda d: d.name,
    )
    if not run_subdirs:
        # Try if run_dir is already a RUN_* dir
        if (run / "final" / "metrics.csv").exists():
            latest = run
        else:
            return {"area_um2": None, "fmax_mhz": None, "power_mw": None,
                    "error": f"no final/metrics.csv found under {run}"}
    else:
        latest = run_subdirs[-1]

    metrics_path = latest / "final" / "metrics.csv"
    metrics = {}
    with metrics_path.open() as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("Metric"):
                continue
            if "," in line:
                key, _, val = line.partition(",")
                metrics[key.strip()] = val.strip()

    area = metrics.get("design__instance__area")
    power = metrics.get("power__total")

    # Setup WNS from typical corner (tt_025C_1v80); clock period is 5.0 ns
    wns_key = "timing__setup__wns__corner:nom_tt_025C_1v80"
    wns = metrics.get(wns_key)
    fmax = None
    if wns is not None:
        try:
            wns_f = float(wns)
            period_ns = 5.0
            achieved = period_ns - wns_f if wns_f < 0 else period_ns
            fmax = round(1000.0 / achieved, 1) if achieved > 0 else None
        except (ValueError, TypeError):
            pass

    return {
        "area_um2": area,
        "fmax_mhz": fmax,
        "power_mw": power,
    }


if __name__ == "__main__":
    result = parse(sys.argv[1])
    area = result.get("area_um2", "")
    fmax = result.get("fmax_mhz", "")
    power = result.get("power_mw", "")
    print(f"{area},{fmax},{power}")
