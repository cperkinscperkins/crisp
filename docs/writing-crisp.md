# Writing Crisp

A working guide for writing GPU kernels in Crisp — aimed at an AI agent (or a person) who knows GPU
programming and some Lisp, and needs to produce kernels that compile and run correctly on the first try.
It covers the language as it IS today; the design document (`docs/ideal_001.md`, split into
`docs/chapters/`) also describes features that are planned (marked 📝).  Every complete example below
compiles for both SPIR-V and PTX.

If you are working ON the compiler rather than writing kernels with it, read `CLAUDE.md` /
`ANTIGRAVITY.md` and `docs/crisp-curios.md` instead.

---

## 1. Compiling and running

```text
bin/crisp-compile.exe [flags] kernel.crisp [libdevice.10.bc]
```

| Flag | Meaning |
|---|---|
| `--ir-target=spv` | SPIR-V for Intel GPUs (Level Zero).  Writes `kernel.spv` next to the source. |
| `--ir-target=ptx` | PTX for NVIDIA.  Writes `kernel.ptx`.  Add `--ir-target-arch=sm_90` (etc.) for arch-specific features. |
| (no `--ir-target`) | LLVM IR to standard output — useful for reading what you wrote. |
| `--hardware-profile=NAME` | `bmg` (Intel Arc B580) and `h100` are built in; others are `def-hardware-profile` forms (see `benchmarks/profiles/`). Required for warp collectives on SPIR-V and for the MMA paths. |
| `--math-precision=ieee\|fast` | `ieee` (default): correctly rounded. `fast`: approximate hardware paths. |
| `--hoist=L0` / `--hoist=CUDA` | Also write a host `.cpp` that loads and runs the kernel (Level Zero / CUDA). |
| `--differentiate` | Compile the BACKWARD (gradient) kernels instead — see §11. |

**PTX + transcendentals** (`exp log sin cos tan asin acos atan pow atan2 log2 tanh erf exp2`) need NVIDIA's
`libdevice.10.bc`: pass it as an extra input (`$CUDA_HOME/nvvm/libdevice/libdevice.10.bc`).  Without it
the compiler stops with a clear message naming the missing `__nv_*` function.  SPIR-V needs nothing.

The compiler is run from the repository root (it finds `bin/LLVM-C.dll` relative to there).

---

## 2. A first kernel

```lisp
;; B[i] = 2 * A[i] for every element, any length.
(def-type in-vec  (vector float :address-space :global :align :compact))
(def-type out-vec (vector float :address-space :global :align :compact))

(def-kernel scale (A &out B)
  (declare #'(in-vec &out out-vec => nil)
           (global-size :derive-from A :strategy :strided))
  (loop-vector-stride A (i)
    (set! (~ B i) (* 2.0 (~ A i)))))
```

- **Storage handles** (`vector`, `matrix`, `tensor`, `cell`) are how a kernel sees memory.  Declare their
  type once with `def-type`; `:align :compact` lets indexing skip strides.
- **`&out`** marks outputs.  Parameters before it are inputs (and get read-only loads on NVIDIA).
- **`(declare #'(... => nil))`** is the signature; kernels return `nil`.
- **`global-size` / `local-size`** say how many threads to launch.  `:derive-from A :strategy :strided`
  sizes the launch from `A` and lets each thread stride over several elements.
- **`loop-vector-stride`** gives each thread its indices; `(~ V i)` reads, `(set! (~ V i) x)` writes.

---

## 3. The rules that trip people up

| Write this | Not this | Why |
|---|---|---|
| `(let ((a 1) (b (+ a 1))) ...)` | `let*` | Crisp's `let` is already sequential (later bindings see earlier ones).  `let*` is an error. |
| `(return q r)` | `(values q r)` | Multiple values are returned with `return`, and bound with `(let ((q r (f x))) ...)`. |
| `(= mode :fast)`, `(!= a b)` | `eq`, `eql`, `equal`, `/=` | One equality, `=`; it compares enum keywords too.  `!=` for not-equal. |
| `(set! x v)`, `(set! (~ v i) x)` | `setf`, `setq`, `incf` | Assignment is `set!`. |
| `(~ v i)` | `aref` | Indexing a storage handle. |
| `(cond (... ) (else default))` | `(cond ... (true default))` | In `cond` the catch-all clause is `else`, not `T`. This is because `T` is often used by users for template types.  There is no boolean literal (`true` / `false` are not values yet). |
| `(* 2.0 x)` | `(* 2 x)` with a float `x` | No implicit int/float mixing — use float literals, or `(to-float n)`. |
| `(< lid 32ul)` | `(< lid 32)` with a `ulong` | Integer literals are `int`; a literal compared with a `ulong` needs `ul` (see §4). |
| `def-function` at top level | `defun`, nested functions | Functions are top-level forms; no closures, no recursion. |
| `dotimes`, stride macros | `loop`, `while`, `dolist` | Every loop is bounded (see §6). |

When you write a Common Lisp form Crisp does not have, the error says what to write instead
(e.g. "Crisp has no EQ: compare values, including enum keywords, with =").

Kernel names come out **lower-cased**: `(def-kernel MyKernel ...)` is the symbol `mykernel` in the SPIR-V /
PTX and the `.metacrisp` (BUG 018).  Look kernels up by the lower-case name, or just name them in lower case.

---

## 4. Types and literals

Scalars: `int uint long ulong short ushort char uchar float double half bfloat16`.

| Literal | Type |
|---|---|
| `5` | `int` |
| `5u` `5l` `5ul` | `uint` `long` `ulong` |
| `5s` `5us` `5c` `5uc` | `short` `ushort` `char` `uchar` |
| `1.0` or `1.0f` | `float` |
| `1.0d` | `double` |
| `1.0h` | `half` |

**No silent conversions between integer types or between int and float.**  Convert with `to-TYPE`:
`(to-float i)`, `(to-int (get-workgroup-id 0))`, `(to-ulong n)`.  Float -> int is `(truncate x)`,
`(floor x)`, `(ceil x)` or `(round x)` (round: ties to even).

Builtins have fixed types worth knowing: `get-global-id`, `get-local-linear-id`, `get-workgroup-id`,
`get-local-work-size`, `get-global-work-size`, `get-num-groups` return `ulong`; `warp-size`, `warp-lane`,
`warp-id` return `uint`.

**An element holds exactly its own type.**  `(set! (~ v i) x)` with an `x` of any other type is a compile
error ("convert it explicitly") -- the rule a plain variable's `set!` always had.  That includes literals:
a `long` element takes `7l`, a `ulong` one `8ul`, a `double` one `1.0d` or `(to-double x)`.  Narrow a
float into a 16-bit element with `(to-half x)` / `(to-bfloat16 x)`, both round-to-nearest-even (before
endeavour 186 such a store silently wrote 4 bytes into a 2-byte slot, BUG 059).  Avoid the scalar
`bfloat16` literal and scalar `bfloat16` arithmetic on SPIR-V for now (BUG 121); `bfloat16` / `half` are
well supported inside the MMA paths.

---

## 5. Memory and storage handles

```text
(def-type in-vec  (vector float :address-space :global :align :compact))
(def-type mat-t   (matrix float :address-space :global :align :compact :contiguous-term :row-major))
(def-type out-c   (cell float :address-space :global))   ; a single value
```

- `(~ v i)`, `(~ m row col)`, `(~ c)` read; `set!` on the same form writes.
- `(length~ v)` is the element count.
- **Kernel parameters must be complete types**: give every `:address-space`, and every compile-time
  property of a struct element.  Storage handles cannot be nested (`(cell (cell ...))` is refused).
- **Scratch memory**: `(make-scratch-vector float :match-workgroup-size)` (also `:match-num-warps-per-workgroup`,
  `make-scratch-matrix`, `make-scratch-cell`).  It is workgroup-local by default and the compiler adds the
  allocation to the kernel's launch for you.
- **Barriers**: `(sync-workgroup)` between writes and reads of shared scratch.

---

## 6. Control flow and loops

- `if` (both branches the same type), `when`, `unless`, `cond`.
- Bounded loops only: `(dotimes (i n) ...)`, `(dec-times-by-half (s 32ul) ...)` (s = 32, 16, ... 1),
  and the other members of the `dotimes` family (chapter 13).
- The **`+` variants** (`dotimes+`, `dec-times-by-half+`, `when+`, `if+`) PROVE the condition / trip count is
  uniform across the workgroup.  A barrier or a warp collective inside a loop requires the `+` form.
- **Strides** hand each thread its work: `loop-vector-stride` (one vector), `grid-stride`, `tile-stride`,
  `matrix-multiply-tile-stride` (§10), `hardware-stride`, `workgroup-stride` (chapter 13).
- `return-from-loop` leaves the innermost `dotimes`-family loop.
- No recursion, no `while`.

---

## 7. Math

| Available | Notes |
|---|---|
| `+ - * /` | `/` on integers truncates.  `(- x)` negates. |
| `min max clamp abs` | int and float.  `(clamp x lo hi)`. |
| `floor ceil round` | one argument: float -> int.  Two arguments: integer division; `(let ((q r (floor a b))) ...)` gives the remainder too. |
| `rem mod` | `rem` truncates (like C `%`); `mod` floors: `(mod -1 4)` is 3.  Int and float. |
| `sqrt rsqrt` | float / double. |
| `exp log log2 exp2 sin cos tan asin acos atan tanh erf pow atan2` | float / double.  PTX needs libdevice (§1). |
| `ash logand logior logxor lognot popcount` | integers.  `(ash x n)`: n > 0 left, n < 0 right, defined for any n. |
| `op-fma op-saturate op-min3 op-max3 op-rsqrt-approx` ... | hardware ops, chapter 32/07. |
| `*!` | widening multiply; on the basic types it is `*`. |

Not yet: the chapter 14 bit-twiddling ops (`op-count-leading-zeros`, `op-bit-reverse`, ...), the chapter 15
pack/unpack ops, `fmin` / `fmax` (use `min` / `max`).

---

## 8. Threads, warps and workgroups

`(get-global-id 0)`, `(get-local-id 0)`, `(get-local-linear-id)`, `(get-workgroup-id 0)`, `(warp-lane)`,
`(warp-id)`, `(warp-size)`; `(sync-workgroup)`; shuffles `shuffle`, `shuffle-up`, `shuffle-down`,
`shuffle-xor`.

`(warp-size)` comes from the hardware profile: 32 on NVIDIA, 16 on BMG.  **On SPIR-V a warp collective
(shuffle, warp reduction) needs `--hardware-profile=...` AND a literal `(local-size :set-to N)` that is a
multiple of the profile's SIMD width** — Crisp refuses rather than guess the subgroup size.  A kernel
that assumes one warp per workgroup must make `local-size` EQUAL the warp width (32 NVIDIA, 16 BMG).  (Write the
literal; `(local-size :set-to (warp-size))` is not yet accepted there — BUG 118.)

```lisp
;; One warp per workgroup: the warp sums its lanes with a butterfly of shuffles.
;; local-size must be exactly one warp: 32 on NVIDIA -- write 16 for --hardware-profile=bmg.
(def-type in-vec  (vector float :address-space :global :align :compact))
(def-type res-vec (vector float :address-space :global :align :compact))

(def-kernel warp_sum (A &out Res)
  (declare #'(in-vec &out res-vec => nil)
           (global-size :derive-from A :strategy :strided)
           (local-size  :set-to 32))
  (let ((sum 0.0))
    (loop-vector-stride A (i)
      (set! sum (+ sum (~ A i))))
    (dec-times-by-half+ (s (/ (warp-size) 2u))
      (set! sum (+ sum (shuffle-xor sum s))))
    (when (= (warp-lane) 0u)
      (set! (~ Res (get-workgroup-id 0)) sum))))
```

---

## 9. Reductions

Do not hand-roll a reduction unless you have a reason: `reduce-vec` does the whole thing — per-thread,
per-warp, per-workgroup and across workgroups — and picks the strategy for the hardware.

```lisp
(def-type in-vec (vector float :address-space :global :align :compact))
(def-type out-c  (cell float :address-space :global))

(def-kernel vec_sum (A &out out)
  (declare #'(in-vec &out out-c => nil)
           (global-size :set-to 128)
           (local-size  :set-to 64))
  (reduce-vec #'+ A 0.0 out))
```

Building blocks when you need them: `reduce-warp`, `reduce-workgroup`, `grid-reduce!` (chapters 18-24,
including several values at once and segmented reductions).

---

## 10. Matrix multiplication

`matrix-multiply-tile-stride` walks output tiles and the K dimension for you; you load tiles, multiply,
and store.  A minimal (scalar) version:

```lisp
(def-type mat-t (matrix float :address-space :global :align :compact :contiguous-term :row-major))

(def-kernel mm_tiles (A B &out C)
  (declare #'(mat-t mat-t &out mat-t)
           (global-size :set-to 1)
           (local-size  :set-to 1))
  (let ((A-tile (make-scratch-matrix float (4 4)))
        (B-tile (make-scratch-matrix float (4 4)))
        (C-tile (make-scratch-matrix float (4 4)))
        (K      (inner-dimension A B)))
    (matrix-multiply-tile-stride C C-tile K 4 (grid-y grid-x grid-k)
      (when (= grid-k (to-ulong 0))
        (fill-tile C-tile 0.0))
      (load-tile A A-tile (grid-y grid-k))
      (load-tile B B-tile (grid-k grid-x))
      (dotimes (i 4)
        (dotimes (j 4)
          (dotimes (kk 4)
            (set! (~ C-tile i j)
                  (+ (~ C-tile i j) (* (~ A-tile i kk) (~ B-tile kk j)))))))
      :epilogue
      (store-tile C-tile C (grid-y grid-x)))))
```

For speed, use the tensor-core / XMX paths (register tiles and `mma`), async tile loads, rings and warp
specialization — chapters 57-60, and the tuned kernels in `performance/matmul-bmg/` and the matmul
benchmarks.  These need `--hardware-profile`.

---

## 11. Automatic differentiation

`--differentiate` compiles a kernel's backward pass: for every `&out` output it produces gradients for
the inputs.  Most of the language is differentiable (including `sqrt`, `abs`, `clamp`, the
transcendentals, reductions with a declared VJP, matmul).  A kernel needs inputs and at least one `&out`.
Integer results (`floor`, bit ops) carry zero gradient.  See chapter 48.

---

## 12. Performance

- Start from the measured guidance in `docs/performance-levers.md`.
- Pick the hardware profile that matches the device; it drives tile shapes, register budgets and the
  warp width.
- `(declare (occupancy-target N))` and the profile's `:stream-occupancy-target` bound registers on NVIDIA
  (registers per thread = 65536 / N).  **Do not hand-set a higher target than the profile's** -- a kernel
  that needs more registers than the bound allows is SPILLED by ptxas, silently (BUG 124).  Leave it to the
  profile, or turn it off with `(occupancy-target nil)`; whatever you choose, check that `ptxas -v` (or a
  contest site's report) shows a stack of 0 bytes.
- `(declare (unroll t))` / unroll counts on loops.
- Reductions: `reduce-vec`.  Matmul: the MMA paths above.  Elementwise: `loop-vector-stride`.
- Compare against `benchmarks/` and `performance/` before claiming a speedup.

### Memory-bound streaming kernels (elementwise maps, vector add, ...)

The work is moving bytes, so the levers are bytes per instruction and loads in flight -- not occupancy:

```lisp
(def-type in-vec  (vector float :address-space :global :align :compact))
(def-type out-vec (vector float :address-space :global :align :compact))

(def-kernel vector_add (A B &out C)
  (declare #'(in-vec in-vec &out out-vec => nil)
           (global-size :derive-from A :strategy :strided)
           (local-size  :set-to 256))
  (let ((n  (length~ A))
        (n4 (/ n 4ul))
        (a4 (make-vector A float4 :length n4))      ; 128-bit loads and stores
        (b4 (make-vector B float4 :length n4))
        (c4 (make-vector C float4 :length n4)))
    (loop-vector-stride a4 (i)
      (declare (unroll 4))                          ; keeps several loads in flight per thread
      (set! (~ c4 i) (+ (~ a4 i) (~ b4 i))))
    (let ((tail (+ (* n4 4ul) (get-global-id 0))))  ; the 0..3 elements float4 cannot cover
      (when (< tail n)
        (set! (~ C tail) (+ (~ A tail) (~ B tail)))))))
```

Measured on LeetGPU's H100 (challenge 01, 2026-10-16), one change at a time:

| Variant | Registers / stack | Time |
|---|---|---|
| scalar, `unroll 4`, `(occupancy-target 2048)` | 32 / **72 B** (spilled) | 0.16 ms |
| scalar, `unroll 4`, no target | 56 / 0 | 0.12 ms |
| the kernel above (`float4` + `unroll 4`) | 64 / 0 | 0.12 ms |
| `float4`, no unroll | 32 / 0 | 0.13 ms |

So: no hand-set occupancy target, keep the unroll, and prefer `float4` -- it was a wash on H100 but is the
form that matters on older GPUs.  Still open: whether one `float4` per thread
(`:strategy :one-thread-per`, no loop) beats the strided loop on H100.  The `float4` rows were measured
before endeavour 186 fixed BUG 125: a view of a read-only input now keeps the `.nc` read-only load
(`ld.global.nc.v4`), so they may improve.  The CUDA launcher Crisp hoists now prints the registers and
local (spill) bytes the driver reports, so a spill shows up without `ptxas -v`.

---

## 13. What Crisp refuses (on purpose)

Recursion; unbounded loops; `let*`; `eq`-family equality; storage handles inside storage handles; incomplete
types at the kernel boundary; `voidp` as a `def-kernel` parameter; two-argument `floor` on floats; a warp
collective on SPIR-V without a pinned subgroup size; reusing one explicit kernel name for two template
instantiations.  Each refusal is a compile error that says what to do instead.

---

## 14. Checking your work

1. Compile for BOTH targets: `--ir-target=spv --hardware-profile=bmg` and `--ir-target=ptx`.
2. Read the generated code when performance matters (`.ptx`, or `llvm-spirv -to-text` on the `.spv`).
3. Run it: `--hoist=L0` (Intel) or `--hoist=CUDA` writes a host program; or write a spec in
   `tests/spec/` with `TEST-HOIST[L0]` and `HOIST-EXPECT: BUFFER name: v0 v1 ...` (see `docs/tests.md`).
   Put several cases in ONE kernel and build operands from a run-time value such as
   `(to-int (get-workgroup-id 0))` so nothing is constant-folded away.
4. For gradients: `VERIFY-AUTODIFF: input=1.5 atol=1e-3 expect.input=2.0` checks against finite differences.
5. Known issues live in `plan/bugs.md`; check it when something compiles but computes the wrong thing
   (BUG 120: some integer operations written inline in a kernel body misbehaved on the BMG; the compiler
   routes the affected built-ins through helper functions).
