;;;; src/specials.lisp -- GENERATED FILE, DO NOT EDIT BY HAND.
;;;;
;;;; Regenerate with:  sbcl --script ./scripts/gen-specials.lisp
;;;;
;;;; Proclaims every global in src/ special BEFORE any file that binds one is
;;;; compiled.  Without this, a `(let ((*foo* x)) ...)` compiled before *FOO*'s
;;;; defvar becomes a LEXICAL binding -- silently, because ASDF muffles the
;;;; style-warning and ql:quickload muffles warnings outright.  The defvars
;;;; themselves keep their homes, their values and their docstrings; this file
;;;; only fixes WHEN the compiler learns they are special.
;;;;
;;;; See scripts/gen-specials.lisp for the full rationale.

(in-package :crisp.compiler)

(declaim (special
          *AD-ANY-OUTPUT-DOUBLE*
          *AD-BARRIER-RING-SYMS*
          *AD-INLINING-FNS*
          *AD-LOOP-VARS*
          *AD-OUTPUT-SYMS*
          *AD-REPLAY-PENDING*
          *AD-RING-SLOT-MARKER*
          *AD-SCRATCH-SYMS*
          *AD-SLM-SCRATCH-CTORS*
          *AD-TILE-SRC-MAP*
          *AD-VIEW-ALIAS-MAP*
          *ANALYSIS-ACCESS-MODE*
          *ANF-COUNTER*
          *ASYNC-BARRIER-INITIAL-PHASE*
          *ASYNC-BARRIER-LOAD-COUNT*
          *ASYNC-BARRIER-MODES*
          *ASYNC-BARRIER-RING-COUNTS*
          *BOUNDARY-ARRAY-PARAMS*
          *BOUNDARY-STRUCT-PARAMS*
          *BRAND-CACHE-LAST-FUNCTION*
          *BRAND-DEFINITIONS*
          *BRAND-INSTANCE-CACHE*
          *BRAND-INSTANCE-TYPES*
          *CACHED-INT32-TYPE*
          *CACHED-INT64-TYPE*
          *CALL-GRAPH*
          *CALL-SITE-ARGS*
          *CLUSTER-BARRIER-BINDINGS*
          *CLUSTER-BARRIER-NODES*
          *CLUSTER-DEGRADE-WARNED*
          *COMPILED-KERNELS*
          *COMPILER-CONTEXT*
          *COMPILER-SESSION*
          *CRISP-DYNAMIC-SMEM-SYMBOL*
          *CRISP-ENUMS*
          *CRISP-STRUCTS*
          *CRISP-TEMPLATE-ALIASES*
          *CRISP-TYPE-ALIASES*
          *CRISP-TYPES*
          *CURRENT-KERNEL-CLUSTER-DIMS*
          *CURRENT-KERNEL-IS-BACKWARD*
          *DEFAULT-MAX-REGISTERS-PER-THREAD*
          *DEFER-STRUCT-VALIDATION*
          *DENORMAL-HANDLING*
          *DIFFERENTIABLE-FUNCTIONS*
          *DIFFERENTIABLE-HOF-STORE*
          *DIFFERENTIATE-P*
          *DIVERGENT-SCOPE-DEPTH*
          *EMIT-METADATA*
          *EXPRESSION-ANALYZERS*
          *FFI-BASEPTR-SRC*
          *FN-NORMALIZED-INFO*
          *FORCE-MATH-PRECISION*
          *FOREIGN-FUNCTIONS*
          *FUNCTION-TABLE*
          *GENERIC-FUNCTIONS*
          *GRID-FUNCTIONS*
          *HARDWARE-PROFILE-SCHEMA*
          *HARDWARE-PROFILES*
          *IMPLICIT-ARG-MAP*
          *IMPLICIT-SCRATCH-SIZE-EXPR-MAP*
          *IN-DISPATCH-CONTEXT*
          *IN-DIVERGENT-CONDITIONAL*
          *IN-GRID-LEVEL-CONTEXT*
          *IN-WARP-SPEC-BLOCK*
          *IN-WORKGROUP-LEVEL-CONTEXT*
          *INERT-FUNCTIONS*
          *INFERRED-PARAM-UNIFORMITY*
          *INSTANTIATED-TEMPLATES*
          *IR-TARGET-ARCH*
          *KERNEL-DECLARED-SIGNATURES*
          *KERNEL-DISPATCH-DECLARATIONS*
          *KERNEL-INFERRED-TILE-SHAPES*
          *KERNEL-READONLY-TENSOR-SYMS*
          *KERNEL-REGISTER-MODE*
          *MATH-PRECISION*
          *MMA-SCRATCH-TILE-DIMS*
          *MULTICAST-CLUSTER-DIMS*
          *NATIVE-BUILTIN-MANGLED-NAMES*
          *NVPTX-TARGET-INITIALIZED*
          *ORIGINATOR-FUNCTIONS*
          *PARAMETERIZED-BRAND-NAMES*
          *PARTIAL-TEMPLATE-INSTANTIATIONS*
          *PENDING-STRUCT-DEFINITIONS*
          *PTX-REGISTER-DEMAND*
          *RECORD-DEFINITIONS*
          *RECORD-PARAM-FIELD-ADJS*
          *REGISTER-TILE-DIMS*
          *REQUESTED-HARDWARE-PROFILE*
          *RESOLVE-DEPTH*
          *RUNTIME-CHECKS-ENABLED*
          *SCAN-CALLEES*
          *SCAN-IS-ORIGINATOR*
          *SCANNING-FUNCTION-NAME*
          *SCRATCH-CELL-COUNTER*
          *SCRATCH-TILE-DIMS*
          *SIDE-CHANNEL-ORIGINATORS*
          *SIGNAL-CLUSTER-EXTENT*
          *SLM-HIGH-WATER-FRACTION*
          *SPV-GRF-REGISTER-BYTES*
          *SPV-REGISTER-DEMAND*
          *STRUCT-KERNEL-PARAM-SHADOWS*
          *STRUCT-MUTATING-FUNCTIONS*
          *STRUCT-NAME-PREFIX*
          *TARGET-BACKEND*
          *TEMPLATE-ARITY-LOOKUP-FN*
          *TEMPLATE-INSTANTIATOR-FN*
          *TEMPLATE-REGISTRY*
          *TILE-VISIT-MAX-STRIP-WIDTH*
          *TMA-COPY-MULTICAST*
          *TMA-COPY-WS-LEADER*
          *TMA-DESCRIPTOR-INFO*
          *TMA-MBAR-COUNTER*
          *TMA-RESOLVED*
          *TO-UNIFORM-ALLOWED*
          *TS-GRID-BINDINGS*
          *TYPE-DERIVATION-GRAPH*
          *UNI-MEET-TABLE*
          *VJP-REGISTRY*
          *VOLATILE-VAR-READS*
          *WGMMA-ACC-DIMS*
          *WGMMA-ACC-OCCUPANCY-WARN-FRACTION*
          *WGMMA-NODE-SWIZZLE*
          +SPV-OPT-PIPELINE+
          ))

;;;; end of generated file

;;;; ============================================================================================
;;;; Folded in from overlays/crisp-compiler-overlay.lisp on 2026-08-26.
;;;; These were appended to the overlay in this order and are kept in it, because
;;;; later definitions here reference earlier ones.
;;;; ============================================================================================
;;;; ------------------------------------------------------------------------------------------
;;;; Endeavour 155 Phase C, part 4 — the LOAD-TILE expansion needs the element type too.
;;;;
;;;; %emit-per-frag-block-load explodes (load-tile SRC <register-tile> COORDS) into one
;;;; load-fragment-a/b per fragment, and sizes that expansion with %frag-mn-for-operand.  Passing
;;;; no element type there means an fp16 A-tile of (8 16) is walked at the TF32 K=8 -- two
;;;; fragments -- while Phase C part 2 minted it with exactly ONE K=16 fragment.  The second index
;;;; resolves to NIL, and the compiler reports:
;;;;
;;;;     Crisp compilation failed ... Unknown variable NIL.
;;;;
;;;; WHY NOT PUT THE ELEMENT TYPE IN THE TILE ENTRY.  That was the first instinct: the entry is
;;;; (NAME M N SYMS N-TRUE FIRST-TRUE OPERAND) and appending ELEM would be the obvious change.  But
;;;; several functions destructure that entry with fixed lambda lists, so an extra element makes
;;;; every one of them an error -- a wide, brittle change for a narrow need.
;;;;
;;;; This codebase already solved the identical problem once, in 145 P3a: *mma-scratch-tile-dims*
;;;; publishes the LET's staged-tile shapes so the accumulate expansion can see them, bound by
;;;; %explode-register-tiles and NIL elsewhere.  *REGISTER-TILE-ELEMS* is the same mechanism for
;;;; the same reason, which also means it degrades the same way: NIL outside an explosion, and a
;;;; tile that is not in the alist falls back to FLOAT -- the pre-155 behaviour.
;;;; ------------------------------------------------------------------------------------------
(defvar *register-tile-elems* nil
  "Endeavour 155: alist (SYM . ELEM) of the ELEMENT TYPE of every register tile / tile-ring bound
   by the LET currently being exploded.  %emit-per-frag-block-load reads it so a load-tile
   expansion walks the operand at ITS element type's native K (8 for a 32-bit operand, 16 for a
   16-bit one) rather than at the profile's first shape.  Bound by %explode-register-tiles; NIL
   elsewhere, in which case FLOAT is assumed — exactly the pre-155 behaviour.")

;;;; ============================================================================
;;;; Endeavour 155 Step 2 — WARP-SLICED OPERAND TILES.
;;;;
;;;; The blocker measured in Phase L: Crisp allocates the FULL workgroup-tile operands in EVERY
;;;; subgroup's registers, so the per-subgroup footprint scales with the WORKGROUP tile instead of
;;;; the subgroup's slice:
;;;;
;;;;     32x64  nw=1     6KB   no spill
;;;;     128x128 nw=8   16KB   spilled 220
;;;;     256x256 nw=32  32KB   spilled 508
;;;;
;;;; SYCL-TLA holds a 256x256 tile at 6KB per subgroup -- the same as our SMALLEST config -- because
;;;; subgroup (wm, wn) of its 8x4 grid loads only A[its 32 rows] and B[its 64 columns].
;;;;
;;;; THE SLICE DIVIDES DIFFERENTLY PER OPERAND, which is the thing to get right:
;;;;     A : warps in the same grid ROW need the SAME rows      -> gm distinct slices
;;;;     B : warps in the same grid COLUMN need the same cols   -> gn distinct slices
;;;;     C : every warp is distinct                             -> n-true slices
;;;;
;;;; THE COUPLING.  An operand tile's slice depends on the ACCUMULATOR's fragment grid, which the
;;;; operand binding cannot see on its own (A knows its row count -- which equals C's m-frags, both
;;;; being TM/8 -- but not C's n-frags).  %explode-register-tiles processes every binding of one LET
;;;; together, so it can compute the grid from the accumulator in a first pass and slice the
;;;; operands in a second.  *WARP-GRID* publishes it to the walk and the load emitter, exactly as
;;;; *mma-scratch-tile-dims* publishes staged-tile shapes (145 P3a).
;;;;
;;;; GUARDED: nothing changes unless an operand tile carries :warps.  Existing kernels are
;;;; untouched by construction.
;;;; ============================================================================
(defvar *warp-grid* nil
  "Endeavour 155: (GM . GN) warp grid of the LET currently being exploded, derived from its
   accumulator register-tile's fragment grid and warp count, or NIL when there is no distributed
   accumulator.  Read by the operand-slicing paths so A/B, C and the loads all agree on which warp
   owns what.  Bound by %explode-register-tiles; NIL elsewhere, in which case operands are
   allocated whole -- the pre-Step-2 behaviour.")

;;;; ============================================================================
;;;; Endeavour 155 Step 4 — BASE-PLUS-DELTA TILE ADDRESSING.
;;;;
;;;; THE MEASUREMENT.  ISA opcode histogram for a Crisp 256x256 bf16 matmul (IGC, Arc B580):
;;;;
;;;;     mov 727    mul 311    macl 224    mach 75    dpas 16
;;;;
;;;; `mach`/`macl` are the halves of an EMULATED 64-bit multiply -- Xe has no native one -- and the
;;;; kernel issues hundreds of them to address SIXTEEN dpas.  Every fragment of every tile recomputes
;;;; its whole flat offset from scratch, and both multiplies have a RUNTIME stride as an operand.
;;;;
;;;; THE STRUCTURE THAT WAS BEING THROWN AWAY.  %emit-per-frag-block-load emits each fragment's
;;;; coordinate as (+ (* (to-int gy) n-rows) ri) -- a per-tile base plus a COMPILE-TIME fragment
;;;; index -- and codegen then multiplies by the fragment extent and by the stride:
;;;;
;;;;     off0 = ((base + ri) * dim) * s0        <- s0 runtime, so emulated, once PER FRAGMENT
;;;;
;;;; but that distributes:
;;;;
;;;;     off0 = (base * dim) * s0  +  (ri * dim) * s0
;;;;            ^^^^^^^^^^^^^^^^^     ^^^^^^^^^^^^^^^
;;;;            identical for every    constant x stride: IGC strength-reduces this to
;;;;            fragment -> CSE'd      shifts and adds, with no mach/macl at all
;;;;
;;;; so the emulated multiplies fall from two per FRAGMENT to two per TILE.
;;;;
;;;; WHY LLVM WILL NOT DO THIS ITSELF.  Distributing a multiply over an add is normally a
;;;; PESSIMISATION -- it turns one multiply into two.  It pays here only because the first term is
;;;; shared across every fragment of the tile, which is not visible at the point where reassociate
;;;; runs.  Doing it at emission is not a workaround for a missed optimisation; emission is the only
;;;; place the sharing is known.
;;;;
;;;; WHY NOT SIMPLY NARROW TO 32-BIT.  That makes each multiply native rather than emulated, and it
;;;; is correct for realistic sizes -- but an element offset at N=65536 is 4.3e9, which wraps
;;;; SILENTLY in uint32.  This endeavour has produced enough silent-wrongness traps already.
;;;; Hoisting is correct at every size and REMOVES the multiplies rather than cheapening them.
;;;;
;;;; Pinned by tests/spec/155-typed-mma-shapes/04-tile-address-arithmetic.crisp.
;;;; ============================================================================
(defconstant +llvm-opcode-add+ 8 "LLVMOpcode enum value for the integer Add instruction.")

(defconstant +llvm-opcode-mul+ 12 "LLVMOpcode enum value for the integer Mul instruction.")

(defconstant +llvm-opcode-sext+ 32 "LLVMOpcode enum value for the SExt cast instruction.")

;;;; ============================================================================
;;;; Endeavour 156 Phase 0 — PIN THE SUBGROUP SIZE.
;;;;
;;;; THE HOLE.  Crisp computes a workgroup's warp count as local-size / :simd-width
;;;; (%resolve-workgroup-warp-count, src/mma.lisp), and every :warps mask, warp-id reference and
;;;; per-warp switch arm is built on that number.  But the generated SPIR-V requests NO subgroup
;;;; size: before this change the only OpExecutionMode in a Crisp kernel was 4459 (DenormPreserve).
;;;;
;;;; Unlike CUDA, where a warp is 32 by hardware definition, an Intel subgroup is one hardware
;;;; thread executing the kernel at its COMPILED SIMD width, and IGC chooses that width per kernel
;;;; from {8, 16, 32}.  BMG's subGroupSizes advertises both 16 and 32.  So Crisp was assuming 16
;;;; while IGC decided independently -- and they agree today only by luck of a heuristic.  Verified
;;;; 2026-08-24: both the shipped 16-work-item kernel and the 512-work-item 32-subgroup probe dump
;;;; as ..._simd16_entry_0001.asm, which is the right answer arrived at by the wrong route.
;;;;
;;;; If IGC ever picks SIMD32, a 32-entry :warps mask describes SIXTEEN actual subgroups, every
;;;; switch arm selects the wrong slice, and the kernel is silently wrong.  Endeavour 156 is about
;;;; to make kernels much larger, which is exactly the input that moves IGC's heuristic.
;;;;
;;;; SIMD16 is also the width XMX/DPAS wants on Xe2, so pinning it is not a tradeoff -- it closes a
;;;; hole and asks for the width the matrix engines want anyway.
;;;;
;;;; WHY THE GUARD IS NARROW.  A required subgroup size is a CONTRACT: a workgroup smaller than the
;;;; subgroup, or not a whole multiple of it, is at best a partial subgroup and at worst a compile
;;;; error in the driver.  1028 shipped specs run through this path, many with tiny or
;;;; runtime-derived local sizes.  So the mode is emitted only when all four hold:
;;;;
;;;;     - a hardware profile is active and names a :simd-width
;;;;     - the kernel's local-size is COMPILE-TIME known
;;;;     - total work-items >= the simd width
;;;;     - total work-items is a whole multiple of it
;;;;
;;;; Any kernel failing those emits exactly what it did before.  That deliberately leaves the
;;;; profile-less case unpinned -- %resolve-workgroup-warp-count defaults warp-size to 32 there,
;;;; which is a separate inconsistency and not Phase 0's to fix.
;;;; ============================================================================
(defconstant +spirv-execution-mode-subgroup-size+ 35
  "SPIR-V ExecutionMode SubgroupSize.  Takes one literal operand: the required size.")

;;;; ============================================================================
;;;; Endeavour 156 — MMA LOWERING SELECTION.
;;;;
;;;; Measured across 155 + 156: the Crisp/SYCL-TLA gap on BMG is a LOWERING gap, not a tuning gap.
;;;; Every geometry the levers can express lands in the same 40-60 TFLOPS band (32x64 single-subgroup
;;;; 60.8, 256x256 over 32 subgroups 34.6, SLM staging 0.9), and the peer is INDIFFERENT to register
;;;; budget -- forced from grf_count 128 with 3904 bytes of spill to 256 with none, it went 185 ->
;;;; 190 TFLOPS at 4096.  Occupancy is not its secret.
;;;;
;;;; What it does instead is not expressible in kernel source: no cooperative-matrix operations at
;;;; all (11 AsmCallINTEL -- hand-written Xe assembly DPAS), the createBlock2DAddressPayload +
;;;; setBlockX/setBlockY load convention, and SPV_INTEL_split_barrier.  Those are codegen choices,
;;;; so Crisp needs a way to NAME a lowering.  This is that surface.
;;;;
;;;; THE RULE THAT MATTERS: REFUSAL, NEVER FALLBACK.  Both endeavours were derailed by silent
;;;; no-ops -- :warps did nothing at all on ring tiles for months, and (intern "MOD" :crisp-language)
;;;; minted a meaningless symbol.  A lowering that quietly downgraded to the portable path would be
;;;; the same failure in better clothes: a slow kernel and no explanation.  Asking for a lowering the
;;;; active profile does not offer is a compile-time error naming both sides.
;;;; ============================================================================
(defparameter *known-mma-lowerings* (list :coop-matrix :xe-native)
  "Every MMA lowering NAME the compiler understands, whether or not a given backend implements it.

   :coop-matrix  SPV_KHR_cooperative_matrix / the portable path.  Implemented; the default.
   :xe-native    Intel Xe: inline-assembly DPAS + the Block2D address-payload load convention.
                 NAMED but NOT YET IMPLEMENTED -- no profile lists it, so requesting it is refused
                 with the profile's actual offering.  It is named here so the value type validates
                 and so the intent is documented in one place.

   A profile's :mma-lowerings is checked against this list, which turns a typo into an error at
   def-hardware-profile time rather than a kernel that silently never selects its lowering.")

;;;; ============================================================================
;;;; Endeavour 156 Step 1 — THE MMA LOWERING BECOMES A PROTOCOL.
;;;;
;;;; Crisp has always had exactly one way to drive a matrix engine: cooperative-matrix types, a
;;;; cooperative-matrix multiply, pointer-form loads.  That choice was never named -- it was simply
;;;; what five functions happened to do.  155 and 156 established by measurement that this choice,
;;;; and not the kernel-source geometry, is what separates Crisp from SYCL-TLA on BMG: every
;;;; geometry the levers can express lands in the same 40-60 TFLOPS band, and the peer is
;;;; indifferent to register budget (forced 128 -> 256 GRF it went 185 -> 190 TFLOPS).
;;;;
;;;; So the choice gets a name and a dispatch point.  Each choke point below becomes a generic
;;;; function on the lowering, with the existing implementation moved VERBATIM into an
;;;; (eql :coop-matrix) method.  The public name keeps its signature and becomes a thin dispatcher,
;;;; so no call site changes -- call-site churn across six functions is how this overlay reached
;;;; 4700 lines the first time.  Adding :xe-native later is adding methods, not editing conditionals.
;;;;
;;;; BEHAVIOUR IS UNCHANGED BY CONSTRUCTION: one method per generic, bodies moved verbatim, and
;;;; *mma-lowering* can only ever hold :coop-matrix today because that is the only lowering any
;;;; profile offers and asking for another is refused at analysis time.
;;;; ============================================================================
(defvar *mma-lowering* :coop-matrix
  "The MMA lowering in force while generating the current kernel's IR.

   Bound per kernel by GENERATE-LLVM-IR from that kernel's (mma-lowering ...) declaration, which
   the analyzer has already validated against the active hardware profile.  Defaults to
   :coop-matrix so any code path reached outside a kernel -- and every existing kernel, which
   declares nothing -- behaves exactly as before.")

;;;; ============================================================================
;;;; Endeavour 156 Step 2 — :XE-NATIVE, part 1: fragment type, fill, and the multiply.
;;;;
;;;; THE INSTRUCTION, established from SYCL-TLA's own headers and verified through our toolchain:
;;;;
;;;;   __spirv_SubgroupMatrixMultiplyAccumulateINTEL(K, A, B, C, Operands) -> D
;;;;
;;;; for the (8 16 16) shape Crisp already uses on BMG -- M=8, N=16 (the subgroup width), K=16:
;;;;
;;;;   K         i32, an <id> (a constant), 16 for both bf16 and fp16
;;;;   A         <8 x i16>     bf16 AND fp16 both travel as raw 16-bit lanes
;;;;   B         <8 x i32>     16 elements per lane, packed two per i32
;;;;   C / D     <8 x float>   f32 accumulator
;;;;   Operands  i32 LITERAL   bf16 0x3000, fp16 0xC00
;;;;
;;;; Verified emission (put_temp_files_here/tune/madprobe2.spt):
;;;;   2 Capability SubgroupMatrixMultiplyAccumulateINTEL
;;;;   8 SubgroupMatrixMultiplyAccumulateINTEL 33 51 50 27 32 37 12288
;;;; -- a real SPIR-V INSTRUCTION with zero imports, and the translator declares the capability
;;;; itself.  That is why this is the target rather than the OpenCL-style
;;;; intel_sub_group_bf16_bf16_matrix_mad_k16, which arrives as a SYCL-vec-mangled Import symbol.
;;;; SYCL-TLA's own header says it: "Use the spirv functions as the builtins do not work."
;;;;
;;;; THE PER-LANE SHAPE.  A cooperative matrix is opaque; an :xe-native fragment is a CONCRETE
;;;; vector, and every lane holds rows*cols/subgroup-width elements of it.  B's are 16-bit but the
;;;; instruction wants them packed two-per-i32, which is the one place the arithmetic differs.
;;;;
;;;; WHAT IS DELIBERATELY REFUSED HERE rather than guessed:
;;;;   - element types other than bf16/half (K would not be 16, and the operand mask is unknown)
;;;;   - a non-zero fragment init (the splat would have to know the lane encoding)
;;;;   - a subgroup width other than 16
;;;; Each of those is a silent-wrongness risk, and 145 established that a load/store round-trip
;;;; CANNOT detect a wrong fragment layout -- it round-trips cleanly and computes garbage.
;;;; ============================================================================
(defconstant +xe-native-operands-bf16+ #x3000
  "MatrixABf16 | MatrixBBf16 for SubgroupMatrixMultiplyAccumulateINTEL.")

(defconstant +xe-native-operands-fp16+ #xC00
  "MatrixAFp16 | MatrixBFp16 for SubgroupMatrixMultiplyAccumulateINTEL.")

;;;; ============================================================================
;;;; Endeavour 156 Step 2 — recovering the OPERAND element type at the multiply.
;;;;
;;;; The multiply needs to know whether A and B are bf16 or fp16: both reach
;;;; SubgroupMatrixMultiplyAccumulateINTEL as <8 x i16>, and only the operand mask distinguishes
;;;; them (0x3000 vs 0xC00).  Get it wrong and the kernel runs and is wrong.
;;;;
;;;; But the MMA emission site cannot tell us.  src/mma.lisp:654 passes (llvm-float-type)
;;;; UNCONDITIONALLY -- the accumulator's type, not the operands' -- and the :coop-matrix method
;;;; never noticed, because it recovers everything from the VALUES it is handed and a
;;;; cooperative-matrix type still names its component.  A concrete <8 x i16> vector does not.
;;;;
;;;; So the fragment-type constructor records what it built.  %coop-type-impl is called for A and B
;;;; with the true element type before any multiply is emitted, which makes it the earliest place
;;;; the answer is known.  It is bound per kernel, so it cannot leak between kernels.
;;;;
;;;; A kernel whose A and B operands disagree is REFUSED rather than resolved by picking one: the
;;;; mask names both operands at once, so there would be no correct value to choose.  No kernel does
;;;; this today -- a-mat and b-mat share an element type in every one.
;;;; ============================================================================
(defvar *xe-native-operand-elem* nil
  "The element kind (:bf16 / :fp16) of the A/B fragments built so far in this kernel, or NIL.

   Recorded by %coop-type-impl for :xe-native and read by %coop-mma-impl, which cannot recover it
   from its own arguments -- see the header above.  Bound per kernel by GENERATE-LLVM-IR.")

;;;; Endeavour 157 Phase 2 — split-barrier pairing analysis.
(defvar *split-barrier-depth* nil
  "How many split-barrier windows are open in the kernel currently being analysed, or NIL outside
   one.  Bound per kernel by INTERNAL-DEF-FUNCTION and stepped by %ANALYZE-GPU-BUILTIN.

   A counter rather than a flag so that nesting is DETECTED rather than silently tolerated: the
   second :arrive sees a non-zero depth and refuses.")
