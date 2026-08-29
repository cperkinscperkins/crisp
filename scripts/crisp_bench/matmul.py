#!/usr/bin/env python3
"""
Benchmark execution driver for the Matmul suite.
Runs parameter sweeps across multiple configurations (M/N/K) and precision flags.
Outputs structured JSON sweep files to the `benchmarks/results/` directory.

Usage:
  python scripts/crisp_bench/matmul.py --precision=fast
  python scripts/crisp_bench/matmul.py --precision=ieee --ftz
"""
import argparse
import subprocess
import os
import sys
import json
import shutil
import time
import re
from pathlib import Path

# Add parent dir to path so we can import harness
sys.path.append(str(Path(__file__).resolve().parent))
from harness import BenchmarkSweep, SweepPoint, BenchmarkMetrics, CompileTimeMetrics, RuntimeMetrics, ThroughputMetrics, create_metadata

HERE = Path(__file__).resolve().parent.parent.parent / "benchmarks" / "matmul"
import platform as _platform

# Endeavor 144 Phase 0 — the Crisp hardware profile forwarded to every device compile.
NVIDIA_HW_PROFILE = "h100"     # H100 PCIe: 114 SMs (the SXM part is 132)
INTEL_HW_PROFILE  = "bmg"      # Arc B580 (Xe2)

# Hardware metadata stamped into every BenchmarkSweep's run_metadata.
HW = {"gpu_model": "NVIDIA H100", "arch_target": "sm_90", "environment": "runpod"}
HW_BY_PLATFORM = {
    "nvidia": {"gpu_model": "NVIDIA H100", "arch_target": "sm_90", "environment": "runpod"},
    "intel":  {"gpu_model": "Intel BMG",   "arch_target": "bmg",   "environment": "docker"},
}

def _detect_gpu_model(fallback):
    try:
        p = subprocess.run(["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"],
                           capture_output=True, text=True, timeout=20)
        name = (p.stdout or "").strip().splitlines()[0].strip()
        if name:
            return name
    except Exception:
        pass
    return fallback

def _apply_hw(meta):
    meta.hardware.gpu_model   = HW["gpu_model"]
    meta.hardware.arch_target = HW["arch_target"]
    meta.hardware.environment = HW["environment"]
    return meta

SIZE_SCALE_REF = 2048
WARMUP_MIN = 2
ITERS_MIN  = 5

def scaled_counts(base_warmup, base_iters, size):
    if size <= SIZE_SCALE_REF:
        return base_warmup, base_iters
    frac = (SIZE_SCALE_REF / size) ** 3
    return (max(WARMUP_MIN, round(base_warmup * frac)),
            max(ITERS_MIN,  round(base_iters  * frac)))

def sh(cmd, **kw):
    print("  $", " ".join(str(c) for c in cmd), file=sys.stderr)
    return subprocess.run([str(c) for c in cmd], **kw)

# --------------------------------------------------------------------------------------
# §5 of plan/benchmark-harness.md — verification does not scale, and it is the real ceiling.
#
# The generated auto-bench harness validates with a HOST reference matmul: an OpenMP'd but
# cache-hostile triple loop, O(N^3).  At N=16384 that is 8.8 TFLOP (~a minute); at N=32768 it is
# 7.0e13 FLOP (many minutes) plus three 4.3 GB host allocations.  The NVIDIA canonical size list
# goes to 32768 where Intel's stops at 16384, which is why this bit on an H100 and not on BMG.
#
# The harness prints its BENCH line BEFORE the reference check.  So we do not need a compiler-side
# "bench without verify" flag (there isn't one -- --mma-bench implies --mma-test): we stream the
# child's output, and above VERIFY_MAX_N we stop at BENCH and terminate it.  Correctness is still
# established at every size <= VERIFY_MAX_N, which is the split §5 asks for -- the tile loops are
# the same code at 16384 as at 2048.
#
# Every benchmark child also gets a WALL TIMEOUT.  Verification is not the only way to hang: a
# deadlocking kernel (cluster/barrier chapters have a known padded-grid failure mode) would
# otherwise wedge the whole sweep with no diagnostic.  A timeout turns that into one lost point.
# --------------------------------------------------------------------------------------
VERIFY_MAX_N   = 2048     # full host-reference verification at or below this size
BENCH_TIMEOUT  = 900.0    # seconds per benchmark binary, verification included
_BENCH_RE      = re.compile(r'^\s*BENCH\b')

# §3 of plan/benchmark-harness.md, for the AUTO-BENCH path specifically.
#
# scaled_counts() bounds the timed loop for competitor binaries, which take warmup/iters as argv.
# The generated auto-bench harness does NOT: crisp-hoist-cuda bakes `const int WARMUP = 20,
# ITERS = 100;` into the .cu and --mma-bench has no flag to override it.  So every auto-bench
# point ran 120 iterations regardless of size -- for chap0_naive (no tensor cores, ~8 s/iter at
# 16384) that is ~16 minutes for ONE point, and ~2.2 hours at 32768.  That, not verification, is
# what made the H100 sweep look hung.
#
# The runner already rewrites this .cu to repoint its PTX path, so the counts are rewritten in the
# same pass.  No compiler change, and the harness's GFLOPS formula divides by ITERS so it stays
# consistent with whatever we substitute.
_COUNTS_RE = re.compile(r'const\s+int\s+WARMUP\s*=\s*\d+\s*,\s*ITERS\s*=\s*\d+\s*;')

def _rewrite_bench_counts(txt: str, n: int, base_warmup: int = 20, base_iters: int = 100) -> str:
    w, it = scaled_counts(base_warmup, base_iters, n)
    new, k = _COUNTS_RE.subn(f"const int WARMUP = {w}, ITERS = {it};", txt)
    if k == 0:
        print(f"  (note: could not rewrite WARMUP/ITERS in the generated harness for N={n}; "
              f"it will use the baked-in 20/100)", file=sys.stderr)
    return new

def should_full_verify(n: int) -> bool:
    """Full host-reference verification only for N <= VERIFY_MAX_N (§5)."""
    return n <= VERIFY_MAX_N

def run_bench_proc(cmd, *, verify: bool, timeout: float = BENCH_TIMEOUT, cwd=None, env=None):
    """Run a benchmark binary, streaming stdout.

    Returns (output_text, status) where status is one of "ok", "early" (stopped at BENCH by
    design), "timeout", or "error".  stderr is folded into stdout so a parse failure still shows
    the child's complaint.
    """
    import threading
    cmd = [str(c) for c in cmd]
    print("  $", " ".join(cmd), file=sys.stderr)
    try:
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             text=True, bufsize=1, cwd=cwd, env=env)
    except OSError as e:
        return (f"failed to launch: {e}", "error")

    lines, state = [], {"early": False}

    def _reader():
        try:
            for line in p.stdout:
                lines.append(line)
                if not verify and _BENCH_RE.match(line):
                    state["early"] = True
                    return          # got the number; the host reference is not worth waiting for
        except Exception:
            pass

    t = threading.Thread(target=_reader, daemon=True)
    t.start()
    t.join(timeout)
    timed_out = t.is_alive()

    if timed_out or state["early"]:
        p.kill()
    try:
        p.wait(timeout=10)
    except Exception:
        pass
    t.join(2)

    out = "".join(lines)
    if timed_out:
        return (out, "timeout")
    if state["early"]:
        return (out, "early")
    return (out, "ok" if p.returncode == 0 else "error")

# §4 of plan/benchmark-harness.md, adaptively rather than as a per-chapter table.
#
# Matmul work grows as N^3, so ONE size doubling is 8x the work.  A point that took ~90s is
# therefore certain to blow the 900s BENCH_TIMEOUT at the next size up.  Attempting it anyway
# costs 900 wasted seconds and yields NOTHING -- the point is skipped either way.  Measured on
# the H100: chap0_naive (no tensor cores) collapses to ~0.55 TFLOPS at 32768, and every naive
# chapter x contender x precision combination burned a full timeout there.
#
# So: once a point is this slow, stop growing the size for THAT contender.  This removes no data
# that would otherwise have been collected -- it only declines to wait for a known failure.  The
# skip is announced, so a gap in the table is attributable rather than mysterious.
SIZE_GIVEUP_SECONDS = 90.0

# ...and a SIZE-SCALED timeout, because the give-up above cannot catch a CLIFF.
#
# It predicts the next size from the last one assuming N^3 scaling (8x per doubling).  Measured on
# the H100 that assumption fails exactly where it matters: chap0_naive completes 16384 in seconds
# and then collapses at 32768 -- roughly 60x, not 8x -- because the naive kernel falls off a cache
# cliff.  No extrapolation from 16384 can see that coming.
#
# So bound the WAIT instead of predicting.  At 32768 anything worth measuring finishes its 7
# iterations in well under ~20s (cuBLAS ~1.3s, Crisp wgmma ~1.8s); 150s is a 7x margin.  A kernel
# that needs longer is reporting "this does not work at this scale", which the resulting gap in
# the table already says -- at 1/6th the wall time.
XL_SIZE_THRESHOLD = 16384
XL_BENCH_TIMEOUT  = 150.0

def bench_timeout_for(n: int) -> float:
    return XL_BENCH_TIMEOUT if n > XL_SIZE_THRESHOLD else BENCH_TIMEOUT

def _too_slow_to_grow(chapter, comp_name, S, elapsed):
    if elapsed < SIZE_GIVEUP_SECONDS:
        return False
    nxt = bench_timeout_for(S * 2)
    print(f"  ! {chapter} ({comp_name}) {S}^3 took {elapsed:.0f}s; larger sizes would exceed their "
          f"{nxt:.0f}s timeout — skipping them", file=sys.stderr)
    return True

class ContenderBuildError(Exception):
    """A contender failed to COMPILE.  Distinct from a crash at run time, and -- importantly --
    survivable: one contender that cannot be built must not abort the whole sweep.

    Carries the compiler's own diagnostic so the skip line says WHY, which is the difference
    between "SYCL-TLA skipped" and "SYCL-TLA skipped: cutlass/... file not found" -- the latter
    tells you to run scripts/setup-third-party.sh."""
    def __init__(self, name, cmd, returncode, output):
        self.name, self.cmd, self.returncode, self.output = name, cmd, returncode, output
        super().__init__("%s failed to build (exit %s)" % (name, returncode))


def time_compile(cmd, name=None, **kw):
    """Compile, returning wall-clock ms.  Raises ContenderBuildError on a non-zero exit.

    Output is captured rather than inherited so the reason for a failure can be attached to the
    exception (and printed once, at the skip site) instead of being interleaved into the sweep log
    at a point where it looks like it belongs to whichever contender ran last."""
    kw.setdefault("capture_output", True)
    kw.setdefault("text", True)
    t0 = time.time()
    res = sh(cmd, **kw)
    t1 = time.time()
    if res.returncode != 0:
        out = (res.stdout or "") + (res.stderr or "")
        raise ContenderBuildError(name or Path(cmd[-1]).name, cmd, res.returncode, out)
    return (t1 - t0) * 1000.0

def time_device_only_compile(compiler, flags, src_path, out_dir, is_sycl):
    dev_out = Path(out_dir) / (Path(src_path).stem + (".devbc" if is_sycl else ".devptx"))
    keep = [f for f in flags if not f.startswith("-l") and f != "-qmkl"]
    if is_sycl:
        attempts = [[compiler, *keep, "-fsycl-device-only", "-fsycl-targets=spir64",
                     str(src_path), "-o", str(dev_out)],
                    [compiler, *keep, "-fsycl-device-only", str(src_path), "-o", str(dev_out)]]
    else:
        attempts = [[compiler, *keep, "-ptx", str(src_path), "-o", str(dev_out)]]

    r, ms = None, 0.0
    for cmd in attempts:
        try:
            t0 = time.time()
            r = sh(cmd, capture_output=True, text=True)
            ms = (time.time() - t0) * 1000.0
        except Exception as e:
            print(f"  (device-only compile could not run: {e})", file=sys.stderr)
            r = None
            continue
        if r.returncode == 0:
            break
    if dev_out.exists():
        try: dev_out.unlink()
        except OSError: pass
    if r is None:
        return None
    if r.returncode != 0:
        print(f"  (device-only compile failed for {Path(src_path).name}; omitting its compile time)", file=sys.stderr)
        return None
    return ms

def _extract_json_object(text: str):
    """Pull the last top-level {...} object out of a stream that may also carry diagnostics.

    Scans for balanced braces while ignoring braces inside double-quoted strings (so a message
    like `"note": "{unused}"` cannot end the object early).  Returns the parsed dict, or None if
    no balanced object in the text parses.  The LAST object wins: a harness prints its result
    after whatever it had to say first.
    """
    found = None
    depth = 0
    start = -1
    in_str = False
    esc = False
    for i, ch in enumerate(text):
        if in_str:
            if esc:            esc = False
            elif ch == "\\":   esc = True
            elif ch == '"':    in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == "{":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "}":
            if depth > 0:
                depth -= 1
                if depth == 0 and start >= 0:
                    try:
                        found = json.loads(text[start:i + 1])
                    except Exception:
                        pass
                    start = -1
    return found

def run_bin(path, M, N, K, warmup, iters, env_extra=None):
    env = dict(os.environ)
    if env_extra: env.update(env_extra)
    # cwd is the BINARY'S OWN directory.  This used to be HERE/"crisp", which the benchmark
    # reorganisation removed along with the technique-named chapters -- a non-existent cwd makes
    # Popen raise rather than run.  A competitor binary lives in its chapter dir and any relative
    # file it wants is there too.
    out, status = run_bench_proc([path, M, N, K, warmup, iters],
                                 verify=True,          # competitor harnesses emit JSON, not BENCH
                                 timeout=bench_timeout_for(N),
                                 cwd=str(Path(path).parent), env=env)
    if status != "ok":
        print(f"  ! {Path(path).name} {M}x{N}x{K}: {status}\n{out[-800:]}", file=sys.stderr)
        return None
    try:
        return json.loads(out)
    except Exception:
        pass
    # A harness is allowed to say something on stderr before its JSON, and run_bench_proc folds
    # stderr INTO stdout on purpose (so a parse failure still shows the child's complaint).  Those
    # two deliberate choices collide: strict json.loads() over the merged stream fails, run_bin
    # returns None, and run_sweep's `if not out: continue` drops the point SILENTLY -- it never
    # reaches the correct=false gate, so nothing says "dropped" either.
    #
    # That is not hypothetical.  The SYCL-TLA peer gained an MMA_CORRECT/MMA_WRONG self-check line
    # on stderr on 2026-08-27; from that moment it could not record a point no matter how correct
    # it was, and the empty peer column looked exactly like the runtime bug it was sitting behind.
    # Recover the JSON object instead of requiring the whole stream to be one.
    obj = _extract_json_object(out)
    if obj is not None:
        return obj
    print(out[-800:], file=sys.stderr)
    return None

def build_harness():
    harness = HERE / "crisp" / "bench_harness.cu"
    if harness.exists():
        sh(["nvcc", "-O3", "-arch=sm_90", *nvcc_math_flags("ieee", False),
            str(harness), "-lcuda", "-o", str(HERE/"crisp/matmul_crisp")], check=True)

def run_sweep(chapter: str, exe_path: str, competitor_name: str, sizes: list, warmup: int, iters: int, precision: str, ftz: bool, compile_dev_ms: float, compile_all_ms: float, env_extra: dict = None) -> BenchmarkSweep:
    meta = _apply_hw(create_metadata())
    results = []
    for s in sizes:
        S = int(s)
        w, it = scaled_counts(warmup, iters, S)
        _t0 = time.time()
        out = run_bin(exe_path, S, S, S, w, it, env_extra)
        _el = time.time() - _t0
        if not out:
            if _too_slow_to_grow(chapter, competitor_name, S, _el): break
            continue

        if not out.get("correct", True):
            print(f"  DROPPED {competitor_name} @ {S}: harness reported correct=false "
                  f"(max_abs_err={out.get('max_abs_err')})", file=sys.stderr)
            continue

        driver_jit = out.get("driver_jit_ms", 0.0)
        final_all_compile_ms = compile_all_ms + driver_jit

        point = SweepPoint(
            configuration={"m": S, "n": S, "k": S, "warmup": w, "iters": it,
                           "verified": bool(out.get("verified", True))},
            metrics=BenchmarkMetrics(
                compile_time=CompileTimeMetrics(device_compile_ms=compile_dev_ms, all_compile_ms=final_all_compile_ms), 
                runtime=RuntimeMetrics(wall_time_ms=out.get("wall_time_ms", 0.0), kernel_execution_ms=out.get("kernel_median_us", 0.0)/1000.0),
                throughput=ThroughputMetrics(tflops=out.get("gflops", 0.0)/1000.0)
            )
        )
        results.append(point)
        if _too_slow_to_grow(chapter, competitor_name, S, _el): break

    return BenchmarkSweep(
        run_metadata=meta,
        benchmark_suite="matmul",
        chapter=chapter,
        competitor=competitor_name,
        precision=precision,
        denormal_handling="ftz" if ftz else "preserve",
        results=results
    )

def _hoist_cuda_bin(crisp_compiler):
    p = Path(crisp_compiler)
    return str(p.parent / ("crisp-hoist-cuda" + (".exe" if p.suffix == ".exe" else "")))

def run_crisp_autobench(src_path: Path, grid_tile: str, M: int, N: int, K: int, crisp_compiler: str,
                        prec_flags=(), nvcc_math=()):
    chap_dir = src_path.parent
    base = src_path.stem
    ptx = chap_dir / f"{base}.ptx"
    metacrisp = chap_dir / f"{base}_matmul.metacrisp"
    if not (ptx.exists() and metacrisp.exists()):
        sh([crisp_compiler, "--ir-target=ptx", "--ir-target-arch=sm_90", f"--hardware-profile={NVIDIA_HW_PROFILE}", *prec_flags, "--log-level=off", str(src_path)], check=True)
        sh([crisp_compiler, "--hoist=cuda", "--ir-target-arch=sm_90", f"--hardware-profile={NVIDIA_HW_PROFILE}", *prec_flags, "--log-level=off", str(src_path)], check=True)
    if not metacrisp.exists():
        print(f"autobench: no metacrisp {metacrisp}", file=sys.stderr); return None
    sh([_hoist_cuda_bin(crisp_compiler), f"--mma-bench={M},{N},{K}", f"--grid-tile={grid_tile}", str(metacrisp)])
    cu = chap_dir / f"{base}_matmul_CUDA.cu"
    if not cu.exists():
        print(f"autobench: no bench .cu {cu}", file=sys.stderr); return None
    txt = cu.read_text()
    txt = re.sub(r'"[^"]*' + re.escape(base) + r'\.ptx"', '"' + str(ptx).replace("\\", "/") + '"', txt)
    txt = _rewrite_bench_counts(txt, N)
    cu.write_text(txt)
    exe = chap_dir / f"{base}_bench"
    c = sh(["nvcc", "-O3", "-arch=sm_90a", "-Xcompiler", "-fopenmp", *nvcc_math, str(cu), "-o", str(exe), "-lcuda"], capture_output=True, text=True)
    if c.returncode != 0:
        print("autobench nvcc failed:\n" + (c.stderr or "")[-1200:], file=sys.stderr); return None
    verify = should_full_verify(N)
    out, status = run_bench_proc([str(exe)], verify=verify, timeout=bench_timeout_for(N))
    if status == "timeout":
        print(f"  ! autobench {N}^3 TIMED OUT after {bench_timeout_for(N):.0f}s — skipping point", file=sys.stderr)
        return None
    m = re.search(r'BENCH\s+matmul\s+\d+x\d+x\d+:\s*([\d.]+)\s*GFLOPS\s*\(([\d.eE+-]+)\s*ms/iter\)', out)
    if not m:
        print(f"autobench parse failed (status={status}):\n" + out[-800:], file=sys.stderr); return None
    # Above VERIFY_MAX_N the child is terminated before its host reference runs, so there is no
    # MMA_CORRECT to find.  Report correctness as None (unknown) rather than False, so a caller
    # cannot mistake "not checked at this size" for "checked and wrong".
    return {"gflops": float(m.group(1)), "kernel_median_us": float(m.group(2)) * 1000.0,
            "correct": ("MMA_CORRECT" in out) if verify else None,
            "verified": verify,
            "wall_time_ms": 0.0, "driver_jit_ms": 0.0}

def run_autobench_sweep(chapter, src_path, grid_tile, comp_name, sizes, warmup, iters,
                        precision, ftz, dev_c_ms, crisp_compiler):
    meta = _apply_hw(create_metadata())
    prec_flags = [f"--math-precision={precision}",
                  f"--denormal-handling={'ftz' if ftz else 'preserve'}"]
    nvcc_math = nvcc_math_flags(precision, ftz)
    src = Path(src_path)
    stale = src.parent / f"{src.stem}_matmul.metacrisp"
    if stale.exists():
        stale.unlink()
    results = []
    for s in sizes:
        S = int(s)
        _t0 = time.time()
        out = run_crisp_autobench(src, grid_tile, S, S, S, crisp_compiler, prec_flags, nvcc_math)
        _el = time.time() - _t0
        if not out:
            if _too_slow_to_grow(chapter, comp_name, S, _el): break
            continue
        # correct is None when the size is above VERIFY_MAX_N and the host reference was
        # deliberately not run (§5).  Only a MEASURED failure discards the point; "not checked"
        # must not be read as "wrong", or every large size would silently vanish from the report.
        if out.get("correct") is False:
            print(f"  ! {chapter} ({comp_name}) {S}^3: NOT MMA_CORRECT — skipping point", file=sys.stderr)
            continue
        results.append(SweepPoint(
            configuration={"m": S, "n": S, "k": S, "warmup": warmup, "iters": iters,
                           "verified": bool(out.get("verified", True))},
            metrics=BenchmarkMetrics(
                compile_time=CompileTimeMetrics(device_compile_ms=dev_c_ms,
                                                all_compile_ms=dev_c_ms + out.get("driver_jit_ms", 0.0)),
                runtime=RuntimeMetrics(wall_time_ms=out.get("wall_time_ms", 0.0),
                                       kernel_execution_ms=out.get("kernel_median_us", 0.0) / 1000.0),
                throughput=ThroughputMetrics(tflops=out.get("gflops", 0.0) / 1000.0))))
        if _too_slow_to_grow(chapter, comp_name, S, _el): break
    return BenchmarkSweep(run_metadata=meta, benchmark_suite="matmul", chapter=chapter, competitor=comp_name,
                          precision=precision, denormal_handling="ftz" if ftz else "preserve", results=results)

def _hoist_l0_bin(crisp_compiler):
    p = Path(crisp_compiler)
    return str(p.parent / ("crisp-hoist-l0" + (".exe" if p.suffix == ".exe" else "")))

def run_l0_autobench(src_path: Path, M: int, N: int, K: int, warmup: int, iters: int, crisp_compiler: str,
                     prec_flags=(), cxx_flags=()):
    chap_dir = src_path.parent
    base = src_path.stem
    spv = chap_dir / f"{base}.spv"
    metacrisp = chap_dir / f"{base}_matmul.metacrisp"
    compile_ms = 0.0
    hoist_ms = 0.0
    if not (spv.exists() and metacrisp.exists()):
        compile_ms = time_compile([crisp_compiler, "--ir-target=spv", f"--hardware-profile={INTEL_HW_PROFILE}", *prec_flags, "--log-level=off", str(src_path)], name=src_path.stem)
        hoist_ms = time_compile([crisp_compiler, "--hoist=l0", f"--hardware-profile={INTEL_HW_PROFILE}", *prec_flags, "--log-level=off", str(src_path)])
    if not metacrisp.exists():
        print(f"autobench-l0: no metacrisp {metacrisp}", file=sys.stderr); return None
    
    sh([_hoist_l0_bin(crisp_compiler), f"--mma-test={M},{N},{K}", f"--mma-bench={iters}", str(metacrisp)])
    cpp = chap_dir / f"{base}_matmul_L0.cpp"
    if not cpp.exists():
        print(f"autobench-l0: no bench .cpp {cpp}", file=sys.stderr); return None
    
    txt = cpp.read_text()
    txt = re.sub(r'"[^"]*' + re.escape(base) + r'\.spv"', '"' + str(spv).replace("\\", "/") + '"', txt)
    txt = _rewrite_bench_counts(txt, N)
    cpp.write_text(txt)
    
    exe = chap_dir / f"{base}_bench_l0"
    cxx, link_pre, link_post = _resolve_cxx_and_l0_link()
    c = sh([cxx, "-O3", *cxx_flags, str(cpp), *link_pre, "-o", str(exe), *link_post], capture_output=True, text=True)
    if c.returncode != 0:
        print("autobench-l0 build failed:\n" + (c.stderr or "")[-1200:], file=sys.stderr); return None
    
    verify = should_full_verify(N)
    out, status = run_bench_proc([str(exe)], verify=verify, timeout=bench_timeout_for(N))
    if status == "timeout":
        print(f"  ! autobench-l0 {N}^3 TIMED OUT after {bench_timeout_for(N):.0f}s — skipping point", file=sys.stderr)
        return None
    m = re.search(r'BENCH\s+(\d+)\s+(\d+)\s+(\d+)\s+([\d.]+)\s*GFLOPS\s*\((\d+)\s*iters,\s*([\d.eE+-]+)\s*s\)', out)
    if not m:
        print(f"autobench-l0 parse failed (status={status}):\n" + out[-800:], file=sys.stderr); return None
    gflops = float(m.group(4))
    secs = float(m.group(6))
    iters_ran = int(m.group(5))
    mm = re.search(r'median_us=([\d.eE+-]+)', out)
    k_us = float(mm.group(1)) if mm else (secs / iters_ran) * 1e6
    method = re.search(r'method=(\w+)', out)
    return {"gflops": gflops, "kernel_median_us": k_us,
            "timing_method": method.group(1) if method else "batched_submit_legacy",
            "compile_ms": compile_ms, "hoist_ms": hoist_ms,
            "correct": ("MMA_CORRECT" in out) if verify else None,
            "verified": verify,
            "wall_time_ms": 0.0, "driver_jit_ms": 0.0}

def run_l0_autobench_sweep(chapter, src_path, comp_name, sizes, warmup, iters,
                           precision, ftz, dev_c_ms, crisp_compiler):
    meta = _apply_hw(create_metadata())
    prec_flags = [f"--math-precision={precision}",
                  f"--denormal-handling={'ftz' if ftz else 'preserve'}"]
    src = Path(src_path)
    stale = src.parent / f"{src.stem}_matmul.metacrisp"
    if stale.exists():
        stale.unlink()
    results = []
    measured_c_ms = 0.0
    measured_hoist_ms = 0.0
    for s in sizes:
        S = int(s)
        if S > 8192:
            continue
        w, it = scaled_counts(warmup, iters, S)
        out = run_l0_autobench(src, S, S, S, w, it, crisp_compiler, prec_flags, [])
        if not out:
            continue
        if out.get("compile_ms", 0.0) > 0.0:
            measured_c_ms = out["compile_ms"]
            measured_hoist_ms = out.get("hoist_ms", 0.0)
        # correct is None when the size is above VERIFY_MAX_N and the host reference was
        # deliberately not run (§5).  Only a MEASURED failure discards the point; "not checked"
        # must not be read as "wrong", or every large size would silently vanish from the report.
        if out.get("correct") is False:
            print(f"  ! {chapter} ({comp_name}) {S}^3: NOT MMA_CORRECT — skipping point", file=sys.stderr)
            continue
        results.append(SweepPoint(
            configuration={"m": S, "n": S, "k": S, "warmup": w, "iters": it,
                           "verified": bool(out.get("verified", True))},
            metrics=BenchmarkMetrics(
                # Driver JIT added for the same reason as the fixed-sweep path below: this total is
                # compile-to-native.  The autobench harness is hoist-generated and does not report
                # driver_jit_ms today, so this contributes 0 there and becomes correct for free if
                # that harness ever does -- rather than being a second place to forget.
                compile_time=CompileTimeMetrics(device_compile_ms=measured_c_ms or dev_c_ms,
                                                all_compile_ms=((measured_c_ms + measured_hoist_ms) or dev_c_ms)
                                                                + out.get("driver_jit_ms", 0.0)),
                runtime=RuntimeMetrics(wall_time_ms=out.get("wall_time_ms", 0.0),
                                       kernel_execution_ms=out.get("kernel_median_us", 0.0) / 1000.0),
                throughput=ThroughputMetrics(tflops=out.get("gflops", 0.0) / 1000.0))))
    if measured_c_ms > 0.0:
        for p in results:
            if p.metrics.compile_time.device_compile_ms == 0.0:
                p.metrics.compile_time.device_compile_ms = measured_c_ms
                p.metrics.compile_time.all_compile_ms = measured_c_ms + measured_hoist_ms
    return BenchmarkSweep(run_metadata=meta, benchmark_suite="matmul", chapter=chapter, competitor=comp_name,
                          precision=precision, denormal_handling="ftz" if ftz else "preserve", results=results)

def _resolve_cxx_and_l0_link():
    if _platform.system() == "Windows":
        clang  = os.environ.get("CRISP_CLANGXX",
                 "C:/Users/cperk/Documents/llvm-mingw-20251216-ucrt-x86_64/bin/clang++.exe")
        lz_inc = os.environ.get("CRISP_L0_INCLUDE", "C:/Users/cperk/Documents/level-zero/include")
        ze     = os.environ.get("CRISP_ZE_LOADER", "C:/Windows/System32/ze_loader.dll")
        return clang, ["-I", lz_inc], [ze, "-static"]
    cxx = shutil.which("icpx") or shutil.which("clang++") or "g++"
    return cxx, [], ["-lze_loader"]

def run_l0_bin(path, M, N, K, warmup, iters, env_extra=None):
    env = dict(os.environ)
    if env_extra: env.update(env_extra)
    # Timeout only: this harness emits JSON on completion rather than a BENCH line, so there is
    # nothing to stop early at -- but it still must not be able to wedge the sweep.
    out, status = run_bench_proc([path, M, N, K, warmup, iters], verify=True,
                                 timeout=bench_timeout_for(N), env=env)
    if status != "ok":
        print(f"  ! {Path(path).name} {M}x{N}x{K}: {status}\n{out[-600:]}", file=sys.stderr)
        return None
    try:
        return json.loads(out)
    except Exception:
        print(out[-600:], file=sys.stderr)
        return None

def _sexp_after(text, key):
    """The balanced s-expression following KEY in a metacrisp, as a string, or ''."""
    i = text.find(key)
    if i < 0:
        return ""
    i = text.find("(", i)
    if i < 0:
        return ""
    d, j = 0, i
    while j < len(text):
        if text[j] == "(":
            d += 1
        elif text[j] == ")":
            d -= 1
            if d == 0:
                return text[i:j + 1]
        j += 1
    return ""


def l0_fixture_env(crisp_src, metacrisp):
    """Environment for bench_harness_l0.cpp, DERIVED from what the compiler recorded.

    Nothing here is restated by the caller: local size, grid strategy, tile shape and the register
    mode all come from the metacrisp, and the element type from the kernel source.  A call site that
    had to repeat them could drift from the kernel, which is the failure this fixture exists to end.
    """
    env = {}
    try:
        meta = Path(metacrisp).read_text(errors="replace")
    except Exception:
        meta = ""
    try:
        src = Path(crisp_src).read_text(errors="replace")
    except Exception:
        src = ""

    ls = _sexp_after(meta, ":local-size")
    nums = re.findall(r"\d+", ls)
    if nums:
        dims = (nums + ["1", "1"])[:3]
        env["CRISP_MATMUL_LOCAL"] = ",".join(dims)

    gs = _sexp_after(meta, ":global-size")
    env["CRISP_MATMUL_GRID"] = "one-thread-per" if ":one-thread-per" in gs else "strided"
    tshape = _sexp_after(gs, ":tile-shape")
    tnums = re.findall(r"\d+", tshape)
    if len(tnums) >= 2:
        env["CRISP_MATMUL_TILE"] = f"{tnums[0]},{tnums[1]}"

    m = re.search(r"matrix\s+(bfloat16|half|float)", src)
    if m:
        env["CRISP_MATMUL_ELEM"] = {"bfloat16": "bf16", "half": "f16", "float": "f32"}[m.group(1)]

    m = re.search(r":selected-registers-per-thread\s+(\d+)", meta)
    if m:
        # The compiler picked this mode; the harness must ask the JIT for the same one, or the
        # kernel it measures is not the kernel that was compiled.  Missing this was a 14x error.
        env["CRISP_MATMUL_BUILD_FLAGS"] = ("-ze-opt-large-register-file" if int(m.group(1)) > 128 else "")

    km = re.search(r"\(def-kernel\s+([A-Za-z0-9_\-]+)", src)
    if km:
        env["CRISP_MATMUL_KERNEL"] = km.group(1)

    # SLM scratch tensors are passed as LEADING kernel arguments, so A/B/C are NOT at 0/9/18.
    # The fixture binds the three global tensors at fixed offsets and has no way to allocate a
    # group-local argument (which needs zeKernelSetArgumentValue(i, bytes, nullptr) plus extents
    # taken from the kernel source).  Rather than bind the global tensors onto the SLM slots -- which
    # produced a nonsense 135848 GFLOPS before verification rejected it -- say so and let the caller
    # use the generated harness, which does handle these kernels.
    env["_fixture_unsupported"] = ("scratch/SLM tensor arguments"
                                   if "ADDRESS-SPACE LOCAL" in meta.upper() else "")
    return env


def build_l0_harness(crisp_compiler):
    harness = HERE / "crisp" / "bench_harness_l0.cpp"
    if not harness.exists():
        print(f"Skipping Intel Crisp — {harness} not found."); return None
    cxx, link_pre, link_post = _resolve_cxx_and_l0_link()
    binexe = HERE / "crisp" / ("matmul_crisp_l0" + (".exe" if _platform.system() == "Windows" else ""))
    c = sh([cxx, "-O3", str(harness), *link_pre, "-o", str(binexe), *link_post], capture_output=True, text=True)
    if c.returncode != 0:
        print("L0 harness build failed:\n" + (c.stderr or "")[-1200:], file=sys.stderr); return None
    return str(binexe)

def run_l0_fixed_sweep(chapter, kernel_src, comp_name, harness_bin, sizes, warmup, iters,
                       precision, ftz, crisp_compiler):
    meta = _apply_hw(create_metadata())
    src = Path(kernel_src)
    spv = src.parent / f"{src.stem}.spv"
    prec_flags = [f"--math-precision={precision}",
                  f"--denormal-handling={'ftz' if ftz else 'preserve'}"]
    empty = BenchmarkSweep(run_metadata=meta, benchmark_suite="matmul", chapter=chapter,
                           competitor=comp_name, precision=precision,
                           denormal_handling="ftz" if ftz else "preserve", results=[])
    try:
        dev_c_ms = time_compile([crisp_compiler, "--ir-target=spv", f"--hardware-profile={INTEL_HW_PROFILE}",
                                 *prec_flags, "--log-level=off", str(src)])
    except subprocess.CalledProcessError:
        print(f"l0-fixed: crisp-compile failed for {src.name}", file=sys.stderr); return empty
    if not spv.exists():
        print(f"l0-fixed: no spv {spv}", file=sys.stderr); return empty
    # The metacrisp carries the dispatch geometry and the register mode the compiler chose.
    # Generate it (metadata only -- this does not produce the harness we are replacing) and derive
    # the fixture's environment from it, so nothing about the launch is restated by hand.
    try:
        sh([crisp_compiler, "--hoist=l0", f"--hardware-profile={INTEL_HW_PROFILE}",
            *prec_flags, "--log-level=off", str(src)], capture_output=True, text=True)
    except Exception:
        pass
    metacrisp = next(iter(sorted(src.parent.glob(f"{src.stem}_*.metacrisp"))), None)
    env_ext = {"CRISP_MATMUL_SPV": str(spv)}
    if metacrisp:
        _e = l0_fixture_env(src, metacrisp)
        _e.pop("_fixture_unsupported", None)   # an internal flag, not an env var
        env_ext.update(_e)
    else:
        print(f"l0-fixed: no metacrisp for {src.name}; using fixture defaults", file=sys.stderr)
    results = []
    for s in sizes:
        S = int(s)
        w, it = scaled_counts(warmup, iters, S)
        out = run_l0_bin(harness_bin, S, S, S, w, it, env_extra=env_ext)
        if not out:
            continue
        results.append(SweepPoint(
            configuration={"m": S, "n": S, "k": S, "warmup": w, "iters": it,
                           "verified": bool(out.get("verified", True))},
            metrics=BenchmarkMetrics(
                # all_compile_ms is compile-to-NATIVE, so it must include the driver JIT.  It was
                # hardcoded to dev_c_ms -- SPIR-V emission only -- which made Crisp's "total build"
                # identical to its device codegen and silently omitted the zeModuleCreate compile
                # the other contenders pay inside their AOT build.  bench_harness_l0.cpp now
                # reports driver_jit_ms; .get keeps this working with older result JSONs.
                compile_time=CompileTimeMetrics(device_compile_ms=dev_c_ms,
                                                all_compile_ms=dev_c_ms + out.get("driver_jit_ms", 0.0)),
                runtime=RuntimeMetrics(wall_time_ms=out.get("wall_time_ms", 0.0),
                                       kernel_execution_ms=out.get("kernel_median_us", 0.0) / 1000.0),
                throughput=ThroughputMetrics(tflops=out.get("gflops", 0.0) / 1000.0))))
    return BenchmarkSweep(run_metadata=meta, benchmark_suite="matmul", chapter=chapter, competitor=comp_name,
                          precision=precision, denormal_handling="ftz" if ftz else "preserve", results=results)

def nvcc_math_flags(prec, ftz):
    b = lambda x: "true" if x else "false"
    return [f"-ftz={b(ftz)}",
            f"-prec-div={b(prec != 'fast')}",
            f"-prec-sqrt={b(prec != 'fast')}",
            "-fmad=true"]

def icpx_math_flags(prec, ftz):
    return [f"-fp-model={'fast' if prec == 'fast' else 'precise'}",
            "-ffp-contract=fast",
            ("-ftz" if ftz else "-no-ftz")]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sizes", default="canonical")
    ap.add_argument("--warmup", type=int, default=20)
    ap.add_argument("--iters", type=int, default=100)
    ap.add_argument("--output-dir", default=str(HERE.parent / "results"))
    ap.add_argument("--precision", choices=["ieee", "fast"], default="fast")
    ap.add_argument("--ftz", action="store_true", help="Enable Flush-To-Zero")
    ap.add_argument("--sweep-all", action="store_true", help="Run full precision matrix (Fast, IEEE+FTZ, IEEE)")
    ap.add_argument("--scratch", action="store_true", help="Force saving to results/scratch/")
    ap.add_argument("--chapters", default="",
                    help="Comma-separated chapter dirs to run (default: all).")
    ap.add_argument("--platform", choices=["nvidia", "intel"], default="nvidia",
                    help="nvidia (default) or intel.")
    a = ap.parse_args()

    global HW, SIZE_SCALE_REF
    HW = dict(HW_BY_PLATFORM[a.platform])
    if a.platform == "nvidia":
        HW["gpu_model"] = _detect_gpu_model(HW["gpu_model"])
        print(f"Hardware detected: {HW['gpu_model']}")
    SIZE_SCALE_REF = 1024 if a.platform == "intel" else 2048

    SIZE_PRESETS = {
        "small": ["256", "512", "1024"],
        "medium": ["2048", "4096"],
        "large": ["8192", "16384"],
        "xl": ["32768", "40960"],
        "canonical": ["256", "512", "1024", "2048", "4096", "8192", "16384"] if a.platform == "intel" else ["256", "512", "1024", "2048", "4096", "8192", "16384", "32768"],
        "all": ["256", "512", "1024", "2048", "4096", "8192", "16384"] if a.platform == "intel" else ["256", "512", "1024", "2048", "4096", "8192", "16384", "32768", "40960"],
    }

    raw_sizes = [x.strip() for x in a.sizes.split(",") if x.strip()]
    sizes = []
    for s in raw_sizes:
        if s.lower() in SIZE_PRESETS:
            sizes.extend(SIZE_PRESETS[s.lower()])
        else:
            sizes.append(s)
    # Deduplicate while preserving order
    seen = set()
    sizes = [x for x in sizes if not (x in seen or seen.add(x))]

    base_out_dir = Path(a.output_dir)
    out_dir = base_out_dir / "scratch" if a.scratch else base_out_dir

    matrix = [(a.precision, a.ftz)]
    if a.sweep_all:
        matrix = [
            ("fast", True),
            ("ieee", True),
            ("ieee", False)
        ]

    repo_root = HERE.parent.parent
    exe_name = "crisp-compile.exe" if sys.platform.startswith("win") else "crisp-compile"
    crisp_compiler = str(repo_root / "bin" / exe_name)

    l0_harness = None
    if a.platform == "nvidia":
        build_harness()
    else:
        l0_harness = build_l0_harness(crisp_compiler)

    for prec, ftz in matrix:
        print(f"\n--- Running Suite with precision={prec}, ftz={ftz} ---")
        
        nv_math = nvcc_math_flags(prec, ftz)
        nvcc_flags   = ["-O3", "-arch=sm_90", *nv_math]
        cublas_flags = ["-O3", "-arch=sm_90", "-lcublas", *nv_math]
        if prec == "fast":
            cublas_flags.append("-DFAST_MATH")
        sycl_flags   = ["-fsycl", "-O3", *icpx_math_flags(prec, ftz)]
        if prec == "fast":
            sycl_flags.append("-DFAST_MATH")

        _want = set(x.strip() for x in a.chapters.split(",") if x.strip())
        def _skip(chapter):
            return bool(_want) and chapter not in _want

        def run_target(chapter, source_name, bin_name, comp_name, flags, is_sycl=False, is_cublas=False, is_crisp=False, crisp_grid_tile=None):
            if _skip(chapter):
                return
            src_path = HERE / chapter / source_name
            if not src_path.exists():
                print("  WARNING: " + str(chapter) + "/" + str(source_name) + " not found -- "
                      "SKIPPING target '" + str(comp_name) + "'.")
                return

            bin_path = HERE / chapter / bin_name
            try:
                return _run_target_inner(chapter, comp_name, flags, is_sycl, is_cublas,
                                         is_crisp, crisp_grid_tile, src_path, bin_path)
            except ContenderBuildError as e:
                # A missing peer library (third_party/ not provisioned) used to raise
                # CalledProcessError out of time_compile and abort the entire chapter -- AFTER
                # Crisp and the control had already produced results, which were then lost.
                print("  WARNING: SKIPPING '" + str(comp_name) + "' -- it failed to compile "
                      "(exit " + str(e.returncode) + ").")
                for line in [l for l in (e.output or "").splitlines() if l.strip()][:6]:
                    print("    | " + line)
                if "cutlass" in (e.output or "").lower():
                    print("    -> peer headers missing; run scripts/setup-third-party.sh")
                return

        def _run_target_inner(chapter, comp_name, flags, is_sycl, is_cublas,
                              is_crisp, crisp_grid_tile, src_path, bin_path):
            dev_c_ms = 0.0
            all_c_ms = 0.0

            if is_crisp:
                if not Path(crisp_compiler).exists():
                    print(f"Skipping {comp_name} because {crisp_compiler} not found.")
                    return
                crisp_prec = [f"--math-precision={prec}",
                              f"--denormal-handling={'ftz' if ftz else 'preserve'}"]
                dev_c_ms = time_compile([crisp_compiler, "--ir-target=ptx", "--ir-target-arch=sm_90", f"--hardware-profile={NVIDIA_HW_PROFILE}", *crisp_prec, "--log-level=off", str(src_path)], name=comp_name)
                all_c_ms = dev_c_ms
                if crisp_grid_tile:
                    sweep = run_autobench_sweep(chapter, src_path, crisp_grid_tile, comp_name, sizes,
                                                a.warmup, a.iters, prec, ftz, dev_c_ms, crisp_compiler)
                    sweep.save(out_dir)
                    print(f"Saved {chapter} ({comp_name}) auto-bench sweep to {out_dir}")
                    return
                exe_path = str(HERE / "crisp" / "matmul_crisp")
                env_ext = {"CRISP_MATMUL_PTX": str(bin_path)}
            else:
                compiler = "icpx" if is_sycl else "nvcc"
                if is_sycl and not shutil.which("icpx"):
                    # Say so.  A silently absent contender reads as "we have no peer number"
                    # rather than "this shell has no oneAPI", and those are very different facts.
                    print(f"  SKIPPING {comp_name} ({chapter}) — icpx not on PATH; "
                          f"run the sweep from a oneAPI shell (setvars) to include SYCL contenders.")
                    return
                
                cmd = [compiler] + flags + [str(src_path), "-o", str(bin_path)]
                if is_sycl and is_cublas: cmd.insert(1, "-qmkl")

                all_c_ms = time_compile(cmd, name=comp_name)
                dev_only = time_device_only_compile(compiler, flags, src_path, bin_path.parent, is_sycl)
                dev_c_ms = dev_only if dev_only is not None else 0.0
                exe_path = str(bin_path)
                env_ext = None
                
            sweep = run_sweep(chapter, exe_path, comp_name, sizes, a.warmup, a.iters, prec, ftz, dev_c_ms, all_c_ms, env_ext)
            sweep.save(out_dir)
            print(f"Saved {chapter} ({comp_name}) sweep to {out_dir}")

        def run_l0_crisp(chapter, source_name, comp_name="Crisp", use_autobench=False):
            if _skip(chapter):
                return
            src = HERE / chapter / source_name
            if not src.exists():
                return
            if not Path(crisp_compiler).exists():
                print(f"Skipping {comp_name} ({chapter}) — {crisp_compiler} not found."); return
            
            try:
                # PREFER THE FIXTURE whenever it is built.  `use_autobench` used to select the
                # per-kernel generated harness, which is both the thing measured and the apparatus
                # measuring it -- it silently dropped contenders (chap4/chap5 bf16 recorded ZERO
                # points while running at 46 and 39 TFLOPS by hand), and it mis-dispatched 2-D local
                # sizes (chap0_naive read MMA_WRONG for a kernel that was always correct).  The
                # fixture is one reviewed harness, identical for every kernel, calibrated against
                # the old path to within 0.5%.  Autobench remains only as a fallback for when the
                # fixture has not been compiled.
                unsupported = ""
                _mc = next(iter(sorted(src.parent.glob(f"{src.stem}_*.metacrisp"))), None)
                if _mc:
                    unsupported = l0_fixture_env(src, _mc).get("_fixture_unsupported", "")
                if l0_harness and not unsupported:
                    sweep = run_l0_fixed_sweep(chapter, src, comp_name, l0_harness, sizes, a.warmup, a.iters,
                                               prec, ftz, crisp_compiler)
                elif use_autobench:
                    # ALWAYS say which harness produced the number.  The two do not agree, so a row
                    # whose provenance is unstated is a row that cannot be compared to the others.
                    dev_c_ms = 0.0
                    why = (f"uses {unsupported}, which the fixture does not support"
                           if unsupported else "the fixture was not built")
                    print(f"  NOTE: {comp_name} ({chapter}) measured through the GENERATED harness "
                          f"— {why}.", file=sys.stderr)
                    sweep = run_l0_autobench_sweep(chapter, src, comp_name, sizes, a.warmup, a.iters,
                                                   prec, ftz, dev_c_ms, crisp_compiler)
                else:
                    print(f"Skipping {comp_name} ({chapter}) — L0 harness not built."); return
            except ContenderBuildError as e:
                # Crisp itself can fail to compile a chapter's kernel — an unsupported element
                # type, a shape the hardware profile does not carry.  That is a result about ONE
                # chapter, not a reason to lose the other chapters' measurements.
                print("  WARNING: SKIPPING '" + str(comp_name) + "' (" + str(chapter) + ") -- "
                      "Crisp failed to compile it (exit " + str(e.returncode) + ").")
                for line in [l for l in (e.output or "").splitlines() if l.strip()][:6]:
                    print("    | " + line)
                return
                
            sweep.save(out_dir)
            print(f"Saved {chapter} ({comp_name}) L0 sweep to {out_dir}")

        if a.platform == "nvidia":
            # §1 Ch 0 — Naive loops, no tensor cores (fp32)
            run_target("chap0_naive", "matmul.crisp", "matmul.ptx", "Crisp", [], is_crisp=True, crisp_grid_tile="16,16")
            run_target("chap0_naive", "cuda_apples.cu", "cuda_apples", "CUDA_Apples", nvcc_flags)
            run_target("chap0_naive", "sycl_apples.cpp", "sycl_apples", "SYCL_Apples", sycl_flags, is_sycl=True)

            # §1 Ch 1 — Hand-rolled mma-accumulate-via-tile (tf32)
            run_target("chap1_handrolled_mma", "matmul.crisp", "matmul.ptx", "Crisp", [], is_crisp=True, crisp_grid_tile="64,64")
            run_target("chap1_handrolled_mma", "cuda_apples.cu", "cuda_apples", "CUDA_Apples", nvcc_flags)
            run_target("chap1_handrolled_mma", "sycl_apples.cpp", "sycl_apples", "SYCL_Apples", sycl_flags, is_sycl=True)

            # §1 Ch 2 — matrix-multiply-tile-stride macro (tiling)
            run_target("chap2_tiling", "matmul.crisp", "matmul.ptx", "Crisp", [], is_crisp=True, crisp_grid_tile="64,64")
            run_target("chap2_tiling", "cuda_apples.cu", "cuda_apples", "CUDA_Apples", nvcc_flags)
            run_target("chap2_tiling", "sycl_apples.cpp", "sycl_apples", "SYCL_Apples", sycl_flags, is_sycl=True)

            # §1 Ch 3 — cp.async linear pipelining
            run_target("chap3_async", "matmul_async.crisp", "matmul_async.ptx", "Crisp", [], is_crisp=True, crisp_grid_tile="64,64")
            run_target("chap3_async", "cuda_apples.cu", "cuda_apples", "CUDA_Apples", nvcc_flags)
            run_target("chap3_async", "sycl_apples.cpp", "sycl_apples", "SYCL_Apples", sycl_flags, is_sycl=True)

            # §1 Ch 4 — TMA descriptor (CUtensorMap)
            run_target("chap4_cheap_fetch", "matmul.crisp", "matmul.ptx", "Crisp", [], is_crisp=True, crisp_grid_tile="64,64")
            run_target("chap4_cheap_fetch", "cuda_apples.cu", "cuda_apples", "CUDA_Apples", nvcc_flags)

            # §1 Ch 5 — SMEM ring (multi-stage pipeline)
            run_target("chap5_multistage_ring", "matmul.crisp", "matmul.ptx", "Crisp", [], is_crisp=True, crisp_grid_tile="64,64")
            run_target("chap5_multistage_ring", "cuda_apples.cu", "cuda_apples", "CUDA_Apples", nvcc_flags)

            # §1 Ch 6 — Warp specialization with sync MMA
            run_target("chap6_warp_specialization", "matmul.crisp", "matmul.ptx", "Crisp", [], is_crisp=True, crisp_grid_tile="64,64")

            # §1 Ch 7 — WGMMA + Warp Specialization (Hopper warpgroup MMA)
            run_target("chap7_wgmma", "matmul.crisp", "matmul.ptx", "Crisp", [], is_crisp=True, crisp_grid_tile="64,256")

            # §2 — Top MMA Benchmarks (All 4 contender classes)
            run_target("sec2_top", "matmul.crisp", "matmul.ptx", "Crisp", [], is_crisp=True, crisp_grid_tile="64,256")
            run_target("sec2_top", "cuda_control.cu", "cuda_control", "CUDA_Apples", nvcc_flags)
            # CUTLASS include is REPO-RELATIVE, matching how SYCL-TLA is located below.  It used
            # to be the absolute "-I/workspace/cutlass/include" -- a path specific to one RunPod
            # volume that nothing ever created, so on every other machine the contender silently
            # took its "headers not found" branch.  scripts/setup-third-party.sh provisions this.
            cutlass_inc = HERE.parent.parent / "third_party" / "cutlass" / "include"
            run_target("sec2_top", "cutlass_peer.cu", "cutlass_peer", "CUTLASS",
                       ["-O3", "-std=c++17", "-arch=sm_90a", f"-I{cutlass_inc}"])
            run_target("sec2_top", "cublas_ceiling.cu", "cublas_ceiling", "CUBLAS_Optimal", cublas_flags, is_cublas=True)

            # §2.1 / §2.2 — 16-BIT TOP MMA, NVIDIA (endeavour 159).
            #
            # THE CRISP COLUMN IS DELIBERATELY ABSENT AND MUST READ AS A GAP.  Crisp cannot emit a
            # 16-bit MMA on PTX at all today: the sync path is hardcoded to
            # llvm.nvvm.mma.m16n8k8.row.col.tf32 (src/mma.lisp) and the wgmma path to
            # m64nNk8.f32.tf32.tf32 with %check-wgmma-shape pinning K=8.  The h100 profile already
            # lists (16 8 16) in :mma-shapes, so the SHAPE is declared and nothing emits it.  These
            # chapters therefore measure the three CONTENDERS first, which is what turns an H100
            # rental into the target the compiler work then aims at.  A missing Crisp row here is a
            # true statement about the compiler; a fabricated one would not be.
            #
            # These reuse the SAME chapter keys as the Intel 16-bit chapters, exactly as sec2_top
            # already carries both platforms' contenders in one directory.  The report loops per
            # GPU, so the NVIDIA rows land in their own section with CUTLASS/cuBLAS/CUDA_Apples
            # labels and no report change is needed.
            #
            # THE PEER IS SWEPT AND THE CEILING IS NOT, ON PURPOSE.  cuBLAS chooses its own kernel
            # internally and cannot be asked which; CUTLASS makes the tile a template argument, so
            # sweeping it both measures the peer honestly and maps the shape-vs-N ladder.  That
            # ladder is the point: the Intel fp16 chapter needed eleven Crisp variants because no
            # one kernel fits all N, and this is how we find out whether NVIDIA is the same.
            cutlass_16bit_configs = [
                ("128x128x64",   ["-DCFG_TILE_M=128", "-DCFG_TILE_N=128", "-DCFG_TILE_K=64"]),
                ("128x256x64",   ["-DCFG_TILE_M=128", "-DCFG_TILE_N=256", "-DCFG_TILE_K=64"]),
                ("256x128x64",   ["-DCFG_TILE_M=256", "-DCFG_TILE_N=128", "-DCFG_TILE_K=64"]),
                ("64x128x64",    ["-DCFG_TILE_M=64",  "-DCFG_TILE_N=128", "-DCFG_TILE_K=64"]),
                # A CONTROLLED CLUSTER CONTRAST, not a shape.  Identical to 128x128x64 but for
                # -DCFG_CLUSTER_M=2.  Endeavour 152 measured clusters as a NEGATIVE for Crisp on
                # this part (forming a cluster of two was free; multicast cost ~5% and never paid
                # back).  Whether CUTLASS's clusters pay where ours did not is a directly
                # informative answer, and it is only readable against the no-cluster twin.
                ("128x128x64c2", ["-DCFG_TILE_M=128", "-DCFG_TILE_N=128", "-DCFG_TILE_K=64",
                                  "-DCFG_CLUSTER_M=2"]),
            ]
            cutlass_16bit_flags = ["-O3", "-std=c++17", "-arch=sm_90a", f"-I{cutlass_inc}"]

            for _ch, _sfx, _tag in (("sec2_top_fp16", "fp16", "FP16"),
                                    ("sec2_top_bf16", "bf16", "BF16")):
                run_target(_ch, f"cuda_control_{_sfx}.cu", f"cuda_control_{_sfx}",
                           f"CUDA_Apples_{_tag}", nvcc_flags)
                for _cfg, _dflags in cutlass_16bit_configs:
                    # CUTLASS_V_<cfg> so the peer column can name which configuration produced a
                    # cell, the same provenance rule the Crisp variants already follow.  A
                    # best-per-size number the reader cannot reproduce is not an honest number.
                    run_target(_ch, f"cutlass_peer_{_sfx}.cu", f"cutlass_peer_{_sfx}_{_cfg}",
                               f"CUTLASS_V_{_cfg}", cutlass_16bit_flags + _dflags)
                run_target(_ch, f"cublas_ceiling_{_sfx}.cu", f"cublas_ceiling_{_sfx}",
                           f"CUBLAS_Optimal_{_tag}", cublas_flags, is_cublas=True)

            # §3 Situational — CLUSTERS + TMA MULTICAST (DSMEM)
            run_target("sec3_cluster_multicast", "matmul_tile128.crisp",
                       "matmul_tile128.ptx", "Crisp", [], is_crisp=True, crisp_grid_tile="64,128")
            run_target("sec3_cluster_multicast", "matmul_tile128_multicast.crisp",
                       "matmul_tile128_multicast.ptx", "Crisp_Multicast", [], is_crisp=True,
                       crisp_grid_tile="64,128")
            run_target("sec3_cluster_multicast", "cublas_optimal.cu", "cublas_optimal",
                       "CUBLAS_Optimal", cublas_flags, is_cublas=True)

            # §4 Activation Ch 1 — Fused ReLU
            run_target("sec4_fused_relu", "matmul_wgmma_ws_relu.crisp", "matmul_wgmma_ws_relu.ptx",
                       "Crisp_Fused_Relu", [], is_crisp=True, crisp_grid_tile="64,256")
            run_target("sec4_fused_relu", "cublaslt_relu.cu", "cublaslt_relu",
                       "CUBLASLt_Fused_Relu", cublas_flags + ["-lcublasLt"], is_cublas=True)
            run_target("sec4_fused_relu", "cublas_optimal.cu", "cublas_optimal",
                       "CUBLAS_Plus_Relu", cublas_flags, is_cublas=True)

            # §4 Activation Ch 2 — Fused Custom
            run_target("sec4_fused_custom", "matmul_wgmma_ws_custom.crisp", "matmul_wgmma_ws_custom.ptx",
                       "Crisp_Fused_Custom", [], is_crisp=True, crisp_grid_tile="64,256")
            run_target("sec4_fused_custom", "cublaslt_optimal.cu", "cublaslt_optimal",
                       "CUBLASLt_Plus_Custom", cublas_flags + ["-lcublasLt"], is_cublas=True)
            run_target("sec4_fused_custom", "cublas_optimal.cu", "cublas_optimal",
                       "CUBLAS_Plus_Custom", cublas_flags, is_cublas=True)
        else:
            # --- Intel/BMG ladder (endeavor 143) ---
            # §1 Ch 0 — Naive loops, no XMX tensor cores
            run_l0_crisp("chap0_naive", "matmul_bmg.crisp", use_autobench=True)
            run_target("chap0_naive", "sycl_apples.cpp", "sycl_apples", "SYCL_Apples", sycl_flags, is_sycl=True)

            # §1 Ch 1 — Hand-rolled XMX coop-matrix
            run_l0_crisp("chap1_handrolled_mma", "matmul_bmg.crisp", use_autobench=True)
            run_target("chap1_handrolled_mma", "sycl_apples.cpp", "sycl_apples", "SYCL_Apples", sycl_flags, is_sycl=True)

            # §1 Ch 2 — synchronous coop-matrix tiling (matrix-multiply-tile-stride)
            run_l0_crisp("chap2_tiling", "matmul_bmg.crisp")
            run_target("chap2_tiling", "sycl_apples.cpp", "sycl_apples", "SYCL_Apples", sycl_flags, is_sycl=True)

            # §1 Ch 3 — OpGroupAsyncCopy staging
            run_l0_crisp("chap3_async", "matmul_bmg_async.crisp")
            run_target("chap3_async", "sycl_apples.cpp", "sycl_apples", "SYCL_Apples", sycl_flags, is_sycl=True)

            # §1 Ch 4 — Register-resident load (global -> GRF)
            run_l0_crisp("chap4_cheap_fetch", "matmul_bmg.crisp", use_autobench=True)
            run_target("chap4_cheap_fetch", "sycl_apples.cpp", "sycl_apples", "SYCL_Apples", sycl_flags + ["-Xs", "-ze-opt-large-register-file"], is_sycl=True)

            # §1 Ch 5 — Register ring + prefetch (intel_prefetch)
            run_l0_crisp("chap5_multistage_ring", "matmul_bmg.crisp", use_autobench=True)

            # §1 (bf16) — the SAME technique ladder in 16-bit.  Registered as separate chapters, not
            # extra contenders in the tf32 chapters: report.py's _is_crisp matches any "Crisp_*"
            # name and _best takes the MAX, so a bf16 contender sharing a chapter would silently
            # replace the tf32 number wherever it was faster.  Separate chapters also match the
            # existing sec2_top / sec2_top_bf16 convention.
            for _ch in ("chap0_naive", "chap1_handrolled_mma", "chap2_tiling",
                        "chap3_async", "chap4_cheap_fetch", "chap5_multistage_ring"):
                run_l0_crisp(_ch + "_bf16", "matmul_bmg_bf16.crisp", use_autobench=True)
            run_target("chap5_multistage_ring", "sycl_apples.cpp", "sycl_apples", "SYCL_Apples", sycl_flags + ["-Xs", "-ze-opt-large-register-file"], is_sycl=True)

            # SYCL-TLA (CUTLASS 3.x for Intel Xe2) specific flags
            tla_dir = HERE.parent.parent / "third_party" / "sycl-tla"
            tla_inc = [f"-I{tla_dir}/include", f"-I{tla_dir}/tools/util/include"]
            # AOT (spir64_gen + -device bmg-g21) needs `ocloc`, which is NOT on PATH in the
            # crisp-bench-intel image -- it ships only under vtune/.../GTPin.  Without it icpx
            # fails, and before the ContenderBuildError fix that killed the whole sweep; after it,
            # the peer is merely SKIPPED, which is how the bf16 ladder ended up with a peer column
            # from an older run.  JIT (the default spir64 target) produces the same device code
            # and the same kernel performance -- AOT only moves compilation from load time to
            # build time -- so falling back costs a slower first launch and nothing else.  The
            # device_compile_ms column for this contender is therefore not comparable to an AOT
            # run; that is the honest trade and it is visible in the report's compile table.
            # 256-GRF IS NOT A TUNING KNOB HERE, IT IS PARITY.  Built without
            # -ze-opt-large-register-file the peer's mainloop spills ~131 registers and reads
            # 12.6 TFLOPS at N=4096; with it the spill goes to ZERO and it reads 81.3 -- 6.5x, on
            # bit-identical source.  Publishing the unflagged number would understate the peer by
            # more than six-fold, which is the same class of error as the hardcoded correct=true
            # this contender used to report, just pointing the other way.  Crisp gets its own GRF
            # budget from the endeavour-144 Intel GRF model and SYCL_Apples is already built with
            # -Xs -ze-opt-large-register-file above, so matching the peer is levelling the field.
            _aot = ["-fsycl-targets=spir64_gen",
                    "-Xsycl-target-backend=spir64_gen",
                    "-device bmg-g21 -options -ze-opt-large-register-file"] if shutil.which("ocloc") else []
            # The GRF flag must survive the JIT fallback too -- it rides inside the AOT backend
            # option string above, so without this the fallback would silently rebuild the peer in
            # the 6.5x-slower spilling configuration, which is exactly the failure the AOT comment
            # warns about wearing a different hat.
            _grf = [] if _aot else ["-Xs", "-ze-opt-large-register-file"]
            if not _aot:
                print("  (note: ocloc not found — SYCL-TLA will be built JIT rather than AOT)")
            sycl_tla_flags = sycl_flags + tla_inc + [
                "-DCUTLASS_ENABLE_SYCL=ON", "-DSYCL_INTEL_TARGET=1",
                "-fno-sycl-instrument-device-code",
                *_aot, *_grf,
                "-Xspirv-translator",
                "-spirv-ext=+SPV_INTEL_split_barrier,+SPV_INTEL_2d_block_io,+SPV_INTEL_subgroup_matrix_multiply_accumulate"
            ]

            # §2 — Top MMA Benchmarks (TF32 / FP32 Precision Tier)
            run_l0_crisp("sec2_top", "matmul_bmg.crisp", use_autobench=True)
            run_target("sec2_top", "sycl_control.cpp", "sycl_control", "SYCL_Apples", sycl_flags + ["-Xs", "-ze-opt-large-register-file"], is_sycl=True)
            run_target("sec2_top", "onemkl_ceiling.cpp", "onemkl_ceiling", "OneMKL_Optimal", sycl_flags, is_sycl=True, is_cublas=True)

            # §2.1 — Top MMA Benchmarks (BFloat16 Low-Precision Tier)
            run_l0_crisp("sec2_top_bf16", "matmul_bmg_bf16.crisp", use_autobench=True)
            # VARIANTS.  The bf16 kernel is geometrically IDENTICAL to its fp16 twin -- same
            # 128x256 tile over 16 subgroups, same K step, same (8 16 16) shape -- so the same
            # prefetch-distance sweep applies.  bf16 had a SYCL-TLA peer and no variant sweep;
            # fp16 had the sweep and no peer.  Both halves are now filled in.
            run_l0_crisp("sec2_top_bf16", "matmul_bmg_bf16_pfw1.crisp", "Crisp_V_pfw1", use_autobench=True)
            # THE fp16 WINNER, TRANSFERRED.  Peer geometry (256x256/32sg) + :xe-native + prefetch
            # reached 106.0 TF at 8192 in fp16 -- 95% of oneMKL, best at every size, no sign
            # flip.  The bf16 kernel is geometrically identical and the pair has tracked within
            # 0.5% at every size, so the result is expected to transfer.  bf16 is where the
            # SYCL-TLA peer has settled data, so this is the comparison that matters.
            run_l0_crisp("sec2_top_bf16", "matmul_bmg_bf16_wg256_pf2.crisp",   "Crisp_V_wg256pf2",   use_autobench=True)
            run_l0_crisp("sec2_top_bf16", "matmul_bmg_bf16_wg256_xe.crisp",    "Crisp_V_wg256xe",    use_autobench=True)
            run_l0_crisp("sec2_top_bf16", "matmul_bmg_bf16_wg256_xepf2.crisp", "Crisp_V_wg256xepf2", use_autobench=True)
            # superseded by the peer geometry; d1 is the best of this family:
            # run_l0_crisp("sec2_top_bf16", "matmul_bmg_bf16_pfw2.crisp", "Crisp_V_pfw2", use_autobench=True)
            # superseded by the peer geometry; d1 is the best of this family:
            # run_l0_crisp("sec2_top_bf16", "matmul_bmg_bf16_pfw3.crisp", "Crisp_V_pfw3", use_autobench=True)
            # superseded by the peer geometry; d1 is the best of this family:
            # run_l0_crisp("sec2_top_bf16", "matmul_bmg_bf16_pfw4.crisp", "Crisp_V_pfw4", use_autobench=True)
            run_target("sec2_top_bf16", "sycl_control_bf16.cpp", "sycl_control_bf16", "SYCL_Apples_BF16", sycl_flags + ["-Xs", "-ze-opt-large-register-file"], is_sycl=True)
            run_target("sec2_top_bf16", "sycl_tla_peer.cpp", "sycl_tla_peer", "SYCL-TLA_BF16", sycl_tla_flags, is_sycl=True)
            run_target("sec2_top_bf16", "onemkl_bf16.cpp", "onemkl_bf16", "OneMKL_BF16", sycl_flags, is_sycl=True, is_cublas=True)

            # §2.2 Top FP16 (endeavour 155).
            #
            # WHY THIS CHAPTER EXISTS SEPARATELY FROM sec2_top_bf16, AND MUST STAY SEPARATE.
            # bf16 does not run on this BMG driver at all: the Level Zero SPIR-V reader (IGC
            # 1.6.33578) does not implement SPV_KHR_bfloat16, reports
            #   "input SPIR-V module uses unknown extension 'SPV_KHR_bfloat16'"
            # and then dies, taking the host process with it.  fp16 goes through the IDENTICAL
            # Crisp path -- same typed register tiles, same (8 16 16) mma-accumulate-via-tile,
            # same DPAS rate on Xe2 -- and builds and runs.
            #
            # Reporting the fp16 number in the bf16 table would be exactly the fabrication this
            # report was just fixed for (the CUB/CUBLAS substring collision).  Different element
            # type, different section, contenders converted to match.
            run_l0_crisp("sec2_top_fp16", "matmul_bmg_fp16.crisp", use_autobench=True)
            # VARIANTS of the fp16 solution, not separate contenders.  The `Crisp_V_` prefix is
            # the marker report.py reads: a `Crisp_V_<tag>` competitor is an alternative
            # CONFIGURATION of this chapter's Crisp kernel, so the report shows the per-size
            # envelope (with provenance) AND the best single fixed choice.  A plain `Crisp_<name>`
            # stays a separate contender -- that is what sec3_mma_lowering's four kernels are, a
            # controlled contrast where taking a max would destroy the comparison.
            #
            # Endeavour 158: prefetch distance is a real tuning parameter here, and it CHANGES
            # SIGN with N -- +40% at 4096, -55% at 8192.  Exactly the case the envelope/single
            # split and the sign-flip warnings exist to make visible.
            run_l0_crisp("sec2_top_fp16", "matmul_bmg_fp16_pfw1.crisp", "Crisp_V_pfw1", use_autobench=True)
            run_l0_crisp("sec2_top_fp16", "matmul_bmg_fp16_pfw2.crisp", "Crisp_V_pfw2", use_autobench=True)
            run_l0_crisp("sec2_top_fp16", "matmul_bmg_fp16_pfw3.crisp", "Crisp_V_pfw3", use_autobench=True)
            run_l0_crisp("sec2_top_fp16", "matmul_bmg_fp16_pfw4.crisp", "Crisp_V_pfw4", use_autobench=True)
            # THE PEER'S GEOMETRY: 256x256 over 32 subgroups, which is what SYCL-TLA runs at
            # EVERY size (verified: compile-time constants, zero size-dependent branching).
            # Per-subgroup tile is already identical to ours at 32x64 and register demand is
            # unchanged at 448/thread -- the difference is purely workgroup aggregation, and
            # therefore arithmetic intensity: 128 flops/byte against our 85.3.
            # Endeavour 156 banked this geometry as a loss at 34.6 vs 60.8, but that was at
            # K=16 and before :warp-partitioned prefetch existed.
            run_l0_crisp("sec2_top_fp16", "matmul_bmg_fp16_wg256.crisp",     "Crisp_V_wg256",     use_autobench=True)
            run_l0_crisp("sec2_top_fp16", "matmul_bmg_fp16_wg256_pf1.crisp", "Crisp_V_wg256pf1", use_autobench=True)
            run_l0_crisp("sec2_top_fp16", "matmul_bmg_fp16_wg256_pf2.crisp", "Crisp_V_wg256pf2", use_autobench=True)
            # :XE-NATIVE at the peer geometry -- 42 machine instructions per dpas against 57.
            # Attacks the INSTRUCTION STREAM, where the remaining gap to the peer lives.
            run_l0_crisp("sec2_top_fp16", "matmul_bmg_fp16_wg256_xe.crisp",    "Crisp_V_wg256xe",    use_autobench=True)
            run_l0_crisp("sec2_top_fp16", "matmul_bmg_fp16_wg256_xepf2.crisp", "Crisp_V_wg256xepf2", use_autobench=True)
            # CACHE CONTROL, now covering the PREFETCH as well as the loads.  Byte-identical
            # source to wg256_pf2; only the NAME differs, so one env setting decorates this
            # kernel and not its twin and both are measured in the SAME session.
            run_l0_crisp("sec2_top_fp16", "matmul_bmg_fp16_wg256_pf2cc.crisp", "Crisp_V_wg256pf2cc", use_autobench=True)

            # §3 Situational — MMA LOWERING (:coop-matrix vs :xe-native), Intel only.
            # Four kernels, one variable at a time.  All are 32x64 bf16 over one subgroup; the
            # TUNED pair adds ring depth 2 + prefetch distance 2, making Crisp_Coop_Tuned the same
            # kernel as sec2_top_bf16.  Both pairs are needed: :xe-native is FASTER bare and SLOWER
            # tuned, so either pair alone tells a true and misleading story.
            run_l0_crisp("sec3_mma_lowering", "matmul_coop_bare.crisp",  "Crisp_Coop_Bare",     use_autobench=True)
            run_l0_crisp("sec3_mma_lowering", "matmul_xe_bare.crisp",    "Crisp_XeNative_Bare",  use_autobench=True)
            run_l0_crisp("sec3_mma_lowering", "matmul_coop_tuned.crisp", "Crisp_Coop_Tuned",    use_autobench=True)
            run_l0_crisp("sec3_mma_lowering", "matmul_xe_tuned.crisp",   "Crisp_XeNative_Tuned", use_autobench=True)
            # DIAGNOSTIC — ROOFLINE PROBE.  Not a chapter of the report; it has no contenders and
            # produces no row.  Three arms of ONE kernel (the shipped sec2_top_fp16 geometry) that
            # separate "bound by the loads" from "bound by the math":
            #     probe_full    16 loads + 32 dpas in the K loop   (the real kernel)
            #     probe_loads   16 loads +  0 dpas                 (math deleted)
            #     probe_math     0 loads + 32 dpas                 (loads hoisted out of the K loop)
            # Read T_full against T_loads and T_math -- see _probe_roofline/README.md for how each
            # outcome is interpreted.
            #
            # TWO OF THE THREE ARMS ARE NUMERICALLY WRONG BY CONSTRUCTION.  That is the point of
            # them, and it is also why this chapter is fenced:
            #   * the directory is underscore-prefixed, so it is not a report chapter;
            #   * _skip() means it runs ONLY when named in --chapters, never in a full sweep;
            #   * it must be run with --scratch, so its JSON lands in results/scratch/ which the
            #     report never reads into a canonical table;
            #   * at N <= VERIFY_MAX_N the harness runs the host reference and DISCARDS the two
            #     wrong arms as NOT MMA_CORRECT.  That is expected and is itself the check that
            #     the integrity gate still works -- include 2048 in the sizes to see it fire.
            # The measurable sizes are therefore 4096 and up, where the host reference is skipped
            # and points are recorded with verified:false.
            run_l0_crisp("_probe_roofline", "probe_full.crisp",  "Probe_Full",  use_autobench=True)
            run_l0_crisp("_probe_roofline", "probe_wg256_xe_math.crisp", "Probe_WG256_XE_Math", use_autobench=True)
            # run_l0_crisp("_probe_roofline", "probe_loads.crisp", "Probe_Loads", use_autobench=True)
            # ROUND-2 ARM, already answered -- re-enable to re-measure:
            # run_l0_crisp("_probe_roofline", "probe_math.crisp",  "Probe_Math",  use_autobench=True)
            # Round 2 arms.  The first probe answered "which half is the critical path" (the
            # loads, at 95%).  These three ask WHY T_loads is large, since fetch and math turned
            # out to be ~95% overlapped already -- so the win has to come from shrinking T_loads
            # itself, not from overlapping it better.  All are probe_loads with ONE change.
            #   A  cache control   CacheControlLoadINTEL {L1,L3}=Cached, SYCL-TLA's kL1C_L3C.
            #                      Needs CRISP_CACHE_CONTROL=l1c_l3c and
            #                      CRISP_CACHE_CONTROL_KERNELS=probe_loads_cc in the environment;
            #                      the kernel SOURCE is byte-identical to probe_loads, so a flat
            #                      result means IGC ignored the decoration -- itself a real answer.
            #   B  prefetch        24 block prefetches per K-iteration, running 2 or 3 ahead.
            #                      Tests memory-level parallelism among the loads.
            #   C  fixed coords    loop-invariant load address: both the per-iteration 64-bit
            #                      address arithmetic and any cache miss vanish.  The CEILING arm.
            # ROUND-2 ARM, already answered -- re-enable to re-measure:
            # run_l0_crisp("_probe_roofline", "probe_loads_cc.crisp",    "Probe_Loads_CC",    use_autobench=True)
            # ROUND-2 ARM, already answered -- re-enable to re-measure:
            # run_l0_crisp("_probe_roofline", "probe_loads_pf2.crisp",   "Probe_Loads_PF2",   use_autobench=True)
            # ROUND-2 ARM, already answered -- re-enable to re-measure:
            # run_l0_crisp("_probe_roofline", "probe_loads_pf3.crisp",   "Probe_Loads_PF3",   use_autobench=True)
            # ROUND-2 ARM, already answered -- re-enable to re-measure:
            # run_l0_crisp("_probe_roofline", "probe_loads_fixed.crisp", "Probe_Loads_Fixed", use_autobench=True)
            # Round 3 (endeavour 158): arm B re-run with a prefetch that is actually DISTRIBUTED.
            # The round-2 arms above issued all 24 prefetches from all 16 subgroups because
            # prefetch-tile had no :warps notion; these issue TWO per subgroup for the same
            # coverage.  probe_full_pfw* are numerically CORRECT (a prefetch changes no result), so
            # unlike the loads-only arms they verify at N<=2048 and compare directly to probe_full.
            # LOADS-ONLY MISLEADS FOR PREFETCH (round 3) -- parked:
            # run_l0_crisp("_probe_roofline", "probe_loads_pfw2.crisp",  "Probe_Loads_PFW2",  use_autobench=True)
            # LOADS-ONLY MISLEADS FOR PREFETCH (round 3) -- parked:
            # run_l0_crisp("_probe_roofline", "probe_loads_pfw3.crisp",  "Probe_Loads_PFW3",  use_autobench=True)
            run_l0_crisp("_probe_roofline", "probe_full_pfw1.crisp",   "Probe_Full_PFW1",   use_autobench=True)
            run_l0_crisp("_probe_roofline", "probe_full_pfw2.crisp",   "Probe_Full_PFW2",   use_autobench=True)
            run_l0_crisp("_probe_roofline", "probe_full_pfw3.crisp",   "Probe_Full_PFW3",   use_autobench=True)
            run_l0_crisp("_probe_roofline", "probe_full_pfw4.crisp",   "Probe_Full_PFW4",   use_autobench=True)

            run_target("sec2_top_fp16", "sycl_control_fp16.cpp", "sycl_control_fp16", "SYCL_Apples_FP16", sycl_flags + ["-Xs", "-ze-opt-large-register-file"], is_sycl=True)
            # PEER for fp16.  A verbatim port of the bf16 peer with only the element type
            # changed.  The fp16 Peer column was empty because this file did not exist -- not
            # because SYCL-TLA lacks fp16 on Xe2 (it is TF32 it does not implement).
            run_target("sec2_top_fp16", "sycl_tla_peer_fp16.cpp", "sycl_tla_peer_fp16", "SYCL-TLA_FP16", sycl_tla_flags, is_sycl=True)
            run_target("sec2_top_fp16", "onemkl_fp16.cpp", "onemkl_fp16", "OneMKL_FP16", sycl_flags, is_sycl=True, is_cublas=True)

            # §4 Activation Ch 1 — Fused ReLU
            run_l0_crisp("sec4_fused_relu", "matmul_bmg_prefetch_relu.crisp",
                         comp_name="Crisp_Fused_Relu", use_autobench=True)
            run_target("sec4_fused_relu", "sycl_apples.cpp", "sycl_apples",
                       "SYCL_Apples_Relu", sycl_flags + ["-Xs", "-ze-opt-large-register-file"], is_sycl=True)
            run_target("sec4_fused_relu", "sycl_tla_relu.cpp", "sycl_tla_relu",
                       "SYCL-TLA_Fused_Relu", sycl_tla_flags, is_sycl=True)
            run_target("sec4_fused_relu", "onemkl_optimal.cpp", "onemkl_optimal",
                       "OneMKL_Plus_Relu", sycl_flags, is_sycl=True, is_cublas=True)
            run_target("sec4_fused_relu", "onednn_fused.cpp", "onednn_fused",
                       "OneDNN_Fused_Relu", sycl_flags + ["-ldnnl"], is_sycl=True, is_cublas=True)

            # §4 Activation Ch 2 — Fused Custom
            run_l0_crisp("sec4_fused_custom", "matmul_bmg_prefetch_custom.crisp",
                         comp_name="Crisp_Fused_Custom", use_autobench=True)
            run_target("sec4_fused_custom", "sycl_apples.cpp", "sycl_apples",
                       "SYCL_Apples_Custom", sycl_flags + ["-Xs", "-ze-opt-large-register-file"], is_sycl=True)
            run_target("sec4_fused_custom", "sycl_tla_custom.cpp", "sycl_tla_custom",
                       "SYCL-TLA_Fused_Custom", sycl_tla_flags, is_sycl=True)
            run_target("sec4_fused_custom", "onemkl_optimal.cpp", "onemkl_optimal",
                       "OneMKL_Plus_Custom", sycl_flags, is_sycl=True, is_cublas=True)
            run_target("sec4_fused_custom", "onednn_optimal.cpp", "onednn_optimal",
                       "OneDNN_Plus_Custom", sycl_flags + ["-ldnnl"], is_sycl=True, is_cublas=True)

if __name__ == "__main__":
    main()
