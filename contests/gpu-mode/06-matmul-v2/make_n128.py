"""Wave-quantization probe (2026-11-11): v7 (matmul_b200_tcgen05_mn.crisp) with a 128 x 128 output tile.

The scored 4096 x 5120 x 4096 has 640 v7 tiles on 296 slots (2 CTAs x 148 SMs) = 2.16 waves (~72% full).
128 x 128 gives 1280 tiles; at ring 2 (64 KB) three CTAs fit an SM (444 slots, 2.88 waves, ~96%), at ring 3
(96 KB) two (296 slots, 4.32 waves, ~86%).  Writes matmul_b200_tcgen05_mn_n128_r{R}.crisp."""
import sys

src = open("matmul_b200_tcgen05_mn.crisp").read()


def rep(s, old, new, count=1):
    n = s.count(old)
    if n != count:
        sys.exit(f"expected {count} x {old!r}, found {n}")
    return s.replace(old, new)


for R in (2, 3):
    s = src
    s = rep(s, "(make-scratch-matrix-ring half (64 256) :ring-count 2)", f"(make-scratch-matrix-ring half (64 128) :ring-count {R})")
    s = rep(s, "(make-scratch-matrix-ring half (128 64) :ring-count 2)", f"(make-scratch-matrix-ring half (128 64) :ring-count {R})")
    s = rep(s, "(make-tcgen05-accumulator float (128 256) 0.0)", "(make-tcgen05-accumulator float (128 128) 0.0)", 2)
    s = rep(s, "(make-async-barrier-ring :ring-count 2 :mode :block :arrivals 1", f"(make-async-barrier-ring :ring-count {R} :mode :block :arrivals 1")
    s = rep(s, "(make-async-barrier-ring :ring-count 2 :mode :block :arrivals 2", f"(make-async-barrier-ring :ring-count {R} :mode :block :arrivals 2")
    s = rep(s, "(tile-stride C (128 256)", "(tile-stride C (128 128)")
    s = rep(s, "(tcgen05-accumulate-via-tile (128 256 64)", "(tcgen05-accumulate-via-tile (128 128 64)")
    s = rep(s, "(mod grid-k (to-ulong 2))", f"(mod grid-k (to-ulong {R}))", 2)
    s = rep(s, ";; Requires M % 128 = 0, N % 256 = 0, K % 64 = 0.", ";; Requires M % 128 = 0, N % 128 = 0, K % 64 = 0.")
    s = (f";; PROBE (2026-11-11, make_n128.py): v7 with a 128 x 128 output tile and a {R}-deep ring -- the scored\n"
         f";; shape's last-wave quantization.  Generated; edit make_n128.py, not this file.\n") + s
    open(f"matmul_b200_tcgen05_mn_n128_r{R}.crisp", "w", newline="\n").write(s)
    print(f"wrote matmul_b200_tcgen05_mn_n128_r{R}.crisp")

# Persistent at full occupancy (2026-11-11): the same kernels with a fixed grid of resident CTAs, so per-tile
# setup (tensor-memory alloc, barrier init, pipeline fill) is paid once per CTA, while 2 / 3 CTAs per SM
# still overlap one tile's epilogue with another's mainloop (the 1-per-SM persistent probe lost that).
GS = "(global-size :derive-from C :strategy :strided)"
for name, ctas in (("matmul_b200_tcgen05_mn.crisp", 296), ("matmul_b200_tcgen05_mn_n128_r2.crisp", 444)):
    s = rep(open(name).read(), GS, f"(global-size :set-to {ctas * 192})")
    out = name.replace(".crisp", f"_p{ctas}.crisp")
    s = (f";; PROBE (make_n128.py): {name} PERSISTENT -- {ctas} resident CTAs ({ctas // 148} per SM) walk the tiles.\n") + s
    open(out, "w", newline="\n").write(s)
    print(f"wrote {out}")
