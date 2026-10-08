#!/usr/bin/env bash
#
# 182-pod-verify.sh -- endeavour 182, the REAL mechanism on an H100 SXM.  ONE batched pod session.
#
# Run ON THE POD from the repo root, after run-on-pod.sh has built the branch:
#     bash scripts/182-pod-verify.sh > put_temp_files_here/182-verify/run.log 2>&1
# Then read put_temp_files_here/182-verify/SUMMARY.txt (small).
#
# The probe (scripts/182-pod-budget.sh) measured hand-inserted launch bounds.  This run measures what a
# user gets: the compiler stamping them from the hardware profile's :stream-occupancy-target, with the
# hand-maintained SXM profile (benchmarks/profiles/h100-sxm.crisp, --profile-file).  Expected: within
# noise of the probe's minCTA=4 column.
#
# WHAT WOULD MAKE THIS A WASTED RENTAL, stated in advance:
#   * the CUDA hoist specs fail -> stop before benchmarking (182/10 runs a bounded kernel on metal).
#   * every kernel shows 1056 / 792 groups (the unbounded counts) -> the profile file was not applied;
#     the summary prints groups per kernel so this is visible at a glance (bounded = 528 at local 256).
#
set -uo pipefail
export PATH=/usr/local/cuda/bin:$PATH

OUT_DIR="${OUT_DIR:-put_temp_files_here/182-verify}"
SIZES="${SIZES:-1,16,64,256,1024,4096}"
ITERS="${ITERS:-50}"
PROFILE="${PROFILE:-benchmarks/profiles/h100-sxm.crisp}"
mkdir -p "$OUT_DIR"
SUMMARY="$OUT_DIR/SUMMARY.txt"
: > "$SUMMARY"
say() { echo "$*" | tee -a "$SUMMARY"; }

say "=== endeavour 182 -- launch bounds from the hardware profile ==="
say "date: $(date -u +%FT%TZ)"
say "gpu:  $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1)"
say "head: $(git rev-parse --short HEAD) ($(git rev-parse --abbrev-ref HEAD))"
say "profile: $PROFILE ($(grep -c stream-occupancy-target "$PROFILE") key line(s))"
say ""

say "--- 1. CUDA hoist specs ---"
gate_ok=1
for f in 182-nvidia-register-budget 181-last-man-sweep; do
    sbcl --script tests/run-specs.lisp --skip-unit-tests --filter="$f" > "$OUT_DIR/specs-$f.log" 2>&1
    say "  $f: $(grep -h 'Spec Summary' "$OUT_DIR/specs-$f.log" | tail -1)"
    grep -h "Hoist\[CUDA\]" "$OUT_DIR/specs-$f.log" | sed 's/^Running Spec: /      /' | cut -c1-110 | tee -a "$SUMMARY" > /dev/null
    grep -q "Spec Summary: \([0-9]*\)/\1 Passed" "$OUT_DIR/specs-$f.log" || gate_ok=0
done
if [ "$gate_ok" != 1 ]; then say "STOP: a spec failed."; exit 1; fi
say ""

say "--- 2. Crisp sweep with the profile (sizes MiB: $SIZES) ---"
python3 scripts/crisp_bench/reduction.py --platform=nvidia --profile-file="$PROFILE" --sizes-mb="$SIZES" \
    --iters="$ITERS" --kernels=rollup/wg_atomic,rollup/wg_last_man,step4_grid_reduce,step5_reduce_vec,workloads \
    --scratch > "$OUT_DIR/crisp.log" 2>&1
say "  exit=$?"
grep -E "^Hardware|^== |MiB " "$OUT_DIR/crisp.log" | cut -c1-110 | tee -a "$SUMMARY" > /dev/null
say ""
say "=== done $(date -u +%FT%TZ) ==="
