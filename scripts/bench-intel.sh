#!/usr/bin/env bash
#
# bench-intel.sh — Run Crisp Intel benchmarks inside a Docker container
# with BMG / Arc GPU passthrough on Windows + WSL2.
#
# Usage:
#   ./scripts/bench-intel.sh <algo> [sizes] [iters]
#
# Examples:
#   ./scripts/bench-intel.sh reduction
#   ./scripts/bench-intel.sh reduction 1K,100K,1M 100
#
# Requirements:
#   - Docker Desktop on Windows with WSL2 backend
#   - Intel WSL GPU driver installed on the Windows host
#     (https://www.intel.com/.../arc-iris-xe-graphics-with-wsl.html)
#   - The dev's working tree is mounted into the container at /workspace,
#     so local edits are immediately picked up by the in-container build.
#
# What it does:
#   1. Build the bench image (scripts/Dockerfile.bench-intel) if not cached
#   2. Run the image with /dev/dxg + /usr/lib/wsl mounted so the L0 driver
#      can talk to the BMG.  The user's working tree is bind-mounted at
#      /workspace.
#   3. Inside the container: build Crisp, then exec the per-algorithm
#      driver (scripts/bench-intel-driver.py <algo>) which compiles all
#      impls (crisp / sycl / onedpl) and runs warmup + measured
#      iterations, printing a comparison table to stdout.
#
# Tee the stdout into docs/benchmarks.md or wherever you want to record
# the run — there's no automatic results file yet (standardising the
# output format across all platforms is a separate piece of work).

set -euo pipefail

# Git Bash / MSYS on Windows aggressively rewrites argument paths starting
# with / (e.g. /usr/lib/wsl → C:\Program Files\Git\usr\lib\wsl).  Disable
# globally — Docker Desktop accepts both Cygwin-style /c/... and Windows
# C:\... paths for -v sources, so we don't lose anything by turning the
# rewrite off.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

# --- Parse arguments ---
ALGO="${1:?Usage: $0 <algo> [sizes] [iters] [impl] [occupancy] [tune]}"
# Per-algorithm default sizes (reduction: element counts; matmul: square dims, multiples of 32).
if [ "$ALGO" = "matmul" ]; then DEFAULT_SIZES="256,512,1024"; else DEFAULT_SIZES="1K,100K,1M"; fi
SIZES="${2:-$DEFAULT_SIZES}"
ITERS="${3:-100}"
# Optional 4th arg: comma-separated impl list or 'all'.
# Use 'sycl' to skip the (currently broken) Crisp L0 path.
IMPL="${4:-all}"
# Optional 5th arg: occupancy override (0.0..1.0).  Empty -> resolve via
# tune cache + .crisp source (see bench-intel-driver.py resolve_occupancy).
OCCUPANCY="${5:-}"
# Optional 6th arg: pass "tune" to force a fresh occupancy sweep on the
# local hardware and cache the result.  Empty / anything else = no.
TUNE="${6:-}"

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

echo "=== Crisp Intel Benchmark Runner ==="
echo "  Algo:   ${ALGO}"
echo "  Sizes:  ${SIZES}"
echo "  Iters:  ${ITERS}"
echo "  Repo:   ${REPO_ROOT}"
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
echo "--- Step 3: Run benchmark driver for ${ALGO} ---"
docker run --rm \
    --device=/dev/dxg \
    -v /usr/lib/wsl:/usr/lib/wsl \
    -v "${REPO_ROOT}:/workspace" \
    -e CRISP_CACHE_DIR=/root/.cache/common-lisp \
    -w /workspace \
    "${IMAGE_TAG}" \
    bash scripts/bench-intel-entrypoint.sh "${ALGO}" "${SIZES}" "${ITERS}" "${IMPL}" "${OCCUPANCY}" "${TUNE}"

echo ""
echo "=== Intel benchmark run complete ==="
