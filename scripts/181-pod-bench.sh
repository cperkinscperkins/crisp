#!/usr/bin/env bash
#
# 181-pod-bench.sh -- endeavour 181 (last-man sweep) on an NVIDIA pod.  ONE batched session.
#
# Run ON THE POD from the repo root, after run-on-pod.sh has installed deps and built the branch:
#     bash scripts/181-pod-bench.sh > put_temp_files_here/181-pod/run.log 2>&1
# Then, locally: scripts/pull-runpod-results.sh <host> <port> <key> ~/crisp/benchmarks/results/scratch
# and read put_temp_files_here/181-pod/SUMMARY.txt (small) -- never the full log.
#
# WHAT WOULD MAKE THIS A WASTED RENTAL, stated in advance:
#   * the CUDA hoist specs fail -> the sweep would time a wrong answer.  So they run FIRST and a
#     failure stops the script before any benchmarking.
#   * the fixture rejects the plan's @groups tokens -> every last-man row errors.  The stale demo
#     (a last-man kernel through the same fixture) runs next, as the cheap probe of that.
#
# Everything is written to benchmarks/results/scratch/ (--scratch): this is an H100 SXM, not the
# NVL the published report used, so whether these rows become canonical is Chris's call.
#
set -uo pipefail
export PATH=/usr/local/cuda/bin:$PATH

OUT_DIR="${OUT_DIR:-put_temp_files_here/181-pod}"
SIZES="${SIZES:-1,16,64,256,1024,4096}"
ITERS="${ITERS:-50}"
mkdir -p "$OUT_DIR"
SUMMARY="$OUT_DIR/SUMMARY.txt"
: > "$SUMMARY"
say() { echo "$*" | tee -a "$SUMMARY"; }

say "=== endeavour 181 -- last-man sweep on NVIDIA ==="
say "date: $(date -u +%FT%TZ)"
say "gpu:  $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1)"
say "head: $(git rev-parse --short HEAD) ($(git rev-parse --abbrev-ref HEAD))"
say ""

# --- 1. correctness on metal: the CUDA hoist specs (181 twins + the pre-181 last-man CUDA specs) ----
say "--- 1. CUDA hoist specs ---"
gate_ok=1
for f in 181-last-man-sweep 07-grid-reduce-default-cuda 08-reduce-vec-sum-cuda; do
    sbcl --script tests/run-specs.lisp --skip-unit-tests --filter="$f" > "$OUT_DIR/specs-$f.log" 2>&1
    say "  $f: $(grep -h 'Spec Summary' "$OUT_DIR/specs-$f.log" | tail -1)"
    grep -h "^BUFFER out\|^BUFFER outv\|^BUFFER outi\|^BUFFER outs\|SKIP\|FAIL" "$OUT_DIR/specs-$f.log" \
        | grep -v "^;" | head -12 | sed 's/^/      /' | tee -a "$SUMMARY" > /dev/null
    grep -q "Spec Summary: \([0-9]*\)/\1 Passed" "$OUT_DIR/specs-$f.log" || gate_ok=0
done
if [ "$gate_ok" != 1 ]; then
    say "STOP: a CUDA hoist spec failed -- not benchmarking a wrong answer."
    exit 1
fi
say ""

# --- 1b. this device's read ceiling (the report's % column is against the NVL's; compute SXM's by hand) --
say "--- 1b. read ceiling ---"
mkdir -p benchmarks/results/scratch
nvcc -O3 -o /tmp/read_bw benchmarks/reduction/ceiling/read_bw.cu > "$OUT_DIR/ceiling-build.log" 2>&1
/tmp/read_bw --sizes-mb=64,256,1024,4096 --iters=20 --pattern=hash     --json=benchmarks/results/scratch/ceiling_nvidia_sxm_hash_$(date +%s).json > "$OUT_DIR/ceiling.log" 2>&1
tail -6 "$OUT_DIR/ceiling.log" | sed 's/^/  /' | tee -a "$SUMMARY" > /dev/null
say ""

# --- 2. the stale-state demo: a last-man kernel through the fixture, @groups plan included ----------
say "--- 2. stale demo ---"
python3 scripts/crisp_bench/reduction.py --platform=nvidia --auto-profile --stale-demo \
    > "$OUT_DIR/stale.log" 2>&1
say "  exit=$? : $(tail -2 "$OUT_DIR/stale.log" | tr '\n' ' ')"
say ""

# --- 3. Crisp rows: strategy rollup, ladder steps 3b/4/5, the four workloads ------------------------
say "--- 3. Crisp sweep (sizes MiB: $SIZES) ---"
python3 scripts/crisp_bench/reduction.py --platform=nvidia --auto-profile --sizes-mb="$SIZES" \
    --iters="$ITERS" --kernels=rollup,step3b_grid_stride_unrolled,step4_grid_reduce,step5_reduce_vec,workloads \
    --scratch > "$OUT_DIR/crisp.log" 2>&1
say "  exit=$?"
grep -E "^== |MiB " "$OUT_DIR/crisp.log" | tee -a "$SUMMARY" > /dev/null
say ""

# --- 4. contenders on THIS device (CUB / Thrust / cuBLAS), so the comparison is same-silicon --------
say "--- 4. contenders ---"
python3 scripts/crisp_bench/reduction.py --platform=nvidia --auto-profile --contenders --sizes-mb="$SIZES" \
    --iters="$ITERS" --scratch > "$OUT_DIR/contenders.log" 2>&1
say "  exit=$?"
grep -E "^== |MiB " "$OUT_DIR/contenders.log" | tee -a "$SUMMARY" > /dev/null

say ""
say "=== done $(date -u +%FT%TZ) ==="
