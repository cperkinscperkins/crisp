# Crisp on the GPU MODE leaderboards

[Crisp](../../README.md) is a Lisp for writing GPU kernels.  To see how a new language holds up against
the field, Crisp kernels are entered on all eight open [GPU MODE](https://www.gpumode.com) `pmpp_v2`
leaderboards, on each of the four GPUs they run: B200, H100, A100 and L4.  That makes 32 entries.

Every entry is written in Crisp.  A submission is a Python file carrying PTX that Crisp compiled ahead
of time, and the Crisp source is quoted at the top of the file, so you can read the kernel that was
scored.  The aim is an honest picture, not prizes, so the weak results are listed alongside the
strong ones.

Standings were captured on 2026-11-14.  The leaderboards keep moving.

## Summary

"% of #1" is the #1 entry's time divided by Crisp's time on that GPU, so 100% means tied with first.

| Board | B200 | H100 | A100 | L4 | In short |
|---|---:|---:|---:|---:|---|
| [`vectoradd_v2`](REPORT-vectoradd_v2.md) | 97% (#21/69) | 97% (#25/44) | 95% (#56/108) | 89% (#22/39) | At the memory-bandwidth limit, but mid-table: the field is packed within a few percent. |
| [`grayscale_v2`](REPORT-grayscale_v2.md) | 98% (#28/51) | 85% (#28/40) | 98% (#25/129) | 93% (#19/33) | Same story as vectoradd. |
| [`prefixsum_v2`](REPORT-prefixsum_v2.md) | 53% (#12/31) | 95% (**#5**/28) | 74% (#19/29) | 93% (#10/22) | Strong on H100 and L4. |
| [`vectorsum_v2`](REPORT-vectorsum_v2.md) | 75% (#40/85) | 82% (#34/71) | 70% (#69/126) | 80% (#13/47) | Middle of the pack. |
| [`histogram_v2`](REPORT-histogram_v2.md) | 57% (#31/37) | 60% (#16/31) | 59% (#19/28) | 97% (**#6**/21) | Close to first on L4; well short elsewhere. |
| [`matmul_v2`](REPORT-matmul_v2.md) | 59% (#41/53) | 89% (#31/46) | 36% (#57/58) | 53% (#21/21) | Tensor cores on every GPU (`tcgen05`, `wgmma`, `mma.sync`).  Within 11% of #1 on H100, but second-to-last on A100 and last on L4. |
| [`sort_v2`](REPORT-sort_v2.md) | 5% (#18/30) | 10% (#17/30) | 10% (#24/33) | 15% (#13/18) | The weakest board: a plain radix sort, far from the leaders. |
| [`conv2d_v2`](REPORT-conv2d_v2.md) | 1%* (#20/25) | 1%* (#25/34) | 39% (**#6**/23) | 3%* (#10/15) | *See below. |

\* On B200, H100 and L4 the reference is a sequential fp32 FMA chain per output, and only a kernel that
sums in that same order passes the 1e-3 tolerance.  Done at the GPU's peak fp32 rate, that takes at
least 21-56 ms, and the current #1 times are below that floor: they were scored against an earlier
reference, or when cuDNN picked a different algorithm.  "% of #1" is not reachable there.  Measured
against the fp32 floor, Crisp is at 30-40%.  On A100 the reference is an FFT, so the Crisp entry is an
FFT convolution too.  Details are in [08-conv2d-v2/NOTES.md](08-conv2d-v2/NOTES.md).

## Where to look

- **[REPORT.md](REPORT.md)** is the full generated table.  It has public and secret scores,
  achieved bandwidth or TFLOPS, and a link to the exact submission and its `.crisp` source.
- **The per-board reports** (`REPORT-<board>.md`) say what each board measures and how its score is
  computed.  On most boards only the *last* benchmark case counts.
- **The "Beauty Contestants"** at the end of [REPORT.md](REPORT.md) are short, idiomatic kernels of
  13-79 lines, one per board.  They use Crisp's built-in abstractions instead of hardware-specific
  tuning, and show what plain Crisp reaches.
- **The board directories** (`01-vectoradd-v2/` … `08-conv2d-v2/`) hold every variant tried, not only
  the winning one.  The [matmul README](06-matmul-v2/README.md) explains why that entry must match
  cuBLAS bit for bit, and how its 65-parameter TMA kernel is launched through the CUDA driver API.

To write a kernel yourself, start with the [Colab notebook](https://colab.research.google.com/github/cperkinscperkins/crisp/blob/main/notebooks/crisp-gpu-intro.ipynb)
or [Writing Crisp](../../docs/writing-crisp.md).
