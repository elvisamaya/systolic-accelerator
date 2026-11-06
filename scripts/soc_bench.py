#!/usr/bin/env python3
"""soc_bench.py - run C = A x B on the SoC two ways and compare cycle counts.

    python3 scripts/soc_bench.py

For several inner dimensions K it builds fresh random matrices, runs
programs/matmul_sw.s (RISC-V only) and programs/matmul_accel.s (RISC-V driving
the accelerator) on the Verilog SoC, checks both results against NumPy, and
prints the cycle counts.
"""
import argparse
import re
import subprocess
import sys


def run(build, prog, data):
    out = subprocess.run(["vvp", "-n", f"{build}/tb_soc.vvp", f"+prog={build}/{prog}.hex", f"+data={data}"],
                         capture_output=True, text=True).stdout
    for line in out.splitlines():
        if "ERROR" in line:
            print("  " + line.strip())
    m = re.search(r"RESULT \S+ cycles=(\d+) instret=(\d+) errors=(\d+)", out)
    if not m or "TEST PASSED" not in out:
        sys.exit(f"FAILED: {prog} on {data}")
    return int(m.group(1)), int(m.group(2))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--build", default="build")
    a = ap.parse_args()

    print("| K | software: cycles | accelerated: cycles | of which the array computes | speedup |")
    print("|---:|---:|---:|---:|---:|")
    for k in (8, 16, 32, 64):
        data = f"{a.build}/matmul_k{k}"
        subprocess.run([sys.executable, "scripts/soc_data.py", "--k", str(k), "--seed", str(k), "--out", data], check=True)
        sw_cycles, _ = run(a.build, "matmul_sw", data)
        hw_cycles, _ = run(a.build, "matmul_accel", data)
        array_cycles = k + 2 * 4
        print(f"| {k} | {sw_cycles:,} | {hw_cycles:,} | {array_cycles} ({100 * array_cycles / hw_cycles:.0f}%) "
              f"| {sw_cycles / hw_cycles:.1f}x |")
    print("TEST PASSED")


if __name__ == "__main__":
    main()
