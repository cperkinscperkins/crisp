#!/usr/bin/env python3
"""
Matmul benchmark driver: builds + runs the Crisp and CUDA implementations for a
set of sizes, checks correctness (A = B = 1.0 -> every C == K), and prints a
kernel-time / GFLOPS comparison with the crisp/cuda ratio.

Usage:
  python run.py [--sizes=256,512,1024] [--warmup=20] [--iters=100] [--impl=all]

Prereqs (on the machine where this runs — i.e. RunPod, not the dev box):
  - nvcc on PATH, an NVIDIA GPU (sm_80+ for tf32 mma)
  - crisp-compile on PATH or ../../bin/

Output: a summary table to stdout; per-run JSON on stderr from each binary.

NOTE: DRAFT — authored on a non-CUDA box; expect to iterate the harness param
layout / strides on first real run.  The Crisp kernel + PTX are verified locally.
"""
import argparse, json, os, re, subprocess, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BIN  = None  # resolved below

def find_crisp_compile():
    for c in [HERE/"../../bin/crisp-compile", HERE/"../../bin/crisp-compile.exe", "crisp-compile"]:
        if str(c) == "crisp-compile" or Path(c).exists():
            return str(c)
    sys.exit("crisp-compile not found (bin/ or PATH)")

def sh(cmd, **kw):
    print("  $", " ".join(str(c) for c in cmd), file=sys.stderr)
    return subprocess.run([str(c) for c in cmd], **kw)

def build_crisp():
    sh([find_crisp_compile(), "--ir-target=ptx", "--log-level=off", str(HERE/"crisp/matmul.crisp")], check=True)
    sh(["nvcc","-O3","-arch=sm_80", str(HERE/"crisp/bench_harness.cu"), "-lcuda",
        "-o", str(HERE/"crisp/matmul_crisp")], check=True)

def build_cuda():
    sh(["nvcc","-O3","-arch=sm_80", str(HERE/"cuda/matmul.cu"),
        "-o", str(HERE/"cuda/matmul_cuda")], check=True)

def run_bin(path, M, N, K, warmup, iters):
    p = sh([path, M, N, K, warmup, iters], cwd=str(HERE/"crisp"), capture_output=True, text=True)
    try:
        return json.loads(p.stdout)
    except Exception:
        print(p.stdout, p.stderr, file=sys.stderr); return None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sizes", default="256,512,1024")
    ap.add_argument("--warmup", default="20"); ap.add_argument("--iters", default="100")
    ap.add_argument("--impl", default="all")
    a = ap.parse_args()

    if a.impl in ("all","crisp"): build_crisp()
    if a.impl in ("all","cuda"):  build_cuda()

    print(f"{'size':>14} {'crisp us':>10} {'crisp GF':>10} {'cuda us':>10} {'cuda GF':>10} {'crisp/cuda':>11} {'ok':>4}")
    for s in a.sizes.split(","):
        S = int(s); M=N=K=S
        cr = run_bin(HERE/"crisp/matmul_crisp", M,N,K,a.warmup,a.iters) if a.impl in ("all","crisp") else None
        cu = run_bin(HERE/"cuda/matmul_cuda",  M,N,K,a.warmup,a.iters) if a.impl in ("all","cuda") else None
        crus = cr["kernel_median_us"] if cr else float("nan")
        cuus = cu["kernel_median_us"] if cu else float("nan")
        ratio = (crus/cuus) if (cr and cu and cuus) else float("nan")
        ok = all(x is None or x.get("correct") for x in (cr,cu))
        print(f"{S}x{S}x{S:>6} {crus:>10.1f} {cr['gflops'] if cr else 0:>10.1f} "
              f"{cuus:>10.1f} {cu['gflops'] if cu else 0:>10.1f} {ratio:>11.2f} {str(ok):>4}")

if __name__ == "__main__":
    main()
