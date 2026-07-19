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
from pathlib import Path

# Add parent dir to path so we can import harness
sys.path.append(str(Path(__file__).resolve().parent))
from harness import BenchmarkSweep, SweepPoint, BenchmarkMetrics, CompileTimeMetrics, RuntimeMetrics, ThroughputMetrics, create_metadata

HERE = Path(__file__).resolve().parent.parent.parent / "benchmarks" / "matmul"

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
    # Build the crisp harness (needed for running Crisp kernels)
    sh(["nvcc", "-O3", "-arch=sm_90", str(HERE/"crisp/bench_harness.cu"), "-lcuda", "-o", str(HERE/"crisp/matmul_crisp")], check=True)

def run_sweep(chapter: str, exe_path: str, competitor_name: str, sizes: list, warmup: int, iters: int, precision: str, ftz: bool, compile_dev_ms: float, compile_all_ms: float, env_extra: dict = None) -> BenchmarkSweep:
    meta = create_metadata()
    meta.hardware.gpu_model = "NVIDIA H100"
    meta.hardware.arch_target = "sm_90"
    meta.hardware.environment = "runpod"

    results = []
    for s in sizes:
        S = int(s)
        out = run_bin(exe_path, S, S, S, warmup, iters, env_extra)
        if not out: continue
        
        # If the harness returns driver_jit_ms, we add it to the measured all_compile_ms
        driver_jit = out.get("driver_jit_ms", 0.0)
        final_all_compile_ms = compile_all_ms + driver_jit
        
        point = SweepPoint(
            configuration={"m": S, "n": S, "k": S, "warmup": warmup, "iters": iters},
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

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sizes", default="256,512,1024,2048,4096")
    ap.add_argument("--warmup", type=int, default=20)
    ap.add_argument("--iters", type=int, default=100)
    ap.add_argument("--output-dir", default=str(HERE.parent / "results"))
    ap.add_argument("--precision", choices=["ieee", "fast"], default="fast")
    ap.add_argument("--ftz", action="store_true", help="Enable Flush-To-Zero")
    ap.add_argument("--sweep-all", action="store_true", help="Run full precision matrix (Fast, IEEE+FTZ, IEEE)")
    a = ap.parse_args()

    sizes = a.sizes.split(",")
    out_dir = Path(a.output_dir)
    
    matrix = [(a.precision, a.ftz)]
    if a.sweep_all:
        matrix = [
            ("fast", False),
            ("ieee", True),
            ("ieee", False)
        ]

    # Pre-build harness
    build_harness()
    
    # Absolute path to crisp-compile binary (assumes ran from repo root)
    repo_root = HERE.parent.parent.parent
    crisp_compiler = str(repo_root / "bin" / "crisp-compile")
    
    for prec, ftz in matrix:
        print(f"\n--- Running Suite with precision={prec}, ftz={ftz} ---")
        
        # Flags
        nvcc_flags = ["-O3", "-arch=sm_90"]
        if prec == "fast":
            nvcc_flags.append("-use_fast_math")
        elif ftz:
            nvcc_flags.append("-ftz=true")
            
        cublas_flags = ["-O3", "-arch=sm_90", "-lcublas"]
        if prec == "fast":
            cublas_flags.append("-DFAST_MATH")
            
        sycl_flags = ["-fsycl", "-O3"]

        def run_target(chapter, source_name, bin_name, comp_name, flags, is_sycl=False, is_cublas=False, is_crisp=False):
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
                # Crisp compile (device compile)
                dev_c_ms = time_compile([crisp_compiler, str(src_path), "-o", str(bin_path)])
                all_c_ms = dev_c_ms # Harness adds driver_jit later
                exe_path = str(HERE / "crisp" / "matmul_crisp")
                env_ext = {"CRISP_MATMUL_PTX": str(bin_path)}
            else:
                # NVCC / ICPX compile
                compiler = "icpx" if is_sycl else "nvcc"
                if is_sycl and not shutil.which("icpx"): return
                
                cmd = [compiler] + flags + [str(src_path), "-o", str(bin_path)]
                if is_sycl and is_cublas: cmd.insert(1, "-onemkl") # OneMKL Optimal
                
                all_c_ms = time_compile(cmd)
                dev_c_ms = all_c_ms # No separate device stage measurable here
                exe_path = str(bin_path)
                env_ext = None
                
            sweep = run_sweep(chapter, exe_path, comp_name, sizes, a.warmup, a.iters, prec, ftz, dev_c_ms, all_c_ms, env_ext)
            sweep.save(out_dir)
            print(f"Saved {chapter} ({comp_name}) sweep to {out_dir}")

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
        
        # Chap 1.5
        run_target("chap1.5_async_block", "matmul_async_block.crisp", "matmul_async_block.ptx", "Crisp", [], is_crisp=True)
        run_target("chap1.5_async_block", "cuda_apples.cu", "cuda_apples", "CUDA_Apples", nvcc_flags)
        
        # Chap 2
        run_target("chap2_pipelined_block", "matmul_pipe.crisp", "matmul_pipe.ptx", "Crisp", [], is_crisp=True)
        run_target("chap2_pipelined_block", "cuda_apples.cu", "cuda_apples", "CUDA_Apples", nvcc_flags)

if __name__ == "__main__":
    main()
