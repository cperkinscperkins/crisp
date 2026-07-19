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
from pathlib import Path

# Add parent dir to path so we can import harness
sys.path.append(str(Path(__file__).resolve().parent))
from harness import BenchmarkSweep, SweepPoint, BenchmarkMetrics, CompileTimeMetrics, RuntimeMetrics, ThroughputMetrics, create_metadata

HERE = Path(__file__).resolve().parent.parent.parent / "benchmarks" / "matmul"

def sh(cmd, **kw):
    print("  $", " ".join(str(c) for c in cmd), file=sys.stderr)
    return subprocess.run([str(c) for c in cmd], **kw)

def run_bin(path, M, N, K, warmup, iters, env_extra=None):
    env = dict(os.environ)
    if env_extra: env.update(env_extra)
    p = sh([path, str(M), str(N), str(K), str(warmup), str(iters)], cwd=str(HERE/"crisp"), capture_output=True, text=True, env=env)
    try:
        return json.loads(p.stdout)
    except Exception:
        print(p.stdout, p.stderr, file=sys.stderr)
        return None

def build_harness(precision: str, ftz: bool):
    # Crisp harness
    sh(["nvcc", "-O3", "-arch=sm_90", str(HERE/"crisp/bench_harness.cu"), "-lcuda", "-o", str(HERE/"crisp/matmul_crisp")], check=True)
    
    # Precision flags for CUDA
    nvcc_flags = ["-O3", "-arch=sm_90"]
    if precision == "fast":
        nvcc_flags.append("-use_fast_math")
    elif ftz:
        nvcc_flags.append("-ftz=true")
        
    # CUDA Apples-to-Apples (Chap 0 Baseline)
    if (HERE / "chap0_sync" / "cuda_apples.cu").exists():
        sh(["nvcc"] + nvcc_flags + [str(HERE/"chap0_sync/cuda_apples.cu"), "-o", str(HERE/"chap0_sync/cuda_apples")], check=True)

    # CUDA Apples-to-Apples (Chap 1 Baseline)
    if (HERE / "chap1_async_linear" / "cuda_apples.cu").exists():
        sh(["nvcc"] + nvcc_flags + [str(HERE/"chap1_async_linear/cuda_apples.cu"), "-o", str(HERE/"chap1_async_linear/cuda_apples")], check=True)

    # CUDA Apples-to-Apples (Chap 1.5 Baseline)
    if (HERE / "chap1.5_async_block" / "cuda_apples.cu").exists():
        sh(["nvcc"] + nvcc_flags + [str(HERE/"chap1.5_async_block/cuda_apples.cu"), "-o", str(HERE/"chap1.5_async_block/cuda_apples")], check=True)

    # CUDA Apples-to-Apples (Chap 2 Baseline)
    if (HERE / "chap2_pipelined_block" / "cuda_apples.cu").exists():
        sh(["nvcc"] + nvcc_flags + [str(HERE/"chap2_pipelined_block/cuda_apples.cu"), "-o", str(HERE/"chap2_pipelined_block/cuda_apples")], check=True)

    # CUBLAS Optimal (Vendor Ceiling)
    cublas_flags = ["-O3", "-arch=sm_90", "-lcublas"]
    if precision == "fast":
        cublas_flags.append("-DFAST_MATH")
    
    if (HERE / "chap0_sync" / "cublas_optimal.cu").exists():
        sh(["nvcc"] + cublas_flags + [str(HERE/"chap0_sync/cublas_optimal.cu"), "-o", str(HERE/"chap0_sync/cublas_optimal")], check=True)

    # SYCL Apples & OneMKL Optimal (only build if icpx is present)
    if shutil.which("icpx"):
        sycl_flags = ["-fsycl", "-O3"]
        if (HERE / "chap0_sync" / "sycl_apples.cpp").exists():
            sh(["icpx"] + sycl_flags + [str(HERE/"chap0_sync/sycl_apples.cpp"), "-o", str(HERE/"chap0_sync/sycl_apples")], check=True)
        if (HERE / "chap1_async_linear" / "sycl_apples.cpp").exists():
            sh(["icpx"] + sycl_flags + [str(HERE/"chap1_async_linear/sycl_apples.cpp"), "-o", str(HERE/"chap1_async_linear/sycl_apples")], check=True)
        if (HERE / "chap0_sync" / "onemkl_optimal.cpp").exists():
            sh(["icpx"] + sycl_flags + ["-onemkl", str(HERE/"chap0_sync/onemkl_optimal.cpp"), "-o", str(HERE/"chap0_sync/onemkl_optimal")], check=True)

def run_sweep(chapter: str, exe_path: str, competitor_name: str, sizes: list, warmup: int, iters: int, precision: str, ftz: bool, env_extra: dict = None) -> BenchmarkSweep:
    meta = create_metadata()
    meta.hardware.gpu_model = "NVIDIA H100"
    meta.hardware.arch_target = "sm_90"
    meta.hardware.environment = "runpod"

    results = []
    for s in sizes:
        S = int(s)
        out = run_bin(exe_path, S, S, S, warmup, iters, env_extra)
        if not out: continue
        
        point = SweepPoint(
            configuration={"m": S, "n": S, "k": S, "warmup": warmup, "iters": iters},
            metrics=BenchmarkMetrics(
                compile_time=CompileTimeMetrics(device_compile_ms=0.0, all_compile_ms=out.get("driver_jit_ms", 0.0)), 
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

    for prec, ftz in matrix:
        print(f"\n--- Running Suite with precision={prec}, ftz={ftz} ---")
        build_harness(prec, ftz)

        # Chap 0 (Crisp)
        if (HERE / "chap0_sync" / "matmul.ptx").exists():
            sweep = run_sweep("chap0_sync", HERE/"crisp/matmul_crisp", "Crisp", sizes, a.warmup, a.iters, prec, ftz, {"CRISP_MATMUL_PTX": str(HERE / "chap0_sync" / "matmul.ptx")})
            sweep.save(out_dir)
            print(f"Saved Chap0 (Crisp) sweep to {out_dir}")

        # Chap 0 (CUDA Apples)
        if (HERE / "chap0_sync" / "cuda_apples").exists():
            sweep = run_sweep("chap0_sync", HERE/"chap0_sync/cuda_apples", "CUDA_Apples", sizes, a.warmup, a.iters, prec, ftz)
            sweep.save(out_dir)
            print(f"Saved Chap0 (CUDA Apples) sweep to {out_dir}")

        # Chap 0 (SYCL Apples)
        if (HERE / "chap0_sync" / "sycl_apples").exists():
            sweep = run_sweep("chap0_sync", HERE/"chap0_sync/sycl_apples", "SYCL_Apples", sizes, a.warmup, a.iters, prec, ftz)
            sweep.save(out_dir)
            print(f"Saved Chap0 (SYCL Apples) sweep to {out_dir}")

        # CUBLAS Optimal
        if (HERE / "chap0_sync" / "cublas_optimal").exists():
            sweep = run_sweep("vendor_ceiling", HERE/"chap0_sync/cublas_optimal", "CUBLAS_Optimal", sizes, a.warmup, a.iters, prec, ftz)
            sweep.save(out_dir)
            print(f"Saved CUBLAS Optimal sweep to {out_dir}")

        # OneMKL Optimal
        if (HERE / "chap0_sync" / "onemkl_optimal").exists():
            sweep = run_sweep("vendor_ceiling", HERE/"chap0_sync/onemkl_optimal", "OneMKL_Optimal", sizes, a.warmup, a.iters, prec, ftz)
            sweep.save(out_dir)
            print(f"Saved OneMKL Optimal sweep to {out_dir}")

        # Chap 1 (Crisp)
        if (HERE / "chap1_async_linear" / "matmul_async.ptx").exists():
            sweep = run_sweep("chap1_async_linear", HERE/"crisp/matmul_crisp", "Crisp", sizes, a.warmup, a.iters, prec, ftz, {"CRISP_MATMUL_PTX": str(HERE / "chap1_async_linear" / "matmul_async.ptx")})
            sweep.save(out_dir)
            print(f"Saved Chap1 (Crisp) sweep to {out_dir}")

        # Chap 1 (CUDA Apples)
        if (HERE / "chap1_async_linear" / "cuda_apples").exists():
            sweep = run_sweep("chap1_async_linear", HERE/"chap1_async_linear/cuda_apples", "CUDA_Apples", sizes, a.warmup, a.iters, prec, ftz)
            sweep.save(out_dir)
            print(f"Saved Chap1 (CUDA Apples) sweep to {out_dir}")

        # Chap 1 (SYCL Apples)
        if (HERE / "chap1_async_linear" / "sycl_apples").exists():
            sweep = run_sweep("chap1_async_linear", HERE/"chap1_async_linear/sycl_apples", "SYCL_Apples", sizes, a.warmup, a.iters, prec, ftz)
            sweep.save(out_dir)
            print(f"Saved Chap1 (SYCL Apples) sweep to {out_dir}")

        # Chap 1.5 (Crisp)
        if (HERE / "chap1.5_async_block" / "matmul_async_block.ptx").exists():
            sweep = run_sweep("chap1.5_async_block", HERE/"crisp/matmul_crisp", "Crisp", sizes, a.warmup, a.iters, prec, ftz, {"CRISP_MATMUL_PTX": str(HERE / "chap1.5_async_block" / "matmul_async_block.ptx")})
            sweep.save(out_dir)
            print(f"Saved Chap1.5 (Crisp) sweep to {out_dir}")

        # Chap 1.5 (CUDA Apples)
        if (HERE / "chap1.5_async_block" / "cuda_apples").exists():
            sweep = run_sweep("chap1.5_async_block", HERE/"chap1.5_async_block/cuda_apples", "CUDA_Apples", sizes, a.warmup, a.iters, prec, ftz)
            sweep.save(out_dir)
            print(f"Saved Chap1.5 (CUDA Apples) sweep to {out_dir}")

        # Chap 2 (Crisp)
        if (HERE / "chap2_pipelined_block" / "matmul_pipe.ptx").exists():
            sweep = run_sweep("chap2_pipelined_block", HERE/"crisp/matmul_crisp", "Crisp", sizes, a.warmup, a.iters, prec, ftz, {"CRISP_MATMUL_PTX": str(HERE / "chap2_pipelined_block" / "matmul_pipe.ptx")})
            sweep.save(out_dir)
            print(f"Saved Chap2 (Crisp) sweep to {out_dir}")

        # Chap 2 (CUDA Apples)
        if (HERE / "chap2_pipelined_block" / "cuda_apples").exists():
            sweep = run_sweep("chap2_pipelined_block", HERE/"chap2_pipelined_block/cuda_apples", "CUDA_Apples", sizes, a.warmup, a.iters, prec, ftz)
            sweep.save(out_dir)
            print(f"Saved Chap2 (CUDA Apples) sweep to {out_dir}")

if __name__ == "__main__":
    main()
