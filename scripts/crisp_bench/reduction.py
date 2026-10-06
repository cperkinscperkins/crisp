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
BENCH-EXPECT functions: sum sumsq min max argmin argmax count mean var (population) m2 (= n * var).

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
from matmul import _resolve_cxx_and_l0_link, crisp_compiler_path, icpx_math_flags, nvcc_math_flags  # noqa: E402
from metacrisp import build_plan, read_metacrisp, write_plan    # noqa: E402

BENCH_DIR = REPO / "benchmarks" / "reduction"
FIXTURE_SRC = {"intel": BENCH_DIR / "fixture" / "reduce_fixture_l0.cpp",
               "nvidia": BENCH_DIR / "fixture" / "reduce_fixture_cuda.cpp"}
IR_TARGET = {"intel": "spv", "nvidia": "ptx"}
RESULTS_DIR = REPO / "benchmarks" / "results"

HW_BY_PLATFORM = {
    "intel": {"gpu_model": "Intel BMG", "arch_target": "bmg", "environment": "docker"},
    "nvidia": {"gpu_model": "NVIDIA H100", "arch_target": "sm_90", "environment": "runpod"},
}

# Relative tolerance for floating-point reductions.  It exists to catch WRONG results -- a stale,
# missing or doubled contribution (>= 1/2560 of the total at the grids used here) or a NaN -- not
# to grade accuracy, which is reported separately (relative_error).  Generated inputs are small
# integers, so every per-thread partial is exact; error comes only from combining partials in fp32.
# Measured on BMG (2026-10-03): tree / last-man sweeps stay under 1e-5; ~2560 per-warp atomics into
# one fp32 cell holding 2.8e9 reach 2e-5.  A kernel that atomically adds MILLIONS of terms into one
# cell (one per element or per work-group) rounds far more and must say so with BENCH-RTOL.
RTOL = {"f32": 1e-4, "f64": 1e-12, "bf16": 1e-2, "f16": 1e-2}


# --------------------------------------------------------------------------------------------
# kernel discovery and directives
# --------------------------------------------------------------------------------------------

def discover(selection: Optional[str]) -> List[Path]:
    """Kernel sources: benchmarks/reduction/<step>/<name>.crisp, optionally filtered by
    comma-separated '<step>/<name>' or '<step>' prefixes."""
    all_srcs = sorted(p for p in BENCH_DIR.glob("*/*.crisp")
                      if p.parent.name not in ("fixture", "ceiling", "crisp"))
    if not selection:
        # Underscore directories are probes -- deliberately not ladder steps -- and run only when named.
        return [p for p in all_srcs if not p.parent.name.startswith("_")]
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
    groups = re.search(r";+\s*BENCH-GROUPS:\s*(\S+)", text)
    inits = re.findall(r";+\s*BENCH-LAUNCH-INIT:\s*(\S+)\s*=\s*(\S+)", text)
    max_mb = re.search(r";+\s*BENCH-MAX-MB:\s*(\d+)", text)
    rtol = re.search(r";+\s*BENCH-RTOL:\s*(\S+)", text)
    return {"workload": workload.group(1) if workload else src.stem,
            "expect": [(o, f, i) for o, f, i in expects],
            "groups": groups.group(1) if groups else None,
            "launch_init": {o: float(v) for o, v in inits},
            "max_mb": int(max_mb.group(1)) if max_mb else None,
            "rtol": float(rtol.group(1)) if rtol else None}


def apply_launch_init_directives(rec, d: Dict[str, Any]) -> List[str]:
    """A hand-written atomic into an output gets no :launch-init from the compiler -- only its own
    reduction constructs record one -- so the kernel's BENCH-LAUNCH-INIT supplies it.  A directive
    never overrides what the compiler recorded.  Returns the outputs it applied to."""
    applied = []
    for p in rec.params:
        if not p.implicit and p.direction == "out" and p.name in d["launch_init"]:
            if p.launch_init:
                continue
            p.launch_init = {"IDENTITY": d["launch_init"][p.name]}
            applied.append(p.name)
    return applied


def resolve_groups(spec: str, n_elements: int, local: List[int]) -> str:
    """per-element -> one work-item per element (rounded up to whole work-groups); anything else is
    passed to the fixture as is (a number, 'eu', 'eu*K', 'occupancy R ...')."""
    if spec == "per-element":
        wg = local[0] * local[1] * local[2]
        return str((n_elements + wg - 1) // wg)
    return spec


def groups_policy(rec, d: Dict[str, Any], cli_groups: Optional[str], cli_occupancy: Optional[float],
                  last_man: bool) -> Tuple[str, Optional[float]]:
    """The grid a REAL Crisp host would launch, unless overridden.  Order:
         --groups (explicit)  >  BENCH-GROUPS (the kernel's own fixed choice)  >
         :strided -> the hoist's occupancy formula with R = --occupancy, else the kernel's
         declared :occupancy, else 1.0 (the hoist's default)  >  'eu'.
    A last-man kernel is capped at its local size: its final sweep reduces every partial in one
    work-group.  Returns (fixture groups spec, the R used or None)."""
    if cli_groups:
        return cli_groups, None
    if d["groups"]:
        return d["groups"], None
    if (rec.strategy or "").upper() == "STRIDED":
        r = cli_occupancy if cli_occupancy is not None else (rec.occupancy if rec.occupancy is not None else 1.0)
        spec = f"occupancy {r}"
        if last_man:
            spec += f" cap={rec.local_size[0] * rec.local_size[1] * rec.local_size[2]}"
        if rec.compute_units:
            spec += f" cu={rec.compute_units}"
        return spec, r
    return "eu", None


# --------------------------------------------------------------------------------------------
# compile + fixture
# --------------------------------------------------------------------------------------------

def compile_kernel(src: Path, work: Path, compiler: str, profile_flags: List[str],
                   precision: str, denormal: str, ir_target: str = "spv") -> Tuple[Path, Path, float]:
    """crisp-compile SRC (copied into its own directory under WORK, so build products never land
    in the repo and one kernel's metacrisp cannot be globbed as another's -- `sum_*.metacrisp`
    also matches `sum_atomic_*`).  Returns (spv, metacrisp, wall ms)."""
    kdir = work / f"{src.parent.name}__{src.stem}"
    kdir.mkdir(parents=True, exist_ok=True)
    work = kdir
    dst = work / src.name
    shutil.copy2(src, dst)
    cmd = [compiler, *profile_flags, str(dst), f"--ir-target={ir_target}", "--metadata",
           f"--math-precision={precision}", f"--denormal-handling={denormal}", "--log-level=off"]
    t0 = time.time()
    r = subprocess.run(cmd, capture_output=True, text=True, cwd=REPO)
    ms = (time.time() - t0) * 1000.0
    if r.returncode != 0:
        raise RuntimeError(f"crisp-compile failed for {src}:\n{(r.stdout or '')[-1500:]}{(r.stderr or '')[-1500:]}")
    spv = dst.with_suffix("." + ir_target)          # the module: .spv (L0) or .ptx (CUDA)
    metas = sorted(work.glob(f"{dst.stem}_*.metacrisp"))
    if not spv.exists() or not metas:
        raise RuntimeError(f"crisp-compile produced no .spv/.metacrisp for {src}")
    return spv, metas[0], ms


def _cuda_home() -> str:
    import os
    if os.environ.get("CUDA_HOME"):
        return os.environ["CUDA_HOME"]
    nvcc = shutil.which("nvcc")
    if nvcc:
        return str(Path(nvcc).resolve().parent.parent)
    return "/usr/local/cuda"


def build_fixture(out_dir: Path, platform: str = "intel") -> Path:
    src = FIXTURE_SRC[platform]
    exe = out_dir / (src.stem + (".exe" if _platform.system() == "Windows" else ""))
    if platform == "nvidia":
        # Driver API only: any C++17 compiler plus libcuda (the stub at link time, the driver at run).
        home = _cuda_home()
        cxx = shutil.which("g++") or shutil.which("clang++") or "c++"
        cmd = [cxx, "-O2", "-std=c++17", str(src), f"-I{home}/include", f"-L{home}/lib64/stubs",
               f"-L{home}/lib64", "-lcuda", "-o", str(exe)]
    else:
        cxx, link_pre, link_post = _resolve_cxx_and_l0_link()
        cmd = [cxx, "-O2", "-std=c++17", str(src), *link_pre, "-o", str(exe), *link_post]
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
        elif word in ("eus", "groups", "max_resident"):
            out[word] = int(rest)
        elif word in ("jit_ms", "wall_us", "launch_overhead_us"):
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
        "m2": st["sumsq"] - st["sum"] ** 2 / n,          # sum of squared deviations (Welford's M2)
    }[fn]


def verify(res: Dict[str, Any], expects, rtol: Optional[float] = None) -> Tuple[bool, float, List[str]]:
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
                good = rel <= (rtol if rtol is not None else RTOL.get(elem, 1e-4))
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

# --------------------------------------------------------------------------------------------
# contenders (plan/benchmark-reductions.md section 2)
# --------------------------------------------------------------------------------------------

CONTENDER_DIR = BENCH_DIR / "contenders"
# library -> (competitor name, contender class).  The class is RECORDED, not inferred from the name.
CONTENDERS = {
    "sycl":   ("SYCL_Reduction", "Peer"),
    "onedpl": ("oneDPL",         "Peer"),
    "onemkl": ("oneMKL",         "Ceiling"),
    "cub":    ("CUB",            "Peer"),
    "thrust": ("Thrust",         "Peer"),
    "cublas": ("cuBLAS",         "Ceiling"),
}
CONTENDER_SUFFIX = {"intel": ".cpp", "nvidia": ".cu"}
CONTENDER_TIMING = {
    "intel": "host-clock (submit + wait)",
    "nvidia": "cuda-events on the stream (Thrust: + its small host copy-back)",
}


def contender_sources(platform: str, selection: Optional[str]) -> List[Path]:
    """benchmarks/reduction/contenders/<platform>/<library>__<workload>.cpp, optionally filtered by
    comma-separated workload or library__workload names."""
    srcs = sorted((CONTENDER_DIR / platform).glob("*__*" + CONTENDER_SUFFIX[platform]))
    if not selection:
        return srcs
    wanted = [w.strip() for w in selection.split(",") if w.strip()]
    return [p for p in srcs if p.stem in wanted or p.stem.split("__", 1)[1] in wanted]


def build_contender(src: Path, out_dir: Path, precision: str, denormal: str,
                    platform: str = "intel") -> Tuple[Path, float, Optional[float]]:
    """icpx -fsycl with the matmul suite's explicit math flags (never a compiler default).  Returns
    (exe, full build ms, device-only compile ms).  Device-only is the number set beside crisp-compile:
    source -> SPIR-V, no host code, no link."""
    lib = src.stem.split("__", 1)[0]
    exe = out_dir / src.stem
    if platform == "nvidia":
        # -arch=native: compile for whatever part the pod has (RunPod rarely offers the same twice).
        flags = ["-O3", "-arch=native", *nvcc_math_flags(precision, denormal == "ftz")]
        cmd = ["nvcc", *flags, str(src), "-o", str(exe)] + (["-lcublas"] if lib == "cublas" else [])
        t0 = time.time()
        r = subprocess.run(cmd, capture_output=True, text=True)
        full_ms = (time.time() - t0) * 1000.0
        if r.returncode != 0:
            raise RuntimeError(f"contender build failed for {src.name}:\n{(r.stderr or r.stdout or '')[-1500:]}")
        # Device-only: source -> PTX, the counterpart of crisp-compile --ir-target=ptx.
        t0 = time.time()
        r = subprocess.run(["nvcc", *flags, "-ptx", str(src), "-o", str(out_dir / (src.stem + ".ptx"))],
                           capture_output=True, text=True)
        dev_ms = (time.time() - t0) * 1000.0 if r.returncode == 0 else None
        return exe, full_ms, dev_ms
    flags = ["-O3", *icpx_math_flags(precision, denormal == "ftz")]
    cmd = ["icpx", "-fsycl", *flags, str(src), "-o", str(exe)] + (["-qmkl"] if lib == "onemkl" else [])
    t0 = time.time()
    r = subprocess.run(cmd, capture_output=True, text=True)
    full_ms = (time.time() - t0) * 1000.0
    if r.returncode != 0:
        raise RuntimeError(f"contender build failed for {src.name}:\n{(r.stderr or r.stdout or '')[-1500:]}")
    dev_cmd = ["icpx", "-fsycl", "-fsycl-device-only", "-fsycl-targets=spir64", *flags, str(src),
               "-o", str(out_dir / (src.stem + ".devbc"))]
    t0 = time.time()
    r = subprocess.run(dev_cmd, capture_output=True, text=True)
    dev_ms = (time.time() - t0) * 1000.0 if r.returncode == 0 else None
    return exe, full_ms, dev_ms


def workload_expectations(workload: str) -> Dict[str, Any]:
    """A contender is verified against the SAME BENCH-EXPECT lines as Crisp's kernel for the workload."""
    return directives(BENCH_DIR / "workloads" / f"{workload}.crisp")


def run_contenders(a, platform: str, work: Path, sizes: List[int], hw: Dict[str, Any],
                   profile, matched, provenance, profile_src, peak) -> int:
    rc = 0
    for src in contender_sources(platform, a.kernels):
        lib, workload = src.stem.split("__", 1)
        name, klass = CONTENDERS[lib]
        try:
            exe, full_ms, dev_ms = build_contender(src, work, a.precision,
                                                   a.denormal or ("ftz" if a.precision == "fast" else "preserve"),
                                                   platform)
        except RuntimeError as e:
            print(f"\n== contender {src.stem}: BUILD FAILED\n{e}")
            rc = 1
            continue
        d = workload_expectations(workload)
        meta_run = create_metadata(gpu_model=hw["gpu_model"], arch_target=hw["arch_target"],
                                   environment=hw["environment"], hardware_profile=profile,
                                   profile_matched=matched, profile_provenance=provenance,
                                   profile_source=profile_src)
        sweep = BenchmarkSweep(run_metadata=meta_run, benchmark_suite="reduction",
                               chapter=f"workloads__{workload}", competitor=name,
                               precision=a.precision, denormal_handling=a.denormal or "ftz",
                               is_canonical=not a.scratch, contender_class=klass)
        print(f"\n== contender {name} / {workload}  (device compile "
              + (f"{dev_ms:.0f} ms" if dev_ms is not None else "n/a") + f", full build {full_ms:.0f} ms)")
        for mb in sizes:
            n = (mb << 20) // 4
            resf = work / f"{src.stem}_{mb}.res"
            r = subprocess.run([str(exe), f"--mb={mb}", f"--warmup={a.warmup}", f"--iters={a.iters}",
                                f"--results={resf}"], capture_output=True, text=True, timeout=1800)
            if r.returncode != 0:
                print(f"  {mb:>5} MiB  RUN FAILED: {(r.stderr or '')[-500:]}")
                rc = 1
                continue
            res = parse_results(resf.read_text(encoding="utf-8"))
            ok, worst, why = verify(res, d["expect"], d["rtol"])
            med_us = statistics.median(res["time_us"])
            gbps = n * 4 / (med_us * 1e-6) / 1e9
            pct = (100.0 * gbps / peak) if peak else None
            ov = res.get("launch_overhead_us")
            print(f"  {mb:>5} MiB  {med_us:10.1f} us  {gbps:8.1f} GB/s"
                  + (f"  {pct:5.1f}% of peak" if pct is not None else "")
                  + (f"  (launch overhead {ov:.1f} us)" if ov is not None else "")
                  + f"  {'verified' if ok else 'FAILED'}")
            for w in why:
                print(f"      {w}")
            if not ok:
                rc = 1
            cfg = {"elements": n, "bytes": n * 4, "size_mb": mb, "workload": workload, "verified": ok,
                   "kernel": src.stem, "library": lib, "timing": CONTENDER_TIMING[platform],
                   "launch_overhead_us": ov, "kernel_best_us": min(res["time_us"]),
                   "device_reported": res.get("device"), "peak_read_gbps": peak, "percent_of_peak": pct,
                   "warmup": a.warmup, "iters": a.iters}
            sweep.results.append(SweepPoint(
                configuration=cfg,
                metrics=BenchmarkMetrics(
                    compile_time=CompileTimeMetrics(device_compile_ms=dev_ms if dev_ms is not None else 0.0,
                                                    all_compile_ms=full_ms),
                    runtime=RuntimeMetrics(wall_time_ms=res.get("wall_us", 0.0) / 1000.0,
                                           kernel_execution_ms=med_us / 1000.0),
                    throughput=ThroughputMetrics(bandwidth_gbps=gbps),
                    verification=VerificationMetrics(verified=ok, mode="full", relative_error=worst, samples=2))))
        if sweep.results:
            path = sweep.save(force_scratch=a.scratch)
            print(f"  -> {path.relative_to(REPO)}")
    return rc


def stale_demo(exe: Path, work: Path, compiler: str, profile_flags: List[str],
               precision: str, denormal: str, ir_target: str = "spv") -> int:
    """Prove the harness catches stale state.  Both runs MUST fail verification."""
    cases = [("step4_grid_reduce/sum_atomic", ["--skip-each-fill"],
              "atomic output not re-initialised between launches"),
             ("step4_grid_reduce/sum", ["--dirty-once-before-relaunch"],
              "last-man counter not zero before the relaunch")]
    caught_all = True
    for sel, flags, what in cases:
        src = BENCH_DIR / (sel + ".crisp")
        spv, meta, _ = compile_kernel(src, work, compiler, profile_flags, precision, denormal, ir_target)
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
    ap.add_argument("--groups", default=None,
                    help="work-groups: a number, 'eu', 'eu*K' or 'per-element'.  Default: the kernel's "
                         "BENCH-GROUPS directive, else 'eu'")
    ap.add_argument("--occupancy", type=float, default=None,
                    help="override every :strided kernel's :occupancy R (groups = R x max resident "
                         "work-groups, the hoist's formula); for sweeping the trade-off")
    ap.add_argument("--warmup", type=int, default=5)
    ap.add_argument("--iters", type=int, default=50)
    ap.add_argument("--precision", default="fast", choices=["fast", "ieee"])
    ap.add_argument("--denormal", default=None, choices=["ftz", "preserve"],
                    help="default: ftz under fast (fast implies flush), preserve under ieee")
    ap.add_argument("--scratch", action="store_true", help="write results to benchmarks/results/scratch/")
    ap.add_argument("--stale-demo", action="store_true", help="prove the harness catches stale state, then exit")
    ap.add_argument("--contenders", action="store_true",
                    help="run the library contenders (benchmarks/reduction/contenders/<platform>/) INSTEAD of "
                         "the Crisp kernels; --kernels then filters by workload or library__workload")
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
        ir_target = IR_TARGET[a.platform]
        exe = build_fixture(work, a.platform)
        if a.stale_demo:
            return stale_demo(exe, work, compiler, profile_flags, a.precision, denormal, ir_target)

        ceiling = latest_ceiling(a.platform)
        peak = ceiling["peak_read_gbs"] if ceiling else None
        if ceiling:
            print(f"Ceiling: {peak:.1f} GB/s measured read peak ({ceiling['_file']})")
        else:
            print("Ceiling: none measured for this platform -- run scripts/bench-ceiling-intel.sh")

        sizes = [int(s) for s in a.sizes_mb.split(",") if s.strip()]
        if a.contenders:
            return run_contenders(a, a.platform, work, sizes, hw, profile, matched, provenance, profile_src, peak)
        rc = 0
        for src in discover(a.kernels):
            d = directives(src)
            step = src.parent.name
            spv, meta, compile_ms = compile_kernel(src, work, compiler, profile_flags, a.precision, denormal,
                                                   ir_target)
            rec = read_metacrisp(meta)[0]
            init_from_directive = apply_launch_init_directives(rec, d)
            # Sizes are BYTES per input; the element count follows from the input's element type, so an
            # fp64 kernel at "256 MiB" reads the same bytes as an fp32 one.
            in_params = [p for p in rec.params if not p.implicit and p.direction == "in" and p.stype
                         and p.stype.kind == "tensor"]
            elem_bytes = in_params[0].stype.elem_bytes if in_params else 4
            last_man = any(p.implicit and p.stype and p.stype.kind == "cell" and p.stype.address_space == "GLOBAL"
                           for p in rec.params)
            groups_spec, occ_used = groups_policy(rec, d, a.groups, a.occupancy, last_man)
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
                if d["max_mb"] and mb > d["max_mb"]:
                    # Recorded as SKIPPED, not silently absent (the data-audit gap: a missing size
                    # must be distinguishable from one never configured).
                    print(f"  {mb:>5} MiB  skipped (BENCH-MAX-MB {d['max_mb']})")
                    sweep.results.append(SweepPoint(
                        configuration={"size_mb": mb, "elements": (mb << 20) // elem_bytes,
                                       "skipped": f"BENCH-MAX-MB {d['max_mb']}",
                                       "workload": d["workload"], "step": step, "kernel": rec.name},
                        metrics=BenchmarkMetrics(
                            compile_time=CompileTimeMetrics(device_compile_ms=compile_ms, all_compile_ms=compile_ms),
                            runtime=RuntimeMetrics(wall_time_ms=0.0, kernel_execution_ms=0.0),
                            throughput=ThroughputMetrics(bandwidth_gbps=None),
                            verification=VerificationMetrics(verified=False, mode="none"))))
                    continue
                n = (mb << 20) // elem_bytes
                in_bytes = n * elem_bytes * len(in_params)
                plan = write_plan(build_plan(rec, n, resolve_groups(groups_spec, n, rec.local_size)), spv, work / f"{rec.name}_{mb}.plan",
                                  warmup=a.warmup, iters=a.iters)
                try:
                    res = run_fixture(exe, plan, work / f"{rec.name}_{mb}.res", [])
                except RuntimeError as e:
                    print(f"  {mb:>5} MiB  FIXTURE ERROR: {e}")
                    rc = 1
                    continue
                groups = res.get("groups")
                ok, worst, why = verify(res, d["expect"], d["rtol"])
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
                      + f"  groups={groups}"
                      + (f" (R={occ_used:g} of {res.get('max_resident')})" if occ_used is not None else "")
                      + f"  {'verified' if ok else 'FAILED'}")
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
                       "ceiling_file": ceiling["_file"] if ceiling else None,
                       "groups_spec": groups_spec, "occupancy": occ_used,
                       "max_resident": res.get("max_resident"),
                       "launch_init_from_directive": init_from_directive,
                       "rtol": d["rtol"] if d["rtol"] is not None else RTOL.get("f32")}
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
