#!/usr/bin/env bash
#
# 165-pod-ladder.sh — the 64-bit MMA Techniques ladder, measured.  One batched pod session.
#
# WHY ieee AND NOT fast.  Every other ladder in this tree is benchmarked at --precision=fast.
# The 64-bit endeavour is explicitly an IEEE exercise (see tests/spec/165-64-bit-mma/64-bit-mma.md):
# fp64 exists to be correct, and measuring it under fast math would be measuring something nobody
# would ship.  This is the one ladder where the precision flag is part of the question.
#
# SMOKE FIRST, ALWAYS.  Every chapter runs at N=256 before the sweep.  These kernels have never
# executed -- they are compile-verified and PTX-inspected only -- so the first contact should be
# cheap.  The fixture resolves every binding decision (argument slots, scratch offsets, shared
# total, tensormap descriptors) from the metacrisp, and a mistake there shows up as `correct:
# false` at 256 in seconds rather than after a full sweep.
#
# WHAT WOULD MAKE THIS A WASTED RENTAL, stated in advance:
#   * a chapter that does not build -> the ladder has a hole, and it is a compile bug we could
#     have caught on the dev box.  All seven compile locally, so this should not happen.
#   * `correct: false` everywhere -> a fixture binding bug, not a kernel bug.  The env extraction
#     was validated on the dev box for chap4 (ELEM=f64, scratch 16:32 + 64:16, both tensormaps,
#     arg indices from the metacrisp), so the plumbing is exercised.
#   * running the sweep before the smoke -> paying sweep prices for a binding mistake.
#
# Usage (ON THE POD, from the repo root, after run-on-pod.sh has installed deps and built):
#     bash scripts/165-pod-ladder.sh 2>&1 | tail -40
#
set -uo pipefail

export PATH=/usr/local/cuda/bin:$PATH

OUT_DIR="${OUT_DIR:-put_temp_files_here/165-ladder}"
SIZES="${SIZES:-1024,2048,4096,8192}"
SMOKE_SIZE="${SMOKE_SIZE:-256}"
PRECISION="${PRECISION:-ieee}"

# The ladder AND section 2 in ONE sweep.  Two reasons, both learned the hard way:
#  * load_all_sweeps keeps the NEWEST file per run identity, so a PARTIAL re-run SUPERSEDES an
#    earlier one instead of merging with it.  Running N=8192 on its own last time wiped chapters
#    4-6's smaller sizes out of the report.  Every size a chapter needs must be in one sweep.
#  * a published section 2 assembled by hand from two different runs is not one measurement.
CHAPTERS="chap0_naive_f64,chap1_handrolled_mma_f64,chap2_tiling_f64,chap3_async_f64,chap4_cheap_fetch_f64,chap5_multistage_ring_f64,chap6_warp_specialization_f64,sec2_top_f64"

mkdir -p "$OUT_DIR"
SUMMARY="$OUT_DIR/SUMMARY.txt"
: > "$SUMMARY"
say() { echo "$*" | tee -a "$SUMMARY"; }

say "=== endeavour 165 — the 64-bit technique ladder ==="
say "date: $(date -u +%FT%TZ)"
say "gpu:  $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1)"
say "nvcc: $(nvcc --version 2>/dev/null | tail -1)"
say "precision: $PRECISION   sizes: $SIZES"
say ""

# --- 1. SMOKE: every chapter at one small size --------------------------------------------------
say "--- smoke (N=$SMOKE_SIZE): do these kernels run at all? ---"
python3 scripts/crisp_bench/matmul.py \
    --chapters="$CHAPTERS" --sizes="$SMOKE_SIZE" \
    --precision="$PRECISION" --warmup=2 --iters=5 --scratch \
    > "$OUT_DIR/smoke.log" 2>&1
say "smoke exit=$?"
# The driver writes results to JSON and only echoes progress, so ALSO inspect what it saved --
# grepping the console log alone is what made the first gate ineffective.
python3 - <<'PYCHK' 2>&1 | tee -a "$SUMMARY"
import json, glob
bad = []
for f in glob.glob("benchmarks/results/scratch/*f64*.json"):
    d = json.load(open(f))
    for r in d.get("results", []):
        if r.get("configuration", {}).get("verified") is False:
            bad.append((d.get("chapter"), r["configuration"].get("m")))
print("SMOKE VERIFIED-CHECK: " + ("all chapters verified"
      if not bad else "UNVERIFIED -> " + ", ".join("%s@N=%s" % b for b in bad)))
PYCHK
if python3 -c "
import json,glob,sys
bad=[1 for f in glob.glob('benchmarks/results/scratch/*f64*.json')
     for r in json.load(open(f)).get('results',[])
     if r.get('configuration',{}).get('verified') is False]
sys.exit(1 if bad else 0)"; then :; else
  say "!!! SMOKE: a chapter reported verified=false in its saved result — stopping before the sweep."
  exit 1
fi
grep -E "chap[0-9].*f64|correct|TFLOPS|GFLOPS|FAIL|ERROR" "$OUT_DIR/smoke.log" | tail -25 | tee -a "$SUMMARY"
say ""

# A chapter that reports correct=false at 256 will report correct=false at 4096 too, and much
# more slowly.  Stop rather than pay for it.
# THE FIELD IS `verified`, NOT `correct`.  The first version of this gate grepped for
# '"correct": false' -- which the CUDA fixture never emits; its correctness flag is `verified`,
# under results[].configuration.  So the gate silently never fired, and the 2026-09-07 sweep
# published two chapters (chap2, chap6) whose numbers were invalid.  A guard that tests the wrong
# field is worse than no guard: it buys false confidence at the price of a rental.
# Both spellings are checked now, because the L0 fixture and the hoist harness DO say "correct"
# / MMA_WRONG, and a gate should not be specific to whichever harness ran.
if grep -qiE '"verified": *false|"correct": *false|MMA_WRONG' "$OUT_DIR/smoke.log"; then
  say "!!! SMOKE FOUND AN INCORRECT CHAPTER — stopping before the sweep."
  say "    Look at $OUT_DIR/smoke.log; this is a binding or a kernel bug, and the sweep would"
  say "    only reproduce it at greater cost."
  exit 1
fi

# --- 2. THE SWEEP -------------------------------------------------------------------------------
say "--- ladder sweep (N=$SIZES) ---"
# NO --scratch ON THE REAL SWEEP.  generate_report merges only benchmarks/results/ and never
# scratch/ -- load_scratch_runs is loaded but its runs are not folded into the report data -- so a
# --scratch sweep produces numbers the report can never display.  The SMOKE above keeps --scratch
# precisely because it is throwaway.
python3 scripts/crisp_bench/matmul.py \
    --chapters="$CHAPTERS" --sizes="$SIZES" \
    --precision="$PRECISION" \
    > "$OUT_DIR/sweep.log" 2>&1
say "sweep exit=$?"
grep -E "chap[0-9].*f64|TFLOPS|GFLOPS|correct" "$OUT_DIR/sweep.log" | tail -60 | tee -a "$SUMMARY"
say ""

say "logs:    $OUT_DIR/{smoke,sweep}.log"
say "results: benchmarks/results/  (JSON, pull with scripts/pull-runpod-results.sh)"
say "=== DONE ==="
