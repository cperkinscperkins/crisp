# Application Call Graph

This graph shows the hierarchy of internal function calls.
Entries without a package name are in :CRISP.COMPILER.
Nodes marked `[RECURSION]` indicate a cycle.
Nodes marked `[See above]` have been expanded previously in the document.

## Roots (Entry Points & Unused Functions)
- (MAIN) :CRISP.MAIN  main.lisp
- - (PARSE-CLI-ARGS ARGS) :CRISP.MAIN  main.lisp
- - - (INITIALIZE-COMPILER &KEY (LOG-LEVEL OFF) (RUNTIME-CHECKS NIL) (DIFFERENTIATE
                                                                      NIL))  compiler.lisp
- - - - (INITIALIZE-CRISP-TYPES)  types/registry.lisp
- - - - (INITIALIZE-TYPE-HIERARCHY)  types/hierarchy.lisp
- - - - (INITIALIZE-EXPRESSION-ANALYZERS)  analysis/core.lisp
- - - - - (REGISTER-OPS-ANALYZERS)  analysis/ops.lisp
- - - - - - (DEF-EXPRESSION-ANALYZER OPERATOR HANDLER-FN)  types/registry.lisp
- - - - - (REGISTER-CONTROL-ANALYZERS)  analysis/control.lisp
- - - - - - (DEF-EXPRESSION-ANALYZER OPERATOR HANDLER-FN)  types/registry.lisp [See above]
- - - - - (REGISTER-STRUCT-ANALYZERS)  analysis/structs.lisp
- - - - - - (DEF-EXPRESSION-ANALYZER OPERATOR HANDLER-FN)  types/registry.lisp [See above]
- - - - (INITIALIZE-ADVISEMENTS) :CRISP.UTILS  utils.lisp
- - - - - (ADVISE-FUNCTION FN-SYMBOL) :CRISP.UTILS  utils.lisp
- - - - (REGISTER-BUILTINS)  compiler.lisp
- - - - - (REGISTER-TEMPLATE NAME PARAMS CONSTRAINTS BODY SIGNATURE)  templates.lisp
- - (COMPILE-FILES FILES OUTPUT-FILE DEBUG-P SINGLE-PASS-P TARGETS METADATA-P HOIST-TARGETS) :CRISP.MAIN  main.lisp
- - - (INITIALIZE-DEBUG-CONTEXT MODULE DI-BUILDER FILEPATH) :CRISP.MAIN  main.lisp
- - - (COMPILE-TOPLEVEL-FORM FORM LOCATION MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)  analysis/core.lisp
- - - - (VISIT-TOPLEVEL-FORM FORM LOCATION VISITOR-FN)  analysis/core.lisp
- - - - - (VISIT-TOPLEVEL-FORM FORM LOCATION VISITOR-FN)  analysis/core.lisp [RECURSION]
- - - - (COMPILE-DEF-FUNCTION FORM LOCATION MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)  analysis/core.lisp
- - - - - (REGISTER-FUNCTION-SIGNATURE FORM LOCATION)  environment.lisp
- - - - - - (PARSE-FUNCTION-DECLARATIONS PARAMS DECLARATIONS)  environment.lisp
- - - - - - - (ANALYZE-RETURN-TYPE-FROM-SPEC FN-SPEC)  environment.lisp
- - - - - - - - (PARSE-TYPE-SPECIFIER SPEC)  environment.lisp
- - - - - - - - - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp
- - - - - - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp
- - - - - - - - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp
- - - - - - - - - - (VALID-BASIC-TYPE-P TYPE-SPEC)  types/validation.lisp
- - - - - - - - - - (VALID-FUNCTION-TYPE-P TYPE-SPEC)  types/validation.lisp
- - - - - - - - - - (VALID-PARAMETERIZED-TYPE-P TYPE-SPEC)  types/validation.lisp
- - - - - - - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp
- - - - - - - - - - - - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - (EXPAND-STORAGE-HANDLE-TYPE-SPECIFIER SPEC)  types/validation.lisp
- - - - - - - - - - - - - (%BARE-STORAGE-HANDLE-VALUE-ERROR ITEM SPEC)  types/validation.lisp
- - - - - - - - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [RECURSION]
- - - - - - - - - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - (EXTRACT-POSITIONAL-FROM-KEYWORD-ARGS ARGS NUM-PARAMS)  types/validation.lisp
- - - - - - - - - - - - (VALIDATE-TEMPLATE-ARG ARG TYPE NAME)  types/validation.lisp
- - - - - - - - - - - (EXCLUDED-TEMPLATE-BASE-TYPE-P BASE-TYPE)  types/validation.lisp
- - - - - - - - - - - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - (VALID-BASIC-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - (%VALIDATE-TEMPLATE-INSTANTIATION BASE-TYPE TEMPLATE-ARGS)  types/validation.lisp
- - - - - - - - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp
- - - - - - - - - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [RECURSION]
- - - - - - - - - - - - (%INSTANTIATE-TEMPLATE-IF-NEEDED BASE-TYPE TEMPLATE-ARGS MANGLED-NAME)  types/validation.lisp
- - - - - - - - - - - - - (COMPILE-TOPLEVEL-FORM FORM LOCATION MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)  analysis/core.lisp [RECURSION]
- - - - - - - - - (PARSE-TYPE-SPECIFIER SPEC)  environment.lisp [RECURSION]
- - - - - - - - - (IS-BRAND-TYPE-P TYPE-NAME)  types/brand.lisp
- - - - - - - - - - (IS-BRAND-TYPE-P TYPE-NAME)  types/brand.lisp [RECURSION]
- - - - - - - - - (BRAND-ACTIVE-P BRAND-DEF)  types/brand.lisp
- - - - - - - - - (EXPAND-STORAGE-HANDLE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - - - - - - (VALID-FUNCTION-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - (GET-TEMPLATE-ARITY NAME)  types/validation.lisp
- - - - - - - - - (EXTRACT-POSITIONAL-FROM-KEYWORD-ARGS ARGS NUM-PARAMS)  types/validation.lisp [See above]
- - - - - - - (ANALYZE-RETURN-TYPE-FROM-LIST DECLARATIONS)  environment.lisp
- - - - - - - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - (ANALYZE-ENVIRONMENT-FROM-SPEC PARAMS FN-SPEC)  environment.lisp
- - - - - - - - (PARSE-TYPE-SPECIFIER SPEC)  environment.lisp [See above]
- - - - - - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - (PARSE-TYPE-SPECIFIER SPEC)  environment.lisp [See above]
- - - - - - - (ANALYZE-ENVIRONMENT-FROM-LIST PARAMS DECLARATIONS)  environment.lisp
- - - - - - - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - (PARSE-TYPE-SPECIFIER SPEC)  environment.lisp [See above]
- - - - - - - (RESOLVE-PARAMETERIZED-BRAND-IN-ENV BRAND-SPEC ENV)  types/brand.lisp
- - - - - - - - (FIND-BRAND-FOR-OWNER BRAND-NAME OWNER-TYPE)  types/brand.lisp
- - - - - - - - - (RESOLVE-OWNER-TYPE-TO-MANGLED TYPE-SPEC)  types/brand.lisp
- - - - - - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - - - (VALIDATE-DEPENDENT-BRAND-TYPES DECLARE-FORMS ENV)  types/brand.lisp
- - - - - - - (IS-BRAND-TYPE-P TYPE-NAME)  types/brand.lisp [See above]
- - - - - - - (FIND-BRAND-FOR-OWNER BRAND-NAME OWNER-TYPE)  types/brand.lisp [See above]
- - - - - - (%REGISTER-GENERIC-FUNCTION NAME PARAMS ENV RETURN-TYPES DECLARE-FORMS EXTRACTED-DEFAULTS KEY-IDX BODY LOCATION)  environment.lisp
- - - - - - (%REGISTER-STANDARD-FUNCTION NAME ENV RETURN-TYPES DECLARE-FORMS LOCATION)  environment.lisp
- - - - - - - (%FIND-ENTRY-POINT-DECLARATION DECLARE-FORMS)  environment.lisp
- - - - - - - (%VALIDATE-KERNEL-RETURN-TYPE RETURN-TYPES)  environment.lisp
- - - - - (PARSE-FUNCTION-DECLARATIONS PARAMS DECLARATIONS)  environment.lisp [See above]
- - - - - (%COMPILE-STANDARD-FUNCTION FORM LOCATION MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)  analysis/core.lisp
- - - - - - (GENERATE-LLVM-IR SEMANTIC-FUNCTION MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)  codegen.lisp
- - - - - - - (GENERATE-FUNCTION-PROTOTYPE SEMANTIC-FUNCTION MODULE DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)  codegen.lisp
- - - - - - - - (CREATE-LLVM-FUNCTION-TYPE MODULE RETURN-TYPES PARAM-NODES)  codegen/abi.lisp
- - - - - - - - - (GET-LLVM-RETURN-TYPE MODULE RETURN-TYPE-NAMES)  codegen/abi.lisp
- - - - - - - - - - (CRISP-TYPE-TO-LLVM-TYPE TYPE-SPEC MODULE)  codegen/abi.lisp
- - - - - - - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - - - - - - - - (RESOLVE-TYPE-TO-LLVM TYPE-SPEC)  types/validation.lisp
- - - - - - - - - - - - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - (RESOLVE-TYPE-TO-LLVM TYPE-SPEC)  types/validation.lisp [RECURSION]
- - - - - - - - - - - - (GET-TYPE-BASE TYPE-NAME)  types/hierarchy.lisp
- - - - - - - - - - - - (ENCODE-ADDRESS-SPACE AS)  types/validation.lisp
- - - - - - - - - - - - (FIND-STRUCT-DEFINITION-BY-NAME NAME-OR-SYMBOL)  structs.lisp
- - - - - - - - - - - - (ENSURE-STRUCT-LLVM-TYPE NAME)  structs.lisp
- - - - - - - - - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - - - - - - - - - - (FIND-STRUCT-DEFINITION-BY-NAME NAME-OR-SYMBOL)  structs.lisp [See above]
- - - - - - - - - - - - - (RESOLVE-TYPE-TO-LLVM TYPE-SPEC)  types/validation.lisp [RECURSION]
- - - - - - - - - - - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - (FIND-TEMPLATE-ROBUST NAME)  types/validation.lisp
- - - - - - - - - - - - (UNMANGLE-TEMPLATE-STRUCT-NAME SYMBOL)  mangling.lisp
- - - - - - - - - - - - - (SPLIT-STRING STRING DELIMITER)  mangling.lisp
- - - - - - - - - - - - - (RECONSTRUCT-TEMPLATE-ARGS TOKENS PACKAGE)  mangling.lisp
- - - - - - - - - - - - - - (RECONSTRUCT-N-ARGS TOKENS N PACKAGE)  mangling.lisp
- - - - - - - - - - - - - - - (RECONSTRUCT-ONE-ARG TOKENS PACKAGE)  mangling.lisp
- - - - - - - - - - - - - - - - (RECONSTRUCT-N-ARGS TOKENS N PACKAGE)  mangling.lisp [RECURSION]
- - - - - - - - - - - - - - - (RECONSTRUCT-N-ARGS TOKENS N PACKAGE)  mangling.lisp [RECURSION]
- - - - - - - - - - - - - - (RECONSTRUCT-TEMPLATE-ARGS TOKENS PACKAGE)  mangling.lisp [RECURSION]
- - - - - - - - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - - - - - - - - - (ENSURE-TEMPLATE-INSTANTIATION NAME EXPLICIT-ARG-TYPES COMPILER-CALLBACK)  templates.lisp
- - - - - - - - - - - - - (%RESOLVE-TEMPLATE-NAME NAME)  templates.lisp
- - - - - - - - - - - - - (TRY-INFER-TEMPLATE-TYPES NAME ARGUMENT-TYPES)  templates.lisp
- - - - - - - - - - - - - - (%INFER-FROM-SINGLE-TEMPLATE TMPL ARGUMENT-TYPES)  templates.lisp
- - - - - - - - - - - - - - - (%UNWRAP-FUNCTION-SIGNATURE RAW-SIG)  templates.lisp
- - - - - - - - - - - - - - - (MATCH-TEMPLATE-ARG RAW-SIG-TYPE ARG-TYPE INFERENCE-MAP TEMPLATE-PARAMS)  templates.lisp
- - - - - - - - - - - - - - - - (NORMALIZE-TEMPLATE-SIG-TYPE TYPE)  templates.lisp
- - - - - - - - - - - - - - - - (MATCH-FUNCTION-SIGNATURE PATTERN-SIG CONCRETE-SIG INFERENCE-MAP TEMPLATE-PARAMS)  templates.lisp
- - - - - - - - - - - - - - - - - (MATCH-TEMPLATE-ARG RAW-SIG-TYPE ARG-TYPE INFERENCE-MAP TEMPLATE-PARAMS)  templates.lisp [RECURSION]
- - - - - - - - - - - - - - - - (MATCH-LIST-STRUCTURE SIG-LIST ARG-LIST INFERENCE-MAP TEMPLATE-PARAMS)  templates.lisp
- - - - - - - - - - - - - - - - - (MATCH-TEMPLATE-ARG RAW-SIG-TYPE ARG-TYPE INFERENCE-MAP TEMPLATE-PARAMS)  templates.lisp [RECURSION]
- - - - - - - - - - - - - - - - (UNMANGLE-TEMPLATE-STRUCT-NAME SYMBOL)  mangling.lisp [See above]
- - - - - - - - - - - - - - - - (STRIP-KEYWORD-LABELS TYPE-LIST TEMPLATE-PARAMS)  templates.lisp
- - - - - - - - - - - - - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - - (MATCH-TEMPLATE-ARG RAW-SIG-TYPE ARG-TYPE INFERENCE-MAP TEMPLATE-PARAMS)  templates.lisp [RECURSION]
- - - - - - - - - - - - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - (%SHOULD-INSTANTIATE-TEMPLATE KEY STATUS IS-COMPILING)  templates.lisp
- - - - - - - - - - - - - (INSTANTIATE-TEMPLATE NAME-OR-TMPL CONCRETE-TYPES &OPTIONAL OVERRIDE-NAME)  templates.lisp
- - - - - - - - - - - - - - (VALIDATE-TEMPLATE-ARG ARG TYPE NAME)  types/validation.lisp [See above]
- - - - - - - - - - - - - - (%INSTANTIATE-STRUCTURE-TEMPLATE NAME BODY SUBSTITUTIONS CONCRETE-TYPES)  templates.lisp
- - - - - - - - - - - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - - - - - - - - - - - - (%DISPATCH-INCOMPLETE-TEMPLATE TEMPLATE-NAME ALL-ARGS)  templates.lisp
- - - - - - - - - - - - - - (%INSTANTIATE-CALLABLE-TEMPLATE NAME BODY SUBSTITUTIONS OVERRIDE-NAME)  templates.lisp
- - - - - - - - - - - - (COMPILE-TOPLEVEL-FORM FORM LOCATION MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)  analysis/core.lisp [RECURSION]
- - - - - - - - - (GET-EXPANDED-TYPES TYPE-SPEC MODULE)  codegen/abi.lisp
- - - - - - - - - - (%RECORD-BASE-FROM-LIST-FORM TYPE-SPEC)  codegen/abi.lisp
- - - - - - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - - - - - - - (RESOLVE-TYPE-TO-LLVM TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - (LOOKUP-STRUCT-DEFINITION TYPE-NAME)  structs.lisp
- - - - - - - - - - - (GET-TYPE-BASE TYPE-NAME)  types/hierarchy.lisp [See above]
- - - - - - - - - - (GET-EXPANDED-TYPES TYPE-SPEC MODULE)  codegen/abi.lisp [RECURSION]
- - - - - - - - - - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - (CRISP-TYPE-TO-LLVM-TYPE TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - - - - - - - - - (IS-GLOBAL-STORAGE-HANDLE-P TYPE-SPEC)  codegen/abi.lisp
- - - - - - - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - - - - - (LLVM-TYPE-KIND-IS-POINTER? TY) :CRISP.LLVM-BINDINGS  llvm-bindings.lisp
- - - - - - - - - - (ENCODE-ADDRESS-SPACE AS)  types/validation.lisp [See above]
- - - - - - - - (%CHECK-EXISTING-FUNCTION EXISTING FN-NAME DI-BUILDER DI-COMPILE-UNIT FUNC CRISP-RETURN-TYPE PARAM-NODES LOCATION-MAP FN-LOC MODULE FN-TYPE)  codegen.lisp
- - - - - - - - - (GENERATE-DEBUG-INFO DI-BUILDER DI-COMPILE-UNIT FUNC FN-NAME FN-LOC RETURN-TYPE PARAM-NODES LOCATION-MAP)  codegen.lisp
- - - - - - - - - - (GET-OR-CREATE-DI-TYPE CRISP-TYPE DI-BUILDER DI-TYPE-CACHE)  codegen.lisp
- - - - - - - - (%CREATE-NEW-FUNCTION FN-NAME FN-TYPE MODULE DI-BUILDER DI-COMPILE-UNIT CRISP-RETURN-TYPE PARAM-NODES LOCATION-MAP FN-LOC)  codegen.lisp
- - - - - - - - - (GENERATE-DEBUG-INFO DI-BUILDER DI-COMPILE-UNIT FUNC FN-NAME FN-LOC RETURN-TYPE PARAM-NODES LOCATION-MAP)  codegen.lisp [See above]
- - - - - - - (ENSURE-OPENCL-KERNEL-METADATA FUNC SEMANTIC-FUNCTION MODULE)  codegen.lisp
- - - - - - - (GENERATE-FUNCTION-BODY SEMANTIC-FUNCTION FUNC DI-SUBPROGRAM BUILDER MODULE DI-BUILDER LOCATION-MAP)  codegen.lisp
- - - - - - - - (INITIALIZE-FUNCTION-PARAMETERS BUILDER FUNC PARAM-NODES MODULE VAR-ENV)  codegen.lisp
- - - - - - - - - (GET-EXPANDED-TYPES TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - - - - - - - - (IMPLODE-VALUE BUILDER COMPONENTS TYPE-SPEC MODULE)  codegen/abi.lisp
- - - - - - - - - - (%RECORD-BASE-FROM-LIST-FORM TYPE-SPEC)  codegen/abi.lisp [See above]
- - - - - - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - - - - - - - (LOOKUP-STRUCT-DEFINITION TYPE-NAME)  structs.lisp [See above]
- - - - - - - - - - (CRISP-TYPE-TO-LLVM-TYPE TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - - - - - - - - - (IMPLODE-VALUE BUILDER COMPONENTS TYPE-SPEC MODULE)  codegen/abi.lisp [RECURSION]
- - - - - - - - - - (GET-EXPANDED-TYPES TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - - - - - - - - - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - (CRISP-TYPE-TO-LLVM-TYPE TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - - - - - - - (GENERATE-EXPRESSION-IR BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP NODE)  codegen.lisp
- - - - - - - - - (GENERATE-NODE-IR (NODE SEMANTIC-DEVICE-VEC-LITERAL) BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP)  codegen.lisp
- - - - - - - - - - (GENERATE-NODE-IR (NODE SEMANTIC-DEVICE-VEC-LITERAL) BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP)  codegen.lisp [RECURSION]
- - - - - - - - - - (GET-LLVM-RETURN-TYPE MODULE RETURN-TYPE-NAMES)  codegen/abi.lisp [See above]
- - - - - - - - - - (CRISP-TYPE-TO-LLVM-TYPE TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - - - - - - - - - (%GENERATE-KEYWORD-LITERAL-IR VALUE)  codegen.lisp
- - - - - - - - - - - (RESOLVE-KEYWORD-CONSTANT KW)  codegen.lisp
- - - - - - - - - - (%GENERATE-CELL-LITERAL-IR BUILDER MODULE VAR-ENV TYPE-SPEC VALUE)  codegen.lisp
- - - - - - - - - - - (CRISP-TYPE-TO-LLVM-TYPE TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - - - - - - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - - - - - - - - (ENSURE-STRUCT-LLVM-TYPE NAME)  structs.lisp [See above]
- - - - - - - - - - (%GENERATE-ENUM-LITERAL-IR BUILDER VALUE LLVM-TYPE)  codegen.lisp
- - - - - - - - - - - (RESOLVE-KEYWORD-CONSTANT KW)  codegen.lisp [See above]
- - - - - - - - - - (%GENERATE-SCALAR-LITERAL-IR BUILDER VALUE LLVM-TYPE CRISP-TYPE)  codegen.lisp
- - - - - - - - - - (SEMANTIC-NODE-SOURCE-LOCATION NODE)  analysis/core.lisp
- - - - - - - - - - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp
- - - - - - - - - - (EXTRACT-PRIMARY-VALUE BUILDER VALUE TYPE-SPEC)  codegen/abi.lisp
- - - - - - - - - - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp
- - - - - - - - - - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - (GET-TEMPLATE-ARITY NAME)  types/validation.lisp [See above]
- - - - - - - - - - - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - - - - - - - - - (BUILD-CAST-IF-NEEDED BUILDER MODULE FROM-VAL FROM-TYPE-NAME TO-TYPE-NAME)  codegen.lisp
- - - - - - - - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - (CRISP-TYPE-TO-LLVM-TYPE TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - - - - - - - - - - (GET-TYPE-CAT-SAFE TYPE-NAME TYPE-OBJ)  codegen.lisp
- - - - - - - - - - - (GET-TYPE-BASE TYPE-NAME)  types/hierarchy.lisp [See above]
- - - - - - - - - - (%HANDLE-DIE-INTRINSIC BUILDER MODULE)  codegen.lisp
- - - - - - - - - - (GET-EXPANDED-TYPES TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - - - - - - - - - (%BUILD-FUNCTION-CALL BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP NODE SIG CALLEE-NAME LLVM-FN-TYPE PARAM-NODES PARAM-COUNT RETURN-TYPE-NAMES)  codegen.lisp
- - - - - - - - - - - (PREPARE-CALL-ARGUMENTS BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP ARG-NODES PARAM-TYPES PARAM-COUNT)  codegen.lisp
- - - - - - - - - - - - (GENERATE-NODE-IR (NODE SEMANTIC-DEVICE-VEC-LITERAL) BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP)  codegen.lisp [RECURSION]
- - - - - - - - - - - - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - - - - - - - - - - - (EXTRACT-PRIMARY-VALUE BUILDER VALUE TYPE-SPEC)  codegen/abi.lisp [See above]
- - - - - - - - - - - - (EXPLODE-VALUE BUILDER AGG-VAL TYPE-SPEC)  codegen/abi.lisp
- - - - - - - - - - - - - (%RECORD-BASE-FROM-LIST-FORM TYPE-SPEC)  codegen/abi.lisp [See above]
- - - - - - - - - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - - - - - - - - - - (LOOKUP-STRUCT-DEFINITION TYPE-NAME)  structs.lisp [See above]
- - - - - - - - - - - - - (EXPLODE-VALUE BUILDER AGG-VAL TYPE-SPEC)  codegen/abi.lisp [RECURSION]
- - - - - - - - - - - - - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - (SEMANTIC-NODE-SOURCE-LOCATION NODE)  analysis/core.lisp [See above]
- - - - - - - - - - (%GENERATE-LET-BINDING BINDING BUILDER MODULE LET-ENV DI-BUILDER DI-SCOPE LOCATION-MAP MEMOIZED-AGGREGATES)  codegen.lisp
- - - - - - - - - - - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]
- - - - - - - - - - - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - - - - - - - - - - (%DVEC-TYPE-LOOKUP TYPE-SYM)  analysis/core.lisp
- - - - - - - - - - - (GENERATE-EXPRESSION-IR BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP NODE)  codegen.lisp [RECURSION]
- - - - - - - - - - - (CRISP-TYPE-TO-LLVM-TYPE TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - - - - - - - - - (GENERATE-EXPRESSION-IR BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP NODE)  codegen.lisp [RECURSION]
- - - - - - - - - - (PREPARE-CALL-ARGUMENTS BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP ARG-NODES PARAM-TYPES PARAM-COUNT)  codegen.lisp [See above]
- - - - - - - - - - (TERMINATOR-P BLOCK)  codegen.lisp
- - - - - - - - - - (LOOKUP-STRUCT-DEFINITION TYPE-NAME)  structs.lisp [See above]
- - - - - - - - - - (ENSURE-STRUCT-LLVM-TYPE NAME)  structs.lisp [See above]
- - - - - - - - - - (RESOLVE-TYPE-TO-LLVM TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - (LLVM-TYPE-KIND-IS-POINTER? TY) :CRISP.LLVM-BINDINGS  llvm-bindings.lisp [See above]
- - - - - - - - - - (%DVEC-TYPE-LOOKUP TYPE-SYM)  analysis/core.lisp [See above]
- - - - - - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - - - - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - - - - - (UNMANGLE-TEMPLATE-STRUCT-NAME SYMBOL)  mangling.lisp [See above]
- - - - - - - - - - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - (%TRY-INLINE-STRUCT-ARRAY-FIELD-PTR ARRAY-NODE BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP)  codegen.lisp
- - - - - - - - - - - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - - - - - - - - - - (LOOKUP-STRUCT-DEFINITION TYPE-NAME)  structs.lisp [See above]
- - - - - - - - - - - (%LOOKUP-FIELD-PHYSICAL-INDEX STRUCT-DEF FIELD-NAME-STR)  codegen.lisp
- - - - - - - - - - - (ENSURE-STRUCT-LLVM-TYPE NAME)  structs.lisp [See above]
- - - - - - - - - - - (GENERATE-NODE-IR (NODE SEMANTIC-DEVICE-VEC-LITERAL) BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP)  codegen.lisp [RECURSION]
- - - - - - - - - - (%DVEC-COERCE-ELEMENT-IR ELEM-NODE COMP-TYPE COMP-LLVM-TYPE BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP)  codegen.lisp
- - - - - - - - - - - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - - - - - - - - - - (GENERATE-NODE-IR (NODE SEMANTIC-DEVICE-VEC-LITERAL) BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP)  codegen.lisp [RECURSION]
- - - - - - - - (CRISP-TYPE-TO-LLVM-TYPE TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - - - - - - - (LLVM-TYPE-KIND-IS-POINTER? TY) :CRISP.LLVM-BINDINGS  llvm-bindings.lisp [See above]
- - - - - (%FN-NAME-IS-GRAD-P NAME)  autodiff.lisp
- - - - - (%GENERATE-BACKWARD-FUNCTION-AST NAME PARAMS DECLARATIONS BODY-FORMS)  autodiff.lisp
- - - - - - (PARSE-FUNCTION-DECLARATIONS PARAMS DECLARATIONS)  environment.lisp [See above]
- - - - - - (%CRISP-FLOAT-TYPE-P TYPE-SPEC)  autodiff.lisp
- - - - - - - (COMPUTE-BASE-TYPE ORIGINAL-TYPE-NAME)  types/hierarchy.lisp
- - - - - - - - (COMPUTE-BASE-TYPE ORIGINAL-TYPE-NAME)  types/hierarchy.lisp [RECURSION]
- - - - - - (%CRISP-FUNCTION-TYPE-P TYPE-SPEC)  autodiff.lisp
- - - - - - (FLATTEN-ANF-BODY ANF-BODY)  anf-transform.lisp
- - - - - - (%EXTRACT-RETURN-VARS FLAT-ANF)  autodiff.lisp
- - - - - - (%CHECK-FN-BODY-FOR-MUTATIONS BODY-FORMS PARAM-NAMES FN-NAME)  autodiff.lisp
- - - - - - (%GENERATE-BACKWARD-FUNCTION-WALK FLAT-ANF FLOAT-PARAM-SYMS T-GRAD-SYMS RETURN-VARS)  autodiff.lisp
- - - - - - - (%BACKWARD-SKIP-FN-P FN-SYM)  autodiff.lisp
- - - - - - (DEF-FUNCTION NAME PARAMS &REST BODY-AND-LOCATION)  macros.lisp
- - - - - - - (REGISTER-FUNCTION-SIGNATURE FORM LOCATION)  environment.lisp [See above]
- - - - - - - (DEF-FUNCTION NAME PARAMS &REST BODY-AND-LOCATION)  macros.lisp [RECURSION]
- - - - - - - (INTERNAL-DEF-FUNCTION NAME PARAMS DECLARATIONS BODY LOCATION)  analysis/core.lisp
- - - - - - - - (ANF-NORMALIZE EXPR IS-NESTED?)  anf-transform.lisp
- - - - - - - - - (ANF-IS-ATOMIC? EXPR)  anf-transform.lisp
- - - - - - - - - (ANF-NORMALIZE EXPR IS-NESTED?)  anf-transform.lisp [RECURSION]
- - - - - - - - - (ANF-NORMALIZE-PLACE PLACE)  anf-transform.lisp
- - - - - - - - - - (ANF-NORMALIZE-ARGS ARGS)  anf-transform.lisp
- - - - - - - - - - - (ANF-NORMALIZE EXPR IS-NESTED?)  anf-transform.lisp [RECURSION]
- - - - - - - - - - - (ANF-NORMALIZE-ARGS ARGS)  anf-transform.lisp [RECURSION]
- - - - - - - - - (ANF-FRESH-TEMP)  anf-transform.lisp
- - - - - - - - - (%ANF-TRANSFORM EXPR)  anf-transform.lisp
- - - - - - - - - - (ANF-NORMALIZE EXPR IS-NESTED?)  anf-transform.lisp [RECURSION]
- - - - - - - - - (ANF-NORMALIZE-ARGS ARGS)  anf-transform.lisp [See above]
- - - - - - - - (PARSE-FUNCTION-DECLARATIONS PARAMS DECLARATIONS)  environment.lisp [See above]
- - - - - - - - (%BOUNDARY-STRUCT-TYPE-P TYPE)  analysis/core.lisp
- - - - - - - - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - (INTERNAL-COMPILE-FUNCTION NAME EXPLICIT-ENV RETURN-TYPE PARAMS BODY DECLARATIONS LOCATION CONTEXT)  analysis/core.lisp
- - - - - - - - - (DETECT-AND-REGISTER-IMPLICIT-TEMPLATE NAME EXPLICIT-ENV RETURN-TYPE PARAMS BODY DECLARATIONS)  environment.lisp
- - - - - - - - - - (INCOMPLETE-TYPE-P TYPE-SPEC)  types/validation.lisp
- - - - - - - - - - - (GET-TEMPLATE-ARITY NAME)  types/validation.lisp [See above]
- - - - - - - - - - - (FIND-STRUCT-DEFINITION-BY-NAME NAME-OR-SYMBOL)  structs.lisp [See above]
- - - - - - - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - - - - - (FIND-STRUCT-DEFINITION-BY-NAME NAME-OR-SYMBOL)  structs.lisp [See above]
- - - - - - - - - - (DEF-FUNCTION NAME PARAMS &REST BODY-AND-LOCATION)  macros.lisp [RECURSION]
- - - - - - - - - - (REGISTER-TEMPLATE NAME PARAMS CONSTRAINTS BODY SIGNATURE)  templates.lisp [See above]
- - - - - - - - - (SCAN-FOR-CARRIERS NAME BODY)  environment.lisp
- - - - - - - - - - (SINGLE-PASS-MODE-P)  analysis/core.lisp
- - - - - - - - - - (WITH-PEEK-SCRATCH-COUNTER &BODY BODY)  macros.lisp
- - - - - - - - - - (SHALLOW-ANALYZE-BODY FORMS)  analysis/core.lisp
- - - - - - - - - - - (SCAN-FORM (FORM CONS))  analysis/core.lisp
- - - - - - - - - - - - (SCAN-OPERATOR (OP (EQL 'MAKE-SCRATCH-CELL)) ARGS)  analysis/core.lisp
- - - - - - - - - - - - - (SCAN-FORM (FORM CONS))  analysis/core.lisp [RECURSION]
- - - - - - - - - - - - - (SCAN-OPERATOR (OP (EQL 'MAKE-SCRATCH-CELL)) ARGS)  analysis/core.lisp [RECURSION]
- - - - - - - - - - - - - (EXPAND-STORAGE-HANDLE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - (SCAN-FORM (FORM CONS))  analysis/core.lisp [RECURSION]
- - - - - - - - - (INJECT-IMPLICIT-ARGUMENTS NAME EXPLICIT-ENV)  environment.lisp
- - - - - - - - - (VALIDATE-RETURN-TYPES NAME BODY ENV CONTEXT DECLARED-RETURN-TYPES LOCATION)  analysis/core.lisp
- - - - - - - - - - (ANALYZE-BODY-EXPRESSIONS BODY-LIST ENV CONTEXT LOCATION)  analysis/core.lisp
- - - - - - - - - - - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp
- - - - - - - - - - - - (%TRY-PARSE-TYPED-LITERAL EXPR LOCATION)  analysis/core.lisp
- - - - - - - - - - - - (FIND-VARIABLE-IN-ENV NAME ENV)  analysis/core.lisp
- - - - - - - - - - - - (ANALYZE-INCOMPLETE-TYPE-ACCESSOR OP EXPR ENV CONTEXT LOCATION)  analysis/structs.lisp
- - - - - - - - - - - - - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [RECURSION]
- - - - - - - - - - - - - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - - - - - - - - - - - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [RECURSION]
- - - - - - - - - - - - (ANALYZE-FUNCTION-CALL OP EXPR ENV CONTEXT LOCATION)  analysis/core.lisp
- - - - - - - - - - - - - (MULTI-PASS-MODE-P)  analysis/core.lisp
- - - - - - - - - - - - - (SINGLE-PASS-MODE-P)  analysis/core.lisp [See above]
- - - - - - - - - - - - - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [RECURSION]
- - - - - - - - - - - - - (RESOLVE-BEST-SIGNATURE OP EXPLICIT-ARG-TYPES CONTEXT)  type-checker.lisp
- - - - - - - - - - - - - - (TYPES-LIST-COMPATIBLE-P ARG-TYPES PARAM-TYPES)  type-checker.lisp
- - - - - - - - - - - - - - (INSTANTIATE-GENERIC-FUNCTION GENERIC-DEF EXPLICIT-ARG-TYPES CONTEXT LOCATION)  environment.lisp
- - - - - - - - - - - - - - - (RESOLVE-ARGUMENT-BINDINGS GENERIC-DEF EXPLICIT-ARG-TYPES)  environment.lisp
- - - - - - - - - - - - - - - - (BIND-KEYWORD-ARGS FULL-ENV EXPLICIT-ARGS KEY-IDX NAME)  environment.lisp
- - - - - - - - - - - - - - - - (TYPES-LIST-COMPATIBLE-P ARG-TYPES PARAM-TYPES)  type-checker.lisp [See above]
- - - - - - - - - - - - - - - - (INJECT-DEFAULTS REMAINDER-ENV DEFAULTS)  environment.lisp
- - - - - - - - - - - - - - - (MANGLE-FUNCTION-VARIANT-NAME BASE-NAME PARAM-TYPES)  mangling.lisp
- - - - - - - - - - - - - - - (INTERNAL-COMPILE-FUNCTION NAME EXPLICIT-ENV RETURN-TYPE PARAMS BODY DECLARATIONS LOCATION CONTEXT)  analysis/core.lisp [RECURSION]
- - - - - - - - - - - - - - (COMPILE-TOPLEVEL-FORM FORM LOCATION MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)  analysis/core.lisp [RECURSION]
- - - - - - - - - - - - - (%CHECK-STRUCT-MUTATING-CALL OP EXPLICIT-ARG-NODES ENV CONTEXT LOCATION)  analysis/core.lisp
- - - - - - - - - - - - - - (FIND-VARIABLE-IN-ENV NAME ENV)  analysis/core.lisp [See above]
- - - - - - - - - - - - - - (%BOUNDARY-STRUCT-TYPE-P TYPE)  analysis/core.lisp [See above]
- - - - - - - - - - - - - (FIND-VARIABLE-IN-ENV NAME ENV)  analysis/core.lisp [See above]
- - - - - - - - - - - - - (IS-BRAND-TYPE-P TYPE-NAME)  types/brand.lisp [See above]
- - - - - - - - - - - - - (BRAND-ACTIVE-P BRAND-DEF)  types/brand.lisp [See above]
- - - - - - - - - - - - - (%FIND-BRAND-OWNER-VAR BRAND-NAME SIG-PARAMS ARG-NODES)  types/brand.lisp
- - - - - - - - - - - - - - (FIND-BRAND-FOR-OWNER BRAND-NAME OWNER-TYPE)  types/brand.lisp [See above]
- - - - - - - - - - - - - (RESOLVE-BRAND-TYPE BRAND-NAME VAR-REF &OPTIONAL BASE-TYPE)  types/brand.lisp
- - - - - - - - - - - - - - (REGISTER-DERIVED-TYPE NEW-TYPE-NAME ORIGINAL-TYPE-NAME SUBST-MODE)  types/hierarchy.lisp
- - - - - - - - - - - - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - - - - - - (COMPUTE-BASE-TYPE ORIGINAL-TYPE-NAME)  types/hierarchy.lisp [See above]
- - - - - - - - - - - - - - - (CRISP-TYPE-TO-LLVM-TYPE TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - - - - - - - - - - - - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]
- - - - - - - - - - - - - (IS-SUBSTITUTABLE-FOR? SOURCE-TYPE TARGET-TYPE)  types/hierarchy.lisp
- - - - - - - - - - - - - - (HAS-ANCESTOR-PATH? FROM-TYPE TO-TYPE VISITED)  types/hierarchy.lisp
- - - - - - - - - - - - - - - (HAS-ANCESTOR-PATH? FROM-TYPE TO-TYPE VISITED)  types/hierarchy.lisp [RECURSION]
- - - - - - - - - - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - - - - - - - - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - - (SEMANTIC-NODE-SOURCE-LOCATION NODE)  analysis/core.lisp [See above]
- - - - - - - - - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - - - - - - - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - - (SEMANTIC-NODE-SOURCE-LOCATION NODE)  analysis/core.lisp [See above]
- - - - - (COMPILE-DEF-FUNCTION FORM LOCATION MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)  analysis/core.lisp [RECURSION]
- - - - (%PRE-REGISTER-HOF-TEMPLATES)  analysis/core.lisp
- - - - - (%TREE-HAS-FUNCALL-P TREE TARGET-SYM)  analysis/core.lisp
- - - - - - (%TREE-HAS-FUNCALL-P TREE TARGET-SYM)  analysis/core.lisp [RECURSION]
- - - (GENERATE-LOCATION-MAP FORMS)  analysis/core.lisp
- - - - (WALK-AND-MAP-LOCATIONS EXPR LOCATION MAP COUNTER)  analysis/core.lisp
- - - - - (WALK-AND-MAP-LOCATIONS EXPR LOCATION MAP COUNTER)  analysis/core.lisp [RECURSION]
- - - (COMPILE-MODULE FORMS MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)  analysis/core.lisp
- - - - (ANALYZE-SIGNATURES-PASS FORMS)  analysis/core.lisp
- - - - - (%PRE-REGISTER-DIFFERENTIABLE-FNS FORMS)  analysis/core.lisp
- - - - - - (%FN-NAME-IS-GRAD-P NAME)  autodiff.lisp [See above]
- - - - - - (PARSE-FUNCTION-DECLARATIONS PARAMS DECLARATIONS)  environment.lisp [See above]
- - - - - - (%CRISP-FLOAT-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - - - - (%CRISP-FUNCTION-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - - - - - (%PRE-REGISTER-DIFFERENTIABLE-FNS FORMS)  analysis/core.lisp [RECURSION]
- - - - - - (%TREE-HAS-FUNCALL-P TREE TARGET-SYM)  analysis/core.lisp [See above]
- - - - - (WALK-CODE-FORMS FORMS VISITOR-FN)  analysis/core.lisp
- - - - - - (VISIT-TOPLEVEL-FORM FORM LOCATION VISITOR-FN)  analysis/core.lisp [See above]
- - - - - (REGISTER-FUNCTION-SIGNATURE FORM LOCATION)  environment.lisp [See above]
- - - - - (SHALLOW-ANALYZE-BODY FORMS)  analysis/core.lisp [See above]
- - - - - (%PRE-REGISTER-HOF-TEMPLATES)  analysis/core.lisp [See above]
- - - - (FINALIZE-STRUCT-DEFINITIONS)  structs.lisp
- - - - - (REGISTER-STRUCT-DEFINITION NAME MEMBERS &OPTIONAL (CATEGORY STRUCT))  structs.lisp
- - - - - - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - - - (COMPUTE-RECORD-LAYOUT MEMBERS)  structs.lisp
- - - - - - - (GET-native-SIZE TYPE-SPEC)  structs.lisp
- - - - - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - (GET-TYPE-BASE TYPE-NAME)  types/hierarchy.lisp [See above]
- - - - - - - - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - (GET-native-SIZE TYPE-SPEC)  structs.lisp [RECURSION]
- - - - - - - - (CALCULATE-native-PADDING CURRENT-OFFSET ALIGNMENT)  structs.lisp
- - - - - - - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - - - (COMPUTE-native-LAYOUT MEMBERS)  structs.lisp
- - - - - - - (GET-native-BASE-ALIGNMENT TYPE-SPEC)  structs.lisp
- - - - - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - (GET-TYPE-BASE TYPE-NAME)  types/hierarchy.lisp [See above]
- - - - - - - - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - - - - - (GET-native-SIZE TYPE-SPEC)  structs.lisp [See above]
- - - - - - - (CALCULATE-native-PADDING CURRENT-OFFSET ALIGNMENT)  structs.lisp [See above]
- - - - - - (ENSURE-STRUCT-LLVM-TYPE NAME)  structs.lisp [See above]
- - - - (PROPAGATE-IMPLICIT-ARGUMENTS)  analysis/core.lisp
- - - - (COMPILE-FORMS-PASS FORMS MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)  analysis/core.lisp
- - - - - (COMPILE-TOPLEVEL-FORM FORM LOCATION MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)  analysis/core.lisp [See above]
- - - - - (WALK-CODE-FORMS FORMS VISITOR-FN)  analysis/core.lisp [See above]
- - - - (CHECK-FOR-RECURSION-CYCLES)  analysis/core.lisp
- - - - - (DETECT-CYCLE-FROM-NODE NODE VISITED VISITING)  analysis/core.lisp
- - - - - - (DETECT-CYCLE-FROM-NODE NODE VISITED VISITING)  analysis/core.lisp [RECURSION]
- - - (COMPILE-TO-SPIRV MODULE OUTPUT-PATH &KEY DEBUG-P)  compiler.lisp
- - - - (%REMOVE-DEAD-ARRAY-RETURNING-FUNCTIONS MODULE)  compiler.lisp
- - - - - (LLVM-TYPE-KIND-IS-ARRAY? TY) :CRISP.LLVM-BINDINGS  llvm-bindings.lisp
- - - - (INJECT-SPIR-KERNEL-METADATA IR-TEXT)  compiler.lisp
- - - - - (FIND-SPIR-KERNELS IR-TEXT)  compiler.lisp
- - - - - (EXTRACT-KERNEL-PARAMS IR-TEXT FUNC-START FUNC-END)  compiler.lisp
- - - - - - (SPLIT-STRING STRING DELIMITER)  mangling.lisp [See above]
- - - - - (GENERATE-KERNEL-METADATA PARAMS METADATA-ID-BASE)  compiler.lisp
- - - - - - (IR-TYPE-TO-OPENCL-METADATA IR-TYPE)  compiler.lisp
- - - - (RESOLVE-TOOL-EXECUTABLE TOOL-BASE)  compiler.lisp
- - - - (RUN-TOOL-COMMAND ARGS &KEY (LOG-PREFIX ))  compiler.lisp
- - - (COMPILE-TO-PTX MODULE OUTPUT-PATH &KEY (COMPUTE-CAPABILITY sm_50) DEBUG-P)  compiler.lisp
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
- - - - - (STRIP-PACKAGE-QUALIFIERS TYPE-SPEC)  metadata.lisp
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
- - - - (SERIALIZE-KERNELS OUTPUT-STREAM KERNEL-NAMES &KEY SOURCE OUTPUT-TARGETS)  metadata.lisp
- - - - - (GENERATE-PHYSICAL-SIGNATURE SIG-OR-PARAMS)  metadata.lisp
- - - - - - (STRIP-PACKAGE-QUALIFIERS TYPE-SPEC)  metadata.lisp [See above]
- - - - - - (%STORAGE-HANDLE-TYPE-P TYPE-SPEC)  macros.lisp
- - - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - (%USER-RECORD-TYPE-P TYPE-SPEC)  metadata-val.lisp
- - - - - - - (%STORAGE-HANDLE-TYPE-P TYPE-SPEC)  macros.lisp [See above]
- - - - - - - (GET-TYPE-BASE TYPE-NAME)  types/hierarchy.lisp [See above]
- - - - - - (%ENUMERATE-PHYSICAL-TYPES TYPE-SPEC)  metadata-val.lisp
- - - - - - - (%STORAGE-HANDLE-TYPE-P TYPE-SPEC)  macros.lisp [See above]
- - - - - - - (LOOKUP-STRUCT-DEFINITION TYPE-NAME)  structs.lisp [See above]
- - - - - - - (%ENUMERATE-PHYSICAL-TYPES TYPE-SPEC)  metadata-val.lisp [RECURSION]
- - - - - - - (IS-BRAND-TYPE-P TYPE-NAME)  types/brand.lisp [See above]
- - - - - (GENERATE-DECLARED-SIGNATURE SIG &OPTIONAL DECLARED-PARAMS)  metadata.lisp
- - - - - - (GET-PHYSICAL-WIDTH TYPE)  metadata.lisp
- - - - - - - (%STORAGE-HANDLE-TYPE-P TYPE-SPEC)  macros.lisp [See above]
- - - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - - - (%USER-RECORD-TYPE-P TYPE-SPEC)  metadata-val.lisp [See above]
- - - - - - - (%ENUMERATE-PHYSICAL-TYPES TYPE-SPEC)  metadata-val.lisp [See above]
- - - - - - (STRIP-PACKAGE-QUALIFIERS TYPE-SPEC)  metadata.lisp [See above]
- - - - - - (%STORAGE-HANDLE-TYPE-P TYPE-SPEC)  macros.lisp [See above]
- - - - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - - (GENERATE-IMPLICIT-SIGNATURE SIG DECLARED-PARAMS)  metadata.lisp
- - - - - - (GET-PHYSICAL-WIDTH TYPE)  metadata.lisp [See above]
- - - - - - (STRIP-PACKAGE-QUALIFIERS TYPE-SPEC)  metadata.lisp [See above]
- - - - - (PRINT-WITHOUT-PACKAGES OBJ STREAM)  metadata.lisp [See above]
- - - (INVOKE-HOISTER HOIST-ID METACRISP-FILE) :CRISP.MAIN  main.lisp
- - - - (GET-HOISTER-BINARY-PATH HOIST-ID) :CRISP.MAIN  main.lisp

- (%CT-RESOLVE-VALUE VALUE)  macros.lisp

- (%GENERATE-BACKWARD-KERNEL-AST NAME PARAMS SIGNATURE-TYPES RAW-BODY)  macros.lisp
- - (%EXPAND-RECORD-KERNEL-INPUTS INPUTS INPUT-TYPES PKG)  autodiff.lisp
- - - (%CRISP-RECORD-TYPE-P TYPE-SPEC)  autodiff.lisp
- - - (%GET-RECORD-RUNTIME-FIELDS REC-TYPE-SPEC)  autodiff.lisp
- - - - (COMPUTE-BASE-TYPE ORIGINAL-TYPE-NAME)  types/hierarchy.lisp [See above]
- - - (%RECORD-FIELD-PARAM-SYM PARAM-SYM FIELD-NAME PKG)  autodiff.lisp
- - - (%CRISP-FLOAT-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - (%SUBSTITUTE-RECORD-ACCESSORS FORM RECORD-SUBS-HT RECORD-TYPE-HT)  autodiff.lisp
- - - (%SUBSTITUTE-RECORD-ACCESSORS FORM RECORD-SUBS-HT RECORD-TYPE-HT)  autodiff.lisp [RECURSION]
- - - (%RECORD-ACCESSOR-SYSTEM-GENERATED-P ACCESSOR-SYM REC-TYPE)  autodiff.lisp
- - (%CRISP-RECORD-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
- - (%CRISP-FLOAT-TYPE-P TYPE-SPEC)  autodiff.lisp [See above]
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
- - (FLATTEN-ANF-BODY ANF-BODY)  anf-transform.lisp [See above]
- - (GENERATE-BACKWARD-WALK FLAT-ANF INPUTS OUTPUTS INPUT-TYPES OUTPUT-TYPES)  autodiff.lisp
- - - (%SUBST-FORM FORM SUBST-ALIST)  autodiff.lisp
- - - - (%SUBST-FORM FORM SUBST-ALIST)  autodiff.lisp [RECURSION]
- - - (%REMOVE-FUNCALL FORM FN-PARAM-SYM CONCRETE-FN-SYM)  autodiff.lisp
- - - - (%REMOVE-FUNCALL FORM FN-PARAM-SYM CONCRETE-FN-SYM)  autodiff.lisp [RECURSION]
- - - (FLATTEN-ANF-BODY ANF-BODY)  anf-transform.lisp [See above]
- - - (%EXTRACT-RETURN-VARS FLAT-ANF)  autodiff.lisp [See above]
- - - (%BACKWARD-SKIP-FN-P FN-SYM)  autodiff.lisp [See above]
- - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - (%FIX-RECORD-GRAD-CELL-EMISSIONS FORM GRAD-CELL-SYMS)  autodiff.lisp
- - - (%FIX-RECORD-GRAD-CELL-EMISSIONS FORM GRAD-CELL-SYMS)  autodiff.lisp [RECURSION]
- - (DEF-KERNEL-EXACT NAME PARAMS &REST BODY)  macros.lisp
- - - (STRICT-VALID-TYPE-P SPEC)  macros.lisp
- - - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - (%STORAGE-HANDLE-TYPE-P TYPE-SPEC)  macros.lisp [See above]
- - - (DEF-FUNCTION NAME PARAMS &REST BODY-AND-LOCATION)  macros.lisp [See above]

- (%GENERATE-RAW-ACCESSOR MEMBER-SPEC NAME PKG RUNTIME-INDEX)  macros.lisp
- - (DEF-FUNCTION NAME PARAMS &REST BODY-AND-LOCATION)  macros.lisp [See above]

- (%GENERATE-STRUCT-ACCESSOR MEMBER-SPEC NAME PKG RUNTIME-INDEX)  macros.lisp
- - (%PARSE-CT-LITERAL VALUE)  macros.lisp
- - (DEF-FUNCTION NAME PARAMS &REST BODY-AND-LOCATION)  macros.lisp [See above]

- (%TENSOR-TYPE-P TYPE)  analysis/structs.lisp

- (ADDRESS-SPACE-VALUE K)  enums.lisp
- - (ENCODE-ADDRESS-SPACE AS)  types/validation.lisp [See above]

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

- (ANALYZE-AREF-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/structs.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - (GET-ARRAY-ELEMENT-TYPE TYPE)  analysis/structs.lisp
- - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - (UNMANGLE-TEMPLATE-STRUCT-NAME SYMBOL)  mangling.lisp [See above]
- - (FIND-VARIABLE-IN-ENV NAME ENV)  analysis/core.lisp [See above]
- - (%GET-TENSOR-ARITY TYPE)  analysis/structs.lisp
- - - (UNMANGLE-TEMPLATE-STRUCT-NAME SYMBOL)  mangling.lisp [See above]
- - (%BUILD-TENSOR-FLAT-INDEX-FORM TARGET-SYM INDEX-FORMS)  analysis/structs.lisp
- - (FIND-BRAND-FOR-OWNER BRAND-NAME OWNER-TYPE)  types/brand.lisp [See above]
- - (BRAND-ACTIVE-P BRAND-DEF)  types/brand.lisp [See above]
- - (RESOLVE-BRAND-TYPE BRAND-NAME VAR-REF &OPTIONAL BASE-TYPE)  types/brand.lisp [See above]
- - (ANALYZE-FUNCTION-CALL OP EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]

- (ANALYZE-ATOMIC-ADD!-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/ops.lisp

- (ANALYZE-BITCAST-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/ops.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]

- (ANALYZE-CAST-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/ops.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]

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

- (ANALYZE-INC!-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/ops.lisp

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
- - (UNMANGLE-TEMPLATE-STRUCT-NAME SYMBOL)  mangling.lisp [See above]
- - (ANALYZE-FUNCTION-CALL OP EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (%ARRAY-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]

- (ANALYZE-LET-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]
- - (SEMANTIC-NODE-SOURCE-LOCATION NODE)  analysis/core.lisp [See above]
- - (ANALYZE-BODY-EXPRESSIONS BODY-LIST ENV CONTEXT LOCATION)  analysis/core.lisp [See above]

- (ANALYZE-NESTED-DEF-FUNCTION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (COMPILE-TOPLEVEL-FORM FORM LOCATION MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)  analysis/core.lisp [See above]

- (ANALYZE-PROGN-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]

- (ANALYZE-QUOTE EXPR ENV CONTEXT LOCATION)  analysis/control.lisp

- (ANALYZE-RETURN-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - (SEMANTIC-NODE-SOURCE-LOCATION NODE)  analysis/core.lisp [See above]

- (ANALYZE-SCRATCH-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/structs.lisp
- - (EXPAND-STORAGE-HANDLE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - (VALID-PARAMETERIZED-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]

- (ANALYZE-SET!-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/structs.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (FIND-VARIABLE-IN-ENV NAME ENV)  analysis/core.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - (TYPES-COMPATIBLE-P ARG-TYPE PARAM-TYPE)  type-checker.lisp [See above]
- - (TYPES-LIST-COMPATIBLE-P ARG-TYPES PARAM-TYPES)  type-checker.lisp [See above]
- - (ENSURE-TEMPLATE-INSTANTIATION NAME EXPLICIT-ARG-TYPES COMPILER-CALLBACK)  templates.lisp [See above]
- - (%CHECK-AREF-BOUNDARY-MUTATION AREF-NODE LOCATION)  analysis/core.lisp
- - (%CHECK-STRUCT-BOUNDARY-MUTATION STRUCT-NODE ENV CONTEXT LOCATION)  analysis/core.lisp
- - - (FIND-VARIABLE-IN-ENV NAME ENV)  analysis/core.lisp [See above]
- - (GET-STRUCT-MEMBER-INDEX STRUCT-TYPE-NAME MEMBER-NAME)  analysis/structs.lisp
- - - (GET-TYPE-BASE TYPE-NAME)  types/hierarchy.lisp [See above]
- - - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - (MANGLE-TEMPLATE-STRUCT-NAME NAME PARAMS)  mangling.lisp [See above]
- - - (FIND-STRUCT-DEFINITION-BY-NAME NAME-OR-SYMBOL)  structs.lisp [See above]

- (ANALYZE-SIZEOF-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (PARSE-TYPE-SPECIFIER SPEC)  environment.lisp [See above]
- - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]

- (ANALYZE-STATIC-UNLESS-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-STATIC-IF-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - - (ANALYZE-IF-EXPRESSION-IMPL EXPR ENV CONTEXT LOCATION &KEY ENFORCE-CONSTANT)  analysis/control.lisp
- - - - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - - - (TRY-CONSTANT-FOLD NODE)  analysis/ops.lisp
- - - - - (TRY-CONSTANT-FOLD NODE)  analysis/ops.lisp [RECURSION]
- - - - (ENSURE-BRANCH-COMPATIBILITY THEN-NODE ELSE-NODE LOCATION)  analysis/control.lisp
- - - - - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - - - - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]
- - - - - (GET-PROMOTED-TYPE TYPE-A-NAME TYPE-B-NAME)  type-checker.lisp
- - - - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - - - - (RESOLVE-DOMINANCE TYPE-A TYPE-B)  types/hierarchy.lisp
- - - - - - - (IS-SUBSTITUTABLE-FOR? SOURCE-TYPE TARGET-TYPE)  types/hierarchy.lisp [See above]
- - - - - - - (FIND-COMMON-PROMOTED-TYPE TYPE-A TYPE-B)  types/hierarchy.lisp
- - - - - - - - (GET-REACHABLE-TYPES TYPE-NAME)  types/hierarchy.lisp
- - - - - (CREATE-IMPLICIT-CAST NODE TARGET-TYPE LOCATION)  analysis/ops.lisp

- (ANALYZE-STATIC-WHEN-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-STATIC-IF-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp [See above]

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

- (ANALYZE-TRUNCATE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/ops.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]

- (ANALYZE-UNLESS-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-IF-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - - (ANALYZE-IF-EXPRESSION-IMPL EXPR ENV CONTEXT LOCATION &KEY ENFORCE-CONSTANT)  analysis/control.lisp [See above]

- (ANALYZE-VALUE-CAST-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/ops.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]

- (ANALYZE-WHEN-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp
- - (ANALYZE-IF-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/control.lisp [See above]

- (ANF-TRANSFORM EXPR)  anf-transform.lisp
- - (%ANF-TRANSFORM EXPR)  anf-transform.lisp [See above]

- (ANF-TRANSFORM-MODULE FORMS)  anf-transform.lisp
- - (WITH-TEMPLATE-TYPE PARAMS &BODY BODY)  templates.lisp

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

- (DEF-BINARY-OP-ANALYZER NAME NODE-CONSTRUCTOR OP-STRING)  analysis/ops.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]
- - (GET-PROMOTED-TYPE TYPE-A-NAME TYPE-B-NAME)  type-checker.lisp [See above]

- (DEF-BINARY-OP-CODEGEN NODE-TYPE INT-INST FLOAT-INST ACCESSOR-PREFIX)  codegen.lisp
- - (GENERATE-NODE-IR (NODE SEMANTIC-DEVICE-VEC-LITERAL) BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP)  codegen.lisp [See above]
- - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]
- - (EXTRACT-PRIMARY-VALUE BUILDER VALUE TYPE-SPEC)  codegen/abi.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - (BUILD-CAST-IF-NEEDED BUILDER MODULE FROM-VAL FROM-TYPE-NAME TO-TYPE-NAME)  codegen.lisp [See above]
- - (SEMANTIC-NODE-SOURCE-LOCATION NODE)  analysis/core.lisp [See above]

- (DEF-COMPARISON-ANALYZER NAME NODE-CONSTRUCTOR OP-STRING)  analysis/ops.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]

- (DEF-COMPARISON-CODEGEN TYPE-NAME INT-PRED FLOAT-PRED ACCESSOR-PREFIX)  codegen.lisp
- - (GENERATE-NODE-IR (NODE SEMANTIC-DEVICE-VEC-LITERAL) BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP)  codegen.lisp [See above]
- - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]
- - (EXTRACT-PRIMARY-VALUE BUILDER VALUE TYPE-SPEC)  codegen/abi.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]

- (DEF-DERIVED-TYPE NEW-NAME ORIGINAL-TYPE &KEY (SUBST NIL SUBST-P))  macros.lisp
- - (COMPUTE-BASE-TYPE ORIGINAL-TYPE-NAME)  types/hierarchy.lisp [See above]
- - (REGISTER-DERIVED-TYPE NEW-TYPE-NAME ORIGINAL-TYPE-NAME SUBST-MODE)  types/hierarchy.lisp [See above]

- (DEF-ENUMERATION NAME &REST SPECS)  enums.lisp

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
- - - - (INCOMPLETE-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]
- - - - (CANONICALIZE-TYPE-SPECIFIER SPEC)  types/validation.lisp [See above]
- - - - (%USER-RECORD-TYPE-P TYPE-SPEC)  metadata-val.lisp [See above]
- - - (%EXPLODE-KERNEL-ARGS PARAMS SIGNATURE)  macros.lisp [See above]
- - - (%CHECK-DIFFERENTIATE-KERNEL-SIGNATURE NAME SIGNATURE-TYPES DECLARATIONS)  macros.lisp
- - (DEF-KERNEL-EXACT NAME PARAMS &REST BODY)  macros.lisp [See above]

- (DEF-RECORD NAME &REST MEMBERS)  macros.lisp
- - (BRAND &REST ARGS)  macros.lisp
- - (REGISTER-BRAND-DEFINITION STRUCT-NAME BRAND-FORM)  types/brand.lisp
- - - (PARSE-BRAND-DECLARATION BRAND-FORM)  types/brand.lisp
- - - (IS-BRAND-TYPE-P TYPE-NAME)  types/brand.lisp [See above]
- - - (FIND-STRUCT-DEFINITION-BY-NAME NAME-OR-SYMBOL)  structs.lisp [See above]
- - - (BRAND-ACTIVE-P BRAND-DEF)  types/brand.lisp [See above]
- - - (REGISTER-DERIVED-TYPE NEW-TYPE-NAME ORIGINAL-TYPE-NAME SUBST-MODE)  types/hierarchy.lisp [See above]
- - (REGISTER-STRUCT-DEFINITION NAME MEMBERS &OPTIONAL (CATEGORY STRUCT))  structs.lisp [See above]
- - (VALIDATE-AND-REORDER-STRUCT-ARGS STRUCT-NAME DEFINED-MEMBERS ARGS)  structs.lisp

- (DEF-SETTER NAME ARGS &BODY BODY)  macros.lisp
- - (DEF-FUNCTION NAME PARAMS &REST BODY-AND-LOCATION)  macros.lisp [See above]

- (DEF-STRUCT NAME &REST MEMBERS)  macros.lisp
- - (BRAND &REST ARGS)  macros.lisp [See above]
- - (REGISTER-BRAND-DEFINITION STRUCT-NAME BRAND-FORM)  types/brand.lisp [See above]
- - (REGISTER-STRUCT-DEFINITION NAME MEMBERS &OPTIONAL (CATEGORY STRUCT))  structs.lisp [See above]
- - (VALIDATE-AND-REORDER-STRUCT-ARGS STRUCT-NAME DEFINED-MEMBERS ARGS)  structs.lisp [See above]

- (DEF-TYPE NAME TYPE-SPEC)  macros.lisp
- - (VALID-TYPE-P TYPE-SPEC)  types/validation.lisp [See above]

- (DEF-UNARY-MATH-ANALYZER NAME NODE-CONSTRUCTOR OP-STRING)  analysis/ops.lisp
- - (ANALYZE-EXPRESSION EXPR ENV CONTEXT LOCATION)  analysis/core.lisp [See above]
- - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]

- (DEF-UNARY-MATH-CODEGEN NODE-TYPE INTRINSIC-NAME)  codegen.lisp
- - (GENERATE-NODE-IR (NODE SEMANTIC-DEVICE-VEC-LITERAL) BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP)  codegen.lisp [See above]
- - (SEMANTIC-NODE-TYPE NODE)  analysis/core.lisp [See above]
- - (CRISP-TYPE-TO-LLVM-TYPE TYPE-SPEC MODULE)  codegen/abi.lisp [See above]
- - (SEMANTIC-NODE-SOURCE-LOCATION NODE)  analysis/core.lisp [See above]

- (DUMP-ENV ENV &KEY (TITLE Environment Dump)) :CRISP.UTILS  utils.lisp

- (GENERATE-COMPARISON-IR BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP NODE OP-NODE-INT OP-NODE-FLOAT)  codegen.lisp
- - (GENERATE-NODE-IR (NODE SEMANTIC-DEVICE-VEC-LITERAL) BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP)  codegen.lisp [See above]
- - (GET-SINGLE-VALUE-TYPE NODE)  analysis/core.lisp [See above]

- (GET-TEMPLATE-SIGNATURE NAME CONCRETE-TYPES)  templates.lisp

- (IF+ TEST THEN &OPTIONAL ELSE)  macros.lisp

- (INITIALIZE-TEMPLATES)  templates.lisp

- (IS-ADDRESS-SPACE? X)  enums.lisp

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
- - - - - (GET-native-SIZE TYPE-SPEC)  structs.lisp [See above]
- - - - - (GET-TYPE-BASE TYPE-NAME)  types/hierarchy.lisp [See above]
- - - - - (FLATTEN-STRUCT-DATA-MEMBERS STRUCT-DEF)  types/hierarchy.lisp [RECURSION]
- - - - (RESOLVE-TYPE-ALIAS TYPE-SPEC)  types/validation.lisp [See above]
- - - (IS-SUBSTITUTABLE-FOR? SOURCE-TYPE TARGET-TYPE)  types/hierarchy.lisp [See above]

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

- (VALIDATE-070-01-VECTOR-METADATA META-PATH)  metadata-val.lisp

- (VALIDATE-070-03-MATRIX-METADATA META-PATH)  metadata-val.lisp

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
- - (COUNT-SUBSTRING NEEDLE HAYSTACK)  metadata-val.lisp

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

- (VALIDATE-DEF-REC-WITH-CT-IN-METADATA METADATA-PATH)  metadata-val.lisp
- - (%READ-METACRISP-FORMS PATH)  metadata-val.lisp
- - (%METACRISP-SECTION FORMS KEY)  metadata-val.lisp
- - (%METACRISP-FIND-KERNEL FORMS KERNEL-NAME)  metadata-val.lisp
- - - (%METACRISP-SECTION FORMS KEY)  metadata-val.lisp [See above]
- - (%FIND-RECORD-DEF RECORDS-SECTION NAME)  metadata-val.lisp
- - (%RECORD-MEMBER-COUNT REC-FORM)  metadata-val.lisp
- - (%FIND-DECL-ENTRY DECL-SIG NAME)  metadata-val.lisp

- (VALIDATE-DEF-RECORD-EXPLODE-IR IR-PATH)  metadata-val.lisp

- (VALIDATE-DEF-RECORD-EXPLOSION METADATA-PATH)  metadata-val.lisp

- (VALIDATE-DEF-RECORD-EXPLOSION-IR IR-PATH)  metadata-val.lisp

- (VALIDATE-DEF-RECORD-IN-METADATA METADATA-PATH)  metadata-val.lisp
- - (%READ-METACRISP-FORMS PATH)  metadata-val.lisp [See above]
- - (%METACRISP-SECTION FORMS KEY)  metadata-val.lisp [See above]
- - (%METACRISP-FIND-KERNEL FORMS KERNEL-NAME)  metadata-val.lisp [See above]
- - (%FIND-RECORD-DEF RECORDS-SECTION NAME)  metadata-val.lisp [See above]
- - (%RECORD-MEMBER-COUNT REC-FORM)  metadata-val.lisp [See above]
- - (%FIND-DECL-ENTRY DECL-SIG NAME)  metadata-val.lisp [See above]

- (VALIDATE-DEF-STRUCT-IN-METADATA METADATA-PATH)  metadata-val.lisp
- - (%READ-METACRISP-FORMS PATH)  metadata-val.lisp [See above]
- - (%METACRISP-SECTION FORMS KEY)  metadata-val.lisp [See above]
- - (%METACRISP-FIND-KERNEL FORMS KERNEL-NAME)  metadata-val.lisp [See above]
- - (%FIND-STRUCT-DEF STRUCTS-SECTION NAME)  metadata-val.lisp
- - (%RECORD-MEMBER-COUNT REC-FORM)  metadata-val.lisp [See above]
- - (%FIND-DECL-ENTRY DECL-SIG NAME)  metadata-val.lisp [See above]

- (VALIDATE-DEF-STRUCT-WITH-CT-IN-METADATA METADATA-PATH)  metadata-val.lisp
- - (%READ-METACRISP-FORMS PATH)  metadata-val.lisp [See above]
- - (%METACRISP-SECTION FORMS KEY)  metadata-val.lisp [See above]
- - (%METACRISP-FIND-KERNEL FORMS KERNEL-NAME)  metadata-val.lisp [See above]
- - (%FIND-STRUCT-DEF STRUCTS-SECTION NAME)  metadata-val.lisp [See above]
- - (%RECORD-MEMBER-COUNT REC-FORM)  metadata-val.lisp [See above]
- - (%FIND-DECL-ENTRY DECL-SIG NAME)  metadata-val.lisp [See above]

- (VALIDATE-DERIVED-ACCESSORS IR-PATH)  metadata-val.lisp

- (VALIDATE-DESCENDANT-DISTANCE IR-PATH)  metadata-val.lisp
- - (COUNT-SUBSTRING NEEDLE HAYSTACK)  metadata-val.lisp [See above]

- (VALIDATE-DIVISION-CHAIN-RULE IR-PATH)  metadata-val.lisp
- - (VALIDATE-GENERIC-GRAD-SIGNATURE IR-PATH FORWARD-NAME EXPECTED-COMMAS)  metadata-val.lisp [See above]

- (VALIDATE-FLOAT-LITERALS-IR IR-PATH)  metadata-val.lisp

- (VALIDATE-INTEGER-LITERALS-IR IR-PATH)  metadata-val.lisp

- (VALIDATE-MULTIPLE-SCRATCH-CELLS METADATA-PATH)  metadata-val.lisp

- (VALIDATE-MULTIPLY-CHAIN-RULE IR-PATH)  metadata-val.lisp
- - (VALIDATE-GENERIC-GRAD-SIGNATURE IR-PATH FORWARD-NAME EXPECTED-COMMAS)  metadata-val.lisp [See above]

- (VALIDATE-MULTIPLY-GRAD-METADATA PATHS)  metadata-val.lisp

- (VALIDATE-MY-KERNEL-SCRATCH-IR IR-PATH)  metadata-val.lisp

- (VALIDATE-NESTED-CHAIN-RULE IR-PATH)  metadata-val.lisp
- - (VALIDATE-GENERIC-GRAD-SIGNATURE IR-PATH FORWARD-NAME EXPECTED-COMMAS)  metadata-val.lisp [See above]

- (VALIDATE-NESTED-REC-IN-METADATA METADATA-PATH)  metadata-val.lisp
- - (%READ-METACRISP-FORMS PATH)  metadata-val.lisp [See above]
- - (%METACRISP-SECTION FORMS KEY)  metadata-val.lisp [See above]
- - (%METACRISP-FIND-KERNEL FORMS KERNEL-NAME)  metadata-val.lisp [See above]
- - (%FIND-RECORD-DEF RECORDS-SECTION NAME)  metadata-val.lisp [See above]
- - (%FIND-DECL-ENTRY DECL-SIG NAME)  metadata-val.lisp [See above]

- (VALIDATE-NESTED-STRUCT-IN-METADATA METADATA-PATH)  metadata-val.lisp
- - (%READ-METACRISP-FORMS PATH)  metadata-val.lisp [See above]
- - (%METACRISP-SECTION FORMS KEY)  metadata-val.lisp [See above]
- - (%METACRISP-FIND-KERNEL FORMS KERNEL-NAME)  metadata-val.lisp [See above]
- - (%FIND-STRUCT-DEF STRUCTS-SECTION NAME)  metadata-val.lisp [See above]
- - (%FIND-DECL-ENTRY DECL-SIG NAME)  metadata-val.lisp [See above]

- (VALIDATE-NO-BRAND-IN-METADATA METADATA-PATH)  metadata-val.lisp
- - (%READ-METACRISP-FORMS PATH)  metadata-val.lisp [See above]
- - (%METACRISP-SECTION FORMS KEY)  metadata-val.lisp [See above]
- - (%METACRISP-FIND-KERNEL FORMS KERNEL-NAME)  metadata-val.lisp [See above]
- - (%FIND-RECORD-DEF RECORDS-SECTION NAME)  metadata-val.lisp [See above]

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

- (VALIDATE-STRUCT-NO-BRAND-IN-METADATA METADATA-PATH)  metadata-val.lisp
- - (%READ-METACRISP-FORMS PATH)  metadata-val.lisp [See above]
- - (%METACRISP-SECTION FORMS KEY)  metadata-val.lisp [See above]
- - (%METACRISP-FIND-KERNEL FORMS KERNEL-NAME)  metadata-val.lisp [See above]
- - (%FIND-STRUCT-DEF STRUCTS-SECTION NAME)  metadata-val.lisp [See above]

- (VALIDATE-SUBTRACTION-CHAIN-RULE IR-PATH)  metadata-val.lisp
- - (VALIDATE-GENERIC-GRAD-SIGNATURE IR-PATH FORWARD-NAME EXPECTED-COMMAS)  metadata-val.lisp [See above]

- (VALIDATE-TOP-KERNEL-4-ARGS-IR IR-PATH)  metadata-val.lisp

- (VALIDATE-TRANSCENDENTAL-CHAIN-RULE IR-PATH)  metadata-val.lisp
- - (VALIDATE-GENERIC-GRAD-SIGNATURE IR-PATH FORWARD-NAME EXPECTED-COMMAS)  metadata-val.lisp [See above]

- (WITH-STRUCT-ACCESSORS STRUCT-TYPE BINDINGS &BODY BODY)  macros.lisp

