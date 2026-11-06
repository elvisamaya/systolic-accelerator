#!/usr/bin/env python3
"""regress.py - random regression of the accelerator against the NumPy golden model.

    python3 scripts/regress.py --n 4 --jobs 500 --seed 1

Generates jobs that mix ordinary random matrices with the cases most likely
to break integer hardware:
  * every value at -128 or +127 (largest products, sign handling)
  * K = 1 and K = KMAX (pipeline fill/drain edge cases)
  * zeros, identity-like and single-nonzero matrices (wiring / indexing bugs)
then runs them on the Verilog accelerator and compares every result.
"""
import argparse
import sys

import numpy as np

sys.path.insert(0, "scripts")
from accel_model import golden, run_on_hardware  # noqa: E402

KMAX = 64


def make_jobs(n, count, rng):
    jobs = []
    for t in range(count):
        kind = t % 8
        k = int(rng.integers(1, KMAX + 1))
        if kind == 1:
            k = 1
        if kind == 2:
            k = KMAX
        if kind == 3:                                   # extremes only
            A = rng.choice(np.array([-128, 127], dtype=np.int8), size=(n, k))
            B = rng.choice(np.array([-128, 127], dtype=np.int8), size=(k, n))
        elif kind == 4:                                 # one nonzero element in each matrix
            A = np.zeros((n, k), np.int8); B = np.zeros((k, n), np.int8)
            A[rng.integers(n), rng.integers(k)] = rng.integers(-128, 128)
            B[rng.integers(k), rng.integers(n)] = rng.integers(-128, 128)
        elif kind == 5:                                 # small values, mostly zeros (sparse)
            A = (rng.integers(-3, 4, (n, k)) * (rng.random((n, k)) < 0.3)).astype(np.int8)
            B = (rng.integers(-3, 4, (k, n)) * (rng.random((k, n)) < 0.3)).astype(np.int8)
        else:                                           # uniform random int8
            A = rng.integers(-128, 128, (n, k), dtype=np.int16).astype(np.int8)
            B = rng.integers(-128, 128, (k, n), dtype=np.int16).astype(np.int8)
        jobs.append((A, B))
    return jobs


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--n", type=int, default=4)
    ap.add_argument("--jobs", type=int, default=400)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--build", default="build")
    a = ap.parse_args()

    rng = np.random.default_rng(a.seed)
    jobs = make_jobs(a.n, a.jobs, rng)
    C_hw, cycles = run_on_hardware(jobs, a.n, a.build, tag=f"regress_n{a.n}_s{a.seed}")

    bad = 0
    for idx, ((A, B), C) in enumerate(zip(jobs, C_hw)):
        expect = golden(A, B)
        if not np.array_equal(C, expect):
            bad += 1
            if bad <= 5:
                diff = np.argwhere(C != expect)[0]
                print(f"  ERROR job {idx} (K={A.shape[1]}): C{tuple(diff)} = {C[tuple(diff)]}, "
                      f"expected {expect[tuple(diff)]}")
        if cycles[idx] != A.shape[1] + 2 * a.n:
            bad += 1
            print(f"  ERROR job {idx}: {cycles[idx]} cycles, expected K + 2N = {A.shape[1] + 2 * a.n}")

    macs = sum(A.shape[0] * A.shape[1] * B.shape[1] for A, B in jobs)
    print(f"regress (N={a.n}, seed={a.seed}): {len(jobs)} jobs, {macs:,} multiply-accumulates, {bad} errors")
    print("TEST PASSED" if bad == 0 else "TEST FAILED")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
