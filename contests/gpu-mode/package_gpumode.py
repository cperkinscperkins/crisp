#!/usr/bin/env python3
"""
Compiles Crisp kernels to PTX, emits self-contained GPU MODE Python submissions (crisp_*.py),
and optionally runs popcorn-cli benchmarks + leaderboard submissions in a single command.
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

REPO_ROOT = Path(__file__).resolve().parents[2]
CRISP_COMPILE = REPO_ROOT / "bin" / "crisp-compile.exe"
POPCORN_CLI = Path(__file__).resolve().parent / "bin" / "popcorn-cli.exe"
def ptx_entry_to_inline_asm(
    ptx_text: str, entry_name: str, param_c_exprs: dict[int, tuple[str, str]]
) -> tuple[str, str]:
    """
    Extracts `.visible .entry <entry_name>(...) { BODY }` from PTX and converts it into
    a CUDA C++ `asm volatile(...)` statement.
    param_c_exprs maps parameter index (0..N-1) -> (constraint, c_expr), e.g. {0: ("l", "a_ptr")}.
    """
    m = re.search(
        rf"\.visible \.entry\s+{re.escape(entry_name)}\s*\((.*?)\)\s*(?://[^\n]*)?\n\{{(.*?)\n\}}",
        ptx_text,
        flags=re.DOTALL,
    )
    if not m:
        raise ValueError(f"Could not find .visible .entry {entry_name} in PTX")

    body = m.group(2)

    # Find which param indices are actually loaded via ld.param.<type> %reg, [<entry_name>_param_<idx>];
    used_indices = sorted(
        {
            int(idx_str)
            for idx_str in re.findall(rf"\b{re.escape(entry_name)}_param_(\d+)\b", body)
        }
    )
    idx_to_asm_slot = {param_idx: slot for slot, param_idx in enumerate(used_indices)}

    special_regs = {
        "ctaid", "ntid", "tid", "nctaid", "laneid", "warpid", "smid", "gridid",
        "clock", "clock64", "pm0", "pm1", "pm2", "pm3",
    }

    def prefix_ptx_registers(text: str, prefix: str = "cr_") -> str:
        def repl(match: re.Match) -> str:
            name = match.group(1)
            base = name.split(".")[0]
            if base in special_regs or base.startswith("envreg"):
                return match.group(0)
            return f"%{prefix}{name}"

        return re.sub(r"%(?!\d)([\w.]+)", repl, text)

    prefixed_body = prefix_ptx_registers(body)
    escaped_body = prefixed_body.replace("%", "%%")

    # Replace ld.param.<type> %%cr_reg, [<entry_name>_param_<idx>]; with mov.<type> %%cr_reg, %<slot>;
    def replace_ld_param(match: re.Match) -> str:
        ld_type = match.group(1)  # e.g., b64, u64, b32, f32
        reg = match.group(2)
        param_idx = int(match.group(3))
        slot = idx_to_asm_slot[param_idx]
        mov_type = "b64" if "64" in ld_type else ("f32" if "f32" in ld_type else "b32")
        return f"mov.{mov_type} \t{reg}, %{slot};"

    escaped_body = re.sub(
        rf"ld\.param\.(\w+)\s+(%%cr_\w+),\s*\[{re.escape(entry_name)}_param_(\d+)\];",
        replace_ld_param,
        escaped_body,
    )

    # Replace `ret;` inside the entry body with a jump to the end of the inline asm block
    escaped_body = re.sub(r"\bret;", "bra.uni $L__crisp_inline_exit;", escaped_body)

    asm_lines = ["    asm volatile(\n        \"{\\n\""]
    for line in escaped_body.splitlines():
        stripped = line.rstrip()
        if not stripped:
            continue
        safe_line = stripped.replace("\\", "\\\\").replace('"', '\\"')
        asm_lines.append(f'        "{safe_line}\\n"')
    asm_lines.append('        "$L__crisp_inline_exit:\\n"')
    asm_lines.append('        "}\\n"')

    operand_strs = []
    for param_idx in used_indices:
        constraint, c_expr = param_c_exprs[param_idx]
        operand_strs.append(f'"{constraint}"({c_expr})')

    asm_lines.append("        : : " + ", ".join(operand_strs))
    asm_lines.append('        : "memory"\n    );')

    m_bounds = re.search(r"\.(?:reqntid|maxntid)\s+(\d+)", ptx_text)
    bsize = m_bounds.group(1) if m_bounds else "256"
    launch_bounds = f"__launch_bounds__({bsize})"

    return "\n".join(asm_lines), launch_bounds


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


def make_gpumode_vectoradd_v2(
    crisp_path: Path,
    out_py_path: Path,
    elem_bytes: int = 2,
    elems_per_iter: int = 16,
    waves_per_sm: int = 1,
    direct_grid_expr: str | None = None,
    inplace: bool = False,
    arch: str = "sm_80",
    hardware_profile: str | None = None,
) -> None:
    ptx_path = compile_crisp_with_profile(crisp_path, arch=arch, hardware_profile=hardware_profile)
    crisp_src = crisp_path.read_text(encoding="utf-8").strip()
    raw_ptx = ptx_path.read_text(encoding="utf-8")

    if inplace:
        # (def-kernel vector_add_f16 (B A) ...)
        # Param 0..5 = B, Param 6..11 = A
        param_map = {
            0: ("l", "b_ptr"), 1: ("l", "bytes"), 2: ("l", "zero"), 3: ("l", "one"), 4: ("l", "len"), 5: ("l", "len"),
            6: ("l", "a_ptr"), 7: ("l", "bytes"), 8: ("l", "zero"), 9: ("l", "one"), 10: ("l", "len"), 11: ("l", "len"),
        }
    else:
        param_map = {
            0: ("l", "a_ptr"), 1: ("l", "bytes"), 2: ("l", "zero"), 3: ("l", "one"), 4: ("l", "len"), 5: ("l", "len"),
            6: ("l", "b_ptr"), 7: ("l", "bytes"), 8: ("l", "zero"), 9: ("l", "one"), 10: ("l", "len"), 11: ("l", "len"),
            12: ("l", "c_ptr"), 13: ("l", "bytes"), 14: ("l", "zero"), 15: ("l", "one"), 16: ("l", "len"), 17: ("l", "len"),
        }

    inline_asm_code, launch_bounds = ptx_entry_to_inline_asm(raw_ptx, "vector_add_f16", param_map)
    m_bs = re.search(r"__launch_bounds__\((\d+)", launch_bounds)
    block_size = int(m_bs.group(1)) if m_bs else 256

    commented_crisp = "\n".join(f"#   {line}" if line else "#" for line in crisp_src.splitlines())

    extra_locals = []
    if "(bytes)" in inline_asm_code:
        extra_locals.append(f"    uint64_t bytes = len * {elem_bytes}ULL;")
    if "(zero)" in inline_asm_code:
        extra_locals.append("    uint64_t zero = 0ULL;")
    if "(one)" in inline_asm_code:
        extra_locals.append("    uint64_t one = 1ULL;")
    extra_locals_str = ("\n".join(extra_locals) + "\n") if extra_locals else ""

    if direct_grid_expr is not None:
        grid_setup = f"""    constexpr int BLOCK_SIZE = {block_size};
    int64_t needed_blocks = {direct_grid_expr};
    if (needed_blocks < 1) needed_blocks = 1;
    int grid_x = static_cast<int>(needed_blocks);"""
    else:
        grid_setup = f"""    constexpr int BLOCK_SIZE = {block_size};
    static int max_grid = 0;
    if (max_grid <= 0) {{
        int blocks_per_sm = 0;
        cudaOccupancyMaxActiveBlocksPerMultiprocessor(
            &blocks_per_sm, crisp_vector_add_f16_kernel, BLOCK_SIZE, 0);
        int num_sms = 0;
        cudaDeviceGetAttribute(&num_sms, cudaDevAttrMultiProcessorCount, 0);
        max_grid = (blocks_per_sm > 0 && num_sms > 0) ? (blocks_per_sm * num_sms * {waves_per_sm}) : 1024;
    }}

    int64_t needed_blocks = (N + (BLOCK_SIZE * {elems_per_iter}) - 1) / (BLOCK_SIZE * {elems_per_iter});
    if (needed_blocks < 1) needed_blocks = 1;
    int grid_x = static_cast<int>(std::min<int64_t>(needed_blocks, max_grid));"""

    if inplace:
        cuda_source = f"""
#include <cuda_runtime.h>
#include <torch/extension.h>
#include <cstdint>
#include <algorithm>

__global__ {launch_bounds}
void crisp_vector_add_f16_kernel(
    uint64_t a_ptr,
    uint64_t b_ptr,
    uint64_t len
) {{
{extra_locals_str}{inline_asm_code}
}}

torch::Tensor launch_crisp_vector_add_f16(torch::Tensor A, torch::Tensor B) {{
    int64_t N = A.numel();
    if (N <= 0) return A;

{grid_setup}

    crisp_vector_add_f16_kernel<<<grid_x, BLOCK_SIZE>>>(
        reinterpret_cast<uint64_t>(A.data_ptr()),
        reinterpret_cast<uint64_t>(B.data_ptr()),
        static_cast<uint64_t>(N)
    );
    return A;
}}
"""
        cpp_source = "torch::Tensor launch_crisp_vector_add_f16(torch::Tensor A, torch::Tensor B);"
        custom_kernel_body = """def custom_kernel(data: input_t) -> output_t:
    A, B, _ = data
    return _crisp_mod.launch_crisp_vector_add_f16(A, B)
"""
    else:
        cuda_source = f"""
#include <cuda_runtime.h>
#include <torch/extension.h>
#include <cstdint>
#include <algorithm>

__global__ {launch_bounds}
void crisp_vector_add_f16_kernel(
    uint64_t a_ptr,
    uint64_t b_ptr,
    uint64_t c_ptr,
    uint64_t len
) {{
{extra_locals_str}{inline_asm_code}
}}

torch::Tensor launch_crisp_vector_add_f16(torch::Tensor A, torch::Tensor B, torch::Tensor C) {{
    int64_t N = A.numel();
    if (N <= 0) return C;

{grid_setup}

    crisp_vector_add_f16_kernel<<<grid_x, BLOCK_SIZE>>>(
        reinterpret_cast<uint64_t>(A.data_ptr()),
        reinterpret_cast<uint64_t>(B.data_ptr()),
        reinterpret_cast<uint64_t>(C.data_ptr()),
        static_cast<uint64_t>(N)
    );
    return C;
}}
"""
        cpp_source = "torch::Tensor launch_crisp_vector_add_f16(torch::Tensor A, torch::Tensor B, torch::Tensor C);"
        custom_kernel_body = """def custom_kernel(data: input_t) -> output_t:
    A, B, output = data
    return _crisp_mod.launch_crisp_vector_add_f16(A, B, output)
"""

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
    name="crisp_vectoradd_f16_ext",
    cpp_sources=[CPP_SOURCE],
    cuda_sources=[CUDA_SOURCE],
    functions=["launch_crisp_vector_add_f16"],
    extra_cuda_cflags=["-O3", "--use_fast_math"],
    verbose=False,
)


{custom_kernel_body}'''

    if "stream" in submission_py.lower():
        raise ValueError(f"Generated {out_py_path.name} contains forbidden substring 'stream'!")

    out_py_path.write_text(submission_py, encoding="utf-8")
    print(f"Wrote {out_py_path} ({len(submission_py.splitlines())} lines) with {launch_bounds}")


def run_popcorn(py_path: Path, gpu: str, leaderboard: str, mode: str) -> str:
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


def extract_size_16384_us(popcorn_stdout: str) -> float | None:
    lines = popcorn_stdout.splitlines()
    for i, line in enumerate(lines):
        if "size: 16384" in line and i + 1 < len(lines):
            m = re.search(r"([\d.]+)\s*±", lines[i + 1])
            if m:
                return float(m.group(1))
    return None


def print_leaderboard_standings(leaderboard_id: int = 543, gpu: str = "H100") -> None:
    url = f"https://www.gpumode.com/api/leaderboard/{leaderboard_id}"
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    rankings = data["data"]["rankings"].get(gpu, [])
    print(f"\n=== Live {gpu} Leaderboard ({len(rankings)} total entrants) ===", flush=True)
    shown_us = False
    for row in rankings[:15]:
        is_us = row["user_name"] == "cperkinscperkins"
        if is_us:
            shown_us = True
        marker = " <-- US!" if is_us else ""
        print(
            f"  #{row['rank']:3d}  {row['user_name']:<20s}  {row['score']*1e6:7.2f} us  ({row['file_name']}){marker}",
            flush=True,
        )
    if not shown_us:
        for idx, row in enumerate(rankings):
            if row["user_name"] == "cperkinscperkins":
                print("  ...", flush=True)
                start = max(0, idx - 2)
                end = min(len(rankings), idx + 3)
                for r in rankings[start:end]:
                    marker = " <-- US!" if r["user_name"] == "cperkinscperkins" else ""
                    print(
                        f"  #{r['rank']:3d}  {r['user_name']:<20s}  {r['score']*1e6:7.2f} us  ({r['file_name']}){marker}",
                        flush=True,
                    )
                break


if __name__ == "__main__":
    base = Path(__file__).resolve().parent / "01-vectoradd-v2"

    # Build the in-place kernels (sm_80 inline PTX is portable across A100, L4, H100, B200)
    for out_name in ["crisp_b200_inplace_half4.py", "crisp_f16_inplace_half4.py"]:
        make_gpumode_vectoradd_v2(
            base / "vectoradd_b200_inplace_half4.crisp",
            base / out_name,
            direct_grid_expr="((N >> 2) + (N & 3) + BLOCK_SIZE - 1) / BLOCK_SIZE",
            inplace=True,
            arch="sm_80",
            hardware_profile="b200",
        )
    for out_name in ["crisp_b200_inplace_2xhalf4.py", "crisp_f16_inplace_2xhalf4.py"]:
        make_gpumode_vectoradd_v2(
            base / "vectoradd_b200_inplace_2xhalf4.crisp",
            base / out_name,
            direct_grid_expr="((N >> 2) + (N & 3) + 511) / 512",
            inplace=True,
            arch="sm_80",
            hardware_profile="b200",
        )
    make_gpumode_vectoradd_v2(
        base / "vectoradd_b200_inplace_tile4x_half4.crisp",
        base / "crisp_b200_inplace_tile4x_half4.py",
        direct_grid_expr="((N >> 2) + (N & 3) + 1023) / 1024",
        inplace=True,
        arch="sm_80",
        hardware_profile="b200",
    )

    if "--bench-other-gpus" in sys.argv:
        # Compare 1x half4 in-place vs 2x half4 in-place across H100, A100, and L4,
        # and submit the faster one to the leaderboard for each GPU!
        baselines = {
            "H100": 526.44,
            "A100": 912.90,
            "L4": 6891.89,
        }
        candidates = [
            "crisp_f16_inplace_half4.py",
            "crisp_f16_inplace_2xhalf4.py",
        ]
        for gpu, prev_best in baselines.items():
            best_cand = None
            best_val = float("inf")
            for cand in candidates:
                out = run_popcorn(base / cand, gpu, "vectoradd_v2", "benchmark")
                val = extract_size_16384_us(out)
                if val is not None:
                    print(f"--> [{gpu}] {cand} size=16384 benchmark: {val:.2f} us (prev out-of-place: {prev_best:.2f} us)", flush=True)
                    if val < best_val:
                        best_val = val
                        best_cand = cand
            if best_cand is not None and best_val < prev_best + 5.0:
                print(f"--> Submitting {best_cand} ({best_val:.2f} us) to {gpu} leaderboard...", flush=True)
                run_popcorn(base / best_cand, gpu, "vectoradd_v2", "leaderboard")

        for gpu in ["B200", "H100", "A100", "L4"]:
            print_leaderboard_standings(543, gpu)