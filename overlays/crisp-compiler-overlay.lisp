;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;;
;;;; INSTRUCTIONS:
;;;; 1. APPEND new/fixed function definitions to the end of this file.
;;;; 2. Add a comment naming the original file (e.g. ;; src/compiler.lisp).
;;;; 3. Do not modify the original file in src/ until cleanup time.
;;;;
;;;; EMPTY as of 2026-10-27 -- endeavour 195 (atomic-load / atomic-store!) folded into src/ (only the LAST copy
;;;; of %195-vjp-atomic-store was taken; both wrappers merged into their originals, *195-orig-* dropped):
;;;;   * analyzers  -> %195-check-* / %195-analyze-atomic-place, analyze-atomic-load-expression,
;;;;                   analyze-atomic-store!-expression, register-195-atomic-access-analyzers after
;;;;                   analyze-atomic-set!-expression; called at the end of register-ops-analyzers (src/analysis/ops.lisp)
;;;;   * ANF        -> *anf-atomic-op-names* (src/anf-transform.lisp)
;;;;   * codegen    -> %195-atomic-alignment, %195-make-relaxed-device, %195-build-atomic-load / -store after
;;;;                   %184-device-sync-scope; the :load / :store CASE in generate-node-ir semantic-atomic-rmw (src/codegen.lisp)
;;;;   * AD         -> "ATOMIC-STORE!" in %ad-replay-fill-targets / %ad-replay-read-syms; *195-ad-param-types*
;;;;                   (defvar before generate-backward-walk, bound in its outer LET); the %195-* VJP helpers
;;;;                   and their register-vjp block at the end of src/autodiff.lisp
;;;;   * semantic   -> semantic-atomic-rmw docstring (src/semantic.lisp)
;;;;   * bindings   -> LLVMSetAtomicSyncScopeID after LLVMSetOrdering (src/llvm-bindings.lisp)
;;;;   (spec-runner-overlay.lisp -> tests/run-specs.lisp the same day: %195-ptx-lines-with,
;;;;    %195-check-ptx-relaxed, validate-ptx-relaxed-load-store(-shared), validate-spv-relaxed-load-store)
;;;;
;;;; EMPTY as of 2026-10-26 -- endeavour 194 (two-level uniformity) folded into src/ (one copy of each
;;;; definition existed; the six wrappers merged into their originals, *194-orig-* scaffolding dropped):
;;;;   * state, structs, lattice, summaries, (/ tid K) inference -> top of src/analysis/core.lisp, with a
;;;;                          (declaim (special ...)) for the specials internal-compile-function binds
;;;;   * calculate-uniformity-state, %uniformity-join, internal-compile-function (fresh context + summary),
;;;;     analyze-function-call (call-site check)                  -> src/analysis/core.lisp
;;;;   * %194-call-in-scope / -note / -judge-loop / refusals, the if / dotimes / loop-variant / unroll-loop /
;;;;     return-from-loop / to-*-uniform / sync / shuffle / tile checks, analyze-return-expression,
;;;;     analyze-let-expression                                   -> src/analysis/control.lisp
;;;;   * %analyze-set!-simple-variable                            -> src/analysis/structs.lisp
;;;;   * %194-reduced-variables, %analyze-reduce-warp            -> src/analysis/ops.lisp
;;;;   * initialize-compiler calls %194-clear-summaries           -> src/compiler.lisp
;;;;   * the two broadcasts, %194-workgroup-slot / -barrier      -> src/codegen.lisp
;;;;
;;;; EMPTY as of 2026-10-25 -- endeavour 193 (logging-output) folded into src/ (only the LAST copy of each
;;;; re-appended function was taken; wrappers folded into their originals, *193-orig-* scaffolding dropped):
;;;;   * state + helpers   -> the die / log defvars, %193-die-symbol-p, %193-may-die-p, %193-body-dies-directly-p,
;;;;                          %193-parse-size, %193-log-capacity-words; :logging-output / :logging-size on
;;;;                          initialize-compiler (src/compiler.lisp)
;;;;   * analysis          -> %193-compute-may-die-functions (called from propagate-implicit-arguments),
;;;;                          %193-current-function, %193-site-of; analyze-function-call marks callers;
;;;;                          analyze-expression tracks the enclosing site (src/analysis/core.lisp)
;;;;   * analyzers         -> +193-die-id-forms+, analyze-die-expression, %193-log-kind,
;;;;                          analyze-log-message-expression, registered in register-ops-analyzers (src/analysis/ops.lisp)
;;;;   * macros            -> when-thread-is, %193-assert-message, r-t-assert, r-t-assert-0, r-t-output(-0),
;;;;                          is-logging?, is-runtime-checking? (src/macros.lisp; exported/imported in src/package.lisp)
;;;;   * codegen           -> the %193-* die / check / log lowering block replacing %handle-die-intrinsic; die and
;;;;                          the log message in generate-node-ir (semantic-call); %build-function-call,
;;;;                          generate-function-prototype; the die flag in generate-function-body; the die check in
;;;;                          %gen-nvvm-mbarrier-try-wait-parity (src/codegen.lisp)
;;;;   * AD                -> the inactive clause in %active-scalar-vars (src/autodiff.lisp)
;;;;   * metadata          -> %193-serialize-die-sites / -log-sites, called from serialize-kernels (src/metadata.lisp)
;;;;   * reader            -> the `(` reader that records source lines, %193-with-read-file (src/reader.lisp);
;;;;                          used by %read-crisp-forms / %compile-files-single-pass; parse-cli-args (src/main.lisp)
;;;;   * bindings          -> LLVMCountParamTypes, GetParamTypes, CountParams, SetOrdering, GetGlobalParent
;;;;                          (src/llvm-bindings.lisp)
;;;; EMPTY as of 2026-10-24 -- endeavour 192 (cache hints) folded into src/ (only the LAST copy of each
;;;; re-appended function was taken; wrappers folded as one call each, their defvar scaffolding dropped):
;;;;   * :cache parsing      -> +cache-intents+, %cache-intent-keyword, %parse-cache-hint,
;;;;                            %check-cache-hint-address-space, %cache-hint-of-type, and a CACHE clause in
;;;;                            the four %expand-*-type-specifier (src/types/validation.lisp)
;;;;   * hint table          -> *kernel-cache-hint-table*, %kernel-llvm-name, %compute-kernel-cache-hints;
;;;;                            ensure-opencl-kernel-metadata records it (src/codegen.lisp)
;;;;   * post-opt pass       -> the %ll-* / %ptx-* / %spv-cache-controls block + %apply-cache-hints-to-ll,
;;;;                            called from compile-to-ptx (+ptx74) and compile-to-spirv (src/compiler.lisp)
;;;;   * tile ops            -> %refuse-per-operation-cache, called by analyze-load-tile-at-expression /
;;;;                            analyze-store-tile-at-expression (src/analysis/control.lisp) and
;;;;                            analyze-prefetch-tile (src/mma.lisp)
;;;;   * spec validators     -> %spv-cache-control-census + validate-spv-cache-* (src/mma.lisp)
;;;;   (spec-runner-overlay.lisp -> tests/run-specs.lisp the same day: the %c192-* / validate-ptx-cache-*
;;;;    validators)
;;;; Before that, EMPTY as of 2026-10-22 -- endeavour 190 (compile API) folded into src/:
;;;;   * BUG 066 on PTX  -> ensure-opencl-kernel-metadata calls %173-ensure-grad-dispatch-decls on every backend (src/codegen.lisp)
;;;;   * BUG 133         -> %physical-array-split (new), %enumerate-physical-types (src/metadata-val.lisp);
;;;;                        get-physical-width, generate-physical-signature (src/metadata.lisp)
;;;;   (spec-runner-overlay.lisp -> tests/run-specs.lisp the same day: --hoist-kernel=source)
;;;; Before that, EMPTY as of 2026-10-13 -- the "/=" entry in *unsupported-form-hints* folded into src/errors.lisp.
;;;; Before that, 2026-10-12 (later) -- endeavour 185 (math-ops) folded into src/:
;;;;   * overrides          -> analyze-let-expression (src/analysis/control.lisp); register-ops-analyzers,
;;;;                           analyze-mod-expression, analyze-rem-expression (src/analysis/ops.lisp);
;;;;                           %handle-single-value-backward (src/autodiff.lisp); semantic-div written out
;;;;                           in place of its def-binary-op-codegen line (src/codegen.lisp)
;;;;   * analyzers          -> the %185-* / analyze-185-* block before register-ops-analyzers (src/analysis/ops.lisp)
;;;;   * lowering           -> the %185-* block + %hw-lower methods after %hw-sat-interior (src/codegen.lisp)
;;;;   * AD                 -> %185-math-backward (src/autodiff.lisp)
;;;;   * bindings           -> select xor srem urem ashr not enum-attribute frem (src/llvm-bindings.lisp)
;;;; EMPTY as of 2026-10-12 -- adversarial sweep (tests/adversarial/issues.md, Resolved) folded:
;;;;   * c-t struct values (ADV-018) -> validate-and-reorder-struct-args, %split-ct-props-args,
;;;;                                  %member-access-struct-name (src/structs.lisp); analyze-struct-construction,
;;;;                                  analyze-extract/insert-struct-member-expression, get-struct-member-index
;;;;                                  (src/analysis/structs.lisp); generate-node-ir semantic-struct-construction
;;;;                                  (src/codegen.lisp); %generate-struct-accessor (src/macros.lisp);
;;;;                                  types-compatible-p (src/type-checker.lisp); types-assignable-p +
;;;;                                  %ct-qualified-arg-fits-bare-param-p (src/types/hierarchy.lisp)
;;;;   * enums (ADV-005/007)       -> ensure-template-instantiation, %keyword-literal-type->enum (src/templates.lisp);
;;;;                                  ensure-branch-compatibility, %enum-type-for-branch (src/analysis/control.lisp);
;;;;                                  %promote-to-float-adjoint, %ad-enum-type-p, %backward-value-expr (src/autodiff.lisp);
;;;;                                  crisp-unsupported-form-error + *unsupported-form-hints* (src/errors.lisp)
;;;;   * kernel boundary (014/015/019/020) -> %validate-kernel-parameters, marshall-cell/-tensor + helpers
;;;;                                  (src/macros.lisp); %instantiate-callable-template, initialize-templates,
;;;;                                  *explicit-instantiation-names* (src/templates.lisp)
;;;;   * c-t-output (ADV-006)      -> src/macros.lisp
;;;;   * shadowed lets in AD (ADV-001/002) -> anf-transform + %alpha-rename-shadowed-lets (src/anf-transform.lisp)
;;;; Before that, 2026-10-10 -- endeavour 183 (last-man fence; BUG 082) folded: %warp-spec-check-sync
;;;;   (src/analysis/control.lisp) and the three last-man lowerings (src/analysis/ops.lisp).
;;;; Before that, 2026-10-08 -- endeavours 181 (last-man sweep) and 182 (NVIDIA register budget)
;;;; folded into src/:
;;;;   * strided final sweep      -> %181-strided-sweep-form (new), %grid-reduce-last-man-expand,
;;;;                                  %fused-grid-reduce-form, %fused-grid-reduce-dependent-form,
;;;;                                  %implicit-scratch-alloc-form (:match-num-workgroups) (src/analysis/ops.lisp)
;;;;   * profile key              -> *hardware-profile-schema* :stream-occupancy-target (src/hardware-profile.lisp)
;;;;   * occupancy target         -> *kernel-occupancy-targets*, *stream-functions*, *analyzing-function*
;;;;                                  (src/compiler.lisp); %declared-local-size-dims, %parse-occupancy-target-decl,
;;;;                                  internal-def-function binds/parses (src/analysis/core.lisp);
;;;;                                  %expand-loop-vector-stride-form marks the stream (src/analysis/control.lisp)
;;;;   * launch bounds            -> %effective-occupancy-target, %apply-occupancy-bound, called beside
;;;;                                  %apply-cluster-dims-attribute (src/codegen.lisp)
;;;;   * spec validators          -> %ptx-minnctapersm, validate-ptx-minnctapersm-4/-2, validate-ptx-no-minnctapersm
;;;;                                  (src/mma.lisp)

(in-package :crisp.compiler)

;;;; ==========================================================================================
;;;; ENDEAVOUR 196 (matmul contest gaps) -- (a): a narrowing conversion on an MMA store SOURCE.
;;;;
;;;;   (store-tile    (to-half D) C (BTY BTX))       (store-tile    (to-bfloat16 D) C ...)
;;;;   (store-tile-at (to-half D) C (ROW COL))       (store-fragment (to-half F) C (TY TX))
;;;;
;;;; D is an f32 accumulator (register tile or wgmma accumulator).  The conversion is fused into
;;;; the per-lane store: every element read (%extract-struct-member ...) is wrapped in the
;;;; conversion before its set!, so no half copy of the tile exists.  set! keeps its rule that an
;;;; element holds exactly its own type -- the author writes the conversion, on the source.
;;;; ==========================================================================================

;; src/mma.lisp (new helper, before analyze-store-fragment)
(defun %196-peel-store-conversion (src)
  "Endeavour 196.  If SRC is (to-half X) or (to-bfloat16 X), return (values X CONVERT-SYMBOL);
   otherwise (values SRC NIL).  Only these two narrowing conversions are peeled: they are the two a
   16-bit MMA needs on the way out (f32 accumulator -> fp16 / bf16 output).  Anything else is left
   for the ordinary analysis, which refuses a conversion of a whole accumulator."
  (if (and (consp src) (symbolp (first src)) (= (length src) 2)
           (member (symbol-name (first src)) '("TO-HALF" "TO-BFLOAT16") :test #'string=))
      (values (second src) (first src))
      (values src nil)))

;; src/mma.lisp (new helper, before analyze-store-fragment)
(defun %196-wrap-conversion (convert form)
  "Endeavour 196.  (CONVERT FORM) when CONVERT is non-NIL, else FORM unchanged."
  (if convert (list convert form) form))

;; src/mma.lisp
(defun analyze-store-fragment (expr env context location)
  "P1 / F-SPV: (store-fragment FRAG DEST (TY TX)).  :spirv -> CooperativeMatrixStoreKHR
   (accumulator, row-major); else the NVIDIA per-lane writes.

   Endeavour 196: FRAG may be (to-half F) / (to-bfloat16 F).  The conversion wraps each element
   read in the per-lane writes, so it costs one cvt per element at the store and nothing else.
   NVIDIA only: on SPIR-V the store is one CooperativeMatrixStoreKHR of the whole fragment, which
   would need the fragment converted first (OpFConvert on a cooperative matrix) -- not built."
  ;; Endeavour 165 (2b-ii): an optional 4th argument carries the ELEMENT TYPE, supplied by
  ;; the store-tile walks (which know it) and defaulting to FLOAT for a hand-written
  ;; store-fragment.  The alternative -- inferring it from the fragment's own type -- would mean
  ;; analyzing FRAG once to ask, then again inside the rewritten form, and analyzing a form twice
  ;; is not safe in general.
  (destructuring-bind (frag-in dest tile-id &optional (elem 'float)) (cdr expr)
    (multiple-value-bind (frag convert) (%196-peel-store-conversion frag-in)
      (log:debug "196 store-fragment: convert=~a elem=~a target=~a" convert elem *target-backend*)
      (let ((ty (first tile-id)) (tx (second tile-id)))
        (if (eq *target-backend* :spirv)
            (progn
              (when convert
                (error 'crisp-compiler-error
                       :message (format nil "store-fragment / store-tile: (~(~a~) TILE) as a store source is not supported on SPIR-V yet.  The SPIR-V store is one CooperativeMatrixStoreKHR of the whole fragment, so the fragment would have to be converted first (OpFConvert on a cooperative matrix).  It is supported on PTX." convert)
                       :source-location location))
              ;; C(accumulator) = MxN; layout from the dest tensor's :contiguous-term.
              (multiple-value-bind (sm sn sk) (%spv-mma-shape)
                (declare (ignore sk))
                (let ((dnode (analyze-expression dest env context (append location '(2)))))
                  (make-semantic-coop-op
                   :type 'void :kind :store
                   :value-node  (analyze-expression frag env context (append location '(1)))
                   :tensor-node dnode
                   :rows sm :cols sn :use 2 :layout (%coop-layout-of dnode)
                   :ty (analyze-expression `(to-int ,ty) env context (append location '(3)))
                   :tx (analyze-expression `(to-int ,tx) env context (append location '(4)))
                   :source-location location))))
            (flet ((elt-of (i) (%196-wrap-conversion convert `(%extract-struct-member frag-val ,i))))
              (if (eql (%mma-elem-bits elem) 64)
                  ;; fp64 m8n8k4 C/D, decoded from CuTe MMA_Traits<SM80_8x8x4_F64F64F64F64_TN>:
                  ;; CLayout = Layout<Shape<Shape<_4,_8>,_2>, Stride<Stride<_16,_1>,_8>> gives
                  ;; m = lane/4 and n = 2*(lane%4) + v for v in {0,1}.  Same column scheme as the
                  ;; tf32 fragment below (two adjacent columns at 2*(lane%4)); it differs only in
                  ;; having ONE row per lane instead of the g / g+8 pair, over a tile 8 rows tall.
                  (analyze-expression
                   `(let ((frag-val ,frag))
                      (let ((lane (to-int (warp-lane))))
                        (let ((g (/ lane 4)) (t2 (* 2 (rem lane 4))))
                          (let ((row (+ (* ,ty 8) g)) (col (+ (* ,tx 8) t2)))
                            (set! (~ ,dest row col)       ,(elt-of 0))
                            (set! (~ ,dest row (+ col 1)) ,(elt-of 1))))))
                   env context location)
                  (analyze-expression
                   `(let ((frag-val ,frag))
                      (let ((lane (to-int (warp-lane))))
                        (let ((g (/ lane 4)) (t2 (* 2 (rem lane 4))))
                          (let ((row (+ (* ,ty 16) g)) (col (+ (* ,tx 8) t2)))
                            (set! (~ ,dest row col)             ,(elt-of 0))
                            (set! (~ ,dest row (+ col 1))       ,(elt-of 1))
                            (set! (~ ,dest (+ row 8) col)       ,(elt-of 2))
                            (set! (~ ,dest (+ row 8) (+ col 1)) ,(elt-of 3))))))
                   env context location))))))))

;; src/mma.lisp (new helper, before %explode-rewrite-body-form)
(defun %196-convert-store-fragment-sources (form convert)
  "Endeavour 196.  Wrap the FRAG argument of every (store-fragment FRAG ...) in FORM with
   (CONVERT FRAG).  Applied to %emit-per-frag-store's expansion, which is the only producer of
   store-fragment forms there, so the per-fragment store logic (static arms, 2-D warp grid) is
   reused untouched rather than copied with a conversion parameter threaded through it."
  (cond
    ((not (consp form)) form)
    ((and (symbolp (first form)) (string= (symbol-name (first form)) "STORE-FRAGMENT"))
     (list* (first form) (list convert (second form)) (cddr form)))
    (t (mapcar (lambda (f) (%196-convert-store-fragment-sources f convert)) form))))

;; src/mma.lisp -- WRAPPER around %explode-rewrite-body-form.  FOLD: add the clause to the original's
;; COND right after its STORE-TILE clause and drop *196-orig-explode-rewrite-body-form*.
;; Wrapped via fdefinition per the let/funcall wrapper trap.
(defvar *196-orig-explode-rewrite-body-form* (fdefinition '%explode-rewrite-body-form))
(defun %explode-rewrite-body-form (form tiles)
  "Endeavour 196 wrapper: (store-tile (to-half V) DEST (BTY BTX)) on an exploded register tile V
   expands exactly as (store-tile V DEST ...) does, with every emitted store-fragment's FRAG wrapped
   in the conversion.  Every other form goes to the original, which recurses back through this
   name."
  (if (and (consp form) (symbolp (first form)) (%head-name-eq (first form) "STORE-TILE")
           (= (length form) 4))
      (multiple-value-bind (v convert) (%196-peel-store-conversion (second form))
        (if (and convert (assoc v tiles))
            (progn
              (log:debug "196 explode: store-tile (~a ~a) -> per-fragment stores" convert v)
              (%196-convert-store-fragment-sources
               (%emit-per-frag-store (third form) (fourth form) (assoc v tiles))
               convert))
            (funcall *196-orig-explode-rewrite-body-form* form tiles)))
      (funcall *196-orig-explode-rewrite-body-form* form tiles)))

;; src/mma.lisp
(defun %wgmma-store-rewrite-origin (tile dest row-origin col-origin n &optional convert)
  "Store the m64xN wgmma accumulator TILE into DEST with its top-left element at
   (ROW-ORIGIN COL-ORIGIN), both absolute element indices.

   Lane mapping (= wgmma_ref.cu, unchanged): warp w within the warpgroup owns rows
   [16w, 16w+16); within a warp, lane -> row lane/4 and column pair (lane mod 4)*2; each n8
   group contributes the standard mma m16n8 C fragment at rows r0 and r0+8.

   Both origins are coerced with TO-INT.  The lane arithmetic is INT throughout (wgw and rlo come
   from to-int of warp-id / warp-lane), so a ULONG origin -- which is what any tile-stride grid
   binding produces, e.g. (* grid-y (to-ulong 128)) -- would otherwise fail to type-check with
   \"Cannot operate on ULONG and INT\".  The grid-index caller has always passed an INT for the same
   reason; this makes the absolute spelling accept either.

   ENDEAVOUR 154: emission order is ROW-MAJOR.  The natural loop is j-outer, which interleaves r0
   and r8 and writes the tile column-strip by column-strip -- 32 passes revisiting the same two
   rows.  Emitting all of row r0 and then all of row r8 lets each WARP lay down a full contiguous
   row (4 lanes x 2 floats x n8 groups) before moving on.  Pure reordering: same stores, same
   values, same addresses.  Measured on an H100 NVL, interleaved, 3 reps: +1.5% at 2048, +0.7% at
   4096, +0.5% at 1024, neutral at 256/512, nothing regressing.

   ENDEAVOUR 196: optional CONVERT (TO-HALF / TO-BFLOAT16 symbol) wraps every element read, for
   (store-tile (to-half D) C ...) -- an f32 accumulator stored into a 16-bit matrix."
  (let* ((to-int (intern "TO-INT" (find-package :crisp-language)))
         (n8 (floor n 8)))
    (flet ((elt-of (i) (%196-wrap-conversion convert `(%extract-struct-member wgv ,i))))
      `(let ((wgv ,tile))
         (let ((wgw (rem (,to-int (warp-id)) 4))
               (lane (,to-int (warp-lane))))
           (let ((rlo (/ lane 4)) (col (* (rem lane 4) 2)))
             (let ((r0 (+ (+ (,to-int ,row-origin) (* wgw 16)) rlo)))
               (let ((r8 (+ r0 8))
                     (c0 (+ (,to-int ,col-origin) col)))
                 (progn
                   ,@(append
                      (loop for j below n8
                            for base = (* j 4)
                            append (list
                                    `(set! (~ ,dest r0 (+ c0 ,(* 8 j)))         ,(elt-of (+ base 0)))
                                    `(set! (~ ,dest r0 (+ (+ c0 ,(* 8 j)) 1))   ,(elt-of (+ base 1)))))
                      (loop for j below n8
                            for base = (* j 4)
                            append (list
                                    `(set! (~ ,dest r8 (+ c0 ,(* 8 j)))         ,(elt-of (+ base 2)))
                                    `(set! (~ ,dest r8 (+ (+ c0 ,(* 8 j)) 1))   ,(elt-of (+ base 3)))))))))))))))

;; src/mma.lisp
(defun %wgmma-store-rewrite (tile dest tile-id n &optional convert)
  "Store the m64xN wgmma accumulator TILE to DEST at grid tile-id (BTY BTX).  warp w (within the
   warpgroup) -> rows [16w,16w+16); per n8 group the standard mma m16n8 C fragment.  (= wgmma_ref.cu.)

   ENDEAVOUR 154: a thin caller of %wgmma-store-rewrite-origin with the TILE-GRID origin
   (bty*64, btx*N).  Behaviour is unchanged -- deliberately, since addressing a tile by grid index
   only identifies a 64-row tile when ONE warpgroup owns it.  Two cooperating warpgroups use
   store-tile-at with explicit origins instead.

   ENDEAVOUR 196: optional CONVERT is passed through (see %wgmma-store-rewrite-origin)."
  (let ((to-int (intern "TO-INT" (find-package :crisp-language))))
    (%wgmma-store-rewrite-origin
     tile dest
     `(* (,to-int ,(first tile-id)) 64)
     `(* (,to-int ,(second tile-id)) ,n)
     n
     convert)))

;; src/mma.lisp (new helper, before analyze-store-tile-mma)
(defun %196-refuse-converted-non-accumulator (op convert src-type location)
  "Endeavour 196.  (store-tile (to-half X) ...) where X is not an MMA accumulator: refuse here,
   naming the rule, rather than let the generic store analyze (to-half X) as a scalar cast of a
   whole tile (which fails later with an unrelated message)."
  (error 'crisp-compiler-error
         :message (let ((*print-pretty* nil)) (format nil "~(~a~): (~(~a~) X) as a store source needs X to be an MMA accumulator (a register tile or a wgmma accumulator), whose f32 elements are converted as they are stored.  X here is ~a.  To convert a scratch or global tile, convert its elements where they are written." op convert src-type))
         :source-location location))

;; src/mma.lisp
(defun analyze-store-tile-mma (expr env context location)
  "store-tile overload: register-tile (mma.sync) OR wgmma-accumulator (Endeavor 140) OR delegate.
   Endeavour 196: the source may be (to-half TILE) / (to-bfloat16 TILE) for either accumulator kind.
   (An exploded register tile never reaches here -- %explode-rewrite-body-form handles it -- so the
   register-tile branch below is the un-exploded path.)"
  (multiple-value-bind (src convert) (%196-peel-store-conversion (second expr))
    (let* ((src-node (analyze-expression src env context (append location '(1))))
           (src-type (semantic-node-type src-node)))
      (log:debug "196 store-tile: src-type=~a convert=~a" src-type convert)
      (cond
        ((%wgmma-acc-type-p src-type)
         (let ((n (second (gethash src-type *wgmma-acc-dims*))))
           (analyze-expression (%wgmma-store-rewrite src (third expr) (fourth expr) n convert)
                               env context location)))
        ((%register-tile-type-p src-type)
         (destructuring-bind (m n &optional (elem 'float)) (gethash src-type *register-tile-dims*)
           (let* ((tile    src)
                  (dest    (third expr))
                  (tile-id (fourth expr))
                  (to-int-sym (intern "TO-INT" (find-package :crisp-language)))
                  (bty (list to-int-sym (first tile-id)))
                  (btx (list to-int-sym (second tile-id)))
                  (fmn (%acc-frag-mn elem))
                  (m-frags (floor m (car fmn))) (n-frags (floor n (cdr fmn))))
             (analyze-expression
              `(let ((tv ,tile))
                 (progn
                   ,@(loop for mi below m-frags
                           append (loop for nj below n-frags
                                        for idx = (+ (* mi n-frags) nj)
                                        collect `(store-fragment ,(%196-wrap-conversion
                                                                   convert
                                                                   `(%extract-struct-member tv ,idx))
                                                                 ,dest
                                                                 ((+ (* ,bty ,m-frags) ,mi)
                                                                  (+ (* ,btx ,n-frags) ,nj))
                                                                 ,elem)))))
              env context location))))
        (convert
         (%196-refuse-converted-non-accumulator "store-tile" convert src-type location))
        (t
         (analyze-store-tile-expression expr env context location))))))

;; src/mma.lisp
(defun analyze-store-tile-at-mma (expr env context location)
  "store-tile-at overload: wgmma-accumulator at an absolute (ROW COL) origin, OR delegate to the
   ordinary cooperative store-tile-at path.

   ENDEAVOUR 154.  %wgmma-store-rewrite computes its row base as `bty * 64`, the wgmma
   instruction's fixed M, which silently bakes in ONE WARPGROUP: with a second consumer warpgroup
   the row base is unchanged and both would write the SAME 64 rows.  A cooperative 128x256 tile
   (two warpgroups splitting M, sharing one B tile) was therefore not expressible -- store-tile-at
   looked like the escape hatch but had no wgmma overload and fell through to the cooperative
   element-loop path.  The two-warpgroup kernel now writes its row offsets explicitly:

     (:consumer0 ... (store-tile-at D C ((* grid-y 128)        (* grid-x 256))))
     (:consumer1 ... (store-tile-at D C ((+ (* grid-y 128) 64) (* grid-x 256))))

   It does NOT infer the warpgroup count.  Deriving it from the tile-stride tile shape (M/64) was
   considered and rejected as UNDER-DETERMINED: a 128-row tile served by ONE warpgroup looping over
   two row halves is a legal kernel the same rule would silently mis-address.

   Dispatches on the SOURCE TYPE before the generic path runs, exactly as analyze-store-tile-mma
   does -- which also keeps the wgmma store out of %warp-spec-check-block-only, whose
   workgroup-collective deadlock rationale does not apply to a warpgroup-private accumulator spill
   (and which store-tile already bypasses for the same reason).

   ENDEAVOUR 196: the source may be (to-half D) / (to-bfloat16 D); the conversion is fused into
   each element store.  A converted source that is not a wgmma accumulator is refused.

   Spec: tests/spec/154-nvidia-perf/02-wgmma-store-at-origin.crisp (validate-ptx-wgmma-store-direct)
         tests/spec/154-nvidia-perf/03-wgmma-two-warpgroups.crisp  (the cooperative kernel)
         tests/spec/196-matmul-contest/04-wgmma-store-tile-at-to-half.crisp."
  (multiple-value-bind (src convert) (%196-peel-store-conversion (second expr))
    (let* ((src-node (analyze-expression src env context (append location '(1))))
           (src-type (semantic-node-type src-node)))
      (log:debug "196 store-tile-at: src-type=~a convert=~a" src-type convert)
      (cond
        ((%wgmma-acc-type-p src-type)
         (let ((n      (second (gethash src-type *wgmma-acc-dims*)))
               (origin (fourth expr)))
           (unless (and (listp origin) (= (length origin) 2))
             (error 'crisp-compiler-error
                    :message (format nil "store-tile-at: a wgmma accumulator needs a 2-D (ROW COL) element origin, got ~S.  The accumulator is a 64xN matrix; its origin is where its top-left element lands in the destination." origin)
                    :source-location location))
           (analyze-expression
            (%wgmma-store-rewrite-origin src (third expr)
                                         (first origin) (second origin) n convert)
            env context location)))
        (convert
         (%196-refuse-converted-non-accumulator "store-tile-at" convert src-type location))
        (t
         (analyze-store-tile-at-expression expr env context location))))))
