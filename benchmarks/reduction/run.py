#!/usr/bin/env python3
"""
Sum reduction benchmark driver.

Builds and runs all implementations (cuda, cub, crisp) for multiple problem
sizes, collects JSON timing results, and prints a comparison table.

Usage:
  python run.py [--sizes=1K,100K,1M] [--warmup=50] [--iters=100] [--impl=all]

Prerequisites (on the machine where this runs):
  - nvcc on PATH
  - crisp-compile and crisp-hoist-cuda on PATH or in ../../bin/
  - CUDA GPU

Output: JSON files in ../results/ and a summary table to stdout.
"""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
RESULTS_DIR = SCRIPT_DIR.parent / "results"
BIN_DIR = SCRIPT_DIR.parent.parent / "bin"

SIZES = {
    "1K": 1_000,
    "10K": 10_000,
    "100K": 100_000,
    "1M": 1_000_000,
    "10M": 10_000_000,
}


def find_executable(name):
    """Find an executable on PATH or in the project bin/ directory."""
    import shutil
    on_path = shutil.which(name)
    if on_path:
        return on_path
    candidate = BIN_DIR / name
    if candidate.exists():
        return str(candidate)
    return None


def build_cuda(impl_dir, binary_name):
    """Compile a .cu file with nvcc -O3."""
    cu_files = list(impl_dir.glob("*.cu"))
    if not cu_files:
        print(f"  SKIP: no .cu files in {impl_dir}")
        return None
    cu = cu_files[0]
    out = impl_dir / binary_name
    cmd = ["nvcc", "-O3", str(cu), "-o", str(out)]
    print(f"  Building: {' '.join(cmd)}")
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  BUILD FAILED:\n{r.stderr}")
        return None
    return str(out)


def build_crisp(crisp_dir):
    """Compile Crisp kernel to PTX, then build the benchmark harness."""
    crisp_files = list(crisp_dir.glob("*.crisp"))
    if not crisp_files:
        print(f"  SKIP: no .crisp files in {crisp_dir}")
        return None
    crisp_file = crisp_files[0]

    compiler = find_executable("crisp-compile")
    if not compiler:
        compiler = find_executable("crisp-compile.exe")
    if not compiler:
        print("  SKIP: crisp-compile not found")
        return None

    # Compile to PTX only (no hoist needed — we use the custom bench harness)
    cmd = [compiler, "--ir-target=ptx", str(crisp_file)]
    print(f"  Crisp compile: {' '.join(cmd)}")
    r = subprocess.run(cmd, capture_output=True, text=True,
                       env={**os.environ, "CRISP_USE_SYSTEM_TOOLS": "true"})
    if r.returncode != 0:
        print(f"  CRISP COMPILE FAILED:\n{r.stderr}")
        return None

    # Verify PTX was generated
    ptx = crisp_dir / "sum-reduce.ptx"
    if not ptx.exists():
        print(f"  SKIP: {ptx} not generated")
        return None

    # Build the benchmark harness (loads PTX at runtime)
    harness = crisp_dir / "bench_harness.cu"
    out = crisp_dir / "sum_reduce_crisp"
    cmd = ["nvcc", "-O3", str(harness), "-lcuda", "-o", str(out)]
    print(f"  nvcc harness: {' '.join(cmd)}")
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  NVCC FAILED:\n{r.stderr}")
        return None
    return str(out)


def run_benchmark(binary, N, warmup, iterations, impl_name):
    """Run a benchmark binary and parse its JSON output."""
    cmd = [binary, str(N), str(warmup), str(iterations)]
    print(f"  Running: {impl_name} N={N} ... ", end="", flush=True)
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    if r.returncode != 0:
        print(f"FAIL (exit {r.returncode})")
        if r.stderr:
            print(f"    stderr: {r.stderr[:200]}")
        return None
    try:
        result = json.loads(r.stdout)
        print(f"{result.get('kernel_median_us', '?')} us (median)")
        return result
    except json.JSONDecodeError:
        print(f"FAIL (bad JSON)")
        print(f"    stdout: {r.stdout[:200]}")
        return None


def print_comparison_table(all_results):
    """Print a summary comparison table."""
    if not all_results:
        print("\nNo results to compare.")
        return

    # Group by N
    by_n = {}
    for r in all_results:
        n = r["N"]
        if n not in by_n:
            by_n[n] = {}
        by_n[n][r["implementation"]] = r

    impls = sorted(set(r["implementation"] for r in all_results))

    # Header
    print("\n" + "=" * 80)
    print("Sum Reduction Benchmark Comparison")
    print("=" * 80)
    header = f"{'N':>10s}"
    for impl in impls:
        header += f"  {impl:>12s} (us)"
        header += f"  {impl:>8s} GB/s"
    print(header)
    print("-" * len(header))

    for n in sorted(by_n.keys()):
        row = f"{n:>10d}"
        for impl in impls:
            r = by_n[n].get(impl)
            if r:
                row += f"  {r['kernel_median_us']:>16.2f}"
                row += f"  {r['throughput_gb_s']:>11.2f}"
            else:
                row += f"  {'---':>16s}"
                row += f"  {'---':>11s}"
        print(row)
    print()


def main():
    parser = argparse.ArgumentParser(description="Sum reduction benchmark")
    parser.add_argument("--sizes", default="1K,100K,1M",
                        help="Comma-separated problem sizes (e.g. 1K,100K,1M,10M)")
    parser.add_argument("--warmup", type=int, default=50)
    parser.add_argument("--iters", type=int, default=100)
    parser.add_argument("--impl", default="all",
                        help="Implementations to run: all, cuda, cub, crisp")
    args = parser.parse_args()

    sizes = []
    for s in args.sizes.split(","):
        s = s.strip().upper()
        if s in SIZES:
            sizes.append(SIZES[s])
        else:
            sizes.append(int(s))

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)

    run_impls = args.impl.split(",") if args.impl != "all" else ["cuda", "cub", "crisp"]

    # Build phase
    binaries = {}
    print("=== Build phase ===")

    if "cuda" in run_impls:
        print("Building CUDA hand-written...")
        b = build_cuda(SCRIPT_DIR / "cuda", "sum_reduce")
        if b:
            binaries["cuda"] = b

    if "cub" in run_impls:
        print("Building CUB...")
        b = build_cuda(SCRIPT_DIR / "cub", "sum_reduce_cub")
        if b:
            binaries["cub"] = b

    if "crisp" in run_impls:
        print("Building Crisp...")
        b = build_crisp(SCRIPT_DIR / "crisp")
        if b:
            binaries["crisp"] = b

    if not binaries:
        print("No implementations built successfully. Exiting.")
        return 1

    # Run phase
    print("\n=== Benchmark phase ===")
    all_results = []

    for N in sizes:
        for impl_name, binary in binaries.items():
            result = run_benchmark(binary, N, args.warmup, args.iters, impl_name)
            if result:
                all_results.append(result)
                # Save individual result
                fname = f"reduction_{impl_name}_N{N}.json"
                with open(RESULTS_DIR / fname, "w") as f:
                    json.dump(result, f, indent=2)

    # Comparison
    print_comparison_table(all_results)

    return 0


if __name__ == "__main__":
    sys.exit(main())
