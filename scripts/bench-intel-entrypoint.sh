#!/usr/bin/env bash
#
# bench-intel-entrypoint.sh — Entry script that runs inside the Docker
# container.  Builds Crisp, then invokes bench-intel-driver.py.
#
# Kept as its own file (rather than inlined into bench-intel.sh) so that
# the host-side wrapper doesn't have to round-trip a multi-line bash -c
# string — both PowerShell and Git Bash mangle that in different ways.
#
# Usage: bench-intel-entrypoint.sh <algo> <sizes> <iters>

set -e

ALGO="${1:?missing algo}"
SIZES="${2:?missing sizes}"
ITERS="${3:?missing iters}"

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

echo '=== Building Crisp inside container ==='
rm -rf /root/.cache/common-lisp
sbcl --non-interactive --load build/build.lisp 2>&1 | tail -8

# Trap a cleanup hook so the Linux ELF binaries the build just dropped into
# bin/ are removed before we exit.  Otherwise they shadow the host's
# Windows .exe binaries on the next native spec-runner invocation, which
# crashes with "is not a valid Win32 application".
trap 'rm -f bin/crisp-compile bin/crisp-hoist-l0 bin/crisp-hoist-cuda 2>/dev/null' EXIT
echo ''

echo '=== Running benchmark driver ==='
# IMPL is optional 4th arg — passes through to the driver's --impl flag.
# Useful while the Crisp L0 path is hung; e.g. IMPL=sycl runs only SYCL.
IMPL="${4:-all}"
# OCCUPANCY is optional 5th arg — empty means resolve via tune cache / .crisp.
OCCUPANCY_FLAG=""
if [ -n "${5:-}" ]; then
    OCCUPANCY_FLAG="--occupancy=$5"
fi
# TUNE is optional 6th arg — pass "tune" to force a fresh occupancy sweep
# on the local hardware and cache the result per-device.
TUNE_FLAG=""
if [ "${6:-}" = "tune" ]; then
    TUNE_FLAG="--tune"
fi
python3 scripts/bench-intel-driver.py "${ALGO}" --sizes="${SIZES}" --iters="${ITERS}" --impl="${IMPL}" ${OCCUPANCY_FLAG} ${TUNE_FLAG}
