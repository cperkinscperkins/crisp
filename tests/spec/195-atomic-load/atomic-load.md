# Endeavour 195 — atomic-load and atomic-store!

Started 2026-10-26 (late) and run overnight while Chris was away ("If there are design decisions, just go
ahead and make them and record them").  Every decision below marked **D-195-n** was taken without him,
for review.

## Why

Finding F4 from the prefixsum single-pass work (`put_temp_files_here/psum/FINDINGS.md`, scramble.md
"Language"): Crisp had no plain atomic READ.  The lookback poll therefore had to be a read-modify-write:

```lisp
(set! word (atomic-add! (~ words ju) 0ul))      ; prefixsum_packed_rfl.crisp
```

PTX lowers that to `atom.global.add.u64 ..., 0`, which every poller sends to L2 as an RMW, so polls on
one flag serialize.  CUB polls with `ld.relaxed.gpu` (or `ld.acquire.gpu`).  Publishing had the mirror
problem: `atomic-xchg!` is `atom.exch` when all the publisher wants is a store that cannot tear.

## The surface

```lisp
(atomic-load  place)          ; => the value at PLACE, read atomically
(atomic-store! place value)   ; writes VALUE to PLACE atomically; no useful result (like set!)
```

PLACE is a memory location `(~ handle idx ...)`, exactly as for every other Crisp atomic.

## Decisions

- **D-195-1 Names.**  `atomic-load` has no `!` because it changes nothing; `atomic-store!` has one.
  This follows the rest of the language (`set!`, `atomic-add!`).  `atomic-read` / `atomic-write`
  were the alternatives; load / store match LLVM, SPIR-V (`OpAtomicLoad` / `OpAtomicStore`), C++ and
  CUDA's `cuda::atomic_ref::load/store`.

- **D-195-2 Relaxed, device scope, and nothing else.**  Same rule as every Crisp atomic since 184
  ("atomics order nothing, fences do").  No `:acquire` / `:release` keyword.  The publish / poll
  idiom is:

  ```lisp
  ;; publisher                          ;; poller
  (set! (~ data i) v)                   (when (= (atomic-load (~ flag i)) 1u) ...)
  (mem-fence)                           (mem-fence)
  (atomic-store! (~ flag i) 1u)         (~ data i)
  ```

  An acquire load would fold the poller's fence into the load (`ld.acquire.gpu` instead of
  `ld.relaxed.gpu` + `membar.gl`).  The packed prefixsum needs no fence at all (value and state
  travel in one word), so that kernel cannot tell the difference.  If a measurement ever shows the
  fence matters, an ordering keyword is a separate decision.

- **D-195-3 `atomic-store!` returns nothing useful.**  Its type is `void`, like `set!`.  It is not an
  exchange: when the old value matters, `atomic-xchg!` is still there.

- **D-195-4 32- and 64-bit scalars only:** `int uint long ulong float double`.  8- and 16-bit types,
  device vectors (`float4`) and structs are refused with a message naming the type.  PTX could do 16
  bits (`ld.relaxed.gpu.b16`), but SPIR-V 16-bit atomics need extensions BMG is not known to have, and
  the paired lowerings must agree ([[paired-lowerings-can-disagree-in-scope]] in memory).  A float
  loads and stores as itself; no bit-pattern games are needed (unlike `atomic-cas!`).

- **D-195-5 Representation: the existing `semantic-atomic-rmw` node, with ops `:load` / `:store`.**
  No new semantic node, so no new etypecase arms in `semantic-node-type` / source-location, and
  every place that already understands an atomic node understands these.  For `:store` the node's
  type is `void` and the element type comes from the target `semantic-aref`.  `:load` has no
  delta node.

- **D-195-6 Uniformity: an `atomic-load` is never uniform.**  It falls through to `:unknown` like
  every atomic.  (A plain read of a uniform handle at a uniform index is `:uniform`; an atomic load
  of the same place must not be -- two lanes polling one flag can see different values.)  Nothing
  to implement; recorded because it is a decision.

- **D-195-7 Autodiff: `atomic-load` refused for every type; `atomic-store!` inert for integers,
  refused for floats.**  (First draft was "integers inert, floats refused" for both; revised while
  writing spec 06.)
  - `atomic-load`: an atomic load exists to read a value that another thread, or an earlier statement
    of this one, published.  Neither reaches the backward pass.  Cross-thread dataflow has no adjoint
    path ([[cross-thread-dataflow-invisible-to-ad]]).  And the backward kernel is a separate launch
    that replays the forward's BINDINGS but not its STATEMENTS, so a replayed `atomic-load` reads
    whatever the memory holds by then.  That is as true of an integer flag as of a float, because an
    int flag can steer the float computation (errors/05 is exactly that).  So it is refused rather
    than differentiated against a value the backward cannot reproduce.
  - `atomic-store!` of an integer: inert, like `atomic-inc!` -- no derivative to carry, and nothing
    in the backward reads it (the load that would is refused).  Spec 06 measures it on metal.
  - `atomic-store!` of a float or double: refused.  It exists to hand a value to another thread;
    differentiating it as a plain `set!` would give the reader a silently wrong gradient.
  - The element type comes from the kernel's parameter types (published by a wrapper on
    `generate-backward-walk`, because the VJP context carries no types) or, for scratch, from the
    `make-scratch-*` binding in the flat ANF.  Unknown -> refused.
  - A kernel with no float input never reaches the backward rules, so 01, 02, 04, 05 pass the
    differentiate pass unchanged.

- **D-195-8 Registrations.**  Both are place-taking forms, so both join `*anf-atomic-op-names*` (else
  ANF flattens the place into a plain read and the "atomic" load becomes `(atomic-load %anf-t-3)`).
  `atomic-store!` joins the AD write-set lists ([[new-place-writing-operator-needs-three-registrations]]).

- **D-195-9 Both places are analysed in WRITE access mode -- an `atomic-load` may read an `&out`.**
  A plain read of an `&out` parameter is refused ("Output parameters are write-only"), and every
  atomic RMW is exempt because it analyses its place in write mode.  The arrays a kernel publishes
  into and polls are its `&out`s (prefixsum's `words`), so `atomic-load` must be exempt too, or the
  feature could not replace the `(atomic-add! place 0)` poll at all.  (Noticed while writing the
  specs: a write to an INPUT tensor is not refused in the forward pass for any operator -- only
  `--differentiate` refuses it -- so no `&in` error spec was written.)

## Lowering (checked by hand, 2026-10-26, bundled LLVM 21)

| | LLVM IR | PTX (sm_70+, NVPTX 21) | SPIR-V (llvm-spirv) |
|---|---|---|---|
| `atomic-load` | `load atomic T, ptr syncscope("device") monotonic` | `ld.relaxed.gpu.{global,shared}.bNN` | `OpAtomicLoad` scope 1 (Device), semantics 0 (Relaxed) |
| `atomic-store!` | `store atomic T, ptr syncscope("device") monotonic` | `st.relaxed.gpu.{global,shared}.bNN` | `OpAtomicStore` scope 1, semantics 0 |

Probe: `put_temp_files_here/195/probe.ll`.  The sync scope is set with `LLVMSetAtomicSyncScopeID`
(exported by the bundled LLVM-C 21; the 184 helper `%184-device-sync-scope` supplies the ID).

## Specs

| spec | what |
|---|---|
| 01 | uint load/store, same thread: PTX (`ld.relaxed.gpu` / `st.relaxed.gpu`, no `atom.`), SPIR-V (Device / Relaxed), on metal |
| 02 | ulong (past 2^32) / long / int (negative), on metal |
| 03 | float / double, on metal; refused under `--differentiate` (D-195-7) |
| 04 | `:local` scratch: `ld.relaxed.gpu.shared` / `st.relaxed.gpu.shared`, on metal |
| 05 | publish / poll across two workgroups with `mem-fence`, bounded poll with `return-from-loop`, on metal |
| 06 | int `atomic-store!` (to scratch) in a differentiated kernel: inert; VERIFY-AUTODIFF on metal |
| 07 (unit) | every `load atomic` / `store atomic` in the IR of 01-06 is `syncscope("device") monotonic` |
| errors/01-04 | arity, non-place target, 16-bit element, float4 element |
| errors/05 | an int `atomic-load` in a float kernel: forward compiles, `--differentiate` refuses |

## Status / log

**FOLDED 2026-10-27**, after review of D-195-1..9.  All three overlays (compiler, llvm-bindings,
spec-runner) are empty; their headers list where each piece went.  The fold was scripted
(`put_temp_files_here/195/fold/fold.py`: verbatim form copies, bottom-up edits, CRLF kept), so the src
diff of each replaced form is exactly its 195 lines.  Only the last copy of `%195-vjp-atomic-store` was
taken.  The `register-ops-analyzers` wrapper became one call at its end.  The `generate-backward-walk`
wrapper became a third binding in that function's existing outer LET; the script asserts that LET encloses
the whole body.  The `semantic-atomic-rmw` docstring now lists `:load` / `:store`.  specials (adds
`*195-AD-PARAM-TYPES*`), reference.md, the call graph and the globals matrices were regenerated.
Post-fold suites, overlays empty: unit 392/392, E2E 1587/1587, negative 387/387.  Every overlay
definition is defined exactly once in src; no `*195-orig-*` remains.
Two SBCL crashes during the post-fold E2E runs, both in foreign (driver) code:
- The first run segfaulted mid-run in the L0 host run of `178/01-reduce-vec-sum-metal`.  That spec then
  passed alone (178: 24/24) and in the full rerun.
- The rerun printed its 1587/1587 summary, then took a memory fault at process exit.

### Verified (2026-10-27)
- 195 specs: 11/11 in the default pass and 11/11 in the differentiate pass (spec 06's VERIFY-AUTODIFF on
  BMG: analytical 3.0, numerical 3.00026), BMG on-metal hoists included.
- Hand-checked lowering: the PTX of every spec (`ld.relaxed.gpu` / `st.relaxed.gpu`, `.shared` for
  scratch, no `atom.`), the SPIR-V of 01 / 03 (`OpAtomicLoad` / `OpAtomicStore`, scope Device,
  semantics Relaxed), and the IR (`syncscope("device") monotonic`, explicit alignment).
- ptxas 12.4 (Docker `nvidia/cuda:12.4.1-devel`) assembles 01-05 for sm_80 and sm_90.
- On NVIDIA metal, through the prefixsum below: GPU MODE H100 test #968162 and four 268M benchmarks
  all PASS, two of them with BOTH `ld.relaxed` polls and `st.relaxed` publishes.
- Spec 06's backward rule really ran: `--log-level=debug` shows `195 VJP atomic-store! into (~ FLAGS L):
  element :INTEGER` -> `:inert` (the scratch-type lookup path).
- Suites on the overlay build: unit 392/392, E2E 1587/1587, negative 387/387.  (CI runs the --debug /
  --single-pass / --differentiate phases.)

### Not verified
- The 195 specs' `TEST-HOIST[CUDA]` runs (no local NVIDIA GPU; nvcc absent so they SKIP).  A pod run of
  `tests/spec/195-atomic-load` would close it; the H100 prefixsum runs are the evidence meanwhile.

### Payoff measurement: the prefixsum lookback (H100, GPU MODE benchmark, 268M floats, one session)

| variant | poll | publish | time | submission |
|---|---|---|---|---|
| `prefixsum_packed_rfl` (control) | `atom.global.or.b64` | `atom.exch.b64` | 753 us | #968164 |
| al | `ld.relaxed.gpu` | `st.relaxed.gpu` | 913 us | #968163 |
| als (al, spin 256 -> 1024) | `ld.relaxed.gpu` | `st.relaxed.gpu` | 921 us | #968165 |
| alp | `ld.relaxed.gpu` | `atom.exch.b64` | 760 us | #968167 |

Hypotheses for al's regression, each with its test: H1 a cheaper poll makes the fixed 256-try spin time
out sooner, so more fallbacks -- REFUTED by als.  H2 the relaxed STORE publish is slower to reach the
pollers -- SUPPORTED by alp: the whole 20% is the publish.  The poll change itself is neutral, so F4's
premise (RMW polls serialize at L2) does not show up in this kernel.  Kept:
`contests/gpu-mode/05-prefixsum-v2/prefixsum_packed_al.crisp` = alp (poll only), with this table in its
header.  Not submitted to the leaderboard (no gain over rfl).  The docs (ideal_001 Atomics) now say:
measure before replacing an `atomic-xchg!` publish.

### Observations for Chris (not filed)
- **VERIFY-AUTODIFF does not use the kernel's `global-size`.**  A kernel indexed by `get-global-id`
  needs `output-vec= group= groups=` spelled out; without them BMG reports L0 DEVICE_LOST (0x70000001),
  and with `output-vec` alone the analytical gradient is 0.0.  Probed on an atomics-free `y = 3x`
  kernel.  Every VAD spec before 195 used `loop-vector-stride`, which is why nobody hit it.  A
  harness question, not a compiler bug.
- The AD replay lists name `"ATOMIC-EXCHANGE!"`, which is not an operator; `ATOMIC-XCHG!` /
  `ATOMIC-SET!` are missing from them.  Harmless today (both refuse `--differentiate`), left alone.
- A write to an INPUT tensor (before `&out`) is not refused in the forward pass, by any operator.
- `atomic-load` of a read-only cell would be refused with a "Cannot write" message (D-195-9's write
  mode).  Edge case, no spec.
