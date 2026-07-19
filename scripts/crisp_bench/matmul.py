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
    # We assume PTX files are already compiled for this first pass since crisp-compile
    # is Windows only and we are executing on the RunPod linux environment.
    sh(["nvcc", "-O3", "-arch=sm_90", str(HERE/"crisp/bench_harness.cu"), "-lcuda", "-o", str(HERE/"crisp/matmul_crisp")], check=True)

def run_sweep(chapter: str, ptx_file: str, sizes: list, warmup: int, iters: int) -> BenchmarkSweep:
    meta = create_metadata()
    # If runpod, use the env var or detect it. For now, hardcode H100 since we're on runpod.
    meta.hardware.gpu_model = "NVIDIA H100"
    meta.hardware.arch_target = "sm_90"
    meta.hardware.environment = "runpod"

    results = []
    for s in sizes:
        S = int(s)
        # Execute
        out = run_bin(HERE/"crisp/matmul_crisp", S, S, S, warmup, iters, {"CRISP_MATMUL_PTX": str(HERE / chapter / ptx_file)})
        if not out: continue
        
        # Parse output and put into standard metrics format
        # Current harness prints: kernel_median_us, gflops, etc.
        # We don't have compile times in the C++ output yet, but we'll mock them or set to 0
        point = SweepPoint(
            configuration={"m": S, "n": S, "k": S, "warmup": warmup, "iters": iters},
            metrics=BenchmarkMetrics(
                compile_time=CompileTimeMetrics(device_compile_ms=0.0, all_compile_ms=0.0), # TODO: add to C++ driver
                runtime=RuntimeMetrics(wall_time_ms=0.0, kernel_execution_ms=out["kernel_median_us"]/1000.0),
                throughput=ThroughputMetrics(tflops=out["gflops"]/1000.0)
            )
        )
        results.append(point)

    return BenchmarkSweep(
        run_metadata=meta,
        benchmark_suite="matmul",
        chapter=chapter,
        competitor="Crisp",
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

    # Chap 0
    if (HERE / "chap0_sync" / "matmul.ptx").exists():
        sweep_0 = run_sweep("chap0_sync", "matmul.ptx", sizes, a.warmup, a.iters)
        sweep_0.save(out_dir)
        print(f"Saved Chap0 sweep to {out_dir}")

    # Chap 1
    if (HERE / "chap1_async_linear" / "matmul_async.ptx").exists():
        sweep_1 = run_sweep("chap1_async_linear", "matmul_async.ptx", sizes, a.warmup, a.iters)
        sweep_1.save(out_dir)
        print(f"Saved Chap1 sweep to {out_dir}")

if __name__ == "__main__":
    main()
