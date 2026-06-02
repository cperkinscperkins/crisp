#!/usr/bin/env python3
"""
Performance regression check for Crisp.

Runs each test in performance/ on the local BMG, compares to baseline.json,
ratchets the baseline down on improvement, fails on regression beyond the
per-metric tolerance.

Usage:
  python performance/check.py                  # run all, ratchet & check
  python performance/check.py --test=<name>    # run one
  python performance/check.py --update         # explicit "I improved this"
                                               # (same as default behaviour
                                               # but prints the diff loudly)
  python performance/check.py --seed           # bootstrap baseline.json
                                               # with the current run

Exit codes:
  0   all tests within tolerance (or improved)
  1   at least one metric regressed beyond tolerance
  2   build / run error

See performance/README.md for design rationale.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

PERF_DIR = Path(__file__).resolve().parent
REPO_ROOT = PERF_DIR.parent
BIN_DIR = REPO_ROOT / "bin"
BASELINE_PATH = PERF_DIR / "baseline.json"

# --- Test registry ----------------------------------------------------------
# Each entry: directory under performance/, crisp source filename, kernel name
# (used to derive the .spv filename), and a default tolerance per metric.
#
# tolerance: fractional slowdown allowed before we call it a regression.
# Wider on compile time (more variable, expected to drift upward as features
# land); tighter on kernel time (this is the thing we're really watching).
TESTS = [
    {
        "name":              "reduction-bmg",
        "crisp_source":      "sum-reduce.crisp",
        "spv":               "sum-reduce.spv",
        "harness":           "harness.cpp",
        "binary":            "harness.exe",
        "tolerance": {
            "kernel_median_us":  0.10,
            "throughput_gb_s":   0.10,
            "device_compile_s":  0.25,
        },
    },
    {
        "name":              "vec-copy-bmg",
        "crisp_source":      "vec-copy.crisp",
        "spv":               "vec-copy.spv",
        "harness":           "harness.cpp",
        "binary":            "harness.exe",
        "tolerance": {
            "kernel_median_us":  0.10,
            "throughput_gb_s":   0.10,
            "device_compile_s":  0.25,
        },
    },
]

# Metrics with this string in the name mean "lower is better" (kernel time,
# compile time).  Anything else is "higher is better" (throughput).
LOWER_IS_BETTER = ("_us", "_s")


def is_lower_better(metric):
    return any(metric.endswith(s) for s in LOWER_IS_BETTER)


# --- Toolchain resolution (mirrors tests/run-specs.lisp) --------------------

def resolve_clang():
    candidate = Path("C:/Users/cperk/Documents/llvm-mingw-20251216-ucrt-x86_64/bin/clang++.exe")
    if candidate.exists():
        return str(candidate)
    on_path = shutil.which("clang++")
    if on_path:
        return on_path
    return None


def resolve_l0_include():
    for c in [Path("C:/Users/cperk/Documents/level-zero/include"),
              Path(os.environ.get("CRISP_L0_INCLUDE", ""))]:
        if c and c.exists():
            return str(c)
    return None


def resolve_ze_loader():
    p = Path("C:/Windows/System32/ze_loader.dll")
    return str(p) if p.exists() else None


def find_crisp_compile():
    on_path = shutil.which("crisp-compile") or shutil.which("crisp-compile.exe")
    if on_path:
        return on_path
    for name in ("crisp-compile.exe", "crisp-compile"):
        candidate = BIN_DIR / name
        if candidate.exists():
            return str(candidate)
    return None


# --- Build & run a single test ---------------------------------------------

def run_test(test, warmup=50, iterations=100):
    """Build, run, and return a dict of measured metrics for `test`.
    Raises RuntimeError on build/run failure."""
    name = test["name"]
    tdir = PERF_DIR / name
    crisp_file = tdir / test["crisp_source"]
    spv_file   = tdir / test["spv"]
    harness_cpp = tdir / test["harness"]
    binary     = tdir / test["binary"]

    crisp_compile = find_crisp_compile()
    if not crisp_compile:
        raise RuntimeError("crisp-compile not found (looked in PATH and bin/)")
    clang = resolve_clang()
    if not clang:
        raise RuntimeError("clang++ not found")
    l0_inc = resolve_l0_include()
    if not l0_inc:
        raise RuntimeError("Level Zero include dir not found")
    ze_loader = resolve_ze_loader()
    if not ze_loader:
        raise RuntimeError("ze_loader.dll not found in System32")

    # 1. crisp-compile -> .spv  (this is the timed device compile)
    print(f"  [{name}] crisp-compile {test['crisp_source']}")
    t0 = time.monotonic()
    r = subprocess.run(
        [crisp_compile, "--ir-target=spv", str(crisp_file)],
        capture_output=True, text=True)
    device_compile_s = time.monotonic() - t0
    if r.returncode != 0:
        raise RuntimeError(f"crisp-compile failed:\n{r.stderr}")
    if not spv_file.exists():
        raise RuntimeError(f"crisp-compile produced no .spv at {spv_file}")

    # 2. clang++ -> .exe  (not timed; harness rebuild cost isn't a Crisp metric)
    print(f"  [{name}] clang++ harness")
    r = subprocess.run(
        [clang, str(harness_cpp), "-I", l0_inc, ze_loader,
         "-static", "-o", str(binary)],
        capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"clang++ failed:\n{r.stderr}")

    # 3. Run the harness; it cwd's into tdir so the relative SPV path resolves.
    print(f"  [{name}] running harness ({warmup} warmup, {iterations} iters)")
    r = subprocess.run(
        [str(binary), str(warmup), str(iterations)],
        capture_output=True, text=True, cwd=str(tdir))
    if r.returncode != 0:
        raise RuntimeError(f"harness failed (exit {r.returncode}):\n{r.stderr}")
    try:
        result = json.loads(r.stdout)
    except json.JSONDecodeError:
        raise RuntimeError(f"harness produced non-JSON output:\n{r.stdout}")

    result["device_compile_s"] = round(device_compile_s, 3)
    return result


# --- Baseline I/O -----------------------------------------------------------

def load_baseline():
    if not BASELINE_PATH.exists():
        return {}
    return json.loads(BASELINE_PATH.read_text())


def save_baseline(baseline):
    BASELINE_PATH.write_text(json.dumps(baseline, indent=2) + "\n")


# --- Comparison logic -------------------------------------------------------

def compare_metric(test_name, metric, current, baseline_entry, tolerance):
    """Returns a tuple (verdict, message) where verdict is one of:
        "first_run"  — no baseline yet
        "improved"   — current beats baseline; ratchet
        "ok"         — within tolerance
        "regressed"  — slowdown exceeds tolerance
    """
    if baseline_entry is None:
        return "first_run", f"{metric}: {current} (no baseline yet)"

    best = baseline_entry["best"]
    if is_lower_better(metric):
        # Lower is better: improvement = current < best
        improvement = (best - current) / best if best else 0
        regression  = (current - best) / best if best else 0
    else:
        # Higher is better: improvement = current > best
        improvement = (current - best) / best if best else 0
        regression  = (best - current) / best if best else 0

    if improvement > 0:
        return "improved", (f"{metric}: {current} (was {best}, "
                            f"improved {improvement*100:.1f}%)")
    if regression > tolerance:
        return "regressed", (f"{metric}: {current} (was {best}, "
                             f"REGRESSED {regression*100:.1f}% > "
                             f"tolerance {tolerance*100:.0f}%)")
    return "ok", (f"{metric}: {current} (was {best}, "
                  f"within tolerance)")


def ratchet(baseline, test_name, metric, current, tolerance, sha=""):
    """Write/update the baseline entry for (test, metric)."""
    if test_name not in baseline:
        baseline[test_name] = {}
    baseline[test_name][metric] = {
        "best":      current,
        "tolerance": tolerance,
        "set_on":    time.strftime("%Y-%m-%d"),
        "sha":       sha,
    }


def get_git_sha():
    try:
        r = subprocess.run(["git", "rev-parse", "--short", "HEAD"],
                           capture_output=True, text=True, cwd=str(REPO_ROOT))
        if r.returncode == 0:
            return r.stdout.strip()
    except FileNotFoundError:
        pass
    return ""


# --- Main -------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Crisp performance regression check")
    parser.add_argument("--test", default=None,
                        help="Run only the named test (default: all)")
    parser.add_argument("--warmup", type=int, default=50)
    parser.add_argument("--iters",  type=int, default=100)
    parser.add_argument("--seed", action="store_true",
                        help="Bootstrap baseline.json with current numbers, "
                             "no regression check.")
    parser.add_argument("--update", action="store_true",
                        help="Print diff loudly even for non-regressions "
                             "(otherwise improvements are quiet).")
    args = parser.parse_args()

    selected = [t for t in TESTS if args.test is None or t["name"] == args.test]
    if not selected:
        print(f"No test named '{args.test}'. Available: "
              f"{', '.join(t['name'] for t in TESTS)}")
        return 2

    baseline = load_baseline()
    sha = get_git_sha()
    any_regression = False

    print(f"=== Crisp performance check (sha={sha or '<no git>'}) ===\n")
    for test in selected:
        print(f"--- {test['name']} ---")
        try:
            result = run_test(test, warmup=args.warmup, iterations=args.iters)
        except RuntimeError as e:
            print(f"  ERROR: {e}")
            return 2

        baseline_for_test = baseline.get(test["name"], {})
        print(f"  results: kernel_median_us={result['kernel_median_us']}  "
              f"throughput_gb_s={result['throughput_gb_s']}  "
              f"device_compile_s={result['device_compile_s']}")

        for metric, tol in test["tolerance"].items():
            current = result.get(metric)
            if current is None:
                print(f"  WARN: metric '{metric}' missing from harness output")
                continue
            baseline_entry = baseline_for_test.get(metric)

            if args.seed:
                ratchet(baseline, test["name"], metric, current, tol, sha)
                print(f"    {metric}: {current}  (seeded)")
                continue

            verdict, msg = compare_metric(test["name"], metric, current,
                                          baseline_entry, tol)
            if verdict == "regressed":
                any_regression = True
                print(f"    FAIL  {msg}")
            elif verdict == "improved":
                ratchet(baseline, test["name"], metric, current, tol, sha)
                print(f"    {'IMPROVED' if args.update else 'improved'}  {msg}")
            elif verdict == "first_run":
                ratchet(baseline, test["name"], metric, current, tol, sha)
                print(f"    seeded  {msg}")
            else:
                if args.update:
                    print(f"    ok    {msg}")
        print()

    save_baseline(baseline)
    print(f"baseline.json {'updated' if not args.seed else 'seeded'}.")
    return 1 if any_regression else 0


if __name__ == "__main__":
    sys.exit(main())
