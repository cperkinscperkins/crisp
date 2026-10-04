#!/usr/bin/env bash
# bench-ceiling-intel.sh -- measure the Intel GPU's READ-bandwidth ceiling, in Docker.
#
# The reduction suite reports "% of measured peak"; this produces the peak.  Same container, same
# device passthrough and same oneAPI as scripts/bench-intel.sh, because Intel numbers measured
# natively on Windows and in the Linux container differ (up to 2.2x on matmul), and a ceiling from
# one environment must not be the denominator for numbers from the other.
#
# Usage:
#   ./scripts/bench-ceiling-intel.sh [sizes-mb] [iters] [pattern]
#   ./scripts/bench-ceiling-intel.sh 16,64,256,1024,4096 20 hash      # the defaults
#
# Output: benchmarks/results/ceiling_intel_<pattern>_<unix-time>.json (report.py ignores ceiling_* files
# when it loads sweeps; it only reads results_*.json).

set -euo pipefail

SIZES="${1:-16,64,256,1024,4096}"
ITERS="${2:-20}"
PATTERN="${3:-hash}"   # hash = incompressible data (see read_bw.cpp); ones = all 1.0f

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    SCRIPT_DIR="$(cygpath -w "${SCRIPT_DIR}")"
    REPO_ROOT="$(cygpath -w "${REPO_ROOT}")"
fi
IMAGE_TAG="crisp-bench-intel:latest"
DOCKERFILE="${SCRIPT_DIR}/Dockerfile.bench-intel"
STAMP="$(date +%s)"
OUT="benchmarks/results/ceiling_intel_${PATTERN}_${STAMP}.json"

echo "=== Crisp Intel read-bandwidth ceiling ==="
echo "  Sizes (MB): ${SIZES}"
echo "  Iters:      ${ITERS}"
echo "  Pattern:    ${PATTERN}"
echo "  Output:     ${OUT}"

docker build --tag "${IMAGE_TAG}" --file "${DOCKERFILE}" "${SCRIPT_DIR}"

MSYS_NO_PATHCONV=1 docker run --rm \
    --device=/dev/dxg \
    -v /usr/lib/wsl:/usr/lib/wsl \
    -v "${REPO_ROOT}:/workspace" \
    -w /workspace \
    "${IMAGE_TAG}" \
    bash -c ". /opt/intel/oneapi/setvars.sh > /dev/null 2>&1; \
             export LD_LIBRARY_PATH=/usr/lib/wsl/lib:\$LD_LIBRARY_PATH; \
             set -e; \
             icpx -fsycl -O3 -o /tmp/read_bw benchmarks/reduction/ceiling/read_bw.cpp; \
             /tmp/read_bw --sizes-mb=${SIZES} --iters=${ITERS} --pattern=${PATTERN} --json=${OUT}"

echo ""
echo "=== wrote ${OUT} ==="
