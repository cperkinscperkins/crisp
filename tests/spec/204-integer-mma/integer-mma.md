# Endeavour 204: Integer MMA

Third preliminary for quantized integers (see `../205-quantized-integers/proposed-api.md`).
Puts `char` and `uchar` operands with an `int` accumulator through the tensor hardware.

## Hardware facts (probed, not assumed)

| Form | Result |
|---|---|
| XMX `OpCooperativeMatrixMulAddKHR`, int8 to int32 | Exact on BMG, all four sign pairs |
| XMX with sign bits zeroed (negative control) | `MMA_WRONG`, e.g. `C[0][0]=568120` against `-200` |
| PTX `mma.sync.m16n8k32.s32.{s8,u8}.{s8,u8}.s32` | Assembles, all four pairs |
| PTX `wgmma.m64n{8..128}k32.s32.s8.s8`, `.u8.u8` | Assembles at `.version 8.0` |
| PTX `wgmma ... .s8.u8`, `.u8.s8` | Needs `.version 8.4` |
| PTX `wgmma` int8 at K=8, 16, 64 | Refused: K=32 only |
| `wgmma` int8 on H100 NVL, driver 595.91.07 | Exact: `s8.s8`, `u8.s8`, derived, all 4096 outputs |

The `wgmma` int8 form is `{N/2 regs}, descA, descB, 1`: one trailing immediate, not tf32's three or
the 16-bit forms' five.  Its slice is 32 bytes of K, the same as tf32 and 16-bit, so the descriptors
carry over unchanged.

## What changed

- **SPIR-V.**  `%elem-coop-type` and `%coop-op-elem-llvm` fell through to `float` for anything they
  did not know.  That is why an int8 kernel emitted float matrices and died in `llvm-spirv` with only
  an exit code.  They now know integers.  The MulAdd operands mask gains the sign bits (A 1, B 2, C 4,
  Result 8), which come from the Crisp types because LLVM integers have no sign.
- **PTX.**  `make-wgmma-accumulator` honours an integer element, with `int` fields and `=r` registers.
  The mnemonic names A and B separately.  TMA copies accept 1-byte elements.
- **PTX version.**  `llc` gets `+ptx84` only for a module with a mixed-sign `wgmma`, found in the IR.
  Every other kernel keeps its version.
- **Accessors.**  `(accum T)` works as a tile or accumulator element.
- **Harnesses.**  Integer operands are filled to expose sign errors: `char` straddles zero and `uchar`
  sits above 200.  The reference is exact, not within a tolerance.  8-bit buffers now print as numbers
  in both harnesses; a raw byte above 127 used to crash the spec runner's reader.
- **Metadata.**  A tensor map names a derived element by its primitive.

## Decisions (D-204-n, for review)

1. **`wgmma` is the NVIDIA integer path; sync `mma.sync` is refused** with a message pointing at
   `wgmma`.  Sync MMA needs per-lane register layouts for each shape, and they can only be proven on
   metal, while `wgmma` reads shared memory.  The cost: no integer MMA below Hopper, such as on Ada.
   `mma.sync` assembles, so it can be added later.
2. **Integer accumulators are 32-bit, and operands 8-bit.**  That is all the hardware offers.
3. **The accumulator is signed if either operand is**, matching `set-accum`.
4. **`CU_TENSOR_MAP_DATA_TYPE_UINT8` serves both signs.**  `cuda.h` has no `INT8`, and TMA moves bytes.
5. **+ptx84 raises the PTX requirement only for mixed-sign kernels.**  They need a driver that accepts
   PTX 8.4.

## Refused at compile time

| Case | Message says |
|---|---|
| Integer with float, in any position | `integer and float do not mix` |
| Signed operand, unsigned accumulator | `must be signed` |
| Integer register tile on NVIDIA | `has no NVIDIA lowering` |
| `wgmma` int8 at K other than 32 | `K must be 32` |
| XMX int8 at a tf32 K | `operands need K=32`.  This one compiled silently until probed |
| A profile with no int8 shape | `is not one of the active hardware` |

## Verified by hand

- SPIR-V: `TypeInt 8` matrices, `i32` accumulator, MulAdd mask `15`, `14` for `uchar x char`.
- PTX: `wgmma.mma_async.sync.aligned.m64n64k32.s32.u8.s8 {..}, desc, desc, 1;` four times for K=128.
- `.version 8.4` on the mixed kernel, `8.0` on the signed one.
- `ptxas -arch=sm_90a` accepts all three H100 kernels.  `nvcc -c` accepts all three harnesses.

## H100 run (2026-11-01)

The first run of 06-08 gave `MMA_WRONG`, and the spec was at fault, not the compiler.  B was declared
`:row-major`, so its tensor map is 64 wide while the box is 128.  `wgmma` reads its tile as N x K
(float spec 140/03 declares B `:col-major` for this reason), and TMA zero-fills past the map's edge.
An offline check on the device buffers fit `C[i][j] = sum_{k<64} A[i][k] * B[j*64 + k]` with 0
mismatches of 4096 in all three kernels, so the multiply, signs, lanes and store mapping were
already exact; only slices 2 and 3 had read zeros.

With B `:col-major`, all three give `MMA_CORRECT`.  The same check on the device buffers gives 0
mismatches at K=128, and 3571 to 4096 if slices 2 and 3 are dropped, so all four slices contribute.
The first run doubles as a negative control: a lost K slice is reported as `MMA_WRONG`.

## Not covered

- `wgmma` int8 is verified at `s8.s8` and `u8.s8`.  `u8.u8` and `s8.u8` assemble but have not run on
  metal.
- A hardware profile with `:wgmma-shapes` compares K against its own entries, so int8 needs a typed or
  k32 entry there.  It fails loudly.  Spec 06-08 use no profile.
- Autodiff through integer MMA.  It belongs to 205's last rung.
- `make-register-tile` of a derived type on PTX gets the same refusal as `int`.

## For the fold

Function-by-function targets are noted in the overlays.  Notes:
- The block headed "Unchanged copies" exists only because SBCL recorded `%wgmma-k-per-slice` as
  returning 8 or 16.  Nothing there needs folding.
- `%wgmma-asm-string` appears three times.  The last one is the one to fold.
- `%wgmma-struct-of-floats` is superseded by `%wgmma-struct-of-regs`.
- Harness changes are in `overlays/hoist-l0/` and `overlays/hoist-cuda/`.
