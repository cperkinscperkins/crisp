#!/usr/bin/env python3
"""
Crisp -> GPU MODE Submission Packager & Runner for grayscale_v2

Compiles Crisp grayscale kernels (`grayscale_*.crisp`) to PTX using `crisp-compile --hoist=cuda`,
wraps them into self-contained GPU MODE Python submissions, and submits to `popcorn-cli`.
"""

from pathlib import Path
import re
import subprocess
import sys
import json

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT / "contests"))
from ptx_packager import ptx_entry_to_inline_asm

POPCORN_CLI = REPO_ROOT / "contests" / "gpu-mode" / "bin" / "popcorn-cli.exe"
CRISP_COMPILE = REPO_ROOT / "bin" / "crisp-compile.exe"
RESULTS_JSON = REPO_ROOT / "contests" / "gpu-mode" / "results" / "grayscale_v2.json"


def compile_crisp_with_cuda_hoist(
    crisp_path: Path,
    kernel_name: str = "grayscale_kernel",
    arch: str = "sm_80",
    hardware_profile: str | None = None,
) -> tuple[Path, str]:
    build_dir = crisp_path.parent / "_build"
    build_dir.mkdir(exist_ok=True)
    build_src = build_dir / crisp_path.name
    build_src.write_text(crisp_path.read_text(encoding="utf-8"), encoding="utf-8")
    cmd = [str(CRISP_COMPILE), "--ir-target=ptx", f"--ir-target-arch={arch}", "--hoist=cuda"]
    if hardware_profile:
        cmd.append(f"--hardware-profile={hardware_profile}")
    cmd.append(str(build_src))
    subprocess.run(cmd, cwd=str(REPO_ROOT), check=True, capture_output=True)
    hoist_cu = build_dir / f"{crisp_path.stem}_{kernel_name}_CUDA.cu"
    return build_src.with_suffix(".ptx"), hoist_cu.read_text(encoding="utf-8")


def param_map_from_cuda_hoist(
    hoist_cu: str, runtime_exprs: dict[str, str]
) -> tuple[dict[int, tuple[str, str]], int]:
    m = re.search(r"void\*\s+kernelParams\[\d+\]\s*=\s*\{(.*?)\};", hoist_cu, flags=re.DOTALL)
    if not m:
        raise ValueError("no kernelParams array in the CUDA hoist")
    names = re.findall(r"&(\w+)", m.group(1))
    param_map: dict[int, tuple[str, str]] = {}
    for idx, name in enumerate(names):
        if name in runtime_exprs:
            param_map[idx] = ("l", runtime_exprs[name])
            continue
        lit = re.search(rf"uint64_t\s+{re.escape(name)}\s*=\s*(\d+)(?:ULL)?\s*;", hoist_cu)
        if not lit:
            raise ValueError(f"kernel param {idx} '{name}' is neither a runtime value nor a literal")
        param_map[idx] = ("l", f"{lit.group(1)}ULL")
    m_smem = re.search(
        r"cuLaunchKernel\(kernel,\s*gridX,\s*gridY,\s*gridZ,\s*\d+,\s*\d+,\s*\d+,\s*(\d+),",
        hoist_cu,
    )
    if not m_smem:
        raise ValueError("no cuLaunchKernel shared-memory argument in the CUDA hoist")
    return param_map, int(m_smem.group(1))


def make_gpumode_grayscale(
    crisp_path: Path,
    out_py_path: Path,
    kernel_name: str = "grayscale_kernel",
    arch: str = "sm_80",
    hardware_profile: str | None = None,
    grid_policy: str = "direct",
    grid_multiplier: int = 4,
    pixels_per_thread: int = 4,
) -> None:
    """
    Package a Crisp grayscale kernel (`(input &out output)`) into a GPU MODE submission file.
    """
    ptx_path, hoist_cu = compile_crisp_with_cuda_hoist(
        crisp_path, kernel_name, arch=arch, hardware_profile=hardware_profile
    )
    crisp_src = crisp_path.read_text(encoding="utf-8").strip()
    raw_ptx = ptx_path.read_text(encoding="utf-8")

    runtime_exprs = {
        "input_ptr": "in_ptr",
        "input_byte_size": "in_bytes",
        "input_ext0": "in_len",
        "input_length": "in_len",
        "output_ptr": "out_ptr",
        "output_byte_size": "out_bytes",
        "output_ext0": "out_len",
        "output_length": "out_len",
    }
    param_map, smem_bytes = param_map_from_cuda_hoist(hoist_cu, runtime_exprs)
    inline_asm_code, launch_bounds = ptx_entry_to_inline_asm(raw_ptx, kernel_name, param_map)

    smem_decl = (
        "    extern __shared__ __align__(128) unsigned char crisp_smem[];\n"
        "    uint64_t smem_ptr = static_cast<uint64_t>(__cvta_generic_to_shared(crisp_smem));\n"
        if smem_bytes > 0
        else ""
    )
    smem_launch = f", {smem_bytes}" if smem_bytes > 0 else ""
    m_bs = re.search(r"__launch_bounds__\((\d+)", launch_bounds)
    block_size = int(m_bs.group(1)) if m_bs else 256

    commented_crisp = "\n".join(f"#   {line}" if line else "#" for line in crisp_src.splitlines())
    commented_crisp = re.sub(r":stream(?=ing\b)", ":str-eam", commented_crisp, flags=re.IGNORECASE)
    commented_crisp = re.sub(r"stream", "str_eam", commented_crisp, flags=re.IGNORECASE)

    extra_locals = []
    if "(in_len)" in inline_asm_code or "(in_bytes)" in inline_asm_code:
        extra_locals.append("    uint64_t in_len = out_len * 3ULL;")
    if "(in_bytes)" in inline_asm_code:
        extra_locals.append("    uint64_t in_bytes = in_len * 4ULL;")
    if "(out_bytes)" in inline_asm_code:
        extra_locals.append("    uint64_t out_bytes = out_len * 4ULL;")
    extra_locals_str = ("\n".join(extra_locals) + "\n") if extra_locals else ""

    if grid_policy == "direct":
        grid_block = f"""    int64_t needed_blocks = (N + (BLOCK_SIZE * {pixels_per_thread}) - 1) / (BLOCK_SIZE * {pixels_per_thread});
    if (needed_blocks < 1) needed_blocks = 1;
    int grid_x = static_cast<int>(needed_blocks);"""
    elif grid_policy == "occupancy":
        grid_block = f"""    static int max_grid = 0;
    if (max_grid <= 0) {{
        int num_sms = 0;
        cudaDeviceGetAttribute(&num_sms, cudaDevAttrMultiProcessorCount, 0);
        int blocks_per_sm = 0;
        cudaOccupancyMaxActiveBlocksPerMultiprocessor(&blocks_per_sm, crisp_grayscale_kernel, BLOCK_SIZE, {smem_bytes});
        max_grid = (blocks_per_sm > 0 && num_sms > 0) ? (blocks_per_sm * num_sms * {grid_multiplier}) : 1024;
    }}
    int64_t needed_blocks = (N + (BLOCK_SIZE * {pixels_per_thread}) - 1) / (BLOCK_SIZE * {pixels_per_thread});
    if (needed_blocks < 1) needed_blocks = 1;
    int grid_x = static_cast<int>(std::min<int64_t>(needed_blocks, max_grid));"""
    else:
        raise ValueError(f"unknown grid_policy {grid_policy!r}")

    cuda_source = f"""
#include <cuda_runtime.h>
#include <torch/extension.h>
#include <cstdint>
#include <algorithm>

__global__ {launch_bounds}
void crisp_grayscale_kernel(
    uint64_t in_ptr,
    uint64_t out_ptr,
    uint64_t out_len
) {{
{extra_locals_str}{smem_decl}{inline_asm_code}
}}

torch::Tensor launch_crisp_grayscale(torch::Tensor input, torch::Tensor output) {{
    int64_t N = output.numel();
    if (N <= 0) return output;

    constexpr int BLOCK_SIZE = {block_size};
{grid_block}

    crisp_grayscale_kernel<<<grid_x, BLOCK_SIZE{smem_launch}>>>(
        reinterpret_cast<uint64_t>(input.data_ptr()),
        reinterpret_cast<uint64_t>(output.data_ptr()),
        static_cast<uint64_t>(N)
    );
    return output;
}}
"""
    cpp_source = "torch::Tensor launch_crisp_grayscale(torch::Tensor input, torch::Tensor output);"
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
    name="crisp_grayscale_ext",
    cpp_sources=[CPP_SOURCE],
    cuda_sources=[CUDA_SOURCE],
    functions=["launch_crisp_grayscale"],
    extra_cuda_cflags=["-O3"],
    verbose=False,
)


def custom_kernel(data: input_t) -> output_t:
    inp, out = data
    return _crisp_mod.launch_crisp_grayscale(inp, out)
'''
    if "stream" in submission_py.lower():
        raise ValueError(f"Generated {out_py_path.name} contains forbidden substring 'stream'!")
    out_py_path.write_text(submission_py, encoding="utf-8")
    print(
        f"Wrote {out_py_path} ({len(submission_py.splitlines())} lines) with {launch_bounds}, "
        f"grid={grid_policy}, ppt={pixels_per_thread}, smem={smem_bytes}B"
    )


def run_popcorn(py_path: Path, gpu: str, leaderboard: str = "grayscale_v2", mode: str = "benchmark") -> str:
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
    out = proc.stdout + ("\n" + proc.stderr if proc.stderr else "")
    print(out, flush=True)
    return out


def parse_and_record_run(out: str, gpu: str, kernel_key: str, file_name: str, mode: str) -> None:
    if not RESULTS_JSON.exists():
        return
    data = json.loads(RESULTS_JSON.read_text(encoding="utf-8"))

    m_id = re.search(r"submission_id=(\d+)|Submission (\d+)", out)
    sub_id = int(m_id.group(1) or m_id.group(2)) if m_id else None

    # Notice: grayscale_v2 has 6 benchmark sizes (512..16384); capture the largest (last) benchmark mean/best/worst
    means = re.findall(r"([0-9.]+)\s*±\s*([0-9.]+)\s*(ms|µs|us)", out)
    bests = re.findall(r"⚡\s*([0-9.]+)\s*(ms|µs|us)\s*🐌\s*([0-9.]+)\s*(ms|µs|us)", out)

    def to_us(val_str: str, unit: str) -> float:
        v = float(val_str)
        return round(v * 1000.0, 2) if unit == "ms" else round(v, 2)

    bench_mean = to_us(means[-1][0], means[-1][2]) if means else None
    bench_std = to_us(means[-1][1], means[-1][2]) if means else None
    bench_best = to_us(bests[-1][0], bests[-1][1]) if bests else None
    bench_worst = to_us(bests[-1][2], bests[-1][3]) if bests else None

    m_pub = re.search(r"(?:public leaderboard score|Geomean score \(public\)[^:]*):\s*([0-9.eE+-]+)", out)
    m_sec = re.search(r"(?:secret leaderboard score|Geomean score \(secret\)[^:]*):\s*([0-9.eE+-]+)", out)
    pub_score = float(m_pub.group(1)) * 1e6 if m_pub else None
    sec_score = float(m_sec.group(1)) * 1e6 if m_sec else None

    if sub_id is None and bench_mean is None and pub_score is None:
        print("Skipping run record (no submission_id or score parsed, e.g. rate limit).")
        return

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
    RESULTS_JSON.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Recorded run {sub_id} in {RESULTS_JSON.name}")


if __name__ == "__main__":
    base = Path(__file__).resolve().parent

    # 0. Beauty Entry: Idiomatic scalar stride + op-fma + &out
    make_gpumode_grayscale(
        base / "grayscale_beauty.crisp",
        base / "crisp_grayscale_beauty.py",
        grid_policy="occupancy",
        grid_multiplier=4,
        pixels_per_thread=4,
    )

    # 1. Direct 1x float4 (4 pixels/thread): &out (.nc) + st.global.cs.v4.f32
    make_gpumode_grayscale(
        base / "grayscale_direct_vec4.crisp",
        base / "crisp_grayscale_direct_vec4.py",
        grid_policy="direct",
        pixels_per_thread=4,
    )

    # 1b. Direct 1x float4 (4 pixels/thread): pure native &out (.nc) + native st.global.v4.b32
    make_gpumode_grayscale(
        base / "grayscale_direct_vec4_nc.crisp",
        base / "crisp_grayscale_direct_vec4_nc.py",
        grid_policy="direct",
        pixels_per_thread=4,
    )

    # 2. Direct 1x float4 + Endeavour 192 :cache (:streaming :prefetch 256) on input + :streaming on output
    make_gpumode_grayscale(
        base / "grayscale_direct_vec4_cs256.crisp",
        base / "crisp_grayscale_direct_vec4_cs256.py",
        grid_policy="direct",
        pixels_per_thread=4,
    )

    # 3. Direct 2x float4 (8 pixels/thread): &out (.nc) + st.global.cs.v4.f32
    make_gpumode_grayscale(
        base / "grayscale_direct_2xvec4.crisp",
        base / "crisp_grayscale_direct_2xvec4.py",
        grid_policy="direct",
        pixels_per_thread=8,
    )

    # 4. Direct 2x float4 (8 pixels/thread): pure native .nc + native st.global.v4 (all offsets folded)
    make_gpumode_grayscale(
        base / "grayscale_direct_2xvec4_nc.crisp",
        base / "crisp_grayscale_direct_2xvec4_nc.py",
        grid_policy="direct",
        pixels_per_thread=8,
    )

    # 5. Persistent Grid-Stride 1x float4 + :cache (:streaming :prefetch 256)
    make_gpumode_grayscale(
        base / "grayscale_stride_vec4_cs256.crisp",
        base / "crisp_grayscale_stride_vec4_cs256.py",
        grid_policy="occupancy",
        grid_multiplier=4,
        pixels_per_thread=16,
    )

    # 6. Stride-1 Coalesced Global float4 Load + Conflict-Free Shared Memory De-Interleave
    make_gpumode_grayscale(
        base / "grayscale_smem_coalesced.crisp",
        base / "crisp_grayscale_smem_coalesced.py",
        grid_policy="direct",
        pixels_per_thread=4,
    )

    if len(sys.argv) > 1 and sys.argv[1] == "--submit":
        gpu = sys.argv[2] if len(sys.argv) > 2 else "H100"
        mode = sys.argv[3] if len(sys.argv) > 3 else "benchmark"
        variant = sys.argv[4] if len(sys.argv) > 4 else "--direct"
        vmap = {
            "--beauty": ("beauty", "crisp_grayscale_beauty.py"),
            "--direct": ("crisp_grayscale_direct_vec4", "crisp_grayscale_direct_vec4.py"),
            "--directnc": ("crisp_grayscale_direct_vec4_nc", "crisp_grayscale_direct_vec4_nc.py"),
            "--cs256": ("crisp_grayscale_direct_vec4_cs256", "crisp_grayscale_direct_vec4_cs256.py"),
            "--2x": ("crisp_grayscale_direct_2xvec4", "crisp_grayscale_direct_2xvec4.py"),
            "--2xnc": ("crisp_grayscale_direct_2xvec4_nc", "crisp_grayscale_direct_2xvec4_nc.py"),
            "--stride": ("crisp_grayscale_stride_vec4_cs256", "crisp_grayscale_stride_vec4_cs256.py"),
            "--smem": ("crisp_grayscale_smem_coalesced", "crisp_grayscale_smem_coalesced.py"),
        }
        kkey, fname = vmap[variant]
        out = run_popcorn(base / fname, gpu=gpu, mode=mode)
        parse_and_record_run(out, gpu=gpu, kernel_key=kkey, file_name=fname, mode=mode)
