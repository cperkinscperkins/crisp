#!/usr/bin/env bash
#
# bench-on-pod.sh — Run Crisp benchmarks on a RunPod instance.
#
# Connects via SSH, ensures dependencies are installed (SBCL, LLVM, nvcc),
# pulls the latest code, builds the compiler, compiles Crisp kernels to PTX,
# builds all benchmark implementations, and runs them.
#
# https://console.runpod.io/deploy
#
# Usage:
#   ./scripts/bench-on-pod.sh <host> <port> [branch] [ssh-key] [sizes] [iters]
#
# Examples:
#   ./scripts/bench-on-pod.sh 157.157.221.29 24405
#   ./scripts/bench-on-pod.sh 157.157.221.29 24405 main ~/.ssh/id_ed25519 1K,100K,1M,10M 100
#
# Prerequisites:
#   - A RunPod pod with CUDA toolkit (nvcc)
#   - SSH access configured
#   - run-on-pod.sh should have been run at least once (deps installed)
#     OR this script will install them itself

set -euo pipefail

# --- Parse arguments ---
HOST="${1:?Usage: $0 <host> <port> [branch] [ssh-key] [sizes] [iters]}"
PORT="${2:?Usage: $0 <host> <port> [branch] [ssh-key] [sizes] [iters]}"
BRANCH="${3:-main}"
SSH_KEY="${4:-$HOME/.ssh/id_ed25519}"
SIZES="${5:-1K,100K,1M}"
ITERS="${6:-100}"

REPO_URL="https://github.com/cperkinscperkins/crisp.git"
WORK_DIR="/root/crisp"

SSH_CMD="ssh -o StrictHostKeyChecking=accept-new -p ${PORT} -i ${SSH_KEY} root@${HOST}"

echo "=== Crisp Benchmark Runner ==="
echo "  Host:   ${HOST}:${PORT}"
echo "  Branch: ${BRANCH}"
echo "  Sizes:  ${SIZES}"
echo "  Iters:  ${ITERS}"
echo ""

pod_run() { ${SSH_CMD} "$@"; }

# --- 1. Verify GPU ---
echo "--- Step 1: Verify GPU ---"
pod_run "nvidia-smi --query-gpu=name,compute_cap,memory.total --format=csv,noheader"
echo ""

# --- 2. Ensure dependencies ---
echo "--- Step 2: Ensure dependencies ---"
pod_run "bash -s" <<'DEPS'
set -e

# SBCL
SBCL_INSTALL_VERSION="2.5.5"
if command -v sbcl &>/dev/null; then
    SBCL_VER=$(sbcl --version | grep -oP '\d+\.\d+' | head -1)
    if [ "$(echo "$SBCL_VER >= 2.4" | bc 2>/dev/null)" = "1" ]; then
        echo "SBCL OK: $(sbcl --version)"
    else
        echo "SBCL too old, upgrading..."
        cd /tmp
        wget -q "https://prdownloads.sourceforge.net/sbcl/sbcl-${SBCL_INSTALL_VERSION}-x86-64-linux-binary.tar.bz2"
        tar xjf "sbcl-${SBCL_INSTALL_VERSION}-x86-64-linux-binary.tar.bz2"
        cd "sbcl-${SBCL_INSTALL_VERSION}-x86-64-linux"
        INSTALL_ROOT=/usr/local sh install.sh
        cd /root && rm -rf /tmp/sbcl-${SBCL_INSTALL_VERSION}*
    fi
else
    echo "Installing SBCL ${SBCL_INSTALL_VERSION}..."
    apt-get update -qq && apt-get install -y -qq wget bzip2 curl
    cd /tmp
    wget -q "https://prdownloads.sourceforge.net/sbcl/sbcl-${SBCL_INSTALL_VERSION}-x86-64-linux-binary.tar.bz2"
    tar xjf "sbcl-${SBCL_INSTALL_VERSION}-x86-64-linux-binary.tar.bz2"
    cd "sbcl-${SBCL_INSTALL_VERSION}-x86-64-linux"
    INSTALL_ROOT=/usr/local sh install.sh
    cd /root && rm -rf /tmp/sbcl-${SBCL_INSTALL_VERSION}*
fi

# LLVM 21 (llc for PTX)
if command -v llc-21 &>/dev/null; then
    echo "LLVM 21 OK"
else
    echo "Installing LLVM 21..."
    apt-get update -qq && apt-get install -y -qq gpg-agent software-properties-common lsb-release
    wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key | gpg --dearmor -o /usr/share/keyrings/llvm-archive-keyring.gpg 2>/dev/null || true
    CODENAME=$(lsb_release -cs 2>/dev/null || echo "jammy")
    echo "deb [signed-by=/usr/share/keyrings/llvm-archive-keyring.gpg] http://apt.llvm.org/${CODENAME}/ llvm-toolchain-${CODENAME}-21 main" > /etc/apt/sources.list.d/llvm-21.list
    apt-get update -qq && apt-get install -y -qq llvm-21
    ln -sf /usr/bin/llc-21 /usr/bin/llc
    ln -sf /usr/bin/llvm-as-21 /usr/bin/llvm-as
fi

# Quicklisp
if [ -f ~/quicklisp/setup.lisp ]; then
    echo "Quicklisp OK"
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

# nvcc
CUDA_DIR=$(ls -d /usr/local/cuda-*/bin 2>/dev/null | sort -V | tail -1)
if [ -n "$CUDA_DIR" ] && ! command -v nvcc &>/dev/null; then
    echo "Adding $CUDA_DIR to PATH..."
    echo "export PATH=${CUDA_DIR}:\$PATH" >> ~/.bashrc
fi
echo "nvcc: $(which nvcc 2>/dev/null || echo $CUDA_DIR/nvcc)"
DEPS
echo ""

# --- 3. Clone or update repo ---
echo "--- Step 3: Clone/update repo (branch: ${BRANCH}) ---"
pod_run "bash -s" <<CLONE
set -e
if [ -d ${WORK_DIR}/.git ]; then
    cd ${WORK_DIR}
    git fetch origin
    git checkout ${BRANCH}
    git pull origin ${BRANCH} || true
else
    git clone --branch ${BRANCH} ${REPO_URL} ${WORK_DIR}
fi
cd ${WORK_DIR}
echo "At commit: \$(git log --oneline -1)"
CLONE
echo ""

# --- 4. Build compiler ---
echo "--- Step 4: Build compiler ---"
pod_run "bash -s" <<'BUILD'
set -e
rm -rf ~/.cache/common-lisp
cd /root/crisp
rm -f bin/llvm-spirv tools/llvm-spirv-linux tools/llvm-as-linux tools/llc-linux tools/LLVM-C-linux.so
sbcl --non-interactive --load build/build.lisp 2>&1 | tail -5
BUILD
echo ""

# --- 5. Run benchmarks ---
echo "--- Step 5: Run benchmarks ---"
pod_run "bash -s" <<BENCH
set -e
cd /root/crisp
CUDA_DIR=\$(ls -d /usr/local/cuda-*/bin 2>/dev/null | sort -V | tail -1)
[ -n "\$CUDA_DIR" ] && export PATH="\${CUDA_DIR}:\$PATH"
export CRISP_USE_SYSTEM_TOOLS=true

python3 benchmarks/reduction/run.py --sizes=${SIZES} --iters=${ITERS}
BENCH

echo ""
echo "=== Benchmark run complete ==="
