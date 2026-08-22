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

def time_compile(cmd, **kw):
    t0 = time.time()
    res = sh(cmd, **kw)
    t1 = time.time()
    res.check_returncode()
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
    sh(["nvcc", "-O3", "-arch=sm_90", *nvcc_math_flags("ieee", False),
        str(HERE/"crisp/bench_harness.cu"), "-lcuda", "-o", str(HERE/"crisp/matmul_crisp")], check=True)

def run_sweep(chapter: str, exe_path: str, competitor_name: str, sizes: list, warmup: int, iters: int, precision: str, ftz: bool, compile_dev_ms: float, compile_all_ms: float, env_extra: dict = None) -> BenchmarkSweep:
    meta = _apply_hw(create_metadata())
    results = []
    for s in sizes:
        S = int(s)
        w, it = scaled_counts(warmup, iters, S)
        out = run_bin(exe_path, S, S, S, w, it, env_extra)
        if not out: continue

        if not out.get("correct", True):
            print(f"  DROPPED {competitor_name} @ {S}: harness reported correct=false "
                  f"(max_abs_err={out.get('max_abs_err')})", file=sys.stderr)
            continue

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
    cu.write_text(txt)
    exe = chap_dir / f"{base}_bench"
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
        compile_ms = time_compile([crisp_compiler, "--ir-target=spv", f"--hardware-profile={INTEL_HW_PROFILE}", *prec_flags, "--log-level=off", str(src_path)])
        hoist_ms = time_compile([crisp_compiler, "--hoist=l0", f"--hardware-profile={INTEL_HW_PROFILE}", *prec_flags, "--log-level=off", str(src_path)])
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
    m = re.search(r'BENCH\s+(\d+)\s+(\d+)\s+(\d+)\s+([\d.]+)\s*GFLOPS\s*\((\d+)\s*iters,\s*([\d.eE+-]+)\s*s\)', out)
    if not m:
        print("autobench-l0 parse failed:\n" + out[-800:], file=sys.stderr); return None
    gflops = float(m.group(4))
    secs = float(m.group(6))
    iters_ran = int(m.group(5))
    mm = re.search(r'median_us=([\d.eE+-]+)', out)
    k_us = float(mm.group(1)) if mm else (secs / iters_ran) * 1e6
    method = re.search(r'method=(\w+)', out)
    return {"gflops": gflops, "kernel_median_us": k_us,
            "timing_method": method.group(1) if method else "batched_submit_legacy",
            "compile_ms": compile_ms, "hoist_ms": hoist_ms,
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
        if not out.get("correct", False):
            print(f"  ! {chapter} ({comp_name}) {S}^3: NOT MMA_CORRECT — skipping point", file=sys.stderr)
            continue
        results.append(SweepPoint(
            configuration={"m": S, "n": S, "k": S, "warmup": w, "iters": it},
            metrics=BenchmarkMetrics(
                compile_time=CompileTimeMetrics(device_compile_ms=measured_c_ms or dev_c_ms,
                                                all_compile_ms=(measured_c_ms + measured_hoist_ms) or dev_c_ms),
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
    p = sh([path, str(M), str(N), str(K), str(warmup), str(iters)], capture_output=True, text=True, env=env)
    try:
        return json.loads(p.stdout)
    except Exception:
        print(p.stdout, (p.stderr or "")[-600:], file=sys.stderr)
        return None

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
    env_ext = {"CRISP_MATMUL_SPV": str(spv)}
    results = []
    for s in sizes:
        S = int(s)
        w, it = scaled_counts(warmup, iters, S)
        out = run_l0_bin(harness_bin, S, S, S, w, it, env_extra=env_ext)
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

            dev_c_ms = 0.0
            all_c_ms = 0.0
            bin_path = HERE / chapter / bin_name

            if is_crisp:
                if not Path(crisp_compiler).exists():
                    print(f"Skipping {comp_name} because {crisp_compiler} not found.")
                    return
                crisp_prec = [f"--math-precision={prec}",
                              f"--denormal-handling={'ftz' if ftz else 'preserve'}"]
                dev_c_ms = time_compile([crisp_compiler, "--ir-target=ptx", "--ir-target-arch=sm_90", f"--hardware-profile={NVIDIA_HW_PROFILE}", *crisp_prec, "--log-level=off", str(src_path)])
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
                if is_sycl and not shutil.which("icpx"): return
                
                cmd = [compiler] + flags + [str(src_path), "-o", str(bin_path)]
                if is_sycl and is_cublas: cmd.insert(1, "-qmkl")

                all_c_ms = time_compile(cmd)
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
            
            if use_autobench:
                dev_c_ms = 0.0
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
            # §1 Ch 0 — Naive loops, no tensor cores (fp32)
            run_target("chap0_naive", "matmul.crisp", "matmul.ptx", "Crisp", [], is_crisp=True)
            run_target("chap0_naive", "cuda_apples.cu", "cuda_apples", "CUDA_Apples", nvcc_flags)
            run_target("chap0_naive", "sycl_apples.cpp", "sycl_apples", "SYCL_Apples", sycl_flags, is_sycl=True)

            # §1 Ch 1 — Hand-rolled mma-accumulate-via-tile (tf32)
            run_target("chap1_handrolled_mma", "matmul.crisp", "matmul.ptx", "Crisp", [], is_crisp=True)
            run_target("chap1_handrolled_mma", "cuda_apples.cu", "cuda_apples", "CUDA_Apples", nvcc_flags)
            run_target("chap1_handrolled_mma", "sycl_apples.cpp", "sycl_apples", "SYCL_Apples", sycl_flags, is_sycl=True)

            # §1 Ch 2 — matrix-multiply-tile-stride macro (tiling)
            run_target("chap2_tiling", "matmul.crisp", "matmul.ptx", "Crisp", [], is_crisp=True)
            run_target("chap2_tiling", "cuda_apples.cu", "cuda_apples", "CUDA_Apples", nvcc_flags)
            run_target("chap2_tiling", "sycl_apples.cpp", "sycl_apples", "SYCL_Apples", sycl_flags, is_sycl=True)

            # §1 Ch 3 — cp.async linear pipelining
            run_target("chap3_async", "matmul_async.crisp", "matmul_async.ptx", "Crisp", [], is_crisp=True)
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
            run_target("sec2_top", "cutlass_peer.cu", "cutlass_peer", "CUTLASS", ["-O3", "-std=c++17", "-arch=sm_90a", "-I/workspace/cutlass/include"])
            run_target("sec2_top", "cublas_ceiling.cu", "cublas_ceiling", "CUBLAS_Optimal", cublas_flags, is_cublas=True)

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
            run_target("chap5_multistage_ring", "sycl_apples.cpp", "sycl_apples", "SYCL_Apples", sycl_flags + ["-Xs", "-ze-opt-large-register-file"], is_sycl=True)

            # SYCL-TLA (CUTLASS 3.x for Intel Xe2) specific flags
            tla_dir = HERE.parent.parent / "third_party" / "sycl-tla"
            tla_inc = [f"-I{tla_dir}/include", f"-I{tla_dir}/tools/util/include"]
            sycl_tla_flags = sycl_flags + tla_inc + [
                "-DCUTLASS_ENABLE_SYCL=ON", "-DSYCL_INTEL_TARGET=1",
                "-fno-sycl-instrument-device-code",
                "-fsycl-targets=spir64_gen",
                "-Xsycl-target-backend=spir64_gen", "-device bmg-g21",
                "-Xspirv-translator",
                "-spirv-ext=+SPV_INTEL_split_barrier,+SPV_INTEL_2d_block_io,+SPV_INTEL_subgroup_matrix_multiply_accumulate"
            ]

            # §2 — Top MMA Benchmarks (TF32 / FP32 Precision Tier)
            run_l0_crisp("sec2_top", "matmul_bmg.crisp", use_autobench=True)
            run_target("sec2_top", "sycl_control.cpp", "sycl_control", "SYCL_Apples", sycl_flags + ["-Xs", "-ze-opt-large-register-file"], is_sycl=True)
            run_target("sec2_top", "onemkl_ceiling.cpp", "onemkl_ceiling", "OneMKL_Optimal", sycl_flags, is_sycl=True, is_cublas=True)

            # §2.1 — Top MMA Benchmarks (BFloat16 Low-Precision Tier)
            run_l0_crisp("sec2_top_bf16", "matmul_bmg_bf16.crisp", use_autobench=True)
            run_target("sec2_top_bf16", "sycl_control_bf16.cpp", "sycl_control_bf16", "SYCL_Apples_BF16", sycl_flags + ["-Xs", "-ze-opt-large-register-file"], is_sycl=True)
            run_target("sec2_top_bf16", "sycl_tla_peer.cpp", "sycl_tla_peer", "SYCL-TLA_BF16", sycl_tla_flags, is_sycl=True)
            run_target("sec2_top_bf16", "onemkl_bf16.cpp", "onemkl_bf16", "OneMKL_BF16", sycl_flags, is_sycl=True, is_cublas=True)

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
