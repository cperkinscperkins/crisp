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

# Hardware metadata stamped into every BenchmarkSweep's run_metadata.  Set by main() from
# --platform so the JSON is tagged per platform (report.py groups by hardware.gpu_model).
# Endeavor 143: the Intel path runs inside the bench Docker container on a BMG.
HW = {"gpu_model": "NVIDIA H100", "arch_target": "sm_90", "environment": "runpod"}
HW_BY_PLATFORM = {
    "nvidia": {"gpu_model": "NVIDIA H100", "arch_target": "sm_90", "environment": "runpod"},
    "intel":  {"gpu_model": "Intel BMG",   "arch_target": "bmg",   "environment": "docker"},
}

def _apply_hw(meta):
    """Stamp the active platform's hardware info onto a run_metadata (replaces the old hardcoded
    'NVIDIA H100' so the same sweep builders serve both platforms)."""
    meta.hardware.gpu_model   = HW["gpu_model"]
    meta.hardware.arch_target = HW["arch_target"]
    meta.hardware.environment = HW["environment"]
    return meta

# Per-size iteration scaling (Endeavor 143).  Matmul work ~ size^3, so a fixed iter count pins the GPU
# for time ~ size^3.  On the Intel BMG that GPU is ALSO the Windows display, so a big GEMM at full iters
# FREEZES the desktop; on any GPU, 4096 at 100 iters can wall the harness on time.  So above a reference
# size we scale warmup+iters down cubically (keeping GPU-time-per-run roughly bounded) to a floor.  The
# JSON records the ACTUAL counts, so a smaller-sample large-size point is transparent, not hidden.
SIZE_SCALE_REF = 2048   # sizes <= this keep full counts.  Set by main(): 1024 (intel/display GPU) / 2048 (nvidia).
WARMUP_MIN = 2
ITERS_MIN  = 5

def scaled_counts(base_warmup, base_iters, size):
    """(warmup, iters) for SIZE: full counts up to SIZE_SCALE_REF, cubic falloff beyond, floored at
    (WARMUP_MIN, ITERS_MIN)."""
    if size <= SIZE_SCALE_REF:
        return base_warmup, base_iters
    frac = (SIZE_SCALE_REF / size) ** 3
    return (max(WARMUP_MIN, round(base_warmup * frac)),
            max(ITERS_MIN,  round(base_iters  * frac)))

def sh(cmd, **kw):
    print("  $", " ".join(str(c) for c in cmd), file=sys.stderr)
    return subprocess.run([str(c) for c in cmd], **kw)

def time_compile(cmd, **kw):
    t0 = time.time()
    res = sh(cmd, **kw)
    t1 = time.time()
    res.check_returncode()
    return (t1 - t0) * 1000.0

def run_bin(path, M, N, K, warmup, iters, env_extra=None):
    env = dict(os.environ)
    if env_extra: env.update(env_extra)
    p = sh([path, str(M), str(N), str(K), str(warmup), str(iters)], cwd=str(HERE/"crisp"), capture_output=True, text=True, env=env)
    try:
        return json.loads(p.stdout)
    except Exception:
        print(p.stdout, p.stderr, file=sys.stderr)
        return None

def build_harness():
    # Build the crisp harness (chap0/chap1 launcher — loads the Crisp PTX and times it).
    # It is precision-agnostic (the measured kernel is the Crisp PTX, compiled separately with its
    # own explicit flags), and it's built once, so it has no per-pass precision.  Still, per the
    # MATH-FLAG POLICY we never emit a bare nvcc: pin it to the strict/reference config (ieee +
    # preserve) so the harness's A=B=1 -> C=K correctness check is exact.
    sh(["nvcc", "-O3", "-arch=sm_90", *nvcc_math_flags("ieee", False),
        str(HERE/"crisp/bench_harness.cu"), "-lcuda", "-o", str(HERE/"crisp/matmul_crisp")], check=True)

def run_sweep(chapter: str, exe_path: str, competitor_name: str, sizes: list, warmup: int, iters: int, precision: str, ftz: bool, compile_dev_ms: float, compile_all_ms: float, env_extra: dict = None) -> BenchmarkSweep:
    meta = _apply_hw(create_metadata())

    results = []
    for s in sizes:
        S = int(s)
        w, it = scaled_counts(warmup, iters, S)   # bound GPU pin time at large sizes
        out = run_bin(exe_path, S, S, S, w, it, env_extra)
        if not out: continue

        # If the harness returns driver_jit_ms, we add it to the measured all_compile_ms
        driver_jit = out.get("driver_jit_ms", 0.0)
        final_all_compile_ms = compile_all_ms + driver_jit

        point = SweepPoint(
            configuration={"m": S, "n": S, "k": S, "warmup": w, "iters": it},
            metrics=BenchmarkMetrics(
                compile_time=CompileTimeMetrics(device_compile_ms=compile_dev_ms, all_compile_ms=final_all_compile_ms), 
                runtime=RuntimeMetrics(wall_time_ms=out.get("wall_time_ms", 0.0), kernel_execution_ms=out.get("kernel_median_us", 0.0)/1000.0),
                throughput=ThroughputMetrics(tflops=out.get("gflops", 0.0)/1000.0)
            )
        )
        results.append(point)

    return BenchmarkSweep(
        run_metadata=meta,
        benchmark_suite="matmul",
        chapter=chapter,
        competitor=competitor_name,
        precision=precision,
        denormal_handling="ftz" if ftz else "preserve",
        results=results
    )

# ---------------------------------------------------------------------------
# Auto-bench path for ADVANCED Crisp kernels (TMA :block, pipelined rings, wgmma).
# bench_harness.cu has a single fixed 45-slot param layout (2 SLM tiles + A/B/C,
# 32 threads, 4KB shared) — it only fits chap0/chap1.  The advanced kernels have
# different params (CuTensorMap descriptors, barriers, ring tiles, 128+ threads,
# >48KB dynamic SMEM), so we instead let `crisp-hoist-cuda --mma-bench` generate a
# per-kernel harness that reads the real param layout from the kernel's metacrisp
# (and emits col-major B strides + the cuFuncSetAttribute SMEM opt-in as needed).
# ---------------------------------------------------------------------------

def _hoist_cuda_bin(crisp_compiler):
    """Sibling crisp-hoist-cuda binary next to crisp-compile."""
    p = Path(crisp_compiler)
    return str(p.parent / ("crisp-hoist-cuda" + (".exe" if p.suffix == ".exe" else "")))

def run_crisp_autobench(src_path: Path, grid_tile: str, M: int, N: int, K: int, crisp_compiler: str,
                        prec_flags=(), nvcc_math=()):
    """Compile + hoist + --mma-bench + nvcc + run one advanced Crisp matmul kernel.
    The mma-bench harness fills A/B, launches with the kernel's real params, checks
    C == A.B, and warmup+times.  Returns a dict shaped like run_bin's JSON (gflops,
    kernel_median_us, correct), or None on failure.  PREC_FLAGS are the Crisp precision
    flags (--math-precision / --denormal-handling) for the kernel compile; NVCC_MATH are
    the explicit nvcc FP flags for the bench-harness compile (the C=A.B reference math) —
    both always passed, never elided (see MATH-FLAG POLICY)."""
    chap_dir = src_path.parent
    base = src_path.stem
    ptx = chap_dir / f"{base}.ptx"
    metacrisp = chap_dir / f"{base}_matmul.metacrisp"
    # device PTX + the hoist metacrisp (param layout / descriptor metadata).  Size-invariant,
    # so compile once per kernel and reuse across sizes (the sweep is slow otherwise) — but the
    # PRECISION flags change the kernel, so run_autobench_sweep clears the metacrisp between
    # precisions, forcing a fresh compile+hoist for each precision's first size.
    if not (ptx.exists() and metacrisp.exists()):
        sh([crisp_compiler, "--ir-target=ptx", "--ir-target-arch=sm_90", *prec_flags, "--log-level=off", str(src_path)], check=True)
        sh([crisp_compiler, "--hoist=cuda", "--ir-target-arch=sm_90", *prec_flags, "--log-level=off", str(src_path)], check=True)
    if not metacrisp.exists():
        print(f"autobench: no metacrisp {metacrisp}", file=sys.stderr); return None
    sh([_hoist_cuda_bin(crisp_compiler), f"--mma-bench={M},{N},{K}", f"--grid-tile={grid_tile}", str(metacrisp)])
    cu = chap_dir / f"{base}_matmul_CUDA.cu"
    if not cu.exists():
        print(f"autobench: no bench .cu {cu}", file=sys.stderr); return None
    # rewrite the build-machine PTX path to this machine's absolute path
    txt = cu.read_text()
    txt = re.sub(r'"[^"]*' + re.escape(base) + r'\.ptx"', '"' + str(ptx).replace("\\", "/") + '"', txt)
    cu.write_text(txt)
    exe = chap_dir / f"{base}_bench"
    # -Xcompiler -fopenmp: the generated harness parallelizes its O(N^3) host C=A.B reference
    # with OpenMP (else 4096 verification is single-threaded minutes).  Forwarded to the host
    # compiler for both compile and link (libgomp).
    c = sh(["nvcc", "-O3", "-arch=sm_90a", "-Xcompiler", "-fopenmp", *nvcc_math, str(cu), "-o", str(exe), "-lcuda"], capture_output=True, text=True)
    if c.returncode != 0:
        print("autobench nvcc failed:\n" + (c.stderr or "")[-1200:], file=sys.stderr); return None
    p = sh([str(exe)], capture_output=True, text=True)
    out = (p.stdout or "") + (p.stderr or "")
    m = re.search(r'BENCH\s+matmul\s+\d+x\d+x\d+:\s*([\d.]+)\s*GFLOPS\s*\(([\d.eE+-]+)\s*ms/iter\)', out)
    if not m:
        print("autobench parse failed:\n" + out[-800:], file=sys.stderr); return None
    return {"gflops": float(m.group(1)), "kernel_median_us": float(m.group(2)) * 1000.0,
            "correct": ("MMA_CORRECT" in out), "wall_time_ms": 0.0, "driver_jit_ms": 0.0}

def run_autobench_sweep(chapter, src_path, grid_tile, comp_name, sizes, warmup, iters,
                        precision, ftz, dev_c_ms, crisp_compiler):
    """run_sweep twin that drives run_crisp_autobench per size (advanced Crisp kernels)."""
    meta = _apply_hw(create_metadata())
    # Crisp precision flags for this pass — a DIFFERENT flag set than nvcc's (Crisp defaults to
    # ieee, so we must pass these or Crisp competes at IEEE against fast-math cuBLAS).
    prec_flags = [f"--math-precision={precision}",
                  f"--denormal-handling={'ftz' if ftz else 'preserve'}"]
    # Explicit nvcc FP flags for the bench-harness compile (the C=A.B reference) — same policy.
    nvcc_math = nvcc_math_flags(precision, ftz)
    # Invalidate the per-kernel compile cache for THIS precision (the kernel differs by precision).
    src = Path(src_path)
    stale = src.parent / f"{src.stem}_matmul.metacrisp"
    if stale.exists():
        stale.unlink()
    results = []
    for s in sizes:
        S = int(s)
        out = run_crisp_autobench(src, grid_tile, S, S, S, crisp_compiler, prec_flags, nvcc_math)
        if not out:
            continue
        if not out.get("correct", False):
            print(f"  ! {chapter} ({comp_name}) {S}^3: NOT MMA_CORRECT — skipping point", file=sys.stderr)
            continue
        results.append(SweepPoint(
            configuration={"m": S, "n": S, "k": S, "warmup": warmup, "iters": iters},
            metrics=BenchmarkMetrics(
                compile_time=CompileTimeMetrics(device_compile_ms=dev_c_ms,
                                                all_compile_ms=dev_c_ms + out.get("driver_jit_ms", 0.0)),
                runtime=RuntimeMetrics(wall_time_ms=out.get("wall_time_ms", 0.0),
                                       kernel_execution_ms=out.get("kernel_median_us", 0.0) / 1000.0),
                throughput=ThroughputMetrics(tflops=out.get("gflops", 0.0) / 1000.0))))
    return BenchmarkSweep(run_metadata=meta, benchmark_suite="matmul", chapter=chapter, competitor=comp_name,
                          precision=precision, denormal_handling="ftz" if ftz else "preserve", results=results)

# ---------------------------------------------------------------------------
# Endeavor 143 — Intel/L0 Crisp path (fixed-harness twin of the NVIDIA chap0/chap1 CRISP_MATMUL_PTX path).
# benchmarks/matmul/crisp/bench_harness_l0.cpp launches the (M/32, N/32) sub-group tile-grid the
# matmul_bmg kernels expect, times with GPU timestamps, and emits {gflops, kernel_median_us}.  The .spv
# is selected at runtime via CRISP_MATMUL_SPV, so the harness builds ONCE (precision-agnostic) and the
# kernel recompiles per precision.  Compiled with icpx in the Docker container / clang++ for a native
# Windows-BMG smoke test.  (Advanced kernels with a different param layout — e.g. the register-ring
# prefetch chapter — will need their own harness / a --grid-tile hoist path, added in Step 4.)
# ---------------------------------------------------------------------------

def _hoist_l0_bin(crisp_compiler):
    """Sibling crisp-hoist-l0 binary next to crisp-compile."""
    p = Path(crisp_compiler)
    return str(p.parent / ("crisp-hoist-l0" + (".exe" if p.suffix == ".exe" else "")))

def run_l0_autobench(src_path: Path, M: int, N: int, K: int, warmup: int, iters: int, crisp_compiler: str,
                     prec_flags=(), cxx_flags=()):
    chap_dir = src_path.parent
    base = src_path.stem
    spv = chap_dir / f"{base}.spv"
    metacrisp = chap_dir / f"{base}_matmul.metacrisp"
    if not (spv.exists() and metacrisp.exists()):
        sh([crisp_compiler, "--ir-target=spv", "--hardware-profile=bmg", *prec_flags, "--log-level=off", str(src_path)], check=True)
        sh([crisp_compiler, "--hoist=l0", "--hardware-profile=bmg", *prec_flags, "--log-level=off", str(src_path)], check=True)
    if not metacrisp.exists():
        print(f"autobench-l0: no metacrisp {metacrisp}", file=sys.stderr); return None
    
    sh([_hoist_l0_bin(crisp_compiler), f"--mma-test={M},{N},{K}", f"--mma-bench={iters}", str(metacrisp)])
    cpp = chap_dir / f"{base}_matmul_L0.cpp"
    if not cpp.exists():
        print(f"autobench-l0: no bench .cpp {cpp}", file=sys.stderr); return None
    
    txt = cpp.read_text()
    txt = re.sub(r'"[^"]*' + re.escape(base) + r'\.spv"', '"' + str(spv).replace("\\", "/") + '"', txt)
    cpp.write_text(txt)
    
    exe = chap_dir / f"{base}_bench_l0"
    cxx, link_pre, link_post = _resolve_cxx_and_l0_link()
    c = sh([cxx, "-O3", *cxx_flags, str(cpp), *link_pre, "-o", str(exe), *link_post], capture_output=True, text=True)
    if c.returncode != 0:
        print("autobench-l0 build failed:\n" + (c.stderr or "")[-1200:], file=sys.stderr); return None
    
    p = sh([str(exe)], capture_output=True, text=True)
    out = (p.stdout or "") + (p.stderr or "")
    m = re.search(r'BENCH\s+(\d+)\s+(\d+)\s+(\d+)\s+([\d.]+)\s*GFLOPS\s*\((\d+)\s*iters,\s*([\d.]+)\s*s\)', out)
    if not m:
        print("autobench-l0 parse failed:\n" + out[-800:], file=sys.stderr); return None
    gflops = float(m.group(4))
    secs = float(m.group(6))
    iters_ran = int(m.group(5))
    k_us = (secs / iters_ran) * 1e6
    return {"gflops": gflops, "kernel_median_us": k_us,
            "correct": ("MMA_CORRECT" in out), "wall_time_ms": 0.0, "driver_jit_ms": 0.0}

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
    for s in sizes:
        S = int(s)
        w, it = scaled_counts(warmup, iters, S)
        out = run_l0_autobench(src, S, S, S, w, it, crisp_compiler, prec_flags, [])
        if not out:
            continue
        if not out.get("correct", False):
            print(f"  ! {chapter} ({comp_name}) {S}^3: NOT MMA_CORRECT — skipping point", file=sys.stderr)
            continue
        results.append(SweepPoint(
            configuration={"m": S, "n": S, "k": S, "warmup": w, "iters": it},
            metrics=BenchmarkMetrics(
                compile_time=CompileTimeMetrics(device_compile_ms=dev_c_ms,
                                                all_compile_ms=dev_c_ms),
                runtime=RuntimeMetrics(wall_time_ms=out.get("wall_time_ms", 0.0),
                                       kernel_execution_ms=out.get("kernel_median_us", 0.0) / 1000.0),
                throughput=ThroughputMetrics(tflops=out.get("gflops", 0.0) / 1000.0))))
    return BenchmarkSweep(run_metadata=meta, benchmark_suite="matmul", chapter=chapter, competitor=comp_name,
                          precision=precision, denormal_handling="ftz" if ftz else "preserve", results=results)

def _resolve_cxx_and_l0_link():
    """(cxx, link_pre, link_post) for the L0 harness compile.  Container(Linux): icpx + -lze_loader
    (system Level Zero headers).  Windows(native smoke test): clang++ (llvm-mingw) + the L0 include dir
    + ze_loader.dll (-static).  All overridable via CRISP_CLANGXX / CRISP_L0_INCLUDE / CRISP_ZE_LOADER."""
    if _platform.system() == "Windows":
        clang  = os.environ.get("CRISP_CLANGXX",
                 "C:/Users/cperk/Documents/llvm-mingw-20251216-ucrt-x86_64/bin/clang++.exe")
        lz_inc = os.environ.get("CRISP_L0_INCLUDE", "C:/Users/cperk/Documents/level-zero/include")
        ze     = os.environ.get("CRISP_ZE_LOADER", "C:/Windows/System32/ze_loader.dll")
        return clang, ["-I", lz_inc], [ze, "-static"]
    cxx = shutil.which("icpx") or shutil.which("clang++") or "g++"
    return cxx, [], ["-lze_loader"]

def run_l0_bin(path, size, warmup, iters, env_extra=None):
    """Run the fixed L0 harness — its args are [Size, warmup, iters] (square), NOT [M,N,K,...].
    JSON on stdout ({gflops, kernel_median_us, ...}); the device name goes to stderr."""
    env = dict(os.environ)
    if env_extra: env.update(env_extra)
    p = sh([path, str(size), str(warmup), str(iters)], capture_output=True, text=True, env=env)
    try:
        return json.loads(p.stdout)
    except Exception:
        print(p.stdout, (p.stderr or "")[-600:], file=sys.stderr)
        return None

def build_l0_harness(crisp_compiler):
    """Compile benchmarks/matmul/crisp/bench_harness_l0.cpp once -> the timed L0 launcher binary.
    Precision-agnostic (it measures whatever .spv CRISP_MATMUL_SPV points at).  Returns the binary
    path, or None if the harness source / a C++ compiler is unavailable."""
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
    """Compile the Crisp kernel -> SPV (bmg, explicit precision flags), then run the fixed L0 harness
    per size (CRISP_MATMUL_SPV env) and collect {gflops, kernel_median_us} into a BenchmarkSweep."""
    meta = _apply_hw(create_metadata())
    src = Path(kernel_src)
    spv = src.parent / f"{src.stem}.spv"
    prec_flags = [f"--math-precision={precision}",
                  f"--denormal-handling={'ftz' if ftz else 'preserve'}"]
    empty = BenchmarkSweep(run_metadata=meta, benchmark_suite="matmul", chapter=chapter,
                           competitor=comp_name, precision=precision,
                           denormal_handling="ftz" if ftz else "preserve", results=[])
    try:
        dev_c_ms = time_compile([crisp_compiler, "--ir-target=spv", "--hardware-profile=bmg",
                                 *prec_flags, "--log-level=off", str(src)])
    except subprocess.CalledProcessError:
        print(f"l0-fixed: crisp-compile failed for {src.name}", file=sys.stderr); return empty
    if not spv.exists():
        print(f"l0-fixed: no spv {spv}", file=sys.stderr); return empty
    env_ext = {"CRISP_MATMUL_SPV": str(spv)}
    results = []
    for s in sizes:
        S = int(s)
        w, it = scaled_counts(warmup, iters, S)   # bound GPU pin time (BMG is the display GPU)
        out = run_l0_bin(harness_bin, S, w, it, env_ext)
        if not out:
            continue
        results.append(SweepPoint(
            configuration={"m": S, "n": S, "k": S, "warmup": w, "iters": it},
            metrics=BenchmarkMetrics(
                compile_time=CompileTimeMetrics(device_compile_ms=dev_c_ms, all_compile_ms=dev_c_ms),
                runtime=RuntimeMetrics(wall_time_ms=out.get("wall_time_ms", 0.0),
                                       kernel_execution_ms=out.get("kernel_median_us", 0.0) / 1000.0),
                throughput=ThroughputMetrics(tflops=out.get("gflops", 0.0) / 1000.0))))
    return BenchmarkSweep(run_metadata=meta, benchmark_suite="matmul", chapter=chapter, competitor=comp_name,
                          precision=precision, denormal_handling="ftz" if ftz else "preserve", results=results)

# ===========================================================================
# MATH-FLAG POLICY — ALWAYS explicit, NEVER rely on a compiler's defaults.
# ---------------------------------------------------------------------------
# nvcc, icpx, and crisp-compile each have their OWN default precision and
# denormal behavior, they are NOT the same across compilers, and the documented/
# reported defaults conflict (asking different sources gives different answers).
# So every compile in this driver passes a COMPLETE, explicit set of flags for
# BOTH precision AND denormal handling — a bare `nvcc -O3 ...` (relying on the
# default) is never emitted.  If you add a compiler, give it an explicit builder
# here too.  (crisp-compile's explicit flags are --math-precision / --denormal-
# handling, applied on both Crisp paths in run_target / run_autobench_sweep.)
# ===========================================================================

def nvcc_math_flags(prec, ftz):
    """Explicit nvcc floating-point flags — never rely on nvcc's defaults.  Four independent knobs:
         -ftz=<b>       : flush denormals to zero (true) vs keep them (false)
         -prec-div=<b>  : IEEE-correct division (true) vs fast approximation (false)
         -prec-sqrt=<b> : IEEE-correct sqrt (true) vs fast approximation (false)
         -fmad=<b>      : fuse mul+add into an FMA (single-rounding, IEEE-754 conformant)
       'fast' is the explicit expansion of -use_fast_math (approx div/sqrt + flush).  -fmad is kept
       ON for every mode: an FMA is a single correctly-rounded op (more accurate than mul-then-add),
       and it's what the tensor-core path uses — the precision axis here is div/sqrt + denormals."""
    b = lambda x: "true" if x else "false"
    return [f"-ftz={b(ftz)}",
            f"-prec-div={b(prec != 'fast')}",
            f"-prec-sqrt={b(prec != 'fast')}",
            "-fmad=true"]

def icpx_math_flags(prec, ftz):
    """Explicit icpx (Intel DPC++/SYCL) floating-point flags — never rely on icpx's defaults.
         -fp-model=<fast|precise> : overall FP model (fast permits reassociation + approximations)
         -ffp-contract=<fast|on>  : FMA contraction (kept on; single-rounding, IEEE-safe)
         -ftz / -no-ftz           : flush denormals to zero (true) vs preserve (false)
       CONFIDENCE NOTE: -fp-model and -ffp-contract are solid.  -ftz/-no-ftz are the documented
       Intel-compiler denormal knobs and icpx accepts them, but whether they reach the SYCL *device*
       (SPIR-V DenormFlushToZero/Preserve) rather than just host code is NOT something I want to
       assert — VERIFY on Intel HW before trusting the ftz-vs-preserve split for SYCL.  (Moot on the
       NVIDIA pods, where SYCL/icpx is absent and these targets are skipped.)"""
    return [f"-fp-model={'fast' if prec == 'fast' else 'precise'}",
            "-ffp-contract=fast",
            ("-ftz" if ftz else "-no-ftz")]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sizes", default="256,512,1024,2048,4096")
    ap.add_argument("--warmup", type=int, default=20)
    ap.add_argument("--iters", type=int, default=100)
    ap.add_argument("--output-dir", default=str(HERE.parent / "results"))
    ap.add_argument("--precision", choices=["ieee", "fast"], default="fast")
    ap.add_argument("--ftz", action="store_true", help="Enable Flush-To-Zero")
    ap.add_argument("--sweep-all", action="store_true", help="Run full precision matrix (Fast, IEEE+FTZ, IEEE)")
    ap.add_argument("--platform", choices=["nvidia", "intel"], default="nvidia",
                    help="nvidia (default): nvcc/cuBLAS + Crisp PTX, runs natively on a RunPod. "
                         "intel: icpx SYCL/oneMKL + Crisp SPIR-V/L0, runs inside the bench Docker container (BMG).")
    a = ap.parse_args()

    global HW, SIZE_SCALE_REF
    HW = HW_BY_PLATFORM[a.platform]
    # Intel BMG is the display GPU here, so 2048 at full iters already freezes the desktop — scale from
    # 1024.  NVIDIA runs on a dedicated pod (no display to starve), so only 4096 needs bounding.
    SIZE_SCALE_REF = 1024 if a.platform == "intel" else 2048

    sizes = a.sizes.split(",")
    out_dir = Path(a.output_dir)

    matrix = [(a.precision, a.ftz)]
    if a.sweep_all:
        # Fast math implies flush-to-zero (nvcc --use_fast_math flushes denormals), so the
        # coherent "peak" point is fast+ftz, not fast+preserve.  The three meaningful math
        # configs: peak (fast+ftz), sweet-spot (ieee+ftz), strict (ieee+preserve).
        matrix = [
            ("fast", True),
            ("ieee", True),
            ("ieee", False)
        ]

    # Absolute path to crisp-compile binary (assumes ran from repo root).  .exe on Windows (native Intel
    # smoke test), unadorned in the Linux container / on the pod.
    repo_root = HERE.parent.parent
    crisp_compiler = str(repo_root / "bin" / "crisp-compile.exe") \
        if (repo_root / "bin" / "crisp-compile.exe").exists() else str(repo_root / "bin" / "crisp-compile")

    # Pre-build the Crisp launcher harness ONCE (precision-agnostic — it measures the separately-compiled
    # device code).  NVIDIA: the nvcc PTX harness.  Intel: the L0 fixed harness (nvcc is absent in the
    # bench container).
    l0_harness = None
    if a.platform == "nvidia":
        build_harness()
    else:
        l0_harness = build_l0_harness(crisp_compiler)

    for prec, ftz in matrix:
        print(f"\n--- Running Suite with precision={prec}, ftz={ftz} ---")
        
        # Flags — ALWAYS explicit for precision AND denormals (see MATH-FLAG POLICY above);
        # never a bare `nvcc -O3` / `icpx -O3` that would inherit an unknown default.
        nv_math = nvcc_math_flags(prec, ftz)
        nvcc_flags   = ["-O3", "-arch=sm_90", *nv_math]
        cublas_flags = ["-O3", "-arch=sm_90", "-lcublas", *nv_math]
        if prec == "fast":
            # -DFAST_MATH selects the tf32 tensor-core math mode inside cublas_optimal.cu
            # (cublasSetMathMode).  cuBLAS's own GEMM ignores the nvcc FP flags above, so this
            # tf32-vs-fp32 choice — not -ftz — is what actually moves cuBLAS between precisions.
            cublas_flags.append("-DFAST_MATH")
        sycl_flags   = ["-fsycl", "-O3", *icpx_math_flags(prec, ftz)]

        def run_target(chapter, source_name, bin_name, comp_name, flags, is_sycl=False, is_cublas=False, is_crisp=False, crisp_grid_tile=None):
            src_path = HERE / chapter / source_name
            if not src_path.exists():
                return

            dev_c_ms = 0.0
            all_c_ms = 0.0
            bin_path = HERE / chapter / bin_name

            if is_crisp:
                if not Path(crisp_compiler).exists():
                    print(f"Skipping {comp_name} because {crisp_compiler} not found.")
                    return
                # Crisp compile (device compile) — also measures device compile time
                # Crisp precision flags (Crisp's own axis — distinct from nvcc's — defaulting to
                # ieee, so we must pass them or Crisp competes at IEEE vs fast-math cuBLAS).
                crisp_prec = [f"--math-precision={prec}",
                              f"--denormal-handling={'ftz' if ftz else 'preserve'}"]
                dev_c_ms = time_compile([crisp_compiler, "--ir-target=ptx", "--ir-target-arch=sm_90", *crisp_prec, "--log-level=off", str(src_path)])
                all_c_ms = dev_c_ms # Harness adds driver_jit later
                if crisp_grid_tile:
                    # Advanced kernel (TMA / rings / wgmma): the fixed-layout bench_harness.cu
                    # can't launch it — use the per-kernel --mma-bench auto-harness instead.
                    sweep = run_autobench_sweep(chapter, src_path, crisp_grid_tile, comp_name, sizes,
                                                a.warmup, a.iters, prec, ftz, dev_c_ms, crisp_compiler)
                    sweep.save(out_dir)
                    print(f"Saved {chapter} ({comp_name}) auto-bench sweep to {out_dir}")
                    return
                exe_path = str(HERE / "crisp" / "matmul_crisp")
                env_ext = {"CRISP_MATMUL_PTX": str(bin_path)}
            else:
                # NVCC / ICPX compile
                compiler = "icpx" if is_sycl else "nvcc"
                if is_sycl and not shutil.which("icpx"): return
                
                cmd = [compiler] + flags + [str(src_path), "-o", str(bin_path)]
                if is_sycl and is_cublas: cmd.insert(1, "-qmkl") # OneMKL Optimal
                
                all_c_ms = time_compile(cmd)
                dev_c_ms = all_c_ms # No separate device stage measurable here
                exe_path = str(bin_path)
                env_ext = None
                
            sweep = run_sweep(chapter, exe_path, comp_name, sizes, a.warmup, a.iters, prec, ftz, dev_c_ms, all_c_ms, env_ext)
            sweep.save(out_dir)
            print(f"Saved {chapter} ({comp_name}) sweep to {out_dir}")

        # Endeavor 143: the Intel Crisp path is SPIR-V/L0 (not PTX/CUDA) — the fixed L0 harness.
        def run_l0_crisp(chapter, source_name, comp_name="Crisp", use_autobench=False):
            src = HERE / chapter / source_name
            if not src.exists():
                return
            if not Path(crisp_compiler).exists():
                print(f"Skipping {comp_name} ({chapter}) — {crisp_compiler} not found."); return
            
            if use_autobench:
                dev_c_ms = 0.0 # Will be measured during sweep if needed
                sweep = run_l0_autobench_sweep(chapter, src, comp_name, sizes, a.warmup, a.iters,
                                               prec, ftz, dev_c_ms, crisp_compiler)
            else:
                if not l0_harness:
                    print(f"Skipping {comp_name} ({chapter}) — L0 harness not built."); return
                sweep = run_l0_fixed_sweep(chapter, src, comp_name, l0_harness, sizes, a.warmup, a.iters,
                                           prec, ftz, crisp_compiler)
                
            sweep.save(out_dir)
            print(f"Saved {chapter} ({comp_name}) L0 sweep to {out_dir}")

        if a.platform == "nvidia":
            # Chap 0
            run_target("chap0_sync", "matmul.crisp", "matmul.ptx", "Crisp", [], is_crisp=True)
            run_target("chap0_sync", "cuda_apples.cu", "cuda_apples", "CUDA_Apples", nvcc_flags)
            run_target("chap0_sync", "sycl_apples.cpp", "sycl_apples", "SYCL_Apples", sycl_flags, is_sycl=True)
            run_target("chap0_sync", "cublas_optimal.cu", "cublas_optimal", "CUBLAS_Optimal", cublas_flags, is_cublas=True)
            run_target("chap0_sync", "onemkl_optimal.cpp", "onemkl_optimal", "OneMKL_Optimal", sycl_flags, is_sycl=True, is_cublas=True)

            # Chap 1
            run_target("chap1_async_linear", "matmul_async.crisp", "matmul_async.ptx", "Crisp", [], is_crisp=True)
            run_target("chap1_async_linear", "cuda_apples.cu", "cuda_apples", "CUDA_Apples", nvcc_flags)
            run_target("chap1_async_linear", "sycl_apples.cpp", "sycl_apples", "SYCL_Apples", sycl_flags, is_sycl=True)

            # Chap 1.5 — TMA :block; needs the auto-bench (CuTensorMap params, 64x64 out tile)
            run_target("chap1.5_async_block", "matmul_async_block.crisp", "matmul_async_block.ptx", "Crisp", [], is_crisp=True, crisp_grid_tile="64,64")
            run_target("chap1.5_async_block", "cuda_apples.cu", "cuda_apples", "CUDA_Apples", nvcc_flags)

            # Chap 2 — pipelined rings; auto-bench (ring tiles, 64x64 out tile)
            run_target("chap2_pipelined_block", "matmul_pipe.crisp", "matmul_pipe.ptx", "Crisp", [], is_crisp=True, crisp_grid_tile="64,64")
            run_target("chap2_pipelined_block", "cuda_apples.cu", "cuda_apples", "CUDA_Apples", nvcc_flags)

            # Chap 3 — wgmma tensor cores (Hopper warpgroup async MMA). Auto-bench: 64x256 out tile,
            # tf32.  cuBLAS tf32 is the vendor ceiling.  This is the tensor-core headline.
            run_target("chap3_wgmma", "matmul_wgmma.crisp", "matmul_wgmma.ptx", "Crisp", [], is_crisp=True, crisp_grid_tile="64,256")
            run_target("chap3_wgmma", "cublas_optimal.cu", "cublas_optimal", "CUBLAS_Optimal", cublas_flags, is_cublas=True)
        else:
            # --- Intel/BMG ladder (endeavor 143) ---
            # chap0_sync — synchronous coop-matrix tiling.  Crisp (SPV/L0) vs SYCL_Apples vs OneMKL ceiling.
            run_l0_crisp("chap0_sync", "matmul_bmg.crisp")
            run_target("chap0_sync", "sycl_apples.cpp", "sycl_apples", "SYCL_Apples", sycl_flags, is_sycl=True)
            run_target("chap0_sync", "onemkl_optimal.cpp", "onemkl_optimal", "OneMKL_Optimal", sycl_flags, is_sycl=True, is_cublas=True)

            # chap1_async_linear — OpGroupAsyncCopy staging.
            run_l0_crisp("chap1_async_linear", "matmul_bmg_async.crisp")
            run_target("chap1_async_linear", "sycl_apples.cpp", "sycl_apples", "SYCL_Apples", sycl_flags, is_sycl=True)

            # chap_intel_prefetch — the endeavor-142 register-ring + Subgroup2DBlockPrefetch pipeline.
            # STEP 4 (this is where Q1 gets answered): the register-ring kernel has a DIFFERENT param
            # layout than the fixed bench_harness_l0.cpp (no scratch tiles), so it needs its own harness
            # (or a --grid-tile hoist path).  Parked until the chap0/chap1 plumbing is proven.
            run_l0_crisp("intel_prefetch", "matmul_bmg_prefetch.crisp", use_autobench=True)

if __name__ == "__main__":
    main()
