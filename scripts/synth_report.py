#!/usr/bin/env python3
"""synth_report.py - synthesize designs to SkyWater 130nm standard cells with
Yosys and report area, cell counts and an estimated maximum clock frequency.

    python3 scripts/synth_report.py --lib build/sky130_fd_sc_hd__tt_025C_1v80.lib

For each configuration it runs:
    synth            generic logic synthesis (RTL -> gates), flattened
    dfflibmap        map flip-flops to sky130 flip-flop cells
    abc -liberty     map logic to sky130 cells, optimizing for delay
    stat -liberty    count cells and sum their area (um^2)
and asks ABC for the longest register-to-register logic delay (`stime`).

These are pre-layout estimates: real place-and-route adds wire delay and
clock-tree effects, typically costing 10-30% of the frequency.
"""
import argparse
import re
import subprocess
import sys
from pathlib import Path

RTL = ["rtl/pe.v", "rtl/systolic_array.v", "rtl/accel.v"]
FLOP_OVERHEAD_NS = 0.45     # sky130 dfxtp clock-to-Q (~0.35 ns) + setup (~0.1 ns)

CONFIGS = [
    # (label, top, parameters)
    ("PE (int8 MAC)",          "pe",             {}),
    ("2x2 array",              "systolic_array", {"N": 2}),
    ("4x4 array",              "systolic_array", {"N": 4}),
    ("8x8 array",              "systolic_array", {"N": 8}),
    ("accelerator N=4, KMAX=16", "accel",        {"N": 4, "KMAX": 16}),
    ("accelerator N=4, KMAX=64", "accel",        {"N": 4, "KMAX": 64}),
]

ABC_SCRIPT = "+strash;dch;map -B 0.9;topo;stime -c;buffer -c;upsize -c;dnsize -c;stime -p"


FILES = {"pe": RTL[:1], "systolic_array": RTL[:2], "accel": RTL}

# A thin wrapper sets the parameters (Yosys 0.33 cannot override parameters
# of a module containing generate blocks from the command line).
WRAPPERS = {
    "pe": None,
    "systolic_array": """module synth_top (input clk, rst_n, clear, in_valid,
    input [{N}*8-1:0] a_col, b_row, output [{N}*{N}*32-1:0] c_flat);
    systolic_array #(.N({N})) u (.clk(clk), .rst_n(rst_n), .clear(clear), .in_valid(in_valid),
                                 .a_col(a_col), .b_row(b_row), .c_flat(c_flat));
endmodule
""",
    "accel": """module synth_top (input clk, rst_n, sel, we, input [11:0] addr, input [31:0] wdata,
    output [31:0] rdata, output busy, done);
    accel #(.N({N}), .KMAX({KMAX})) u (.clk(clk), .rst_n(rst_n), .sel(sel), .we(we), .addr(addr),
                                       .wdata(wdata), .rdata(rdata), .busy(busy), .done(done));
endmodule
""",
}


def synth(top, params, lib, log_dir):
    tag = top + "".join(f"_{k}{v}" for k, v in params.items())
    files = list(FILES[top])
    top_name = top
    if WRAPPERS[top]:
        wrapper = log_dir / f"wrap_{tag}.v"
        wrapper.write_text(WRAPPERS[top].format(**params))
        files.append(str(wrapper))
        top_name = "synth_top"
    script = f"""
read_verilog -sv -I rtl {' '.join(files)}
hierarchy -check -top {top_name}
synth -top {top_name} -flatten
dfflibmap -liberty {lib}
abc -liberty {lib} -script "{ABC_SCRIPT}"
opt_clean
stat -liberty {lib}
"""
    log = log_dir / f"synth_{tag}.log"
    res = subprocess.run(["yosys", "-q", "-l", str(log), "-p", script], capture_output=True, text=True)
    if res.returncode != 0:
        sys.exit(f"yosys failed for {tag}:\n{res.stderr[-2000:]}")
    text = log.read_text()
    area = float(re.findall(r"Chip area for (?:top )?module '?\\?\S*'?:\s*([\d.]+)", text)[-1])
    cells = int(re.findall(r"Number of cells:\s+(\d+)", text)[-1])
    flops = _count_flops(text)
    # ABC reports timing twice: after mapping, and after buffering and gate sizing.
    # The last report is the final netlist.
    delays = [float(d) for d in re.findall(r"Delay\s*=\s*([\d.]+)\s*ps", text)]
    delay_ns = delays[-1] / 1000 if delays else float("nan")
    return area, cells, flops, delay_ns


def _count_flops(text):
    # the last 'stat' block lists "<count> <cell>" lines
    block = text[text.rfind("Number of cells"):]
    total = 0
    for m in re.finditer(r"^\s+(\d+)\s+sky130_fd_sc_hd__(\w+)$", block, re.M):
        if m.group(2).startswith(("df", "edf", "sdf", "dl")):
            total += int(m.group(1))
    if total == 0:   # newer yosys prints "<cell> <count>"
        for m in re.finditer(r"^\s+sky130_fd_sc_hd__(\w+)\s+(\d+)$", block, re.M):
            if m.group(1).startswith(("df", "edf", "sdf", "dl")):
                total += int(m.group(2))
    return total


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--lib", required=True)
    ap.add_argument("--build", default="build")
    a = ap.parse_args()
    log_dir = Path(a.build)
    log_dir.mkdir(exist_ok=True)

    rows = []
    for label, top, params in CONFIGS:
        area, cells, flops, delay = synth(top, params, a.lib, log_dir)
        fmax = 1000 / (delay + FLOP_OVERHEAD_NS)
        rows.append((label, cells, flops, area, delay, fmax))
        print(f"  {label:<26} done", file=sys.stderr)

    print("| design | cells | flip-flops | area (um^2) | critical path (ns) | est. Fmax (MHz) |")
    print("|---|---:|---:|---:|---:|---:|")
    for label, cells, flops, area, delay, fmax in rows:
        print(f"| {label} | {cells:,} | {flops:,} | {area:,.0f} | {delay:.2f} | {fmax:.0f} |")


if __name__ == "__main__":
    main()
