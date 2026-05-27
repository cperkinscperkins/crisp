#!/usr/bin/env bash
#
# run-on-pod.sh — Set up a RunPod instance and run Crisp's CUDA test suite.
#
# Connects via SSH, installs dependencies (SBCL, LLVM 21, Quicklisp),
# clones the Crisp repo, builds the compiler + hoist apps, and runs
# the spec suite with CUDA hoist tests executing on real hardware.
#
# Usage:
#   ./scripts/run-on-pod.sh <host> <port> [branch] [ssh-key]
#
# Examples:
#   ./scripts/run-on-pod.sh 149.36.1.192 29800
#   ./scripts/run-on-pod.sh 149.36.1.192 29800 main
#   ./scripts/run-on-pod.sh 149.36.1.192 29800 runpod-prep ~/.ssh/id_ed25519
#
# Prerequisites:
#   - A RunPod pod running a PyTorch or CUDA image (provides nvcc)
#   - SSH access configured (key-based)
#
# What this script does:
#   1. Verifies SSH connectivity and GPU availability
#   2. Installs SBCL and LLVM 21 (llc-21) if not already present
#   3. Installs Quicklisp if not already present
#   4. Clones the Crisp repo at the specified branch
#   5. Builds the compiler, L0 hoist, and CUDA hoist
#   6. Runs the full spec suite (TEST-HOIST[CUDA] tests execute on metal)
#   7. Reports results
#
# The script is idempotent — safe to re-run if interrupted.

set -euo pipefail

# --- Parse arguments ---
HOST="${1:?Usage: $0 <host> <port> [branch] [ssh-key]}"
PORT="${2:?Usage: $0 <host> <port> [branch] [ssh-key]}"
BRANCH="${3:-main}"
SSH_KEY="${4:-$HOME/.ssh/id_ed25519}"

REPO_URL="https://github.com/cperkinscperkins/crisp.git"
WORK_DIR="/root/crisp"

SSH_CMD="ssh -o StrictHostKeyChecking=accept-new -p ${PORT} -i ${SSH_KEY} root@${HOST}"

echo "=== Crisp RunPod Test Runner ==="
echo "  Host:   ${HOST}:${PORT}"
echo "  Branch: ${BRANCH}"
echo "  Key:    ${SSH_KEY}"
echo ""

# --- Helper: run a command on the pod ---
pod_run() {
    ${SSH_CMD} "$@"
}

# --- Helper: run a command on the pod, don't fail on error ---
pod_try() {
    ${SSH_CMD} "$@" || true
}

# --- 1. Verify connectivity and GPU ---
echo "--- Step 1: Verify connectivity and GPU ---"
pod_run "nvidia-smi --query-gpu=name,compute_cap,driver_version --format=csv,noheader"
echo ""

# --- 2. Install system dependencies ---
echo "--- Step 2: Install dependencies (SBCL, LLVM 21) ---"
pod_run "bash -s" <<'SETUP_DEPS'
set -e

# Check if SBCL is already installed
if command -v sbcl &>/dev/null; then
    echo "SBCL already installed: $(sbcl --version)"
else
    echo "Installing SBCL..."
    apt-get update -qq
    apt-get install -y -qq sbcl wget gpg-agent software-properties-common lsb-release curl
fi

# Check if llc-21 and clang-21 are already installed
if command -v llc-21 &>/dev/null && command -v clang-21 &>/dev/null; then
    echo "LLVM 21 already installed: $(llc-21 --version | head -1)"
else
    echo "Installing LLVM 21 + clang 21..."
    wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key | gpg --dearmor -o /usr/share/keyrings/llvm-archive-keyring.gpg 2>/dev/null || true
    CODENAME=$(lsb_release -cs 2>/dev/null || echo "jammy")
    echo "deb [signed-by=/usr/share/keyrings/llvm-archive-keyring.gpg] http://apt.llvm.org/${CODENAME}/ llvm-toolchain-${CODENAME}-21 main" > /etc/apt/sources.list.d/llvm-21.list
    apt-get update -qq
    apt-get install -y -qq llvm-21 clang-21
    # Create unversioned symlinks
    ln -sf /usr/bin/llc-21 /usr/bin/llc
    ln -sf /usr/bin/llvm-as-21 /usr/bin/llvm-as
    ln -sf /usr/bin/clang-21 /usr/bin/clang
fi

# Ensure CUDA toolkit is on PATH (RunPod images install it but don't always add to PATH)
CUDA_DIR=$(ls -d /usr/local/cuda-*/bin 2>/dev/null | sort -V | tail -1)
if [ -n "$CUDA_DIR" ] && ! command -v nvcc &>/dev/null; then
    echo "Adding $CUDA_DIR to PATH..."
    echo "export PATH=${CUDA_DIR}:\$PATH" >> ~/.bashrc
    export PATH="${CUDA_DIR}:$PATH"
fi

echo "llc: $(which llc-21)"
echo "nvcc: $(which nvcc || echo 'NOT FOUND')"
SETUP_DEPS
echo ""

# --- 3. Install Quicklisp ---
echo "--- Step 3: Install Quicklisp ---"
pod_run "bash -s" <<'SETUP_QL'
set -e
if [ -f ~/quicklisp/setup.lisp ]; then
    echo "Quicklisp already installed"
else
    echo "Installing Quicklisp..."
    curl -sO https://beta.quicklisp.org/quicklisp.lisp
    echo "" | sbcl --non-interactive \
        --load quicklisp.lisp \
        --eval '(quicklisp-quickstart:install)' \
        --eval '(ql:add-to-init-file)' \
        --eval '(quit)'
    rm -f quicklisp.lisp
fi
SETUP_QL
echo ""

# --- 4. Clone or update repo ---
echo "--- Step 4: Clone/update repo (branch: ${BRANCH}) ---"
pod_run "bash -s" <<CLONE
set -e
if [ -d ${WORK_DIR}/.git ]; then
    echo "Repo exists, fetching and checking out ${BRANCH}..."
    cd ${WORK_DIR}
    git fetch origin
    git checkout ${BRANCH}
    git pull origin ${BRANCH} || true
else
    echo "Cloning repo..."
    git clone --branch ${BRANCH} ${REPO_URL} ${WORK_DIR}
fi
cd ${WORK_DIR}
echo "At commit: \$(git log --oneline -1)"
CLONE
echo ""

# --- 5. Clear FASL cache and build ---
echo "--- Step 5: Build compiler + hoist apps ---"
pod_run "bash -s" <<'BUILD'
set -e
# Clear stale FASL cache
rm -rf ~/.cache/common-lisp

cd /root/crisp

# Remove LFS pointer files (same as CI step 1.5)
rm -f bin/llvm-spirv tools/llvm-spirv-linux tools/llvm-as-linux tools/llc-linux tools/LLVM-C-linux.so

echo "Building..."
sbcl --non-interactive --load build/build.lisp
echo ""
echo "Binaries:"
ls -la bin/crisp-compile bin/crisp-hoist-l0 bin/crisp-hoist-cuda 2>/dev/null || ls -la bin/
BUILD
echo ""

# --- 6. Run specs ---
echo "--- Step 6: Run spec suite ---"
# Run with CRISP_USE_SYSTEM_TOOLS so it finds llc-21 on PATH
pod_run "bash -s" <<'RUN_SPECS'
set -e
cd /root/crisp
export CRISP_USE_SYSTEM_TOOLS=true
export SKIP_L0_HOIST=true
export SKIP_SPIRV_TESTS=true
# Ensure CUDA on PATH for nvcc
CUDA_DIR=$(ls -d /usr/local/cuda-*/bin 2>/dev/null | sort -V | tail -1)
[ -n "$CUDA_DIR" ] && export PATH="${CUDA_DIR}:$PATH"

echo "=== Running specs (external binary) ==="
sbcl --script tests/run-specs.lisp --use-binary --skip-unit-tests 2>&1 | tail -30

echo ""
echo "=== Running specs (external binary, --differentiate) ==="
sbcl --script tests/run-specs.lisp --use-binary --differentiate --skip-unit-tests 2>&1 | tail -10

echo ""
echo "=== Running negative specs ==="
sbcl --script tests/run-error-specs.lisp 2>&1 | tail -5
RUN_SPECS

echo ""
echo "=== RunPod test run complete ==="
