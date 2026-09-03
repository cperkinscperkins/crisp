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

# ServerAlive* and ConnectTimeout are LOAD-BEARING, not hygiene.  Without them a dropped pod
# connection leaves the local ssh blocked on a dead TCP socket forever: the script looks alive,
# the pod sits completely idle, and nothing times out.  That is exactly how two consecutive runs
# stalled -- one at "Processing triggers for libc-bin", one at "Installing SBCL" -- with `ps` on
# the pod showing no work in progress at all.  15s x 4 gives up after a minute instead of never.
SSH_CMD="ssh -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o ConnectTimeout=20 -p ${PORT} -i ${SSH_KEY} root@${HOST}"

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
# --- apt reachability preflight (endeavor 144) -------------------------------------------
# Some RunPod images cannot reach archive.ubuntu.com / security.ubuntu.com at all.  apt has no
# default timeout, so `apt-get update` then hangs FOREVER rather than failing -- this cost ~2h
# of paid pod time on 2026-07-27 before it was diagnosed.  Fail fast, and fall back to a mirror
# that responds.  APT_OPTS is applied to every apt call below.
APT_OPTS="-o Acquire::http::Timeout=20 -o Acquire::http::ConnectionAttemptDelayMsec=500 -o Acquire::Retries=1"
if ! curl -s -o /dev/null -m 8 http://archive.ubuntu.com/ubuntu/dists/jammy/Release; then
    echo "archive.ubuntu.com unreachable from this pod; switching apt to mirrors.edge.kernel.org"
    for M in mirrors.edge.kernel.org azure.archive.ubuntu.com mirror.arizona.edu; do
        if curl -s -o /dev/null -m 8 "http://${M}/ubuntu/dists/jammy/Release"; then
            sed -i "s|http://archive\.ubuntu\.com/ubuntu/|http://${M}/ubuntu/|g;                     s|http://security\.ubuntu\.com/ubuntu/|http://${M}/ubuntu/|g;                     s|http://us\.archive\.ubuntu\.com/ubuntu/|http://${M}/ubuntu/|g" /etc/apt/sources.list
            echo "  apt now using ${M}"
            break
        fi
    done
fi

# Ubuntu 22.04 ships needrestart, which on some images prompts "which services should be
# restarted?" from apt and blocks forever on a non-interactive stdin.  Pin it to automatic
# before the first apt call.  NEEDRESTART_MODE=a is what suppresses it; a conf.d file was
# tried first and is not worth the shell-escaping it costs inside a remote heredoc.
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

if $NEED_SBCL; then
    echo "Installing SBCL $SBCL_INSTALL_VERSION from official binary..."
    apt-get update -qq $APT_OPTS
    apt-get install -y -qq $APT_OPTS wget gpg-agent software-properties-common lsb-release curl bzip2
    cd /tmp
    # SourceForge has been UNREACHABLE from RunPod hosts (curl reports an SSL connection
    # timeout, not a 404 -- egress filtering rather than the mirror being down).  Bare `wget -q`
    # hid that completely: it defaults to a 900s read timeout and 20 retries, so an unreachable
    # host hangs for HOURS with no output, and -q suppressed even the eventual failure.  Bound it,
    # let it speak, and check the result rather than blindly untarring.
    SBCL_TARBALL="sbcl-${SBCL_INSTALL_VERSION}-x86-64-linux-binary.tar.bz2"
    rm -f "$SBCL_TARBALL"
    wget --tries=3 --timeout=20 -nv "https://prdownloads.sourceforge.net/sbcl/${SBCL_TARBALL}" || true
    if [ -s "$SBCL_TARBALL" ] && tar tjf "$SBCL_TARBALL" >/dev/null 2>&1; then
        tar xjf "$SBCL_TARBALL"
        cd "sbcl-${SBCL_INSTALL_VERSION}-x86-64-linux"
        INSTALL_ROOT=/usr/local sh install.sh
        cd /root
        rm -rf /tmp/sbcl-${SBCL_INSTALL_VERSION}*
    else
        # apt's SBCL is older (2.1.11 on jammy) but it BUILDS CRISP -- verified on an H100 NVL
        # and an H200.  A working older compiler beats a stalled newer one.
        echo "SourceForge unreachable or tarball bad; falling back to apt sbcl..." >&2
        apt-get install -y -qq $APT_OPTS sbcl || true
    fi
    command -v sbcl >/dev/null || { echo "FATAL: no sbcl after both install paths" >&2; exit 1; }
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
    apt-get update -qq $APT_OPTS
    apt-get install -y -qq $APT_OPTS llvm-21 clang-21
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

# --- 5.5. Third-party PEER libraries -------------------------------------------------------
# CUTLASS is not a dependency of the compiler, so it was never installed here -- but every
# benchmark sweep run on a pod needs it, and its absence is SILENT in the tables: the peer column
# renders "--", which reads identically to "we measured it and it was nothing".  It has now been
# missed on three separate rentals, each time discovered only after the sweep finished.
# Installing it here makes it structural rather than something to remember.  It is a shallow
# header-only clone; if it is already present the script is a no-op.
pod_run "bash -s" <<'THIRDPARTY'
cd /root/crisp
if [ -d third_party/cutlass/include ]; then
  echo "CUTLASS already present."
else
  bash scripts/setup-third-party.sh cutlass 2>&1 | tail -3
fi
THIRDPARTY
echo ""

# --- 6. Run specs ---
step "Step 6: Run spec suite${FILTER:+  (filter: ${FILTER})}"
# Run with CRISP_USE_SYSTEM_TOOLS so it finds llc-21 on PATH.
# FILTER is injected into the remote env so the (quoted) heredoc can read it.
# The remote exits non-zero if any phase failed; capture it (set -e would otherwise abort
# before the completion banner) and propagate as this script's exit status.
RUN_STATUS=0
pod_run "FILTER='${FILTER}' bash -s" <<'RUN_SPECS' || RUN_STATUS=$?
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
# Phase verdicts accumulate here for the end-of-run summary (label|verdict per line).
PHASE_LOG=/tmp/crisp-phase-verdicts.txt
: > "$PHASE_LOG"

run_phase() {
    local label="$1"; shift
    local logf="/tmp/crisp-$(echo "$label" | tr ' /,()' '_____').log"
    echo ""
    echo "=== [$(date +%H:%M:%S)] ${label} ==="
    # NOTE on the heartbeat grep below: a spec whose flag list WRAPS prints its verdict on a
    # continuation line matching none of the other patterns, so the stream showed such specs
    # starting and never finishing -- which reads exactly like a hang.  The trailing
    # alternative catches those indented '... PASS/FAIL' tails.  Comments must stay OUT of the
    # pipeline itself: a backslash-continued line followed by a comment is a syntax error.
    stdbuf -oL -eL sbcl "$@" 2>&1 \
        | stdbuf -oL tee "$logf" \
        | stdbuf -oL grep -E 'Running Spec:|Spec Summary|Passed:|Failed:|Skipped:|BUFFER |FAIL|^[[:space:]]+.*\.\.\.[[:space:]]+(PASS|FAIL)' \
        || true

    # The live stream buries the verdict among hundreds of 'Running Spec:' lines, and the
    # runner's 'Failed Specs:' list never matched the grep above ('Failed:' != 'Failed Specs:',
    # and the '  - name' lines matched nothing) — so re-print both, compactly, right here.
    local summary failed
    summary=$(grep -E '^(Spec Summary|Negative Test Summary)' "$logf" | tail -2)
    failed=$(sed -n '/^Failed Specs:/,$p' "$logf" | grep -E '^[[:space:]]+- ' || true)

    echo "  ----- ${label}: verdict -----"
    if [ -n "$summary" ]; then echo "$summary" | sed 's/^/    /'; else echo "    (no summary line — phase likely crashed)"; fi
    if [ -n "$failed" ]; then
        echo "    FAILED SPECS:"
        echo "$failed" | sed 's/^[[:space:]]*/      /'
        echo "${label}|FAIL" >> "$PHASE_LOG"
    elif [ -z "$summary" ]; then
        echo "${label}|CRASH" >> "$PHASE_LOG"
    else
        echo "${label}|ok" >> "$PHASE_LOG"
    fi
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

# --- Aggregate summary: one place to look, at the very bottom ---
echo ""
echo "============================================================"
echo "  RUN SUMMARY"
echo "============================================================"
while IFS='|' read -r plabel pverdict; do
    printf "  %-34s %s\n" "$plabel" "$pverdict"
done < "$PHASE_LOG"

if grep -qE '\|(FAIL|CRASH)$' "$PHASE_LOG"; then
    echo ""
    echo "  ALL FAILED SPECS (across phases):"
    for lf in /tmp/crisp-specs*.log /tmp/crisp-negative*.log; do
        [ -f "$lf" ] || continue
        sed -n '/^Failed Specs:/,$p' "$lf" | grep -E '^[[:space:]]+- ' | sed "s#^[[:space:]]*#    #" || true
    done
    echo ""
    echo "  RESULT: FAILURES PRESENT"
    echo "============================================================"
    exit 1
fi
echo ""
echo "  RESULT: all phases green"
echo "============================================================"
RUN_SPECS

echo ""
if [ "${RUN_STATUS}" -ne 0 ]; then
    echo "=== [$(date +%H:%M:%S)] RunPod test run complete — FAILURES (see RUN SUMMARY above) ==="
    exit "${RUN_STATUS}"
fi
echo "=== [$(date +%H:%M:%S)] RunPod test run complete — all green ==="
