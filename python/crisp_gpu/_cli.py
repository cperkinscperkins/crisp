"""Console entry points: `crisp-compile` (and the hoist programs) on PATH, running the binaries in
crisp_gpu/bin/.  The compiler finds libLLVM, llc and the hoist programs beside itself, so it can be
run from any directory."""
import os
import subprocess
import sys

from . import bin_dir, _prepare_bin, _EXE


def _run(name):
    exe = os.path.join(bin_dir(), name + _EXE)
    if not os.path.exists(exe):
        hint = " (pip install crisp-gpu-hoist)" if name.startswith("crisp-hoist") else ""
        sys.exit(f"crisp_gpu: {exe} is missing{hint}")
    _prepare_bin()
    args = [exe] + sys.argv[1:]
    if sys.platform == "win32":
        sys.exit(subprocess.call(args))
    os.execv(exe, args)


def crisp_compile():
    _run("crisp-compile")


def crisp_hoist_cuda():
    _run("crisp-hoist-cuda")


def crisp_hoist_l0():
    _run("crisp-hoist-l0")
