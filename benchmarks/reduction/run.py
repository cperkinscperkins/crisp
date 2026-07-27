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
    """Compile a .cu file with nvcc -O3.
    Returns (binary_path, compile_times) where compile_times is a dict:
      {'device': float,    # nvcc -ptx -O3 only (kernel compile)
       'end_to_end': float} # nvcc -O3 full build (kernel + host link)

    The 'device' number is fair to compare against Crisp's crisp-compile
    (both produce just the device-side PTX).  The 'end_to_end' number is
    fair to compare against Crisp's crisp-compile + nvcc-on-harness."""
    if cu_name:
        cu = impl_dir / cu_name
    else:
        cu_files = list(impl_dir.glob("*.cu"))
        if not cu_files:
            print(f"  SKIP: no .cu files in {impl_dir}")
            return None, {'device': 0.0, 'end_to_end': 0.0}
        cu = cu_files[0]
    out = impl_dir / binary_name

    # Device-only timing: nvcc -ptx -O3
    ptx_out = impl_dir / (cu.stem + ".ptx")
    cmd_ptx = ["nvcc", "-O3", "-ptx", str(cu), "-o", str(ptx_out)]
    t0 = time.monotonic()
    r_ptx = subprocess.run(cmd_ptx, capture_output=True, text=True)
    device_time = time.monotonic() - t0

    # End-to-end timing: nvcc -O3 (full executable)
    cmd_full = ["nvcc", "-O3", str(cu), "-o", str(out)]
    print(f"  Building: {' '.join(cmd_full)}")
    t0 = time.monotonic()
    r = subprocess.run(cmd_full, capture_output=True, text=True)
    end_to_end_time = time.monotonic() - t0
    if r.returncode != 0:
        print(f"  BUILD FAILED:\n{r.stderr}")
        return None, {'device': device_time, 'end_to_end': end_to_end_time}
    print(f"  Compiled in {end_to_end_time:.2f}s (device-only: {device_time:.2f}s)")
    return str(out), {'device': device_time, 'end_to_end': end_to_end_time}


def build_crisp_variant(crisp_dir, crisp_filename, ptx_filename, harness_filename, binary_name):
    """Compile one Crisp kernel + its harness.
    Returns (binary_path, compile_times) where compile_times is a dict:
      {'device': float,    # crisp-compile only (PTX kernel)
       'end_to_end': float} # crisp-compile + nvcc on harness"""
    crisp_file = crisp_dir / crisp_filename
    if not crisp_file.exists():
        print(f"  SKIP: {crisp_file} not found")
        return None, {'device': 0.0, 'end_to_end': 0.0}

    compiler = find_executable("crisp-compile") or find_executable("crisp-compile.exe")
    if not compiler:
        print("  SKIP: crisp-compile not found")
        return None, {'device': 0.0, 'end_to_end': 0.0}

    cmd = [compiler, "--ir-target=ptx", str(crisp_file)]
    print(f"  Crisp compile [{crisp_filename}]: {' '.join(cmd)}")
    t0 = time.monotonic()
    r = subprocess.run(cmd, capture_output=True, text=True,
                       env={**os.environ, "CRISP_USE_SYSTEM_TOOLS": "true"})
    crisp_compile_time = time.monotonic() - t0
    if r.returncode != 0:
        print(f"  CRISP COMPILE FAILED:\n{r.stderr}")
        return None, {'device': crisp_compile_time, 'end_to_end': crisp_compile_time}
    print(f"  Crisp compiled in {crisp_compile_time:.2f}s")

    ptx = crisp_dir / ptx_filename
    if not ptx.exists():
        print(f"  SKIP: {ptx} not generated")
        return None, {'device': crisp_compile_time, 'end_to_end': crisp_compile_time}

    harness = crisp_dir / harness_filename
    out = crisp_dir / binary_name
    cmd = ["nvcc", "-O3", str(harness), "-lcuda", "-o", str(out)]
    print(f"  nvcc harness: {' '.join(cmd)}")
    t0 = time.monotonic()
    r = subprocess.run(cmd, capture_output=True, text=True)
    harness_compile_time = time.monotonic() - t0
    if r.returncode != 0:
        print(f"  NVCC FAILED:\n{r.stderr}")
        return None, {'device': crisp_compile_time, 'end_to_end': crisp_compile_time}
    end_to_end = crisp_compile_time + harness_compile_time
    print(f"  Total {end_to_end:.2f}s (device-only: {crisp_compile_time:.2f}s + harness: {harness_compile_time:.2f}s)")
    return str(out), {'device': crisp_compile_time, 'end_to_end': end_to_end}


def build_crisp(crisp_dir):
    """Workgroup tree-reduce + one atomic per workgroup version
    (the only Crisp variant we ship in this benchmark)."""
    return build_crisp_variant(
        crisp_dir, "sum-reduce.crisp", "sum-reduce.ptx",
        "bench_harness.cu", "sum_reduce_crisp")


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

    # Compile times — two columns:
    #   device:     just the kernel device compile (nvcc -ptx for CUDA/CUB; crisp-compile for Crisp).
    #   end-to-end: full source-to-executable build (CUDA/CUB nvcc; Crisp + nvcc-on-harness for Crisp).
    if compile_times:
        print("\n" + "=" * 60)
        print("Compile Times")
        print("=" * 60)
        print(f"  {'impl':>10s}   {'device (s)':>12s}   {'end-to-end (s)':>16s}")
        print(f"  {'-'*10}   {'-'*12}   {'-'*16}")
        for impl in impls:
            ct = compile_times.get(impl, {})
            if isinstance(ct, dict):
                device = ct.get('device', 0.0)
                e2e    = ct.get('end_to_end', 0.0)
            else:
                # Backwards compat for the old single-float schema
                device = ct
                e2e = ct
            print(f"  {impl:>10s}   {device:>12.2f}   {e2e:>16.2f}")
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


# ----------------------------------------------------------------------
# Occupancy auto-tune (sibling of bench-intel-driver.py's logic).
#
# Resolution order (most specific wins):
#   1. --crisp-tree-occupancy=X on the CLI         (explicit override)
#   2. --tune flag                                 (sweep fresh, cache, use)
#   3. cache entry for the device we just probed   (use, don't sweep)
#   4. :occupancy declaration in sum-reduce.crisp  (existing default)
#   5. 1.0
#
# Cache: benchmarks/reduction/.tune-cache.json, keyed by device name.
# Same file the Intel driver uses — different device names live as
# different top-level keys, so they don't collide.
# Sweep impl: Crisp (CUDA reference picks up the same value).
# Picker: fastest single occupancy.
# ----------------------------------------------------------------------

TUNE_OCCUPANCIES = [0.10, 0.15, 0.25, 0.50, 0.75, 1.00]
TUNE_N           = 1_000_000
TUNE_WARMUP      = 100
TUNE_ITERS       = 200

TUNE_CACHE_PATH = SCRIPT_DIR / ".tune-cache.json"


def load_tune_cache():
    if not TUNE_CACHE_PATH.exists():
        return {}
    try:
        return json.loads(TUNE_CACHE_PATH.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def save_tune_cache(cache):
    TUNE_CACHE_PATH.write_text(json.dumps(cache, indent=2) + "\n")


def probe_device_name(binary):
    """Run a tiny harness invocation to read 'Device: ...' off stderr."""
    try:
        r = subprocess.run([binary, "10000", "5", "10", "0.5"],
                           capture_output=True, text=True, timeout=60)
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return ""
    for line in r.stderr.splitlines():
        if line.startswith("Device:"):
            return line.split(":", 1)[1].strip()
    return ""


def tune_occupancy(crisp_binary):
    """Sweep occupancies, return (best_occ, sample_dict)."""
    print(f"\n=== Tuning occupancy on local hardware "
          f"(N={TUNE_N}, {TUNE_ITERS} iters per probe) ===")
    results = []
    for occ in TUNE_OCCUPANCIES:
        print(f"  probe occupancy={occ:>4.2f} ...", end="", flush=True)
        try:
            r = subprocess.run(
                [crisp_binary, str(TUNE_N), str(TUNE_WARMUP), str(TUNE_ITERS), str(occ)],
                capture_output=True, text=True, timeout=300)
        except subprocess.TimeoutExpired:
            print(" TIMEOUT")
            continue
        if r.returncode != 0:
            print(f" FAIL (exit {r.returncode})")
            continue
        try:
            data = json.loads(r.stdout)
            us = data["kernel_median_us"]
            print(f" {us:>7.2f} us")
            results.append((occ, us))
        except (json.JSONDecodeError, KeyError):
            print(" FAIL (bad output)")

    if not results:
        return None, None

    # Pick the fastest.  TUNE_ITERS=200 keeps per-probe medians stable
    # enough; revisit if we see picker oscillation across runs on the
    # same hardware.
    best_occ, best_us = min(results, key=lambda x: x[1])
    print(f"  → best occupancy: {best_occ} ({best_us:.2f} us)")
    return best_occ, dict(results)


def resolve_occupancy(args, binaries):
    """Returns (occupancy, source_label)."""
    if args.crisp_tree_occupancy is not None:
        return args.crisp_tree_occupancy, "--crisp-tree-occupancy CLI override"

    crisp_binary = binaries.get("crisp")
    cache = load_tune_cache()
    device = probe_device_name(crisp_binary) if crisp_binary else ""

    if args.tune:
        if not crisp_binary:
            print("--tune requested but Crisp binary unavailable; "
                  "falling back to .crisp source")
        else:
            best_occ, sample = tune_occupancy(crisp_binary)
            if best_occ is not None and device:
                cache[device] = {
                    "occupancy": best_occ,
                    "tuned_on":  time.strftime("%Y-%m-%d"),
                    "sample":    {f"{o}": u for o, u in sample.items()},
                }
                save_tune_cache(cache)
                return best_occ, f"--tune sweep on {device}"
            if best_occ is not None:
                return best_occ, "--tune sweep (device unknown, not cached)"

    if device and device in cache:
        return cache[device]["occupancy"], f"tune cache for {device}"

    if device and not args.tune:
        print(f"\n(no tune-cache entry for '{device}' — "
              f"consider running with --tune)")

    occ = extract_occupancy_from_crisp(SCRIPT_DIR / "crisp" / "sum-reduce.crisp")
    return occ, "parsed from sum-reduce.crisp"


def main():
    parser = argparse.ArgumentParser(description="Sum reduction benchmark")
    parser.add_argument("--sizes", default="1K,100K,1M",
                        help="Comma-separated problem sizes (e.g. 1K,100K,1M,10M)")
    parser.add_argument("--warmup", type=int, default=50)
    parser.add_argument("--iters", type=int, default=100)
    parser.add_argument("--impl", default="all",
                        help="Implementations to run: all, cuda, cub, crisp")
    parser.add_argument("--crisp-tree-occupancy", type=float, default=None,
                        help="Override occupancy ratio (>0.0; values above 1.0 oversubscribe).  Wins over "
                             "--tune and the cache.  Default: resolve via "
                             "--tune cache, then the .crisp source's :occupancy.")
    parser.add_argument("--tune", action="store_true",
                        help="Sweep occupancy on the local GPU, cache the best "
                             "value per device, and use it.  Overrides the "
                             ":occupancy declaration in the .crisp source.")
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
        print("Building Crisp...")
        b, ct = build_crisp(SCRIPT_DIR / "crisp")
        if b:
            binaries["crisp"] = b
            compile_times["crisp"] = ct

    if not binaries:
        print("No implementations built successfully. Exiting.")
        return 1

    # Run phase
    print("\n=== Benchmark phase ===")
    all_results = []

    # Resolve occupancy (shared between crisp and cuda): see
    # resolve_occupancy() for the full order.  Same value applies to both
    # impls so the comparison stays apples-to-apples — we're tuning for
    # the WORKLOAD on this hardware, not for one language.
    shared_occupancy, source = resolve_occupancy(args, binaries)
    print(f"\nOccupancy: {shared_occupancy} ({source}, applied to crisp and cuda)")

    for N in sizes:
        for impl_name, binary in binaries.items():
            extra = None
            if impl_name in ("crisp", "cuda"):
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
