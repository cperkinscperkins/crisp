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


def compile_crisp(crisp: str, kernels, arch: str = "sm_80") -> tuple[str, dict[str, str]]:
    """PTX text and {kernel: CUDA hoist text}.  Run from the repo root (crisp-compile finds its DLLs there)."""
    build = HERE / "_build"
    build.mkdir(exist_ok=True)
    src = build / crisp
    src.write_text((HERE / crisp).read_text(encoding="utf-8"), encoding="utf-8")
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

# The GPUs whose fp32 cuDNN reference is ONE sequential FMA chain (implicit_convolve_sgemm), measured by
# diag_conv2d_orders.py: there only cuDNN's own summation order passes.  Everywhere else the reference is
# an FFT, accurate to ~1e-4, and the accurate kernel is the one that passes.
_CUDNN_ORDER_CC = {(9, 0)}          # H100


def custom_kernel(data: input_t) -> output_t:
    x, w, out = data
    if _lib is None:
        _init()
    B, C, H, _ = x.shape
    K = w.shape[2]
    n = out.numel()
    k = ("conv2d_cudnn_order" if torch.cuda.get_device_capability() in _CUDNN_ORDER_CC
         else "conv2d_accurate")
    P = lambda t: t.data_ptr()
    _launch(k, (n + 255) // 256, {"x": (P(x), x.numel()), "w": (P(w), w.numel()),
                                  "dims": (P(_dims(C, H, K)), 3), "y": (P(out), n)})
    return out
'''


# ------------------------------------------------------------------------------------------------
# Tiled (H100 lane): w_transpose + conv_tiled (conv2d_tiled.crisp)
# ------------------------------------------------------------------------------------------------
TILED_KERNELS = ("w_transpose", "conv_tiled")
TILED = r'''

_WT = {}
def custom_kernel(data: input_t) -> output_t:
    x, w, out = data
    if _lib is None:
        _init()
    B, C, H, _ = x.shape
    K = w.shape[2]
    O = H - K + 1
    nw = w.numel()
    wt = _WT.get(nw)
    if wt is None:
        wt = _WT[nw] = torch.empty(nw, dtype=torch.float32, device="cuda")
    dims = _dims(C, H, K, B)
    P = lambda t: t.data_ptr()
    _launch("w_transpose", ((C + 31) // 32) * ((nw // C + 31) // 32), {"w": (P(w), nw), "dims": (P(dims), 4), "wt": (P(wt), nw)})
    groups = B * ((C + 31) // 32) * ((O + 7) // 8) * ((O + 31) // 32)
    _launch("conv_tiled", groups, {"x": (P(x), x.numel()), "wt": (P(wt), nw), "dims": (P(dims), 4),
                                   "y": (P(out), out.numel())})
    return out
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
          f"# --- {crisp} ---\n{commented(HERE / crisp)}\n"
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
                    "conv2d_tiled.crisp", TILED, TILED_KERNELS)
    make_submission("diag_conv2d_orders.py", "conv2d_v2 ORDER DIAGNOSTIC (which FMA chain reproduces cuDNN fp32)",
                    "conv2d_orders.crisp", ORDER_DIAG, ORDER_KERNELS)


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
