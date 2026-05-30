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
import re
import subprocess
import sys
import time
from pathlib import Path


def extract_occupancy_from_crisp(crisp_file):
    """Parse a .crisp file for :occupancy <ratio> in a global-size declaration.
    Returns the float value, or 1.0 if not found.

    NOTE: This is a regex on the source file — brittle in the abstract.
    We do it this way because:

      - The bench harness uses its OWN occupancy logic (not the auto-generated
        hoist .cu), so it needs the value at launch time.
      - The proper-but-heavier alternative is `--metadata` + s-expression parsing
        of the .metacrisp file via sbcl-from-python.  Overkill for one number.
      - The .crisp dispatch syntax is documented and stable (see
        docs/chapters/14_control_flow/07_hoisting_and_enqueing_a_kernel.md).

    If you change the dispatch declaration syntax, update this regex too.
    The pattern is intentionally tolerant of whitespace and accepts plain
    decimals (no scientific notation, which the spec doesn't allow anyway).
    """
    pattern = re.compile(r':occupancy\s+([0-9]+(?:\.[0-9]+)?)')
    try:
        content = Path(crisp_file).read_text()
    except OSError:
        return 1.0
    m = pattern.search(content)
    if m:
        return float(m.group(1))
    return 1.0

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


def build_cuda(impl_dir, binary_name, cu_name=None):
    """Compile a .cu file with nvcc -O3. Returns (binary_path, compile_time_s)."""
    if cu_name:
        cu = impl_dir / cu_name
    else:
        cu_files = list(impl_dir.glob("*.cu"))
        if not cu_files:
            print(f"  SKIP: no .cu files in {impl_dir}")
            return None, 0.0
        cu = cu_files[0]
    out = impl_dir / binary_name
    cmd = ["nvcc", "-O3", str(cu), "-o", str(out)]
    print(f"  Building: {' '.join(cmd)}")
    t0 = time.monotonic()
    r = subprocess.run(cmd, capture_output=True, text=True)
    compile_time = time.monotonic() - t0
    if r.returncode != 0:
        print(f"  BUILD FAILED:\n{r.stderr}")
        return None, compile_time
    print(f"  Compiled in {compile_time:.2f}s")
    return str(out), compile_time


def build_crisp_variant(crisp_dir, crisp_filename, ptx_filename, harness_filename, binary_name):
    """Compile one Crisp kernel + its harness.  Returns (binary_path, compile_time_s).
    compile_time measures crisp-compile only (not nvcc for the harness)."""
    crisp_file = crisp_dir / crisp_filename
    if not crisp_file.exists():
        print(f"  SKIP: {crisp_file} not found")
        return None, 0.0

    compiler = find_executable("crisp-compile") or find_executable("crisp-compile.exe")
    if not compiler:
        print("  SKIP: crisp-compile not found")
        return None, 0.0

    cmd = [compiler, "--ir-target=ptx", str(crisp_file)]
    print(f"  Crisp compile [{crisp_filename}]: {' '.join(cmd)}")
    t0 = time.monotonic()
    r = subprocess.run(cmd, capture_output=True, text=True,
                       env={**os.environ, "CRISP_USE_SYSTEM_TOOLS": "true"})
    crisp_compile_time = time.monotonic() - t0
    if r.returncode != 0:
        print(f"  CRISP COMPILE FAILED:\n{r.stderr}")
        return None, crisp_compile_time
    print(f"  Crisp compiled in {crisp_compile_time:.2f}s")

    ptx = crisp_dir / ptx_filename
    if not ptx.exists():
        print(f"  SKIP: {ptx} not generated")
        return None, crisp_compile_time

    harness = crisp_dir / harness_filename
    out = crisp_dir / binary_name
    cmd = ["nvcc", "-O3", str(harness), "-lcuda", "-o", str(out)]
    print(f"  nvcc harness: {' '.join(cmd)}")
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  NVCC FAILED:\n{r.stderr}")
        return None, crisp_compile_time
    return str(out), crisp_compile_time


def build_crisp(crisp_dir):
    """Naive grid-stride + atomic-per-thread version."""
    return build_crisp_variant(
        crisp_dir, "sum-reduce.crisp", "sum-reduce.ptx",
        "bench_harness.cu", "sum_reduce_crisp")


def build_crisp_tree(crisp_dir):
    """Workgroup tree-reduce + one atomic per workgroup version."""
    return build_crisp_variant(
        crisp_dir, "sum-reduce-tree.crisp", "sum-reduce-tree.ptx",
        "bench_harness_tree.cu", "sum_reduce_crisp_tree")


def run_benchmark(binary, N, warmup, iterations, impl_name, extra_args=None):
    """Run a benchmark binary and parse its JSON output.
    extra_args: optional list of extra positional args appended after iterations."""
    cmd = [binary, str(N), str(warmup), str(iterations)]
    if extra_args:
        cmd.extend(str(a) for a in extra_args)
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


def print_comparison_table(all_results, compile_times=None):
    """Print a summary comparison table."""
    if not all_results:
        print("\nNo results to compare.")
        return

    by_n = {}
    for r in all_results:
        n = r["N"]
        if n not in by_n:
            by_n[n] = {}
        by_n[n][r["implementation"]] = r

    impls = sorted(set(r["implementation"] for r in all_results))

    # Compile times
    if compile_times:
        print("\n" + "=" * 60)
        print("Compile Times")
        print("=" * 60)
        for impl in impls:
            ct = compile_times.get(impl, 0)
            print(f"  {impl:>8s}: {ct:.2f}s")
        print()

    # Kernel time table
    print("=" * 100)
    print("Kernel Time (GPU hardware events, excludes host overhead)")
    print("=" * 100)
    header = f"{'N':>10s}"
    for impl in impls:
        header += f"  {impl+' (us)':>14s}"
        header += f"  {impl+' GB/s':>11s}"
    print(header)
    print("-" * len(header))
    for n in sorted(by_n.keys()):
        row = f"{n:>10d}"
        for impl in impls:
            r = by_n[n].get(impl)
            if r:
                row += f"  {r['kernel_median_us']:>14.2f}"
                row += f"  {r['throughput_gb_s']:>11.2f}"
            else:
                row += f"  {'---':>14s}"
                row += f"  {'---':>11s}"
        print(row)

    # Wall time table (if available)
    has_wall = any("wall_median_us" in r for r in all_results)
    if has_wall:
        print()
        print("=" * 70)
        print("Wall Time (includes kernel + sync + D→H readback)")
        print("=" * 70)
        header = f"{'N':>10s}"
        for impl in impls:
            header += f"  {impl+' (us)':>14s}"
        print(header)
        print("-" * len(header))
        for n in sorted(by_n.keys()):
            row = f"{n:>10d}"
            for impl in impls:
                r = by_n[n].get(impl)
                if r and "wall_median_us" in r:
                    row += f"  {r['wall_median_us']:>14.2f}"
                else:
                    row += f"  {'---':>14s}"
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
    parser.add_argument("--crisp-tree-occupancy", type=float, default=None,
                        help="Occupancy ratio (0.0..1.0) for crisp_tree grid sizing. "
                             "Default: read :occupancy from the .crisp file (falls back to 1.0).")
    args = parser.parse_args()

    sizes = []
    for s in args.sizes.split(","):
        s = s.strip().upper()
        if s in SIZES:
            sizes.append(SIZES[s])
        else:
            sizes.append(int(s))

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)

    run_impls = args.impl.split(",") if args.impl != "all" else ["cuda", "cub", "crisp", "crisp_tree"]

    # Build phase
    binaries = {}
    compile_times = {}
    print("=== Build phase ===")

    if "cuda" in run_impls:
        print("Building CUDA hand-written...")
        b, ct = build_cuda(SCRIPT_DIR / "cuda", "sum_reduce", "sum_reduce.cu")
        if b:
            binaries["cuda"] = b
            compile_times["cuda"] = ct

    if "cub" in run_impls:
        print("Building CUB...")
        b, ct = build_cuda(SCRIPT_DIR / "cub", "sum_reduce_cub", "sum_reduce_cub.cu")
        if b:
            binaries["cub"] = b
            compile_times["cub"] = ct

    if "crisp" in run_impls:
        print("Building Crisp (atomic-per-thread)...")
        b, ct = build_crisp(SCRIPT_DIR / "crisp")
        if b:
            binaries["crisp"] = b
            compile_times["crisp"] = ct

    if "crisp_tree" in run_impls:
        print("Building Crisp (workgroup tree-reduce)...")
        b, ct = build_crisp_tree(SCRIPT_DIR / "crisp")
        if b:
            binaries["crisp_tree"] = b
            compile_times["crisp_tree"] = ct

    if not binaries:
        print("No implementations built successfully. Exiting.")
        return 1

    # Run phase
    print("\n=== Benchmark phase ===")
    all_results = []

    # Resolve occupancy (shared between crisp_tree and cuda):
    #   CLI flag overrides; otherwise read from the .crisp file.
    # This keeps a single source of truth (the .crisp file's :occupancy
    # declaration) while still allowing ad-hoc sweeps from the command line.
    # The cuda reference uses the SAME occupancy as crisp_tree so the
    # comparison is "same algorithm, same launch policy, different language".
    if args.crisp_tree_occupancy is not None:
        shared_occupancy = args.crisp_tree_occupancy
        print(f"\nOccupancy: {shared_occupancy} (from --crisp-tree-occupancy CLI flag, "
              f"applied to both crisp_tree and cuda)")
    else:
        shared_occupancy = extract_occupancy_from_crisp(
            SCRIPT_DIR / "crisp" / "sum-reduce-tree.crisp")
        print(f"\nOccupancy: {shared_occupancy} (parsed from sum-reduce-tree.crisp, "
              f"applied to both crisp_tree and cuda)")

    for N in sizes:
        for impl_name, binary in binaries.items():
            extra = None
            if impl_name in ("crisp_tree", "cuda"):
                extra = [shared_occupancy]
            result = run_benchmark(binary, N, args.warmup, args.iters, impl_name, extra_args=extra)
            if result:
                all_results.append(result)
                # Save individual result
                fname = f"reduction_{impl_name}_N{N}.json"
                with open(RESULTS_DIR / fname, "w") as f:
                    json.dump(result, f, indent=2)

    # Comparison
    print_comparison_table(all_results, compile_times)

    return 0


if __name__ == "__main__":
    sys.exit(main())
