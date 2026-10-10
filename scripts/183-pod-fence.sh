#!/usr/bin/env bash
#
# 183-pod-fence.sh -- endeavour 183 (last-man fence: thread 0 releases, elected group acquires) on an
# H100 SXM.  ONE batched pod session; results to benchmarks/results/scratch/.
#
# Run ON THE POD from the repo root, after run-on-pod.sh has built the branch:
#     bash scripts/183-pod-fence.sh > put_temp_files_here/183-pod/run.log 2>&1
# Then read put_temp_files_here/183-pod/SUMMARY.txt (small).
#
# The comparison is WITHIN the session -- last-man against :atomic on the same card, same grid -- so no
# second (pre-183) compiler build is needed.  The canonical run (75d13e22, same profile) had last-man at
# 13.0 / 16.0 / 39.6 / 103.9 us against :atomic's 6.8 / 8.6 / 28.8 / 92.4 us at 1 / 16 / 64 / 256 MiB:
# a ~6-11 us fixed gap.  183 should shrink it.
#
# WHAT WOULD MAKE THIS A WASTED RENTAL, stated in advance:
#   * a CUDA hoist spec fails (181/182/183 include last-man on metal) -> stop before benchmarking.
#   * the stale demo misses its planted state -> the last-man counter reset (179) broke; stop.
#
set -uo pipefail
export PATH=/usr/local/cuda/bin:$PATH

OUT_DIR="${OUT_DIR:-put_temp_files_here/183-pod}"
SIZES="${SIZES:-1,16,64,256,1024,4096}"
ITERS="${ITERS:-100}"
PROFILE="${PROFILE:-benchmarks/profiles/h100-sxm.crisp}"
mkdir -p "$OUT_DIR"
SUMMARY="$OUT_DIR/SUMMARY.txt"
: > "$SUMMARY"
say() { echo "$*" | tee -a "$SUMMARY"; }

say "=== endeavour 183 -- last-man fence on NVIDIA ==="
say "date: $(date -u +%FT%TZ)"
say "gpu:  $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1)"
say "head: $(git rev-parse --short HEAD) ($(git rev-parse --abbrev-ref HEAD))"
say ""

say "--- 1. CUDA hoist specs ---"
gate_ok=1
for f in 183-last-man-fence 182-nvidia-register-budget 181-last-man-sweep; do
    sbcl --script tests/run-specs.lisp --skip-unit-tests --filter="$f" > "$OUT_DIR/specs-$f.log" 2>&1
    say "  $f: $(grep -h 'Spec Summary' "$OUT_DIR/specs-$f.log" | tail -1)"
    grep -q "Spec Summary: \([0-9]*\)/\1 Passed" "$OUT_DIR/specs-$f.log" || gate_ok=0
done
if [ "$gate_ok" != 1 ]; then say "STOP: a spec failed."; exit 1; fi
say ""

say "--- 2. stale-state demo ---"
python3 scripts/crisp_bench/reduction.py --platform=nvidia --profile-file="$PROFILE" --stale-demo \
    > "$OUT_DIR/stale.log" 2>&1
rc=$?
say "  exit=$rc  $(grep -c CAUGHT "$OUT_DIR/stale.log") caught"
if [ "$rc" != 0 ]; then say "STOP: the stale demo did not catch its planted state."; exit 1; fi
say ""

say "--- 3. last-man vs :atomic, same session (sizes MiB: $SIZES) ---"
python3 scripts/crisp_bench/reduction.py --platform=nvidia --profile-file="$PROFILE" --sizes-mb="$SIZES" \
    --iters="$ITERS" --kernels=rollup/wg_atomic,rollup/wg_last_man,step5_reduce_vec,workloads \
    --scratch > "$OUT_DIR/crisp.log" 2>&1
say "  exit=$?"
grep -E "^== |MiB " "$OUT_DIR/crisp.log" | sed 's/  (.*crisp-compile [0-9]* ms)//' | cut -c1-100 \
    | tee -a "$SUMMARY" > /dev/null
say ""
say "=== done $(date -u +%FT%TZ) ==="
