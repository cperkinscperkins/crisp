#!/usr/bin/env python3
"""
Crisp reduction benchmark driver (plan/benchmark-reductions.md).

For every reduction kernel under benchmarks/reduction/<step>/*.crisp:
  1. compile it with crisp-compile (SPIR-V + .metacrisp) -- timed: that is Crisp's device compile;
  2. turn its metacrisp into an ARGUMENT PLAN (metacrisp.py) for each size;
  3. run the ONE generic fixture (benchmarks/reduction/fixture/reduce_fixture_l0.cpp) on the plan;
  4. verify what came back against the fixture's double-precision input statistics, on BOTH the
     last timed launch (input A) and a relaunch on different data (input B);
  5. write a results_*.json in the same schema as the matmul suite, with benchmark_suite=reduction.

A kernel says what it computes in header comments the driver reads:
    ;; BENCH-WORKLOAD: sum
    ;; BENCH-EXPECT: result = sum(input)
BENCH-EXPECT functions: sum sumsq min max argmin argmax count mean var (population).

Stale-state demonstration (--stale-demo): runs an :atomic kernel without its per-launch identity
fill, and a last-man kernel with its zero-once counter dirtied before the relaunch.  Both MUST
fail verification; the driver exits non-zero if either is not caught.

Usage (inside the Intel container, or natively on Windows for correctness work):
    python scripts/crisp_bench/reduction.py --platform=intel [--kernels=step4_grid_reduce/sum]
        [--sizes-mb=1,16,64,256,1024,3072] [--groups=eu] [--iters=50] [--warmup=5]
        [--precision=fast] [--scratch] [--stale-demo]
"""

from __future__ import annotations

import argparse
import json
import math
import platform as _platform
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(HERE))

import hwprofile                                                # noqa: E402
from harness import (BenchmarkMetrics, BenchmarkSweep, CompileTimeMetrics, RuntimeMetrics,  # noqa: E402
                     SweepPoint, ThroughputMetrics, VerificationMetrics, create_metadata)
from matmul import _resolve_cxx_and_l0_link, crisp_compiler_path      # noqa: E402
from metacrisp import build_plan, read_metacrisp, write_plan    # noqa: E402

BENCH_DIR = REPO / "benchmarks" / "reduction"
FIXTURE_SRC = BENCH_DIR / "fixture" / "reduce_fixture_l0.cpp"
RESULTS_DIR = REPO / "benchmarks" / "results"

HW_BY_PLATFORM = {
    "intel": {"gpu_model": "Intel BMG", "arch_target": "bmg", "environment": "docker"},
}

# Relative tolerance for floating-point reductions.  Generated inputs are small integers, so every
# per-thread partial is exact; only the cross-thread tree rounds, by roughly log2(threads) ulps.
RTOL = {"f32": 1e-5, "f64": 1e-12, "bf16": 1e-2, "f16": 1e-2}


# --------------------------------------------------------------------------------------------
# kernel discovery and directives
# --------------------------------------------------------------------------------------------

def discover(selection: Optional[str]) -> List[Path]:
    """Kernel sources: benchmarks/reduction/<step>/<name>.crisp, optionally filtered by
    comma-separated '<step>/<name>' or '<step>' prefixes."""
    all_srcs = sorted(p for p in BENCH_DIR.glob("*/*.crisp")
                      if p.parent.name not in ("fixture", "ceiling", "crisp"))
    if not selection:
        return all_srcs
    wanted = [s.strip() for s in selection.split(",") if s.strip()]
    rel = lambda p: f"{p.parent.name}/{p.stem}"
    return [p for p in all_srcs if any(rel(p) == w or rel(p).startswith(w + "/") or p.parent.name == w
                                       for w in wanted)]


def directives(src: Path) -> Dict[str, Any]:
    text = src.read_text(encoding="utf-8")
    workload = re.search(r";+\s*BENCH-WORKLOAD:\s*(\S+)", text)
    expects = re.findall(r";+\s*BENCH-EXPECT:\s*(\S+)\s*=\s*(\w+)\((\w+)\)", text)
    if not expects:
        raise SystemExit(f"{src}: no ';; BENCH-EXPECT: <output> = <fn>(<input>)' line")
    return {"workload": workload.group(1) if workload else src.stem,
            "expect": [(o, f, i) for o, f, i in expects]}


# --------------------------------------------------------------------------------------------
# compile + fixture
# --------------------------------------------------------------------------------------------

def compile_kernel(src: Path, work: Path, compiler: str, profile_flags: List[str],
                   precision: str, denormal: str) -> Tuple[Path, Path, float]:
    """crisp-compile SRC (copied into its own directory under WORK, so build products never land
    in the repo and one kernel's metacrisp cannot be globbed as another's -- `sum_*.metacrisp`
    also matches `sum_atomic_*`).  Returns (spv, metacrisp, wall ms)."""
    kdir = work / f"{src.parent.name}__{src.stem}"
    kdir.mkdir(parents=True, exist_ok=True)
    work = kdir
    dst = work / src.name
    shutil.copy2(src, dst)
    cmd = [compiler, *profile_flags, str(dst), "--ir-target=spv", "--metadata",
           f"--math-precision={precision}", f"--denormal-handling={denormal}", "--log-level=off"]
    t0 = time.time()
    r = subprocess.run(cmd, capture_output=True, text=True, cwd=REPO)
    ms = (time.time() - t0) * 1000.0
    if r.returncode != 0:
        raise RuntimeError(f"crisp-compile failed for {src}:\n{(r.stdout or '')[-1500:]}{(r.stderr or '')[-1500:]}")
    spv = dst.with_suffix(".spv")
    metas = sorted(work.glob(f"{dst.stem}_*.metacrisp"))
    if not spv.exists() or not metas:
        raise RuntimeError(f"crisp-compile produced no .spv/.metacrisp for {src}")
    return spv, metas[0], ms


def build_fixture(out_dir: Path) -> Path:
    cxx, link_pre, link_post = _resolve_cxx_and_l0_link()
    exe = out_dir / ("reduce_fixture_l0" + (".exe" if _platform.system() == "Windows" else ""))
    cmd = [cxx, "-O2", "-std=c++17", str(FIXTURE_SRC), *link_pre, "-o", str(exe), *link_post]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("fixture build failed:\n" + (r.stderr or r.stdout or "")[-2000:])
    return exe


def run_fixture(exe: Path, plan: Path, res: Path, extra: List[str]) -> Dict[str, Any]:
    r = subprocess.run([str(exe), str(plan), str(res), *extra], capture_output=True, text=True, timeout=1800)
    if r.returncode != 0:
        raise RuntimeError(f"fixture failed (rc={r.returncode}):\n{(r.stderr or '')[-2000:]}")
    return parse_results(res.read_text(encoding="utf-8"))


def parse_results(text: str) -> Dict[str, Any]:
    out: Dict[str, Any] = {"stats": {}, "out": {}}
    for line in text.splitlines():
        if not line.strip():
            continue
        word, _, rest = line.partition(" ")
        if word == "device":
            out["device"] = rest.strip()
        elif word in ("eus", "groups"):
            out[word] = int(rest)
        elif word in ("jit_ms", "wall_us"):
            out[word] = float(rest)
        elif word == "time_us":
            out["time_us"] = [float(x) for x in rest.split()]
        elif word == "stats":
            tag, name, *kvs = rest.split()
            out["stats"][(tag, name)] = {k: float(v) for k, v in (t.split("=") for t in kvs)}
        elif word == "out":
            tag, name, elem, *vals = rest.split()
            out["out"][(tag, name)] = (elem, [float(v) if v not in ("nan", "-nan") else math.nan for v in vals])
    return out


# --------------------------------------------------------------------------------------------
# verification
# --------------------------------------------------------------------------------------------

def expected_value(fn: str, st: Dict[str, float]) -> float:
    n = st["count"]
    return {
        "sum": st["sum"], "sumsq": st["sumsq"], "min": st["min"], "max": st["max"],
        "argmin": st["argmin"], "argmax": st["argmax"], "count": n,
        "mean": st["sum"] / n, "var": st["sumsq"] / n - (st["sum"] / n) ** 2,
    }[fn]


def verify(res: Dict[str, Any], expects) -> Tuple[bool, float, List[str]]:
    """Both the last timed launch (A) and the relaunch (B) must match.  Returns
    (ok, worst relative error, human-readable failures)."""
    ok, worst, why = True, 0.0, []
    for tag in ("A", "B"):
        for out_name, fn, in_name in expects:
            st = res["stats"].get((tag, in_name))
            got = res["out"].get((tag, out_name))
            if st is None or got is None:
                ok = False
                why.append(f"{tag}: no {'statistics for ' + in_name if st is None else 'output ' + out_name}")
                continue
            elem, vals = got
            want = expected_value(fn, st)
            have = vals[0]
            if math.isnan(have):
                ok = False
                why.append(f"{tag}: {out_name} is NaN -- the poison survived the launch: the kernel never wrote it")
                continue
            if fn in ("argmin", "argmax", "count"):
                good, rel = (have == want), (0.0 if have == want else math.inf)
            else:
                rel = abs(have - want) / max(abs(want), 1e-30)
                good = rel <= RTOL.get(elem, 1e-5)
            worst = max(worst, rel)
            if not good:
                ok = False
                why.append(f"{tag}: {out_name}={have!r}, expected {fn}({in_name})={want!r} (rel err {rel:.3g})")
    return ok, worst, why


# --------------------------------------------------------------------------------------------
# ceilings
# --------------------------------------------------------------------------------------------

def latest_ceiling(platform: str) -> Optional[Dict[str, Any]]:
    """The newest measured read-bandwidth ceiling for this platform (incompressible data)."""
    files = sorted(RESULTS_DIR.glob(f"ceiling_{platform}_hash_*.json"))
    if not files:
        return None
    d = json.loads(files[-1].read_text(encoding="utf-8"))
    d["_file"] = files[-1].name
    return d


# --------------------------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------------------------

def stale_demo(exe: Path, work: Path, compiler: str, profile_flags: List[str],
               precision: str, denormal: str) -> int:
    """Prove the harness catches stale state.  Both runs MUST fail verification."""
    cases = [("step4_grid_reduce/sum_atomic", ["--skip-each-fill"],
              "atomic output not re-initialised between launches"),
             ("step4_grid_reduce/sum", ["--dirty-once-before-relaunch"],
              "last-man counter not zero before the relaunch")]
    caught_all = True
    for sel, flags, what in cases:
        src = BENCH_DIR / (sel + ".crisp")
        spv, meta, _ = compile_kernel(src, work, compiler, profile_flags, precision, denormal)
        rec = read_metacrisp(meta)[0]
        plan = write_plan(build_plan(rec, 1 << 20, min(rec.local_size[0], 160)), spv,
                          work / f"{rec.name}.stale.plan", warmup=3, iters=10)
        res = run_fixture(exe, plan, work / f"{rec.name}.stale.res", flags)
        ok, _, why = verify(res, directives(src)["expect"])
        caught = not ok
        caught_all &= caught
        print(f"  stale demo [{what}]: {'CAUGHT' if caught else 'NOT CAUGHT -- the harness is blind to this'}")
        for w in why:
            print(f"      {w}")
    return 0 if caught_all else 1


def main() -> int:
    ap = argparse.ArgumentParser(description="Crisp reduction benchmark driver")
    ap.add_argument("--platform", default="intel", choices=sorted(HW_BY_PLATFORM))
    ap.add_argument("--kernels", default=None, help="comma-separated <step>/<name> or <step> filters")
    ap.add_argument("--sizes-mb", default="1,16,64,256,1024,3072",
                    help="input sizes in MiB (per input), clamped to a third of device memory")
    ap.add_argument("--groups", default="eu", help="work-groups: a number, 'eu', or 'eu*K'")
    ap.add_argument("--warmup", type=int, default=5)
    ap.add_argument("--iters", type=int, default=50)
    ap.add_argument("--precision", default="fast", choices=["fast", "ieee"])
    ap.add_argument("--denormal", default=None, choices=["ftz", "preserve"],
                    help="default: ftz under fast (fast implies flush), preserve under ieee")
    ap.add_argument("--scratch", action="store_true", help="write results to benchmarks/results/scratch/")
    ap.add_argument("--stale-demo", action="store_true", help="prove the harness catches stale state, then exit")
    ap.add_argument("--keep-work", action="store_true")
    ap.add_argument("--pretend-device", default=None)
    ap.add_argument("--allow-unprofiled", action="store_true")
    ap.add_argument("--auto-profile", action="store_true")
    ap.add_argument("--profile-file", default=None)
    a = ap.parse_args()
    denormal = a.denormal or ("ftz" if a.precision == "fast" else "preserve")

    hw = dict(HW_BY_PLATFORM[a.platform])
    compiler = crisp_compiler_path()
    try:
        profile, device, matched, provenance, profile_src = hwprofile.gate(
            a.platform, compiler, pretend=a.pretend_device, allow_unprofiled=a.allow_unprofiled,
            auto_profile=a.auto_profile, profile_file=a.profile_file, repo_root=REPO)
    except hwprofile.UnprofiledDevice as e:
        print(str(e))
        return 2
    profile_flags = ([str(profile_src)] if profile_src else []) + ([f"--hardware-profile={profile}"] if profile else [])
    if device and device != "unknown":
        hw["gpu_model"] = device
    print(f"Hardware: {hw['gpu_model']}  profile={profile} ({provenance})", flush=True)

    work = Path(tempfile.mkdtemp(prefix="crisp-reduction-"))
    try:
        exe = build_fixture(work)
        if a.stale_demo:
            return stale_demo(exe, work, compiler, profile_flags, a.precision, denormal)

        ceiling = latest_ceiling(a.platform)
        peak = ceiling["peak_read_gbs"] if ceiling else None
        if ceiling:
            print(f"Ceiling: {peak:.1f} GB/s measured read peak ({ceiling['_file']})")
        else:
            print("Ceiling: none measured for this platform -- run scripts/bench-ceiling-intel.sh")

        sizes = [int(s) for s in a.sizes_mb.split(",") if s.strip()]
        rc = 0
        for src in discover(a.kernels):
            d = directives(src)
            step = src.parent.name
            spv, meta, compile_ms = compile_kernel(src, work, compiler, profile_flags, a.precision, denormal)
            rec = read_metacrisp(meta)[0]
            last_man = any(p.implicit and p.stype and p.stype.kind == "cell" and p.stype.address_space == "GLOBAL"
                           for p in rec.params)
            meta_run = create_metadata(gpu_model=hw["gpu_model"], arch_target=hw["arch_target"],
                                       environment=hw["environment"], hardware_profile=profile,
                                       profile_matched=matched, profile_provenance=provenance,
                                       profile_source=profile_src)
            sweep = BenchmarkSweep(run_metadata=meta_run, benchmark_suite="reduction",
                                   chapter=f"{step}__{src.stem}", competitor="Crisp",
                                   precision=a.precision, denormal_handling=denormal,
                                   is_canonical=not a.scratch, contender_class="Crisp")
            print(f"\n== {step}/{src.stem}  ({rec.name}, workload={d['workload']}, crisp-compile {compile_ms:.0f} ms)")
            for mb in sizes:
                n = (mb << 20) // 4
                in_bytes = n * 4 * sum(1 for p in rec.params if not p.implicit and p.direction == "in" and p.stype
                                       and p.stype.kind == "tensor")
                plan = write_plan(build_plan(rec, n, a.groups), spv, work / f"{rec.name}_{mb}.plan",
                                  warmup=a.warmup, iters=a.iters)
                try:
                    res = run_fixture(exe, plan, work / f"{rec.name}_{mb}.res", [])
                except RuntimeError as e:
                    print(f"  {mb:>5} MiB  FIXTURE ERROR: {e}")
                    rc = 1
                    continue
                groups = res.get("groups")
                ok, worst, why = verify(res, d["expect"])
                if last_man and groups and groups > rec.local_size[0]:
                    ok = False
                    why.append(f"{groups} work-groups exceed the local size {rec.local_size[0]}: "
                               f"last-man's final sweep cannot cover every partial")
                times = res["time_us"]
                med_us = statistics.median(times)
                gbps = in_bytes / (med_us * 1e-6) / 1e9
                pct = (100.0 * gbps / peak) if peak else None
                print(f"  {mb:>5} MiB  {med_us:10.1f} us  {gbps:8.1f} GB/s"
                      + (f"  {pct:5.1f}% of peak" if pct is not None else "")
                      + f"  groups={groups}  {'verified' if ok else 'FAILED'}")
                for w in why:
                    print(f"      {w}")
                if not ok:
                    rc = 1
                cfg = {"elements": n, "bytes": in_bytes, "size_mb": mb, "workload": d["workload"],
                       "groups": groups, "local_size": rec.local_size, "warmup": a.warmup, "iters": a.iters,
                       "verified": ok, "kernel": rec.name, "step": step,
                       "kernel_best_us": min(times), "jit_ms": res.get("jit_ms"),
                       "device_reported": res.get("device"),
                       "peak_read_gbps": peak, "percent_of_peak": pct,
                       "ceiling_file": ceiling["_file"] if ceiling else None}
                sweep.results.append(SweepPoint(
                    configuration=cfg,
                    metrics=BenchmarkMetrics(
                        compile_time=CompileTimeMetrics(device_compile_ms=compile_ms, all_compile_ms=compile_ms),
                        runtime=RuntimeMetrics(wall_time_ms=res.get("wall_us", 0.0) / 1000.0,
                                               kernel_execution_ms=med_us / 1000.0),
                        throughput=ThroughputMetrics(bandwidth_gbps=gbps),
                        verification=VerificationMetrics(verified=ok, mode="full", relative_error=worst,
                                                         samples=2))))
            if sweep.results:
                path = sweep.save(force_scratch=a.scratch)
                print(f"  -> {path.relative_to(REPO)}")
        return rc
    finally:
        if a.keep_work:
            print(f"(work kept in {work})")
        else:
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
