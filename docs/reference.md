# Crisp Codebase Reference

Generated on 2026-04-18T03:10:08.985859Z

## File: `C:\Users\cperk\Documents\crisp-man\src\analysis\control.lisp`

### DEFUN `ENSURE-BRANCH-COMPATIBILITY`
- **Args**: `(THEN-NODE ELSE-NODE LOCATION)`

  > Unifies types of then/else branches. Returns (values unified-type new-then new-else).


---
### DEFUN `ANALYZE-IF-EXPRESSION-IMPL`
- **Args**: `(EXPR ENV CONTEXT LOCATION &KEY ENFORCE-CONSTANT)`

---
### DEFUN `ANALYZE-IF-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

---
### DEFUN `ANALYZE-STATIC-IF-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

---
### DEFUN `ANALYZE-WHEN-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

---
### DEFUN `ANALYZE-STATIC-WHEN-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

---
### DEFUN `ANALYZE-UNLESS-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

---
### DEFUN `ANALYZE-STATIC-UNLESS-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

---
### DEFUN `ANALYZE-LET-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes a `(let ...)` expression.


---
### DEFUN `ANALYZE-PROGN-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes a `(progn ...)` expression.


---
### DEFUN `ANALYZE-RETURN-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes a `(return ...)` expression.  >    FIX: A 1-element list whose sole element is a symbol (e.g. (INDEX-T)) is always  >    treated as a return-types list, not a parameterized type. This mirrors the fix  >    in validate-return-types.


---
### DEFUN `ANALYZE-FUNCTION-LITERAL`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes (function x) or #'(...)


---
### DEFUN `ANALYZE-FUNCALL-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes a (funcall f args...) form.


---
### DEFUN `ANALYZE-QUOTE`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

---
### DEFUN `ANALYZE-SIZEOF-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

---
### DEFUN `ANALYZE-COMPILER-NO-OP`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes a (compiler-no-op) form, which results in a void literal.  >    Used by compile-time macros (c-t-assert, c-t-output) to emit no code.


---
### DEFUN `ANALYZE-NESTED-DEF-FUNCTION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes a nested `(def-function ...)` expression (e.g. from a template).


---
### DEFUN `ANALYZE-TEMPLATE-INSTANTIATION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes a `(template-instantiation ...)` form, allowing nested def-functions.


---
### DEFUN `ANALYZE-EVAL-WHEN`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes (eval-when ...) forms by ignoring them in the runtime IR.  >    Side effects (like struct registration) should have already occurred during macro expansion.


---
### DEFUN `ANALYZE-IS-SET-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes (is-set? var). Returns 1 (true) if var is bound in env, 0 (false) otherwise.


---
### DEFUN `ANALYZE-LENGTH-TILDE-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes (length~ arr).  >    For (array T N): returns compile-time constant N as ulong literal.  >    For tensor types: dispatches to the runtime length~ accessor function.  >    Signals crisp-compiler-error if argument is neither array nor tensor.


---
### DEFUN `REGISTER-CONTROL-ANALYZERS`

  > Registers all control flow expression analyzers, including length~ for arrays.


---
## File: `C:\Users\cperk\Documents\crisp-man\src\analysis\core.lisp`

### DEFVAR `*ANALYSIS-ACCESS-MODE*`

---
### DEFUN `%DVEC-INTEGRAL-TYPE-P`
- **Args**: `(TYPE-SYM)`

  > Returns T if TYPE-SYM is a registered integer (signed or unsigned) Crisp type.


---
### DEFUN `%DVEC-FLOAT-TYPE-P`
- **Args**: `(TYPE-SYM)`

  > Returns T if TYPE-SYM is a registered floating-point Crisp type.


---
### DEFUN `%DVEC-INFER-COMP-TYPE`
- **Args**: `(ELEM-NODE LOCATION)`

  > Returns the component type symbol for a device vector element node.  >    Plain int literals -> 'int, plain float literals -> 'float,  >    typed literals -> their explicit type.  >    Signals crisp-compiler-error for device-vector or unknown types.


---
### DEFUN `%DVEC-ELEMENT-COMPATIBLE-P`
- **Args**: `(ELEM-TYPE COMP-TYPE)`

  > Returns T if ELEM-TYPE (of a subsequent element) is compatible with COMP-TYPE  >    under the first-term coercion rule:  >    - Exact match always passes.  >    - Plain 'int is coercible to any integral comp-type.  >    - Plain 'float is coercible to any float comp-type.


---
### DEFUN `ANALYZE-CRISP-DVEC-LITERAL`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes (crisp-vec-literal e1 e2 ...) — produced by the ##(...) reader macro.  >    Infers the component type from the first element, validates width (2-4) and  >    element type compatibility, then returns a semantic-device-vec-literal node.


---
### DEFUN `INITIALIZE-EXPRESSION-ANALYZERS`

  > Registers all expression analyzers, including device vector support.


---
### DEFVAR `*IMPLICIT-ARG-MAP*`

  > Map of function-name -> list of implicit argument requirements.


---
### DEFVAR `*SCRATCH-CELL-COUNTER*`

  > Monotonic counter for disambiguating scratch cells.  >          Used TWICE per module:  >          1. During Analysis Scan (Pass 1) to generate Implicit Arguments.  >          2. During Codegen (Pass 2) to generate LLVM IR.  >          MUST BE RESET TO 0 BETWEEN PASSES.


---
### DEFUN `COMPILE-MODULE`
- **Args**: `(FORMS MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)`

  > Orchestrates the multi-pass compilation of a list of top-level forms.


---
### DEFUN `PROPAGATE-IMPLICIT-ARGUMENTS`

  > Phase 4: Traverses the call graph backwards from originators to find all carriers.


---
### DEFUN `MULTI-PASS-MODE-P`

  > Returns T if in multi-pass compilation mode, NIL if in single-pass mode.  >   >    Multi-pass mode builds a call graph, propagates implicit arguments, and  >    allows forward references. Single-pass requires dependency-ordered code.


---
### DEFUN `SINGLE-PASS-MODE-P`

  > Returns T if in single-pass compilation mode, NIL if in multi-pass mode.  >   >    Single-pass mode compiles each form immediately as read, requiring functions  >    to be defined before use (no forward references). Used for fast JIT compilation.


---
### DEFVAR `*SCANNING-FUNCTION-NAME*`

  > The name of the function currently being scanned in Pass 1.


---
### DEFVAR `*SCRATCH-CELL-COUNTER*`

  > Monotonic counter for disambiguating scratch cells.


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

  > Compiles a single def-function form. Handles optional parameters by generating  > overloaded variants. When *differentiate-p* is T, also generates and compiles  > the _GRAD backward companion after the forward function.


---
### DEFUN `WALK-CODE-FORMS`
- **Args**: `(FORMS VISITOR-FN)`

  > Walks top-level forms, handling macros and progn, and calling visitor-fn on def-function.


---
### DEFUN `ANALYZE-SIGNATURES-PASS`
- **Args**: `(FORMS)`

  > Pass 1: Pre-register differentiable functions, then iterate through forms  > to find and register all function signatures and build the call graph.  > Pre-registration ensures *differentiable-functions* is populated before  > def-kernel macros expand and call generate-backward-walk (feature 052).  > Also scans *template-registry* for HOF templates after walk-code-forms.


---
### DEFUN `COMPILE-FORMS-PASS`
- **Args**: `(FORMS MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)`

  > Pass 2: Iterates through forms to perform full analysis and codegen.


---
### DEFUN `COMPILE-TOPLEVEL-FORM`
- **Args**: `(FORM LOCATION MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT
              LOCATION-MAP)`

  > Analyzes and compiles a single top-level form (used in Pass 2 and single-pass mode).  > When *differentiate-p* is T, also calls %pre-register-hof-templates after each form  > so that with-template-type HOF definitions are available before kernel backward walks  > in single-pass mode.


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
- **Args**: `(NAME BODY ENV CONTEXT DECLARED-RETURN-TYPES LOCATION)`

  > Analyzes the function body and validates return types.  >    Fixes: A 1-element list whose sole element is a symbol (e.g. (TOKEN-T)) is always  >    treated as a return-types list, never as a parameterized type. This prevents  >    double-wrapping when the type name is a type alias.


---
### DEFUN `INTERNAL-COMPILE-FUNCTION`
- **Args**: `(NAME EXPLICIT-ENV RETURN-TYPE PARAMS BODY DECLARATIONS LOCATION
              CONTEXT)`

  > Core compilation logic for a function, accepting a pre-parsed environment.


---
### DEFVAR `*BOUNDARY-STRUCT-PARAMS*`

  > Dynamic variable: list of uppercase param name strings that are def-struct  >    params at the current kernel boundary. Non-nil only when compiling an  >    entry-point kernel body. Nil in regular functions.


---
### DEFVAR `*STRUCT-MUTATING-FUNCTIONS*`

  > Maps uppercase function name (string) -> T for functions that directly or  >    indirectly mutate a struct-typed :in parameter.


---
### DEFUN `%BOUNDARY-STRUCT-TYPE-P`
- **Args**: `(TYPE)`

  > Returns T if TYPE is a symbol naming a registered def-struct (category :struct)  >    in *crisp-structs*. Returns NIL for def-record types (category :record).  >    Uses string-equal for package-agnostic comparison.


---
### DEFUN `%CHECK-STRUCT-BOUNDARY-MUTATION`
- **Args**: `(STRUCT-NODE ENV CONTEXT LOCATION)`

  > Called when a struct member update is about to be emitted.  >    In kernel context (*boundary-struct-params* bound): error if the struct  >    being mutated is a kernel boundary parameter.  >    In function context: mark the current function as struct-mutating if it is  >    mutating an :in parameter.


---
### DEFUN `%CHECK-STRUCT-MUTATING-CALL`
- **Args**: `(OP EXPLICIT-ARG-NODES ENV CONTEXT LOCATION)`

  > Called during function call analysis when OP is in *struct-mutating-functions*.  >    Kernel context: error if any arg is a boundary struct param.  >    Function context: propagate struct-mutating mark if any :in struct param is passed.


---
### DEFVAR `*BOUNDARY-ARRAY-PARAMS*`

  > Dynamic variable: list of uppercase param name strings that are (array T N)  >    params at the current kernel boundary. Non-nil only when compiling an  >    entry-point kernel. Nil in regular functions.


---
### DEFUN `%CHECK-AREF-BOUNDARY-MUTATION`
- **Args**: `(AREF-NODE LOCATION)`

  > Called when a semantic-aref is the target of a set!.  >    Error 01: If the array-node is a direct var-read in *boundary-array-params*, error.  >    Error 02: If the array-node is a call (accessor) whose first arg is a boundary struct, error.


---
### DEFUN `INTERNAL-DEF-FUNCTION`
- **Args**: `(NAME PARAMS DECLARATIONS BODY LOCATION)`

  > Wrapper around internal-compile-function. Detects kernel entry-points and  >    binds *boundary-struct-params* and *boundary-array-params* to enforce immutability.


---
### DEFUN `ANALYZE-BODY-EXPRESSIONS`
- **Args**: `(BODY-LIST ENV CONTEXT LOCATION)`

  > Recursively analyzes a list of expressions.


---
### DEFUN `ANALYZE-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Recursively analyzes a *single* expression.


---
### DEFUN `ANALYZE-FUNCTION-CALL`
- **Args**: `(OP EXPR ENV CONTEXT LOCATION)`

  > Analyzes a function call expression.  >    Checks for struct immutability violations via %check-struct-mutating-call.


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
### DEFUN `%TRY-PARSE-TYPED-LITERAL`
- **Args**: `(EXPR LOCATION)`

  > If EXPR is a symbol whose name matches <integer><suffix> or <number><suffix>,  >    returns a semantic-literal node with the appropriate Crisp type and value.  >    Suffixes (symbols are already upcased by the SBCL reader):  >      BF -> bfloat16   UC -> uchar   UL -> ulong   US -> ushort  >      U  -> uint       S  -> short   L  -> long     C  -> char  >      H  -> half       F  -> float   D  -> double  >    Multi-character suffixes are tested first to avoid BF matching F,  >    UL matching L, etc.  Returns NIL if EXPR does not match.


---
### DEFUN `%PRE-REGISTER-DIFFERENTIABLE-FNS`
- **Args**: `(FORMS)`

  > When *differentiate-p* is T, walk FORMS for def-function forms and  > pre-register them in *differentiable-functions* (and *differentiable-hof-store*  > for HOF functions). Handles top-level def-function, progn, and with-template-type.  > Guards parse-function-declarations against unknown-type errors from brand types  > that are not yet registered at pre-registration time.


---
### DEFUN `%PRE-REGISTER-HOF-TEMPLATES`

  > When *differentiate-p* is T, scan *template-registry* for def-function templates  > that use (funcall <param> ...) in their body, indicating a HOF parameter. Pre-register  > each such template in *differentiable-hof-store* and *differentiable-functions*.  > Must be called after walk-code-forms so *template-registry* is populated.


---
### DEFUN `%TREE-HAS-FUNCALL-P`
- **Args**: `(TREE TARGET-SYM)`

  > Returns T if any subtree in TREE contains (funcall TARGET-SYM ...).


---
### DEFUN `%DVEC-TYPE-LOOKUP`
- **Args**: `(TYPE-SYM)`

  > Returns the crisp-type entry for TYPE-SYM if it is a registered device-vector  >    type, trying both :crisp-language and :crisp.compiler packages.  >    Returns NIL when TYPE-SYM is not a device-vector type.


---
### DEFUN `%DVEC-CHECK-CELL-WRITE-ACCESS`
- **Args**: `(AREF-NODE LOCATION)`

  > Signals crisp-compiler-error if the cell accessed through AREF-NODE is  >    read-only.  The check examines the mangled struct name for 'READ-ONLY'.


---
### DEFUN `ANALYZE-DVEC-COMPONENT-REF`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes (x~ v), (y~ v), (z~ v), (w~ v) — device-vector component accessors.  >    The operator symbol determines the 0-based LLVM element index (0..3).  >    Returns a semantic-extract-value node whose type is the scalar component type.  >   >    Brand-instance gensyms (e.g. VALUE-T-204 derived from float2) are resolved  >    to their concrete device-vector base type via *type-derivation-graph* before  >    width and component-scalar extraction.  >   >    In :write mode (inside a set! target), also validates that a cell-deref  >    aggregate is not read-only.


---
## File: `C:\Users\cperk\Documents\crisp-man\src\analysis\ops.lisp`

### DEFMACRO `DEF-BINARY-OP-ANALYZER`
- **Args**: `(NAME NODE-CONSTRUCTOR OP-STRING)`

---
### DEFMACRO `DEF-UNARY-MATH-ANALYZER`
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
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

---
### DEFUN `ANALYZE-DEC!-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

---
### DEFUN `ANALYZE-ATOMIC-ADD!-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

---
### DEFUN `ANALYZE-CAST-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes a to-XXXX or as-XXXX cast expression.


---
### DEFUN `ANALYZE-TRUNCATE-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes (truncate val) -> (values int rem).


---
### DEFUN `ANALYZE-VALUE-CAST-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes the generic (to type value) form.


---
### DEFUN `ANALYZE-GENERIC-AS-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes the generic (as type value) form.  >    Extended to handle brand application forms like (index-t fc) where  >    index-t is a brand, resolving to the concrete target type before validation.


---
### DEFUN `CREATE-IMPLICIT-CAST`
- **Args**: `(NODE TARGET-TYPE LOCATION)`

  > Wraps node in an implicit cast to target-type.


---
### DEFUN `ANALYZE-BITCAST-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Handler for explicit (as-bits type val) or aliased calls.


---
### DEFUN `REGISTER-OPS-ANALYZERS`

---
## File: `C:\Users\cperk\Documents\crisp-man\src\analysis\structs.lisp`

### DEFUN `GET-ARRAY-ELEMENT-TYPE`
- **Args**: `(TYPE)`

  > Determines the element type of an array, pointer, cell, or tensor type.  >    Returns NIL if unknown.  >    Handles single-element list wrapping, e.g. ((array float 4)) → (array float 4).


---
### DEFUN `GET-STRUCT-MEMBER-INDEX`
- **Args**: `(STRUCT-TYPE-NAME MEMBER-NAME)`

  > Helper to find the physical index of a struct member, accounting for padding.


---
### DEFUN `NUMERIC-TYPE-CATEGORY`
- **Args**: `(TYPE-NAME)`

  > Returns the category (:signed-int, :unsigned-int, :float) if TYPE-NAME is a numeric  >    scalar in *crisp-types*, or NIL otherwise. Resolves aliases and derived types first.


---
### DEFUN `ANALYZE-STRUCT-CONSTRUCTION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes a (%construct-struct type-name arg1 arg2 ...) form.  >    Supports implicit promotion of base-type values to branded member types  >    in struct constructors (the birthplace of branded values).  >    Uses get-single-value-type to normalize function-call return type lists  >    (e.g. ((STORAGE GLOBAL)) -> (STORAGE GLOBAL)) before type comparison.


---
### DEFUN `ANALYZE-EXTRACT-STRUCT-MEMBER-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes a `%extract-struct-member` expression.  >    Form: (%extract-struct-member object-node index-literal)


---
### DEFUN `ANALYZE-INSERT-STRUCT-MEMBER-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes a `%insert-struct-member` expression.  >    Form: (%insert-struct-member object-node index-literal value-node)


---
### DEFUN `%TENSOR-TYPE-P`
- **Args**: `(TYPE)`

  > Returns T if TYPE denotes a tensor (list or mangled-symbol form).


---
### DEFUN `%GET-TENSOR-ARITY`
- **Args**: `(TYPE)`

  > Returns the compile-time arity N of TYPE as an integer, or NIL.  >    Handles list form (tensor elem N ...) and mangled-symbol form.


---
### DEFUN `%BUILD-TENSOR-FLAT-INDEX-FORM`
- **Args**: `(TARGET-SYM INDEX-FORMS)`

  > Builds a Crisp expression computing the flat element index for a tensor access.  >    flat = Σ_k( (~ (offset~ target) k) + index_k * (~ (strides~ target) k) )  >    for k in 0..(N-1).  Returns a Crisp form ready for analyze-expression.  >    All arithmetic is ulong: each index is wrapped in (to-ulong ...) to ensure  >    consistent types when the caller passes bare integer literals (int by default).


---
### DEFUN `%GET-TENSOR-ALIGN`
- **Args**: `(TYPE)`

  > Extracts the :align keyword from a tensor type specifier.  >    TYPE may be a list form (tensor elem N addr access align) or a  >    mangled symbol TENSOR_ELEM_N_ADDR_ACCESS_ALIGN.  >    Returns :compact, :compact-offset, :strided, or NIL (unknown / template).


---
### DEFUN `%BUILD-TENSOR-COMPACT-FLAT-INDEX-FORM`
- **Args**: `(TARGET-SYM INDEX-FORMS)`

  > Builds the :compact flat-index form — Horner on extents only, NO offset reads.  >    :compact guarantees all offsets are zero at the kernel boundary, so we skip them.  >    N=1: flat = i_0  >    N>=2: flat = Horner(i_0..i_{N-1}, ext_1..ext_{N-1})


---
### DEFUN `%BUILD-TENSOR-COMPACT-OFFSET-FLAT-INDEX-FORM`
- **Args**: `(TARGET-SYM INDEX-FORMS)`

  > Builds the :compact-offset flat-index form — Horner on extents plus offset sum.  >    Strides are ignored (compact layout), but per-dimension offsets are read.  >    N=1: flat = offset[0] + i_0  >    N>=2: flat = Horner(i_0..i_{N-1}, ext_1..ext_{N-1}) + sum(offset[k])


---
### DEFUN `ANALYZE-AREF-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes (~ target [index...]) or (~ref~ ...) expressions.  >    Tensor path dispatches on resolved :align:  >      :compact        → %build-tensor-compact-flat-index-form  (no offset, no stride)  >      :compact-offset → %build-tensor-compact-offset-flat-index-form (offset, no stride)  >      :strided / NIL  → %build-tensor-flat-index-form (offset + stride, safe fallback)


---
### DEFUN `ANALYZE-SET!-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes a (set! target value) expression.  >    Enforces struct and array immutability at kernel boundary.


---
### DEFUN `ANALYZE-INCOMPLETE-TYPE-ACCESSOR`
- **Args**: `(OP EXPR ENV CONTEXT LOCATION)`

  > Attempts to resolve a call like (color~ obj) where obj is (shirt :color :blue).  >    Returns a semantic-node (literal) if resolved, or NIL if not applicable.  >   >    Fix: float values now return value-type 'float instead of 'quote.


---
### DEFUN `ANALYZE-SCRATCH-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes a (make-scratch-cell ...) expression.  >  This marks the current function as an originator in BOTH analysis modes.


---
### DEFUN `ANALYZE-%MAKE-CT-ARRAY`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes (%make-ct-array elem-type val0 val1 ... valN-1).  >    elem-type is taken as a literal type symbol (not evaluated).  >    Returns a semantic-ct-array node of type (array elem-type N).  >    Used internally by marshall-tensor to assemble offset/strides/extents fields.


---
### DEFUN `%EXTRACT-SCRATCH-SIZE-EXPR`
- **Args**: `(OP ARGS)`

  > Extracts the user-supplied size expression from make-scratch-* args.


---
### DEFUN `%SCRATCH-TENSOR-CANONICAL-SPEC`
- **Args**: `(OP ARGS)`

  > Resolves the type arguments of a make-scratch-{vector,matrix,tensor} form  >    to a canonical (tensor elem N addr access align) spec.  >   >    OP is the operator symbol.  ARGS is the rest of the form (everything after  >    the operator).  Returns the canonical spec or NIL if resolution fails.  >   >    Dual-syntax disambiguation for make-scratch-tensor:  >      - If the second positional arg (after the first type-ish arg) is an integer  >        AND the first arg is NOT a registered tensor/vector/matrix type alias,  >        we treat it as Form 1: (elem-type N sizeExpr ...).  >      - Otherwise Form 2: (tensor-type sizeExpr ...).


---
### DEFUN `%REGISTER-SCRATCH-TENSOR-IMPLICIT`
- **Args**: `(OP ARGS)`

  > Shared logic for scan-operator methods on make-scratch-{vector,matrix,tensor}.  >    Marks the current function as an originator and records the canonical-list type  >    in *implicit-arg-map* and the size-expr in *implicit-scratch-size-expr-map*.


---
### DEFUN `ANALYZE-SCRATCH-TENSOR-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes a (make-scratch-{vector,matrix,tensor} ...) expression.  >    Stores canonical-list type in *implicit-arg-map* and size-expr in  >    *implicit-scratch-size-expr-map*.


---
### DEFUN `REGISTER-STRUCT-ANALYZERS`

  > Registers all struct/storage-handle expression analyzers.  >    Redefines the original to add make-scratch-{vector,matrix,tensor}.


---
## File: `C:\Users\cperk\Documents\crisp-man\src\anf-transform.lisp`

### DEFVAR `*ANF-COUNTER*`

---
### DEFUN `ANF-FRESH-TEMP`

---
### DEFUN `ANF-IS-ATOMIC?`
- **Args**: `(EXPR)`

  > Returns true if EXPR is considered an atomic value in ANF.


---
### DEFUN `ANF-NORMALIZE-ARGS`
- **Args**: `(ARGS)`

  > Returns (VALUES normalized-args bindings-list)


---
### DEFUN `ANF-NORMALIZE-PLACE`
- **Args**: `(PLACE)`

  > Returns (VALUES normalized-place bindings)  >    Normalizes a place for mutation (e.g. the left side of a set!).  >    An atomic place stays unchanged, while accessors have their parent argument hoisted.


---
### DEFUN `ANF-NORMALIZE`
- **Args**: `(EXPR IS-NESTED?)`

  > Returns (VALUES normalized-expr bindings-list)


---
### DEFUN `%ANF-TRANSFORM`
- **Args**: `(EXPR)`

  > Internal helper for recursive ANF transformation.


---
### DEFUN `ANF-TRANSFORM`
- **Args**: `(EXPR)`

  > Transforms a Crisp expression into A-Normal Form.


---
### DEFUN `ANF-TRANSFORM-MODULE`
- **Args**: `(FORMS)`

  > Iterates over top-level forms, running ANF transform on function/kernel bodies.


---
### DEFUN `FLATTEN-ANF-BODY`
- **Args**: `(ANF-BODY)`

  > Flattens an ANF body into a sequential list of bindings and side-effects.  > Returns a list of elements formatted as either (var expr), (var0 var1 expr) for  > multi-value bindings, or just expr (for side-effects).  > Accepts bindings of length >= 2 (fix: was = 2, dropping multi-value bindings).


---
## File: `C:\Users\cperk\Documents\crisp-man\src\autodiff.lisp`

### DEFUN `GENERATE-BACKWARD-WALK`
- **Args**: `(FLAT-ANF INPUTS OUTPUTS INPUT-TYPES OUTPUT-TYPES)`

  > Walks a flattened ANF body backwards to accumulate adjoints.  > Returns a backward ANF body (a let form).  > Extended for feature 052: handles differentiable sub-function calls (B1/B2),  > multi-value bindings, HOF inline backward, errors for non-differentiable  > functions (B3), and mutation errors (B4).


---
### DEFUN `%CRISP-FLOAT-TYPE-P`
- **Args**: `(TYPE-SPEC)`

  > Returns T if TYPE-SPEC (possibly a type alias) resolves to a Crisp  > float-category scalar type (float, double, half, bfloat16).  > Checks *crisp-types* directly first (for primitives like 'float),  > then falls back to compute-base-type for derived/alias types.


---
### DEFUN `%CRISP-RECORD-TYPE-P`
- **Args**: `(TYPE-SPEC)`

  > Returns T if TYPE-SPEC names a def-record (category :record).  >    Handles parameterized forms like (V-POINT :EARNESTNESS 3.0).


---
### DEFUN `%GET-RECORD-RUNTIME-FIELDS`
- **Args**: `(REC-TYPE-SPEC)`

  > Returns a list of (FIELD-NAME RESOLVED-FIELD-TYPE) for the runtime  >    (non-:c-t) members of the record type named by REC-TYPE-SPEC.  >    Handles parameterised forms like (V-POINT :EARNESTNESS 3.0).


---
### DEFUN `%RECORD-ACCESSOR-SYSTEM-GENERATED-P`
- **Args**: `(ACCESSOR-SYM REC-TYPE)`

  > Returns T if ACCESSOR-SYM (e.g. X~) is the single system-generated  >    accessor for REC-TYPE — i.e. it has NOT been user-overloaded.  >    Heuristic: count *function-table* entries whose first parameter type  >    matches REC-TYPE.  Exactly 1 means system-generated only.


---
### DEFUN `%RECORD-FIELD-PARAM-SYM`
- **Args**: `(PARAM-SYM FIELD-NAME PKG)`

  > Creates the exploded scalar symbol for PARAM-SYM's FIELD-NAME.  >    E.g. VP + X -> VP_X.


---
### DEFUN `%SUBSTITUTE-RECORD-ACCESSORS`
- **Args**: `(FORM RECORD-SUBS-HT RECORD-TYPE-HT)`

  > Recursively walks FORM (a raw Crisp body S-expression) and substitutes:  >      (~field~ p)  -> p_field   (always, ~field~ is non-overloadable)  >      (field~  p)  -> p_field   (only when field~ is system-generated for p's type)  >    RECORD-SUBS-HT maps param-sym -> alist of (field-sym . exploded-sym).  >    RECORD-TYPE-HT  maps param-sym -> rec-type-spec.


---
### DEFUN `%FIX-RECORD-GRAD-CELL-EMISSIONS`
- **Args**: `(FORM GRAD-CELL-SYMS)`

  > Post-processes the backward-walk output.  >    For any (SET! var expr) where VAR is in GRAD-CELL-SYMS,  >    rewrites to (SET! (~ var) expr), since the gradient output  >    for a record field is a cell, not a plain scalar.  >    GRAD-CELL-SYMS is a list of symbols that need cell-style emission.


---
### DEFUN `%EXPAND-RECORD-KERNEL-INPUTS`
- **Args**: `(INPUTS INPUT-TYPES PKG)`

  > Expands record-typed inputs into their scalar fields.  >    Returns (values flat-inputs flat-input-types  >                    reassembly-bindings  >                    grad-out-params grad-out-types  >                    record-subs-ht record-type-ht  >                    grad-cell-syms).  >   >    flat-inputs / flat-input-types : record params replaced by scalar field params.  >    reassembly-bindings : let-bindings to reconstruct each record from its fields.  >    grad-out-params / grad-out-types : gradient cell output params (float fields only).  >    record-subs-ht : param-sym -> alist (field-sym . exploded-sym).  >    record-type-ht  : param-sym -> rec-type-spec.  >    grad-cell-syms  : list of _GRAD symbols that need (set! (~ ..) adj) emission.


---
### DEFUN `%BACKWARD-SKIP-FN-P`
- **Args**: `(FN-SYM)`

  > Returns T if FN-SYM should be silently skipped in the AD backward walk.  > Skips: system-generated functions (name contains %), AS/AS-* type casts and  > derived-type coercions, and TO-<int-type> integer conversions.


---
### DEFUN `%GENERATE-BACKWARD-FUNCTION-AST`
- **Args**: `(NAME PARAMS DECLARATIONS BODY-FORMS)`

---
### DEFUN `%GENERATE-BACKWARD-FUNCTION-WALK`
- **Args**: `(FLAT-ANF FLOAT-PARAM-SYMS T-GRAD-SYMS RETURN-VARS)`

  > Generates the backward-pass body for a def-function.  > FLAT-ANF         : flattened ANF of the forward function body.  > FLOAT-PARAM-SYMS : parameter symbols whose types are float (get delta outputs).  > T-GRAD-SYMS      : symbols for the incoming gradient inputs (one per return value).  > RETURN-VARS      : symbols of the return variables (identified from FLAT-ANF last element).  > Returns a (let (...) ...) form suitable as the body of the _GRAD companion function.


---
### DEFUN `%CHECK-FN-BODY-FOR-MUTATIONS`
- **Args**: `(BODY-FORMS PARAM-NAMES FN-NAME)`

  > Walks BODY-FORMS looking for (set! (~ p) ...) where p is in PARAM-NAMES.  > Signals a compiler error if any mutation is detected, naming FN-NAME.


---
### DEFUN `%CRISP-FUNCTION-TYPE-P`
- **Args**: `(TYPE-SPEC)`

  > Returns T if TYPE-SPEC is a parsed :function-type or :function-literal specifier.


---
### DEFUN `%SUBST-FORM`
- **Args**: `(FORM SUBST-ALIST)`

  > Recursively substitute atoms in FORM according to SUBST-ALIST (list of (sym . replacement)).


---
### DEFUN `%REMOVE-FUNCALL`
- **Args**: `(FORM FN-PARAM-SYM CONCRETE-FN-SYM)`

  > Recursively replace (funcall FN-PARAM-SYM ...) or (funcall (function X) ...)  > with (CONCRETE-FN-SYM ...) in FORM.


---
### DEFUN `%FN-NAME-IS-GRAD-P`
- **Args**: `(NAME)`

  > Returns T if NAME ends with the _GRAD suffix, indicating it is already  > a backward companion and should not receive its own companion.


---
### DEFUN `%EXTRACT-RETURN-VARS`
- **Args**: `(FLAT-ANF)`

  > Returns the list of return-value symbols from FLAT-ANF.  > Handles both implicit last-expression and explicit (return v0 v1 ...) forms.


---
## File: `C:\Users\cperk\Documents\crisp-man\src\codegen.lisp`

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
### DEFUN `%LOOKUP-FIELD-PHYSICAL-INDEX`
- **Args**: `(STRUCT-DEF FIELD-NAME-STR)`

  > Returns the physical (LLVM struct) index of a field identified by  >    FIELD-NAME-STR, using string-equal so package differences don't matter.  >    Returns NIL if not found.


---
### DEFUN `%TRY-INLINE-STRUCT-ARRAY-FIELD-PTR`
- **Args**: `(ARRAY-NODE BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE
              LOCATION-MAP)`

  > Bypass for array-returning struct field accessors (e.g. extents~, strides~).  >    Resolves type aliases and canonical list types to mangled symbols so that  >    scratch tensors (with def-type alias or with list type) get the same GEP  >    treatment as named tensors.  >   >    Returns a GEP pointer to the array field, or NIL if the pattern is not matched.


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
### DEFUN `%GENERATE-TENSOR-SCRATCH-LITERAL-IR`
- **Args**: `(BUILDER MODULE VAR-ENV TYPE-SPEC VALUE)`

  > Generates IR for a scratch tensor/vector/matrix literal.  >   >    Unlike scratch cells, scratch tensors use Option B (full SROA): the host  >    passes every field of the tensor record individually (ptr, bytesize, each  >    offset, stride, extent, and length).  The SROA/reconstruction machinery  >    in internal-compile-function therefore delivers a fully-assembled tensor  >    record value into var-env under the unique implicit-arg name.  >   >    All we need to do here is:  >      1. Reconstruct the deterministic unique name (same counter + ordering as Pass 1).  >      2. Look up the tensor alloca in var-env.  >      3. Load and return the tensor value.


---
### DEFUN `GET-TYPE-CAT-SAFE`
- **Args**: `(TYPE-NAME TYPE-OBJ)`

---
### DEFUN `BUILD-CAST-IF-NEEDED`
- **Args**: `(BUILDER MODULE FROM-VAL FROM-TYPE-NAME TO-TYPE-NAME)`

  > Builds LLVM cast instruction if types differ, with alias resolution.  >    MODULE is required to resolve types correctly.  >    Cross-package same-name fix: USHORT2 may be in :crisp-language or :crisp.compiler;  >    treat same symbol-name as no-op cast.


---
### DEFMACRO `DEF-BINARY-OP-CODEGEN`
- **Args**: `(NODE-TYPE INT-INST FLOAT-INST ACCESSOR-PREFIX)`

---
### DEFMACRO `DEF-UNARY-MATH-CODEGEN`
- **Args**: `(NODE-TYPE INTRINSIC-NAME)`

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

  > Helper: Generates IR for a single let binding.  >    Updates let-env with the new binding and returns the alloca.  >    Extended to use llvm-build-extract-element for device-vector aggregates  >    instead of llvm-build-extract-value (which is for struct aggregates only).


---
### DEFUN `TERMINATOR-P`
- **Args**: `(BLOCK)`

  > Checks if a basic block already has a terminator instruction.


---
### DEFUN `%DVEC-COERCE-ELEMENT-IR`
- **Args**: `(ELEM-NODE COMP-TYPE COMP-LLVM-TYPE BUILDER MODULE VAR-ENV
              DI-BUILDER DI-SCOPE LOCATION-MAP)`

  > Generates the LLVM value for one element of a ##(...) literal.  >    If the element type already matches COMP-TYPE, generates normally.  >    If the element is a plain-int or plain-float constant being coerced to  >    a different integral/float type, produces the correctly-typed constant  >    directly without emitting a conversion instruction.


---
## File: `C:\Users\cperk\Documents\crisp-man\src\codegen\abi.lisp`

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
### DEFUN `%RECORD-BASE-FROM-LIST-FORM`
- **Args**: `(TYPE-SPEC)`

  > If TYPE-SPEC is a non-storage list form like (V-POINT :EARNESTNESS 3.0),  >    returns the base symbol V-POINT if it resolves to a user record type.  >    Otherwise returns NIL.  Plain symbols and storage list forms return NIL.


---
### DEFUN `GET-EXPANDED-TYPES`
- **Args**: `(TYPE-SPEC MODULE)`

  > Returns a list of LLVM types for a given Crisp type spec.  >    For cell/storage, returns exploded ptr+i64 types. For records, explodes recursively.  >    For (array T N), explodes to N copies of T's expanded types (SROA for record fields).  >    For others, returns (type).  >    If *target-backend* is :spirv or :ptx, upgrades pointers to Global Address Space (1).


---
### DEFUN `EXPLODE-VALUE`
- **Args**: `(BUILDER AGG-VAL TYPE-SPEC)`

  > Extracts components from an aggregate value if necessary. Returns a list of LLVM values.  >    Handles list-form parameterised record types like (V-POINT :EARNESTNESS 3.0).  >    For (array T N) fields: extracts N individual element values (SROA).


---
### DEFUN `IMPLODE-VALUE`
- **Args**: `(BUILDER COMPONENTS TYPE-SPEC MODULE)`

  > Combines components into an aggregate value if necessary. Returns a single LLVM value.  >    Handles list-form parameterised record types like (V-POINT :EARNESTNESS 3.0).  >    For (array T N) fields: assembles N scalar components into an array value (SROA).


---
### DEFUN `EXTRACT-PRIMARY-VALUE`
- **Args**: `(BUILDER VALUE TYPE-SPEC)`

  > If the type indicates an MVR (multiple return value) struct, extract the first element.  >    Otherwise return the value as is.  >    Used when a single-value context receives an MVR result.


---
### DEFUN `CREATE-LLVM-FUNCTION-TYPE`
- **Args**: `(MODULE RETURN-TYPES PARAM-NODES)`

  > Calculates the LLVM function type, handling parameter explosion.


---
## File: `C:\Users\cperk\Documents\crisp-man\src\compiler.lisp`

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

  > Extract parameter types from a kernel function signature.  > Returns list of type strings (e.g., 'ptr addrspace(1)', 'i64', '%POINT').


---
### DEFUN `IR-TYPE-TO-OPENCL-METADATA`
- **Args**: `(IR-TYPE)`

  > Convert LLVM IR type to OpenCL metadata (addr-space, access-qual, type-name).  > Returns (values addr-space-int access-qual-string type-name-string).


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
- **Args**: `(MODULE OUTPUT-PATH &KEY DEBUG-P)`

  > Compiles an LLVM Module to SPIR-V using the external toolchain.  >    Runs %remove-dead-array-returning-functions before translation to  >    prevent IGC from miscompiling dead TypeArray-returning functions  >    (bug 028 workaround Part 2).


---
### DEFUN `%REMOVE-DEAD-ARRAY-RETURNING-FUNCTIONS`
- **Args**: `(MODULE)`

  > Scans MODULE for functions whose return type is an LLVM array type  >    ([N x T]) and that have no uses (no callers in this module).  >    Deletes each such function.  >   >    This is Part 2 of the IGC bug 028 workaround.  >    Returns the number of functions deleted.


---
### DEFUN `COMPILE-TO-PTX`
- **Args**: `(MODULE OUTPUT-PATH &KEY (COMPUTE-CAPABILITY sm_50) DEBUG-P)`

  > Compiles an LLVM Module to PTX using llc.  >  COMPUTE-CAPABILITY: Target GPU architecture (sm_50, sm_75, sm_86, etc.)  >                      sm_50 = Maxwell (good default for compatibility)


---
### DEFUN `REGISTER-BUILTINS`

  > Registers built-in types: storage, cell, and tensor def-record templates.  >    Cell and tensor carry the value-t brand for --differentiate mode.  >    Tensor: N-dimensional strided view; offset/strides/extents are virtual  >    fixed arrays of length N (SROA to N ulong registers each at boundaries).


---
### DEFVAR `*DIFFERENTIABLE-HOF-STORE*`

  > Maps HOF function name to info plist for inline backward differentiation.


---
### DEFVAR `*IMPLICIT-SCRATCH-SIZE-EXPR-MAP*`

  > Maps implicit scratch tensor param-name → size-expr form as written by the user  >    (e.g. :match-warp-tile, 1, 4).  Used by generate-implicit-signature for metadata.


---
### DEFUN `INITIALIZE-COMPILER`
- **Args**: `(&KEY (LOG-LEVEL OFF) (RUNTIME-CHECKS NIL) (DIFFERENTIATE NIL))`

  > Initializes the compiler state.  >    Extended to also clear *implicit-scratch-size-expr-map* for scratch tensor support.


---
## File: `C:\Users\cperk\Documents\crisp-man\src\enums.lisp`

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
## File: `C:\Users\cperk\Documents\crisp-man\src\environment.lisp`

### DEFUN `PARSE-FUNCTION-DECLARATIONS`
- **Args**: `(PARAMS DECLARATIONS)`

  > Parses a function's declarations and returns its environment and return type.  >    Supports interleaved type syntax: ((p type)).  >    Post-processes return types to resolve parameterized brand applications.


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
- **Args**: `(GENERIC-DEF EXPLICIT-ARG-TYPES CONTEXT LOCATION)`

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

  > Injects implicit arguments into the environment for carrier functions.  >    Types in *implicit-arg-map* are already in the correct form:  >    mangled symbols for tensors (no integers to mangle-type-spec),  >    canonical lists for cells (preserved for hoist metadata).


---
### DEFUN `SCAN-FOR-CARRIERS`
- **Args**: `(NAME BODY)`

  > Performs a single-pass look-ahead to detect if the function is a carrier.  >   >    This logic is ONLY executed in single-pass mode. It serves two purposes:  >    1. Early originator detection - finds make-scratch-cell BEFORE env is built  >    2. Upward carrier propagation - copies implicit args from callees to callers  >   >    In multi-pass mode, this analysis is handled by analyze-signatures-pass.


---
### DEFUN `DETECT-AND-REGISTER-IMPLICIT-TEMPLATE`
- **Args**: `(NAME EXPLICIT-ENV RETURN-TYPE PARAMS BODY DECLARATIONS)`

  > Detects if a function is an implicit template (e.g. has function-type args  >    or incomplete-type parameters), and if so registers it as a template and  >    returns T.  Otherwise returns NIL.  >   >    A type is treated as incomplete only if incomplete-type-p says so AND the  >    type is NOT a mangled/instantiated concrete struct (i.e. its name contains  >    an underscore AND has a registered struct definition).  Bare base names such  >    as PANTS and SHIRT have no underscore and remain eligible as implicit  >    template parameters even though they are in *crisp-structs*.


---
### DEFUN `PARSE-TYPE-SPECIFIER`
- **Args**: `(SPEC)`

  > Parses a single type specifier, handling basic types, parameterized types,  >    function types like #'(int => int), and brand type applications like (token-t s).  >    Extended: (array T N) is returned as-is (not mangled) before the generic path.


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
## File: `C:\Users\cperk\Documents\crisp-man\src\errors.lisp`

## File: `C:\Users\cperk\Documents\crisp-man\src\hoist-l0\main.lisp`

### DEFUN `MAIN`

  > Entry point for crisp-hoist-l0.exe


---
### DEFVAR `*HOIST-CURRENT-STRUCTS*`

  > Dynamic variable: list of (def-struct NAME ...) forms from the current  >    metacrisp :structs section.  Bound by generate-l0-launcher.


---
### DEFUN `%FIND-STRUCT-DEF-L0`
- **Args**: `(NAME)`

  > Find (def-struct NAME ...) in *hoist-current-structs*.  >    NAME is a symbol; all comparisons use string-equal to be package-agnostic.  >    The metacrisp is parsed with standard READ (cl-user package), so symbols  >    from the parsed data will not eq symbols from overlay source code.


---
### DEFUN `STRUCT-TYPE-P-L0`
- **Args**: `(TYPE)`

  > Returns T if TYPE names a def-struct in *hoist-current-structs*.  >    Accepts plain symbols or list forms like (POINT :EARNESTNESS 3.0).


---
### DEFUN `%STRUCT-BASE-TYPE`
- **Args**: `(PARAM-TYPE)`

  > Extract the base struct name from PARAM-TYPE (symbol or list form).


---
### DEFUN `%ARRAY-TYPE-P`
- **Args**: `(TYPE)`

  > Returns T if TYPE is an (array T N) form.


---
### DEFUN `%ARRAY-ELEMENT-TYPE`
- **Args**: `(ARRAY-TYPE)`

  > Returns the element type T from an (array T N) form.


---
### DEFUN `%ARRAY-SIZE`
- **Args**: `(ARRAY-TYPE)`

  > Returns the compile-time size N from an (array T N) form.


---
### DEFUN `%STRUCT-EMIT-FIELDS`
- **Args**: `(STREAM VAR-PATH MEMBERS ALIASES)`

  > Recursively emit C++ field assignments for a struct variable at VAR-PATH.  >    MEMBERS is the member list from the (def-struct NAME ...) form.  >    Array-typed fields are iota-initialized: field[i] = (T)i.  >    Scalar fields use a type-appropriate constant (1 / 1.0f / 1.0).  >    Nested structs are recursed into.


---
### DEFUN `GENERATE-L0-LAUNCHER`
- **Args**: `(METACRISP-PATH)`

  > Generate Level Zero C++ launcher code from metacrisp file.  >    Binds *hoist-current-structs* so generate-kernel-arguments-with-usm  >    can identify and handle def-struct parameters.


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

  > Generate C++ struct definitions from metadata.  >    For (array T N) member types: emits 'T name[N]' for the field declaration  >    and a loop in operator<< to print all elements space-separated.  >    operator<< prints values space-separated (no field names, no braces)  >    so HOIST-EXPECT substring checks work correctly.


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
- **Args**: `(STREAM KERNEL-NAME SPV-PATH DECLARED-SIG ALIASES RECORDS)`

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
- **Args**: `(STREAM KERNEL-NAME DECLARED-SIG ALIASES RECORDS)`

  > Generate kernel creation and launch code. Returns list of USM allocations.


---
### DEFUN `GENERATE-KERNEL-ARGUMENTS`
- **Args**: `(STREAM DECLARED-SIG)`

  > Generate kernel argument setup code


---
### DEFUN `RECORD-BASE-TYPE`
- **Args**: `(TYPE)`

  > Extract the base record type symbol from a plain symbol or a list-form like (V-POINT EARNESTNESS 3.0).


---
### DEFUN `FIND-RECORD-DEF`
- **Args**: `(TYPE RECORDS)`

  > Find the def-record entry matching TYPE in RECORDS.  >    TYPE may be a plain symbol or a parameterized list form.


---
### DEFUN `RECORD-TYPE-P`
- **Args**: `(TYPE RECORDS)`

  > Returns true if TYPE refers to a def-record in RECORDS.


---
### DEFUN `%RECORD-FIELD-ARGS`
- **Args**: `(STREAM MEMBERS VAR-PATH ARG-INDEX RECORDS ALIASES)`

  > Recursively emit field initialization and zeKernelSetArgumentValue calls  >    for all leaf fields of a record, following nested records.  >    Array-typed members are SROA'd: iota-initialized and passed as N  >    individual scalar args (one per element), matching the compiler's  >    physical signature which explodes (array T N) to N scalar slots.  >    Returns the updated arg-index after consuming all fields.


---
### DEFUN `TENSOR-TYPE-P`
- **Args**: `(PARAM-TYPE)`

  > Returns T if PARAM-TYPE is a tensor/vector/matrix type specifier.


---
### DEFUN `%TENSOR-COMPACT-EXTENTS-STRIDES`
- **Args**: `(N DIM-EXTENT)`

  > Returns (values extents strides) for a compact N-dim tensor.  >    Strides are in elements; innermost stride = 1.


---
### DEFUN `GENERATE-KERNEL-ARGUMENTS-WITH-USM`
- **Args**: `(STREAM DECLARED-SIG ALIASES RECORDS CONTEXT-VAR DEVICE-VAR)`

  > Generate kernel argument setup code with USM allocation for cells/tensors.  >    Handles:  >      cell                   — 3 args (ptr, byte-size, offset)  >      local scratch tensor   — 3N+3 args; ptr as nullptr local alloc (NEW)  >      tensor/vector/matrix   — 3N+3 args; USM allocation  >      def-struct             — 1 arg (aggregate by value, sizeof struct)  >      def-record             — exploded scalar args  >      (array T N)            — 1 arg, passed by value (iota-initialized T[N])  >      scalar/dvec            — 1 arg


---
## File: `C:\Users\cperk\Documents\crisp-man\src\hoist-l0\package.lisp`

## File: `C:\Users\cperk\Documents\crisp-man\src\hoist\codegen-base.lisp`

### DEFUN `CRISP-TYPE-TO-CPP-TYPE`
- **Args**: `(CRISP-TYPE)`

  > Convert a Crisp type to a C++ type string.  >    Uses string-equal for package-agnostic symbol comparison so that  >    symbols interned in any package (e.g. :crisp.hoist.l0 during metacrisp  >    parsing) are handled correctly.  >    Maps long→int64_t, ulong→uint64_t (64-bit on all platforms).  >    Fallback: hyphens converted to underscores (safe for C++ identifiers).  >    For (array T N): resolves element type.


---
### DEFUN `FORMAT-CPP-IDENTIFIER`
- **Args**: `(LISP-SYMBOL)`

  > Convert Lisp symbol to C++-safe identifier.


---
### DEFUN `%DVEC-PARSE`
- **Args**: `(TYPE-SYM)`

  > If TYPE-SYM names a device vector type (e.g. USHORT2, FLOAT4), returns  >    (values base-name width) where base-name is a lowercase string (e.g. "ushort")  >    and width is an integer (2, 3, or 4).  Returns NIL if not a device vector type.


---
### DEFUN `%DVEC-CPP-SCALAR-TYPE`
- **Args**: `(BASE-NAME)`

  > Map a Crisp scalar base name (e.g. "ushort") to a C++ <cstdint> type string.


---
### DEFUN `%EMIT-DVEC-TYPEDEF`
- **Args**: `(STREAM TYPE-SYM)`

  > Emit a C++ struct definition for a device vector type (e.g. ushort2).  >    Uses <cstdint> types for the members.  >    Uses 'struct NAME { };' (not typedef struct) so that the type name is in scope  >    inside the body, which is required for the friend operator<< declaration.  >    The operator<< prints space-separated components, matching the HOIST-EXPECT  >    substring-match convention.


---
### DEFUN `%COLLECT-DVEC-TYPES`
- **Args**: `(DECLARED-SIG ALIASES)`

  > Collect all distinct device vector type symbols used in DECLARED-SIG and ALIASES.  >    Checks cell element types from aliases and direct scalar param types.  >    Returns a deduplicated list ordered by first appearance.


---
### DEFUN `GENERATE-CPP-DVEC-TYPEDEFS`
- **Args**: `(STREAM DVEC-TYPES)`

  > Emit C++ typedef structs for all device vector types in DVEC-TYPES.  >    Called from generate-l0-launcher after generate-cpp-typedefs.


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
## File: `C:\Users\cperk\Documents\crisp-man\src\hoist\common.lisp`

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
### DEFUN `METACRISP-RECORDS`
- **Args**: `(METACRISP-DATA)`

  > Extract def-record definitions from metacrisp data.


---
## File: `C:\Users\cperk\Documents\crisp-man\src\hoist\package.lisp`

## File: `C:\Users\cperk\Documents\crisp-man\src\llvm-bindings.lisp`

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
### DEFUN `LLVM-TYPE-KIND-IS-ARRAY?`
- **Args**: `(TY)`

  > Returns T if TY is an LLVM array type ([N x T]).


---
## File: `C:\Users\cperk\Documents\crisp-man\src\macros.lisp`

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
### DEFMACRO `WITH-PEEK-SCRATCH-COUNTER`
- **Args**: `(&BODY BODY)`

  > Executes body while insulating the global *scratch-cell-counter* from changes.  >    Used for look-ahead scans that shouldn't affect the main codegen counter state.  >    This is critical for single-pass compilation where we scan AND then codegen immediately.


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

  > Returns T if the type-spec is a storage handle but is missing explicit required keys  >    (address-space, access). Handles both the cell 4-tuple and tensor 6-tuple canonical forms.  >    A fully-expanded tensor spec (tensor elem N addr acc aln) — 5 args after head — is complete.


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

  > Helper: Validates that kernel parameters are complete, not voidp,  >    and that records do not appear in &out position.


---
### DEFUN `%CHECK-DIFFERENTIATE-KERNEL-SIGNATURE`
- **Args**: `(NAME SIGNATURE-TYPES DECLARATIONS)`

  > Helper: Enforces kernel requirements when Auto-Differentiation is enabled.  >    Returns T if the kernel should be differentiated, NIL if it is forward-only.


---
### DEFUN `%GENERATE-BACKWARD-KERNEL-AST`
- **Args**: `(NAME PARAMS SIGNATURE-TYPES RAW-BODY)`

  > Generates the def-kernel-exact AST for the backward (gradient) pass.  >    Extends the original to handle def-record inputs at the kernel boundary  >    via Option B (scalar explosion before AD).


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
### DEFUN `%PARSE-CT-LITERAL`
- **Args**: `(VALUE)`

  > If VALUE is a symbol whose name looks like a typed numeric literal (e.g. 2.0F,  >    100UC), parse and return the underlying number.  Otherwise return VALUE unchanged.


---
### DEFUN `%GENERATE-STRUCT-ACCESSOR`
- **Args**: `(MEMBER-SPEC NAME PKG RUNTIME-INDEX)`

  > Helper: Generates accessor (and setter) for a single struct member.  >    Returns (values accessor-form new-runtime-index).  >    Fix: typed-literal symbols in :c-t defaults are resolved to their numeric values.


---
### DEFUN `%GENERATE-RAW-ACCESSOR`
- **Args**: `(MEMBER-SPEC NAME PKG RUNTIME-INDEX)`

  > Helper: Generates raw accessor for a runtime struct member.  >    Returns (values accessor-form new-runtime-index).


---
### DEFMACRO `DEF-STRUCT`
- **Args**: `(NAME &REST MEMBERS)`

  > Defines a new Crisp struct type. Supports brand declarations.


---
### DEFUN `%CT-RESOLVE-VALUE`
- **Args**: `(VALUE)`

  > Resolve VALUE to a Lisp number if it is a typed-literal symbol (e.g. 2.0F, 100UC).  >    SBCL reads suffix-notation literals as symbols; this converts them to the  >    underlying number so :c-t default accessors have the right return type.  >    Returns VALUE unchanged if it is not a recognisable typed literal.


---
### DEFMACRO `DEF-RECORD`
- **Args**: `(NAME &REST MEMBERS)`

  > Defines a new Crisp record type (virtual struct). Supports brand declarations.


---
### DEFMACRO `DEF-DERIVED-TYPE`
- **Args**: `(NEW-NAME ORIGINAL-TYPE &KEY (SUBST NIL SUBST-P))`

  > Defines a new derived type from an existing type.  >   >    Parameters:  >    - new-name: Symbol for the new type  >    - original-type: Type to derive from (must exist)  >    - :subst: Substitution mode - :no, :equal, :descendant, :ancestor  >   >    Automatically generates:  >    - make-<new-name> constructor (for structural types)  >    - as-<new-name> and as-<original> casting functions  >    - is-<new-name>? type predicate  >    - Property accessors (for struct types) - delegates to base type accessors  >   >    Example:  >      (def-derived-type meters float :subst :ancestor)


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
### DEFMACRO `%MARSHALL-TENSOR`
- **Args**: `(TYPE-ALIAS BYTE-SIZE PTR &REST FLAT-ARGS)`

  > Internal workhorse: assembles a tensor struct from flat positional scalar args.  >    Form: (%marshall-tensor type byte-size ptr off0..N-1 str0..N-1 ext0..N-1 length)  >    flat-args must contain exactly 3N+1 values: N offsets, N strides, N extents, 1 length.  >    Used by %explode-kernel-args, marshall-vector, marshall-matrix, and marshall-tensor.


---
### DEFMACRO `MARSHALL-TENSOR`
- **Args**: `(TYPE-ALIAS BYTE-SIZE PTR &REST KWARGS)`

  > Assembles a tensor struct from keyword-grouped scalar args.  >   >    Form:  >      (marshall-tensor type byte-size ptr  >        :offsets (o0 o1 ... oN-1)  >        :strides (s0 s1 ... sN-1)  >        :extents (e0 e1 ... eN-1)  >        :length  len)  >   >    type-alias must be a fully-specified tensor (or expanded vector/matrix) type.  >    Each sublist must contain exactly N elements matching the tensor arity.  >    All four keywords are required.


---
### DEFMACRO `MARSHALL-VECTOR`
- **Args**: `(TYPE-ALIAS BYTE-SIZE PTR OFF_0 STR_0 EXT_0 LENGTH)`

  > Assembles a vector (tensor N=1) from 6 flat scalar args.  >    type-alias must be a fully-specified vector or tensor N=1 type.  >    Delegates to %marshall-tensor after validating N=1.


---
### DEFMACRO `MARSHALL-MATRIX`
- **Args**: `(TYPE-ALIAS BYTE-SIZE PTR OFF_0 OFF_1 STR_0 STR_1 EXT_0 EXT_1
              LENGTH)`

  > Assembles a matrix (tensor N=2) from 9 flat scalar args.  >    type-alias must be a fully-specified matrix or tensor N=2 type.  >    Delegates to %marshall-tensor after validating N=2.


---
### DEFMACRO `SET-DERIVED`
- **Args**: `(ANCESTOR-TYPE DESCENDANT-TYPE)`

  > Links two existing struct types in a type hierarchy.  >    The descendant can implicitly pass where the ancestor is expected.  >    Generates as-<ancestor> and as-<descendant> casting functions.  >   >    Syntax: (set-derived ancestor-type descendant-type)  >   >    Requirements:  >    - Both types must be structs (or derived from structs)  >    - Ancestor size <= Descendant size  >    - Shape compatible (flattened data members match in type and byte offset)  >    - No cycles in the type DAG


---
### DEFMACRO `BRAND`
- **Args**: `(&REST ARGS)`

  > Catches invalid usage of BRAND outside of DEF-STRUCT or DEF-RECORD.


---
## File: `C:\Users\cperk\Documents\crisp-man\src\main.lisp`

### DEFUN `PRINT-COMPILER-ERROR`
- **Args**: `(C FILENAME)`

  > Prints a formatted compiler error to *error-output*.


---
### DEFUN `INITIALIZE-DEBUG-CONTEXT`
- **Args**: `(MODULE DI-BUILDER FILEPATH)`

  > Creates and returns the top-level DICompileUnit for a file.


---
### DEFUN `PARSE-CLI-ARGS`
- **Args**: `(ARGS)`

  > Parses command-line arguments and returns (values files output-file debug-p single-pass-p targets metadata-p hoist-targets).  > Supports one or more .crisp source files: the last file is treated as the primary (determines output name).


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

  > Compiles the given files as a single unit (in order), iterating over requested targets, then invokes hoisters.  > When multiple files are given, forms are read from each file in order and compiled together as if they  > had been one file.  The LAST file is the primary: its name determines output file names and the debug  > compile-unit filepath.


---
### DEFUN `MAIN`

  > Main entry point for the crisp-compile executable.


---
## File: `C:\Users\cperk\Documents\crisp-man\src\mangling.lisp`

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

  > Recursively groups tokens into lists based on template arity.  >    tokens: list of strings.  >    package: the fallback package for interning.  >    Returns: (values property-list remaining-tokens)  >    FIX: numeric token strings are parsed as integers before interning as symbols.


---
### DEFUN `UNMANGLE-TEMPLATE-STRUCT-NAME`
- **Args**: `(SYMBOL)`

  > Attempts to reverse mangling for known parameterized types like CELL.  >    Returns the list form (e.g. (CELL FLOAT :GLOBAL :READ-WRITE)) or NIL.  >    Returns NIL immediately for uninterned symbols (gensyms produced by  >    brand instance differentiation) since they cannot be mangled struct names.


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

  > Creates a string representation of a type spec for name mangling.  >    Extended to handle integers (e.g. tensor arity N in canonical list form).


---
## File: `C:\Users\cperk\Documents\crisp-man\src\metadata-val.lisp`

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
### DEFUN `VALIDATE-MULTIPLE-SCRATCH-CELLS`
- **Args**: `(METADATA-PATH)`

  > Validates that metadata contains 2 distinct implicit scratch cell parameters.


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
### DEFUN `VALIDATE-NO-SUBST-OVERLOADS`
- **Args**: `(IR-PATH)`

  > Validates that both distance_point_point and distance_coordinate_coordinate  >    are defined and called in the IR. Used for :subst :no tests where explicit  >    as-point/as-coordinate casts are required.


---
### DEFUN `COUNT-SUBSTRING`
- **Args**: `(NEEDLE HAYSTACK)`

  > Count occurrences of NEEDLE in HAYSTACK. Returns integer count.


---
### DEFUN `VALIDATE-DESCENDANT-DISTANCE`
- **Args**: `(IR-PATH)`

  > Validates descendant substitution: coordinate can substitute for point.  >    Expected: distance_point_point called 2x, distance_coordinate_coordinate called 1x.


---
### DEFUN `VALIDATE-ANCESTOR-DISTANCE`
- **Args**: `(IR-PATH)`

  > Validates ancestor substitution: point can substitute for coordinate.  >    Expected: distance_coordinate_coordinate called 2x, distance_point_point called 1x.


---
### DEFUN `VALIDATE-DERIVED-ACCESSORS`
- **Args**: `(IR-PATH)`

  > Validates that all five x~ accessor overloads are defined and called:  >    x__point, x__dot, x__conclusion, x__pair, x__coordinate.


---
### DEFUN `VALIDATE-GENERIC-GRAD-SIGNATURE`
- **Args**: `(IR-PATH FORWARD-NAME EXPECTED-COMMAS)`

---
### DEFUN `VALIDATE-BASIC-GRAD-SIGNATURE`
- **Args**: `(IR-PATH)`

---
### DEFUN `VALIDATE-POINT-IN-METADATA`
- **Args**: `(METADATA-PATH)`

  > Validates that the base struct 'point' appears in metadata when a derived  >    type is used on a kernel boundary. Also verifies derived type names like  >    'coordinate', 'dot', 'conclusion' are NOT listed as separate structs.


---
### DEFUN `VALIDATE-ADDITION-CHAIN-RULE`
- **Args**: `(IR-PATH)`

---
### DEFUN `VALIDATE-MULTIPLY-CHAIN-RULE`
- **Args**: `(IR-PATH)`

---
### DEFUN `VALIDATE-SUBTRACTION-CHAIN-RULE`
- **Args**: `(IR-PATH)`

---
### DEFUN `VALIDATE-DIVISION-CHAIN-RULE`
- **Args**: `(IR-PATH)`

---
### DEFUN `VALIDATE-TRANSCENDENTAL-CHAIN-RULE`
- **Args**: `(IR-PATH)`

---
### DEFUN `VALIDATE-NESTED-CHAIN-RULE`
- **Args**: `(IR-PATH)`

---
### DEFUN `VALIDATE-INTEGER-LITERALS-IR`
- **Args**: `(IR-PATH)`

  > Validates that integer literal suffixes produce the correct LLVM integer types.  >    Expects:  ret-uchar->i8, ret-char->i8, ret-short/ret-ushort->i16,  >              ret-uint->i32, ret-long/ret-ulong->i64.


---
### DEFUN `VALIDATE-FLOAT-LITERALS-IR`
- **Args**: `(IR-PATH)`

  > Validates that float literal suffixes produce the correct LLVM float types.  >    Expects: ret-half->half, ret-float->float, ret-bfloat16->bfloat, ret-double->double.


---
### DEFUN `%READ-METACRISP-FORMS`
- **Args**: `(PATH)`

  > Reads all top-level forms from a .metacrisp file. Returns NIL if file missing.


---
### DEFUN `%METACRISP-SECTION`
- **Args**: `(FORMS KEY)`

  > Returns the cdr of the first top-level form whose car is KEY.


---
### DEFUN `%METACRISP-FIND-KERNEL`
- **Args**: `(FORMS KERNEL-NAME)`

  > Returns the plist for the named kernel, or NIL.


---
### DEFUN `%FIND-RECORD-DEF`
- **Args**: `(RECORDS-SECTION NAME)`

  > Finds (def-record NAME ...) in a list of forms. Returns the form or NIL.


---
### DEFUN `%RECORD-MEMBER-COUNT`
- **Args**: `(REC-FORM)`

  > Counts the members listed in a (def-record NAME member...) form.


---
### DEFUN `%FIND-DECL-ENTRY`
- **Args**: `(DECL-SIG NAME)`

  > Finds the declared-signature entry whose :name matches (case-insensitive).


---
### DEFUN `VALIDATE-DEF-RECORD-IN-METADATA`
- **Args**: `(METADATA-PATH)`

  > Validates 01-basic-rec-meta: v-point at kernel boundary.  >    Checks :records section, physical width (2+3=5), and declared sig.


---
### DEFUN `VALIDATE-DEF-REC-WITH-CT-IN-METADATA`
- **Args**: `(METADATA-PATH)`

  > Validates 03-record-with-ct-meta: v-point with :c-t earnestness at kernel boundary.  >    Checks :records shows only 2 runtime members, physical width is 2+2+3=7,  >    and declared sig shows the full (v-point :earnestness 3.0) type for vp-2.


---
### DEFUN `VALIDATE-NESTED-REC-IN-METADATA`
- **Args**: `(METADATA-PATH)`

  > Validates 04-nested-records-meta: v-rect (containing v-point) at kernel boundary.  >    Checks both records in :records section, physical width is 4+3=7,  >    and declared sig shows vr with type v-rect and range (0 3).


---
### DEFUN `VALIDATE-NO-BRAND-IN-METADATA`
- **Args**: `(METADATA-PATH)`

  > Validates 09-branded-rec-elide: branded def-record at kernel boundary.  >    Checks that the :records section shows the base type (ulong) for branded  >    fields, not the brand type (token-t), and no brand declarations appear.


---
### DEFUN `%USER-RECORD-TYPE-P`
- **Args**: `(TYPE-SPEC)`

  > Returns T if TYPE-SPEC refers to a user-defined def-record (not a storage handle or primitive).  >    Handles both bare symbols and list forms like (v-point :earnestness 3.0).


---
### DEFUN `%ENUMERATE-PHYSICAL-TYPES`
- **Args**: `(TYPE-SPEC)`

  > Returns a flat list of primitive Crisp type-specs for TYPE-SPEC.  >    Records are recursively flattened to their runtime members (excluding :c-t members).  >    List forms like (v-point :earnestness 3.0) use the base record type.  >    Brand-typed members are resolved to their base types.


---
### DEFUN `VALIDATE-REC-KB-NON-OVERLOADABLE`
- **Args**: `(IR-PATH)`

  > Validates backward kernel for 01-non-overloadable-accessor.  >    Expects: (VP_X VP_Y C C_GRAD &out VP_X_GRAD VP_Y_GRAD) = 14 params = 13 commas.


---
### DEFUN `VALIDATE-REC-KB-BASIC`
- **Args**: `(IR-PATH)`

  > Validates backward kernel for 03-basic-rec-at-kb.  >    Same signature shape as non-overloadable: 14 params = 13 commas.


---
### DEFUN `VALIDATE-REC-KB-NOT-FLOAT`
- **Args**: `(IR-PATH)`

  > Validates backward kernel for 05-not-float.  >    x field is int (no grad), y is float.  >    Expects: (VP_X VP_Y C C_GRAD &out VP_Y_GRAD) = 11 params = 10 commas.


---
### DEFUN `VALIDATE-REC-KB-UNUSED-FIELD`
- **Args**: `(IR-PATH)`

  > Validates backward kernel for 07-unused-field.  >    Both fields are float, even though x is unused in the body (its grad is 0).  >    Expects: (VP_X VP_Y C C_GRAD &out VP_X_GRAD VP_Y_GRAD) = 14 params = 13 commas.


---
### DEFUN `VALIDATE-REC-KB-CT-PROP`
- **Args**: `(IR-PATH)`

  > Validates backward kernel for 09-compile-time-prop.  >    Two v-point inputs (c-t :earnestness excluded), each with 2 float fields.  >    Expects: (VP-1_X VP-1_Y VP-2_X VP-2_Y C C_GRAD &out VP-1_X_GRAD VP-1_Y_GRAD VP-2_X_GRAD VP-2_Y_GRAD)  >    = 22 params = 21 commas.


---
### DEFUN `VALIDATE-MULTIPLY-GRAD-METADATA`
- **Args**: `(PATHS)`

  > Validates the backward grad metacrisp for 01-multiply/cell_mult_grad kernel.  >    (A B &out C) -> backward: (A B C C_grad &out A_grad B_grad)  >    Checks: kernel name, physical sig (18 params = 6 cells x 3),  >    declared sig: a/b/c/c_grad (:in :read-only), a_grad/b_grad (:out :write-only),  >    and source path present.


---
### DEFUN `VALIDATE-RECORD-GRAD-METADATA`
- **Args**: `(PATHS)`

  > Validates the backward grad metacrisp for 03-record-at-boundary.  >    The record v-point (x float, y float) is exploded to scalar fields at the boundary.  >    Checks: kernel name, physical sig (14 params), declared sig (6 params):  >      vp_x/vp_y (float scalars, :in), c/c_grad (cells, :in :read-only),  >      vp_x_grad/vp_y_grad (cells, :out :write-only), and source path present.


---
### DEFUN `%FIND-STRUCT-DEF`
- **Args**: `(STRUCTS-SECTION NAME)`

  > Finds (def-struct NAME ...) in a list of forms from a :structs section.  > Returns the form or NIL.


---
### DEFUN `VALIDATE-DEF-STRUCT-IN-METADATA`
- **Args**: `(METADATA-PATH)`

  > Validates 056/01-basic-struct-meta: point at kernel boundary.  >    Checks :structs contains POINT (2 members) but NOT RECT,  >    physical-signature has 4 entries (1 struct + 3 cell), and  >    declared-signature shows p :in with type point.


---
### DEFUN `VALIDATE-DEF-STRUCT-WITH-CT-IN-METADATA`
- **Args**: `(METADATA-PATH)`

  > Validates 056/03-struct-with-ct-meta: point with :c-t earnestness.  >    Checks :structs shows 2 runtime members only (c-t earnestness excluded),  >    physical-signature has 5 entries (2 struct + 3 cell), and  >    declared-sig shows (point earnestness 3.0) for p2.


---
### DEFUN `VALIDATE-NESTED-STRUCT-IN-METADATA`
- **Args**: `(METADATA-PATH)`

  > Validates 056/04-nested-structs-meta: rect (containing point) at kernel boundary.  >    Checks :structs contains both RECT and POINT (dependency),  >    physical-signature has 4 entries (1 struct + 3 cell), and  >    declared-sig shows r :in rect.


---
### DEFUN `VALIDATE-STRUCT-NO-BRAND-IN-METADATA`
- **Args**: `(METADATA-PATH)`

  > Validates 056/09-branded-struct-elide: branded def-struct at kernel boundary.  >    Checks that the :structs section shows the base type (ulong) for branded  >    fields (not token-t), no brand declarations appear, and the kernel is present.


---
### DEFUN `VALIDATE-070-03-MATRIX-METADATA`
- **Args**: `(META-PATH)`

  > Validates .metacrisp for test 03-metadata-matrix.  >    Matrix (N=2): 3*2+3=9 slots for v (indices 0-8), then val at index 9.  >    :physical-signature — 10 entries  >    :declared-signature — v :rank 2 :align :compact :range (0 8); val :range (9 9)


---
### DEFUN `VALIDATE-070-01-VECTOR-METADATA`
- **Args**: `(META-PATH)`

  > Validates .metacrisp for test 01-metadata-vector.  >    Checks:  >      - physical-signature: (0 LONG) (1 (C-POINTER...)) (2 ULONG) x 5 = 7 slots  >      - declared-signature: val :range (0 0), v :range (1 6) :rank 1 :align :compact  >      - aliases: OUT-VEC-T with keyword-form type spec


---
### DEFUN `%071-KERNEL-BODY`
- **Args**: `(IR FUNCTION-NAME)`

  > Extracts the body of the named LLVM kernel function from IR string.  >    Searches for 'define ... @function-name' using a prefix match so that  >    mangled names like compact_mat_get_tensor_float_2_... are found by  >    searching for '@compact_mat_get'.  >    Returns the function body substring, or NIL if not found.


---
### DEFUN `%071-HAS-STRIDE-MUL`
- **Args**: `(BODY)`

  > Returns T if BODY contains a stride multiply: a 'mul i64' instruction  >    whose second operand is a register (not a ptrtoint sizeof constant).  >    Byte-offset multiplies (mul i64 %reg, ptrtoint(...)) are excluded.


---
### DEFUN `VALIDATE-071-01-COMPACT-VECTOR-GET-IR`
- **Args**: `(IR-PATH)`

  > Validates compact vector GET IR: no stride multiply, no offset load.  >    Checks:  >      - No 'mul i64 %reg, %reg' (stride multiply) in the kernel body.  >      - No load from offset field (field index 1)  — :compact skips offsets entirely.


---
### DEFUN `VALIDATE-071-02-COMPACT-VECTOR-SET-IR`
- **Args**: `(IR-PATH)`

  > Validates compact vector SET IR: no stride multiply, no offset load.  >    Checks:  >      - No 'mul i64 %reg, %reg' (stride multiply) in the kernel body.  >      - No load from offset field — :compact skips offsets entirely.


---
### DEFUN `VALIDATE-071-03-COMPACT-MATRIX-GET-IR`
- **Args**: `(IR-PATH)`

  > Validates compact matrix GET IR: exactly one mul i64 (Horner), no stride load.  >    Checks:  >      - Exactly one 'mul i64' in the kernel body  (i_0 * ext[1])  >      - No load from the strides array field (struct field index 2)


---
### DEFUN `VALIDATE-071-05-STRIDED-VECTOR-IR`
- **Args**: `(IR-PATH)`

  > Validates strided vector GET IR: stride multiply must be present.  >    Checks:  >      - A 'mul i64 %reg, %reg' (stride multiply) IS present in the kernel body.  >        This confirms the compact optimization is NOT applied to :strided tensors.


---
### DEFUN `%072-HAS-OFFSET-LOAD`
- **Args**: `(BODY)`

  > Returns T if BODY contains a load from the tensor offset field (struct field index 1).  >    The GEP pattern is 'i32 0, i32 1' (field 0=parent, 1=offsets, 2=strides, 3=extents).


---
### DEFUN `VALIDATE-072-01-COMPACT-OFFSET-VECTOR-GET-IR`
- **Args**: `(IR-PATH)`

  > Validates :compact-offset vector GET IR:  >      - No stride mul (compact strides)  >      - Offset field IS loaded (non-zero offset supported)  >      - add i64 present


---
### DEFUN `VALIDATE-072-02-COMPACT-OFFSET-VECTOR-SET-IR`
- **Args**: `(IR-PATH)`

  > Validates :compact-offset vector SET IR:  >      - No stride mul  >      - Offset field IS loaded


---
### DEFUN `VALIDATE-072-04-COMPACT-NO-OFFSET-IR`
- **Args**: `(IR-PATH)`

  > Validates :compact vector GET IR (strengthened regression):  >      - No stride mul  >      - No offset field load  ← new check vs 071


---
### DEFUN `%074-COUNT-KERNEL-PARAMS`
- **Args**: `(IR KERNEL-NAME)`

  > Returns the parameter count of the named kernel from the IR string,  >    or NIL if the kernel is not found.  >    Handles nested parens in type names like addrspace(3) by counting  >    only top-level commas.


---
### DEFUN `%074-HAS-LOCAL-PTR-PARAM`
- **Args**: `(DEFINE-LINE)`

  > Returns T if the define line contains a ptr addrspace(3) parameter.


---
### DEFUN `VALIDATE-074-02-SCRATCH-VECTOR-PROPAGATION-IR`
- **Args**: `(IR-PATH)`

  > Validates scratch vector propagation IR:  >      - kernel_a has 7 params: ptr addrspace(3) + 5 x i64 (implicit tensor N=1)  >        + i32 (explicit n)  >      - fun_c has the same expanded signature (is a carrier)


---
### DEFUN `VALIDATE-074-03-SCRATCH-TENSOR-PROPAGATION-IR`
- **Args**: `(IR-PATH)`

  > Validates scratch tensor (N=3) propagation IR:  >      - kernel_a has 13 params: ptr addrspace(3) + 11 x i64 (implicit tensor N=3)  >        + i32 (explicit n)  >      - fun_c has the same expanded signature


---
### DEFUN `VALIDATE-074-04-SCRATCH-MATRIX-PROPAGATION-IR`
- **Args**: `(IR-PATH)`

  > Validates scratch matrix (N=2) propagation IR:  >      - kernel_a has 11 params: ptr addrspace(3) + 8 x i64 (implicit tensor N=2)  >        + 2 x i64 (explicit row col as ulong)  >      - fun_c has the same expanded signature


---
### DEFUN `%075-FIND-KERNEL`
- **Args**: `(METACRISP-PATH KERNEL-NAME)`

  > Reads a metacrisp file and returns the plist for the named kernel, or NIL.


---
### DEFUN `%075-VALIDATE-TENSOR-IMPLICIT`
- **Args**: `(TAG K-DEF EXPECTED-TYPE-HEAD EXPECTED-N EXPECTED-SLOTS
              EXPECTED-ADDR-SPACE EXPECTED-SIZE-EXPR)`

  > Shared checker for 075-0x validators.  >    Verifies:  >      - exactly one implicit param  >      - :type is a cons whose first element is TENSOR with the correct N and :address-space  >      - :size-expr is present and equals EXPECTED-SIZE-EXPR  >      - :range spans exactly EXPECTED-SLOTS physical slots starting at 0  >      - :physical-signature has EXPECTED-SLOTS entries for the implicit range,  >        first entry (C-POINTER ...), remaining entries ULONG


---
### DEFUN `VALIDATE-075-01-SCRATCH-VECTOR-IMPLICIT-META`
- **Args**: `(META-PATH)`

  > Validates scratch vector (N=1) metacrisp:  >      - implicit :type is (TENSOR INT 1 :ADDRESS-SPACE :LOCAL ...) canonical list  >      - physical-signature has 6 exploded scalar entries for the implicit range  >      - :range is (0 5)


---
### DEFUN `VALIDATE-075-02-SCRATCH-TENSOR-N3-IMPLICIT-META`
- **Args**: `(META-PATH)`

  > Validates scratch tensor (N=3) metacrisp:  >      - implicit :type is (TENSOR FLOAT 3 :ADDRESS-SPACE :LOCAL ...) canonical list  >      - physical-signature has 12 exploded scalar entries for the implicit range  >      - :range is (0 11)


---
### DEFUN `VALIDATE-075-03-SCRATCH-MATRIX-IMPLICIT-META`
- **Args**: `(META-PATH)`

  > Validates scratch matrix (N=2) metacrisp:  >      - implicit :type is (TENSOR FLOAT 2 :ADDRESS-SPACE :LOCAL ...) canonical list  >      - physical-signature has 9 exploded scalar entries for the implicit range  >      - :range is (0 8)


---
## File: `C:\Users\cperk\Documents\crisp-man\src\metadata.lisp`

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
### DEFUN `%SERIALIZE-RECORDS`
- **Args**: `(STREAM STRUCTS-HASH)`

  > Emits the (:records ...) section for user-defined records found in STRUCTS-HASH.  >    Only runtime members are emitted (no :c-t members). Brand types resolved to base.


---
### DEFUN `SERIALIZE-STRUCTS`
- **Args**: `(STREAM STRUCTS-HASH)`

  > Emits (:records ...) for def-records and (:structs ...) for def-structs.  >    Records are split into their own section; brand and :c-t members handled.  >    For def-structs: c-t members are excluded (they are compile-time constants  >    not in the runtime memory layout).


---
### DEFUN `EXTRACT-DEFINED-KERNELS`
- **Args**: `(FORMS)`

---
### DEFUN `GENERATE-METADATA-FOR-FILE`
- **Args**: `(INPUT-PATH OUTPUT-PATH &KEY (OUTPUT-TARGETS NIL)
              (SOURCE-FILE NIL) (FORMS NIL))`

  > Generates .metacrisp sidecar files for each kernel in INPUT-PATH.  >    In differentiate mode (*differentiate-p*), generates metadata for the backward  >    (_GRAD) kernel rather than the forward kernel, while preserving the file-name  >    convention established by main.lisp (output-path already carries the _grad prefix).


---
### DEFUN `GET-PHYSICAL-WIDTH`
- **Args**: `(TYPE)`

  > Returns the number of physical ABI slots for TYPE.  >    Cell -> 3, Storage -> 2, user-defined records -> recursively counted, others -> 1.


---
### DEFUN `GENERATE-PHYSICAL-SIGNATURE`
- **Args**: `(SIG-OR-PARAMS)`

  > Generates the physical ABI signature from kernel parameters.  >    Records are flattened to primitive scalar entries.


---
### DEFUN `VALIDATE-14-PHYSICAL-SIGNATURE`
- **Args**: `(PATHS)`

---
### DEFUN `GENERATE-DECLARED-SIGNATURE`
- **Args**: `(SIG &OPTIONAL DECLARED-PARAMS)`

  > Generates the declared-signature plist for a kernel's metadata.  >    Handles user-defined records by using the corrected get-physical-width.


---
### DEFUN `GENERATE-IMPLICIT-SIGNATURE`
- **Args**: `(SIG DECLARED-PARAMS)`

  > Generates the :implicit-params plist for metadata serialization.  >    Handles CELL canonical lists (positional addr-space/access at idx 2/3) and  >    TENSOR/VECTOR/MATRIX canonical lists (positional addr-space/access at idx 3/4),  >    and includes :size-expr from *implicit-scratch-size-expr-map*.


---
### DEFUN `SERIALIZE-KERNELS`
- **Args**: `(OUTPUT-STREAM KERNEL-NAMES &KEY SOURCE OUTPUT-TARGETS)`

---
### DEFUN `%BWD-RESOLVE-TYPE`
- **Args**: `(TYPE-SPEC &OPTIONAL NEW-ACCESS)`

  > Resolves TYPE-SPEC alias to its inline form. If NEW-ACCESS (:read-only or :write-only)  >    is provided and the resolved type is a cell, replaces the :access keyword value.  >    Used to build semantically correct declared-types for backward kernel metadata (Option B).


---
### DEFUN `%BWD-FIXUP-DECLARED-TYPES`
- **Args**: `(BWD-K-NAME)`

  > Reads BWD-K-NAME's entry in *kernel-declared-signatures*, produces semantically  >    correct inline types (Option B), and updates the entry in place.  >    Rules:  >      - Params before &out: resolve alias, force cell :access to :read-only  >      - Params after  &out: resolve alias, force cell :access to :write-only  >    This corrects the raw types stored by %generate-backward-kernel-ast, which  >    copies them mechanically from the forward kernel's type list.


---
## File: `C:\Users\cperk\Documents\crisp-man\src\package.lisp`

## File: `C:\Users\cperk\Documents\crisp-man\src\parameters.lisp`

### DEFSTRUCT `PARAMETER-DEF`

  > Represents a function parameter with its type, kind, and metadata.  >    Replaces the legacy list format: (name type :kind kind ...)


---
## File: `C:\Users\cperk\Documents\crisp-man\src\reader.lisp`

## File: `C:\Users\cperk\Documents\crisp-man\src\semantic.lisp`

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
### DEFSTRUCT `SEMANTIC-DEVICE-VEC-LITERAL`

  > Represents a ##(...) device vector literal.  >    VEC-TYPE is the full Crisp type symbol (e.g. 'float4).  >    ELEMENT-TYPE is the component type symbol (e.g. 'float).  >    WIDTH is the number of elements (2, 3, or 4).  >    ELEMENTS is a list of analyzed semantic nodes, one per element.


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
### DEFSTRUCT `SEMANTIC-SIN`

---
### DEFSTRUCT `SEMANTIC-COS`

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
### DEFSTRUCT `SEMANTIC-CT-ARRAY`

  > Represents construction of a (array T N) value from N scalar T values.  >    Used by marshall-tensor to assemble offset/strides/extents array fields.


---
### DEFSTRUCT `SEMANTIC-PROGN`

  > Represents a (progn ...) expression.


---
### DEFSTRUCT `SEMANTIC-SIZEOF`

  > Represents a sizeof(type) expression.


---
## File: `C:\Users\cperk\Documents\crisp-man\src\session.lisp`

### DEFSTRUCT `COMPILER-SESSION`

  > Holds the state for a single compilation session or pass.


---
### DEFSTRUCT `COMPILER-CONTEXT`

  > Holds the mutable state for the current analysis pass, replacing global variables.


---
### DEFVAR `*COMPILER-SESSION*`

  > The active compiler session state. Bound dynamically during compilation passes.


---
### DEFVAR `*COMPILER-CONTEXT*`

  > The active analysis context context. Bound dynamically during compilation passes.


---
## File: `C:\Users\cperk\Documents\crisp-man\src\structs.lisp`

### DEFUN `%STRUCT-NATIVE-ALIGNMENT`
- **Args**: `(STRUCT-NAME)`

  > Returns the native scalar alignment of a struct: the maximum alignment of  >    all its runtime members (recursively resolved).  This is the struct's  >    own alignment requirement under native scalar layout rules.


---
### DEFUN `GET-NATIVE-BASE-ALIGNMENT`
- **Args**: `(TYPE-SPEC)`

  > Returns the base alignment (in bytes) for TYPE-SPEC under native scalar rules.  >    Scalars: natural size.  Arrays: element alignment.  Structs: max member alignment.


---
### DEFUN `GET-NATIVE-SIZE`
- **Args**: `(TYPE-SPEC)`

  > Returns the size (in bytes) of TYPE-SPEC under native scalar rules.  >    Arrays: N * elem-size (compact, no per-element 16-byte padding).  >    Structs: total-size as recorded (compact layout).  Scalars: natural size.


---
### DEFUN `CALCULATE-NATIVE-PADDING`
- **Args**: `(CURRENT-OFFSET ALIGNMENT)`

  > Calculates padding needed to reach the next alignment boundary.


---
### DEFUN `COMPUTE-NATIVE-LAYOUT`
- **Args**: `(MEMBERS)`

  > Computes native scalar layout for a struct.  >    Members are placed at their natural alignment boundaries (same as before).  >    Total struct size is padded to the struct's overall alignment, which equals  >    the maximum alignment of any member — NOT to 16.  >    Returns (values expanded-members total-size).


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
### DEFUN `LOOKUP-STRUCT-DEFINITION`
- **Args**: `(TYPE-NAME)`

  > Looks up a struct definition, handling derived types and package issues.  >    Returns the struct definition or NIL if not found.  >   >    This function:  >    1. Resolves derived types to their base type using get-type-base  >    2. Tries package-agnostic lookup (current package, then :crisp-language)  >    3. Works for both structs and records (both stored in *crisp-structs*)


---
### DEFUN `REGISTER-STRUCT-DEFINITION`
- **Args**: `(NAME MEMBERS &OPTIONAL (CATEGORY STRUCT))`

  > Registers a struct or record definition in the global registry.  >    Extended: for records, validates that no (array T N) member has N > 16.


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
## File: `C:\Users\cperk\Documents\crisp-man\src\templates.lisp`

### DEFSTRUCT `TEMPLATE-DATA`

  > Stores the definition of a template function.


---
### DEFVAR `*PARTIAL-TEMPLATE-INSTANTIATIONS*`

  > Maps template name symbols to lists of partial instantiation plists.  >    Each plist has keys:  >      :partial-mangled-name - symbol for the partial concrete type (e.g. FAKE-CELL_INT)  >      :data-members         - ordered data-member specs (excluding brand forms)


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
### DEFUN `STRIP-KEYWORD-LABELS`
- **Args**: `(TYPE-LIST TEMPLATE-PARAMS)`

  > Strips keyword LABEL pairs from a type specifier list, keeping keyword VALUES.  >    A keyword is treated as a label (and stripped) only when the element following  >    it is a template parameter.  Keyword values (concrete types like :global) are kept.  >    e.g. (fake-cell T :address-space addr :access acc) with params (T addr acc)  >         => (fake-cell T addr acc)  >    But  (cell T :global :read-write) with params (T)  >         => (cell T :global :read-write)  -- :global and :read-write are values, kept.


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

  > Recursively matches sig-type against arg-type, updating inference-map.  >    FIX: Resolves type aliases (e.g., FC-INT -> (FAKE-CELL INT ...)) before matching  >    list structures, so def-type aliases work with template inference.


---
### DEFUN `MATCH-LIST-STRUCTURE`
- **Args**: `(SIG-LIST ARG-LIST INFERENCE-MAP TEMPLATE-PARAMS)`

---
### DEFUN `MATCH-FUNCTION-SIGNATURE`
- **Args**: `(PATTERN-SIG CONCRETE-SIG INFERENCE-MAP TEMPLATE-PARAMS)`

---
### DEFUN `INITIALIZE-TEMPLATES`

  > Initializes the template system and hooks into the compiler.  >    Extended to register ARRAY as a built-in arity-2 form for unmangle support.


---
### DEFUN `INSTANTIATE-TEMPLATE`
- **Args**: `(NAME-OR-TMPL CONCRETE-TYPES &OPTIONAL OVERRIDE-NAME)`

  > Generates the specialized code for a template.   >    name-or-tmpl can be a symbol (name) or a template-data struct.  >    override-name: If provided (string or symbol), renames the generated function/kernel.


---
### DEFUN `%INSTANTIATE-STRUCTURE-TEMPLATE`
- **Args**: `(NAME BODY SUBSTITUTIONS CONCRETE-TYPES)`

  > Instantiates a struct template with the given substitutions and concrete types.  >    For incomplete templates (those with :c-t fields lacking a default value), stores  >    partial instantiation info in *partial-template-instantiations* and installs a CL  >    macro for MAKE-X%DISPATCH so dispatch can complete the type at call-site expansion.  >    For complete templates, generates the wrapper def-function and registers the overload  >    as before.


---
### DEFUN `%DISPATCH-INCOMPLETE-TEMPLATE`
- **Args**: `(TEMPLATE-NAME ALL-ARGS)`

  > Called at CL macro expansion time when MAKE-X%DISPATCH expands for an incomplete  >    struct template. Maps positional args back to keyword args and calls the partial  >    struct's constructor with all values (including the required incomplete CT ones).  >    Returns a direct constructor call whose result type is the partial mangled type  >    (e.g. FAKE-CELL_INT), preserving correct arity for template function resolution.


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

  > Helper: Attempts to infer template types for a single template.  > Returns NIL on failure, or (list template-data concrete-types) on success.  > Extended: HOF-type sig-params are allowed to fail matching when all template  > parameters have already been inferred from earlier arguments.


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
## File: `C:\Users\cperk\Documents\crisp-man\src\type-checker.lisp`

### DEFUN `GET-PROMOTED-TYPE`
- **Args**: `(TYPE-A-NAME TYPE-B-NAME)`

  > Determines result type of binary operation with alias resolution.  >    Now uses type derivation hierarchy (DAG) for promotion rules.  >    Cross-package same-name fix: device vector types like USHORT2 may be interned in  >    :crisp-language or :crisp.compiler depending on the code path; treat same symbol-name  >    as the same type after alias resolution.


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
- **Args**: `(OP EXPLICIT-ARG-TYPES CONTEXT)`

  > Finds the best matching function signature for the given operator and argument types.  >    Attempts template instantiation if no immediate match is found.


---
## File: `C:\Users\cperk\Documents\crisp-man\src\types\brand.lisp`

### DEFVAR `*BRAND-INSTANCE-CACHE*`

  > Per-function cache mapping (brand-name . variable-identity) to a gensym'd  >    instance-specific type name. Cleared at the start of each function compilation.


---
### DEFVAR `*BRAND-CACHE-LAST-FUNCTION*`

  > The name of the function for which the brand instance cache was last cleared.


---
### DEFVAR `*BRAND-INSTANCE-TYPES*`

  > Maps gensym brand-instance type names (created by resolve-brand-type) to  >    the brand-name they instantiate.  Consulted by resolve-dominance to block  >    cross-instance arithmetic and to preserve instance types in arithmetic  >    with the brand's base type.  >    Cleared alongside *brand-instance-cache* in initialize-compiler.


---
### DEFUN `BRAND-ACTIVE-P`
- **Args**: `(BRAND-DEF)`

  > Returns T if the given brand should be actively enforced in the current compilation.  >    A brand is active when :enforce is :always, or when :enforce is :diff  >    and *differentiate-p* is set.


---
### DEFUN `IS-BRAND-TYPE-P`
- **Args**: `(TYPE-NAME)`

  > Returns the brand-definition if TYPE-NAME is a registered brand, NIL otherwise.


---
### DEFUN `BRAND-MEMBER-P`
- **Args**: `(MEMBER-TYPE)`

  > Returns T if MEMBER-TYPE is a branded type whose brand is currently active.


---
### DEFUN `PARSE-BRAND-DECLARATION`
- **Args**: `(BRAND-FORM)`

  > Parses a brand declaration form: (brand name base-type :subst mode &optional :enforce mode).  >    Returns a brand-definition struct.


---
### DEFUN `REGISTER-BRAND-DEFINITION`
- **Args**: `(STRUCT-NAME BRAND-FORM)`

  > Registers a brand declaration from within a struct definition.  >    When the brand is active: registers as a derived type in the DAG.  >    When inactive: registers as a type alias (transparent erasure).  >    Parameterized brands (base type varies across template specializations,  >    and the brand is NOT used as a concrete struct member type) skip global  >    registration and are resolved lazily per-owner.  >    Brands that conflict in base type AND appear as a concrete struct member  >    in the existing owner are always an error (cannot be parameterized).  >   >    Non-symbol base types (e.g., compound types like (POINT INT)) are silently  >    skipped: they cannot be registered in the type DAG.


---
### DEFUN `RESOLVE-BRAND-TYPE`
- **Args**: `(BRAND-NAME VAR-REF &OPTIONAL BASE-TYPE)`

  > Resolves a branded type for a specific variable instance.  >    Returns a gensym'd type name unique to (brand-name, var-ref [, base-type]).  >   >    When BASE-TYPE is supplied the gensym is registered as a :descendant of  >    BASE-TYPE directly.  BASE-TYPE is first normalized against the type registries  >    to handle package mismatches: unmangle-template-struct-name creates symbols in  >    crisp.compiler (the cell type's package) while user structs are stored in  >    crisp-language (Fix D reads source files in that package).  A name-based scan  >    of *type-derivation-graph* then *crisp-structs* finds the canonical symbol.  >   >    When BASE-TYPE is NIL, the gensym is registered as a :descendant of  >    brand-name (original behaviour, used by fake-cell / template brands).  >   >    In all cases the gensym is stored in *brand-instance-types* under brand-name  >    so that resolve-dominance can block cross-instance arithmetic.


---
### DEFUN `VALIDATE-DEPENDENT-BRAND-TYPES`
- **Args**: `(DECLARE-FORMS ENV)`

  > Verifies that any parameters typed as (brand var) refer to a valid owner parameter.  >    Scans the raw declarations to find dependencies that parse-type-specifier might have flattened.  >    Supports shared brands (same brand name defined on multiple structs).  >    Uses find-brand-for-owner for alias resolution (e.g., FC-INT -> FAKE-CELL_INT_GLOBAL_READ-WRITE).


---
### DEFUN `%FIND-BRAND-OWNER-VAR`
- **Args**: `(BRAND-NAME SIG-PARAMS ARG-NODES)`

  > Finds the actual argument variable for the parameter that owns the brand instance.  >    Handles shared brands by checking if any parameter's type is a registered owner  >    for the given BRAND-NAME. Uses find-brand-for-owner for alias resolution.


---
### DEFVAR `*PARAMETERIZED-BRAND-NAMES*`

  > Set of brand names whose base type varies across template specializations.  >    These brands skip global type registration and are resolved lazily per-owner.


---
### DEFUN `RESOLVE-OWNER-TYPE-TO-MANGLED`
- **Args**: `(TYPE-SPEC)`

  > Resolves a type specifier (which may be an alias like FC-INT) to its  >    canonical mangled form (like FAKE-CELL_INT_GLOBAL_READ-WRITE).  >    Used for looking up per-owner brand definitions.


---
### DEFUN `FIND-BRAND-FOR-OWNER`
- **Args**: `(BRAND-NAME OWNER-TYPE)`

  > Looks up a brand definition for the given brand name and owner type.  >    Resolves type aliases (e.g., FC-INT -> FAKE-CELL_INT_GLOBAL_READ-WRITE)  >    before lookup.


---
### DEFUN `RESOLVE-PARAMETERIZED-BRAND-IN-ENV`
- **Args**: `(BRAND-SPEC ENV)`

  > Resolves a parameterized brand application (brand-name var-ref) using  >    the function environment. Returns the concrete base type for the brand  >    based on the variable's owner type.  >    For inactive brands, returns the base type directly (transparent).  >    For active brands, returns the base type (instance differentiation  >    happens later in analyze-function-call).


---
## File: `C:\Users\cperk\Documents\crisp-man\src\types\definitions.lisp`

### DEFSTRUCT `ENUMERATION-DEF`

---
## File: `C:\Users\cperk\Documents\crisp-man\src\types\hierarchy.lisp`

### DEFSTRUCT `TYPE-NODE`

  > Represents a type in the derivation hierarchy (DAG).  >    Used for both 'real' types (scalars, structs) and derived types.


---
### DEFVAR `*TYPE-DERIVATION-GRAPH*`

  > Maps type-name (symbol) -> type-node for all types (real and derived).


---
### DEFUN `INITIALIZE-TYPE-HIERARCHY`

  > Initializes the type derivation graph (starts empty).  >    User-defined derived types will be added via def-derived-type.  >    Built-in numeric types use the existing size-based promotion system.


---
### DEFUN `CREATE-ROOT-TYPE-NODE`
- **Args**: `(TYPE-NAME)`

  > Creates a root type node for a built-in 'real' type with no derivation relationships.


---
### DEFUN `CREATE-NUMERIC-HIERARCHY`
- **Args**: `(TYPE-NAMES)`

  > Creates a linked hierarchy of numeric types.  >    type-names should be ordered from most specific to most general.  >    Example: '(char short int long) creates char -> short -> int -> long.


---
### DEFUN `IS-SUBSTITUTABLE-FOR?`
- **Args**: `(SOURCE-TYPE TARGET-TYPE)`

  > Returns T if SOURCE-TYPE can be used where TARGET-TYPE is expected.  >    This is the fundamental 'Can I put peg A in hole B?' check.  >   >    Algorithm:  >    - If types are equal, return T  >    - Walk UP from source through ancestors to find target  >    - Handles cycles (from :equal relationships) via visited tracking


---
### DEFUN `TYPES-ASSIGNABLE-P`
- **Args**: `(SOURCE-TYPE TARGET-TYPE)`

  > Checks if source-type can be assigned to target-type.  >    This is true if:  >    1. The types feature exact equivalence (types-equivalent-p)  >    2. The source type represents a derived type that is substitutable for the target (is-substitutable-for?)


---
### DEFUN `HAS-ANCESTOR-PATH?`
- **Args**: `(FROM-TYPE TO-TYPE VISITED)`

  > Walk UP through ancestors from FROM-TYPE to find TO-TYPE.  >    Returns T if path exists, NIL otherwise.  >    VISITED hash table prevents infinite loops (from :equal cycles).


---
### DEFUN `GET-TYPE-BASE`
- **Args**: `(TYPE-NAME)`

  > Returns the base 'real' type for a given type (derived or real).  >    If the type is not in the derivation graph, returns the type itself.


---
### DEFUN `GET-REACHABLE-TYPES`
- **Args**: `(TYPE-NAME)`

  > Returns a list of all types that TYPE-NAME can substitute for (including itself).  >    Uses BFS to walk up the ancestor graph, plus handles :equal relationships.  >    Returns types in order from closest to farthest (BFS order).


---
### DEFUN `FIND-COMMON-PROMOTED-TYPE`
- **Args**: `(TYPE-A TYPE-B)`

  > Finds the best common type for promotion in binary operations.  >    Returns the closest common type that both can substitute for.  >   >    Algorithm:  >    1. Calculate all types type-a can reach (substitute for)  >    2. Calculate all types type-b can reach  >    3. Find intersection  >    4. Return the first common type in type-a's reachable list (closest to type-a)  >   >    Returns NIL if no common type exists.


---
### DEFUN `RESOLVE-DOMINANCE`
- **Args**: `(TYPE-A TYPE-B)`

  > Determines which type dominates in arithmetic operations.  >    Returns the dominant type, or NIL if the types cannot mix.  >   >    Brand-instance rules are applied BEFORE substitutability so that a brand  >    instance always wins over the plain type it descends from:  >    - Same type: return it.  >    - Both instances of the SAME brand (different vars): cannot mix -> NIL.  >    - One brand instance, one non-brand: brand instance dominates.  >    - Neither is a brand instance: standard substitutability /  >      find-common-promoted-type.


---
### DEFUN `COMPUTE-BASE-TYPE`
- **Args**: `(ORIGINAL-TYPE-NAME)`

  > Walks the original-type chain to find the root 'real' type.  >    Returns the base type name, or NIL if not found.


---
### DEFUN `REGISTER-DERIVED-TYPE`
- **Args**: `(NEW-TYPE-NAME ORIGINAL-TYPE-NAME SUBST-MODE)`

  > Registers a new derived type in the type derivation graph.  >   >    Parameters:  >    - new-type-name: Symbol for the new derived type  >    - original-type-name: Symbol for the type being derived from  >    - subst-mode: One of :no, :equal, :descendant, :ancestor  >   >    Validates:  >    - Original type must exist (in *type-derivation-graph*, *crisp-types*, or *crisp-structs*)  >    - Subst-mode must be valid  >   >    Updates:  >    - Creates new type-node with computed base-type  >    - Updates ancestor/descendant relationships based on subst-mode


---
### DEFUN `REGISTER-SET-DERIVED`
- **Args**: `(ANCESTOR-TYPE-NAME DESCENDANT-TYPE-NAME)`

  > Registers a set-derived relationship between two existing struct types.  >    The descendant can implicitly substitute for the ancestor (like :descendant subst-mode).  >   >    Parameters:  >    - ancestor-type-name: The 'smaller' or contained type  >    - descendant-type-name: The 'larger' or extension type  >   >    Validates:  >    - Both types must exist  >    - Both must be structs (or derived from structs) -- not records, scalars, functions, or enums  >    - Ancestor size <= Descendant size  >    - Shape compatibility (flattened data members with matching types and byte offsets)  >    - No cycles in the type hierarchy DAG


---
### DEFUN `FLATTEN-STRUCT-DATA-MEMBERS`
- **Args**: `(STRUCT-DEF)`

  > Recursively flattens a struct definition to its scalar data members.  >    Returns a list of (type byte-offset) pairs, skipping padding fields.  >    Nested structs are expanded recursively.


---
### DEFUN `VALIDATE-SET-DERIVED-SHAPE`
- **Args**: `(ANCESTOR-STRUCT DESCENDANT-STRUCT ANCESTOR-NAME DESCENDANT-NAME)`

  > Validates shape compatibility for set-derived.  >    Flattens both structs and checks that each ancestor data member has a  >    matching data member in the descendant with the same type and byte offset.


---
## File: `C:\Users\cperk\Documents\crisp-man\src\types\registry.lisp`

### DEFVAR `*GENERIC-FUNCTIONS*`

  > Registry of generic function templates (functions with &optional or &key parameters)   >    that are instantiated lazily. Key: function name symbol. Value: generic-function-def struct.


---
### DEFVAR `*FUNCTION-TABLE*`

  > A hash table mapping function names (symbols) to a list of  >   FUNCTION-SIGNATURE structs. This supports overloading.


---
### DEFVAR `*DIFFERENTIABLE-FUNCTIONS*`

  > Registry of user def-functions for which a _GRAD backward companion has been generated.  > Maps function-name -> (:bkwd-name sym :n-float-params N :n-return M).


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
### DEFVAR `*BRAND-DEFINITIONS*`

  > Maps (brand-name . struct-type) to brand-definition records.  >    Populated when def-struct / def-record with brand declarations are processed.


---
### DEFSTRUCT `BRAND-DEFINITION`

  > Stores the definition of a branded type declared inside a struct/record.


---
### DEFVAR `*DIFFERENTIATE-P*`

  > If T, enable differentiation mode. Activates branded type enforcement  >    for brands declared with :enforce :diff (the default).


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

  > Populates *crisp-types* with built-in scalar types and device vector types.


---
## File: `C:\Users\cperk\Documents\crisp-man\src\types\validation.lisp`

### DEFUN `EXCLUDED-TEMPLATE-BASE-TYPE-P`
- **Args**: `(BASE-TYPE)`

  > Returns true if the base-type should be excluded from struct template processing.  >    Excludes COMMON-LISP special forms like FUNCTION and QUOTE to prevent package lock violations.


---
### DEFUN `RESOLVE-TYPE-ALIAS`
- **Args**: `(TYPE-SPEC)`

  > Fully resolves a type alias chain, returning the underlying type.  >    Includes cycle detection to prevent infinite loops.  >    SIGNALS ERROR if a cycle is detected.


---
### DEFUN `%BARE-STORAGE-HANDLE-VALUE-ERROR`
- **Args**: `(ITEM SPEC)`

  > Raises an intelligent error when a bare address-space/access/align value  >    is found in a storage handle type spec, suggesting the correct key-value form.


---
### DEFUN `EXPAND-STORAGE-HANDLE-TYPE-SPECIFIER`
- **Args**: `(SPEC)`

  > Expands storage handle type specs into canonical positional forms.  >    Cell        → (cell  elem addr access)               [4-tuple, defaults :global :read-write].  >    Vector      → (tensor elem 1 addr access align)      [6-tuple, sugar for tensor N=1].  >    Matrix      → (tensor elem 2 addr access align)      [6-tuple, sugar for tensor N=2].  >    Tensor      → (tensor elem N addr access align)      [6-tuple, defaults :global :read-write :compact].  >    Vector/matrix with extra positional arg → error.  >    Tensor missing N → crisp-incomplete-type-error.  >    Bare address-space/access/align values → intelligent 'did you mean :key value?' error.  >    Address-space / access / align MUST use key-value form: :address-space :local etc.


---
### DEFUN `PARSE-TEMPLATE-PARAMETER-SPEC`
- **Args**: `(PARAM)`

  > Parses (Name [Type] [Default]) -> (list Name Type Default)


---
### DEFUN `VALIDATE-TEMPLATE-ARG`
- **Args**: `(ARG TYPE NAME)`

---
### DEFUN `CANONICALIZE-TYPE-SPECIFIER`
- **Args**: `(SPEC)`

  > Canonicalizes type specifiers.  >    Extended: (array T N) is returned as-is before the template path, preventing  >    mangle to ARRAY_LONG_5 via the get-template-arity=2 path.


---
### DEFUN `%TYPE-ATOM-EQUAL-P`
- **Args**: `(A B)`

  > Package-agnostic atom comparison for type specs.  >    Symbols compared by name (string-equal); others compared by equal.


---
### DEFUN `%TYPE-SPEC-EQUAL-P`
- **Args**: `(T1 T2)`

  > Recursive package-agnostic comparison of type spec trees.  >    Used in types-equivalent-p for the cons-vs-cons case.


---
### DEFUN `TYPES-EQUIVALENT-P`
- **Args**: `(T1 T2)`

  > Checks if two types are equivalent, with alias resolution and template handling.  >    FIX: Always canonicalize list type specs (not just CELL) to strip keyword labels  >    before mangling comparison. This supports def-type aliases for any template type.  >    FIX2: Use %type-spec-equal-p (package-agnostic) for cons-vs-cons case.


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

  > Checks if type-spec is a valid function literal or descriptor.  > Extended to also accept raw (function ...) forms from the Crisp reader  > (i.e., #'(float float => float) which the CL reader gives as (function ...)).


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

  > Checks if type-spec is a valid parameterized type (cell, templates, array, etc).  >    Extended to recognise (array T N), reject nested arrays, and accept symbol counts  >    (e.g. the symbol |5| produced by unmangle-template-struct-name).


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
### DEFPARAMETER `*RESOLVE-DEPTH*`

---
### DEFUN `FIND-TEMPLATE-ROBUST`
- **Args**: `(NAME)`

---
### DEFUN `%ARRAY-TYPE-P`
- **Args**: `(TYPE-SPEC)`

  > Returns T if TYPE-SPEC is a list form whose head is the symbol ARRAY.  >    Used throughout the array implementation to identify (array T N) type specs.


---
### DEFUN `RESOLVE-TYPE-TO-LLVM`
- **Args**: `(TYPE-SPEC)`

  > Resolves a Crisp type specifier to an LLVM type reference.  >    Extended to handle (array T N) → LLVM [N x T_llvm].  >    Extended to normalize VECTOR/MATRIX sugar to TENSOR before dispatch,  >    and to canonicalize type alias values before recursing.


---
### DEFUN `INCOMPLETE-TYPE-P`
- **Args**: `(TYPE-SPEC)`

  > Checks if a type specifier is incomplete (missing required compile-time properties).  >    Returns T if incomplete, NIL if complete.


---
### DEFUN `EXTRACT-POSITIONAL-FROM-KEYWORD-ARGS`
- **Args**: `(ARGS NUM-PARAMS)`

  > Extract NUM-PARAMS positional template args from ARGS when (length ARGS) > NUM-PARAMS.  >   >    Two conventions are supported:  >    1. Labeled style: (:label value) pairs identify template params by a descriptive name.  >       e.g. (int :address-space :global :access :read-write) with arity 3  >            => (int :global :read-write)  >    2. Positional+c-t style: first NUM-PARAMS args are positional template args;  >       any remaining args are compile-time field overrides handled elsewhere.  >       e.g. (int :blue :stitching-c :black) with arity 2  >            => (int :blue)  >   >    Disambiguation: label-strip the entire list.  If the result has exactly  >    NUM-PARAMS elements, the labeled convention was used and that result is  >    returned.  Otherwise the positional+c-t convention was used and the first  >    NUM-PARAMS elements of ARGS are returned unchanged.


---
## File: `C:\Users\cperk\Documents\crisp-man\src\utils.lisp`

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
