# Application Call Graph

This graph shows the hierarchy of internal function calls.
Entries without a package name are in :CRISP.COMPILER.
Nodes marked `[RECURSION]` indicate a cycle.
Nodes marked `[See above]` have been expanded previously in the document.

## Roots (Entry Points & Unused Functions)
- (MAIN) :CRISP.MAIN  main.lisp
- - (GENERATE-CUDA-LAUNCHER METACRISP-PATH)  hoist-cuda/main.lisp
- - - (EMIT-PREAMBLE STREAM METACRISP-PATH KERNEL-NAME OUTPUT-NAME)  hoist-cuda/main.lisp
- - - (EMIT-INCLUDES STREAM)  hoist-cuda/main.lisp
- - - (EMIT-TYPEDEFS STREAM ALIASES)  hoist-cuda/main.lisp
- - - (EMIT-CUDA-DVEC-OSTREAM-OPERATORS STREAM DVEC-TYPES)  hoist-cuda/main.lisp
- - - (EMIT-STRUCTS STREAM STRUCTS)  hoist-cuda/main.lisp
- - - - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp
- - - - (%ARRAY-ELEMENT-TYPE TYPE)  hoist-cuda/main.lisp
- - - - (%ARRAY-SIZE TYPE)  hoist-cuda/main.lisp
- - - (EMIT-HELPERS STREAM)  hoist-cuda/main.lisp
- - - (EMIT-MAIN STREAM KERNEL-NAME PTX-PATH DECLARED-SIG ALIASES RECORDS &OPTIONAL DISPATCH-INFO COMPUTE-UNITS)  hoist-cuda/main.lisp
- - - - (EMIT-CUDA-INIT STREAM)  hoist-cuda/main.lisp
- - - - (EMIT-MODULE-LOADING STREAM PTX-PATH)  hoist-cuda/main.lisp
- - - - (EMIT-KERNEL-ARGS STREAM DECLARED-SIG ALIASES RECORDS DISPATCH-INFO)  hoist-cuda/main.lisp
- - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp
- - - - - (%CUDA-EMIT-CELL-ARG STREAM PARAM PARAM-NAME PARAM-TYPE PARAM-DIR IS-LOCAL ALIASES ARG-INDEX)  hoist-cuda/main.lisp
- - - - - - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - (%ARRAY-ELEMENT-TYPE TYPE)  hoist-cuda/main.lisp [See above]
- - - - - - (%ARRAY-SIZE TYPE)  hoist-cuda/main.lisp [See above]
- - - - - (TENSOR-TYPE-P PARAM-TYPE)  hoist-cuda/main.lisp
- - - - - (%CUDA-EMIT-LOCAL-SCRATCH-TENSOR-ARG STREAM PARAM PARAM-NAME PARAM-TYPE ARG-INDEX)  hoist-cuda/main.lisp
- - - - - - (%TENSOR-COMPACT-EXTENTS-STRIDES N EXTENTS-LIST)  hoist-cuda/main.lisp
- - - - - - (%CUDA-SCRATCH-DIMS SIZE-EXPR RANK PARAM-NAME)  hoist-cuda/main.lisp
- - - - - (%CUDA-EMIT-GLOBAL-SCRATCH-TENSOR-ARG STREAM PARAM PARAM-NAME PARAM-TYPE ARG-INDEX)  hoist-cuda/main.lisp
- - - - - - (%TENSOR-COMPACT-EXTENTS-STRIDES N EXTENTS-LIST)  hoist-cuda/main.lisp [See above]
- - - - - - (%CUDA-SCRATCH-DIMS SIZE-EXPR RANK PARAM-NAME)  hoist-cuda/main.lisp [See above]
- - - - - (%CUDA-EMIT-TENSOR-ARG STREAM PARAM PARAM-NAME PARAM-TYPE PARAM-DIR ARG-INDEX DISPATCH-INFO)  hoist-cuda/main.lisp
- - - - - - (%TENSOR-COMPACT-EXTENTS-STRIDES N EXTENTS-LIST)  hoist-cuda/main.lisp [See above]
- - - - - (STRUCT-TYPE-P TYPE)  hoist-cuda/main.lisp
- - - - - - (%FIND-STRUCT-DEF STRUCTS-SECTION NAME)  metadata-val.lisp
- - - - - (%CUDA-EMIT-STRUCT-ARG STREAM PARAM-NAME PARAM-TYPE ALIASES ARG-INDEX)  hoist-cuda/main.lisp
- - - - - - (%STRUCT-BASE-TYPE PARAM-TYPE)  hoist-cuda/main.lisp
- - - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - (%FIND-STRUCT-DEF STRUCTS-SECTION NAME)  metadata-val.lisp [See above]
- - - - - - (%STRUCT-EMIT-FIELDS STREAM VAR-PATH MEMBERS ALIASES)  hoist-cuda/main.lisp
- - - - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - (%ARRAY-ELEMENT-TYPE TYPE)  hoist-cuda/main.lisp [See above]
- - - - - - - (%ARRAY-SIZE TYPE)  hoist-cuda/main.lisp [See above]
- - - - - - - (STRUCT-TYPE-P TYPE)  hoist-cuda/main.lisp [See above]
- - - - - - - (%FIND-STRUCT-DEF STRUCTS-SECTION NAME)  metadata-val.lisp [See above]
- - - - - - - (%STRUCT-EMIT-FIELDS STREAM VAR-PATH MEMBERS ALIASES)  hoist-cuda/main.lisp [RECURSION]
- - - - - (RECORD-TYPE-P TYPE RECORDS)  hoist-cuda/main.lisp
- - - - - - (FIND-RECORD-DEF TYPE RECORDS)  hoist-cuda/main.lisp
- - - - - - - (RECORD-BASE-TYPE TYPE)  hoist-cuda/main.lisp
- - - - - (%CUDA-EMIT-RECORD-ARG STREAM PARAM-NAME PARAM-TYPE RECORDS ALIASES ARG-INDEX)  hoist-cuda/main.lisp
- - - - - - (RECORD-BASE-TYPE TYPE)  hoist-cuda/main.lisp [See above]
- - - - - - (FIND-RECORD-DEF TYPE RECORDS)  hoist-cuda/main.lisp [See above]
- - - - - - (%RECORD-FIELD-ARGS STREAM MEMBERS VAR-PATH ARG-INDEX RECORDS ALIASES)  hoist-cuda/main.lisp
- - - - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - (%ARRAY-ELEMENT-TYPE TYPE)  hoist-cuda/main.lisp [See above]
- - - - - - - (%ARRAY-SIZE TYPE)  hoist-cuda/main.lisp [See above]
- - - - - - - (RECORD-TYPE-P TYPE RECORDS)  hoist-cuda/main.lisp [See above]
- - - - - - - (FIND-RECORD-DEF TYPE RECORDS)  hoist-cuda/main.lisp [See above]
- - - - - - - (%RECORD-FIELD-ARGS STREAM MEMBERS VAR-PATH ARG-INDEX RECORDS ALIASES)  hoist-cuda/main.lisp [RECURSION]
- - - - - (%CUDA-EMIT-SCALAR-ARG STREAM PARAM-NAME PARAM-TYPE ARG-INDEX)  hoist-cuda/main.lisp
- - - - (COMPUTE-TOTAL-SHARED-BYTES DECLARED-SIG ALIASES)  hoist-cuda/main.lisp
- - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - - - (TENSOR-TYPE-P PARAM-TYPE)  hoist-cuda/main.lisp [See above]
- - - - - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - (%ARRAY-SIZE TYPE)  hoist-cuda/main.lisp [See above]
- - - - (EMIT-LAUNCH STREAM DISPATCH-INFO SHARED-BYTES &OPTIONAL COMPUTE-UNITS)  hoist-cuda/main.lisp
- - - - - (%DERIVE-FROM-IS-TENSOR-P RAW)  hoist-cuda/main.lisp
- - - - - (%NORMALIZE-DERIVE-FROM RAW)  hoist-cuda/main.lisp
- - - - - (%TENSOR-LENGTH-CPP-VAR SYM)  hoist-cuda/main.lisp
- - - - - (%DISPATCH-SYM-TO-CPP-VAR SYM)  hoist-cuda/main.lisp
- - - - (EMIT-READBACK STREAM ALLOCATIONS)  hoist-cuda/main.lisp
- - (PARSE-CLI-ARGS ARGS) :CRISP.MAIN  main.lisp
- - - (INITIALIZE-COMPILER &KEY (LOG-LEVEL OFF) (RUNTIME-CHECKS NIL) (DIFFERENTIATE
                                                                      NIL) (MATH-PRECISION
                                                                            IEEE) (FORCE-MATH-PRECISION
                                                                                   NIL) (DENORMAL-HANDLING
                                                                                         PRESERVE) (HARDWARE-PROFILE
                                                                                                    NIL))  compiler.lisp
- - - - (INITIALIZE-CRISP-TYPES)  types/registry.lisp
- - - - (INITIALIZE-TYPE-HIERARCHY)  types/hierarchy.lisp
- - - - (INITIALIZE-EXPRESSION-ANALYZERS)  analysis/core.lisp
- - - - - (REGISTER-OPS-ANALYZERS)  analysis/ops.lisp
- - - - - - (DEF-EXPRESSION-ANALYZER OPERATOR HANDLER-FN)  types/registry.lisp
- - - - - (REGISTER-CONTROL-ANALYZERS)  analysis/control.lisp
- - - - - - (DEF-EXPRESSION-ANALYZER OPERATOR HANDLER-FN)  types/registry.lisp [See above]
- - - - - - (REGISTER-WARP-BUILTINS)  analysis/core.lisp
- - - - - - - (%ANALYZE-GPU-BUILTIN BUILTIN-KW NAME-STR EXPR ENV CONTEXT LOCATION)  analysis/core.lisp
- - - - - - - - (%TLC-CHECK-NOT-DIVERGENT OP-NAME LOCATION)  analysis/control.lisp
- - - - - - - - (%GPU-BUILTIN-INFO BUILTIN-KW)  analysis/core.lisp
- - - - - (REGISTER-STRUCT-ANALYZERS)  analysis/structs.lisp
- - - - - - (DEF-EXPRESSION-ANALYZER OPERATOR HANDLER-FN)  types/registry.lisp [See above]
- - - - - (REGISTER-MMA-ANALYZERS)  mma.lisp
- - - - - (%ANALYZE-GPU-BUILTIN BUILTIN-KW NAME-STR EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - - - (INITIALIZE-ADVISEMENTS) :CRISP.UTILS  utils.lisp
- - - - - (ADVISE-FUNCTION FN-SYMBOL) :CRISP.UTILS  utils.lisp
- - - - (REGISTER-BUILTINS)  compiler.lisp
- - - - - (REGISTER-TEMPLATE NAME PARAMS CONSTRAINTS BODY SIGNATURE)  templates.lisp
- - - - (REGISTER-MMA-TYPES)  mma.lisp
- - - - - (REGISTER-STRUCT-DEFINITION NAME MEMBERS &OPTIONAL (CATEGORY STRUCT))  structs.lisp
- - - - - - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp
- - - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [RECURSION]
- - - - - - (COMPUTE-RECORD-LAYOUT MEMBERS)  structs.lisp
- - - - - - - (GET-NATIVE-SIZE TYPE-SPEC)  structs.lisp
- - - - - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - (GET-TYPE-BASE TYPE-NAME)  types/hierarchy.lisp
- - - - - - - - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - (GET-NATIVE-SIZE TYPE-SPEC)  structs.lisp [RECURSION]
- - - - - - - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp
- - - - - - - - - (VALID-BASIC-TYPE-P TYPE-SPEC)  types/validation.lisp
- - - - - - - - - (VALID-FUNCTION-TYPE-P TYPE-SPEC)  types/validation.lisp
- - - - - - - - - (VALID-PARAMETERIZED-TYPE-P TYPE-SPEC)  types/validation.lisp
- - - - - - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp
- - - - - - - - - - - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - (EXPAND-STORAGE-HANDLE-TYPE-SPECIFIER SPEC)  types/validation.lisp
- - - - - - - - - - - - (%EXPAND-VECTOR-TYPE-SPECIFIER ELEMENT-TYPE REST-ARGS SPEC)  types/validation.lisp
- - - - - - - - - - - - - (%BARE-STORAGE-HANDLE-VALUE-ERROR ITEM SPEC)  types/validation.lisp
- - - - - - - - - - - - (%EXPAND-MATRIX-TYPE-SPECIFIER ELEMENT-TYPE REST-ARGS SPEC)  types/validation.lisp
- - - - - - - - - - - - - (%BARE-STORAGE-HANDLE-VALUE-ERROR ITEM SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - (%EXPAND-TENSOR-TYPE-SPECIFIER BASE ELEMENT-TYPE REST-ARGS SPEC)  types/validation.lisp
- - - - - - - - - - - - (%EXPAND-CELL-TYPE-SPECIFIER BASE ELEMENT-TYPE REST-ARGS SPEC)  types/validation.lisp
- - - - - - - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [RECURSION]
- - - - - - - - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - (EXTRACT-POSITIONAL-FROM-KEYWORD-ARGS ARGS NUM-PARAMS)  types/validation.lisp
- - - - - - - - - - - (VALIDATE-TEMPLATE-ARG ARG TYPE NAME)  types/validation.lisp
- - - - - - - - - - (EXCLUDED-TEMPLATE-BASE-TYPE-P BASE-TYPE)  types/validation.lisp
- - - - - - - - - - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - (VALID-BASIC-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - (%VALIDATE-TEMPLATE-INSTANTIATION BASE-TYPE TEMPLATE-ARGS)  types/validation.lisp
- - - - - - - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - - - - - - - - (%INSTANTIATE-TEMPLATE-IF-NEEDED BASE-TYPE TEMPLATE-ARGS MANGLED-NAME)  types/validation.lisp
- - - - - - - - - - - - (COMPILE-TOPLEVEL-FORM FORM LOCATION MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)  analysis/core.lisp
- - - - - - - - - - - - - (VISIT-TOPLEVEL-FORM FORM LOCATION VISITOR-FN)  analysis/core.lisp
- - - - - - - - - - - - - - (%PROCESS-DECLAIM FORM)  analysis/core.lisp
- - - - - - - - - - - - - - (VISIT-TOPLEVEL-FORM FORM LOCATION VISITOR-FN)  analysis/core.lisp [RECURSION]
- - - - - - - - - - - - - (COMPILE-DEF-FUNCTION FORM LOCATION MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)  analysis/core.lisp
- - - - - - - - - - - - - - (REGISTER-FUNCTION-SIGNATURE FORM LOCATION)  environment.lisp
- - - - - - - - - - - - - - - (PARSE-FUNCTION-DECLARATIONS PARAMS DECLARATIONS)  environment.lisp
- - - - - - - - - - - - - - - - (ANALYZE-RETURN-TYPE-FROM-SPEC FN-SPEC)  environment.lisp
- - - - - - - - - - - - - - - - - (PARSE-TYPE-SPECIFIER SPEC)  environment.lisp
- - - - - - - - - - - - - - - - - - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - (PARSE-TYPE-SPECIFIER SPEC)  environment.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - (IS-BRAND-TYPE-P TYPE-NAME)  types/brand.lisp
- - - - - - - - - - - - - - - - - - - (IS-BRAND-TYPE-P TYPE-NAME)  types/brand.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - (BRAND-ACTIVE-P BRAND-DEF)  types/brand.lisp
- - - - - - - - - - - - - - - - - - (EXPAND-STORAGE-HANDLE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - - - - - - - - - - - - - - - (VALID-FUNCTION-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - (GET-TEMPLATE-ARITY NAME)  types/validation.lisp
- - - - - - - - - - - - - - - - - - (EXTRACT-POSITIONAL-FROM-KEYWORD-ARGS ARGS NUM-PARAMS)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - (ANALYZE-RETURN-TYPE-FROM-LIST DECLARATIONS)  environment.lisp
- - - - - - - - - - - - - - - - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [RECURSION]
- - - - - - - - - - - - - - - - (ANALYZE-ENVIRONMENT-FROM-SPEC PARAMS FN-SPEC)  environment.lisp
- - - - - - - - - - - - - - - - - (PARSE-TYPE-SPECIFIER SPEC)  environment.lisp [See above]
- - - - - - - - - - - - - - - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [RECURSION]
- - - - - - - - - - - - - - - - (PARSE-TYPE-SPECIFIER SPEC)  environment.lisp [See above]
- - - - - - - - - - - - - - - - (ANALYZE-ENVIRONMENT-FROM-LIST PARAMS DECLARATIONS)  environment.lisp
- - - - - - - - - - - - - - - - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [RECURSION]
- - - - - - - - - - - - - - - - - (PARSE-TYPE-SPECIFIER SPEC)  environment.lisp [See above]
- - - - - - - - - - - - - - - - (RESOLVE-PARAMETERIZED-BRAND-IN-ENV BRAND-SPEC ENV)  types/brand.lisp
- - - - - - - - - - - - - - - - - (FIND-BRAND-FOR-OWNER BRAND-NAME OWNER-TYPE)  types/brand.lisp
- - - - - - - - - - - - - - - - - - (RESOLVE-OWNER-TYPE-TO-MANGLED TYPE-SPEC)  types/brand.lisp
- - - - - - - - - - - - - - - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - - - - - - - - - - - - (VALIDATE-DEPENDENT-BRAND-TYPES DECLARE-FORMS ENV)  types/brand.lisp
- - - - - - - - - - - - - - - - (IS-BRAND-TYPE-P TYPE-NAME)  types/brand.lisp [See above]
- - - - - - - - - - - - - - - - (FIND-BRAND-FOR-OWNER BRAND-NAME OWNER-TYPE)  types/brand.lisp [See above]
- - - - - - - - - - - - - - - (%REGISTER-GENERIC-FUNCTION NAME PARAMS ENV RETURN-TYPES DECLARE-FORMS EXTRACTED-DEFAULTS KEY-IDX BODY LOCATION)  environment.lisp
- - - - - - - - - - - - - - - (%REGISTER-STANDARD-FUNCTION NAME ENV RETURN-TYPES DECLARE-FORMS LOCATION)  environment.lisp
- - - - - - - - - - - - - - - - (%FIND-ENTRY-POINT-DECLARATION DECLARE-FORMS)  environment.lisp
- - - - - - - - - - - - - - - - (%VALIDATE-KERNEL-RETURN-TYPE RETURN-TYPES)  environment.lisp
- - - - - - - - - - - - - - (PARSE-FUNCTION-DECLARATIONS PARAMS DECLARATIONS)  environment.lisp [See above]
- - - - - - - - - - - - - - (%COMPILE-STANDARD-FUNCTION FORM LOCATION MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)  analysis/core.lisp
- - - - - - - - - - - - - - - (GENERATE-LLVM-IR SEMANTIC-FUNCTION MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)  codegen.lisp
- - - - - - - - - - - - - - - - (GENERATE-FUNCTION-PROTOTYPE SEMANTIC-FUNCTION MODULE DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)  codegen.lisp
- - - - - - - - - - - - - - - - - (CREATE-LLVM-FUNCTION-TYPE MODULE RETURN-TYPES PARAM-NODES &OPTIONAL IS-ENTRY-POINT FN-NAME)  codegen/abi.lisp
- - - - - - - - - - - - - - - - - - (GET-LLVM-RETURN-TYPE MODULE RETURN-TYPE-NAMES)  codegen/abi.lisp
- - - - - - - - - - - - - - - - - - - (CRISP-TYPE-TO-LLVM-TYPE TYPE-SPEC MODULE)  codegen/abi.lisp
- - - - - - - - - - - - - - - - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (RESOLVE-TYPE-TO-LLVM TYPE-SPEC)  types/validation.lisp
- - - - - - - - - - - - - - - - - - - - - (RESOLVE-TYPE-TO-LLVM TYPE-SPEC)  types/validation.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - - - (EXPAND-STORAGE-HANDLE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - (GET-TYPE-BASE TYPE-NAME)  types/hierarchy.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - (ENCODE-ADDRESS-SPACE AS)  types/validation.lisp
- - - - - - - - - - - - - - - - - - - - - (FIND-STRUCT-DEFINITION-BY-NAME NAME-OR-SYMBOL)  structs.lisp
- - - - - - - - - - - - - - - - - - - - - (ENSURE-STRUCT-LLVM-TYPE NAME)  structs.lisp
- - - - - - - - - - - - - - - - - - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - - (FIND-STRUCT-DEFINITION-BY-NAME NAME-OR-SYMBOL)  structs.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - - (RESOLVE-TYPE-TO-LLVM TYPE-SPEC)  types/validation.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - - - (FIND-TEMPLATE-ROBUST NAME)  types/validation.lisp
- - - - - - - - - - - - - - - - - - - - - (UNMANGLE-TEMPLATE-STRUCT-NAME SYMBOL)  mangling.lisp
- - - - - - - - - - - - - - - - - - - - - - (SPLIT-STRING STRING DELIMITER)  mangling.lisp
- - - - - - - - - - - - - - - - - - - - - - (RECONSTRUCT-TEMPLATE-ARGS TOKENS PACKAGE)  mangling.lisp
- - - - - - - - - - - - - - - - - - - - - - - (RECONSTRUCT-N-ARGS TOKENS N PACKAGE)  mangling.lisp
- - - - - - - - - - - - - - - - - - - - - - - - (RECONSTRUCT-ONE-ARG TOKENS PACKAGE)  mangling.lisp
- - - - - - - - - - - - - - - - - - - - - - - - - (RECONSTRUCT-N-ARGS TOKENS N PACKAGE)  mangling.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - - - - - - (RECONSTRUCT-N-ARGS TOKENS N PACKAGE)  mangling.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - - - - - (RECONSTRUCT-TEMPLATE-ARGS TOKENS PACKAGE)  mangling.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - (ENSURE-TEMPLATE-INSTANTIATION NAME EXPLICIT-ARG-TYPES COMPILER-CALLBACK)  templates.lisp
- - - - - - - - - - - - - - - - - - - - - - (%RESOLVE-TEMPLATE-NAME NAME)  templates.lisp
- - - - - - - - - - - - - - - - - - - - - - (TRY-INFER-TEMPLATE-TYPES NAME ARGUMENT-TYPES)  templates.lisp
- - - - - - - - - - - - - - - - - - - - - - - (%INFER-FROM-SINGLE-TEMPLATE TMPL ARGUMENT-TYPES)  templates.lisp
- - - - - - - - - - - - - - - - - - - - - - - - (%UNWRAP-FUNCTION-SIGNATURE RAW-SIG)  templates.lisp
- - - - - - - - - - - - - - - - - - - - - - - - (MATCH-TEMPLATE-ARG RAW-SIG-TYPE ARG-TYPE INFERENCE-MAP TEMPLATE-PARAMS)  templates.lisp
- - - - - - - - - - - - - - - - - - - - - - - - - (NORMALIZE-TEMPLATE-SIG-TYPE TYPE)  templates.lisp
- - - - - - - - - - - - - - - - - - - - - - - - - (MATCH-FUNCTION-SIGNATURE PATTERN-SIG CONCRETE-SIG INFERENCE-MAP TEMPLATE-PARAMS)  templates.lisp
- - - - - - - - - - - - - - - - - - - - - - - - - - (MATCH-TEMPLATE-ARG RAW-SIG-TYPE ARG-TYPE INFERENCE-MAP TEMPLATE-PARAMS)  templates.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - - - - - - - (MATCH-LIST-STRUCTURE SIG-LIST ARG-LIST INFERENCE-MAP TEMPLATE-PARAMS)  templates.lisp
- - - - - - - - - - - - - - - - - - - - - - - - - - (MATCH-TEMPLATE-ARG RAW-SIG-TYPE ARG-TYPE INFERENCE-MAP TEMPLATE-PARAMS)  templates.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - - - - - - - (UNMANGLE-TEMPLATE-STRUCT-NAME SYMBOL)  mangling.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - - - - - (STRIP-KEYWORD-LABELS TYPE-LIST TEMPLATE-PARAMS)  templates.lisp
- - - - - - - - - - - - - - - - - - - - - - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - - - - - (MATCH-TEMPLATE-ARG RAW-SIG-TYPE ARG-TYPE INFERENCE-MAP TEMPLATE-PARAMS)  templates.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - - - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - - (%SHOULD-INSTANTIATE-TEMPLATE KEY STATUS IS-COMPILING)  templates.lisp
- - - - - - - - - - - - - - - - - - - - - - (INSTANTIATE-TEMPLATE NAME-OR-TMPL CONCRETE-TYPES &OPTIONAL OVERRIDE-NAME)  templates.lisp
- - - - - - - - - - - - - - - - - - - - - - - (VALIDATE-TEMPLATE-ARG ARG TYPE NAME)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - - - (%INSTANTIATE-STRUCTURE-TEMPLATE NAME BODY SUBSTITUTIONS CONCRETE-TYPES)  templates.lisp
- - - - - - - - - - - - - - - - - - - - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - - - - (%DISPATCH-INCOMPLETE-TEMPLATE TEMPLATE-NAME ALL-ARGS)  templates.lisp
- - - - - - - - - - - - - - - - - - - - - - - (%INSTANTIATE-CALLABLE-TEMPLATE NAME BODY SUBSTITUTIONS OVERRIDE-NAME)  templates.lisp
- - - - - - - - - - - - - - - - - - - - - (COMPILE-TOPLEVEL-FORM FORM LOCATION MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)  analysis/core.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - (GET-EXPANDED-TYPES TYPE-SPEC MODULE)  codegen/abi.lisp
- - - - - - - - - - - - - - - - - - - (%RECORD-BASE-FROM-LIST-FORM TYPE-SPEC)  codegen/abi.lisp
- - - - - - - - - - - - - - - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - - - - - - - - - - - - - - - - (LOOKUP-STRUCT-DEFINITION TYPE-NAME)  structs.lisp
- - - - - - - - - - - - - - - - - - - - (GET-TYPE-BASE TYPE-NAME)  types/hierarchy.lisp [See above]
- - - - - - - - - - - - - - - - - - - (RESOLVE-TYPE-TO-LLVM TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - - (GET-EXPANDED-TYPES TYPE-SPEC MODULE)  codegen/abi.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - - (CRISP-TYPE-TO-LLVM-TYPE TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - - - - - - - - - - - - - - - - - - (IS-GLOBAL-STORAGE-HANDLE-P TYPE-SPEC)  codegen/abi.lisp
- - - - - - - - - - - - - - - - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - - (LLVM-TYPE-KIND-IS-POINTER? TY) :CRISP.LLVM-BINDINGS  llvm-bindings.lisp
- - - - - - - - - - - - - - - - - - - (ENCODE-ADDRESS-SPACE AS)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - (%VERIFY-PTX-ENTRY-EXPANDED-TYPES EXPANDED-TYPES FN-NAME)  codegen.lisp
- - - - - - - - - - - - - - - - - - - (LLVM-TYPE-KIND-IS-POINTER? TY) :CRISP.LLVM-BINDINGS  llvm-bindings.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%PTX-ENTRY-ILLEGAL-ADDRSPACE-P AS)  codegen.lisp
- - - - - - - - - - - - - - - - - (%CHECK-EXISTING-FUNCTION EXISTING FN-NAME DI-BUILDER DI-COMPILE-UNIT FUNC CRISP-RETURN-TYPE PARAM-NODES LOCATION-MAP FN-LOC MODULE FN-TYPE)  codegen.lisp
- - - - - - - - - - - - - - - - - - (GENERATE-DEBUG-INFO DI-BUILDER DI-COMPILE-UNIT FUNC FN-NAME FN-LOC RETURN-TYPE PARAM-NODES LOCATION-MAP)  codegen.lisp
- - - - - - - - - - - - - - - - - - - (GET-OR-CREATE-DI-TYPE CRISP-TYPE DI-BUILDER DI-TYPE-CACHE)  codegen.lisp
- - - - - - - - - - - - - - - - - (%CREATE-NEW-FUNCTION FN-NAME FN-TYPE MODULE DI-BUILDER DI-COMPILE-UNIT CRISP-RETURN-TYPE PARAM-NODES LOCATION-MAP FN-LOC)  codegen.lisp
- - - - - - - - - - - - - - - - - - (GENERATE-DEBUG-INFO DI-BUILDER DI-COMPILE-UNIT FUNC FN-NAME FN-LOC RETURN-TYPE PARAM-NODES LOCATION-MAP)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - (ENSURE-OPENCL-KERNEL-METADATA FUNC SEMANTIC-FUNCTION MODULE)  codegen.lisp
- - - - - - - - - - - - - - - - - (%APPLY-DENORMAL-ATTRIBUTE FUNC MODULE)  codegen.lisp
- - - - - - - - - - - - - - - - - (%EMIT-SPIRV-DENORM-EXECUTION-MODE FUNC MODULE)  codegen.lisp
- - - - - - - - - - - - - - - - (GENERATE-FUNCTION-BODY SEMANTIC-FUNCTION FUNC DI-SUBPROGRAM BUILDER MODULE DI-BUILDER LOCATION-MAP)  codegen.lisp
- - - - - - - - - - - - - - - - - (INITIALIZE-FUNCTION-PARAMETERS BUILDER FUNC PARAM-NODES MODULE VAR-ENV &OPTIONAL IS-ENTRY-POINT)  codegen.lisp
- - - - - - - - - - - - - - - - - - (GET-EXPANDED-TYPES TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - - - - - - - - - - - - - - - - - (%PTX-ENTRY-RESTORE-SHARED-PTRS-FOR-IMPLODE BUILDER COMPONENTS TYPE-SPEC MODULE IS-ENTRY-POINT)  codegen.lisp
- - - - - - - - - - - - - - - - - - - (GET-EXPANDED-TYPES TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - - - - - - - - - - - - - - - - - - (LLVM-TYPE-KIND-IS-POINTER? TY) :CRISP.LLVM-BINDINGS  llvm-bindings.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%PTX-ENTRY-ILLEGAL-ADDRSPACE-P AS)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - (IMPLODE-VALUE BUILDER COMPONENTS TYPE-SPEC MODULE)  codegen/abi.lisp
- - - - - - - - - - - - - - - - - - - (%RECORD-BASE-FROM-LIST-FORM TYPE-SPEC)  codegen/abi.lisp [See above]
- - - - - - - - - - - - - - - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - - - - - - - - - - - - - - - - (LOOKUP-STRUCT-DEFINITION TYPE-NAME)  structs.lisp [See above]
- - - - - - - - - - - - - - - - - - - (CRISP-TYPE-TO-LLVM-TYPE TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - - - - - - - - - - - - - - - - - - (IMPLODE-VALUE BUILDER COMPONENTS TYPE-SPEC MODULE)  codegen/abi.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - (GET-EXPANDED-TYPES TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - (CRISP-TYPE-TO-LLVM-TYPE TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - - - - - - - - - - - - - - - - (%COLLECT-READONLY-TENSOR-PARAM-SYMS SEMANTIC-FUNCTION)  codegen.lisp
- - - - - - - - - - - - - - - - - - (%CRISP-FLOAT-TENSOR-TYPE-P TYPE-SPEC)  autodiff.lisp
- - - - - - - - - - - - - - - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%CRISP-FLOAT-TYPE-P TYPE-SPEC)  autodiff.lisp
- - - - - - - - - - - - - - - - - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (COMPUTE-BASE-TYPE ORIGINAL-TYPE-NAME)  types/hierarchy.lisp
- - - - - - - - - - - - - - - - - - - - - (COMPUTE-BASE-TYPE ORIGINAL-TYPE-NAME)  types/hierarchy.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - (%CRISP-INTEGER-TENSOR-TYPE-P TYPE-SPEC)  autodiff.lisp
- - - - - - - - - - - - - - - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - (GENERATE-EXPRESSION-IR BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP NODE)  codegen.lisp
- - - - - - - - - - - - - - - - - - (GENERATE-NODE-IR (NODE
                                                       SEMANTIC-MMA-ACCUMULATE) BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP)  mma.lisp
- - - - - - - - - - - - - - - - - - - (GENERATE-NODE-IR (NODE
                                                         SEMANTIC-MMA-ACCUMULATE) BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP)  mma.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - (GET-LLVM-RETURN-TYPE MODULE RETURN-TYPE-NAMES)  codegen/abi.lisp [See above]
- - - - - - - - - - - - - - - - - - - (CRISP-TYPE-TO-LLVM-TYPE TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%GENERATE-KEYWORD-LITERAL-IR VALUE)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (RESOLVE-KEYWORD-CONSTANT KW)  codegen.lisp
- - - - - - - - - - - - - - - - - - - (%GENERATE-CELL-LITERAL-IR BUILDER MODULE VAR-ENV TYPE-SPEC VALUE)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (CRISP-TYPE-TO-LLVM-TYPE TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (ENSURE-STRUCT-LLVM-TYPE NAME)  structs.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%GENERATE-TENSOR-SCRATCH-LITERAL-IR BUILDER MODULE VAR-ENV TYPE-SPEC VALUE)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (ENSURE-STRUCT-LLVM-TYPE NAME)  structs.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%GENERATE-ENUM-LITERAL-IR BUILDER VALUE LLVM-TYPE)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (RESOLVE-KEYWORD-CONSTANT KW)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%GENERATE-SCALAR-LITERAL-IR BUILDER VALUE LLVM-TYPE CRISP-TYPE)  codegen.lisp
- - - - - - - - - - - - - - - - - - - (%GET-DI-LOCATION NODE MODULE DI-BUILDER DI-SCOPE LOCATION-MAP)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (SEMANTIC-NODE-SOURCE-LOCATION NODE)  analysis/core.lisp
- - - - - - - - - - - - - - - - - - - (%HANDLE-DIE-INTRINSIC BUILDER MODULE)  codegen.lisp
- - - - - - - - - - - - - - - - - - - (%BUILD-LLVM-FUNCTION-TYPE MODULE RETURN-TYPE-NAMES PARAM-TYPES)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (GET-LLVM-RETURN-TYPE MODULE RETURN-TYPE-NAMES)  codegen/abi.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (GET-EXPANDED-TYPES TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%BUILD-FUNCTION-CALL BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP NODE SIG CALLEE-NAME LLVM-FN-TYPE PARAM-NODES PARAM-COUNT RETURN-TYPE-NAMES)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (PREPARE-CALL-ARGUMENTS BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP ARG-NODES PARAM-TYPES PARAM-COUNT)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - - (GENERATE-NODE-IR (NODE
                                                             SEMANTIC-MMA-ACCUMULATE) BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP)  mma.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - - - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp
- - - - - - - - - - - - - - - - - - - - - (EXTRACT-PRIMARY-VALUE BUILDER VALUE TYPE-SPEC)  codegen/abi.lisp
- - - - - - - - - - - - - - - - - - - - - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - - - (EXPLODE-VALUE BUILDER AGG-VAL TYPE-SPEC)  codegen/abi.lisp
- - - - - - - - - - - - - - - - - - - - - - (%RECORD-BASE-FROM-LIST-FORM TYPE-SPEC)  codegen/abi.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - - (LOOKUP-STRUCT-DEFINITION TYPE-NAME)  structs.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - - (EXPLODE-VALUE BUILDER AGG-VAL TYPE-SPEC)  codegen/abi.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - - - - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (%ATTACH-DEBUG-LOC INST NODE MODULE DI-BUILDER DI-SCOPE LOCATION-MAP)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - - (%GET-DI-LOCATION NODE MODULE DI-BUILDER DI-SCOPE LOCATION-MAP)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (%PROPAGATE-CALLEE-CC-TO-CALL CALL-INST CALLEE-FN-VAL)  codegen.lisp
- - - - - - - - - - - - - - - - - - - (%GENERATE-LET-BINDING BINDING BUILDER MODULE LET-ENV DI-BUILDER DI-SCOPE LOCATION-MAP MEMOIZED-AGGREGATES)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp
- - - - - - - - - - - - - - - - - - - - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - - - (GET-TEMPLATE-ARITY NAME)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (%DVEC-TYPE-LOOKUP TYPE-SYM)  analysis/core.lisp
- - - - - - - - - - - - - - - - - - - - (GENERATE-EXPRESSION-IR BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP NODE)  codegen.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - - (CRISP-TYPE-TO-LLVM-TYPE TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - - - - - - - - - - - - - - - - - - (GENERATE-EXPRESSION-IR BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP NODE)  codegen.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - - - - - - - - - - - - - - - - - - (PREPARE-CALL-ARGUMENTS BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP ARG-NODES PARAM-TYPES PARAM-COUNT)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%ATTACH-DEBUG-LOC INST NODE MODULE DI-BUILDER DI-SCOPE LOCATION-MAP)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%PROPAGATE-CALLEE-CC-TO-CALL CALL-INST CALLEE-FN-VAL)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - (TERMINATOR-P BLOCK)  codegen.lisp
- - - - - - - - - - - - - - - - - - - (LOOKUP-STRUCT-DEFINITION TYPE-NAME)  structs.lisp [See above]
- - - - - - - - - - - - - - - - - - - (ENSURE-STRUCT-LLVM-TYPE NAME)  structs.lisp [See above]
- - - - - - - - - - - - - - - - - - - (RESOLVE-TYPE-TO-LLVM TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - - (LLVM-TYPE-KIND-IS-POINTER? TY) :CRISP.LLVM-BINDINGS  llvm-bindings.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%DVEC-TYPE-LOOKUP TYPE-SYM)  analysis/core.lisp [See above]
- - - - - - - - - - - - - - - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - - - - - - - - - - - - - - - - (EXTRACT-PRIMARY-VALUE BUILDER VALUE TYPE-SPEC)  codegen/abi.lisp [See above]
- - - - - - - - - - - - - - - - - - - (UNMANGLE-TEMPLATE-STRUCT-NAME SYMBOL)  mangling.lisp [See above]
- - - - - - - - - - - - - - - - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%TRY-INLINE-STRUCT-ARRAY-FIELD-PTR ARRAY-NODE BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (EXPAND-STORAGE-HANDLE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (LOOKUP-STRUCT-DEFINITION TYPE-NAME)  structs.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (%LOOKUP-FIELD-PHYSICAL-INDEX STRUCT-DEF FIELD-NAME-STR)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (ENSURE-STRUCT-LLVM-TYPE NAME)  structs.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (GENERATE-NODE-IR (NODE
                                                           SEMANTIC-MMA-ACCUMULATE) BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP)  mma.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - (%ARRAY-NODE-READONLY-TENSOR-PARAM-P ARRAY-NODE)  codegen.lisp
- - - - - - - - - - - - - - - - - - - (%ATTACH-INVARIANT-LOAD LOADED-INST MODULE)  codegen.lisp
- - - - - - - - - - - - - - - - - - - (%DVEC-COERCE-ELEMENT-IR ELEM-NODE COMP-TYPE COMP-LLVM-TYPE BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (GENERATE-NODE-IR (NODE
                                                           SEMANTIC-MMA-ACCUMULATE) BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP)  mma.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - (%MV-BUMP-PTR BUILDER BASE-PTR OFFSET-BYTES ADDR-SPACE)  codegen.lisp
- - - - - - - - - - - - - - - - - - - (%MV-SOURCE-ADDR CANON)  analysis/structs.lisp
- - - - - - - - - - - - - - - - - - - - (%MV-SOURCE-HEAD CANON)  analysis/structs.lisp
- - - - - - - - - - - - - - - - - - - (%MV-BUILD-STORAGE BUILDER MODULE ADDR-SPACE SRC-PARENT NEW-PTR NEW-BYTESIZE)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (CRISP-TYPE-TO-LLVM-TYPE TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%MV-BUILD-ZERO-I64-ARRAY RANK)  codegen.lisp
- - - - - - - - - - - - - - - - - - - (%MV-ROW-MAJOR-STRIDES EXTENTS)  analysis/structs.lisp
- - - - - - - - - - - - - - - - - - - (%MV-BUILD-CONST-I64-ARRAY BUILDER RANK VALUES)  codegen.lisp
- - - - - - - - - - - - - - - - - - - (%SV-TO-I64 BUILDER VAL)  codegen.lisp
- - - - - - - - - - - - - - - - - - - (%GET-BUILTIN-VEC3 BUILDER MODULE SPIRV-NAME)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (%PTX-READ-SREG-VEC3 BUILDER MODULE SREG-BASE)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - - (CRISP-TYPE-TO-LLVM-TYPE TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - (%PTX-READ-SREG-SCALAR BUILDER MODULE SREG-BASE DIM)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - - - (%SPIRV-GET-OR-CREATE-FN MODULE FN-NAME LLVM-RET-TYPE PARAM-TYPES PARAM-COUNT)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (%PTX-SYNTHESIZE-GLOBAL-ID-VEC3 BUILDER MODULE)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - - (CRISP-TYPE-TO-LLVM-TYPE TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - (%PTX-READ-SREG-SCALAR BUILDER MODULE SREG-BASE DIM)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (%PTX-SYNTHESIZE-GLOBAL-SIZE-VEC3 BUILDER MODULE)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - - (CRISP-TYPE-TO-LLVM-TYPE TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - (%PTX-READ-SREG-SCALAR BUILDER MODULE SREG-BASE DIM)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (%PTX-ZERO-VEC3 BUILDER MODULE)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - - (CRISP-TYPE-TO-LLVM-TYPE TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (%CALL-SPIRV-VEC3-BUILTIN BUILDER MODULE SPIRV-NAME)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - - (CRISP-TYPE-TO-LLVM-TYPE TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%EXTRACT-VEC3-I64 BUILDER VEC-VAL DIM NAME-SUFFIX)  codegen.lisp
- - - - - - - - - - - - - - - - - - - (%CALL-SPIRV-VEC3-BUILTIN BUILDER MODULE SPIRV-NAME)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%CALL-SPIRV-UINT-BUILTIN BUILDER MODULE SPIRV-NAME)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (%SPIRV-GET-OR-CREATE-FN MODULE FN-NAME LLVM-RET-TYPE PARAM-TYPES PARAM-COUNT)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%GEN-LOCAL-LINEAR-ID BUILDER MODULE)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (%GET-BUILTIN-VEC3 BUILDER MODULE SPIRV-NAME)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (%GEN-FLAT-LINEAR-ID-FROM-VECS BUILDER LID-VEC LWS-VEC NAME)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - - (%EXTRACT-VEC3-I64 BUILDER VEC-VAL DIM NAME-SUFFIX)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%GEN-PRODUCT-OF-VEC3 BUILDER MODULE SPIRV-NAME RESULT-NAME)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (%GET-BUILTIN-VEC3 BUILDER MODULE SPIRV-NAME)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (%EXTRACT-VEC3-I64 BUILDER VEC-VAL DIM NAME-SUFFIX)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%GEN-GLOBAL-LINEAR-ID BUILDER MODULE)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (%GET-BUILTIN-VEC3 BUILDER MODULE SPIRV-NAME)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (%GEN-FLAT-LINEAR-ID-FROM-VECS BUILDER LID-VEC LWS-VEC NAME)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (%EXTRACT-VEC3-I64 BUILDER VEC-VAL DIM NAME-SUFFIX)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%PTX-READ-WARP-SREG BUILDER MODULE SREG-NAME)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (%SPIRV-GET-OR-CREATE-FN MODULE FN-NAME LLVM-RET-TYPE PARAM-TYPES PARAM-COUNT)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%CALL-SPIRV-UINT-GLOBAL-BUILTIN BUILDER MODULE SPIRV-NAME)  codegen.lisp
- - - - - - - - - - - - - - - - - - - (%PTX-SYNTHESIZE-WARP-COUNT BUILDER MODULE)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (%SPIRV-GET-OR-CREATE-FN MODULE FN-NAME LLVM-RET-TYPE PARAM-TYPES PARAM-COUNT)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%PTX-BARRIER BUILDER MODULE)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (%SPIRV-GET-OR-CREATE-FN MODULE FN-NAME LLVM-RET-TYPE PARAM-TYPES PARAM-COUNT)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%GEN-SPIRV-CONTROL-BARRIER BUILDER MODULE)  codegen.lisp
- - - - - - - - - - - - - - - - - - - (%PTX-SYNCWARP BUILDER MODULE)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (%SPIRV-GET-OR-CREATE-FN MODULE FN-NAME LLVM-RET-TYPE PARAM-TYPES PARAM-COUNT)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%GEN-SPIRV-WARP-BARRIER BUILDER MODULE)  codegen.lisp
- - - - - - - - - - - - - - - - - - - (%PTX-MEMBAR-CTA BUILDER MODULE)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (%SPIRV-GET-OR-CREATE-FN MODULE FN-NAME LLVM-RET-TYPE PARAM-TYPES PARAM-COUNT)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%GEN-SPIRV-MEMORY-BARRIER BUILDER MODULE)  codegen.lisp
- - - - - - - - - - - - - - - - - - - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%GEN-NVVM-READ-TID-X BUILDER MODULE)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (%SPIRV-GET-OR-CREATE-FN MODULE FN-NAME LLVM-RET-TYPE PARAM-TYPES PARAM-COUNT)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%GEN-NVVM-READ-TID-Y BUILDER MODULE)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (%SPIRV-GET-OR-CREATE-FN MODULE FN-NAME LLVM-RET-TYPE PARAM-TYPES PARAM-COUNT)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%GEN-NVVM-READ-TID-Z BUILDER MODULE)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (%SPIRV-GET-OR-CREATE-FN MODULE FN-NAME LLVM-RET-TYPE PARAM-TYPES PARAM-COUNT)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%GEN-NVVM-READ-NTID-X BUILDER MODULE)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (%SPIRV-GET-OR-CREATE-FN MODULE FN-NAME LLVM-RET-TYPE PARAM-TYPES PARAM-COUNT)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%GEN-NVVM-READ-NTID-Y BUILDER MODULE)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (%SPIRV-GET-OR-CREATE-FN MODULE FN-NAME LLVM-RET-TYPE PARAM-TYPES PARAM-COUNT)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%GEN-NVVM-READ-NTID-Z BUILDER MODULE)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (%SPIRV-GET-OR-CREATE-FN MODULE FN-NAME LLVM-RET-TYPE PARAM-TYPES PARAM-COUNT)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%GEN-NVVM-MBARRIER-INIT-SHARED BUILDER MODULE MBARRIER-PTR COUNT-VAL)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (%SPIRV-GET-OR-CREATE-FN MODULE FN-NAME LLVM-RET-TYPE PARAM-TYPES PARAM-COUNT)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%VECTOR-ELEM-TYPE TILE-TYPE-SPEC)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (SPLIT-STRING STRING DELIMITER)  mangling.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%GEN-NVVM-CP-ASYNC-ELEM BUILDER MODULE DST-PTR SRC-PTR ELEM-BYTES)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (%SPIRV-GET-OR-CREATE-FN MODULE FN-NAME LLVM-RET-TYPE PARAM-TYPES PARAM-COUNT)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%GEN-NVVM-CP-ASYNC-MBARRIER-ARRIVE-NOINC-SHARED BUILDER MODULE MBARRIER-PTR)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (%SPIRV-GET-OR-CREATE-FN MODULE FN-NAME LLVM-RET-TYPE PARAM-TYPES PARAM-COUNT)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%GEN-NVVM-MBARRIER-ARRIVE-SHARED BUILDER MODULE MBARRIER-PTR)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (%SPIRV-GET-OR-CREATE-FN MODULE FN-NAME LLVM-RET-TYPE PARAM-TYPES PARAM-COUNT)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%GEN-NVVM-MBARRIER-TEST-WAIT-SHARED BUILDER MODULE MBARRIER-PTR STATE-VAL)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (%SPIRV-GET-OR-CREATE-FN MODULE FN-NAME LLVM-RET-TYPE PARAM-TYPES PARAM-COUNT)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%COOP-FILL BUILDER MODULE INIT-VAL ELEM-LLVM ROWS COLS USE)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (%COOP-CALL BUILDER MODULE NAME RET-TYPE PARAM-TYPES ARG-VALS)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (%COOP-TYPE ELEM-LLVM ROWS COLS USE)  codegen.lisp
- - - - - - - - - - - - - - - - - - - (%COOP-TENSOR-PTR+STRIDE BUILDER TENSOR-VAL OROW OCOL LAYOUT)  codegen.lisp
- - - - - - - - - - - - - - - - - - - (%COOP-LOAD BUILDER MODULE PTR STRIDE-VAL ELEM-LLVM ROWS COLS USE LAYOUT)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (%PTR-AS PTR-VAL)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (%COOP-CALL BUILDER MODULE NAME RET-TYPE PARAM-TYPES ARG-VALS)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (%COOP-TYPE ELEM-LLVM ROWS COLS USE)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (%COOP-PTR-TYPE &OPTIONAL (AS 1))  codegen.lisp
- - - - - - - - - - - - - - - - - - - (%COOP-STORE BUILDER MODULE PTR MATRIX-VAL STRIDE-VAL ELEM-LLVM ROWS COLS USE LAYOUT)  codegen.lisp
- - - - - - - - - - - - - - - - - - - - (%PTR-AS PTR-VAL)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (%COOP-CALL BUILDER MODULE NAME RET-TYPE PARAM-TYPES ARG-VALS)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (%COOP-PTR-TYPE &OPTIONAL (AS 1))  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (%COOP-TYPE ELEM-LLVM ROWS COLS USE)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%SPV-MMA-SHAPE)  mma.lisp
- - - - - - - - - - - - - - - - - - - - (ACTIVE-HARDWARE-PROFILE)  hardware-profile.lisp
- - - - - - - - - - - - - - - - - - - (%COOP-MMA BUILDER MODULE A-VAL B-VAL C-VAL ELEM-LLVM M N K)  mma.lisp
- - - - - - - - - - - - - - - - - - - - (%COOP-TYPE ELEM-LLVM ROWS COLS USE)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (%COOP-CALL BUILDER MODULE NAME RET-TYPE PARAM-TYPES ARG-VALS)  codegen.lisp [See above]
- - - - - - - - - - - - - - - - - - - (%EMIT-NVVM-MMA BUILDER MODULE A-VAL B-VAL C-VAL)  mma.lisp
- - - - - - - - - - - - - - - - - - - - (CRISP-TYPE-TO-LLVM-TYPE TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - - - - - - - - - - - - - - - - (CRISP-TYPE-TO-LLVM-TYPE TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - - - - - - - - - - - - - - - - (LLVM-TYPE-KIND-IS-POINTER? TY) :CRISP.LLVM-BINDINGS  llvm-bindings.lisp [See above]
- - - - - - - - - - - - - - (%FN-NAME-IS-GRAD-P NAME)  autodiff.lisp
- - - - - - - - - - - - - - (%GENERATE-BACKWARD-FUNCTION-AST NAME PARAMS DECLARATIONS BODY-FORMS)  autodiff.lisp
- - - - - - - - - - - - - - - (%TRIVIAL-ACCESSOR-BODY-P BODY-FORMS)  autodiff.lisp
- - - - - - - - - - - - - - - (PARSE-FUNCTION-DECLARATIONS PARAMS DECLARATIONS)  environment.lisp [See above]
- - - - - - - - - - - - - - - (%CRISP-FLOAT-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - - - - - - - - - - - - - (%COLLECT-RECORD-PARAM-INFO ENV PKG)  autodiff.lisp
- - - - - - - - - - - - - - - - (%RESOLVE-TO-BASE-TYPE-FOR-STRUCTS-OR-RECORDS PD-TYPE)  autodiff.lisp
- - - - - - - - - - - - - - - - - (COMPUTE-BASE-TYPE ORIGINAL-TYPE-NAME)  types/hierarchy.lisp [See above]
- - - - - - - - - - - - - - - - - (%CRISP-RECORD-TYPE-P TYPE-SPEC)  autodiff.lisp
- - - - - - - - - - - - - - - - - (%CRISP-STRUCT-TYPE-P TYPE-SPEC)  autodiff.lisp
- - - - - - - - - - - - - - - - (%CRISP-HANDLE-PARAM-TYPE-P PD-TYPE)  autodiff.lisp
- - - - - - - - - - - - - - - - - (%CRISP-TENSOR-PARAM-TYPE-P PD-TYPE)  autodiff.lisp
- - - - - - - - - - - - - - - - - - (%CRISP-FLOAT-TENSOR-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - - - - - - - - - - - - - - - - (%CRISP-INTEGER-TENSOR-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - - - - - - - - - - - - - - - (%CRISP-CELL-PARAM-TYPE-P PD-TYPE)  autodiff.lisp
- - - - - - - - - - - - - - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - (%CRISP-FLOAT-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - - - - - - - - - - - - - - - - (%CRISP-INTEGER-SCALAR-TYPE-P TYPE-SPEC)  autodiff.lisp
- - - - - - - - - - - - - - - - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - (%CRISP-RECORD-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - - - - - - - - - - - - - - (%CRISP-STRUCT-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - - - - - - - - - - - - - - (%GET-RECORD-RUNTIME-FIELDS REC-TYPE-SPEC)  autodiff.lisp
- - - - - - - - - - - - - - - - - (COMPUTE-BASE-TYPE ORIGINAL-TYPE-NAME)  types/hierarchy.lisp [See above]
- - - - - - - - - - - - - - - (%ACTIVE-SCALAR-PARAM-SET PARAMS BODY-FORMS)  autodiff.lisp
- - - - - - - - - - - - - - - - (%ACTIVE-SCALAR-VARS EXPR ENV)  autodiff.lisp
- - - - - - - - - - - - - - - - - (%ASV-UNION EXPRS ENV)  autodiff.lisp
- - - - - - - - - - - - - - - - - - (%ACTIVE-SCALAR-VARS EXPR ENV)  autodiff.lisp [RECURSION]
- - - - - - - - - - - - - - - - - (%ACTIVE-SCALAR-VARS EXPR ENV)  autodiff.lisp [RECURSION]
- - - - - - - - - - - - - - - (%COLLECT-ALL-DIFF-PARAM-SYMS-FOR-RETURN ENV RECORD-PARAM-INFO &OPTIONAL ACTIVE-SET)  autodiff.lisp
- - - - - - - - - - - - - - - - (%CRISP-FLOAT-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - - - - - - - - - - - - - - (%COUNT-ACTIVE-CONTRIBUTIONS PD-TYPE SYM ACTIVE-SET &OPTIONAL RECORD-INFO)  autodiff.lisp
- - - - - - - - - - - - - - - - - (%COUNT-DIFFERENTIABLE-CONTRIBUTIONS PD-TYPE &OPTIONAL RECORD-INFO)  autodiff.lisp
- - - - - - - - - - - - - - - - - - (%RESOLVE-TO-BASE-TYPE-FOR-STRUCTS-OR-RECORDS PD-TYPE)  autodiff.lisp [See above]
- - - - - - - - - - - - - - - - - - (%CRISP-HANDLE-PARAM-TYPE-P PD-TYPE)  autodiff.lisp [See above]
- - - - - - - - - - - - - - - - - - (%CRISP-RECORD-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - - - - - - - - - - - - - - - - (%CRISP-STRUCT-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - - - - - - - - - - - - - - - - (%GET-RECORD-RUNTIME-FIELDS REC-TYPE-SPEC)  autodiff.lisp [See above]
- - - - - - - - - - - - - - - - - - (%CRISP-FLOAT-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - - - - - - - - - - - - - - - (%CRISP-INTEGER-SCALAR-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - - - - - - - - - - - - - (%BUILD-RECORD-PARAM-FIELD-ADJS-HT RECORD-PARAM-INFO)  autodiff.lisp
- - - - - - - - - - - - - - - (%COUNT-ACTIVE-CONTRIBUTIONS PD-TYPE SYM ACTIVE-SET &OPTIONAL RECORD-INFO)  autodiff.lisp [See above]
- - - - - - - - - - - - - - - (%CRISP-FUNCTION-TYPE-P TYPE-SPEC)  autodiff.lisp
- - - - - - - - - - - - - - - (%HAS-TENSOR-DIFF-PARAM-P ENV)  autodiff.lisp
- - - - - - - - - - - - - - - - (%CRISP-HANDLE-PARAM-TYPE-P PD-TYPE)  autodiff.lisp [See above]
- - - - - - - - - - - - - - - (%REGISTER-HOF-DIFFERENTIABLE-FUNCTION NAME ENV FLOAT-PARAM-SYMS FN-PARAM-ENTRIES N-RETURN BODY-FORMS)  autodiff.lisp
- - - - - - - - - - - - - - - (%GENERATE-BACKWARD-COMPANION-AST-BODY NAME PARAMS ENV DECLARATIONS BODY-FORMS PKG N-FLOAT-PARAMS N-RETURN RETURN-TYPES-NON-VOID RECORD-PARAM-INFO RECORD-PARAM-FIELD-ADJS-HT ALL-DIFF-PARAM-SYMS-FOR-RETURN)  autodiff.lisp
- - - - - - - - - - - - - - - - (%PROMOTE-TO-FLOAT-ADJOINT TYPE-SPEC)  autodiff.lisp
- - - - - - - - - - - - - - - - - (%CRISP-INTEGER-TENSOR-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - - - - - - - - - - - - - - - (%INTEGER-TENSOR-ELEM-TO-FLOAT TYPE-SPEC)  autodiff.lisp
- - - - - - - - - - - - - - - - - - (%CRISP-INTEGER-TENSOR-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - - - - - - - - - - - - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - (%GET-TENSOR-CT CANON)  analysis/structs.lisp
- - - - - - - - - - - - - - - - - (%CRISP-INTEGER-CELL-TYPE-P TYPE-SPEC)  autodiff.lisp
- - - - - - - - - - - - - - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - (%CRISP-INTEGER-SCALAR-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - - - - - - - - - - - - - - - (%INTEGER-CELL-ELEM-TO-FLOAT TYPE-SPEC)  autodiff.lisp
- - - - - - - - - - - - - - - - - - (%CRISP-INTEGER-CELL-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - - - - - - - - - - - - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - (%INTEGER-SCALAR-TO-FLOAT-SCALAR TYPE-SPEC)  autodiff.lisp
- - - - - - - - - - - - - - - - - - - (%CRISP-INTEGER-SCALAR-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - - - - - - - - - - - - - - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - (%CRISP-INTEGER-SCALAR-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - - - - - - - - - - - - - - - (%INTEGER-SCALAR-TO-FLOAT-SCALAR TYPE-SPEC)  autodiff.lisp [See above]
- - - - - - - - - - - - - - - - (%AD-SCALAR-ADJOINT-TYPE TYPE-SPEC)  autodiff.lisp
- - - - - - - - - - - - - - - - - (%AD-PROMOTES-TO-DOUBLE-P TYPE-SPEC)  autodiff.lisp
- - - - - - - - - - - - - - - - - - (%PROMOTE-TO-FLOAT-ADJOINT TYPE-SPEC)  autodiff.lisp [See above]
- - - - - - - - - - - - - - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - (%COLLECT-TENSOR-PARAM-INFO ENV PKG)  autodiff.lisp
- - - - - - - - - - - - - - - - - (%CRISP-HANDLE-PARAM-TYPE-P PD-TYPE)  autodiff.lisp [See above]
- - - - - - - - - - - - - - - - - (%CRISP-INTEGER-TENSOR-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - - - - - - - - - - - - - - - (%INTEGER-TENSOR-ELEM-TO-FLOAT TYPE-SPEC)  autodiff.lisp [See above]
- - - - - - - - - - - - - - - - - (%CRISP-TENSOR-PARAM-TYPE-P PD-TYPE)  autodiff.lisp [See above]
- - - - - - - - - - - - - - - - - (%ENSURE-TENSOR-READ-WRITE TYPE-SPEC)  autodiff.lisp
- - - - - - - - - - - - - - - - (%CRISP-HANDLE-PARAM-TYPE-P PD-TYPE)  autodiff.lisp [See above]
- - - - - - - - - - - - - - - - (FLATTEN-ANF-BODY ANF-BODY)  anf-transform.lisp
- - - - - - - - - - - - - - - - (%EXTRACT-RETURN-VARS FLAT-ANF)  autodiff.lisp
- - - - - - - - - - - - - - - - (%CHECK-FN-BODY-FOR-MUTATIONS BODY-FORMS PARAM-NAMES FN-NAME)  autodiff.lisp
- - - - - - - - - - - - - - - - (%GENERATE-BACKWARD-FUNCTION-WALK FLAT-ANF FLOAT-PARAM-SYMS T-GRAD-SYMS RETURN-VARS &OPTIONAL TENSOR-INPUTS-HT ANY-DOUBLE RETURN-ADJ-TYPES)  autodiff.lisp
- - - - - - - - - - - - - - - - - (%HANDLE-SINGLE-VALUE-BACKWARD V EXPR ADJOINT-MAP EMIT-FN LOCAL-ADJ-FN &KEY HOF-HANDLER-FN (ERROR-ON-UNKNOWN
                                                                                                                              T) TENSOR-INPUTS-HT SCRATCH-TILE-SYMS)  autodiff.lisp
- - - - - - - - - - - - - - - - - - (%HANDLE-MATH-AND-TRIG-BACKWARD V EXPR EMIT-FN LOCAL-ADJ-FN ADJOINT-MAP)  autodiff.lisp
- - - - - - - - - - - - - - - - - - (%HANDLE-TILDE-BACKWARD V EXPR EMIT-FN LOCAL-ADJ-FN TENSOR-INPUTS-HT SCRATCH-TILE-SYMS)  autodiff.lisp
- - - - - - - - - - - - - - - - - - (%HANDLE-SUB-FN-CALL-BACKWARD V EXPR EMIT-FN LOCAL-ADJ-FN HOF-HANDLER-FN)  autodiff.lisp
- - - - - - - - - - - - - - - - - - - (%EMIT-FOREIGN-BACKWARD FN ARGS T-ADJ-FORMS PKG EMIT-FN LOCAL-ADJ-FN)  autodiff.lisp
- - - - - - - - - - - - - - - - - - - (%EMIT-SUB-FN-BACKWARD FN ARGS BKWD-FN T-ADJ-FORMS N-FP PKG EMIT-FN LOCAL-ADJ-FN &OPTIONAL (SYM-PREFIX
                                                                                                                                  BW))  autodiff.lisp
- - - - - - - - - - - - - - - - - - (%IS-ACCESSOR-P EXPR)  autodiff.lisp
- - - - - - - - - - - - - - - - - - (%HANDLE-ACCESSOR-BACKWARD V EXPR EMIT-FN LOCAL-ADJ-FN ADJOINT-MAP)  autodiff.lisp
- - - - - - - - - - - - - - - - - - - (%STRIP-ACCESSOR-TILDES ACCESSOR)  autodiff.lisp
- - - - - - - - - - - - - - - - - - - (%NESTED-FIELD-INFO-P FIELD-INFO)  autodiff.lisp
- - - - - - - - - - - - - - - - - - (%HANDLE-CONSTRUCTOR-BACKWARD V EXPR EMIT-FN LOCAL-ADJ-FN ADJOINT-MAP)  autodiff.lisp
- - - - - - - - - - - - - - - - - - (%VALUE-IF-P EXPR)  autodiff.lisp
- - - - - - - - - - - - - - - - - - (%HANDLE-VALUE-IF-BACKWARD V EXPR ADJOINT-MAP EMIT-FN LOCAL-ADJ-FN &KEY HOF-HANDLER-FN (ERROR-ON-UNKNOWN
                                                                                                                            T) TENSOR-INPUTS-HT SCRATCH-TILE-SYMS)  autodiff.lisp
- - - - - - - - - - - - - - - - - - - (%BACKWARD-VALUE-EXPR V EXPR ADJOINT-MAP EMIT-FN LOCAL-ADJ-FN &KEY HOF-HANDLER-FN (ERROR-ON-UNKNOWN
                                                                                                                         T) TENSOR-INPUTS-HT SCRATCH-TILE-SYMS)  autodiff.lisp
- - - - - - - - - - - - - - - - - - - - (%VALUE-IF-P EXPR)  autodiff.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (%HANDLE-VALUE-IF-BACKWARD V EXPR ADJOINT-MAP EMIT-FN LOCAL-ADJ-FN &KEY HOF-HANDLER-FN (ERROR-ON-UNKNOWN
                                                                                                                                T) TENSOR-INPUTS-HT SCRATCH-TILE-SYMS)  autodiff.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - - (%VALUE-LET-P EXPR)  autodiff.lisp
- - - - - - - - - - - - - - - - - - - - (%HANDLE-VALUE-LET-BACKWARD V EXPR ADJOINT-MAP EMIT-FN LOCAL-ADJ-FN &KEY HOF-HANDLER-FN (ERROR-ON-UNKNOWN
                                                                                                                                 T) TENSOR-INPUTS-HT SCRATCH-TILE-SYMS)  autodiff.lisp
- - - - - - - - - - - - - - - - - - - - - (%BACKWARD-VALUE-EXPR V EXPR ADJOINT-MAP EMIT-FN LOCAL-ADJ-FN &KEY HOF-HANDLER-FN (ERROR-ON-UNKNOWN
                                                                                                                             T) TENSOR-INPUTS-HT SCRATCH-TILE-SYMS)  autodiff.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - - (%HANDLE-SINGLE-VALUE-BACKWARD V EXPR ADJOINT-MAP EMIT-FN LOCAL-ADJ-FN &KEY HOF-HANDLER-FN (ERROR-ON-UNKNOWN
                                                                                                                                    T) TENSOR-INPUTS-HT SCRATCH-TILE-SYMS)  autodiff.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - (%FORMS->PROGN FORMS)  autodiff.lisp
- - - - - - - - - - - - - - - - - - (%VALUE-LET-P EXPR)  autodiff.lisp [See above]
- - - - - - - - - - - - - - - - - - (%HANDLE-VALUE-LET-BACKWARD V EXPR ADJOINT-MAP EMIT-FN LOCAL-ADJ-FN &KEY HOF-HANDLER-FN (ERROR-ON-UNKNOWN
                                                                                                                             T) TENSOR-INPUTS-HT SCRATCH-TILE-SYMS)  autodiff.lisp [See above]
- - - - - - - - - - - - - - - - - - (%BACKWARD-SKIP-FN-P FN-SYM)  autodiff.lisp
- - - - - - - - - - - - - - - - - (%EMIT-SUB-FN-BACKWARD FN ARGS BKWD-FN T-ADJ-FORMS N-FP PKG EMIT-FN LOCAL-ADJ-FN &OPTIONAL (SYM-PREFIX
                                                                                                                              BW))  autodiff.lisp [See above]
- - - - - - - - - - - - - - - - (DEF-FUNCTION NAME PARAMS &REST BODY-AND-LOCATION)  macros.lisp
- - - - - - - - - - - - - - - - - (REGISTER-FUNCTION-SIGNATURE FORM LOCATION)  environment.lisp [See above]
- - - - - - - - - - - - - - - - - (DEF-FUNCTION NAME PARAMS &REST BODY-AND-LOCATION)  macros.lisp [RECURSION]
- - - - - - - - - - - - - - - - - (INTERNAL-DEF-FUNCTION NAME PARAMS DECLARATIONS BODY LOCATION)  analysis/core.lisp
- - - - - - - - - - - - - - - - - - (PARSE-FUNCTION-DECLARATIONS PARAMS DECLARATIONS)  environment.lisp [See above]
- - - - - - - - - - - - - - - - - - (%BOUNDARY-STRUCT-TYPE-P TYPE)  analysis/core.lisp
- - - - - - - - - - - - - - - - - - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - (%VALIDATE-GRID-FUNCTION-RETURN-TYPE RETURN-TYPES)  environment.lisp
- - - - - - - - - - - - - - - - - - (%HP-CHECK-WORKGROUP-BOUNDS KERNEL-NAME LOCAL-SIZE-DECL PROFILE)  hardware-profile.lisp
- - - - - - - - - - - - - - - - - - - (%HP-LOCAL-SIZE-DIMS LOCAL-SIZE-DECL)  hardware-profile.lisp
- - - - - - - - - - - - - - - - - - (ACTIVE-HARDWARE-PROFILE)  hardware-profile.lisp [See above]
- - - - - - - - - - - - - - - - - - (INTERNAL-COMPILE-FUNCTION NAME EXPLICIT-ENV RETURN-TYPE PARAMS BODY DECLARATIONS LOCATION CONTEXT)  analysis/core.lisp
- - - - - - - - - - - - - - - - - - - (SINGLE-PASS-MODE-P)  analysis/core.lisp
- - - - - - - - - - - - - - - - - - - (DETECT-AND-REGISTER-IMPLICIT-TEMPLATE NAME EXPLICIT-ENV RETURN-TYPE PARAMS BODY DECLARATIONS)  environment.lisp
- - - - - - - - - - - - - - - - - - - - (INCOMPLETE-TYPE-P TYPE-SPEC)  types/validation.lisp
- - - - - - - - - - - - - - - - - - - - - (GET-TEMPLATE-ARITY NAME)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - (FIND-STRUCT-DEFINITION-BY-NAME NAME-OR-SYMBOL)  structs.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (FIND-STRUCT-DEFINITION-BY-NAME NAME-OR-SYMBOL)  structs.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (DEF-FUNCTION NAME PARAMS &REST BODY-AND-LOCATION)  macros.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - - (REGISTER-TEMPLATE NAME PARAMS CONSTRAINTS BODY SIGNATURE)  templates.lisp [See above]
- - - - - - - - - - - - - - - - - - - (SCAN-FOR-CARRIERS NAME BODY)  environment.lisp
- - - - - - - - - - - - - - - - - - - - (SINGLE-PASS-MODE-P)  analysis/core.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (WITH-PEEK-SCRATCH-COUNTER &BODY BODY)  macros.lisp
- - - - - - - - - - - - - - - - - - - - (SHALLOW-ANALYZE-BODY FORMS)  analysis/core.lisp
- - - - - - - - - - - - - - - - - - - - - (SCAN-FORM (FORM CONS))  analysis/core.lisp
- - - - - - - - - - - - - - - - - - - - - - (SCAN-OPERATOR (OP
                                                            (EQL
                                                             'MAKE-SCRATCH-TENSOR)) ARGS)  analysis/core.lisp
- - - - - - - - - - - - - - - - - - - - - - - (SCAN-FORM (FORM CONS))  analysis/core.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - - - - - (SCAN-OPERATOR (OP
                                                              (EQL
                                                               'MAKE-SCRATCH-TENSOR)) ARGS)  analysis/core.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - - - - - (EXPAND-STORAGE-HANDLE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - - - (%REGISTER-SCRATCH-TENSOR-IMPLICIT OP ARGS)  analysis/structs.lisp
- - - - - - - - - - - - - - - - - - - - - - - - (%SCRATCH-TENSOR-CANONICAL-SPEC OP ARGS)  analysis/structs.lisp
- - - - - - - - - - - - - - - - - - - - - - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - - - - - (EXPAND-STORAGE-HANDLE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - - - - (%EXTRACT-SCRATCH-SIZE-EXPR OP ARGS)  analysis/structs.lisp
- - - - - - - - - - - - - - - - - - - - - - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - - (SCAN-FORM (FORM CONS))  analysis/core.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - (INJECT-IMPLICIT-ARGUMENTS NAME EXPLICIT-ENV)  environment.lisp
- - - - - - - - - - - - - - - - - - - (VALIDATE-RETURN-TYPES NAME BODY ENV CONTEXT DECLARED-RETURN-TYPES LOCATION)  analysis/core.lisp
- - - - - - - - - - - - - - - - - - - - (ANALYZE-BODY-EXPRESSIONS BODY-LIST ENV CONTEXT LOCATION)  analysis/core.lisp
- - - - - - - - - - - - - - - - - - - - - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp
- - - - - - - - - - - - - - - - - - - - - - (%TRY-PARSE-TYPED-LITERAL EXPR LOCATION)  analysis/core.lisp
- - - - - - - - - - - - - - - - - - - - - - (FIND-VARIABLE-IN-ENV NAME ENV)  analysis/core.lisp
- - - - - - - - - - - - - - - - - - - - - - (ANALYZE-INCOMPLETE-TYPE-ACCESSOR OP EXPR ENV CONTEXT LOCATION)  analysis/structs.lisp
- - - - - - - - - - - - - - - - - - - - - - - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - - - - - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - - - - (ANALYZE-FUNCTION-CALL OP EXPR ENV CONTEXT LOCATION)  analysis/core.lisp
- - - - - - - - - - - - - - - - - - - - - - - (MULTI-PASS-MODE-P)  analysis/core.lisp
- - - - - - - - - - - - - - - - - - - - - - - (SINGLE-PASS-MODE-P)  analysis/core.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - - - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - - - - - (RESOLVE-BEST-SIGNATURE OP EXPLICIT-ARG-TYPES CONTEXT)  type-checker.lisp
- - - - - - - - - - - - - - - - - - - - - - - - (TYPES-LIST-COMPATIBLE-P ARG-TYPES PARAM-TYPES)  type-checker.lisp
- - - - - - - - - - - - - - - - - - - - - - - - (INSTANTIATE-GENERIC-FUNCTION GENERIC-DEF EXPLICIT-ARG-TYPES CONTEXT LOCATION)  environment.lisp
- - - - - - - - - - - - - - - - - - - - - - - - - (RESOLVE-ARGUMENT-BINDINGS GENERIC-DEF EXPLICIT-ARG-TYPES)  environment.lisp
- - - - - - - - - - - - - - - - - - - - - - - - - - (BIND-KEYWORD-ARGS FULL-ENV EXPLICIT-ARGS KEY-IDX NAME)  environment.lisp
- - - - - - - - - - - - - - - - - - - - - - - - - - (TYPES-LIST-COMPATIBLE-P ARG-TYPES PARAM-TYPES)  type-checker.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - - - - - - (INJECT-DEFAULTS REMAINDER-ENV DEFAULTS)  environment.lisp
- - - - - - - - - - - - - - - - - - - - - - - - - (MANGLE-FUNCTION-VARIANT-NAME BASE-NAME PARAM-TYPES)  mangling.lisp
- - - - - - - - - - - - - - - - - - - - - - - - - (INTERNAL-COMPILE-FUNCTION NAME EXPLICIT-ENV RETURN-TYPE PARAMS BODY DECLARATIONS LOCATION CONTEXT)  analysis/core.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - - - - - - (COMPILE-TOPLEVEL-FORM FORM LOCATION MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)  analysis/core.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - - - - - (%CHECK-STRUCT-MUTATING-CALL OP EXPLICIT-ARG-NODES ENV CONTEXT LOCATION)  analysis/core.lisp
- - - - - - - - - - - - - - - - - - - - - - - - (FIND-VARIABLE-IN-ENV NAME ENV)  analysis/core.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - - - - (%BOUNDARY-STRUCT-TYPE-P TYPE)  analysis/core.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - - - (FIND-VARIABLE-IN-ENV NAME ENV)  analysis/core.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - - - (CALCULATE-UNIFORMITY-STATE NODE ENV)  analysis/core.lisp
- - - - - - - - - - - - - - - - - - - - - - - - (CALCULATE-UNIFORMITY-STATE NODE ENV)  analysis/core.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - - - - - - (FIND-VARIABLE-IN-ENV NAME ENV)  analysis/core.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - - - (IS-BRAND-TYPE-P TYPE-NAME)  types/brand.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - - - (BRAND-ACTIVE-P BRAND-DEF)  types/brand.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - - - (%FIND-BRAND-OWNER-VAR BRAND-NAME SIG-PARAMS ARG-NODES)  types/brand.lisp
- - - - - - - - - - - - - - - - - - - - - - - - (FIND-BRAND-FOR-OWNER BRAND-NAME OWNER-TYPE)  types/brand.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - - - (RESOLVE-BRAND-TYPE BRAND-NAME VAR-REF &OPTIONAL BASE-TYPE)  types/brand.lisp
- - - - - - - - - - - - - - - - - - - - - - - - (REGISTER-DERIVED-TYPE NEW-TYPE-NAME ORIGINAL-TYPE-NAME SUBST-MODE)  types/hierarchy.lisp
- - - - - - - - - - - - - - - - - - - - - - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - - - - - (%VALIDATE-DERIVED-TYPE-REGISTRATION NEW-TYPE-NAME ORIGINAL-TYPE-NAME SUBST-MODE)  types/hierarchy.lisp
- - - - - - - - - - - - - - - - - - - - - - - - - (COMPUTE-BASE-TYPE ORIGINAL-TYPE-NAME)  types/hierarchy.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - - - - - (%UPDATE-DERIVED-TYPE-RELATIONSHIPS NEW-NODE NEW-TYPE-NAME ORIGINAL-TYPE-NAME SUBST-MODE)  types/hierarchy.lisp
- - - - - - - - - - - - - - - - - - - - - - - - - (%REGISTER-DERIVED-IN-CRISP-TYPES NEW-TYPE-NAME BASE-TYPE)  types/hierarchy.lisp
- - - - - - - - - - - - - - - - - - - - - - - - - - (CRISP-TYPE-TO-LLVM-TYPE TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - - - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]
- - - - - - - - - - - - - - - - - - - - - - - (IS-SUBSTITUTABLE-FOR? SOURCE-TYPE TARGET-TYPE)  types/hierarchy.lisp
- - - - - - - - - - - - - - - - - - - - - - - - (HAS-ANCESTOR-PATH? FROM-TYPE TO-TYPE VISITED)  types/hierarchy.lisp
- - - - - - - - - - - - - - - - - - - - - - - - - (HAS-ANCESTOR-PATH? FROM-TYPE TO-TYPE VISITED)  types/hierarchy.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - - - - - - - - - - - - - - - - - - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - - (SEMANTIC-NODE-SOURCE-LOCATION NODE)  analysis/core.lisp [See above]
- - - - - - - - - - - - - - - - - - - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - - - - - - - - - - - - - - - - - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [RECURSION]
- - - - - - - - - - - - - - - - - - - (SEMANTIC-NODE-SOURCE-LOCATION NODE)  analysis/core.lisp [See above]
- - - - - - - - - - - - - - (COMPILE-DEF-FUNCTION FORM LOCATION MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)  analysis/core.lisp [RECURSION]
- - - - - - - - - - - - - (%PRE-REGISTER-HOF-TEMPLATES)  analysis/core.lisp
- - - - - - - - - - - - - - (%EXTRACT-FN-BODY-AND-DECLARATIONS BODY-AND-LOC)  analysis/core.lisp
- - - - - - - - - - - - - - (%DETECT-HOF-PARAM-VIA-FUNCALL PARAMS FN-BODY)  analysis/core.lisp
- - - - - - - - - - - - - - - (%TREE-HAS-FUNCALL-P TREE TARGET-SYM)  analysis/core.lisp
- - - - - - - - - - - - - - - - (%TREE-HAS-FUNCALL-P TREE TARGET-SYM)  analysis/core.lisp [RECURSION]
- - - - - - - - - - - - - - (%REGISTER-HOF-ENTRY NAME TYPE-DESC PARAMS FN-PARAM-IDX FN-PARAM-SYM FLOAT-PARAM-SYMS CLEAN-BODY N-FLOAT-PARAMS N-RETURN)  analysis/core.lisp
- - - - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - - - (COMPUTE-NATIVE-LAYOUT MEMBERS)  structs.lisp
- - - - - - - (GET-NATIVE-BASE-ALIGNMENT TYPE-SPEC)  structs.lisp
- - - - - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - (GET-TYPE-BASE TYPE-NAME)  types/hierarchy.lisp [See above]
- - - - - - - - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - (GET-NATIVE-BASE-ALIGNMENT TYPE-SPEC)  structs.lisp [RECURSION]
- - - - - - - - (%STRUCT-NATIVE-ALIGNMENT STRUCT-NAME)  structs.lisp
- - - - - - - - - (FIND-STRUCT-DEFINITION-BY-NAME NAME-OR-SYMBOL)  structs.lisp [See above]
- - - - - - - - - (GET-NATIVE-BASE-ALIGNMENT TYPE-SPEC)  structs.lisp [RECURSION]
- - - - - - - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - - - - (GET-NATIVE-SIZE TYPE-SPEC)  structs.lisp [See above]
- - - - - - - (CALCULATE-NATIVE-PADDING CURRENT-OFFSET ALIGNMENT)  structs.lisp
- - - - - - (ENSURE-STRUCT-LLVM-TYPE NAME)  structs.lisp [See above]
- - (COMPILE-FILES FILES OUTPUT-FILE DEBUG-P SINGLE-PASS-P TARGETS METADATA-P HOIST-TARGETS &OPTIONAL BC-FILES) :CRISP.MAIN  main.lisp
- - - (INITIALIZE-DEBUG-CONTEXT MODULE DI-BUILDER FILEPATH) :CRISP.MAIN  main.lisp
- - - (COMPILE-TOPLEVEL-FORM FORM LOCATION MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)  analysis/core.lisp [See above]
- - - (GENERATE-LOCATION-MAP FORMS)  analysis/core.lisp
- - - - (WALK-AND-MAP-LOCATIONS EXPR LOCATION MAP COUNTER)  analysis/core.lisp
- - - - - (WALK-AND-MAP-LOCATIONS EXPR LOCATION MAP COUNTER)  analysis/core.lisp [RECURSION]
- - - (COMPILE-MODULE FORMS MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)  analysis/core.lisp
- - - - (%INJECT-SHADOW-STRUCT-FORMS FORMS)  autodiff.lisp
- - - - - (%COLLECT-STRUCT-NAMES-FROM-FORMS FORMS)  autodiff.lisp
- - - - - (%GENERATE-SHADOW-DEF-STRUCT-FORM DEF-STRUCT-FORM &OPTIONAL STRUCT-NAME-SET)  autodiff.lisp
- - - - - - (%ADJ-TYPE-FOR-FIELD FORWARD-TYPE &OPTIONAL STRUCT-NAME-SET)  autodiff.lisp
- - - - - - - (%CRISP-FLOAT-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - - - - - (%CRISP-INTEGER-SCALAR-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - - - - - (%INTEGER-SCALAR-TO-FLOAT-SCALAR TYPE-SPEC)  autodiff.lisp [See above]
- - - - - - - (IS-BRAND-TYPE-P TYPE-NAME)  types/brand.lisp [See above]
- - - - - - - (BRAND &REST ARGS)  macros.lisp
- - - - - - (DEF-STRUCT NAME &REST MEMBERS)  macros.lisp
- - - - - - - (BRAND &REST ARGS)  macros.lisp [See above]
- - - - - - - (REGISTER-BRAND-DEFINITION STRUCT-NAME BRAND-FORM)  types/brand.lisp
- - - - - - - - (PARSE-BRAND-DECLARATION BRAND-FORM)  types/brand.lisp
- - - - - - - - (IS-BRAND-TYPE-P TYPE-NAME)  types/brand.lisp [See above]
- - - - - - - - (FIND-STRUCT-DEFINITION-BY-NAME NAME-OR-SYMBOL)  structs.lisp [See above]
- - - - - - - - (BRAND-ACTIVE-P BRAND-DEF)  types/brand.lisp [See above]
- - - - - - - - (REGISTER-DERIVED-TYPE NEW-TYPE-NAME ORIGINAL-TYPE-NAME SUBST-MODE)  types/hierarchy.lisp [See above]
- - - - - - - (REGISTER-STRUCT-DEFINITION NAME MEMBERS &OPTIONAL (CATEGORY
                                                                  STRUCT))  structs.lisp [See above]
- - - - - - - (VALIDATE-AND-REORDER-STRUCT-ARGS STRUCT-NAME DEFINED-MEMBERS ARGS)  structs.lisp
- - - - (ANALYZE-SIGNATURES-PASS FORMS)  analysis/core.lisp
- - - - - (%PRE-REGISTER-DIFFERENTIABLE-FNS FORMS &OPTIONAL RECORD-INFO)  analysis/core.lisp
- - - - - - (%SCAN-FORMS-FOR-RECORD-INFO FORMS)  autodiff.lisp
- - - - - - (%EXTRACT-FN-BODY-AND-DECLARATIONS BODY-AND-LOC)  analysis/core.lisp [See above]
- - - - - - (%FN-NAME-IS-GRAD-P NAME)  autodiff.lisp [See above]
- - - - - - (PARSE-FUNCTION-DECLARATIONS PARAMS DECLARATIONS)  environment.lisp [See above]
- - - - - - (%CRISP-FLOAT-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - - - - (%ACTIVE-SCALAR-PARAM-SET PARAMS BODY-FORMS)  autodiff.lisp [See above]
- - - - - - (%COUNT-ACTIVE-CONTRIBUTIONS PD-TYPE SYM ACTIVE-SET &OPTIONAL RECORD-INFO)  autodiff.lisp [See above]
- - - - - - (%CRISP-FUNCTION-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - - - - (%HAS-TENSOR-DIFF-PARAM-P ENV)  autodiff.lisp [See above]
- - - - - - (%REGISTER-HOF-ENTRY NAME TYPE-DESC PARAMS FN-PARAM-IDX FN-PARAM-SYM FLOAT-PARAM-SYMS CLEAN-BODY N-FLOAT-PARAMS N-RETURN)  analysis/core.lisp [See above]
- - - - - - (%REGISTER-STANDARD-DIFFERENTIABLE-ENTRY NAME TYPE-DESC N-FLOAT-PARAMS N-RETURN &KEY OPTIMISTIC-P)  analysis/core.lisp
- - - - - - (%PRE-REGISTER-DIFFERENTIABLE-FNS FORMS &OPTIONAL RECORD-INFO)  analysis/core.lisp [RECURSION]
- - - - - - (%DETECT-HOF-PARAM-VIA-FUNCALL PARAMS FN-BODY)  analysis/core.lisp [See above]
- - - - - (WALK-CODE-FORMS FORMS VISITOR-FN)  analysis/core.lisp
- - - - - - (VISIT-TOPLEVEL-FORM FORM LOCATION VISITOR-FN)  analysis/core.lisp [See above]
- - - - - (REGISTER-FUNCTION-SIGNATURE FORM LOCATION)  environment.lisp [See above]
- - - - - (SHALLOW-ANALYZE-BODY FORMS)  analysis/core.lisp [See above]
- - - - - (%PRE-REGISTER-HOF-TEMPLATES)  analysis/core.lisp [See above]
- - - - - (INFER-PARAM-UNIFORMITY)  analysis/core.lisp
- - - - - - (%UNI-TOPO-ORDER NODES)  analysis/core.lisp
- - - - - - (%UNI-PARAM-NAMES PARAMS)  analysis/core.lisp
- - - - - - (%UNI-ANALYZE FORM ENV)  analysis/core.lisp
- - - - - - - (%UNI-BUILTIN-STATE OP)  analysis/core.lisp
- - - - - - - (%UNI-ANALYZE FORM ENV)  analysis/core.lisp [RECURSION]
- - - - - - - (%UNI-ANALYZE-LET FORM ENV)  analysis/core.lisp
- - - - - - - - (%UNI-ANALYZE FORM ENV)  analysis/core.lisp [RECURSION]
- - - - - - - (%UNI-COMBINE STATES)  analysis/core.lisp
- - - - - - - (%UNI-PARAM-NAMES PARAMS)  analysis/core.lisp [See above]
- - - - - - - (%UNI-CONTRIBUTE CALLEE PARAM-NAME STATE)  analysis/core.lisp
- - - - - - - - (%UNI-COMBINE STATES)  analysis/core.lisp [See above]
- - - - (FINALIZE-STRUCT-DEFINITIONS)  structs.lisp
- - - - - (REGISTER-STRUCT-DEFINITION NAME MEMBERS &OPTIONAL (CATEGORY STRUCT))  structs.lisp [See above]
- - - - (PROPAGATE-IMPLICIT-ARGUMENTS)  analysis/core.lisp
- - - - (COMPILE-FORMS-PASS FORMS MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)  analysis/core.lisp
- - - - - (COMPILE-TOPLEVEL-FORM FORM LOCATION MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)  analysis/core.lisp [See above]
- - - - - (WALK-CODE-FORMS FORMS VISITOR-FN)  analysis/core.lisp [See above]
- - - - (CHECK-FOR-RECURSION-CYCLES)  analysis/core.lisp
- - - - - (DETECT-CYCLE-FROM-NODE NODE VISITED VISITING)  analysis/core.lisp
- - - - - - (DETECT-CYCLE-FROM-NODE NODE VISITED VISITING)  analysis/core.lisp [RECURSION]
- - - - (%HP-CHECK-ALL-SHARED-MEMORY)  hardware-profile.lisp
- - - - - (ACTIVE-HARDWARE-PROFILE)  hardware-profile.lisp [See above]
- - - - - (%HP-CHECK-SHARED-MEMORY KERNEL-NAME PROFILE)  hardware-profile.lisp
- - - - - - (%HP-KERNEL-SHARED-BYTES KERNEL-NAME)  hardware-profile.lisp
- - - - - - - (GENERATE-IMPLICIT-SIGNATURE SIG DECLARED-PARAMS)  metadata.lisp
- - - - - - - - (GET-PHYSICAL-WIDTH TYPE)  metadata.lisp
- - - - - - - - - (%STORAGE-HANDLE-TYPE-P TYPE-SPEC)  macros.lisp
- - - - - - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - - - - (%USER-RECORD-TYPE-P TYPE-SPEC)  metadata-val.lisp
- - - - - - - - - - (%STORAGE-HANDLE-TYPE-P TYPE-SPEC)  macros.lisp [See above]
- - - - - - - - - - (GET-TYPE-BASE TYPE-NAME)  types/hierarchy.lisp [See above]
- - - - - - - - - (%ENUMERATE-PHYSICAL-TYPES TYPE-SPEC)  metadata-val.lisp
- - - - - - - - - - (%STORAGE-HANDLE-TYPE-P TYPE-SPEC)  macros.lisp [See above]
- - - - - - - - - - (LOOKUP-STRUCT-DEFINITION TYPE-NAME)  structs.lisp [See above]
- - - - - - - - - - (%ENUMERATE-PHYSICAL-TYPES TYPE-SPEC)  metadata-val.lisp [RECURSION]
- - - - - - - - - - (IS-BRAND-TYPE-P TYPE-NAME)  types/brand.lisp [See above]
- - - - - - - - (STRIP-PACKAGE-QUALIFIERS TYPE-SPEC)  metadata.lisp
- - - - - - - (%HP-SCRATCH-ELEM-BYTES ELEM-TYPE)  hardware-profile.lisp
- - - (LINK-FOREIGN-BITCODE MODULE BC-FILES) :CRISP.MAIN  main.lisp
- - - (COMPILE-TO-SPIRV MODULE OUTPUT-PATH &KEY DEBUG-P)  compiler.lisp
- - - - (%REMOVE-DEAD-ARRAY-RETURNING-FUNCTIONS MODULE)  compiler.lisp
- - - - - (LLVM-TYPE-KIND-IS-ARRAY? TY) :CRISP.LLVM-BINDINGS  llvm-bindings.lisp
- - - - (%MODULE-USES-NATIVE-BUILTIN-P MODULE)  codegen.lisp
- - - - (%EMIT-OPENCL-VERSION-METADATA MODULE)  codegen.lisp
- - - - (INJECT-SPIR-KERNEL-METADATA IR-TEXT)  compiler.lisp
- - - - - (FIND-SPIR-KERNELS IR-TEXT)  compiler.lisp
- - - - - - (%EXTRACT-SPIR-KERNEL-INFO IR-TEXT KERNEL-POS)  compiler.lisp
- - - - - (EXTRACT-KERNEL-PARAMS IR-TEXT FUNC-START FUNC-END)  compiler.lisp
- - - - - - (SPLIT-STRING STRING DELIMITER)  mangling.lisp [See above]
- - - - - (GENERATE-KERNEL-METADATA PARAMS METADATA-ID-BASE)  compiler.lisp
- - - - - - (IR-TYPE-TO-OPENCL-METADATA IR-TYPE)  compiler.lisp
- - - - (%RUN-OPT-PIPELINE INPUT-LL-FILE OUTPUT-LL-FILE PASSES-STRING)  compiler.lisp
- - - - - (%RUN-PASSES-IN-PROCESS INPUT-LL-FILE OUTPUT-LL-FILE PASSES-STRING)  compiler.lisp
- - - - - - (%MAKE-TARGET-MACHINE-FOR-MODULE MODULE)  compiler.lisp
- - - - - - - (%ENSURE-NVPTX-TARGET-INITIALIZED)  compiler.lisp
- - - - - (%LL-HAS-SPIRV-ILLEGAL-INT-P LL-FILE)  compiler.lisp
- - - - (RESOLVE-TOOL-EXECUTABLE TOOL-BASE)  compiler.lisp
- - - - (RUN-TOOL-COMMAND ARGS &KEY (LOG-PREFIX ))  compiler.lisp
- - - - (%MODULE-USES-COOP-MATRIX-P MODULE)  compiler.lisp
- - - (COMPILE-TO-PTX MODULE OUTPUT-PATH &KEY (COMPUTE-CAPABILITY sm_80) DEBUG-P)  compiler.lisp
- - - - (%PTX-FINALIZE-LIBDEVICE MODULE)  codegen.lisp
- - - - - (%SET-NVVM-REFLECT-FTZ MODULE FTZ-P)  codegen.lisp
- - - - (%RUN-OPT-O3 INPUT-LL-FILE OUTPUT-LL-FILE)  compiler.lisp
- - - - - (%RUN-PASSES-IN-PROCESS INPUT-LL-FILE OUTPUT-LL-FILE PASSES-STRING)  compiler.lisp [See above]
- - - - (RESOLVE-TOOL-EXECUTABLE TOOL-BASE)  compiler.lisp [See above]
- - - - (RUN-TOOL-COMMAND ARGS &KEY (LOG-PREFIX ))  compiler.lisp [See above]
- - - (PRINT-COMPILER-ERROR C FILENAME) :CRISP.MAIN  main.lisp
- - - (GENERATE-METADATA-FOR-FILE INPUT-PATH OUTPUT-PATH &KEY (OUTPUT-TARGETS
                                                               NIL) (SOURCE-FILE
                                                                     NIL) (FORMS
                                                                           NIL))  metadata.lisp
- - - - (EXTRACT-DEFINED-KERNELS FORMS)  metadata.lisp
- - - - (COLLECT-KERNEL-DEPENDENCIES KERNEL-NAMES)  metadata.lisp
- - - - - (GET-TYPE-BASE TYPE-NAME)  types/hierarchy.lisp [See above]
- - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - (%BWD-FIXUP-DECLARED-TYPES BWD-K-NAME)  metadata.lisp
- - - - - (%BWD-RESOLVE-TYPE TYPE-SPEC &OPTIONAL NEW-ACCESS)  metadata.lisp
- - - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - - (SERIALIZE-ALIASES STREAM ALIASES-HASH)  metadata.lisp
- - - - - (STRIP-PACKAGE-QUALIFIERS TYPE-SPEC)  metadata.lisp [See above]
- - - - - (PRINT-WITHOUT-PACKAGES OBJ STREAM)  metadata.lisp
- - - - (SERIALIZE-STRUCTS STREAM STRUCTS-HASH)  metadata.lisp
- - - - - (%SERIALIZE-RECORDS STREAM STRUCTS-HASH)  metadata.lisp
- - - - - - (SORT-STRUCTS-BY-DEPENDENCY STRUCT-NAMES)  metadata.lisp
- - - - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - (STRIP-PACKAGE-QUALIFIERS TYPE-SPEC)  metadata.lisp [See above]
- - - - - - (IS-BRAND-TYPE-P TYPE-NAME)  types/brand.lisp [See above]
- - - - - (SORT-STRUCTS-BY-DEPENDENCY STRUCT-NAMES)  metadata.lisp [See above]
- - - - - (STRIP-PACKAGE-QUALIFIERS TYPE-SPEC)  metadata.lisp [See above]
- - - - - (IS-BRAND-TYPE-P TYPE-NAME)  types/brand.lisp [See above]
- - - - (%HP-SERIALIZE-ACTIVE-PROFILE STREAM)  hardware-profile.lisp
- - - - - (ACTIVE-HARDWARE-PROFILE)  hardware-profile.lisp [See above]
- - - - (SERIALIZE-KERNELS OUTPUT-STREAM KERNEL-NAMES &KEY SOURCE OUTPUT-TARGETS)  metadata.lisp
- - - - - (GENERATE-PHYSICAL-SIGNATURE SIG-OR-PARAMS)  metadata.lisp
- - - - - - (STRIP-PACKAGE-QUALIFIERS TYPE-SPEC)  metadata.lisp [See above]
- - - - - - (%STORAGE-HANDLE-TYPE-P TYPE-SPEC)  macros.lisp [See above]
- - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - (%USER-RECORD-TYPE-P TYPE-SPEC)  metadata-val.lisp [See above]
- - - - - - (%ENUMERATE-PHYSICAL-TYPES TYPE-SPEC)  metadata-val.lisp [See above]
- - - - - (GENERATE-DECLARED-SIGNATURE SIG &OPTIONAL DECLARED-PARAMS)  metadata.lisp
- - - - - - (GET-PHYSICAL-WIDTH TYPE)  metadata.lisp [See above]
- - - - - - (STRIP-PACKAGE-QUALIFIERS TYPE-SPEC)  metadata.lisp [See above]
- - - - - - (%STORAGE-HANDLE-TYPE-P TYPE-SPEC)  macros.lisp [See above]
- - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - (GENERATE-IMPLICIT-SIGNATURE SIG DECLARED-PARAMS)  metadata.lisp [See above]
- - - - - (PRINT-WITHOUT-PACKAGES OBJ STREAM)  metadata.lisp [See above]
- - - (INVOKE-HOISTER HOIST-ID METACRISP-FILE) :CRISP.MAIN  main.lisp
- - - - (GET-HOISTER-BINARY-PATH HOIST-ID) :CRISP.MAIN  main.lisp

- (%074-HAS-LOCAL-PTR-PARAM DEFINE-LINE)  metadata-val.lisp

- (%089-CHECK-DISPATCH-KEY K-DEF KEY EXPECTED-HEAD)  metadata-val.lisp

- (%089-DECL-STRATEGY= DECL-VALUE EXPECTED-STRATEGY)  metadata-val.lisp

- (%089-FIND-KERNEL METACRISP-PATH)  metadata-val.lisp

- (%AUTODIFF-GRAD-CELL-TYPE)  autodiff.lisp

- (%CRISP-TENSOR-TYPE-P TYPE-SPEC)  autodiff.lisp
- - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]

- (%CT-RESOLVE-VALUE VALUE)  macros.lisp

- (%EXPAND-WARP-IDX-FORM TENSOR-FORM BINDINGS BODY-FORMS LOCATION)  analysis/control.lisp

- (%FIND-RECORD-DEF RECORDS-SECTION NAME)  metadata-val.lisp

- (%GENERATE-BACKWARD-KERNEL-AST NAME PARAMS SIGNATURE-TYPES RAW-BODY)  macros.lisp
- - (%SPLIT-KERNEL-INPUTS-OUTPUTS PARAMS SIGNATURE-TYPES)  macros.lisp
- - (%EXPAND-RECORD-KERNEL-INPUTS INPUTS INPUT-TYPES PKG)  autodiff.lisp
- - - (%CRISP-RECORD-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - (%GET-RECORD-RUNTIME-FIELDS REC-TYPE-SPEC)  autodiff.lisp [See above]
- - - (%RECORD-FIELD-PARAM-SYM PARAM-SYM FIELD-NAME PKG)  autodiff.lisp
- - - (%CRISP-FLOAT-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - (%CRISP-INTEGER-SCALAR-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - (%INTEGER-SCALAR-TO-FLOAT-SCALAR TYPE-SPEC)  autodiff.lisp [See above]
- - - (%CRISP-STRUCT-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - (%SHADOW-TYPE-NAME-FOR STRUCT-TYPE-NAME)  autodiff.lisp
- - - (%BUILD-STRUCT-FIELD-ADJ-ALIST PARAM-SYM STRUCT-TYPE PKG)  autodiff.lisp
- - - - (%GET-RECORD-RUNTIME-FIELDS REC-TYPE-SPEC)  autodiff.lisp [See above]
- - - - (%CRISP-STRUCT-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - - (%BUILD-STRUCT-FIELD-ADJ-ALIST PARAM-SYM STRUCT-TYPE PKG)  autodiff.lisp [RECURSION]
- - (%SUBSTITUTE-RECORD-ACCESSORS FORM RECORD-SUBS-HT RECORD-TYPE-HT)  autodiff.lisp
- - - (%SUBSTITUTE-RECORD-ACCESSORS FORM RECORD-SUBS-HT RECORD-TYPE-HT)  autodiff.lisp [RECURSION]
- - - (%RECORD-ACCESSOR-SYSTEM-GENERATED-P ACCESSOR-SYM REC-TYPE)  autodiff.lisp
- - (%MAKE-KERNEL-PARAM-TYPE-RESOLVER PARAMS TYPES)  macros.lisp
- - (%EXPAND-STRIDE-MACROS-IN-FORM FORM TYPE-RESOLVER-FN LOCATION)  macros.lisp
- - - (%EXPAND-STRIDE-MACROS-IN-FORM FORM TYPE-RESOLVER-FN LOCATION)  macros.lisp [RECURSION]
- - - (%EXPAND-TENSOR-STRIDE-OP FORM TYPE-RESOLVER-FN LOCATION)  macros.lisp
- - - - (%EXPAND-STRIDE-MACROS-IN-FORM FORM TYPE-RESOLVER-FN LOCATION)  macros.lisp [RECURSION]
- - - - (%TENSOR-STRIDE-RESOLVE-CT EXPR TYPE-RESOLVER-FN LOCATION)  macros.lisp
- - - - - (%RESOLVE-TENSOR-FORM-CT TENSOR-FORM TYPE-RESOLVER-FN)  macros.lisp
- - - - - - (%TS-CANONICALIZE-TENSOR-TYPE RAW-TYPE)  analysis/control.lisp
- - - - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - (UNMANGLE-TEMPLATE-STRUCT-NAME SYMBOL)  mangling.lisp [See above]
- - - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - (%GET-TENSOR-CT CANON)  analysis/structs.lisp [See above]
- - - - - (%TS-LAYOUT-TAG-TO-CT TAG N LOCATION)  analysis/control.lisp
- - - - (%EXPAND-TENSOR-STRIDE-FORM EXPR CT LOCATION)  analysis/control.lisp
- - - - - (%TS-BUILD-STRIDE-BINDINGS EXTENTS-SYMS CT)  analysis/control.lisp
- - - - - (%TS-BUILD-DECODE-BINDINGS FLAT-SYM BINDING-SYMS STRIDE-SYMS CT)  analysis/control.lisp
- - - - - (%BUILD-EXACT-ITER-COUNT-FORM START-SYM STRIDE-SYM LEN-SYM CL-PKG)  analysis/control.lisp
- - - (%EXPAND-GRID-STRIDE-OP FORM TYPE-RESOLVER-FN LOCATION)  macros.lisp
- - - - (%EXPAND-STRIDE-MACROS-IN-FORM FORM TYPE-RESOLVER-FN LOCATION)  macros.lisp [RECURSION]
- - - - (%EXPAND-GRID-STRIDE-FORM EXPR LOCATION)  analysis/control.lisp
- - - - - (%TS-BUILD-STRIDE-BINDINGS EXTENTS-SYMS CT)  analysis/control.lisp [See above]
- - - - - (%TS-BUILD-DECODE-BINDINGS FLAT-SYM BINDING-SYMS STRIDE-SYMS CT)  analysis/control.lisp [See above]
- - - - - (%BUILD-EXACT-ITER-COUNT-FORM START-SYM STRIDE-SYM LEN-SYM CL-PKG)  analysis/control.lisp [See above]
- - - (%EXPAND-LOOP-VECTOR-STRIDE-OP FORM TYPE-RESOLVER-FN LOCATION)  macros.lisp
- - - - (%EXPAND-STRIDE-MACROS-IN-FORM FORM TYPE-RESOLVER-FN LOCATION)  macros.lisp [RECURSION]
- - - - (%EXPAND-LOOP-VECTOR-STRIDE-FORM EXPR LOCATION)  analysis/control.lisp
- - - - - (%BUILD-EXACT-ITER-COUNT-FORM START-SYM STRIDE-SYM LEN-SYM CL-PKG)  analysis/control.lisp [See above]
- - - (%EXPAND-TILE-STRIDE-OP FORM TYPE-RESOLVER-FN LOCATION)  macros.lisp
- - - - (%EXPAND-STRIDE-MACROS-IN-FORM FORM TYPE-RESOLVER-FN LOCATION)  macros.lisp [RECURSION]
- - - - (%TENSOR-STRIDE-RESOLVE-CT EXPR TYPE-RESOLVER-FN LOCATION)  macros.lisp [See above]
- - - - (%EXPAND-TILE-STRIDE-FORM EXPR CT LOCATION)  analysis/control.lisp
- - - - - (%TILE-STRIDE-PARSE EXPR)  analysis/control.lisp
- - - - - (%EXPAND-WORKGROUP-STRIDED-OUTER-LOOP-WITH-TS-SYMS TENSOR-FORM N BINDINGS BODY-FORMS TS-SYMS TILE-SIZE-EXPR-FN LOCATION)  analysis/control.lisp
- - - - - - (%BUILD-EXACT-ITER-COUNT-FORM START-SYM STRIDE-SYM LEN-SYM CL-PKG)  analysis/control.lisp [See above]
- - - (%EXPAND-HARDWARE-STRIDE-OP FORM TYPE-RESOLVER-FN LOCATION)  macros.lisp
- - - - (%EXPAND-STRIDE-MACROS-IN-FORM FORM TYPE-RESOLVER-FN LOCATION)  macros.lisp [RECURSION]
- - - - (%TENSOR-STRIDE-RESOLVE-CT EXPR TYPE-RESOLVER-FN LOCATION)  macros.lisp [See above]
- - - - (%EXPAND-HARDWARE-STRIDE-FORM EXPR CT LOCATION)  analysis/control.lisp
- - - - - (%HARDWARE-STRIDE-PARSE EXPR)  analysis/control.lisp
- - - - - (%EXPAND-HW-WORKGROUP-IDX-FORM TENSOR-FORM BINDINGS BODY-FORMS LOCATION)  analysis/control.lisp
- - - - - - (%EXPAND-WORKGROUP-STRIDED-OUTER-LOOP-WITH-TS-SYMS TENSOR-FORM N BINDINGS BODY-FORMS TS-SYMS TILE-SIZE-EXPR-FN LOCATION)  analysis/control.lisp [See above]
- - - - - (%EXPAND-HW-WARP-IDX-FORM TENSOR-FORM BINDINGS BODY-FORMS LOCATION)  analysis/control.lisp
- - - - - - (%DETECT-BARE-LOAD-STORE-TILE-IN-FORM FORM PATH)  analysis/control.lisp
- - - - - - - (%DETECT-BARE-LOAD-STORE-TILE-IN-FORM FORM PATH)  analysis/control.lisp [RECURSION]
- - - - - - (%BUILD-EXACT-ITER-COUNT-FORM START-SYM STRIDE-SYM LEN-SYM CL-PKG)  analysis/control.lisp [See above]
- - - (%EXPAND-WORKGROUP-STRIDE-OP FORM TYPE-RESOLVER-FN LOCATION)  macros.lisp
- - - - (%EXPAND-STRIDE-MACROS-IN-FORM FORM TYPE-RESOLVER-FN LOCATION)  macros.lisp [RECURSION]
- - - - (%EXPAND-WORKGROUP-STRIDE-FORM EXPR LOCATION)  analysis/control.lisp
- - - - - (%WORKGROUP-STRIDE-PARSE EXPR)  analysis/control.lisp
- - - - - (%BUILD-EXACT-ITER-COUNT-FORM START-SYM STRIDE-SYM LEN-SYM CL-PKG)  analysis/control.lisp [See above]
- - - (%EXPAND-LET-STRIDE-OP FORM TYPE-RESOLVER-FN LOCATION)  macros.lisp
- - - - (%EXPAND-STRIDE-MACROS-IN-FORM FORM TYPE-RESOLVER-FN LOCATION)  macros.lisp [RECURSION]
- - (%COMPUTE-BACKWARD-KERNEL-PARAMS FLAT-INPUTS FLAT-INPUT-TYPES OUTPUTS OUTPUT-TYPES RECORD-SUBS-HT REC-GRAD-OUT-PARAMS REC-GRAD-OUT-TYPES PKG INPUTS)  macros.lisp
- - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - (%CRISP-FLOAT-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - (%CRISP-INTEGER-SCALAR-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - (%CRISP-FLOAT-TENSOR-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - (%CRISP-INTEGER-TENSOR-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - (%CRISP-RECORD-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - (%INTEGER-TENSOR-ELEM-TO-FLOAT TYPE-SPEC)  autodiff.lisp [See above]
- - - (%ENSURE-TENSOR-READ-WRITE TYPE-SPEC)  autodiff.lisp [See above]
- - - (%CRISP-INTEGER-CELL-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - (%INTEGER-CELL-ELEM-TO-FLOAT TYPE-SPEC)  autodiff.lisp [See above]
- - - (%INTEGER-SCALAR-TO-FLOAT-SCALAR TYPE-SPEC)  autodiff.lisp [See above]
- - - (%PROMOTE-TO-FLOAT-ADJOINT TYPE-SPEC)  autodiff.lisp [See above]
- - (%HAS-DIFF-CAPABLE-SCALAR-INPUT-P FLAT-INPUT-TYPES)  macros.lisp
- - - (%CRISP-INTEGER-SCALAR-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - (BRAND &REST ARGS)  macros.lisp [See above]
- - - (IS-BRAND-TYPE-P TYPE-NAME)  types/brand.lisp [See above]
- - (%EXPLODE-KERNEL-ARGS PARAMS SIGNATURE)  macros.lisp
- - - (%STORAGE-HANDLE-TYPE-P TYPE-SPEC)  macros.lisp [See above]
- - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - (MARSHALL-CELL TYPE-ALIAS BYTE-SIZE PTR OFFSET)  macros.lisp
- - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - (INSTANTIATE-TEMPLATE NAME-OR-TMPL CONCRETE-TYPES &OPTIONAL OVERRIDE-NAME)  templates.lisp [See above]
- - - (%MARSHALL-TENSOR TYPE-ALIAS BYTE-SIZE PTR &REST FLAT-ARGS)  macros.lisp
- - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - (INSTANTIATE-TEMPLATE NAME-OR-TMPL CONCRETE-TYPES &OPTIONAL OVERRIDE-NAME)  templates.lisp [See above]
- - (DEF-KERNEL-EXACT NAME PARAMS &REST BODY)  macros.lisp
- - - (STRICT-VALID-TYPE-P SPEC)  macros.lisp
- - - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - (%STORAGE-HANDLE-TYPE-P TYPE-SPEC)  macros.lisp [See above]
- - - (DEF-FUNCTION NAME PARAMS &REST BODY-AND-LOCATION)  macros.lisp [See above]
- - (FLATTEN-ANF-BODY ANF-BODY)  anf-transform.lisp [See above]
- - (%REGISTER-SHADOW-ANF-INTERMEDIATES FLAT-ANF SHADOW-HT)  autodiff.lisp
- - - (%NESTED-FIELD-INFO-P FIELD-INFO)  autodiff.lisp [See above]
- - (GENERATE-BACKWARD-WALK FLAT-ANF INPUTS OUTPUTS INPUT-TYPES OUTPUT-TYPES &KEY KERNEL-PKG)  autodiff.lisp
- - - (%CRISP-RECORD-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - (%CRISP-STRUCT-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - (%GET-RECORD-RUNTIME-FIELDS REC-TYPE-SPEC)  autodiff.lisp [See above]
- - - (%CRISP-FLOAT-TENSOR-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - (%AD-PROMOTES-TO-DOUBLE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - (%AD-ZERO DOUBLE-P)  autodiff.lisp
- - - (%SUBST-FORM FORM SUBST-ALIST)  autodiff.lisp
- - - - (%SUBST-FORM FORM SUBST-ALIST)  autodiff.lisp [RECURSION]
- - - (%REMOVE-FUNCALL FORM FN-PARAM-SYM CONCRETE-FN-SYM)  autodiff.lisp
- - - - (%REMOVE-FUNCALL FORM FN-PARAM-SYM CONCRETE-FN-SYM)  autodiff.lisp [RECURSION]
- - - (FLATTEN-ANF-BODY ANF-BODY)  anf-transform.lisp [See above]
- - - (%EXTRACT-RETURN-VARS FLAT-ANF)  autodiff.lisp [See above]
- - - (%HANDLE-SINGLE-VALUE-BACKWARD V EXPR ADJOINT-MAP EMIT-FN LOCAL-ADJ-FN &KEY HOF-HANDLER-FN (ERROR-ON-UNKNOWN
                                                                                                  T) TENSOR-INPUTS-HT SCRATCH-TILE-SYMS)  autodiff.lisp [See above]
- - - (%TLC-EXTRACT-TRANSPOSE-KEY KEY-ARGS)  autodiff.lisp
- - - (%TLC-BWD-ADJ-NAME SYM INPUTS OUTPUTS LOCAL-ADJ-FN KERNEL-PKG)  autodiff.lisp
- - - (%GFW-PROCESS-SET! FORM EMIT-FN LOCAL-ADJ-FN INPUTS OUTPUTS SCRATCH-TILE-SYMS INTERMEDIATE-ZERO KERNEL-PKG)  autodiff.lisp
- - - - (%TLC-BWD-ADJ-NAME SYM INPUTS OUTPUTS LOCAL-ADJ-FN KERNEL-PKG)  autodiff.lisp [See above]
- - - (%AUGMENT-SCRATCH-ADJ-BINDINGS BINDINGS KERNEL-PKG)  autodiff.lisp
- - - - (%PROMOTE-SCRATCH-INIT-FOR-AD INIT)  autodiff.lisp
- - - - - (%SCRATCH-TENSOR-CANONICAL-SPEC OP ARGS)  analysis/structs.lisp [See above]
- - - - - (%CRISP-INTEGER-SCALAR-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - - - (%INTEGER-SCALAR-TO-FLOAT-SCALAR TYPE-SPEC)  autodiff.lisp [See above]
- - - - - (%EXTRACT-SCRATCH-SIZE-EXPR OP ARGS)  analysis/structs.lisp [See above]
- - - (%GFW-PROCESS-LET FORM EMIT-FN PROCESS-FORM-FN BINDINGS AUGMENTED-BINDINGS BODY)  autodiff.lisp
- - - (%COLLECT-LOCALLY-BOUND-VARS BODY-FORMS)  autodiff.lisp
- - - (%GFW-PROCESS-DOTIMES FORM EMIT-FN PROCESS-FORM-FN BINDING BODY LOCAL-VARS ADJOINT-MAP INTERMEDIATE-ZERO)  autodiff.lisp
- - - (%GFW-PROCESS-IF FORM EMIT-FN PROCESS-FORM-FN COND-FORM THEN-FORM ELSE-FORM)  autodiff.lisp
- - - (%EMIT-FOREIGN-BACKWARD FN ARGS T-ADJ-FORMS PKG EMIT-FN LOCAL-ADJ-FN)  autodiff.lisp [See above]
- - - (%EMIT-SUB-FN-BACKWARD FN ARGS BKWD-FN T-ADJ-FORMS N-FP PKG EMIT-FN LOCAL-ADJ-FN &OPTIONAL (SYM-PREFIX
                                                                                                  BW))  autodiff.lisp [See above]
- - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - (%CRISP-INTEGER-TENSOR-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - (%CRISP-INTEGER-SCALAR-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - (%CRISP-FLOAT-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - (%PROMOTE-SCRATCH-INIT-FOR-AD INIT)  autodiff.lisp [See above]
- - (%FIX-RECORD-GRAD-CELL-EMISSIONS FORM GRAD-CELL-SYMS)  autodiff.lisp
- - - (%FIX-RECORD-GRAD-CELL-EMISSIONS FORM GRAD-CELL-SYMS)  autodiff.lisp [RECURSION]
- - (%COLLECT-ALL-LEAF-ADJ-SYMS FIELD-ADJ-ALIST)  autodiff.lisp
- - - (%NESTED-FIELD-INFO-P FIELD-INFO)  autodiff.lisp [See above]
- - - (%COLLECT-ALL-LEAF-ADJ-SYMS FIELD-ADJ-ALIST)  autodiff.lisp [RECURSION]
- - (%ENSURE-LEAF-ADJ-BINDINGS FORM LEAF-ADJ-SYMS)  autodiff.lisp
- - (%FIX-STRUCT-SHADOW-WRITES FORM STRUCT-SHADOW-INFO)  autodiff.lisp

- (%GENERATE-RAW-ACCESSOR MEMBER-SPEC NAME PKG RUNTIME-INDEX)  macros.lisp
- - (DEF-FUNCTION NAME PARAMS &REST BODY-AND-LOCATION)  macros.lisp [See above]

- (%GENERATE-STRUCT-ACCESSOR MEMBER-SPEC NAME PKG RUNTIME-INDEX)  macros.lisp
- - (%PARSE-CT-LITERAL VALUE)  macros.lisp
- - (DEF-FUNCTION NAME PARAMS &REST BODY-AND-LOCATION)  macros.lisp [See above]

- (%HAS-EXPLICIT-N ARGS)  autodiff.lisp
- - (%IS-TENSOR-ALIAS SYM)  autodiff.lisp
- - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]

- (%METACRISP-FIND-KERNEL FORMS KERNEL-NAME)  metadata-val.lisp
- - (%METACRISP-SECTION FORMS KEY)  metadata-val.lisp

- (%MV-SOURCE-ACCESS CANON)  analysis/structs.lisp
- - (%MV-SOURCE-HEAD CANON)  analysis/structs.lisp [See above]

- (%OPT-AVAILABLE-P)  compiler.lisp
- - (RESOLVE-TOOL-EXECUTABLE TOOL-BASE)  compiler.lisp [See above]

- (%PTX-ENTRY-DEMOTE-TYPE TY)  codegen.lisp
- - (LLVM-TYPE-KIND-IS-POINTER? TY) :CRISP.LLVM-BINDINGS  llvm-bindings.lisp [See above]
- - (%PTX-ENTRY-ILLEGAL-ADDRSPACE-P AS)  codegen.lisp [See above]

- (%RECORD-MEMBER-COUNT REC-FORM)  metadata-val.lisp

- (%RESOLVE-TO-BASE-TYPE-FOR-RECORDS PD-TYPE)  autodiff.lisp
- - (COMPUTE-BASE-TYPE ORIGINAL-TYPE-NAME)  types/hierarchy.lisp [See above]
- - (%CRISP-RECORD-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]

- (%REWRITE-BARE-LOAD-STORE-TILE-IN-BODY BODY-FORMS ORIGIN-BINDING-SYMS CL-PKG)  analysis/control.lisp
- - (%REWRITE-BARE-TILE-IN-FORM FORM ORIGIN-BINDING-SYMS CL-PKG)  analysis/control.lisp
- - - (%REWRITE-BARE-TILE-IN-FORM FORM ORIGIN-BINDING-SYMS CL-PKG)  analysis/control.lisp [RECURSION]

- (ADDRESS-SPACE-VALUE K)  enums.lisp
- - (ENCODE-ADDRESS-SPACE AS)  types/validation.lisp [See above]

- (ANALYZE-%LOAD-TILE-AT-BWD-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (%EXPAND-LOAD-TILE-AT-BWD-FORM EXPR LOCATION)  analysis/control.lisp
- - - (%EXTRACT-KEY-ARG KEY-ARGS KEYWORD DEFAULT)  analysis/control.lisp
- - - (%TLC-TRANSPOSE-PERMUTATION N TRANSPOSE-FORM LOCATION)  analysis/control.lisp
- - - (%TLC-SOURCE-COORD-EXPRS N ORIGIN-SYMS TILE-COORD-SYMS PERM PLUS-SYM)  analysis/control.lisp
- - - (%TLC-ALL-IN-BOUNDS-FORM N SRC-COORD-EXPRS GLOBAL-EXTENT-SYMS LT-SYM AND-SYM)  analysis/control.lisp
- - - (%TLC-COOP-LOOP-SKELETON N TILE-SYM LOCAL-BINDINGS TILE-COORD-SYMS TILE-EXTENT-SYMS LID-SYMS LWS-SYMS INNER-FORM CL-PKG)  analysis/control.lisp

- (ANALYZE-%MAKE-CT-ARRAY EXPR ENV CONTEXT LOCATION)  analysis/structs.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - (TYPES-EQUIVALENT-P T1 T2)  types/validation.lisp
- - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - (EXCLUDED-TEMPLATE-BASE-TYPE-P BASE-TYPE)  types/validation.lisp [See above]
- - - (COMPILE-TOPLEVEL-FORM FORM LOCATION MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)  analysis/core.lisp [See above]
- - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - (TYPES-EQUIVALENT-P T1 T2)  types/validation.lisp [RECURSION]
- - - (%TYPE-SPEC-EQUAL-P T1 T2)  types/validation.lisp
- - - - (%TYPE-SPEC-EQUAL-P T1 T2)  types/validation.lisp [RECURSION]
- - - - (%TYPE-ATOM-EQUAL-P A B)  types/validation.lisp
- - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]

- (ANALYZE-%STORE-TILE-AT-BWD-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (%EXPAND-STORE-TILE-AT-BWD-FORM EXPR LOCATION)  analysis/control.lisp
- - - (%EXTRACT-KEY-ARG KEY-ARGS KEYWORD DEFAULT)  analysis/control.lisp [See above]
- - - (%TLC-TRANSPOSE-PERMUTATION N TRANSPOSE-FORM LOCATION)  analysis/control.lisp [See above]
- - - (%TLC-SOURCE-COORD-EXPRS N ORIGIN-SYMS TILE-COORD-SYMS PERM PLUS-SYM)  analysis/control.lisp [See above]
- - - (%TLC-ALL-IN-BOUNDS-FORM N SRC-COORD-EXPRS GLOBAL-EXTENT-SYMS LT-SYM AND-SYM)  analysis/control.lisp [See above]
- - - (%TLC-COOP-LOOP-SKELETON N TILE-SYM LOCAL-BINDINGS TILE-COORD-SYMS TILE-EXTENT-SYMS LID-SYMS LWS-SYMS INNER-FORM CL-PKG)  analysis/control.lisp [See above]

- (ANALYZE-%UNIFORM-WHEN-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-%UNIFORM-IF-IMPL EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - - (TRY-CONSTANT-FOLD NODE)  analysis/ops.lisp
- - - - (TRY-CONSTANT-FOLD NODE)  analysis/ops.lisp [RECURSION]
- - - (ENSURE-BRANCH-COMPATIBILITY THEN-NODE ELSE-NODE LOCATION)  analysis/control.lisp
- - - - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - - - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]
- - - - (GET-PROMOTED-TYPE TYPE-A-NAME TYPE-B-NAME)  type-checker.lisp
- - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - - - (RESOLVE-DOMINANCE TYPE-A TYPE-B)  types/hierarchy.lisp
- - - - - - (IS-SUBSTITUTABLE-FOR? SOURCE-TYPE TARGET-TYPE)  types/hierarchy.lisp [See above]
- - - - - - (FIND-COMMON-PROMOTED-TYPE TYPE-A TYPE-B)  types/hierarchy.lisp
- - - - - - - (GET-REACHABLE-TYPES TYPE-NAME)  types/hierarchy.lisp
- - - - (CREATE-IMPLICIT-CAST NODE TARGET-TYPE LOCATION)  analysis/ops.lisp

- (ANALYZE-%VOLATILE-READ-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]

- (ANALYZE-AREF-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/structs.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - (GET-ARRAY-ELEMENT-TYPE TYPE)  analysis/structs.lisp
- - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - (UNMANGLE-TEMPLATE-STRUCT-NAME SYMBOL)  mangling.lisp [See above]
- - (FIND-VARIABLE-IN-ENV NAME ENV)  analysis/core.lisp [See above]
- - (%GET-TENSOR-ARITY TYPE)  analysis/structs.lisp
- - - (UNMANGLE-TEMPLATE-STRUCT-NAME SYMBOL)  mangling.lisp [See above]
- - (%GET-TENSOR-ALIGN TYPE)  analysis/structs.lisp
- - - (UNMANGLE-TEMPLATE-STRUCT-NAME SYMBOL)  mangling.lisp [See above]
- - (%BUILD-TENSOR-COMPACT-FLAT-INDEX-FORM TARGET-SYM INDEX-FORMS)  analysis/structs.lisp
- - (%BUILD-TENSOR-COMPACT-OFFSET-FLAT-INDEX-FORM TARGET-SYM INDEX-FORMS)  analysis/structs.lisp
- - (%BUILD-TENSOR-FLAT-INDEX-FORM TARGET-SYM INDEX-FORMS)  analysis/structs.lisp
- - (ANALYZE-FUNCTION-CALL OP EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]

- (ANALYZE-ATOMIC-ADD!-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/ops.lisp
- - (%ANALYZE-ATOMIC-RMW-EXPRESSION OP EXPR ENV CONTEXT LOCATION &KEY NO-DELTA)  analysis/ops.lisp
- - - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]

- (ANALYZE-ATOMIC-DEC!-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/ops.lisp
- - (%ANALYZE-ATOMIC-RMW-EXPRESSION OP EXPR ENV CONTEXT LOCATION &KEY NO-DELTA)  analysis/ops.lisp [See above]

- (ANALYZE-ATOMIC-INC!-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/ops.lisp
- - (%ANALYZE-ATOMIC-RMW-EXPRESSION OP EXPR ENV CONTEXT LOCATION &KEY NO-DELTA)  analysis/ops.lisp [See above]

- (ANALYZE-ATOMIC-MAX!-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/ops.lisp
- - (%ANALYZE-ATOMIC-RMW-EXPRESSION OP EXPR ENV CONTEXT LOCATION &KEY NO-DELTA)  analysis/ops.lisp [See above]

- (ANALYZE-ATOMIC-MIN!-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/ops.lisp
- - (%ANALYZE-ATOMIC-RMW-EXPRESSION OP EXPR ENV CONTEXT LOCATION &KEY NO-DELTA)  analysis/ops.lisp [See above]

- (ANALYZE-ATOMIC-SET!-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/ops.lisp
- - (%ANALYZE-ATOMIC-RMW-EXPRESSION OP EXPR ENV CONTEXT LOCATION &KEY NO-DELTA)  analysis/ops.lisp [See above]

- (ANALYZE-ATOMIC-SUB!-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/ops.lisp
- - (%ANALYZE-ATOMIC-RMW-EXPRESSION OP EXPR ENV CONTEXT LOCATION &KEY NO-DELTA)  analysis/ops.lisp [See above]

- (ANALYZE-ATOMIC-XCHG!-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/ops.lisp
- - (%ANALYZE-ATOMIC-RMW-EXPRESSION OP EXPR ENV CONTEXT LOCATION &KEY NO-DELTA)  analysis/ops.lisp [See above]

- (ANALYZE-AWAIT-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]

- (ANALYZE-BITCAST-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/ops.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]

- (ANALYZE-CAST-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/ops.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]

- (ANALYZE-COL-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/structs.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - (%083-REQUIRE-2D-TENSOR RAW-TYPE LOCATION)  analysis/structs.lisp
- - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - (UNMANGLE-TEMPLATE-STRUCT-NAME SYMBOL)  mangling.lisp [See above]
- - - (EXPAND-STORAGE-HANDLE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]

- (ANALYZE-COMPILER-NO-OP EXPR ENV CONTEXT LOCATION)  analysis/control.lisp

- (ANALYZE-CRISP-DVEC-LITERAL EXPR ENV CONTEXT LOCATION)  analysis/core.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (%DVEC-INFER-COMP-TYPE ELEM-NODE LOCATION)  analysis/core.lisp
- - - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - (%DVEC-ELEMENT-COMPATIBLE-P ELEM-TYPE COMP-TYPE)  analysis/core.lisp
- - - (%DVEC-INTEGRAL-TYPE-P TYPE-SYM)  analysis/core.lisp
- - - (%DVEC-FLOAT-TYPE-P TYPE-SYM)  analysis/core.lisp

- (ANALYZE-DEC!-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/ops.lisp

- (ANALYZE-DOTIMES+-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (CALCULATE-UNIFORMITY-STATE NODE ENV)  analysis/core.lisp [See above]
- - (ANALYZE-DOTIMES-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]
- - - (CALCULATE-UNIFORMITY-STATE NODE ENV)  analysis/core.lisp [See above]
- - - (ANALYZE-BODY-EXPRESSIONS BODY-LIST ENV CONTEXT LOCATION)  analysis/core.lisp [See above]

- (ANALYZE-DVEC-COMPONENT-REF EXPR ENV CONTEXT LOCATION)  analysis/core.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - (%DVEC-TYPE-LOOKUP TYPE-SYM)  analysis/core.lisp [See above]
- - (ANALYZE-FUNCTION-CALL OP EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (%DVEC-CHECK-CELL-WRITE-ACCESS AREF-NODE LOCATION)  analysis/core.lisp
- - - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]

- (ANALYZE-EVAL-WHEN EXPR ENV CONTEXT LOCATION)  analysis/control.lisp

- (ANALYZE-EXTRACT-STRUCT-MEMBER-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/structs.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - (LOOKUP-STRUCT-DEFINITION TYPE-NAME)  structs.lisp [See above]

- (ANALYZE-FUNCALL-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]

- (ANALYZE-FUNCTION-LITERAL EXPR ENV CONTEXT LOCATION)  analysis/control.lisp

- (ANALYZE-GENERIC-AS-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/ops.lisp
- - (IS-BRAND-TYPE-P TYPE-NAME)  types/brand.lisp [See above]
- - (FIND-BRAND-FOR-OWNER BRAND-NAME OWNER-TYPE)  types/brand.lisp [See above]
- - (BRAND-ACTIVE-P BRAND-DEF)  types/brand.lisp [See above]
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]

- (ANALYZE-GET-POINTER EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]

- (ANALYZE-GLOBAL-SCRATCH-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/structs.lisp
- - (EXPAND-STORAGE-HANDLE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - (VALID-PARAMETERIZED-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]

- (ANALYZE-GRID-STRIDE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (%EXPAND-GRID-STRIDE-FORM EXPR LOCATION)  analysis/control.lisp [See above]

- (ANALYZE-HARDWARE-STRIDE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (%HARDWARE-STRIDE-PARSE EXPR)  analysis/control.lisp [See above]
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - (%TENSOR-STRIDE-RESOLVE-CT EXPR TYPE-RESOLVER-FN LOCATION)  macros.lisp [See above]
- - (%TS-CANONICALIZE-TENSOR-TYPE RAW-TYPE)  analysis/control.lisp [See above]
- - (%EXPAND-HARDWARE-STRIDE-FORM EXPR CT LOCATION)  analysis/control.lisp [See above]

- (ANALYZE-INC!-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/ops.lisp

- (ANALYZE-INNER-DIMENSION EXPR ENV CONTEXT LOCATION)  mma.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]

- (ANALYZE-INSERT-STRUCT-MEMBER-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/structs.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - (LOOKUP-STRUCT-DEFINITION TYPE-NAME)  structs.lisp [See above]
- - (TYPES-COMPATIBLE-P ARG-TYPE PARAM-TYPE)  type-checker.lisp
- - - (TYPES-EQUIVALENT-P T1 T2)  types/validation.lisp [See above]
- - - (IS-SUBSTITUTABLE-FOR? SOURCE-TYPE TARGET-TYPE)  types/hierarchy.lisp [See above]
- - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - (UNMANGLE-TEMPLATE-STRUCT-NAME SYMBOL)  mangling.lisp [See above]

- (ANALYZE-IS-SET-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (FIND-VARIABLE-IN-ENV NAME ENV)  analysis/core.lisp [See above]

- (ANALYZE-LENGTH-TILDE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - (EXPAND-STORAGE-HANDLE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - (UNMANGLE-TEMPLATE-STRUCT-NAME SYMBOL)  mangling.lisp [See above]
- - (ANALYZE-FUNCTION-CALL OP EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]

- (ANALYZE-LET-WITH-TILE-EXPLOSION EXPR ENV CONTEXT LOCATION)  mma.lisp
- - (ANALYZE-LET-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - - (%STRIP-EXECUTION-CONTEXT-DECLARES BODY-FORMS)  analysis/control.lisp
- - - (%CHECK-CONTEXT-DECLARATIONS DECL-SPECS LOCATION)  analysis/control.lisp
- - - (%TO-UNIFORM-FORM-P FORM)  analysis/control.lisp
- - - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - - (CALCULATE-UNIFORMITY-STATE NODE ENV)  analysis/core.lisp [See above]
- - - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]
- - - (SEMANTIC-NODE-SOURCE-LOCATION NODE)  analysis/core.lisp [See above]
- - - (FIND-VARIABLE-IN-ENV NAME ENV)  analysis/core.lisp [See above]
- - - (ANALYZE-BODY-EXPRESSIONS BODY-LIST ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (%EXPLODE-REGISTER-TILES LET-EXPR &OPTIONAL LOCATION)  mma.lisp
- - - (%REGISTER-TILE-INIT-FORM-P FORM)  mma.lisp
- - - - (%HEAD-NAME-EQ HEAD NAME)  mma.lisp
- - - (%REGISTER-TILE-FIT-CHECK M N LOCATION)  mma.lisp
- - - - (ACTIVE-HARDWARE-PROFILE)  hardware-profile.lisp [See above]
- - - (%REGISTER-TILE-FRAG-SYMS VAR M N)  mma.lisp
- - - - (%FRAG-MN)  mma.lisp
- - - - - (%SPV-MMA-SHAPE)  mma.lisp [See above]

- (ANALYZE-LOAD-FRAGMENT-A EXPR ENV CONTEXT LOCATION)  mma.lisp
- - (%SPV-MMA-SHAPE)  mma.lisp [See above]
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (%COOP-LAYOUT-OF TENSOR-NODE)  mma.lisp
- - - (%GET-TENSOR-CT CANON)  analysis/structs.lisp [See above]
- - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]

- (ANALYZE-LOAD-FRAGMENT-B EXPR ENV CONTEXT LOCATION)  mma.lisp
- - (%SPV-MMA-SHAPE)  mma.lisp [See above]
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (%COOP-LAYOUT-OF TENSOR-NODE)  mma.lisp [See above]

- (ANALYZE-LOAD-LOCAL-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - (%TENSOR-TYPE-P TYPE)  analysis/structs.lisp
- - (%GET-TENSOR-ARITY TYPE)  analysis/structs.lisp [See above]
- - (ANALYZE-LOAD-TILE-AT-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - - (%TLC-CHECK-NOT-DIVERGENT OP-NAME LOCATION)  analysis/control.lisp [See above]
- - - (%EXTRACT-KEY-ARG KEY-ARGS KEYWORD DEFAULT)  analysis/control.lisp [See above]
- - - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - - (%EXPAND-LOAD-TILE-AT-FORM EXPR LOCATION)  analysis/control.lisp
- - - - (%EXTRACT-KEY-ARG KEY-ARGS KEYWORD DEFAULT)  analysis/control.lisp [See above]
- - - - (%TLC-TRANSPOSE-PERMUTATION N TRANSPOSE-FORM LOCATION)  analysis/control.lisp [See above]
- - - - (%TLC-SOURCE-COORD-EXPRS N ORIGIN-SYMS TILE-COORD-SYMS PERM PLUS-SYM)  analysis/control.lisp [See above]
- - - - (%TLC-ALL-IN-BOUNDS-FORM N SRC-COORD-EXPRS GLOBAL-EXTENT-SYMS LT-SYM AND-SYM)  analysis/control.lisp [See above]
- - - - (%TLC-COOP-LOOP-SKELETON N TILE-SYM LOCAL-BINDINGS TILE-COORD-SYMS TILE-EXTENT-SYMS LID-SYMS LWS-SYMS INNER-FORM CL-PKG)  analysis/control.lisp [See above]

- (ANALYZE-LOAD-TILE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-LOAD-TILE-AT-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp [See above]

- (ANALYZE-LOOP-VECTOR-STRIDE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (%EXPAND-LOOP-VECTOR-STRIDE-FORM EXPR LOCATION)  analysis/control.lisp [See above]

- (ANALYZE-MAKE-ASYNC-BARRIER-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-SCRATCH-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/structs.lisp
- - - (EXPAND-STORAGE-HANDLE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - (VALID-PARAMETERIZED-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]

- (ANALYZE-MAKE-C-HANDLE EXPR ENV CONTEXT LOCATION)  analysis/control.lisp

- (ANALYZE-MAKE-REGISTER-FRAGMENT EXPR ENV CONTEXT LOCATION)  mma.lisp
- - (%SPV-MMA-SHAPE)  mma.lisp [See above]
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]

- (ANALYZE-MAKE-REGISTER-TILE EXPR ENV CONTEXT LOCATION)  mma.lisp
- - (%ENSURE-REGISTER-TILE-TYPE M N)  mma.lisp
- - - (%REGISTER-TILE-TYPE-NAME M N)  mma.lisp
- - - (REGISTER-STRUCT-DEFINITION NAME MEMBERS &OPTIONAL (CATEGORY STRUCT))  structs.lisp [See above]
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]

- (ANALYZE-MAKE-VIEW-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/structs.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - (%MV-RESOLVE-SRC-TYPE SRC-TYPE)  analysis/core.lisp
- - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - (EXPAND-STORAGE-HANDLE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - (UNMANGLE-TEMPLATE-STRUCT-NAME SYMBOL)  mangling.lisp [See above]
- - (%MV-SOURCE-HEAD CANON)  analysis/structs.lisp [See above]
- - (%MV-PARSE-KWARGS KWARG-LIST)  analysis/structs.lisp
- - (%MV-EVAL-INTEGER FORM)  analysis/structs.lisp
- - (%MV-SOURCE-ADDR CANON)  analysis/structs.lisp [See above]
- - (%MV-CHECK-RESTRICTIONS OP SRC-CANON NEW-ELEM LOCATION)  analysis/structs.lisp
- - - (%MV-SOURCE-ELEM CANON)  analysis/structs.lisp
- - - (%MV-SOURCE-ALIGN CANON)  analysis/structs.lisp
- - - - (%MV-SOURCE-HEAD CANON)  analysis/structs.lisp [See above]
- - - (%MV-IS-STRUCT-ELEM ELEM-TYPE)  analysis/structs.lisp
- - (%MV-RESULT-CELL-TYPE NEW-ELEM ADDR)  analysis/structs.lisp
- - (%MV-SOURCE-ALIGN CANON)  analysis/structs.lisp [See above]
- - (%MV-RESULT-ALIGN SRC-ALIGN EXPLICIT-STRIDES-P COL-MAJOR-P)  analysis/structs.lisp
- - (%MV-RESULT-TENSOR-TYPE NEW-ELEM RANK ADDR ALIGN &OPTIONAL (CT LAST))  analysis/structs.lisp
- - (%MV-EVAL-LIST FORM)  analysis/structs.lisp
- - (%MV-COL-MAJOR-STRIDES EXTENTS)  analysis/structs.lisp
- - (%MV-ROW-MAJOR-STRIDES EXTENTS)  analysis/structs.lisp [See above]

- (ANALYZE-MMA-ACCUMULATE EXPR ENV CONTEXT LOCATION)  mma.lisp
- - (%SPV-MMA-SHAPE)  mma.lisp [See above]
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]

- (ANALYZE-MMA-ACCUMULATE-VIA-TILE EXPR ENV CONTEXT LOCATION)  mma.lisp
- - (%CHECK-MMA-SHAPE MMA-SHAPE LOCATION)  mma.lisp
- - - (ACTIVE-HARDWARE-PROFILE)  hardware-profile.lisp [See above]
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - (%REGISTER-TILE-TYPE-P TYPE-NAME)  mma.lisp

- (ANALYZE-NESTED-DEF-FUNCTION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (COMPILE-TOPLEVEL-FORM FORM LOCATION MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)  analysis/core.lisp [See above]

- (ANALYZE-OUTER-DIMENSIONS-EXPRESSION EXPR ENV CONTEXT LOCATION)  mma.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]

- (ANALYZE-PROGN-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (%STRIP-EXECUTION-CONTEXT-DECLARES BODY-FORMS)  analysis/control.lisp [See above]
- - (%CHECK-CONTEXT-DECLARATIONS DECL-SPECS LOCATION)  analysis/control.lisp [See above]
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]

- (ANALYZE-PROVABLY-DIVERGENT? EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (CALCULATE-UNIFORMITY-STATE NODE ENV)  analysis/core.lisp [See above]

- (ANALYZE-PROVABLY-UNIFORM? EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (CALCULATE-UNIFORMITY-STATE NODE ENV)  analysis/core.lisp [See above]

- (ANALYZE-QUOTE EXPR ENV CONTEXT LOCATION)  analysis/control.lisp

- (ANALYZE-REM-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/ops.lisp
- - (ANALYZE-MOD-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/ops.lisp
- - - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]

- (ANALYZE-RETURN-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - (SEMANTIC-NODE-SOURCE-LOCATION NODE)  analysis/core.lisp [See above]

- (ANALYZE-ROW-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/structs.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - (%083-REQUIRE-2D-TENSOR RAW-TYPE LOCATION)  analysis/structs.lisp [See above]

- (ANALYZE-SCRATCH-TENSOR-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/structs.lisp
- - (%SCRATCH-TENSOR-CANONICAL-SPEC OP ARGS)  analysis/structs.lisp [See above]
- - (%EXTRACT-SCRATCH-SIZE-EXPR OP ARGS)  analysis/structs.lisp [See above]
- - (VALID-PARAMETERIZED-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]

- (ANALYZE-SET!-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/structs.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (%ANALYZE-SET!-SIMPLE-VARIABLE TARGET-FORM VALUE-NODE ENV LOCATION)  analysis/structs.lisp
- - - (FIND-VARIABLE-IN-ENV NAME ENV)  analysis/core.lisp [See above]
- - - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - - (TYPES-COMPATIBLE-P ARG-TYPE PARAM-TYPE)  type-checker.lisp [See above]
- - - (CALCULATE-UNIFORMITY-STATE NODE ENV)  analysis/core.lisp [See above]
- - (%ANALYZE-SET!-CALL-ACCESSOR TARGET-FORM VALUE-NODE ENV CONTEXT LOCATION)  analysis/structs.lisp
- - - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - - (TYPES-LIST-COMPATIBLE-P ARG-TYPES PARAM-TYPES)  type-checker.lisp [See above]
- - - (ENSURE-TEMPLATE-INSTANTIATION NAME EXPLICIT-ARG-TYPES COMPILER-CALLBACK)  templates.lisp [See above]
- - - (%CHECK-AREF-BOUNDARY-MUTATION AREF-NODE LOCATION)  analysis/core.lisp
- - - (%ANALYZE-SET!-STRUCT-ACCESSOR OP ARG-NODES VALUE-NODE ENV CONTEXT LOCATION TARGET-FORM)  analysis/structs.lisp
- - - - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - - - (%CHECK-STRUCT-BOUNDARY-MUTATION STRUCT-NODE ENV CONTEXT LOCATION)  analysis/core.lisp
- - - - - (FIND-VARIABLE-IN-ENV NAME ENV)  analysis/core.lisp [See above]
- - - - (GET-STRUCT-MEMBER-INDEX STRUCT-TYPE-NAME MEMBER-NAME)  analysis/structs.lisp
- - - - - (GET-TYPE-BASE TYPE-NAME)  types/hierarchy.lisp [See above]
- - - - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - - (FIND-STRUCT-DEFINITION-BY-NAME NAME-OR-SYMBOL)  structs.lisp [See above]

- (ANALYZE-SIZEOF-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (PARSE-TYPE-SPECIFIER SPEC)  environment.lisp [See above]
- - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]

- (ANALYZE-STATIC-UNLESS-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-STATIC-IF-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - - (ANALYZE-IF-EXPRESSION-IMPL EXPR ENV CONTEXT LOCATION &KEY ENFORCE-CONSTANT)  analysis/control.lisp
- - - - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - - - (TRY-CONSTANT-FOLD NODE)  analysis/ops.lisp [See above]
- - - - (CALCULATE-UNIFORMITY-STATE NODE ENV)  analysis/core.lisp [See above]
- - - - (ENSURE-BRANCH-COMPATIBILITY THEN-NODE ELSE-NODE LOCATION)  analysis/control.lisp [See above]

- (ANALYZE-STATIC-WHEN-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-STATIC-IF-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp [See above]

- (ANALYZE-STORE-FRAGMENT EXPR ENV CONTEXT LOCATION)  mma.lisp
- - (%SPV-MMA-SHAPE)  mma.lisp [See above]
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (%COOP-LAYOUT-OF TENSOR-NODE)  mma.lisp [See above]

- (ANALYZE-STORE-GLOBAL-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - (%TENSOR-TYPE-P TYPE)  analysis/structs.lisp [See above]
- - (%GET-TENSOR-ARITY TYPE)  analysis/structs.lisp [See above]
- - (ANALYZE-STORE-TILE-AT-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - - (%TLC-CHECK-NOT-DIVERGENT OP-NAME LOCATION)  analysis/control.lisp [See above]
- - - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - - (%EXPAND-STORE-TILE-AT-FORM EXPR LOCATION)  analysis/control.lisp
- - - - (%EXTRACT-KEY-ARG KEY-ARGS KEYWORD DEFAULT)  analysis/control.lisp [See above]
- - - - (%TLC-TRANSPOSE-PERMUTATION N TRANSPOSE-FORM LOCATION)  analysis/control.lisp [See above]
- - - - (%TLC-SOURCE-COORD-EXPRS N ORIGIN-SYMS TILE-COORD-SYMS PERM PLUS-SYM)  analysis/control.lisp [See above]
- - - - (%TLC-ALL-IN-BOUNDS-FORM N SRC-COORD-EXPRS GLOBAL-EXTENT-SYMS LT-SYM AND-SYM)  analysis/control.lisp [See above]
- - - - (%TLC-COOP-LOOP-SKELETON N TILE-SYM LOCAL-BINDINGS TILE-COORD-SYMS TILE-EXTENT-SYMS LID-SYMS LWS-SYMS INNER-FORM CL-PKG)  analysis/control.lisp [See above]

- (ANALYZE-STORE-TILE-MMA EXPR ENV CONTEXT LOCATION)  mma.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - (%REGISTER-TILE-TYPE-P TYPE-NAME)  mma.lisp [See above]
- - (ANALYZE-STORE-TILE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - - (ANALYZE-STORE-TILE-AT-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp [See above]

- (ANALYZE-STRUCT-CONSTRUCTION EXPR ENV CONTEXT LOCATION)  analysis/structs.lisp
- - (LOOKUP-STRUCT-DEFINITION TYPE-NAME)  structs.lisp [See above]
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]
- - (TYPE-EQUAL-P T1 T2)  types/validation.lisp
- - - (TYPES-EQUIVALENT-P T1 T2)  types/validation.lisp [See above]
- - (IS-BRAND-TYPE-P TYPE-NAME)  types/brand.lisp [See above]
- - (NUMERIC-TYPE-CATEGORY TYPE-NAME)  analysis/structs.lisp
- - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - (GET-TYPE-BASE TYPE-NAME)  types/hierarchy.lisp [See above]

- (ANALYZE-TEMPLATE-INSTANTIATION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]

- (ANALYZE-TENSOR-STRIDE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - (%RESOLVE-TENSOR-FORM-CT TENSOR-FORM TYPE-RESOLVER-FN)  macros.lisp [See above]
- - (%TENSOR-STRIDE-RESOLVE-CT EXPR TYPE-RESOLVER-FN LOCATION)  macros.lisp [See above]
- - (%TS-CANONICALIZE-TENSOR-TYPE RAW-TYPE)  analysis/control.lisp [See above]
- - (%EXPAND-TENSOR-STRIDE-FORM EXPR CT LOCATION)  analysis/control.lisp [See above]

- (ANALYZE-TILE-STRIDE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (%TILE-STRIDE-PARSE EXPR)  analysis/control.lisp [See above]
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - (%TENSOR-STRIDE-RESOLVE-CT EXPR TYPE-RESOLVER-FN LOCATION)  macros.lisp [See above]
- - (%TS-CANONICALIZE-TENSOR-TYPE RAW-TYPE)  analysis/control.lisp [See above]
- - (%EXPAND-TILE-STRIDE-FORM EXPR CT LOCATION)  analysis/control.lisp [See above]

- (ANALYZE-TO-WARP-UNIFORM EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]

- (ANALYZE-TO-WORKGROUP-UNIFORM EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]

- (ANALYZE-TRANSPOSE-BANG-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/structs.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]

- (ANALYZE-TRANSPOSE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/structs.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - (%083-REQUIRE-2D-TENSOR RAW-TYPE LOCATION)  analysis/structs.lisp [See above]
- - (%GET-TENSOR-CT CANON)  analysis/structs.lisp [See above]

- (ANALYZE-TRUNCATE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/ops.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]

- (ANALYZE-UNIFORMITY-STATE EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (CALCULATE-UNIFORMITY-STATE NODE ENV)  analysis/core.lisp [See above]

- (ANALYZE-UNLESS+-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-IF+-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - - (TRY-CONSTANT-FOLD NODE)  analysis/ops.lisp [See above]
- - - (CALCULATE-UNIFORMITY-STATE NODE ENV)  analysis/core.lisp [See above]
- - - (ANALYZE-%UNIFORM-IF-IMPL EXPR ENV CONTEXT LOCATION)  analysis/control.lisp [See above]
- - (IF+ TEST THEN &OPTIONAL ELSE)  macros.lisp

- (ANALYZE-UNLESS-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-IF-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - - (ANALYZE-IF-EXPRESSION-IMPL EXPR ENV CONTEXT LOCATION &KEY ENFORCE-CONSTANT)  analysis/control.lisp [See above]

- (ANALYZE-VALUE-CAST-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/ops.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]

- (ANALYZE-WHEN+-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-IF+-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp [See above]
- - (IF+ TEST THEN &OPTIONAL ELSE)  macros.lisp [See above]

- (ANALYZE-WHEN-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-IF-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp [See above]

- (ANALYZE-WHILE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]
- - (ANALYZE-BODY-EXPRESSIONS BODY-LIST ENV CONTEXT LOCATION)  analysis/core.lisp [See above]

- (ANALYZE-WITH-PRECISION-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]

- (ANALYZE-WORKGROUP-STRIDE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (%WORKGROUP-STRIDE-PARSE EXPR)  analysis/control.lisp [See above]
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - (%TS-CANONICALIZE-TENSOR-TYPE RAW-TYPE)  analysis/control.lisp [See above]
- - (%EXPAND-WORKGROUP-STRIDE-FORM EXPR LOCATION)  analysis/control.lisp [See above]

- (ANF-TRANSFORM EXPR)  anf-transform.lisp
- - (%ANF-TRANSFORM EXPR)  anf-transform.lisp
- - - (ANF-NORMALIZE EXPR IS-NESTED?)  anf-transform.lisp
- - - - (ANF-IS-ATOMIC? EXPR)  anf-transform.lisp
- - - - (ANF-NORMALIZE EXPR IS-NESTED?)  anf-transform.lisp [RECURSION]
- - - - (ANF-FRESH-TEMP)  anf-transform.lisp
- - - - (%ANF-NORMALIZE-SET! EXPR IS-NESTED?)  anf-transform.lisp
- - - - - (ANF-NORMALIZE-PLACE PLACE)  anf-transform.lisp
- - - - - - (ANF-NORMALIZE-ARGS ARGS)  anf-transform.lisp
- - - - - - - (ANF-NORMALIZE EXPR IS-NESTED?)  anf-transform.lisp [RECURSION]
- - - - - - - (ANF-NORMALIZE-ARGS ARGS)  anf-transform.lisp [RECURSION]
- - - - - (ANF-NORMALIZE EXPR IS-NESTED?)  anf-transform.lisp [RECURSION]
- - - - - (ANF-FRESH-TEMP)  anf-transform.lisp [See above]
- - - - (%ANF-NORMALIZE-IF OP EXPR IS-NESTED?)  anf-transform.lisp
- - - - - (ANF-NORMALIZE EXPR IS-NESTED?)  anf-transform.lisp [RECURSION]
- - - - - (%ANF-TRANSFORM EXPR)  anf-transform.lisp [RECURSION]
- - - - - (ANF-FRESH-TEMP)  anf-transform.lisp [See above]
- - - - (%ANF-NORMALIZE-IF+ OP EXPR IS-NESTED?)  anf-transform.lisp
- - - - - (%ANF-TRANSFORM EXPR)  anf-transform.lisp [RECURSION]
- - - - - (ANF-FRESH-TEMP)  anf-transform.lisp [See above]
- - - - (%ANF-NORMALIZE-COND EXPR IS-NESTED?)  anf-transform.lisp
- - - - - (%ANF-TRANSFORM EXPR)  anf-transform.lisp [RECURSION]
- - - - - (ANF-FRESH-TEMP)  anf-transform.lisp [See above]
- - - - (%ANF-NORMALIZE-LET EXPR IS-NESTED?)  anf-transform.lisp
- - - - - (ANF-NORMALIZE EXPR IS-NESTED?)  anf-transform.lisp [RECURSION]
- - - - - (ANF-FRESH-TEMP)  anf-transform.lisp [See above]
- - - - (ANF-NORMALIZE-ARGS ARGS)  anf-transform.lisp [See above]
- - - - (%ANF-NORMALIZE-DOTIMES OP EXPR IS-NESTED?)  anf-transform.lisp
- - - - - (ANF-NORMALIZE EXPR IS-NESTED?)  anf-transform.lisp [RECURSION]
- - - - - (ANF-FRESH-TEMP)  anf-transform.lisp [See above]
- - - - (%ANF-NORMALIZE-WHILE OP EXPR IS-NESTED?)  anf-transform.lisp
- - - - - (ANF-NORMALIZE EXPR IS-NESTED?)  anf-transform.lisp [RECURSION]
- - - - - (ANF-FRESH-TEMP)  anf-transform.lisp [See above]
- - - - (%ANF-NORMALIZE-ATOMIC OP EXPR IS-NESTED?)  anf-transform.lisp
- - - - - (ANF-NORMALIZE-PLACE PLACE)  anf-transform.lisp [See above]
- - - - - (ANF-NORMALIZE-ARGS ARGS)  anf-transform.lisp [See above]
- - - - - (ANF-FRESH-TEMP)  anf-transform.lisp [See above]
- - - (%STRIP-CTX-DECLARES EXPR)  anf-transform.lisp

- (ANF-TRANSFORM-MODULE FORMS)  anf-transform.lisp
- - (WITH-TEMPLATE-TYPE PARAMS &BODY BODY)  templates.lisp

- (AWAIT BARRIER)  macros.lisp

- (BRAND-MEMBER-P MEMBER-TYPE)  types/brand.lisp
- - (IS-BRAND-TYPE-P TYPE-NAME)  types/brand.lisp [See above]
- - (BRAND-ACTIVE-P BRAND-DEF)  types/brand.lisp [See above]

- (C-T-ASSERT CONDITION MESSAGE)  macros.lisp

- (C-T-OUTPUT &REST ARGS)  macros.lisp
- - (COMPILER-NO-OP)  macros.lisp

- (COMPILE-CRISP-FORM-TO-IR-STRING CRISP-FORM &KEY (DEBUG-P NIL))  analysis/core.lisp
- - (GENERATE-LOCATION-MAP FORMS)  analysis/core.lisp [See above]
- - (GENERATE-LLVM-IR SEMANTIC-FUNCTION MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)  codegen.lisp [See above]

- (CREATE-NUMERIC-HIERARCHY TYPE-NAMES)  types/hierarchy.lisp

- (CREATE-ROOT-TYPE-NODE TYPE-NAME)  types/hierarchy.lisp

- (DEF-BINARY-MATH-ANALYZER NAME NODE-CONSTRUCTOR OP-STRING)  analysis/ops.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]

- (DEF-BINARY-MATH-CODEGEN NODE-TYPE INTRINSIC-NAME &OPTIONAL NATIVE-NAME LIBDEVICE-BASE LIBDEVICE-FAST-BASE)  codegen.lisp
- - (GENERATE-NODE-IR (NODE SEMANTIC-MMA-ACCUMULATE) BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP)  mma.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - (CRISP-TYPE-TO-LLVM-TYPE TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - (%MATH-CALL-NAME INTRINSIC-NAME NATIVE-NAME LIBDEVICE-BASE LIBDEVICE-FAST-BASE ARITY SIZE)  codegen.lisp
- - - (%LIBDEVICE-FN-NAME BASE F32-P)  codegen.lisp
- - - (%NATIVE-BUILTIN-MANGLED-NAME BASE-NAME ARITY)  codegen.lisp
- - (%APPLY-PRECISION-FMF INST)  codegen.lisp
- - (%ATTACH-DEBUG-LOC INST NODE MODULE DI-BUILDER DI-SCOPE LOCATION-MAP)  codegen.lisp [See above]

- (DEF-BINARY-OP-ANALYZER NAME NODE-CONSTRUCTOR OP-STRING)  analysis/ops.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]
- - (GET-PROMOTED-TYPE TYPE-A-NAME TYPE-B-NAME)  type-checker.lisp [See above]

- (DEF-BINARY-OP-CODEGEN NODE-TYPE INT-INST FLOAT-INST ACCESSOR-PREFIX)  codegen.lisp
- - (GENERATE-NODE-IR (NODE SEMANTIC-MMA-ACCUMULATE) BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP)  mma.lisp [See above]
- - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]
- - (EXTRACT-PRIMARY-VALUE BUILDER VALUE TYPE-SPEC)  codegen/abi.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - (BUILD-CAST-IF-NEEDED BUILDER MODULE FROM-VAL FROM-TYPE-NAME TO-TYPE-NAME)  codegen.lisp
- - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - (CRISP-TYPE-TO-LLVM-TYPE TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - - (GET-TYPE-CAT-SAFE TYPE-NAME TYPE-OBJ)  codegen.lisp
- - - (GET-TYPE-BASE TYPE-NAME)  types/hierarchy.lisp [See above]
- - (%APPLY-PRECISION-FMF INST)  codegen.lisp [See above]
- - (%ATTACH-DEBUG-LOC INST NODE MODULE DI-BUILDER DI-SCOPE LOCATION-MAP)  codegen.lisp [See above]

- (DEF-CAST-CODEGEN NODE-TYPE DOCSTRING ARG-ACCESSOR TYPE-ACCESSOR &BODY BODY)  codegen.lisp
- - (GENERATE-NODE-IR (NODE SEMANTIC-MMA-ACCUMULATE) BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP)  mma.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - (EXTRACT-PRIMARY-VALUE BUILDER VALUE TYPE-SPEC)  codegen/abi.lisp [See above]
- - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]
- - (CRISP-TYPE-TO-LLVM-TYPE TYPE-SPEC MODULE)  codegen/abi.lisp [See above]

- (DEF-COMPARISON-ANALYZER NAME NODE-CONSTRUCTOR OP-STRING)  analysis/ops.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]
- - (GET-PROMOTED-TYPE TYPE-A-NAME TYPE-B-NAME)  type-checker.lisp [See above]
- - (CREATE-IMPLICIT-CAST NODE TARGET-TYPE LOCATION)  analysis/ops.lisp [See above]

- (DEF-COMPARISON-CODEGEN TYPE-NAME INT-PRED FLOAT-PRED ACCESSOR-PREFIX)  codegen.lisp
- - (GENERATE-NODE-IR (NODE SEMANTIC-MMA-ACCUMULATE) BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP)  mma.lisp [See above]
- - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]
- - (EXTRACT-PRIMARY-VALUE BUILDER VALUE TYPE-SPEC)  codegen/abi.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]

- (DEF-DERIVED-TYPE NEW-NAME ORIGINAL-TYPE &KEY (SUBST NIL SUBST-P))  macros.lisp
- - (COMPUTE-BASE-TYPE ORIGINAL-TYPE-NAME)  types/hierarchy.lisp [See above]
- - (REGISTER-DERIVED-TYPE NEW-TYPE-NAME ORIGINAL-TYPE-NAME SUBST-MODE)  types/hierarchy.lisp [See above]

- (DEF-ENUMERATION NAME &REST SPECS)  enums.lisp

- (DEF-FOREIGN-FUNCTION C-NAME SIGNATURE &OPTIONAL BACKWARD-NAME)  macros.lisp
- - (REGISTER-FOREIGN-FUNCTION C-NAME SIGNATURE &OPTIONAL BACKWARD-NAME)  compiler.lisp
- - - (ANALYZE-RETURN-TYPE-FROM-SPEC FN-SPEC)  environment.lisp [See above]
- - - (PARSE-TYPE-SPECIFIER SPEC)  environment.lisp [See above]
- - - (%FOREIGN-C-NAME SYM)  macros.lisp
- - - (%REGISTER-FOREIGN-BACKWARD C-NAME PARAMS RETURN-TYPES BACKWARD-NAME)  compiler.lisp
- - - - (%FFI-ACTIVE-SCALAR-PARAM-P TYPE-SPEC)  compiler.lisp
- - - - - (%CRISP-FLOAT-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - - - (%CRISP-INTEGER-SCALAR-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - - (%FFI-POINTER-PARAM-P TYPE-SPEC)  compiler.lisp
- - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]

- (DEF-GRID-FUNCTION NAME PARAMS &REST BODY)  macros.lisp
- - (DEF-FUNCTION NAME PARAMS &REST BODY-AND-LOCATION)  macros.lisp [See above]

- (DEF-HARDWARE-PROFILE NAME &REST PROPLIST)  macros.lisp
- - (REGISTER-HARDWARE-PROFILE NAME PROPLIST)  hardware-profile.lisp
- - - (%HP-VALIDATE-VALUE PROFILE-NAME KEY TYPE RAW)  hardware-profile.lisp
- - - - (%HP-PARSE-SIZE V)  hardware-profile.lisp
- - - - (%HP-UNQUOTE V)  hardware-profile.lisp
- - - - (%HP-3-POS-INTS-P X)  hardware-profile.lisp

- (DEF-KERNEL NAME PARAMS &REST BODY)  macros.lisp
- - (PARSE-KERNEL-SIGNATURE NAME PARAMS BODY)  macros.lisp
- - - (%PARSE-KERNEL-TYPE-DECLARATIONS PARAMS DECLARATIONS)  macros.lisp
- - - - (STRICT-VALID-TYPE-P SPEC)  macros.lisp [See above]
- - - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - (%VALIDATE-KERNEL-PARAMETERS PARAMS TYPE-MAP NAME)  macros.lisp
- - - - (%INCOMPLETE-STORAGE-HANDLE-P TYPE-SPEC)  macros.lisp
- - - - - (%RESOLVE-ALIAS-STRICT SPEC)  macros.lisp
- - - - - - (%RESOLVE-ALIAS-STRICT-CHECKED SPEC SEEN)  macros.lisp
- - - - - - - (%RESOLVE-ALIAS-STRICT-CHECKED SPEC SEEN)  macros.lisp [RECURSION]
- - - - - (%STORAGE-HANDLE-TYPE-P TYPE-SPEC)  macros.lisp [See above]
- - - - - (EXPAND-STORAGE-HANDLE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - (INCOMPLETE-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - (%USER-RECORD-TYPE-P TYPE-SPEC)  metadata-val.lisp [See above]
- - - (%EXPLODE-KERNEL-ARGS PARAMS SIGNATURE)  macros.lisp [See above]
- - - (%CHECK-DIFFERENTIATE-KERNEL-SIGNATURE NAME SIGNATURE-TYPES DECLARATIONS)  macros.lisp
- - (DEF-KERNEL-EXACT NAME PARAMS &REST BODY)  macros.lisp [See above]

- (DEF-RECORD NAME &REST MEMBERS)  macros.lisp
- - (BRAND &REST ARGS)  macros.lisp [See above]
- - (REGISTER-BRAND-DEFINITION STRUCT-NAME BRAND-FORM)  types/brand.lisp [See above]
- - (REGISTER-STRUCT-DEFINITION NAME MEMBERS &OPTIONAL (CATEGORY STRUCT))  structs.lisp [See above]
- - (VALIDATE-AND-REORDER-STRUCT-ARGS STRUCT-NAME DEFINED-MEMBERS ARGS)  structs.lisp [See above]

- (DEF-SETTER NAME ARGS &BODY BODY)  macros.lisp
- - (DEF-FUNCTION NAME PARAMS &REST BODY-AND-LOCATION)  macros.lisp [See above]

- (DEF-TYPE NAME TYPE-SPEC)  macros.lisp
- - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]

- (DEF-UNARY-MATH-ANALYZER NAME NODE-CONSTRUCTOR OP-STRING)  analysis/ops.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]

- (DEF-UNARY-MATH-CODEGEN NODE-TYPE INTRINSIC-NAME &OPTIONAL NATIVE-NAME LIBDEVICE-BASE LIBDEVICE-FAST-BASE)  codegen.lisp
- - (GENERATE-NODE-IR (NODE SEMANTIC-MMA-ACCUMULATE) BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP)  mma.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - (CRISP-TYPE-TO-LLVM-TYPE TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - (%MATH-CALL-NAME INTRINSIC-NAME NATIVE-NAME LIBDEVICE-BASE LIBDEVICE-FAST-BASE ARITY SIZE)  codegen.lisp [See above]
- - (%APPLY-PRECISION-FMF INST)  codegen.lisp [See above]
- - (%ATTACH-DEBUG-LOC INST NODE MODULE DI-BUILDER DI-SCOPE LOCATION-MAP)  codegen.lisp [See above]

- (DEFINE-FORWARD-ONLY-VALIDATOR NAME ARGS &BODY BODY)  metadata-val.lisp

- (DUMP-ENV ENV &KEY (TITLE Environment Dump)) :CRISP.UTILS  utils.lisp

- (GENERATE-COMPARISON-IR BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP NODE OP-NODE-INT OP-NODE-FLOAT)  codegen.lisp
- - (GENERATE-NODE-IR (NODE SEMANTIC-MMA-ACCUMULATE) BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP)  mma.lisp [See above]
- - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]

- (GET-TEMPLATE-SIGNATURE NAME CONCRETE-TYPES)  templates.lisp

- (INITIALIZE-TEMPLATES)  templates.lisp

- (IS-ADDRESS-SPACE? X)  enums.lisp

- (LOAD-TILE SRC TILE GRID-LIST &REST KEY-ARGS)  macros.lisp

- (MAKE-ARRIVAL-SYNC COUNT)  macros.lisp
- - (MAKE-ARRIVAL-SYNC-HANDLE COUNTER COUNT)  macros.lisp

- (MAKE-ASYNC-BARRIER)  macros.lisp

- (MAKE-STRUCTURE-TEMPLATE-INSTANCE TEMPLATE-NAME CONCRETE-TYPES &REST CTOR-ARGS)  templates.lisp
- - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - (ENSURE-TEMPLATE-INSTANTIATION NAME EXPLICIT-ARG-TYPES COMPILER-CALLBACK)  templates.lisp [See above]
- - (COMPILE-TOPLEVEL-FORM FORM LOCATION MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)  analysis/core.lisp [See above]

- (MANGLE-PARAM-TYPE-NAME TYPE)  mangling.lisp

- (MANGLE-TYPE-SPEC TYPE-SPEC)  mangling.lisp

- (MARSHALL-MATRIX TYPE-ALIAS BYTE-SIZE PTR OFF_0 OFF_1 STR_0 STR_1 EXT_0 EXT_1 LENGTH)  macros.lisp
- - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - (%MARSHALL-TENSOR TYPE-ALIAS BYTE-SIZE PTR &REST FLAT-ARGS)  macros.lisp [See above]

- (MARSHALL-TENSOR TYPE-ALIAS BYTE-SIZE PTR &REST KWARGS)  macros.lisp
- - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - (%MARSHALL-TENSOR TYPE-ALIAS BYTE-SIZE PTR &REST FLAT-ARGS)  macros.lisp [See above]

- (MARSHALL-VECTOR TYPE-ALIAS BYTE-SIZE PTR OFF_0 STR_0 EXT_0 LENGTH)  macros.lisp
- - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - (%MARSHALL-TENSOR TYPE-ALIAS BYTE-SIZE PTR &REST FLAT-ARGS)  macros.lisp [See above]

- (PARSE-STRUCT-MEMBER-SPEC SPEC)  structs.lisp

- (PARSE-TEMPLATE-PARAMETER-SPEC PARAM)  types/validation.lisp

- (POSITION-TILE TILE PARENT GRID-LIST)  macros.lisp

- (POSITION-TILE-AT TILE PARENT GRID-LIST)  macros.lisp

- (PRINT-OBJECT (OBJ PARAMETER-DEF) STREAM) :COMMON-LISP  parameters.lisp

- (R-T-ASSERT-0 TEST &REST ARGS)  macros.lisp
- - (R-T-ASSERT TEST &REST ARGS)  macros.lisp

- (REGISTER-OVERLOAD ALIAS REAL-NAME)  environment.lisp

- (REORDER-TEMPLATE-ARGS-FROM-KEYWORDS ARGS PARAM-NAMES)  templates.lisp

- (SET-DERIVED ANCESTOR-TYPE DESCENDANT-TYPE)  macros.lisp
- - (REGISTER-SET-DERIVED ANCESTOR-TYPE-NAME DESCENDANT-TYPE-NAME)  types/hierarchy.lisp
- - - (GET-TYPE-BASE TYPE-NAME)  types/hierarchy.lisp [See above]
- - - (VALIDATE-SET-DERIVED-SHAPE ANCESTOR-STRUCT DESCENDANT-STRUCT ANCESTOR-NAME DESCENDANT-NAME)  types/hierarchy.lisp
- - - - (FLATTEN-STRUCT-DATA-MEMBERS STRUCT-DEF)  types/hierarchy.lisp
- - - - - (GET-NATIVE-SIZE TYPE-SPEC)  structs.lisp [See above]
- - - - - (GET-TYPE-BASE TYPE-NAME)  types/hierarchy.lisp [See above]
- - - - - (FLATTEN-STRUCT-DATA-MEMBERS STRUCT-DEF)  types/hierarchy.lisp [RECURSION]
- - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - (IS-SUBSTITUTABLE-FOR? SOURCE-TYPE TARGET-TYPE)  types/hierarchy.lisp [See above]

- (STORE-TILE TILE DEST GRID-LIST &REST KEY-ARGS)  macros.lisp

- (SYNC-ARRIVE HANDLE)  macros.lisp
- - (ARRIVAL-SYNC-HANDLE-COUNTER OBJ)  macros.lisp

- (SYNC-WAIT HANDLE)  macros.lisp
- - (ARRIVAL-SYNC-HANDLE-COUNTER OBJ)  macros.lisp [See above]
- - (ARRIVAL-SYNC-HANDLE-COUNT OBJ)  macros.lisp

- (TEMPLATE-INSTANTIATION FORM)  templates.lisp

- (TYPE-LISTS-EQUIVALENT-P L1 L2)  types/validation.lisp

- (TYPES-ASSIGNABLE-P SOURCE-TYPE TARGET-TYPE)  types/hierarchy.lisp
- - (TYPES-EQUIVALENT-P T1 T2)  types/validation.lisp [See above]
- - (IS-SUBSTITUTABLE-FOR? SOURCE-TYPE TARGET-TYPE)  types/hierarchy.lisp [See above]

- (VALIDATE-01-ALIASES METADATA-PATH)  metadata.lisp
- - (VALIDATE-METADATA-DEF-TYPE METADATA-PATH TYPE-NAME TARGET-TYPE)  metadata.lisp

- (VALIDATE-04-BASIC-STRUCT METADATA-PATH)  metadata.lisp
- - (VALIDATE-STRUCT-PRESENCE METADATA-PATH EXPECTED-STRUCTS &KEY (UNEXPECTED-STRUCTS
                                                                   NIL))  metadata.lisp

- (VALIDATE-06-NESTED-STRUCTS METADATA-PATH)  metadata.lisp
- - (VALIDATE-STRUCT-PRESENCE METADATA-PATH EXPECTED-STRUCTS &KEY (UNEXPECTED-STRUCTS
                                                                   NIL))  metadata.lisp [See above]

- (VALIDATE-071-01-COMPACT-VECTOR-GET-IR IR-PATH)  metadata-val.lisp
- - (%071-KERNEL-BODY IR FUNCTION-NAME)  metadata-val.lisp
- - (%071-HAS-STRIDE-MUL BODY)  metadata-val.lisp
- - (%072-HAS-OFFSET-LOAD BODY)  metadata-val.lisp

- (VALIDATE-071-02-COMPACT-VECTOR-SET-IR IR-PATH)  metadata-val.lisp
- - (%071-KERNEL-BODY IR FUNCTION-NAME)  metadata-val.lisp [See above]
- - (%071-HAS-STRIDE-MUL BODY)  metadata-val.lisp [See above]
- - (%072-HAS-OFFSET-LOAD BODY)  metadata-val.lisp [See above]

- (VALIDATE-071-03-COMPACT-MATRIX-GET-IR IR-PATH)  metadata-val.lisp
- - (%071-KERNEL-BODY IR FUNCTION-NAME)  metadata-val.lisp [See above]
- - (%071-HAS-STRIDE-MUL BODY)  metadata-val.lisp [See above]

- (VALIDATE-071-05-STRIDED-VECTOR-IR IR-PATH)  metadata-val.lisp
- - (%071-KERNEL-BODY IR FUNCTION-NAME)  metadata-val.lisp [See above]
- - (%071-HAS-STRIDE-MUL BODY)  metadata-val.lisp [See above]

- (VALIDATE-072-01-COMPACT-OFFSET-VECTOR-GET-IR IR-PATH)  metadata-val.lisp
- - (%071-KERNEL-BODY IR FUNCTION-NAME)  metadata-val.lisp [See above]
- - (%071-HAS-STRIDE-MUL BODY)  metadata-val.lisp [See above]
- - (%072-HAS-OFFSET-LOAD BODY)  metadata-val.lisp [See above]

- (VALIDATE-072-02-COMPACT-OFFSET-VECTOR-SET-IR IR-PATH)  metadata-val.lisp
- - (%071-KERNEL-BODY IR FUNCTION-NAME)  metadata-val.lisp [See above]
- - (%071-HAS-STRIDE-MUL BODY)  metadata-val.lisp [See above]
- - (%072-HAS-OFFSET-LOAD BODY)  metadata-val.lisp [See above]

- (VALIDATE-072-04-COMPACT-NO-OFFSET-IR IR-PATH)  metadata-val.lisp
- - (%071-KERNEL-BODY IR FUNCTION-NAME)  metadata-val.lisp [See above]
- - (%071-HAS-STRIDE-MUL BODY)  metadata-val.lisp [See above]
- - (%072-HAS-OFFSET-LOAD BODY)  metadata-val.lisp [See above]

- (VALIDATE-074-02-SCRATCH-VECTOR-PROPAGATION-IR IR-PATH)  metadata-val.lisp
- - (%074-COUNT-KERNEL-PARAMS IR KERNEL-NAME)  metadata-val.lisp

- (VALIDATE-074-03-SCRATCH-TENSOR-PROPAGATION-IR IR-PATH)  metadata-val.lisp
- - (%074-COUNT-KERNEL-PARAMS IR KERNEL-NAME)  metadata-val.lisp [See above]

- (VALIDATE-074-04-SCRATCH-MATRIX-PROPAGATION-IR IR-PATH)  metadata-val.lisp
- - (%074-COUNT-KERNEL-PARAMS IR KERNEL-NAME)  metadata-val.lisp [See above]

- (VALIDATE-075-01-SCRATCH-VECTOR-IMPLICIT-META META-PATH)  metadata-val.lisp
- - (%075-FIND-KERNEL METACRISP-PATH KERNEL-NAME)  metadata-val.lisp
- - (%075-VALIDATE-TENSOR-IMPLICIT TAG K-DEF EXPECTED-TYPE-HEAD EXPECTED-N EXPECTED-SLOTS EXPECTED-ADDR-SPACE EXPECTED-SIZE-EXPR)  metadata-val.lisp

- (VALIDATE-075-02-SCRATCH-TENSOR-N3-IMPLICIT-META META-PATH)  metadata-val.lisp
- - (%075-FIND-KERNEL METACRISP-PATH KERNEL-NAME)  metadata-val.lisp [See above]
- - (%075-VALIDATE-TENSOR-IMPLICIT TAG K-DEF EXPECTED-TYPE-HEAD EXPECTED-N EXPECTED-SLOTS EXPECTED-ADDR-SPACE EXPECTED-SIZE-EXPR)  metadata-val.lisp [See above]

- (VALIDATE-075-03-SCRATCH-MATRIX-IMPLICIT-META META-PATH)  metadata-val.lisp
- - (%075-FIND-KERNEL METACRISP-PATH KERNEL-NAME)  metadata-val.lisp [See above]
- - (%075-VALIDATE-TENSOR-IMPLICIT TAG K-DEF EXPECTED-TYPE-HEAD EXPECTED-N EXPECTED-SLOTS EXPECTED-ADDR-SPACE EXPECTED-SIZE-EXPR)  metadata-val.lisp [See above]

- (VALIDATE-10-BASICS-META PATH)  metadata-val.lisp
- - (VALIDATE-KERNEL-METADATA METADATA-PATH KERNEL-NAME &KEY (TARGETS NIL
                                                              TARGETS-P))  metadata-val.lisp

- (VALIDATE-10-BASICS-MULTI PATH)  metadata-val.lisp
- - (VALIDATE-KERNEL-METADATA METADATA-PATH KERNEL-NAME &KEY (TARGETS NIL
                                                              TARGETS-P))  metadata-val.lisp [See above]

- (VALIDATE-10-BASICS-SPV PATH)  metadata-val.lisp
- - (VALIDATE-KERNEL-METADATA METADATA-PATH KERNEL-NAME &KEY (TARGETS NIL
                                                              TARGETS-P))  metadata-val.lisp [See above]

- (VALIDATE-12-MULTIPLE-KERNELS PATHS)  metadata-val.lisp
- - (VALIDATE-KERNEL-METADATA METADATA-PATH KERNEL-NAME &KEY (TARGETS NIL
                                                              TARGETS-P))  metadata-val.lisp [See above]

- (VALIDATE-14-PHYSICAL-SIGNATURE PATHS)  metadata.lisp

- (VALIDATE-ADDITION-CHAIN-RULE IR-PATH)  metadata-val.lisp
- - (VALIDATE-GENERIC-GRAD-SIGNATURE IR-PATH FORWARD-NAME EXPECTED-COMMAS)  metadata-val.lisp

- (VALIDATE-ANCESTOR-DISTANCE IR-PATH)  metadata-val.lisp
- - (%EXTRACT-FN-BODY-FROM-IR IR-CONTENT FN-DEFINE-PREFIX)  metadata-val.lisp
- - (COUNT-SUBSTRING NEEDLE HAYSTACK)  metadata-val.lisp

- (VALIDATE-ATOMICRMW-ADD IR-PATH)  metadata-val.lisp

- (VALIDATE-ATOMICRMW-FADD IR-PATH)  metadata-val.lisp

- (VALIDATE-ATOMICRMW-MAX IR-PATH)  metadata-val.lisp

- (VALIDATE-ATOMICRMW-MIN IR-PATH)  metadata-val.lisp

- (VALIDATE-ATOMICRMW-SUB IR-PATH)  metadata-val.lisp

- (VALIDATE-ATOMICRMW-XCHG IR-PATH)  metadata-val.lisp

- (VALIDATE-BASIC-GRAD-SIGNATURE IR-PATH)  metadata-val.lisp
- - (VALIDATE-GENERIC-GRAD-SIGNATURE IR-PATH FORWARD-NAME EXPECTED-COMMAS)  metadata-val.lisp [See above]

- (VALIDATE-C-STYLE-NAME-IR IR-PATH)  metadata-val.lisp
- - (VALIDATE-KERNEL-NAME-EXACT-IR IR-PATH EXPECTED-NAME)  metadata-val.lisp

- (VALIDATE-CALL-FUNCTION-F-IR IR-PATH)  metadata-val.lisp
- - (VALIDATE-KERNEL-NAME-EXACT-IR IR-PATH EXPECTED-NAME)  metadata-val.lisp [See above]

- (VALIDATE-CALL-FUNCTION-IR IR-PATH)  metadata-val.lisp
- - (VALIDATE-KERNEL-NAME-EXACT-IR IR-PATH EXPECTED-NAME)  metadata-val.lisp [See above]

- (VALIDATE-CELL-ADD-F-IR IR-PATH)  metadata-val.lisp
- - (VALIDATE-KERNEL-NAME-EXACT-IR IR-PATH EXPECTED-NAME)  metadata-val.lisp [See above]

- (VALIDATE-CELL-ADD-I-IR IR-PATH)  metadata-val.lisp
- - (VALIDATE-KERNEL-NAME-EXACT-IR IR-PATH EXPECTED-NAME)  metadata-val.lisp [See above]

- (VALIDATE-DEF-RECORD-EXPLODE-IR IR-PATH)  metadata-val.lisp

- (VALIDATE-DEF-RECORD-EXPLOSION METADATA-PATH)  metadata-val.lisp

- (VALIDATE-DEF-RECORD-EXPLOSION-IR IR-PATH)  metadata-val.lisp

- (VALIDATE-DERIVED-ACCESSORS IR-PATH)  metadata-val.lisp

- (VALIDATE-DESCENDANT-DISTANCE IR-PATH)  metadata-val.lisp
- - (%EXTRACT-FN-BODY-FROM-IR IR-CONTENT FN-DEFINE-PREFIX)  metadata-val.lisp [See above]
- - (COUNT-SUBSTRING NEEDLE HAYSTACK)  metadata-val.lisp [See above]

- (VALIDATE-DIVISION-CHAIN-RULE IR-PATH)  metadata-val.lisp
- - (VALIDATE-GENERIC-GRAD-SIGNATURE IR-PATH FORWARD-NAME EXPECTED-COMMAS)  metadata-val.lisp [See above]

- (VALIDATE-FLOAT-LITERALS-IR IR-PATH)  metadata-val.lisp

- (VALIDATE-INTEGER-LITERALS-IR IR-PATH)  metadata-val.lisp

- (VALIDATE-MAT-BASIC-SUB-GRAD IR-PATH)  metadata-val.lisp

- (VALIDATE-MATRIX-ADD-GRAD IR-PATH)  metadata-val.lisp

- (VALIDATE-MULTIPLE-SCRATCH-CELLS METADATA-PATH)  metadata-val.lisp

- (VALIDATE-MULTIPLY-CHAIN-RULE IR-PATH)  metadata-val.lisp
- - (VALIDATE-GENERIC-GRAD-SIGNATURE IR-PATH FORWARD-NAME EXPECTED-COMMAS)  metadata-val.lisp [See above]

- (VALIDATE-MULTIPLY-GRAD-METADATA PATHS)  metadata-val.lisp

- (VALIDATE-MY-KERNEL-SCRATCH-IR IR-PATH)  metadata-val.lisp

- (VALIDATE-NESTED-CHAIN-RULE IR-PATH)  metadata-val.lisp
- - (VALIDATE-GENERIC-GRAD-SIGNATURE IR-PATH FORWARD-NAME EXPECTED-COMMAS)  metadata-val.lisp [See above]

- (VALIDATE-NO-SROA-GRAD-LEAK METADATA-PATH)  metadata-val.lisp
- - (%READ-METACRISP-FORMS PATH)  metadata-val.lisp
- - (%METACRISP-SECTION FORMS KEY)  metadata-val.lisp [See above]
- - (%ENDS-WITH-GRAD-P NAME)  metadata-val.lisp
- - (%STRIP-GRAD-SUFFIX NAME)  metadata-val.lisp
- - (%FIND-DECL-ENTRY DECL-SIG NAME)  metadata-val.lisp

- (VALIDATE-NO-SUBST-OVERLOADS IR-PATH)  metadata-val.lisp

- (VALIDATE-POINT-IN-METADATA METADATA-PATH)  metadata-val.lisp

- (VALIDATE-REC-KB-BASIC IR-PATH)  metadata-val.lisp
- - (VALIDATE-GENERIC-GRAD-SIGNATURE IR-PATH FORWARD-NAME EXPECTED-COMMAS)  metadata-val.lisp [See above]

- (VALIDATE-REC-KB-CT-PROP IR-PATH)  metadata-val.lisp
- - (VALIDATE-GENERIC-GRAD-SIGNATURE IR-PATH FORWARD-NAME EXPECTED-COMMAS)  metadata-val.lisp [See above]

- (VALIDATE-REC-KB-NON-OVERLOADABLE IR-PATH)  metadata-val.lisp
- - (VALIDATE-GENERIC-GRAD-SIGNATURE IR-PATH FORWARD-NAME EXPECTED-COMMAS)  metadata-val.lisp [See above]

- (VALIDATE-REC-KB-NOT-FLOAT IR-PATH)  metadata-val.lisp
- - (VALIDATE-GENERIC-GRAD-SIGNATURE IR-PATH FORWARD-NAME EXPECTED-COMMAS)  metadata-val.lisp [See above]

- (VALIDATE-REC-KB-UNUSED-FIELD IR-PATH)  metadata-val.lisp
- - (VALIDATE-GENERIC-GRAD-SIGNATURE IR-PATH FORWARD-NAME EXPECTED-COMMAS)  metadata-val.lisp [See above]

- (VALIDATE-RECORD-GRAD-METADATA PATHS)  metadata-val.lisp

- (VALIDATE-RETURN-7-IR IR-PATH)  metadata-val.lisp
- - (VALIDATE-KERNEL-NAME-EXACT-IR IR-PATH EXPECTED-NAME)  metadata-val.lisp [See above]

- (VALIDATE-SCRATCH-CELL-EXPLOSION METADATA-PATH)  metadata-val.lisp

- (VALIDATE-SCRATCH-CELL-EXPLOSION-IR IR-PATH)  metadata-val.lisp

- (VALIDATE-SUBTRACTION-CHAIN-RULE IR-PATH)  metadata-val.lisp
- - (VALIDATE-GENERIC-GRAD-SIGNATURE IR-PATH FORWARD-NAME EXPECTED-COMMAS)  metadata-val.lisp [See above]

- (VALIDATE-TENSOR-AD-ATOMIC IR-PATH)  metadata-val.lisp

- (VALIDATE-TENSOR-ADD-GRAD IR-PATH)  metadata-val.lisp

- (VALIDATE-TENSOR-BASIC-SUB-GRAD IR-PATH)  metadata-val.lisp

- (VALIDATE-TOP-KERNEL-4-ARGS-IR IR-PATH)  metadata-val.lisp

- (VALIDATE-TRANSCENDENTAL-CHAIN-RULE IR-PATH)  metadata-val.lisp
- - (VALIDATE-GENERIC-GRAD-SIGNATURE IR-PATH FORWARD-NAME EXPECTED-COMMAS)  metadata-val.lisp [See above]

- (VALIDATE-VEC-ADD-GRAD IR-PATH)  metadata-val.lisp

- (VALIDATE-VEC-BASIC-SUB-GRAD IR-PATH)  metadata-val.lisp

- (VALIDATE-VEC-CHAIN-DEPTH-GRAD IR-PATH)  metadata-val.lisp

- (VALIDATE-VEC-FAN-OUT-SUB-GRAD IR-PATH)  metadata-val.lisp

- (VALIDATE-VEC-MIXED-GRAD IR-PATH)  metadata-val.lisp

- (VALIDATE-VEC-MIXED-SUB-GRAD IR-PATH)  metadata-val.lisp

- (VALIDATE-VEC-MULTIPLY-GRAD IR-PATH)  metadata-val.lisp

- (VALIDATE-VEC-MVB-SUB-GRAD IR-PATH)  metadata-val.lisp

- (VALIDATE-VEC-TRANSCENDENTAL-GRAD IR-PATH)  metadata-val.lisp

- (WITH-STRUCT-ACCESSORS STRUCT-TYPE BINDINGS &BODY BODY)  macros.lisp

