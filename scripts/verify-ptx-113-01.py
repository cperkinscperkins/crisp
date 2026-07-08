#!/usr/bin/env python3
"""
First runtime verification of Crisp PTX output, on real NVIDIA hardware.

Loads the PTX compiled from
  tests/spec/113-async-load-tile-store-tile/01-request-load-tile-at-1d.crisp
launches it with a simple ulong input vector, and verifies that the
output equals the input -- the kernel copies V[0..3] through a local
tile using cp.async + cp.async.commit_group + cp.async.wait_group,
then a workgroup-stride loop writes the tile back to OUT.

Exercises end-to-end:
  - Endeavor 114 Phase B.1 (cp.async PTX codegen)
  - Endeavor 115 Phase 1  (PTX %tid.x / %ntid.x dispatch for GPU built-ins)
  - Endeavor 115 Phase 1.5 (kernel-entry shared-pointer demotion)
  - Crisp's PTX backend in general (first real-hardware test)

Usage on a RunPod Ampere+ pod (or any sm_80+ CUDA host):
  pip install pycuda numpy   # if not already
  python verify-ptx-113-01.py <path-to-01-request-load-tile-at-1d.ptx>

What this script does (in order, all failures surfaced early):
  1. Reads the .ptx file and sanity-greps for cp.async markers.
  2. Detects the actual GPU's compute capability via pycuda.
  3. Pre-validates the kernel entry signature: refuses to launch if any
     param is `.ptr .shared` / `.ptr .local` (these are the CUDA-driver-
     rejection cases — fail with a clear message instead of the opaque
     "device kernel image is invalid" you'd otherwise get).
  4. Tries to find ptxas on PATH (or in /usr/local/cuda*/bin) and
     ahead-of-time-assembles the PTX for the detected sm_XX into a
     cubin in /tmp, so we bypass pycuda's runtime JIT.  If ptxas isn't
     available we fall back to JIT and let pycuda's driver-side compile
     have a shot.
  5. Launches the kernel, copies the output back, asserts V == OUT.

Expected output (last line):
  PASS
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

import numpy as np
import pycuda.driver as drv
import pycuda.autoinit  # noqa: F401 -- side effect: initialises CUDA context


CP_ASYNC_MARKERS = (
    "cp.async.ca.shared.global",
    "cp.async.commit_group",
    "cp.async.wait_group",
)


def detect_compute_capability():
    """Returns the device's compute capability as a string like 'sm_89'."""
    dev = pycuda.autoinit.device
    major, minor = dev.compute_capability()
    return f"sm_{major}{minor}"


def find_ptxas():
    """Returns the absolute path to ptxas, or None if not found.
    Looks on PATH first, then in /usr/local/cuda*/bin (covers RunPod images
    that ship the CUDA toolkit but don't put it on PATH by default)."""
    on_path = shutil.which("ptxas")
    if on_path:
        return on_path
    import glob
    for candidate in sorted(glob.glob("/usr/local/cuda*/bin/ptxas"), reverse=True):
        if os.access(candidate, os.X_OK):
            return candidate
    return None


def precheck_no_illegal_kernel_param_pointers(ptx_text):
    """Greps the .entry signature for `.ptr .shared` / `.ptr .local`.
    CUDA driver rejects any kernel image with these on entry params,
    producing the opaque `device kernel image is invalid` error at load.
    Fail early with a clear message instead.
    Returns (ok, [list_of_bad_lines])."""
    in_entry = False
    bad = []
    for ln in ptx_text.splitlines():
        stripped = ln.lstrip()
        if stripped.startswith(".visible .entry") or stripped.startswith(".entry"):
            in_entry = True
            continue
        if in_entry:
            if stripped.startswith(")"):
                in_entry = False
                continue
            if re.search(r"\.ptr\s+\.(shared|local)\b", stripped):
                bad.append(stripped.rstrip(","))
    return (len(bad) == 0, bad)


def assemble_ptx_to_cubin(ptxas, ptx_path, sm_target, out_path):
    """ptxas -arch=<sm_target> <ptx_path> -o <out_path>.
    Raises RuntimeError on failure with ptxas's stderr."""
    proc = subprocess.run(
        [ptxas, f"-arch={sm_target}", ptx_path, "-o", out_path],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"ptxas failed (rc={proc.returncode}):\n"
            f"  cmd: {ptxas} -arch={sm_target} {ptx_path} -o {out_path}\n"
            f"  stdout: {proc.stdout}\n"
            f"  stderr: {proc.stderr}"
        )
    return out_path


def load_module(ptx_path, ptx_text, sm_target):
    """Tries ptxas-then-cuModuleLoad (cleanest error path).  Falls back
    to PTX-via-JIT if ptxas isn't on the system."""
    ptxas = find_ptxas()
    if ptxas:
        cubin_path = tempfile.mktemp(suffix=".cubin")
        print(f"  ptxas: {ptxas}")
        print(f"  assembling for {sm_target} -> {cubin_path}")
        assemble_ptx_to_cubin(ptxas, ptx_path, sm_target, cubin_path)
        return drv.module_from_file(cubin_path)
    print("  ptxas not found; falling back to pycuda JIT")
    return drv.module_from_buffer(ptx_text.encode("utf-8"))


def main(ptx_path):
    print(f"Loading PTX from {ptx_path}")
    with open(ptx_path, "r") as f:
        ptx_text = f.read()

    for marker in CP_ASYNC_MARKERS:
        if marker not in ptx_text:
            print(f"FAIL: PTX missing expected instruction '{marker}'",
                  file=sys.stderr)
            return 2

    ok, bad_lines = precheck_no_illegal_kernel_param_pointers(ptx_text)
    if not ok:
        print("FAIL: PTX entry signature contains illegal kernel-param "
              "pointers (`.ptr .shared` / `.ptr .local`).",
              file=sys.stderr)
        print("      CUDA driver rejects these — would produce "
              "`device kernel image is invalid` at load.",
              file=sys.stderr)
        print("      Crisp's PTX kernel-entry demoter "
              "(Endeavor 115 Phase 1.5) should catch these.",
              file=sys.stderr)
        for ln in bad_lines:
            print(f"        > {ln}", file=sys.stderr)
        return 3

    sm_target = detect_compute_capability()
    print(f"Device compute capability: {sm_target}")
    module = load_module(ptx_path, ptx_text, sm_target)
    kernel = module.get_function("rltc_basic_1d")

    # 4-element ulong vector through a 4-element local tile.
    N = 4
    h_V = np.array([100, 200, 300, 400], dtype=np.uint64)
    h_OUT = np.zeros(N, dtype=np.uint64)

    d_V = drv.mem_alloc(h_V.nbytes)
    d_OUT = drv.mem_alloc(h_OUT.nbytes)
    drv.memcpy_htod(d_V, h_V)
    drv.memcpy_htod(d_OUT, h_OUT)

    # The kernel takes 18 .u64 params: a 6-tuple per tensor descriptor
    # (parent ptr, parent byte_size, offset, stride[0], extent[0], length)
    # for tile (shared), V (global), OUT (global), in that order.
    #
    # Crisp packs every tensor parameter as 6 .u64 params at the kernel
    # boundary; the shared tile parameter slot expects a dyn-shared
    # offset (0 here -- we allocate 32 bytes of dyn-shared at launch
    # below, and the kernel reads/writes at offsets 0..31).
    BYTE_SIZE = N * 8  # 32

    args = [
        # Tile (params 0-5): shared ptr offset, byte_size, offset, stride, extent, length
        np.uint64(0),
        np.uint64(BYTE_SIZE),
        np.uint64(0),
        np.uint64(1),
        np.uint64(N),
        np.uint64(N),
        # V (params 6-11): device ptr, byte_size, offset, stride, extent, length
        np.uint64(int(d_V)),
        np.uint64(BYTE_SIZE),
        np.uint64(0),
        np.uint64(1),
        np.uint64(N),
        np.uint64(N),
        # OUT (params 12-17): same shape
        np.uint64(int(d_OUT)),
        np.uint64(BYTE_SIZE),
        np.uint64(0),
        np.uint64(1),
        np.uint64(N),
        np.uint64(N),
    ]

    # global_size = 4, local_size = 4  =>  grid=(1,1,1), block=(4,1,1).
    # shared= BYTE_SIZE allocates the tile's dyn-shared region.
    kernel(*args, grid=(1, 1, 1), block=(N, 1, 1), shared=BYTE_SIZE)
    drv.Context.synchronize()

    drv.memcpy_dtoh(h_OUT, d_OUT)

    print(f"V   = {h_V}")
    print(f"OUT = {h_OUT}")
    if np.array_equal(h_V, h_OUT):
        print("PASS")
        return 0
    else:
        print("FAIL: OUT does not match V")
        return 1


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <path-to-ptx>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
