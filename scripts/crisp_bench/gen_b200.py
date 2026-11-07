"""Endeavour 209: generate the B200 (tcgen05) section-2 kernels from ONE template, so a difference
between two lanes is the FORMAT and nothing else.

usage (repo root):  python scripts/crisp_bench/gen_b200.py [--tune]
  default  writes the lane kernels into benchmarks/matmul/<lane>/
  --tune   writes the tuning variants into benchmarks/matmul/_b200_tune/ (fenced: `_` dir)
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MM = ROOT / "benchmarks" / "matmul"
SMS = 148                    # B200 SMs (benchmarks/profiles/b200.crisp :compute-units, QUERIED)
THREADS = 192                # epilogue warpgroup + producer warp + mma warp

# lane -> (dir, file, A/B elem, acc elem, C elem, K-step in elements, header line, extra prelude)
DENSE = {
    "tf32":  ("sec2_top",       "matmul_b200.crisp",       "float",    "float", "float", 32,  "tf32 (fp32 operands, tf32 MMA), fp32 C"),
    "bf16":  ("sec2_top_bf16",  "matmul_b200_bf16.crisp",  "bfloat16", "float", "float", 64,  "bf16 operands, fp32 accumulator and C"),
    "fp16":  ("sec2_top_fp16",  "matmul_b200_fp16.crisp",  "half",     "float", "float", 64,  "fp16 operands, fp32 accumulator and C"),
    "int8":  ("sec2_top_int8",  "matmul_b200_int8.crisp",  "char",     "int",   "int",   128, "s8 x s8 operands, s32 accumulator and C (kind::i8)"),
    "requant": ("sec4_int8_requant", "matmul_b200_int8_requant.crisp", "char", "(accum q-a)", "q-a", 128,
                "s8 x s8, s32 accumulator, C REQUANTIZED to s8: sat8(rne(acc * 0.003))"),
}
# block lanes: (dir, file, block name, base, scale, vec, K-step in codes)
BLOCK = {
    "nvfp4": ("sec2_top_nvfp4", "matmul_b200_nvfp4.crisp", "nvfp4", "fp4",      "fp8-e4m3", 16, 256),
    "mxfp4": ("sec2_top_mxfp4", "matmul_b200_mxfp4.crisp", "mxfp4", "fp4",      "fp8-e8m0", 32, 256),
    "mxfp8": ("sec2_top_mxfp8", "matmul_b200_mxfp8.crisp", "mxfp8", "fp8-e4m3", "fp8-e8m0", 32, 128),
}


def visit_lines(visit):
    """Header lines fixing the tile visit order of a persistent kernel: strip width VISIT (the
    harness exports it as CRISP_TILE_VISIT for this kernel's compile).  1 = the default flat walk."""
    if not visit or visit == 1:
        return []
    return [f";; Tile visit: column strips {visit} tiles wide (endeavour 144's grouped walk), for L2 reuse.",
            f";; BENCH-TILE-VISIT: grouped:{visit}"]


def dense_kernel(lane, ring=4, persistent=True, tn=256, visit=1):
    d, f, el, acc, cel, ks, what = DENSE[lane]
    requant = lane == "requant"
    hdr = [f";; Section 2, B200 (sm_100a) -- {what}.  Endeavour 209.",
           ";;",
           ";; GENERATED from ONE template by scripts/crisp_bench/gen_b200.py, so a difference between two",
           ";; B200 lanes is the FORMAT and nothing else.  Endeavour 208's kernel (spec 11's shape): warp-specialized",
           ";; :epilogue 4 / :producer 1 / :mma 1, a TMA ring of A and B^T tiles (128-byte swizzle), tcgen05 with the",
           ";; accumulator in tensor memory.",
           ";;"]
    if persistent:
        hdr += [f";; PERSISTENT: (global-size :set-to {SMS*THREADS}) is one workgroup per SM ({SMS} x {THREADS}); tile-stride",
                ";; walks ONE flat tile index over them (F-209-3), and the accumulator is a 2-slot RING in tensor memory",
                ";; (2 x 256 columns, all 512), so the epilogue stores tile t while the MMA warp computes tile t+1."]
        hdr += visit_lines(visit)
    else:
        hdr += [";; TILE GRID: one CTA per output tile, one accumulator (the chapter-7 shape)."]
    hdr += [f";; Ring depth {ring}: {ring} x (128 + {tn}) x {ks} elements of A/B per stage."]
    if requant:
        hdr += [";;",
                ";; The requantize epilogue of sec4_int8_requant/matmul_int8_requant.crisp (H100): `(to-q-a acc m)` on",
                ";; the store's source narrows each accumulator element as it is stored (205).  The harness reads",
                ";; the multiplier from the line below, so its oracle applies the same rule.",
                ";; BENCH-REQUANT-MULTIPLIER: 0.003"]
    hdr += [";; Requires sm_100a."]
    pre = ["(def-qint q-a :base char :accum int)"] if requant else []
    types = [f"(def-type a-mat (matrix {el} :address-space :global :align :compact :contiguous-term :row-major))",
             f"(def-type b-mat (matrix {el} :address-space :global :align :compact :contiguous-term :col-major))",
             f"(def-type c-mat (matrix {cel} :address-space :global :align :compact :contiguous-term :row-major))"]
    zero = "0" if acc != "float" else "0.0"
    gs = (f"(global-size :set-to {SMS*THREADS})" if persistent
          else "(global-size :derive-from C :strategy :strided)")
    if persistent:
        accf = f"(acc       (make-tcgen05-accumulator-ring {acc} (128 {tn}) :ring-count 2))"
        dsel = "(ring-get acc s)"
    else:
        accf = f"(D         (make-tcgen05-accumulator {acc} (128 {tn}) {zero}))"
        dsel = "D"
    if requant:
        store = (f"(store-tile-at (to-q-a {dsel} 0.003) C ((* grid-y (to-ulong 128)) (* grid-x (to-ulong {tn}))))")
    else:
        store = f"(store-tile {dsel} C (grid-y grid-x))"
    na = 2 if persistent else 1
    s = "s" if persistent else "0"
    body = f"""(def-kernel matmul (A B &out C)
  (declare #'(a-mat b-mat &out c-mat)
           {gs}
           (local-size :set-to {THREADS}))                 ; epilogue warpgroup + producer warp + mma warp
  (let ((A-ring    (make-scratch-matrix-ring {el} (128 {ks}) :ring-count {ring}))
        (B-ring    (make-scratch-matrix-ring {el} ({tn} {ks}) :ring-count {ring}))   ; B^T: N x K
        {accf}
        (K         (inner-dimension A B))
{"        (tiles     (to-ulong 0))" + chr(10) if persistent else ""}        (empty     (make-async-barrier-ring :ring-count {ring} :mode :block :arrivals 1 :initial-state :signaled))
        (full      (make-async-barrier-ring :ring-count {ring} :mode :block :arrivals 2 :initial-state :waiting))
        (acc-full  (make-async-barrier-ring :ring-count {na} :mode :block :arrivals 1 :initial-state :waiting))
        (acc-empty (make-async-barrier-ring :ring-count {na} :mode :block :arrivals 4 :initial-state :signaled)))
    (tile-stride C (128 {tn}) (grid-y grid-x)
"""
    roles = f"""(with-warp-specialization (:epilogue 4 :producer 1 :mma 1)
          (:epilogue
            (await (ring-get acc-full {s}))
            {store}
            (signal (ring-get acc-empty {s})))
          (:producer
            (dotimes (grid-k (/ (to-ulong K) (to-ulong {ks})))
              (let ((slot (mod grid-k (to-ulong {ring}))))
                (await (ring-get empty slot))
                (load-tile A (ring-get A-ring slot) (grid-y grid-k) :barrier (ring-get full slot) :swizzle :128b)
                (load-tile B (ring-get B-ring slot) (grid-x grid-k) :barrier (ring-get full slot) :swizzle :128b))))
          (:mma
            (await (ring-get acc-empty {s}))
"""
    if persistent:
        roles += f"""            (let ((D (ring-get acc s)))
              (dotimes (grid-k (/ (to-ulong K) (to-ulong {ks})))
                (let ((slot (mod grid-k (to-ulong {ring}))))
                  (await (ring-get full slot))
                  (tcgen05-accumulate-via-tile (128 {tn} {ks}) D (ring-get A-ring slot) (ring-get B-ring slot)
                                               :swizzle :128b :on-complete (ring-get empty slot)))))
            (tcgen05-commit (ring-get acc-full s))))"""
        body += f"""      (let ((s (mod tiles (to-ulong 2))))
        {roles})
      (set! tiles (+ tiles (to-ulong 1))))))
"""
    else:
        roles += f"""            (set! D (make-tcgen05-accumulator {acc} (128 {tn}) {zero}))
            (dotimes (grid-k (/ (to-ulong K) (to-ulong {ks})))
              (let ((slot (mod grid-k (to-ulong {ring}))))
                (await (ring-get full slot))
                (tcgen05-accumulate-via-tile (128 {tn} {ks}) D (ring-get A-ring slot) (ring-get B-ring slot)
                                             :swizzle :128b :on-complete (ring-get empty slot))))
            (tcgen05-commit (ring-get acc-full 0))))"""
        body += f"""      {roles})))
"""
    return "\n".join(hdr + [""] + pre + types + [""]) + "\n" + body


def block_kernel(lane, ring=3, persistent=True, visit=1):
    d, f, blk, base, scale, vec, ks = BLOCK[lane]
    epb = 2 if base == "fp4" else 1
    kb = ks // epb                                   # bytes per row per K-step (128)
    sa, sb = 128 * (ks // vec), 256 * (ks // vec)    # scale bytes per stage
    shape = ("PERSISTENT: one workgroup per SM, one flat tile walk (F-209-3)" if persistent
             else "TILE GRID: one workgroup per output tile")
    gs = (f"(global-size :set-to {SMS*THREADS})" if persistent
          else "(global-size :derive-from C :strategy :strided)")
    hdr = [f";; Section 2, B200 (sm_100a) -- {blk.upper()}: {base} codes, a {scale} scale per {vec}, fp32 accumulator and C.",
           ";; Endeavour 209.  GENERATED by scripts/crisp_bench/gen_b200.py (one template for every block lane).",
           ";;",
           f";; Endeavour 208's block-scaled pipeline (spec 16's shape), {shape}.",
           f";; Each ring slot is a codes tile plus its hidden scales tile; one K-step is {ks} codes",
           f";; ({kb} bytes).  A slot is {128*kb//1024} + {sa/1024:g} KB of A and {256*kb//1024} + {sb/1024:g} KB of B; ring depth {ring}.",
           ";; ONE accumulator, not a ring: 256 columns of accumulator plus the scales' columns already need",
           ";; the 512-column allocation, so a second 256-column slot does not fit."]
    hdr += (visit_lines(visit) if persistent else []) + [";; Requires sm_100a."]
    body = f"""(def-microfloat-block {blk} :base {base} :scale {scale} :accum float :shape ({vec}))
(def-type a-mat (matrix {blk} :address-space :global :align :compact :contiguous-term :row-major))
(def-type b-mat (matrix {blk} :address-space :global :align :compact :contiguous-term :col-major))
(def-type s-vec (vector (scale {blk}) :address-space :global :align :compact))
(def-type c-mat (matrix float :address-space :global :align :compact :contiguous-term :row-major))

(def-kernel matmul (A SA B SB &out C)
  (declare #'(a-mat s-vec b-mat s-vec &out c-mat)
           {gs}
           (local-size :set-to {THREADS})                  ; epilogue warpgroup + producer warp + mma warp
           (scale-layout SA :of A :blocked-128x4)
           (scale-layout SB :of B :blocked-128x4))
  (let ((A-ring    (make-scratch-matrix-ring {blk} (128 {ks}) :ring-count {ring}))
        (B-ring    (make-scratch-matrix-ring {blk} (256 {ks}) :ring-count {ring}))
        (D         (make-tcgen05-accumulator float (128 256) 0.0))
        (K         (inner-dimension A B))
        (empty     (make-async-barrier-ring :ring-count {ring} :mode :block :arrivals 1 :initial-state :signaled))
        (full      (make-async-barrier-ring :ring-count {ring} :mode :block :arrivals 2 :initial-state :waiting))
        (acc-full  (make-async-barrier-ring :ring-count 1 :mode :block :arrivals 1 :initial-state :waiting))
        (acc-empty (make-async-barrier-ring :ring-count 1 :mode :block :arrivals 4 :initial-state :signaled)))
    (tile-stride C (128 256) (grid-y grid-x)
      (with-warp-specialization (:epilogue 4 :producer 1 :mma 1)
        (:epilogue
          (await (ring-get acc-full 0))
          (store-tile D C (grid-y grid-x))
          (signal (ring-get acc-empty 0)))
        (:producer
          (dotimes (grid-k (/ (to-ulong K) (to-ulong {ks})))
            (let ((slot (mod grid-k (to-ulong {ring}))))
              (await (ring-get empty slot))
              (load-tile A (ring-get A-ring slot) (grid-y grid-k) :scales SA :barrier (ring-get full slot) :swizzle :128b)
              (load-tile B (ring-get B-ring slot) (grid-x grid-k) :scales SB :barrier (ring-get full slot) :swizzle :128b))))
        (:mma
          (await (ring-get acc-empty 0))
          (set! D (make-tcgen05-accumulator float (128 256) 0.0))
          (dotimes (grid-k (/ (to-ulong K) (to-ulong {ks})))
            (let ((slot (mod grid-k (to-ulong {ring}))))
              (await (ring-get full slot))
              (tcgen05-accumulate-via-tile (128 256 {ks}) D (ring-get A-ring slot) (ring-get B-ring slot)
                                           :swizzle :128b :on-complete (ring-get empty slot))))
          (tcgen05-commit (ring-get acc-full 0)))))))
"""
    return "\n".join(hdr) + "\n\n" + body


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, newline="\n")
    print("wrote", path.relative_to(ROOT))


if __name__ == "__main__":
    if "--tune" in sys.argv:
        # Round 2 (after F-209-3): persistent at ring 3 / 4 x strip width 1 / 2 / 4, and the tile grid at
        # ring 2 (two workgroups per SM -- chapter 7's winning shape) and 4.  Block lanes: persistent
        # ring 3 / 4 x width 1 / 2, tile grid ring 2 / 3.
        T = MM / "_b200_tune"
        for old in T.glob("*.crisp"):
            old.unlink()
        for lane in DENSE:
            for ring in (3, 4):
                for w in (1, 2, 4):
                    write(T / f"{lane}_p_r{ring}_w{w}.crisp", dense_kernel(lane, ring, True, visit=w))
            for ring in (2, 4):
                write(T / f"{lane}_tg_r{ring}.crisp", dense_kernel(lane, ring, False))
        for lane in BLOCK:
            for ring in (3, 4):
                for w in (1, 2):
                    write(T / f"{lane}_p_r{ring}_w{w}.crisp", block_kernel(lane, ring, True, visit=w))
            for ring in (2, 3):
                write(T / f"{lane}_tg_r{ring}.crisp", block_kernel(lane, ring, False))
    else:
        for lane, (d, f, *_r) in DENSE.items():
            write(MM / d / f, dense_kernel(lane, 4, True))
        for lane, (d, f, *_r) in BLOCK.items():
            write(MM / d / f, block_kernel(lane, 3))
