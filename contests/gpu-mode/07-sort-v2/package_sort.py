#!/usr/bin/env python3
"""
Crisp -> GPU MODE submission packager & runner for sort_v2 (leaderboard #542).

Compiles the Crisp radix sort to PTX with `crisp-compile --hoist=cuda`, reads each kernel's parameter
ABI out of the generated CUDA launchers (parameter order, scratch literals, dynamic shared memory), and
writes one self-contained GPU MODE Python submission.

The submission loads the PTX with the CUDA DRIVER API through ctypes alone (cuModuleLoadData /
cuLaunchKernel on libcuda.so.1): no load_inline, so nothing is compiled on the judge.  Every Crisp
kernel parameter is a u64 (a vector is ptr, byte_size, off0, str0, ext0, length), so one ctypes u64
array per launch covers the whole ABI.  Decision D-200-3 in tests/spec/200-sort-contest/sort-contest.md.

Usage:
    python package_sort.py                       # build every submission .py
    python package_sort.py <py> <GPU> <mode>     # build, then submit one via popcorn-cli
"""

from __future__ import annotations

import datetime
import json
import os
import re
import subprocess
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = Path(__file__).resolve().parent
REPO_ROOT = Path(__file__).resolve().parents[3]
CRISP_COMPILE = REPO_ROOT / "bin" / "crisp-compile.exe"
RESULTS_JSON = REPO_ROOT / "contests" / "gpu-mode" / "results" / "sort_v2.json"
KERNELS = ("sort_minmax", "sort_upsweep", "sort_digit_scan", "sort_downsweep")
FIELDS = ("ptr", "byte_size", "off0", "str0", "ext0", "length")


def _popcorn_cli() -> Path:
    for p in (Path(os.environ["POPCORN_CLI"]) if os.environ.get("POPCORN_CLI") else None,
              REPO_ROOT / "contests" / "gpu-mode" / "bin" / "popcorn-cli.exe",
              REPO_ROOT.parent / "crisp" / "contests" / "gpu-mode" / "bin" / "popcorn-cli.exe"):
        if p and p.exists():
            return p
    raise FileNotFoundError("popcorn-cli.exe not found (set POPCORN_CLI)")


def compile_crisp(crisp: str, arch: str = "sm_80", kernels=KERNELS) -> tuple[str, dict[str, str]]:
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


SIZEOF = {"unsigned int": 4, "int": 4, "float": 4, "uint64_t": 8, "int64_t": 8, "double": 8}
CELL_FIELDS = ("ptr", "size_bytes", "offset")


def parse_abi(kernel: str, hoist: str) -> dict:
    """{params: [int literal | [tensor, field] | ["@scratch", name, field]], scratch, smem, block} -- never
    hardcoded: the compiler orders the scratch vectors first, in an order that is not the binding order.

    Endeavour 201: the compiler's own GLOBAL scratch (a look-back's status words, a ticket counter, ...) is
    not a caller tensor, so the runtime allocates it -- zeroed once, as the hoist does.  scratch maps its
    name to {bytes: element size, n: fixed element count, or per: elements per WORKGROUP (n = groups * per)
    for the grid-sized kinds, :match-num-workgroups (per 1) and :match-global-size (per = block)}."""
    m = re.search(r'cuModuleGetFunction\(&kernel,\s*module,\s*"(\w+)"\)', hoist)
    if m.group(1) != kernel:
        raise ValueError(f"hoist names {m.group(1)}, expected {kernel}")
    m = re.search(r"void\*\s+kernelParams\[\d+\]\s*=\s*\{(.*?)\};", hoist, flags=re.DOTALL)
    names = re.findall(r"&(\w+)", m.group(1))
    tensors = set(re.findall(r"CUdeviceptr\s+(\w+)_ptr;", hoist))
    lits = dict(re.findall(r"uint64_t\s+(\w+)\s*=\s*(\d+)(?:ULL)?\s*;", hoist))   # a local cell's offset has no ULL
    # a workgroup-local cell's size: `uint64_t X_size_bytes = 1 * sizeof(uint64_t);`
    sized = {nm: int(c) * SIZEOF[t] for nm, c, t in
             re.findall(r"uint64_t\s+(\w+)\s*=\s*(\d+)\s*\*\s*sizeof\(([\w ]+)\)\s*;", hoist)}
    scratch = {}
    # a global scratch CELL: allocated and zeroed in the launcher; args ptr, size_bytes, offset
    for b, c, t in re.findall(r"size_t\s+(\w+)_size\s*=\s*(\d+);\s*CUdeviceptr\s+\1_ptr;\s*"
                              r"CUDA_CHECK\(cuMemAlloc\(&\1_ptr,\s*\1_size \* sizeof\(([\w ]+)\)\)\);", hoist):
        scratch[b] = {"bytes": SIZEOF[t], "n": int(c)}
    # a GRID-sized global scratch vector (181 / 201): sized at the launch anchor from gridX * gridY * gridZ
    for b, per in re.findall(r"(\w+)_length = \(uint64_t\)gridX \* gridY \* gridZ(?: \* (\d+)ULL)?;", hoist):
        eb = re.search(rf"{b}_byte_size = {b}_length \* (\d+)ULL;", hoist)
        scratch[b] = {"bytes": int(eb.group(1)), "per": int(per or 1)}
    params = []
    for nm in names:
        t, _, f = nm.rpartition("_")
        if f in ("size",):                      # byte_size
            t, f = nm[: -len("_byte_size")], "byte_size"
        cb = next((nm[: -len(cf) - 1] for cf in CELL_FIELDS if nm.endswith("_" + cf)), None)
        if t in scratch and "per" in scratch[t] and f in FIELDS:      # before lits: its fields are 0ULL placeholders
            params.append(["@scratch", t, f])
        elif cb in scratch and "n" in scratch[cb]:
            params.append(["@scratch", cb, nm[len(cb) + 1:]])
        elif t in tensors and f in FIELDS:
            params.append([t, f])
        elif nm in lits:
            params.append(int(lits[nm]))
        elif nm in sized:
            params.append(sized[nm])
        else:
            raise ValueError(f"{kernel}: parameter {nm} is neither a runtime tensor field nor a literal")
    m = re.search(r"cuLaunchKernel\(kernel,\s*gridX,\s*gridY,\s*gridZ,\s*(\d+),\s*\d+,\s*\d+,\s*(\d+),", hoist)
    return {"params": params, "block": int(m.group(1)), "smem": int(m.group(2)), "tensors": sorted(tensors),
            "scratch": scratch}


def commented(path: Path) -> str:
    return "\n".join("# " + l if l.strip() else "#" for l in path.read_text(encoding="utf-8").splitlines())


RUNTIME = r'''
import ctypes as _C
import torch
from task import input_t, output_t

_TILE = 4096          # keys per workgroup in sort_upsweep / sort_downsweep (the .crisp's tile)
_lib = None
_fn = {}
_args = {}            # launch-argument cache: (kernel, tensor pointers) -> (u64 array, void* array)
_bufs = {}            # per-n scratch buffers


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


_scr = {}            # the compiler's global scratch: (kernel, name) -> zeroed buffer, kept for the run
_scr_old = []        # outgrown buffers stay alive -- a cached launch for fewer groups still points at them


def _scratch(k, name, n, eb):
    """A zeroed device buffer of N elements of EB bytes for kernel K's implicit global scratch NAME.  Zeroed
    ONCE (the hoist's contract): the kernel resets / re-tags its own state between launches.  More groups
    than before get a fresh, larger, zeroed buffer."""
    t = _scr.get((k, name))
    if t is None or t.numel() < n * eb:
        if t is not None:
            _scr_old.append(t)
        t = _scr[(k, name)] = torch.zeros(n * eb, dtype=torch.uint8, device="cuda")
    return t.data_ptr()


def _launch(k, groups, tensors):
    """tensors: Crisp tensor name -> (pointer, element count[, element bytes, default 4])."""
    key = (k, groups, tuple(sorted(tensors.items())))
    a = _args.get(key)
    if a is None:
        vals = []
        for p in ABI[k]["params"]:
            if isinstance(p, int):
                vals.append(p)
            elif p[0] == "@scratch":
                s = ABI[k]["scratch"][p[1]]
                n = s["n"] if "n" in s else groups * s["per"]
                vals.append({"ptr": _scratch(k, p[1], n, s["bytes"]), "byte_size": n * s["bytes"],
                             "size_bytes": n * s["bytes"], "off0": 0, "offset": 0, "str0": 1,
                             "ext0": n, "length": n}[p[2]])
            else:
                ptr, n, *es = tensors[p[0]]
                vals.append({"ptr": ptr, "byte_size": (es[0] if es else 4) * n, "off0": 0, "str0": 1, "ext0": n, "length": n}[p[1]])
        u = (_C.c_uint64 * len(vals))(*vals)
        v = (_C.c_void_p * len(vals))(*[_C.addressof(u) + 8 * i for i in range(len(vals))])
        a = _args[key] = (u, v)
    _ck(_lib.cuLaunchKernel(_fn[k], groups, 1, 1, ABI[k]["block"], 1, 1, ABI[k]["smem"], None, a[1], None),
        "launch " + k)
    if _EV is not None:                                 # diagnostics only: an event after every launch
        e = torch.cuda.Event(enable_timing=True)
        e.record()
        _EV.append((k, e))


_EV = None


_PRM = {}
def _prm(passes):
    """Per-pass [shift, first, last] rows, one device tensor per pass count (made once)."""
    t = _PRM.get(passes)
    if t is None:
        rows = [[8 * i, int(i == 0), int(i == passes - 1)] for i in range(passes)]
        t = _PRM[passes] = torch.tensor(rows, dtype=torch.int32, device="cuda")
    return t


def custom_kernel(data: input_t) -> output_t:
    x, out = data
    n = x.numel()
    if _lib is None:
        _init()
    nb = (n + _TILE - 1) // _TILE
    b = _bufs.get(n)
    if b is None:
        b = _bufs[n] = dict(tmp=torch.empty(n, dtype=torch.float32, device="cuda"),
                            hist=torch.empty(256 * nb, dtype=torch.int32, device="cuda"),
                            scanned=torch.empty(256 * nb, dtype=torch.int32, device="cuda"),
                            totals=torch.empty(256, dtype=torch.int32, device="cuda"),
                            mm=torch.empty(2, dtype=torch.int32, device="cuda"),
                            mm0=torch.tensor([-1, 0], dtype=torch.int32, device="cuda"))
    mm = b["mm"]
    mm.copy_(b["mm0"])                                  # kmin <- ~0, kmax <- 0
    P = lambda t: t.data_ptr()
    _launch("sort_minmax", min(nb, 1024), {"input": (P(x), n), "mm": (P(mm), 2)})
    lo, hi = (v & 0xFFFFFFFF for v in mm.tolist())     # the one host sync: it decides the pass count
    passes = ((hi - lo).bit_length() + 7) // 8
    if passes == 0:
        out.copy_(x)
        return out
    prm = _prm(passes)
    hist, scanned, totals, tmp = b["hist"], b["scanned"], b["totals"], b["tmp"]
    src = x
    for i in range(passes):
        dst = out if (passes - 1 - i) % 2 == 0 else tmp
        pr = (P(prm) + 12 * i, 3)
        _launch("sort_upsweep", nb, {"src": (P(src), n), "mm": (P(mm), 2), "prm": pr, "hist": (P(hist), 256 * nb)})
        _launch("sort_digit_scan", 256, {"hist": (P(hist), 256 * nb), "scanned": (P(scanned), 256 * nb),
                                         "totals": (P(totals), 256)})
        _launch("sort_downsweep", nb, {"src": (P(src), n), "mm": (P(mm), 2), "prm": pr,
                                       "scanned": (P(scanned), 256 * nb), "totals": (P(totals), 256),
                                       "dst": (P(dst), n)})
        src = dst
    return out
'''


def make_submission(out_name: str, title: str, crisp: str, extra: str = "", kernels=KERNELS) -> Path:
    ptx, hoists = compile_crisp(crisp, kernels=kernels)
    abi = {}
    for k in kernels:
        a = parse_abi(k, hoists[k])
        print(f"  {k}: params={len(a['params'])} block={a['block']} smem={a['smem']} tensors={a['tensors']}"
              f" scratch={a['scratch']}")
        abi[k] = {"params": a["params"], "block": a["block"], "smem": a["smem"], "scratch": a["scratch"]}
    py = (f"#!POPCORN leaderboard sort_v2\n# {title}\n#\n"
          "# Generated by contests/gpu-mode/07-sort-v2/package_sort.py from Crisp source.  The kernels are Crisp,\n"
          "# compiled to PTX by crisp-compile; this file only loads that PTX with the CUDA driver API and launches it.\n"
          "#\n# Crisp source:\n# -------------------------------------------------------------------------\n"
          f"# --- {crisp} ---\n{commented(HERE / crisp)}\n"
          "# -------------------------------------------------------------------------\n"
          + RUNTIME + extra +
          f"\nABI = {json.dumps(abi)}\n\nPTX = r\"\"\"{ptx}\"\"\"\n")
    if "stream" in py.lower():
        raise ValueError(f"{out_name}: forbidden substring 'stream'")
    out = HERE / out_name
    out.write_text(py, encoding="utf-8")
    print(f"Wrote {out.name} ({len(py.splitlines())} lines)")
    return out


DIAG = r'''

# ---- diagnostic: popcorn --mode test; the per-launch table comes back as the RuntimeError ----
_real_kernel = custom_kernel
_diag_done = False
def custom_kernel(data):
    global _diag_done, _EV
    x, out = data
    if _diag_done or x.numel() != 4096:
        return _real_kernel(data)
    _diag_done = True
    lines = []
    def occ():
        r = []
        for k in ABI:
            nb_ = _C.c_int()
            _ck(_lib.cuOccupancyMaxActiveBlocksPerMultiprocessor(_C.byref(nb_), _fn[k], 256, ABI[k]["smem"]), "occ")
            regs = _C.c_int(); _lib.cuFuncGetAttribute(_C.byref(regs), 4, _fn[k])
            r.append(f"{k[5:]}: {nb_.value} blocks/SM, {regs.value} regs")
        return "; ".join(r)
    for carve in (None,):
        if carve is not None:
            for k in ABI:
                _ck(_lib.cuFuncSetAttribute(_fn[k], 9, carve), "carveout")   # 9 = PREFERRED_SHARED_MEMORY_CARVEOUT
        lines.append(f"carveout={carve}: {occ()}")
        lines += _diag_sizes(((100_000_000, 6252),) if carve is not None else
                             ((100_000_000, 6252), (10_000_000, 8841), (1_000_000, 6256)))
    raise RuntimeError("DIAG\n" + "\n".join(lines))


def _diag_sizes(cases):
    global _EV
    lines = []
    for n, seed in cases:
        rows = int(n ** 0.5); cols = (n + rows - 1) // rows
        g = torch.Generator(device="cuda"); g.manual_seed(seed)
        big = (torch.randn(rows, cols, device="cuda", generator=g)
               + torch.arange(rows, device="cuda", dtype=torch.float32)[:, None] + seed).flatten()[:n].contiguous()
        o = torch.empty_like(big)
        _real_kernel((big, o)); torch.cuda.synchronize()
        ok = torch.equal(o, torch.sort(big)[0])
        walls = []
        for rep in range(3):
            _EV = []
            e0 = torch.cuda.Event(enable_timing=True); e0.record()
            _real_kernel((big, o))
            e1 = torch.cuda.Event(enable_timing=True); e1.record()
            torch.cuda.synchronize()
            ev, _EV = _EV, None
            walls.append(e0.elapsed_time(e1) * 1000)
        prev = e0
        per = []
        for k, e in ev:
            per.append(f"{k[5:]}={prev.elapsed_time(e) * 1000:.0f}")
            prev = e
        lines.append(f"n={n} correct={ok} wall_us={[round(w) for w in walls]} last-rep: " + " ".join(per))
    return lines
'''


DIAG_PROBE = r'''

# ---- probe diagnostic (endeavour 200): time FENCED probe kernels (wrong results by design) at 100M ----
_real_kernel = custom_kernel
_diag_done = False
def custom_kernel(data):
    global _diag_done
    x, out = data
    if _diag_done or x.numel() != 4096:
        return _real_kernel(data)
    _diag_done = True
    mod = _C.c_void_p()
    _ck(_lib.cuModuleLoadData(_C.byref(mod), _C.c_char_p(PTX_PROBE.encode())), "probe module")
    for k, abi in ABI_PROBE.items():
        f = _C.c_void_p()
        _ck(_lib.cuModuleGetFunction(_C.byref(f), mod, k.encode()), k)
        _ck(_lib.cuFuncSetAttribute(f, 8, abi["smem"]), k)
        _fn[k] = f
        ABI[k] = abi
    n, seed = 100_000_000, 6252
    rows = int(n ** 0.5); cols = (n + rows - 1) // rows
    g = torch.Generator(device="cuda"); g.manual_seed(seed)
    big = (torch.randn(rows, cols, device="cuda", generator=g)
           + torch.arange(rows, device="cuda", dtype=torch.float32)[:, None] + seed).flatten()[:n].contiguous()
    o = torch.empty_like(big)
    _real_kernel((big, o)); torch.cuda.synchronize()       # fills mm / hist / scanned / totals
    b = _bufs[n]; nb = (n + _TILE - 1) // _TILE
    P = lambda t: t.data_ptr()
    prm = _prm(3)
    lines = []
    for k in list(ABI_PROBE) + ["sort_downsweep"]:
        ts = []
        for rep in range(4):
            e0 = torch.cuda.Event(enable_timing=True); e1 = torch.cuda.Event(enable_timing=True)
            e0.record()
            _launch(k, nb, {"src": (P(big), n), "mm": (P(b["mm"]), 2), "prm": (P(prm), 3),
                            "scanned": (P(b["scanned"]), 256 * nb), "totals": (P(b["totals"]), 256),
                            "dst": (P(b["tmp"]), n)})
            e1.record(); torch.cuda.synchronize()
            ts.append(round(e0.elapsed_time(e1) * 1000))
        lines.append(f"{k}: {ts} us")
    raise RuntimeError("DIAG-PROBE\n" + "\n".join(lines))
'''


def make_probe_diag(out_name: str, probe_crisp: Path) -> Path:
    """The v1 submission + DIAG_PROBE + the probe module (compiled from PROBE_CRISP, outside the contest dir)."""
    res = subprocess.run([str(CRISP_COMPILE), "--ir-target=ptx", "--ir-target-arch=sm_80", "--hoist=cuda",
                          str(probe_crisp)], cwd=str(REPO_ROOT), capture_output=True, text=True)
    if res.returncode != 0 or "compilation failed" in (res.stdout + res.stderr):
        raise RuntimeError(f"probe compile failed:\n{res.stdout}\n{res.stderr}")
    ptx = probe_crisp.with_suffix(".ptx").read_text(encoding="utf-8")
    abi = {}
    for h in sorted(probe_crisp.parent.glob(f"{probe_crisp.stem}_*_CUDA.cu")):
        k = h.name[len(probe_crisp.stem) + 1:-len("_CUDA.cu")]
        a = parse_abi(k, h.read_text(encoding="utf-8"))
        abi[k] = {"params": a["params"], "block": a["block"], "smem": a["smem"]}
    extra = DIAG_PROBE + f"\nABI_PROBE = {json.dumps(abi)}\n\nPTX_PROBE = r\"\"\"{ptx}\"\"\"\n"
    return make_submission(out_name, "sort_v2 PROBE DIAGNOSTIC (fenced probe kernels, timing only)",
                           "sort_radix.crisp", extra)


ONESWEEP_KERNELS = ("sort_minmax_hist", "sort_onesweep")

# Replaces the radix custom_kernel: sort_minmax_hist, then ONE sort_onesweep launch per pass.
ONESWEEP = r'''

_PRMT = {}
def _prm_table(passes):
    # rows [shift, first, last, pass], one per pass: made once, so no per-call upload.  The look-back's
    # status words, epoch and ticket are the compiler's (implicit scratch, see _scratch).
    t = _PRMT.get(passes)
    if t is None:
        rows = [[8 * i, int(i == 0), int(i == passes - 1), i] for i in range(passes)]
        t = _PRMT[passes] = torch.tensor(rows, dtype=torch.int32, device="cuda")
    return t


def custom_kernel(data: input_t) -> output_t:
    x, out = data
    n = x.numel()
    if _lib is None:
        _init()
    nb = (n + _TILE - 1) // _TILE
    b = _bufs.get(n)
    if b is None:
        b = _bufs[n] = dict(tmp=torch.empty(n, dtype=torch.float32, device="cuda"),
                            ghist=torch.zeros(1024, dtype=torch.int32, device="cuda"),
                            mm=torch.empty(2, dtype=torch.int32, device="cuda"),
                            mm0=torch.tensor([-1, 0], dtype=torch.int32, device="cuda"))
    mm, ghist = b["mm"], b["ghist"]
    mm.copy_(b["mm0"])                                  # kmin <- ~0, kmax <- 0
    ghist.zero_()
    P = lambda t: t.data_ptr()
    _launch("sort_minmax_hist", min(nb, 1024), {"input": (P(x), n), "mm": (P(mm), 2), "ghist": (P(ghist), 1024)})
    lo, hi = (v & 0xFFFFFFFF for v in mm.tolist())     # the one host sync: it decides the pass count
    passes = ((hi - lo).bit_length() + 7) // 8
    if passes == 0:
        out.copy_(x)
        return out
    prm = _prm_table(passes)
    src = x
    for i in range(passes):
        dst = out if (passes - 1 - i) % 2 == 0 else b["tmp"]
        _launch("sort_onesweep", nb, {"src": (P(src), n), "prm": (P(prm) + 16 * i, 4),
                                      "dst": (P(dst), n), "mm": (P(mm), 2), "ghist": (P(ghist), 1024)})
        src = dst
    return out
'''


BITONIC_KERNELS = ("bitonic_pad", "bitonic_tiles", "bitonic_global", "bitonic_finish", "bitonic_unpad")

# The beauty entry: plain bitonic sort.  Replaces the radix custom_kernel.
BITONIC = r'''

_STEPS = {}
def _steps(P):
    # the (j, k) launch list for padded size P, and a device table of [j, k] rows (made once)
    s = _STEPS.get(P)
    if s is None:
        rows, k = [], 4096
        while k <= P:
            j = k // 2
            while j >= 2048:
                rows.append(("bitonic_global", j, k)); j //= 2
            rows.append(("bitonic_finish", 1024, k)); k *= 2
        t = torch.tensor([[j, k] for _, j, k in rows] or [[0, 0]], dtype=torch.int32, device="cuda")
        s = _STEPS[P] = (rows, t)
    return s


def custom_kernel(data: input_t) -> output_t:
    x, out = data
    n = x.numel()
    if _lib is None:
        _init()
    P = 2048
    while P < n:
        P *= 2
    b = _bufs.get(P)
    if b is None:
        b = _bufs[P] = torch.empty(P, dtype=torch.float32, device="cuda")
    rows, prm = _steps(P)
    D = lambda m: min(8192, (m + 255) // 256)
    _launch("bitonic_pad", D(P), {"input": (x.data_ptr(), n), "buf": (b.data_ptr(), P)})
    _launch("bitonic_tiles", P // 2048, {"src": (b.data_ptr(), P), "dst": (b.data_ptr(), P)})
    for r, (kname, j, k) in enumerate(rows):
        _launch(kname, D(P // 2) if kname == "bitonic_global" else P // 2048,
                {"src": (b.data_ptr(), P), "prm": (prm.data_ptr() + 8 * r, 2), "dst": (b.data_ptr(), P)})
    _launch("bitonic_unpad", D(n), {"buf": (b.data_ptr(), P), "output": (out.data_ptr(), n)})
    return out
'''


BUILD_ONESWEEP = True


def build_all() -> None:
    print("Building sort_v2 submissions ...")
    make_submission("crisp_sort_beauty.py",
                    "sort_v2 BEAUTY: plain bitonic sort -- compare-and-swap, shared-memory tiles, global merge passes",
                    "sort_bitonic_beauty.crisp", BITONIC, BITONIC_KERNELS)
    make_submission("crisp_sort_v1.py",
                    "sort_v2 v1: LSD radix sort, range-reduced keys (min/max pass), reduce-then-scan, 4096-key tiles",
                    "sort_radix.crisp")
    make_submission("diag_sort_v1.py", "sort_v2 v1 DIAGNOSTIC (per-launch timing at 100M / 10M / 1M)",
                    "sort_radix.crisp", DIAG)
    # sort_onesweep.crisp's look-back is endeavour 201's ordered-workgroup-id + look-back-scan (before that
    # it waited with `while`, which Crisp does not have -- BUG 148).  The switch stays for a quick opt-out.
    if not BUILD_ONESWEEP:
        return
    make_submission("crisp_sort_v2.py",
                    "sort_v2 v2: ONESWEEP LSD radix sort (decoupled look-back), minmax+histogram in one read",
                    "sort_onesweep.crisp", ONESWEEP, ONESWEEP_KERNELS)
    make_submission("diag_sort_v2.py", "sort_v2 v2 DIAGNOSTIC (onesweep, per-launch timing)",
                    "sort_onesweep.crisp", ONESWEEP + DIAG, ONESWEEP_KERNELS)


# ------------------------------------------------------------------------------------------------
# popcorn
# ------------------------------------------------------------------------------------------------

def submit_popcorn(py_file: Path, gpu: str, mode: str) -> str:
    cmd = [str(_popcorn_cli()), "submit", str(py_file), "--gpu", gpu, "--leaderboard", "sort_v2",
           "--mode", mode, "--no-tui"]
    print("Running:", " ".join(cmd))
    res = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=1900)
    log = HERE / "_build" / f"popcorn_{py_file.stem}_{gpu}_{mode}.log"
    log.parent.mkdir(exist_ok=True)
    log.write_text(res.stdout + "\n" + res.stderr, encoding="utf-8")
    print(f"popcorn exit {res.returncode}; log {log}")
    record_run(res.stdout, gpu, py_file.name, mode)
    return res.stdout


def record_run(stdout: str, gpu: str, file_name: str, mode: str) -> None:
    """Append the run to results/sort_v2.json in report.py's run schema.  A rate-limited (429) or failed
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
    data = json.loads(RESULTS_JSON.read_text(encoding="utf-8")) if RESULTS_JSON.exists() else {"runs": []}
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
