#!/usr/bin/env python3
"""
Crisp -> GPU MODE submission packager & runner for matmul_v2 (leaderboard #540).

Compiles Crisp matmul kernels to PTX with `crisp-compile --hoist=cuda`, reads the kernel's parameter
ABI out of the generated CUDA launcher (parameter order, scratch-ring literals, TMA tensor maps), and
wraps everything into one self-contained GPU MODE Python submission.

WHY NOT the inline-asm packager the other contests use (contests/ptx_packager.py): a TMA kernel takes
65 parameters (two tensor-map pointers, 9 per tensor, 12 per scratch ring), and an `asm` statement
takes at most 30 operands.  So this submission loads the PTX with the CUDA DRIVER API
(cuModuleLoadData / cuLaunchKernel), opened with dlopen("libcuda.so.1") so no link flags are needed.
Decision D-196-6 in tests/spec/196-matmul-contest/matmul-contest.md.

Usage:
    python package_matmul.py                       # build every submission .py
    python package_matmul.py <py> <GPU> <mode>     # build, then submit one via popcorn-cli
"""

from __future__ import annotations

import datetime
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

HERE = Path(__file__).resolve().parent
REPO_ROOT = Path(__file__).resolve().parents[3]
CRISP_COMPILE = REPO_ROOT / "bin" / "crisp-compile.exe"
RESULTS_JSON = REPO_ROOT / "contests" / "gpu-mode" / "results" / "matmul_v2.json"


def _popcorn_cli() -> Path:
    for p in (os.environ.get("POPCORN_CLI"),
              REPO_ROOT / "contests" / "gpu-mode" / "bin" / "popcorn-cli.exe",
              REPO_ROOT.parent / "crisp" / "contests" / "gpu-mode" / "bin" / "popcorn-cli.exe"):
        if p and Path(p).exists():
            return Path(p)
    raise FileNotFoundError("popcorn-cli.exe not found (set POPCORN_CLI)")


# ------------------------------------------------------------------------------------------------
# Kernels
# ------------------------------------------------------------------------------------------------

@dataclass
class KernelSpec:
    key: str                  # C++ identifier suffix
    crisp: str                # file name in this directory
    arch: str                 # --ir-target-arch
    tile: tuple[int, int]     # (TM, TN) output tile -> grid (ceil(M/TM), ceil(N/TN)): x <- rows
    k_step: int               # K must be a multiple of this
    b_layout: str             # "row": the contest's (K N) b as is; "col": a transposed (N K) copy
    profile: str | None = None
    tensor_names: tuple = ("a", "b", "c")     # the hoist's names for the kernel's global tensors
    tensor_setup: list[str] | None = None     # C++ CRISP_TENSOR lines; default: the matmul a / b / c
    # filled in by build_kernel
    ptx: str = ""
    entry: str = ""
    params: list[str] = field(default_factory=list)
    literals: dict[str, str] = field(default_factory=dict)
    tensormaps: list[dict] = field(default_factory=list)
    block: int = 0
    smem: int = 0


def compile_with_hoist(spec: KernelSpec) -> tuple[str, str]:
    build = HERE / "_build"
    build.mkdir(exist_ok=True)
    src = build / spec.crisp
    src.write_text((HERE / spec.crisp).read_text(encoding="utf-8"), encoding="utf-8")
    cmd = [str(CRISP_COMPILE), "--ir-target=ptx", f"--ir-target-arch={spec.arch}", "--hoist=cuda"]
    if spec.profile:
        cmd.append(f"--hardware-profile={spec.profile}")
    cmd.append(str(src))
    res = subprocess.run(cmd, cwd=str(REPO_ROOT), capture_output=True, text=True,
                         encoding="utf-8", errors="replace")
    if res.returncode != 0 or "compilation failed" in (res.stdout + res.stderr):
        raise RuntimeError(f"crisp-compile failed for {spec.crisp}:\n{res.stdout}\n{res.stderr}")
    ptx = src.with_suffix(".ptx").read_text(encoding="utf-8")
    hoists = sorted(build.glob(f"{src.stem}_*_CUDA.cu"), key=lambda p: p.stat().st_mtime)
    if not hoists:
        raise RuntimeError(f"no CUDA hoist produced for {spec.crisp}")
    return ptx, hoists[-1].read_text(encoding="utf-8")


def parse_hoist(spec: KernelSpec, hoist: str) -> None:
    """Read the launch ABI out of the generated CUDA launcher -- never hardcode it (the compiler
    orders scratch tiles first, in an order that is not the binding order)."""
    m = re.search(r'cuModuleGetFunction\(&kernel,\s*module,\s*"(\w+)"\)', hoist)
    spec.entry = m.group(1)
    m = re.search(r"void\*\s+kernelParams\[\d+\]\s*=\s*\{(.*?)\};", hoist, flags=re.DOTALL)
    spec.params = re.findall(r"&(\w+)", m.group(1))
    # global tensors are the CUdeviceptr <t>_ptr ones; everything they own is runtime
    runtime_tensors = set(re.findall(r"CUdeviceptr\s+(\w+)_ptr;", hoist))
    if runtime_tensors != set(spec.tensor_names):
        raise ValueError(f"{spec.crisp}: expected global tensors {spec.tensor_names}; hoist has {sorted(runtime_tensors)}")
    # exact names, not prefixes: a scratch ring called b-ring hoists to b_ring_..._ptr
    runtime_names = {f"{t}_{f}" for t in runtime_tensors
                     for f in ("ptr", "byte_size", "off0", "off1", "str0", "str1", "ext0", "ext1", "length")}
    for name, val in re.findall(r"uint64_t\s+(\w+)\s*=\s*(\d+)ULL\s*;", hoist):
        if name not in runtime_names:
            spec.literals[name] = val
    for tm in re.finditer(
            r"CUtensorMap\s+(\w+)_host;.*?"
            r"_gdim\[2\]\s*=\s*\{([^}]*)\};.*?_gstr\[1\]\s*=\s*\{([^}]*)\};.*?"
            r"_box\[2\]\s*=\s*\{([^}]*)\};.*?cuTensorMapEncodeTiled\(&\w+,\s*(CU_TENSOR_MAP_DATA_TYPE_\w+),\s*2,\s*"
            r"\(void\*\)(\w+),.*?(CU_TENSOR_MAP_SWIZZLE_\w+)",
            hoist, flags=re.DOTALL):
        spec.tensormaps.append({
            "name": tm.group(1), "gdim": tm.group(2).strip(), "gstr": tm.group(3).strip(),
            "box": tm.group(4).strip(), "dtype": tm.group(5), "ptr": tm.group(6), "swizzle": tm.group(7)})
    m = re.search(r"cuLaunchKernel\(kernel,\s*gridX,\s*gridY,\s*gridZ,\s*(\d+),\s*\d+,\s*\d+,\s*(\d+),", hoist)
    spec.block, spec.smem = int(m.group(1)), int(m.group(2))
    for p in spec.params:
        known = (p in spec.literals or p in runtime_names
                 or any(t["name"] == p for t in spec.tensormaps))
        if not known:
            raise ValueError(f"{spec.crisp}: kernel param '{p}' is neither runtime, literal nor a tensor map")


def build_kernel(spec: KernelSpec) -> KernelSpec:
    ptx, hoist = compile_with_hoist(spec)
    spec.ptx = ptx
    parse_hoist(spec, hoist)
    print(f"  {spec.key}: entry={spec.entry} params={len(spec.params)} literals={len(spec.literals)} "
          f"tensormaps={len(spec.tensormaps)} block={spec.block} smem={spec.smem}")
    return spec


# ------------------------------------------------------------------------------------------------
# C++ generation
# ------------------------------------------------------------------------------------------------

CPP_PRELUDE = r"""
#include <torch/extension.h>
#include <cuda.h>
#include <cuda_runtime.h>
#include <dlfcn.h>
#include <map>
#include <tuple>
#include <vector>
#include <string>
#include <stdexcept>

// The CUDA driver API, opened at run time: no -lcuda needed in the build.
struct Drv {
    decltype(&cuModuleLoadDataEx)     moduleLoadDataEx = nullptr;
    decltype(&cuFuncGetAttribute)     funcGetAttribute = nullptr;
    decltype(&cuModuleGetFunction)    moduleGetFunction = nullptr;
    decltype(&cuFuncSetAttribute)     funcSetAttribute = nullptr;
    decltype(&cuLaunchKernel)         launchKernel = nullptr;
    decltype(&cuTensorMapEncodeTiled) tensorMapEncodeTiled = nullptr;
    decltype(&cuMemAlloc)             memAlloc = nullptr;
    decltype(&cuMemcpyHtoD)           memcpyHtoD = nullptr;
    decltype(&cuGetErrorString)       getErrorString = nullptr;
};
static Drv drv;

static void* sym(void* h, const char* name) {
    void* p = dlsym(h, name);
    if (!p) throw std::runtime_error(std::string("libcuda: missing ") + name);
    return p;
}

static void drv_init() {
    if (drv.launchKernel) return;
    void* h = dlopen("libcuda.so.1", RTLD_NOW | RTLD_GLOBAL);
    if (!h) h = dlopen("libcuda.so", RTLD_NOW | RTLD_GLOBAL);
    if (!h) throw std::runtime_error("dlopen libcuda failed");
    drv.moduleLoadDataEx     = (decltype(drv.moduleLoadDataEx))    sym(h, "cuModuleLoadDataEx");
    drv.funcGetAttribute     = (decltype(drv.funcGetAttribute))    sym(h, "cuFuncGetAttribute");
    drv.moduleGetFunction    = (decltype(drv.moduleGetFunction))   sym(h, "cuModuleGetFunction");
    drv.funcSetAttribute     = (decltype(drv.funcSetAttribute))    sym(h, "cuFuncSetAttribute");
    drv.launchKernel         = (decltype(drv.launchKernel))        sym(h, "cuLaunchKernel");
    drv.tensorMapEncodeTiled = (decltype(drv.tensorMapEncodeTiled)) sym(h, "cuTensorMapEncodeTiled");
    drv.memAlloc             = (decltype(drv.memAlloc))            sym(h, "cuMemAlloc_v2");
    drv.memcpyHtoD           = (decltype(drv.memcpyHtoD))          sym(h, "cuMemcpyHtoD_v2");
    drv.getErrorString       = (decltype(drv.getErrorString))      sym(h, "cuGetErrorString");
    cudaFree(0);   // make sure the runtime's primary context is current on this thread
}

static void ck(CUresult r, const char* what) {
    if (r != CUDA_SUCCESS) {
        const char* s = "?";
        if (drv.getErrorString) drv.getErrorString(r, &s);
        throw std::runtime_error(std::string(what) + ": " + s);
    }
}

// TMA descriptors live in device memory (Crisp's pointer-to-global tensor-map ABI).  A descriptor is a
// pure function of (pointer, dims, strides, box, type, swizzle), so it is cached by exactly that and never
// overwritten: a reused allocation address with the same shape gets the same, still-correct descriptor.
typedef std::tuple<uint64_t, uint64_t, uint64_t, uint64_t, uint32_t, uint32_t, int, int> TmKey;
static std::map<TmKey, CUdeviceptr> tm_cache;

static uint64_t tensormap(uint64_t ptr, uint64_t g0, uint64_t g1, uint64_t gstr,
                          uint32_t b0, uint32_t b1, CUtensorMapDataType dt, CUtensorMapSwizzle sw) {
    TmKey key(ptr, g0, g1, gstr, b0, b1, (int)dt, (int)sw);
    auto it = tm_cache.find(key);
    if (it != tm_cache.end()) return (uint64_t)it->second;
    CUtensorMap host;
    cuuint64_t gdim[2] = {g0, g1};
    cuuint64_t gs[1] = {gstr};
    cuuint32_t box[2] = {b0, b1};
    cuuint32_t el[2] = {1, 1};
    ck(drv.tensorMapEncodeTiled(&host, dt, 2, (void*)ptr, gdim, gs, box, el,
                                CU_TENSOR_MAP_INTERLEAVE_NONE, sw,
                                CU_TENSOR_MAP_L2_PROMOTION_NONE, CU_TENSOR_MAP_FLOAT_OOB_FILL_NONE),
       "cuTensorMapEncodeTiled");
    CUdeviceptr d;
    ck(drv.memAlloc(&d, sizeof(CUtensorMap)), "cuMemAlloc");
    ck(drv.memcpyHtoD(d, &host, sizeof(CUtensorMap)), "cuMemcpyHtoD");
    tm_cache[key] = d;
    return (uint64_t)d;
}

// The 9 Crisp parameters of a rank-2 tensor.  ROW: (R C) contiguous in C.  COL: (R C) contiguous in R.
#define CRISP_TENSOR(t, P, R, C, ROWMAJOR)                                         \
    uint64_t t##_ptr = (uint64_t)(P);                                              \
    uint64_t t##_ext0 = (R), t##_ext1 = (C);                                       \
    uint64_t t##_str0 = (ROWMAJOR) ? (C) : 1, t##_str1 = (ROWMAJOR) ? 1 : (R);     \
    uint64_t t##_off0 = 0, t##_off1 = 0;                                           \
    uint64_t t##_length = (R) * (C), t##_byte_size = (R) * (C) * 2;
"""


def cpp_for_kernel(spec: KernelSpec) -> tuple[str, str]:
    k = spec.key
    lines = [f"static CUfunction fn_{k} = nullptr;",
             f"void load_{k}(const std::string& ptx) {{",
             "    drv_init();",
             "    CUmodule mod;",
             "    // The PTX carries no .maxntid, so tell the JIT the block size (= __launch_bounds__): without it",
             "    // ptxas may spend up to 255 registers/thread, which a 288-thread block cannot be launched with.",
             "    CUjit_option opt[1] = {CU_JIT_THREADS_PER_BLOCK};",
             f"    void* val[1] = {{(void*)(uintptr_t){spec.block}}};",
             f'    ck(drv.moduleLoadDataEx(&mod, ptx.c_str(), 1, opt, val), "cuModuleLoadDataEx {k}");',
             f'    ck(drv.moduleGetFunction(&fn_{k}, mod, "{spec.entry}"), "cuModuleGetFunction {k}");',
             f"    ck(drv.funcSetAttribute(fn_{k}, CU_FUNC_ATTRIBUTE_MAX_DYNAMIC_SHARED_SIZE_BYTES, {spec.smem}),"
             f' "smem attr {k}");',
             "}",
             "",
             f"std::vector<int64_t> info_{k}() {{",
             "    int regs = 0, maxthr = 0, sshared = 0, local = 0;",
             f"    drv.funcGetAttribute(&regs, CU_FUNC_ATTRIBUTE_NUM_REGS, fn_{k});",
             f"    drv.funcGetAttribute(&maxthr, CU_FUNC_ATTRIBUTE_MAX_THREADS_PER_BLOCK, fn_{k});",
             f"    drv.funcGetAttribute(&sshared, CU_FUNC_ATTRIBUTE_SHARED_SIZE_BYTES, fn_{k});",
             f"    drv.funcGetAttribute(&local, CU_FUNC_ATTRIBUTE_LOCAL_SIZE_BYTES, fn_{k});",
             "    return {regs, maxthr, sshared, local};",
             "}",
             "",
             f"void run_{k}_grid(torch::Tensor A, torch::Tensor B, torch::Tensor C, int64_t gx_, int64_t gy_) {{",
             f'    if (!fn_{k}) throw std::runtime_error("{k}: not loaded");',
             "    const uint64_t M = A.size(0), K = A.size(1), N = C.size(1);",
             "    (void)M; (void)K; (void)N;"]
    lines += spec.tensor_setup or [
             "    CRISP_TENSOR(a, A.data_ptr(), M, K, true)",
             ("    CRISP_TENSOR(b, B.data_ptr(), K, N, true)   // the contest's (K N) b"
              if spec.b_layout == "row" else
              "    CRISP_TENSOR(b, B.data_ptr(), K, N, false)  // (N K) transposed copy = (K N) col-major"),
             "    CRISP_TENSOR(c, C.data_ptr(), M, N, true)"]
    for name, val in spec.literals.items():
        lines.append(f"    uint64_t {name} = {val}ULL;")
    for tm in spec.tensormaps:
        g = [x.strip() for x in tm["gdim"].split(",")]
        b = [x.strip() for x in tm["box"].split(",")]
        gstr = tm["gstr"].replace("sizeof(uint16_t)", "2")
        lines.append(f"    uint64_t {tm['name']} = tensormap({tm['ptr']}, {g[0]}, {g[1]}, {gstr}, {b[0]}, {b[1]},"
                     f" {tm['dtype']}, {tm['swizzle']});")
    lines.append("    void* kp[] = {" + ", ".join(f"&{p}" for p in spec.params) + "};")
    tm_, tn_ = spec.tile
    # the grid tiles the OUTPUT C: x <- rows, y <- cols (the endeavour 143 convention)
    lines += [f"    const uint64_t RC = C.size(0), CC = C.size(1);",
              f"    unsigned gx = (unsigned)((RC + {tm_} - 1) / {tm_}), gy = (unsigned)((CC + {tn_} - 1) / {tn_});",
              # a smaller grid makes the tile-stride kernel walk several tiles per CTA (diagnostics only)
              "    if (gx_ > 0) gx = (unsigned)gx_;",
              "    if (gy_ > 0) gy = (unsigned)gy_;",
              f"    ck(drv.launchKernel(fn_{k}, gx, gy, 1, {spec.block}, 1, 1, {spec.smem}, nullptr, kp, nullptr),"
              f' "launch {k}");',
              "}",
              f"void run_{k}(torch::Tensor A, torch::Tensor B, torch::Tensor C) {{ run_{k}_grid(A, B, C, 0, 0); }}",
              ""]
    decl = (f"void load_{k}(const std::string& ptx);\nstd::vector<int64_t> info_{k}();\n"
            f"void run_{k}(torch::Tensor A, torch::Tensor B, torch::Tensor C);\n"
            f"void run_{k}_grid(torch::Tensor A, torch::Tensor B, torch::Tensor C, int64_t gx_, int64_t gy_);")
    return "\n".join(lines), decl


# ------------------------------------------------------------------------------------------------
# Submission
# ------------------------------------------------------------------------------------------------

def commented(path: Path) -> str:
    return "\n".join("# " + l if l.strip() else "#" for l in path.read_text(encoding="utf-8").splitlines())


def make_submission(out_name: str, title: str, kernels: dict[str, KernelSpec], dispatch_py: str,
                    show: list[str]) -> Path:
    """kernels: role -> spec.  dispatch_py: the body of custom_kernel after `a, b, c = data`."""
    cuda_src = CPP_PRELUDE + "\n" + "\n".join(cpp_for_kernel(s)[0] for s in kernels.values())
    cpp_decl = "#include <torch/extension.h>\n#include <string>\n#include <vector>\n" + \
        "\n".join(cpp_for_kernel(s)[1] for s in kernels.values())
    fns = [f for s in kernels.values()
           for f in (f"load_{s.key}", f"info_{s.key}", f"run_{s.key}", f"run_{s.key}_grid")]
    ptx_consts = "\n".join(f'PTX_{s.key.upper()} = r"""{s.ptx}"""' for s in kernels.values())
    crisp_srcs = "\n#\n".join(f"# --- {name} ---\n{commented(HERE / name)}" for name in show)
    py = f'''#!POPCORN leaderboard matmul_v2
# {title}
#
# Generated by contests/gpu-mode/06-matmul-v2/package_matmul.py from Crisp source.  The kernels are Crisp,
# compiled to PTX by crisp-compile; this file only loads that PTX with the CUDA driver API and launches it.
#
# Crisp source:
# -------------------------------------------------------------------------
{crisp_srcs}
# -------------------------------------------------------------------------

import torch
from torch.utils.cpp_extension import load_inline
from task import input_t, output_t

CUDA_SOURCE = r"""{cuda_src}"""
CPP_SOURCE = r"""{cpp_decl}"""

_mod = load_inline(
    name="crisp_matmul_{out_name.replace('.py', '').replace('-', '_')}",
    cpp_sources=[CPP_SOURCE],
    cuda_sources=[CUDA_SOURCE],
    functions={fns!r},
    extra_cuda_cflags=["-O3"],
    verbose=False,
)

{ptx_consts}

_loaded = set()
def _load(key, ptx):
    if key not in _loaded:
        getattr(_mod, "load_" + key)(ptx)
        _loaded.add(key)

_CAP = torch.cuda.get_device_capability()
_BT = {{}}
def _bt_buffer(b):
    """A persistent (N K) buffer for b's transpose: a stable address keeps its TMA descriptor cached."""
    key = (b.shape[0], b.shape[1])
    bt = _BT.get(key)
    if bt is None:
        bt = torch.empty((b.shape[1], b.shape[0]), device=b.device, dtype=b.dtype)
        _BT[key] = bt
    return bt


def _transposed(b):
    """(K N) b -> a persistent (N K) contiguous copy, i.e. b in the col-major layout wgmma reads.
    Persistent so its address (and so its cached TMA descriptor) is stable across calls."""
    key = (b.shape[0], b.shape[1])
    bt = _BT.get(key)
    if bt is None:
        bt = torch.empty((b.shape[1], b.shape[0]), device=b.device, dtype=b.dtype)
        _BT[key] = bt
    bt.copy_(b.t())
    return bt


def custom_kernel(data: input_t) -> output_t:
    a, b, c = data
    M, K = a.shape
    N = b.shape[1]
{dispatch_py}
    return c
'''
    if "stream" in py.lower():
        raise ValueError(f"{out_name}: forbidden substring 'stream'")
    out = HERE / out_name
    out.write_text(py, encoding="utf-8")
    print(f"Wrote {out.name} ({len(py.splitlines())} lines)")
    return out


SMALL = dict(key="small", crisp="matmul_small_mma.crisp", arch="sm_80", tile=(16, 8), k_step=16,
             b_layout="row", profile="h100")


H100_2WG = dict(key="h100_2wg", crisp="matmul_h100_2wg_deep.crisp", arch="sm_90a", tile=(128, 256),
                k_step=64, b_layout="col")
# endeavour 198: the same kernel reading the contest's (K N) b directly (wgmma transB) -- no transpose
H100_TRANSB = dict(key="h100tb", crisp="matmul_h100_2wg_transb.crisp", arch="sm_90a", tile=(128, 256),
                   k_step=64, b_layout="row")
# endeavour 199: transB + the accumulator stored through stmatrix + TMA (store-tile-at ... :via :tma)
H100_TMA = dict(key="h100tma", crisp="matmul_h100_2wg_tma.crisp", arch="sm_90a", tile=(128, 256),
                k_step=64, b_layout="row")
AMPERE = dict(key="ampere", crisp="matmul_ampere_cp_async.crisp", arch="sm_80", tile=(64, 64), k_step=16,
              b_layout="row", profile="h100")
AMPERE4W = dict(key="ampere4w", crisp="matmul_ampere_4w.crisp", arch="sm_80", tile=(128, 128), k_step=16,
                b_layout="row", profile="h100")
TRANSPOSE = dict(key="transpose", crisp="transpose_b.crisp", arch="sm_80", tile=(64, 64), k_step=1,
                 b_layout="row", tensor_names=("b", "bt"),
                 tensor_setup=["    CRISP_TENSOR(b, A.data_ptr(), A.size(0), A.size(1), true)",
                               "    CRISP_TENSOR(bt, C.data_ptr(), C.size(0), C.size(1), true)"])
B200_TMA = dict(key="b200", crisp="matmul_b200_tma_mma.crisp", arch="sm_100", tile=(64, 64), k_step=16,
                b_layout="row", profile="h100")

# One dispatch for every GPU: the fast kernel when the device and shape fit it, else the small one.
DISPATCH_ALL = """    if _CAP == (9, 0) and M % 128 == 0 and N % 256 == 0 and K % 64 == 0:
        _load("h100tma", PTX_H100TMA)
        _mod.run_h100tma(a, b, c)
    elif _CAP[0] in (8, 10) and M % 128 == 0 and N % 128 == 0 and K % 16 == 0:
        _load("ampere4w", PTX_AMPERE4W)
        _mod.run_ampere4w(a, b, c)
    else:
        _load("small", PTX_SMALL)
        _mod.run_small(a, b, c)"""


def build_all() -> None:
    print("Building matmul_v2 kernels ...")
    ks = {"small": build_kernel(KernelSpec(**SMALL)),
          "h100tma": build_kernel(KernelSpec(**H100_TMA)),
          "ampere4w": build_kernel(KernelSpec(**AMPERE4W))}
    # v5 (endeavour 199): the H100 kernel stores its accumulators :via :tma (stmatrix + TMA store).
    # v4 (197 + 198: packed stores, transB) and v3 are kept as submitted.
    make_submission(
        "crisp_matmul_v5.py",
        "matmul_v2 v5: H100 wgmma 2wg_deep, transB, stmatrix + TMA-store epilogue; A100 / L4 / B200 4-warp cp.async + mma.sync",
        ks, DISPATCH_ALL,
        ["matmul_h100_2wg_tma.crisp", "matmul_ampere_4w.crisp", "matmul_small_mma.crisp"])
    # The beauty entry: one portable 13-line kernel for every GPU and shape.
    beauty = build_kernel(KernelSpec(key="beauty", crisp="matmul_beauty.crisp", arch="sm_80", tile=(16, 8),
                                     k_step=16, b_layout="row", profile="h100"))
    make_submission(
        "crisp_matmul_beauty.py",
        "matmul_v2 beauty entry: one idiomatic tensor-core kernel, every GPU, every shape",
        {"beauty": beauty},
        """    _load("beauty", PTX_BEAUTY)
    _mod.run_beauty(a, b, c)""",
        ["matmul_beauty.crisp"])


# ------------------------------------------------------------------------------------------------
# popcorn
# ------------------------------------------------------------------------------------------------

def submit_popcorn(py_file: Path, gpu: str, mode: str) -> str:
    cmd = [str(_popcorn_cli()), "submit", str(py_file), "--gpu", gpu, "--leaderboard", "matmul_v2",
           "--mode", mode, "--no-tui"]
    print("Running:", " ".join(cmd), flush=True)
    res = subprocess.run(cmd, cwd=str(REPO_ROOT), capture_output=True, text=True, encoding="utf-8",
                         errors="replace")
    out = (res.stdout or "") + "\n" + (res.stderr or "")
    log = HERE / "_build" / f"popcorn_{py_file.stem}_{gpu}_{mode}.log"
    log.write_text(out, encoding="utf-8")
    record_run(out, gpu, py_file.stem, py_file.name, mode)
    return out


def record_run(stdout: str, gpu: str, kernel_key: str, file_name: str, mode: str) -> None:
    if not RESULTS_JSON.exists():
        return
    data = json.loads(RESULTS_JSON.read_text(encoding="utf-8"))
    m_sub = re.search(r'"submission_id":\s*(\d+)', stdout) or re.search(r"[Ss]ubmission\s+(\d+)", stdout)
    sub_id = int(m_sub.group(1)) if m_sub else None
    # popcorn prints us, or ms once a time passes 1000 us -- normalise to us
    scale = {"µs": 1.0, "us": 1.0, "ms": 1000.0, "s": 1e6}
    unit = "(µs|us|ms|s)(?![a-z])"
    num = "([0-9.]+)"
    sp = "[ 	]*"
    pairs = [(float(m.group(1)) * scale[m.group(3)], float(m.group(2)) * scale[m.group(3)])
             for m in re.finditer("⏱" + sp + num + sp + "±" + sp + num + sp + unit, stdout)]
    means = [round(a, 2) for a, _ in pairs]
    stds = [round(b, 3) for _, b in pairs]
    bw = [(float(m.group(1)) * scale[m.group(2)], float(m.group(3)) * scale[m.group(4)])
          for m in re.finditer("⚡" + sp + num + sp + unit + sp + "🐌" + sp + num + sp + unit, stdout)]
    bests = [round(a, 2) for a, _ in bw]
    worsts = [round(b, 2) for _, b in bw]
    m_pub = re.search(r"(?:public leaderboard score|Geomean score \(public\)[^:]*):\s*([0-9.eE+-]+)\s*s", stdout)
    m_sec = re.search(r"(?:secret leaderboard score|Geomean score \(secret\)[^:]*):\s*([0-9.eE+-]+)\s*s", stdout)
    data.setdefault("runs", []).append({
        "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "gpu": gpu, "kernel_key": kernel_key, "file_name": file_name, "mode": mode,
        "submission_id": sub_id,
        "benchmark_mean_us": means[-1] if means else None,
        "benchmark_std_us": stds[-1] if stds else None,
        "benchmark_best_us": bests[-1] if bests else None,
        "benchmark_worst_us": worsts[-1] if worsts else None,
        "per_case_us": means or None,
        "public_score_us": round(float(m_pub.group(1)) * 1e6, 2) if m_pub else None,
        "secret_score_us": round(float(m_sec.group(1)) * 1e6, 2) if m_sec else None,
    })
    RESULTS_JSON.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Recorded run (submission {sub_id}) in {RESULTS_JSON.name}")


if __name__ == "__main__":
    build_all()
    if len(sys.argv) >= 4:
        submit_popcorn(HERE / sys.argv[1], gpu=sys.argv[2], mode=sys.argv[3])


# ------------------------------------------------------------------------------------------------
# Per-arm timing diagnostic (popcorn --mode test; the table comes back as a RuntimeError).
# Method: memory gpumode-per-case-diag -- time each arm on the SCORED case with utils.clear_l2_cache
# between reps, median of N.
# ------------------------------------------------------------------------------------------------

DIAG_BODY = r'''
    import statistics
    from reference import generate_input, ref_kernel
    from utils import clear_l2_cache
    torch.backends.cuda.matmul.allow_tf32 = False
    rows = [f"device {torch.cuda.get_device_name(0)} cc{_CAP}"]
    for (m, n, k, seed) in DIAG_CASES:
        a2, b2, c2 = generate_input(m, n, k, seed)
        exp = ref_kernel((a2, b2, c2)).clone()
        def t(fn, reps=15):
            fn(); torch.cuda.synchronize()
            ts = []
            for _ in range(reps):
                clear_l2_cache()
                s = torch.cuda.Event(enable_timing=True); e = torch.cuda.Event(enable_timing=True)
                s.record(); fn(); e.record(); torch.cuda.synchronize()
                ts.append(s.elapsed_time(e) * 1000.0)
            return statistics.median(ts)
        out = [f"{m}x{n}x{k}:"]
        for name, fn, check in DIAG_ARMS(a2, b2, c2):
            us = t(fn)
            bad = ""
            if check:
                fn(); torch.cuda.synchronize()
                nbad = int(((c2.float() - exp.float()).abs() > 1e-5 * exp.float().abs()).sum().item())
                bad = f" bad={nbad}"
            out.append(f"{name}={us:.1f}us{bad}")
        rows.append(" ".join(out))
    raise RuntimeError("DIAG\n" + "\n".join(rows))
'''


def make_diag(out_name: str, kernels: dict[str, KernelSpec], arms_py: str, cases: list[tuple],
              show: list[str]) -> Path:
    """A submission whose custom_kernel times DIAG_ARMS on DIAG_CASES and raises the table."""
    dispatch = (f"    DIAG_CASES = {cases!r}\n" + arms_py + DIAG_BODY)
    return make_submission(out_name, "matmul_v2 timing diagnostic", kernels, dispatch, show)
