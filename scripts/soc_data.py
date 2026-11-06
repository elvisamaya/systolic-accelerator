#!/usr/bin/env python3
"""soc_data.py - make the data-memory image and expected result for the SoC test.

    python3 scripts/soc_data.py --k 32 --seed 1 --out build/matmul

writes build/matmul.dmem   1024-word RAM image (A, B and K in the layout the
                           programs expect)
       build/matmul.expect 16 words: C = A x B from the NumPy golden model
"""
import argparse
import sys

import numpy as np

sys.path.insert(0, "scripts")
from accel_model import _pack_vectors, golden  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--k", type=int, default=32)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    assert 1 <= a.k <= 64

    rng = np.random.default_rng(a.seed)
    A = rng.integers(-128, 128, (4, a.k), dtype=np.int16).astype(np.int8)
    B = rng.integers(-128, 128, (a.k, 4), dtype=np.int16).astype(np.int8)
    A[0, 0], B[0, 0] = -128, -128                       # always include the extreme case

    ram = np.zeros(1024, dtype=np.uint32)
    ram[0x000 // 4:0x000 // 4 + a.k] = _pack_vectors(A.T)   # A, column by column
    ram[0x100 // 4:0x100 // 4 + a.k] = _pack_vectors(B)     # B, row by row
    ram[0x300 // 4] = a.k

    with open(a.out + ".dmem", "w") as f:
        f.writelines(f"{int(w):08x}\n" for w in ram)
    with open(a.out + ".expect", "w") as f:
        f.writelines(f"{int(w):08x}\n" for w in golden(A, B).astype(np.int32).view(np.uint32).reshape(-1))


if __name__ == "__main__":
    main()
