
SCRAMBLE — the working plan
===========================
Pruned 2026-10-11.  Everything before that date, done and not, is verbatim in
`plan/scramble-archive.md`; `(Lnnn)` below is the line in that file, for context.
Known defects live in `plan/bugs.md` and `tests/adversarial/issues.md`, not here.


NEXT  (housekeeping-oct)
========================
- [x] audit scramble.md -> this file + scramble-archive.md
- [x] clear out put_temp_files_here (7.5 GB -> 0.3 GB; cited evidence promoted to research/)
- [x] retire endeavour-numbered pod scripts (moved to put_temp_files_here/pod-scripts/)
- [x] adversarial tests: 22 KNOWN-FAIL -> 5 open issues (2026-10-12; put_temp_files_here/adversarial-overnight.md)
- [ ] adversarial follow-ups: c-t default override + type-aware XXX~ (ADV-012/013/023), c-t-assert in a body
      (ADV-022 / BUG 114), AD through implicit templates (ADV-003/004/011/017), BUG 115-117
- [x] 185 math-ops: chapter 32 made real (integer division, sqrt/rsqrt/abs/clamp/*!, bit ops, tanh/erf/exp2,
      AD); 3 silent bugs fixed; BUG 062/119 closed, BUG 120 opened -- 2026-10-12
- [x] review bugs.md -- 2026-10-13: closed 024 047 056 060 090-093 095 096 (fixed + folded, never ticked);
      094 106 now partial; 018 022 059 068 108 re-verified open.  059 (float into a half element, silent)
      matters for fp16 contest work.
- [x] docs for AI: docs/writing-crisp.md (linked from README, CLAUDE.md, ANTIGRAVITY.md); stale reduction docs fixed -- 2026-10-13
- [x] revisit docs/criticsms.md: status table added at the top -- 2026-10-13
- [x] refactor (narrow: specials.lisp tail, build warnings; long functions after the first contest)
- [ ] debugging: (1) --debug also writes a listing (myfile.crisp.dbg) whose line N is virtual line N --
      the s-expression path and its form -- and the DWARF file entry points at it (today DWARF 'lines' are a
      pre-order count of tree paths, so a debugger would show the wrong line of the .crisp); (2) cuda-gdb smoke
      test on the next pod rental (break / step / print in a Crisp kernel), alongside the 185 PTX libdevice check
      (tanh / erf / exp2); (3) gdb-oneapi on the BMG once it is not driving the display (iGPU for the monitor?) (L339)
- [x] make new prerelease (see Release)
- [ ] set up Claude with runpod.io MCP -- needs guardrails first (spend cap, auto-kill TTL)
- [x] Start AG on contest submissions -- 2026-10-16: LeetGPU challenge 01 (vector add) submitted; the format
      is Crisp PTX as inline asm inside a CUDA __global__ + a solve() launcher.  H100: 0.16 ms -> 0.12 ms
      (78th pct) after removing a hand-set occupancy-target that spilled (BUG 124).  Recipe in
      docs/writing-crisp.md section 12.  Follow-ups: one-thread-per float4 (AG), BUG 125 (.nc through views).
- [x] 186 contest-fixes (branch contest-fixes) -- 2026-10-18: BUG 059 element stores type-checked +
      to-half / to-bfloat16 (BMG-verified RNE); BUG 125 read-only through views (ld.global.nc.v4);
      BUG 124 option (b), the launcher + harnesses report registers / local bytes.  Exposed BUG 126 (AD of
      a cell-of-struct stores a float adjoint).  tests/spec/186-contest-fixes/contest-fixes.md.
      Open: re-measure the float4 kernel on H100 (the .nc effect + the new resource line).
- [x] matmul report is not up-to-date. winning entry on leaderboard is not in Reprot.
     plus we added :via :tma support, but don't see ANY kernel using that 
- [ ] matmul contest for GPU Mode needs B200 and teneg05? support ( follow up to wgmma )
- [ ] benchmarks need above, plus incorporation of :via :tma and possibly other code changes introduced by matmul-contest branch.  And then rerun.


OPEN
====

### Docs
- [x] warp-size not get-warp-size, warp-id not get-warp-id, get-workgroup-id not get-group-id (L892) -- 2026-10-12
- [x] "Sum Vector Using Local Memory" and "Sum Vector using Shuffles" rewritten from compiled code (L893, L894) -- 2026-10-12
- [x] --binary-gpu-target: already marked planned; its usage example now says aspirational (L322, L972) -- 2026-10-12
- [ ] synchronous load-tile / store-tile FASTER than async for very small tiles (L629)
- [ ] tile oversubscribe-and-assert behaviour (L636-638, see Tiles)
- [ ] scan design doc for :size :length :extent on vectors -- c-t or not? (L601)
- [ ] make-scratch-XXXX in doc vs as realized: in sync? need :contiguous-term? (L602)
- [ ] LLVM can only bitcast same size: (as-ulong 12345) fails, (to-ulong 12345) works. Decide + document (L481)
- [x] how to tag the repo to match a release: docs/releases/HOW-TO-RELEASE.md (L931) -- 2026-10-13
- [ ] how to contribute / PR cycle (L932)
- [ ] split-docs.lisp -- less granular, simplify? (L859)

### Release / distribution
- [x] opt-windows.exe / opt-linux: OBSOLETE -- opt runs in-process via libLLVM (%opt-available-p is never called) (L728)
- [x] script for bundling a release: package_prerelease.py --version + build-linux-release.sh (L937) -- 2026-10-13
- [ ] Quicklisp distribution (L22, L67)
- [ ] SEO: logo; confirm discoverable at https://cperkinscperkins.github.io/crisp/ ; search console (L1186-1190)
- [ ] proper bug tracker -- GitHub Issues? (L1200)
- [ ] .whl and Python Wheel <== 

### Benchmarks ("above reproach")
- [ ] MMA and reduction reports BOTH: (a) measure/report vendor device compile time (MKL, cuBLAS ...)
      and (b) say the vendor uses precompiled kernels (L888)
- [ ] "Apples" routines not always matching the Crisp algorithm (L834, L945)
- [ ] CUDA arch skip-gate: a capability check, not an arch allowlist (L799)
- [ ] small sizes fare poorly against cuBLAS and MKL -- why? (L762)
- [ ] performance ratchet updated, with control for multicast (L763)
- [/] remove benchmarking from hoist, or put it behind a hoist flag (L766)
- [ ] benchmark A|D? (L940)
- [ ] SAXPY in the cross-platform set (L995)
- [/] RunPod as a GitHub Actions target (hoist tests only? separate .yml) (L985)

### Compiler hygiene / refactor
- [x] src/specials.lisp tail -> src/globals.lisp (hand-written, loaded right after specials; generated file now
      wholly generated) -- 2026-10-15.  (The generator had carried the tail since 184, not wiped it.)  Regenerating
      also proclaimed 6 globals that 185 / the adversarial fixes had added without a regen. (L864)
- [x] warnings when building the compiler: clean build 15 STYLE-WARNINGs -> 0 (2026-10-15).  Left: 20 SBCL
      "deleting unreachable code" notes -- REVIEWED 2026-10-16 (put_temp_files_here/refactor/unreachable.txt):
      1 real bug fixed (make-matrix's friendly error came after (* width height), so users got a raw type
      error; spec 083/errors/02), 1 latent dead branch noted (semantic-literal singleton types (keyword :k)
      are swallowed by the earlier (listp type-spec) clause; no spec reaches it), 18 harmless (L862, L863)
- [x] overly long functions (L861) -- refactor-oct phase 3, 2026-10-16: every LOGIC function over 100 CODE
      lines decomposed (12: generate-backward-walk 550->271, anf-normalize, %emit-launch-base, calculate-
      uniformity-state, resolve-type-to-llvm, %generate-backward-kernel-ast, parse-cli-args, compile-files,
      %fused-grid-reduce-form, and the semantic-aref / -coop-op / -make-view codegen).  Each verified
      byte-identical: compiler corpus (7588 files), hoister corpus (1471), CLI snapshot (16 cases).  Left on
      purpose: registration tables, %handle-single-value-backward (half documentation), and the rest of
      generate-backward-walk (its process-form closure -- moving it needs a context object; proposal).
- [x] --mma-bench retired (2026-10-16): L0 fixture binds SLM scratch (chapters 1-3 moved onto it; Docker
      agreement within 0.6% to N=1024, 1-6% at 2048/4096), fixture BUILD_FLAGS "" bug fixed, matmul.py
      auto-bench paths removed (a kernel the fixture cannot run is a loud missing row), results record
      "harness": "fixture", hoisters refuse --mma-bench / --grid-tile by name.  --mma-test stays.
- [x] hoister helpers: 18 functionally identical helpers moved into crisp.hoist (2026-10-16); 1471 hoister
      outputs byte-identical.  Left per-backend: %record-field-args, %mma-parse-args, main.
- [x] BUG 122 fixed (2026-10-16): log lines no longer leak onto stdout above --log-level=off.
- [x] reproducible output: initialize-compiler resets *gensym-counter* to *gensym-counter-base* (10000,
      src/globals.lisp) -- 2026-10-15.  Same source -> byte-identical output across builds (proven with a
      probe build: 7588/7588 corpus files identical).  Names now read %g10038.
- [x] ersatz output -> log4cl (2026-10-15): main.lisp progress chatter (Starting pass / passes finished /
      hoister / FFI linking) and core.lisp's DEBUG prints.  Kept: errors, usage, user WARNINGs, the IR, c-t-output,
      spec-validator FAIL lines, and the hoisters (no log4cl by design; a --quiet flag if wanted).  Found BUG 122:
      above --log-level=off every log line ALSO lands on stdout (exe only). (L191)
- [ ] audit uses of symbolp that assume (symbolp nil) is false (L209)
- [ ] move validators to their own file(s); only the spec runner loads them (L237)
- [ ] dump tables like dump-env for *function-table* and others (L303)
- [x] the "volatile" BUG 030 workaround -- CHECKED 2026-10-18 against the corpus: FORWARD kernels never get it
      (1 of 1111 has a volatile access: 118/02 arrival-sync's deliberate %volatile-read spin -- correct, not
      030).  BACKWARD: 8 of 1111, all struct-at-kernel-boundary (009/12, 056/*, 103/02) -- 030's own pattern.
      But it is NOT SPIR-V-only: it is in the generic IR, so CUDA struct _GRAD kernels pay it too, though the
      IGC bug does not exist there.  Optional follow-up: gate it on :spirv. (L607)

### Errors and flags
- [ ] unknown / misspelled CLI flags should be a compilation error (L148, L975)
- [ ] error coverage: internal errors, errors from LLVM, bad user defmacro, failure to infer,
      bad syntax / parens, malformed `=> =>` (L126-132, L142-143)
- [ ] errors involving return type state what the compiler thinks it is (L472)
- [ ] audit errors: some don't show the location (L474)
- [ ] FAIL-WITH[--differentiate] message isn't checked for "normal" tests (L475)
- [ ] 02-kernel-illegal-voidp and friends: no CHECK-FAIL header (L476)

### AutoDifferentiation
- [ ] cannot differentiate float4 (or other machine vector types)
- [ ] cannot differentiate "shadowed" vars. see 186/04.  Fix? Document Limitation?

### Language
- [ ] bool type and literal `true` / `false` (analysis/control.lisp: "no boolean literal yet") (L163, L174, L387, L613)
- [ ] variadic + * < = etc, up to 5 or 7 args (L170, L283)
- [ ] i64 / ui64 types and literals; i128 and friends (L508, L509)
- [ ] &out: appears once only; enforce no reading from &out -- or are these superseded by the
      &out input/output decision? (L226, L497, L498)
- [ ] (atomic-xchg! (~ someCell) v) -- not exercised by any spec (L257)
- [ ] r-t-assert on set! of offset~ / parent~, validated against --runtime-checks (L261, L262)
- [ ] compile error mutating offset/stride under :compact / :compact-offset alignment; extent? (L512)
- [ ] make-implicit-XXXX with :msg and :name; make-scratch-cell via make-implicit-cell (L235, L236)
- [ ] .metacrisp review: :name, others; flags recorded in metadata (L239, L331)
- [ ] scratch cells as &optional / &key args -- test (L469)
- [ ] DENY setf and aref (L225)
- [ ] (declare (type ...)) in let (L183)
- [ ] def-derived-type and templating: test (branded types CAN be templated) (L386)
- [ ] reqd_work_group_size from strategy choices (L510, L585)
- [ ] strategy: :interleaved (deferred to def-orchestration), check-thread-bounds / check-wg-bounds,
      single-task as declare vs strategy (L582-586)
- [ ] :derive-from / :strided with tensors of any arity (L965)
- [ ] gen-XXXX promotion to kernel (L618)
- [ ] convert-layout (in Crisp) (L632)
- [ ] (byte-size float) (L701)
- [ ] integer-only operations -- 6 or 7, easily overlooked (L732)
- [ ] def-parameter, -D, #+ / #- (L744)
- [ ] prefetch-tile L1 / L2 / L3 targets (L761)
- [ ] spill warning may be eager on Intel (L779)
- [ ] when-thread-in-warp-is / when-thread-in-group-is divergence inside reductions (L895)
- [ ] L0 hoisting doesn't interpret hardware-profile yet (L974)
- [ ] soa-matrix / soa-tensor N (L519)
- [ ] standard library (src/stdlib/matrix.crisp; transpose / transpose!) (L516, L523)
- [ ] Revisit def-constant-vector -> def-constant-storage? (L1096)
- [ ] => nil to => void? (L1105)
- [ ] if-reorder (see google doc) (L1104)
- [ ] --allow-redefinition (L1107)
- [ ] rework quantized and microfloats (L1050)
- [/] precision naming: ieee | fast | ieee-ftz (L710)
- [/] anaphoric support, star `*` variants (L202, L203)
- [x] `atomic-load` (relaxed, device scope): a plain atomic READ.  Polling today has to use a read-modify-
      write -- the prefixsum lookback spins on (atomic-add! (~ flags j) 0u), which PTX lowers to
      atom.or / atom.add and which serializes at L2 when many tiles poll one flag.  CUB polls with
      ld.relaxed.gpu.  Fits "atomics order nothing, fences do": atomic-load is relaxed, an explicit
      mem-fence orders it.  PTX ld.relaxed.gpu (sm_70+) / SPIR-V OpAtomicLoad; probably an atomic-store
      to match.  Measure on the prefixsum kernel (contests/gpu-mode/05-prefixsum-v2/prefixsum_packed_rfl.crisp).
      Found 2026-10-25 (F4 of the prefixsum single-pass findings, put_temp_files_here/psum/FINDINGS.md).
      DONE 2026-10-27, endeavour 195 (overlay, not folded; 9 decisions for review in
      tests/spec/195-atomic-load/atomic-load.md): atomic-load + atomic-store!, BMG-verified.  H100 A/B on
      the prefixsum: the relaxed POLL is neutral (760 vs 753 us); an atomic-store! PUBLISH is 20% slower
      than atomic-xchg! (913 us).  F4's L2-serialization premise does not show up in this kernel.

### Tiles / tensors
- [ ] hoisting: total tensor size an even multiple of the tile ("oversubscribe", identity fill
      declared by :strategy?); --runtime-checks validates it (L636, L637)
- [ ] is :align :strided / :compact handled correctly? unit test (L538)
- [ ] test offsets/strides really SET by hoisting code (needs a .cpp fixture?) (L543)
- [ ] double check branding on storage handles (L549)
- [ ] no-sroa? (L557)
- [x] DONE 2026-10-28, endeavour 198 (`:b-major :mn`; tests/spec/198-wgmma-transb).  H100 scored case
      290 -> 255 us, bit-exact.  Overlay unfolded.
      wgmma transB=1 for 16-bit operands: accept an MN-major (K N) B tile in wgmma-accumulate-via-tile.
      Today *wgmma-16-trans* pins (0 0) and src/mma.lisp refuses (K N) B; the f16/bf16 hardware reads
      it with transB=1 (CUTLASS GMMA::Major::MN), but the SMEM descriptor LBO/SBO meaning changes for
      MN-major, so it is not just flipping the bit.  tf32 has no transpose -- keep refusing there.
      Found 2026-10-27 on matmul_v2 (GPU MODE): its b is (K N) contiguous in N, the plain `a @ b`
      layout.  First contest entry transposes B in the wrapper instead (~25 us tax on H100).
- [ ] Persistent launch for tiled kernels: tile-stride over a 1-D grid walking the LINEARISED tile space
      (tile t = blockIdx + k*gridDim -> (row, col)), so the hoist can launch residency-capped grids.
      Today :tile-shape launches one block per tile, and a 1-D :strided grid under N-D tile-stride
      serialises an axis (the L0 7.6x trap).  Probe: 3% on the H100 contest kernel once stores were packed
      (endeavour 197 doc).  Also the natural home for tile rasterisation (L2 reuse).  Endeavour 197 step 2.
- [x] stmatrix + TMA-store epilogue for wgmma accumulators -- DONE, endeavour 199:
      `(store-tile-at (to-half D) C (r c) :via :tma)`; H100 contest kernel 255.5 -> 228.0 us, exact
      (tests/spec/199-tma-store/tma-store.md).  Persistence measured at only ~1 us on top of it.
- [x] sort_v2 contest -- endeavour 200 (2026-10-30, Chris away; decisions D-200-* for review):
      LSD radix (range-reduced keys, 3 passes), H100 3749.5 us #19/30; onesweep variant correct but slower;
      bitonic beauty entry.  Fixed BUG 138 (ash/popcount inline on PTX) and BUG 145 (while type) in
      overlays; opened BUG 146/147 (BMG).  tests/spec/200-sort-contest/sort-contest.md.
- [ ] sort_v2 next lever: a warp ballot / match builtin (vote.ballot / match.any; SPIR-V subgroup
      ballot) for warp-level multisplit ranking -- one 8-bit ranking pass instead of two 4-bit splits.
      A compiler feature: discuss first.
- [ ] `:via :tma` for an f32 C (the benchmark suite's wgmma kernels): stmatrix is b16-only, so it needs a
      st.shared.v2.f32 staging write with its own swizzle.  D-199-5.
- [ ] ldmatrix for load-fragment-a / -b on PTX.  The mma.sync path reads every operand fragment from
      shared memory one 2-byte element at a time (ld.shared.b16 + packing; no ldmatrix anywhere).  The
      A100 matmul_v2 entry (4-warp, vectorized cp.async) is 4.7 ms vs cuBLAS 0.67 ms.  ldmatrix.x4 for A
      and ldmatrix.x2.trans for a (K N) B, plus a padded or swizzled scratch layout against bank
      conflicts.  Found 2026-10-28, endeavour 196.
- [ ] (local-size :set-to N) should emit .maxntid N (or .reqntid) in the PTX.  Without it ptxas may
      spend 255 registers a thread and a 288-thread block cannot launch ("too many resources requested
      for launch"); the matmul_v2 launcher passes CU_JIT_THREADS_PER_BLOCK to compensate.  Endeavour 196.
- [ ] offsets~ accessor for tensors (strides~ and extents~ exist).  The vectorized cp.async load-tile
      ASSUMES the base address + offsets is 16-byte aligned because it cannot test it (D-196-8).
- [ ] autodiff through a converted store source, (store-tile (to-half D) C ...) -- refused by name today
      (D-196-12).  The adjoint of (to-half D) is D's; the accumulator backward must see through the
      conversion in the activity scan, %mma-ad-register-accumulator-tile-p and the wgmma store path.
      Then delete tests/spec/196-matmul-contest/errors/04 and that directory's SKIP-WITH[--differentiate].
- [ ] tcgen05 lowering (B200/B300, sm_100a) -- its own endeavour.  wgmma is sm_90a only, so today
      B200 falls back to mma.sync.  Surface mostly fits the wgmma forms; new pieces: TMEM accumulator
      (compiler-managed alloc/dealloc), single-thread issue, completion via tcgen05.commit -> mbarrier
      (needs an :on-complete / commit form -- the one real semantic change), TMEM->reg epilogue in
      store-tile-at, an accumulator ring for epilogue overlap; later cta_group::2.  popcorn B200 test
      and benchmark modes are free, so the matmul_v2 contest is the dev test bed.

### Autodiff
- [ ] def-function with &out param in sub-function differentiation (L436)
- [ ] structs directly on the kernel boundary: probably refuse to differentiate if they feed an &out (L457)
- [ ] grid-level dependent AD (BUG 102) -- needs VERIFY-AUTODIFF with more than one &out (L877)
- [ ] MMA A|D loose ends (L757)
- [ ] more testing: sub-functions with return values and &out params (L409)

### Testing / spine
- [ ] r-t-assert and --runtime-checks need testing; audit which routines should support it;
      --debug-logging? (L470, L670-672)
- [ ] 009-def-struct/04-def-struct-mixed-types.crisp needs a validator (L471)
- [ ] tests/spec/111-load-and-store-tile/09-load-transpose-2d.crisp uses `t` not `true` (L795)
- [ ] OpenCL CPU device on CI / POCL / Intel OpenCL CPU runtime (L341, L1194, L1195)
- [ ] oneAPI docker image for oneapi-gdb to test our DWARF (L339)
- [ ] negative tests: exactly one failure per file (L1119)
- [ ] spine proposals not built: TEST-FILES[...], PASS-ONLY-WITH, CHECK-WARN, .expected.xx,
      -l0.cpp, .perf -- keep or drop? (L503, L1134-1141, L1159, L1163)
- [ ] self-hosted GPU runner (L1196)
- [ ] VS Code: lisp highlighting for .crisp (L477)


IDEAS / LATER
=============
- C API for compilation (Target #11); def-orchestration, def-topology, primitives (L76, L913-916)
- out of core orchestration -- not now (L764, L889, L919)
- H100 small-input gap: needs a genuinely new idea (Hopper cluster hierarchy) -- not now (L887)
- PGAS / SHMEM (L1021-1038, L1049)
- "empty room fallacy"? GPU display / monitoring? (L753)
- "Crisp IR": generalize target intrinsics beyond --ir-target spv/ptx? (L195)
- math intermediaries / more explicit passes; a --sanity flag that dumps each pass (L407, L1170-1178)
- more algorithms: bitonic sort, radix sort (L998-1000)
- other platforms: OpenCL, Huawei, Triton? Mojo? (L1018)
- Google AI Studio (L1204)

QUESTIONS
=========
- why don't log:debug messages show up in the Alive REPL even with the level set? (L1044)
- commutative-op-type instead of binop-type for reductions? (L1045)
- give up on "no (to-int)" already? (L224)


Milestones
==========
- **2026-01-03**: Compiled first `.spv` from Crisp and successfully ran it with a bespoke OpenCL script. Massive milestone.
- **2026-01-22**: Crisp toolset can now generate (hoist) `.cpp` files for those kernels, and the testing system runs them on actual GPU iron via Level Zero.
- **2026-04-29** `loop-vector-stride` joins the toolkit, along with def-grid-function, strategy declarations, tensors/vectors/matrices, and more. With this Crisp can now be used FOR REAL to write
reductions, matrix multiply, stencil operations, convolutions and more.
- **2026-05-27**: CUDA hoisting, runpod.io e2e testing AND performance comparisons. Crisp is fastest to compile, by far (order of magnitude).  While not yet fastest, it is breathing down the neck of CUDA and CUB.
