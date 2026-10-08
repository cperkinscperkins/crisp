#!/usr/bin/env bash
#
# 182-pod-budget.sh -- endeavour 182 (NVIDIA register budget) measurements.  ONE batched pod session.
#
# Run ON THE POD from the repo root, after run-on-pod.sh has built the branch AND the local
# overlays/crisp-compiler-overlay.lisp (which carries the CRISP_PROBE_PTX_MINCTA hook) has been copied
# over and the compiler rebuilt:
#     bash scripts/182-pod-budget.sh > put_temp_files_here/182-pod/run.log 2>&1
# Then read put_temp_files_here/182-pod/SUMMARY.txt (small).
#
# QUESTION: does a .minnctapersm launch bound (ptxas's register budget) bring every streaming reduction
# into the 90s on NVIDIA?  Offline SASS (put_temp_files_here/e182/) predicts: at the default 32
# registers last-man sum has ONE load in flight per thread; minCTA 6 -> 40 regs, 6 in flight; 5 -> 48
# regs, 14; 4 -> 53 regs, 16.  argmax spills inside its hot loop at minCTA 6 (and at 8), not at 5/4.
# Welford's loop has 4 loads and a division -- registers should NOT help it (a control).
#
# WHAT WOULD MAKE THIS A WASTED RENTAL, stated in advance:
#   * the probe hook not firing (every arm identical) -> the summary prints each arm's REGISTER count
#     from the fixture-side occupancy (groups), so identical groups across arms flags it at once.
#   * a verification failure -> launch bounds cannot change results; one would mean the PTX edit broke
#     the module.  Each arm's log keeps the fixture's verdict.
#
set -uo pipefail
export PATH=/usr/local/cuda/bin:$PATH

OUT_DIR="${OUT_DIR:-put_temp_files_here/182-pod}"
SIZES="${SIZES:-64,256,1024,4096}"
ITERS="${ITERS:-50}"
KERNELS="${KERNELS:-rollup/wg_atomic,step5_reduce_vec,workloads}"
mkdir -p "$OUT_DIR"
SUMMARY="$OUT_DIR/SUMMARY.txt"
: > "$SUMMARY"
say() { echo "$*" | tee -a "$SUMMARY"; }

say "=== endeavour 182 -- ptxas register budget (.minnctapersm) ==="
say "date: $(date -u +%FT%TZ)"
say "gpu:  $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1)"
say "head: $(git rev-parse --short HEAD) ($(git rev-parse --abbrev-ref HEAD))"
say "probe hook present: $(grep -c CRISP_PROBE_PTX_MINCTA overlays/crisp-compiler-overlay.lisp)"
say ""

for n in none 6 5 4; do
    if [ "$n" = none ]; then unset CRISP_PROBE_PTX_MINCTA; else export CRISP_PROBE_PTX_MINCTA=$n; fi
    python3 scripts/crisp_bench/reduction.py --platform=nvidia --auto-profile --sizes-mb="$SIZES" \
        --iters="$ITERS" --kernels="$KERNELS" --scratch > "$OUT_DIR/arm-$n.log" 2>&1
    rc=$?
    say "arm minCTA=$n exit=$rc rows=$(grep -cE '^ +[0-9]+ MiB' "$OUT_DIR/arm-$n.log") verified=$(grep -c ' verified' "$OUT_DIR/arm-$n.log")"
done
unset CRISP_PROBE_PTX_MINCTA
say ""

# --- compact table: kernel x arm -> us and groups at each size ---
python3 - "$OUT_DIR" <<'EOF' | tee -a "$SUMMARY"
import re, sys, pathlib
out = pathlib.Path(sys.argv[1])
arms = ['none', '6', '5', '4']
data = {}
for a in arms:
    kern = None
    for line in (out / f'arm-{a}.log').read_text().splitlines():
        m = re.match(r'== (\S+)', line)
        if m: kern = m.group(1); continue
        m = re.match(r'\s+(\d+) MiB\s+([\d.]+) us\s+([\d.]+) GB/s.*groups=(\d+)(.*)', line)
        if m and kern:
            data.setdefault(kern, {}).setdefault(int(m.group(1)), {})[a] = (
                float(m.group(2)), float(m.group(3)), int(m.group(4)), 'verified' in m.group(5))
for kern, sizes in data.items():
    print(f'\n{kern}')
    print('  MiB   ' + ''.join(f'{"minCTA=" + a:>24s}' for a in arms))
    for mb in sorted(sizes):
        cells = []
        for a in arms:
            v = sizes[mb].get(a)
            cells.append(f'{v[1]:7.0f} GB/s g={v[2]:<5d}{"" if v[3] else "!"}' if v else f'{"-":>24s}')
        print(f'  {mb:<5d} ' + ''.join(f'{c:>24s}' for c in cells))
EOF
say ""
say "=== done $(date -u +%FT%TZ) ==="
