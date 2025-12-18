# Crisp Codebase Reference

Generated on 2025-12-18T08:02:42.546108Z

## File: `C:\Users\cperk\Documents\crisp\src\package.lisp`

## File: `C:\Users\cperk\Documents\crisp\src\llvm-bindings.lisp`

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
## File: `C:\Users\cperk\Documents\crisp\src\semantic.lisp`

### DEFSTRUCT `CRISP-TYPE`

  > Represents a Crisp type.


---
### DEFSTRUCT `FUNCTION-SIGNATURE`

  > Represents the full signature of a Crisp function.


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
### DEFSTRUCT `SEMANTIC-VALUE-CAST`

  > Represents a value-preserving cast (e.g., to-float).


---
### DEFSTRUCT `SEMANTIC-BITCAST`

  > Represents a bit reinterpretation cast (e.g., as-int).


---
### DEFSTRUCT `SEMANTIC-FP-TRUNCATE-CAST`

  > Represents a float-to-integer truncation cast.


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
### DEFSTRUCT `SEMANTIC-STRUCT-CONSTRUCTION`

  > Represents constructing a struct instance e.g. (%construct-struct 'point ...).


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
### DEFMACRO `IF+`
- **Args**: `(TEST THEN &OPTIONAL ELSE)`

  > Compile-time conditional. Evaluates TEST at macro-expansion time.  >    Errors if TEST cannot be evaluated (e.g. relies on runtime values).


---
## File: `C:\Users\cperk\Documents\crisp\src\compiler.lisp`

### DEFVAR `*FUNCTION-TABLE*`

  > A hash table mapping function names (symbols) to a list of  >   FUNCTION-SIGNATURE structs. This supports overloading.


---
### DEFVAR `*SINGLE-PASS-CALL-STACK*`

  > A list of function names currently in the compilation stack, used to  >   detect recursion in single-pass mode.


---
### DEFVAR `*CALL-GRAPH*`

  > A hash table representing the call graph of functions.  >   Keys are caller function names, values are lists of callee names.


---
### DEFVAR `*TEMPLATE-INSTANTIATOR-FN*`

  > Hook for template instantiation.  >    Called as (funcall *template-instantiator-fn* name arg-types callback).  >    The callback is (funcall callback form location).


---
### DEFVAR `*TEMPLATE-REGISTRY*`

  > Maps template names (symbols) to a LIST of template-data structs.  > This supports overloading templates by arity or other factors.


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
### DEFVAR `*CRISP-TYPES*`

  > A hash table mapping type names (symbols) to CRISP-TYPE structs.


---
### DEFVAR `*CRISP-STRUCTS*`

  > A hash table mapping struct names to CRISP-STRUCT-DEFINITION structs.


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
### DEFUN `INITIALIZE-COMPILER`
- **Args**: `(&KEY (LOG-LEVEL INFO))`

  > A master initialization function for the Crisp compiler.  >   This should be called by any entry point into the system (REPL, executable, CI).


---
### DEFMACRO `DEF-FUNCTION`
- **Args**: `(NAME PARAMS &REST BODY-AND-LOCATION)`

  > Defines a new, thread-level Crisp function.


---
### DEFUN `EXCLUDED-TEMPLATE-BASE-TYPE-P`
- **Args**: `(BASE-TYPE)`

  > Returns true if the base-type should be excluded from struct template processing.  >    Excludes COMMON-LISP special forms like FUNCTION and QUOTE to prevent package lock violations.


---
### DEFUN `MANGLE-TEMPLATE-STRUCT-NAME`
- **Args**: `(NAME PARAMS)`

  > Generates the mangled name for a struct template instance. e.g. POINT (FLOAT) -> POINT_FLOAT


---
### DEFUN `TYPES-EQUIVALENT-P`
- **Args**: `(T1 T2)`

  > Checks if two types are equivalent, handling template struct canonicalization.


---
### DEFUN `TYPE-LISTS-EQUIVALENT-P`
- **Args**: `(L1 L2)`

---
### DEFUN `REGISTER-STRUCT-DEFINITION`
- **Args**: `(NAME MEMBERS)`

  > Registers a struct definition in the global registry.


---
### DEFUN `PARSE-STRUCT-MEMBER-SPEC`
- **Args**: `(SPEC)`

  > Parses a struct member specification.  >    Supports (name type) and (name:type).


---
### DEFMACRO `DEF-STRUCT`
- **Args**: `(NAME &REST MEMBERS)`

  > Defines a new Crisp struct type.


---
### DEFMACRO `DEF-SETTER`
- **Args**: `(NAME ARGS &BODY BODY)`

  > Defines a setter function (which is just a def-function but semantically intended for use with set!).  >    The return type is implicitly nil/void. We append (return) to ensure this.


---
### DEFUN `GET-STD140-BASE-ALIGNMENT`
- **Args**: `(TYPE-SPEC)`

  > Returns the base alignment (N) for a given type according to std140 rules.  >   For scalars, N is the size of the scalar.  >   For vectors, it is 2N or 4N.  >   For arrays/structs, it is rounded up to vec4 alignment (16).


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

  > Takes a list of (name type) members.  >   Returns a list of:  >     - Expanded members with `_pad` fields inserted.  >     - Total struct size (padded to 16 bytes).  >     >   Returns (values expanded-members total-size)


---
### DEFUN `VALID-TYPE-P`
- **Args**: `(TYPE-SPEC)`

  > Checks if a type specifier is valid.  >   Handles simple types, parameterized types, and function literals/types.


---
### DEFUN `RESOLVE-TYPE-TO-LLVM`
- **Args**: `(TYPE-SPEC)`

  > Resolves a Crisp type specifier to an LLVM type reference.


---
### DEFUN `ENSURE-STRUCT-LLVM-TYPE`
- **Args**: `(NAME)`

  > Ensures the LLVM struct type exists for the given struct name.  >    Handles forward declarations and recursion.


---
### DEFUN `ANALYZE-FUNCTION-LITERAL`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes a (function name) form, e.g., #'foo.


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
### DEFUN `SHALLOW-ANALYZE-BODY`
- **Args**: `(FORMS)`

  > Performs a shallow, recursive walk of a function's body.  >   Returns two values:  >   1. A boolean indicating if a side-channel originator was found.  >   2. A list of all unique symbols found in the 'car' of lists (potential function calls).


---
### DEFUN `VISIT-TOPLEVEL-FORM`
- **Args**: `(FORM LOCATION VISITOR-FN)`

  > Recursively visits a top-level form, handling macros and progn.  >    Visitor-fn is called as (visitor-fn form location) for def-function forms.  >    Other forms are evaluated if they are not special forms handled by the walker.


---
### DEFUN `COMPILE-DEF-FUNCTION`
- **Args**: `(FORM LOCATION MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT
              LOCATION-MAP)`

  > Compiles a single def-function form.


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
### DEFUN `PARSE-FUNCTION-DECLARATIONS`
- **Args**: `(PARAMS DECLARATIONS)`

  > Parses a function's declarations and returns its environment and return type.  >    Supports interleaved type syntax: ((p type))


---
### DEFUN `REGISTER-FUNCTION-SIGNATURE`
- **Args**: `(FORM LOCATION)`

  > Extracts and registers a function's signature without analyzing its body.


---
### DEFUN `INJECT-IMPLICIT-ARGUMENTS`
- **Args**: `(NAME EXPLICIT-ENV)`

  > Injects implicit arguments into the environment if the function is a carrier.


---
### DEFUN `SCAN-FOR-CARRIERS`
- **Args**: `(NAME BODY)`

  > Performs a single-pass look-ahead to detect if the function is a carrier.


---
### DEFUN `VALIDATE-RETURN-TYPES`
- **Args**: `(NAME BODY ENV DECLARED-RETURN-TYPES LOCATION)`

  > Analyzes the function body and validates return types.


---
### DEFUN `DETECT-AND-REGISTER-IMPLICIT-TEMPLATE`
- **Args**: `(NAME EXPLICIT-ENV RETURN-TYPE PARAMS BODY)`

  > Detects if a function is an implicit template (e.g. has function-type args),  >    and if so, registers it as a template and returns T. Otherwise returns NIL.


---
### DEFUN `INTERNAL-DEF-FUNCTION`
- **Args**: `(NAME PARAMS DECLARATIONS BODY LOCATION)`

  > This is the 'Semantic Analyzer' (Pass 2).


---
### DEFUN `PARSE-TYPE-SPECIFIER`
- **Args**: `(SPEC)`

  > Parses a single type specifier, handling basic types, parameterized types,  >    and function types like #'(int => int).


---
### DEFUN `ANALYZE-RETURN-TYPE-FROM-SPEC`
- **Args**: `(FN-SPEC)`

  > Parses '(int int => int int)' and returns a list of types.


---
### DEFUN `ANALYZE-ENVIRONMENT-FROM-SPEC`
- **Args**: `(PARAMS FN-SPEC)`

  > Builds the environment from the signature.


---
### DEFUN `ANALYZE-RETURN-TYPE-FROM-LIST`
- **Args**: `(DECLARATIONS)`

  > Finds and returns the return-type(s) from a (return-type ...) decl.


---
### DEFUN `ANALYZE-ENVIRONMENT-FROM-LIST`
- **Args**: `(PARAMS DECLARATIONS)`

  > Builds the environment from a (type ...) decl.


---
### DEFUN `GET-PROMOTED-TYPE`
- **Args**: `(TYPE-A-NAME TYPE-B-NAME)`

  > Determines the result type of a binary operation, applying promotion rules.


---
### DEFUN `ANALYZE-ADD-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes a `(+ ...)` expression.


---
### DEFUN `ANALYZE-SUB-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes a `(- ...)` expression.


---
### DEFUN `ANALYZE-MUL-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes a `(* ...)` expression.


---
### DEFUN `ANALYZE-DIV-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes a `(/ ...)` expression.


---
### DEFUN `ANALYZE-LT-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

---
### DEFUN `ANALYZE-GT-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

---
### DEFUN `ANALYZE-LE-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

---
### DEFUN `ANALYZE-GE-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

---
### DEFUN `ANALYZE-EQ-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

---
### DEFUN `ANALYZE-NEQ-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

---
### DEFUN `ANALYZE-CONSTRUCT-STRUCT-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes a `%construct-struct` expression.


---
### DEFUN `ANALYZE-EXTRACT-STRUCT-MEMBER-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes a `%extract-struct-member` expression.  >    Form: (%extract-struct-member object-node index-literal)


---
### DEFUN `ANALYZE-IF-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

---
### DEFUN `ANALYZE-WHEN-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

---
### DEFUN `ANALYZE-UNLESS-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

---
### DEFUN `ANALYZE-AREF-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

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
### DEFUN `ANALYZE-SCRATCH-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes a `(make-scratch-cell ...)` expression.  >   In single-pass mode, this marks the current function as an originator.


---
### DEFUN `ANALYZE-PROGN-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes a `(progn ...)` expression.


---
### DEFUN `ANALYZE-NESTED-DEF-FUNCTION`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes a nested `(def-function ...)` expression (e.g. from a template).


---
### DEFMACRO `TEMPLATE-INSTANTIATION`
- **Args**: `(&BODY BODY)`

  > Wrapper to allow nested def-functions during template instantiation.  >    At top-level, it expands to PROGN to allow evaluation.


---
### DEFUN `ANALYZE-TEMPLATE-INSTANTIATION`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes a `(template-instantiation ...)` form, allowing nested def-functions.


---
### DEFUN `ANALYZE-EVAL-WHEN`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes (eval-when ...) forms by ignoring them in the runtime IR.  >    Side effects (like struct registration) should have already occurred during macro expansion.


---
### DEFUN `ANALYZE-LET-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes a `(let ...)` expression.


---
### DEFUN `ANALYZE-RETURN-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes a `(return ...)` expression.


---
### DEFUN `ANALYZE-CAST-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes a to-XXXX or as-XXXX cast expression.


---
### DEFUN `GET-STRUCT-MEMBER-INDEX`
- **Args**: `(STRUCT-TYPE-NAME MEMBER-NAME)`

  > Helper to find the physical index of a struct member, accounting for padding.


---
### DEFUN `ANALYZE-SET!-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes a (set! target value) expression.


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

  > Finds the best matching function signature for the given operator and argument types.  >    Attempts template instantiation if no immediate match is found.


---
### DEFUN `ANALYZE-FUNCTION-CALL`
- **Args**: `(OP EXPR ENV LOCATION)`

  > Analyzes a call to a user-defined function.


---
### DEFUN `ANALYZE-FUNCALL-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes a (funcall f args...) form.


---
### DEFUN `ANALYZE-PARAMETERS`
- **Args**: `(PARAMS)`

  > Builds the environment (a symbol table).


---
### DEFUN `ANALYZE-STRUCT-CONSTRUCTION`
- **Args**: `(EXPR ENV LOCATION)`

  > Analyzes a (%construct-struct type-name arg1 arg2 ...) form.


---
### DEFUN `ANALYZE-BODY-EXPRESSIONS`
- **Args**: `(BODY-LIST ENV LOCATION)`

  > Recursively analyzes a list of expressions.


---
### DEFUN `ANALYZE-EXPRESSION`
- **Args**: `(EXPR ENV LOCATION)`

  > Recursively analyzes a *single* expression.


---
### DEFUN `SEMANTIC-NODE-TYPE`
- **Args**: `(NODE)`

---
### DEFUN `SEMANTIC-NODE-SOURCE-LOCATION`
- **Args**: `(NODE)`

---
### DEFUN `GET-SINGLE-VALUE-TYPE`
- **Args**: `(NODE)`

  > Returns the type of a semantic node, assuming a single-value context.  >   If the node's type is a list (e.g., from a multi-value function call),  >   this returns the first type in the list. Otherwise, it returns the type as-is.


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

  > Takes a single Crisp s-expression (like a def-function form),  >   compiles it, and returns its LLVM IR as a string.  >   This is a developer utility for REPL use and testing.


---
## File: `C:\Users\cperk\Documents\crisp\src\codegen.lisp`

### DEFUN `GET-OR-CREATE-DI-TYPE`
- **Args**: `(CRISP-TYPE DI-BUILDER DI-TYPE-CACHE)`

  > Gets a DIBasicType from a cache or creates it if it doesn't exist.


---
### DEFUN `GET-LLVM-RETURN-TYPE`
- **Args**: `(MODULE RETURN-TYPE-NAMES)`

  > Determines the LLVM return type from a list of Crisp type names.  >   Handles single values, void, and multiple values (by creating a struct).


---
### DEFUN `MANGLE-TYPE-SPEC`
- **Args**: `(TYPE-SPEC)`

  > Creates a string representation of a type spec for name mangling.


---
### DEFUN `CRISP-TYPE-TO-LLVM-TYPE`
- **Args**: `(TYPE-SPEC MODULE)`

  > Resolves a Crisp type specifier (simple or parameterized) to an LLVM type.


---
### DEFUN `GET-EXPANDED-TYPES`
- **Args**: `(TYPE-SPEC MODULE)`

  > Returns a list of LLVM types for a given Crisp type spec.  >    For 'cell', returns (ptr i64). For others, returns (type).


---
### DEFUN `EXPLODE-VALUE`
- **Args**: `(BUILDER AGG-VAL TYPE-SPEC)`

  > Extracts components from an aggregate value if necessary.  >    Returns a list of LLVM values.


---
### DEFUN `IMPLODE-VALUE`
- **Args**: `(BUILDER COMPONENTS TYPE-SPEC MODULE)`

  > Combines components into an aggregate value if necessary.  >    Returns a single LLVM value.


---
### DEFUN `CREATE-LLVM-FUNCTION-TYPE`
- **Args**: `(MODULE RETURN-TYPES PARAM-NODES)`

  > Calculates the LLVM function type, handling parameter explosion.


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
### DEFUN `BUILD-CAST-IF-NEEDED`
- **Args**: `(BUILDER FROM-VAL FROM-TYPE-NAME TO-TYPE-NAME)`

  > Builds an LLVM cast instruction if the types differ.


---
### DEFUN `GENERATE-COMPARISON-IR`
- **Args**: `(BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP NODE
              OP-NODE-INT OP-NODE-FLOAT)`

  > Helper to generate IR for comparison operators (<, >, =, etc).


---
### DEFMACRO `DEF-COMPARISON-CODEGEN`
- **Args**: `(TYPE-NAME INT-PRED FLOAT-PRED ACCESSOR-PREFIX)`

---
### DEFUN `TERMINATOR-P`
- **Args**: `(BLOCK)`

  > Checks if a basic block already has a terminator instruction.


---
## File: `C:\Users\cperk\Documents\crisp\src\templates.lisp`

### DEFSTRUCT `TEMPLATE-DATA`

  > Stores the definition of a template function.


---
### DEFUN `REGISTER-TEMPLATE`
- **Args**: `(NAME PARAMS CONSTRAINTS BODY SIGNATURE)`

  > Registers a new template definition.


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
- **Args**: `(NAME-OR-TMPL CONCRETE-TYPES)`

  > Generates the specialized code for a template.   >    name-or-tmpl can be a symbol (name) or a template-data struct.


---
### DEFUN `TRY-INFER-TEMPLATE-TYPES`
- **Args**: `(NAME ARGUMENT-TYPES)`

  > Attempts to infer template parameters for 'name' given 'argument-types'.  >    Returns a LIST OF LISTS of (template-data concrete-types).


---
### DEFUN `ENSURE-TEMPLATE-INSTANTIATION`
- **Args**: `(NAME EXPLICIT-ARG-TYPES COMPILER-CALLBACK)`

  > Called by the compiler to auto-instantiate templates.  >    compiler-callback is (lambda (form location) ...)


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

  > Parses command-line arguments and returns (values files output-file debug-p single-pass-p).


---
### DEFUN `COMPILE-FILES`
- **Args**: `(FILES OUTPUT-FILE DEBUG-P SINGLE-PASS-P)`

  > Compiles the given files.


---
### DEFUN `MAIN`

  > Main entry point for the crisp-compile executable.


---
