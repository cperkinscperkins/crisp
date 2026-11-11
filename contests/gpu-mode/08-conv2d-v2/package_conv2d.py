#!/usr/bin/env python3
"""
Crisp -> GPU MODE submission packager & runner for conv2d_v2 (leaderboard #537).

Compiles a Crisp conv2d kernel to PTX with `crisp-compile --hoist=cuda`, reads its parameter ABI out of
the generated CUDA launcher, and writes one self-contained GPU MODE Python submission that loads the PTX
with the CUDA driver API through ctypes (cuModuleLoadData / cuLaunchKernel on libcuda.so.1) -- nothing is
compiled on the judge.  The ABI reader and the runtime's launch scheme are sort_v2's (07-sort-v2/package_sort.py):
every Crisp vector parameter is six u64s (ptr, byte_size, off0, str0, ext0, length).

Usage:
    python package_conv2d.py                       # build every submission .py
    python package_conv2d.py <py> <GPU> <mode>     # build, then submit one via popcorn-cli
"""

from __future__ import annotations

import datetime
import importlib.util
import json
import re
import subprocess
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = Path(__file__).resolve().parent
REPO_ROOT = Path(__file__).resolve().parents[3]
CRISP_COMPILE = REPO_ROOT / "bin" / "crisp-compile.exe"
RESULTS_JSON = REPO_ROOT / "contests" / "gpu-mode" / "results" / "conv2d_v2.json"
LEADERBOARD = "conv2d_v2"

_spec = importlib.util.spec_from_file_location("package_sort", HERE.parent / "07-sort-v2" / "package_sort.py")
_sort = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_sort)
parse_abi, commented, _popcorn_cli = _sort.parse_abi, _sort.commented, _sort._popcorn_cli


def _top_level_forms(text: str) -> list[str]:
    """The top-level forms of a Crisp file (comments outside forms dropped; ; comments and strings respected)."""
    forms, depth, start, i, n = [], 0, None, 0, len(text)
    while i < n:
        ch = text[i]
        if ch == ";":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if ch == '"':
            i += 1
            while i < n and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
        elif ch == "(":
            if depth == 0:
                start = i
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                forms.append(text[start:i + 1])
        i += 1
    return forms


def merged_source(crisp) -> tuple[str, str]:
    """(file name, text) for one Crisp file or a tuple of them.  A tuple is concatenated into one module;
    a top-level form that already appeared in an earlier file (the shared def-types, splat) is dropped."""
    if isinstance(crisp, str):
        return crisp, (HERE / crisp).read_text(encoding="utf-8")
    seen, parts = set(), []
    for f in crisp:
        text = (HERE / f).read_text(encoding="utf-8")
        for form in _top_level_forms(text):
            key = " ".join(form.split())
            if key in seen:
                text = text.replace(form, f";; (shared form dropped: defined earlier in the merged module)", 1)
            seen.add(key)
        parts.append(f";; ===== {f} =====\n{text}")
    name = "_".join(Path(f).stem for f in crisp) + ".crisp"
    return name, "\n".join(parts)


def compile_crisp(crisp, kernels, arch: str = "sm_80") -> tuple[str, dict[str, str]]:
    """PTX text and {kernel: CUDA hoist text}.  Run from the repo root (crisp-compile finds its DLLs there).
    crisp is one file name, or a tuple of them compiled as ONE module (see merged_source)."""
    build = HERE / "_build"
    build.mkdir(exist_ok=True)
    name, text = merged_source(crisp)
    src = build / name
    src.write_text(text, encoding="utf-8")
    cmd = [str(CRISP_COMPILE), "--ir-target=ptx", f"--ir-target-arch={arch}", "--hoist=cuda", str(src)]
    res = subprocess.run(cmd, cwd=str(REPO_ROOT), capture_output=True, text=True, encoding="utf-8", errors="replace")
    if res.returncode != 0 or "compilation failed" in (res.stdout + res.stderr):
        raise RuntimeError(f"crisp-compile failed for {crisp}:\n{res.stdout}\n{res.stderr}")
    ptx = src.with_suffix(".ptx").read_text(encoding="utf-8")
    hoists = {k: (build / f"{src.stem}_{k}_CUDA.cu").read_text(encoding="utf-8") for k in kernels}
    return ptx, hoists


# The driver-API runtime shared by every conv2d submission (sort_v2's, minus its sort-specific parts).
RUNTIME = r'''
import ctypes as _C
import torch
from task import input_t, output_t

_lib = None
_fn = {}
_args = {}            # launch-argument cache: (kernel, groups, tensors) -> (u64 array, void* array)


def _ck(r, what):
    if r != 0:
        s = _C.c_char_p()
        _lib.cuGetErrorString(r, _C.byref(s))
        raise RuntimeError(f"{what}: CUDA error {r} {s.value}")


def _init():
    global _lib
    torch.empty(1, device="cuda")                      # the runtime's primary context, current here
    _lib = _C.CDLL("libcuda.so.1")
    mod = _C.c_void_p()
    _ck(_lib.cuModuleLoadData(_C.byref(mod), _C.c_char_p(PTX.encode())), "cuModuleLoadData")
    for k, abi in ABI.items():
        f = _C.c_void_p()
        _ck(_lib.cuModuleGetFunction(_C.byref(f), mod, k.encode()), "cuModuleGetFunction " + k)
        _ck(_lib.cuFuncSetAttribute(f, 8, abi["smem"]), "max dynamic smem " + k)   # 8 = MAX_DYNAMIC_SHARED_SIZE_BYTES
        _fn[k] = f


def _launch(k, groups, tensors):
    """tensors: Crisp vector name -> (pointer, element count[, element bytes, default 4])."""
    key = (k, groups, tuple(sorted(tensors.items())))
    a = _args.get(key)
    if a is None:
        vals = []
        for p in ABI[k]["params"]:
            if isinstance(p, int):
                vals.append(p)
            elif p[0] == "@scratch":
                raise RuntimeError(f"{k}: compiler-owned global scratch is not supported by this runtime")
            else:
                ptr, n, *es = tensors[p[0]]
                vals.append({"ptr": ptr, "byte_size": (es[0] if es else 4) * n, "off0": 0, "str0": 1, "ext0": n,
                             "length": n}[p[1]])
        u = (_C.c_uint64 * len(vals))(*vals)
        v = (_C.c_void_p * len(vals))(*[_C.addressof(u) + 8 * i for i in range(len(vals))])
        a = _args[key] = (u, v)
    g = groups if isinstance(groups, tuple) else (groups, 1, 1)
    _ck(_lib.cuLaunchKernel(_fn[k], g[0], g[1], g[2], ABI[k]["block"], 1, 1, ABI[k]["smem"], None, a[1], None),
        "launch " + k)


_DIMS = {}
def _dims(*v):
    """A small int32 device vector of shape numbers, made once per distinct shape."""
    t = _DIMS.get(v)
    if t is None:
        t = _DIMS[v] = torch.tensor(v, dtype=torch.int32, device="cuda")
    return t
'''


# ------------------------------------------------------------------------------------------------
# Beauty: one thread per output element (conv2d_beauty.crisp)
# ------------------------------------------------------------------------------------------------
BEAUTY_KERNELS = ("conv2d_cudnn_order", "conv2d_accurate")
BEAUTY = r'''

# The GPUs whose fp32 cuDNN reference is an FFT, accurate to ~1e-4: there the accurate kernel passes.
# Everywhere else measured (H100 implicit_convolve_sgemm; L4 and B200 precomputed_convolve_sgemm) the
# reference is ONE sequential FMA chain per output and only its own summation order passes
# (diag_conv2d_orders.py / diag_conv2d_orders_lite.py, 2026-11-11).
_FFT_REFERENCE_CC = {(8, 0)}        # A100


def custom_kernel(data: input_t) -> output_t:
    x, w, out = data
    if _lib is None:
        _init()
    B, C, H, _ = x.shape
    K = w.shape[2]
    n = out.numel()
    k = ("conv2d_accurate" if torch.cuda.get_device_capability() in _FFT_REFERENCE_CC
         else "conv2d_cudnn_order")
    P = lambda t: t.data_ptr()
    _launch(k, (n + 255) // 256, {"x": (P(x), x.numel()), "w": (P(w), w.numel()),
                                  "dims": (P(_dims(C, H, K)), 3), "y": (P(out), n)})
    return out
'''


# ------------------------------------------------------------------------------------------------
# Tiled (H100 lane): w_transpose + conv_tiled (conv2d_tiled.crisp)
# ------------------------------------------------------------------------------------------------
TILED_KERNELS = ("w_transpose", "conv_tiled", "conv_tiled8", "conv_tiled_p", "conv_tiled_p32",
                 "conv_tiled_p32r", "conv_tiled_p32e", "conv_tiled_pe", "conv_edge")
# kernel -> (patch rows, patch columns): groups = B * ceil(C / 32) * ceil(O / rows) * ceil(O / cols)
TILED_SHAPES = {"conv_tiled": (8, 32), "conv_tiled8": (8, 64), "conv_tiled_p": (8, 32), "conv_tiled_p32": (8, 32),
                "conv_tiled_p32r": (8, 32), "conv_tiled_p32e": (8, 32, "edge"),
                "conv_tiled_pe": (8, 32, "edge")}


def tiled_body(kernel: str) -> str:
    return TILED_COMMON + f"\n_KERNEL = {kernel!r}\n" + TILED_ENTRY


TILED_COMMON = r'''

_WT = {}
_SHAPES = SHAPES_PLACEHOLDER


def _conv_tiled(k, x, w, out):
    B, C, H, _ = x.shape
    K = w.shape[2]
    O = H - K + 1
    nw = w.numel()
    wt = _WT.get(nw)
    if wt is None:
        wt = _WT[nw] = torch.empty(nw, dtype=torch.float32, device="cuda")
    dims = _dims(C, H, K, B)
    P = lambda t: t.data_ptr()
    _launch("w_transpose", ((C + 31) // 32) * ((nw // C + 31) // 32),
            {"w": (P(w), nw), "dims": (P(dims), 4), "wt": (P(wt), nw)})
    rows, cols, *edge = _SHAPES[k]
    if not edge:
        groups = B * ((C + 31) // 32) * ((O + rows - 1) // rows) * ((O + cols - 1) // cols)
        _launch(k, groups, {"x": (P(x), x.numel()), "wt": (P(wt), nw), "dims": (P(dims), 4), "y": (P(out), out.numel())})
        return out
    # the host picks the patch grid: a thin leftover strip (<= 4 columns, <= 1 row) goes to conv_edge
    nbx = O // cols if O % cols <= 4 else (O + cols - 1) // cols
    nby = O // rows if O % rows <= 1 else (O + rows - 1) // rows
    xl, yl = min(nbx * cols, O), min(nby * rows, O)
    ne = B * C * (yl * (O - xl) + (O - yl) * O)
    d6 = _dims(C, H, K, B, nbx, nby)
    if nbx * nby:
        _launch(k, B * ((C + 31) // 32) * nby * nbx,
                {"x": (P(x), x.numel()), "wt": (P(wt), nw), "dims": (P(d6), 6), "y": (P(out), out.numel())})
    if ne:
        _launch("conv_edge", (ne + 255) // 256,
                {"x": (P(x), x.numel()), "w": (P(w), nw), "dims": (P(d6), 6), "y": (P(out), out.numel())})
    return out
'''.replace("SHAPES_PLACEHOLDER", repr(TILED_SHAPES))

TILED_ENTRY = r'''

def custom_kernel(data: input_t) -> output_t:
    x, w, out = data
    if _lib is None:
        _init()
    return _conv_tiled(_KERNEL, x, w, out)
'''

# ------------------------------------------------------------------------------------------------
# FFT lane (conv2d_fft.crisp): where the cuDNN reference is an FFT (the A100), any accurate method passes.
# Overlap-save on 64 x 64 tiles; planar complex spectra in device scratch made once per shape.
# ------------------------------------------------------------------------------------------------
FFT_KERNELS = ("fft_fwd", "cgemm", "fft_inv", "fft_fwd32", "cgemm32", "fft_inv32", "fft8_fwd", "fft8_inv", "cgemm2")
FFT_COMMON = r'''
import math as _math

_FFT_REFERENCE_CC = {(8, 0)}        # A100: cuDNN's own answer is an FFT (accurate), so ours may be too
_FFT = {}
# variant -> (forward transform, cgemm, inverse transform, twiddle entries); "8" = radix-8 transforms
_FFT_VARIANTS = {"64": ("fft_fwd", "cgemm", "fft_inv", 32), "32": ("fft_fwd32", "cgemm32", "fft_inv32", 32),
                 "8": ("fft8_fwd", "cgemm", "fft8_inv", 64), "8c32": ("fft8_fwd", "cgemm32", "fft8_inv", 64),
                 "8g2": ("fft8_fwd", "cgemm2", "fft8_inv", 64)}
_FFT_VARIANT = "8g2"     # best on the A100 (diag_conv2d_fft.py, 2026-11-11)


def _fft_plan(B, C, H, K):
    O, V = H - K + 1, 65 - K
    nt = -(-O // V)
    NBT = B * nt * nt
    NBTP = -(-NBT // 7) * 7
    key = (B, C, H, K)
    st = _FFT.get(key)
    if st is None:
        f = lambda n: torch.empty(n, dtype=torch.float32, device="cuda")
        def twiddles(n):         # W64^m, m < n: (cos ; -sin)
            m = torch.arange(n, dtype=torch.float64)
            return torch.cat([torch.cos(2 * _math.pi * m / 64), -torch.sin(2 * _math.pi * m / 64)]).float().cuda()
        nxf, nwf = C * NBTP * 2112, C * C * 2112
        st = _FFT[key] = dict(tw={32: twiddles(32), 64: twiddles(64)}, nxf=nxf, nwf=nwf,
                              xr=f(nxf), xi=f(nxf), wr=f(nwf), wi=f(nwf), yr=f(nxf), yi=f(nxf),
                              d0=_dims(C, H, K, 0, NBT, nt, NBTP, B), d1=_dims(C, H, K, 1, NBT, nt, NBTP, B),
                              NBT=NBT, NBTP=NBTP)
    return st


def _fft_stage(st, which, x, w, out, var):
    P = lambda t: t.data_ptr()
    C = w.shape[0]
    nxf, nwf = st["nxf"], st["nwf"]
    kf, kg, ki, ntw = _FFT_VARIANTS[var]
    tw = (P(st["tw"][ntw]), 2 * ntw)
    if which == "wfft":
        _launch(kf, C * C, {"src": (P(w), w.numel()), "tw": tw, "dims": (P(st["d1"]), 8),
                            "outr": (P(st["wr"]), nwf), "outi": (P(st["wi"]), nwf)})
    elif which == "xfft":
        _launch(kf, C * st["NBT"], {"src": (P(x), x.numel()), "tw": tw, "dims": (P(st["d0"]), 8),
                                    "outr": (P(st["xr"]), nxf), "outi": (P(st["xi"]), nxf)})
    elif which == "cgemm":
        nblk = st["NBTP"] // 7
        _launch(kg, 66 * ((C + 31) // 32) * ((nblk + 1) // 2 if kg == "cgemm2" else nblk),
                {"xr": (P(st["xr"]), nxf), "xi": (P(st["xi"]), nxf), "wr": (P(st["wr"]), nwf), "wi": (P(st["wi"]), nwf),
                 "dims": (P(st["d0"]), 8), "yr": (P(st["yr"]), nxf), "yi": (P(st["yi"]), nxf)})
    else:
        _launch(ki, C * st["NBT"], {"yr": (P(st["yr"]), nxf), "yi": (P(st["yi"]), nxf), "tw": tw,
                                    "dims": (P(st["d0"]), 8), "y": (P(out), out.numel())})


def _conv_fft(x, w, out, var=None):
    B, C, H, _ = x.shape
    st = _fft_plan(B, C, H, w.shape[2])
    for s in ("wfft", "xfft", "cgemm", "ifft"):
        _fft_stage(st, s, x, w, out, var or _FFT_VARIANT)
    return out
'''

PERF_ENTRY = r'''

def custom_kernel(data: input_t) -> output_t:
    x, w, out = data
    if _lib is None:
        _init()
    if torch.cuda.get_device_capability() in _FFT_REFERENCE_CC and w.shape[2] <= 33:
        return _conv_fft(x, w, out)
    return _conv_tiled("conv_tiled_p", x, w, out)
'''

# Per-stage timing of the FFT lane on the scored case (eval.py's procedure), plus accuracy vs the reference.
FFT_TIMING_DIAG = r'''

_DIAG_SFX = ("64", "8", "8g2")
_DIAG_KERNELS = FFT_KERNELS_PLACEHOLDER

def custom_kernel(data):
    from reference import generate_input, ref_kernel
    from utils import clear_l2_cache
    if _lib is None:
        _init()
    def tm(f, reps=5, clear=True):
        f(); torch.cuda.synchronize()
        ts = []
        for _ in range(reps):
            if clear:
                clear_l2_cache()
            torch.cuda.synchronize()
            a, b = torch.cuda.Event(enable_timing=True), torch.cuda.Event(enable_timing=True)
            a.record(); f(); b.record(); torch.cuda.synchronize()
            ts.append(a.elapsed_time(b))
        return sum(ts) / len(ts), min(ts)
    lines = [f"device {torch.cuda.get_device_name()} cc {torch.cuda.get_device_capability()}"]
    for case in ((256, 32, 128, 1, 6252), (256, 16, 128, 2, 8841), (128, 8, 64, 4, 54352)):
        size, ks, ch, b, seed = case
        d = generate_input(size=size, kernelsize=ks, channels=ch, batch=b, seed=seed)
        x, w, out = d
        ref = ref_kernel(d).clone()
        m, lo = tm(lambda: ref_kernel(d))
        lines.append(f"case {case}: ref {m:.3f} ms")
        tol = 1e-3 + 1e-3 * ref.abs()
        st = _fft_plan(b, ch, size, ks)
        for sfx in _DIAG_SFX:
            o = torch.empty_like(out)
            _conv_fft(x, w, o, sfx); torch.cuda.synchronize()
            bad = int(((o - ref).abs() > tol).sum().item())
            e = (o - ref).abs()
            m, lo = tm(lambda: _conv_fft(x, w, o, sfx))
            line = f"   [{sfx}] total {m:.3f} ms (min {lo:.3f});"
            for s in ("wfft", "xfft", "cgemm", "ifft"):
                sm, _ = tm(lambda: _fft_stage(st, s, x, w, o, sfx))
                line += f" {s} {sm:.3f}"
            line += f"; mismatches {bad}, max|d| {e.max().item():.2e}, rms {e.pow(2).mean().sqrt().item():.2e}"
            lines.append(line)
    for k in _DIAG_KERNELS:
        nb = _C.c_int(); _ck(_lib.cuOccupancyMaxActiveBlocksPerMultiprocessor(_C.byref(nb), _fn[k], ABI[k]["block"], ABI[k]["smem"]), "occ")
        regs = _C.c_int(); _lib.cuFuncGetAttribute(_C.byref(regs), 4, _fn[k])
        lcl = _C.c_int(); _lib.cuFuncGetAttribute(_C.byref(lcl), 3, _fn[k])
        lines.append(f"{k}: {regs.value} regs, {lcl.value} B local, smem {ABI[k]['smem']}, {nb.value} blocks/SM")
    raise RuntimeError("DIAG\n" + "\n".join(lines))
'''.replace("FFT_KERNELS_PLACEHOLDER", repr(FFT_KERNELS))


# A/B timing on ONE runner (GPU MODE's H100s differ ~30%): eval.py's procedure -- clear_l2_cache, events,
# mean -- for the cuDNN reference and each tiled kernel on the scored case, plus bit-exactness vs the reference.
TIMING_DIAG = TILED_COMMON + r'''

def custom_kernel(data):
    from reference import generate_input, ref_kernel
    from utils import clear_l2_cache
    if _lib is None:
        _init()
    d = generate_input(size=256, kernelsize=32, channels=128, batch=1, seed=6252)
    x, w, out = d
    def tm(f, reps=5):
        f(); torch.cuda.synchronize()
        ts = []
        for _ in range(reps):
            clear_l2_cache(); torch.cuda.synchronize()
            a, b = torch.cuda.Event(enable_timing=True), torch.cuda.Event(enable_timing=True)
            a.record(); f(); b.record(); torch.cuda.synchronize()
            ts.append(a.elapsed_time(b))
        return sum(ts) / len(ts), min(ts)
    ref = ref_kernel(d)
    lines = [f"device {torch.cuda.get_device_name()} cc {torch.cuda.get_device_capability()}"]
    m, lo = tm(lambda: ref_kernel(d))
    lines.append(f"cudnn reference: mean {m:.2f} ms, min {lo:.2f} ms")
    for k in _SHAPES:
        o = torch.empty_like(out)
        _conv_tiled(k, x, w, o); torch.cuda.synchronize()
        exact = (o == ref).double().mean().item()
        m, lo = tm(lambda: _conv_tiled(k, x, w, o))
        nb = _C.c_int(); _ck(_lib.cuOccupancyMaxActiveBlocksPerMultiprocessor(_C.byref(nb), _fn[k], 256, ABI[k]["smem"]), "occ")
        regs = _C.c_int(); _lib.cuFuncGetAttribute(_C.byref(regs), 4, _fn[k])
        lcl = _C.c_int(); _lib.cuFuncGetAttribute(_C.byref(lcl), 3, _fn[k])
        lines.append(f"{k}: mean {m:.2f} ms, min {lo:.2f} ms, {1.699e12 / (m * 1e-3) / 1e12:.1f} TFLOPS; bit-exact vs ref "
                     f"{exact:.6f}; {regs.value} regs, {lcl.value} B local, {nb.value} blocks/SM")
    raise RuntimeError("DIAG\n" + "\n".join(lines))
'''


# ------------------------------------------------------------------------------------------------
# Accuracy diagnostic (popcorn --mode test): who carries the error -- us or the cuDNN reference?
# Runs the scored case, compares ours and the fp32 reference against a float64 conv2d, and raises the
# table as a RuntimeError (it comes back on stderr).  Appended after a submission's custom_kernel.
# ------------------------------------------------------------------------------------------------
ACCURACY_DIAG = r'''

# ---- diagnostic: the table comes back as the RuntimeError ----
_real_kernel = custom_kernel
def custom_kernel(data):
    import torch.nn.functional as _F
    from reference import generate_input, ref_kernel
    lines = []
    for case in ((256, 32, 128, 1, 6252), (256, 16, 128, 2, 8841), (128, 8, 64, 4, 54352)):
        size, ks, ch, b, seed = case
        d = generate_input(size=size, kernelsize=ks, channels=ch, batch=b, seed=seed)
        ours = _real_kernel(d).clone()
        ref = ref_kernel(d)
        exact = _F.conv2d(d[0].double(), d[1].double())
        tol = 1e-3 + 1e-3 * ref.abs()
        def st(t):
            e = (t.double() - exact).abs()
            return f"rms {e.pow(2).mean().sqrt().item():.2e} max {e.max().item():.2e}"
        lines.append(f"case {case}: |exact| rms {exact.pow(2).mean().sqrt().item():.1f}")
        lines.append(f"   ours vs f64: {st(ours)}")
        lines.append(f"   ref  vs f64: {st(ref)}")
        lines.append(f"   ours vs ref: mismatches {int(((ours - ref).abs() > tol).sum().item())}")
        lines.append(f"   f64  vs ref: mismatches {int(((exact.float() - ref).abs() > tol).sum().item())}")
        lines.append(f"   cudnn algo flags: deterministic {torch.backends.cudnn.deterministic} "
                     f"benchmark {torch.backends.cudnn.benchmark} version {torch.backends.cudnn.version()}")
    raise RuntimeError("DIAG\n" + "\n".join(lines))
'''


# Order diagnostic: which single fp32 FMA chain (if any) reproduces cuDNN's rounding, and which cuDNN
# kernel the reference runs.  conv2d_orders.crisp.
ORDER_KERNELS = ("conv_crs", "conv_rsc")
ORDER_DIAG = r'''

def custom_kernel(data):
    import torch.nn.functional as _F
    from reference import generate_input, ref_kernel
    if _lib is None:
        _init()
    P = lambda t: t.data_ptr()
    lines = []
    for case in ((256, 32, 128, 1, 6252), (256, 16, 128, 2, 8841), (128, 16, 64, 4, 93246)):
        size, ks, ch, b, seed = case
        d = generate_input(size=size, kernelsize=ks, channels=ch, batch=b, seed=seed)
        x, w, out = d
        with torch.profiler.profile(activities=[torch.profiler.ProfilerActivity.CUDA]) as prof:
            ref = ref_kernel(d)
            torch.cuda.synchronize()
        names = sorted({e.name[:110] for e in prof.events() if e.device_type == torch.autograd.DeviceType.CUDA})
        exact = _F.conv2d(x.double(), w.double())
        tol = 1e-3 + 1e-3 * ref.abs()
        lines.append(f"case {case}: ref vs f64 rms {(ref.double() - exact).pow(2).mean().sqrt().item():.2e}; "
                     f"f64 mismatches {int(((exact.float() - ref).abs() > tol).sum().item())}")
        lines.append("   cudnn kernels: " + " | ".join(names))
        for k in ABI:
            o = torch.empty_like(out)
            n = o.numel()
            _launch(k, (n + 255) // 256, {"x": (P(x), x.numel()), "w": (P(w), w.numel()),
                                          "dims": (P(_dims(ch, size, ks)), 3), "y": (P(o), n)})
            torch.cuda.synchronize()
            e = (o - ref).abs()
            lines.append(f"   {k}: vs ref mismatches {int((e > tol).sum().item())}, max {e.max().item():.2e}, "
                         f"rms {e.double().pow(2).mean().sqrt().item():.2e}, bit-exact {(o == ref).double().mean().item():.4f}; "
                         f"vs f64 rms {(o.double() - exact).pow(2).mean().sqrt().item():.2e}")
    raise RuntimeError("DIAG\n" + "\n".join(lines))
'''


# Light order diagnostic for slow GPUs (the full one timed out on the L4: a full-size float64 conv2d): the
# scored case only, the chain kernel only, and the reference's accuracy on a 40 x 40 output crop.
ORDER_LITE_DIAG = r'''

def custom_kernel(data):
    import torch.nn.functional as _F
    from reference import generate_input, ref_kernel
    if _lib is None:
        _init()
    P = lambda t: t.data_ptr()
    size, ks, ch, b, seed = 256, 32, 128, 1, 6252
    d = generate_input(size=size, kernelsize=ks, channels=ch, batch=b, seed=seed)
    x, w, out = d
    with torch.profiler.profile(activities=[torch.profiler.ProfilerActivity.CUDA]) as prof:
        ref = ref_kernel(d)
        torch.cuda.synchronize()
    names = sorted({e.name[:90] for e in prof.events() if e.device_type == torch.autograd.DeviceType.CUDA})
    crop = _F.conv2d(x[:, :, :40 + ks - 1, :40 + ks - 1].double(), w.double())
    rc = ref[:, :, :40, :40].double()
    tol = 1e-3 + 1e-3 * ref.abs()
    lines = [f"device {torch.cuda.get_device_name()} cc {torch.cuda.get_device_capability()}",
             "cudnn kernels: " + " | ".join(names),
             f"ref vs f64 on a 40x40 crop: rms {(rc - crop).pow(2).mean().sqrt().item():.2e}, "
             f"max {(rc - crop).abs().max().item():.2e}"]
    o = torch.empty_like(out)
    n = o.numel()
    _launch("conv_crs", (n + 255) // 256, {"x": (P(x), x.numel()), "w": (P(w), w.numel()),
                                           "dims": (P(_dims(ch, size, ks)), 3), "y": (P(o), n)})
    torch.cuda.synchronize()
    e = (o - ref).abs()
    lines.append(f"conv_crs vs ref: mismatches {int((e > tol).sum().item())}, max {e.max().item():.2e}, "
                 f"bit-exact {(o == ref).double().mean().item():.4f}")
    raise RuntimeError("DIAG\n" + "\n".join(lines))
'''


def make_submission(out_name: str, title: str, crisp: str, body: str, kernels) -> Path:
    ptx, hoists = compile_crisp(crisp, kernels)
    abi = {}
    for k in kernels:
        a = parse_abi(k, hoists[k])
        print(f"  {k}: params={len(a['params'])} block={a['block']} smem={a['smem']} tensors={a['tensors']}"
              f" scratch={a['scratch']}")
        if a["scratch"]:
            raise ValueError(f"{k}: compiler-owned global scratch {a['scratch']} -- extend the runtime first")
        abi[k] = {"params": a["params"], "block": a["block"], "smem": a["smem"]}
    py = (f"#!POPCORN leaderboard {LEADERBOARD}\n# {title}\n#\n"
          "# Generated by contests/gpu-mode/08-conv2d-v2/package_conv2d.py from Crisp source.  The kernels are Crisp,\n"
          "# compiled to PTX by crisp-compile; this file only loads that PTX with the CUDA driver API and launches it.\n"
          "#\n# Crisp source:\n# -------------------------------------------------------------------------\n"
          + "".join(f"# --- {f} ---\n{commented(HERE / f)}\n" for f in ((crisp,) if isinstance(crisp, str) else crisp)) +
          "# -------------------------------------------------------------------------\n"
          + RUNTIME + body +
          f"\nABI = {json.dumps(abi)}\n\nPTX = r\"\"\"{ptx}\"\"\"\n")
    if "stream" in py.lower():
        raise ValueError(f"{out_name}: forbidden substring 'stream'")
    out = HERE / out_name
    out.write_text(py, encoding="utf-8")
    print(f"Wrote {out.name} ({len(py.splitlines())} lines)")
    return out


def build_all() -> None:
    print("Building conv2d_v2 submissions ...")
    make_submission("crisp_conv2d_beauty.py",
                    "conv2d_v2 BEAUTY: one thread per output element, summed in the order the GPU's cuDNN "
                    "reference sums (one FMA chain on H100; short row / channel sums where cuDNN uses FFT)",
                    "conv2d_beauty.crisp", BEAUTY, BEAUTY_KERNELS)
    make_submission("diag_conv2d_accuracy.py", "conv2d_v2 ACCURACY DIAGNOSTIC (beauty kernel vs cuDNN vs float64)",
                    "conv2d_beauty.crisp", BEAUTY + ACCURACY_DIAG, BEAUTY_KERNELS)
    make_submission("crisp_conv2d_tiled.py",
                    "conv2d_v2 v1 (H100 lane): register-tiled direct convolution, 8 channels x 4 pixels per thread, "
                    "staged in shared memory per (ci, ky); cuDNN's (ci, ky, kx) FMA order kept per output",
                    "conv2d_tiled.crisp", tiled_body("conv_tiled"), TILED_KERNELS)
    make_submission("crisp_conv2d_tiled8.py",
                    "conv2d_v2 v2 (H100 lane): as v1 with 8 channels x 8 pixels per thread (8 x 64 pixel patches)",
                    "conv2d_tiled.crisp", tiled_body("conv_tiled8"), TILED_KERNELS)
    make_submission("crisp_conv2d_tiled_p.py",
                    "conv2d_v2 v3 (H100 lane): v1 with the (ci, ky) staging pipelined one stage ahead in registers, "
                    "kx unrolled by 4",
                    "conv2d_tiled.crisp", tiled_body("conv_tiled_p"), TILED_KERNELS)
    perf = ("conv2d_tiled.crisp", "conv2d_fft.crisp", "conv2d_fft8.crisp")
    make_submission("crisp_conv2d_perf.py",
                    "conv2d_v2 PERFORMANT: per GPU, the method its cuDNN reference allows -- an FFT convolution "
                    "(overlap-save, 64 x 64 tiles) where cuDNN itself uses FFT (A100), else the register-tiled "
                    "direct convolution that keeps cuDNN's (ci, ky, kx) FMA chain bit for bit",
                    perf, TILED_COMMON + FFT_COMMON + PERF_ENTRY, TILED_KERNELS + FFT_KERNELS)
    make_submission("diag_conv2d_fft.py", "conv2d_v2 FFT TIMING DIAGNOSTIC (per stage, vs cuDNN, one runner)",
                    perf, TILED_COMMON + FFT_COMMON + FFT_TIMING_DIAG, TILED_KERNELS + FFT_KERNELS)
    make_submission("diag_conv2d_timing.py", "conv2d_v2 TIMING DIAGNOSTIC (cuDNN vs tiled kernels, one runner)",
                    "conv2d_tiled.crisp", TIMING_DIAG, TILED_KERNELS)
    make_submission("diag_conv2d_orders.py", "conv2d_v2 ORDER DIAGNOSTIC (which FMA chain reproduces cuDNN fp32)",
                    "conv2d_orders.crisp", ORDER_DIAG, ORDER_KERNELS)
    make_submission("diag_conv2d_orders_lite.py", "conv2d_v2 ORDER DIAGNOSTIC, light (scored case, chain only)",
                    "conv2d_orders.crisp", ORDER_LITE_DIAG, ORDER_KERNELS)


# ------------------------------------------------------------------------------------------------
# popcorn
# ------------------------------------------------------------------------------------------------

def submit_popcorn(py_file: Path, gpu: str, mode: str) -> str:
    cmd = [str(_popcorn_cli()), "submit", str(py_file), "--gpu", gpu, "--leaderboard", LEADERBOARD,
           "--mode", mode, "--no-tui"]
    print("Running:", " ".join(cmd))
    res = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=1900)
    log = HERE / "_build" / f"popcorn_{py_file.stem}_{gpu}_{mode}.log"
    log.parent.mkdir(exist_ok=True)
    log.write_text(res.stdout + "\n" + res.stderr, encoding="utf-8")
    print(f"popcorn exit {res.returncode}; log {log}")
    record_run(res.stdout, gpu, py_file.name, mode)
    return res.stdout + "\n" + res.stderr     # popcorn prints a 429's "Try again in Ns" on stderr


RESULTS_HEADER = {
    "problem": "conv2d_v2",
    "title": "GPU MODE Challenge 08: 2-D convolution (fp32; 256x256, K=32, 128 channels, batch 1 scored)",
    "leaderboard_id": 537,
    "leaderboard_url": "https://www.gpumode.com/leaderboard/537?tab=rankings",
    "workload": {
        "description": "Y = conv2d(X, W), no padding, stride 1, fp32, checked at rtol = atol = 1e-3 against cuDNN with "
                       "TF32 disabled.  task.yml lists 5 benchmarks; kernelbot ranks by RankCriterion.LAST, so the "
                       "score is the LAST case only: size 256, kernelsize 32, channels 128, batch 1 (seed 6252) -- "
                       "225x225x128 outputs, each a 131,072-term dot product: 1.699 TFLOP as a direct convolution.",
        "total_flops": 2 * 128 * 225 * 225 * 128 * 32 * 32,
    },
}


def record_run(stdout: str, gpu: str, file_name: str, mode: str) -> None:
    """Append the run to results/conv2d_v2.json in report.py's run schema.  A rate-limited (429) or failed
    submission has no id and is not recorded."""
    m_sub = re.search(r'"submission_id":\s*(\d+)', stdout) or re.search(r"[Ss]ubmission\s+(\d+)", stdout)
    if not m_sub or "429" in stdout:
        print("Not recorded (no submission id)")
        return
    scale = {"µs": 1.0, "us": 1.0, "ms": 1000.0, "s": 1e6}
    means = [round(float(m.group(1)) * scale[m.group(3)], 2)
             for m in re.finditer(r"⏱[ \t]*([0-9.]+)[ \t]*±[ \t]*([0-9.]+)[ \t]*(µs|us|ms|s)(?![a-z])", stdout)]
    m_pub = re.search(r"Geomean score \(public\)[^:]*:\s*([0-9.eE+-]+)\s*s", stdout)
    m_sec = re.search(r"Geomean score \(secret\)[^:]*:\s*([0-9.eE+-]+)\s*s", stdout)
    data = json.loads(RESULTS_JSON.read_text(encoding="utf-8")) if RESULTS_JSON.exists() else dict(RESULTS_HEADER)
    data.setdefault("runs", []).append({
        "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "gpu": gpu, "kernel_key": Path(file_name).stem, "file_name": file_name, "mode": mode,
        "submission_id": int(m_sub.group(1)),
        "benchmark_mean_us": means[-1] if means else None, "benchmark_std_us": None,
        "benchmark_best_us": None, "benchmark_worst_us": None, "per_case_us": means or None,
        "public_score_us": round(float(m_pub.group(1)) * 1e6, 2) if m_pub else None,
        "secret_score_us": round(float(m_sec.group(1)) * 1e6, 2) if m_sec else None,
    })
    RESULTS_JSON.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Recorded run in {RESULTS_JSON.name}")


if __name__ == "__main__":
    build_all()
    if len(sys.argv) >= 4:
        submit_popcorn(HERE / sys.argv[1], gpu=sys.argv[2], mode=sys.argv[3])
