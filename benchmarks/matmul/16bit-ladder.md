# The Technique Ladder in 16-bit (Intel BMG)

> **The live table is `REPORT.md` § 1b**, generated from the sweep data on every run. This file is
> the *findings* — the scaling analysis, the caveats, and what building the ladder exposed. It
> deliberately does not restate the numbers, because two hand-maintained copies of the same table
> is the drift problem this benchmark work exists to remove.

Chapters 0–5 in bfloat16. Each kernel is its tf32 twin with exactly two changes: the operand element
type (`float` → `bfloat16`; the C accumulator stays f32, since XMX accumulates in f32 either way)
and the K step 8 → 16, the native XMX shape for 16-bit operands being `(8 16 16)` rather than
`(8 16 8)`. Tile K extents follow.

One deliberate third difference: the bf16 twins carry `(declaim (precision fast))`, which the tf32
originals do not. The shipped §2.1 bf16 kernels carry it and bf16 is an approximate format whose
point is throughput. It is a second variable — if a ratio looks anomalous, re-test that first.

## The scaling factor

Measured on an Arc B580 through the fixture harness, over the chapters that are correct and
non-degenerate (Ch 1, 2, 4, 5 — sixteen data points):

    min 1.46x   median 1.78x   mean 1.84x   max 2.79x

**Centred just under 2×, and nowhere near 4×.** That is what the hardware's own shape ladder
predicts: `(8 16 8)` tf32 → `(8 16 16)` bf16 → `(8 16 32)` int8, same M×N with K doubling per step.
One DPAS does twice the MACs in bf16 as in tf32 at the same issue rate, so 2× is the
instruction-level ceiling for that switch; **4× is the tf32→int8 step**, one rung further down.

Two caveats on reading that.

**The 32-bit baseline here is tf32 ON XMX**, not fp32 on the vector engines. Against the latter a
much larger factor would be expected, and it would be a different comparison entirely. If someone
expects 4×, this is usually the disagreement.

**The points above 2.0× are the memory path, not the arithmetic path.** Ch 4 reaches 2.28× at 2048
and 2.79× at 8192; Ch 5 reaches 2.13× at 4096. Halving the operand bytes buys cache behaviour on top
of the doubled K, which is how a ratio exceeds the instruction-level ceiling. Note it is the *large*
sizes where this shows — exactly where the working set stops fitting.

## What building the ladder exposed

Everything below was found by putting the chapters side by side, and none of it is about 16-bit.

**Two bf16 compiler gaps, both fixed.** Both from endeavour 155's `bfloat`→`i16` rewrite, and
neither reachable before, because no 16-bit kernel had ever used scalar conversion or async staging:

- `(to-float <bfloat16>)` emitted `fpext i16 … to float`, not a legal cast — `llvm-as` rejected it.
  A bf16 is an f32 with the low mantissa bits dropped, so widening is `zext` → `shl 16` → `bitcast`.
- `%spirv-mangle-elem` had no bfloat16 case, so `OpGroupAsyncCopy` refused Ch 3 outright. An async
  copy moves bytes and never interprets them, so it mangles as `s`.

**Ch 2 computed a full matmul and discarded it — fixed.** `chap2_tiling` had no `store-tile` at all.
Endeavour 137 removed `matrix-multiply-tile-stride`'s auto-store and replaced it with a warning; the
kernel predates that. The compiler said so on every build —

    WARNING: matrix-multiply-tile-stride: the C-tile is computed but never stored —
             add an :epilogue with (store-tile C-TILE C (GRID-Y GRID-X)).

— but a benchmark sweep runs with `--log-level=off` and nobody reads its warnings. Spec 135/10 covers
exactly this warning, so the **test suite did catch the class of problem**; the benchmark ignored the
diagnostic. Established by isolating one variable at a time from spec 135/04: derived vs pinned
`global-size`, single- vs multi-fragment C-tile, `load-tile` vs `load-tile-at` — correct every way,
and only the missing store reproduced it. `matrix-multiply-tile-stride` is not broken.

After the fix Ch 2 tracks Ch 1 almost exactly, which is the expected result — Ch 2 is the macro form
of Ch 1's hand-rolled loop — and its throughput *dropped*, because skipping the store was faster.

**Ch 0 was never broken — the harness was.** `chap0_naive` measured MMA_CORRECT at 16×16×16 and
MMA_WRONG at 32×32×32 and above, with no MMA in the kernel whatsoever. The generated harness emitted
a **1-D group count for a kernel with a 2-D local size**, pinning `grid.y` to 1: at N=16 that happens
to cover the matrix, at N=32 half the columns are never written. Under the fixture harness it
verifies at every size.

**Ch 3 async staging is degenerate in BOTH datatypes** — around 0.001 TFLOPS tf32 and 0.003 bf16,
and MMA_CORRECT. Correct, and roughly four orders of magnitude below the register-resident chapter.
Pre-existing, nothing to do with 16-bit, and still undiagnosed.

## Known gaps in the live table

`Ch 2 tiling` shows `tf32 n/a` and `Ch 3 async` is empty. Those three kernels
(`chap2_tiling` tf32, `chap3_async`, `chap3_async_bf16`) pass **SLM scratch matrices as leading
kernel arguments**, so A/B/C are not at argument indices 0/9/18. The fixture detects
`ADDRESS-SPACE LOCAL` in the physical signature, declines with a printed NOTE, and falls back to the
generated harness — which still drops their points. Supporting them in the fixture means binding
`zeKernelSetArgumentValue(i, bytes, nullptr)` for each SLM pointer plus extents taken from
`make-scratch-matrix`.

Ch 3 is additionally slow enough that a sweep at large N is unlikely to complete regardless.
