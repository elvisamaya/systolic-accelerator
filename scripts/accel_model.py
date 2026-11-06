"""accel_model.py - NumPy golden model of the accelerator + job-file helpers.

The golden model is just `A.astype(int32) @ B.astype(int32)`: NumPy's matrix
multiply is about as trustworthy as software gets, and it knows nothing about
systolic arrays, skewing or cycles. The hardware must match it bit for bit.

Job files connect Python to the Verilog testbench (tb/tb_accel_jobs.v):

  jobs file (hex, one 32-bit word per line)
      number of jobs
      per job:  K
                K * N/4 words of A, column by column (A[i][k] in byte i % 4)
                K * N/4 words of B, row by row       (B[k][j] in byte j % 4)

  results file written by the testbench
      per job:  N*N words of C (row-major, int32), then the CYCLES counter
"""
import subprocess
from pathlib import Path

import numpy as np


def golden(A, B):
    """Reference result: int8 x int8 -> exact int32 matrix product."""
    return A.astype(np.int32) @ B.astype(np.int32)


def _pack_vectors(M):
    """Pack each row of M (shape K x N, int8) into N/4 little-endian words."""
    K, N = M.shape
    as_bytes = M.astype(np.int8).view(np.uint8).reshape(K, N // 4, 4)
    words = (as_bytes[..., 0].astype(np.uint32)
             | as_bytes[..., 1].astype(np.uint32) << 8
             | as_bytes[..., 2].astype(np.uint32) << 16
             | as_bytes[..., 3].astype(np.uint32) << 24)
    return words.reshape(-1)


def pack_job(A, B):
    """Words for one job: K, then A's columns, then B's rows."""
    N, K = A.shape
    assert B.shape == (K, N) and N % 4 == 0
    return np.concatenate([[K], _pack_vectors(A.T), _pack_vectors(B)]).astype(np.uint32)


def write_jobs(path, jobs):
    words = [np.array([len(jobs)], dtype=np.uint32)] + [pack_job(A, B) for A, B in jobs]
    Path(path).write_text("".join(f"{int(w):08x}\n" for w in np.concatenate(words)))


def read_results(path, n, count):
    vals = np.array([int(x, 16) for x in Path(path).read_text().split()], dtype=np.uint32)
    assert len(vals) == count * (n * n + 1), f"expected {count} results in {path}, got {len(vals) / (n * n + 1)}"
    vals = vals.reshape(count, n * n + 1)
    C = vals[:, :n * n].view(np.int32).reshape(count, n, n)
    cycles = vals[:, n * n].astype(np.int64)
    return C, cycles


def run_on_hardware(jobs, n, build="build", tag="jobs"):
    """Write a job file, run it through the Verilog testbench, return (C, cycles)."""
    build = Path(build)
    vvp = build / f"tb_accel_jobs_n{n}.vvp"
    if not vvp.exists():
        raise SystemExit(f"{vvp} not found - run `make {vvp}` first")
    jobs_file, results_file = build / f"{tag}.jobs", build / f"{tag}.results"
    write_jobs(jobs_file, jobs)
    subprocess.run(["vvp", "-n", str(vvp), f"+jobs={jobs_file}", f"+results={results_file}"],
                   check=True, stdout=subprocess.DEVNULL)
    return read_results(results_file, n, len(jobs))
