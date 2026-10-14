# Crisp Prerelease 002

Binaries for Windows x86_64 and Linux x86_64 (built on Ubuntu 24.04): the compiler (`crisp-compile`), the
Level Zero and CUDA hoisters, and the LLVM 21 tools they use.  Install with `python init_bin.py` from a
checkout of the matching tag — see [INSTALL.md](../../INSTALL.md).  New to Crisp?  Start with
[Writing Crisp](../writing-crisp.md).

On Linux, install `libedit2` and `libxml2` first (`sudo apt-get install -y libedit2 libxml2`); the bundled
LLVM library links against them.

## Highlights since Prerelease 001

**Matrix multiplication**
- Tensor-core / XMX paths end to end: typed MMA shapes, 16-bit (fp16 / bf16) and 64-bit (fp64), async tile
  loads, TMA, multicast, rings with prefetch, warp specialization, wgmma, workgroup cooperation, fused epilogues.
- `matrix-multiply-tile-stride` as the one entry point; MMA hardware profiles; autodiff through MMA.
- bf16 matmul on Intel Arc B580 at 98–102% of oneMKL; on H100 at parity with CUTLASS
  ([benchmarks/REPORT-matmul.md](../../benchmarks/REPORT-matmul.md)).

**Reductions**
- `reduce-vec`, `reduce-warp`, `reduce-workgroup`, `grid-reduce!`, several values at once (sum + sum of
  squares, argmax, Welford), with autodiff.
- Warp shuffles, the `dotimes` family, loop unrolling, register-budget / occupancy control, last-man and CAS
  strategies.  99% of read peak on the B580, 96–97% on the H100
  ([benchmarks/REPORT-reduction.md](../../benchmarks/REPORT-reduction.md)).

**Language and math**
- The math of design-doc chapter 32: integer division with quotient and remainder, `mod` / `rem`, `sqrt`,
  `rsqrt`, `abs`, `clamp`, `ash`, `logand` / `logior` / `logxor` / `lognot`, `popcount`, `tanh`, `erf`, `exp2`
  (each verified on hardware, with gradients where they exist); hardware math ops (`op-fma`, ...).
- Device memory, CAS and relaxed / device-scope atomics, `return-from-loop`.

**Correctness**
- An adversarial test suite; this release fixes the issues it found, including several that gave wrong
  answers without an error (shadowed `let` bindings under autodiff, integer `floor` / `ceil` / `round`,
  float `mod`, unsigned division).  Remaining known issues: [plan/bugs.md](../../plan/bugs.md),
  [tests/adversarial/issues.md](../../tests/adversarial/issues.md).

**Autodiff**
- Primal replay, autodiff over the FFI boundary, `VERIFY-AUTODIFF` on both Level Zero and CUDA.

## Known limitations
- Many design-doc chapters are still planned (marked 📝): scans, sorting, FFT, `def-orchestration`, the
  in-memory compilation API, the chapter 14/15 bit and packing operations.
- PTX transcendentals need NVIDIA's `libdevice.10.bc` at compile time.
- `--debug` emits DWARF, but its line numbers count s-expression nodes, not source lines; debugger support
  is untested.
