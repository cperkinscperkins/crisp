# The Technique Ladder in 16-bit (Intel BMG)

Chapters 0–5 in bfloat16, each kernel its tf32 twin with exactly two changes: the operand element
type (`float` → `bfloat16`; the C accumulator stays f32, as XMX accumulates in f32 either way) and
the K step 8 → 16, the native XMX shape for 16-bit operands being `(8 16 16)` rather than `(8 16 8)`.
Tile K extents follow. A deliberate third difference: the bf16 twins carry
`(declaim (precision fast))`, which the tf32 originals do not — the shipped §2.1 bf16 kernels carry
it and bf16 is an approximate format. If a ratio looks anomalous, re-test that first.

**These numbers were measured DIRECTLY, not through the benchmark sweep.** See "The harness is
dropping results" below.

Arc B580, `--math-precision=fast`, `--mma-bench=10`. Format: `tf32 → bf16 (ratio)`, TFLOPS.

| chapter | N=512 | N=1024 | N=2048 | N=4096 | |
|---|---|---|---|---|---|
| Ch 0 naive (no XMX) | 0.001→0.001 (1.00×) | 0.004→0.004 (1.00×) | 0.034→0.034 (1.00×) | 0.275→0.275 (1.00×) | **MMA_WRONG both** |
| Ch 1 hand-rolled MMA | 0.387→0.850 (2.20×) | 1.356→2.317 (1.71×) | 1.434→2.442 (1.70×) | 1.502→2.032 (1.35×) | correct |
| Ch 2 tiling macro | 0.645→0.952 (1.48×) | 2.371→2.319 (0.98×) | 2.380→2.151 (0.90×) | 2.164→2.026 (0.94×) | **MMA_WRONG both** |
| Ch 3 async staging | 0.001→0.003 | 0.001→0.003 | 0.001→0.003 | 0.001→0.003 | correct, **degenerate** |
| Ch 4 register-resident | 12.118→19.703 (1.63×) | 25.908→**46.611** (1.80×) | 16.012→37.172 (**2.32×**) | 13.199→26.470 (2.01×) | correct |
| Ch 5 ring + prefetch | 9.560→15.835 (1.66×) | 21.331→39.406 (1.85×) | 24.073→**41.537** (1.73×) | 16.084→34.332 (**2.13×**) | correct |

## The scaling factor

Across the chapters that are correct and non-degenerate (Ch 1, 4, 5 — eleven data points):

    min 1.35x   median 1.73x   mean 1.81x   max 2.32x

**Centred on roughly 2×, and never near 4×.** That is what the hardware's own shape ladder predicts:
`(8 16 8)` tf32 → `(8 16 16)` bf16 → `(8 16 32)` int8, same M×N with K doubling per step. One DPAS
does twice the MACs in bf16 as in tf32 at the same issue rate, so 2× is the instruction-level
ceiling for that switch; 4× is the tf32→**int8** step, one rung further down.

Two caveats on that reading. The 32-bit baseline here is **tf32 on XMX**, not fp32 on the vector
engines — against that baseline a much larger factor would be expected, and it would be a different
comparison. And the three points above 2.0× (Ch 4 at N=2048 and N=4096, Ch 5 at N=4096) are where
halving the operand bytes buys cache behaviour on top of the arithmetic, which is why they exceed
the instruction-level ceiling.

## What the ladder exposed that tf32 data could not

**Two compiler gaps, both from endeavour 155's `bfloat`→`i16` rewrite.** Neither was reachable
before, because no 16-bit kernel had ever used scalar conversion or async staging:

- `(to-float <bfloat16>)` emitted `fpext i16 … to float`, not a legal cast — `llvm-as` rejected it.
  A bf16 is an f32 with the low mantissa bits dropped, so widening is `zext` → `shl 16` → `bitcast`.
- `%spirv-mangle-elem` had no bfloat16 case, so `OpGroupAsyncCopy` refused Ch 3 outright. An async
  copy moves bytes and never interprets them, so it mangles as `s`.

**Ch 3 async staging is degenerate in BOTH datatypes** — 0.001 TFLOPS tf32, 0.003 bf16, both
MMA_CORRECT. Correct and roughly four orders of magnitude off the register-resident chapter. This is
pre-existing and has nothing to do with 16-bit; the ladder simply made it visible by putting the
chapters side by side.

**Ch 0 and Ch 2 are MMA_WRONG in BOTH datatypes.** The tf32 twins are equally wrong, so the bf16
conversion did not cause it — these are pre-existing failures in the shipped chapter ladder. Ch 2 is
the more serious of the two: it is `matrix-multiply-tile-stride`, a shipped macro, and it produces
wrong results while reporting plausible throughput. Ch 0's numbers being byte-identical between
tf32 and bf16 is itself suspicious and worth a look.

## The harness is dropping results

`run_l0_autobench_sweep` recorded **zero points** for `chap4_cheap_fetch_bf16` and
`chap5_multistage_ring_bf16`, and one point each for Ch 0, 2 and 3 — while those same kernels run
correctly by hand at 46.6 and 39.4 TFLOPS. It also ate `Crisp_XeNative_Tuned` in §3 earlier. Three
contenders silently dropped makes it a systematic fault, not bad luck, and every number in this file
was therefore taken directly through `crisp-hoist-l0`.

Until that is fixed, the auto-generated §1b table in `REPORT.md` will be full of gaps and should not
be read as the ladder. This file is the ladder.
