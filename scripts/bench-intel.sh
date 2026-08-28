#!/usr/bin/env bash
#
# bench-intel.sh — Run Crisp Intel benchmarks inside a Docker container
# with BMG / Arc GPU passthrough on Windows + WSL2.
#
# Usage:
#   ./scripts/bench-intel.sh [sizes] [iters] [precision] [chapters]
#
# Examples:
#   ./scripts/bench-intel.sh                          # full sweep, default sizes, precision matrix
#   ./scripts/bench-intel.sh 256,512,1024 100         # smaller sizes
#   ./scripts/bench-intel.sh 256,512,1024,2048,4096,8192 100 fast    # single precision pass
#   ./scripts/bench-intel.sh 256,512,1024,2048,4096,8192 100 fast sec2_top_bf16,sec2_top_fp16
#                                                    # just the 16-bit top kernels + their peers
#   ./scripts/bench-intel.sh 2048,4096,8192 100 fast _probe_roofline --scratch
#                                                    # the roofline diagnostic; --scratch is REQUIRED
#                                                    # (two of its three arms are deliberately wrong)
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
# Square GEMM sizes (multiples of 32). Precision "all" runs the full sweep (fast / ieee+ftz / ieee).
# (Note: Crisp on Intel BMG starts to drop off against MKL around N=6144 due to cache constraints,
#  so the default sweep includes sizes up to 8192 to capture this crossover).
SIZES="${1:-256,512,1024,2048,4096,8192}"
ITERS="${2:-100}"
PRECISION="${3:-all}"   # all -> full sweep; or fast | ieee for single pass
# Empty runs every chapter.  A filter here is the difference between refreshing two rows and
# pinning the display GPU for the entire suite -- which is why peer columns go stale.
CHAPTERS="${4:-}"
# Extra flags forwarded verbatim to matmul.py.  Needed for --scratch, which the diagnostic
# chapters (e.g. _probe_roofline) must be run with -- it routes their JSON into
# benchmarks/results/scratch/, which the report never reads into a canonical table.
EXTRA="${5:-}"

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
echo "  Chapters:   ${CHAPTERS:-<all>}"
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
    -e CRISP_CACHE_CONTROL \
    -e CRISP_CACHE_CONTROL_KERNELS \
    -e CRISP_TILE_VISIT \
    -w /workspace \
    "${IMAGE_TAG}" \
    bash scripts/bench-intel-entrypoint.sh "${SIZES}" "${ITERS}" "${PRECISION}" "${CHAPTERS}" "${EXTRA}"

echo ""
echo "=== Intel benchmark run complete ==="
