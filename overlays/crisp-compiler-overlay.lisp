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

;;;; ==========================================================================================
;;;; ENDEAVOUR 196 (matmul contest gaps) -- (b): the Ampere cp.async load-tile, VECTORIZED.
;;;;
;;;; (load-tile SRC TILE coords :barrier BAR) with a :linear barrier on PTX (A100 / L4: no TMA) was
;;;; one cp.async per ELEMENT, and PTX cp.async moves only 4, 8 or 16 bytes, so a half / bfloat16
;;;; tile was refused outright ("element type HALF needs 4 or 8 bytes").  Now:
;;;;
;;;;   * the last (contiguous) tile dimension is walked in 16-byte CHUNKS -- one cp.async .16 per
;;;;     chunk (8 halves, 4 floats, 2 doubles) -- when a uniform run-time test says the layout
;;;;     allows it: source and tile contiguous in the last dimension, every other stride and the
;;;;     origin's last coordinate a multiple of the chunk (D-196-7);
;;;;   * a chunk that runs off the tile or the source falls back to per-element copies with the
;;;;     identity fill, exactly as before;
;;;;   * when the layout test fails, the old per-element loop runs; and an element under 4 bytes in
;;;;     that per-element path is copied SYNCHRONOUSLY (a plain set!) instead of being refused --
;;;;     correct, just not asynchronous.
;;;; ==========================================================================================

;; src/analysis/control.lisp
(defun analyze-%cp-async-copy-elem-expression (expr env context location)
  "Analyzer for (%cp-async-copy-elem <dst-aref> <src-aref> [BYTES]) — one non-blocking cp.async,
   dst (SLM) <- src (global).  Both operands are aref forms; codegen grabs each element's address
   (the aref's 3rd return value) and emits cp.async.ca.shared.global.

   Endeavour 196: optional BYTES (4, 8 or 16) copies that many bytes starting at the element -- the
   vectorized load-tile passes 16 for a whole chunk.  BYTES must be a multiple of the element size.
   Without BYTES an element under 4 bytes (half, bfloat16, char ...) cannot be a cp.async at all, so it
   is analysed as the SYNCHRONOUS copy (set! dst src): the per-element fallback of a 16-bit tile stays
   correct instead of being refused."
  (let* ((bytes-arg (fourth expr))
         (dst-node (analyze-expression (second expr) env context (append location '(1))))
         (elem-type (semantic-node-type dst-node))
         (elem (if (listp elem-type) (first elem-type) elem-type))
         (elem-size (case elem
                      ((char uchar) 1)
                      ((short ushort half bfloat16) 2)
                      ((int uint float) 4)
                      ((long ulong double) 8)
                      (t nil))))
    (log:debug "196 cp-async-copy-elem: elem=~a size=~a bytes=~a" elem elem-size bytes-arg)
    (cond
      ((null elem-size)
       (error 'crisp-compiler-error
              :message (format nil "%cp-async-copy-elem: element type ~S has no cp.async size" elem-type)
              :source-location location))
      ((and (null bytes-arg) (< elem-size 4))
       (analyze-expression (list (intern "SET!" (find-package :crisp-language)) (second expr) (third expr))
                           env context location))
      (t
       (let ((bytes (or bytes-arg elem-size)))
         (unless (and (member bytes '(4 8 16)) (zerop (mod bytes elem-size)))
           (error 'crisp-compiler-error
                  :message (format nil "%cp-async-copy-elem: ~a bytes is not a cp.async size (4, 8, 16) that is a multiple of the ~a-byte element ~S" bytes elem-size elem)
                  :source-location location))
         (make-semantic-cp-async-copy-elem
          :dst-aref-node dst-node
          :src-aref-node (analyze-expression (third expr) env context (append location '(2)))
          :elem-bytes bytes
          :type 'nil
          :source-location location))))))

;; src/analysis/control.lisp (new, after %expand-async-load-tile-at-form)
(defun %196-expand-async-load-tile-vec-form (expr location vec &optional static-dims)
  "Endeavour 196.  Like %expand-async-load-tile-at-form, but the LAST tile dimension is walked in
   chunks of VEC elements (VEC x element-size = 16 bytes), each chunk one (%cp-async-copy-elem tile src 16).

   A uniform run-time test VOK picks the vector nest or the original per-element nest:
     - source and tile have stride 1 in the last dimension,
     - every other source / tile stride is a multiple of VEC,
     - the origin's last coordinate is a multiple of VEC.
   Each thread's chunk starts at a multiple of VEC within the tile, so together these make every
   chunk 16-byte aligned on both sides -- ASSUMING the tensors' base addresses (pointer + offsets)
   are 16-byte aligned, which no Crisp form can test (D-196-8).

   A chunk that is not wholly inside the tile and the source is copied element by element, with the
   identity for out-of-bounds elements -- the same contract as the scalar path.

   Thread mapping (like the scalar nest): dims 0..n-2 stride by the local work size, the last dim
   strides by VEC x its local work size, thread lid starting at lid x VEC.

   STATIC-DIMS, when the tile's shape is a compile-time literal (a make-scratch-matrix / -ring binding),
   replaces the run-time extents~ reads: the chunk walk divides and takes remainders by the tile
   extents, and a 64-bit divide by a VARIABLE costs dozens of instructions per chunk, where a divide by
   a literal power of two is a shift.  (A100: the flattened walk on run-time extents made the 1-warp
   kernel 6.8 -> 9.6 ms.)"
  (let* ((src-form (second expr))
         (tile-form (third expr))
         (origin-list (fourth expr))
         (key-args (nthcdr 4 expr))
         (identity-form (%extract-key-arg key-args :identity 0))
         (n (length origin-list))
         (last (1- n))
         (cl (find-package :crisp-language))
         (s (lambda (name) (intern name cl)))
         (src (gensym "SRC")) (tile (gensym "TILE")) (ident (gensym "IDENT")) (vok (gensym "VOK"))
         (orig (loop for i below n collect (gensym (format nil "ORIG~A" i))))
         (tc   (loop for i below n collect (gensym (format nil "TLC~A" i))))
         (te   (loop for i below n collect (gensym (format nil "TE~A" i))))
         (ge   (loop for i below n collect (gensym (format nil "GE~A" i))))
         (lid  (loop for i below n collect (gensym (format nil "LID~A" i))))
         (lws  (loop for i below n collect (gensym (format nil "LWS~A" i))))
         (uvec (list (funcall s "TO-ULONG") vec)))
    (labels ((sym (name) (funcall s name))
             (u (x) (list (sym "TO-ULONG") x))
             (stride (tensor k) (list (sym "~") (list (sym "STRIDES~") tensor) k))
             (src-coords (last-coord)
               (loop for k below n
                     collect (list (sym "+") (nth k orig) (if (= k last) last-coord (nth k tc)))))
             (tile-aref (last-coord)
               (list* (sym "~") tile (loop for k below n collect (if (= k last) last-coord (nth k tc)))))
             (src-aref (last-coord) (list* (sym "~") src (src-coords last-coord)))
             (in-bounds (last-coord)
               (%tlc-all-in-bounds-form n (src-coords last-coord) ge (sym "<") (sym "AND")))
             (one-elem (last-coord)
               ;; per-element: async when in bounds (sync for <4-byte elements), identity otherwise
               (list (sym "IF") (in-bounds last-coord)
                     (list (sym "%CP-ASYNC-COPY-ELEM") (tile-aref last-coord) (src-aref last-coord))
                     (list (sym "SET!") (tile-aref last-coord) ident))))
      (let* ((tcl (nth last tc)) (tel (nth last te))
             (chunk-end (list (sym "+") tcl uvec))
             (whole-chunk-ok
               (list (sym "AND")
                     (list (sym "<=") chunk-end tel)
                     (%tlc-all-in-bounds-form
                      n (src-coords (list (sym "+") tcl (u (1- vec)))) ge (sym "<") (sym "AND"))))
             (chunk
               (list (sym "IF") whole-chunk-ok
                     (list (sym "%CP-ASYNC-COPY-ELEM") (tile-aref tcl) (src-aref tcl) 16)
                     (cons (sym "PROGN")
                           (loop for j below vec
                                 for cj = (if (zerop j) tcl (list (sym "+") tcl (u j)))
                                 collect (list (sym "WHEN") (list (sym "<") cj tel) (one-elem cj))))))
             ;; FLATTENED chunk walk: every thread of the workgroup takes chunks q = LIN, LIN+NT, ...
             ;; over all TE0 x .. x TE(n-2) x NCH chunks, row-major, so consecutive threads take
             ;; consecutive 16-byte chunks of a row (coalesced) and no thread idles because a tile
             ;; dimension is shorter than the workgroup (a 16-row B slice under 128 threads).
             (nch (gensym "NCH")) (tot (gensym "TOT")) (lin (gensym "LIN")) (nt (gensym "NT"))
             (qb (gensym "QB")) (q (gensym "Q"))
             (rests (loop for k below n collect (gensym "R")))
             (mul (lambda (forms) (reduce (lambda (x y) (list (sym "*") x y)) forms)))
             (decomp-bindings
               (append
                (list (list tcl (list (sym "*") (list (sym "REM") q nch) uvec)))
                (when (> n 1)
                  (list (list (nth (- n 2) rests) (list (sym "/") q nch))))
                (loop for k from (- n 2) downto 0
                      append (list (list (nth k tc) (list (sym "REM") (nth k rests) (nth k te))))
                      when (> k 0)
                        append (list (list (nth (1- k) rests) (list (sym "/") (nth k rests) (nth k te)))))))
             (vec-nest
               (list (sym "LET")
                     (list (list nch (list (sym "/") (list (sym "+") tel (u (1- vec))) uvec))
                           (list lin (u (list (sym "GET-LOCAL-LINEAR-ID"))))
                           (list nt (funcall mul lws))
                           (list tot (funcall mul (append (butlast te) (list nch)))))
                     (list (sym "DOTIMES") (list qb tot nt)
                           (list (sym "LET") (list (list q (list (sym "+") qb lin)))
                                 (list (sym "WHEN") (list (sym "<") q tot)
                                       (list (sym "LET") decomp-bindings chunk))))))
             (scalar-nest (%tlc-coop-loop-skeleton n tile nil tc te lid lws (one-elem tcl) cl))
             (vok-form
               (cons (sym "AND")
                     (append
                      (list (list (sym "=") (stride src last) (u 1))
                            (list (sym "=") (stride tile last) (u 1))
                            (list (sym "=") (list (sym "REM") (nth last orig) uvec) (u 0)))
                      (loop for k below last
                            append (list (list (sym "=") (list (sym "REM") (stride src k) uvec) (u 0))
                                         (list (sym "=") (list (sym "REM") (stride tile k) uvec) (u 0)))))))
             (bindings
               (append
                (list (list src src-form)
                      (list tile tile-form)
                      (list ident (list (sym "%ELEMENT-OF-CAST") tile identity-form)))
                (loop for i below n collect (list (nth i orig) (u (nth i origin-list))))
                (loop for i below n collect (list (nth i te)
                                                  (if static-dims
                                                      (u (nth i static-dims))
                                                      (list (sym "~") (list (sym "EXTENTS~") tile) i))))
                (loop for i below n collect (list (nth i ge) (list (sym "~") (list (sym "EXTENTS~") src) i)))
                (loop for i below n collect (list (nth i lid) (list (sym "GET-LOCAL-ID") i)))
                (loop for i below n collect (list (nth i lws) (list (sym "GET-LOCAL-WORK-SIZE") i))))))
        (declare (ignorable location))
        (log:debug "196 vectorized load-tile: n=~a vec=~a" n vec)
        (list (sym "LET") bindings
              (list (sym "LET") (list (list vok vok-form))
                    (list (sym "PROGN")
                          (list (sym "IF") vok vec-nest scalar-nest)
                          (list (sym "%CP-ASYNC-COMMIT")))))))))

;; src/analysis/control.lisp (new helper, before analyze-load-tile-at-expression)
(defun %196-static-tile-dims (tile-form rank)
  "Endeavour 196.  The compile-time (ROWS COLS) of TILE-FORM -- a scratch-matrix binding or a ring-get of
   a scratch-matrix ring -- from *mma-scratch-tile-dims* (published by the enclosing LET), or NIL."
  (let* ((sym (cond ((symbolp tile-form) tile-form)
                    ((and (consp tile-form) (symbolp (first tile-form))
                          (string= (symbol-name (first tile-form)) "RING-GET")
                          (symbolp (second tile-form)))
                     (second tile-form))))
         (dims (and sym (cdr (assoc sym *mma-scratch-tile-dims*)))))
    (and dims (= (length dims) rank) (every #'integerp dims) dims)))

;; src/analysis/control.lisp (new helper, before analyze-load-tile-at-expression)
(defun %196-cp-async-vec-width (tile-form env context location)
  "Endeavour 196.  Elements per 16-byte cp.async chunk for TILE-FORM's element type (8 for half /
   bfloat16, 4 for float / int, 2 for double / long, 16 for char), or NIL when the element type is
   unknown.  Analysing TILE-FORM here is a pure read: it is a variable or a ring-get."
  (let* ((node (analyze-expression tile-form env context location))
         (elem (get-array-element-type (semantic-node-type node))))
    (case elem
      ((char uchar) 16)
      ((short ushort half bfloat16) 8)
      ((int uint float) 4)
      ((long ulong double) 2)
      (t nil))))

;; src/analysis/control.lisp
(defun analyze-load-tile-at-expression (expr env context location)
  "Analyzer for (load-tile-at SRC TILE (ORIGIN...) &key (identity 0) transpose barrier).
   Rejects placement inside a thread-divergent conditional. If :barrier is provided
   and target is :ptx, emits semantic-nvvm-cp-async-tile-copy. Otherwise, delegates
   codegen via %expand-load-tile-at-form.
   Endeavour 192: a per-operation :cache key is refused (the hint comes from the tensor's type).
   Endeavour 196: a :linear barrier on PTX without :transpose takes the VECTORIZED cp.async nest
   (%196-expand-async-load-tile-vec-form, 16-byte chunks); with :transpose the per-element one."
  ;; Endeavour 192: the cache hint comes from the tensor's type; a per-operation :cache is refused.
  (%refuse-per-operation-cache "load-tile-at" (nthcdr 4 expr) location)
  ;; Endeavor 139: inside a warp-spec block, %warp-spec-check-block-only (after mode resolution)
  ;; governs instead of the thread-divergent check.
  (unless *in-warp-spec-block* (%tlc-check-not-divergent "load-tile-at" location))
  (%tlc-check-elem-match (second expr) (third expr) env "load-tile-at" location)
  (let* ((key-args (nthcdr 4 expr))
         (barrier-form (%extract-key-arg key-args :barrier nil)))
    (when (and (getf key-args :barrier) (getf key-args :transformF))
       (error 'crisp-compiler-error :message "Cannot use :barrier and :transformF together" :source-location location))
    ;; Endeavor 137: the barrier's :mode (looked up via its binding) picks the lowering.
    (let ((mode (and barrier-form (async-barrier-mode-of barrier-form))))
      (%warp-spec-check-block-only "load-tile" mode location)
      (cond
        ;; :block on PTX (Chapter 1.5, Phase 2) — NVIDIA TMA: one bulk descriptor-driven copy
        ;; (cp.async.bulk.tensor...mbarrier::complete_tx::bytes) issued by an elected leader,
        ;; tracked by the barrier's SLM mbarrier.  Arch (sm_90+) already gated at barrier parse.
        ((and barrier-form (eq mode :block) (eq *target-backend* :ptx))
         (%analyze-nvvm-tma-load-tile-at expr env context location))
        ;; :block on any other target (the GENERIC compile-check pass; SPV is rejected at
        ;; barrier parse) — fall to the sync staging so the kernel still compiles + runs
        ;; correctly (just not block-optimized).
        ((and barrier-form (eq mode :block))
         (analyze-expression (%expand-load-tile-at-form expr location)
                             env context location))
        ((and barrier-form (eq mode :linear) (eq *target-backend* :ptx))
         ;; Endeavor 136 (Chapter 1): cooperative cp.async copy + commit_group.
         ;; Endeavour 196: vectorized (16-byte chunks) unless :transpose reorders the walk.
         (let ((vec (and (null (%extract-key-arg key-args :transpose nil))
                         (%196-cp-async-vec-width (third expr) env context (append location '(2))))))
           (log:debug "196 load-tile-at :linear PTX: vec=~a" vec)
           (analyze-expression (if vec
                                   (%196-expand-async-load-tile-vec-form
                                    expr location vec (%196-static-tile-dims (third expr) (length (fourth expr))))
                                   (%expand-async-load-tile-at-form expr location))
                               env context location)))
        ((and barrier-form (eq mode :linear) (eq *target-backend* :spirv)
              (<= (length (fourth expr)) 2))
         ;; Endeavor 136 (Chapter 1, SPV): 1D -> one OpGroupAsyncCopy; 2D -> per-row.
         (analyze-expression (%expand-spirv-async-load-tile-at-form expr location)
                             env context location))
        (t
         (analyze-expression (%expand-load-tile-at-form expr location)
                             env context location))))))

;;;; ==========================================================================================
;;;; ENDEAVOUR 196 -- the register FIT-CHECK charges a DISTRIBUTED tile per warp (D-196-10).
;;;;
;;;; (make-register-tile float (128 128) 0.0 :warps '(true true true true)) spreads 128 fragments over
;;;; four warps: each thread holds 32 fragments = 128 registers.  The fit check charged all 128 fragments
;;;; (512 registers) to every thread and refused the tile, so a multi-warp register tile could never be
;;;; bigger than a single warp could hold -- which is the point of distributing it.
;;;; ==========================================================================================

;; src/mma.lisp (new, before %register-tile-fit-check)
(defvar *196-tile-warp-shares* nil
  "Endeavour 196.  ((M N ELEM N-TRUE) ...) for the register tiles of the LET being exploded, so the fit
   check can charge a :warps-distributed tile per warp.  Bound by the %explode-register-tiles wrapper.")

;; src/mma.lisp (new helper)
(defun %196-tile-warp-shares (bindings location)
  "Endeavour 196.  For each (V (make-register-tile ELEM (M N) INIT ... :warps MASK)) binding, (M N ELEM
   N-TRUE); N-TRUE is 1 without :warps."
  (loop for b in bindings
        when (and (consp b) (= (length b) 2) (symbolp (first b))
                  (%register-tile-init-form-p (second b)))
          collect (let* ((form (second b))
                         (warps-in (getf (nthcdr 4 form) :warps))
                         (mask (and warps-in (%normalize-warp-mask (%warp-mask-unquote warps-in) location))))
                    (list (first (third form)) (second (third form)) (second form)
                          (max 1 (if mask (count t mask) 1))))))

;; src/mma.lisp -- WRAPPER around %explode-register-tiles.  FOLD: bind *196-tile-warp-shares* in the
;; original's LET* (next to *register-tile-elems*) and drop the wrapper.
(defvar *196-orig-explode-register-tiles* (fdefinition '%explode-register-tiles))
(defun %explode-register-tiles (let-expr &optional location context)
  "Endeavour 196 wrapper: publishes each register tile's warp share for %register-tile-fit-check, then
   runs the original."
  (let ((*196-tile-warp-shares*
          (if (and (consp let-expr) (>= (length let-expr) 2) (listp (second let-expr)))
              (%196-tile-warp-shares (second let-expr) location)
              *196-tile-warp-shares*)))
    (funcall *196-orig-explode-register-tiles* let-expr location context)))

;; src/mma.lisp
(defun %register-tile-fit-check (m n location &optional (elem 'float))
  "F1 register FIT-CHECK — NVIDIA per-thread register model only.  On :spirv the tile is opaque
   cooperative matrices (the driver owns register residency), so SKIP — Intel GRF accounting is
   separate (Phase 4).  Else: (M/fr)x(N/fc) accumulator fragments x regs-per-fragment <=
   :max-registers-per-thread.

   Endeavor 144 (D4): reads the budget through %hp-registers-per-thread-default, since
   :max-registers-per-thread may be a scalar OR a list of selectable modes.

   Endeavour 165 (BUG 058): also refuses a tile too SMALL to hold one fragment.  A tile that
   overflows the register budget and a tile that holds nothing are the same kind of mistake and
   are named by the same function, at compile time, rather than discovered as a spill or as an
   empty kernel.

   Endeavour 165 (2b-i): takes ELEM so both bounds use the element type's own fragment geometry.
   Inert while %acc-frag-mn answers 16x8 for everything.

   Endeavour 196 (D-196-10): a tile distributed over N-TRUE warps (:warps) costs each thread
   ceil(fragments / N-TRUE) fragments -- the share it actually allocates -- looked up in
   *196-tile-warp-shares* by (M N ELEM)."
  (unless (eq *target-backend* :spirv)
    (destructuring-bind (fr . fc) (%acc-frag-mn elem)
      (%register-tile-dims-must-divide m n location fr fc)
      (let* ((share         (or (fourth (find-if (lambda (e) (and (eql (first e) m) (eql (second e) n)
                                                                      (equal (symbol-name (third e))
                                                                             (symbol-name elem))))
                                                     *196-tile-warp-shares*))
                                1))
             (nfrags-all    (* (floor m fr) (floor n fc)))
             (nfrags        (ceiling nfrags-all share))
             (regs-per-frag 4)
             (total-regs    (* nfrags regs-per-frag))
             (budget        (or (%hp-registers-per-thread-default)
                                *default-max-registers-per-thread*)))
        (log:debug "196 fit-check ~ax~a ~a: ~a fragments over ~a warp(s) -> ~a regs (budget ~a)"
                   m n elem nfrags-all share total-regs budget)
        (when (> total-regs budget)
          (error 'crisp-compiler-error
                 :message (format nil "make-register-tile: a ~ax~a accumulator tile needs ~a registers/thread (~a fragments × ~a regs~a), exceeding the register budget of ~a.  Use a smaller tile shape, distribute it over more warps (:warps), or a hardware profile with a larger :max-registers-per-thread."
                                  m n total-regs nfrags regs-per-frag
                                  (if (> share 1) (format nil ", ~a-way :warps share" share) "")
                                  budget)
                 :source-location location))))))

;;;; ==========================================================================================
;;;; ENDEAVOUR 196 -- `await` on a :linear barrier (PTX cp.async) also synchronises the workgroup
;;;; (D-196-11).
;;;;
;;;; cp.async.wait_group N waits for the CALLING THREAD's own copies only.  A cooperative load-tile always
;;;; spreads a tile's elements over the workgroup, so after a bare wait_group a thread may read shared
;;;; memory another thread's copy has not reached yet.  CUDA's canonical sequence is
;;;; cp_async_wait_all(); __syncthreads().  Found on A100 (matmul_v2, 4-warp kernel with the flattened
;;;; chunk walk): 2.8% of outputs wrong, every one-warp kernel right.  Inside a warp-specialized block the
;;;; old behaviour is kept -- a workgroup barrier there would wait for warps that never reach it.
;;;; ==========================================================================================

;; src/analysis/control.lisp -- WRAPPER around analyze-await-expression.  FOLD: in the original's
;; (eq *target-backend* :ptx) cp.async branch, return the progn built below.
(defvar *196-orig-analyze-await-expression* (fdefinition 'analyze-await-expression))
(defun analyze-await-expression (expr env context location)
  "Endeavour 196 wrapper: a cp.async await (a :linear barrier on PTX) outside a warp-specialized block
   becomes wait_group + sync-workgroup, so every thread sees every thread's copies.  See D-196-11."
  (let ((node (funcall *196-orig-analyze-await-expression* expr env context location)))
    (if (and (semantic-nvvm-cp-async-wait-p node) (not *in-warp-spec-block*))
        (let ((sync (analyze-expression (list (intern "SYNC-WORKGROUP" (find-package :crisp-language)))
                                        env context location)))
          (log:debug "196 await: cp.async wait_group + sync-workgroup")
          (make-semantic-progn :type (semantic-node-type sync)
                               :body (list node sync)
                               :source-location location))
        node)))

;;;; ==========================================================================================
;;;; ENDEAVOUR 196 -- autodiff of (store-tile (to-half D) C ...) is REFUSED, by name (D-196-12).
;;;;
;;;; Mathematically the adjoint of (to-half D) is D's adjoint (a precision cast is the identity on value,
;;;; the rule %ad-widening-conversion-form-p applies to a scalar).  But the backward machinery asks
;;;; "is the store source a register / wgmma accumulator SYMBOL" in several places -- the activity scan
;;;; that mints <tile>_ADJ, %mma-ad-register-accumulator-tile-p, the wgmma store path -- and resolving the
;;;; name alone only moved the failure to "Unknown variable C-TILE_ADJ".  Until those agree, refuse with a
;;;; message that says what is missing instead of "No adjoint rule for the tile expression".
;;;; ==========================================================================================

;; src/autodiff.lisp -- WRAPPER around %tlc-bwd-adj-name.  FOLD: add the clause to the original's COND,
;; before the (not (symbolp sym)) refusal.
(defvar *196-orig-tlc-bwd-adj-name* (fdefinition '%tlc-bwd-adj-name))
(defun %tlc-bwd-adj-name (sym inputs outputs local-adj-fn kernel-pkg)
  "Endeavour 196 wrapper: a converted tile -- (to-half D), (to-bfloat16 D) -- as a store source is refused
   under --differentiate with a message naming the gap (D-196-12).  Everything else goes to the original."
  (if (%ad-widening-conversion-form-p sym)
      (error 'crisp-compiler-error
             :message (format nil "--differentiate: ~(~s~) as a store source is not differentiable yet.  Its adjoint is ~(~a~)'s (a precision cast is the identity on value), but the accumulator backward does not yet see through the conversion (endeavour 196, D-196-12).  The forward kernel compiles without --differentiate."
                              sym (second sym))
             :source-location nil)
      (funcall *196-orig-tlc-bwd-adj-name* sym inputs outputs local-adj-fn kernel-pkg)))

;;;; ======================================================================
;;;; ENDEAVOUR 197 -- packed accumulator stores.
;;;; The H100 2wg_deep epilogue was 23% of the kernel (72 of 310 us at 4096x5120x4096): one scalar
;;;; st.global per accumulator element.  Each thread owns adjacent column PAIRS, so the lowering now
;;;; stores a pair as one <2 x T> store, guarded by one per-thread run-time check.
;;;; See tests/spec/197-packed-stores/packed-stores.md.
;;;;   * new structs     -> semantic-store-pair, semantic-pair-ok-p (src/semantic.lisp)
;;;;   * wrappers        -> semantic-node-type, semantic-node-source-location (src/analysis/core.lisp):
;;;;                        fold as two clauses in each etypecase, then drop the defvars
;;;;   * analyzers       -> analyze-%store-pair-expression, analyze-%pair-ok-p-expression
;;;;                        (src/analysis/control.lisp); registered by register-197-pair-store-analyzers,
;;;;                        called at the end of register-control-analyzers
;;;;   * codegen         -> two generate-node-ir methods (src/codegen.lisp)
;;;;   * lowering        -> %wgmma-store-rewrite-origin (src/mma.lisp)
;;;; ======================================================================

;; src/semantic.lisp
(defstruct semantic-store-pair
  "Endeavour 197.  (%store-pair P0 P1 LO HI): LO and HI stored as ONE <2 x T> store at P0's element
   address, aligned to two elements.  Only legal under a (%pair-ok-p P0 P1) guard -- the lowering
   that emits it always puts it there.  P1 is analysed only for the fallback (see the analyzer)."
  place-node  ;; semantic aref node: the first element
  lo-node     ;; value stored at P0
  hi-node     ;; value stored at the element after P0
  elem-bytes  ;; 2, 4 or 8
  type
  source-location)

;; src/semantic.lisp
(defstruct semantic-pair-ok-p
  "Endeavour 197.  (%pair-ok-p P0 P1) -> int 1 when P1's address is exactly one element past P0's AND
   P0 is aligned to two elements, else 0.  Address arithmetic on the two element pointers, so it
   covers the strides and the tensor's base offset without either being visible to Crisp."
  place0-node
  place1-node
  elem-bytes
  type
  source-location)

;; src/analysis/core.lisp -- FOLD: add the two clauses to semantic-node-type's etypecase
(defvar *197-orig-semantic-node-type* (fdefinition 'semantic-node-type))
(defun semantic-node-type (node)
  "Returns the Crisp type of a semantic node.
   Extended for 092-dotimes and 114 Phase B (semantic-nvvm-cp-async-*).
   Endeavour 197: semantic-store-pair, semantic-pair-ok-p."
  (typecase node
    (semantic-store-pair (semantic-store-pair-type node))
    (semantic-pair-ok-p  (semantic-pair-ok-p-type node))
    (t (funcall *197-orig-semantic-node-type* node))))

;; src/analysis/core.lisp -- FOLD: add the two clauses to semantic-node-source-location's etypecase
(defvar *197-orig-semantic-node-source-location* (fdefinition 'semantic-node-source-location))
(defun semantic-node-source-location (node)
  "Returns the source location of a semantic node.
   Endeavour 197: semantic-store-pair, semantic-pair-ok-p."
  (typecase node
    (semantic-store-pair (semantic-store-pair-source-location node))
    (semantic-pair-ok-p  (semantic-pair-ok-p-source-location node))
    (t (funcall *197-orig-semantic-node-source-location* node))))

;; src/analysis/control.lisp
(defun %197-pair-elem-bytes (elem-type)
  "Endeavour 197.  Bytes per element for a packable element type (2, 4 or 8), else NIL.  NIL turns
   %pair-ok-p into a constant 0 and %store-pair into two plain set!s."
  (case elem-type
    ((short ushort half bfloat16) 2)
    ((int uint float) 4)
    ((long ulong double) 8)
    (t nil)))

;; src/analysis/control.lisp
(defun analyze-%pair-ok-p-expression (expr env context location)
  "Analyzer for (%pair-ok-p P0 P1), P0 / P1 aref forms naming adjacent elements of one storage.
   Type int (like a comparison).  An element type that cannot be packed analyses to the literal 0,
   so the guarded pair branch is dead and the scalar branch runs."
  (unless (= (length expr) 3)
    (error 'crisp-compiler-error :message "%pair-ok-p: expects two aref forms" :source-location location))
  (let* ((p0 (analyze-expression (second expr) env context (append location '(1))))
         (p1 (analyze-expression (third expr) env context (append location '(2))))
         (bytes (%197-pair-elem-bytes (semantic-node-type p0))))
    (log:debug "197 %pair-ok-p: elem-type=~a bytes=~a" (semantic-node-type p0) bytes)
    (if (and bytes (semantic-aref-p p0) (semantic-aref-p p1))
        (make-semantic-pair-ok-p :place0-node p0 :place1-node p1 :elem-bytes bytes
                                 :type 'int :source-location location)
        (make-semantic-literal :value-type 'int :value 0 :source-location location))))

;; src/analysis/control.lisp
(defun analyze-%store-pair-expression (expr env context location)
  "Analyzer for (%store-pair P0 P1 LO HI): one <2 x T> store when LO and HI already have P0's element
   type and that type packs; otherwise exactly (progn (set! P0 LO) (set! P1 HI)), so conversions
   and type errors are set!'s own.  The caller guards it with (%pair-ok-p P0 P1)."
  (unless (= (length expr) 5)
    (error 'crisp-compiler-error :message "%store-pair: expects (%store-pair P0 P1 LO HI)"
           :source-location location))
  (destructuring-bind (p0-form p1-form lo-form hi-form) (rest expr)
    (let* ((p0 (analyze-expression p0-form env context (append location '(1))))
           (elem (semantic-node-type p0))
           (bytes (%197-pair-elem-bytes elem))
           (lo (analyze-expression lo-form env context (append location '(3))))
           (hi (analyze-expression hi-form env context (append location '(4)))))
      (if (and bytes (semantic-aref-p p0)
               (equal (semantic-node-type lo) elem) (equal (semantic-node-type hi) elem))
          (make-semantic-store-pair :place-node p0 :lo-node lo :hi-node hi :elem-bytes bytes
                                    :type 'nil :source-location location)
          (progn
            (log:debug "197 %store-pair: falling back to two set!s (elem ~a, lo ~a, hi ~a)"
                       elem (semantic-node-type lo) (semantic-node-type hi))
            (analyze-expression `(progn (set! ,p0-form ,lo-form) (set! ,p1-form ,hi-form))
                                env context location))))))

;; src/analysis/control.lisp
(defun register-197-pair-store-analyzers ()
  "Endeavour 197.  Registers %store-pair and %pair-ok-p (internal forms of the accumulator store
   lowering) in both packages, like the other % forms in register-control-analyzers."
  (dolist (entry (list (cons "%STORE-PAIR" #'analyze-%store-pair-expression)
                       (cons "%PAIR-OK-P"  #'analyze-%pair-ok-p-expression)))
    (let ((sym-cl (intern (car entry) (find-package :crisp-language)))
          (sym-cc (intern (car entry) (find-package :crisp.compiler))))
      (setf (gethash sym-cl *expression-analyzers*) (cdr entry))
      (unless (eq sym-cl sym-cc)
        (setf (gethash sym-cc *expression-analyzers*) (cdr entry))))))

;; src/analysis/control.lisp -- FOLD: call (register-197-pair-store-analyzers) at the end of
;; register-control-analyzers, then drop the defvar
(defvar *197-orig-register-control-analyzers* (fdefinition 'register-control-analyzers))
(defun register-control-analyzers ()
  "Registers the control-flow analyzers.  Endeavour 197: plus %store-pair / %pair-ok-p."
  (funcall *197-orig-register-control-analyzers*)
  (register-197-pair-store-analyzers))

;; src/codegen.lisp
(defun %197-aref-element-pointer (aref-node builder module var-env di-builder di-scope location-map what)
  "Endeavour 197.  The element address of an aref node: its third return value (the loaded r-value
   is dead and opt removes it -- the %cp-async-copy-elem idiom)."
  (multiple-value-bind (v ign ptr)
      (generate-node-ir aref-node builder module var-env di-builder di-scope location-map)
    (declare (ignore v ign))
    (unless ptr
      (error "~a: aref did not yield an element pointer (~a)" what aref-node))
    ptr))

;; src/codegen.lisp
(defmethod generate-node-ir ((node semantic-pair-ok-p) builder module var-env
                              di-builder di-scope location-map)
  "Endeavour 197.  i32 (p1 - p0 == bytes) & ((p0 & (2*bytes - 1)) == 0), zero-extended like a comparison."
  (let* ((bytes (semantic-pair-ok-p-elem-bytes node))
         (i64 (llvm-int64-type))
         (p0 (%197-aref-element-pointer (semantic-pair-ok-p-place0-node node) builder module var-env
                                         di-builder di-scope location-map "%pair-ok-p"))
         (p1 (%197-aref-element-pointer (semantic-pair-ok-p-place1-node node) builder module var-env
                                         di-builder di-scope location-map "%pair-ok-p"))
         (a0 (llvm-build-ptr-to-int builder p0 i64 "pair_a0"))
         (a1 (llvm-build-ptr-to-int builder p1 i64 "pair_a1"))
         (adjacent (llvm-build-icmp builder +llvm-int-eq+ (llvm-build-sub builder a1 a0 "pair_gap")
                                    (llvm-const-int i64 bytes nil) "pair_adjacent"))
         (aligned (llvm-build-icmp builder +llvm-int-eq+
                                   (crisp.llvm-bindings::llvm-build-and builder a0 (llvm-const-int i64 (1- (* 2 bytes)) nil)
                                                   "pair_misalign")
                                   (llvm-const-int i64 0 nil) "pair_aligned"))
         (ok (crisp.llvm-bindings::llvm-build-and builder adjacent aligned "pair_ok")))
    (log:debug "197 codegen %pair-ok-p: elem-bytes=~a" bytes)
    (values (llvm-build-zext builder ok (llvm-int32-type) "pair_ok_ext") nil)))

;; src/codegen.lisp
(defmethod generate-node-ir ((node semantic-store-pair) builder module var-env
                              di-builder di-scope location-map)
  "Endeavour 197.  insertelement LO, HI into <2 x T>; one store at P0, aligned to 2 x elem-bytes
   (NVPTX: st.global.b32 for a half / bf16 pair, st.global.v2.f32 for float, v2.f64 for double)."
  (let* ((bytes (semantic-store-pair-elem-bytes node))
         (ptr (%197-aref-element-pointer (semantic-store-pair-place-node node) builder module var-env
                                          di-builder di-scope location-map "%store-pair"))
         (lo-node (semantic-store-pair-lo-node node))
         (hi-node (semantic-store-pair-hi-node node))
         (lo (extract-primary-value builder (generate-node-ir lo-node builder module var-env
                                                              di-builder di-scope location-map)
                                    (semantic-node-type lo-node)))
         (hi (extract-primary-value builder (generate-node-ir hi-node builder module var-env
                                                              di-builder di-scope location-map)
                                    (semantic-node-type hi-node)))
         (vec-ty (llvm-vector-type (llvm-type-of lo) 2))
         (i32 (llvm-int32-type))
         (v (llvm-build-insert-element builder (llvm-get-undef vec-ty) lo (llvm-const-int i32 0 nil) "pair_lo"))
         (v (llvm-build-insert-element builder v hi (llvm-const-int i32 1 nil) "pair_hi"))
         (st (llvm-build-store builder v ptr)))
    (crisp.llvm-bindings::llvm-set-alignment st (* 2 bytes))
    (log:debug "197 codegen %store-pair: <2 x ~a-byte> align ~a" bytes (* 2 bytes))
    (values nil nil)))

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
   (store-tile (to-half D) C ...) -- an f32 accumulator stored into a 16-bit matrix.

   ENDEAVOUR 197: each thread's elements come in adjacent column PAIRS (c, c+1), so a pair is one
   (%store-pair ...) -- a single <2 x T> store -- under ONE (%pair-ok-p ...) test of the thread's
   first pair.  One test covers them all: every other pair is 8k columns and/or 8 rows away, i.e. a
   multiple of 2 elements on both axes once the first pair is adjacent (unit last stride) and
   2-element aligned.  When the test fails (an odd column origin, an unaligned base, a strided last
   dimension) the original scalar stores run.  H100, 4096x5120x4096 fp16: 304 -> 252 us."
  (let* ((to-int (intern "TO-INT" (find-package :crisp-language)))
         (if-sym (intern "IF" (find-package :crisp-language)))
         (n8 (floor n 8)))
    (flet ((elt-of (i) (%196-wrap-conversion convert `(%extract-struct-member wgv ,i))))
      (flet ((pairs (row base-offset)
               (loop for j below n8
                     for base = (+ (* j 4) base-offset)
                     collect `(%store-pair (~ ,dest ,row (+ c0 ,(* 8 j)))
                                           (~ ,dest ,row (+ (+ c0 ,(* 8 j)) 1))
                                           ,(elt-of base) ,(elt-of (1+ base)))))
             (scalars (row base-offset)
               (loop for j below n8
                     for base = (+ (* j 4) base-offset)
                     append (list
                             `(set! (~ ,dest ,row (+ c0 ,(* 8 j)))       ,(elt-of base))
                             `(set! (~ ,dest ,row (+ (+ c0 ,(* 8 j)) 1)) ,(elt-of (1+ base)))))))
        `(let ((wgv ,tile))
           (let ((wgw (rem (,to-int (warp-id)) 4))
                 (lane (,to-int (warp-lane))))
             (let ((rlo (/ lane 4)) (col (* (rem lane 4) 2)))
               (let ((r0 (+ (+ (,to-int ,row-origin) (* wgw 16)) rlo)))
                 (let ((r8 (+ r0 8))
                       (c0 (+ (,to-int ,col-origin) col)))
                   (,if-sym (%pair-ok-p (~ ,dest r0 c0) (~ ,dest r0 (+ c0 1)))
                     (progn ,@(pairs 'r0 0) ,@(pairs 'r8 2))
                     (progn ,@(scalars 'r0 0) ,@(scalars 'r8 2))))))))))))

;; src/mma.lisp -- Endeavour 197: analyze-store-fragment packs each lane's column pairs (NVIDIA)
(defun analyze-store-fragment (expr env context location)
  "P1 / F-SPV: (store-fragment FRAG DEST (TY TX)).  :spirv -> CooperativeMatrixStoreKHR
   (accumulator, row-major); else the NVIDIA per-lane writes.

   Endeavour 196: FRAG may be (to-half F) / (to-bfloat16 F).  The conversion wraps each element
   read in the per-lane writes, so it costs one cvt per element at the store and nothing else.
   NVIDIA only: on SPIR-V the store is one CooperativeMatrixStoreKHR of the whole fragment, which
   would need the fragment converted first (OpFConvert on a cooperative matrix) -- not built.

   Endeavour 197: each lane's elements are adjacent column PAIRS (col, col+1), so on NVIDIA a pair
   is one (%store-pair ...) under a per-fragment (%pair-ok-p ...) of the lane's first pair; the
   scalar set!s are the fallback branch (odd origin, unaligned base, strided last dimension).  The
   row+8 pair shares the guard: 8 rows move the address by 8 x the row stride, an even number of
   elements."
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
            (let ((if-sym (intern "IF" (find-package :crisp-language))))
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
                            (,if-sym (%pair-ok-p (~ ,dest row col) (~ ,dest row (+ col 1)))
                              (%store-pair (~ ,dest row col) (~ ,dest row (+ col 1)) ,(elt-of 0) ,(elt-of 1))
                              (progn
                                (set! (~ ,dest row col)       ,(elt-of 0))
                                (set! (~ ,dest row (+ col 1)) ,(elt-of 1))))))))
                   env context location)
                  (analyze-expression
                   `(let ((frag-val ,frag))
                      (let ((lane (to-int (warp-lane))))
                        (let ((g (/ lane 4)) (t2 (* 2 (rem lane 4))))
                          (let ((row (+ (* ,ty 16) g)) (col (+ (* ,tx 8) t2)))
                            (,if-sym (%pair-ok-p (~ ,dest row col) (~ ,dest row (+ col 1)))
                              (progn
                                (%store-pair (~ ,dest row col) (~ ,dest row (+ col 1))
                                             ,(elt-of 0) ,(elt-of 1))
                                (%store-pair (~ ,dest (+ row 8) col) (~ ,dest (+ row 8) (+ col 1))
                                             ,(elt-of 2) ,(elt-of 3)))
                              (progn
                                (set! (~ ,dest row col)             ,(elt-of 0))
                                (set! (~ ,dest row (+ col 1))       ,(elt-of 1))
                                (set! (~ ,dest (+ row 8) col)       ,(elt-of 2))
                                (set! (~ ,dest (+ row 8) (+ col 1)) ,(elt-of 3))))))))
                   env context location)))))))))
