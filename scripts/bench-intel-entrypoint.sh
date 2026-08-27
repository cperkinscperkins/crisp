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
# Usage: bench-intel-entrypoint.sh <sizes> <iters> [precision] [chapters]
#   precision: "all" (default) -> full precision sweep (--sweep-all);
#              "fast" | "ieee"  -> a single precision pass.
#   chapters:  comma-separated chapter filter passed to matmul.py --chapters;
#              empty (default) runs every chapter.  Use this to refresh a couple of rows
#              without pinning the display GPU for the whole suite.

set -e

# DEFAULT stops at 1024: the BMG is the Windows display GPU here, and a large GEMM pins it long enough
# to freeze the desktop (see bench-intel.sh).  2048/4096 are an explicit opt-in.
SIZES="${1:-256,512,1024}"
ITERS="${2:-100}"
PRECISION="${3:-all}"
CHAPTERS="${4:-}"
# Extra flags passed straight through to matmul.py.  Exists for --scratch, which diagnostic
# chapters (e.g. _probe_roofline) REQUIRE: it routes their JSON to results/scratch/, which
# report.py never reads into a canonical table.  Probe kernels are deliberately wrong.
EXTRA="${5:-}"

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
sbcl --non-interactive --load build/build.lisp

# Trap a cleanup hook so the Linux ELF binaries the build just dropped into
# bin/ are removed before we exit.  Otherwise they shadow the host's
# Windows .exe binaries on the next native spec-runner invocation, which
# crashes with "is not a valid Win32 application".
trap 'rm -f bin/crisp-compile bin/crisp-hoist-l0 bin/crisp-hoist-cuda 2>/dev/null' EXIT
echo ''

# Provision the PEER library (SYCL-TLA).  third_party/ lives in the bind-mounted repo, so this
# persists on the host across container runs and costs nothing after the first.  Without it the
# SYCL-TLA contender cannot build and the report's Peer column is empty -- and on Intel the peer
# is the ONLY contender reaching the bf16 matrix engines at full rate, so its absence hides the
# largest gap in the ladder.
echo '=== Provisioning peer libraries ==='
bash scripts/setup-third-party.sh sycl-tla 2>&1 | tail -6 ||     echo '  (peer provisioning failed — SYCL-TLA contenders will be skipped)'
echo ''

echo "=== Running matmul.py (Intel/BMG) — sizes=${SIZES} iters=${ITERS} precision=${PRECISION} ==="
# --platform=intel: Crisp via SPIR-V/L0 (crisp-compile --hardware-profile=bmg + the L0 fixed harness),
# SYCL_Apples + OneMKL_Optimal via icpx (the CUDA/cuBLAS targets auto-skip — no nvcc here).  JSON lands
# in benchmarks/results/ (bind-mounted -> host), where report.py picks it up.
PREC_FLAG="--sweep-all"
if [ "${PRECISION}" != "all" ]; then PREC_FLAG="--precision=${PRECISION}"; fi
CHAP_FLAG=""
if [ -n "${CHAPTERS}" ]; then CHAP_FLAG="--chapters=${CHAPTERS}"; fi
python3 scripts/crisp_bench/matmul.py --platform=intel ${PREC_FLAG} ${CHAP_FLAG} --sizes="${SIZES}" --iters="${ITERS}" ${EXTRA}
