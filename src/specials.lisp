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
