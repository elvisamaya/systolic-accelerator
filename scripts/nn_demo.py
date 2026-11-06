#!/usr/bin/env python3
"""nn_demo.py - run a real neural network on the (simulated) accelerator.

    python3 scripts/nn_demo.py            # needs build/tb_accel_jobs_n4.vvp

1. Train a small MLP (64 -> 32 -> 10) on scikit-learn's 8x8 handwritten digits,
   in float32 with plain NumPy.
2. Quantize it to int8: weights and activations become 8-bit integers plus a
   per-tensor scale factor (symmetric, "post-training quantization").
3. Run every matrix multiply of the int8 network on the Verilog accelerator,
   tiling the matrices into 4x4 output blocks. The host does only the cheap
   parts: adding biases, ReLU and rescaling between layers.
4. Compare: float accuracy, int8 accuracy computed by NumPy, and int8
   accuracy computed by the hardware. The last two must agree exactly,
   because integer arithmetic has no rounding differences.
"""
import argparse
import sys
import time

import numpy as np
from sklearn.datasets import load_digits
from sklearn.model_selection import train_test_split

sys.path.insert(0, "scripts")
from accel_model import golden, run_on_hardware  # noqa: E402

N = 4          # array size
HIDDEN = 32


# ------------------------------------------------------------------ float model
def train(X, y, epochs, rng):
    W1 = rng.normal(0, np.sqrt(2 / 64), (64, HIDDEN)).astype(np.float32)
    b1 = np.zeros(HIDDEN, np.float32)
    W2 = rng.normal(0, np.sqrt(2 / HIDDEN), (HIDDEN, 10)).astype(np.float32)
    b2 = np.zeros(10, np.float32)
    Y = np.eye(10, dtype=np.float32)[y]
    lr, batch = 0.05, 32
    for _ in range(epochs):
        order = rng.permutation(len(X))
        for s in range(0, len(X), batch):
            idx = order[s:s + batch]
            x, t = X[idx], Y[idx]
            h = np.maximum(x @ W1 + b1, 0)
            z = h @ W2 + b2
            p = np.exp(z - z.max(1, keepdims=True)); p /= p.sum(1, keepdims=True)
            dz = (p - t) / len(idx)                     # softmax + cross-entropy gradient
            dW2 = h.T @ dz; db2 = dz.sum(0)
            dh = (dz @ W2.T) * (h > 0)
            dW1 = x.T @ dh; db1 = dh.sum(0)
            W1 -= lr * dW1; b1 -= lr * db1; W2 -= lr * dW2; b2 -= lr * db2
    return W1, b1, W2, b2


def predict_float(X, W1, b1, W2, b2):
    return (np.maximum(X @ W1 + b1, 0) @ W2 + b2).argmax(1)


# ------------------------------------------------------------------ quantization
def quantize_sym(W):
    scale = np.abs(W).max() / 127.0
    return np.clip(np.round(W / scale), -127, 127).astype(np.int8), scale


class Int8Net:
    """The int8 network. `matmul` is pluggable: NumPy or the hardware."""

    def __init__(self, W1, b1, W2, b2, X_calib):
        self.sx = 16.0 / 127.0                          # inputs are 0..16
        self.qW1, self.s1 = quantize_sym(W1)
        self.qW2, self.s2 = quantize_sym(W2)
        self.qb1 = np.round(b1 / (self.sx * self.s1)).astype(np.int32)
        h = np.maximum(X_calib @ W1 + b1, 0)            # calibrate hidden-layer range
        self.sh = h.max() / 127.0
        self.qb2 = np.round(b2 / (self.sh * self.s2)).astype(np.int32)

    def quant_input(self, X):
        return np.clip(np.round(X / self.sx), 0, 127).astype(np.int8)

    def forward(self, X, matmul):
        qx = self.quant_input(X)
        acc1 = matmul(qx, self.qW1) + self.qb1                          # int32
        h = np.maximum(acc1, 0) * (self.sx * self.s1)                   # ReLU, back to real units
        qh = np.clip(np.round(h / self.sh), 0, 127).astype(np.int8)     # requantize to int8
        acc2 = matmul(qh, self.qW2) + self.qb2
        return acc2.argmax(1), (acc1, acc2)


# ------------------------------------------------------------------ hardware matmul
class HardwareMatmul:
    """Tiles X (M x K) @ W (K x C) into N x N output blocks for the accelerator."""

    def __init__(self, build):
        self.build, self.jobs, self.macs, self.cycles = build, 0, 0, 0

    def __call__(self, X, W):
        M, K = X.shape
        C = W.shape[1]
        Mp, Cp = -(-M // N) * N, -(-C // N) * N         # pad to multiples of N
        Xp = np.zeros((Mp, K), np.int8); Xp[:M] = X
        Wp = np.zeros((K, Cp), np.int8); Wp[:, :C] = W
        tiles = [(r, c) for r in range(0, Mp, N) for c in range(0, Cp, N)]
        jobs = [(Xp[r:r + N], Wp[:, c:c + N]) for r, c in tiles]
        out, cycles = run_on_hardware(jobs, N, self.build, tag=f"nn_k{K}")
        result = np.zeros((Mp, Cp), np.int32)
        for (r, c), block in zip(tiles, out):
            result[r:r + N, c:c + N] = block
        self.jobs += len(jobs)
        self.macs += len(jobs) * N * N * K
        self.cycles += int(cycles.sum())
        return result[:M, :C]


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--build", default="build")
    ap.add_argument("--epochs", type=int, default=60)
    a = ap.parse_args()

    rng = np.random.default_rng(0)
    digits = load_digits()
    X = digits.data.astype(np.float32)
    Xtr, Xte, ytr, yte = train_test_split(X, digits.target, test_size=0.2, random_state=0,
                                          stratify=digits.target)

    W1, b1, W2, b2 = train(Xtr, ytr, a.epochs, rng)
    acc_float = (predict_float(Xte, W1, b1, W2, b2) == yte).mean()

    net = Int8Net(W1, b1, W2, b2, Xtr)
    pred_np, (np1, np2) = net.forward(Xte, golden)
    acc_np = (pred_np == yte).mean()

    hw = HardwareMatmul(a.build)
    t0 = time.time()
    pred_hw, (hw1, hw2) = net.forward(Xte, hw)
    sim_s = time.time() - t0
    acc_hw = (pred_hw == yte).mean()

    exact = np.array_equal(np1, hw1) and np.array_equal(np2, hw2)
    print(f"digits test set: {len(yte)} images, network 64 -> {HIDDEN} -> 10")
    print(f"  float32 (NumPy)          accuracy {100 * acc_float:5.1f}%")
    print(f"  int8    (NumPy)          accuracy {100 * acc_np:5.1f}%")
    print(f"  int8    (accelerator)    accuracy {100 * acc_hw:5.1f}%")
    print(f"  hardware layer outputs identical to NumPy int8: {exact}")
    print(f"  accelerator: {hw.jobs} jobs, {hw.macs:,} multiply-accumulates, "
          f"{hw.cycles:,} array cycles ({hw.macs / hw.cycles:.1f} MACs/cycle), "
          f"simulated in {sim_s:.1f} s")
    ok = exact and acc_hw == acc_np
    print("TEST PASSED" if ok else "TEST FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
