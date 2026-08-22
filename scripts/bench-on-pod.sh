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
#   ./scripts/bench-on-pod.sh <host> <port> [branch] [ssh-key] [sizes] [iters] [occupancy]
#                             [--bench=reduction|matmul]
#
# The --bench flag (default: reduction) selects which benchmark to run; it may appear
# anywhere in the argument list.  Each benchmark has its own default sizes
# (reduction: 1K,100K,1M ; matmul: 256,512,1024 — matmul dims must be multiples of 64).
#
# Examples:
#   ./scripts/bench-on-pod.sh 157.157.221.29 24405
#   ./scripts/bench-on-pod.sh 157.157.221.29 24405 main ~/.ssh/id_ed25519 1K,100K,1M,10M 100
#   ./scripts/bench-on-pod.sh 157.157.221.29 24405 mm-tile-stride ~/.ssh/id_ed25519 --bench=matmul
#   ./scripts/bench-on-pod.sh 157.157.221.29 24405 mm-tile-stride ~/.ssh/id_ed25519 256,512,1024 100 --bench=matmul
#
# Prerequisites:
#   - A RunPod pod with CUDA toolkit (nvcc)
#   - SSH access configured
#   - run-on-pod.sh should have been run at least once (deps installed)
#     OR this script will install them itself

set -euo pipefail

# --- Parse arguments ---
## Pull the optional --bench=NAME flag out of the argument list (it may appear anywhere),
## leaving the positional args intact.  ONE script, many benchmarks.
BENCH="reduction"
KEEP_POD_RESULTS="0"
CHAPTERS=""
for _a in "$@"; do
    case "$_a" in --chapters=*) CHAPTERS="${_a#--chapters=}" ;; esac
done
set -- $(printf "%s\n" "$@" | grep -v -- "--chapters=" | tr "\n" " ")
for _a in "$@"; do
    if [ "$_a" = "--keep-pod-results" ]; then KEEP_POD_RESULTS="1"; fi
done
set -- $(printf "%s\n" "$@" | grep -v -- "--keep-pod-results" | tr "\n" " ")
## --scratch: forward to the suite driver so an exploratory run lands in results/scratch/, which
## the report never reads (§2 of plan/benchmark-harness.md).  Without this the flag was NOT
## recognised here and fell through to POSITIONAL, where it silently became the SIZES argument --
## so `bench.py --scratch --target=pod` produced a run with sizes="--scratch" AND wrote it to the
## canonical directory: precisely the contamination §2 exists to prevent.
SCRATCH_ARG=""
for _a in "$@"; do
    if [ "$_a" = "--scratch" ]; then SCRATCH_ARG="--scratch"; fi
done
set -- $(printf "%s\n" "$@" | grep -v -- "--scratch" | tr "\n" " ")
POSITIONAL=()
for _arg in "$@"; do
    case "$_arg" in
        --bench=*) BENCH="${_arg#--bench=}" ;;
        *)         POSITIONAL+=("$_arg") ;;
    esac
done
set -- "${POSITIONAL[@]}"

case "$BENCH" in
    reduction|matmul) ;;
    *) echo "ERROR: unknown --bench=$BENCH (expected 'reduction' or 'matmul')" >&2; exit 1 ;;
esac

HOST="${1:?Usage: $0 <host> <port> [branch] [ssh-key] [sizes] [iters] [occupancy] [--bench=reduction|matmul]}"
PORT="${2:?Usage: $0 <host> <port> [branch] [ssh-key] [sizes] [iters] [occupancy] [--bench=reduction|matmul]}"
BRANCH="${3:-main}"
SSH_KEY="${4:-$HOME/.ssh/id_ed25519}"
## Per-benchmark default sizes (reduction: element counts; matmul: square dims, multiples of 64).
if [ "$BENCH" = "matmul" ]; then DEFAULT_SIZES="256,512,1024"; else DEFAULT_SIZES="1K,100K,1M"; fi
SIZES="${5:-$DEFAULT_SIZES}"
ITERS="${6:-100}"
## crisp-tree occupancy (reduction only): when empty, run.py reads :occupancy from the .crisp
## file (the single source of truth).  Provide a value to override for ad-hoc sweeps.
CRISP_TREE_OCCUPANCY="${7:-}"

REPO_URL="https://github.com/cperkinscperkins/crisp.git"
WORK_DIR="/root/crisp"

SSH_CMD="ssh -o StrictHostKeyChecking=accept-new -p ${PORT} -i ${SSH_KEY} root@${HOST}"

echo "=== Crisp Benchmark Runner ==="
echo "  Host:   ${HOST}:${PORT}"
echo "  Branch: ${BRANCH}"
echo "  Bench:  ${BENCH}"
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
    # Use sort -V instead of bc — bc isn't on the RunPod base image and was
    # silently failing, causing SBCL to be reinstalled every run.
    if [ "$(printf '%s\n%s\n' "2.4" "$SBCL_VER" | sort -V | head -1)" = "2.4" ]; then
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
    git stash
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

# --- 4b. Clear the pod's results dir so the pull is precise ---
#
# The pod cloned the repo, so benchmarks/results/ already contains every committed result from
# every machine.  pull-runpod-results.sh copies *.json back wholesale, which would drag that
# whole history home and make the report look like it ignored this run.  Wiping the POD copy
# (never the local one — local accretion across hardware is the point) means whatever lands
# there afterwards is exactly what this run produced.
if [ "${KEEP_POD_RESULTS}" = "1" ]; then
    echo "--- Step 4b: keeping existing pod results (--keep-pod-results) ---"
else
    echo "--- Step 4b: clearing pod results dir (use --keep-pod-results to accumulate) ---"
    pod_run "rm -f /root/crisp/benchmarks/results/*.json 2>/dev/null; \
             mkdir -p /root/crisp/benchmarks/results; \
             echo \"  pod results dir now holds \$(ls -1 /root/crisp/benchmarks/results 2>/dev/null | wc -l) files\""
fi
echo ""

# --- 5. Run benchmarks ---
if [ -n "${CHAPTERS}" ]; then
    CHAPTERS_ARG="--chapters=${CHAPTERS}"
    echo "    (restricted to chapters: ${CHAPTERS})"
else
    CHAPTERS_ARG=""
fi
echo "--- Step 5: Run benchmarks (${BENCH}) ---"
pod_run "bash -s" <<RUNBENCH
set -e
cd /root/crisp
CUDA_DIR=\$(ls -d /usr/local/cuda-*/bin 2>/dev/null | sort -V | tail -1)
[ -n "\$CUDA_DIR" ] && export PATH="\${CUDA_DIR}:\$PATH"
export CRISP_USE_SYSTEM_TOOLS=true

case "${BENCH}" in
  reduction)
    ## Only pass --crisp-tree-occupancy when overriding; empty -> run.py reads it from
    ## the .crisp file (avoids stale defaults).
    PY_ARGS="--sizes=${SIZES} --iters=${ITERS}"
    if [ -n "${CRISP_TREE_OCCUPANCY}" ]; then
        PY_ARGS="\${PY_ARGS} --crisp-tree-occupancy=${CRISP_TREE_OCCUPANCY}"
    fi
    python3 benchmarks/reduction/run.py \${PY_ARGS}
    ;;
  matmul)
    ## MATH-FLAG POLICY: this sweep NEVER relies on a compiler's default precision or denormal
    ## behavior.  nvcc / icpx / crisp-compile have different (and inconsistently documented)
    ## defaults, so matmul.py passes a COMPLETE, explicit set of precision + denormal flags to
    ## every compiler on every precision pass (see nvcc_math_flags / icpx_math_flags and the
    ## MATH-FLAG POLICY block in scripts/crisp_bench/matmul.py).  A bare `nvcc -O3` is never emitted.
    ## --chapters= (optional) restricts the ladder.  A fused-epilogue session does not need
    ## chap0/chap1/chap1.5/chap2 re-measured at 8192 — those are slow, known, and dominate
    ## the wall time.  Empty means the whole ladder, as before.
    python3 scripts/crisp_bench/matmul.py --sizes=${SIZES} --iters=${ITERS} --sweep-all ${CHAPTERS_ARG} ${SCRATCH_ARG}
    ;;
esac
RUNBENCH

echo ""
echo "=== Benchmark run complete ==="
