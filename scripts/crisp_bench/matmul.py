#!/usr/bin/env python3
import argparse
import subprocess
import os
import sys
import json
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

def build_harness():
    # Crisp harness
    sh(["nvcc", "-O3", "-arch=sm_90", str(HERE/"crisp/bench_harness.cu"), "-lcuda", "-o", str(HERE/"crisp/matmul_crisp")], check=True)
    
    # CUDA Apples-to-Apples (Chap 0 Baseline)
    if (HERE / "chap0_sync" / "cuda_apples.cu").exists():
        sh(["nvcc", "-O3", "-arch=sm_90", str(HERE/"chap0_sync/cuda_apples.cu"), "-o", str(HERE/"chap0_sync/cuda_apples")], check=True)

    # CUBLAS Optimal (Vendor Ceiling)
    if (HERE / "chap0_sync" / "cublas_optimal.cu").exists():
        sh(["nvcc", "-O3", "-arch=sm_90", str(HERE/"chap0_sync/cublas_optimal.cu"), "-lcublas", "-o", str(HERE/"chap0_sync/cublas_optimal")], check=True)

def run_sweep(chapter: str, exe_path: str, competitor_name: str, sizes: list, warmup: int, iters: int, env_extra: dict = None) -> BenchmarkSweep:
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
                compile_time=CompileTimeMetrics(device_compile_ms=0.0, all_compile_ms=0.0), 
                runtime=RuntimeMetrics(wall_time_ms=0.0, kernel_execution_ms=out.get("kernel_median_us", 0.0)/1000.0),
                throughput=ThroughputMetrics(tflops=out.get("gflops", 0.0)/1000.0)
            )
        )
        results.append(point)

    return BenchmarkSweep(
        run_metadata=meta,
        benchmark_suite="matmul",
        chapter=chapter,
        competitor=competitor_name,
        precision="fast",
        denormal_handling="ftz",
        results=results
    )

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sizes", default="256,512,1024,2048,4096")
    ap.add_argument("--warmup", type=int, default=20)
    ap.add_argument("--iters", type=int, default=100)
    ap.add_argument("--output-dir", default=str(HERE.parent / "results"))
    a = ap.parse_args()

    sizes = a.sizes.split(",")
    build_harness()

    out_dir = Path(a.output_dir)

    # Chap 0 (Crisp)
    if (HERE / "chap0_sync" / "matmul.ptx").exists():
        sweep = run_sweep("chap0_sync", HERE/"crisp/matmul_crisp", "Crisp", sizes, a.warmup, a.iters, {"CRISP_MATMUL_PTX": str(HERE / "chap0_sync" / "matmul.ptx")})
        sweep.save(out_dir)
        print(f"Saved Chap0 (Crisp) sweep to {out_dir}")

    # Chap 0 (CUDA Apples)
    if (HERE / "chap0_sync" / "cuda_apples").exists():
        sweep = run_sweep("chap0_sync", HERE/"chap0_sync/cuda_apples", "CUDA_Apples", sizes, a.warmup, a.iters)
        sweep.save(out_dir)
        print(f"Saved Chap0 (CUDA Apples) sweep to {out_dir}")

    # CUBLAS Optimal
    if (HERE / "chap0_sync" / "cublas_optimal").exists():
        sweep = run_sweep("chap0_sync", HERE/"chap0_sync/cublas_optimal", "CUBLAS_Optimal", sizes, a.warmup, a.iters)
        sweep.save(out_dir)
        print(f"Saved CUBLAS Optimal sweep to {out_dir}")

    # Chap 1 (Crisp)
    if (HERE / "chap1_async_linear" / "matmul_async.ptx").exists():
        sweep = run_sweep("chap1_async_linear", HERE/"crisp/matmul_crisp", "Crisp", sizes, a.warmup, a.iters, {"CRISP_MATMUL_PTX": str(HERE / "chap1_async_linear" / "matmul_async.ptx")})
        sweep.save(out_dir)
        print(f"Saved Chap1 (Crisp) sweep to {out_dir}")

if __name__ == "__main__":
    main()
