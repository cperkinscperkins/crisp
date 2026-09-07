#!/usr/bin/env bash
#
# 165-pod-sec2.sh — the §2 fp64 COMPETITOR session for endeavour 165, as one command.
#
# WHY THIS RUNS BEFORE ANY CRISP KERNEL EXISTS.  The 64-bit ladder's whole justification is that
# fp64 tensor cores (DMMA) beat vector fp64 by enough to be worth seven chapters.  cuBLAS can
# answer that outright: CUBLAS_COMPUTE_64F is free to use DMMA, CUBLAS_COMPUTE_64F_PEDANTIC is
# not, and both compute the SAME IEEE double result.  The ratio between those two arms is the
# ceiling of everything we were about to build, measured by NVIDIA's own tuned code.
#
#   ~2x  -> the ladder is worth building, roughly as planned (vendor figures for H100 imply this)
#   ~1.3x -> chapter 1 is a formality and the 64-bit story is data movement from top to bottom
#
# It also settles the CUTLASS question.  The tf32/16-bit peers are CUTLASS 3.x on arch::Sm90, and
# that machinery is wgmma-based; there is no fp64 wgmma, so the f64 peer is the 2.x device API on
# arch::Sm80 instead.  Confirmed on the dev box before renting anything: CUTLASS dc45f97 defines
# exactly ONE f64 tensor-op MMA, GemmShape<8,8,4> with 1/1/2 doubles per lane, and our LLVM
# (21.1.5) lowers only llvm.nvvm.mma.m8n8k4.row.col.f64 -- the sm_90 f64 shapes silently become
# an .extern .func call.  Two independent sources, same answer.
#
# NO COMPILER BUILD.  There is no Crisp kernel in this session, so this needs nvcc and the CUTLASS
# headers and nothing else -- no SBCL, no LLVM, no quicklisp.  That makes it the cheapest possible
# rental: minutes, not an hour.
#
# THE ORACLE IS NOT A = B = 1.  See benchmarks/matmul/sec2_top_f64/f64_oracle.h.  Every other
# matmul benchmark here checks C == K, which passes identically whether the GEMM ran in fp64 or
# fp32 -- useless for the one endeavour that is about IEEE double.  Both contenders instead fill
# A and B with 1 + 2^-25, a value fp32 rounds away and fp64 keeps, and report a
# precision_diagnosis that names a single-precision path when it sees one.  The discriminator is
# verified on the dev box: fp64 lands at 6.7e-16 relative, a simulated fp32 path at 5.96e-08,
# and the tolerance is 1e-10 between them.
#
# Usage (ON THE POD, from the repo root):
#     SMOKE=1 bash scripts/165-pod-sec2.sh 2>&1 | tail -20    # prove the apparatus first
#     bash scripts/165-pod-sec2.sh 2>&1 | tail -40            # the real sweep
#     # then, from the dev box:  scripts/pull-runpod-results.sh <host> <port>
#
set -uo pipefail

OUT_DIR="${OUT_DIR:-put_temp_files_here/165-pod}"
SRC_DIR="benchmarks/matmul/sec2_top_f64"
ARCH="${ARCH:-sm_90}"
CUTLASS_ARCH="${CUTLASS_ARCH:-sm_90a}"
WARMUP="${WARMUP:-20}"
ITERS="${ITERS:-100}"

# fp64 costs 8 bytes/element, so the sizes stop lower than the 16-bit sweeps do: N=8192 is already
# ~1.6 GB of host buffers across A/B/C, N=16384 would be ~6.4 GB.  Raise SIZES deliberately, not
# by habit.
SIZES="${SIZES:-1024,2048,4096,8192}"

# SMOKE=1 -- prove the APPARATUS before spending the rental on the sweep.  Every contender still
# builds and runs, at one tiny size, so a missing header or a config CUTLASS refuses to
# instantiate surfaces in a minute rather than at the end.  159 came back with an empty peer
# column because CUTLASS could not build; a smoke run would have said so immediately.
SMOKE="${SMOKE:-0}"
if [ "$SMOKE" = "1" ]; then
  SIZES="256"
  WARMUP=2
  ITERS=5
fi

mkdir -p "$OUT_DIR"
SUMMARY="$OUT_DIR/SUMMARY.txt"
RESULTS="$OUT_DIR/results.jsonl"
DONE_FILE="$OUT_DIR/DONE"
: > "$SUMMARY"
: > "$RESULTS"
# The sentinel is the ONLY trustworthy completion signal: an ssh call returning proves the
# CONNECTION ended, not that the work did.  Cleared at start so a stale one cannot be mistaken
# for this run.
rm -f "$DONE_FILE"

say() { echo "$*" | tee -a "$SUMMARY"; }

say "=== endeavour 165 — §2 fp64 competitors ==="
say "date:   $(date -u +%FT%TZ)"
say "gpu:    $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1)"
say "nvcc:   $(nvcc --version 2>/dev/null | tail -1)"
say "sizes:  $SIZES   (warmup=$WARMUP iters=$ITERS smoke=$SMOKE)"
say ""

# --- 0. CUTLASS headers ---------------------------------------------------------------------
CUTLASS_INC=""
for cand in third_party/cutlass /workspace/cutlass "$HOME/cutlass"; do
  if [ -f "$cand/include/cutlass/gemm/device/gemm.h" ]; then CUTLASS_INC="$cand"; break; fi
done
if [ -z "$CUTLASS_INC" ]; then
  say "cutlass: NOT FOUND — fetching"
  bash scripts/setup-third-party.sh cutlass >>"$SUMMARY" 2>&1
  [ -f "third_party/cutlass/include/cutlass/gemm/device/gemm.h" ] && CUTLASS_INC="third_party/cutlass"
fi
if [ -n "$CUTLASS_INC" ]; then
  say "cutlass: $CUTLASS_INC ($(git -C "$CUTLASS_INC" rev-parse --short HEAD 2>/dev/null || echo '?'))"
else
  say "cutlass: UNAVAILABLE — the peer column will be a visible gap, not a silent zero"
fi
say ""

BIN_DIR="$OUT_DIR/bin"
mkdir -p "$BIN_DIR"

# --- 1. build the two cuBLAS arms ------------------------------------------------------------
# The PEDANTIC arm is the measurement this session exists for; it is not an afterthought.
say "--- building cuBLAS arms ---"
for arm in "64F:" "64F_PEDANTIC:-DPEDANTIC"; do
  name="${arm%%:*}"; flag="${arm#*:}"
  out="$BIN_DIR/cublas_f64_${name}"
  if nvcc -O3 -arch="$ARCH" $flag "$SRC_DIR/cublas_ceiling_f64.cu" -o "$out" -lcublas \
       >"$OUT_DIR/build_cublas_${name}.log" 2>&1; then
    say "  cublas $name: built"
  else
    say "  cublas $name: BUILD FAILED — see build_cublas_${name}.log"
    tail -20 "$OUT_DIR/build_cublas_${name}.log" >> "$SUMMARY"
  fi
done
say ""

# --- 2. build the CUTLASS peer configs --------------------------------------------------------
# The INSTRUCTION shape is fixed at 8x8x4 (the only fp64 tensor-core shape); only the
# threadblock/warp tiling and stage count are swept.  Every entry's warp shape tiles its
# threadblock exactly -- CFG_TILE_M/CFG_WARP_M * CFG_TILE_N/CFG_WARP_N is the warp count.
CUTLASS_CONFIGS=(
  "64x64x16w32x32s4:-DCFG_TILE_M=64  -DCFG_TILE_N=64  -DCFG_TILE_K=16 -DCFG_WARP_M=32 -DCFG_WARP_N=32 -DCFG_STAGES=4"
  "128x128x16w32x64s3:-DCFG_TILE_M=128 -DCFG_TILE_N=128 -DCFG_TILE_K=16 -DCFG_WARP_M=32 -DCFG_WARP_N=64 -DCFG_STAGES=3"
  "128x64x16w64x32s3:-DCFG_TILE_M=128 -DCFG_TILE_N=64  -DCFG_TILE_K=16 -DCFG_WARP_M=64 -DCFG_WARP_N=32 -DCFG_STAGES=3"
  "64x128x16w32x64s3:-DCFG_TILE_M=64  -DCFG_TILE_N=128 -DCFG_TILE_K=16 -DCFG_WARP_M=32 -DCFG_WARP_N=64 -DCFG_STAGES=3"
  "32x32x16w32x32s4:-DCFG_TILE_M=32  -DCFG_TILE_N=32  -DCFG_TILE_K=16 -DCFG_WARP_M=32 -DCFG_WARP_N=32 -DCFG_STAGES=4"
)
say "--- building CUTLASS f64 peer configs ---"
BUILT_CUTLASS=()
for entry in "${CUTLASS_CONFIGS[@]}"; do
  name="${entry%%:*}"; flags="${entry#*:}"
  out="$BIN_DIR/cutlass_f64_${name}"
  inc=""
  [ -n "$CUTLASS_INC" ] && inc="-I$CUTLASS_INC/include -I$CUTLASS_INC/tools/util/include"
  # shellcheck disable=SC2086
  if nvcc -O3 -std=c++17 -arch="$CUTLASS_ARCH" $inc $flags "$SRC_DIR/cutlass_peer_f64.cu" -o "$out" \
       >"$OUT_DIR/build_cutlass_${name}.log" 2>&1; then
    say "  cutlass $name: built"
    BUILT_CUTLASS+=("$name")
  else
    # A config CUTLASS refuses to instantiate is INFORMATION -- record which one and why.
    say "  cutlass $name: BUILD FAILED — see build_cutlass_${name}.log"
    grep -m3 -E "error" "$OUT_DIR/build_cutlass_${name}.log" | sed 's/^/      /' >> "$SUMMARY"
  fi
done
say ""

# --- 3. run -----------------------------------------------------------------------------------
run_one() {
  local label="$1" exe="$2" S="$3"
  [ -x "$exe" ] || return 0
  local json
  json="$("$exe" "$S" "$S" "$S" "$WARMUP" "$ITERS" 2>>"$OUT_DIR/run_stderr.log")"
  local rc=$?
  # One JSON object per line, with the label and size attached, so the dev box reads a compact
  # file instead of a transcript.
  echo "{\"label\": \"$label\", \"size\": $S, \"exit\": $rc, \"json\": $(echo "$json" | tr -d '\n')}" \
    >> "$RESULTS"
  local g c d
  g="$(echo "$json" | grep -o '"gflops":[^,}]*' | head -1 | cut -d: -f2 | tr -d ' ')"
  c="$(echo "$json" | grep -o '"correct":[^,}]*' | head -1 | cut -d: -f2 | tr -d ' ')"
  d="$(echo "$json" | grep -o '"precision_diagnosis": *"[^"]*"' | head -1 | sed 's/.*: *"//; s/"$//')"
  printf "  %-28s %6d  %12s GFLOPS  correct=%-6s %s\n" \
    "$label" "$S" "${g:-—}" "${c:-—}" "${d:-}" | tee -a "$SUMMARY"
}

IFS=',' read -ra SIZE_LIST <<< "$SIZES"
for S in "${SIZE_LIST[@]}"; do
  say "--- N = $S ---"
  run_one "cublas_64F"           "$BIN_DIR/cublas_f64_64F"           "$S"
  run_one "cublas_64F_PEDANTIC"  "$BIN_DIR/cublas_f64_64F_PEDANTIC"  "$S"
  for name in ${BUILT_CUTLASS[@]+"${BUILT_CUTLASS[@]}"}; do
    run_one "cutlass_$name" "$BIN_DIR/cutlass_f64_${name}" "$S"
  done
  say ""
done

# --- 4. the headline ---------------------------------------------------------------------------
# The DMMA/vector ratio is the number this whole session was rented for, so it is computed here
# rather than left for someone to divide by hand off a table.
say "--- DMMA vs vector fp64 (the ladder's ceiling) ---"
for S in "${SIZE_LIST[@]}"; do
  a="$(grep "\"label\": \"cublas_64F\", \"size\": $S," "$RESULTS" | grep -o '"gflops":[^,}]*' | head -1 | cut -d: -f2 | tr -d ' ')"
  b="$(grep "\"label\": \"cublas_64F_PEDANTIC\", \"size\": $S," "$RESULTS" | grep -o '"gflops":[^,}]*' | head -1 | cut -d: -f2 | tr -d ' ')"
  if [ -n "$a" ] && [ -n "$b" ]; then
    r="$(awk -v x="$a" -v y="$b" 'BEGIN{ if (y>0) printf "%.2f", x/y; else print "—" }')"
    say "  N=$S  tensor-core $a / vector $b  =  ${r}x"
  fi
done
say ""
say "results:  $RESULTS"
say "summary:  $SUMMARY"
touch "$DONE_FILE"
say "=== DONE ==="
