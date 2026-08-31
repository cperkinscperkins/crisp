#!/usr/bin/env bash
#
# 159-pod-batch.sh — the ENTIRE endeavour-159 hardware session, as one command.
#
# WHY ONE SCRIPT.  A rented H100 bills by the minute and the API bills by the request, so the
# expensive shape is a conversation with the pod: many short commands, each one a round trip, each
# one re-sending the whole context.  A single blocking call that writes a compact summary is one
# request no matter how long it runs.  Everything here has already been run on the dev box as far
# as it can be without a GPU -- the fixture compiles under nvcc in docker and its whole binding
# path is validated by CRISP_MATMUL_DRYRUN -- so this should not be a debugging session.
#
# WHAT IT PROVES, and it is only this: that the 16-bit fragment LAYOUTS are right.  The instruction
# being emitted is already checked locally by tests/spec/159-nvidia-16bit/0{1,2}.  A store/load
# roundtrip cannot see a wrong-but-self-consistent layout, so an MMA against a host reference is
# the only thing that can, and that needs the GPU.
#
# Usage (ON THE POD, from the repo root, after run-on-pod.sh has installed deps):
#     bash scripts/159-pod-batch.sh 2>&1 | tail -5
#     # then, from the dev box:  scripts/pull-runpod-results.sh <host> <port>
#
set -uo pipefail

OUT_DIR="${OUT_DIR:-put_temp_files_here/159-pod}"
ARCH="${ARCH:-sm_90}"
SIZES="${SIZES:-256,512,1024}"
mkdir -p "$OUT_DIR"
SUMMARY="$OUT_DIR/SUMMARY.txt"
: > "$SUMMARY"

say() { echo "$*" | tee -a "$SUMMARY"; }

say "=== endeavour 159 pod batch ==="
say "date: $(date -u +%FT%TZ)"
say "gpu:  $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1)"
say "nvcc: $(nvcc --version 2>/dev/null | tail -1)"
say ""

# --- 1. build the compiler -----------------------------------------------------------------
say "[1/5] building the Crisp compiler..."
sbcl --non-interactive --load ./build/build.lisp > "$OUT_DIR/build.log" 2>&1
say "      build exit=$?  (log: $OUT_DIR/build.log)"

# --- 2. the local suites, on THIS machine ---------------------------------------------------
# Cheap, and it catches a platform difference before any of it is blamed on the GPU.  159 sits
# past ci-stop, so the rungs are run separately with ci-stop moved and then restored.
say "[2/5] spec suites..."
sbcl --script tests/run-specs.lisp > "$OUT_DIR/e2e.log" 2>&1
say "      e2e:      $(grep 'Spec Summary' "$OUT_DIR/e2e.log" | tail -1)"
say "      e2e passes in log: $(grep -c 'Spec Summary' "$OUT_DIR/e2e.log") (expect 1), crashes: $(grep -c 'unhandled condition' "$OUT_DIR/e2e.log")"

CI_STOP_ORIG="$(cat tests/ci-stop.txt)"
printf '159-nvidia-16bit' > tests/ci-stop.txt
sbcl --script tests/run-specs.lisp --filter=159-nvidia-16bit > "$OUT_DIR/159.log" 2>&1
say "      159 rungs: $(grep 'Spec Summary' "$OUT_DIR/159.log" | tail -1)"
git checkout -- tests/ci-stop.txt 2>/dev/null || printf '%s' "$CI_STOP_ORIG" > tests/ci-stop.txt
say "      ci-stop restored: $(cat tests/ci-stop.txt)"

# --- 3. THE POINT OF THE TRIP: 16-bit MMA correctness on metal ------------------------------
say "[3/5] 16-bit MMA on metal (fp16 + bf16), through the reviewed fixture..."
python3 scripts/verify-16bit-cuda.py --arch "$ARCH" --sizes "$SIZES" > "$OUT_DIR/159-verify.json" 2> "$OUT_DIR/159-verify.err"
VERIFY_RC=$?
say "      verify exit=$VERIFY_RC  (0 = every rung correct at every size)"
if command -v python3 >/dev/null; then
  python3 - "$OUT_DIR/159-verify.json" <<'PY' | tee -a "$SUMMARY"
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"      could not parse verify JSON: {e}"); sys.exit(0)
print(f"      fixture build ok: {d.get('fixture_build', {}).get('ok')}")
for r in d.get("rungs", []):
    print(f"      {r['kernel']}: compiled={r.get('compiled')} mnemonic={r.get('mnemonic_present')} tf32={r.get('tf32_present')}")
    for run in r.get("runs", []):
        print(f"        N={run.get('size')}: correct={run.get('correct')} "
              f"max_abs_err={run.get('max_abs_err')} median_us={run.get('kernel_median_us')} "
              f"gflops={run.get('gflops')} shared={run.get('shared_bytes')}")
PY
fi

# --- 3b. third-party benchmark dependencies ----------------------------------------------
# WITHOUT THIS THE PEER COLUMN IS EMPTY.  run-on-pod.sh installs SBCL/LLVM but NOT the benchmark
# third parties, so every CUTLASS config fails to build and writes a result file with zero data
# points -- "CUTLASS headers not found at build time -- this contender did NOT run".  The report
# then renders the peer as "--", which reads exactly like "we measured it and it was nothing".
# (The contender failing LOUDLY, with an error in its JSON rather than a fabricated time, is the
# Phase A hardening working -- but it only helps if someone reads the log.)
say "[3b/5] third-party benchmark deps (CUTLASS)..."
if [ -f scripts/setup-third-party.sh ]; then
  bash scripts/setup-third-party.sh cutlass > "$OUT_DIR/third-party.log" 2>&1
  say "      setup-third-party exit=$?  (log: $OUT_DIR/third-party.log)"
else
  say "      WARNING: scripts/setup-third-party.sh missing — the peer column WILL be empty"
fi

# --- 4. Phase A leftovers: the benchmark driver end to end -----------------------------------
# Phase A's numbers and binaries were verified in August; the INTEGRATION (driver -> result JSON ->
# report rendering the swept peer with its config named) never was.
say "[4/5] Phase A leftover: bench.py --platform=nvidia end to end..."
if [ -f scripts/bench.py ]; then
  python3 scripts/bench.py --platform=nvidia > "$OUT_DIR/bench.log" 2>&1
  say "      bench exit=$?  (log: $OUT_DIR/bench.log)"
  say "      result JSONs written: $(find benchmarks/results -newer "$SUMMARY" -name '*.json' 2>/dev/null | wc -l)"
else
  say "      SKIPPED — scripts/bench.py not found"
fi

# --- 5. Phase A leftover: regenerate the report ----------------------------------------------
say "[5/5] Phase A leftover: regenerate REPORT.md..."
if [ -f scripts/crisp_bench/report.py ]; then
  python3 scripts/crisp_bench/report.py --output benchmarks/REPORT.md > "$OUT_DIR/report.log" 2>&1
  say "      report exit=$?  (log: $OUT_DIR/report.log)"
else
  say "      SKIPPED — report.py not found at scripts/crisp_bench/report.py"
fi

say ""
say "=== done.  Pull $OUT_DIR back and read SUMMARY.txt + 159-verify.json. ==="
say "=== The pod can be released as soon as those two files are on the dev box. ==="
