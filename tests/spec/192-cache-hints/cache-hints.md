# Endeavour 192 — cache-hints

Let a kernel say how its data should be cached: streamed once, reused, read-only. Today Crisp can
express none of this. The only hint it emits is `.nc`, and only when it can prove an input read-only.
Branch `cache-hints`.

## Why

GPU MODE `vectorsum_v2` (2026-10-23, contest BUG-002 follow-up). On H100, at 52M floats, the kernel
alone takes ~75 µs (2.8 TB/s). Entries from this month imply ~64 µs kernels. Hand-patching our PTX,
measured one variant at a time (popcorn `benchmark` mode, 52M case, µs):

| Variant | H100 | B200 |
|---|---|---|
| Pure Crisp (`vectorsum_lastman_wg.crisp`, occupancy x1 grid) | 85.0 | — |
| + `ld.global.cs` (streaming, evict-first L1+L2) | 83.3 / 83.1 | 43.0 |
| + `ld.global.nc.L1::no_allocate.L2::256B` | 83.1 | 43.0 |
| + `(unroll 8)` and `.cs` | 83.0 | — |
| + `(unroll 8)` and `nc.L1::no_allocate.L2::256B` | **80.8** | 43.5 |

On H100 this is a real but modest lever (~2.5 µs of an ~11 µs gap). On B200 it does nothing. The SASS
for the best variant is `LDG.E.NA.LTC256B.128.CONSTANT`: no L1 allocate, 256-byte L2 prefetch,
read-only path. Raw outputs: `put_temp_files_here/vs_runs/`. Context: memory note
`gpumode-vectorsum-bug-002`.

## The hardware vocabulary

| PTX | Meaning | CUDA C |
|---|---|---|
| `.ca` | cache at all levels (default) | plain load |
| `.cg` | L2 only, skip L1 | `__ldcg` |
| `.cs` | streaming: used once, evict first | `__ldcs` / `__stcs` |
| `.lu` | last use | `__ldlu` |
| `.nc` | read-only (non-coherent) path; legal only if unwritten during the kernel | `__ldg` |
| `L1::no_allocate`, `L1::evict_first/last` | L1 allocation / priority | (PTX only) |
| `L2::evict_first/last`, `createpolicy` + `L2::cache_hint` | L2 priority | `cuda::annotated_ptr` |
| `L2::64B/128B/256B` | prefetch size on a miss | (PTX only) |
| stores: `.wb .cg .cs .wt` | write-back / L2-only / streaming / write-through | `__stcg`, `__stcs` |

SPIR-V/Intel: `SPV_INTEL_cache_controls` (load: uncached / cached / streaming / invalidate-after-read /
const-cached; store: uncached / write-through / write-back / streaming, per cache level). Reminder:
`-O3` strips `!spirv.Decorations`. These would have to be re-attached after opt, like the others
(memory `o3-strips-spirv-decorations`). Not yet checked: how much of the PTX vocabulary our LLVM
NVPTX backend exposes as metadata or intrinsics vs. needing inline asm.

## Design — where the hint lives (OPEN, under discussion)

Chris, 2026-10-23:
- A cache hint is a property of the DATA. So its primary home is the Storage Handle type declaration
  (cells and tensors; vector/matrix are 1-D/2-D tensors), next to `:address-space`, `:align` and
  `:contiguous`.
- NOT on the reinterpreting casts (`make-vector` and friends). Those are handy but far from every
  kernel.
- Maybe also on the bulk data-movement operations, which already carry keys (`:barrier`, `:identify`,
  `:transformF`, ...): `load-tile` / `load-tile-at`, `store-tile` / `store-tile-at`, `load-local` /
  `store-global`, `prefetch-tile`.

Claude's proposed refinement of that direction (to be agreed):
1. Type-level = the default for every access to that handle.
2. Tile / bulk ops = a per-operation override, when one tensor is used two ways.
3. Views inherit their parent's hint: a reinterpreting cast takes no hint argument, but must not lose
   one. This is exactly where BUG 134 loses `.nc` today.
4. Spell intent (`:streaming`, `:reused`, ...) and map it per backend, vs. exposing raw knobs: open.

Open questions:
- Vocabulary: intent words vs. raw knobs; how many words.
- Read-only (`.nc`) stays inferred? Or can a declaration assert it?
- Stores: same key, or separate load/store hints?
- AD: what do the `_ADJ` shadow types and grad-kernel buffers inherit?
- Intel: `prefetch-tile` already IS a cache operation (Subgroup2DBlockPrefetchINTEL). Do its cache
  controls (L1/L3 policy) belong in the same vocabulary?
- Hoist / metacrisp: record the hint? (Probably no runtime effect.)

## Scope (agreed 2026-10-23)

One endeavour, everything below. **Out of scope:** updating and running the benchmark suite (MMA
included). That is a later, separate effort. Metal checks stay in scope: specs with
`TEST-HOIST[L0]` / `HOIST-EXPECT` on BMG and CUDA, and VERIFY-AUTODIFF where it applies.

1. **Spike first.** What can LLVM express without inline asm (NVPTX metadata/intrinsics for
   `.cs/.cg/.lu`, `L1::`/`L2::` eviction, `L2::256B`)? Does it survive `-O3`? On NVPTX, does the
   load/store vectorizer merge or drop it? On SPIR-V: `SPV_INTEL_cache_controls` through our
   pipeline (the decoration re-attach after opt), llvm-spirv / driver acceptance on BMG. The answers
   pick the lowering.
2. **`:cache` on Storage Handle types** (cells, tensors, vector, matrix), next to `:address-space`
   `:align` `:contiguous`. Type-level default for every element load/store.
3. **Views inherit** their parent's `:cache` (no argument on `make-vector` and friends). Fold in
   **BUG 134** (retyped view loses `.nc`), same propagation path.
4. **Per-operation `:cache` override** on `load-tile` / `load-tile-at`, `store-tile` /
   `store-tile-at`, `load-local` / `store-global`, `prefetch-tile`. Lowered into each instruction's
   own slots: cp.async `.ca/.cg`, TMA `L2::cache_hint`, Intel 2D block load/prefetch cache controls.
5. **Both backends:** PTX qualifiers and SPIR-V `cache_controls` decorations.
6. **Refusals (errors/):** unknown `:cache` value; `:cache` on a non-storage type; `:cache` on
   `:local` memory (L1/L2 hints are meaningless there).
7. **AD:** decide what `_ADJ` shadow types and gradient buffers inherit (proposal: nothing). Plus a
   spec proving the hint is AD-neutral.
8. **Compile API (190):** decide (not by accident) whether `:cache` appears in reported
   types/metadata. Proposal: no, it has no runtime effect.
9. **TDD:** specs under `tests/spec/192-cache-hints/` and a `cache-hints.unit.lisp` for IR-level
   claims. Bump `tests/ci-stop.txt` to `192-cache-hints`. Add `ci.yml` and `run-all-tests.bat`
   entries.
10. **Docs:** `ideal_001.md` (the `:cache` key, status emojis, new errors, and the missing
    `prefetch-tile` section), `writing-crisp.md`, `performance-levers.md`. Regenerate chapters,
    reference, call graph, globals and specials.
11. **Summary for AG**, so the contest entries can adopt `:cache` and be re-run. Include the packager
    changes from the BUG-002 work (kernel ABI derived from `--hoist=cuda`, the last-man scratch
    pattern).

Vocabulary proposal (to confirm in step 2): `:cache :default | :streaming | :reused | :no-l1`. Plus a
separate L2 prefetch-size knob, the one that actually moved H100.

## Spike results (2026-10-23)

Probe files: `put_temp_files_here/192-spike/`. Tools: bundled `bin/llc.exe` (LLVM 21.1.5), Crisp's
in-process `-O3` (`%run-opt-O3`), ptxas + cuobjdump in `nvidia/cuda:12.4.1-devel`.

**NVPTX (LLVM 21):**
- `.nc` IS expressible in IR. `!invariant.load` or `noalias readonly` params give
  `ld.global.nc[.v4]`. Read-only can stay in codegen (the BUG 134 path).
- Everything else is NOT. `!nontemporal` is silently ignored on loads and stores (no `.cs`, no
  `L1::no_allocate`). There is no intrinsic for a hinted plain load. Invented `llvm.nvvm.ld.*`
  names become extern calls. `llvm.nvvm.prefetch.*` fails instruction selection. Only
  `applypriority.global.L2` and `discard.global.L2` exist, and those are separate instructions.
- The load/store vectorizer (runs inside llc) merges hinted and plain loads into one `v4`
  without complaint (`k_mixed_vec4`).
- Custom metadata on loads does NOT survive `-O3`: 3 of 22 tagged global loads keep it. The float4
  view loads are split into scalar loads, which drop it. Same failure family as `!spirv.Decorations`
  on GEPs (memory `o3-strips-spirv-decorations`).
- **Inline asm works.** llc passes `asm sideeffect "ld.global.nc.L1::no_allocate.L2::256B.v4.f32 ..."`
  through. ptxas treats it as an ordinary load: it unrolled the loop x16 and emitted
  `LDG.E.NA.LTC256B.CONSTANT` (sm_90). `st.global.cs` became `STG.E.EF`.
- **PTX ISA version:** llc emits `.version 7.0` for sm_80 and 7.8 for sm_90. ptxas rejects
  `L2::NNNB` below 7.4. `-mattr=+ptx78` fixes sm_80 (where `L2::256B` became `LTC128B`). So the
  lowering must raise the PTX version whenever a hint is emitted.

**SPIR-V (Intel):** the plumbing already exists, from the MMA work (`CRISP_CACHE_CONTROL`
environment experiment):
- `%attach-cache-control-load` (codegen)
- `%inject-cache-control-decorations`, a post-opt text pass re-attaching `CacheControlLoadINTEL`
  (6442) to pointer definitions
- llvm-spirv with `--spirv-ext`

It reached the `.spv` (58 decorations verified), and BMG ran it. But it only decorates
coop-matrix loads and 2D block prefetches, found from their call sites. Measured: no benefit for
matmul (-0.8% / -3.3%, within noise). `performance-levers.md` lists it as ineffective. Plain element
loads and `CacheControlStoreINTEL` (6443) were never tried. Honest expectation: the Intel side is
for parity and correctness; it may not be faster.

**Recommended lowering (to agree):**
1. Codegen records, per kernel, `param-index -> :cache intent`, from the Storage Handle types. The
   physical params are positional (`%0..%N`, the hoist ABI). Views inherit, so they map to their
   parent's param.
2. Read-only stays in codegen via `!invariant.load` (that metadata does survive, and NVPTX honours
   it).
3. A post-opt, pre-backend pass, in-process via the LLVM-C API (not text): run the load/store
   vectorizer ourselves, then for each global load/store walk its pointer to its base kernel
   argument (through GEP / casts / phi / select) and look up the intent.
   - **PTX:** replace the access with an `asm sideeffect` load/store carrying the qualifiers, with
     a memory clobber for ordering safety. ptxas still schedules it freely. Raise the PTX ISA
     version when any hint is emitted.
   - **SPIR-V:** attach `CacheControlLoadINTEL` / `CacheControlStoreINTEL` to the pointer, through
     the existing re-attach path (or move that pass in-process too).
4. One provenance walk, two emitters. It also replaces the coop-load call-site scan.
5. Tile ops (cp.async `.ca/.cg`, TMA `L2::cache_hint`, Intel 2D block cache controls): not spiked
   yet. LLVM does have cp.async and TMA intrinsics with cache-hint operands, and Crisp already
   emits those ops. Check how, at the start of that phase.

Rejected: a PTX text post-pass (register provenance in PTX text is fragile) and codegen-time
metadata (dropped by `-O3`, above).

## Intent -> instruction mapping (PROPOSAL, 2026-10-23)

Chris agreed the lowering above ("continue forward"). The vocabulary below is the working set.

**Spelling.** One key. A bare intent, or a list that adds the L2 prefetch size. The same value
syntax is used for the per-operation override on tile ops:
```lisp
(def-type in-vec (vector float :address-space :global :align :compact :cache :streaming))
(def-type in-vec (vector float :address-space :global :align :compact :cache (:streaming :prefetch 256)))
```

| Intent | PTX load | PTX store | SPIR-V load (L1, L3) | SPIR-V store (L1, L3) |
|---|---|---|---|---|
| `:default` | (nothing) | (nothing) | (nothing) | (nothing) |
| `:streaming` | `L1::no_allocate.L2::evict_first` | `L1::no_allocate.L2::evict_first` | Streaming, Streaming | Streaming, Streaming |
| `:reused` | `L2::evict_last` | `L2::evict_last` | Cached, Cached | WriteBack, WriteBack |
| `:no-l1` | `.cg` | `.cg` | Uncached, Cached | Uncached, WriteBack |
| `:prefetch N` (64/128/256) | `L2::NB` (loads only) | — | not mapped (no Intel equivalent; documented) | — |

Rules:
- `.nc` is never declared. It is added when codegen proves the handle read-only, and it combines:
  `ld.global.nc.L1::no_allocate.L2::evict_first.L2::256B.v4.f32`.
- PTX ISA is raised to >= 7.4 (sm_70+ eviction priorities, prefetch sizes) whenever any hint is
  emitted.
- SPIR-V tokens: `CacheControlLoadINTEL` = 6442 (Uncached 0, Cached 1, Streaming 2,
  InvalidateAfterRead 3, ConstCached 4); `CacheControlStoreINTEL` = 6443 (Uncached 0,
  WriteThrough 1, WriteBack 2, Streaming 3). Level 0 = L1, 1 = L3.
- Every combination must be verified against ptxas / spirv-val in the specs, not assumed.

## Decisions made overnight 2026-10-23/24 (Chris away -- FOR REVIEW)

1. **`:cache` is not part of the canonical type or type identity.** The four expanders
   (`%expand-{vector,matrix,tensor,cell}-type-specifier`) validate and STRIP it. def-type keeps the
   RAW spec in `*crisp-type-aliases*`, and `%cache-hint-of-type` reads the hint back from there
   (following the alias chain). So `(vector float ... :cache :streaming)` and the same without
   `:cache` are one type, like C's `restrict`. This leaves the positional 6-tuple untouched.
2. **PTX mapping changed from the agreed table -- ptxas forced it.** CUDA 12.4 ptxas REFUSES
   `L1::no_allocate.L2::evict_first` ("Multiple cache eviction priority modifiers") and a bare
   `L2::evict_last` on ld/st ("'.L1::eviction_priority' syntax expected"). The verified-legal forms
   (all assembled for sm_80 and sm_90; `put_temp_files_here/192-spike/combos.ll`) are now the mapping:
   `:streaming` -> `.cs` (SASS `LDG.E.EF` / `STG.E.EF`, evict-first in L1 and L2); `:reused` ->
   `.L2::cache_hint` under `createpolicy.fractional.L2::evict_last` on sm_80+ (`L1::evict_last` on
   loads below sm_80, no store form there); `:no-l1` -> `.cg`; prefetch -> `.L2::NB`; `.nc` combines
   with all. The table in "Intent -> instruction mapping" above is superseded for PTX.
3. **Per-operation `:cache` on tile operations is REFUSED, not implemented.** Tile operations honour
   the TYPE-level hint on every path: their element accesses trace back to the argument, and Intel
   block / coop builtins have their pointer decorated. A per-operation override needs a construct
   that survives -O3 (one tensor, two access patterns -- the post-opt walk cannot tell the accesses
   apart, and metadata is dropped). Sketch for a follow-up: route the operation's view through an
   opaque marker call `@__crisp_cache_hint.<intent>(ptr)` that the post-opt pass resolves and
   removes. The motivating matmul case (A, B `:reused`; C `:streaming`) uses separate tensors, so the
   type level already covers it. Refusing beats silently ignoring.
4. **cp.async and TMA are not hinted (left exactly as before).** 4- and 8-byte `cp.async.ca` has no
   L1-bypass form (`cp.async.cg` is 16-byte only), and L2 policies on cp.async / TMA need either
   inline asm on shared addresses or a policy operand built at codegen. Neither can be verified on
   metal tonight. Follow-up.
5. **Adjoints inherit nothing.** In a `*_GRAD` kernel, a parameter `P_GRAD` whose `P` is also
   declared is a shadow buffer and gets no hint, though it is declared with the same alias type.
   Primal reads in the `_GRAD` kernel keep theirs. Spec 14 checks it.
6. **The read-only re-mark is guarded.** The post-opt pass re-applies `!invariant.load` (BUG 134) to
   loads traced to a read-only argument, i.e. a tensor before `&out` (codegen's existing
   convention), but never to an argument the same function stores to, updates atomically, or passes
   to a call.
7. **The compile API (190) does not report `:cache`.** It has no runtime effect, and the stripped
   canonical type is what the metacrisp / ABI already carry. Decided, not accidental.
8. **PTX accesses of other element types are left unhinted:** anything but `float` / `double` /
   `i32` / `i64` scalars and 2- / 4-lane vectors, and under-aligned vectors (a `.v4` needs natural
   alignment). Correct, just not hinted.
9. **`-mattr=+ptx74` is passed whenever a hint is emitted.** It only ever RAISES the PTX version
   (sm_80 7.0 -> 7.4; sm_89 / sm_90 / sm_100 unchanged).
10. **Implementation lives in overlays** (`crisp-compiler-overlay.lisp`, `spec-runner-overlay.lisp`).
    Several functions were re-appended as bugs were found; **only the LAST copy is live**, and the
    last copies say "FOLD: this is the one to take". Wrappers (`ensure-opencl-kernel-metadata`, the
    three tile analyzers) use the `(defvar *orig* (fdefinition ...))` pattern; the FOLD comment says
    where the one added call goes.

## TODO

- [x] Agree the design direction and scope (2026-10-23). Key name: `:cache`.
- [x] Spike (scope 1). Results above.
- [x] Agree the recommended lowering, the spelling and the mapping (2026-10-23). Stores use the
      eviction-priority form, not `.cs`.
- [x] `tests/ci-stop.txt` -> `192-cache-hints`.
- [x] TDD specs written, all red for the right reason (2026-10-23):

| Spec | Claim | Red because |
|---|---|---|
| 01-streaming-loads-ptx | :streaming inputs -> every ld `L1::no_allocate.L2::evict_first`, st plain, ISA >= 7.4 | `:cache` unknown |
| 02-streaming-stores-ptx | :streaming output -> every st hinted, ld plain | `:cache` unknown |
| 03-reused-ptx | ld and st `L2::evict_last` | `:cache` unknown |
| 04-no-l1-ptx | ld/st `.cg` | `:cache` unknown |
| 05-prefetch-ptx-sm80 | `(:streaming :prefetch 256)` -> `L2::256B`; sm_80 ISA raised from 7.0 | `:cache` unknown |
| 06-default-is-inert | `:cache :default` == no key | `:cache` unknown |
| 07-mixed-params-ptx | only A hinted -> exactly half the loads (provenance) | `:cache` unknown |
| 08-view-inherits-ptx | lane-accessed float4 view of :streaming input -> vector, .nc, hinted | `:cache` unknown |
| 09-lane-view-readonly-nc | BUG 134: same kernel, no :cache -> every load .nc | plain `ld.global.v4.b32` (the bug) |
| 10-cell-reused-ptx | :cache on a cell | "Invalid type option" |
| 11/12-streaming-*-spv | CacheControlLoad/StoreINTEL on the right argument only | `:cache` unknown |
| 13-streaming-metal | correct results, L0 + CUDA | `:cache` unknown |
| 14-autodiff-neutral | VERIFY-AUTODIFF; `_grad`: primal reads hinted, adjoint stores not | `:cache` unknown |
| errors/01-04 | unknown intent, bad prefetch size, :local, list without intent | wrong message (checked by run-error-specs) |

  Validators: PTX in `overlays/spec-runner-overlay.lisp` (`%c192-*`, `validate-ptx-cache-*`); SPIR-V
  in `overlays/crisp-compiler-overlay.lisp` (`%spv-cache-control-census`, `validate-spv-cache-*`).
  Tile-op specs come with that phase.
- [x] Implementation: type parsing (`:cache` on vector/matrix/tensor/cell) + the error messages.
- [x] Implementation: codegen side table (LLVM param index -> intent + read-only; views inherit by
      construction -- a view's accesses walk back to the parent's argument).
- [x] Implementation: post-opt provenance pass (LSV first on PTX, walk to argument, re-apply
      `!invariant.load` with the write guard).
- [x] Implementation: PTX emitter (inline asm, `+ptx74`) and SPIR-V emitter (decorations: typed
      zero-offset GEP for plain accesses; the pointer's defining instruction for block / coop builtins).
- [x] Implementation: AD (adjoints inherit nothing).
- [x] Tile ops: type-level hint honoured on every path (spec 15: sync load-tile / load-tile-at, BMG
      metal; spec 16: Intel XMX coop loads + C store, BMG metal MMA_CORRECT); per-operation `:cache`
      refused (errors/05).  cp.async / TMA: follow-up (decision 4).
- [x] Unit tests: `cache-hints.unit.lisp` (parser, opcode builder, SPIR-V controls, .ll parsing,
      pointer walk incl. the i64 + inttoptr chain).
- [x] Docs: ideal_001 (`:cache` subsection, `prefetch-tile` section), writing-crisp, performance-levers;
      chapters / reference / call graph / globals / specials regenerated.  NOTE: the generators scan
      src/ only -- regenerate reference.md / call_graph.md / globals AFTER the overlay fold to pick up the
      new functions.
- [x] Handoff for AG: `contests/gpu-mode/HANDOFF-192-cache-hints.md`.
- [x] ci.yml / run-all-tests.bat: no change needed (both follow ci-stop.txt).
- [x] **Final suites on the final build (2026-10-24):** unit 392/392, E2E spine 1529/1529, negative
      365/365.  (Local runs: CUDA hoists SKIP -- no nvcc here.)
- [x] **NVIDIA metal, H100 PCIe (driver 595.91), 2026-10-24:** targeted run 21/21; spec 13 (`.cs`
      loads + stores) `c: 0 2 4 6`, spec 15 (tile ops, 64-bit `.cs`) `out: 2 3 1 2`.  Spec 14's
      VERIFY-AUTODIFF is unpinned, so it runs on SPIR-V only (BMG-verified).
- [x] **Full CUDA suite on the H100 PCIe (2026-10-24):** main phase 1524/1529, `--differentiate`
      1383/1529, negative 365/365.  Accounted for:
      - 137 `--differentiate` failures: VERIFY-AUTODIFF auto-selects the SPIR-V route, and the pod has
        no `llvm-spirv` (exit 127) or `libze_loader.so`.  Environment; these kernels carry no hints.
      - 6 were **192's validators**, too strict under `--differentiate`: the `_grad` kernel's adjoint
        loads are unhinted by design.  The validators now skip `_grad` entries; spec 14's adjoint
        validator reads the `_grad` entry raw.
      - 08 / 09 under `--differentiate`: BUG 061 (AD of float4 lane access mints a scalar adjoint),
        pre-existing -> `KNOWN-ISSUE[differentiate]: BUG-061`.
      - Main phase: 122/07, 128/13, 128/14, 170/43 (libdevice FFI hoists) pass when run singly on BOTH
        main and cache-hints built side by side on the pod; 154/03 wgmma-two-warpgroups is MMA_WRONG on
        both builds -> pre-existing, filed as BUG 135.
      - Local after the fixes: 192 default 21/21, 192 `--differentiate` 21/21 (2 KNOWN-FAIL BUG-061).
- [ ] (superseded) **NVIDIA metal** (spec 13 / 15 TEST-HOIST[CUDA], spec 14 VERIFY-AUTODIFF[CUDA] if pinned):
      needs the pod.  Every spec's PTX already assembles with CUDA 12.4 ptxas for its .target.
- [ ] Fold the overlays into src/ (Chris).  Take the LAST copy of each re-appended function.

## Bugs found and fixed during the night (all caught by checks beyond the spec validators)

- PTX mapping illegal to ptxas -> remapped (decision 2).  Caught by assembling every spec's PTX.
- `char` / `return` are shadowed in :crisp.compiler (Crisp's types / return); use `cl:char` /
  `cl:return` in compiler-side Lisp.
- PTX kernels take every handle field as i64 and rebuild pointers with `inttoptr`; the walk follows it.
- SPIR-V: an i8 decoration GEP made llvm-spirv insert an undecorated bitcast; the GEP is now typed with
  the accessed type.
- The write-guard regex was written with single backslashes before `(` and `)`, which a Lisp string
  silently drops -- the pattern became a regex group that never matches real IR -- so it never
  matched; an escape audit of every overlay string literal found no other instance.
- **The physical parameter index ignored multi-slot semantic parameters** (an implicit scratch tile
  is one node, six LLVM params): a kernel with scratch ahead of a hinted / read-only tensor indexed the
  WRONG argument, and the read-only re-mark could have tagged another argument's loads.  Fixed with the
  same get-expanded-types widths create-llvm-function-type uses; spec 15 is the regression test.  The
  first full E2E run (1526/1526) predates this fix; the suites were rerun on the final build.
- [ ] **Document `prefetch-tile` in `docs/ideal_001.md`.** It appears only inside MMA examples (lines
      ~12751, ~13312-13328). It has no section of its own. Facts from `analyze-prefetch-tile`
      (`src/mma.lisp`): `(prefetch-tile SRC (COORD-Y COORD-X) :size (H W) &key warp-partitioned)`;
      Intel/SPV-only (Subgroup2DBlockPrefetchINTEL; PTX refuses: NVIDIA's model is cp.async into SLM);
      requires `--hardware-profile`; fire-and-forget, no destination, never changes results;
      `:warp-partitioned` (endeavour 158) splits the footprint across the workgroup's warps. Endeavours
      142 and 158.
- [ ] BUG 134 (retyped view loses `.nc`): fold in here? Same mechanism (view propagation).
- [ ] Spec claims are checkable in emitted text (PTX qualifiers, SPIR-V decorations). Metal check via
      the vectorsum contest entry.
