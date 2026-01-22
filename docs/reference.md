# Crisp Codebase Reference

Generated on 2026-01-22T22:44:49.545040Z

## File: `C:\Users\cperk\Documents\crisp\src\analysis\control.lisp`

### DEFUN `ENSURE-BRANCH-COMPATIBILITY`
- **Args**: `(THEN-NODE ELSE-NODE LOCATION)`

  > Unifies types of then/else branches. Returns (values unified-type new-then new-else).


---
### DEFUN `ANALYZE-IF-EXPRESSION-IMPL`
- **Args**: `(EXPR ENV LOCATION &KEY ENFORCE-CONSTANT)`

---
### DEFUN `ANALYZE-IF-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

---
### DEFUN `ANALYZE-STATIC-IF-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

---
### DEFUN `ANALYZE-WHEN-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

---
### DEFUN `ANALYZE-STATIC-WHEN-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

---
### DEFUN `ANALYZE-UNLESS-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

---
### DEFUN `ANALYZE-STATIC-UNLESS-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

---
### DEFUN `ANALYZE-LET-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes a `(let ...)` expression.


---
### DEFUN `ANALYZE-PROGN-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes a `(progn ...)` expression.


---
### DEFUN `ANALYZE-RETURN-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes a `(return ...)` expression.


---
### DEFUN `ANALYZE-FUNCTION-LITERAL`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes (function x) or #'(...)


---
### DEFUN `ANALYZE-FUNCALL-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes a (funcall f args...) form.


---
### DEFUN `ANALYZE-QUOTE`
- **Args**: `(EXPR ENV LOCATION)`

---
### DEFUN `ANALYZE-SIZEOF-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

---
### DEFUN `ANALYZE-COMPILER-NO-OP`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes a (compiler-no-op) form, which results in a void literal.  >    Used by compile-time macros (c-t-assert, c-t-output) to emit no code.


---
### DEFUN `ANALYZE-NESTED-DEF-FUNCTION`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes a nested `(def-function ...)` expression (e.g. from a template).


---
### DEFUN `ANALYZE-TEMPLATE-INSTANTIATION`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes a `(template-instantiation ...)` form, allowing nested def-functions.


---
### DEFUN `ANALYZE-EVAL-WHEN`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes (eval-when ...) forms by ignoring them in the runtime IR.  >    Side effects (like struct registration) should have already occurred during macro expansion.


---
### DEFUN `ANALYZE-IS-SET-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes (is-set? var). Returns 1 (true) if var is bound in env, 0 (false) otherwise.


---
### DEFUN `REGISTER-CONTROL-ANALYZERS`

---
## File: `C:\Users\cperk\Documents\crisp\src\analysis\core.lisp`

### DEFVAR `*ANALYSIS-ACCESS-MODE*`

---
### DEFUN `INITIALIZE-EXPRESSION-ANALYZERS`

  > Registers all expression analyzers.


---
### DEFUN `COMPILE-MODULE`
- **Args**: `(FORMS MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)`

  > Orchestrates the multi-pass compilation of a list of top-level forms.


---
### DEFUN `PROPAGATE-IMPLICIT-ARGUMENTS`

  > Phase 4: Traverses the call graph backwards from originators to find all carriers.


---
### DEFVAR `*SCANNING-FUNCTION-NAME*`

  > The name of the function currently being scanned in Pass 1.


---
### DEFVAR `*SCAN-CALLEES*`

---
### DEFVAR `*SCAN-IS-ORIGINATOR*`

---
### DEFGENERIC `SCAN-FORM`
- **Args**: `(FORM)`

---
### DEFGENERIC `SCAN-OPERATOR`
- **Args**: `(OP ARGS)`

---
### DEFUN `SHALLOW-ANALYZE-BODY`
- **Args**: `(FORMS)`

  > Performs a shallow, recursive walk of a function's body.  >   Returns two values:  >   1. A boolean indicating if a side-channel originator was found.  >   2. A list of all unique symbols found in the 'car' of lists (potential function calls).


---
### DEFUN `VISIT-TOPLEVEL-FORM`
- **Args**: `(FORM LOCATION VISITOR-FN)`

  > Recursively visits a top-level form, handling macros and progn.  >    Visitor-fn is called as (visitor-fn form location) for def-function forms.  >    Other forms are evaluated if they are not special forms handled by the walker.


---
### DEFUN `%COMPILE-STANDARD-FUNCTION`
- **Args**: `(FORM LOCATION MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT
              LOCATION-MAP)`

  > Helper: Compiles a standard (non-generic) function definition.


---
### DEFUN `COMPILE-DEF-FUNCTION`
- **Args**: `(FORM LOCATION MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT
              LOCATION-MAP)`

  > Compiles a single def-function form. Handles optional parameters by generating overloaded variants.


---
### DEFUN `WALK-CODE-FORMS`
- **Args**: `(FORMS VISITOR-FN)`

  > Walks top-level forms, handling macros and progn, and calling visitor-fn on def-function.


---
### DEFUN `ANALYZE-SIGNATURES-PASS`
- **Args**: `(FORMS)`

  > Pass 1: Iterates through forms to find and register function signatures.


---
### DEFUN `COMPILE-FORMS-PASS`
- **Args**: `(FORMS MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)`

  > Pass 2: Iterates through forms to perform full analysis and codegen.


---
### DEFUN `COMPILE-TOPLEVEL-FORM`
- **Args**: `(FORM LOCATION MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT
              LOCATION-MAP)`

  > Analyzes and compiles a single top-level form (used in Pass 2).


---
### DEFUN `CHECK-FOR-RECURSION-CYCLES`

  > Iterates through the call graph to find any recursive cycles.


---
### DEFUN `DETECT-CYCLE-FROM-NODE`
- **Args**: `(NODE VISITED VISITING)`

  > Performs a DFS from the given node to detect a cycle.


---
### DEFUN `FIND-VARIABLE-IN-ENV`
- **Args**: `(NAME ENV)`

  > Finds a variable definition in the environment.


---
### DEFUN `VALIDATE-RETURN-TYPES`
- **Args**: `(NAME BODY ENV DECLARED-RETURN-TYPES LOCATION)`

  > Analyzes the function body and validates return types.


---
### DEFUN `INTERNAL-COMPILE-FUNCTION`
- **Args**: `(NAME EXPLICIT-ENV RETURN-TYPE PARAMS BODY DECLARATIONS LOCATION)`

  > Core compilation logic for a function, accepting a pre-parsed environment.


---
### DEFUN `INTERNAL-DEF-FUNCTION`
- **Args**: `(NAME PARAMS DECLARATIONS BODY LOCATION)`

  > This is a wrapper around internal-compile-function that parses declarations.


---
### DEFUN `ANALYZE-BODY-EXPRESSIONS`
- **Args**: `(BODY-LIST ENV LOCATION)`

  > Recursively analyzes a list of expressions.


---
### DEFUN `ANALYZE-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

  > Recursively analyzes a *single* expression.


---
### DEFUN `ANALYZE-FUNCTION-CALL`
- **Args**: `(OP EXPR ENV LOCATION)`

  > Analyzes a call to a user-defined function.


---
### DEFUN `SEMANTIC-NODE-TYPE`
- **Args**: `(NODE)`

---
### DEFUN `SEMANTIC-NODE-SOURCE-LOCATION`
- **Args**: `(NODE)`

---
### DEFUN `GET-SINGLE-VALUE-TYPE`
- **Args**: `(NODE)`

  > Returns the type of a semantic node, assuming a single-value context.  >   If the node's type is a list (e.g., from a multi-value function call),  >   this returns the first type in the list. Otherwise, it returns the type as-is.


---
### DEFUN `WALK-AND-MAP-LOCATIONS`
- **Args**: `(EXPR LOCATION MAP COUNTER)`

  > Recursively walks an S-expression, populating a map from location paths to line numbers.


---
### DEFUN `GENERATE-LOCATION-MAP`
- **Args**: `(FORMS)`

  > Creates a map from S-expression location paths to virtual line numbers.


---
### DEFUN `COMPILE-CRISP-FORM-TO-IR-STRING`
- **Args**: `(CRISP-FORM &KEY (DEBUG-P NIL))`

  > Takes a single Crisp s-expression (like a def-function form),  >   compiles it, and returns its LLVM IR as a string.  >   This is a developer utility for REPL use and testing.


---
## File: `C:\Users\cperk\Documents\crisp\src\analysis\ops.lisp`

### DEFMACRO `DEF-BINARY-OP-ANALYZER`
- **Args**: `(NAME NODE-CONSTRUCTOR OP-STRING)`

---
### DEFMACRO `DEF-COMPARISON-ANALYZER`
- **Args**: `(NAME NODE-CONSTRUCTOR OP-STRING)`

---
### DEFUN `TRY-CONSTANT-FOLD`
- **Args**: `(NODE)`

  > Attempts to reduce a semantic node to a semantic-literal if possible.


---
### DEFUN `ANALYZE-INC!-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

---
### DEFUN `ANALYZE-DEC!-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

---
### DEFUN `ANALYZE-ATOMIC-ADD!-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

---
### DEFUN `ANALYZE-CAST-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes a to-XXXX or as-XXXX cast expression.


---
### DEFUN `ANALYZE-TRUNCATE-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes (truncate val) -> (values int rem).


---
### DEFUN `ANALYZE-VALUE-CAST-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes the generic (to type value) form.


---
### DEFUN `ANALYZE-GENERIC-AS-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes the generic (as type value) form.


---
### DEFUN `CREATE-IMPLICIT-CAST`
- **Args**: `(NODE TARGET-TYPE LOCATION)`

  > Wraps node in an implicit cast to target-type.


---
### DEFUN `ANALYZE-BITCAST-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

  > Handler for explicit (as-bits type val) or aliased calls.


---
### DEFUN `REGISTER-OPS-ANALYZERS`

---
## File: `C:\Users\cperk\Documents\crisp\src\analysis\structs.lisp`

### DEFUN `GET-ARRAY-ELEMENT-TYPE`
- **Args**: `(TYPE)`

  > Determines the element type of an array, pointer, or cell type. Returns NIL if unknown.


---
### DEFUN `GET-STRUCT-MEMBER-INDEX`
- **Args**: `(STRUCT-TYPE-NAME MEMBER-NAME)`

  > Helper to find the physical index of a struct member, accounting for padding.


---
### DEFUN `ANALYZE-STRUCT-CONSTRUCTION`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes a (%construct-struct type-name arg1 arg2 ...) form.


---
### DEFUN `ANALYZE-EXTRACT-STRUCT-MEMBER-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes a `%extract-struct-member` expression.  >    Form: (%extract-struct-member object-node index-literal)


---
### DEFUN `ANALYZE-INSERT-STRUCT-MEMBER-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes a `%insert-struct-member` expression.  >    Form: (%insert-struct-member object-node index-literal value-node)


---
### DEFUN `ANALYZE-AREF-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

---
### DEFUN `ANALYZE-SET!-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes a (set! target value) expression.


---
### DEFUN `ANALYZE-INCOMPLETE-TYPE-ACCESSOR`
- **Args**: `(OP EXPR ENV LOCATION)`

  > Attempts to resolve a call like (color~ obj) where obj is (shirt :color :blue).  >    Returns a semantic-node (literal) if resolved, or NIL if not applicable.


---
### DEFUN `ANALYZE-SCRATCH-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes a (make-scratch-cell ...) expression.  >  This marks the current function as an originator in BOTH analysis modes.


---
### DEFUN `REGISTER-STRUCT-ANALYZERS`

---
## File: `C:\Users\cperk\Documents\crisp\src\codegen.lisp`

### DEFUN `GET-OR-CREATE-DI-TYPE`
- **Args**: `(CRISP-TYPE DI-BUILDER DI-TYPE-CACHE)`

  > Gets a DIBasicType from a cache or creates it if it doesn't exist.


---
### DEFUN `GENERATE-DEBUG-INFO`
- **Args**: `(DI-BUILDER DI-COMPILE-UNIT FUNC FN-NAME FN-LOC RETURN-TYPE
              PARAM-NODES LOCATION-MAP)`

  > Generates and attaches DWARF debug info for the function.


---
### DEFUN `INITIALIZE-FUNCTION-PARAMETERS`
- **Args**: `(BUILDER FUNC PARAM-NODES MODULE VAR-ENV)`

  > Allocates stack space and stores function parameters.


---
### DEFUN `ENSURE-OPENCL-KERNEL-METADATA`
- **Args**: `(FUNC SEMANTIC-FUNCTION MODULE)`

  > Marks a function as a SPIR-V/PTX kernel if it's an entry point.  >    Sets the appropriate calling convention (76 for SPIR-V, 71 for PTX).  >      >    NOTE: Kernel argument metadata (address space, access qualifiers, etc.) is added  >    as text during IR printing for SPIR-V.


---
### DEFUN `%CHECK-EXISTING-FUNCTION`
- **Args**: `(EXISTING FN-NAME DI-BUILDER DI-COMPILE-UNIT FUNC
              CRISP-RETURN-TYPE PARAM-NODES LOCATION-MAP FN-LOC MODULE FN-TYPE)`

  > Helper: Handles redefinition or forward declaration of existing functions.


---
### DEFUN `%CREATE-NEW-FUNCTION`
- **Args**: `(FN-NAME FN-TYPE MODULE DI-BUILDER DI-COMPILE-UNIT
              CRISP-RETURN-TYPE PARAM-NODES LOCATION-MAP FN-LOC)`

  > Helper: Creates a new function and its debug info.


---
### DEFUN `GENERATE-FUNCTION-PROTOTYPE`
- **Args**: `(SEMANTIC-FUNCTION MODULE DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)`

  > Generates the LLVM function prototype and debug info.


---
### DEFUN `GENERATE-FUNCTION-BODY`
- **Args**: `(SEMANTIC-FUNCTION FUNC DI-SUBPROGRAM BUILDER MODULE DI-BUILDER
              LOCATION-MAP)`

  > Generates the body of the function.


---
### DEFUN `GENERATE-LLVM-IR`
- **Args**: `(SEMANTIC-FUNCTION MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT
              LOCATION-MAP)`

  > Top-level function to generate LLVM IR for a given semantic function.


---
### DEFGENERIC `GENERATE-NODE-IR`
- **Args**: `(NODE BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP)`

---
### DEFUN `GENERATE-EXPRESSION-IR`
- **Args**: `(BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP NODE)`

  > Recursively generates IR for a single expression node.


---
### DEFUN `RESOLVE-KEYWORD-CONSTANT`
- **Args**: `(KW)`

  > Resolves a keyword to its integer value by searching all registered enumerations.


---
### DEFUN `%GENERATE-KEYWORD-LITERAL-IR`
- **Args**: `(VALUE)`

  > Helper: Generates IR for keyword/symbol/quote literals.


---
### DEFUN `%GENERATE-CELL-LITERAL-IR`
- **Args**: `(BUILDER MODULE VAR-ENV TYPE-SPEC VALUE)`

  > Helper: Generates IR for cell literals (scratch cells).


---
### DEFUN `%GENERATE-ENUM-LITERAL-IR`
- **Args**: `(BUILDER VALUE LLVM-TYPE)`

  > Helper: Generates IR for enum literals.


---
### DEFUN `%GENERATE-SCALAR-LITERAL-IR`
- **Args**: `(BUILDER VALUE LLVM-TYPE CRISP-TYPE)`

  > Helper: Generates IR for scalar (int/float) literals.


---
### DEFUN `GET-TYPE-CAT-SAFE`
- **Args**: `(TYPE-NAME TYPE-OBJ)`

---
### DEFUN `BUILD-CAST-IF-NEEDED`
- **Args**: `(BUILDER FROM-VAL FROM-TYPE-NAME TO-TYPE-NAME)`

  > Builds LLVM cast instruction if types differ, with alias resolution.


---
### DEFMACRO `DEF-BINARY-OP-CODEGEN`
- **Args**: `(NODE-TYPE INT-INST FLOAT-INST ACCESSOR-PREFIX)`

---
### DEFUN `GENERATE-COMPARISON-IR`
- **Args**: `(BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP NODE
              OP-NODE-INT OP-NODE-FLOAT)`

  > Helper to generate IR for comparison operators (<, >, =, etc).


---
### DEFMACRO `DEF-COMPARISON-CODEGEN`
- **Args**: `(TYPE-NAME INT-PRED FLOAT-PRED ACCESSOR-PREFIX)`

---
### DEFUN `PREPARE-CALL-ARGUMENTS`
- **Args**: `(BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP ARG-NODES
              PARAM-TYPES PARAM-COUNT)`

  > Prepares arguments for a function call by generating IR, exploding values, and filling a CFFI array.


---
### DEFUN `%HANDLE-DIE-INTRINSIC`
- **Args**: `(BUILDER MODULE)`

  > Helper: Handles the compiler intrinsic DIE (llvm.trap).


---
### DEFUN `%BUILD-FUNCTION-CALL`
- **Args**: `(BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP NODE SIG
              CALLEE-NAME LLVM-FN-TYPE PARAM-NODES PARAM-COUNT
              RETURN-TYPE-NAMES)`

  > Helper: Builds the actual function call instruction.


---
### DEFUN `%GENERATE-LET-BINDING`
- **Args**: `(BINDING BUILDER MODULE LET-ENV DI-BUILDER DI-SCOPE LOCATION-MAP
              MEMOIZED-AGGREGATES)`

  > Helper: Generates IR for a single let binding.  >    Updates let-env with the new binding and returns the alloca.


---
### DEFUN `TERMINATOR-P`
- **Args**: `(BLOCK)`

  > Checks if a basic block already has a terminator instruction.


---
## File: `C:\Users\cperk\Documents\crisp\src\codegen\abi.lisp`

### DEFPARAMETER `*CACHED-INT32-TYPE*`

---
### DEFPARAMETER `*CACHED-INT64-TYPE*`

---
### DEFUN `GET-LLVM-RETURN-TYPE`
- **Args**: `(MODULE RETURN-TYPE-NAMES)`

  > Determines the LLVM return type from a list of Crisp type names.  >   Handles single values, void, and multiple values (by creating a struct).


---
### DEFUN `CRISP-TYPE-TO-LLVM-TYPE`
- **Args**: `(TYPE-SPEC MODULE)`

  > Resolves a Crisp type specifier (simple or parameterized) to an LLVM type.


---
### DEFUN `IS-GLOBAL-STORAGE-HANDLE-P`
- **Args**: `(TYPE-SPEC)`

  > Returns true if the type-spec represents a handle to global memory.


---
### DEFUN `GET-EXPANDED-TYPES`
- **Args**: `(TYPE-SPEC MODULE)`

  > Returns a list of LLVM types for a given Crisp type spec.  >    For 'cell', returns (ptr i64 i64). For 'storage', returns (ptr i64). For records, explodes recursively. For others, returns (type).  >      >    If *target-backend* is :spirv or :ptx, upgrade pointers in storage handles to Global Address Space (1).


---
### DEFUN `EXPLODE-VALUE`
- **Args**: `(BUILDER AGG-VAL TYPE-SPEC)`

  > Extracts components from an aggregate value if necessary.  >    Returns a list of LLVM values.


---
### DEFUN `IMPLODE-VALUE`
- **Args**: `(BUILDER COMPONENTS TYPE-SPEC MODULE)`

  > Combines components into an aggregate value if necessary.  >    Returns a single LLVM value.


---
### DEFUN `EXTRACT-PRIMARY-VALUE`
- **Args**: `(BUILDER VALUE TYPE-SPEC)`

  > If the type indicates an MVR (multiple return value) struct, extract the first element.  >    Otherwise return the value as is.  >    Used when a single-value context receives an MVR result.


---
### DEFUN `CREATE-LLVM-FUNCTION-TYPE`
- **Args**: `(MODULE RETURN-TYPES PARAM-NODES)`

  > Calculates the LLVM function type, handling parameter explosion.


---
## File: `C:\Users\cperk\Documents\crisp\src\compiler.lisp`

### DEFUN `RUN-TOOL-COMMAND`
- **Args**: `(ARGS &KEY (LOG-PREFIX ))`

  > Runs a command using uiop:run-program.


---
### DEFUN `RESOLVE-TOOL-EXECUTABLE`
- **Args**: `(TOOL-BASE)`

  > Resolves the path to a tool executable.   >    Prefers bundled version in bin/, falls back to system PATH.  >    Robustness:   >    - Checks versioned suffixes (e.g. llc-21) if base name not in path.  >    - Falls back to bundled tool if system tool is missing even if CRISP_USE_SYSTEM_TOOLS is set.


---
### DEFUN `FIND-SPIR-KERNELS`
- **Args**: `(IR-TEXT)`

  > Find all SPIR kernel functions in LLVM IR text.  >    Returns list of (function-name start-pos end-pos-of-signature).


---
### DEFUN `EXTRACT-KERNEL-PARAMS`
- **Args**: `(IR-TEXT FUNC-START FUNC-END)`

  > Extract parameter types from a kernel function signature.  >  Returns list of type strings (e.g., 'ptr addrspace(1)', 'i64').


---
### DEFUN `IR-TYPE-TO-OPENCL-METADATA`
- **Args**: `(IR-TYPE)`

  > Convert LLVM IR type to OpenCL metadata (addr-space, access-qual, type-name).  >  Returns (values addr-space-int access-qual-string type-name-string).


---
### DEFUN `GENERATE-KERNEL-METADATA`
- **Args**: `(PARAMS METADATA-ID-BASE)`

  > Generate LLVM metadata definitions for kernel parameters.  >  Returns (values metadata-refs-string metadata-defs-string next-id).


---
### DEFUN `INJECT-SPIR-KERNEL-METADATA`
- **Args**: `(IR-TEXT)`

  > Inject OpenCL kernel metadata for all SPIR kernels found in IR text.  >  Returns modified IR text with metadata.


---
### DEFUN `COMPILE-TO-SPIRV`
- **Args**: `(MODULE OUTPUT-PATH)`

  > Compiles an LLVM Module to SPIR-V using the external toolchain.


---
### DEFUN `COMPILE-TO-PTX`
- **Args**: `(MODULE OUTPUT-PATH &KEY (COMPUTE-CAPABILITY sm_50))`

  > Compiles an LLVM Module to PTX using llc.  >  COMPUTE-CAPABILITY: Target GPU architecture (sm_50, sm_75, sm_86, etc.)  >                      sm_50 = Maxwell (good default for compatibility)


---
### DEFUN `INITIALIZE-COMPILER`
- **Args**: `(&KEY (LOG-LEVEL INFO) (RUNTIME-CHECKS NIL))`

  > A master initialization function for the Crisp compiler.  > This should be called by any entry point into the system (REPL, executable, CI).


---
### DEFUN `REGISTER-BUILTINS`

  > Registers built-in types and structs like 'storage' using def-struct semantics.


---
## File: `C:\Users\cperk\Documents\crisp\src\enums.lisp`

### DEFMACRO `DEF-ENUMERATION`
- **Args**: `(NAME &REST SPECS)`

  > Defines a new enumeration type.  >    Usage: (def-enumeration address-space (:global 1) :local :private)


---
### DEFUN `IS-ADDRESS-SPACE?`
- **Args**: `(X)`

---
### DEFUN `ADDRESS-SPACE-VALUE`
- **Args**: `(K)`

  > Returns the integer value for an address space keyword, sensitive to *target-backend*.


---
## File: `C:\Users\cperk\Documents\crisp\src\environment.lisp`

### DEFUN `PARSE-FUNCTION-DECLARATIONS`
- **Args**: `(PARAMS DECLARATIONS)`

  > Parses a function's declarations and returns its environment and return type.  >    Supports interleaved type syntax: ((p type))


---
### DEFUN `BIND-KEYWORD-ARGS`
- **Args**: `(FULL-ENV EXPLICIT-ARGS KEY-IDX NAME)`

  > Helper for resolve-argument-bindings. Handles &key argument parsing.  >    Returns (values active-env remainder-env error-message)


---
### DEFUN `INJECT-DEFAULTS`
- **Args**: `(REMAINDER-ENV DEFAULTS)`

  > Helper for resolve-argument-bindings. Generates bindings for missing parameters.


---
### DEFUN `RESOLVE-ARGUMENT-BINDINGS`
- **Args**: `(GENERIC-DEF EXPLICIT-ARG-TYPES)`

  > Resolves the active environment and default bindings for a generic instantiation.  >    Returns (values active-env injected-bindings error-message).


---
### DEFUN `INSTANTIATE-GENERIC-FUNCTION`
- **Args**: `(GENERIC-DEF EXPLICIT-ARG-TYPES LOCATION)`

  > Instantiates a lazy generic function variant for the given argument types.


---
### DEFUN `%FIND-ENTRY-POINT-DECLARATION`
- **Args**: `(DECLARE-FORMS)`

  > Helper: Returns T if any declare form contains an entry-point declaration.


---
### DEFUN `%VALIDATE-KERNEL-RETURN-TYPE`
- **Args**: `(RETURN-TYPES)`

  > Helper: Validates that kernel return types are void. Signals error if non-void.


---
### DEFUN `%REGISTER-GENERIC-FUNCTION`
- **Args**: `(NAME PARAMS ENV RETURN-TYPES DECLARE-FORMS EXTRACTED-DEFAULTS
              KEY-IDX BODY LOCATION)`

  > Helper: Registers a generic function (with &optional or &key parameters) for lazy instantiation.


---
### DEFUN `%REGISTER-STANDARD-FUNCTION`
- **Args**: `(NAME ENV RETURN-TYPES DECLARE-FORMS LOCATION)`

  > Helper: Registers a standard function signature (eager registration).


---
### DEFUN `REGISTER-FUNCTION-SIGNATURE`
- **Args**: `(FORM LOCATION)`

  > Extracts and registers a function's signature without analyzing its body.  >    Handles optional parameters by generating overloaded signatures.


---
### DEFVAR `*TEMPLATE-REGISTRY*`

  > Maps template names to their generator macros.


---
### DEFVAR `*KERNEL-DECLARED-SIGNATURES*`

  > Maps kernel names to their declared (high-level) parameter types, before explosion.


---
### DEFUN `REGISTER-OVERLOAD`
- **Args**: `(ALIAS REAL-NAME)`

  > Registers the signature(s) of `real-name` under `alias` to generic overloading/aliasing.


---
### DEFUN `INJECT-IMPLICIT-ARGUMENTS`
- **Args**: `(NAME EXPLICIT-ENV)`

  > Injects implicit arguments into the environment if the function is a carrier.


---
### DEFUN `SCAN-FOR-CARRIERS`
- **Args**: `(NAME BODY)`

  > Performs a single-pass look-ahead to detect if the function is a carrier.


---
### DEFUN `DETECT-AND-REGISTER-IMPLICIT-TEMPLATE`
- **Args**: `(NAME EXPLICIT-ENV RETURN-TYPE PARAMS BODY DECLARATIONS)`

  > Detects if a function is an implicit template (e.g. has function-type args),  >    and if so, registers it as a template and returns T. Otherwise returns NIL.


---
### DEFUN `PARSE-TYPE-SPECIFIER`
- **Args**: `(SPEC)`

  > Parses a single type specifier, handling basic types, parameterized types,  >    and function types like #'(int => int).


---
### DEFUN `ANALYZE-RETURN-TYPE-FROM-SPEC`
- **Args**: `(FN-SPEC)`

  > Parses '(int int => int int)' and returns a list of types.


---
### DEFUN `ANALYZE-ENVIRONMENT-FROM-SPEC`
- **Args**: `(PARAMS FN-SPEC)`

  > Builds the environment from the signature. Returns (values env optional-start-index defaults-alist).


---
### DEFUN `ANALYZE-RETURN-TYPE-FROM-LIST`
- **Args**: `(DECLARATIONS)`

  > Finds and returns the return-type(s) from a (return-type ...) decl.


---
### DEFUN `ANALYZE-ENVIRONMENT-FROM-LIST`
- **Args**: `(PARAMS DECLARATIONS)`

  > Builds the environment from standard CL (type type-spec vars...) declarations.


---
## File: `C:\Users\cperk\Documents\crisp\src\errors.lisp`

## File: `C:\Users\cperk\Documents\crisp\src\hoist-l0\main.lisp`

### DEFUN `MAIN`

  > Entry point for crisp-hoist-l0.exe


---
### DEFUN `GENERATE-L0-LAUNCHER`
- **Args**: `(METACRISP-PATH)`

  > Generate Level Zero C++ launcher code from metacrisp file.


---
### DEFUN `GENERATE-CPP-PREAMBLE`
- **Args**: `(STREAM METACRISP-PATH KERNEL-NAME OUTPUT-NAME)`

  > Generate C++ file preamble comment


---
### DEFUN `GENERATE-CPP-INCLUDES`
- **Args**: `(STREAM)`

  > Generate C++ includes


---
### DEFUN `GENERATE-CPP-STRUCTS`
- **Args**: `(STREAM STRUCTS)`

  > Generate C++ struct definitions from metadata


---
### DEFUN `GENERATE-CPP-TYPEDEFS`
- **Args**: `(STREAM ALIASES)`

  > Generate C++ typedef declarations from type aliases


---
### DEFUN `GENERATE-CPP-HELPERS`
- **Args**: `(STREAM)`

  > Generate C++ helper functions


---
### DEFUN `GENERATE-CPP-MAIN`
- **Args**: `(STREAM KERNEL-NAME SPV-PATH DECLARED-SIG ALIASES)`

  > Generate C++ main function


---
### DEFUN `GENERATE-L0-INIT`
- **Args**: `(STREAM)`

  > Generate Level Zero initialization code


---
### DEFUN `GENERATE-MODULE-LOADING`
- **Args**: `(STREAM SPV-PATH)`

  > Generate SPIR-V module loading code


---
### DEFUN `GENERATE-KERNEL-LAUNCH`
- **Args**: `(STREAM KERNEL-NAME DECLARED-SIG ALIASES)`

  > Generate kernel creation and launch code. Returns list of USM allocations.


---
### DEFUN `GENERATE-KERNEL-ARGUMENTS`
- **Args**: `(STREAM DECLARED-SIG)`

  > Generate kernel argument setup code


---
### DEFUN `RESOLVE-TYPE-ALIAS`
- **Args**: `(TYPE ALIASES)`

---
### DEFUN `CELL-TYPE-P`
- **Args**: `(PARAM-TYPE)`

  > Check if a parameter type is a cell type


---
### DEFUN `CELL-BASE-TYPE`
- **Args**: `(PARAM-TYPE)`

  > Extract the base type from a cell type like (cell int ...)


---
### DEFUN `GENERATE-KERNEL-ARGUMENTS-WITH-USM`
- **Args**: `(STREAM DECLARED-SIG ALIASES CONTEXT-VAR DEVICE-VAR)`

  > Generate kernel argument setup code with USM allocation for cells


---
## File: `C:\Users\cperk\Documents\crisp\src\hoist-l0\package.lisp`

## File: `C:\Users\cperk\Documents\crisp\src\hoist\codegen-base.lisp`

### DEFUN `CRISP-TYPE-TO-CPP-TYPE`
- **Args**: `(CRISP-TYPE)`

  > Convert a Crisp type to C++ type string.


---
### DEFUN `FORMAT-CPP-IDENTIFIER`
- **Args**: `(LISP-SYMBOL)`

  > Convert Lisp symbol to C++-safe identifier.


---
## File: `C:\Users\cperk\Documents\crisp\src\hoist\common.lisp`

### DEFUN `PARSE-METACRISP-FILE`
- **Args**: `(FILEPATH)`

  > Parse a .metacrisp file and return the data structure.


---
### DEFUN `METACRISP-KERNELS`
- **Args**: `(METACRISP-DATA)`

  > Extract kernels list from metacrisp data.


---
### DEFUN `METACRISP-ALIASES`
- **Args**: `(METACRISP-DATA)`

  > Extract type aliases from metacrisp data.


---
### DEFUN `METACRISP-STRUCTS`
- **Args**: `(METACRISP-DATA)`

  > Extract struct definitions from metacrisp data.


---
## File: `C:\Users\cperk\Documents\crisp\src\hoist\package.lisp`

## File: `C:\Users\cperk\Documents\crisp\src\llvm-bindings.lisp`

### DEFCONSTANT `+LLVM-VOID-TYPE-KIND+`

---
### DEFCONSTANT `+LLVM-HALF-TYPE-KIND+`

---
### DEFCONSTANT `+LLVM-FLOAT-TYPE-KIND+`

---
### DEFCONSTANT `+LLVM-DOUBLE-TYPE-KIND+`

---
### DEFCONSTANT `+LLVM-INTEGER-TYPE-KIND+`

---
### DEFCONSTANT `+LLVM-FUNCTION-TYPE-KIND+`

---
### DEFCONSTANT `+LLVM-STRUCT-TYPE-KIND+`

---
### DEFCONSTANT `+LLVM-ARRAY-TYPE-KIND+`

---
### DEFCONSTANT `+LLVM-POINTER-TYPE-KIND+`

---
### DEFCONSTANT `+LLVM-VECTOR-TYPE-KIND+`

---
### DEFUN `LLVM-TYPE-KIND-IS-POINTER?`
- **Args**: `(TY)`

---
### DEFCONSTANT `+LLVM-INT-EQ+`

---
### DEFCONSTANT `+LLVM-INT-NE+`

---
### DEFCONSTANT `+LLVM-INT-UGT+`

---
### DEFCONSTANT `+LLVM-INT-UGE+`

---
### DEFCONSTANT `+LLVM-INT-ULT+`

---
### DEFCONSTANT `+LLVM-INT-ULE+`

---
### DEFCONSTANT `+LLVM-INT-SGT+`

---
### DEFCONSTANT `+LLVM-INT-SGE+`

---
### DEFCONSTANT `+LLVM-INT-SLT+`

---
### DEFCONSTANT `+LLVM-INT-SLE+`

---
### DEFCONSTANT `+LLVM-REAL-OEQ+`

---
### DEFCONSTANT `+LLVM-REAL-OGT+`

---
### DEFCONSTANT `+LLVM-REAL-OGE+`

---
### DEFCONSTANT `+LLVM-REAL-OLT+`

---
### DEFCONSTANT `+LLVM-REAL-OLE+`

---
### DEFCONSTANT `+LLVM-REAL-ONE+`

---
### DEFCONSTANT `+LLVM-REAL-ORD+`

---
### DEFCONSTANT `+LLVM-REAL-UNO+`

---
### DEFCONSTANT `+LLVM-REAL-UEQ+`

---
### DEFCONSTANT `+LLVM-REAL-UGT+`

---
### DEFCONSTANT `+LLVM-REAL-UGE+`

---
### DEFCONSTANT `+LLVM-REAL-ULT+`

---
### DEFCONSTANT `+LLVM-REAL-ULE+`

---
### DEFCONSTANT `+LLVM-REAL-UNE+`

---
## File: `C:\Users\cperk\Documents\crisp\src\macros.lisp`

### DEFMACRO `LET`
- **Args**: `(BINDINGS &BODY BODY)`

  > A unified 'let' for Crisp that works in both Kernels and Macros.  >    - It is SEQUENTIAL (like CL:LET*).  >    - It supports Multi-Value-Binding (MVB) destructuring.  >      >    Example:  >      (let ((a 1)  >            (b 2)  >            ((q r) (floor 10 3)))  >        (+ a b q r))  >   >    This macro expands into a nest of CL:LET* and CL:MULTIPLE-VALUE-BIND  >    forms, suitable for execution in the Lisp host (macros/tests).  >      >    When compiling Kernels, the Crisp Compiler intercepts the 'let' symbol  >    directly and uses its own semantic analyzer, ignoring this macro.


---
### DEFMACRO `WHEN`
- **Args**: `(TEST &BODY BODY)`

---
### DEFMACRO `UNLESS`
- **Args**: `(TEST &BODY BODY)`

---
### DEFMACRO `COND`
- **Args**: `(&REST CLAUSES)`

---
### DEFMACRO `RETURN`
- **Args**: `(&OPTIONAL VALUE)`

  > Crisp's special RETURN form. Expands to an explicit-return node.


---
### DEFMACRO `IF+`
- **Args**: `(TEST THEN &OPTIONAL ELSE)`

  > Compile-time conditional. Evaluates TEST at macro-expansion time.  >    Errors if TEST cannot be evaluated (e.g. relies on runtime values).


---
### DEFUN `COMPILER-NO-OP`

  > A no-op function that returns no values.   >    Used as the expansion target for compile-time macros when evaluated in the host environment.


---
### DEFMACRO `C-T-OUTPUT`
- **Args**: `(&REST ARGS)`

  > Compile-Time Output. Evaluates arguments at macro-expansion time and prints them.


---
### DEFMACRO `DEF-FUNCTION`
- **Args**: `(NAME PARAMS &REST BODY-AND-LOCATION)`

  > Defines a new, thread-level Crisp function.


---
### DEFUN `STRICT-VALID-TYPE-P`
- **Args**: `(SPEC)`

---
### DEFMACRO `DEF-KERNEL-EXACT`
- **Args**: `(NAME PARAMS &REST BODY)`

  > Defines a GPU Kernel with exact ABI control (Raw Scalars).  >    - Name must be valid C identifier (no dashes).  >    - No implicit arguments or marshalling by the compiler.  >    - Return type is implicitly NIL (void).


---
### DEFUN `%STORAGE-HANDLE-TYPE-P`
- **Args**: `(TYPE-SPEC)`

  > Returns T if the type-spec refers to a storage handle (cell, tensor, etc.).


---
### DEFUN `%RESOLVE-ALIAS-STRICT`
- **Args**: `(SPEC)`

---
### DEFUN `%RESOLVE-ALIAS-STRICT-CHECKED`
- **Args**: `(SPEC SEEN)`

---
### DEFUN `%INCOMPLETE-STORAGE-HANDLE-P`
- **Args**: `(TYPE-SPEC)`

  > Returns T if the type-spec is a storage handle but is missing explicit required keys (address-space, access).


---
### DEFUN `%EXPLODE-KERNEL-ARGS`
- **Args**: `(PARAMS SIGNATURE)`

  > Explodes storage handle parameters into raw scalars.  >    Returns (VALUES exploded-params exploded-signature-types reassembly-bindings).


---
### DEFUN `%PARSE-KERNEL-TYPE-DECLARATIONS`
- **Args**: `(PARAMS DECLARATIONS)`

  > Helper: Parses type declarations and builds a hash map of param -> type.


---
### DEFUN `%VALIDATE-KERNEL-PARAMETERS`
- **Args**: `(PARAMS TYPE-MAP NAME)`

  > Helper: Validates that kernel parameters are complete and not voidp.


---
### DEFUN `PARSE-KERNEL-SIGNATURE`
- **Args**: `(NAME PARAMS BODY)`

  > Parses kernel parameters and body, performing validation and type extraction.  >    Returns (values exploded-params exploded-types reassembly-bindings raw-body other-decls).


---
### DEFMACRO `DEF-KERNEL`
- **Args**: `(NAME PARAMS &REST BODY)`

  > Defines a GPU Kernel (Entry Point).  >      >    Constraint: All parameter types MUST be complete.  >    Incomplete types (missing compile-time properties) are forbidden at the kernel boundary  >    because the host must know the exact layout to marshall arguments.


---
### DEFMACRO `WITH-STRUCT-ACCESSORS`
- **Args**: `(STRUCT-TYPE BINDINGS &BODY BODY)`

  > Iterates over the members of a struct type, binding accessor symbols to the provided variables.  >    Bindings: (aos-var [soa-var] [:access type])  >    Returns a PROGN containing the expanded body forms.


---
### DEFMACRO `DEF-TYPE`
- **Args**: `(NAME TYPE-SPEC)`

  > Defines a type alias.  >    Example: (def-type T int)


---
### DEFUN `%GENERATE-STRUCT-ACCESSOR`
- **Args**: `(MEMBER-SPEC NAME PKG RUNTIME-INDEX)`

  > Helper: Generates accessor (and setter) for a single struct member.  >    Returns (values accessor-form new-runtime-index).


---
### DEFUN `%GENERATE-RAW-ACCESSOR`
- **Args**: `(MEMBER-SPEC NAME PKG RUNTIME-INDEX)`

  > Helper: Generates raw accessor for a runtime struct member.  >    Returns (values accessor-form new-runtime-index).


---
### DEFMACRO `DEF-STRUCT`
- **Args**: `(NAME &REST MEMBERS)`

  > Defines a new Crisp struct type.


---
### DEFMACRO `DEF-RECORD`
- **Args**: `(NAME &REST MEMBERS)`

  > Defines a new Crisp record type (virtual struct).


---
### DEFMACRO `DEF-SETTER`
- **Args**: `(NAME ARGS &BODY BODY)`

  > Defines a setter function (which is just a def-function but semantically intended for use with set!).  >    The return type is determined by the body.


---
### DEFMACRO `SETF`
- **Args**: `(PLACE VALUE &REST PAIRS)`

  > Custom setf implementation mapping (setf (f x) y) to (f_set! x y).


---
### DEFMACRO `R-T-ASSERT`
- **Args**: `(TEST &REST ARGS)`

  > Asserts that TEST is true at runtime. If not, terminates kernel.  >    Args (message strings etc) are currently ignored.


---
### DEFMACRO `C-T-ASSERT`
- **Args**: `(CONDITION MESSAGE)`

  > Compile-Time Assertion.


---
### DEFMACRO `R-T-ASSERT-0`
- **Args**: `(TEST &REST ARGS)`

  > Asserts that TEST is true at runtime (placeholder for thread-0 check).


---
### DEFMACRO `MARSHALL-CELL`
- **Args**: `(TYPE-ALIAS BYTE-SIZE PTR OFFSET)`

  > Marshals raw kernel arguments into a Cell struct.  >    Usage: (marshall-cell out-c byte-size ptr offset)


---
## File: `C:\Users\cperk\Documents\crisp\src\main.lisp`

### DEFUN `PRINT-COMPILER-ERROR`
- **Args**: `(C FILENAME)`

  > Prints a formatted compiler error to *error-output*.


---
### DEFUN `INITIALIZE-DEBUG-CONTEXT`
- **Args**: `(DI-BUILDER FILEPATH)`

  > Creates and returns the top-level DICompileUnit for a file.


---
### DEFUN `PARSE-CLI-ARGS`
- **Args**: `(ARGS)`

  > Parses command-line arguments and returns (values files output-file debug-p single-pass-p targets metadata-p hoist-targets).


---
### DEFUN `GET-HOISTER-BINARY-PATH`
- **Args**: `(HOIST-ID)`

  > Returns path to crisp-hoist-{id}.exe (or .bin on Unix)


---
### DEFUN `INVOKE-HOISTER`
- **Args**: `(HOIST-ID METACRISP-FILE)`

  > Invokes crisp-hoist-{id}.exe with the given .metacrisp file


---
### DEFUN `COMPILE-FILES`
- **Args**: `(FILES OUTPUT-FILE DEBUG-P SINGLE-PASS-P TARGETS METADATA-P
              HOIST-TARGETS)`

  > Compiles the given files, iterating over requested targets, then invokes hoisters.


---
### DEFUN `MAIN`

  > Main entry point for the crisp-compile executable.


---
## File: `C:\Users\cperk\Documents\crisp\src\mangling.lisp`

### DEFVAR `*TEMPLATE-ARITY-LOOKUP-FN*`

  > A hook for looking up the arity of a template by name (symbol or string).  >    Should be set by the templates module. Returns integer or nil.


---
### DEFUN `SPLIT-STRING`
- **Args**: `(STRING DELIMITER)`

  > Splits a string by a character delimiter.


---
### DEFUN `MANGLE-TEMPLATE-STRUCT-NAME`
- **Args**: `(NAME PARAMS)`

  > Generates the mangled name for a struct template instance. e.g. POINT (FLOAT) -> POINT_FLOAT


---
### DEFUN `RECONSTRUCT-ONE-ARG`
- **Args**: `(TOKENS PACKAGE)`

  > Reads exactly one logical form (atom or template-expr) from tokens.


---
### DEFUN `RECONSTRUCT-N-ARGS`
- **Args**: `(TOKENS N PACKAGE)`

  > Consumes N arguments from tokens.


---
### DEFUN `RECONSTRUCT-TEMPLATE-ARGS`
- **Args**: `(TOKENS PACKAGE)`

  > Recursively groups tokens into lists based on template arity.  >    tokens: list of strings.  >    package: the fallback package for interning.  >    Returns: (values property-list remaining-tokens)


---
### DEFUN `UNMANGLE-TEMPLATE-STRUCT-NAME`
- **Args**: `(SYMBOL)`

  > Attempts to reverse mangling for known parameterized types like CELL.  >    Returns the list form (e.g. (CELL FLOAT :GLOBAL :READ-WRITE)) or NIL.


---
### DEFUN `MANGLE-PARAM-TYPE-NAME`
- **Args**: `(TYPE)`

  > Helper to mangle a type specifier for function names.


---
### DEFUN `MANGLE-FUNCTION-VARIANT-NAME`
- **Args**: `(BASE-NAME PARAM-TYPES)`

---
### DEFUN `MANGLE-TYPE-SPEC`
- **Args**: `(TYPE-SPEC)`

  > Creates a string representation of a type spec for name mangling.


---
## File: `C:\Users\cperk\Documents\crisp\src\metadata-val.lisp`

### DEFUN `VALIDATE-KERNEL-METADATA`
- **Args**: `(METADATA-PATH KERNEL-NAME &KEY (TARGETS NIL TARGETS-P))`

---
### DEFUN `VALIDATE-10-BASICS-META`
- **Args**: `(PATH)`

---
### DEFUN `VALIDATE-10-BASICS-SPV`
- **Args**: `(PATH)`

---
### DEFUN `VALIDATE-10-BASICS-MULTI`
- **Args**: `(PATH)`

---
### DEFUN `VALIDATE-12-MULTIPLE-KERNELS`
- **Args**: `(PATHS)`

  > Validates that multiple kernel metadata files are generated.


---
### DEFUN `VALIDATE-DEF-RECORD-EXPLOSION`
- **Args**: `(METADATA-PATH)`

  > Validates that def-record types are exploded in physical signatures.


---
### DEFUN `VALIDATE-SCRATCH-CELL-EXPLOSION`
- **Args**: `(METADATA-PATH)`

  > Validates that scratch cells explode to 3 slots in metadata.


---
### DEFUN `VALIDATE-DEF-RECORD-EXPLOSION-IR`
- **Args**: `(IR-PATH)`

  > Validates that def-record types are exploded in LLVM IR signatures.  >    Takes a path to a .ll file containing LLVM IR.


---
### DEFUN `VALIDATE-SCRATCH-CELL-EXPLOSION-IR`
- **Args**: `(IR-PATH)`

  > Validates that scratch cells explode to 3 LLVM parameters in IR signatures.  >    Checks for: ptr addrspace(N), i64 (size), i64 (offset).  >      >    Example expected signature:  >    define i32 @kernel_cell_int_global_read_write_int(ptr addrspace(1) %0, i64 %1, i64 %2, i32 %3)  >    where %0, %1, %2 are the exploded cell (ptr, size, offset) and %3 is the explicit int param.


---
### DEFUN `VALIDATE-TOP-KERNEL-4-ARGS-IR`
- **Args**: `(IR-PATH)`

  > Validates that top_kernel has exactly 4 parameters (3 from cell + 1 int).


---
### DEFUN `VALIDATE-DEF-RECORD-EXPLODE-IR`
- **Args**: `(IR-PATH)`

  > Validates that v-point def-record explodes to 2 i32 parameters.


---
### DEFUN `VALIDATE-MY-KERNEL-SCRATCH-IR`
- **Args**: `(IR-PATH)`

  > Validates that my_kernel has implicit scratch cell parameters.


---
### DEFUN `VALIDATE-KERNEL-NAME-EXACT-IR`
- **Args**: `(IR-PATH EXPECTED-NAME)`

  > Validates that kernel has exact name (case-sensitive).


---
### DEFUN `VALIDATE-C-STYLE-NAME-IR`
- **Args**: `(IR-PATH)`

---
### DEFUN `VALIDATE-CALL-FUNCTION-IR`
- **Args**: `(IR-PATH)`

---
### DEFUN `VALIDATE-CALL-FUNCTION-F-IR`
- **Args**: `(IR-PATH)`

---
### DEFUN `VALIDATE-RETURN-7-IR`
- **Args**: `(IR-PATH)`

---
### DEFUN `VALIDATE-CELL-ADD-I-IR`
- **Args**: `(IR-PATH)`

---
### DEFUN `VALIDATE-CELL-ADD-F-IR`
- **Args**: `(IR-PATH)`

---
## File: `C:\Users\cperk\Documents\crisp\src\metadata.lisp`

### DEFVAR `*EMIT-METADATA*`

  > If T, the compiler will generate a .metacrisp sidecar file for each orchestration/kernel.


---
### DEFUN `VALIDATE-METADATA-DEF-TYPE`
- **Args**: `(METADATA-PATH TYPE-NAME TARGET-TYPE)`

---
### DEFUN `VALIDATE-01-ALIASES`
- **Args**: `(METADATA-PATH)`

---
### DEFUN `VALIDATE-STRUCT-PRESENCE`
- **Args**: `(METADATA-PATH EXPECTED-STRUCTS &KEY (UNEXPECTED-STRUCTS NIL))`

---
### DEFUN `VALIDATE-04-BASIC-STRUCT`
- **Args**: `(METADATA-PATH)`

---
### DEFUN `VALIDATE-06-NESTED-STRUCTS`
- **Args**: `(METADATA-PATH)`

---
### DEFUN `COLLECT-KERNEL-DEPENDENCIES`
- **Args**: `(KERNEL-NAMES)`

---
### DEFUN `SORT-STRUCTS-BY-DEPENDENCY`
- **Args**: `(STRUCT-NAMES)`

---
### DEFUN `STRIP-PACKAGE-QUALIFIERS`
- **Args**: `(TYPE-SPEC)`

  > Recursively strips package qualifiers from symbols in a type specification.  >    Returns the type spec with bare symbol names (no CRISP.COMPILER:: prefixes).  >      >    Examples:  >      CRISP.COMPILER:INT -> INT  >      (CRISP.COMPILER:CELL CRISP.COMPILER:FLOAT :GLOBAL :READ-WRITE)   >        -> (CELL FLOAT :GLOBAL :READ-WRITE)  >      (C-POINTER ADDRESS-SPACE GLOBAL) -> (C-POINTER ADDRESS-SPACE GLOBAL)


---
### DEFUN `PRINT-WITHOUT-PACKAGES`
- **Args**: `(OBJ STREAM)`

  > Prints an object to stream without any package qualifiers.  >    Uses *package* context to avoid printing qualifiers.


---
### DEFUN `SERIALIZE-ALIASES`
- **Args**: `(STREAM ALIASES-HASH)`

---
### DEFUN `SERIALIZE-STRUCTS`
- **Args**: `(STREAM STRUCTS-HASH)`

---
### DEFUN `EXTRACT-DEFINED-KERNELS`
- **Args**: `(FORMS)`

---
### DEFUN `GENERATE-METADATA-FOR-FILE`
- **Args**: `(INPUT-PATH OUTPUT-PATH &KEY (OUTPUT-TARGETS NIL)
              (SOURCE-FILE NIL) (FORMS NIL))`

---
### DEFUN `GET-PHYSICAL-WIDTH`
- **Args**: `(TYPE)`

---
### DEFUN `GENERATE-PHYSICAL-SIGNATURE`
- **Args**: `(SIG-OR-PARAMS)`

---
### DEFUN `VALIDATE-14-PHYSICAL-SIGNATURE`
- **Args**: `(PATHS)`

---
### DEFUN `GENERATE-DECLARED-SIGNATURE`
- **Args**: `(SIG &OPTIONAL DECLARED-PARAMS)`

---
### DEFUN `GENERATE-IMPLICIT-SIGNATURE`
- **Args**: `(SIG DECLARED-PARAMS)`

---
### DEFUN `SERIALIZE-KERNELS`
- **Args**: `(OUTPUT-STREAM KERNEL-NAMES &KEY SOURCE OUTPUT-TARGETS)`

---
### DEFUN `VALIDATE-18-IMPLICIT-SIGNATURE`
- **Args**: `(&OPTIONAL (PATHS NIL))`

---
## File: `C:\Users\cperk\Documents\crisp\src\package.lisp`

## File: `C:\Users\cperk\Documents\crisp\src\parameters.lisp`

### DEFSTRUCT `PARAMETER-DEF`

  > Represents a function parameter with its type, kind, and metadata.  >    Replaces the legacy list format: (name type :kind kind ...)


---
## File: `C:\Users\cperk\Documents\crisp\src\semantic.lisp`

### DEFSTRUCT `CRISP-TYPE`

  > Represents a Crisp type.


---
### DEFSTRUCT `FUNCTION-SIGNATURE`

  > Represents the full signature of a Crisp function.


---
### DEFSTRUCT `GENERIC-FUNCTION-DEF`

---
### DEFSTRUCT `CRISP-STRUCT-DEFINITION`

  > Stores the definition of a user-defined struct.


---
### DEFSTRUCT `SEMANTIC-FUNCTION`

---
### DEFSTRUCT `SEMANTIC-RETURN`

---
### DEFSTRUCT `SEMANTIC-EXPLICIT-RETURN`

  > Represents an explicit (return ...) form.


---
### DEFSTRUCT `SEMANTIC-LITERAL`

---
### DEFSTRUCT `SEMANTIC-PARAM`

---
### DEFSTRUCT `SEMANTIC-VAR-READ`

---
### DEFSTRUCT `SEMANTIC-ADD`

---
### DEFSTRUCT `SEMANTIC-SUB`

---
### DEFSTRUCT `SEMANTIC-MUL`

---
### DEFSTRUCT `SEMANTIC-DIV`

---
### DEFSTRUCT `SEMANTIC-LT`

---
### DEFSTRUCT `SEMANTIC-GT`

---
### DEFSTRUCT `SEMANTIC-LE`

---
### DEFSTRUCT `SEMANTIC-GE`

---
### DEFSTRUCT `SEMANTIC-EQ`

---
### DEFSTRUCT `SEMANTIC-NEQ`

---
### DEFSTRUCT `SEMANTIC-IF`

---
### DEFSTRUCT `SEMANTIC-SET!`

  > Represents a (set! ...) expression.


---
### DEFSTRUCT `SEMANTIC-STRUCT-MEMBER-UPDATE`

  > Represents updating a single member of a struct (creates a new struct value).


---
### DEFSTRUCT `SEMANTIC-AREF`

---
### DEFSTRUCT `SEMANTIC-CAST`

  > Base struct for all cast operations.


---
### DEFSTRUCT `SEMANTIC-VALUE-CAST`

  > Represents a value-preserving cast (e.g., to-float).


---
### DEFSTRUCT `SEMANTIC-BITCAST`

  > Represents a bit reinterpretation cast (e.g., as-int).


---
### DEFSTRUCT `SEMANTIC-FP-TRUNCATE-CAST`

  > Represents a float-to-integer truncation cast.


---
### DEFSTRUCT `SEMANTIC-TRUNCATE`

  > Represents a truncate operation returning (quot rem).


---
### DEFSTRUCT `SEMANTIC-CALL`

  > Represents a call to a user-defined function.


---
### DEFSTRUCT `SEMANTIC-FUNCALL`

  > Represents a 'funcall' form.


---
### DEFSTRUCT `SEMANTIC-LET`

  > Represents a (let ...) expression.


---
### DEFSTRUCT `SEMANTIC-EXTRACT-VALUE`

  > Represents extracting a single value from an aggregate (struct).


---
### DEFSTRUCT `SEMANTIC-INSERT-VALUE`

  > Represents inserting a single value into an aggregate (struct).


---
### DEFSTRUCT `SEMANTIC-STRUCT-CONSTRUCTION`

  > Represents constructing a struct instance e.g. (%construct-struct 'point ...).


---
### DEFSTRUCT `SEMANTIC-PROGN`

  > Represents a (progn ...) expression.


---
### DEFSTRUCT `SEMANTIC-SIZEOF`

  > Represents a sizeof(type) expression.


---
## File: `C:\Users\cperk\Documents\crisp\src\structs.lisp`

### DEFUN `GET-STD140-BASE-ALIGNMENT`
- **Args**: `(TYPE-SPEC)`

  > Returns the base alignment (N) for a given type according to std140 rules.  >    For scalars, N is the size of the scalar.  >    For vectors, it is 2N or 4N.  >    For arrays/structs, it is rounded up to vec4 alignment (16).


---
### DEFUN `GET-STD140-SIZE`
- **Args**: `(TYPE-SPEC)`

  > Returns the size (in bytes) of a type. Does not include padding for alignment context.


---
### DEFUN `CALCULATE-STD140-PADDING`
- **Args**: `(CURRENT-OFFSET ALIGNMENT)`

  > Calculates padding needed to reach the next alignment boundary.


---
### DEFUN `COMPUTE-STD140-LAYOUT`
- **Args**: `(MEMBERS)`

  > Takes a list of (name type) members.  >   Returns a list of:  >     - Expanded members with `_pad` fields inserted.  >     - Total struct size (padded to 16 bytes).  >     >   Returns (values expanded-members total-size)


---
### DEFVAR `*STRUCT-NAME-PREFIX*`

---
### DEFPARAMETER `*RECORD-DEFINITIONS*`

---
### DEFUN `ENSURE-STRUCT-LLVM-TYPE`
- **Args**: `(NAME)`

  > Ensures the LLVM struct type exists for the given struct name.  >    Handles forward declarations and recursion.


---
### DEFUN `FIND-STRUCT-DEFINITION-BY-NAME`
- **Args**: `(NAME-OR-SYMBOL)`

  > Robustly finds a struct definition by symbol or name string, ignoring package.


---
### DEFUN `COMPUTE-RECORD-LAYOUT`
- **Args**: `(MEMBERS)`

  > Computes layout for records (virtual, no padding).


---
### DEFUN `REGISTER-STRUCT-DEFINITION`
- **Args**: `(NAME MEMBERS &OPTIONAL (CATEGORY STRUCT))`

  > Registers a struct or record definition in the global registry.


---
### DEFUN `FINALIZE-STRUCT-DEFINITIONS`

  > Iteratively attempts to register pending structs. Errors if a cycle or unknown type persists.


---
### DEFUN `PARSE-STRUCT-MEMBER-SPEC`
- **Args**: `(SPEC)`

  > Parses a struct member specification.  >    Supports (name type) and (name type :c-t [value]).


---
### DEFUN `VALIDATE-AND-REORDER-STRUCT-ARGS`
- **Args**: `(STRUCT-NAME DEFINED-MEMBERS ARGS)`

  > Validates and reorders keyword arguments for a struct constructor macro.


---
## File: `C:\Users\cperk\Documents\crisp\src\templates.lisp`

### DEFSTRUCT `TEMPLATE-DATA`

  > Stores the definition of a template function.


---
### DEFUN `REGISTER-TEMPLATE`
- **Args**: `(NAME PARAMS CONSTRAINTS BODY SIGNATURE)`

  > Registers a new template definition.


---
### DEFMACRO `TEMPLATE-INSTANTIATION`
- **Args**: `(FORM)`

  > Identity macro to allow top-level template instantiation logic to be visible to the compiler  >    walker (visit-toplevel-form), preventing 'undefined function' errors.


---
### DEFUN `REORDER-TEMPLATE-ARGS-FROM-KEYWORDS`
- **Args**: `(ARGS PARAM-NAMES)`

  > Helper to convert keyword args to positional loop for template constructors.


---
### DEFMACRO `WITH-TEMPLATE-TYPE`
- **Args**: `(PARAMS &BODY BODY)`

  > Defines templates for the enclosed forms.


---
### DEFUN `GET-TEMPLATE-SIGNATURE`
- **Args**: `(NAME CONCRETE-TYPES)`

  > Returns the specialized signature for a template.


---
### DEFUN `NORMALIZE-TEMPLATE-SIG-TYPE`
- **Args**: `(TYPE)`

  > Converts (function ...) specs to (:function-type ...) structs for matching.


---
### DEFUN `MATCH-TEMPLATE-ARG`
- **Args**: `(RAW-SIG-TYPE ARG-TYPE INFERENCE-MAP TEMPLATE-PARAMS)`

  > Recursively matches sig-type against arg-type, updating inference-map.


---
### DEFUN `MATCH-LIST-STRUCTURE`
- **Args**: `(SIG-LIST ARG-LIST INFERENCE-MAP TEMPLATE-PARAMS)`

---
### DEFUN `MATCH-FUNCTION-SIGNATURE`
- **Args**: `(PATTERN-SIG CONCRETE-SIG INFERENCE-MAP TEMPLATE-PARAMS)`

---
### DEFUN `INITIALIZE-TEMPLATES`

  > Initializes the template system and hooks into the compiler.


---
### DEFUN `INSTANTIATE-TEMPLATE`
- **Args**: `(NAME-OR-TMPL CONCRETE-TYPES &OPTIONAL OVERRIDE-NAME)`

  > Generates the specialized code for a template.   >    name-or-tmpl can be a symbol (name) or a template-data struct.  >    override-name: If provided (string or symbol), renames the generated function/kernel.


---
### DEFUN `%INSTANTIATE-STRUCTURE-TEMPLATE`
- **Args**: `(NAME BODY SUBSTITUTIONS CONCRETE-TYPES)`

---
### DEFUN `%INSTANTIATE-CALLABLE-TEMPLATE`
- **Args**: `(NAME BODY SUBSTITUTIONS OVERRIDE-NAME)`

---
### DEFUN `%UNWRAP-FUNCTION-SIGNATURE`
- **Args**: `(RAW-SIG)`

  > Helper: Unwraps (FUNCTION ...) wrapper if present.


---
### DEFUN `%INFER-FROM-SINGLE-TEMPLATE`
- **Args**: `(TMPL ARGUMENT-TYPES)`

  > Helper: Attempts to infer template types for a single template.  >    Returns NIL on failure, or (list template-data concrete-types) on success.


---
### DEFUN `TRY-INFER-TEMPLATE-TYPES`
- **Args**: `(NAME ARGUMENT-TYPES)`

  > Attempts to infer template parameters for 'name' given 'argument-types'.  >    Returns a LIST OF LISTS of (template-data concrete-types).


---
### DEFUN `%RESOLVE-TEMPLATE-NAME`
- **Args**: `(NAME)`

  > Helper: Resolves constructor names (MAKE-POINT, MAKE-POINT%DISPATCH) to base struct names.


---
### DEFUN `%SHOULD-INSTANTIATE-TEMPLATE`
- **Args**: `(KEY STATUS IS-COMPILING)`

  > Helper: Determines if a template should be instantiated based on cache status.  >    Returns T if instantiation should proceed, NIL otherwise.


---
### DEFUN `ENSURE-TEMPLATE-INSTANTIATION`
- **Args**: `(NAME EXPLICIT-ARG-TYPES COMPILER-CALLBACK)`

  > Called by the compiler to auto-instantiate templates.  >    compiler-callback is (lambda (form location) ...)


---
### DEFMACRO `MAKE-STRUCTURE-TEMPLATE-INSTANCE`
- **Args**: `(TEMPLATE-NAME CONCRETE-TYPES &REST CTOR-ARGS)`

  > Instantiates the struct template ensuring definitions exist, then calls the constructor.


---
## File: `C:\Users\cperk\Documents\crisp\src\type-checker.lisp`

### DEFUN `GET-PROMOTED-TYPE`
- **Args**: `(TYPE-A-NAME TYPE-B-NAME)`

  > Determines result type of binary operation with alias resolution.


---
### DEFUN `TYPES-COMPATIBLE-P`
- **Args**: `(ARG-TYPE PARAM-TYPE)`

  > Checks if an argument type is compatible with a parameter type.


---
### DEFUN `TYPES-LIST-COMPATIBLE-P`
- **Args**: `(ARG-TYPES PARAM-TYPES)`

  > Checks if a list of argument types is compatible with a list of parameter types.


---
### DEFUN `RESOLVE-BEST-SIGNATURE`
- **Args**: `(OP EXPLICIT-ARG-TYPES)`

  > Finds the best matching function signature for the given operator and argument types.  >    Attempts template instantiation if no immediate match is found.


---
## File: `C:\Users\cperk\Documents\crisp\src\types\definitions.lisp`

### DEFSTRUCT `ENUMERATION-DEF`

---
## File: `C:\Users\cperk\Documents\crisp\src\types\registry.lisp`

### DEFVAR `*GENERIC-FUNCTIONS*`

  > Registry of generic function templates (functions with &optional or &key parameters)   >    that are instantiated lazily. Key: function name symbol. Value: generic-function-def struct.


---
### DEFVAR `*FUNCTION-TABLE*`

  > A hash table mapping function names (symbols) to a list of  >   FUNCTION-SIGNATURE structs. This supports overloading.


---
### DEFVAR `*SINGLE-PASS-CALL-STACK*`

  > A list of function names currently in the compilation stack, used to  >   detect recursion in single-pass mode.


---
### DEFVAR `*CALL-GRAPH*`

  > A hash table representing the call graph of functions.  >   Keys are caller function names, values are lists of callee names.


---
### DEFVAR `*TEMPLATE-INSTANTIATOR-FN*`

  > Hook for template instantiation.  >    Called as (funcall *template-instantiator-fn* name arg-types callback).  >    The callback is (funcall callback form location).


---
### DEFVAR `*TEMPLATE-REGISTRY*`

  > Maps template names (symbols) to a LIST of template-data structs.  > This supports overloading templates by arity or other factors.


---
### DEFVAR `*INSTANTIATED-TEMPLATES*`

  > Tracks which specializations have already been generated.


---
### DEFVAR `*SIDE-CHANNEL-ORIGINATORS*`

  > A list of function names that trigger the implicit side-channel argument passing mechanism.


---
### DEFVAR `*ORIGINATOR-FUNCTIONS*`

  > A hash table containing the names of all functions that directly use a side-channel originator.


---
### DEFVAR `*IMPLICIT-ARG-MAP*`

  > A hash table mapping function names to the implicit side-channel arguments they require.


---
### DEFVAR `*RUNTIME-CHECKS-ENABLED*`

  > If true, runtime assertions (r-t-assert) are compiled.


---
### DEFVAR `*CURRENT-COMPILING-FUNCTION*`

---
### DEFVAR `*CURRENT-MODULE*`

---
### DEFVAR `*CURRENT-BUILDER*`

---
### DEFVAR `*CURRENT-DI-BUILDER*`

---
### DEFVAR `*CURRENT-DI-COMPILE-UNIT*`

---
### DEFVAR `*CURRENT-LOCATION-MAP*`

---
### DEFVAR `*ALLOW-NESTED-DEF-FUNCTION*`

---
### DEFVAR `*CURRENT-FUNCTION-DECLARATIONS*`

  > Function declarations for current function being compiled.


---
### DEFVAR `*COMPILED-KERNELS*`

  > List of kernel names (symbols) compiled in the current session.


---
### DEFVAR `*EMIT-METADATA*`

  > If T, generate .metacrisp file.


---
### DEFVAR `*TARGET-BACKEND*`

  > The active target backend for compilation.   >    Supported values: :generic, :cpu, :spirv, :ptx.


---
### DEFVAR `*CRISP-TYPES*`

  > A hash table mapping type names (symbols) to CRISP-TYPE structs.


---
### DEFVAR `*CRISP-STRUCTS*`

  > A hash table mapping struct names to CRISP-STRUCT-DEFINITION structs.


---
### DEFVAR `*CRISP-TYPE-ALIASES*`

  > A hash table mapping alias symbols to their target type specifiers.


---
### DEFVAR `*CRISP-TEMPLATE-ALIASES*`

  > A hash table mapping template alias names to (params . body-type-spec).


---
### DEFVAR `*DEFER-STRUCT-VALIDATION*`

  > If T, register-struct-definition will not error on unknown types but instead queue the definition.


---
### DEFVAR `*PENDING-STRUCT-DEFINITIONS*`

  > A list of (name members category) tuples that are waiting for types to be defined.


---
### DEFVAR `*CRISP-ENUMS*`

---
### DEFVAR `*EXPRESSION-ANALYZERS*`

  > A dispatch table mapping operator symbols to their analyzer functions.


---
### DEFMACRO `DEF-EXPRESSION-ANALYZER`
- **Args**: `(OPERATOR HANDLER-FN)`

  > A helper macro to register an operator's analyzer function.


---
### DEFUN `INITIALIZE-CRISP-TYPES`

  > Populates the *crisp-types* hash table with built-in scalar types.


---
## File: `C:\Users\cperk\Documents\crisp\src\types\validation.lisp`

### DEFUN `EXCLUDED-TEMPLATE-BASE-TYPE-P`
- **Args**: `(BASE-TYPE)`

  > Returns true if the base-type should be excluded from struct template processing.  >    Excludes COMMON-LISP special forms like FUNCTION and QUOTE to prevent package lock violations.


---
### DEFUN `RESOLVE-TYPE-ALIAS`
- **Args**: `(TYPE-SPEC)`

  > Fully resolves a type alias chain, returning the underlying type.  >    Includes cycle detection to prevent infinite loops.  >    SIGNALS ERROR if a cycle is detected.


---
### DEFUN `EXPAND-STORAGE-HANDLE-TYPE-SPECIFIER`
- **Args**: `(SPEC)`

  > Expands legacy/shorthand storage handle specs (cell, vector, etc) into their canonical struct form.  >    e.g. (cell int) -> (cell int :global :read-write)  >    e.g. (cell int :address-space :local) -> (cell int :local :read-write)


---
### DEFUN `CANONICALIZE-TYPE-SPECIFIER`
- **Args**: `(SPEC)`

  > Canonicalizes type specifiers.


---
### DEFUN `TYPES-EQUIVALENT-P`
- **Args**: `(T1 T2)`

  > Checks if two types are equivalent, with alias resolution and template handling.


---
### DEFUN `GET-TEMPLATE-ARITY`
- **Args**: `(NAME)`

  > Returns the arity (number of type parameters) for a registered template, or nil.


---
### DEFUN `TYPE-LISTS-EQUIVALENT-P`
- **Args**: `(L1 L2)`

---
### DEFUN `VALID-BASIC-TYPE-P`
- **Args**: `(TYPE-SPEC)`

  > Checks if type-spec is a valid basic symbol type (built-in, struct, or function reference).


---
### DEFUN `VALID-FUNCTION-TYPE-P`
- **Args**: `(TYPE-SPEC)`

  > Checks if type-spec is a valid function literal or descriptor.


---
### DEFUN `%INSTANTIATE-TEMPLATE-IF-NEEDED`
- **Args**: `(BASE-TYPE TEMPLATE-ARGS MANGLED-NAME)`

  > Helper: Attempts to instantiate a template if not already instantiated.  >    Returns T if template exists/instantiated successfully, NIL otherwise.


---
### DEFUN `%VALIDATE-TEMPLATE-INSTANTIATION`
- **Args**: `(BASE-TYPE TEMPLATE-ARGS)`

  > Helper: Validates a template instantiation, checking if it's already defined  >    or can be instantiated. Returns T if valid, NIL otherwise.


---
### DEFUN `VALID-PARAMETERIZED-TYPE-P`
- **Args**: `(TYPE-SPEC)`

  > Checks if type-spec is a valid parameterized type (cell, templates, etc).


---
### DEFUN `VALID-TYPE-P`
- **Args**: `(TYPE-SPEC)`

  > Checks if a type specifier is valid.  >    Handles simple types, parameterized types, and function literals/types.


---
### DEFUN `TYPE-EQUAL-P`
- **Args**: `(T1 T2)`

---
### DEFUN `ENCODE-ADDRESS-SPACE`
- **Args**: `(AS)`

  > Maps a keyword address space to an integer, sensitive to *target-backend*.


---
### DEFUN `RESOLVE-TYPE-TO-LLVM`
- **Args**: `(TYPE-SPEC)`

  > Resolves a Crisp type specifier to an LLVM type reference.


---
### DEFUN `INCOMPLETE-TYPE-P`
- **Args**: `(TYPE-SPEC)`

  > Checks if a type specifier is incomplete (missing required compile-time properties).  >    Returns T if incomplete, NIL if complete.


---
## File: `C:\Users\cperk\Documents\crisp\src\utils.lisp`

### DEFMACRO `LET-D`
- **Args**: `(BINDINGS &BODY BODY)`

  > A debugging version of `let*`.  >   >   It behaves exactly like `let*`, but inserts a `(log:debug ...)` statement  >   after each variable is bound to log its name and value.  >   >   Example:  >     (let-d ((a 10)  >             (b (* a 2)))  >       b)  >   Will log:  >     DEBUG: let-d: A => 10  >     DEBUG: let-d: B => 20


---
### DEFUN `ADVISE-FUNCTION`
- **Args**: `(FN-SYMBOL)`

  > Replaces a function's definition with a logging wrapper.  >   The wrapper logs arguments on entry and return values on exit.  >   It correctly handles multiple return values.


---
### DEFUN `INITIALIZE-ADVISEMENTS`

  > Advises a hard-coded list of functions for debugging purposes.


---
### DEFUN `DUMP-ENV`
- **Args**: `(ENV &KEY (TITLE Environment Dump))`

  > Prints the contents of a semantic environment to *debug-io* in a formatted way.  >   The environment is expected to be an alist of (name type) pairs.


---
