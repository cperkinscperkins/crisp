#!/usr/bin/env bash
# Installs the wheels in dist/wheels/ into clean containers and runs scripts/wheel_smoke.py there:
#   ubuntu:22.04        the glibc 2.35 floor (Colab's base), system python3 + pip
#   python:3.11-slim    Debian bookworm, a minimal image with none of libLLVM's dependencies
#   python:3.13-slim    the newest Python
# No GPU needed: it compiles, describes and hoists, it does not launch.
# Usage (repo root):  ./scripts/test-wheel.sh [IMAGE ...]
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGES=("$@")
[ ${#IMAGES[@]} -gt 0 ] || IMAGES=(ubuntu:22.04 python:3.11-slim python:3.13-slim)
SRC_DIR=$(pwd -W 2>/dev/null || pwd)
ls dist/wheels/crisp_gpu-*.whl dist/wheels/crisp_gpu_hoist-*.whl > /dev/null
rc=0
for img in "${IMAGES[@]}"; do
  echo "=== $img ==="
  MSYS_NO_PATHCONV=1 docker run --rm -v "${SRC_DIR}:/src:ro" "$img" bash -c '
    set -e
    if ! command -v pip3 > /dev/null; then
      apt-get update -qq > /dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-pip > /dev/null
    fi
    cd /tmp
    pip3 install -q --no-index --find-links /src/dist/wheels crisp-gpu 2>&1 | grep -v -i "root user" || true
    python3 /src/scripts/wheel_smoke.py
  ' || rc=1
done
exit $rc
