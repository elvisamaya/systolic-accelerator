#!/usr/bin/env python3
"""openlane_summary.py - summarize the latest OpenLane run as a Markdown table.

    python3 scripts/openlane_summary.py [openlane/runs]
"""
import json
import sys
from pathlib import Path

FIELDS = [
    ("design__die__area", "die area (um^2)"),
    ("design__core__area", "core area (um^2)"),
    ("design__instance__count", "standard cells"),
    ("design__instance__utilization", "core utilization"),
    ("timing__setup__ws", "setup slack @ 10 ns (ns)"),
    ("timing__hold__ws", "hold slack (ns)"),
    ("power__total", "total power (W)"),
    ("route__wirelength", "wire length (um)"),
    ("route__drc_errors", "DRC errors after routing"),
    ("magic__drc_error__count", "Magic DRC errors"),
    ("design__lvs_error__count", "LVS errors"),
]


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "openlane/runs")
    runs = sorted(root.glob("*/final/metrics.json"), key=lambda p: p.stat().st_mtime)
    if not runs:
        print("No finished OpenLane run found.")
        return
    metrics = json.loads(runs[-1].read_text())
    print(f"### OpenLane results ({runs[-1].parent.parent.name})\n")
    print("| metric | value |\n|---|---:|")
    for key, label in FIELDS:
        if key in metrics:
            v = metrics[key]
            print(f"| {label} | {v:,.4g} |" if isinstance(v, (int, float)) else f"| {label} | {v} |")


if __name__ == "__main__":
    main()
