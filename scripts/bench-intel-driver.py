#!/usr/bin/env python3
"""
Intel benchmark driver (runs inside the Docker container).

Mirrors benchmarks/<algo>/run.py (the NVIDIA driver) for the Intel side.
Compiles all Intel impls (crisp, sycl, onedpl) for the requested algorithm,
runs warmup + measured iterations per (impl, N) cell, and prints a
comparison table to stdout.

Phase A scope: crisp only.  SYCL and oneDPL added in Phase B/C.

Usage (inside container):
  python3 scripts/bench-intel-driver.py <algo> [--sizes=...] [--iters=...]

Invoked from outside via scripts/bench-intel.sh.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
BIN_DIR   = REPO_ROOT / "bin"

SIZES = {
    "1K": 1_000,
    "10K": 10_000,
    "100K": 100_000,
    "1M": 1_000_000,
    "10M": 10_000_000,
}


def extract_occupancy_from_crisp(crisp_file):
    """Parse :occupancy <ratio> from a .crisp source file (same regex as
    benchmarks/reduction/run.py).  Falls back to 1.0."""
    pattern = re.compile(r":occupancy\s+([0-9]+(?:\.[0-9]+)?)")
    try:
        m = pattern.search(Path(crisp_file).read_text())
        return float(m.group(1)) if m else 1.0
    except OSError:
        return 1.0


def find_executable(name):
    on_path = shutil.which(name)
    if on_path:
        return on_path
    candidate = BIN_DIR / name
    return str(candidate) if candidate.exists() else None


# ----------------------------------------------------------------------
# Per-algorithm metadata.
#
# Each algorithm needs to know, for each Intel impl:
#   - source dir
#   - source file(s) to compile
#   - kernel name (for Crisp .spv loading)
#   - output binary name
#
# Right now we only define reduction.  Add more as new algorithms come on.
# ----------------------------------------------------------------------
ALGORITHMS = {
    "reduction": {
        "crisp": {
            "dir":          REPO_ROOT / "benchmarks" / "reduction" / "crisp",
            "crisp_source": "sum-reduce.crisp",
            "spv_name":     "sum-reduce.spv",
            "harness":      "bench_harness_l0.cpp",
            "binary":       "sum_reduce_crisp_l0",
        },
        "sycl": {
            "dir":    REPO_ROOT / "benchmarks" / "reduction" / "sycl",
            "source": "sum_reduce.cpp",
            "binary": "sum_reduce_sycl",
        },
        "onedpl": {
            "dir":    REPO_ROOT / "benchmarks" / "reduction" / "onedpl",
            "source": "sum_reduce.cpp",
            "binary": "sum_reduce_onedpl",
        },
    },
}


def build_sycl(algo_meta):
    """Compile the SYCL DPC++ reference via icpx -fsycl -O3.
    Returns (binary_path, compile_times_dict) or (None, ...) on failure.

    The 'device' compile-time here is icpx's -fsycl-host-compiler-only or
    -fsycl-device-only.  We don't bother splitting — icpx is a unified
    compile path and reporting one number (end_to_end) keeps the table
    honest; device-only is reported as 0 to match the Crisp/CUDA shape."""
    impl   = algo_meta["sycl"]
    src    = impl["dir"] / impl["source"]
    binary = impl["dir"] / impl["binary"]
    if not src.exists():
        print(f"  SKIP: {src} not found")
        return None, {"device": 0.0, "end_to_end": 0.0}

    cmd = ["icpx", "-fsycl", "-O3", str(src), "-o", str(binary)]
    print(f"  Building: {' '.join(cmd)}")
    t0 = time.monotonic()
    r = subprocess.run(cmd, capture_output=True, text=True)
    e2e = time.monotonic() - t0
    if r.returncode != 0:
        print(f"  BUILD FAILED:\n{r.stderr[:600]}")
        return None, {"device": 0.0, "end_to_end": e2e}
    print(f"  Compiled in {e2e:.2f}s")
    return str(binary), {"device": 0.0, "end_to_end": e2e}


def build_crisp_l0(algo_meta):
    """Compile a Crisp kernel to SPV, then build the L0 harness via icpx.
    Returns (binary_path, compile_times_dict) or (None, ...) on failure."""
    impl = algo_meta["crisp"]
    crisp_dir   = impl["dir"]
    crisp_file  = crisp_dir / impl["crisp_source"]
    spv_file    = crisp_dir / impl["spv_name"]
    harness_cpp = crisp_dir / impl["harness"]
    binary      = crisp_dir / impl["binary"]

    if not crisp_file.exists():
        print(f"  SKIP: {crisp_file} not found")
        return None, {"device": 0.0, "end_to_end": 0.0}

    compiler = find_executable("crisp-compile") or find_executable("crisp-compile.exe")
    if not compiler:
        print("  SKIP: crisp-compile not found")
        return None, {"device": 0.0, "end_to_end": 0.0}

    # Phase 1: Crisp source -> SPV (device-only compile time).
    # We deliberately skip --hoist=l0 — the bench harness does its own
    # L0 setup, and the L0 hoist's launcher.cpp doesn't yet support
    # :match-workgroup-size scratch tensors (which the reduction kernel
    # uses).  Bypassing the hoist avoids that limitation entirely.
    cmd_crisp = [compiler, "--ir-target=spv", str(crisp_file)]
    print(f"  Crisp compile: {' '.join(cmd_crisp)}")
    t0 = time.monotonic()
    r = subprocess.run(cmd_crisp, capture_output=True, text=True,
                       env={**os.environ, "CRISP_USE_SYSTEM_TOOLS": "true"})
    crisp_time = time.monotonic() - t0
    if r.returncode != 0:
        print(f"  CRISP COMPILE FAILED:\n{r.stderr}")
        return None, {"device": crisp_time, "end_to_end": crisp_time}
    print(f"  Crisp compiled in {crisp_time:.2f}s")
    if not spv_file.exists():
        print(f"  SKIP: {spv_file} not generated")
        return None, {"device": crisp_time, "end_to_end": crisp_time}

    # Phase 2: harness compile via icpx (end-to-end build time)
    cmd_icpx = ["icpx", "-O3", str(harness_cpp), "-lze_loader", "-o", str(binary)]
    print(f"  Harness compile: {' '.join(cmd_icpx)}")
    t0 = time.monotonic()
    r = subprocess.run(cmd_icpx, capture_output=True, text=True)
    harness_time = time.monotonic() - t0
    if r.returncode != 0:
        print(f"  HARNESS COMPILE FAILED:\n{r.stderr}")
        return None, {"device": crisp_time, "end_to_end": crisp_time + harness_time}
    end_to_end = crisp_time + harness_time
    print(f"  Total {end_to_end:.2f}s (device-only: {crisp_time:.2f}s + harness: {harness_time:.2f}s)")
    return str(binary), {"device": crisp_time, "end_to_end": end_to_end}


def run_benchmark(binary, N, warmup, iters, impl_name, extra_args=None):
    """Run a benchmark binary and parse JSON output from stdout."""
    cmd = [binary, str(N), str(warmup), str(iters)]
    if extra_args:
        cmd.extend(str(a) for a in extra_args)
    print(f"  Running: {impl_name} N={N} ... ", end="", flush=True)
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=300,
                       cwd=str(Path(binary).parent))
    if r.returncode != 0:
        print(f"FAIL (exit {r.returncode})")
        if r.stderr:
            print(f"    stderr: {r.stderr[:400]}")
        return None
    try:
        result = json.loads(r.stdout)
        print(f"{result.get('kernel_median_us', '?')} us (median)")
        return result
    except json.JSONDecodeError:
        print("FAIL (bad JSON)")
        print(f"    stdout: {r.stdout[:400]}")
        return None


def print_comparison_table(all_results, compile_times):
    """Print the same shape of table the NVIDIA run.py prints, so the
    output reads identically across platforms."""
    if not all_results:
        print("\nNo results to compare.")
        return

    by_n = {}
    for r in all_results:
        by_n.setdefault(r["N"], {})[r["implementation"]] = r
    impls = sorted({r["implementation"] for r in all_results})

    if compile_times:
        print("\n" + "=" * 60)
        print("Compile Times")
        print("=" * 60)
        print(f"  {'impl':>10s}   {'device (s)':>12s}   {'end-to-end (s)':>16s}")
        print(f"  {'-'*10}   {'-'*12}   {'-'*16}")
        for impl in impls:
            ct = compile_times.get(impl, {})
            d  = ct.get("device", 0.0) if isinstance(ct, dict) else ct
            e  = ct.get("end_to_end", 0.0) if isinstance(ct, dict) else ct
            print(f"  {impl:>10s}   {d:>12.2f}   {e:>16.2f}")
        print()

    print("=" * 100)
    print("Kernel Time (GPU hardware events, excludes host overhead)")
    print("=" * 100)
    header = f"{'N':>10s}"
    for impl in impls:
        header += f"  {impl+' (us)':>14s}  {impl+' GB/s':>11s}"
    print(header)
    print("-" * len(header))
    for n in sorted(by_n):
        row = f"{n:>10d}"
        for impl in impls:
            r = by_n[n].get(impl)
            if r:
                row += f"  {r['kernel_median_us']:>14.2f}  {r['throughput_gb_s']:>11.2f}"
            else:
                row += f"  {'---':>14s}  {'---':>11s}"
        print(row)

    has_wall = any("wall_median_us" in r for r in all_results)
    if has_wall:
        print()
        print("=" * 70)
        print("Wall Time (includes kernel + sync + readback)")
        print("=" * 70)
        header = f"{'N':>10s}"
        for impl in impls:
            header += f"  {impl+' (us)':>14s}"
        print(header)
        print("-" * len(header))
        for n in sorted(by_n):
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
    parser = argparse.ArgumentParser(description="Intel benchmark driver (Docker-side)")
    parser.add_argument("algo", help="Algorithm name (e.g. reduction)")
    parser.add_argument("--sizes",  default="1K,100K,1M")
    parser.add_argument("--warmup", type=int, default=50)
    parser.add_argument("--iters",  type=int, default=100)
    parser.add_argument("--impl",   default="all",
                        help="Comma-separated impl list, or 'all' (default).")
    parser.add_argument("--occupancy", type=float, default=None,
                        help="Override occupancy ratio (0.0..1.0) for impls that "
                             "take one (crisp, sycl).  Default: read :occupancy "
                             "from the .crisp source file.")
    args = parser.parse_args()

    if args.algo not in ALGORITHMS:
        print(f"Unknown algorithm: {args.algo}")
        print(f"Available: {', '.join(ALGORITHMS.keys())}")
        return 1
    algo_meta = ALGORITHMS[args.algo]

    sizes = []
    for s in args.sizes.split(","):
        s = s.strip().upper()
        sizes.append(SIZES[s] if s in SIZES else int(s))

    available_impls = list(algo_meta.keys())
    run_impls = args.impl.split(",") if args.impl != "all" else available_impls

    binaries = {}
    compile_times = {}
    print("=== Build phase ===")

    if "crisp" in run_impls and "crisp" in algo_meta:
        print("Building Crisp (L0 backend)...")
        b, ct = build_crisp_l0(algo_meta)
        if b:
            binaries["crisp"] = b
            compile_times["crisp"] = ct

    if "sycl" in run_impls and "sycl" in algo_meta:
        print("Building SYCL hand-written...")
        b, ct = build_sycl(algo_meta)
        if b:
            binaries["sycl"] = b
            compile_times["sycl"] = ct

    if "onedpl" in run_impls and "onedpl" in algo_meta:
        print("Building oneDPL...")
        # Same compile path as the SYCL hand-written impl — icpx -fsycl -O3.
        # build_sycl is parametric on the impl dict so we reuse it.
        b, ct = build_sycl({"sycl": algo_meta["onedpl"]})
        if b:
            binaries["onedpl"] = b
            compile_times["onedpl"] = ct

    if not binaries:
        print("No impls built successfully. Exiting.")
        return 1

    print("\n=== Benchmark phase ===")

    # Occupancy: CLI override wins; otherwise read from the Crisp source
    # (single source of truth).  Passed to all impls that take one.
    occupancy = None
    crisp_meta = algo_meta.get("crisp")
    if args.occupancy is not None:
        occupancy = args.occupancy
        print(f"\nOccupancy: {occupancy} (from --occupancy CLI override)")
    elif crisp_meta:
        occupancy = extract_occupancy_from_crisp(
            crisp_meta["dir"] / crisp_meta["crisp_source"])
        print(f"\nOccupancy: {occupancy} (parsed from {crisp_meta['crisp_source']})")

    all_results = []
    for N in sizes:
        for impl_name, binary in binaries.items():
            extra = [occupancy] if occupancy is not None and impl_name in ("crisp", "sycl") else None
            r = run_benchmark(binary, N, args.warmup, args.iters, impl_name, extra_args=extra)
            if r:
                all_results.append(r)

    print_comparison_table(all_results, compile_times)
    return 0


if __name__ == "__main__":
    sys.exit(main())
