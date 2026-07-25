#!/usr/bin/env bash
#
# bench-intel-entrypoint.sh — Entry script that runs inside the Docker
# container.  Builds Crisp, then runs the unified cross-platform matmul
# benchmark driver in Intel mode (scripts/crisp_bench/matmul.py --platform=intel).
#
# Endeavor 143: this replaced the old bench-intel-driver.py (which printed a
# stdout table with no JSON).  matmul.py is the SAME driver the NVIDIA side
# uses — it emits the shared BenchmarkSweep JSON into benchmarks/results/,
# sweeps the precision matrix with explicit flags, and report.py renders a
# `## Hardware: Intel BMG` section from the JSON.
#
# Kept as its own file (rather than inlined into bench-intel.sh) so that
# the host-side wrapper doesn't have to round-trip a multi-line bash -c
# string — both PowerShell and Git Bash mangle that in different ways.
#
# Usage: bench-intel-entrypoint.sh <sizes> <iters> [precision]
#   precision: "all" (default) -> full precision sweep (--sweep-all);
#              "fast" | "ieee"  -> a single precision pass.

set -e

SIZES="${1:-256,512,1024,2048,4096}"
ITERS="${2:-100}"
PRECISION="${3:-all}"

# Activate the oneAPI environment, then extend LD_LIBRARY_PATH to include
# the WSL2 D3D shim libs so the L0 driver can actually open the GPU.
#
# setvars.sh returns non-zero (typically 3) even on success — it's an
# Intel convention for "some components not initialized" warnings (NPU,
# advisor, etc. that aren't installed in this image).  The env vars we
# care about (oneAPI compiler, L0, oneDPL) are set correctly.  Disable
# `set -e` around the source so the script continues.
set +e
. /opt/intel/oneapi/setvars.sh > /dev/null 2>&1
set -e
export LD_LIBRARY_PATH=/usr/lib/wsl/lib:$LD_LIBRARY_PATH
# crisp-compile in the Linux container finds llc / llvm-spirv / llvm-as on PATH
# (the LLVM toolchain), NOT the repo's Windows binaries — same as run-on-pod.sh.
export CRISP_USE_SYSTEM_TOOLS=true

echo '=== Building Crisp inside container ==='
rm -rf /root/.cache/common-lisp
sbcl --non-interactive --load build/build.lisp 2>&1 | tail -8

# Trap a cleanup hook so the Linux ELF binaries the build just dropped into
# bin/ are removed before we exit.  Otherwise they shadow the host's
# Windows .exe binaries on the next native spec-runner invocation, which
# crashes with "is not a valid Win32 application".
trap 'rm -f bin/crisp-compile bin/crisp-hoist-l0 bin/crisp-hoist-cuda 2>/dev/null' EXIT
echo ''

echo "=== Running matmul.py (Intel/BMG) — sizes=${SIZES} iters=${ITERS} precision=${PRECISION} ==="
# --platform=intel: Crisp via SPIR-V/L0 (crisp-compile --hardware-profile=bmg + the L0 fixed harness),
# SYCL_Apples + OneMKL_Optimal via icpx (the CUDA/cuBLAS targets auto-skip — no nvcc here).  JSON lands
# in benchmarks/results/ (bind-mounted -> host), where report.py picks it up.
PREC_FLAG="--sweep-all"
if [ "${PRECISION}" != "all" ]; then PREC_FLAG="--precision=${PRECISION}"; fi
python3 scripts/crisp_bench/matmul.py --platform=intel ${PREC_FLAG} --sizes="${SIZES}" --iters="${ITERS}"
