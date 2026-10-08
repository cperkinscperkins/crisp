#!/usr/bin/env bash
#
# 182-pod-canonical.sh -- the CANONICAL NVIDIA reduction run after endeavours 181 + 182 were folded.
# ONE batched pod session, ONE card, results to benchmarks/results/ (not scratch).
#
# Run ON THE POD from the repo root, after run-on-pod.sh has built the branch:
#     bash scripts/182-pod-canonical.sh > put_temp_files_here/182-canonical/run.log 2>&1
# Then, locally:  scripts/pull-runpod-results.sh <host> <port> <key>
# and read put_temp_files_here/182-canonical/SUMMARY.txt (small).
#
# Order matters: the read ceiling FIRST -- every Crisp point records the ceiling file current when it
# ran, so the report's % column is against THIS card's peak (H100 SXM cards measured 3100-3179 GB/s).
# Every kernel compiles against benchmarks/profiles/h100-sxm.crisp (--profile-file), the profile that
# carries the measured :stream-occupancy-target.
#
# WHAT WOULD MAKE THIS A WASTED RENTAL, stated in advance:
#   * a CUDA hoist spec fails -> stop before benchmarking.
#   * the stale demo fails to CATCH its planted stale state -> the harness cannot be trusted; stop.
#   * bounded kernels at the unbounded group counts (1056 / 792 at local 256) -> the profile was not
#     applied; the summary prints groups per kernel.
#
set -uo pipefail
export PATH=/usr/local/cuda/bin:$PATH

OUT_DIR="${OUT_DIR:-put_temp_files_here/182-canonical}"
SIZES="${SIZES:-1,16,64,256,1024,4096}"
ITERS="${ITERS:-50}"
PROFILE="${PROFILE:-benchmarks/profiles/h100-sxm.crisp}"
mkdir -p "$OUT_DIR"
SUMMARY="$OUT_DIR/SUMMARY.txt"
: > "$SUMMARY"
say() { echo "$*" | tee -a "$SUMMARY"; }

say "=== canonical NVIDIA reduction run (endeavours 181 + 182 folded) ==="
say "date: $(date -u +%FT%TZ)"
say "gpu:  $(nvidia-smi --query-gpu=name,driver_version,clocks.max.mem --format=csv,noheader 2>/dev/null | head -1)"
say "head: $(git rev-parse --short HEAD) ($(git rev-parse --abbrev-ref HEAD))"
say "profile: $PROFILE"
say ""

say "--- 1. CUDA hoist specs ---"
gate_ok=1
for f in 182-nvidia-register-budget 181-last-man-sweep; do
    sbcl --script tests/run-specs.lisp --skip-unit-tests --filter="$f" > "$OUT_DIR/specs-$f.log" 2>&1
    say "  $f: $(grep -h 'Spec Summary' "$OUT_DIR/specs-$f.log" | tail -1)"
    grep -q "Spec Summary: \([0-9]*\)/\1 Passed" "$OUT_DIR/specs-$f.log" || gate_ok=0
done
if [ "$gate_ok" != 1 ]; then say "STOP: a spec failed."; exit 1; fi
say ""

say "--- 2. read ceiling (canonical) ---"
nvcc -O3 -o /tmp/read_bw benchmarks/reduction/ceiling/read_bw.cu > "$OUT_DIR/ceiling-build.log" 2>&1
/tmp/read_bw --sizes-mb=64,256,1024,4096 --iters=20 --pattern=hash \
    --json=benchmarks/results/ceiling_nvidia_hash_$(date +%s).json > "$OUT_DIR/ceiling.log" 2>&1
say "  $(grep 'PEAK READ' "$OUT_DIR/ceiling.log")"
say ""

say "--- 3. stale-state demo ---"
python3 scripts/crisp_bench/reduction.py --platform=nvidia --profile-file="$PROFILE" --stale-demo \
    > "$OUT_DIR/stale.log" 2>&1
rc=$?
say "  exit=$rc  $(grep -c CAUGHT "$OUT_DIR/stale.log") caught"
if [ "$rc" != 0 ]; then say "STOP: the stale demo did not catch its planted state."; exit 1; fi
say ""

say "--- 4. Crisp: ladder, rollup, workloads (sizes MiB: $SIZES) ---"
python3 scripts/crisp_bench/reduction.py --platform=nvidia --profile-file="$PROFILE" --sizes-mb="$SIZES" \
    --iters="$ITERS" > "$OUT_DIR/crisp.log" 2>&1
say "  exit=$?"
grep -E "^Hardware|^== |  (64|4096) MiB" "$OUT_DIR/crisp.log" | cut -c1-110 | tee -a "$SUMMARY" > /dev/null
say ""

say "--- 5. contenders (CUB / Thrust / cuBLAS) ---"
python3 scripts/crisp_bench/reduction.py --platform=nvidia --profile-file="$PROFILE" --contenders \
    --sizes-mb="$SIZES" --iters="$ITERS" > "$OUT_DIR/contenders.log" 2>&1
say "  exit=$?"
grep -E "^== |  4096 MiB" "$OUT_DIR/contenders.log" | cut -c1-110 | tee -a "$SUMMARY" > /dev/null
say ""
say "=== done $(date -u +%FT%TZ) ==="
