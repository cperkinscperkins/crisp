# Crisp Codebase Reference

Generated on 2026-07-17T20:58:00.831191Z

## File: `C:\Users\cperk\Documents\crisp-man\src\analysis\control.lisp`

### DEFUN `ENSURE-BRANCH-COMPATIBILITY`
- **Args**: `(THEN-NODE ELSE-NODE LOCATION)`

  > Unifies types of then/else branches. Returns (values unified-type new-then new-else).


---
### DEFUN `%EXTRACT-KEY-ARG`
- **Args**: `(KEY-ARGS KEYWORD DEFAULT)`

  > Parses a &key-style plist KEY-ARGS for KEYWORD, returning its value or  >    DEFAULT if absent.  Phase 1a helper for load-tile-at / store-tile-at  >    keyword parsing.


---
### DEFUN `%TLC-TRANSPOSE-PERMUTATION`
- **Args**: `(N TRANSPOSE-FORM LOCATION)`

  > Returns the coord permutation list implied by TRANSPOSE-FORM for a tile of  >    arity N.  Returns NIL for identity (no transpose).  Errors on invalid  >    combinations.  Phase 1a: only NIL and T are supported; explicit permutation  >    lists are deferred.


---
### DEFUN `%TLC-COOP-LOOP-SKELETON`
- **Args**: `(N TILE-SYM LOCAL-BINDINGS TILE-COORD-SYMS TILE-EXTENT-SYMS
              LID-SYMS LWS-SYMS INNER-FORM CL-PKG)`

  > Builds the cooperative N-dim workgroup-strided nest used by  >    load-tile-at and store-tile-at.  At each level:  >      (dotimes (K_k TE_k LWS_k)  >        (let ((tile-coord-k (+ K_k LID_k)))  >          (when (< tile-coord-k TE_k)  >            <inner>)))  >    Returns the nested form.  Local-bindings is the outer let's binding list  >    (passed through unchanged; caller adds tensor/extent/lid/lws bindings).  >    Tile-coord-syms / tile-extent-syms / lid-syms / lws-syms must be lists of  >    length n.


---
### DEFUN `%TLC-SOURCE-COORD-EXPRS`
- **Args**: `(N ORIGIN-SYMS TILE-COORD-SYMS PERM PLUS-SYM)`

  > Returns a list of N source-coord expressions: source-coord[k] = origin[k]  >    + tile-coord[perm[k]].  PERM is NIL for identity (no transpose) or a  >    permutation list of length N.


---
### DEFUN `%TLC-ALL-IN-BOUNDS-FORM`
- **Args**: `(N SRC-COORD-EXPRS GLOBAL-EXTENT-SYMS LT-SYM AND-SYM)`

  > Builds an AND of per-dim bounds checks: (and (< src-coord[k] ge[k]) ...).  >    For N=1, returns just the single comparison.


---
### DEFUN `%EXPAND-LOAD-TILE-AT-FORM`
- **Args**: `(EXPR LOCATION)`

  > Pure expansion of (load-tile-at SRC TILE (ORIGIN...) &key (identity 0) transpose).  >    Returns a let/dotimes/when nest that cooperatively loads the tile, ending  >    with (sync-workgroup).


---
### DEFUN `%EXPAND-ASYNC-LOAD-TILE-AT-FORM`
- **Args**: `(EXPR LOCATION)`

  > Async (cp.async) expansion of (load-tile-at SRC TILE (ORIGIN...) &key (identity 0)  >    transpose barrier).  Cooperative cp.async copy + commit_group; the matching await  >    emits wait_group(0).


---
### DEFUN `%EXPAND-STORE-TILE-AT-FORM`
- **Args**: `(EXPR LOCATION)`

  > Pure expansion of (store-tile-at TILE DEST (ORIGIN...) &key transformF transpose).  >    Returns a let/progn nest with (sync-workgroup) BEFORE and AFTER the  >    cooperative store loop.  TransformF is applied per-element (unary).


---
### DEFVAR `*IN-DIVERGENT-CONDITIONAL*`

  > T when the analyzer is currently inside a thread-divergent if/when/unless/cond  >    branch (i.e. the conditional's test was not constant-folded).  Used by the  >    load-tile-at / store-tile-at analyzers to reject placement that  >    would deadlock at their internal sync-workgroups.  >   >    Compiler-generated workgroup-uniform whens (e.g. the per-dim bounds check  >    that wraps tile-stride / hardware-stride :workgroup-idx bodies) use the  >    internal %uniform-when form instead, whose analyzer does NOT set this flag.


---
### DEFUN `ANALYZE-%UNIFORM-IF-IMPL`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Internal-use: structurally identical to analyze-if-expression-impl but  >    does NOT bind *in-divergent-conditional* on the two-branch path.  Use  >    only from compiler-generated forms whose conditions are guaranteed  >    workgroup-uniform.


---
### DEFUN `ANALYZE-%UNIFORM-WHEN-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Internal: like when, but workgroup-uniform — does not set  >    *in-divergent-conditional*.  Used by compiler-generated stride bounds-  >    checks; not exposed to user code.


---
### DEFUN `%TLC-CHECK-NOT-DIVERGENT`
- **Args**: `(OP-NAME LOCATION)`

  > Signals a clear compile error if (op-name) appears inside a thread-divergent  >    conditional.  Call from load-tile-at / store-tile-at analyzers.


---
### DEFUN `ANALYZE-LOAD-TILE-AT-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzer for (load-tile-at SRC TILE (ORIGIN...) &key (identity 0) transpose barrier).  >    Rejects placement inside a thread-divergent conditional. If :barrier is provided  >    and target is :ptx, emits semantic-nvvm-cp-async-tile-copy. Otherwise, delegates  >    codegen via %expand-load-tile-at-form.


---
### DEFUN `%ANALYZE-NVVM-TMA-LOAD-TILE-AT`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Endeavor 137 (Chapter 1.5, Phase 2) — analyze (load-tile-at SRC TILE (ORIGIN...) :barrier BAR)  >    for a NVIDIA :block barrier into a semantic-nvvm-tma-tile-copy.  Codegen emits one bulk  >    cp.async.bulk.tensor copy issued by an elected leader, tracked by BAR's mbarrier.  We build  >    the dest/source as aref-at-base forms so codegen can reuse the aref element-address machinery  >    for the SLM tile base (addrspace 3) and the source tensor base (addrspace 1, the STAND-IN  >    tensormap pointer).  The ORIGIN coords become the TMA {x,y} tile-box operands (element units).


---
### DEFUN `%EXPAND-SPIRV-ASYNC-LOAD-TILE-AT-FORM`
- **Args**: `(EXPR LOCATION)`

  > Endeavor 136 (Chapter 1, SPV) — async load-tile-at via OpGroupAsyncCopy.  >    Rank 1: one collective (%spirv-async-copy <tile[0]> <src[ORIGIN]> <tile-length> BAR)  >    of the whole contiguous run.  Rank 2 (M x N tile from a strided source): a runtime  >    (dotimes (r M) (%spirv-async-copy <tile[r,0]> <src[ORIGIN0+r,ORIGIN1]> N BAR)) — one  >    OpGroupAsyncCopy PER ROW, each copying N contiguous elements, its event chained  >    through the barrier's spirv.Event slot.  The matching await lowers to OpGroupWaitEvents.


---
### DEFUN `ANALYZE-%SPIRV-ASYNC-COPY-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzer for (%spirv-async-copy <dst-aref> <src-aref> <num> BARRIER) — one collective  >    OpGroupAsyncCopy.  dst/src are aref forms (codegen reuses their element-address 3rd  >    value); num is the element count; BARRIER carries the chained spirv.Event slot.


---
### DEFUN `ANALYZE-%CP-ASYNC-COPY-ELEM-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzer for (%cp-async-copy-elem <dst-aref> <src-aref>) — one non-blocking cp.async of a  >    single element, dst (SLM) <- src (global).  Both operands are aref forms; codegen grabs  >    each element's address (the aref's 3rd return value) and emits cp.async.ca.shared.global.


---
### DEFUN `ANALYZE-%CP-ASYNC-COMMIT-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzer for (%cp-async-commit) — emits cp.async.commit_group.


---
### DEFUN `ANALYZE-STORE-TILE-AT-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzer for (store-tile-at TILE DEST (ORIGIN...) &key transformF transpose).  >    Rejects placement inside a thread-divergent conditional, then delegates  >    codegen via %expand-store-tile-at-form.


---
### DEFUN `ANALYZE-AWAIT-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Emits semantic-nvvm-cp-async-wait on :ptx; no-op fallback elsewhere.


---
### DEFUN `ANALYZE-IF-EXPRESSION-IMPL`
- **Args**: `(EXPR ENV CONTEXT LOCATION &KEY ENFORCE-CONSTANT)`

---
### DEFUN `ANALYZE-IF-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

---
### DEFUN `ANALYZE-IF+-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Strictly checks that the condition is workgroup-uniform at compile time.  >    If unknown, prompts for a declare uniform.


---
### DEFUN `ANALYZE-STATIC-IF-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

---
### DEFUN `ANALYZE-WHEN-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

---
### DEFUN `ANALYZE-WHEN+-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

---
### DEFUN `ANALYZE-STATIC-WHEN-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

---
### DEFUN `ANALYZE-UNLESS-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

---
### DEFUN `ANALYZE-UNLESS+-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

---
### DEFUN `ANALYZE-STATIC-UNLESS-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

---
### DEFUN `%STRIP-EXECUTION-CONTEXT-DECLARES`
- **Args**: `(BODY-FORMS)`

  > Strips leading (declare ...) forms from BODY-FORMS.  >    Returns (values remaining-body all-decl-specs).  >    Uses string-equal matching so package of 'declare doesn't matter.


---
### DEFUN `%CHECK-CONTEXT-DECLARATIONS`
- **Args**: `(DECL-SPECS LOCATION)`

  > Checks DECL-SPECS for (grid-level) and (workgroup-level) declarations.  >    Enforces that:  >    - (grid-level) requires *in-dispatch-context* and cannot be nested.  >    - (workgroup-level) cannot be nested inside another workgroup-level context.  >    Returns (values has-grid-level has-workgroup-level).


---
### DEFVAR `*TO-UNIFORM-ALLOWED*`

  > T only while analyzing a let-binding initializer that is itself a direct  >    to-warp-uniform / to-workgroup-uniform form.


---
### DEFUN `%TO-UNIFORM-FORM-P`
- **Args**: `(FORM)`

  > T if FORM is a direct (to-warp-uniform ...) or (to-workgroup-uniform ...).


---
### DEFUN `ANALYZE-LET-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes a `(let ...)` expression.  >    Extended (091): strips leading declare forms from the body, checks for  >    (grid-level) and (workgroup-level) declarations, and enforces nesting rules.  >    Extended (120): propagates each binding's uniformity from its init.


---
### DEFUN `ANALYZE-PROGN-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes a `(progn ...)` expression.  >    Extended (091): strips leading declare forms, checks for  >    (grid-level) and (workgroup-level) declarations, and enforces nesting rules.


---
### DEFUN `ANALYZE-WITH-PRECISION-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Endeavor 126 (pass 5): analyzes (with-precision (KEY) body...), KEY = fast|ieee.  >    Produces a semantic-with-precision node carrying the region MODE + body nodes; its  >    codegen scopes *math-precision* over just the body (respecting the --force lock).  >    The region's value is the last body form's value (like progn). KEY may be written  >    parenthesised — (with-precision (ieee) ...) — or bare.


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

  > Analyzes (length~ arr).  >    For (array T N): returns compile-time constant N as ulong literal.  >    For tensor/vector/matrix types: dispatches to the runtime length~ accessor.  >    Signals crisp-compiler-error if argument is none of the above.


---
### DEFUN `ANALYZE-DOTIMES-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes (dotimes (var limit [stride]) body...).  >    VAR is bound as the limit's type (int, ulong, etc.) in the body.  >    STRIDE is optional; defaults to literal 1 of the limit's type.  >    Returns a semantic-dotimes node (type void).


---
### DEFUN `ANALYZE-DOTIMES+-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Strictly checks that the limit (and stride) are workgroup-uniform.


---
### DEFUN `ANALYZE-WHILE-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes (while condition body...).  >    Returns a semantic-while node (type void).


---
### DEFUN `ANALYZE-UNIFORMITY-STATE`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

---
### DEFUN `ANALYZE-PROVABLY-UNIFORM?`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

---
### DEFUN `ANALYZE-PROVABLY-DIVERGENT?`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

---
### DEFUN `ANALYZE-TO-WORKGROUP-UNIFORM`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

---
### DEFUN `ANALYZE-TO-WARP-UNIFORM`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

---
### DEFUN `%BUILD-EXACT-ITER-COUNT-FORM`
- **Args**: `(START-SYM STRIDE-SYM LEN-SYM CL-PKG)`

  > Returns an expression that computes the exact iteration count for a  >    grid-stride loop starting at START-SYM and stepping by STRIDE-SYM,  >    visiting only positions < LEN-SYM.  All three symbols name ULONG values.  >   >    Formula:  >      iters = (start >= len) ? 0  >                             : 1 + (len - 1 - start) / stride  >   >    The outer (>= start len) guard short-circuits the (len - 1 - start)  >    ulong underflow when start >= len or len = 0.


---
### DEFUN `%EXPAND-TENSOR-STRIDE-FORM`
- **Args**: `(EXPR CT LOCATION)`

  > Pure expansion of (tensor-stride T [LAYOUT-TAG] (BINDINGS...) BODY...).  >    CT must be :last or :first (already resolved by caller).  Returns the  >    expanded let+dotimes tree.  Validates form shape only — strict-tag vs  >    CT agreement and tensor-arity checks are the caller's job.  >   >    New shape: exact-iter-count + simple dotimes (no per-iter bounds check).


---
### DEFUN `%EXPAND-GRID-STRIDE-FORM`
- **Args**: `(EXPR LOCATION)`

  > Pure expansion of (grid-stride (SIZE-LIST) (BINDINGS) BODY...).  No type  >    info needed — grid-stride is always rightmost-binding-gets-warp.  >   >    New shape: exact-iter-count + simple dotimes (no per-iter bounds check).


---
### DEFUN `%EXPAND-LOOP-VECTOR-STRIDE-FORM`
- **Args**: `(EXPR LOCATION)`

  > Pure expansion of (loop-vector-stride VEC (VAR) BODY...).  >    Refactored to use %build-exact-iter-count-form for consistency with  >    the rest of Group A.  Same behaviour as the earlier rewrite — single  >    counter dotimes, body runs unconditionally.


---
### DEFUN `ANALYZE-LOOP-VECTOR-STRIDE-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes (loop-vector-stride VEC (VAR) BODY...).  Delegates to  >    %expand-loop-vector-stride-form.


---
### DEFUN `%TS-BUILD-DECODE-BINDINGS`
- **Args**: `(FLAT-SYM BINDING-SYMS STRIDE-SYMS CT)`

  > Builds the let* binding list that decodes FLAT-SYM into BINDING-SYMS using  >    STRIDE-SYMS (per-iteration-strides for each dim, length N or N-1) under  >    contiguous-term CT (:last or :first).  >   >    For CT :last:  i0 = flat/s0; rem1 = flat - i0*s0; i1 = rem1/s1; ...; i_{N-1} = rem_{N-1}  >    For CT :first: i_{N-1} = flat/s_{N-1}; rem1 = flat - i_{N-1}*s_{N-1}; ...; i_0 = rem_{N-1}


---
### DEFUN `%TS-BUILD-STRIDE-BINDINGS`
- **Args**: `(EXTENTS-SYMS CT)`

  > Returns a list of (stride-sym stride-form) bindings for the per-iteration  >    strides, in dim-index order (s_0 .. s_{N-2}).  For N=1, returns NIL.  >   >    For CT :last:  s_k = product(E_{k+1} .. E_{N-1})  >    For CT :first: s_k = product(E_0     .. E_{k-1})  but iteration uses these  >                   in reverse, so we build s_{N-1} .. s_1 instead.  >    Returned bindings have the same indexing convention as %ts-build-decode-bindings.


---
### DEFUN `%TS-CANONICALIZE-TENSOR-TYPE`
- **Args**: `(RAW-TYPE)`

  > Resolves RAW-TYPE down to the canonical 6-tuple (TENSOR elem N addr aln ct).  >    Mirrors %083-require-2d-tensor's normalisation but is arity-agnostic.  >    Returns the 6-tuple, or NIL when RAW-TYPE isn't a tensor.


---
### DEFUN `%TS-LAYOUT-TAG-TO-CT`
- **Args**: `(TAG N LOCATION)`

  > Maps a strict layout-tag to its effective contiguous-term (:last or :first).  >    Validates the tag and (for :row-major / :col-major) the 2D restriction.


---
### DEFUN `ANALYZE-TENSOR-STRIDE-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes (tensor-stride T [LAYOUT-TAG] (BINDINGS...) BODY...).  >    Delegates expansion to %expand-tensor-stride-form (shared with the AD  >    pre-pass).  Env-based CT resolution: pre-analyzes the tensor form to  >    read its static type.


---
### DEFUN `ANALYZE-GRID-STRIDE-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes (grid-stride (SIZE-LIST) (BINDINGS) BODY...).  Delegates to  >    %expand-grid-stride-form.


---
### DEFUN `%TILE-STRIDE-PARSE`
- **Args**: `(EXPR)`

  > Returns (values strict-p layout-tag tile-spec tile-spec-kind bindings body-forms tensor-form)  >    for a tile-stride EXPR.  TILE-SPEC-KIND is one of :size-list or :tile-tensor.  >    Form-shape validation only — does not check arity vs tensor.


---
### DEFUN `%EXPAND-HW-WORKGROUP-IDX-FORM`
- **Args**: `(TENSOR-FORM BINDINGS BODY-FORMS LOCATION)`

  > Outer-loop expansion for hardware-stride :workgroup-idx.  Phase 1b:  >    pre-walks the body to rewrite bare load-tile / store-tile into their  >    -coords forms using the bindings as the origin.


---
### DEFUN `%EXPAND-HW-WARP-IDX-FORM`
- **Args**: `(TENSOR-FORM BINDINGS BODY-FORMS LOCATION)`

  > Outer-loop expansion for hardware-stride :warp-idx.  Always 1D.  >    Bare load-tile / store-tile inside :warp-idx remain a compile error.  >   >    New shape: exact-iter-count + simple dotimes (no per-iter bounds check).  >    Loop start  = mywarp * ws         (warp-uniform within a warp)  >    Loop stride = ws * numwarps       (warp-uniform across the device)  >    Loop var    = start + k * stride.


---
### DEFUN `%EXPAND-TILE-STRIDE-FORM`
- **Args**: `(EXPR CT LOCATION)`

  > Pure expansion of (tile-stride T [LAYOUT-TAG] <TILE-SPEC> (BINDINGS) BODY...).  >    Outer loop over tile origins, workgroup-strided.  Phase 1b: pre-walks the  >    body to rewrite bare load-tile / store-tile into their -coords forms using  >    the tile-stride's binding syms as the origin.


---
### DEFUN `ANALYZE-TILE-STRIDE-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes (tile-stride T [LAYOUT-TAG] <TILE-SPEC> (BINDINGS) BODY...).  >    Validates tensor-arity-vs-bindings and tile-arity-vs-bindings, then  >    delegates codegen via %expand-tile-stride-form.


---
### DEFUN `%HARDWARE-STRIDE-PARSE`
- **Args**: `(EXPR)`

  > Returns (values strict-p layout-tag hw-tag bindings body-forms tensor-form)  >    for a hardware-stride EXPR.  Form-shape validation only — does not check  >    arity vs tensor.


---
### DEFUN `%EXPAND-WARP-IDX-FORM`
- **Args**: `(TENSOR-FORM BINDINGS BODY-FORMS LOCATION)`

  > Linear-flatten expansion for hardware-stride :warp-idx.  Always 1 binding.


---
### DEFUN `%EXPAND-WORKGROUP-STRIDED-OUTER-LOOP-WITH-TS-SYMS`
- **Args**: `(TENSOR-FORM N BINDINGS BODY-FORMS TS-SYMS TILE-SIZE-EXPR-FN
              LOCATION)`

  > Workgroup-strided outer loop over TILE-IDs.  Per-workgroup exact iter count per dim —  >    body runs unconditionally, with each binding bound to a tile-ID (0-based chunk index),  >    grid-strided by the number of workgroups.


---
### DEFUN `%EXPAND-HARDWARE-STRIDE-FORM`
- **Args**: `(EXPR CT LOCATION)`

  > Pure expansion of (hardware-stride T [LAYOUT-TAG] <HW-TAG> (BINDINGS) BODY...).  >   >    :workgroup-idx — N-dim outer loop with chunk-size = (get-local-size k)  >                     per dim.  Shares structure with tile-stride; body runs  >                     once per workgroup per chunk.  >    :warp-idx       — 1D outer loop with chunk-size = warp width (currently  >                      hardcoded to 32 as a placeholder for (get-warp-size)).  >                      Body runs once per warp per chunk.  Iteration is  >                      warp-strided over the flattened global execution space.


---
### DEFUN `ANALYZE-HARDWARE-STRIDE-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes (hardware-stride T [LAYOUT-TAG] <HW-TAG> (BINDINGS) BODY...).  >    Validates arity (:warp-idx must be 1 binding, :workgroup-idx must match  >    tensor arity) and delegates codegen via %expand-hardware-stride-form.


---
### DEFUN `%WORKGROUP-STRIDE-PARSE`
- **Args**: `(EXPR)`

  > Returns (values bindings body-forms tensor-form) for a workgroup-stride EXPR.  >    Form-shape validation only — does not check tensor arity vs bindings arity.


---
### DEFUN `%EXPAND-WORKGROUP-STRIDE-FORM`
- **Args**: `(EXPR LOCATION)`

  > Pure expansion of (workgroup-stride T (BINDINGS) BODY...).  N-dim nested  >    per-thread cooperative loop.  Each dim's iter count is computed up  >    front (per thread) so the inner dotimes is a single-counter, body-  >    unconditional loop the unroller can attack.


---
### DEFUN `ANALYZE-WORKGROUP-STRIDE-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes (workgroup-stride T (BINDINGS) BODY...).  Validates arity-vs-tensor  >    then delegates codegen via %expand-workgroup-stride-form.


---
### DEFUN `%EXPAND-LOAD-TILE-AT-BWD-FORM`
- **Args**: `(EXPR LOCATION)`

  > Pure expansion of (%load-tile-at-bwd SRC-ADJ TILE-ADJ (ORIGIN...) &key transpose).  >    Cooperative scatter-add via atomic-add!.


---
### DEFUN `%EXPAND-STORE-TILE-AT-BWD-FORM`
- **Args**: `(EXPR LOCATION)`

  > Pure expansion of (%store-tile-at-bwd TILE-ADJ DEST-ADJ (ORIGIN...) &key transpose).  >    Cooperative non-atomic accumulate into local tile_adj.  Barriers before  >    and after so prior tile_adj writes are visible and subsequent ones see  >    the result.


---
### DEFUN `ANALYZE-%LOAD-TILE-AT-BWD-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzer for compiler-internal %load-tile-at-bwd.


---
### DEFUN `ANALYZE-%STORE-TILE-AT-BWD-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzer for compiler-internal %store-tile-at-bwd.


---
### DEFUN `%REWRITE-BARE-TILE-IN-FORM`
- **Args**: `(FORM ORIGIN-BINDING-SYMS CL-PKG)`

---
### DEFUN `%REWRITE-BARE-LOAD-STORE-TILE-IN-BODY`
- **Args**: `(BODY-FORMS ORIGIN-BINDING-SYMS CL-PKG)`

---
### DEFUN `%DETECT-BARE-LOAD-STORE-TILE-IN-FORM`
- **Args**: `(FORM PATH)`

---
### DEFUN `ANALYZE-LOAD-TILE-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

---
### DEFUN `ANALYZE-STORE-TILE-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

---
### DEFUN `ANALYZE-LOAD-LOCAL-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzer for (load-local global-tensor scratch-tensor &key identity barrier).


---
### DEFUN `ANALYZE-STORE-GLOBAL-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzer for (store-global scratch-tensor global-tensor &key (transformF #'identityF) barrier).


---
### DEFUN `%PARSE-ASYNC-BARRIER-KEYS`
- **Args**: `(EXPR LOCATION)`

  > Parse (make-async-barrier &key mode) -> barrier-mode (Endeavor 137).  >    Omitted :mode is arch-automatic (resolved elsewhere; defaults to :linear here).  :type was  >    removed with def-topology.  Validates the mode and gates :block per backend/arch.


---
### DEFUN `ANALYZE-MAKE-ASYNC-BARRIER-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Endeavor 136/137: (make-async-barrier &key mode).  :linear is a PHANTOM barrier on PTX —  >    commit_group/wait_group need no object, so we codegen a constant 0; on SPV it owns a  >    target("spirv.Event") slot to chain OpGroupAsyncCopy events.  The node carries :mode so  >    load-tile/await pick the lowering (Endeavor 137 mode-threading).


---
### DEFUN `%CHECK-BARRIER-RING-ARRIVALS`
- **Args**: `(ARRIVALS BMODE LOCATION)`

  > Endeavor 138: validate :arrivals on a barrier ring.  Positive compile-time integer, and  >    REQUIRED for EVERY barrier ring — both modes need the per-stage transfer count:  >      :block  -> the mbarrier init ARRIVAL count.  >      :linear -> the loads-per-stage factor in the cp.async wait_group((ring-count-1)*arrivals).  >    (An earlier note said :linear ignored it; Endeavor 138's :linear ring pipelining needs it too,  >    and requiring it for both keeps an arch-automatic ring kernel portable — the same :arrivals  >    works whether the arch resolves to :block on sm_90 or :linear on sm_80.)  >   >    Why explicit and not inferred: for :block the count must be exact — a hardware mbarrier  >    completes only when BOTH its arrival count and its transaction bytes are met, so too high HANGS  >    the kernel and too low reads a half-arrived tile.  A single make-async-barrier can be inferred  >    (one stage in the text), but through a RING the prologue AND the main loop both load it, so the  >    textual tally (2 prologue + 2 loop = 4) is NOT the per-stage count (2).  Static 'per phase'  >    grouping is fragile and fails silently on the GPU, so we ask.


---
### DEFUN `ANALYZE-MAKE-ASYNC-BARRIER-RING-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Endeavor 138 (Chapter 2): (make-async-barrier-ring &key ring-count mode arrivals) -> a ring  >    of RING-COUNT async barriers for pipelining.  >   >    Unification: a plain (make-async-barrier) is simply a RING OF 1.  Both build the same  >    semantic-make-async-barrier node; this one just sets :ring-count N.  Codegen allocates  >    [N x i64] of SLM mbarriers and yields the BASE address as an i64 — so (ring-get r i) is  >    nothing but (base + i*8), which load-tile/await already inttoptr back to an mbarrier ptr.  >    That means the whole 137 barrier path is reused verbatim for every slot.  >   >    :ARRIVALS is how many transfers EACH SLOT tracks per pipeline stage.  It is REQUIRED for every  >    barrier ring (both modes) — the mbarrier arrival count on :block, the cp.async wait_group depth  >    factor on :linear — see %check-barrier-ring-arrivals for why it is explicit not scan-inferred.


---
### DEFUN `%BARRIER-RING-FORM-P`
- **Args**: `(FORM)`

  > T if FORM is (ring-get RING i) naming an async-barrier RING; returns the ring symbol.


---
### DEFUN `BARRIER-LOAD-COUNT-OF`
- **Args**: `(BARRIER-FORM)`

  > Endeavor 137138: the mbarrier arrival count for the barrier a load-tile/await refers to.  >    BARRIER-FORM is either the barrier variable SYMBOL, or — Endeavor 138 — a  >    (ring-get BARRIER-RING i) form, in which case the count is the RING's (every slot shares it:  >    each stage issues the same loads).  Defaults to 1.  >   >    For a single barrier this is the scan-counted tally of :block loads naming it; for a ring it is  >    the user's explicit :arrivals, recorded under the ring's binding by  >    analyze-make-async-barrier-ring-expression.  Both land in *async-barrier-load-count*, so  >    consumers need only resolve the ring and look up one table.  >   >    This MUST agree with the count the barrier was init'd with — await re-inits the mbarrier to  >    restart it at phase 0, and re-arming with the wrong count either hangs the kernel (too high)  >    or completes it on a half-arrived tile (too low).


---
### DEFUN `BARRIER-RING-COUNT-OF`
- **Args**: `(BARRIER-FORM)`

  > Endeavor 138: the RING DEPTH of the barrier a load-tile/await refers to (1 for a plain,  >    non-ring barrier).  BARRIER-FORM is either the barrier symbol or a (ring-get RING i) form;  >    resolves to the ring and looks up *async-barrier-ring-counts*.  Used to size the :linear  >    cp.async.wait_group idiom: keep (ring-count - 1) stages of groups in flight.


---
### DEFUN `ASYNC-BARRIER-MODE-OF`
- **Args**: `(BARRIER-FORM)`

  > Endeavor 137/138: resolved :mode (:linear/:block) of the barrier a load-tile/await refers to.  >    BARRIER-FORM is either the barrier variable SYMBOL, or — Endeavor 138 — a  >    (ring-get BARRIER-RING i) form, in which case the mode is the RING's (every slot shares it).  >    Defaults to :linear when unknown (bare/older barriers).


---
### DEFUN `ANALYZE-MAKE-C-HANDLE`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzer for (make-c-handle <held-ptr-type>).


---
### DEFUN `ANALYZE-GET-POINTER`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzer for (get-pointer <c-handle>) — loads the held pointer from the slot.


---
### DEFUN `ANALYZE-FILL-TILE-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > (fill-tile T V) for a scratch/SLM tile — workgroup-collective fill of every element of  >    the tensor T to V.  No barrier is inserted; the caller syncs before reading.  Register  >    tiles are handled earlier in the SROA explosion and never reach here.


---
### DEFUN `%MMTS-PARSE`
- **Args**: `(EXPR LOCATION)`

  > Validate + destructure a matrix-multiply-tile-stride form.  Returns  >    (values c-form c-tile k-form k-step grid-y grid-x grid-k body).


---
### DEFUN `%MMTS-SPLIT-EPILOGUE`
- **Args**: `(BODY)`

  > Endeavor 137: split a matrix-multiply-tile-stride body at the :epilogue marker into  >    (values reduction-body epilogue-body).  Forms before :epilogue run once per K-step  >    (the reduction); forms after run once per tile, post-reduction (grid-y/grid-x in scope,  >    C-tile complete) — that is where the user's store-tile (and any fusion) go.  No :epilogue  >    -> (values body nil).


---
### DEFUN `%FORM-TREE-MENTIONS-STORE-TILE-P`
- **Args**: `(FORMS)`

  > T if any form in the tree FORMS is a (store-tile ...) / (store-tile-at ...) call.


---
### DEFUN `%MMTS-LOWER`
- **Args**: `(C-FORM C-TILE TILE-SPEC K-FORM K-STEP GRID-Y GRID-X GRID-K BODY
              LOCATION)`

  > The tile-stride (over TILE-SPEC) + grid-k K/k-step reduction loop.  Endeavor 137: NO  >    auto-store — the body's :epilogue section (post-reduction, per tile) holds the explicit  >    store + any fusion.  Warns if the C-tile is never stored.


---
### DEFUN `ANALYZE-MATRIX-MULTIPLY-TILE-STRIDE-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Scratch-tensor path for (matrix-multiply-tile-stride C C-tile K <k-step> (gy gx gk) BODY...).  >    Lowers with the tile-tensor C-tile (tile-stride reads its extents~).  Register-tile C-tiles  >    are pre-lowered in analyze-let-with-tile-explosion, before SROA explosion, so never reach here.


---
### DEFUN `REGISTER-CONTROL-ANALYZERS`

  > Registers all control flow expression analyzers, including loop-vector-stride,  >    tensor-stride, grid-stride, tile-stride, hardware-stride, workgroup-stride,  >    and (111 Phase 1a) load-tile-at / store-tile-at.  >    Endeavor 113: also registers request-load-tile-at and await-request.


---
## File: `C:\Users\cperk\Documents\crisp-man\src\analysis\core.lisp`

### DEFVAR `*ANALYSIS-ACCESS-MODE*`

---
### DEFVAR `*IN-DISPATCH-CONTEXT*`

  > T when the analyzer is inside a def-kernel/def-grid-function body.  >    Used to restrict GPU built-in calls to kernel entry points only.


---
### DEFVAR `*IN-GRID-LEVEL-CONTEXT*`

  > T when the analyzer is currently inside a (declare (grid-level)) let/progn scope.  >    Grid-level contexts cannot be nested inside each other.


---
### DEFVAR `*IN-WORKGROUP-LEVEL-CONTEXT*`

  > T when the analyzer is currently inside a (declare (workgroup-level)) let/progn scope.  >    Workgroup-level contexts cannot be nested inside each other.


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

  > Analyzes (crisp-vec-literal e1 e2 ...) -- produced by the ##(...) reader macro.  >    Infers the component type from the first element, validates width (2-4) and  >    element type compatibility, then returns a semantic-device-vec-literal node.


---
### DEFUN `REGISTER-WARP-BUILTINS`

  > Registers the warp-id / warp-lane / warp-count GPU builtins in  >    *expression-analyzers* for both :crisp-language and :crisp.compiler.


---
### DEFUN `%GPU-BUILTIN-INFO`
- **Args**: `(BUILTIN-KW)`

  > Returns (base-return-type accepts-dim-p) for a GPU builtin keyword.  >    BASE-RETURN-TYPE: return type when called with no args (nil = void).  >    ACCEPTS-DIM-P: T if the builtin accepts a scalar dimension arg 0/1/2.


---
### DEFUN `%ANALYZE-GPU-BUILTIN`
- **Args**: `(BUILTIN-KW NAME-STR EXPR ENV CONTEXT LOCATION)`

  > Analyzer for all GPU built-in function forms.


---
### DEFVAR `*VOLATILE-VAR-READS*`

  > Set of semantic-var-read nodes whose load should be emitted as volatile.  >    Weak-keyed so entries vanish when the kernel's AST is GC'd.


---
### DEFUN `ANALYZE-%VOLATILE-READ-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes (%volatile-read SYM): produces the same semantic node as a plain  >    var-read for SYM, but tags the node in *volatile-var-reads* so codegen  >    emits the load as volatile.  IGC SROA-aliasing workaround.


---
### DEFUN `INITIALIZE-EXPRESSION-ANALYZERS`

  > Registers all expression analyzers; extended for 087-gpu-builtins.  >    Endeavor 103 phase B: adds %volatile-read for the IGC workaround.


---
### DEFVAR `*IMPLICIT-ARG-MAP*`

  > Map of function-name -> list of implicit argument requirements.


---
### DEFVAR `*ASYNC-BARRIER-MODES*`

  > Endeavor 137: map of async-barrier binding SYMBOL -> resolved :mode (:linear/:block).  >          make-async-barrier records its let-binding name here (via  >          compiler-context-current-binding-name); load-tile/await look the barrier variable  >          up to pick the lowering (cp.async/OpGroupAsyncCopy vs TMA/LSC 2D block). Rebound  >          per module for clean state.


---
### DEFVAR `*SCRATCH-CELL-COUNTER*`

  > Monotonic counter for disambiguating scratch cells.  >          Used TWICE per module:  >          1. During Analysis Scan (Pass 1) to generate Implicit Arguments.  >          2. During Codegen (Pass 2) to generate LLVM IR.  >          MUST BE RESET TO 0 BETWEEN PASSES.


---
### DEFVAR `*ASYNC-BARRIER-RING-COUNTS*`

  > Endeavor 138: map of async-barrier-RING binding SYMBOL -> :ring-count.  Presence in this  >          table is also what marks a binding as a BARRIER ring (vs a scratch tile ring), so  >          ring-get can dispatch: a barrier slot is address arithmetic (base + i*8), a tile slot is  >          an offset view.  Rebound per module.


---
### DEFVAR `*ASYNC-BARRIER-LOAD-COUNT*`

  > Endeavor 137 Phase 2d: scan-time map of async-barrier binding SYMBOL -> count of :block  >          load-tiles that reference it.  Becomes the mbarrier init arrival count (each TMA load  >          issues one mbarrier.arrive.expect_tx).  Rebound per module.


---
### DEFVAR `*SCRATCH-TILE-DIMS*`

  > Endeavor 137: scan-time map of (fn . scratch-tile-binding-SYMBOL) -> plist  >          (:element-type E :box-dims (D...) :rank N).  Populated when scanning a  >          make-scratch-{vector,matrix,tensor} binding; consulted when a :block load-tile mints  >          a CUtensorMap descriptor to record the tile-box shape.  Rebound per module.


---
### DEFVAR `*TMA-DESCRIPTOR-INFO*`

  > Endeavor 137: map of CUtensorMap descriptor implicit-arg unique-NAME -> plist  >          (:originator F0 :describes-sym SRC :tile-sym TILE).  Populated at scan when a :block  >          load-tile mints a descriptor.  These are ORIGINATOR-frame symbols; resolve-tma-descriptors  >          walks the carrier chain to turn them into concrete kernel-frame values in *tma-resolved*.  >          PERSISTENT (cleared via clrhash in the compiler reset) — survives to metadata emit.


---
### DEFVAR `*CALL-SITE-ARGS*`

  > Endeavor 137: scan-time map fn-name -> list of (callee-name . explicit-arg-list) for the  >          user-function calls in fn's body.  Used to resolve a descriptor's describes/tile refs  >          down the carrier call chain (args are threaded positionally at each hop).  Rebound per  >          module (only consulted during resolution, which runs inside compile-module).


---
### DEFVAR `*TMA-RESOLVED*`

  > Endeavor 137: map (kernel-name . descriptor-uname) -> plist (:describes NAME  >          :element-type E :rank N :box-dims (D...)), resolved through the carrier chain by  >          resolve-tma-descriptors; read by generate-implicit-signature.  PERSISTENT (cleared via  >          clrhash in the compiler reset) — metadata emit runs after compile-module returns.


---
### DEFUN `COMPILE-MODULE`
- **Args**: `(FORMS MODULE BUILDER DI-BUILDER DI-COMPILE-UNIT LOCATION-MAP)`

  > Orchestrates the multi-pass compilation of a list of top-level forms.  >    When --differentiate is enabled, pre-injects shadow def-struct forms for  >    AD support before any of the passes see the forms list.


---
### DEFUN `PROPAGATE-IMPLICIT-ARGUMENTS`

  > Phase 4: Traverses the call graph backwards from originators to find all carriers.


---
### DEFUN `%FN-EXPLICIT-PARAMS`
- **Args**: `(FN-NAME)`

  > The LOGICAL explicit parameter symbols of FN-NAME, &out removed.  For a kernel we use the  >    declared signature — its *fn-normalized-info* :params are the EXPLODED physical ABI (a_ptr,  >    a_byte_size, ...) after def-kernel expansion, not the logical tensors.  Sub-functions keep  >    their logical params in *fn-normalized-info*.


---
### DEFUN `%FN-IS-KERNEL-P`
- **Args**: `(FN-NAME)`

  > T if FN-NAME is a kernel entry point.


---
### DEFUN `%KERNEL-PARAM-CONTIGUOUS-TERM`
- **Args**: `(KERNEL SYM)`

  > The :contiguous-term (:row-major / :col-major) of KERNEL's tensor param SYM, from its  >    declared type (resolving a type alias).  The CUtensorMap encode is layout-dependent.  >    Defaults to :row-major.


---
### DEFUN `%FN-CARRIES-DESCRIPTOR-P`
- **Args**: `(FN-NAME UNAME)`

  > T if FN-NAME carries the descriptor implicit UNAME (in its *implicit-arg-map* entry).


---
### DEFUN `%TMA-DOWNSTREAM-CARRIER`
- **Args**: `(FN UNAME)`

  > The callee FN calls that carries descriptor UNAME, plus the explicit args of that call.  >    Returns (values callee-name arg-list) or NIL.


---
### DEFUN `%TMA-CLASSIFY`
- **Args**: `(FN SYM KIND)`

  > Classify SYM in FN's frame for KIND (:describes / :tile).  Returns a concrete  >    (:tensor SYM) / (:tile DIMS ELEM RANK), or (:param SYM) to continue up the chain, or NIL.


---
### DEFUN `%TMA-RESOLVE-REF`
- **Args**: `(FN UNAME KIND &OPTIONAL VISITED)`

  > Resolve descriptor UNAME's KIND reference in FN's frame by substituting through the carrier  >    chain.  Returns concrete (:tensor SYM) / (:tile DIMS ELEM RANK), (:param SYM), or NIL.


---
### DEFUN `RESOLVE-TMA-DESCRIPTORS`

  > Endeavor 137 Phase 2c: for every kernel carrying a CUtensorMap descriptor, resolve its  >    describes tensor + tile box-dims through the carrier call chain into *tma-resolved*.  >    Element-type / rank come from the resolved tile (they match the source).  Subsumes the 2b  >    same-function case as a zero-hop resolution (originator == kernel).


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
### DEFUN `%RESOLVE-ASYNC-BARRIER-MODE-SCAN`
- **Args**: `(ARGS)`

  > Scan-pass resolution of a (make-async-barrier &key mode) form's :mode WITHOUT the Pass-2  >    gating/validation.  Explicit :mode wins; otherwise arch-automatic — :block on a TMA-capable  >    NVIDIA arch (sm_90+), else :linear.  Used to decide at scan time whether a :block load-tile  >    needs a CUtensorMap descriptor implicit arg (Endeavor 137 Phase 2b).


---
### DEFUN `%SCAN-REGISTER-TMA-DESCRIPTOR`
- **Args**: `(ARGS)`

  > Endeavor 137 Phase 2b: when a (load-tile[-at] SRC TILE COORDS ... :barrier BAR) references a  >    :block barrier on PTX, register a CUtensorMap descriptor implicit arg for SRC in the current  >    scanning function, deduped per SRC name, and mark the fn a side-channel originator.  The  >    descriptor's canonical spec is (tensor-map SRC) — one physical slot (option A = a pointer);  >    its element-type / rank / box-dims are resolved later (metadata + hoist) from SRC's declared  >    type and the staging tile, so scan only needs SRC + the barrier's resolved mode.


---
### DEFUN `SHALLOW-ANALYZE-BODY`
- **Args**: `(FORMS)`

  > Performs a shallow, recursive walk of a function's body.  >   Returns two values:  >   1. A boolean indicating if a side-channel originator was found.  >   2. A list of all unique symbols found in the 'car' of lists (potential function calls).


---
### DEFUN `%PROCESS-DECLAIM`
- **Args**: `(FORM)`

  > Endeavor 126: handle (declaim (precision KEY)) — the first (and currently only)  >    supported declaim: a file-level precision selection. Sets *math-precision* to  >    :fast/:ieee for the rest of the compilation, UNLESS --force-math-precision is  >    active (force locks precision; declaim is then ignored). Runs in both the analysis  >    and codegen passes — each processes the declaim before the functions, so  >    *math-precision* is correct when FP ops are emitted. Unknown declaim clauses are  >    ignored (forward-compatible); an unknown precision key is an error.


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

  > Pass 1: Pre-register differentiable functions, then iterate through forms  > to find and register all function signatures and build the call graph.  > Pre-registration ensures *differentiable-functions* is populated before  > def-kernel macros expand and call generate-backward-walk (feature 052).  > Also scans *template-registry* for HOF templates after walk-code-forms.  >   > Endeavor 120: also captures each function's macro-expanded params/body and  > runs infer-param-uniformity once the call graph is complete.


---
### DEFUN `%UNI-PARAM-NAMES`
- **Args**: `(PARAMS)`

  > Extract ordered parameter names from a def-function parameter list,  >    handling both plain symbols and (name type ...) interleaved specs.


---
### DEFUN `%UNI-COMBINE`
- **Args**: `(STATES)`

  > Taint-max over a list of uniformity STATES. :divergent dominates, then  >    :unknown, otherwise :uniform. (Empty list -> :uniform.)


---
### DEFUN `%UNI-BUILTIN-STATE`
- **Args**: `(OP)`

  > Return :uniform or :divergent if OP is a recognized GPU builtin operator,  >    else NIL. Matched by symbol-name so it is package-agnostic.


---
### DEFUN `%UNI-CONTRIBUTE`
- **Args**: `(CALLEE PARAM-NAME STATE)`

  > Meet STATE into *uni-meet-table*[CALLEE][PARAM-NAME].


---
### DEFUN `%UNI-ANALYZE-LET`
- **Args**: `(FORM ENV)`

  > Uniformity walk of a (let (bindings...) body...) form. Crisp let is  >    let*-like, so bindings extend ENV sequentially. Multi-value bindings bind  >    each var to :unknown (conservative). Returns the state of the last body  >    form.


---
### DEFUN `%UNI-ANALYZE`
- **Args**: `(FORM ENV)`

  > Lightweight uniformity walk of a raw body FORM under ENV (an alist  >    name -> state). Returns FORM's uniformity state; as a side effect,  >    contributes call-site argument states to *uni-meet-table* for every call  >    to a known user function (see infer-param-uniformity).


---
### DEFUN `%UNI-TOPO-ORDER`
- **Args**: `(NODES)`

  > Topological order of NODES (function-name symbols) by *call-graph* edges  >    caller->callee, callers first. Recursion is banned so this is a DAG; any  >    leftover (cyclic) nodes are appended at the end.


---
### DEFUN `INFER-PARAM-UNIFORMITY`

  > Endeavor 120 (Option 1): conservative interprocedural uniformity inference.  >    Seeds kernel (entry-point) parameters as :uniform, then propagates argument  >    uniformity down the call graph (callers processed before callees). A  >    function parameter is inferred :uniform only when EVERY observed call site  >    passes a provably-uniform argument. Results are stored in  >    *inferred-param-uniformity* and applied (upgrade-only) to the  >    body-compilation environment by inject-implicit-arguments.  >   >    Generic/template functions are skipped: their call sites can be created  >    lazily during Pass 2, so the pre-pass cannot see all of them, and an  >    incorrectly-inferred :uniform would be unsafe.


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
### DEFVAR `*DIVERGENT-SCOPE-DEPTH*`

  > Tracks the depth of nested divergent control flow constructs (if, when, etc.  >    with divergent conditions) during semantic analysis.


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

  > Wrapper around internal-compile-function. Detects kernel entry-points and  >    binds *boundary-struct-params*, *boundary-array-params*, and  >    *in-dispatch-context* to enforce kernel-boundary rules.  >    Extended to capture global-size/local-size/num-groups dispatch declarations.  >    Extended (091) to handle (grid-function) declaration: sets dispatch context,  >    validates void return type.  >    Note: ANF pre-processing removed from forward pass — backward pass applies  >    its own anf-transform in %generate-backward-function-ast.


---
### DEFUN `CALCULATE-UNIFORMITY-STATE`
- **Args**: `(NODE ENV)`

  > Recursively determines the uniformity state of an analyzed semantic AST node.  >    Returns :uniform, :divergent, or :unknown.  >    - Literals are :uniform.  >    - Variables are looked up in the env for their stored uniformity. If env lookup  >      fails or missing, defaults to :unknown. Kernel arguments are initialized to :uniform.  >    - GPU Builtins: per-work-item ids (get-global-id/get-local-id/*-linear-id/  >      get-global-id-abs) are :divergent; ids/sizes/offsets constant across the  >      workgroup (get-workgroup-id, get-num-groups, get-*-work-size, get-global-offset,  >      get-work-dim, get-*-linear-size, get-total-*) are :uniform.  >    - Math operations (add, sub, mul, etc): if all args are :uniform, it is :uniform.  >      If any arg is :divergent, it is :divergent. Otherwise :unknown.  >    - Casts/conversions (to-*, as-*) are passthrough: same uniformity as the operand.  >    - Memory reads (aref) are :divergent (or :unknown) unless explicitly cast.


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

  > Analyzes a function call expression.  >    Checks for struct immutability violations via %check-struct-mutating-call.  >    Extended (091): grid functions can only be called from a dispatch context.


---
### DEFUN `SEMANTIC-NODE-TYPE`
- **Args**: `(NODE)`

  > Returns the Crisp type of a semantic node.  >    Extended for 092-dotimes and 114 Phase B (semantic-nvvm-cp-async-*).


---
### DEFUN `SEMANTIC-NODE-SOURCE-LOCATION`
- **Args**: `(NODE)`

  > Returns the source location of a semantic node.  >    Extended for 092-dotimes and 114 Phase B.


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
### DEFUN `%EXTRACT-FN-BODY-AND-DECLARATIONS`
- **Args**: `(BODY-AND-LOC)`

  > Helper: Splits the body-and-loc of a function into declare-forms, flat declarations, and the actual fn-body.


---
### DEFUN `%DETECT-HOF-PARAM-VIA-FUNCALL`
- **Args**: `(PARAMS FN-BODY)`

  > Helper: Scans parameters for one that is funcall'd in the body.  >    Returns (values fn-param-idx fn-param-sym float-param-syms).


---
### DEFUN `%REGISTER-HOF-ENTRY`
- **Args**: `(NAME TYPE-DESC PARAMS FN-PARAM-IDX FN-PARAM-SYM FLOAT-PARAM-SYMS
              CLEAN-BODY N-FLOAT-PARAMS N-RETURN)`

  > Helper: Registers a HOF in *differentiable-hof-store* and *differentiable-functions*.


---
### DEFUN `%REGISTER-STANDARD-DIFFERENTIABLE-ENTRY`
- **Args**: `(NAME TYPE-DESC N-FLOAT-PARAMS N-RETURN &KEY OPTIMISTIC-P)`

  > Helper: Registers a non-HOF function in *differentiable-functions*.


---
### DEFUN `%PRE-REGISTER-DIFFERENTIABLE-FNS`
- **Args**: `(FORMS &OPTIONAL RECORD-INFO)`

  > When *differentiate-p* is T, walk FORMS for def-function forms and  > pre-register them in *differentiable-functions* (and *differentiable-hof-store*  > for HOF functions). Handles top-level def-function, progn, and with-template-type.  > Guards parse-function-declarations against unknown-type errors from brand types  > that are not yet registered at pre-registration time.  >   > 101 widening: records / structs / derived-from-record-or-struct contribute  > their runtime-field count to the differentiable-param count, and a function  > with any tensor or cell parameter is differentiable (handle-grad pathway).  >   > RECORD-INFO is an alist of (NAME-STR . FIELD-COUNT) built by  > %scan-forms-for-record-info at top-level call.  Recursive calls reuse it.


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

  > Analyzes (x~ v), (y~ v), (z~ v), (w~ v) -- device-vector component accessors.  >    The operator symbol determines the 0-based LLVM element index (0..3).  >    Returns a semantic-extract-value node whose type is the scalar component type.  >   >    Brand-instance gensyms (e.g. VALUE-T-204 derived from float2) are resolved  >    to their concrete device-vector base type via *type-derivation-graph* before  >    width and component-scalar extraction.  >   >    In :write mode (inside a set! target), also validates that a cell-deref  >    aggregate is not read-only.


---
### DEFUN `%MV-RESOLVE-SRC-TYPE`
- **Args**: `(SRC-TYPE)`

  > Resolve a source storage-handle type to a canonical list.  >    Handles type aliases, mangled symbols (e.g. TENSOR_INT_1_...),  >    (vector ...) / (matrix ...) sugar, and already-canonical lists.  >    Returns (CELL elem addr access) or (TENSOR elem N addr access align), or NIL.


---
## File: `C:\Users\cperk\Documents\crisp-man\src\analysis\ops.lisp`

### DEFMACRO `DEF-BINARY-OP-ANALYZER`
- **Args**: `(NAME NODE-CONSTRUCTOR OP-STRING)`

---
### DEFMACRO `DEF-UNARY-MATH-ANALYZER`
- **Args**: `(NAME NODE-CONSTRUCTOR OP-STRING)`

---
### DEFMACRO `DEF-BINARY-MATH-ANALYZER`
- **Args**: `(NAME NODE-CONSTRUCTOR OP-STRING)`

  > Endeavor 128: analyzer for a binary FP math intrinsic (pow, atan2). Both args  >    must be float; the result type is the (promoted) argument type.


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
### DEFUN `%ANALYZE-ATOMIC-RMW-EXPRESSION`
- **Args**: `(OP EXPR ENV CONTEXT LOCATION &KEY NO-DELTA)`

  > Shared helper for all atomic RMW analyzers.  > OP is a keyword (:add :sub :min :max :xchg).  > Target (second element of EXPR) must be an aref expression like (~ vec idx).  > When NO-DELTA is T (for atomic-inc!/atomic-dec!), synthesizes a literal-1 delta.  >   > Target analysis runs with *analysis-access-mode* = :write so &out params can  > serve as atomic-RMW targets — the read is part of the write.  Matches the  > set!  analyzer's behavior in analysis/structs.lisp.


---
### DEFUN `ANALYZE-ATOMIC-ADD!-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes (atomic-add! target delta) — atomic fetch-and-add.


---
### DEFUN `ANALYZE-ATOMIC-SUB!-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes (atomic-sub! target delta) — atomic fetch-and-subtract.


---
### DEFUN `ANALYZE-ATOMIC-INC!-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes (atomic-inc! target) — atomic increment by 1.


---
### DEFUN `ANALYZE-ATOMIC-DEC!-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes (atomic-dec! target) — atomic decrement by 1.


---
### DEFUN `ANALYZE-ATOMIC-MIN!-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes (atomic-min! target val) — atomic fetch-and-min.


---
### DEFUN `ANALYZE-ATOMIC-MAX!-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes (atomic-max! target val) — atomic fetch-and-max.


---
### DEFUN `ANALYZE-ATOMIC-XCHG!-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes (atomic-xchg! target new-val) — atomic exchange.


---
### DEFUN `ANALYZE-ATOMIC-SET!-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes (atomic-set! target new-val) — alias for atomic-xchg!.


---
### DEFUN `ANALYZE-MOD-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes (mod x y).  Expands to (- x (* (/ x y) y)) with x and y bound  >    to gensyms first, then delegates to analyze-expression.  Works for any  >    numeric type via the standard +/-/*/ analyzers.


---
### DEFUN `ANALYZE-REM-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes (rem x y).  Currently identical to mod — both match C % / LLVM  >    srem.  Split semantics later if needed.


---
### DEFUN `REGISTER-OPS-ANALYZERS`

  > Registers all expression analyzer functions.  > Redefined for 082-atomics to add atomic RMW op analyzers.  > Endeavor 109: adds mod / rem under both :crisp-language and :crisp.compiler.


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

  > Extracts the :align keyword from a tensor type specifier.  >    New 6-tuple (tensor elem N addr aln ct): align at position 4 = (fifth type).  >    Handles both list form and mangled symbol.


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
### DEFUN `%ANALYZE-SET!-SIMPLE-VARIABLE`
- **Args**: `(TARGET-FORM VALUE-NODE ENV LOCATION)`

  > Helper to analyze simple variable assignment (set! target-form value-node).  >    Endeavor 120 (gap #5): taints the variable :divergent when mutated inside a  >    divergent block, or when assigned a divergent value.


---
### DEFUN `%ANALYZE-SET!-STRUCT-ACCESSOR`
- **Args**: `(OP ARG-NODES VALUE-NODE ENV CONTEXT LOCATION TARGET-FORM)`

  > Helper to handle struct accessor logic for set!


---
### DEFUN `%ANALYZE-SET!-CALL-ACCESSOR`
- **Args**: `(TARGET-FORM VALUE-NODE ENV CONTEXT LOCATION)`

  > Helper to analyze set! when target is a function call or struct accessor.


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
### DEFUN `ANALYZE-GLOBAL-SCRATCH-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes a (%make-global-scratch-cell <type>) expression.  >  This marks the current function as an originator in BOTH analysis modes.


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

  > Resolves type arguments of a make-scratch-{vector,matrix,tensor} form  >    to a canonical (tensor elem N addr align ct) spec.


---
### DEFUN `%REGISTER-SCRATCH-TENSOR-IMPLICIT`
- **Args**: `(OP ARGS)`

  > Shared logic for scan-operator methods on make-scratch-{vector,matrix,tensor}.  >    Marks the current function as an originator and records the canonical-list type  >    in *implicit-arg-map* and the size-expr in *implicit-scratch-size-expr-map*.


---
### DEFUN `ANALYZE-SCRATCH-TENSOR-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes a (make-scratch-{vector,matrix,tensor} ...) expression.  >    Stores canonical-list type in *implicit-arg-map* and size-expr in  >    *implicit-scratch-size-expr-map*.


---
### DEFUN `%MV-SOURCE-HEAD`
- **Args**: `(CANON)`

  > Return the head keyword (:cell or :tensor) from a canonical type, or NIL.


---
### DEFUN `%MV-SOURCE-ELEM`
- **Args**: `(CANON)`

  > Return the element-type symbol from a canonical storage handle type.


---
### DEFUN `%MV-SOURCE-ADDR`
- **Args**: `(CANON)`

  > Return the address-space keyword from a canonical storage handle type.


---
### DEFUN `%MV-SOURCE-ACCESS`
- **Args**: `(CANON)`

  > Return the access keyword from a canonical storage handle type.


---
### DEFUN `%MV-SOURCE-ALIGN`
- **Args**: `(CANON)`

  > Return the :align keyword from a canonical storage handle type (tensors only).  >    New 6-tuple (tensor elem N addr aln ct): align at position 4 = (fifth canon).


---
### DEFUN `%MV-IS-STRUCT-ELEM`
- **Args**: `(ELEM-TYPE)`

  > Returns T if ELEM-TYPE is a registered def-struct type.


---
### DEFUN `%MV-PARSE-KWARGS`
- **Args**: `(KWARG-LIST)`

  > Parse a flat keyword-arg list like (:offset 2 :length 5 :major :row).  >    Returns a plist.


---
### DEFUN `%MV-EVAL-INTEGER`
- **Args**: `(FORM)`

  > Evaluate a compile-time integer form (bare integer or quoted integer).  >    Returns an integer or NIL.


---
### DEFUN `%MV-EVAL-LIST`
- **Args**: `(FORM)`

  > Evaluate a compile-time list form like '(2 3 4) or (2 3 4) for extents/strides.  >    Returns a list of integers or NIL.


---
### DEFUN `%MV-CHECK-RESTRICTIONS`
- **Args**: `(OP SRC-CANON NEW-ELEM LOCATION)`

  > Enforce compile-time restrictions for view constructors.  >    Signals a compiler-error on violation.


---
### DEFUN `%MV-RESULT-ALIGN`
- **Args**: `(SRC-ALIGN EXPLICIT-STRIDES-P COL-MAJOR-P)`

  > Determine result alignment given source alignment and constructor options.


---
### DEFUN `%MV-RESULT-CELL-TYPE`
- **Args**: `(NEW-ELEM ADDR)`

  > Build canonical cell result type: (cell elem addr).


---
### DEFUN `%MV-RESULT-TENSOR-TYPE`
- **Args**: `(NEW-ELEM RANK ADDR ALIGN &OPTIONAL (CT LAST))`

  > Build canonical tensor result type: (tensor elem rank addr align ct).


---
### DEFUN `%MV-ROW-MAJOR-STRIDES`
- **Args**: `(EXTENTS)`

  > Compute row-major strides for given extents list.  >    Innermost stride = 1; stride[k] = product(extents[k+1..N-1]).


---
### DEFUN `%MV-COL-MAJOR-STRIDES`
- **Args**: `(EXTENTS)`

  > Compute col-major strides for a 2D matrix with extents [height width].  >    stride_row=1, stride_col=height.


---
### DEFUN `ANALYZE-RING-GET-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Endeavor 138 (Chapter 2): (ring-get RING INDEX) -> slot INDEX of RING.  >   >    A ring is ONE rank-(1+N) scratch tensor whose dim 0 IS the ring slot (see the  >    make-scratch-*-ring macros), so slot i is simply the ring VIEWED as a rank-N handle bumped by  >    i * slot-elems.  That means ring-get is a make-view with a RUNTIME offset — no new codegen,  >    and it reuses the view machinery wholesale.  >   >    INDEX may be runtime (the pipelining main loop uses (mod (+ idx 1) stages)); it rides  >    semantic-make-view's OFFSET-NODE.  The ring's compile-time dims come from the scan-time  >    scratch table keyed (fn . binding) — the same table Endeavor 137 added for TMA box-dims.


---
### DEFUN `%ANALYZE-TILE-RING-GET`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > The storage-handle (tile) ring case of ring-get — slot i as an offset view.


---
### DEFUN `ANALYZE-MAKE-VIEW-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes make-cell / make-vector / make-matrix / make-tensor.


---
### DEFUN `REGISTER-STRUCT-ANALYZERS`

  > Registers all struct/storage-handle expression analyzers.  >    Extends the original to add make-cell/vector/matrix/tensor view constructors.


---
### DEFUN `%083-REQUIRE-2D-TENSOR`
- **Args**: `(RAW-TYPE LOCATION)`

  > Validates that RAW-TYPE is a 2D tensor and returns the canonical 6-tuple list.  >    Unwraps single-element list wrappers and mangled symbols.  >    Signals crisp-compiler-error if the type is not a 2D tensor.


---
### DEFUN `%GET-TENSOR-CT`
- **Args**: `(CANON)`

  > Extracts the :contiguous-term keyword (6th element, index 5) from a  >    canonical tensor type 6-tuple, defaulting to :last when absent.


---
### DEFUN `ANALYZE-TRANSPOSE-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes (transpose M) for 2D tensors.  >    Result type: (tensor elem 2 addr :strided src-ct).


---
### DEFUN `ANALYZE-COL-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes (col index M) for 2D tensors.  >    Result type: (tensor elem 1 addr :strided :last).


---
### DEFUN `ANALYZE-ROW-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes (row index M) for 2D tensors.  >    Result type: (tensor elem 1 addr :strided :last).


---
### DEFUN `ANALYZE-TRANSPOSE-BANG-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Analyzes (transpose! M). Expands to (set! M (transpose M)).  >    Signals a type error if M's type is :compact (result is :strided, incompatible).


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
### DEFUN `%ANF-NORMALIZE-SET!`
- **Args**: `(EXPR IS-NESTED?)`

---
### DEFUN `%ANF-NORMALIZE-IF`
- **Args**: `(OP EXPR IS-NESTED?)`

---
### DEFUN `%ANF-NORMALIZE-IF+`
- **Args**: `(OP EXPR IS-NESTED?)`

---
### DEFUN `%ANF-NORMALIZE-COND`
- **Args**: `(EXPR IS-NESTED?)`

---
### DEFUN `%ANF-NORMALIZE-LET`
- **Args**: `(EXPR IS-NESTED?)`

---
### DEFUN `%ANF-NORMALIZE-DOTIMES`
- **Args**: `(OP EXPR IS-NESTED?)`

---
### DEFUN `%ANF-NORMALIZE-WHILE`
- **Args**: `(OP EXPR IS-NESTED?)`

---
### DEFUN `%ANF-NORMALIZE-ATOMIC`
- **Args**: `(OP EXPR IS-NESTED?)`

---
### DEFUN `ANF-NORMALIZE`
- **Args**: `(EXPR IS-NESTED?)`

  > Returns (VALUES normalized-expr bindings-list).  >    Phase 1c: added opaque pass-through for load-tile-at / store-tile-at  >    and their internal *-bwd / bare load-tile / store-tile variants.


---
### DEFUN `%STRIP-CTX-DECLARES`
- **Args**: `(EXPR)`

  > Recursively strip (declare (grid-level)) and (declare (workgroup-level))  > from let/progn bodies before ANF transform.


---
### DEFUN `%ANF-TRANSFORM`
- **Args**: `(EXPR)`

  > Internal helper for recursive ANF transformation.  > Pre-strips execution-context declares so anf-normalize never sees them.


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

### DEFUN `%EMIT-SUB-FN-BACKWARD`
- **Args**: `(FN ARGS BKWD-FN T-ADJ-FORMS N-FP PKG EMIT-FN LOCAL-ADJ-FN
              &OPTIONAL (SYM-PREFIX BW))`

  > Emits the call to BKWD-FN and routes returned deltas / passed-through  >    &out grad-tensors per the AD convention.  >   >    - Scalar arg: one delta from multi-value return → accumulated into  >      (local-adj arg).  >    - Record/struct arg (looked up via *record-param-field-adjs*): N deltas  >      in declaration order → accumulated into each per-field synth adj.  >    - Tensor arg (identified via fn's :tensor-param-indices registry slot):  >      pairs with an &out arg in the call.  The kernel's corresponding  >      `<arg>_GRAD` is passed; the chain rule's atomic-add happens inside  >      the sub-fn body.  No scalar delta to accumulate.  >   >    The call is emitted whenever there's any accumulation OR any tensor  >    arg (the tensor case writes via &out, not via accumulation, but the  >    call itself still needs to happen).


---
### DEFVAR `*FFI-BASEPTR-SRC*`

  > Endeavor 123 (FFI-AD) backward-walk dynamic map: pointer-temp-sym -> source  >    storage sym, built from (temp (base-ptr~ src)) ANF bindings. Lets  >    %emit-foreign-backward route a foreign pointer argument's gradient SHADOW to  >    the source storage's grad cell, <src>_GRAD. Bound in generate-backward-walk.


---
### DEFUN `%EMIT-FOREIGN-BACKWARD`
- **Args**: `(FN ARGS T-ADJ-FORMS PKG EMIT-FN LOCAL-ADJ-FN)`

  > Endeavor 123 (FFI-AD): emits the user-supplied VJP call for foreign function  >    FN. Call shape mirrors the mechanically-derived VJP signature:  >   >        (BKWD  primals...  seeds...  shadows...)  >   >      - primals = ARGS (the original forward args, in order)  >      - seeds   = T-ADJ-FORMS (adjoints of the active returns; empty for => nil)  >      - shadows = (base-ptr~ <src>_GRAD) for each c-pointer/voidp param, where  >                  <src> is the storage the forward pointer came from via  >                  (base-ptr~ <src>), resolved through *ffi-baseptr-src*.  >   >    The VJP returns one delta per ACTIVE SCALAR input (float/int), in forward  >    order; each is accumulated into that input arg's local adjoint. Pointer-input  >    gradients are written through the shadow pointers by the VJP body, not  >    returned. Handles and other passive params get nothing.


---
### DEFUN `%CRISP-TENSOR-TYPE-P`
- **Args**: `(TYPE-SPEC)`

  > Returns T if TYPE-SPEC (possibly a type alias) resolves to a tensor/vector/matrix  >    storage handle. Vectors (N=1) and matrices (N=2) are syntactic sugar for tensor,  >    so a single head check covers all three.


---
### DEFUN `%CRISP-FLOAT-TENSOR-TYPE-P`
- **Args**: `(TYPE-SPEC)`

  > Returns T if TYPE-SPEC resolves to a tensor/vector/matrix whose element type  >    is a float type (float, double, etc.).  Non-float tensors (e.g. vector long)  >    are not differentiable and should not receive gradient parameters.


---
### DEFUN `%ENSURE-TENSOR-READ-WRITE`
- **Args**: `(TYPE-SPEC)`

  > For backwards compatibility: returns the canonical 6-tuple unchanged.  >    Access was removed; tensors are always read-write.


---
### DEFUN `%STRIP-ACCESSOR-TILDES`
- **Args**: `(ACCESSOR)`

  > Strips trailing tilde, and leading tilde if present, from an accessor  >    name string.  X~ → X, ~X~ → X.


---
### DEFUN `%HANDLE-MATH-AND-TRIG-BACKWARD`
- **Args**: `(V EXPR EMIT-FN LOCAL-ADJ-FN ADJOINT-MAP)`

  > Handles mathematical operations (+, -, *, /) and trigonometric functions (sin, cos).


---
### DEFUN `%HANDLE-TILDE-BACKWARD`
- **Args**: `(V EXPR EMIT-FN LOCAL-ADJ-FN TENSOR-INPUTS-HT SCRATCH-TILE-SYMS)`

  > Handles the tilde (~) indexing operation.


---
### DEFUN `%HANDLE-SUB-FN-CALL-BACKWARD`
- **Args**: `(V EXPR EMIT-FN LOCAL-ADJ-FN HOF-HANDLER-FN)`

  > Handles differentiable sub-function calls.


---
### DEFUN `%IS-ACCESSOR-P`
- **Args**: `(EXPR)`

---
### DEFUN `%HANDLE-ACCESSOR-BACKWARD`
- **Args**: `(V EXPR EMIT-FN LOCAL-ADJ-FN ADJOINT-MAP)`

  > Handles record and struct accessors.


---
### DEFUN `%HANDLE-CONSTRUCTOR-BACKWARD`
- **Args**: `(V EXPR EMIT-FN LOCAL-ADJ-FN ADJOINT-MAP)`

  > Handles %CONSTRUCT-STRUCT backward rule.


---
### DEFUN `%HANDLE-SINGLE-VALUE-BACKWARD`
- **Args**: `(V EXPR ADJOINT-MAP EMIT-FN LOCAL-ADJ-FN &KEY HOF-HANDLER-FN
              (ERROR-ON-UNKNOWN T) TENSOR-INPUTS-HT SCRATCH-TILE-SYMS)`

  > Generates backward-pass adjoint updates for a single ANF binding (v := expr).


---
### DEFUN `%VALUE-IF-P`
- **Args**: `(EXPR)`

  > T if EXPR is a value-producing conditional: if / if+ / when / when+ /  >    unless / unless+.


---
### DEFUN `%VALUE-LET-P`
- **Args**: `(EXPR)`

  > T if EXPR is a value-producing LET.


---
### DEFUN `%FORMS->PROGN`
- **Args**: `(FORMS)`

  > NIL for no forms, the single form, else a (progn ...) wrapper.


---
### DEFUN `%BACKWARD-VALUE-EXPR`
- **Args**: `(V EXPR ADJOINT-MAP EMIT-FN LOCAL-ADJ-FN &KEY HOF-HANDLER-FN
              (ERROR-ON-UNKNOWN T) TENSOR-INPUTS-HT SCRATCH-TILE-SYMS)`

  > Backward-AD for a VALUE expression EXPR whose result is bound to V (so V's  >    adjoint is the incoming seed). Endeavor 124 A1: handles the symbol-copy and  >    literal cases plus compound value exprs (if / let), recursing; leaf exprs  >    (math, ~, calls, accessors) delegate to %handle-single-value-backward.


---
### DEFUN `%HANDLE-VALUE-IF-BACKWARD`
- **Args**: `(V EXPR ADJOINT-MAP EMIT-FN LOCAL-ADJ-FN &KEY HOF-HANDLER-FN
              (ERROR-ON-UNKNOWN T) TENSOR-INPUTS-HT SCRATCH-TILE-SYMS)`

  > Backward for a value-producing (if[+]/when[+]/unless[+] COND THEN ELSE): the  >    result adjoint V_adj flows into whichever branch was taken. Emits a plain `if`  >    mirroring the forward (the uniform-ness of if+ is irrelevant to the backward),  >    each arm carrying its value's chain-rule contribution into V_adj.


---
### DEFUN `%HANDLE-VALUE-LET-BACKWARD`
- **Args**: `(V EXPR ADJOINT-MAP EMIT-FN LOCAL-ADJ-FN &KEY HOF-HANDLER-FN
              (ERROR-ON-UNKNOWN T) TENSOR-INPUTS-HT SCRATCH-TILE-SYMS)`

  > Backward for a value-producing (let (BINDS) ... BODY-EXPR): the let's value is  >    V. Recompute BINDS (forward), declare BRANCH-LOCAL adjoints for the bind temps,  >    push V_adj through BODY-EXPR, then push each bind temp's adjoint through its rhs.  >    The local adjoints are scoped to the emitted let so they don't collide with the  >    global adjoint-map / top-level adjoint declarations. Endeavor 124 A1.  >   >    NOTE: zero-inits the local adjoints with 0.0 (float). Double-chain interaction  >    is deferred to the mixed-precision pass (Phase C).


---
### DEFUN `%COLLECT-LOCALLY-BOUND-VARS`
- **Args**: `(BODY-FORMS)`

  > Returns a list of distinct symbols introduced as bindings anywhere  >    inside BODY-FORMS (a list of forms).  Includes single-value bindings  >    `(v expr)`, multi-value bindings `(v0 v1 ... expr)`, the induction var  >    of nested DOTIMES, and the bound vars of nested LET.  Recurses through  >    LET / DOTIMES / IF / PROGN / WHEN / UNLESS bodies.  SET! and DECLARE  >    introduce no bindings, so they are not scanned.  Used by the AD walker  >    to identify adjoint allocas that must be reset at the top of each  >    backward loop iteration.


---
### DEFUN `%IS-TENSOR-ALIAS`
- **Args**: `(SYM)`

---
### DEFUN `%HAS-EXPLICIT-N`
- **Args**: `(ARGS)`

---
### DEFUN `%PROMOTE-SCRATCH-INIT-FOR-AD`
- **Args**: `(INIT)`

  > Promotes the type in a make-scratch-* form to its float adjoint equivalent.  >    E.g., (make-scratch-vector ulong 4) -> (make-scratch-vector double 4).


---
### DEFUN `%AUGMENT-SCRATCH-ADJ-BINDINGS`
- **Args**: `(BINDINGS KERNEL-PKG)`

  > For each binding (var (make-scratch-X ...)), inject a paired  >    (var_ADJ (make-scratch-X ...)) binding right after.  For other bindings,  >    pass through unchanged.  Promotes element type (e.g., ulong -> double)  >    so gradients use correct FP precision.


---
### DEFUN `%TLC-BWD-ADJ-NAME`
- **Args**: `(SYM INPUTS OUTPUTS LOCAL-ADJ-FN KERNEL-PKG)`

  > Returns the backward-pass adjoint symbol for a forward arg SYM:  >      - if SYM is in INPUTS or OUTPUTS  → <SYM>_GRAD  (kernel param)  >      - otherwise (let-bound local)     → <SYM>_ADJ  (direct intern; NOT  >        via local-adj-fn, because local-adj-fn would add the sym to the  >        adjoint-map, which causes the wrapping let to scalar-initialize it  >        — wrong for tensor adjoints.  The auto-allocated LET binding for  >        <var>_ADJ as a make-scratch-* is the only initializer needed.)


---
### DEFUN `%TLC-EXTRACT-TRANSPOSE-KEY`
- **Args**: `(KEY-ARGS)`

  > Returns the value of :transpose in KEY-ARGS, or NIL if absent.


---
### DEFUN `%GFW-PROCESS-SET!`
- **Args**: `(FORM EMIT-FN LOCAL-ADJ-FN INPUTS OUTPUTS SCRATCH-TILE-SYMS
              INTERMEDIATE-ZERO KERNEL-PKG)`

---
### DEFUN `%GFW-PROCESS-LET`
- **Args**: `(FORM EMIT-FN PROCESS-FORM-FN BINDINGS AUGMENTED-BINDINGS BODY)`

---
### DEFUN `%GFW-PROCESS-DOTIMES`
- **Args**: `(FORM EMIT-FN PROCESS-FORM-FN BINDING BODY LOCAL-VARS ADJOINT-MAP
              INTERMEDIATE-ZERO)`

---
### DEFUN `%GFW-PROCESS-IF`
- **Args**: `(FORM EMIT-FN PROCESS-FORM-FN COND-FORM THEN-FORM ELSE-FORM)`

---
### DEFUN `GENERATE-BACKWARD-WALK`
- **Args**: `(FLAT-ANF INPUTS OUTPUTS INPUT-TYPES OUTPUT-TYPES &KEY KERNEL-PKG)`

  > Walks an ANF body backwards to accumulate adjoints.  >    Phase 1c: adds LOAD-TILE-AT / STORE-TILE-AT clauses to process-form  >    that emit %load-tile-at-bwd / %store-tile-at-bwd with the correct  >    adjoint symbols.  Also extends the LET case to auto-allocate paired  >    <var>_ADJ scratch tensors for make-scratch-* bindings.  >   >    Bug 032 fix: SET! on a local-scratch tile (target neither input nor  >    output) now emits a proper consume + reset pair so the RHS chain rule  >    propagates through tile mutations.


---
### DEFUN `%CRISP-FLOAT-TYPE-P`
- **Args**: `(TYPE-SPEC)`

  > Returns T if TYPE-SPEC (possibly a type alias) resolves to a Crisp  > float-category scalar type (float, double, half, bfloat16).  > Resolves def-type aliases via *crisp-type-aliases* first, then checks  > *crisp-types* directly (for primitives like 'float), then falls back  > to compute-base-type for derived types.


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

  > Recursively expands record-typed inputs into their scalar fields,  >    chasing through nested records.  Also handles struct kernel inputs  >    per the Shadow Struct design: structs are NOT exploded; instead a  >    single shadow-grad-cell is paired with each struct param.  >   >    Returns 9 values: (flat-inputs flat-input-types reassembly-bindings  >    grad-out-params grad-out-types record-subs-ht record-type-ht  >    grad-cell-syms struct-shadow-info).  >   >    The 9th value, struct-shadow-info, is an alist:  >      ((STRUCT-PARAM-SYM SHADOW-GRAD-SYM SHADOW-TYPE FIELD-ADJ-ALIST) ...)  >    used by %fix-struct-shadow-writes to emit the final shadow-write.  >   >    Leaf scalar fields (float or integer) produce grad cells per 101.  >    Nested-record fields produce a synthetic intermediate sym that gets  >    registered in record-subs-ht/record-type-ht so the substitution  >    machinery walks through it; their leaf fields are further exploded.


---
### DEFUN `%BACKWARD-SKIP-FN-P`
- **Args**: `(FN-SYM)`

  > Returns T if FN-SYM should be silently skipped in the AD backward walk.


---
### DEFUN `%COLLECT-RECORD-PARAM-INFO`
- **Args**: `(ENV PKG)`

  > Record/struct params + their field info, in declaration order.


---
### DEFUN `%COLLECT-ALL-DIFF-PARAM-SYMS-FOR-RETURN`
- **Args**: `(ENV RECORD-PARAM-INFO &OPTIONAL ACTIVE-SET)`

  > Full ordered list of 'differentiable param syms' used for emitting the multi-value  >    return. ACTIVE-SET (A2) gates integer scalar params: an int is included only when  >    active (differentiably reaches the return).


---
### DEFUN `%BUILD-RECORD-PARAM-FIELD-ADJS-HT`
- **Args**: `(RECORD-PARAM-INFO)`

  > Build the hash table record-param-field-adjs-ht.


---
### DEFUN `%COLLECT-TENSOR-PARAM-INFO`
- **Args**: `(ENV PKG)`

  > Handle params (tensors + cells) + their grad-out info, in declaration order.


---
### DEFUN `%REGISTER-HOF-DIFFERENTIABLE-FUNCTION`
- **Args**: `(NAME ENV FLOAT-PARAM-SYMS FN-PARAM-ENTRIES N-RETURN BODY-FORMS)`

  > Register the HOF details for autodiff compilation.


---
### DEFUN `%GENERATE-BACKWARD-COMPANION-AST-BODY`
- **Args**: `(NAME PARAMS ENV DECLARATIONS BODY-FORMS PKG N-FLOAT-PARAMS
              N-RETURN RETURN-TYPES-NON-VOID RECORD-PARAM-INFO
              RECORD-PARAM-FIELD-ADJS-HT ALL-DIFF-PARAM-SYMS-FOR-RETURN)`

  > Generate backward companion def-function AST body.


---
### DEFUN `%GENERATE-BACKWARD-FUNCTION-AST`
- **Args**: `(NAME PARAMS DECLARATIONS BODY-FORMS)`

  > Generates the backward companion (def-function NAME_GRAD ...) for a  > differentiable user function.


---
### DEFUN `%GENERATE-BACKWARD-FUNCTION-WALK`
- **Args**: `(FLAT-ANF FLOAT-PARAM-SYMS T-GRAD-SYMS RETURN-VARS &OPTIONAL
              TENSOR-INPUTS-HT ANY-DOUBLE RETURN-ADJ-TYPES)`

  > Generates the backward-pass body for a def-function.  > FLAT-ANF         : flattened ANF of the forward function body.  > FLOAT-PARAM-SYMS : parameter symbols whose types are float (get delta outputs).  > T-GRAD-SYMS      : symbols for the incoming gradient inputs (one per return value).  > RETURN-VARS      : symbols of the return variables (identified from FLAT-ANF last element).  >   > 101 extension: TENSOR-INPUTS-HT (optional hash-table mapping each tensor-sub-  > fn-param symbol to its tensor type) is threaded into %handle-single-value-  > backward so tensor reads inside the body emit atomic-add into the corresponding  > &out grad-tensor.  >   > Returns a (let (...) ...) form suitable as the body of the _GRAD companion function.


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
### DEFUN `%CRISP-INTEGER-TENSOR-TYPE-P`
- **Args**: `(TYPE-SPEC)`

  > Returns T if TYPE-SPEC resolves to a tensor whose element type is an integer  > category (:signed-int or :unsigned-int). Mirrors %crisp-float-tensor-type-p.


---
### DEFUN `%INTEGER-TENSOR-ELEM-TO-FLOAT`
- **Args**: `(TYPE-SPEC)`

  > Replaces the element type of an integer tensor with its float analog:  >    64-bit integers (long, ulong) → double; all others → float.  >    Returns TYPE-SPEC unchanged if it is not an integer tensor.


---
### DEFUN `%CRISP-INTEGER-SCALAR-TYPE-P`
- **Args**: `(TYPE-SPEC)`

  > Returns T if TYPE-SPEC (possibly a type alias) resolves to an integer  > scalar type (signed or unsigned).  Mirrors %crisp-float-type-p but for ints.


---
### DEFUN `%INTEGER-SCALAR-TO-FLOAT-SCALAR`
- **Args**: `(TYPE-SPEC)`

  > Returns the float-analog scalar type for an integer scalar:  >    64-bit (long, ulong) → double; smaller ints → float.  Type aliases are  >    resolved.  Returns TYPE-SPEC unchanged if it is not an integer scalar.


---
### DEFUN `%CRISP-INTEGER-CELL-TYPE-P`
- **Args**: `(TYPE-SPEC)`

  > Returns T if TYPE-SPEC is a cell whose element type is an integer scalar.


---
### DEFUN `%INTEGER-CELL-ELEM-TO-FLOAT`
- **Args**: `(TYPE-SPEC)`

  > Replaces the element type of an integer cell with its float analog.  >    Returns the keyword form (cell float-elem :address-space addr) — length 4 —  >    to satisfy downstream consumers like marshall-cell that reject the canonical  >    3-tuple positional form.  Returns TYPE-SPEC unchanged if it is not an  >    integer cell.


---
### DEFUN `%PROMOTE-TO-FLOAT-ADJOINT`
- **Args**: `(TYPE-SPEC)`

  > Generalised float-adjoint type promotion for AD output gradient slots.  >    - integer scalar      → float / double scalar  >    - integer tensor      → float / double tensor (element-type promoted)  >    - integer cell        → cell of float / double  >    - everything else     → unchanged (already float, or non-numeric)  >    Used to produce caller-supplied _GRAD seed types and input _GRAD output  >    types that mirror the input shape with float adjoint values.


---
### DEFUN `%AD-PROMOTES-TO-DOUBLE-P`
- **Args**: `(TYPE-SPEC)`

  > T if the ADJOINT of a value of TYPE-SPEC is DOUBLE (double / long / ulong, or a  >    cell/tensor thereof). Canonicalizes first, because %promote-to-float-adjoint  >    leaves a non-integer type ALIAS unresolved (e.g. a (cell double) alias).


---
### DEFUN `%AD-ZERO`
- **Args**: `(DOUBLE-P)`

  > The typed zero literal for a fresh adjoint accumulator: (as double 0.0) when  >    DOUBLE-P, else 0.0.


---
### DEFUN `%AD-SCALAR-ADJOINT-TYPE`
- **Args**: `(TYPE-SPEC)`

  > The SCALAR adjoint type ('float or 'double) for a scalar value of TYPE-SPEC.


---
### DEFVAR `*AD-ANY-OUTPUT-DOUBLE*`

  > Dynamically bound (by the kernel walk and the sub-function walk) to T when the  >    backward chain runs in double — any output/param/return promotes to double. Read  >    by the value-if/let and FFI paths so their fresh adjoints get the typed zero  >    (%ad-zero) too, without threading the flag through every call.


---
### DEFUN `%AUTODIFF-GRAD-CELL-TYPE`

  > Returns the canonical cell type used for gradient output parameters.


---
### DEFVAR `*RECORD-PARAM-FIELD-ADJS*`

  > Hash table: record-sym -> alist of (FIELD-NAME-STR . FIELD-ADJ-SYM)  >    in declaration order.  Bound during backward walk for sub-functions  >    with record params, and for kernels with record-valued ANF temps  >    (constructed via make-RECORD).  Otherwise NIL.  >   >    Consumers:  >      - The accessor rule in %handle-single-value-backward routes adjoint  >        flow from (FIELD~ p) to the per-field synth adj.  >      - The %construct-struct case flows per-field adjs to constructor args.  >      - %emit-sub-fn-backward distributes deltas per-field when an arg is  >        a record-valued symbol.


---
### DEFVAR `*STRUCT-KERNEL-PARAM-SHADOWS*`

  > Hash table: struct-kernel-param-sym -> (cons SHADOW-GRAD-SYM FIELD-ADJ-ALIST).  >    FIELD-ADJ-ALIST is an alist of (FIELD-NAME-STR . FIELD-ADJ-SYM) in  >    declaration order.  Bound by %generate-backward-kernel-ast around  >    the backward walk when struct kernel params are present.  Used by:  >      - The accessor rule in %handle-single-value-backward.  >      - The shadow-write postprocessor.


---
### DEFUN `%SCAN-FORMS-FOR-RECORD-INFO`
- **Args**: `(FORMS)`

  > Walks FORMS (recursing through progn / with-template-type) and returns  >    an alist mapping (symbol-name TYPE-NAME) -> count of non-:c-t,  >    non-brand runtime fields. Used during pre-registration when *crisp-types*  >    isn't yet populated.  >   >    Includes BOTH def-record AND def-struct (records and structs at the  >    sub-function AD level both contribute their field count toward the  >    differentiability gate).  Also includes derived-from-{record,struct}  >    types: when (def-derived-type NEW BASE ...) is encountered and BASE is  >    already in the alist, NEW is added with the same field count.  >   >    The name `record-info` is historical; the alist now tracks structs too.


---
### DEFUN `%RESOLVE-TO-BASE-TYPE-FOR-RECORDS`
- **Args**: `(PD-TYPE)`

  > If PD-TYPE names a derived type whose base is a record, returns the  >    base record type symbol. Otherwise returns PD-TYPE unchanged.  >   >    Records are SROA'd at every function boundary, and derived-type wrappers  >    preserve that property. This helper lets the sub-function gate widening  >    accept derived-from-record types (e.g. `coordinate` derived from `point`).


---
### DEFUN `%RESOLVE-TO-BASE-TYPE-FOR-STRUCTS-OR-RECORDS`
- **Args**: `(PD-TYPE)`

  > If PD-TYPE names a derived type whose base is a struct OR a record,  >    returns the base type symbol.  Otherwise returns PD-TYPE unchanged.  >    Used by sub-function gate widening to accept derived-from-struct types  >    in addition to derived-from-record types.


---
### DEFUN `%COUNT-DIFFERENTIABLE-CONTRIBUTIONS`
- **Args**: `(PD-TYPE &OPTIONAL RECORD-INFO)`

  > Returns the number of SCALAR-DELTA contributions this parameter type  >    makes at the SUB-FUNCTION level (def-function).  Used to size the  >    multi-value-return arity at the sub-fn _GRAD boundary.  >   >    - Records / derived-from-records  -> runtime-field count (per-field deltas).  >    - Structs  / derived-from-structs -> runtime-field count (same convention).  >    - Float scalars                   -> 1.  >    - Tensors, cells, integer scalars -> 0.  These contribute zero scalar  >      deltas; tensors flow grad via &out grad-tensor params instead  >      (see %has-tensor-diff-param-p and the tensor-sub-fn pipeline).  >   >    RECORD-INFO (optional alist of (NAME-STR . FIELD-COUNT)) bridges the  >    pre-registration ordering issue where *crisp-types* isn't yet  >    populated. When supplied, it takes priority over the runtime registry.


---
### DEFUN `%ASV-UNION`
- **Args**: `(EXPRS ENV)`

  > Union of %active-scalar-vars over EXPRS.


---
### DEFUN `%ACTIVE-SCALAR-VARS`
- **Args**: `(EXPR ENV)`

  > Set (list) of scalar symbols that DIFFERENTIABLY affect EXPR's value. ENV is an  >    alist mapping a let-bound symbol to its own active-scalar-var set.


---
### DEFUN `%ACTIVE-SCALAR-PARAM-SET`
- **Args**: `(PARAMS BODY-FORMS)`

  > Subset of PARAMS (symbols) that are ACTIVE — differentiably affect the value of  >    BODY-FORMS' final form (the function's return).


---
### DEFUN `%COUNT-ACTIVE-CONTRIBUTIONS`
- **Args**: `(PD-TYPE SYM ACTIVE-SET &OPTIONAL RECORD-INFO)`

  > Like %count-differentiable-contributions, but an INTEGER scalar param counts 1  >    only when SYM is in ACTIVE-SET (A2 activity analysis). Float / tensor / cell /  >    record behavior is unchanged — this only ADDS active-int contributions.


---
### DEFUN `%CRISP-TENSOR-PARAM-TYPE-P`
- **Args**: `(PD-TYPE)`

  > Returns T if PD-TYPE is a tensor (float-element or integer-element)  >    at the sub-function level.  Used to decide whether a sub-fn param  >    contributes a tensor grad-out (vs a scalar delta).  >   >    Handles three forms:  >    - List form: (tensor float 1 ...) — caught by the existing helpers.  >    - Mangled-template-name symbol: TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST —  >      produced by Crisp's template instantiation.  Detected by name prefix.  >    - Plain symbol naming a registered tensor type.


---
### DEFUN `%CRISP-CELL-PARAM-TYPE-P`
- **Args**: `(PD-TYPE)`

  > Returns T if PD-TYPE is a cell of a SCALAR element type (float or  >    integer) at the sub-function level.  Cells flow grad via &out  >    grad-cell, same pattern as tensors.  >   >    Cells of structs/records are NOT accepted here — their grad-cell  >    would need to be a cell of the corresponding shadow type, and the  >    chain rule for `(set! (field~ (~ c)) ...)` is structurally different  >    (deferred).  >   >    Recognizes three forms (mirrors %crisp-tensor-param-type-p):  >    - List form: (cell float :address-space :global ...).  >    - Mangled template name like CELL_FLOAT_GLOBAL — produced by Crisp's  >      template instantiation.  Detected by name prefix + scalar element.  >    - Plain symbol naming a registered cell type.


---
### DEFUN `%CRISP-HANDLE-PARAM-TYPE-P`
- **Args**: `(PD-TYPE)`

  > Returns T for any sub-fn param type that flows grad via &out grad-handle:  >    tensors AND cells.  Both go through the same convention — paired with  >    an &out grad-handle of matching shape, body atomic-adds into it.


---
### DEFUN `%HAS-TENSOR-DIFF-PARAM-P`
- **Args**: `(ENV)`

  > Returns T if ENV contains at least one non-&OUT parameter that flows  >    grad via a paired &out grad-handle (tensor OR cell).  Used by the  >    sub-function pre-reg + _GRAD generator gates: a sub-fn with such  >    params is differentiable even when its scalar-delta count is zero.  >   >    Name is historical (originally tensor-only); now covers cells too.


---
### DEFUN `%TRIVIAL-ACCESSOR-BODY-P`
- **Args**: `(BODY-FORMS)`

  > Returns T if BODY-FORMS is a single (return (%extract-struct-member obj idx))  >    — i.e. a trivial field-extraction accessor.  Used to detect auto-generated  >    accessors that def-derived-type emits without a `(crisp-system-generated)`  >    declaration (def-record's accessors ARE marked, but def-derived-type's are  >    not).  These accessors don't need their own _GRAD: the kernel-side accessor  >    rule handles them inline.


---
### DEFUN `%ADJ-TYPE-FOR-FIELD`
- **Args**: `(FORWARD-TYPE &OPTIONAL STRUCT-NAME-SET)`

  > Returns the adjoint type for a forward struct field's TYPE, per  >    the 101 promotion rules.  >   >    STRUCT-NAME-SET (optional hash table, symbol->T) covers struct types  >    that will be defined by upcoming def-struct forms in the same  >    compilation unit but haven't been registered in *crisp-types* yet.  >    At shadow-injection time (before any macro expansion), this is the  >    only way to know which symbols are struct types.


---
### DEFUN `%GENERATE-SHADOW-DEF-STRUCT-FORM`
- **Args**: `(DEF-STRUCT-FORM &OPTIONAL STRUCT-NAME-SET)`

  > Given (def-struct NAME (f0 t0) (f1 t1) ... brand-decls...), returns  >    the matching (def-struct NAME_ADJ (f0 adj_t0) (f1 adj_t1) ...) form.  >    Brand declarations are dropped.  :c-t members are preserved (their  >    value is a forward-time constant; not differentiable but harmless).  >    STRUCT-NAME-SET enables recognizing nested struct field types whose  >    def-struct forms appear elsewhere in the compilation unit.


---
### DEFUN `%COLLECT-STRUCT-NAMES-FROM-FORMS`
- **Args**: `(FORMS)`

  > Walks FORMS at the top level and returns a hash table mapping each  >    (def-struct NAME ...) NAME (and only structs, not records) to T.  >    Used by shadow-injection to recognize struct field types when  >    *crisp-types* isn't yet populated.


---
### DEFUN `%INJECT-SHADOW-STRUCT-FORMS`
- **Args**: `(FORMS)`

  > Walks FORMS at the top level.  After each (def-struct NAME ...) that  >    defines a NON-shadow struct, appends (def-struct NAME_ADJ ...).  >    Already-shadow structs (name ends with _ADJ) are passed through.  >    def-record forms are left untouched (records SROA, no shadow needed).  >    Other forms unchanged.  >   >    First pass collects all struct names so the shadow generator can  >    recognize nested struct field types.


---
### DEFUN `%CRISP-STRUCT-TYPE-P`
- **Args**: `(TYPE-SPEC)`

  > Returns T if TYPE-SPEC names a registered def-struct (category :struct).  >    Distinct from %crisp-record-type-p (which checks category :record).


---
### DEFUN `%SHADOW-TYPE-NAME-FOR`
- **Args**: `(STRUCT-TYPE-NAME)`

  > Returns the shadow struct's type symbol for STRUCT-TYPE-NAME.


---
### DEFUN `%MAKE-SHADOW-CONSTRUCTOR-NAME-FOR`
- **Args**: `(STRUCT-TYPE-NAME)`

  > Returns the MAKE-<TYPE>_ADJ constructor symbol for STRUCT-TYPE-NAME.


---
### DEFUN `%NESTED-FIELD-INFO-P`
- **Args**: `(FIELD-INFO)`

  > T if FIELD-INFO from a struct-shadow alist refers to a nested struct  >    (an alist), as opposed to a scalar leaf (a symbol).


---
### DEFUN `%REGISTER-SHADOW-ANF-INTERMEDIATES`
- **Args**: `(FLAT-ANF SHADOW-HT)`

  > Pre-scans FLAT-ANF for bindings of the shape (TEMP (FIELD~ SHADOW-TRACKED-SYM))  >    where SHADOW-TRACKED-SYM is in SHADOW-HT and the field's info is a  >    nested-struct alist.  Registers TEMP in SHADOW-HT (with the nested  >    alist as TEMP's field-adj-alist) so subsequent accessor calls on TEMP  >    can route deeper.  Mutates SHADOW-HT in place.  >   >    Must run BEFORE the backward walk so the accessor case can consult  >    the augmented map.


---
### DEFUN `%BUILD-STRUCT-FIELD-ADJ-ALIST`
- **Args**: `(PARAM-SYM STRUCT-TYPE PKG)`

  > Recursively builds a field-adj-alist for a struct kernel param of  >    STRUCT-TYPE.  Each entry is (FIELD-NAME-STR . FIELD-INFO) where:  >   >    - For scalar fields: FIELD-INFO is the per-field adj symbol  >      (e.g. r_top-left_x_adj).  >    - For nested struct fields: FIELD-INFO is itself an alist of the  >      same shape, recursively descended.  >   >    PARAM-SYM is the prefix used when generating leaf adj sym names  >    (so leaves nested under r.top-left get names like r_top-left_x_adj).


---
### DEFUN `%BUILD-SHADOW-CTOR-FORM`
- **Args**: `(STRUCT-TYPE-NAME FIELD-ADJ-ALIST PKG)`

  > Builds a (MAKE-<S>_ADJ :field1 val1 :field2 val2 ...) form recursively.  >    For scalar leaf fields, val is wrapped in (%volatile-read SYM) — see  >    IGC SROA-aliasing workaround commentary above.


---
### DEFUN `%COLLECT-ALL-LEAF-ADJ-SYMS`
- **Args**: `(FIELD-ADJ-ALIST)`

  > Collects all leaf adj syms (scalars at the bottom of a nested alist)  >    recursively.


---
### DEFUN `%ENSURE-LEAF-ADJ-BINDINGS`
- **Args**: `(FORM LEAF-ADJ-SYMS)`

  > If FORM is `(let (bindings) body...)`, augments the bindings list with  >    `(sym 0.0)` for each sym in LEAF-ADJ-SYMS not already bound.  Used to  >    ensure that leaf adj syms referenced ONLY by the shadow-write  >    postprocessor (i.e. unused in the kernel body) have valid zero-init  >    bindings.


---
### DEFUN `%FIX-STRUCT-SHADOW-WRITES`
- **Args**: `(FORM STRUCT-SHADOW-INFO)`

  > Postprocesses the kernel backward walk's output.  For each struct  >    kernel input S in STRUCT-SHADOW-INFO, replaces the default scalar  >    input-grad-write `(set! S_GRAD S_ADJ)` with the correct shadow-  >    struct write `(set! (~ S_GRAD) (MAKE-<S>_ADJ ...))` — building  >    the shadow constructor recursively for nested struct fields.  >   >    STRUCT-SHADOW-INFO is the alist returned as the 9th value of  >    %expand-record-kernel-inputs:  >      ((STRUCT-PARAM-SYM SHADOW-GRAD-SYM SHADOW-TYPE FIELD-ADJ-ALIST) ...)  >   >    Other (set! ...) forms are passed through unchanged.


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
### DEFUN `%PTX-ENTRY-ILLEGAL-ADDRSPACE-P`
- **Args**: `(AS)`

  > PTX kernel entry-point param pointers may not target shared (NVPTX  >    addrspace 3) or local (NVPTX addrspace 5).  Both are per-block /  >    per-thread state spaces with no addressable launch-time value, and  >    the CUDA driver rejects any cubin whose entry sig declares such  >    a pointer.


---
### DEFUN `%PTX-ENTRY-DEMOTE-TYPE`
- **Args**: `(TY)`

  > If TY is a pointer in an illegal-for-PTX-entry addrspace, returns  >    i64 (the demoted form Crisp passes at the kernel boundary).  >    Otherwise returns TY unchanged.


---
### DEFUN `%VERIFY-PTX-ENTRY-EXPANDED-TYPES`
- **Args**: `(EXPANDED-TYPES FN-NAME)`

  > Walks an already-demoted EXPANDED-TYPES list and ERRORs if any entry  >    is still an illegal-for-entry pointer (shared/local).  Called from  >    inside CREATE-LLVM-FUNCTION-TYPE on the post-demotion list, so this  >    should never fire in correct code — it's a belt-and-suspenders check  >    for future regressions where a new pointer-producing path slips past  >    %PTX-ENTRY-DEMOTE-TYPE.  >   >    We check expanded LLVM types rather than walking the live func via  >    llvm-count-params because we already have the list at the demotion  >    site and there's no Crisp binding for LLVMCountParams (avoiding the  >    need to plumb a new foreign binding through llvm-bindings-overlay).


---
### DEFUN `%PTX-ENTRY-RESTORE-SHARED-PTRS-FOR-IMPLODE`
- **Args**: `(BUILDER COMPONENTS TYPE-SPEC MODULE IS-ENTRY-POINT)`

  > Counterpart to the demoter: at the receive site, the kernel's LLVM  >    param at a demoted slot is now an i64.  IMPLODE-VALUE expects a  >    pointer in the original addrspace there, so inttoptr each demoted  >    component back before packing.  No-op for non-PTX, non-entry, and  >    for params whose expanded types had no demotable pointer.


---
### DEFUN `INITIALIZE-FUNCTION-PARAMETERS`
- **Args**: `(BUILDER FUNC PARAM-NODES MODULE VAR-ENV &OPTIONAL IS-ENTRY-POINT)`

  > Allocates stack space and stores function parameters.  >    When IS-ENTRY-POINT is non-NIL and *TARGET-BACKEND* is :PTX, restores  >    any param components that the kernel-entry demoter swapped from  >    shared/local pointer to i64 (see header comment in this overlay).


---
### DEFUN `%APPLY-DENORMAL-ATTRIBUTE`
- **Args**: `(FUNC MODULE)`

  > Endeavor 126: stamp the `denormal-fp-math` (and `-f32`) function attribute on FUNC  >    per *denormal-handling* — :ftz -> "preserve-sign,preserve-sign" (flush subnormals),  >    :preserve -> "ieee,ieee" (strict IEEE). NVPTX honours these directly; the SPIR-V  >    DenormFlushToZero execution mode is emitted separately. Applied to every function.


---
### DEFUN `%EMIT-SPIRV-DENORM-EXECUTION-MODE`
- **Args**: `(FUNC MODULE)`

  > Endeavor 126: emit an !spirv.ExecutionMode metadata entry on kernel FUNC so the  >    LLVM->SPIR-V translator emits DenormFlushToZero (4460, :ftz) or DenormPreserve  >    (4459, :preserve) at width 32. The `denormal-fp-math` attribute alone does NOT  >    reach SPIR-V (verified 2026-07-01), so this is required for the choice to take  >    effect on the SPV/L0 path. Per-entry-point; SPV target only.


---
### DEFUN `ENSURE-OPENCL-KERNEL-METADATA`
- **Args**: `(FUNC SEMANTIC-FUNCTION MODULE)`

  > Marks a function as a SPIR-V/PTX kernel if it's an entry point.  >    Sets the appropriate calling convention (76 for SPIR-V, 71 for PTX).  >    Endeavor 126: also stamps the denormal-fp-math attribute (all functions).  >   >    NOTE: Kernel argument metadata (address space, access qualifiers, etc.) is added  >    as text during IR printing for SPIR-V.


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

  > Generates the LLVM function prototype and debug info.  >    For PTX entry points, threads IS-ENTRY-POINT and FN-NAME into  >    CREATE-LLVM-FUNCTION-TYPE so shared/local pointer params get demoted  >    to i64 at the kernel boundary, and the post-demotion verifier can  >    error with the kernel name (see header comment).


---
### DEFPARAMETER `*KERNEL-READONLY-TENSOR-SYMS*`

  > Hash-table set of kernel-param symbols whose indexed loads should be  >    marked with !invariant.load metadata.  Bound by generate-function-body  >    around the body codegen loop; read by the semantic-aref tensor case.  >    NIL means no read-only inference applies (kernel has no &out, or non-  >    kernel function).


---
### DEFUN `%COLLECT-READONLY-TENSOR-PARAM-SYMS`
- **Args**: `(SEMANTIC-FUNCTION)`

  > Looks up SEMANTIC-FUNCTION's high-level (pre-flatten) declared  >    signature in *KERNEL-DECLARED-SIGNATURES* and returns a hash-table  >    of param symbols whose tensor reads can be marked invariant, or NIL  >    if the convention doesn't apply.  >   >    The convention applies iff the kernel's declared params include &OUT.  >    Every param BEFORE the &OUT marker that is also a float or integer  >    tensor goes into the returned set.  >   >    Returns NIL when:  >      - The function isn't a registered kernel (no entry in  >        *KERNEL-DECLARED-SIGNATURES*).  Helper functions, accessors, and  >        internally-generated functions all fall here — safe default.  >      - The declared signature contains no &OUT marker (kernel may write  >        through any param; no read-only inference possible).  >      - No qualifying tensor params remain after filtering.  >   >    Declared signature shape: a list of (PARAM-NAME . TYPE-SPEC) pairs,  >    except &OUT itself which appears as (&OUT . &OUT).


---
### DEFUN `%ATTACH-INVARIANT-LOAD`
- **Args**: `(LOADED-INST MODULE)`

  > Attach `!invariant.load !{}` metadata to the LLVM load instruction  >    LOADED-INST.  The empty MD node is the LLVM convention for the  >    invariant.load assertion.  NVPTX lowers `load` + `!invariant.load`  >    to `ld.global.nc.f32` (texture-cache / non-coherent path).  >   >    Note: LLVMMDNodeInContext2 returns an LLVMMetadataRef; LLVMSetMetadata  >    expects an LLVMValueRef.  We wrap via LLVMMetadataAsValue.


---
### DEFUN `%ARRAY-NODE-READONLY-TENSOR-PARAM-P`
- **Args**: `(ARRAY-NODE)`

  > Returns T if ARRAY-NODE is a direct reference (semantic-var-read)  >    to a kernel-param symbol in *KERNEL-READONLY-TENSOR-SYMS*.  Aliased  >    references (let-bindings, function-call results) return NIL — they  >    degrade gracefully to a plain load.


---
### DEFUN `GENERATE-FUNCTION-BODY`
- **Args**: `(SEMANTIC-FUNCTION FUNC DI-SUBPROGRAM BUILDER MODULE DI-BUILDER
              LOCATION-MAP)`

  > Generates the body of the function.  >    Threads IS-ENTRY-POINT into INITIALIZE-FUNCTION-PARAMETERS so the  >    PTX kernel-entry receive site can inttoptr demoted i64 params back  >    to their original-addrspace pointer.  >    Binds *kernel-readonly-tensor-syms* around the body codegen so the  >    semantic-aref tensor case can attach !invariant.load to direct  >    reads of read-only kernel-param tensors.


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
### DEFUN `%GET-DI-LOCATION`
- **Args**: `(NODE MODULE DI-BUILDER DI-SCOPE LOCATION-MAP)`

  > Helper: Creates and returns a debug location if debug metadata is available.


---
### DEFUN `%ATTACH-DEBUG-LOC`
- **Args**: `(INST NODE MODULE DI-BUILDER DI-SCOPE LOCATION-MAP)`

  > Helper: Creates and attaches a debug location to the instruction if metadata is available.


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
### DEFUN `%APPLY-PRECISION-FMF`
- **Args**: `(INST)`

  > Endeavor 126: when *math-precision* is :fast, stamp all fast-math flags on the  >    FP-math instruction INST (guarded by llvm-can-value-use-fast-math-flags). Returns  >    INST so it can wrap a build call inline. No-op under :ieee (plain FP left as-is).  >    Per-instruction FMF is the only path the LLVM->SPIR-V translator honours.


---
### DEFUN `%NATIVE-BUILTIN-MANGLED-NAME`
- **Args**: `(BASE-NAME ARITY)`

  > Itanium-mangled name of an OpenCL native builtin taking ARITY float args.  >    native_sin/1 -> _Z10native_sinf ; native_powr/2 -> _Z11native_powrff.


---
### DEFPARAMETER `*NATIVE-BUILTIN-MANGLED-NAMES*`

  > The mangled OpenCL native builtins Crisp may emit under fast precision on SPV.


---
### DEFUN `%MODULE-USES-NATIVE-BUILTIN-P`
- **Args**: `(MODULE)`

  > T if MODULE declares any OpenCL native_* builtin. Used to decide whether to  >    inject !opencl.ocl.version so the translator recognises the mangled calls.  >    (NB: `return` is shadowed to Crisp's RETURN in :crisp.compiler, so use `some`.)


---
### DEFUN `%MODULE-USES-ASYNC-COPY-BUILTIN-P`
- **Args**: `(MODULE)`

  > Endeavor 136 (SPV): T if MODULE declares the OpenCL async-copy/wait builtins  >    (OpGroupAsyncCopy / OpGroupWaitEvents lowering).  The wait builtin has a single  >    element-type-independent mangled name and every async load-tile is paired with an  >    await, so it is a reliable, cheap indicator.  Like native_*, these are only lowered  >    to opcodes when !opencl.ocl.version metadata is present.


---
### DEFUN `%EMIT-OPENCL-VERSION-METADATA`
- **Args**: `(MODULE)`

  > Endeavor 128: add !opencl.ocl.version / !opencl.spir.version = {2,0} so the  >    LLVM->SPIR-V translator runs OpenCL-builtin recognition and maps native_*  >    mangled calls to native_* OpenCL.std ExtInst. Without this metadata the calls  >    translate to imported OpFunctionCall (unresolved at zeKernelCreate on L0).  >    Endeavor 136 reuses this for the async_work_group_copy / wait_group_events builtins.


---
### DEFUN `%LIBDEVICE-FN-NAME`
- **Args**: `(BASE F32-P)`

  > libdevice symbol for BASE at the given width: __nv_sin -> __nv_sinf (f32) / __nv_sin (f64).


---
### DEFUN `%MATH-CALL-NAME`
- **Args**: `(INTRINSIC-NAME NATIVE-NAME LIBDEVICE-BASE LIBDEVICE-FAST-BASE
              ARITY SIZE)`

  > Select the concrete callee for a math intrinsic given target + precision:  >    - PTX + fast + f32 with a fast libdevice variant -> __nv_fast_*f (Phase 3; the  >      .approx hardware path, ftz driven by the nvvm-reflect-ftz flag);  >    - PTX (ieee / f64 / no fast variant) -> precise libdevice __nv_*f / __nv_* (Phase 4);  >    - SPV + fast + f32 with a native variant -> OpenCL native_* ExtInst (Phase 2);  >    - everything else (SPV ieee, f64, generic) -> the precise llvm.* intrinsic.


---
### DEFUN `%SET-NVVM-REFLECT-FTZ`
- **Args**: `(MODULE FTZ-P)`

  > Set the nvvm-reflect-ftz module flag (Override behavior): 1 = flush-to-zero,  >    0 = preserve. llc's NVPTX NVVMReflect pass reads it to resolve libdevice's  >    __nvvm_reflect("__CUDA_FTZ") calls at codegen time.


---
### DEFUN `%PTX-FINALIZE-LIBDEVICE`
- **Args**: `(MODULE)`

  > PTX finalization for libdevice transcendentals. If the module calls any __nv_*  >    (a transcendental lowered to a libdevice symbol): (1) error if it is still an  >    undefined declaration -- libdevice.10.bc was not linked -- and (2) set the  >    nvvm-reflect-ftz module flag from *denormal-handling*.


---
### DEFMACRO `DEF-BINARY-OP-CODEGEN`
- **Args**: `(NODE-TYPE INT-INST FLOAT-INST ACCESSOR-PREFIX)`

---
### DEFMACRO `DEF-UNARY-MATH-CODEGEN`
- **Args**: `(NODE-TYPE INTRINSIC-NAME &OPTIONAL NATIVE-NAME LIBDEVICE-BASE
              LIBDEVICE-FAST-BASE)`

  > Codegen for a unary FP math intrinsic. INTRINSIC-NAME is the precise `llvm.*`  >    used under ieee (and for f64 / generic). NATIVE-NAME (SPV fast f32), LIBDEVICE-BASE  >    (PTX) and LIBDEVICE-FAST-BASE (PTX fast f32) select alternate callees; see  >    %math-call-name.


---
### DEFMACRO `DEF-BINARY-MATH-CODEGEN`
- **Args**: `(NODE-TYPE INTRINSIC-NAME &OPTIONAL NATIVE-NAME LIBDEVICE-BASE
              LIBDEVICE-FAST-BASE)`

  > Endeavor 128: codegen for a binary FP math intrinsic (pow, atan2). Precise  >    `llvm.*` under ieee; SPV fast f32 -> NATIVE-NAME (native_powr, base>=0); PTX ->  >    libdevice LIBDEVICE-BASE; PTX fast f32 -> LIBDEVICE-FAST-BASE. See %math-call-name.


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
### DEFMACRO `DEF-CAST-CODEGEN`
- **Args**: `(NODE-TYPE DOCSTRING ARG-ACCESSOR TYPE-ACCESSOR &BODY BODY)`

---
### DEFUN `%HANDLE-DIE-INTRINSIC`
- **Args**: `(BUILDER MODULE)`

  > Helper: Handles the compiler intrinsic DIE (llvm.trap).


---
### DEFUN `%BUILD-LLVM-FUNCTION-TYPE`
- **Args**: `(MODULE RETURN-TYPE-NAMES PARAM-TYPES)`

  > Helper: Constructs an llvm-function-type and parameter count from a list of return types and parameter types.


---
### DEFUN `%PROPAGATE-CALLEE-CC-TO-CALL`
- **Args**: `(CALL-INST CALLEE-FN-VAL)`

  > If CALLEE-FN-VAL is a function value, copy its calling convention to  >    CALL-INST.  Safe to call even when callee is an arbitrary SSA value  >    (e.g. a function pointer through generate-node-ir) — we only set CC  >    when we have a concrete LLVM value in hand.


---
### DEFUN `%BUILD-FUNCTION-CALL`
- **Args**: `(BUILDER MODULE VAR-ENV DI-BUILDER DI-SCOPE LOCATION-MAP NODE SIG
              CALLEE-NAME LLVM-FN-TYPE PARAM-NODES PARAM-COUNT
              RETURN-TYPE-NAMES)`

  > Helper: Builds the actual function call instruction.  >   >    Overlay change: propagate the callee's calling convention onto the  >    resulting call instruction.  Required on SPV builds — see overlay  >    header for the InstCombine UB bug this fix addresses.


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
### DEFUN `%MV-BUILD-CONST-I64-ARRAY`
- **Args**: `(BUILDER RANK VALUES)`

  > Build an LLVM [rank x i64] constant array from a list of integers.  >    If VALUES is shorter than rank, remaining slots are filled with 0.


---
### DEFUN `%MV-BUILD-ZERO-I64-ARRAY`
- **Args**: `(RANK)`

  > Build a constant all-zero [rank x i64] array.


---
### DEFUN `%MV-BUMP-PTR`
- **Args**: `(BUILDER BASE-PTR OFFSET-BYTES ADDR-SPACE)`

  > GEP base-ptr by offset-bytes (an i64 LLVM value).  >    Returns the new ptr in the same address space.


---
### DEFUN `%MV-BUILD-STORAGE`
- **Args**: `(BUILDER MODULE ADDR-SPACE SRC-PARENT NEW-PTR NEW-BYTESIZE)`

  > Build a new STORAGE_{addr} struct value from ptr and bytesize.


---
### DEFUN `%SV-TO-I64`
- **Args**: `(BUILDER VAL)`

  > Sign-extends VAL to i64 if smaller than 64 bits; returns as-is if already i64.  >    Avoids the invalid sext-to-same-width LLVM instruction.


---
### DEFUN `%SPIRV-GET-OR-CREATE-FN`
- **Args**: `(MODULE FN-NAME LLVM-RET-TYPE PARAM-TYPES PARAM-COUNT)`

  > Gets or creates an LLVM function declaration in MODULE.


---
### DEFUN `%CALL-SPIRV-VEC3-BUILTIN`
- **Args**: `(BUILDER MODULE SPIRV-NAME)`

  > Emits a load from @__spirv_BuiltIn<SPIRV-NAME> addrspace(1) global with zeroinitializer.  >    The LLVM-SPIRV translator maps addrspace(1) globals named __spirv_BuiltIn* to SPIR-V  >    OpVariable BuiltIn decorations.  Using a zeroinitializer (CommonLinkage) suppresses the  >    import linkage that an external declaration generates, preventing the  >    ZE_RESULT_ERROR_INVALID_MODULE_UNLINKED error from Level Zero at runtime.


---
### DEFUN `%CALL-SPIRV-UINT-BUILTIN`
- **Args**: `(BUILDER MODULE SPIRV-NAME)`

  > Emits a call to @__spirv_BuiltIn<SPIRV-NAME>() returning i32 (uint).


---
### DEFUN `%EXTRACT-VEC3-I64`
- **Args**: `(BUILDER VEC-VAL DIM NAME-SUFFIX)`

  > Extracts element at DIM (0/1/2) from a <3 x i64> LLVM value.


---
### DEFUN `%GEN-PRODUCT-OF-VEC3`
- **Args**: `(BUILDER MODULE SPIRV-NAME RESULT-NAME)`

  > Computes x*y*z for the <3 x i64> builtin named SPIRV-NAME.  >    Backend-aware: uses %get-builtin-vec3 for PTX dispatch.


---
### DEFUN `%GEN-FLAT-LINEAR-ID-FROM-VECS`
- **Args**: `(BUILDER LID-VEC LWS-VEC NAME)`

  > Synthesizes z*lws.y*lws.x + y*lws.x + x from two <3 x i64> values.


---
### DEFUN `%GEN-LOCAL-LINEAR-ID`
- **Args**: `(BUILDER MODULE)`

  > Synthesizes get-local-linear-id: z*lws.y*lws.x + y*lws.x + x.  >    Backend-aware: uses %get-builtin-vec3 for PTX dispatch.


---
### DEFUN `%GEN-GLOBAL-LINEAR-ID`
- **Args**: `(BUILDER MODULE)`

  > Synthesizes get-global-linear-id: flat_wg * lws_total + flat_lid.  >    Backend-aware: uses %get-builtin-vec3 for PTX dispatch.


---
### DEFUN `%GEN-SPIRV-WARP-BARRIER`
- **Args**: `(BUILDER MODULE)`

  > Emits @__spirv_ControlBarrier(i32 3, i32 3, i32 264).  >    Scope=Subgroup(3) MemScope=Subgroup(3) Semantics=AcquireRelease(8)|WorkgroupMemory(256).


---
### DEFUN `%GEN-SPIRV-CONTROL-BARRIER`
- **Args**: `(BUILDER MODULE)`

  > Emits @__spirv_ControlBarrier(i32 2, i32 2, i32 264).  >    Scope=Workgroup(2) MemScope=Workgroup(2) Semantics=AcquireRelease(8)|WorkgroupMemory(256).


---
### DEFUN `%GEN-SPIRV-MEMORY-BARRIER`
- **Args**: `(BUILDER MODULE)`

  > Emits @__spirv_MemoryBarrier(i32 1, i32 520).  >    MemScope=CrossWorkgroup(1) Semantics=AcquireRelease(8)|CrossWorkgroupMemory(512).


---
### DEFUN `%CALL-SPIRV-UINT-GLOBAL-BUILTIN`
- **Args**: `(BUILDER MODULE SPIRV-NAME)`

  > Loads from an addrspace(1) i32 global @__spirv_BuiltIn<SPIRV-NAME>.


---
### DEFUN `%PTX-SYNTHESIZE-GLOBAL-ID-VEC3`
- **Args**: `(BUILDER MODULE)`

  > Synthesizes GlobalInvocationId = ctaid * ntid + tid as a <3 x i64>.


---
### DEFUN `%PTX-SYNTHESIZE-GLOBAL-SIZE-VEC3`
- **Args**: `(BUILDER MODULE)`

  > Synthesizes GlobalSize = nctaid * ntid as a <3 x i64>.


---
### DEFUN `%PTX-ZERO-VEC3`
- **Args**: `(BUILDER MODULE)`

  > Returns a <3 x i64> of all zeros (PTX has no GlobalOffset).


---
### DEFUN `%GET-BUILTIN-VEC3`
- **Args**: `(BUILDER MODULE SPIRV-NAME)`

  > Backend-aware vec3 builtin read.  On SPV, delegates to  >    %call-spirv-vec3-builtin.  On PTX, maps SPV names to NVVM  >    special-register intrinsics or synthesizes the value from  >    component registers.


---
### DEFUN `%PTX-SYNCWARP`
- **Args**: `(BUILDER MODULE)`

  > Emits @llvm.nvvm.bar.warp.sync(i32) - PTX bar.warp.sync 0xFFFFFFFF.


---
### DEFUN `%PTX-BARRIER`
- **Args**: `(BUILDER MODULE)`

  > Emits @llvm.nvvm.barrier0() — PTX bar.sync 0 (workgroup barrier).


---
### DEFUN `%PTX-MEMBAR-CTA`
- **Args**: `(BUILDER MODULE)`

  > Emits @llvm.nvvm.membar.cta() — PTX membar.cta (workgroup memory fence).


---
### DEFUN `%PTX-READ-SREG-SCALAR`
- **Args**: `(BUILDER MODULE SREG-BASE DIM)`

  > Reads @llvm.nvvm.read.ptx.sreg.<SREG-BASE>.<X|Y|Z> and zext-promotes  >    the i32 result to i64 (Crisp's ulong contract).  >    SREG-BASE: "tid" / "ntid" / "ctaid" / "nctaid".  >    DIM: 0=x, 1=y, 2=z.


---
### DEFUN `%PTX-READ-SREG-VEC3`
- **Args**: `(BUILDER MODULE SREG-BASE)`

  > Builds a <3 x i64> vector from x/y/z reads of the NVPTX special  >    register family SREG-BASE.  Mirrors the shape of %call-spirv-vec3-builtin  >    so the rest of the gpu-builtin codegen can treat both backends  >    uniformly.


---
### DEFUN `%PTX-READ-WARP-SREG`
- **Args**: `(BUILDER MODULE SREG-NAME)`

  > Reads a single NVPTX warp special register (warpid, laneid) as i32.  >    Unlike %ptx-read-sreg-scalar which zext's to i64, this returns i32  >    to match the SPV uint convention used by warp builtins.


---
### DEFUN `%PTX-SYNTHESIZE-WARP-COUNT`
- **Args**: `(BUILDER MODULE)`

  > Synthesizes warp count per block: ceil(ntid.x * ntid.y * ntid.z / 32).  >    Returns i32 to match SPV uint convention.


---
### DEFUN `%GEN-NVVM-CP-ASYNC-ELEM`
- **Args**: `(BUILDER MODULE DST-PTR SRC-PTR ELEM-BYTES)`

  > Emits @llvm.nvvm.cp.async.ca.shared.global.{4|8|16}(dst, src).  >    ELEM-BYTES picks the right intrinsic variant.


---
### DEFUN `%GEN-NVVM-CP-ASYNC-COMMIT-GROUP`
- **Args**: `(BUILDER MODULE)`

  > Emits @llvm.nvvm.cp.async.commit.group() — closes the current async-copy group  >    (the canonical Ampere cp.async idiom; no mbarrier object required).


---
### DEFUN `%GEN-NVVM-CP-ASYNC-WAIT-GROUP`
- **Args**: `(BUILDER MODULE N)`

  > Emits @llvm.nvvm.cp.async.wait.group(i32 N) — blocks until all but the N most  >    recent async-copy groups have completed.  N=0 waits for every committed group.


---
### DEFUN `%GEN-NVVM-MBARRIER-INIT-SHARED`
- **Args**: `(BUILDER MODULE MBARRIER-PTR COUNT-VAL)`

  > Emits @llvm.nvvm.mbarrier.init.shared(ptr addrspace(3), i32 count).


---
### DEFUN `%GEN-NVVM-CP-ASYNC-MBARRIER-ARRIVE-NOINC-SHARED`
- **Args**: `(BUILDER MODULE MBARRIER-PTR)`

  > Emits @llvm.nvvm.cp.async.mbarrier.arrive.noinc.shared(ptr addrspace(3)).


---
### DEFUN `%GEN-NVVM-MBARRIER-ARRIVE-SHARED`
- **Args**: `(BUILDER MODULE MBARRIER-PTR)`

  > Emits @llvm.nvvm.mbarrier.arrive.shared(ptr addrspace(3)) -> i64 state.


---
### DEFUN `%GEN-NVVM-MBARRIER-TEST-WAIT-SHARED`
- **Args**: `(BUILDER MODULE MBARRIER-PTR STATE-VAL)`

  > Emits @llvm.nvvm.mbarrier.test.wait.shared(ptr addrspace(3), i64 state) -> i1 bool.


---
### DEFVAR `*TMA-MBAR-COUNTER*`

  > Monotonic id source for unique __crisp_mbar_N shared globals (Endeavor 137 TMA).


---
### DEFUN `%COERCE-TO-I32`
- **Args**: `(BUILDER VAL)`

  > Coerces an integer VAL to i32 for a TMA tile-box coordinate: trunc if wider, zext if  >    narrower (coords are non-negative), pass-through if already i32.


---
### DEFUN `%COERCE-TO-I64`
- **Args**: `(BUILDER VAL)`

  > Coerces an integer VAL to i64 (Endeavor 138: a runtime make-view element offset, which is  >    multiplied by the element size to bump the pointer): zext if narrower (offsets are  >    non-negative), trunc if wider, pass-through if already i64.


---
### DEFUN `%GEN-NVVM-TMA-BULK-TENSOR-G2S-2D`
- **Args**: `(BUILDER MODULE DST-SMEM-PTR MBAR-PTR TENSORMAP-PTR COORD0 COORD1)`

  > Emits @llvm.nvvm.cp.async.bulk.tensor.g2s.tile.2d(dst_smem, mbar, tensormap, x, y, mcast,  >    cachehint, flag_mcast, flag_cachehint) ->  >      cp.async.bulk.tensor.2d.shared::cluster.global.tile.mbarrier::complete_tx::bytes  >        [dst], [tensormap, {x, y}], [mbar];  >    DST-SMEM-PTR and MBAR-PTR are addrspace(3); TENSORMAP-PTR is a generic ptr to the 128-byte  >    CUtensorMap; COORD0/COORD1 are i32 tile-box origins (element units).  The trailing multicast  >    / cache-hint flags are immarg 0 (disabled) — Phase 2b may enable a cache hint.


---
### DEFUN `%GEN-NVVM-TMA-MBAR-GLOBAL`
- **Args**: `(MODULE &OPTIONAL (COUNT 1))`

  > Creates a fresh per-CTA SLM mbarrier object: a module-level addrspace(3) global with an undef  >    initializer (shared memory is not statically initialized).  Returns the global value (a ptr  >    addrspace(3) to the FIRST mbarrier).  Endeavor 137: the mbarrier is a plain shared global, so  >    it needs none of the CUtensorMap implicit-arg machinery (that is for the descriptor).  >    Endeavor 138: COUNT > 1 allocates a [COUNT x i64] RING of mbarriers — a single barrier is just  >    a ring of 1, and (ring-get r i) is (base + i*8).


---
### DEFUN `%GEN-NVVM-MBAR-SLOT-PTR`
- **Args**: `(BUILDER MBAR-BASE I)`

  > Address of mbarrier slot I within an mbarrier ring (i8-indexed: each mbarrier is 8 bytes).


---
### DEFUN `%BUILD-INLINE-ASM-CALL`
- **Args**: `(BUILDER RET-TYPE PARAM-TYPES ARG-VALS ASM-STR CONSTRAINTS)`

  > Builds a call to an inline-asm value (Endeavor 137 TMA).  RET-TYPE is the llvm result type  >    (void for a statement).  PARAM-TYPES / ARG-VALS are parallel lists of llvm types / values.  >    ASM-STR uses $0.. operand placeholders (output constraints first).  Always side-effecting  >    (these are barrier/DMA ops), ATT dialect (0).


---
### DEFUN `%GEN-NVVM-FENCE-PROXY-ASYNC-SHARED`
- **Args**: `(BUILDER)`

  > Inline PTX: fence.proxy.async.shared::cta;  Makes the mbarrier.init visible to the async  >    (TMA) proxy before the bulk copy is issued.  Emitted by the leader thread after init.


---
### DEFUN `%GEN-NVVM-MBARRIER-ARRIVE-EXPECT-TX`
- **Args**: `(BUILDER MBAR-ADDR-I32 TX-BYTES-I32)`

  > Inline PTX: mbarrier.arrive.expect_tx.shared::cta.b64 _, [bar], tx;  Announces the expected  >    transaction byte count for the bulk copy that follows.  MBAR-ADDR-I32 is the 32-bit shared  >    address of the mbarrier (ptrtoint of the addrspace(3) ptr); leader-only.


---
### DEFUN `%GEN-NVVM-MBARRIER-TRY-WAIT-PARITY`
- **Args**: `(BUILDER MBAR-ADDR-I32 PHASE-I32)`

  > Inline PTX: try_wait.parity -> i32 (1 if the barrier's phase flipped, else 0).  Wrapped so  >    the caller can spin in an LLVM loop (no label in the asm).


---
### DEFUN `%TMA-LOOKUP-DESCRIPTOR-PTR`
- **Args**: `(BUILDER VAR-ENV SRC-NAME GLOB-PTR-TYPE)`

  > Endeavor 137 Phase 2b: reconstruct the CUtensorMap descriptor implicit-arg name  >    (SRC_TENSORMAP_FROM_FN — the same deterministic name the scan pass registered) and LOAD the  >    descriptor pointer from its var-env slot (implicit params are alloca'd like every param).  >    Returns the ptr (addrspace 1) or NIL if absent (no src symbol / not registered), so the  >    caller falls back to the Phase-2a stand-in.


---
### DEFUN `%GEN-NVVM-READ-TID-X`
- **Args**: `(BUILDER MODULE)`

  > Emits @llvm.nvvm.read.ptx.sreg.tid.x() → i32 (per-thread tid in X).


---
### DEFUN `%GEN-NVVM-READ-TID-Y`
- **Args**: `(BUILDER MODULE)`

  > Emits @llvm.nvvm.read.ptx.sreg.tid.y() → i32.


---
### DEFUN `%GEN-NVVM-READ-TID-Z`
- **Args**: `(BUILDER MODULE)`

  > Emits @llvm.nvvm.read.ptx.sreg.tid.z() → i32.


---
### DEFUN `%GEN-NVVM-READ-NTID-X`
- **Args**: `(BUILDER MODULE)`

  > Emits @llvm.nvvm.read.ptx.sreg.ntid.x() → i32.


---
### DEFUN `%GEN-NVVM-READ-NTID-Y`
- **Args**: `(BUILDER MODULE)`

  > Emits @llvm.nvvm.read.ptx.sreg.ntid.y() → i32.


---
### DEFUN `%GEN-NVVM-READ-NTID-Z`
- **Args**: `(BUILDER MODULE)`

  > Emits @llvm.nvvm.read.ptx.sreg.ntid.z() → i32.


---
### DEFUN `%VECTOR-ELEM-TYPE`
- **Args**: `(TILE-TYPE-SPEC)`

  > Returns the element type symbol from a (vector ELEM ...) or (tensor  >    ELEM ...) type spec, walking through aliases.


---
### DEFUN `%SPIRV-EVENT-TYPE`
- **Args**: `(MODULE)`

  > The target("spirv.Event") LLVM type — the OpTypeEvent used by OpGroupAsyncCopy.


---
### DEFUN `%SPIRV-MANGLE-ELEM`
- **Args**: `(ELEM-TYPE)`

  > Itanium single-char mangle for the element type in the async_work_group_copy name.


---
### DEFUN `%GEN-SPIRV-ASYNC-WORK-GROUP-COPY`
- **Args**: `(BUILDER MODULE DST-AS3 SRC-AS1 NUM-I64 EVENT-IN ELEM-TYPE)`

  > Emit %e = call async_work_group_copy(dst, src, num, event-in) -> spirv.Event.  >    Mangling mirrors clang so llvm-spirv lowers it to OpGroupAsyncCopy.


---
### DEFUN `%GEN-SPIRV-WAIT-GROUP-EVENTS`
- **Args**: `(BUILDER MODULE EVENTS-AS4-PTR)`

  > Emit call wait_group_events(1, events) -> void.  Lowers to OpGroupWaitEvents.


---
### DEFUN `%COOP-TYPE`
- **Args**: `(ELEM-LLVM ROWS COLS USE)`

  > Build target("spirv.CooperativeMatrixKHR", ELEM-LLVM, 3, ROWS, COLS, USE) in the  >    global context (= the module's context, so the type matches).


---
### DEFUN `%COOP-CALL`
- **Args**: `(BUILDER MODULE NAME RET-TYPE PARAM-TYPES ARG-VALS)`

  > Declare (once) NAME : RET-TYPE(PARAM-TYPES…) and build a call with ARG-VALS.


---
### DEFUN `%COOP-PTR-TYPE`
- **Args**: `(&OPTIONAL (AS 1))`

  > ptr addrspace(AS) — memory pointer for coop load/store (global=1, SLM/local=3).


---
### DEFUN `%PTR-AS`
- **Args**: `(PTR-VAL)`

  > The address space of a pointer VALUE (global=1, SLM=3).


---
### DEFUN `%COOP-TENSOR-PTR+STRIDE`
- **Args**: `(BUILDER TENSOR-VAL OROW OCOL LAYOUT)`

  > From a Crisp tensor STRUCT value, return (values element-ptr stride-i64) for the coop  >    tile whose element origin is (OROW, OCOL) — both i64 LLVM values.  Tensor layout: field0  >    = parent storage {ptr,i64}, field2 = strides [N x i64].  Leading dim = strides[0]  >    (RowMajor) / strides[1] (ColMajor).


---
### DEFUN `%COOP-STORE`
- **Args**: `(BUILDER MODULE PTR MATRIX-VAL STRIDE-VAL ELEM-LLVM ROWS COLS USE
              LAYOUT)`

  > Emit CooperativeMatrixStoreKHR(PTR, MATRIX, LAYOUT, STRIDE, 0).


---
### DEFUN `%COOP-LOAD`
- **Args**: `(BUILDER MODULE PTR STRIDE-VAL ELEM-LLVM ROWS COLS USE LAYOUT)`

  > Emit CooperativeMatrixLoadKHR(PTR, LAYOUT, STRIDE, 0) -> coop(elem,rows,cols,use).  >    STRIDE-VAL is an i64 LLVM value (leading dimension in elements).


---
### DEFUN `%COOP-FILL`
- **Args**: `(BUILDER MODULE INIT-VAL ELEM-LLVM ROWS COLS USE)`

  > Construct a coop matrix filled with INIT-VAL (scalar) via __spirv_CompositeConstruct.


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

  > Resolves a Crisp type specifier (simple or parameterized) to an LLVM type.  >    Endeavor 122 Pass 4: (c-handle ...) -> addrspace-0 opaque pointer (the slot).


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
- **Args**: `(MODULE RETURN-TYPES PARAM-NODES &OPTIONAL IS-ENTRY-POINT FN-NAME)`

  > Calculates the LLVM function type, handling parameter explosion.  >    When IS-ENTRY-POINT is non-NIL and *TARGET-BACKEND* is :PTX, demotes  >    shared (addrspace 3) and local (addrspace 5) pointer params to i64  >    so the resulting kernel image will be accepted by the CUDA driver  >    (see header comment in this overlay).  After demotion, runs the  >    PTX-entry verifier as a belt-and-suspenders check.  FN-NAME is used  >    only in the verifier's error message.


---
## File: `C:\Users\cperk\Documents\crisp-man\src\compiler.lisp`

### DEFVAR `*GRID-FUNCTIONS*`

  > Maps grid function name → T.  >    Used to enforce that grid functions can only be called from  >    dispatch contexts (def-kernel or def-grid-function bodies).


---
### DEFUN `RUN-TOOL-COMMAND`
- **Args**: `(ARGS &KEY (LOG-PREFIX ))`

  > Runs a command using uiop:run-program.


---
### DEFUN `RESOLVE-TOOL-EXECUTABLE`
- **Args**: `(TOOL-BASE)`

  > Resolves the path to a tool executable.   >    Prefers bundled version in bin/, falls back to system PATH.  >    Robustness:   >    - Checks versioned suffixes (e.g. llc-21) if base name not in path.  >    - Falls back to bundled tool if system tool is missing even if CRISP_USE_SYSTEM_TOOLS is set.


---
### DEFUN `%EXTRACT-SPIR-KERNEL-INFO`
- **Args**: `(IR-TEXT KERNEL-POS)`

  > Extracts (values func-name define-pos brace-pos) for a kernel-pos in LLVM IR text.


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

  > Inject OpenCL kernel metadata for all SPIR kernels found in IR text.  > Returns modified IR text with metadata.


---
### DEFUN `%OPT-AVAILABLE-P`

  > Returns the resolved opt tool path if findable, NIL otherwise.  >    We probe rather than assume, so machines without opt installed still  >    produce PTX / SPV (just unoptimized).


---
### DEFVAR `*NVPTX-TARGET-INITIALIZED*`

  > Guard so the NVPTX target is registered at most once per image.


---
### DEFUN `%ENSURE-NVPTX-TARGET-INITIALIZED`

  > Register the NVPTX target/MC so LLVMGetTargetFromTriple can resolve  >    nvptx64-nvidia-cuda.  Idempotent.


---
### DEFUN `%MAKE-TARGET-MACHINE-FOR-MODULE`
- **Args**: `(MODULE)`

  > Best-effort TargetMachine from MODULE's triple: NVPTX -> a real TM (target-  >    aware opt/TTI); an unregistered target (e.g. spir64) -> NULL, which is the  >    target-independent behavior opt fell back to on the SPV path anyway.


---
### DEFUN `%RUN-PASSES-IN-PROCESS`
- **Args**: `(INPUT-LL-FILE OUTPUT-LL-FILE PASSES-STRING)`

  > Parse INPUT-LL-FILE into a fresh context, run PASSES-STRING (new pass manager)  >    in-process via the loaded libLLVM, and write the optimized IR to  >    OUTPUT-LL-FILE.  Returns T on success, NIL on any failure (caller falls back  >    to the unoptimized IR).


---
### DEFUN `%RUN-OPT-O3`
- **Args**: `(INPUT-LL-FILE OUTPUT-LL-FILE)`

  > Run default<O3> on INPUT-LL-FILE in-process (libLLVM), writing OUTPUT-LL-FILE.  >    Returns T on success, NIL on failure (caller falls back to unoptimized IR).


---
### DEFPARAMETER `+SPV-OPT-PIPELINE+`

  > Full -O3 pipeline for SPV builds.  Safe now that the call-site CC  >    mismatch (see overlay header) is fixed in `%build-function-call` and  >    `generate-node-ir semantic-funcall` below.


---
### DEFUN `%LL-HAS-SPIRV-ILLEGAL-INT-P`
- **Args**: `(LL-FILE)`

  > T if LL-FILE mentions an integer type iN with N NOT in SPIR-V's legal set  >    {1,8,16,32,64}.  opt's default<O3> can synthesize odd widths (e.g. i33 from the  >    umul-high / (a*b)>>1 idiom) that llvm-spirv rejects with `InvalidBitWidth`.


---
### DEFUN `%RUN-OPT-PIPELINE`
- **Args**: `(INPUT-LL-FILE OUTPUT-LL-FILE PASSES-STRING)`

  > SPV opt (in-process).  Run PASSES-STRING, but if the optimized IR contains a  >    SPIR-V-illegal integer width, discard it and return NIL so the caller falls  >    back to the unoptimized IR — llvm-spirv can't translate e.g. i33, whereas the  >    PTX path (llc/NVPTX) legalizes it fine, so this guard is SPV-only.


---
### DEFUN `%MODULE-USES-COOP-MATRIX-P`
- **Args**: `(MODULE)`

  > T if MODULE declares/calls any __spirv_CooperativeMatrix* builtin (Endeavor 133) — used  >    to add --spirv-ext=+SPV_KHR_cooperative_matrix only when needed.


---
### DEFUN `COMPILE-TO-SPIRV`
- **Args**: `(MODULE OUTPUT-PATH &KEY DEBUG-P)`

  > Compiles an LLVM Module to SPIR-V via opt (full -O3) -> llvm-as -> llvm-spirv.


---
### DEFUN `%REMOVE-DEAD-ARRAY-RETURNING-FUNCTIONS`
- **Args**: `(MODULE)`

  > Scans MODULE for functions whose return type is an LLVM array type  >    ([N x T]) and that have no uses (no callers in this module).  >    Deletes each such function.  >   >    This is Part 2 of the IGC bug 028 workaround.  >    Returns the number of functions deleted.


---
### DEFUN `COMPILE-TO-PTX`
- **Args**: `(MODULE OUTPUT-PATH &KEY (COMPUTE-CAPABILITY sm_80) DEBUG-P)`

  > Compiles an LLVM Module to PTX using llc.  >    Pipeline: IR -> opt -O3 (if available) -> llc -> PTX.  >    COMPUTE-CAPABILITY: Target GPU architecture (sm_50, sm_75, sm_86, etc.)  >                        sm_80 = Ampere (required for endeavor 114's cp.async path).  >                        Pre-Ampere targets can pass an explicit value if needed,  >                        but kernels using request-load-tile / await-request will  >                        fail to compile on anything earlier.


---
### DEFUN `REGISTER-BUILTINS`

  > Registers built-in storage handle templates (storage, cell, tensor) and  >    their system-generated accessor functions.  Called by initialize-compiler.


---
### DEFVAR `*DIFFERENTIABLE-HOF-STORE*`

  > Maps HOF function name to info plist for inline backward differentiation.


---
### DEFVAR `*IMPLICIT-SCRATCH-SIZE-EXPR-MAP*`

  > Maps implicit scratch tensor param-name → size-expr form as written by the user  >    (e.g. :match-warp-tile, 1, 4).  Used by generate-implicit-signature for metadata.


---
### DEFVAR `*KERNEL-DISPATCH-DECLARATIONS*`

  > Maps kernel name symbol → plist of dispatch declarations extracted from def-kernel.  >    Keys: :global-size, :local-size, :num-groups. Values: the raw s-expression forms  >    e.g. :global-size = (global-size :derive-from (width height) :strategy :one-thread-per).


---
### DEFUN `REGISTER-FOREIGN-FUNCTION`
- **Args**: `(C-NAME SIGNATURE &OPTIONAL BACKWARD-NAME)`

  > Registers a (def-foreign-function C-NAME SIGNATURE [BACKWARD-NAME]). SIGNATURE  >    is a Crisp arrow spec, possibly wrapped as (function (...)) from #'(...).  >    Builds a single function-signature in *function-table* (synthetic param names;  >    only the types matter for resolution) and records the verbatim C name in  >    *foreign-functions*.  >   >    Endeavor 123 (FFI-AD): when BACKWARD-NAME is supplied, also wires the foreign  >    function into *differentiable-functions* (via %register-foreign-backward) so a  >    call to it inside a --differentiate kernel routes its backward pass through  >    BACKWARD-NAME (the user-supplied VJP).


---
### DEFUN `%REGISTER-FOREIGN-BACKWARD`
- **Args**: `(C-NAME PARAMS RETURN-TYPES BACKWARD-NAME)`

  > Endeavor 123 (FFI-AD): registers C-NAME in *differentiable-functions* so the  >    backward walk (%handle-sub-fn-call-backward / the void-statement branch ->  >    %emit-foreign-backward) drives the user-supplied VJP BACKWARD-NAME.  >   >    Unlike the sub-function convention (%count-differentiable-contributions, which  >    treats integer scalars as gradient-inert), FFI treats every active scalar  >    input — float AND integer — as differentiable, matching Crisp's kernel-level  >    integer differentiation.  >   >    Stored slots:  >    - :ACTIVE-SCALAR-INDICES — param positions of float/int scalars, in forward  >      order. The VJP returns one gradient per such input (accumulated into that  >      input's adjoint). :N-FLOAT-PARAMS mirrors the count for legacy callers.  >    - :POINTER-PARAM-INDICES — param positions of c-pointer / voidp (active  >      memory) inputs. Each gets a shadow pointer appended to the VJP call,  >      sourced from <storage>_GRAD (Pass 2 shadow routing).  >    - Handles (c-handle) and other types are passive: in neither list, so they  >      contribute no seed, no shadow, and no returned gradient.


---
### DEFUN `%FFI-ACTIVE-SCALAR-PARAM-P`
- **Args**: `(TYPE-SPEC)`

  > T if TYPE-SPEC is an active (differentiable) scalar for FFI VJP purposes:  >    a float-category OR integer-category scalar. Integers are active here (Crisp  >    differentiates them, promoting gradients to float/double), in contrast to the  >    sub-function delta convention which treats integer scalars as inert.


---
### DEFUN `%FFI-POINTER-PARAM-P`
- **Args**: `(TYPE-SPEC)`

  > T if TYPE-SPEC is a c-pointer / voidp (active memory) for FFI shadow routing.  >    voidp is matched by name (it is a convenience alias for a generic c-pointer  >    and may not canonicalize to a (c-pointer ...) head).


---
### DEFVAR `*MATH-PRECISION*`

  > Endeavor 126: active math-precision mode for FP codegen — :ieee (plain, strict FP)  >    or :fast (per-instruction fast-math flags stamped on FP ops). Set by  >    initialize-compiler from --math-precision / --force-math-precision. Default :ieee  >    (PENDING DECISION 2026-07-02): the language's stated default is `fast`, but  >    flipping it globally breaks every numerical-correctness check (HOIST-EXPECT exact  >    output, VERIFY-AUTODIFF finite-difference) — those must run under :ieee. Kept :ieee  >    until we decide precise-default (nvcc/clang style, fast opt-in) vs. fast-default +  >    forcing :ieee for all correctness runs.


---
### DEFVAR `*FORCE-MATH-PRECISION*`

  > Endeavor 126: when non-NIL (:fast/:ieee), the --force-math-precision hard override  >    is active — it LOCKS the precision, so in-source `(declaim (precision …))` and  >    `with-precision` choices are ignored. NIL means no force: declaim (pass 4) /  >    with-precision (pass 5) may set *math-precision*. Precedence:  >    --force > with-precision > declaim > --math-precision > default(:ieee).


---
### DEFVAR `*DENORMAL-HANDLING*`

  > Endeavor 126: subnormal handling for FP codegen — :preserve (strict IEEE gradual  >    underflow) or :ftz (flush subnormals to sign-preserved zero). Orthogonal to  >    *math-precision*. Set by initialize-compiler from --denormal-handling. Stamped as  >    the `denormal-fp-math` function attribute (PTX/NVPTX honours it directly; SPIR-V  >    needs a DenormFlushToZero execution mode, emitted separately). Default :preserve  >    matches the precise (:ieee) default and nvcc (-ftz=false).


---
### DEFVAR `*HARDWARE-PROFILES*`

  > Endeavor 130: upcased profile-name string -> normalized plist of the target's  >    capabilities/limits.  Populated by def-hardware-profile / register-hardware-profile.  >    Cleared per-compile by initialize-compiler (so profiles don't leak across files in  >    the in-process test runner); the current file's def-hardware-profile forms register  >    after that clear.


---
### DEFVAR `*REQUESTED-HARDWARE-PROFILE*`

  > Endeavor 130: profile name (string) requested via --hardware-profile, or NIL.  >    Resolved lazily against *hardware-profiles* by active-hardware-profile.


---
### DEFUN `INITIALIZE-COMPILER`
- **Args**: `(&KEY (LOG-LEVEL OFF) (RUNTIME-CHECKS NIL) (DIFFERENTIATE NIL)
              (MATH-PRECISION IEEE) (FORCE-MATH-PRECISION NIL)
              (DENORMAL-HANDLING PRESERVE) (HARDWARE-PROFILE NIL))`

  > Initializes the compiler state.  >    Extended to clear *grid-functions* for def-grid-function support.


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

  > Injects implicit arguments into the environment for carrier functions.  >    Types in *implicit-arg-map* are already in the correct form:  >    mangled symbols for tensors (no integers to mangle-type-spec),  >    canonical lists for cells (preserved for hoist metadata).  >   >    Endeavor 120: also stamps interprocedurally-inferred :uniform onto the  >    returned parameter-defs. Upgrade-only — it never downgrades a parameter  >    already marked :uniform by an explicit (declare (uniform ...)) or by  >    entry-point status, and it does not touch the stored function signature, so  >    call-site uniformity constraints are unaffected.


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
### DEFUN `%VALIDATE-GRID-FUNCTION-RETURN-TYPE`
- **Args**: `(RETURN-TYPES)`

  > Validates that a grid function has a void return type.  >    Grid functions are void by definition; declaring a return type is an error.


---
## File: `C:\Users\cperk\Documents\crisp-man\src\errors.lisp`

## File: `C:\Users\cperk\Documents\crisp-man\src\hardware-profile.lisp`

### DEFPARAMETER `*HARDWARE-PROFILE-SCHEMA*`

  > Endeavor 130: canonical hardware-profile keys and their value types.  Every key  >    is KNOWN from Phase 0 (so profiles are typo-checked and may be complete); the  >    CONSUMERS that read each key are added phase by phase.  Unknown keys are a  >    compile error; any subset may be specified (missing keys are fine).


---
### DEFUN `%HP-PARSE-SIZE`
- **Args**: `(V)`

  > Parse a size value into bytes: a positive integer, or a size-literal symbol  >    like 227KB / 50MB / 8GB / 2TB.  Returns the byte count, or NIL if unparseable.


---
### DEFUN `%HP-UNQUOTE`
- **Args**: `(V)`

  > Unwrap (quote X) -> X; otherwise return V unchanged.


---
### DEFUN `%HP-3-POS-INTS-P`
- **Args**: `(X)`

  > T if X is a list of exactly 3 positive integers.


---
### DEFUN `%HP-VALIDATE-VALUE`
- **Args**: `(PROFILE-NAME KEY TYPE RAW)`

  > Validate/normalize RAW for KEY of TYPE.  Signals a clear compile error on a  >    malformed value; returns the normalized value (sizes in bytes, lists unquoted).


---
### DEFUN `REGISTER-HARDWARE-PROFILE`
- **Args**: `(NAME PROPLIST)`

  > Endeavor 130 Phase 0: parse, validate, and register a hardware profile.  >    Unknown key -> error; malformed value -> error; duplicate key within one  >    profile -> error; missing keys are fine (a partial profile is valid).  Keyed in  >    *hardware-profiles* by the upcased profile name (package-agnostic).


---
### DEFUN `ACTIVE-HARDWARE-PROFILE`

  > Resolve the requested hardware profile (--hardware-profile) to its normalized  >    plist, or NIL if none was requested.  Errors if a profile was requested but is  >    not registered (a typo'd flag, or a name no def-hardware-profile defines).


---
### DEFUN `%HP-LOCAL-SIZE-DIMS`
- **Args**: `(LOCAL-SIZE-DECL)`

  > Extract concrete (X Y Z) workgroup dims from a (local-size :set-to <val>) decl,  >    normalizing a scalar or short list to three dims.  Returns NIL when the local  >    size is not compile-time-known (:derive-from / :strategy / absent), in which  >    case profile bounds can't be checked.


---
### DEFUN `%HP-CHECK-WORKGROUP-BOUNDS`
- **Args**: `(KERNEL-NAME LOCAL-SIZE-DECL PROFILE)`

  > Endeavor 130 Phase 1: when PROFILE is active and the local size is  >    compile-time-known, error if the workgroup exceeds the profile's  >    :max-total-threads-per-block or any :max-work-group-dims axis.  Missing keys are  >    skipped (a partial profile simply checks less).


---
### DEFUN `%HP-SCRATCH-ELEM-BYTES`
- **Args**: `(ELEM-TYPE)`

  > Bytes per scratch element, matching the hoist's rule (compute-total-shared-bytes):  >    64-bit element types -> 8, everything else -> 4 (the width the launcher reserves).


---
### DEFUN `%HP-KERNEL-SHARED-BYTES`
- **Args**: `(KERNEL-NAME)`

  > Total local (shared) memory bytes a kernel reserves, summed from its implicit  >    scratch signature (matching the hoist's `(* (expt size-expr rank) elem-bytes)`).  >    Returns the byte total, or NIL if any local scratch size is not a compile-time  >    integer (then the bound can't be checked and is skipped).


---
### DEFUN `%HP-CHECK-SHARED-MEMORY`
- **Args**: `(KERNEL-NAME PROFILE)`

  > Endeavor 130 Phase 2: error if KERNEL-NAME's local/shared memory exceeds the  >    profile's :max-shared-memory-per-block.  Skipped if the profile omits that key or  >    the total isn't compile-time-known.


---
### DEFUN `%HP-CHECK-ALL-SHARED-MEMORY`

  > Endeavor 130 Phase 2: after a module compiles (all signatures, incl. implicit  >    scratch, finalized), validate every kernel's local memory against the active  >    hardware profile.


---
### DEFUN `%HP-SERIALIZE-ACTIVE-PROFILE`
- **Args**: `(STREAM)`

  > Emit the active hardware profile (the one --hardware-profile / a topology named)  >    as a top-level metacrisp form, keeping its name.  Values are the normalized  >    (already-parsed) form: sizes in bytes, lists resolved.  Emits nothing when no  >    profile is active.


---
## File: `C:\Users\cperk\Documents\crisp-man\src\hoist-cuda\main.lisp`

### DEFVAR `*MMA-TEST-DIMS*`

  > (M N K) when --mma-test=M,N,K is passed to the hoist; else NIL.


---
### DEFVAR `*MMA-INPUT-COUNTER*`

  > Per-kernel input-tensor counter for A(0)/B(1) role assignment.


---
### DEFVAR `*MMA-SCALE*`

  > Reference scale factor (--mma-scale=S): expected C = S·(A·B).  Default 1.  >    Used by kernels that fire the MMA more than once per fragment (e.g. accum-op body).


---
### DEFVAR `*MMA-BENCH-P*`

  > T when --mma-bench=M,N,K is passed: same setup + C=A·B check as  >    --mma-test, PLUS a warmup + timed relaunch loop reporting GFLOPS.  Since the harness is  >    generated from the metacrisp, it launches EACH kernel with its exact args (incl. the  >    CUtensorMap descriptor for :block) — so sync / :linear / :block are apples-to-apples.


---
### DEFVAR `*MMA-GRID-TILE*`

  > Explicit (TM TN) output-tile override from --grid-tile=T[,TN]; the  >    --mma-bench harness launches a (M/TM x N/TN) 2-D grid.  When NIL the tile is DERIVED from the  >    two local staging tiles (%derive-output-tile).


---
### DEFUN `%MMA-PARSE-ARGS`
- **Args**: `(ARGS)`

  > Return (values metacrisp-path (M N K)-or-NIL scale bench-p grid-tile), extracting --mma-test,  >    --mma-bench (implies test + timing), --mma-scale=S, and --grid-tile=T[,TN].


---
### DEFUN `%DERIVE-OUTPUT-TILE`
- **Args**: `(FULL-SIG)`

  > Endeavor 137: derive the (M-per-wg . N-per-wg) output tile from the two LOCAL staging tiles  >    in the metacrisp.  A-tile is (M-per-wg k-step), B-tile is (k-step N-per-wg) — they share the  >    k-step dim.  Returns (values TM TN) or NIL if it cannot be cleanly identified (caller falls  >    back to --grid-tile / a single workgroup).


---
### DEFUN `%MMA-OUT-DIR-P`
- **Args**: `(DIR)`

  > T if the param direction is an output (&out).


---
### DEFUN `MAIN`

  > Entry point for crisp-hoist-cuda.exe.  Endeavor 134: accepts --mma-test=M,N,K.


---
### DEFVAR `*HOIST-CURRENT-STRUCTS*`

  > Dynamic variable: list of (def-struct NAME ...) forms from the current  >    metacrisp :structs section.


---
### DEFUN `%FIND-STRUCT-DEF`
- **Args**: `(NAME)`

  > Find (def-struct NAME ...) in *hoist-current-structs*.


---
### DEFUN `STRUCT-TYPE-P`
- **Args**: `(TYPE)`

  > Returns T if TYPE names a def-struct in *hoist-current-structs*.


---
### DEFUN `%STRUCT-BASE-TYPE`
- **Args**: `(PARAM-TYPE)`

  > Extract the base struct name from PARAM-TYPE.


---
### DEFUN `%ARRAY-TYPE-P`
- **Args**: `(TYPE)`

  > Returns T if TYPE is an (array T N) form.


---
### DEFUN `%ARRAY-ELEMENT-TYPE`
- **Args**: `(TYPE)`

---
### DEFUN `%ARRAY-SIZE`
- **Args**: `(TYPE)`

---
### DEFUN `%STRUCT-EMIT-FIELDS`
- **Args**: `(STREAM VAR-PATH MEMBERS ALIASES)`

  > Recursively emit C++ field assignments for a struct variable.


---
### DEFUN `RECORD-BASE-TYPE`
- **Args**: `(TYPE)`

  > Extract the base record type symbol.


---
### DEFUN `FIND-RECORD-DEF`
- **Args**: `(TYPE RECORDS)`

  > Find the def-record entry matching TYPE in RECORDS.


---
### DEFUN `RECORD-TYPE-P`
- **Args**: `(TYPE RECORDS)`

  > Returns true if TYPE refers to a def-record in RECORDS.


---
### DEFUN `TENSOR-TYPE-P`
- **Args**: `(PARAM-TYPE)`

  > Returns T if PARAM-TYPE is a tensor/vector/matrix type specifier.


---
### DEFUN `%TENSOR-COMPACT-EXTENTS-STRIDES`
- **Args**: `(N EXTENTS-LIST)`

  > Returns (values extents strides) for a compact N-dim tensor.  >    Strides are in elements; innermost stride = 1.


---
### DEFUN `EMIT-CUDA-DVEC-OSTREAM-OPERATORS`
- **Args**: `(STREAM DVEC-TYPES)`

  > Emit operator<< free functions for device vector types.  >    Unlike the L0 hoist, does NOT emit struct definitions since CUDA already  >    provides them via <cuda.h>.


---
### DEFUN `GENERATE-CUDA-LAUNCHER`
- **Args**: `(METACRISP-PATH)`

  > Generate CUDA Driver API C++ launcher code from metacrisp file.


---
### DEFUN `EMIT-PREAMBLE`
- **Args**: `(STREAM METACRISP-PATH KERNEL-NAME OUTPUT-NAME)`

  > Generate C++ file preamble comment.


---
### DEFUN `EMIT-INCLUDES`
- **Args**: `(STREAM)`

  > Generate C++ includes for CUDA Driver API.


---
### DEFUN `EMIT-TYPEDEFS`
- **Args**: `(STREAM ALIASES)`

  > Generate C++ typedef declarations from type aliases.


---
### DEFUN `EMIT-STRUCTS`
- **Args**: `(STREAM STRUCTS)`

  > Generate C++ struct definitions from metadata (mirrors L0 hoist).


---
### DEFUN `EMIT-HELPERS`
- **Args**: `(STREAM)`

  > Generate C++ helper: read PTX file and CUDA error checking.


---
### DEFUN `EMIT-MAIN`
- **Args**: `(STREAM KERNEL-NAME PTX-PATH DECLARED-SIG ALIASES RECORDS
              &OPTIONAL DISPATCH-INFO COMPUTE-UNITS)`

  > Generate C++ main function for CUDA Driver API launcher.  > COMPUTE-UNITS, when non-NIL, is the active hardware profile's :compute-units and  > overrides the runtime SM-count query in the grid-size heuristic.


---
### DEFUN `EMIT-CUDA-INIT`
- **Args**: `(STREAM)`

  > Emit CUDA Driver API initialization.


---
### DEFUN `EMIT-MODULE-LOADING`
- **Args**: `(STREAM PTX-PATH)`

  > Emit PTX module loading via cuModuleLoadData (JIT).


---
### DEFUN `COMPUTE-TOTAL-SHARED-BYTES`
- **Args**: `(DECLARED-SIG ALIASES)`

  > Sum up all local-memory tensor byte-sizes for the sharedMemBytes launch param.


---
### DEFUN `%CUDA-EMIT-CELL-ARG`
- **Args**: `(STREAM PARAM PARAM-NAME PARAM-TYPE PARAM-DIR IS-LOCAL ALIASES
              ARG-INDEX)`

---
### DEFUN `%CUDA-SCRATCH-DIMS`
- **Args**: `(SIZE-EXPR RANK PARAM-NAME)`

  > Per-dimension extents for a scratch tensor.  :size-expr may be a scalar (a SQUARE  >    tensor: all RANK dims equal it — e.g. make-scratch-matrix float 4 -> 4x4) or a LIST  >    of RANK integers (a non-square tensor — e.g. make-scratch-matrix float (16 8)).


---
### DEFVAR `*CUDA-SHARED-SCRATCH-OFFSET*`

  > Running byte offset into the kernel's dynamic shared memory, assigned to each  >    LOCAL scratch tile in turn so multiple tiles do not alias.  Reset per kernel in  >    emit-kernel-args.


---
### DEFUN `%CUDA-EMIT-LOCAL-SCRATCH-TENSOR-ARG`
- **Args**: `(STREAM PARAM PARAM-NAME PARAM-TYPE ARG-INDEX)`

---
### DEFUN `%CUDA-EMIT-GLOBAL-SCRATCH-TENSOR-ARG`
- **Args**: `(STREAM PARAM PARAM-NAME PARAM-TYPE ARG-INDEX)`

---
### DEFUN `%CUDA-EMIT-TENSOR-ARG`
- **Args**: `(STREAM PARAM PARAM-NAME PARAM-TYPE PARAM-DIR ARG-INDEX
              DISPATCH-INFO)`

---
### DEFUN `%CUDA-EMIT-STRUCT-ARG`
- **Args**: `(STREAM PARAM-NAME PARAM-TYPE ALIASES ARG-INDEX)`

---
### DEFUN `%CUDA-EMIT-RECORD-ARG`
- **Args**: `(STREAM PARAM-NAME PARAM-TYPE RECORDS ALIASES ARG-INDEX)`

---
### DEFUN `%CUDA-EMIT-SCALAR-ARG`
- **Args**: `(STREAM PARAM-NAME PARAM-TYPE ARG-INDEX)`

---
### DEFUN `%CUDA-TENSOR-MAP-DATA-TYPE`
- **Args**: `(ELEM-TYPE)`

  > Maps a Crisp element type to the CU_TENSOR_MAP_DATA_TYPE_* enum for cuTensorMapEncodeTiled.


---
### DEFUN `%CUDA-EMIT-TENSOR-MAP-ENCODE`
- **Args**: `(STREAM PARAM)`

  > Endeavor 137 Phase 2b.3: emit the host cuTensorMapEncodeTiled for a :kind :tensor-map  >    descriptor and copy the 128-byte descriptor to device global (option A), leaving the device  >    pointer in <name> (forward-declared earlier at the descriptor's ABI slot).  References the  >    DESCRIBED tensor's already-emitted host variables (<d>_ptr, <d>_ext<k>, <d>_str<k>).  Uses the  >    innermost-dimension-first convention (globalDim / boxDim reversed vs the row-major extents),  >    matching the nvcc-verified H100 reference.


---
### DEFUN `EMIT-KERNEL-ARGS`
- **Args**: `(STREAM DECLARED-SIG ALIASES RECORDS DISPATCH-INFO)`

  > Emit host-side variable declarations and fill the kernelParams[] array.  >    Returns a list of allocation plists for readback.  >    Bug 034: resets *cuda-shared-scratch-offset* so each kernel's LOCAL tiles get  >    distinct, non-overlapping shared-memory offsets.


---
### DEFUN `%RECORD-FIELD-ARGS`
- **Args**: `(STREAM MEMBERS VAR-PATH ARG-INDEX RECORDS ALIASES)`

  > Recursively emit field initialization for record args.  >    Returns (values new-arg-index list-of-arg-names).


---
### DEFUN `%DISPATCH-SYM-TO-CPP-VAR`
- **Args**: `(SYM)`

  > Convert a dispatch param symbol to C++ variable name.


---
### DEFUN `%TENSOR-LENGTH-CPP-VAR`
- **Args**: `(SYM)`

  > Convert a tensor parameter symbol to its C++ length variable.  >    The CUDA hoist emits 'uint64_t <name>_length = N;' for each tensor param,  >    which we reference at dispatch time.


---
### DEFUN `%NORMALIZE-DERIVE-FROM`
- **Args**: `(RAW)`

  > Normalize :derive-from value into a list:  >      <symbol>           -> (<symbol>)  ;; tensor case  >      (sym1 sym2 ...)    -> (sym1 sym2 ...)  >      nil                -> nil


---
### DEFUN `%DERIVE-FROM-IS-TENSOR-P`
- **Args**: `(RAW)`

  > Returns T if :derive-from was supplied as a bare symbol (tensor name).


---
### DEFUN `EMIT-LAUNCH`
- **Args**: `(STREAM DISPATCH-INFO SHARED-BYTES &OPTIONAL COMPUTE-UNITS
              KERNEL-NAME OUT-TILE)`

  > Emit cuLaunchKernel call with grid/block dims from dispatch-info.  >    OUT-TILE (TM TN), when set (--mma-bench), OVERRIDES the grid with a (M/TM x N/TN) 2-D grid.  >    Supports:  >      :strategy :strided        — max occupancy (cuOccupancyMaxActiveBlocksPerMultiprocessor)  >      :strategy :one-thread-per — grid sized to derive-from source  >      :strategy :exact          — grid sized via derive-from / local-size (or tile-shape if present)  >      :set-to integer/list      — fixed grid  >    And :derive-from can be a single tensor symbol (uses <name>_length) or a list  >    of scalar parameter names (uses <name>_arg).  >    COMPUTE-UNITS, when non-NIL, is the active hardware profile's :compute-units;  >    the :strided strategy then uses that fixed SM count instead of querying the  >    device (CU_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT), so a shrunken profile takes  >    effect host-side.


---
### DEFUN `%CUDA-EMIT-MMA-REFERENCE`
- **Args**: `(STREAM ALLOCATIONS)`

  > Emit a stride-agnostic host reference C = A·B (copy A/B/C back to host, compare).


---
### DEFUN `EMIT-READBACK`
- **Args**: `(STREAM ALLOCATIONS)`

  > Emit cuMemcpyDtoH and print buffer contents.  Endeavor 134: appends host-reference C=A·B.


---
## File: `C:\Users\cperk\Documents\crisp-man\src\hoist-cuda\package.lisp`

## File: `C:\Users\cperk\Documents\crisp-man\src\hoist-l0\main.lisp`

### DEFVAR `*MMA-TEST-DIMS*`

  > (M N K) when --mma-test=M,N,K is passed to the hoist; else NIL.


---
### DEFVAR `*MMA-INPUT-COUNTER*`

  > Per-kernel input-tensor counter for A(0)/B(1) role assignment.


---
### DEFVAR `*MMA-SCALE*`

  > Reference scale factor (--mma-scale=S): expected C = S·(A·B).  Default 1.  >    Used by kernels that fire the MMA more than once per fragment (e.g. accum-op body).


---
### DEFUN `%MMA-PARSE-ARGS`
- **Args**: `(ARGS)`

  > Return (values metacrisp-path (M N K)-or-NIL scale), extracting --mma-test=M,N,K and an  >    optional --mma-scale=S flag.


---
### DEFUN `%MMA-OUT-DIR-P`
- **Args**: `(DIR)`

  > T if the param direction is an output (&out).


---
### DEFUN `MAIN`

  > Entry point for crisp-hoist-l0.exe.  Endeavor 134: accepts --mma-test=M,N,K.


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

  > Generate Level Zero C++ launcher code from metacrisp file.  >    Extended to extract and pass dispatch declarations to generate-cpp-main.


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
### DEFUN `%L0-EMIT-MMA-REFERENCE`
- **Args**: `(STREAM ALLOCATIONS)`

  > Emit a stride-agnostic host reference C = A·B and compare against the device C.


---
### DEFUN `GENERATE-CPP-MAIN`
- **Args**: `(STREAM KERNEL-NAME SPV-PATH DECLARED-SIG ALIASES RECORDS
              &OPTIONAL DISPATCH-INFO)`

  > Generate C++ main.  Endeavor 134: under --mma-test, appends a host-reference C=A·B check.


---
### DEFUN `GENERATE-L0-INIT`
- **Args**: `(STREAM)`

  > Generate Level Zero initialization code


---
### DEFUN `GENERATE-MODULE-LOADING`
- **Args**: `(STREAM SPV-PATH)`

  > Generate SPIR-V module loading code


---
### DEFUN `%DISPATCH-SYM-TO-CPP-VAR`
- **Args**: `(SYM)`

  > Convert a dispatch param symbol (e.g. 'WIDTH or 'width) to C++ variable name 'width_arg'.


---
### DEFUN `%L0-TENSOR-LENGTH-CPP-VAR`
- **Args**: `(SYM)`

  > Convert a tensor parameter symbol to its C++ length variable.  >    The L0 hoist emits 'uint64_t <name>_length = N;' for each tensor param.


---
### DEFUN `%L0-NORMALIZE-DERIVE-FROM`
- **Args**: `(RAW)`

  > Normalize :derive-from value into a list:  >      <symbol>           -> (<symbol>)  ;; tensor case  >      (sym1 sym2 ...)    -> (sym1 sym2 ...)  >      nil                -> nil


---
### DEFUN `%L0-DERIVE-FROM-IS-TENSOR-P`
- **Args**: `(RAW)`

  > Returns T if :derive-from was supplied as a bare symbol (tensor name).


---
### DEFUN `%L0-DIM-TO-GC`
- **Args**: `(DIM LOCAL-VAL)`

  > Convert a dimension value (integer or symbol) to C++ expression for group count.


---
### DEFUN `%L0-EMIT-OCCUPANCY-AND-STRATEGY`
- **Args**: `(STREAM IS-STRIDED IS-INTERLEAVED OCCUPANCY DERIVE-FROM-IS-TENSOR
              DERIVE-FROM)`

  > Emit strategy descriptions and max-occupancy calculation.


---
### DEFUN `%L0-EMIT-GROUP-COUNT`
- **Args**: `(STREAM IS-STRIDED IS-INTERLEAVED IS-EXACT IS-ONE-THREAD-PER
              DISPATCH-DECL SET-TO DERIVE-FROM DERIVE-FROM-IS-TENSOR TILE-SHAPE
              LOCAL-X LOCAL-Y)`

  > Emit group count logic for ze_group_count_t groupCount.


---
### DEFUN `%L0-EMIT-DISPATCH`
- **Args**: `(STREAM GLOBAL-DECL LOCAL-DECL NUM-GROUPS-DECL)`

  > Emit zeKernelSetGroupSize and ze_group_count_t based on dispatch declarations.  >    Supports:  >      :strategy :strided        — max occupancy (zeDeviceGetComputeProperties +  >                                  optional zeKernelGetProperties)  >      :strategy :one-thread-per — grid sized to derive-from source  >      :strategy :exact          — grid sized via derive-from / local-size (or tile-shape if present)  >      :strategy :interleaved    — not yet implemented (default dispatch)  >    :set-to scalar/list       — fixed grid  >    :derive-from can be a single tensor symbol (uses <name>_length) or a list  >    of scalar parameter names (uses <name>_arg).


---
### DEFUN `GENERATE-KERNEL-LAUNCH`
- **Args**: `(STREAM KERNEL-NAME DECLARED-SIG ALIASES RECORDS &OPTIONAL
              DISPATCH-INFO)`

  > Generate kernel creation and launch code. Returns list of USM allocations.  >    Extended to accept dispatch-info plist with :global-size, :local-size, :num-groups.


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
- **Args**: `(N EXTENTS-LIST)`

  > Returns (values extents strides) for a compact N-dim tensor.  >    Strides are in elements; innermost stride = 1.


---
### DEFUN `%L0-EMIT-CELL-ARG`
- **Args**: `(STREAM PARAM PARAM-NAME PARAM-TYPE PARAM-DIR IS-LOCAL ALIASES
              CONTEXT-VAR DEVICE-VAR ARG-INDEX)`

---
### DEFUN `%L0-SCRATCH-DIMS`
- **Args**: `(SIZE-EXPR RANK PARAM-NAME)`

  > Per-dimension extents for a scratch tensor.  :size-expr may be a scalar (a SQUARE  >    tensor: all RANK dims equal it) or a LIST of RANK integers (a non-square tensor,  >    e.g. make-scratch-matrix float (8 16)).


---
### DEFUN `%L0-EMIT-LOCAL-SCRATCH-TENSOR-ARG`
- **Args**: `(STREAM PARAM PARAM-NAME PARAM-TYPE ARG-INDEX)`

---
### DEFUN `%L0-EMIT-GLOBAL-SCRATCH-TENSOR-ARG`
- **Args**: `(STREAM PARAM PARAM-NAME PARAM-TYPE CONTEXT-VAR DEVICE-VAR
              ARG-INDEX)`

---
### DEFUN `%L0-EMIT-TENSOR-ARG`
- **Args**: `(STREAM PARAM PARAM-NAME PARAM-TYPE PARAM-DIR CONTEXT-VAR
              DEVICE-VAR ARG-INDEX DISPATCH-INFO)`

---
### DEFUN `%L0-EMIT-STRUCT-ARG`
- **Args**: `(STREAM PARAM PARAM-NAME PARAM-TYPE ALIASES ARG-INDEX)`

---
### DEFUN `%L0-EMIT-RECORD-ARG`
- **Args**: `(STREAM PARAM PARAM-NAME PARAM-TYPE RECORDS ALIASES ARG-INDEX)`

---
### DEFUN `%L0-EMIT-ARRAY-ARG`
- **Args**: `(STREAM PARAM PARAM-NAME PARAM-TYPE ARG-INDEX)`

---
### DEFUN `%L0-EMIT-SCALAR-ARG`
- **Args**: `(STREAM PARAM-NAME PARAM-TYPE ARG-INDEX)`

---
### DEFUN `GENERATE-KERNEL-ARGUMENTS-WITH-USM`
- **Args**: `(STREAM DECLARED-SIG ALIASES RECORDS CONTEXT-VAR DEVICE-VAR
              DISPATCH-INFO)`

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
### DEFUN `METACRISP-HARDWARE-PROFILE`
- **Args**: `(METACRISP-DATA)`

  > Extract the active hardware profile plist (or NIL) from metacrisp data.  > The plist keeps its :name plus every registered key, e.g.  >   (:name "GPU-A" :COMPUTE-UNITS 132 ...).


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
### DEFCONSTANT `+LLVM-ATTRIBUTE-FUNCTION-INDEX+`

  > LLVMAttributeFunctionIndex (~0u): attribute index for function-level attributes.


---
### DEFCONSTANT `+LLVM-FAST-MATH-NONE+`

---
### DEFCONSTANT `+LLVM-FAST-MATH-ALLOW-REASSOC+`

---
### DEFCONSTANT `+LLVM-FAST-MATH-NO-NANS+`

---
### DEFCONSTANT `+LLVM-FAST-MATH-NO-INFS+`

---
### DEFCONSTANT `+LLVM-FAST-MATH-NO-SIGNED-ZEROS+`

---
### DEFCONSTANT `+LLVM-FAST-MATH-ALLOW-RECIPROCAL+`

---
### DEFCONSTANT `+LLVM-FAST-MATH-ALLOW-CONTRACT+`

---
### DEFCONSTANT `+LLVM-FAST-MATH-APPROX-FUNC+`

---
### DEFCONSTANT `+LLVM-FAST-MATH-ALL+`

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
### DEFMACRO `DEF-FOREIGN-FUNCTION`
- **Args**: `(C-NAME SIGNATURE &OPTIONAL BACKWARD-NAME)`

  > Endeavor 122 (FFI): declares a foreign (C / device-library) function callable  >    from Crisp kernels. C-NAME is the verbatim C symbol; SIGNATURE is a Crisp  >    arrow spec. The definition is supplied by linking a .bc at compile time.  >   >    Endeavor 123 (FFI-AD): the optional BACKWARD-NAME names a user-supplied Crisp  >    def-function that serves as this foreign function's Vector-Jacobian Product  >    (VJP). When present, the foreign function becomes differentiable: a call to it  >    inside a --differentiate kernel routes its backward pass through BACKWARD-NAME.  >    The VJP's signature is mechanically derived from SIGNATURE (primals ++ seeds  >    for active returns ++ shadow pointers for active-memory inputs => one gradient  >    per active scalar input).  >   >    Example:  >      (def-foreign-function my_add #'(float float => float))  >      (def-foreign-function c_cube #'(float => float) c-cube-bwd)  ;; differentiable  >   >    Expands to a registration call (evaluated during the signatures pass), so the  >    call resolves and codegen emits an external declaration + call. No body is  >    generated here.


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

  > Returns T if the type-spec is a storage handle missing a required :c-t property.  >    Canonical 6-tuple (tensor elem N addr aln ct) is complete only when addr and aln  >    are both non-nil; canonical 3-tuple (cell elem addr) is complete only when addr  >    is non-nil.  ct always has a default of :last so it's never the incompleteness  >    trigger.


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
### DEFUN `%SPLIT-KERNEL-INPUTS-OUTPUTS`
- **Args**: `(PARAMS SIGNATURE-TYPES)`

---
### DEFUN `%COMPUTE-BACKWARD-KERNEL-PARAMS`
- **Args**: `(FLAT-INPUTS FLAT-INPUT-TYPES OUTPUTS OUTPUT-TYPES RECORD-SUBS-HT
              REC-GRAD-OUT-PARAMS REC-GRAD-OUT-TYPES PKG INPUTS)`

  > Computes the parameter lists and type lists for the backward (gradient) kernel.  > 085: integer tensor inputs now also receive _GRAD outputs, typed as float tensors  > (64-bit integers → double, all others → float). The backward walk still only  > processes float inputs — integer tensor inputs contribute zero gradient.


---
### DEFUN `%HAS-DIFF-CAPABLE-SCALAR-INPUT-P`
- **Args**: `(FLAT-INPUT-TYPES)`

  > Returns T if flat-input-types contains at least one integer scalar  >    (signed/unsigned), including branded int scalars.  Used by the  >    relaxed gate in %generate-backward-kernel-ast.


---
### DEFUN `%RESOLVE-TENSOR-FORM-CT`
- **Args**: `(TENSOR-FORM TYPE-RESOLVER-FN)`

  > Returns the static :contiguous-term keyword (:last/:first) of TENSOR-FORM,  >    or NIL when it can't be determined.  TYPE-RESOLVER-FN: (sym -> static-type-or-nil).  >    Only works when TENSOR-FORM is a bare symbol (the common case).


---
### DEFUN `%TENSOR-STRIDE-RESOLVE-CT`
- **Args**: `(EXPR TYPE-RESOLVER-FN LOCATION)`

  > Determines the effective CT for expanding a tensor-stride EXPR.  >    Handles both safe and strict variants:  >      - Safe: returns the tensor's static CT, or :last with log:warn if  >        it can't be resolved.  >      - Strict: validates LAYOUT-TAG agrees with the tensor's static CT  >        (when known) and returns the tag-implied CT.


---
### DEFUN `%MAKE-KERNEL-PARAM-TYPE-RESOLVER`
- **Args**: `(PARAMS TYPES)`

  > Returns a closure (sym -> static-type-or-nil) built from the kernel's  >    PARAMS and their declared TYPES.  Used by the AD pre-pass to resolve  >    tensor-stride CT without an env.


---
### DEFUN `%EXPAND-TENSOR-STRIDE-OP`
- **Args**: `(FORM TYPE-RESOLVER-FN LOCATION)`

  > Expand TENSOR-STRIDE form.


---
### DEFUN `%EXPAND-GRID-STRIDE-OP`
- **Args**: `(FORM TYPE-RESOLVER-FN LOCATION)`

  > Expand GRID-STRIDE form.


---
### DEFUN `%EXPAND-LOOP-VECTOR-STRIDE-OP`
- **Args**: `(FORM TYPE-RESOLVER-FN LOCATION)`

  > Expand LOOP-VECTOR-STRIDE form.


---
### DEFUN `%EXPAND-TILE-STRIDE-OP`
- **Args**: `(FORM TYPE-RESOLVER-FN LOCATION)`

  > Expand TILE-STRIDE form.


---
### DEFUN `%EXPAND-HARDWARE-STRIDE-OP`
- **Args**: `(FORM TYPE-RESOLVER-FN LOCATION)`

  > Expand HARDWARE-STRIDE form.


---
### DEFUN `%EXPAND-WORKGROUP-STRIDE-OP`
- **Args**: `(FORM TYPE-RESOLVER-FN LOCATION)`

  > Expand WORKGROUP-STRIDE form.


---
### DEFUN `%EXPAND-LET-STRIDE-OP`
- **Args**: `(FORM TYPE-RESOLVER-FN LOCATION)`

  > Expand LET form, hoisting tile-load/store binding values out of let-bindings.


---
### DEFUN `%EXPAND-STRIDE-MACROS-IN-FORM`
- **Args**: `(FORM TYPE-RESOLVER-FN LOCATION)`

  > Recursively walks FORM and rewrites tensor-stride / grid-stride /  >    loop-vector-stride / tile-stride / hardware-stride / workgroup-stride  >    forms into their expansions.  Endeavor 113: also normalises  >    request-load-tile-at -> load-tile-at and await-request -> nil  >    for the backward pass.


---
### DEFUN `%GENERATE-BACKWARD-KERNEL-AST`
- **Args**: `(NAME PARAMS SIGNATURE-TYPES RAW-BODY)`

  > Generates the def-kernel-exact AST for the backward (gradient) pass.  >    Endeavor 103 Phase A: dyn-binds *record-param-field-adjs* so record-at-  >    boundary accessor calls route adj into the SROA'd field's adj sym.  >    Endeavor 107: pre-expands stride macros (tensor-stride / grid-stride /  >    loop-vector-stride) in the kernel body so AD walks the expansion.


---
### DEFUN `%FOREIGN-C-NAME`
- **Args**: `(SYM)`

  > C name to emit for a foreign-function symbol. Verbatim when the symbol was  >    written with any lowercase character (i.e. escaped, like |myFunc|), otherwise  >    downcased -- the common case, since unescaped Lisp symbols are uppercased on  >    read while C library names are typically lowercase.


---
### DEFUN `PARSE-KERNEL-SIGNATURE`
- **Args**: `(NAME PARAMS BODY)`

  > Parses kernel parameters and body, performing validation and type extraction.  >    Returns (values exploded-params exploded-types reassembly-bindings raw-body other-decls).


---
### DEFMACRO `DEF-KERNEL`
- **Args**: `(NAME PARAMS &REST BODY)`

  > Defines a GPU Kernel (Entry Point).  >      >    Constraint: All parameter types MUST be complete.  >    Incomplete types (missing compile-time properties) are forbidden at the kernel boundary  >    because the host must know the exact layout to marshall arguments.


---
### DEFMACRO `DEF-GRID-FUNCTION`
- **Args**: `(NAME PARAMS &REST BODY)`

  > Defines a grid-level function.  >    Grid functions have a dispatch-level context in their body: they can call both  >    thread-level (def-function) and grid-level functions.  >   >    Unlike def-function:  >    - Cannot return values (void).  >    - Cannot be called from def-function (thread-level context).  >   >    Unlike def-kernel:  >    - Lisp-style naming allowed (dashes ok, case-insensitive).  >    - Supports &optional and &key parameters.  >    - Not an entry point; cannot be enqueued by the host directly.


---
### DEFMACRO `WITH-STRUCT-ACCESSORS`
- **Args**: `(STRUCT-TYPE BINDINGS &BODY BODY)`

  > Iterates over the members of a struct type, binding accessor symbols to the provided variables.  >    Bindings: (aos-var [soa-var] [:access type])  >    Returns a PROGN containing the expanded body forms.


---
### DEFMACRO `DEF-TYPE`
- **Args**: `(NAME TYPE-SPEC)`

  > Defines a type alias.  >    Example: (def-type T int)


---
### DEFMACRO `DEF-HARDWARE-PROFILE`
- **Args**: `(NAME &REST PROPLIST)`

  > Endeavor 130: define a named hardware profile — a property list describing a  >    target's capabilities and limits (SIMD width, register file, shared memory,  >    work-group bounds, MMA shapes, ...) that the compiler uses for validation and,  >    later, optimization.  See docs/topology.md.  Keys and values are validated at  >    compile-toplevel time; unknown keys and malformed values are compile errors.


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
### DEFMACRO `MAKE-ASYNC-BARRIER`
- **Args**: `(&KEY MODE)`

  > Creates an async global->local data-movement barrier.  :mode (:linear/:block) selects  >    the DMA path; omitted => arch-automatic (NVIDIA sm_90+ :block, else :linear; Intel always  >    :linear).  (:type was removed with def-topology — Endeavor 137.)  The analyzer  >    (analyze-make-async-barrier-expression) handles the real semantics and validation — this  >    stub just returns 0 for any CL-level macroexpansion that reaches it.


---
### DEFMACRO `MAKE-ARRIVAL-SYNC-HANDLE`
- **Args**: `(COUNTER COUNT)`

---
### DEFMACRO `ARRIVAL-SYNC-HANDLE-COUNTER`
- **Args**: `(OBJ)`

---
### DEFMACRO `ARRIVAL-SYNC-HANDLE-COUNT`
- **Args**: `(OBJ)`

---
### DEFMACRO `MAKE-ARRIVAL-SYNC`
- **Args**: `(COUNT)`

  > Creates an arrival sync handle using a global atomic counter.


---
### DEFMACRO `SYNC-ARRIVE`
- **Args**: `(HANDLE)`

  > Puts one unit into the sync bucket.


---
### DEFMACRO `SYNC-WAIT`
- **Args**: `(HANDLE)`

  > Blocks until count units have been put into the sync bucket.


---
### DEFMACRO `AWAIT`
- **Args**: `(BARRIER)`

  > Awaits an async barrier.


---
### DEFUN `%RING-COUNT-FROM-KEYS`
- **Args**: `(OP KEY-ARGS)`

  > Extract + validate :ring-count from a make-scratch-*-ring key list.  Must be a positive  >    compile-time integer (it becomes a scratch dimension, which cannot be a runtime value).


---
### DEFMACRO `MAKE-SCRATCH-VECTOR-RING`
- **Args**: `(ELEM DIM &REST KEY-ARGS)`

  > A ring of :ring-count vectors of length DIM — one rank-2 scratch tensor (ring-count DIM).  >    Dim 0 is the ring slot; use (ring-get ring i) to get slot i as a vector.


---
### DEFMACRO `MAKE-SCRATCH-MATRIX-RING`
- **Args**: `(ELEM DIMS &REST KEY-ARGS)`

  > A ring of :ring-count matrices of shape DIMS — one rank-3 scratch tensor (ring-count . DIMS).  >    Dim 0 is the ring slot; use (ring-get ring i) to get slot i as a matrix.


---
### DEFMACRO `MAKE-SCRATCH-TENSOR-RING`
- **Args**: `(ELEM DIMS &REST KEY-ARGS)`

  > A ring of :ring-count tensors of shape DIMS — one rank-(1+N) scratch tensor (ring-count . DIMS).  >    Dim 0 is the ring slot; use (ring-get ring i) to get slot i as a rank-N tensor.


---
### DEFMACRO `LOAD-TILE`
- **Args**: `(SRC TILE GRID-LIST &REST KEY-ARGS)`

  > Helper macro to automatically compute grid index offsets dynamically  >    by scaling the incoming grid-coords by the extents of the tile.


---
### DEFMACRO `STORE-TILE`
- **Args**: `(TILE DEST GRID-LIST &REST KEY-ARGS)`

  > Helper macro to automatically compute grid index offsets dynamically  >    by scaling the incoming grid-coords by the extents of the tile.


---
### DEFMACRO `POSITION-TILE-AT`
- **Args**: `(TILE PARENT GRID-LIST)`

  > Sets the tile to view a sub-region of the parent tensor at the specified coordinates.  >    Updates the tile's parent and offset metadata in place without transferring data.


---
### DEFMACRO `POSITION-TILE`
- **Args**: `(TILE PARENT GRID-LIST)`

  > Sets the tile to view a sub-region of the parent tensor at the specified grid coordinates.  >    Updates the tile's parent and offset metadata in place without transferring data.


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
### DEFUN `LINK-FOREIGN-BITCODE`
- **Args**: `(MODULE BC-FILES)`

  > Endeavor 122 (FFI): parse each .bc in BC-FILES and link it into MODULE so  >    that def-foreign-function calls resolve to real definitions at compile time.  >    Quits with a clear error on read/parse/link failure.


---
### DEFUN `COMPILE-FILES`
- **Args**: `(FILES OUTPUT-FILE DEBUG-P SINGLE-PASS-P TARGETS METADATA-P
              HOIST-TARGETS &OPTIONAL BC-FILES)`

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

### DEFMACRO `DEFINE-FORWARD-ONLY-VALIDATOR`
- **Args**: `(NAME ARGS &BODY BODY)`

  > Like defun, but the resulting function returns T trivially when  >    *differentiate-p* is set.  Use for metadata validators that describe  >    forward-kernel structure — under --differentiate the metacrisp describes  >    the backward kernel with a different shape, so the forward-only check  >    doesn't apply.


---
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
### DEFUN `%EXTRACT-FN-BODY-FROM-IR`
- **Args**: `(IR-CONTENT FN-DEFINE-PREFIX)`

  > Returns the substring of IR-CONTENT covering the body of a function  >    whose `define` line starts with FN-DEFINE-PREFIX (e.g.  >    "define void @measure_distance(").  The body spans from the  >    `define` line through the matching closing `}` at column 0.  >    Returns NIL if no such function found.  >   >    In LLVM IR the function-closing brace is the only `}` that appears at  >    column 0; nested braces (e.g. struct literals) are indented.


---
### DEFUN `VALIDATE-DESCENDANT-DISTANCE`
- **Args**: `(IR-PATH)`

  > Validates descendant substitution: coordinate can substitute for point.  >    Expected: distance_point_point called 2x, distance_coordinate_coordinate called 1x  >    in the FORWARD kernel body (measure_distance).  The check is scoped to  >    the forward kernel so it stays meaningful under --differentiate, where  >    the backward kernel recomputes forward values for chain-rule purposes.


---
### DEFUN `VALIDATE-ANCESTOR-DISTANCE`
- **Args**: `(IR-PATH)`

  > Validates ancestor substitution: point can substitute for coordinate.  >    Expected: distance_coordinate_coordinate called 2x, distance_point_point called 1x  >    in the FORWARD kernel body (measure_distance).  Scoped to the forward  >    kernel for the same reason as validate-descendant-distance.


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

  > Validates backward kernel for 05-not-float.  >    Post 101 endeavor: integer fields are also differentiable (with float-typed  >    _GRAD slots).  x (int) and y (float) both get gradient outputs.  >    Expects: (VP_X VP_Y C C_GRAD &out VP_X_GRAD VP_Y_GRAD) = 14 params = 13 commas.


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

  > Validates the backward grad metacrisp for 01-multiply.  >    Checks: kernel name, physical sig (18 params), declared sig (6 params with  >    correct names and directions), and source path present.


---
### DEFUN `VALIDATE-RECORD-GRAD-METADATA`
- **Args**: `(PATHS)`

  > Validates the backward grad metacrisp for 03-record-at-boundary.  >    Checks: kernel name, physical sig (14 params), declared sig (6 params with  >    correct names and directions), and source path present.


---
### DEFUN `%FIND-STRUCT-DEF`
- **Args**: `(STRUCTS-SECTION NAME)`

  > Finds (def-struct NAME ...) in a list of forms from a :structs section.  > Returns the form or NIL.


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

  > Validates scratch vector propagation IR (updated for 6-tuple tensor names, no access).


---
### DEFUN `VALIDATE-074-03-SCRATCH-TENSOR-PROPAGATION-IR`
- **Args**: `(IR-PATH)`

  > Validates scratch tensor (N=3) propagation IR (updated for 6-tuple tensor names, no access).


---
### DEFUN `VALIDATE-074-04-SCRATCH-MATRIX-PROPAGATION-IR`
- **Args**: `(IR-PATH)`

  > Validates scratch matrix (N=2) propagation IR (updated for 6-tuple tensor names, no access).


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
### DEFUN `VALIDATE-VEC-ADD-GRAD`
- **Args**: `(IR-PATH)`

  > Validates the backward kernel for 01-vec-add (vector addition):  >      - @vec_add_grad is defined  >      - TENSOR_FLOAT_1_GLOBAL_COMPACT type present (gradient tensors, no access in name)  >      - fadd instruction present (addition backward)  >      - idx_GRAD is NOT present (integer scalar filtering)


---
### DEFUN `VALIDATE-VEC-MULTIPLY-GRAD`
- **Args**: `(IR-PATH)`

  > Validates the backward kernel for 02-vec-multiply (vector product rule):  >      - @vec_mult_grad is defined  >      - fmul instruction present  >      - TENSOR_FLOAT_1_GLOBAL_COMPACT type present (no access in name)  >      - idx_GRAD is NOT present


---
### DEFUN `VALIDATE-VEC-MIXED-GRAD`
- **Args**: `(IR-PATH)`

  > Validates the backward kernel for 03-vec-mixed (scalar float + tensor inputs):  >      - @vec_scale_grad is defined  >      - %scale_grad present  >      - TENSOR_FLOAT_1_GLOBAL_COMPACT present (no access in name)  >      - fmul present  >      - idx_GRAD is NOT present


---
### DEFUN `VALIDATE-MATRIX-ADD-GRAD`
- **Args**: `(IR-PATH)`

  > Validates the backward kernel for 04-matrix-add (2D matrix, two indices):  >      - @mat_add_grad is defined  >      - TENSOR_FLOAT_2_GLOBAL_COMPACT type present (no access in name)  >      - fadd present  >      - row_GRAD and col_GRAD are NOT present (integer scalar filtering)


---
### DEFUN `VALIDATE-TENSOR-ADD-GRAD`
- **Args**: `(IR-PATH)`

  > Validates the backward kernel for 05-tensor-add (3D tensor, three indices):  >      - @tensor_add_grad is defined  >      - TENSOR_FLOAT_3_GLOBAL_COMPACT type present (no access in name)  >      - fadd present  >      - d0_GRAD, d1_GRAD, d2_GRAD are NOT present (integer scalar filtering)


---
### DEFUN `VALIDATE-VEC-TRANSCENDENTAL-GRAD`
- **Args**: `(IR-PATH)`

  > Validates the backward kernel for 06-vec-transcendental (sin with cos chain rule):  >      - @vec_sin_grad is defined  >      - @llvm.cos.f32 intrinsic declared and called (derivative of sin is cos)  >      - fmul present (chain rule: cos(x) * adj)  >      - idx_GRAD is NOT present


---
### DEFUN `VALIDATE-VEC-BASIC-SUB-GRAD`
- **Args**: `(IR-PATH)`

  > Validates 081/01-vec-basic-sub-function:  >      - @some_operation_grad is defined (the _GRAD companion)  >      - @vec_sub_op_grad is defined (the backward kernel)  >      - some_operation_grad is called inside vec_sub_op_grad body  >      - fadd present (gradient accumulation)  >      - idx_GRAD NOT present (integer index filtered)


---
### DEFUN `VALIDATE-VEC-CHAIN-DEPTH-GRAD`
- **Args**: `(IR-PATH)`

  > Validates 081/02-vec-chain-depth:  >      - three _GRAD companions defined: some_operation_grad, other_operation_grad, final_operation_grad  >      - @vec_chain_grad backward kernel defined  >      - idx_GRAD NOT present


---
### DEFUN `VALIDATE-MAT-BASIC-SUB-GRAD`
- **Args**: `(IR-PATH)`

  > Validates 081/03-matrix-basic-sub-function:  >      - @scale_and_bias_grad defined  >      - @mat_sub_op_grad defined  >      - 2D gradient tensor type present (TENSOR_FLOAT_2 ... READ-WRITE)  >      - fmul present (product rule for a*b)  >      - row_GRAD and col_GRAD NOT present


---
### DEFUN `VALIDATE-TENSOR-BASIC-SUB-GRAD`
- **Args**: `(IR-PATH)`

  > Validates 081/04-tensor-basic-sub-function:  >      - @combine_grad defined  >      - @tensor_sub_op_grad defined  >      - 3D gradient tensor type present  >      - d0_GRAD, d1_GRAD, d2_GRAD NOT present


---
### DEFUN `VALIDATE-VEC-MVB-SUB-GRAD`
- **Args**: `(IR-PATH)`

  > Validates 081/05-vec-multi-value-return:  >      - @split_op_grad defined (two t_grad inputs, two delta outputs)  >      - @vec_mvb_op_grad defined  >      - split_op_grad called in backward kernel body  >      - idx_GRAD NOT present


---
### DEFUN `VALIDATE-VEC-FAN-OUT-SUB-GRAD`
- **Args**: `(IR-PATH)`

  > Validates 081/06-vec-fan-out:  >      - @some_operation_grad and @augmentation_grad both defined  >      - @vec_fan_op_grad defined  >      - both _GRAD functions referenced (two paths contribute to A_GRAD)  >      - idx_GRAD NOT present


---
### DEFUN `VALIDATE-VEC-MIXED-SUB-GRAD`
- **Args**: `(IR-PATH)`

  > Validates 081/07-vec-mixed-scalar-tensor:  >      - @scale_element_grad defined  >      - @vec_scale_sub_grad defined  >      - scalar scale_GRAD present (float scalar gradient)  >      - TENSOR_FLOAT_1 present (tensor gradient for A_GRAD)  >      - fmul present (product rule for s*a)  >      - idx_GRAD NOT present


---
### DEFUN `VALIDATE-ATOMICRMW-ADD`
- **Args**: `(IR-PATH)`

  > Verifies atomicrmw add (integer fetch-and-add) is present in the IR.  > Used by: 01-atomic-add-cell, 03-atomic-inc-cell.


---
### DEFUN `VALIDATE-ATOMICRMW-SUB`
- **Args**: `(IR-PATH)`

  > Verifies atomicrmw sub (integer fetch-and-sub) is present in the IR.  > Used by: 02-atomic-sub-cell, 04-atomic-dec-cell.


---
### DEFUN `VALIDATE-ATOMICRMW-MIN`
- **Args**: `(IR-PATH)`

  > Verifies atomicrmw min (signed integer fetch-and-min) is present in the IR.  > Used by: 05-atomic-min-cell.


---
### DEFUN `VALIDATE-ATOMICRMW-MAX`
- **Args**: `(IR-PATH)`

  > Verifies atomicrmw max (signed integer fetch-and-max) is present in the IR.  > Used by: 06-atomic-max-cell.


---
### DEFUN `VALIDATE-ATOMICRMW-XCHG`
- **Args**: `(IR-PATH)`

  > Verifies atomicrmw xchg (unconditional exchange) is present in the IR.  > Used by: 07-atomic-xchg-cell, 09-atomic-set-alias.


---
### DEFUN `VALIDATE-ATOMICRMW-FADD`
- **Args**: `(IR-PATH)`

  > Verifies atomicrmw fadd (float fetch-and-add) is present in the IR.  > Used by: 08-atomic-add-float.


---
### DEFUN `VALIDATE-TENSOR-AD-ATOMIC`
- **Args**: `(IR-PATH)`

  > Validates that tensor gradient accumulation in the backward kernel uses atomicrmw fadd.  > Checks:  >   - tensor_ad_atomic_grad function is defined  >   - atomicrmw instruction is present (atomic gradient accumulation)  >   - idx_GRAD is NOT present (integer index is non-differentiable)


---
### DEFUN `%089-FIND-KERNEL`
- **Args**: `(METACRISP-PATH)`

  > Parse metacrisp file and return the first kernel plist.


---
### DEFUN `%089-DECL-STRATEGY=`
- **Args**: `(DECL-VALUE EXPECTED-STRATEGY)`

  > True if the :strategy keyword in DECL-VALUE equals EXPECTED-STRATEGY (string-equal).


---
### DEFUN `%089-CHECK-DISPATCH-KEY`
- **Args**: `(K-DEF KEY EXPECTED-HEAD)`

  > Return the value at KEY in K-DEF, verifying the head symbol name matches EXPECTED-HEAD.


---
### DEFUN `%ENDS-WITH-GRAD-P`
- **Args**: `(NAME)`

  > Returns T if NAME (a string) ends with '_grad' (case-insensitive).


---
### DEFUN `%STRIP-GRAD-SUFFIX`
- **Args**: `(NAME)`

  > Returns NAME with the trailing 5-character '_grad' suffix removed.


---
### DEFUN `VALIDATE-NO-SROA-GRAD-LEAK`
- **Args**: `(METADATA-PATH)`

  > Locks the no-SROA-grad-leak invariant for backward kernels.  >   >    For every entry in the kernel's :declared-signature whose :name ends in  >    '_grad', the name stripped of '_grad' must also appear as an entry's  >    :name in the same declared-signature.  >   >    This catches the failure mode where SROA-expanded scalar components of a  >    compound type (e.g. a tensor's offset/stride/extent/length/parent/byte-size)  >    leak as standalone _grad cells in the backward kernel signature, rather  >    than riding along inside the single logical _grad companion of the  >    compound parameter.  >   >    In the forward (non --differentiate) suite, no _grad entries exist in  >    declared-signature at all, so the validator passes trivially. The same  >    test file therefore locks the invariant under both passes.


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

  > Generates the physical ABI signature from kernel parameters.  >    Records are flattened to primitive scalar entries.  >    Fixed: tensor address-space is at (fourth canonical) in the positional 6-tuple.


---
### DEFUN `VALIDATE-14-PHYSICAL-SIGNATURE`
- **Args**: `(PATHS)`

---
### DEFUN `GENERATE-DECLARED-SIGNATURE`
- **Args**: `(SIG &OPTIONAL DECLARED-PARAMS)`

  > Generates the declared-signature plist for a kernel's metadata.  >    Omits :access — storage handles are always treated as read-write by hoist code.


---
### DEFUN `GENERATE-IMPLICIT-SIGNATURE`
- **Args**: `(SIG DECLARED-PARAMS)`

  > Generates the :implicit-params plist for metadata serialization.  >    Omits :access — storage handles are always treated as read-write by hoist code.


---
### DEFUN `SERIALIZE-KERNELS`
- **Args**: `(OUTPUT-STREAM KERNEL-NAMES &KEY SOURCE OUTPUT-TARGETS)`

  > Emits the (:kernels ...) section of the metacrisp file.  >    Extended to include :global-size, :local-size, :num-groups dispatch declarations.


---
### DEFUN `%BWD-RESOLVE-TYPE`
- **Args**: `(TYPE-SPEC &OPTIONAL NEW-ACCESS)`

  > Resolves TYPE-SPEC alias to its inline form.  >    NEW-ACCESS is accepted for signature compatibility but ignored.


---
### DEFUN `%BWD-FIXUP-DECLARED-TYPES`
- **Args**: `(BWD-K-NAME)`

  > Reads BWD-K-NAME's entry in *kernel-declared-signatures*, resolves  >    aliases to inline types, and updates the entry in place.


---
## File: `C:\Users\cperk\Documents\crisp-man\src\mma.lisp`

### DEFUN `REGISTER-MMA-TYPES`

  > Registers the MMA register-fragment record types.  Called from initialize-compiler  >    AFTER register-builtins (initialize-compiler clrhash-es *crisp-structs* on every  >    init, so a load-time registration would not survive).  >   >    tf32 m16n8k8 register counts: A (16x8) -> 4 regs, B (8x8) -> 2 regs, C/D (16x8) -> 4  >    regs.  tf32 is fp32-stored, so all fragment fields are float.


---
### DEFUN `%SPV-MMA-SHAPE`

  > The (values M N K) cooperative-matrix INSTRUCTION shape for the SPV path.  Vendor-  >    specific: from the active hardware profile's :mma-shapes (first entry) — e.g. Intel  >    BMG tf32 is (8 16 8) — else the NVIDIA default (16 8 8).  So the SAME kernel source  >    picks the right hardware shape per --hardware-profile.  A/B/C coop dims derive from  >    it: A = MxK, B = KxN, C(accumulator) = MxN.


---
### DEFUN `ANALYZE-MAKE-REGISTER-FRAGMENT`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > P1 / F-SPV: (make-register-fragment M N INIT).  :spirv -> a filled accumulator coop  >    matrix; else the NVIDIA %construct-struct record.


---
### DEFUN `%COOP-LAYOUT-OF`
- **Args**: `(TENSOR-NODE)`

  > The coop load/store MemoryLayout for an operand, derived from its tensor type's  >    :contiguous-term (NOT hardcoded): :last (row-major) -> 0 (RowMajor); :first (col-major)  >    -> 1 (ColMajor).  So the layout matches how the matrix is actually stored — the stride  >    in %coop-tensor-ptr+stride follows (s0 for RowMajor, s1 for ColMajor).  NOTE: Intel has  >    no ColumnMajor-B coop builtin, so an Intel B operand must be declared :row-major.


---
### DEFUN `ANALYZE-STORE-FRAGMENT`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > P1 / F-SPV: (store-fragment FRAG DEST (TY TX)).  :spirv -> CooperativeMatrixStoreKHR  >    (accumulator, row-major); else the NVIDIA per-lane writes.


---
### DEFUN `ANALYZE-LOAD-FRAGMENT-A`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > P2 / F-SPV: (load-fragment-a SRC (TY TK)).  :spirv -> CooperativeMatrixLoadKHR (A,  >    16x8, row-major); else the NVIDIA per-lane read.


---
### DEFUN `ANALYZE-LOAD-FRAGMENT-B`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > P2 / F-SPV: (load-fragment-b SRC (TK TX)).  :spirv -> CooperativeMatrixLoadKHR (B,  >    8x8, col-major); else the NVIDIA per-lane read.


---
### DEFUN `ANALYZE-MMA-ACCUMULATE`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > P2 / F-SPV: (mma-accumulate C A B).  Node typed as the accumulator fragment — a coop  >    matrix on :spirv, else the fp32 record.  Codegen forks in the generate-node-ir below.


---
### DEFUN `%EMIT-NVVM-MMA`
- **Args**: `(BUILDER MODULE A-VAL B-VAL C-VAL)`

  > The NVIDIA tf32 m16n8k8 MMA (@llvm.nvvm.mma.m16n8k8.row.col.tf32) — copied from the  >    original src/mma.lisp semantic-mma-accumulate codegen; A-VAL/B-VAL/C-VAL are the fp32  >    fragment records.  Returns (values acc-record nil).


---
### DEFUN `%COOP-MMA`
- **Args**: `(BUILDER MODULE A-VAL B-VAL C-VAL ELEM-LLVM M N K)`

  > Emit CooperativeMatrixMulAddKHR(A, B, C, 0) -> the MxN accumulator coop matrix.


---
### DEFVAR `*REGISTER-TILE-DIMS*`

  > Maps a minted register-tile type symbol -> (list M N); used by store-tile's walk.


---
### DEFUN `%REGISTER-TILE-TYPE-NAME`
- **Args**: `(M N)`

---
### DEFUN `%REGISTER-TILE-TYPE-P`
- **Args**: `(TYPE-NAME)`

  > T if TYPE-NAME is a minted register-tile type.


---
### DEFUN `%ENSURE-REGISTER-TILE-TYPE`
- **Args**: `(M N)`

  > Mint (once) the register-tile-acc-f32-MxN record — (M/16)x(N/8) fragment fields —  >    and record its dims.  Returns the type symbol.


---
### DEFUN `ANALYZE-MAKE-REGISTER-TILE`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > P3a: (make-register-tile T (M N) INIT) -> a record-of-fragments accumulator tile,  >    each fragment initialized to INIT.  Mints the tile type on demand; rewrites to  >    %construct-struct of make-register-fragment fields.


---
### DEFUN `ANALYZE-STORE-TILE-MMA`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > Overload of store-tile: if the source is a register-tile, store each fragment via  >    store-fragment at its (row-tile, col-tile) offset; otherwise delegate to the existing  >    (SLM / async) store-tile analyzer.


---
### DEFUN `%CHECK-MMA-SHAPE`
- **Args**: `(MMA-SHAPE LOCATION)`

  > Validate the (M N K) MMA shape: an int triple, and — if a hardware profile is active —  >    a member of its :mma-shapes (the vendor's supported shape, e.g. Intel (8 16 8)); with  >    NO profile, require the tf32 NVIDIA default (16 8 8).


---
### DEFUN `ANALYZE-MMA-ACCUMULATE-VIA-TILE`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > P3b-1: (mma-accumulate-via-tile (M N K) C-TILE A B) — walk the register C-tile in  >    16x8 fragments and accumulate ONE K-step (K = the shape's K) into each, set!-ing the  >    accumulated tile back.  Bodyless (no accum-op / epilogue yet).


---
### DEFUN `%HEAD-NAME-EQ`
- **Args**: `(HEAD NAME)`

  > T if HEAD is a symbol whose name is NAME (package-insensitive).


---
### DEFUN `%REGISTER-TILE-INIT-FORM-P`
- **Args**: `(FORM)`

  > T if FORM is a (make-register-tile T (M N) INIT) constructor.


---
### DEFUN `%FRAG-MN`

  > Per-fragment (M . N) for register-tile decomposition: the active profile's mma-shape  >    (M N) on :spirv, else NVIDIA 16x8.


---
### DEFUN `%REGISTER-TILE-FRAG-SYMS`
- **Args**: `(VAR M N)`

  > The N per-fragment variable symbols for tile VAR of shape MxN (row-major fragment  >    grid), interned in VAR's package with a `$F<i>' suffix.  Fragment dims are the  >    target's per-fragment (M . N).


---
### DEFPARAMETER `*DEFAULT-MAX-REGISTERS-PER-THREAD*`

  > Fallback per-thread register budget for the register-tile fit-check when no  >    hardware profile pins :max-registers-per-thread.  255 = NVIDIA architectural max.


---
### DEFUN `%REGISTER-TILE-FIT-CHECK`
- **Args**: `(M N LOCATION)`

  > F1 register FIT-CHECK — NVIDIA per-thread register model only.  On :spirv the tile  >    is opaque cooperative matrices (the driver owns register residency), so SKIP.  Else:  >    (M/16)x(N/8) accumulator fragments x 4 fp32 regs <= :max-registers-per-thread.


---
### DEFUN `%SUBST-ACCUM`
- **Args**: `(FORM BINDING-SYM FRAG-VAR ACC-SET)`

  > F3: substitute a mma-accumulate-via-tile body per fragment — the accum-binding symbol  >    BINDING-SYM -> FRAG-VAR, and any (accum-op …) call -> ACC-SET (that fragment's  >    accumulate set!).  Walks FORM structurally (cons-cell recursion, so dotted/improper  >    tails are preserved).


---
### DEFUN `%EMIT-PER-FRAG-ACCUMULATE`
- **Args**: `(A B ENTRY &OPTIONAL ACCUM-BINDING BODY)`

  > Per-fragment expansion of mma-accumulate-via-tile (fragment dims = target per-fragment  >    M/N).  Bodyless: one accumulate set!/frag; with ACCUM-BINDING+BODY: splice the body.


---
### DEFUN `%EMIT-PER-FRAG-STORE`
- **Args**: `(DEST TILE-ID ENTRY)`

  > Per-fragment expansion of (store-tile V DEST (BTY BTX)) — fragment dims = target M/N.


---
### DEFUN `%EMIT-PER-FRAG-FILL`
- **Args**: `(ENTRY VAL)`

  > Per-fragment expansion of (fill-tile V VAL) for a register tile: reset every fragment  >    of V to a fragment-of-VAL (matching make-register-tile's own 16x8 fragment init).


---
### DEFUN `%EXPLODE-REWRITE-BODY-FORM`
- **Args**: `(FORM TILES)`

  > Recursively rewrite body FORM: replace via-tile / store-tile / fill-tile references to  >    any exploded tile in TILES (alist V -> (V m n syms)) with per-fragment progns;  >    otherwise recurse structurally.


---
### DEFUN `%EXPLODE-REGISTER-TILES`
- **Args**: `(LET-EXPR &OPTIONAL LOCATION)`

  > Source->source: explode any (V (make-register-tile T (M N) INIT)) binding in  >    LET-EXPR into N (V$Fi (make-register-fragment 16 8 INIT)) bindings, and rewrite  >    the body's via-tile/store-tile references to V into per-fragment progns.  Runs the  >    register FIT-CHECK per tile.  A no-op (returns LET-EXPR unchanged) when no  >    register-tile binding is present.


---
### DEFUN `ANALYZE-INNER-DIMENSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > (inner-dimension A B) -> the contraction extent K (A is M×K row-major, so K is A's  >    inner/column extent = extents[1]).  Rewrites to (~ (extents~ A) 1).


---
### DEFUN `ANALYZE-OUTER-DIMENSIONS-EXPRESSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > (outer-dimensions A B) => M N.  M = A's outer/row extent (~ (extents~ A) 0);  >    N = B's outer/col extent (~ (extents~ B) 1).  Produces a semantic-values 2-value node.


---
### DEFUN `%MMTS-HEAD-P`
- **Args**: `(FORM)`

  > T if FORM is a matrix-multiply-tile-stride call.


---
### DEFUN `%MMTS-REGISTER-DIMS-MAP`
- **Args**: `(BINDINGS)`

  > Alist var -> (M N) for each register-tile binding in a let's BINDINGS.


---
### DEFUN `%EXPAND-MMTS-REGISTER-IN-FORM`
- **Args**: `(FORM REG-MAP LOCATION)`

  > Rewrite matrix-multiply-tile-stride forms whose C-tile is a register tile (in REG-MAP)  >    to their tile-stride + auto-store lowering with a compile-time (M N) size-list tile-spec,  >    so the generated store-tile/mma are visible to the register-tile SROA explosion.


---
### DEFUN `%EXPAND-MATMUL-TILE-STRIDE-REGISTER-FORMS`
- **Args**: `(LET-EXPR LOCATION)`

  > If LET-EXPR binds register tiles, pre-lower the matrix-multiply-tile-stride forms in its  >    body that target them (endeavor 135).  No-op when no register tile is bound.


---
### DEFUN `ANALYZE-LET-WITH-TILE-EXPLOSION`
- **Args**: `(EXPR ENV CONTEXT LOCATION)`

  > let/let* analyzer wrapper: pre-lower register-tile matrix-multiply-tile-stride (endeavor 135),  >    then explode register-tile bindings into per-fragment mutable variables (register residency,  >    Endeavor 132), then defer to the normal let analysis.


---
### DEFUN `REGISTER-MMA-ANALYZERS`

  > Registers the MMA expression analyzers in *expression-analyzers* for both  >    :crisp-language and :crisp.compiler.  Called from initialize-expression-analyzers  >    (which clrhash-es the table on every compiler init, so a load-time setf would not  >    survive).  Overlay: adds the let/let* wrapper for register-tile residency.


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
### DEFSTRUCT `SEMANTIC-MMA-ACCUMULATE`

---
### DEFSTRUCT `SEMANTIC-EXP`

---
### DEFSTRUCT `SEMANTIC-LOG`

---
### DEFSTRUCT `SEMANTIC-LOG2`

---
### DEFSTRUCT `SEMANTIC-TAN`

---
### DEFSTRUCT `SEMANTIC-ASIN`

---
### DEFSTRUCT `SEMANTIC-ACOS`

---
### DEFSTRUCT `SEMANTIC-ATAN`

---
### DEFSTRUCT `SEMANTIC-POW`

---
### DEFSTRUCT `SEMANTIC-ATAN2`

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
### DEFSTRUCT `SEMANTIC-ATOMIC-RMW`

  > Represents an atomic read-modify-write operation (atomic-add!, atomic-sub!, etc.).  > Returns the value at the location BEFORE the modification (fetch-and-op semantics).  > OP is a keyword: :add :sub :min :max :xchg.  > DELTA-NODE is the value to apply; nil is not used (inc!/dec! use a literal 1).


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
### DEFSTRUCT `SEMANTIC-VALUES`

  > A multi-value producer: TYPE = list of the VALUE-NODES' types; codegen packs them into  >    an LLVM aggregate (get-llvm-return-type + insertvalue), indexed by the let mvb path.


---
### DEFSTRUCT `SEMANTIC-COOP-OP`

  > A SPIR-V cooperative-matrix op (Endeavor 133): fill / load / store.


---
### DEFSTRUCT `SEMANTIC-MAKE-C-HANDLE`

  > Allocates a local slot (alloca) that holds a pointer of HELD-TYPE; the node's  >    value is the slot's address (a c-handle, an addrspace-0 pointer). Pass it to a  >    foreign function expecting a void**; read it back with get-pointer.


---
### DEFSTRUCT `SEMANTIC-GET-POINTER`

  > Loads the held pointer out of a c-handle slot (the value a foreign function  >    wrote into it).


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
### DEFSTRUCT `SEMANTIC-WITH-PRECISION`

  > Endeavor 126 (pass 5): (with-precision (KEY) body...) — per-region precision.  >    Codegen dynamically binds *math-precision* to MODE over the body (unless  >    --force-math-precision locks it), so the body's FP ops carry the region's mode.  >    Value is the last body expression's value (like progn).


---
### DEFSTRUCT `SEMANTIC-TO-WORKGROUP-UNIFORM`

  > Represents a (to-workgroup-uniform ...) expression.


---
### DEFSTRUCT `SEMANTIC-TO-WARP-UNIFORM`

  > Represents a (to-warp-uniform ...) expression.


---
### DEFSTRUCT `SEMANTIC-SIZEOF`

  > Represents a sizeof(type) expression.


---
### DEFSTRUCT `SEMANTIC-GPU-BUILTIN`

  > Represents a GPU built-in function call (e.g. get-global-id, sync-workgroup).  >    BUILTIN-NAME is a keyword: :get-global-id, :sync-workgroup, etc.  >    DIMENSION is NIL for the 3D vector form, or 0/1/2 for the scalar-n form.  >    TYPE is the Crisp return type: 'ulong3, 'ulong, 'uint, or NIL (void).


---
### DEFSTRUCT `SEMANTIC-MAKE-ASYNC-BARRIER`

---
### DEFSTRUCT `SEMANTIC-SPIRV-ASYNC-COPY`

---
### DEFSTRUCT `SEMANTIC-SPIRV-GROUP-WAIT`

---
### DEFSTRUCT `SEMANTIC-NVVM-CP-ASYNC-TILE-COPY`

---
### DEFSTRUCT `SEMANTIC-NVVM-CP-ASYNC-WAIT`

---
### DEFSTRUCT `SEMANTIC-NVVM-TMA-TILE-COPY`

---
### DEFSTRUCT `SEMANTIC-NVVM-TMA-WAIT`

---
### DEFSTRUCT `SEMANTIC-CP-ASYNC-COPY-ELEM`

---
### DEFSTRUCT `SEMANTIC-CP-ASYNC-COMMIT`

---
### DEFSTRUCT `SEMANTIC-MAKE-VIEW`

  > Represents a make-cell/vector/matrix/tensor view construction.  >    Creates a new Storage Handle that reinterprets an existing one.  >    No memory allocation occurs — only a new struct value is built.  >    Fields:  >      type        — result type, e.g. (tensor int 1 :global :read-write :compact)  >      source-node — semantic node for the source storage handle  >      element-type — new element type symbol (e.g. int, float, short)  >      rank        — N: 0=cell, 1=vector, 2=matrix, N=tensor  >      offset      — element offset (non-negative integer, default 0)  >      offset-node — Endeavor 138: a semantic node for a RUNTIME element offset.  When non-NIL it  >                    OVERRIDES `offset` (which is compile-time only, via %mv-eval-integer).  This is  >                    what makes (ring-get ring i) work for a runtime i: a ring slot is just a view  >                    of the ring tensor bumped by i * slot-elems.  >      length      — explicit length (integer) or NIL for auto-compute (vectors only)  >      extents     — list of N integers (matrix/tensor); NIL for cell/auto-vector  >      strides     — explicit strides list or NIL (computed from extents/major)  >      major       — :row or :col (make-matrix only; default :row)  >      source-location


---
### DEFSTRUCT `SEMANTIC-STRIDE-VIEW`

  > A view into an existing 2D tensor with stride/extent/offset computed at runtime.  >    Used for: transpose (swaps row/col dimensions), col (extract 1D column slice),  >    row (extract 1D row slice).  >    Fields:  >      op           — :transpose, :col, or :row  >      source-node  — semantic node for the 2D source matrix  >      index-node   — semantic node for the column/row index (NIL for transpose)  >      type         — result type list, e.g. (tensor int 2 :global :read-write :strided)  >      source-location


---
### DEFSTRUCT `SEMANTIC-DOTIMES`

  > Represents (dotimes (var limit [stride]) body...).  >    var is bound to 0, stride, 2*stride, ... while var < limit.  >    stride-node is NIL when the stride was omitted (emit constant 1).  >    Always returns void.


---
### DEFSTRUCT `SEMANTIC-WHILE`

  > Represents (while condition body...).  >    Returns void.


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
## File: `C:\Users\cperk\Documents\crisp-man\src\struct-definitions.lisp`

### DEFSTRUCT `CRISP-STRUCT-DEFINITION`

  > Stores the definition of a user-defined struct.


---
### DEFSTRUCT `BRAND-DEFINITION`

  > Stores the definition of a branded type declared inside a struct/record.


---
### DEFSTRUCT `TYPE-NODE`

  > Represents a type in the derivation hierarchy (DAG).  >    Used for both 'real' types (scalars, structs) and derived types.


---
### DEFSTRUCT `TEMPLATE-DATA`

  > Stores the definition of a template function.


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

  > Called by the compiler to auto-instantiate templates.  >    compiler-callback is (lambda (form location) ...).  >    Fixed: is-compiling now uses *compiler-session* instead of boundp on symbol-macro.


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
### DEFUN `%VALIDATE-DERIVED-TYPE-REGISTRATION`
- **Args**: `(NEW-TYPE-NAME ORIGINAL-TYPE-NAME SUBST-MODE)`

  > Checks if new-type-name is already registered identically (returns :already-registered),  >    otherwise performs collisions & presence checks, raising an error if anything is invalid.


---
### DEFUN `%UPDATE-DERIVED-TYPE-RELATIONSHIPS`
- **Args**: `(NEW-NODE NEW-TYPE-NAME ORIGINAL-TYPE-NAME SUBST-MODE)`

  > Updates ancestor/descendant relationships in *type-derivation-graph* based on subst-mode.


---
### DEFUN `%REGISTER-DERIVED-IN-CRISP-TYPES`
- **Args**: `(NEW-TYPE-NAME BASE-TYPE)`

  > Registers the derived type in *crisp-types* so type checking and casting work.  >    Derived types have identical memory layout to their base type.


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
### DEFVAR `*FOREIGN-FUNCTIONS*`

  > Endeavor 122 (FFI). Registry of functions declared via def-foreign-function.  > Maps the function-name symbol -> the verbatim C name string to emit (no Crisp  > mangling). Presence here also tells codegen to give the external declaration the  > target-appropriate calling convention so it matches the linked .bc definition.


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

  > The active target backend for compilation.  >    Supported values: :generic, :cpu, :spirv, :ptx.


---
### DEFVAR `*IR-TARGET-ARCH*`

  > The raw --ir-target-arch value as a keyword (e.g. :sm_90, :dg2), or NIL if unset.  >    Use (resolved-target-arch) for the effective arch (applies per-backend defaults).


---
### DEFUN `RESOLVED-TARGET-ARCH`

  > The effective target architecture keyword.  When --ir-target-arch is unset it defaults  >    per backend (Endeavor 137): sm_80 for :ptx, dg2 for :spirv, NIL otherwise.


---
### DEFUN `%ARCH-NAME-STRING`
- **Args**: `(ARCH)`

---
### DEFUN `%ARCH-HAS-PREFIX-P`
- **Args**: `(ARCH PREFIX)`

---
### DEFUN `%ARCH-VENDOR`
- **Args**: `(ARCH)`

  > Vendor of an arch keyword: :nvidia for sm_*, :intel for gen12/dg2/pvc/xe2, else NIL.


---
### DEFUN `%ARCH-SM-NUMBER`
- **Args**: `(ARCH)`

  > Numeric SM level for an sm_NN[a|f] arch (:sm_90 / :sm_90a -> 90), or NIL for non-NVIDIA.  >    Tolerates the architecture-specific `a`/`f` suffix (junk-allowed strips it).


---
### DEFUN `%ARCH-SUPPORTS-BLOCK-P`
- **Args**: `(ARCH)`

  > T if ARCH can realize :mode :block: NVIDIA TMA needs sm_90+; Intel LSC 2D block loads  >    need DG2 or newer (i.e. any Intel arch except Gen12).


---
### DEFUN `PTX-COMPUTE-CAPABILITY-STRING`

  > The llc -mcpu string for the PTX backend, from --ir-target-arch (default sm_80).  >    Endeavor 137: a bare sm_90 request is upgraded to sm_90a — Hopper's architecture-specific  >    features (TMA cp.async.bulk.tensor, wgmma) are gated behind the `a` target variant, and a  >    plain `.target sm_90` PTX JIT-rejects them at cuModuleLoad.  An explicit sm_90a/sm_90f (or  >    any other sm_*) passes through unchanged.


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
### DEFVAR `*INERT-FUNCTIONS*`

  > Set of user functions intentionally skipped from _GRAD generation because  >    they have no differentiable parameters (their gradient is identically  >    zero). Calls to these are gradient-inert and are silently skipped during  >    the AD backward walk -- in contrast to genuinely non-differentiable  >    functions, whose _GRAD generation errored and which must still error if  >    called from a differentiable kernel. Cleared per-module in  >    analyze-signatures-pass.


---
### DEFVAR `*FN-NORMALIZED-INFO*`

  > Per-module map: function name -> plist (:params :body :entry-point-p),  >    captured during analyze-signatures-pass from the macro-expanded  >    def-function forms. Consumed by infer-param-uniformity. Cleared per-module.


---
### DEFVAR `*INFERRED-PARAM-UNIFORMITY*`

  > Per-module map: function name -> alist (param-name . :uniform|:divergent|  >    :unknown), the result of infer-param-uniformity. Applied (upgrade-only) to  >    the body-compilation environment by inject-implicit-arguments. Cleared  >    per-module.


---
### DEFVAR `*UNI-MEET-TABLE*`

  > Dynamic: hash callee-name -> (hash param-name -> accumulated meet state).  >    Bound for the duration of infer-param-uniformity.


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
### DEFUN `%EXPAND-VECTOR-TYPE-SPECIFIER`
- **Args**: `(ELEMENT-TYPE REST-ARGS SPEC)`

---
### DEFUN `%EXPAND-MATRIX-TYPE-SPECIFIER`
- **Args**: `(ELEMENT-TYPE REST-ARGS SPEC)`

---
### DEFUN `%EXPAND-TENSOR-TYPE-SPECIFIER`
- **Args**: `(BASE ELEMENT-TYPE REST-ARGS SPEC)`

---
### DEFUN `%EXPAND-CELL-TYPE-SPECIFIER`
- **Args**: `(BASE ELEMENT-TYPE REST-ARGS SPEC)`

---
### DEFUN `EXPAND-STORAGE-HANDLE-TYPE-SPECIFIER`
- **Args**: `(SPEC)`

  > Expands storage handle type specs into canonical positional forms.  >    Cell   → (cell  elem addr)              [3-tuple].  >    Vector → (tensor elem 1 addr align ct)  [6-tuple, sugar for tensor N=1].  >    Matrix → (tensor elem 2 addr align ct)  [6-tuple, sugar for tensor N=2].  >    Tensor → (tensor elem N addr align ct)  [6-tuple].  >    ct defaults to :last; :row-major/:col-major are matrix-only aliases for :last/:first.


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

  > Checks if two types are equivalent, with alias resolution and template handling.  >    FIX: Always canonicalize list type specs (not just CELL) to strip keyword labels  >    before mangling comparison. This supports def-type aliases for any template type.  >    FIX2: Use %type-spec-equal-p (package-agnostic) for cons-vs-cons case.  >    FIX3: Use compiler-session check instead of broken (boundp '*current-module*).


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

  > Helper: Attempts to instantiate a template if not already instantiated.  >    Returns T if template exists/instantiated successfully, NIL otherwise.  >    FIX3: Use (and *compiler-session* (compiler-session-module *compiler-session*))  >    instead of (boundp '*current-module*) — the latter always returns NIL because  >    *current-module* is a define-symbol-macro, not a defvar special variable.


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

  > Checks if a type specifier is valid.  >    Handles simple types, parameterized types, and function literals/types.  >    Endeavor 122 Pass 4: accepts (c-handle ...).


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
