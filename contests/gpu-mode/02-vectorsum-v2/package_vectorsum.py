#!/usr/bin/env python3
"""
Compiles Crisp reduction kernels to PTX, emits self-contained GPU MODE Python submissions,
and runs popcorn-cli benchmarks and leaderboard submissions for vectorsum_v2.
"""

import json
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

REPO_ROOT = Path(__file__).resolve().parents[3]
CRISP_COMPILE = REPO_ROOT / "bin" / "crisp-compile.exe"
POPCORN_CLI = Path(__file__).resolve().parents[1] / "bin" / "popcorn-cli.exe"

sys.path.insert(0, str(REPO_ROOT))
from contests.ptx_packager import ptx_entry_to_inline_asm


def compile_crisp_with_profile(
    crisp_path: Path,
    arch: str = "sm_80",
    hardware_profile: str | None = None,
    fast_math: bool = False,
) -> Path:
    cmd = [
        str(CRISP_COMPILE),
        "--ir-target=ptx",
        f"--ir-target-arch={arch}",
    ]
    if hardware_profile:
        cmd.append(f"--hardware-profile={hardware_profile}")
    if fast_math:
        cmd.append("--math-precision=fast")
    cmd.append(str(crisp_path))
    subprocess.run(cmd, cwd=str(REPO_ROOT), check=True)
    return crisp_path.with_suffix(".ptx")


def make_gpumode_vectorsum(
    crisp_path: Path,
    out_py_path: Path,
    kernel_name: str = "vectorsum_kernel",
    arch: str = "sm_80",
    hardware_profile: str | None = None,
    smem_bytes: int = 0,
    elems_per_thread: int = 4,
    grid_multiplier: int = 2,
    f64_acc: bool = True,
) -> None:
    ptx_path = compile_crisp_with_profile(crisp_path, arch=arch, hardware_profile=hardware_profile)
    crisp_src = crisp_path.read_text(encoding="utf-8").strip()
    raw_ptx = ptx_path.read_text(encoding="utf-8")

    param_map = {
        0: ("l", "in_ptr"),
        1: ("l", "bytes"),
        2: ("l", "zero"),
        3: ("l", "one"),
        4: ("l", "len"),
        5: ("l", "len"),
        6: ("l", "out_ptr"),
        7: ("l", "four"),
        8: ("l", "zero"),
    }

    inline_asm_code, launch_bounds = ptx_entry_to_inline_asm(raw_ptx, kernel_name, param_map)
    m_bs = re.search(r"__launch_bounds__\((\d+)", launch_bounds)
    block_size = int(m_bs.group(1)) if m_bs else 256

    commented_crisp = "\n".join(f"#   {line}" if line else "#" for line in crisp_src.splitlines())

    smem_arg = f", {smem_bytes}" if smem_bytes > 0 else ""

    if f64_acc:
        launch_body = f"""
    auto d_out = torch::zeros({{1}}, input.options().dtype(torch::kFloat64));

    constexpr int BLOCK_SIZE = {block_size};
    static int max_grid = 0;
    if (max_grid <= 0) {{
        int num_sms = 0;
        cudaDeviceGetAttribute(&num_sms, cudaDevAttrMultiProcessorCount, 0);
        max_grid = (num_sms > 0) ? (num_sms * {grid_multiplier}) : 256;
    }}

    int64_t needed_blocks = (N + (BLOCK_SIZE * {elems_per_thread}) - 1) / (BLOCK_SIZE * {elems_per_thread});
    if (needed_blocks < 1) needed_blocks = 1;
    int grid_x = static_cast<int>(std::min<int64_t>(needed_blocks, max_grid));

    crisp_vectorsum_kernel<<<grid_x, BLOCK_SIZE{smem_arg}>>>(
        reinterpret_cast<uint64_t>(input.data_ptr()),
        reinterpret_cast<uint64_t>(d_out.data_ptr()),
        static_cast<uint64_t>(N)
    );
    output.copy_(d_out.to(torch::kFloat32));
    return output.dim() > 0 ? output.squeeze(0) : output;
"""
    else:
        launch_body = f"""
    output.zero_();

    constexpr int BLOCK_SIZE = {block_size};
    static int max_grid = 0;
    if (max_grid <= 0) {{
        int num_sms = 0;
        cudaDeviceGetAttribute(&num_sms, cudaDevAttrMultiProcessorCount, 0);
        max_grid = (num_sms > 0) ? (num_sms * {grid_multiplier}) : 256;
    }}

    int64_t needed_blocks = (N + (BLOCK_SIZE * {elems_per_thread}) - 1) / (BLOCK_SIZE * {elems_per_thread});
    if (needed_blocks < 1) needed_blocks = 1;
    int grid_x = static_cast<int>(std::min<int64_t>(needed_blocks, max_grid));

    crisp_vectorsum_kernel<<<grid_x, BLOCK_SIZE{smem_arg}>>>(
        reinterpret_cast<uint64_t>(input.data_ptr()),
        reinterpret_cast<uint64_t>(output.data_ptr()),
        static_cast<uint64_t>(N)
    );
    return output.dim() > 0 ? output.squeeze(0) : output;
"""

    cuda_source = f"""
#include <cuda_runtime.h>
#include <torch/extension.h>
#include <cstdint>
#include <algorithm>

__global__ {launch_bounds}
void crisp_vectorsum_kernel(
    uint64_t in_ptr,
    uint64_t out_ptr,
    uint64_t len
) {{
    uint64_t bytes = len * 4ULL;
    uint64_t zero = 0ULL;
{inline_asm_code}
}}

torch::Tensor launch_crisp_vectorsum(torch::Tensor input, torch::Tensor output) {{
    int64_t N = input.numel();
    if (N <= 0) return output.dim() > 0 ? output.squeeze(0) : output;
    if (!input.is_contiguous()) {{
        input = input.contiguous();
    }}
{launch_body}
}}
"""
    cpp_source = "torch::Tensor launch_crisp_vectorsum(torch::Tensor input, torch::Tensor output);"

    submission_py = f'''# Generated from Crisp (https://github.com/cperkinscperkins/crisp)
#
# Crisp Source ({crisp_path.name}):
# -------------------------------------------------------------------------
{commented_crisp}
# -------------------------------------------------------------------------

import torch
from torch.utils.cpp_extension import load_inline
from task import input_t, output_t

CUDA_SOURCE = r"""{cuda_source}"""
CPP_SOURCE = r"""{cpp_source}"""

_crisp_mod = load_inline(
    name="crisp_vectorsum_ext",
    cpp_sources=[CPP_SOURCE],
    cuda_sources=[CUDA_SOURCE],
    functions=["launch_crisp_vectorsum"],
    extra_cuda_cflags=["-O3", "--use_fast_math"],
    verbose=False,
)


def custom_kernel(data: input_t) -> output_t:
    inp, out = data
    return _crisp_mod.launch_crisp_vectorsum(inp, out)
'''

    if "stream" in submission_py.lower():
        raise ValueError(f"Generated {out_py_path.name} contains forbidden substring 'stream'!")

    out_py_path.write_text(submission_py, encoding="utf-8")
    print(f"Wrote {out_py_path} ({len(submission_py.splitlines())} lines) with {launch_bounds}")


def run_popcorn(py_path: Path, gpu: str, leaderboard: str = "vectorsum_v2", mode: str = "benchmark") -> str:
    cmd = [
        str(POPCORN_CLI),
        "submit",
        str(py_path),
        "--gpu",
        gpu,
        "--leaderboard",
        leaderboard,
        "--mode",
        mode,
        "--no-tui",
    ]
    print(f"\n=== Running: {' '.join(cmd)} ===", flush=True)
    proc = subprocess.run(cmd, cwd=str(REPO_ROOT), text=True, capture_output=True, encoding="utf-8", errors="replace")
    print(proc.stdout, flush=True)
    if proc.stderr:
        print(proc.stderr, flush=True)
    return proc.stdout


def parse_and_record_run(
    stdout: str,
    gpu: str,
    kernel_key: str,
    file_name: str,
    mode: str,
) -> None:
    results_file = Path(__file__).resolve().parents[1] / "results" / "vectorsum_v2.json"
    if not results_file.exists():
        return
    data = json.loads(results_file.read_text(encoding="utf-8"))

    # Extract submission id
    m_sub = re.search(r'"submission_id":\s*(\d+)', stdout)
    sub_id = int(m_sub.group(1)) if m_sub else None

    # Extract benchmark mean and std
    m_bench = re.search(r"⏱\s*([\d.]+)\s*±\s*([\d.]+)\s*µs", stdout)
    bench_mean = float(m_bench.group(1)) if m_bench else None
    bench_std = float(m_bench.group(2)) if m_bench else None

    m_bw = re.search(r"⚡\s*([\d.]+)\s*µs\s*🐌\s*([\d.]+)\s*µs", stdout)
    bench_best = float(m_bw.group(1)) if m_bw else None
    bench_worst = float(m_bw.group(2)) if m_bw else None

    # Extract leaderboard scores
    m_pub = re.search(r"Geomean score \(public\)[^:]*:\s*([\d.e-]+)\s*s", stdout)
    pub_score = float(m_pub.group(1)) * 1e6 if m_pub else None

    m_sec = re.search(r"Geomean score \(secret\)[^:]*:\s*([\d.e-]+)\s*s", stdout)
    sec_score = float(m_sec.group(1)) * 1e6 if m_sec else None

    now_iso = subprocess.run(
        ["python", "-c", "import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))"],
        text=True,
        capture_output=True,
    ).stdout.strip()

    run_record = {
        "timestamp": now_iso,
        "gpu": gpu,
        "kernel_key": kernel_key,
        "file_name": file_name,
        "mode": mode,
        "submission_id": sub_id,
        "benchmark_mean_us": bench_mean,
        "benchmark_std_us": bench_std,
        "benchmark_best_us": bench_best,
        "benchmark_worst_us": bench_worst,
        "public_score_us": round(pub_score, 2) if pub_score else None,
        "secret_score_us": round(sec_score, 2) if sec_score else None,
    }
    data.setdefault("runs", []).append(run_record)
    results_file.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Recorded run {sub_id} in {results_file.name}")


if __name__ == "__main__":
    base = Path(__file__).resolve().parent

    # 1. Universal float4 FP64-accumulating warp reduce kernel (H100, A100, L4)
    make_gpumode_vectorsum(
        base / "vectorsum_warp_reduce.crisp",
        base / "crisp_vectorsum_warp_reduce.py",
        kernel_name="vectorsum_kernel",
        arch="sm_80",
        elems_per_thread=4,
        grid_multiplier=2,
        f64_acc=True,
    )

    # 2. B200 2x float4 FP64-accumulating tuned kernel
    make_gpumode_vectorsum(
        base / "vectorsum_b200_2xfloat4.crisp",
        base / "crisp_vectorsum_b200_2xfloat4.py",
        kernel_name="vectorsum_b200_kernel",
        arch="sm_80",
        hardware_profile="b200",
        elems_per_thread=8,
        grid_multiplier=2,
        f64_acc=True,
    )

    gpu = "B200" if "--b200" in sys.argv else ("A100" if "--a100" in sys.argv else ("L4" if "--l4" in sys.argv else "H100"))
    target_py = base / ("crisp_vectorsum_b200_2xfloat4.py" if gpu == "B200" else "crisp_vectorsum_warp_reduce.py")
    kernel_key = "crisp_vectorsum_b200_2xfloat4" if gpu == "B200" else "crisp_vectorsum_warp_reduce"

    if "--test" in sys.argv:
        out = run_popcorn(target_py, gpu, "vectorsum_v2", "test")
        parse_and_record_run(out, gpu, kernel_key, target_py.name, "test")

    if "--bench" in sys.argv:
        out = run_popcorn(target_py, gpu, "vectorsum_v2", "benchmark")
        parse_and_record_run(out, gpu, kernel_key, target_py.name, "benchmark")

    if "--leaderboard" in sys.argv:
        out = run_popcorn(target_py, gpu, "vectorsum_v2", "leaderboard")
        parse_and_record_run(out, gpu, kernel_key, target_py.name, "leaderboard")
        # Refresh reports
        subprocess.run(["python", "contests/gpu-mode/report.py", "--refresh", "--all"], cwd=str(REPO_ROOT))
