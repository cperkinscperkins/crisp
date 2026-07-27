#!/usr/bin/env bash
#
# bench-intel.sh — Run Crisp Intel benchmarks inside a Docker container
# with BMG / Arc GPU passthrough on Windows + WSL2.
#
# Usage:
#   ./scripts/bench-intel.sh [sizes] [iters] [precision]
#
# Examples:
#   ./scripts/bench-intel.sh                          # full sweep, default sizes, precision matrix
#   ./scripts/bench-intel.sh 256,512,1024 100         # smaller sizes
#   ./scripts/bench-intel.sh 256,512,1024 100 fast    # single precision pass
#
# Requirements:
#   - Docker Desktop on Windows with WSL2 backend
#   - Intel WSL GPU driver installed on the Windows host
#     (https://www.intel.com/.../arc-iris-xe-graphics-with-wsl.html)
#   - The dev's working tree is mounted into the container at /workspace,
#     so local edits are immediately picked up by the in-container build.
#
# What it does (Endeavor 143 — the Intel arm of the UNIFIED benchmark system):
#   1. Build the bench image (scripts/Dockerfile.bench-intel) if not cached
#   2. Run the image with /dev/dxg + /usr/lib/wsl mounted so the L0 driver
#      can talk to the BMG.  The user's working tree is bind-mounted at
#      /workspace.
#   3. Inside the container: build Crisp, then run the SAME cross-platform
#      driver the NVIDIA side uses — scripts/crisp_bench/matmul.py
#      --platform=intel — which compiles Crisp (SPIR-V/L0), SYCL_Apples, and
#      OneMKL_Optimal (icpx) with EXPLICIT precision flags across the full
#      precision matrix, and writes BenchmarkSweep JSON to benchmarks/results/.
#
# Results are JSON in benchmarks/results/ (bind-mounted, so they appear on the
# host).  Render the report with:
#     python scripts/crisp_bench/report.py --output benchmarks/REPORT.md
# report.py auto-adds a `## Hardware: Intel BMG` section from the JSON.

set -euo pipefail

# Git Bash / MSYS on Windows aggressively rewrites argument paths starting
# with / (e.g. /usr/lib/wsl → C:\Program Files\Git\usr\lib\wsl).  Disable
# globally — Docker Desktop accepts both Cygwin-style /c/... and Windows
# C:\... paths for -v sources, so we don't lose anything by turning the
# rewrite off.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

# --- Parse arguments ---
# Endeavor 143: matmul-only, driven by the unified cross-platform matmul.py (--platform=intel).
# Square GEMM sizes (multiples of 32).  Precision "all" runs the full sweep (fast / ieee+ftz / ieee).
#
# ⚠️  DISPLAY-GPU WARNING: on this machine the BMG is BOTH the compute device AND the Windows display
# GPU (the WSL2/Docker passthrough shares the one physical GPU).  A large square GEMM pins the GPU for
# tens of seconds — size^3 scaling means 4096 pins ~64x longer than 1024 — during which Windows cannot
# composite the desktop and the WHOLE MACHINE FREEZES.  So the DEFAULT stops at 1024.  2048/4096 are an
# EXPLICIT opt-in only (`bench-intel.sh 256,512,1024,2048`); expect a multi-second-to-minutes freeze,
# and prefer fewer iters at those sizes.  (On a dedicated compute GPU / RunPod there's no display to
# starve, so the NVIDIA matmul.py default keeps the full 256..4096.)
SIZES="${1:-256,512,1024}"
ITERS="${2:-100}"
PRECISION="${3:-all}"   # all -> full precision sweep (--sweep-all); or fast | ieee for a single pass

case ",${SIZES}," in
  *,2048,*|*,4096,*|*,8192,*)
    echo "⚠️  bench-intel.sh: sizes >= 2048 pin the BMG (your DISPLAY GPU) for a long time — the desktop"
    echo "    may freeze for the duration.  Ctrl-C won't repaint until the GPU frees.  Continuing in 5s..."
    sleep 5 ;;
esac

# Locate the repo root from this script's directory.  Use cygpath where
# available to convert to Windows-form paths — with MSYS_NO_PATHCONV=1 set
# above, docker won't translate /c/... itself, so we have to.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    SCRIPT_DIR="$(cygpath -w "${SCRIPT_DIR}")"
    REPO_ROOT="$(cygpath -w "${REPO_ROOT}")"
fi

IMAGE_TAG="crisp-bench-intel:latest"
DOCKERFILE="${SCRIPT_DIR}/Dockerfile.bench-intel"

echo "=== Crisp Intel Benchmark Runner (matmul) ==="
echo "  Sizes:      ${SIZES}"
echo "  Iters:      ${ITERS}"
echo "  Precision:  ${PRECISION}"
echo "  Repo:       ${REPO_ROOT}"
echo ""

# --- 1. Build the image (cached) ---
echo "--- Step 1: Build (or reuse cached) Docker image ${IMAGE_TAG} ---"
docker build \
    --tag "${IMAGE_TAG}" \
    --file "${DOCKERFILE}" \
    "${SCRIPT_DIR}"
echo ""

# --- 2. Sanity-check GPU passthrough ---
# Important: LD_LIBRARY_PATH must be EXTENDED inside the container (after
# setvars.sh has built up the oneAPI search path), not replaced via -e
# from outside.  Passing -e LD_LIBRARY_PATH=/usr/lib/wsl/lib wipes the
# compiler/lib entries and the L0 loader can't resolve its deps.
echo "--- Step 2: Verify BMG visible to L0 inside container ---"
docker run --rm \
    --device=/dev/dxg \
    -v /usr/lib/wsl:/usr/lib/wsl \
    "${IMAGE_TAG}" \
    bash -c '. /opt/intel/oneapi/setvars.sh > /dev/null 2>&1; \
             export LD_LIBRARY_PATH=/usr/lib/wsl/lib:$LD_LIBRARY_PATH; \
             sycl-ls 2>&1 | head -5'
echo ""

# --- 3. Build Crisp + run the benchmark driver inside the container ---
#
# We exec the in-container entrypoint script directly rather than passing
# a multi-line bash -c string.  Both Git Bash and PowerShell break a
# multi-line `bash -c` argument differently (Git Bash sometimes mangles
# globs, PowerShell splits on newline), and an external script file dodges
# both problems cleanly.
echo "--- Step 3: Build Crisp + run matmul.py (Intel/BMG) inside the container ---"
docker run --rm \
    --device=/dev/dxg \
    -v /usr/lib/wsl:/usr/lib/wsl \
    -v "${REPO_ROOT}:/workspace" \
    -e CRISP_CACHE_DIR=/root/.cache/common-lisp \
    -w /workspace \
    "${IMAGE_TAG}" \
    bash scripts/bench-intel-entrypoint.sh "${SIZES}" "${ITERS}" "${PRECISION}"

echo ""
echo "=== Intel benchmark run complete ==="
