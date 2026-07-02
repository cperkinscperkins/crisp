#!/usr/bin/env bash
#
# run-on-pod.sh — Set up a RunPod instance and run Crisp's CUDA test suite.
#
# Connects via SSH, installs dependencies (SBCL, LLVM 21, Quicklisp),
# clones the Crisp repo, builds the compiler + hoist apps, and runs
# the spec suite with CUDA hoist tests executing on real hardware.
#
# https://console.runpod.io/deploy
#
# Usage:
#   ./scripts/run-on-pod.sh <host> <port> [branch] [ssh-key] [filter]
#
# Examples:
#   ./scripts/run-on-pod.sh 149.36.1.192 29800
#   ./scripts/run-on-pod.sh 149.36.1.192 29800 main
#   ./scripts/run-on-pod.sh 149.36.1.192 29800 precision ~/.ssh/id_ed25519
#   # targeted (fast): only specs whose path matches <filter>; skips the
#   # --differentiate + negative phases:
#   ./scripts/run-on-pod.sh 149.36.1.192 29800 precision ~/.ssh/id_ed25519 09-denorm-ftz
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
#   6. Runs the spec suite (TEST-HOIST[CUDA] tests execute on metal); output
#      streams live and is saved to /tmp/crisp-*.log on the pod. A [filter]
#      targets a subset. L0 hoist + SPIR-V compile-checks are skipped (no Intel GPU).
#   7. Reports results
#
# The script is idempotent — safe to re-run if interrupted.

set -euo pipefail

# --- Parse arguments ---
HOST="${1:?Usage: $0 <host> <port> [branch] [ssh-key]}"
PORT="${2:?Usage: $0 <host> <port> [branch] [ssh-key]}"
BRANCH="${3:-main}"
SSH_KEY="${4:-$HOME/.ssh/id_ed25519}"
FILTER="${5:-}"          # optional: substring filter -> only run matching specs (fast, targeted)

REPO_URL="https://github.com/cperkinscperkins/crisp.git"
WORK_DIR="/root/crisp"

SSH_CMD="ssh -o StrictHostKeyChecking=accept-new -p ${PORT} -i ${SSH_KEY} root@${HOST}"

# --- Helper: timestamped step banner (so a long/quiet phase is obvious) ---
step() { echo "--- [$(date +%H:%M:%S)] $* ---"; }

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
step "Step 1: Verify connectivity and GPU"
pod_run "nvidia-smi --query-gpu=name,compute_cap,driver_version --format=csv,noheader"
echo ""

# --- 2. Install system dependencies ---
step "Step 2: Install dependencies (SBCL, LLVM 21)"
pod_run "bash -s" <<'SETUP_DEPS'
set -e

# Check SBCL version — apt's 2.1.x is too old (save-lisp-and-die crashes on modern kernels)
SBCL_MIN_VERSION="2.4"
SBCL_INSTALL_VERSION="2.5.5"
NEED_SBCL=true
if command -v sbcl &>/dev/null; then
    SBCL_VER=$(sbcl --version | grep -oP '\d+\.\d+' | head -1)
    # Use sort -V (GNU coreutils — present on Ubuntu by default) instead
    # of bc, which isn't pre-installed on the RunPod base image and was
    # silently failing here, causing SBCL to be reinstalled every run.
    if [ "$(printf '%s\n%s\n' "$SBCL_MIN_VERSION" "$SBCL_VER" | sort -V | head -1)" = "$SBCL_MIN_VERSION" ]; then
        echo "SBCL already installed: $(sbcl --version)"
        NEED_SBCL=false
    else
        echo "SBCL $SBCL_VER is too old (need >= $SBCL_MIN_VERSION), upgrading..."
    fi
fi
if $NEED_SBCL; then
    echo "Installing SBCL $SBCL_INSTALL_VERSION from official binary..."
    apt-get update -qq
    apt-get install -y -qq wget gpg-agent software-properties-common lsb-release curl bzip2
    cd /tmp
    wget -q "https://prdownloads.sourceforge.net/sbcl/sbcl-${SBCL_INSTALL_VERSION}-x86-64-linux-binary.tar.bz2"
    tar xjf "sbcl-${SBCL_INSTALL_VERSION}-x86-64-linux-binary.tar.bz2"
    cd "sbcl-${SBCL_INSTALL_VERSION}-x86-64-linux"
    INSTALL_ROOT=/usr/local sh install.sh
    cd /root
    rm -rf /tmp/sbcl-${SBCL_INSTALL_VERSION}*
    echo "Installed: $(sbcl --version)"
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
step "Step 3: Install Quicklisp"
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
step "Step 4: Clone/update repo (branch: ${BRANCH})"
pod_run "bash -s" <<CLONE
set -e
if [ -d ${WORK_DIR}/.git ]; then
    echo "Repo exists, fetching and checking out ${BRANCH}..."
    cd ${WORK_DIR}
    git stash
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
step "Step 5: Build compiler + hoist apps"
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
step "Step 6: Run spec suite${FILTER:+  (filter: ${FILTER})}"
# Run with CRISP_USE_SYSTEM_TOOLS so it finds llc-21 on PATH.
# FILTER is injected into the remote env so the (quoted) heredoc can read it.
pod_run "FILTER='${FILTER}' bash -s" <<'RUN_SPECS'
set -e
cd /root/crisp
export CRISP_USE_SYSTEM_TOOLS=true
export SKIP_L0_HOIST=true
export SKIP_SPIRV_TESTS=true
# Ensure CUDA on PATH for nvcc
CUDA_DIR=$(ls -d /usr/local/cuda-*/bin 2>/dev/null | sort -V | tail -1)
[ -n "$CUDA_DIR" ] && export PATH="${CUDA_DIR}:$PATH"

# Endeavor 122 (FFI) Pass 5: libdevice lives at <toolkit-root>/nvvm/libdevice/.
# CUDA_DIR above is the .../bin dir; set CUDA_HOME to the toolkit ROOT so the
# 07-ffi-libdevice spec can resolve $CUDA_HOME/nvvm/libdevice/libdevice.10.bc.
# Derived from nvcc so it works regardless of how the image names the toolkit;
# harmless if nvcc is absent (the FFI libdevice spec then SKIPs cleanly).
if command -v nvcc &>/dev/null; then
    export CUDA_HOME="$(dirname "$(dirname "$(command -v nvcc)")")"
    echo "CUDA_HOME=${CUDA_HOME}"
    ls "${CUDA_HOME}/nvvm/libdevice/libdevice.10.bc" 2>/dev/null \
        && echo "libdevice found" || echo "libdevice NOT found at expected path"
fi

FILTER_ARG=""
[ -n "${FILTER:-}" ] && FILTER_ARG="--filter=${FILTER}"

# Stream a phase LIVE. stdbuf -oL forces line-buffering so progress shows over
# SSH instead of block-buffering into silence (the old `| tail` emitted nothing
# until the whole suite finished — that was the "20 minutes of silence"). tee keeps
# a full log on the pod; grep is a per-spec heartbeat. `|| true` so a failing spec
# doesn't abort the remaining phases under `set -e`.
run_phase() {
    local label="$1"; shift
    local logf="/tmp/crisp-$(echo "$label" | tr ' /,()' '_____').log"
    echo ""
    echo "=== [$(date +%H:%M:%S)] ${label} ==="
    stdbuf -oL -eL sbcl "$@" 2>&1 \
        | stdbuf -oL tee "$logf" \
        | stdbuf -oL grep -E 'Running Spec:|Spec Summary|Passed:|Failed:|Skipped:|BUFFER |FAIL' \
        || true
    echo "  [$(date +%H:%M:%S)] done  (full log: ${logf})"
}

run_phase "specs (binary)" --script tests/run-specs.lisp --use-binary --skip-unit-tests ${FILTER_ARG}

# A filter means a targeted run — skip the extra whole-suite phases.
if [ -z "${FILTER:-}" ]; then
    run_phase "specs (binary, --differentiate)" --script tests/run-specs.lisp --use-binary --differentiate --skip-unit-tests
    run_phase "negative specs" --script tests/run-error-specs.lisp
else
    echo ""
    echo "  (filter active -> skipping --differentiate and negative phases)"
fi
RUN_SPECS

echo ""
echo "=== [$(date +%H:%M:%S)] RunPod test run complete ==="
