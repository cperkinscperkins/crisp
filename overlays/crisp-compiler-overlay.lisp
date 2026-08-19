;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Late-binding overrides for CRISP.COMPILER.
;;;;
;;;; EMPTY BY DESIGN.  Definitions live here only while a feature or bug fix is in
;;;; flight; once it settles they are folded back into their home file in src/ so
;;;; that the source of truth is one place.  Folded 2026-08-02 (endeavour 145),
;;;; again 2026-08-09 (endeavour 146), and again 2026-08-14 (endeavour 149).
;;;;
;;;; To add one: APPEND a complete definition with a `;; src/<file>.lisp` comment
;;;; above it saying where it belongs.  Do not patch definitions already here.
;;;; Note that macros and structs CANNOT be overridden this way -- they are not
;;;; late-bound -- and must be patched in src/ directly.
;;;;
;;;; A NOTE ON WRAPPERS, learned the hard way in 146.  Capturing an original with
;;;;     (defvar *orig-foo* (symbol-function 'foo))
;;;; and then redefining FOO works beautifully in an overlay and does NOT survive
;;;; copy-paste into src/ -- there is no "original" there to capture.  Each such
;;;; wrapper has to be MERGED INTO the real function body when it is folded back.
;;;; If you reach for that pattern, note in the header which src function the
;;;; wrapper's body ultimately belongs inside.


(in-package :crisp.compiler)


;;; ===========================================================================
;;; Endeavor 150 (fused epilogue) — `map-elements!`
;;;
;;; (map-elements! <fragment-or-register-tile> #'<unary-fn>)
;;;
;;; Applies a user function to every element, IN PLACE.  It generalises the idiom
;;; store-tile's :transformF already established (a user-supplied unary function applied
;;; per element) to the two register-resident altitudes: a single MMA fragment, and a whole
;;; register tile.
;;;
;;; WHY ELEMENTWISE IS THE WHOLE SCOPE.  A fragment is warp-collective — each lane holds a
;;; few registers of a logical MxN tile — and which logical (row, col) a given register holds
;;; is a per-vendor layout detail.  An ELEMENTWISE function does not care: applying f to each
;;; register independently is identical to applying f to the logical matrix.  That is what
;;; makes this implementable without committing to a fragment->coordinate map (which 145 left
;;; deliberately unvalidated — see [[mma-fragment-layout-untestable-by-roundtrip]]).  Anything
;;; NOT elementwise (bias-add along N, row reductions) needs that map and is out of scope.
;;; ===========================================================================

;; src/mma.lisp
(defun %map-elements-fragment-fields (frag-type)
  "The number of scalar register fields in a PTX register-fragment record type, or NIL if
   FRAG-TYPE is not one of them.

   These counts mirror register-mma-types' definitions exactly: the tf32 m16n8k8 fragments
   are acc 16x8 -> 4 regs, A 16x8 -> 4, B 8x8 -> 2, all fp32-stored.  Kept as a function
   rather than inlined so the fragment-vs-not test and the field count are one decision."
  (case frag-type
    (register-fragment-acc-f32-16x8 4)
    (register-fragment-a-tf32-16x8  4)
    (register-fragment-b-tf32-8x8   2)
    (t nil)))

;; src/mma.lisp
(defun analyze-map-elements (expr env context location)
  "(map-elements! TARGET #'FN) -> apply the unary FN to every element of TARGET, in place.

   Endeavor 150 P0.  This first cut implements the NVIDIA/PTX register-fragment path, where
   a fragment is a plain record of scalar fields, so the map is fieldwise and rewrites to
   forms that already exist:

       (set! FRAG (%construct-struct <frag-type>
                     (funcall FN (%extract-struct-member FRAG 0))
                     ... one per field ...))

   No new codegen — the same %construct-struct / %extract-struct-member primitives
   make-register-fragment and store-fragment already use.

   TARGET is analyzed once up front purely to learn its TYPE; it is always a variable
   reference at this site (an accum binding or a tile), so re-analyzing it inside the
   rewrite is free of side effects.

   FUNCALL is interned in :crisp-language deliberately, matching store-tile's :transformF
   lowering (src/analysis/control.lisp) — the proven path for calling a user-supplied
   function, which Crisp realises through template monomorphization, so there is no
   function-pointer indirection in the emitted kernel."
  (unless (= (length (cdr expr)) 2)
    (error 'crisp-compiler-error
           :message (format nil "map-elements!: expects exactly 2 arguments — (map-elements! <fragment-or-tile> #'<unary-fn>) — got ~a."
                            (length (cdr expr)))
           :source-location location))
  (destructuring-bind (target fn-form) (cdr expr)
    (let* ((node (analyze-expression target env context location))
           (ty   (get-single-value-type node))
           (nf   (%map-elements-fragment-fields ty)))
      (cond
        (nf
         (let ((funcall-sym (intern "FUNCALL" (find-package :crisp-language))))
           (analyze-expression
            `(set! ,target
                   (%construct-struct ,ty
                                      ,@(loop for i below nf
                                              collect `(,funcall-sym ,fn-form
                                                                     (%extract-struct-member ,target ,i)))))
            env context location)))
        (t
         (error 'crisp-compiler-error
                :message (format nil "map-elements!: unsupported target type ~a. Endeavor 150 P0 implements the PTX register-fragment path; SPV cooperative matrices and whole register tiles are the next slices."
                                 ty)
                :source-location location))))))

;; src/mma.lisp
;; VERBATIM re-definition of the src/ original, with ONE added entry: MAP-ELEMENTS!.
(defun register-mma-analyzers ()
  "Registers the MMA + wgmma expression analyzers.  Overlay (Endeavor 140): adds the wgmma forms.
   Endeavor 145 P2: adds LOAD-FRAGMENT-ACC (the store-fragment inverse).
   Endeavor 150: adds MAP-ELEMENTS! (the fused-epilogue primitive)."
  (let ((cl-pkg (find-package :crisp-language))
        (cc-pkg (find-package :crisp.compiler)))
    (dolist (entry (list (cons "MAKE-REGISTER-FRAGMENT" #'analyze-make-register-fragment)
                         (cons "STORE-FRAGMENT"          #'analyze-store-fragment)
                         (cons "LOAD-FRAGMENT-A"         #'analyze-load-fragment-a)
                         (cons "LOAD-FRAGMENT-B"         #'analyze-load-fragment-b)
                         ;; Endeavor 145 (P2) — the accumulator READ, inverse of store-fragment.
                         (cons "LOAD-FRAGMENT-ACC"       #'analyze-load-fragment-acc)
                         (cons "MMA-ACCUMULATE"          #'analyze-mma-accumulate)
                         (cons "MAKE-REGISTER-TILE"      #'analyze-make-register-tile)
                         (cons "MMA-ACCUMULATE-VIA-TILE" #'analyze-mma-accumulate-via-tile)
                         ;; Endeavor 150 (fused epilogue) — elementwise map over a fragment/tile.
                         (cons "MAP-ELEMENTS!"           #'analyze-map-elements)
                         ;; Endeavor 142 (Phase B) — Intel L1 prefetch (Subgroup2DBlockPrefetchINTEL)
                         (cons "PREFETCH-TILE"           #'analyze-prefetch-tile)
                         (cons "INNER-DIMENSION"         #'analyze-inner-dimension)
                         (cons "OUTER-DIMENSIONS"        #'analyze-outer-dimensions-expression)
                         ;; Endeavor 140 (Chapter 4) -- wgmma forms
                         (cons "MAKE-WGMMA-ACCUMULATOR"    #'analyze-make-wgmma-accumulator)
                         (cons "WGMMA-ACCUMULATE"          #'analyze-wgmma-accumulate)
                         (cons "WGMMA-ACCUMULATE-VIA-TILE" #'analyze-wgmma-accumulate-via-tile)
                         (cons "STORE-TILE"              #'analyze-store-tile-mma)
                         (cons "LET"                     #'analyze-let-with-tile-explosion)
                         (cons "LET*"                    #'analyze-let-with-tile-explosion)))
      (let ((sym-cl (intern (car entry) cl-pkg))
            (sym-cc (intern (car entry) cc-pkg)))
        (setf (gethash sym-cl *expression-analyzers*) (cdr entry))
        (unless (eq sym-cl sym-cc)
          (setf (gethash sym-cc *expression-analyzers*) (cdr entry)))))))



;;; ---------------------------------------------------------------------------
;;; Endeavor 150 — arity refusal for the fused function (spec errors/06).
;;;
;;; WITHOUT this check, a non-unary callee reaches analyze-funcall-expression, which fails
;;; its signature lookup with a plain CL (error "No matching signature ...") — an unhandled
;;; condition that aborts the whole spec RUN with a backtrace rather than failing one spec.
;;; So this is not only a nicer diagnostic; it is what keeps one bad kernel from taking the
;;; suite down with it.
;;; ---------------------------------------------------------------------------

;; src/mma.lisp
(defun %map-elements-fn-name (fn-form)
  "The function NAME out of a #'FOO argument to map-elements!, or NIL if FN-FORM is not
   that shape.  #'FOO reads as (FUNCTION FOO); the head is matched by name so it does not
   matter which package the reader interned it in."
  (and (consp fn-form)
       (%head-name-eq (first fn-form) "FUNCTION")
       (second fn-form)))

;; src/mma.lisp
(defun %map-elements-check-unary (fn-form location)
  "Refuse a fused function that is not UNARY, before it reaches the funcall lowering.

   map-elements! applies its function to ONE element at a time, so there is no second
   argument to supply.  Checked against *function-table*, the same registry
   analyze-funcall-expression consults.  When the name is unknown (not a #'FOO form, or no
   signature registered yet) this stays silent and lets the normal path report — the goal is
   a better message for a real mistake, not a new source of false refusals."
  (let* ((name (%map-elements-fn-name fn-form))
         (sigs (and name (gethash name *function-table*))))
    (when sigs
      (unless (find 1 sigs :key (lambda (s) (length (function-signature-parameters s))))
        (error 'crisp-compiler-error
               :message (format nil "map-elements!: the fused function ~a must be unary — it is applied to one element at a time — but its declared signature takes ~{~a~^ or ~} argument(s)."
                                name
                                (remove-duplicates
                                 (mapcar (lambda (s) (length (function-signature-parameters s))) sigs)))
               :source-location location)))))

;; src/mma.lisp
;; SUPERSEDES the analyze-map-elements defined earlier in this same overlay file (house rule:
;; append, never patch).  When folding to src/mma.lisp, take THIS definition and drop the
;; earlier one.  The only change is the added %map-elements-check-unary call.
(defun analyze-map-elements (expr env context location)
  "(map-elements! TARGET #'FN) -> apply the unary FN to every element of TARGET, in place.

   Endeavor 150 P0.  NVIDIA/PTX register-fragment path: a fragment is a record of scalar
   fields, so the map is fieldwise and rewrites onto primitives that already exist:

       (set! FRAG (%construct-struct <frag-type>
                     (funcall FN (%extract-struct-member FRAG 0))
                     ... one per field ...))

   No new codegen.  TARGET is analyzed once up front purely to learn its TYPE; it is always
   a variable reference at this site, so re-analyzing it inside the rewrite has no side
   effects.  FUNCALL is interned in :crisp-language, matching store-tile's :transformF
   lowering — the proven path for calling a user function, which Crisp realises through
   template monomorphization, so no function-pointer indirection survives into the kernel."
  (unless (= (length (cdr expr)) 2)
    (error 'crisp-compiler-error
           :message (format nil "map-elements!: expects exactly 2 arguments — (map-elements! <fragment-or-tile> #'<unary-fn>) — got ~a."
                            (length (cdr expr)))
           :source-location location))
  (destructuring-bind (target fn-form) (cdr expr)
    (%map-elements-check-unary fn-form location)
    (let* ((node (analyze-expression target env context location))
           (ty   (get-single-value-type node))
           (nf   (%map-elements-fragment-fields ty)))
      (cond
        (nf
         (let ((funcall-sym (intern "FUNCALL" (find-package :crisp-language))))
           (analyze-expression
            `(set! ,target
                   (%construct-struct ,ty
                                      ,@(loop for i below nf
                                              collect `(,funcall-sym ,fn-form
                                                                     (%extract-struct-member ,target ,i)))))
            env context location)))
        (t
         (error 'crisp-compiler-error
                :message (format nil "map-elements!: unsupported target type ~a. Endeavor 150 P0 implements the PTX register-fragment path; SPV cooperative matrices and whole register tiles are the next slices."
                                 ty)
                :source-location location))))))


;;; ---------------------------------------------------------------------------
;;; Endeavor 150 — the SPV (Intel / cooperative-matrix) map lowering.
;;;
;;; CONFIRMED BY SPIKE before any of this was written (put_temp_files_here/150-spv/):
;;; llvm-spirv lowers __spirv_CooperativeMatrixLengthKHR and __spirv_AccessChain to REAL
;;; instructions (OpCooperativeMatrixLengthKHR / OpAccessChain), not to surviving calls —
;;; which matters, because a __spirv_* call that survives translation gets Import linkage
;;; and fails at device link with L0 UNLINKED.
;;;
;;; WHY SPV NEEDS A LOOP WHERE PTX DOES NOT.  OpCooperativeMatrixLengthKHR yields a RUNTIME
;;; value: how many components an invocation holds is implementation-defined.  So the PTX
;;; path unrolls over known record fields, and this path loops over [0, len).  That is the
;;; same property that makes elementwise fusion portable — we never learn WHICH logical
;;; element we hold, so nothing here can accidentally depend on the fragment layout.
;;;
;;; THE ALLOCA IS ALREADY THERE.  OpAccessChain needs a POINTER to the matrix, and codegen
;;; already gives every tile fragment one:
;;;     %"c-tile$f0" = alloca target("spirv.CooperativeMatrixKHR", float, 3, 8, 16, 2)
;;; so the map mutates the variable's own storage directly — no copy back.
;;;
;;; NOTE ON SLOT REUSE, and it should be cleaned up when this folds into src/.  The :map kind
;;; rides on the EXISTING semantic-coop-op struct because defstructs are not late-bound and
;;; cannot be added from an overlay.  It reuses slots that other kinds use for other things:
;;;     ty          <- the TARGET variable's symbol   (other kinds: a tile-id node)
;;;     tx          <- the per-element temp's symbol  (other kinds: a tile-id node)
;;;     tensor-node <- the analyzed body expression   (other kinds: the tensor)
;;; When folding, either give semantic-coop-op properly-named slots or mint a dedicated node.
;;; ---------------------------------------------------------------------------

;; src/codegen.lisp
(defun %coop-length (builder module mat-val elem-llvm rows cols use)
  "Emit OpCooperativeMatrixLengthKHR(MAT-VAL) -> i32, the number of components THIS
   invocation holds.  Runtime value by design (see the header).

   The name carries a _use_rows_cols suffix for the same reason the Load/Store builtins do:
   %coop-call reuses a declaration by NAME, so two different coop types under one name would
   collide on the second call's signature.  The translator matches on the prefix — verified
   by spike2 in put_temp_files_here/150-spv/, which emits the real instruction."
  (%coop-call builder module
              (format nil "__spirv_CooperativeMatrixLengthKHR_~d_~d_~d" use rows cols)
              (crisp.llvm-bindings::llvm-int32-type)
              (list (%coop-type elem-llvm rows cols use))
              (list mat-val)))

;; src/codegen.lisp
(defun %coop-access-chain (builder module mat-ptr idx-i64)
  "Emit OpAccessChain(MAT-PTR, IDX) -> ptr to component IDX of the cooperative matrix that
   MAT-PTR points at.  Needs no name suffix: with opaque pointers the signature is
   (ptr, i64) -> ptr for every coop type."
  (%coop-call builder module "__spirv_AccessChain"
              (%coop-ptr-type 0)
              (list (%coop-ptr-type 0) (crisp.llvm-bindings::llvm-int64-type))
              (list mat-ptr idx-i64)))


;; src/codegen.lisp
;; VERBATIM re-definition of the src/ original, with ONE added ecase arm: :MAP.
(defmethod generate-node-ir ((node semantic-coop-op) builder module var-env di-builder di-scope location-map)
  "Endeavor 133: lower a cooperative-matrix op (fill / load / store / prefetch).
   Endeavor 150: adds :map — an in-place elementwise map over the matrix's components."
  (flet ((gen (n) (generate-node-ir n builder module var-env di-builder di-scope location-map)))
    (let ((kind (semantic-coop-op-kind node))
          (rows (semantic-coop-op-rows node))
          (cols (semantic-coop-op-cols node))
          (use  (semantic-coop-op-use node))
          (layout (semantic-coop-op-layout node))
          (i64 (llvm-int64-type))
          (f32 (llvm-float-type)))
      (labels ((origin (dim-node dim)
                 (llvm-build-mul builder
                                 (llvm-build-sext builder (gen dim-node) i64 "coop_tid")
                                 (llvm-const-int i64 dim nil) "coop_orig")))
        (ecase kind
          (:fill
           (values (%coop-fill builder module (gen (semantic-coop-op-value-node node))
                               f32 rows cols use)
                   nil))
          (:load
           (multiple-value-bind (ptr stride)
               (%coop-tensor-ptr+stride builder (gen (semantic-coop-op-tensor-node node))
                                        (origin (semantic-coop-op-ty node) rows)
                                        (origin (semantic-coop-op-tx node) cols) layout)
             (values (%coop-load builder module ptr stride f32 rows cols use layout) nil)))
          (:store
           (let* ((mat (gen (semantic-coop-op-value-node node)))
                  (tv  (gen (semantic-coop-op-tensor-node node)))
                  (orow (origin (semantic-coop-op-ty node) rows))
                  (ocol (origin (semantic-coop-op-tx node) cols)))
             (multiple-value-bind (ptr stride)
                 (%coop-tensor-ptr+stride builder tv orow ocol layout)
               (%coop-store builder module ptr mat stride f32 rows cols use layout)
               (values nil nil))))
          (:prefetch
           (let* ((tv   (gen (semantic-coop-op-tensor-node node)))
                  (orow (origin (semantic-coop-op-ty node) rows))
                  (ocol (origin (semantic-coop-op-tx node) cols)))
             (multiple-value-bind (ptr stride)
                 (%coop-tensor-ptr+stride builder tv orow ocol layout)
               (%block-prefetch builder module ptr stride rows cols)
               (values nil nil))))
          ;; Endeavor 150 — in-place elementwise map.  Loops [0, OpCooperativeMatrixLengthKHR)
          ;; and rewrites each component THROUGH THE VARIABLE'S OWN ALLOCA, so there is no
          ;; copy back.  The body is an already-analyzed expression that reads a temp holding
          ;; the current element; the temp is bound into a copy of var-env exactly the way
          ;; semantic-dotimes binds its loop variable.
          (:map
           (let* ((i32         (llvm-int32-type))
                  (target-name (semantic-coop-op-ty node))
                  (temp-name   (semantic-coop-op-tx node))
                  (body-node   (semantic-coop-op-tensor-node node))
                  (coop-ty     (%coop-type f32 rows cols use))
                  (target-ptr  (gethash target-name var-env))
                  (mat         (llvm-build-load2 builder coop-ty target-ptr "cm_map_mat"))
                  (len         (%coop-length builder module mat f32 rows cols use))
                  (current-fn  (llvm-get-basic-block-parent (llvm-get-insert-block builder)))
                  (i-alloca    (llvm-build-alloca builder i32 "cm_i"))
                  (t-alloca    (llvm-build-alloca builder f32 "cm_elem"))
                  (check-block (llvm-append-basic-block current-fn "cm_check"))
                  (body-block  (llvm-append-basic-block current-fn "cm_body"))
                  (exit-block  (llvm-append-basic-block current-fn "cm_exit")))
             (unless target-ptr
               (error 'crisp-compiler-error
                      :message (format nil "map-elements!: no storage found for cooperative-matrix variable ~a." target-name)
                      :source-location (semantic-coop-op-source-location node)))
             (llvm-build-store builder (llvm-const-int i32 0 0) i-alloca)
             (llvm-build-br builder check-block)
             ;; --- check: i < len ---
             (llvm-position-builder-at-end builder check-block)
             (let* ((i-val  (llvm-build-load2 builder i32 i-alloca "cm_i_v"))
                    (cond-v (llvm-build-icmp builder +llvm-int-slt+ i-val len "cm_cond")))
               (llvm-build-cond-br builder cond-v body-block exit-block))
             ;; --- body: component <- f(component) ---
             (llvm-position-builder-at-end builder body-block)
             (let ((body-env (alexandria:copy-hash-table var-env)))
               (setf (gethash temp-name body-env) t-alloca)
               (let* ((i-val (llvm-build-load2 builder i32 i-alloca "cm_i_b"))
                      (i-x   (llvm-build-sext builder i-val i64 "cm_i64"))
                      (ep    (%coop-access-chain builder module target-ptr i-x))
                      (elem  (llvm-build-load2 builder f32 ep "cm_elem_v")))
                 (llvm-build-store builder elem t-alloca)
                 (let ((res (generate-node-ir body-node builder module body-env
                                              di-builder di-scope location-map)))
                   (llvm-build-store builder res ep)))
               (let* ((i-cur  (llvm-build-load2 builder i32 i-alloca "cm_i_c"))
                      (i-next (llvm-build-add builder i-cur (llvm-const-int i32 1 0) "cm_i_n")))
                 (llvm-build-store builder i-next i-alloca)))
             (unless (terminator-p (llvm-get-insert-block builder))
               (llvm-build-br builder check-block))
             (llvm-position-builder-at-end builder exit-block)
             (values nil nil))))))))


;; src/mma.lisp
(defun %map-elements-coop-dims (ty)
  "(ROWS COLS USE) if TY is a (coop-matrix ELEM ROWS COLS USE) type spec, else NIL."
  (and (consp ty)
       (%head-name-eq (first ty) "COOP-MATRIX")
       (= (length ty) 5)
       (list (third ty) (fourth ty) (fifth ty))))

;; src/mma.lisp
;; SUPERSEDES both earlier analyze-map-elements definitions in this file (house rule: append,
;; never patch).  When folding to src/mma.lisp, take THIS one and drop the other two.
;; CHANGE: adds the SPV cooperative-matrix branch alongside the PTX record branch.
(defun analyze-map-elements (expr env context location)
  "(map-elements! TARGET #'FN) -> apply the unary FN to every element of TARGET, in place.

   Endeavor 150.  TWO LOWERINGS, because the two vendors represent a fragment differently
   and the difference is not cosmetic:

     PTX   a fragment is a record of scalar fields, and the field count is known at compile
           time, so this UNROLLS fieldwise onto primitives that already exist:
               (set! FRAG (%construct-struct <ty> (funcall FN (%extract-struct-member FRAG i)) ...))

     SPV   a fragment is an OPAQUE cooperative matrix whose per-invocation component count is
           a RUNTIME value (OpCooperativeMatrixLengthKHR), so this emits a semantic-coop-op
           :map node that codegen turns into a LOOP over the components, rewriting each one
           through the variable's own alloca via OpAccessChain.

   Both are elementwise and therefore layout-agnostic: neither ever learns which logical
   (row, col) a given register or component holds, which is exactly why this is portable and
   why layout-aware epilogues (bias-add, row reductions) are out of scope.

   The SPV branch needs TARGET to be a variable, since codegen resolves its storage through
   var-env — always true at this site, where TARGET is an accum binding or a tile fragment."
  (unless (= (length (cdr expr)) 2)
    (error 'crisp-compiler-error
           :message (format nil "map-elements!: expects exactly 2 arguments — (map-elements! <fragment-or-tile> #'<unary-fn>) — got ~a."
                            (length (cdr expr)))
           :source-location location))
  (destructuring-bind (target fn-form) (cdr expr)
    (%map-elements-check-unary fn-form location)
    (let* ((node (analyze-expression target env context location))
           (ty   (get-single-value-type node))
           (nf   (%map-elements-fragment-fields ty))
           (coop (%map-elements-coop-dims ty))
           (funcall-sym (intern "FUNCALL" (find-package :crisp-language))))
      (cond
        ;; ---- NVIDIA / PTX: unrolled fieldwise rewrite ----
        (nf
         (analyze-expression
          `(set! ,target
                 (%construct-struct ,ty
                                    ,@(loop for i below nf
                                            collect `(,funcall-sym ,fn-form
                                                                   (%extract-struct-member ,target ,i)))))
          env context location))
        ;; ---- Intel / SPV: runtime-length component loop ----
        (coop
         (unless (symbolp target)
           (error 'crisp-compiler-error
                  :message (format nil "map-elements!: on SPIR-V the target must be a cooperative-matrix VARIABLE (its storage is what OpAccessChain indexes), got ~a."
                                   target)
                  :source-location location))
         (destructuring-bind (rows cols use) coop
           (let* ((temp (gensym "CMELEM"))
                  (env2 (cons (make-parameter-def :name temp :type 'float :kind :local) env))
                  (body-node (analyze-expression (list funcall-sym fn-form temp)
                                                 env2 context location)))
             (make-semantic-coop-op
              :type 'void :kind :map
              :ty target :tx temp :tensor-node body-node
              :rows rows :cols cols :use use
              :source-location location))))
        (t
         (error 'crisp-compiler-error
                :message (format nil "map-elements!: unsupported target type ~a. Implemented for MMA fragments (PTX records and SPV cooperative matrices); whole register tiles are the next slice."
                                 ty)
                :source-location location))))))


;;; ---------------------------------------------------------------------------
;;; Endeavor 150 — map-elements! on a whole REGISTER TILE (specs 03 and 10).
;;;
;;; A register tile does not survive analysis as one variable: %explode-register-tiles turns
;;; (V (make-register-tile ...)) into per-fragment bindings V$F0, V$F1, ... and rewrites the
;;; body's references to V.  Until now that rewriter knew via-tile / store-tile / fill-tile /
;;; load-tile but not map-elements!, so a tile-level map reached codegen still naming V and
;;; failed with `Unknown variable C-TILE`.
;;;
;;; The expansion is the fill-tile shape exactly: touch every fragment THIS warp holds, no
;;; logical fragment index needed.  That is what makes the warp-distributed (:warps) case fall
;;; out for free — like fill-tile, an elementwise map does not care WHICH fragments it owns.
;;; Both backends then inherit the tile form from the per-fragment lowering already shipped.
;;; ---------------------------------------------------------------------------

;; src/mma.lisp
(defun %emit-per-frag-map (entry fn-form)
  "Per-fragment expansion of (map-elements! V #'FN) for a register tile: apply FN elementwise
   to every fragment of V that this warp holds.

   Mirrors %emit-per-frag-fill — no logical fragment index is needed, because an elementwise
   map is indifferent to which fragments of the tile this warp owns, so n-true / first-true
   are deliberately ignored."
  (destructuring-bind (m n syms &optional n-true first-true operand) (cdr entry)
    (declare (ignore m n n-true first-true operand))
    `(progn
       ,@(loop for s in syms
               collect `(map-elements! ,s ,fn-form)))))

;; src/mma.lisp
;; VERBATIM re-definition of the src/ original, with ONE added clause: MAP-ELEMENTS!.
(defun %explode-rewrite-body-form (form tiles)
  "Recursively rewrite body FORM: replace via-tile / store-tile / fill-tile / load-tile /
   map-elements! references to any exploded tile in TILES (alist V -> (V m n syms)) with
   per-fragment progns; otherwise recurse structurally."
  (cond
    ((not (consp form)) form)
    ((and (%head-name-eq (first form) "MMA-ACCUMULATE-VIA-TILE") (>= (length form) 5)
          (assoc (third form) tiles))
     (let ((shape (nth 1 form)) (v (nth 2 form)) (a (nth 3 form)) (b (nth 4 form)))
       (%check-mma-shape shape nil)
       (if (>= (length form) 6)
           (let* ((binding-form (nth 5 form))
                  (binding-sym (if (and (consp binding-form) (= (length binding-form) 1)
                                        (symbolp (first binding-form)))
                                   (first binding-form)
                                   (error 'crisp-compiler-error
                                          :message (format nil "mma-accumulate-via-tile: the accum-binding must be a one-symbol list like (acc), got ~a." binding-form)
                                          :source-location nil)))
                  (body (nthcdr 6 form)))
             (%emit-per-frag-accumulate a b (assoc v tiles) tiles binding-sym body))
           (%emit-per-frag-accumulate a b (assoc v tiles) tiles))))
    ((and (%head-name-eq (first form) "STORE-TILE") (= (length form) 4)
          (assoc (second form) tiles))
     (destructuring-bind (v dest tile-id) (cdr form)
       (%emit-per-frag-store dest tile-id (assoc v tiles))))
    ((and (%head-name-eq (first form) "%LOAD-REGISTER-TILE-ACC") (= (length form) 4)
          (assoc (second form) tiles))
     (destructuring-bind (v src tile-id) (cdr form)
       (%emit-per-frag-acc-load src tile-id (assoc v tiles))))
    ((and (%head-name-eq (first form) "FILL-TILE") (= (length form) 3)
          (assoc (second form) tiles))
     (%emit-per-frag-fill (assoc (second form) tiles) (third form)))
    ;; Endeavor 150 — (map-elements! V #'FN) where V is an exploded register tile.
    ((and (%head-name-eq (first form) "MAP-ELEMENTS!") (= (length form) 3)
          (assoc (second form) tiles))
     (%emit-per-frag-map (assoc (second form) tiles) (third form)))
    ((and (%head-name-eq (first form) "LOAD-TILE") (= (length form) 4)
          (%resolve-tile-ref (third form) tiles))
     (unless (active-hardware-profile)
       (error 'crisp-compiler-error
         :message "load-tile into a register-tile requires a hardware profile (pass --hardware-profile): its GRF / L1 limits drive the register-pipeline safety analysis."
         :source-location nil))
     (unless (eq *target-backend* :spirv)
       (error 'crisp-compiler-error
         :message "load-tile into a register-tile lowers to Subgroup2DBlockLoadINTEL, which is Intel/SPV-only — it has no PTX/NVIDIA mapping in this register-pipeline model."
         :source-location nil))
     (%emit-per-frag-block-load (second form) (%resolve-tile-ref (third form) tiles) (fourth form)))
    (t (mapcar (lambda (f) (%explode-rewrite-body-form f tiles)) form))))


;;; ---------------------------------------------------------------------------
;;; Endeavor 150 — lower the fused call as a DIRECT call, not FUNCALL.
;;;
;;; MEASURED, not assumed (put_temp_files_here/150-vjp/):
;;;     (set! (~ C i) (funcall #'relu7 (~ A i)))  -> backward FAILS to compile:
;;;         "Function FUNCALL is not differentiable."
;;;     (set! (~ C i) (relu7 (~ A i)))            -> PASS [l0] analytical=1.0 numerical=1.0
;;;
;;; So the AD engine walks a DIRECT call into a user function happily — including through the
;;; `if` kink — and has no rule for the indirect one.  Since map-elements! is handed #'FOO and
;;; can read the name straight off it, there is no reason to route through the form AD cannot
;;; differentiate.  This is a strict improvement even before the map's own VJP exists.
;;;
;;; The funcall path is KEPT as a fallback for a fn-form that is not #'NAME, so nothing that
;;; used to compile stops compiling.
;;; ---------------------------------------------------------------------------

;; src/mma.lisp
(defun %map-elements-call (fn-form arg-form)
  "Build the call applying the fused function to ARG-FORM.

   Prefers a DIRECT call (FOO arg) when FN-FORM is #'FOO, because that is the form the AD
   engine can differentiate; falls back to (funcall FN-FORM arg) otherwise."
  (let ((name (%map-elements-fn-name fn-form)))
    (if name
        (list name arg-form)
        (list (intern "FUNCALL" (find-package :crisp-language)) fn-form arg-form))))

;; src/mma.lisp
;; SUPERSEDES the earlier analyze-map-elements definitions in this file (house rule: append,
;; never patch).  When folding to src/mma.lisp, take THIS one and drop the others.
;; CHANGE: both branches now build their call through %map-elements-call.
(defun analyze-map-elements (expr env context location)
  "(map-elements! TARGET #'FN) -> apply the unary FN to every element of TARGET, in place.

   Endeavor 150.  TWO LOWERINGS, because the vendors represent a fragment differently:

     PTX   a record of scalar fields, count known at compile time -> UNROLLED fieldwise onto
           %construct-struct / %extract-struct-member, which already exist.
     SPV   an opaque cooperative matrix whose per-invocation component count is a RUNTIME
           value (OpCooperativeMatrixLengthKHR) -> a semantic-coop-op :map node that codegen
           turns into a LOOP, rewriting each component through the variable's own alloca via
           OpAccessChain.

   Both are elementwise and layout-agnostic: neither learns which logical (row, col) a register
   or component holds, which is why this is portable and why layout-aware epilogues are out of
   scope.  A whole register TILE is handled earlier, in %explode-rewrite-body-form, which
   expands it to one of these per fragment."
  (unless (= (length (cdr expr)) 2)
    (error 'crisp-compiler-error
           :message (format nil "map-elements!: expects exactly 2 arguments — (map-elements! <fragment-or-tile> #'<unary-fn>) — got ~a."
                            (length (cdr expr)))
           :source-location location))
  (destructuring-bind (target fn-form) (cdr expr)
    (%map-elements-check-unary fn-form location)
    (let* ((node (analyze-expression target env context location))
           (ty   (get-single-value-type node))
           (nf   (%map-elements-fragment-fields ty))
           (coop (%map-elements-coop-dims ty)))
      (cond
        ;; ---- NVIDIA / PTX: unrolled fieldwise rewrite ----
        (nf
         (analyze-expression
          `(set! ,target
                 (%construct-struct ,ty
                                    ,@(loop for i below nf
                                            collect (%map-elements-call
                                                     fn-form
                                                     `(%extract-struct-member ,target ,i)))))
          env context location))
        ;; ---- Intel / SPV: runtime-length component loop ----
        (coop
         (unless (symbolp target)
           (error 'crisp-compiler-error
                  :message (format nil "map-elements!: on SPIR-V the target must be a cooperative-matrix VARIABLE (its storage is what OpAccessChain indexes), got ~a."
                                   target)
                  :source-location location))
         (destructuring-bind (rows cols use) coop
           (let* ((temp (gensym "CMELEM"))
                  (env2 (cons (make-parameter-def :name temp :type 'float :kind :local) env))
                  (body-node (analyze-expression (%map-elements-call fn-form temp)
                                                 env2 context location)))
             (make-semantic-coop-op
              :type 'void :kind :map
              :ty target :tx temp :tensor-node body-node
              :rows rows :cols cols :use use
              :source-location location))))
        (t
         (error 'crisp-compiler-error
                :message (format nil "map-elements!: unsupported target type ~a. Implemented for MMA fragments (PTX records and SPV cooperative matrices) and, via the tile explosion, whole register tiles."
                                 ty)
                :source-location location))))))


;;; ---------------------------------------------------------------------------
;;; Endeavor 150 P2 — `%map-elements-vjp!`, the pairwise backward primitive.
;;;
;;;     (%map-elements-vjp! ADJ PRIMAL #'F_GRAD)   =>   adj[i] <- F_GRAD(primal[i], adj[i])
;;;
;;; Compiler-internal (leading %): it is emitted by the VJP, never written by a user.
;;;
;;; The engine already mints exactly the callee this needs.  A user function compiled under
;;; --differentiate produces BOTH halves with no prompting:
;;;     @shifted_relu_7_float(float)                    ; forward
;;;     @shifted_relu_7_grad_float_float(float, float)  ; (primal, seed) -> d_primal
;;; and the twin recomputes the function's own internals from the primal, so per element we
;;; need only hand it (primal, incoming-adjoint).  Crisp-level name is <NAME>_GRAD.
;;;
;;; Lowering mirrors map-elements! exactly, walking TWO fragments in lockstep instead of one:
;;; PTX unrolls fieldwise, SPV loops to OpCooperativeMatrixLengthKHR with two OpAccessChains.
;;; ---------------------------------------------------------------------------

;; src/mma.lisp
(defun %map-elements-grad-name (fn-form pkg)
  "The <NAME>_GRAD symbol for the fused function in FN-FORM (a #'NAME), interned in PKG.
   Matches the convention the AD walk itself uses (src/autodiff.lisp:2553)."
  (let ((name (%map-elements-fn-name fn-form)))
    (when name
      (intern (format nil "~a_GRAD" (symbol-name name))
              (or pkg (symbol-package name))))))

;; src/mma.lisp
(defun analyze-map-elements-vjp (expr env context location)
  "(%map-elements-vjp! ADJ PRIMAL #'F_GRAD) -> adj[i] <- F_GRAD(primal[i], adj[i]), in place.

   The backward twin of map-elements!.  ADJ and PRIMAL must be fragments of the same shape;
   the walk pairs a tile with its adjoint tile, and the tile explosion (see
   %explode-rewrite-body-form) zips their fragment lists before this ever runs."
  (unless (= (length (cdr expr)) 3)
    (error 'crisp-compiler-error
           :message (format nil "%map-elements-vjp!: expects 3 arguments (adj primal #'fn-grad), got ~a."
                            (length (cdr expr)))
           :source-location location))
  (destructuring-bind (adj primal fn-form) (cdr expr)
    (let* ((adj-node (analyze-expression adj env context location))
           (ty       (get-single-value-type adj-node))
           (nf       (%map-elements-fragment-fields ty))
           (coop     (%map-elements-coop-dims ty))
           (gname    (or (%map-elements-fn-name fn-form)
                         (error 'crisp-compiler-error
                                :message "%map-elements-vjp!: the gradient callee must be a #'NAME form."
                                :source-location location))))
      (cond
        ;; ---- NVIDIA / PTX: unrolled fieldwise ----
        (nf
         (analyze-expression
          `(set! ,adj
                 (%construct-struct ,ty
                                    ,@(loop for i below nf
                                            collect `(,gname (%extract-struct-member ,primal ,i)
                                                             (%extract-struct-member ,adj ,i)))))
          env context location))
        ;; ---- Intel / SPV: paired component loop ----
        (coop
         (unless (and (symbolp adj) (symbolp primal))
           (error 'crisp-compiler-error
                  :message "%map-elements-vjp!: on SPIR-V both operands must be cooperative-matrix VARIABLES."
                  :source-location location))
         (destructuring-bind (rows cols use) coop
           (let* ((tp (gensym "CMPRM"))
                  (ta (gensym "CMADJ"))
                  (env2 (list* (make-parameter-def :name tp :type 'float :kind :local)
                               (make-parameter-def :name ta :type 'float :kind :local)
                               env))
                  (body-node (analyze-expression (list gname tp ta) env2 context location)))
             (make-semantic-coop-op
              :type 'void :kind :map2
              :ty adj :tx primal :layout (list tp ta) :tensor-node body-node
              :rows rows :cols cols :use use
              :source-location location))))
        (t
         (error 'crisp-compiler-error
                :message (format nil "%map-elements-vjp!: unsupported operand type ~a." ty)
                :source-location location))))))

;; src/mma.lisp
(defun %emit-per-frag-map-vjp (adj-entry primal-entry fn-form)
  "Per-fragment expansion of (%map-elements-vjp! ADJ PRIMAL #'F_GRAD) for register tiles:
   zip the two tiles' fragment lists and pair them positionally.  Positional pairing is right
   because both tiles carry the SAME shape and the same warp distribution, so fragment k of one
   corresponds to fragment k of the other."
  (let ((asyms (fourth adj-entry))
        (psyms (fourth primal-entry)))
    (unless (= (length asyms) (length psyms))
      (error 'crisp-compiler-error
             :message (format nil "%map-elements-vjp!: adjoint tile has ~a fragments but the primal tile has ~a — they must match."
                              (length asyms) (length psyms))
             :source-location nil))
    `(progn
       ,@(loop for a in asyms
               for p in psyms
               collect `(%map-elements-vjp! ,a ,p ,fn-form)))))


;; src/mma.lisp
;; SUPERSEDES the earlier register-mma-analyzers in this file.  CHANGE: adds %MAP-ELEMENTS-VJP!.
(defun register-mma-analyzers ()
  "Registers the MMA + wgmma expression analyzers.
   Endeavor 150: adds MAP-ELEMENTS! and its backward twin %MAP-ELEMENTS-VJP!."
  (let ((cl-pkg (find-package :crisp-language))
        (cc-pkg (find-package :crisp.compiler)))
    (dolist (entry (list (cons "MAKE-REGISTER-FRAGMENT" #'analyze-make-register-fragment)
                         (cons "STORE-FRAGMENT"          #'analyze-store-fragment)
                         (cons "LOAD-FRAGMENT-A"         #'analyze-load-fragment-a)
                         (cons "LOAD-FRAGMENT-B"         #'analyze-load-fragment-b)
                         (cons "LOAD-FRAGMENT-ACC"       #'analyze-load-fragment-acc)
                         (cons "MMA-ACCUMULATE"          #'analyze-mma-accumulate)
                         (cons "MAKE-REGISTER-TILE"      #'analyze-make-register-tile)
                         (cons "MMA-ACCUMULATE-VIA-TILE" #'analyze-mma-accumulate-via-tile)
                         (cons "MAP-ELEMENTS!"           #'analyze-map-elements)
                         (cons "%MAP-ELEMENTS-VJP!"      #'analyze-map-elements-vjp)
                         (cons "PREFETCH-TILE"           #'analyze-prefetch-tile)
                         (cons "INNER-DIMENSION"         #'analyze-inner-dimension)
                         (cons "OUTER-DIMENSIONS"        #'analyze-outer-dimensions-expression)
                         (cons "MAKE-WGMMA-ACCUMULATOR"    #'analyze-make-wgmma-accumulator)
                         (cons "WGMMA-ACCUMULATE"          #'analyze-wgmma-accumulate)
                         (cons "WGMMA-ACCUMULATE-VIA-TILE" #'analyze-wgmma-accumulate-via-tile)
                         (cons "STORE-TILE"              #'analyze-store-tile-mma)
                         (cons "LET"                     #'analyze-let-with-tile-explosion)
                         (cons "LET*"                    #'analyze-let-with-tile-explosion)))
      (let ((sym-cl (intern (car entry) cl-pkg))
            (sym-cc (intern (car entry) cc-pkg)))
        (setf (gethash sym-cl *expression-analyzers*) (cdr entry))
        (unless (eq sym-cl sym-cc)
          (setf (gethash sym-cc *expression-analyzers*) (cdr entry)))))))

;; src/codegen.lisp
;; SUPERSEDES the earlier generate-node-ir for semantic-coop-op in this file.
;; CHANGE: adds the :MAP2 arm (the paired backward walk) beside :MAP, and factors the shared
;; loop skeleton into MAP-LOOP so the forward and backward walks cannot drift apart.
(defmethod generate-node-ir ((node semantic-coop-op) builder module var-env di-builder di-scope location-map)
  "Cooperative-matrix op: fill / load / store / prefetch / map / map2."
  (flet ((gen (n) (generate-node-ir n builder module var-env di-builder di-scope location-map)))
    (let ((kind (semantic-coop-op-kind node))
          (rows (semantic-coop-op-rows node))
          (cols (semantic-coop-op-cols node))
          (use  (semantic-coop-op-use node))
          (layout (semantic-coop-op-layout node))
          (i64 (llvm-int64-type))
          (f32 (llvm-float-type)))
      (labels ((origin (dim-node dim)
                 (llvm-build-mul builder
                                 (llvm-build-sext builder (gen dim-node) i64 "coop_tid")
                                 (llvm-const-int i64 dim nil) "coop_orig"))
               (ptr-of (name)
                 (or (gethash name var-env)
                     (error 'crisp-compiler-error
                            :message (format nil "cooperative-matrix map: no storage found for variable ~a." name)
                            :source-location (semantic-coop-op-source-location node))))
               (map-loop (primary-ptr per-elem)
                 (let* ((i32 (llvm-int32-type))
                        (coop-ty (%coop-type f32 rows cols use))
                        (mat (llvm-build-load2 builder coop-ty primary-ptr "cm_map_mat"))
                        (len (%coop-length builder module mat f32 rows cols use))
                        (current-fn (llvm-get-basic-block-parent (llvm-get-insert-block builder)))
                        (i-alloca (llvm-build-alloca builder i32 "cm_i"))
                        (check-block (llvm-append-basic-block current-fn "cm_check"))
                        (body-block  (llvm-append-basic-block current-fn "cm_body"))
                        (exit-block  (llvm-append-basic-block current-fn "cm_exit")))
                   (llvm-build-store builder (llvm-const-int i32 0 0) i-alloca)
                   (llvm-build-br builder check-block)
                   (llvm-position-builder-at-end builder check-block)
                   (let* ((i-val  (llvm-build-load2 builder i32 i-alloca "cm_i_v"))
                          (cond-v (llvm-build-icmp builder +llvm-int-slt+ i-val len "cm_cond")))
                     (llvm-build-cond-br builder cond-v body-block exit-block))
                   (llvm-position-builder-at-end builder body-block)
                   (let* ((i-val (llvm-build-load2 builder i32 i-alloca "cm_i_b"))
                          (i-x   (llvm-build-sext builder i-val i64 "cm_i64")))
                     (funcall per-elem i-x)
                     (let* ((i-cur  (llvm-build-load2 builder i32 i-alloca "cm_i_c"))
                            (i-next (llvm-build-add builder i-cur (llvm-const-int i32 1 0) "cm_i_n")))
                       (llvm-build-store builder i-next i-alloca)))
                   (unless (terminator-p (llvm-get-insert-block builder))
                     (llvm-build-br builder check-block))
                   (llvm-position-builder-at-end builder exit-block)
                   (values nil nil))))
        (ecase kind
          (:fill
           (values (%coop-fill builder module (gen (semantic-coop-op-value-node node))
                               f32 rows cols use)
                   nil))
          (:load
           (multiple-value-bind (ptr stride)
               (%coop-tensor-ptr+stride builder (gen (semantic-coop-op-tensor-node node))
                                        (origin (semantic-coop-op-ty node) rows)
                                        (origin (semantic-coop-op-tx node) cols) layout)
             (values (%coop-load builder module ptr stride f32 rows cols use layout) nil)))
          (:store
           (let* ((mat (gen (semantic-coop-op-value-node node)))
                  (tv  (gen (semantic-coop-op-tensor-node node)))
                  (orow (origin (semantic-coop-op-ty node) rows))
                  (ocol (origin (semantic-coop-op-tx node) cols)))
             (multiple-value-bind (ptr stride)
                 (%coop-tensor-ptr+stride builder tv orow ocol layout)
               (%coop-store builder module ptr mat stride f32 rows cols use layout)
               (values nil nil))))
          (:prefetch
           (let* ((tv   (gen (semantic-coop-op-tensor-node node)))
                  (orow (origin (semantic-coop-op-ty node) rows))
                  (ocol (origin (semantic-coop-op-tx node) cols)))
             (multiple-value-bind (ptr stride)
                 (%coop-tensor-ptr+stride builder tv orow ocol layout)
               (%block-prefetch builder module ptr stride rows cols)
               (values nil nil))))
          (:map
           (let* ((tgt (ptr-of (semantic-coop-op-ty node)))
                  (temp-name (semantic-coop-op-tx node))
                  (body-node (semantic-coop-op-tensor-node node))
                  (t-alloca (llvm-build-alloca builder f32 "cm_elem")))
             (map-loop tgt
                       (lambda (i-x)
                         (let* ((ep   (%coop-access-chain builder module tgt i-x))
                                (elem (llvm-build-load2 builder f32 ep "cm_elem_v"))
                                (benv (alexandria:copy-hash-table var-env)))
                           (llvm-build-store builder elem t-alloca)
                           (setf (gethash temp-name benv) t-alloca)
                           (let ((res (generate-node-ir body-node builder module benv
                                                        di-builder di-scope location-map)))
                             (llvm-build-store builder res ep)))))))
          (:map2
           (let* ((adj-ptr (ptr-of (semantic-coop-op-ty node)))
                  (prm-ptr (ptr-of (semantic-coop-op-tx node)))
                  (temps   (semantic-coop-op-layout node))
                  (tp-name (first temps))
                  (ta-name (second temps))
                  (body-node (semantic-coop-op-tensor-node node))
                  (tp-alloca (llvm-build-alloca builder f32 "cm_prm"))
                  (ta-alloca (llvm-build-alloca builder f32 "cm_adj")))
             (map-loop adj-ptr
                       (lambda (i-x)
                         (let* ((ep-a (%coop-access-chain builder module adj-ptr i-x))
                                (ep-p (%coop-access-chain builder module prm-ptr i-x))
                                (v-a  (llvm-build-load2 builder f32 ep-a "cm_adj_v"))
                                (v-p  (llvm-build-load2 builder f32 ep-p "cm_prm_v"))
                                (benv (alexandria:copy-hash-table var-env)))
                           (llvm-build-store builder v-p tp-alloca)
                           (llvm-build-store builder v-a ta-alloca)
                           (setf (gethash tp-name benv) tp-alloca)
                           (setf (gethash ta-name benv) ta-alloca)
                           (let ((res (generate-node-ir body-node builder module benv
                                                        di-builder di-scope location-map)))
                             (llvm-build-store builder res ep-a))))))))))))

;; src/mma.lisp
;; SUPERSEDES the earlier %explode-rewrite-body-form in this file.
;; CHANGE: adds the %MAP-ELEMENTS-VJP! clause beside MAP-ELEMENTS!.
(defun %explode-rewrite-body-form (form tiles)
  "Recursively rewrite body FORM: replace via-tile / store-tile / fill-tile / load-tile /
   map-elements! / %map-elements-vjp! references to any exploded tile in TILES with
   per-fragment progns; otherwise recurse structurally."
  (cond
    ((not (consp form)) form)
    ((and (%head-name-eq (first form) "MMA-ACCUMULATE-VIA-TILE") (>= (length form) 5)
          (assoc (third form) tiles))
     (let ((shape (nth 1 form)) (v (nth 2 form)) (a (nth 3 form)) (b (nth 4 form)))
       (%check-mma-shape shape nil)
       (if (>= (length form) 6)
           (let* ((binding-form (nth 5 form))
                  (binding-sym (if (and (consp binding-form) (= (length binding-form) 1)
                                        (symbolp (first binding-form)))
                                   (first binding-form)
                                   (error 'crisp-compiler-error
                                          :message (format nil "mma-accumulate-via-tile: the accum-binding must be a one-symbol list like (acc), got ~a." binding-form)
                                          :source-location nil)))
                  (body (nthcdr 6 form)))
             (%emit-per-frag-accumulate a b (assoc v tiles) tiles binding-sym body))
           (%emit-per-frag-accumulate a b (assoc v tiles) tiles))))
    ((and (%head-name-eq (first form) "STORE-TILE") (= (length form) 4)
          (assoc (second form) tiles))
     (destructuring-bind (v dest tile-id) (cdr form)
       (%emit-per-frag-store dest tile-id (assoc v tiles))))
    ((and (%head-name-eq (first form) "%LOAD-REGISTER-TILE-ACC") (= (length form) 4)
          (assoc (second form) tiles))
     (destructuring-bind (v src tile-id) (cdr form)
       (%emit-per-frag-acc-load src tile-id (assoc v tiles))))
    ((and (%head-name-eq (first form) "FILL-TILE") (= (length form) 3)
          (assoc (second form) tiles))
     (%emit-per-frag-fill (assoc (second form) tiles) (third form)))
    ((and (%head-name-eq (first form) "MAP-ELEMENTS!") (= (length form) 3)
          (assoc (second form) tiles))
     (%emit-per-frag-map (assoc (second form) tiles) (third form)))
    ((and (%head-name-eq (first form) "%MAP-ELEMENTS-VJP!") (= (length form) 4)
          (assoc (second form) tiles) (assoc (third form) tiles))
     (%emit-per-frag-map-vjp (assoc (second form) tiles) (assoc (third form) tiles) (fourth form)))
    ((and (%head-name-eq (first form) "LOAD-TILE") (= (length form) 4)
          (%resolve-tile-ref (third form) tiles))
     (unless (active-hardware-profile)
       (error 'crisp-compiler-error
         :message "load-tile into a register-tile requires a hardware profile (pass --hardware-profile): its GRF / L1 limits drive the register-pipeline safety analysis."
         :source-location nil))
     (unless (eq *target-backend* :spirv)
       (error 'crisp-compiler-error
         :message "load-tile into a register-tile lowers to Subgroup2DBlockLoadINTEL, which is Intel/SPV-only — it has no PTX/NVIDIA mapping in this register-pipeline model."
         :source-location nil))
     (%emit-per-frag-block-load (second form) (%resolve-tile-ref (third form) tiles) (fourth form)))
    (t (mapcar (lambda (f) (%explode-rewrite-body-form f tiles)) form))))




;;; ---------------------------------------------------------------------------
;;; Endeavor 150 P2 — differentiate a fused epilogue that lives in the via-tile BODY.
;;;
;;; WHERE THE GRADIENT WAS BEING LOST.  %vjp-mma-accumulate-via-tile destructures its form as
;;;     (shape c-tile a-op b-op &rest ignored)
;;; and IGNORES the rest — which is exactly where the accum binding and the body live.  So for
;;;     (mma-accumulate-via-tile (8 16 8) C-tile A-tile B-tile (acc)
;;;        (accum-op)
;;;        (map-elements! acc #'shifted-relu-7))
;;; the activation was dropped silently, and rung 09 got the UN-activated gradient (1.1994476
;;; where the finite difference correctly said 0.0).  Confirmed by counting instructions: the
;;; backward kernel contained ZERO CooperativeMatrixLengthKHR while the forward contained one.
;;;
;;; THE CHAIN RULE.  With P = A.B and C = f(P):
;;;     dP = dC * f'(P)
;;; so before the existing MMA backward runs (which turns dC into dA and dB), the C adjoint has
;;; to be scaled elementwise by f'(P).  Everything after that is unchanged — which is why this
;;; is a PREFIX on the existing backward rather than a rewrite of it.
;;;
;;; RECOVERING P (option (a), recompute — chosen deliberately over saving it in the forward,
;;; which would grow the forward signature and propagate into hoist codegen, launch argument
;;; lists and both VERIFY-AUTODIFF runtimes).  P is recomputed by re-running the SAME multiply
;;; into a fresh register tile.  Note this is a second MMA in the BACKWARD only; the forward
;;; kernel is untouched, which is the property we cared about.
;;; ---------------------------------------------------------------------------

;; src/autodiff.lisp
(defun %vjp-via-tile-body-map (form)
  "The (map-elements! ACC #'FN) call in a via-tile BODY, or NIL.

   Returns (values ACC-SYM FN-FORM).  The body is everything after the accum binding, so this
   looks only where a fused epilogue can legally be — it does not search the whole form."
  (when (>= (length form) 7)
    (let ((binding (nth 5 form))
          (body    (nthcdr 6 form)))
      (when (and (consp binding) (= (length binding) 1) (symbolp (first binding)))
        (dolist (f body)
          (when (and (consp f) (%head-name-eq (first f) "MAP-ELEMENTS!") (= (length f) 3)
                     (eq (second f) (first binding)))
            (return (values (second f) (third f)))))))))

;; src/autodiff.lisp
;; SUPERSEDES the src/ %vjp-mma-accumulate-via-tile.  CHANGE: when the via-tile body fuses an
;; activation onto the accum binding, prepend the activation's own backward step.
(defun %vjp-mma-accumulate-via-tile (form ctx)
  "VJP for (mma-accumulate-via-tile (M N K) C-TILE A B [(acc) BODY...]).

   Picks the LOWERING here, inside the VJP, which is the whole point of the registry: the walk
   never learns the MMA path shape requirements, so they cannot leak back out as a
   language-level contract.

   Endeavor 150: if BODY fuses an activation onto the accum binding with map-elements!, the
   chain rule needs dP = dC * f'(P), so a prefix recomputes P into a fresh register tile and
   scales the C adjoint through the function's _GRAD twin before the existing backward runs."
  (destructuring-bind (shape c-tile a-op b-op &rest ignored) (cdr form)
    (declare (ignore ignored))
    (let* ((flat-anf  (getf ctx :flat-anf))
           (inputs    (getf ctx :inputs))
           (outputs   (getf ctx :outputs))
           (local-adj (getf ctx :local-adj))
           (kernel-pkg (getf ctx :kernel-pkg))
           (dims-map (%mma-ad-tile-dims-map flat-anf))
           (src-map  (%mma-ad-tile-source-map flat-anf))
           (ring-sites (%ad-ring-load-sites flat-anf))
           (c-dims   (assoc (%ad-tile-base c-tile) dims-map))
           (a-dims   (assoc (%ad-tile-base a-op) dims-map)))
      (when c-dims
        (multiple-value-bind (a-src aoy aox a-kind)
            (%mma-vjp-operand-ref a-op src-map dims-map inputs ring-sites)
          (multiple-value-bind (b-src boy box b-kind)
              (%mma-vjp-operand-ref b-op src-map dims-map inputs ring-sites)
            (when (and a-src b-src)
              (let* ((mt (second c-dims))
                     (nt (third c-dims))
                     (kt (if a-dims
                             (third a-dims)
                             (nth-value 2 (%spv-mma-shape))))
                     (pkg (or kernel-pkg (symbol-package (or (%ad-tile-base c-tile) c-tile))))
                     (ringp (or (eq a-kind :ring) (eq b-kind :ring)))
                     (c-adj (%tlc-bwd-adj-name c-tile inputs outputs local-adj kernel-pkg))
                     (a-adj (%tlc-bwd-adj-name a-op  inputs outputs local-adj kernel-pkg))
                     (b-adj (%tlc-bwd-adj-name b-op  inputs outputs local-adj kernel-pkg))
                     (core (if (and (not ringp) (%mma-vjp-mma-admissible-p mt nt kt))
                               (%mma-via-tile-backward form dims-map src-map inputs outputs
                                                       local-adj kernel-pkg)
                               (%mma-vjp-scalar-lowering mt nt kt c-adj a-op b-op a-adj b-adj
                                                         a-src aoy aox b-src boy box pkg))))
                (log:debug "VJP via-tile: Mt=~a Nt=~a Kt=~a a=~a(~a) b=~a(~a) ring=~a mma-path=~a"
                           mt nt kt a-op a-kind b-op b-kind ringp
                           (%mma-vjp-mma-admissible-p mt nt kt))
                (multiple-value-bind (acc-sym fn-form) (%vjp-via-tile-body-map form)
                  (if (not acc-sym)
                      core
                      ;; A fused activation: dP = dC * f'(P).  Recompute P, then scale.
                      (let* ((cl    (find-package :crisp-language))
                             (grad  (%map-elements-grad-name fn-form pkg))
                             (p-sym (intern (format nil "~a_PRIMAL" (symbol-name (%ad-tile-base c-tile))) pkg))
                             (progn-s (intern "PROGN" cl))
                             (let-s   (intern "LET" cl))
                             (mrt-s   (intern "MAKE-REGISTER-TILE" cl))
                             (flt-s   (intern "FLOAT" cl))
                             (via-s   (intern "MMA-ACCUMULATE-VIA-TILE" cl))
                             (vjp-s   (intern "%MAP-ELEMENTS-VJP!" cl))
                             (fn-s    (intern "FUNCTION" cl)))
                        (unless grad
                          (error 'crisp-compiler-error
                                 :message "map-elements! in a via-tile body: the fused function must be a #'NAME form for its gradient twin to be nameable."
                                 :source-location nil))
                        (log:debug "VJP via-tile: fused activation ~a -> prefixing dP = dC * ~a(P, dC)"
                                   fn-form grad)
                        (log:info "VJP-150 EMITTING: ~s"
                                  `(,progn-s
                                    (,let-s ((,p-sym (,mrt-s ,flt-s (,mt ,nt) 0.0)))
                                            (,via-s ,shape ,p-sym ,a-op ,b-op)
                                            (,vjp-s ,c-adj ,p-sym (,fn-s ,grad)))
                                    :CORE-ELIDED))
                        `(,progn-s
                          (,let-s ((,p-sym (,mrt-s ,flt-s (,mt ,nt) 0.0)))
                                  (,via-s ,shape ,p-sym ,a-op ,b-op)
                                  (,vjp-s ,c-adj ,p-sym (,fn-s ,grad)))
                          ,core))))))))))))

(register-vjp "MMA-ACCUMULATE-VIA-TILE" #'%vjp-mma-accumulate-via-tile)


;; src/autodiff.lisp
;; SUPERSEDES the %vjp-via-tile-body-map above (house rule: append, never patch).
;;
;; THE BUG IT FIXES, worth recording because the failure mode is unrecognisable from the
;; symptom.  The first version used (return ...) to escape a dolist.  In :crisp.compiler
;; `return` is not cl:return — it is Crisp's own RETURN macro (src/macros.lisp:80-84), which
;; expands to (explicit-return VALUE).  So the escape compiled into a call to a function that
;; does not exist, and every spec with a fused epilogue died at compile time with
;;
;;     The function CRISP.COMPILER::EXPLICIT-RETURN is undefined.
;;
;; — a message that names neither this function nor `return`, and that arrives before any of
;; the VJP's own logging can fire.  This is the same shadowing hazard already recorded for
;; `char` in :crisp.compiler; `return` belongs on that list.
;;
;; Rewritten with FIND-IF so no escape construct is needed at all.
(defun %vjp-via-tile-body-map (form)
  "The (map-elements! ACC #'FN) call in a via-tile BODY, or NIL.

   Returns (values ACC-SYM FN-FORM).  Looks only after the accum binding, which is the only
   place a fused epilogue can legally be — it does not search the whole form."
  (when (>= (length form) 7)
    (let ((binding (nth 5 form))
          (body    (nthcdr 6 form)))
      (when (and (consp binding) (= (length binding) 1) (symbolp (first binding)))
        (let ((hit (find-if (lambda (f)
                              (and (consp f)
                                   (%head-name-eq (first f) "MAP-ELEMENTS!")
                                   (= (length f) 3)
                                   (eq (second f) (first binding))))
                            body)))
          (when hit
            (values (second hit) (third hit))))))))


;;; ---------------------------------------------------------------------------
;;; Endeavor 150 P2 — two-pass resolution for %map-elements-vjp!.
;;;
;;; THE PROBLEM.  The VJP emits
;;;     (%map-elements-vjp! C-TILE_ADJ C-TILE_PRIMAL #'F_GRAD)
;;; where C-TILE_PRIMAL is bound by the VJP's own inner LET and C-TILE_ADJ by the walk in an
;;; OUTER scope.  %explode-register-tiles builds its `tiles` alist per-LET, so one explosion
;;; sees only the primal and the other only the adjoint.  Requiring both names in one alist
;;; therefore never succeeded, the whole-tile name survived to codegen, and the compile died
;;; with `Unknown variable C-TILE_ADJ`.
;;;
;;; THE FIX.  Carry an optional FRAGMENT INDEX so the form can be resolved a side at a time.
;;; Whichever explosion runs first fans the form out per fragment and records which fragment
;;; each copy is for; the other explosion, at its own level, uses that index for its side:
;;;
;;;     (%map-elements-vjp! ADJ PRIMAL #'g)                    ; emitted
;;;     (%map-elements-vjp! ADJ$F0 PRIMAL #'g 0) ... $F1 ... 1 ; first explosion
;;;     (%map-elements-vjp! ADJ$F0 PRIMAL$F0 #'g 0) ...        ; second explosion
;;;
;;; Order-independent by construction: neither explosion needs to know whether it is the one
;;; that runs first.  The index is inert once both sides are fragments — the analyzer ignores
;;; a trailing index — so nothing has to strip it.
;;; ---------------------------------------------------------------------------

;; src/mma.lisp
;; SUPERSEDES the earlier analyze-map-elements-vjp.  CHANGE: tolerates the trailing fragment
;; index left behind by two-pass resolution.
(defun analyze-map-elements-vjp (expr env context location)
  "(%map-elements-vjp! ADJ PRIMAL #'F_GRAD [IDX]) -> adj[i] <- F_GRAD(primal[i], adj[i]).

   IDX is bookkeeping for the tile explosion (see %emit-map-vjp-explode) and is inert here: by
   the time this analyzer runs, both operands are already single fragments."
  (unless (member (length (cdr expr)) '(3 4))
    (error 'crisp-compiler-error
           :message (format nil "%map-elements-vjp!: expects 3 or 4 arguments (adj primal #'fn-grad [idx]), got ~a."
                            (length (cdr expr)))
           :source-location location))
  (destructuring-bind (adj primal fn-form &optional idx) (cdr expr)
    (declare (ignore idx))
    (let* ((adj-node (analyze-expression adj env context location))
           (ty       (get-single-value-type adj-node))
           (nf       (%map-elements-fragment-fields ty))
           (coop     (%map-elements-coop-dims ty))
           (gname    (or (%map-elements-fn-name fn-form)
                         (error 'crisp-compiler-error
                                :message "%map-elements-vjp!: the gradient callee must be a #'NAME form."
                                :source-location location))))
      (cond
        (nf
         (analyze-expression
          `(set! ,adj
                 (%construct-struct ,ty
                                    ,@(loop for i below nf
                                            collect `(,gname (%extract-struct-member ,primal ,i)
                                                             (%extract-struct-member ,adj ,i)))))
          env context location))
        (coop
         (unless (and (symbolp adj) (symbolp primal))
           (error 'crisp-compiler-error
                  :message "%map-elements-vjp!: on SPIR-V both operands must be cooperative-matrix VARIABLES."
                  :source-location location))
         (destructuring-bind (rows cols use) coop
           (let* ((tp (gensym "CMPRM"))
                  (ta (gensym "CMADJ"))
                  (env2 (list* (make-parameter-def :name tp :type 'float :kind :local)
                               (make-parameter-def :name ta :type 'float :kind :local)
                               env))
                  (body-node (analyze-expression (list gname tp ta) env2 context location)))
             (make-semantic-coop-op
              :type 'void :kind :map2
              :ty adj :tx primal :layout (list tp ta) :tensor-node body-node
              :rows rows :cols cols :use use
              :source-location location))))
        (t
         (error 'crisp-compiler-error
                :message (format nil "%map-elements-vjp!: unsupported operand type ~a." ty)
                :source-location location))))))

;; src/mma.lisp
(defun %emit-map-vjp-explode (form tiles)
  "Rewrite (%map-elements-vjp! ADJ PRIMAL FN [IDX]) when EITHER operand names an exploded tile.

   Resolves ONE side per call, so the adjoint tile and the primal tile may be bound at
   different LET levels — which they always are, since the VJP binds the primal itself while
   the walk binds the adjoint outside.  See the header above for the three-step shape."
  (destructuring-bind (adj primal fn &optional idx) (cdr form)
    (let ((vjp-s (first form))
          (adj-e (assoc adj tiles))
          (prm-e (assoc primal tiles)))
      (cond
        ;; Both sides known here — pair positionally and we are done.  Positional pairing is
        ;; right because the two tiles carry the same shape and the same warp distribution.
        ((and adj-e prm-e)
         (let ((asyms (fourth adj-e)) (psyms (fourth prm-e)))
           (unless (= (length asyms) (length psyms))
             (error 'crisp-compiler-error
                    :message (format nil "%map-elements-vjp!: adjoint tile has ~a fragments but the primal tile has ~a — they must match."
                                     (length asyms) (length psyms))
                    :source-location nil))
           `(progn ,@(loop for a in asyms for p in psyms
                           collect `(,vjp-s ,a ,p ,fn)))))
        ;; Only the adjoint is known at this level.
        (adj-e
         (let ((asyms (fourth adj-e)))
           (if idx
               `(,vjp-s ,(nth idx asyms) ,primal ,fn ,idx)
               `(progn ,@(loop for a in asyms for i from 0
                               collect `(,vjp-s ,a ,primal ,fn ,i))))))
        ;; Only the primal is known at this level.
        (prm-e
         (let ((psyms (fourth prm-e)))
           (if idx
               `(,vjp-s ,adj ,(nth idx psyms) ,fn ,idx)
               `(progn ,@(loop for p in psyms for i from 0
                               collect `(,vjp-s ,adj ,p ,fn ,i))))))
        (t form)))))

;; src/mma.lisp
;; SUPERSEDES the earlier %explode-rewrite-body-form.  CHANGE: the %MAP-ELEMENTS-VJP! clause
;; now fires when EITHER operand is an exploded tile, and delegates to %emit-map-vjp-explode.
(defun %explode-rewrite-body-form (form tiles)
  "Recursively rewrite body FORM: replace via-tile / store-tile / fill-tile / load-tile /
   map-elements! / %map-elements-vjp! references to any exploded tile in TILES with
   per-fragment progns; otherwise recurse structurally."
  (cond
    ((not (consp form)) form)
    ((and (%head-name-eq (first form) "MMA-ACCUMULATE-VIA-TILE") (>= (length form) 5)
          (assoc (third form) tiles))
     (let ((shape (nth 1 form)) (v (nth 2 form)) (a (nth 3 form)) (b (nth 4 form)))
       (%check-mma-shape shape nil)
       (if (>= (length form) 6)
           (let* ((binding-form (nth 5 form))
                  (binding-sym (if (and (consp binding-form) (= (length binding-form) 1)
                                        (symbolp (first binding-form)))
                                   (first binding-form)
                                   (error 'crisp-compiler-error
                                          :message (format nil "mma-accumulate-via-tile: the accum-binding must be a one-symbol list like (acc), got ~a." binding-form)
                                          :source-location nil)))
                  (body (nthcdr 6 form)))
             (%emit-per-frag-accumulate a b (assoc v tiles) tiles binding-sym body))
           (%emit-per-frag-accumulate a b (assoc v tiles) tiles))))
    ((and (%head-name-eq (first form) "STORE-TILE") (= (length form) 4)
          (assoc (second form) tiles))
     (destructuring-bind (v dest tile-id) (cdr form)
       (%emit-per-frag-store dest tile-id (assoc v tiles))))
    ((and (%head-name-eq (first form) "%LOAD-REGISTER-TILE-ACC") (= (length form) 4)
          (assoc (second form) tiles))
     (destructuring-bind (v src tile-id) (cdr form)
       (%emit-per-frag-acc-load src tile-id (assoc v tiles))))
    ((and (%head-name-eq (first form) "FILL-TILE") (= (length form) 3)
          (assoc (second form) tiles))
     (%emit-per-frag-fill (assoc (second form) tiles) (third form)))
    ((and (%head-name-eq (first form) "MAP-ELEMENTS!") (= (length form) 3)
          (assoc (second form) tiles))
     (%emit-per-frag-map (assoc (second form) tiles) (third form)))
    ((and (%head-name-eq (first form) "%MAP-ELEMENTS-VJP!") (>= (length form) 4)
          (or (assoc (second form) tiles) (assoc (third form) tiles)))
     (%emit-map-vjp-explode form tiles))
    ((and (%head-name-eq (first form) "LOAD-TILE") (= (length form) 4)
          (%resolve-tile-ref (third form) tiles))
     (unless (active-hardware-profile)
       (error 'crisp-compiler-error
         :message "load-tile into a register-tile requires a hardware profile (pass --hardware-profile): its GRF / L1 limits drive the register-pipeline safety analysis."
         :source-location nil))
     (unless (eq *target-backend* :spirv)
       (error 'crisp-compiler-error
         :message "load-tile into a register-tile lowers to Subgroup2DBlockLoadINTEL, which is Intel/SPV-only — it has no PTX/NVIDIA mapping in this register-pipeline model."
         :source-location nil))
     (%emit-per-frag-block-load (second form) (%resolve-tile-ref (third form) tiles) (fourth form)))
    (t (mapcar (lambda (f) (%explode-rewrite-body-form f tiles)) form))))


;;; ---------------------------------------------------------------------------
;;; Endeavor 150 P2 — recompute P from the GLOBAL sources, not the staged tiles.
;;;
;;; WHAT THE FIRST WORKING VERSION GOT WRONG, caught by the 08/09 pair exactly as designed:
;;;
;;;     08 (probe above the kink)  analytical=0.0  numerical=1.1992188  FAIL
;;;     09 (probe below the kink)  analytical=0.0  numerical=0.0        PASS  <- spurious
;;;
;;; The prefix re-ran the multiply over A-TILE / B-TILE, the tiles the forward staged.  In the
;;; BACKWARD those are empty — a backward kernel replays the forward's BINDINGS but not its
;;; STATEMENTS, which is the whole reason %mma-vjp-scalar-lowering indexes the original global
;;; operands instead.  So P came back all zeros, f'(0 - 7 < 0) = 0, and every gradient through
;;; the activation was killed.
;;;
;;; Note how it presented: the rung that expects ZERO went green.  A backward that has stopped
;;; propagating anything looks identical to a correctly-blocked gradient, and rung 09 alone
;;; could never tell them apart.  Only rung 08, which expects a NON-zero 1.2 through the same
;;; kernel, exposed it.  That is precisely the necessary-but-not-sufficient argument written
;;; into both spec headers before either was run.
;;;
;;; THE FIX: re-stage the operands from their GLOBAL sources first, mirroring what the forward
;;; itself does, then run the multiply.  %mma-vjp-operand-ref already resolves each operand to
;;; (global-source, origin-y, origin-x), which is all load-tile-at needs.  Cost stays entirely
;;; inside the backward kernel.
;;; ---------------------------------------------------------------------------

;; src/autodiff.lisp
;; SUPERSEDES the %vjp-mma-accumulate-via-tile above.  CHANGE: the recompute prefix re-stages
;; A and B from their global sources instead of reading the (empty) forward-staged tiles.
(defun %vjp-mma-accumulate-via-tile (form ctx)
  "VJP for (mma-accumulate-via-tile (M N K) C-TILE A B [(acc) BODY...]).

   Picks the LOWERING here, inside the VJP, which is the whole point of the registry: the walk
   never learns the MMA path shape requirements, so they cannot leak back out as a
   language-level contract.

   Endeavor 150: if BODY fuses an activation onto the accum binding with map-elements!, the
   chain rule needs dP = dC * f'(P).  A prefix re-stages the operands from their GLOBAL sources,
   recomputes P into a fresh register tile, and scales the C adjoint through the function's
   _GRAD twin before the existing backward runs.  The forward kernel is untouched."
  (destructuring-bind (shape c-tile a-op b-op &rest ignored) (cdr form)
    (declare (ignore ignored))
    (let* ((flat-anf  (getf ctx :flat-anf))
           (inputs    (getf ctx :inputs))
           (outputs   (getf ctx :outputs))
           (local-adj (getf ctx :local-adj))
           (kernel-pkg (getf ctx :kernel-pkg))
           (dims-map (%mma-ad-tile-dims-map flat-anf))
           (src-map  (%mma-ad-tile-source-map flat-anf))
           (ring-sites (%ad-ring-load-sites flat-anf))
           (c-dims   (assoc (%ad-tile-base c-tile) dims-map))
           (a-dims   (assoc (%ad-tile-base a-op) dims-map)))
      (when c-dims
        (multiple-value-bind (a-src aoy aox a-kind)
            (%mma-vjp-operand-ref a-op src-map dims-map inputs ring-sites)
          (multiple-value-bind (b-src boy box b-kind)
              (%mma-vjp-operand-ref b-op src-map dims-map inputs ring-sites)
            (when (and a-src b-src)
              (let* ((mt (second c-dims))
                     (nt (third c-dims))
                     (kt (if a-dims
                             (third a-dims)
                             (nth-value 2 (%spv-mma-shape))))
                     (pkg (or kernel-pkg (symbol-package (or (%ad-tile-base c-tile) c-tile))))
                     (ringp (or (eq a-kind :ring) (eq b-kind :ring)))
                     (c-adj (%tlc-bwd-adj-name c-tile inputs outputs local-adj kernel-pkg))
                     (a-adj (%tlc-bwd-adj-name a-op  inputs outputs local-adj kernel-pkg))
                     (b-adj (%tlc-bwd-adj-name b-op  inputs outputs local-adj kernel-pkg))
                     (core (if (and (not ringp) (%mma-vjp-mma-admissible-p mt nt kt))
                               (%mma-via-tile-backward form dims-map src-map inputs outputs
                                                       local-adj kernel-pkg)
                               (%mma-vjp-scalar-lowering mt nt kt c-adj a-op b-op a-adj b-adj
                                                         a-src aoy aox b-src boy box pkg))))
                (log:debug "VJP via-tile: Mt=~a Nt=~a Kt=~a a=~a(~a) b=~a(~a) ring=~a mma-path=~a"
                           mt nt kt a-op a-kind b-op b-kind ringp
                           (%mma-vjp-mma-admissible-p mt nt kt))
                (multiple-value-bind (acc-sym fn-form) (%vjp-via-tile-body-map form)
                  (if (not acc-sym)
                      core
                      (let* ((cl    (find-package :crisp-language))
                             (grad  (%map-elements-grad-name fn-form pkg))
                             (base  (symbol-name (or (%ad-tile-base c-tile) c-tile)))
                             (p-sym  (intern (format nil "~a_PRIMAL" base) pkg))
                             (ap-sym (intern (format nil "~a_PRIMAL_A" base) pkg))
                             (bp-sym (intern (format nil "~a_PRIMAL_B" base) pkg))
                             (progn-s (intern "PROGN" cl))
                             (let-s   (intern "LET" cl))
                             (mrt-s   (intern "MAKE-REGISTER-TILE" cl))
                             (msm-s   (intern "MAKE-SCRATCH-MATRIX" cl))
                             (lta-s   (intern "LOAD-TILE-AT" cl))
                             (sync-s  (intern "SYNC-WORKGROUP" cl))
                             (flt-s   (intern "FLOAT" cl))
                             (via-s   (intern "MMA-ACCUMULATE-VIA-TILE" cl))
                             (vjp-s   (intern "%MAP-ELEMENTS-VJP!" cl))
                             (fn-s    (intern "FUNCTION" cl)))
                        (unless grad
                          (error 'crisp-compiler-error
                                 :message "map-elements! in a via-tile body: the fused function must be a #'NAME form for its gradient twin to be nameable."
                                 :source-location nil))
                        (log:debug "VJP via-tile: fused activation ~a -> dP = dC * ~a(P, dC); re-staging P from ~a / ~a"
                                   fn-form grad a-src b-src)
                        `(,progn-s
                          (,let-s ((,ap-sym (,msm-s ,flt-s (,mt ,kt)))
                                   (,bp-sym (,msm-s ,flt-s (,kt ,nt)))
                                   (,p-sym  (,mrt-s ,flt-s (,mt ,nt) 0.0)))
                                  (,lta-s ,a-src ,ap-sym (,aoy ,aox))
                                  (,lta-s ,b-src ,bp-sym (,boy ,box))
                                  (,sync-s)
                                  (,via-s ,shape ,p-sym ,ap-sym ,bp-sym)
                                  (,vjp-s ,c-adj ,p-sym (,fn-s ,grad)))
                          ,core))))))))))))

(register-vjp "MMA-ACCUMULATE-VIA-TILE" #'%vjp-mma-accumulate-via-tile)


;;; ---------------------------------------------------------------------------
;;; Endeavor 150 — refuse a map on the ACCUMULATOR inside a staged reduction (spec errors/07).
;;;
;;; WHY THIS BECAME URGENT THE MOMENT map-elements! STARTED WORKING.  Before the form existed,
;;; errors/07 failed with "Unsupported form MAP-ELEMENTS!" — wrong message, right outcome.  Now
;;; the same kernel COMPILES, and produces a silently wrong matmul.  That is the failure class
;;; this project keeps getting bitten by, so the check goes in immediately rather than after
;;; the benchmark.
;;;
;;; THE RULE IS STRUCTURAL, NOT ABOUT LINEARITY.  matrix-multiply-tile-stride calls the body
;;; once per K-step and the accumulator carries the running sum ACROSS those calls, so a map
;;; applied there re-transforms the accumulator every step.  With p1 and p2 the two K-steps:
;;;
;;;     correct   (map once, in the :epilogue):   2*p1 + 2*p2
;;;     this bug  (map per K-step):               4*p1 + 2*p2
;;;
;;; The only function that survives per-step application is the identity — so this is refused
;;; for EVERY function, including a plain scale.  errors/07 deliberately uses a linear one.
;;;
;;; SCOPE, kept deliberately narrow: only a map on THE ACCUMULATOR is refused — the mmts C-tile
;;; itself, or the accum binding of a via-tile inside the reduction body.  A map on some other
;;; register tile in the loop (a register-resident A operand, say) is a legitimate per-step
;;; transform and is left alone.
;;; ---------------------------------------------------------------------------

;; src/analysis/control.lisp
(defun %mmts-accumulator-map-target (reduction-body c-tile)
  "The target symbol of a map-elements! applied to the ACCUMULATOR anywhere in REDUCTION-BODY,
   or NIL.  The accumulator is either C-TILE itself or the accum binding of a via-tile in the
   body.  Walks structurally; deliberately does not use an escape construct, because `return`
   in :crisp.compiler is Crisp's RETURN macro, not cl:return."
  (let ((acc-names (list c-tile)))
    ;; Collect via-tile accum bindings that appear in this reduction body.
    (labels ((collect (f)
               (when (consp f)
                 (when (and (%head-name-eq (first f) "MMA-ACCUMULATE-VIA-TILE")
                            (>= (length f) 6)
                            (consp (nth 5 f))
                            (= (length (nth 5 f)) 1)
                            (symbolp (first (nth 5 f))))
                   (push (first (nth 5 f)) acc-names))
                 (mapc #'collect f))))
      (mapc #'collect reduction-body))
    (labels ((find-map (f)
               (cond
                 ((not (consp f)) nil)
                 ((and (%head-name-eq (first f) "MAP-ELEMENTS!")
                       (>= (length f) 3)
                       (symbolp (second f))
                       (member (second f) acc-names))
                  (second f))
                 (t (some #'find-map f)))))
      (some #'find-map reduction-body))))

;; src/analysis/control.lisp
;; SUPERSEDES the src/ %mmts-lower.  CHANGE: refuses a map on the accumulator in the reduction
;; body before lowering anything.
(defun %mmts-lower (c-form c-tile tile-spec k-form k-step grid-y grid-x grid-k body location
                    &optional (reset-value 0.0))
  "The tile-stride (over TILE-SPEC) + grid-k K/k-step reduction loop.  Endeavor 137: NO
   auto-store — the body's :epilogue section (post-reduction, per tile) holds the explicit
   store + any fusion.  Warns if the C-tile is never stored.

   BUG 036: emits a per-OUTPUT-TILE reset of the accumulator to RESET-VALUE before the K-loop.

   Endeavor 150: REFUSES a map-elements! on the accumulator inside the reduction body, where
   the accumulator is a partial sum."
  (multiple-value-bind (reduction-body epilogue-body) (%mmts-split-epilogue body)
    (let ((bad (%mmts-accumulator-map-target reduction-body c-tile)))
      (when bad
        (error 'crisp-compiler-error
               :message (format nil "map-elements! on ~a inside a matrix-multiply-tile-stride reduction body: the macro runs this body once per K-step, so ~:*~a holds a partial sum here and mapping it re-transforms the running total on every step (even a linear function is wrong — only the identity survives). Move the map into the :epilogue, where the C-tile is complete."
                                bad)
               :source-location location)))
    (unless (%form-tree-mentions-store-tile-p epilogue-body)
      (format *error-output*
        "WARNING: matrix-multiply-tile-stride: the C-tile is computed but never stored — add an :epilogue with (store-tile ~a ~a (~a ~a)).~%"
        (if (symbolp c-tile) c-tile 'C-tile) (if (symbolp c-form) c-form 'C) grid-y grid-x))
    (let* ((cl-pkg          (find-package :crisp-language))
           (tile-stride-sym (intern "TILE-STRIDE" cl-pkg))
           (dotimes-sym     (intern "DOTIMES" cl-pkg))
           (div-sym         (intern "/" cl-pkg))
           (to-ulong-sym    (intern "TO-ULONG" cl-pkg))
           (fill-sym        (intern "FILL-TILE" cl-pkg))
           (sync-sym        (intern "SYNC-WORKGROUP" cl-pkg))
           (register-p      (and (listp tile-spec) tile-spec (every #'integerp tile-spec)))
           (reset-forms     (when register-p
                              (list (list fill-sym c-tile reset-value)))))
      (declare (ignorable sync-sym))
      (append (list tile-stride-sym c-form tile-spec (list grid-y grid-x))
              reset-forms
              (list (list* dotimes-sym
                           (list grid-k
                                 (list div-sym (list to-ulong-sym k-form) (list to-ulong-sym k-step)))
                           reduction-body))
              epilogue-body))))

;; src/mma.lisp
;; SUPERSEDES the earlier %map-elements-fragment-fields.
;; CHANGE: recognises Hopper wgmma accumulators.
;;
;; WHY THIS IS A THREE-LINE CHANGE AND NOT A THIRD LOWERING.  A wgmma D accumulator is minted by
;; %ensure-wgmma-acc-type as a RECORD of N/2 flat f32 fields and constructed with the very same
;; %construct-struct primitive the mma.sync fragments use (src/mma.lisp:1611-1625).  So the PTX
;; fieldwise unroll already fits it exactly; all that was missing was the field count.  Dims come
;; from *wgmma-acc-dims*, the same source analyze-store-tile-mma consults for its own overload.
;;
;; Found by pointing map-elements! at benchmarks/matmul/crisp/matmul_wgmma_ws_n256.crisp — the
;; NVIDIA champion kernel — which refused with
;;     map-elements!: unsupported target type WGMMA-ACC-F32-64X256.
(defun %map-elements-fragment-fields (frag-type)
  "The number of scalar register fields in a PTX accumulator record type, or NIL if FRAG-TYPE is
   not one.  Covers the tf32 m16n8k8 fragments (acc/A 16x8 -> 4 regs, B 8x8 -> 2) and Hopper
   wgmma accumulators (N/2 f32 registers per thread across the 128-thread warpgroup)."
  (or (case frag-type
        (register-fragment-acc-f32-16x8 4)
        (register-fragment-a-tf32-16x8  4)
        (register-fragment-b-tf32-8x8   2)
        (t nil))
      (when (%wgmma-acc-type-p frag-type)
        (floor (second (gethash frag-type *wgmma-acc-dims*)) 2))))


;;; ---------------------------------------------------------------------------
;;; Endeavor 150 — widen %map-elements-fragment-fields' derived return type.
;;;
;;; OVERLAY HAZARD, worth recording because the error names nothing useful.  The original
;;; definition returned only 2, 4 or NIL, so SBCL DERIVED the ftype
;;;     (OR (INTEGER 2 2) (INTEGER 4 4) NULL)
;;; and compiled the CALLERS against it.  Teaching the function about wgmma accumulators makes
;;; it return N/2 (128 for the n256 kernel), which the already-compiled callers reject:
;;;     The value 128 is not of type (OR (INTEGER 2 2) (INTEGER 4 4) NULL)
;;;     from the function type declaration.
;;; A late redefinition alone is not enough — the callers must be recompiled too.  Hence the
;;; explicit DECLAIM (so nothing narrow is re-derived) followed by re-definitions of both
;;; callers, verbatim.
;;; ---------------------------------------------------------------------------

(declaim (ftype (function (t) (or null (integer 1 8192))) %map-elements-fragment-fields))

(defun %map-elements-fragment-fields (frag-type)
  "The number of scalar register fields in a PTX accumulator record type, or NIL if FRAG-TYPE is
   not one.  Covers the tf32 m16n8k8 fragments (acc/A 16x8 -> 4 regs, B 8x8 -> 2) and Hopper
   wgmma accumulators (N/2 f32 registers per thread across the 128-thread warpgroup), which are
   minted as flat f32 records by %ensure-wgmma-acc-type and so fit the fieldwise lowering as-is."
  (or (case frag-type
        (register-fragment-acc-f32-16x8 4)
        (register-fragment-a-tf32-16x8  4)
        (register-fragment-b-tf32-8x8   2)
        (t nil))
      (when (%wgmma-acc-type-p frag-type)
        (floor (second (gethash frag-type *wgmma-acc-dims*)) 2))))

;; Re-definitions of the two callers so they recompile against the widened type.  Bodies are
;; verbatim copies of their latest versions above.

(defun analyze-map-elements (expr env context location)
  "(map-elements! TARGET #'FN) -> apply the unary FN to every element of TARGET, in place.

   Endeavor 150.  TWO LOWERINGS, because the vendors represent a fragment differently:

     PTX   a record of scalar fields, count known at compile time -> UNROLLED fieldwise onto
           %construct-struct / %extract-struct-member, which already exist.
     SPV   an opaque cooperative matrix whose per-invocation component count is a RUNTIME
           value (OpCooperativeMatrixLengthKHR) -> a semantic-coop-op :map node that codegen
           turns into a LOOP, rewriting each component through the variable's own alloca via
           OpAccessChain.

   Both are elementwise and layout-agnostic: neither learns which logical (row, col) a register
   or component holds, which is why this is portable and why layout-aware epilogues are out of
   scope.  A whole register TILE is handled earlier, in %explode-rewrite-body-form, which
   expands it to one of these per fragment."
  (unless (= (length (cdr expr)) 2)
    (error 'crisp-compiler-error
           :message (format nil "map-elements!: expects exactly 2 arguments — (map-elements! <fragment-or-tile> #'<unary-fn>) — got ~a."
                            (length (cdr expr)))
           :source-location location))
  (destructuring-bind (target fn-form) (cdr expr)
    (%map-elements-check-unary fn-form location)
    (let* ((node (analyze-expression target env context location))
           (ty   (get-single-value-type node))
           (nf   (%map-elements-fragment-fields ty))
           (coop (%map-elements-coop-dims ty)))
      (cond
        ;; ---- NVIDIA / PTX: unrolled fieldwise rewrite ----
        (nf
         (analyze-expression
          `(set! ,target
                 (%construct-struct ,ty
                                    ,@(loop for i below nf
                                            collect (%map-elements-call
                                                     fn-form
                                                     `(%extract-struct-member ,target ,i)))))
          env context location))
        ;; ---- Intel / SPV: runtime-length component loop ----
        (coop
         (unless (symbolp target)
           (error 'crisp-compiler-error
                  :message (format nil "map-elements!: on SPIR-V the target must be a cooperative-matrix VARIABLE (its storage is what OpAccessChain indexes), got ~a."
                                   target)
                  :source-location location))
         (destructuring-bind (rows cols use) coop
           (let* ((temp (gensym "CMELEM"))
                  (env2 (cons (make-parameter-def :name temp :type 'float :kind :local) env))
                  (body-node (analyze-expression (%map-elements-call fn-form temp)
                                                 env2 context location)))
             (make-semantic-coop-op
              :type 'void :kind :map
              :ty target :tx temp :tensor-node body-node
              :rows rows :cols cols :use use
              :source-location location))))
        (t
         (error 'crisp-compiler-error
                :message (format nil "map-elements!: unsupported target type ~a. Implemented for MMA fragments (PTX records and SPV cooperative matrices) and, via the tile explosion, whole register tiles."
                                 ty)
                :source-location location))))))

(defun analyze-map-elements-vjp (expr env context location)
  "(%map-elements-vjp! ADJ PRIMAL #'F_GRAD [IDX]) -> adj[i] <- F_GRAD(primal[i], adj[i]).

   IDX is bookkeeping for the tile explosion (see %emit-map-vjp-explode) and is inert here: by
   the time this analyzer runs, both operands are already single fragments."
  (unless (member (length (cdr expr)) '(3 4))
    (error 'crisp-compiler-error
           :message (format nil "%map-elements-vjp!: expects 3 or 4 arguments (adj primal #'fn-grad [idx]), got ~a."
                            (length (cdr expr)))
           :source-location location))
  (destructuring-bind (adj primal fn-form &optional idx) (cdr expr)
    (declare (ignore idx))
    (let* ((adj-node (analyze-expression adj env context location))
           (ty       (get-single-value-type adj-node))
           (nf       (%map-elements-fragment-fields ty))
           (coop     (%map-elements-coop-dims ty))
           (gname    (or (%map-elements-fn-name fn-form)
                         (error 'crisp-compiler-error
                                :message "%map-elements-vjp!: the gradient callee must be a #'NAME form."
                                :source-location location))))
      (cond
        (nf
         (analyze-expression
          `(set! ,adj
                 (%construct-struct ,ty
                                    ,@(loop for i below nf
                                            collect `(,gname (%extract-struct-member ,primal ,i)
                                                             (%extract-struct-member ,adj ,i)))))
          env context location))
        (coop
         (unless (and (symbolp adj) (symbolp primal))
           (error 'crisp-compiler-error
                  :message "%map-elements-vjp!: on SPIR-V both operands must be cooperative-matrix VARIABLES."
                  :source-location location))
         (destructuring-bind (rows cols use) coop
           (let* ((tp (gensym "CMPRM"))
                  (ta (gensym "CMADJ"))
                  (env2 (list* (make-parameter-def :name tp :type 'float :kind :local)
                               (make-parameter-def :name ta :type 'float :kind :local)
                               env))
                  (body-node (analyze-expression (list gname tp ta) env2 context location)))
             (make-semantic-coop-op
              :type 'void :kind :map2
              :ty adj :tx primal :layout (list tp ta) :tensor-node body-node
              :rows rows :cols cols :use use
              :source-location location))))
        (t
         (error 'crisp-compiler-error
                :message (format nil "%map-elements-vjp!: unsupported operand type ~a." ty)
                :source-location location))))))


;;; =====================================================================
;;; Endeavor 152 Phase 1 — (declare (cluster-size ...))
;;;
;;; Front half: parse, validate, store, and stamp the cluster dimensions onto the
;;; PTX entry point.  The hoist half (cudaLaunchKernelEx + the divisibility
;;; pad/error policy) and the metadata half land separately.
;;;
;;; MEASURED FACTS this is built on
;;; (tests/spec/152-DSMEM-Cluster/00-verification-findings.md):
;;;   * gridDim % clusterDim == 0 is enforced PER AXIS by the driver as a hard
;;;     launch error (cudaErrorInvalidClusterSize) -- not a warning, not a clamp.
;;;   * portable max extent is 8; 16 needs cudaFuncAttributeNonPortableClusterSizeAllowed.
;;;   * LLVM 21.1.5 honours BOTH !nvvm.annotations cluster_dim_{x,y,z} AND the
;;;     "nvvm.cluster_dim"="x,y,z" function attribute; each ALONE yields
;;;     `.explicitcluster` + `.reqnctapercluster x, y, z`.  We use the ATTRIBUTE
;;;     form: nvvm.annotations is on LLVM's deprecation path, and one string
;;;     attribute beats three metadata nodes.
;;; =====================================================================

;; src/analysis/control.lisp  (new)
(defun %parse-cluster-size-decl (decl kernel-name declarations)
  "Validate a (cluster-size ...) declaration and return its dims as a 3-list (x y z),
   padding absent axes with 1.  Returns NIL when DECL is NIL.

   Refuses, with a message that says WHY rather than merely that a key is unknown:
     * :derive-from  -- cluster-size is consumed at CODEGEN, so its shape cannot come
                        from a host-side runtime value.  Every sibling declaration in
                        the enqueue family is advisory; this one is not.
     * a missing or non-integer :set-to
     * rank > 3, or rank exceeding an explicit :tile-shape
     * extent > 8 (the portable maximum; 16 needs a non-portable opt-in the hoist
                   does not yet emit)"
  (when decl
    (let* ((opts   (cdr decl))
           (set-to (getf opts :set-to))
           (derive (getf opts :derive-from)))
      (when derive
        (error 'crisp-compiler-error
               :message (format nil "cluster-size does not support :derive-from (kernel ~a).  Unlike global-size / local-size, which only advise the hoisting code, cluster-size is consumed at code generation -- it decides the multicast mask, the leader predicate, and the cluster dimensions baked into the PTX -- so its shape cannot be computed from a host-side runtime value.  Use :set-to with a compile-time literal."
                                kernel-name)))
      (unless set-to
        (error 'crisp-compiler-error
               :message (format nil "cluster-size requires :set-to (kernel ~a), e.g. (cluster-size :set-to 2) or (cluster-size :set-to (2 1))."
                                kernel-name)))
      ;; Accept the scalar shorthand, following (local-size :set-to 256).  Tolerate a
      ;; quoted list too -- the docs show both (2 1) and '(2 2) in the wild.
      (let* ((raw  (if (and (consp set-to) (eq (car set-to) 'quote)) (second set-to) set-to))
             (dims (if (listp raw) raw (list raw))))
        (unless (and dims (every (lambda (d) (and (integerp d) (plusp d))) dims))
          (error 'crisp-compiler-error
                 :message (format nil "cluster-size :set-to must be a positive compile-time integer or a list of them (kernel ~a), got ~S."
                                  kernel-name set-to)))
        (when (> (length dims) 3)
          (error 'crisp-compiler-error
                 :message (format nil "cluster-size has rank ~a (kernel ~a); the maximum is 3."
                                  (length dims) kernel-name)))
        ;; Rank must agree with an EXPLICIT :tile-shape, mirroring the existing rule that
        ;; global-size and local-size must agree in arity.  Axes beyond the declared rank
        ;; default to 1, so an UNDER-specified cluster rank is legal -- only an
        ;; over-specified one is an error.
        ;;
        ;; TODO(152): an INFERRED :tile-shape (Endeavor 143, %ts-maybe-infer-tile-shape)
        ;; is not visible here -- inference runs during body analysis, after this point.
        ;; A kernel that relies on inference therefore escapes this check.  Move the rank
        ;; comparison to a post-inference pass when the multicast axis analysis lands,
        ;; since that pass needs the same information.
        (let* ((gs (find "GLOBAL-SIZE" declarations
                         :key (lambda (x) (when (consp x) (symbol-name (car x))))
                         :test #'string-equal))
               (ts (and gs (getf (cdr gs) :tile-shape))))
          (when (and ts (listp ts) (> (length dims) (length ts)))
            (error 'crisp-compiler-error
                   :message (format nil "cluster-size rank ~a exceeds the :tile-shape rank ~a (kernel ~a).  Cluster axes are interpreted in the tile grid's axis order, so a cluster axis with no corresponding tile axis has nothing to cluster along.  Axes beyond the tile-shape rank default to 1, so a SHORTER cluster-size is fine; a longer one is not."
                                    (length dims) (length ts) kernel-name))))
        (let ((total (reduce (function *) dims)))
          (when (> total 8)
            (error 'crisp-compiler-error
                   :message (format nil "cluster-size ~a gives ~a workgroups per cluster (kernel ~a); the portable maximum is 8.  Larger clusters (16 on Hopper) require cudaFuncAttributeNonPortableClusterSizeAllowed to be set at launch, which Crisp does not yet emit."
                                    dims total kernel-name))))
        ;; Normalise to 3 axes so codegen and the hoist never re-derive the padding.
        (let ((d (copy-list dims)))
          (loop while (< (length d) 3) do (setf d (append d (list 1))))
          (log:info "Kernel ~a: cluster-size ~a -> normalised dims ~a" kernel-name dims d)
          d)))))

;; src/analysis/core.lisp
(defun internal-def-function (name params declarations body location)
  "Wrapper around internal-compile-function. Detects kernel entry-points and
   binds *boundary-struct-params*, *boundary-array-params*, and
   *in-dispatch-context* to enforce kernel-boundary rules.
   Extended to capture global-size/local-size/num-groups dispatch declarations.
   Extended (091) to handle (grid-function) declaration: sets dispatch context,
   validates void return type.
   Endeavor 152: also captures and validates (cluster-size ...), storing the
   NORMALISED 3-axis dims under :cluster-size so codegen and the hoist share one
   representation.
   Note: ANF pre-processing removed from forward pass — backward pass applies
   its own anf-transform in %generate-backward-function-ast."
  (log:info "Analyzing function ~s" name)

  (multiple-value-bind (explicit-env return-type)
      (parse-function-declarations params declarations)
    (let* ((*compiler-context* (or *compiler-context* (make-compiler-context)))
           (is-entry-p (loop for d in declarations
                             thereis (and (listp d)
                                          (symbolp (first d))
                                          (string-equal (symbol-name (first d)) "ENTRY-POINT"))))
           (is-grid-fn-p (loop for d in declarations
                               thereis (and (listp d)
                                            (symbolp (first d))
                                            (string-equal (symbol-name (first d)) "GRID-FUNCTION"))))
           (*in-dispatch-context* (or is-entry-p is-grid-fn-p))
           (*boundary-struct-params*
             (if is-entry-p
                 (loop for param in explicit-env
                       when (%boundary-struct-type-p (parameter-def-type param))
                       collect (string-upcase (symbol-name (parameter-def-name param))))
                 *boundary-struct-params*))
           (*boundary-array-params*
             (if is-entry-p
                 (loop for param in explicit-env
                       when (%array-type-p (parameter-def-type param))
                       collect (string-upcase (symbol-name (parameter-def-name param))))
                 *boundary-array-params*)))
      (when (and is-entry-p *boundary-struct-params*)
            (log:debug "Kernel ~a has boundary struct params: ~a" name *boundary-struct-params*))
      (when (and is-entry-p *boundary-array-params*)
            (log:debug "Kernel ~a has boundary array params: ~a" name *boundary-array-params*))

      ;; Void return type enforcement for grid functions
      (when is-grid-fn-p
        (log:info "Compiling grid function ~a (dispatch context)" name)
        (%validate-grid-function-return-type return-type))

      ;; Extract and store dispatch declarations for entry-point kernels
      (when is-entry-p
        (let* ((global-size-decl (find "GLOBAL-SIZE" declarations
                                       :key (lambda (x) (when (consp x) (symbol-name (car x))))
                                       :test #'string-equal))
               (local-size-decl  (find "LOCAL-SIZE" declarations
                                       :key (lambda (x) (when (consp x) (symbol-name (car x))))
                                       :test #'string-equal))
               (num-groups-decl  (find "NUM-GROUPS" declarations
                                       :key (lambda (x) (when (consp x) (symbol-name (car x))))
                                       :test #'string-equal))
               (cluster-size-decl (find "CLUSTER-SIZE" declarations
                                        :key (lambda (x) (when (consp x) (symbol-name (car x))))
                                        :test #'string-equal))
               ;; Validated HERE, at declaration time, so a malformed cluster-size is
               ;; reported before any code generation has run.
               (cluster-dims (%parse-cluster-size-decl cluster-size-decl name declarations)))
          (when (or global-size-decl local-size-decl num-groups-decl cluster-size-decl)
            (let ((dispatch-plist
                    (append (when global-size-decl (list :global-size global-size-decl))
                            (when local-size-decl  (list :local-size  local-size-decl))
                            (when num-groups-decl  (list :num-groups  num-groups-decl))
                            (when cluster-size-decl (list :cluster-size-decl cluster-size-decl))
                            (when cluster-dims      (list :cluster-size cluster-dims)))))
              (log:info "Kernel ~a: storing dispatch declarations ~a" name dispatch-plist)
              (setf (gethash name *kernel-dispatch-declarations*) dispatch-plist)))
          ;; Endeavor 130 Phase 1: validate the workgroup (local-size) bounds against
          ;; the active hardware profile, when one is selected and local-size is
          ;; compile-time-known.  active-hardware-profile also errors here if the
          ;; --hardware-profile flag names a profile that isn't registered.
          (%hp-check-workgroup-bounds name local-size-decl (active-hardware-profile))))

      (internal-compile-function name explicit-env return-type params body declarations location *compiler-context*))))

;; src/codegen.lisp  (new)
(defun %apply-cluster-dims-attribute (func semantic-function module)
  "Endeavor 152: stamp the cluster dimensions on a PTX entry point.

   Emits the nvvm.cluster_dim function attribute, which LLVM 21 lowers to
   .explicitcluster + .reqnctapercluster x, y, z on the .entry.  Baking the shape into
   the PTX is what makes the host/kernel agreement DRIVER-ENFORCED rather than a
   convention the hoisting code is trusted to honour.

   PTX only.  On SPIR-V the declaration degrades to extent 1; the diagnostic for that
   is emitted separately (it is a performance trap, not an error -- see rung 05)."
  (when (eq *target-backend* :ptx)
    (let* ((kname (semantic-function-name semantic-function))
           (decls (and kname (gethash kname *kernel-dispatch-declarations*)))
           (dims  (and decls (getf decls :cluster-size))))
      (when (and dims (> (reduce (function *) dims) 1))
        (let* ((ctx  (llvm-get-module-context module))
               (key  "nvvm.cluster_dim")
               (val  (format nil "~{~a~^,~}" dims))
               (attr (llvm-create-string-attribute ctx key (length key) val (length val))))
          (log:info "Kernel ~a: stamping cluster dims ~a (.reqnctapercluster)" kname val)
          (llvm-add-attribute-at-index func +llvm-attribute-function-index+ attr))))))

;; src/codegen.lisp
(defun ensure-opencl-kernel-metadata (func semantic-function module)
  "Marks a function as a SPIR-V/PTX kernel if it's an entry point.
   Sets the appropriate calling convention (76 for SPIR-V, 71 for PTX).
   Endeavor 126: also stamps the denormal-fp-math attribute (all functions).
   Endeavor 152: stamps cluster dimensions on PTX entry points.

   NOTE: Kernel argument metadata (address space, access qualifiers, etc.) is added
   as text during IR printing for SPIR-V."
  (%apply-denormal-attribute func module)
  (when (semantic-function-is-entry-point semantic-function)
        (log:info "Marking function ~a as Kernel for backend ~a"
                  (semantic-function-name semantic-function) *target-backend*)

        (case *target-backend*
          (:spirv
           ;; calling convention spir_kernel (76)
           (llvm-set-function-call-conv func 76)
           ;; Endeavor 126: denormal handling reaches SPIR-V only via an execution mode.
           (%emit-spirv-denorm-execution-mode func module))
          (:ptx
           ;; Use ptx_kernel calling convention (71) so llc emits .entry
           ;; If this crashes on Windows, we will need to revisit nvvm attributes.
           (log:info "Setting CC 71 (ptx_kernel) for function ~a" (semantic-function-name semantic-function))
           (llvm-set-function-call-conv func 71)
           (%apply-cluster-dims-attribute func semantic-function module))
          (t
           ;; Default to C calling convention (0) for generic/unknown
           (log:warn "Using default CC (0) for kernel in backend ~a" *target-backend*)
           (llvm-set-function-call-conv func 0))))

  (unless (semantic-function-is-entry-point semantic-function)
    (case *target-backend*
      (:spirv
       ;; Use SPIR_FUNC (75) for non-kernel functions
       (llvm-set-function-call-conv func 75)))))


;;; =====================================================================
;;; Endeavor 152 Phase 1 (cont.) — arch gating, degrade diagnostic, metadata
;;;
;;; FIXES A BUG IN THE FIRST CUT: %apply-cluster-dims-attribute gated on
;;; (eq *target-backend* :ptx) alone, so a default-arch compile (sm_80) would
;;; stamp .reqnctapercluster on a target that cannot form clusters.  Nothing
;;; caught it because the spec suite only checks that the kernel COMPILES --
;;; the invalid directive would not have surfaced until ptxas or the JIT.
;;; Clusters need sm_90+, so the gate is now capability-based.
;;; =====================================================================

;; src/types/registry.lisp  (new)
(defun %arch-supports-clusters-p (arch)
  "T if ARCH can form workgroup clusters.  NVIDIA Hopper (sm_90) or later only;
   no Intel architecture has an equivalent."
  (and (eq (%arch-vendor arch) :nvidia)
       (let ((n (%arch-sm-number arch)))
         (and n (>= n 90)))))

;; src/analysis/control.lisp  (new)
(defun %effective-cluster-dims (declared)
  "The cluster dims the compiler ACTUALLY built, as opposed to what the source asked for.

   These are two different facts and the metadata reports BOTH: on a target without
   cluster support the declared shape is still (2 1) while the effective shape is
   (1 1 1).  Reporting only the declaration would make a silently-degraded kernel
   indistinguishable from a working one -- which is the 143 failure class, where a
   benchmark read 69.65 TFLOPS for a kernel running at 1.40."
  (if (and declared
           (eq *target-backend* :ptx)
           (%arch-supports-clusters-p (or *ir-target-arch* :sm_80)))
      declared
      (list 1 1 1)))

;; src/codegen.lisp  (new)
(defvar *cluster-degrade-warned* (make-hash-table :test #'eq)
  "Kernels we have already emitted the cluster-degrade diagnostic for, so a
   multi-pass compile does not repeat it once per pass.")

;; src/codegen.lisp  (new)
(defun %warn-cluster-degraded (kernel-name declared)
  "Endeavor 152 rung 05: a kernel declaring cluster-size on a target without cluster
   support still computes the correct answer -- every multicast becomes an ordinary
   per-workgroup load and the traffic reduction the declaration was written for is
   simply gone, with nothing in the output to reveal it.

   Unlike sync-cluster, whose degrade to sync-workgroup is semantically exact and free,
   THIS degrade costs bandwidth.  So it is never silent."
  (unless (gethash kernel-name *cluster-degrade-warned*)
    (setf (gethash kernel-name *cluster-degrade-warned*) t)
    (log:warn "Kernel ~a declares (cluster-size :set-to ~a) but the selected target (~a~@[/~a~]) has no cluster support -- the effective cluster extent is 1.  The kernel is still CORRECT, but any multicast becomes an ordinary per-workgroup load and the bandwidth reduction is lost.  Clusters require NVIDIA sm_90 or later.  The effective extent is recorded in the kernel metadata; assert on that rather than on a timing number."
              kernel-name declared *target-backend*
              (and (eq *target-backend* :ptx) *ir-target-arch*))))

;; src/codegen.lisp
(defun %apply-cluster-dims-attribute (func semantic-function module)
  "Endeavor 152: stamp the cluster dimensions on a PTX entry point.

   Emits the nvvm.cluster_dim function attribute, which LLVM 21 lowers to
   .explicitcluster + .reqnctapercluster x, y, z on the .entry.  Baking the shape into
   the PTX is what makes the host/kernel agreement DRIVER-ENFORCED rather than a
   convention the hoisting code is trusted to honour.

   Gated on CAPABILITY, not merely on the backend: clusters need sm_90+, so a default
   (sm_80) PTX compile degrades to extent 1 and warns rather than emitting a directive
   the target cannot honour."
  (let* ((kname (semantic-function-name semantic-function))
         (decls (and kname (gethash kname *kernel-dispatch-declarations*)))
         (dims  (and decls (getf decls :cluster-size))))
    (when (and dims (> (reduce (function *) dims) 1))
      (cond
        ((and (eq *target-backend* :ptx)
              (%arch-supports-clusters-p (or *ir-target-arch* :sm_80)))
         (let* ((ctx  (llvm-get-module-context module))
                (key  "nvvm.cluster_dim")
                (val  (format nil "~{~a~^,~}" dims))
                (attr (llvm-create-string-attribute ctx key (length key) val (length val))))
           (log:info "Kernel ~a: stamping cluster dims ~a (.reqnctapercluster)" kname val)
           (llvm-add-attribute-at-index func +llvm-attribute-function-index+ attr)))
        (t
         (%warn-cluster-degraded kname dims))))))

;; src/metadata.lisp
(defun serialize-kernels (output-stream kernel-names &key source output-targets)
  "Emits the (:kernels ...) section of the metacrisp file.
   Extended to include :global-size, :local-size, :num-groups dispatch declarations.
   Endeavor 152: also emits :cluster-size (what the SOURCE asked for) and
   :effective-cluster-size (what the compiler BUILT).  Both, deliberately -- a
   degraded cluster is otherwise indistinguishable from a working one."
  (when kernel-names
        (format output-stream "(:kernels~%")
        (dolist (k-name (sort (copy-list kernel-names) (function string<) :key (function symbol-name)))
          (let ((sigs (gethash k-name *function-table*))
                (blocks-to-emit nil))
            ;; Use only the FIRST signature (Pass 1 registered, Pass 2 updated)
            (dolist (actual-sig (list (first sigs)))
              (when actual-sig
                    (let* ((phys-sig-str (generate-physical-signature actual-sig))
                           (declared-types (gethash k-name *kernel-declared-signatures*))
                           (decl-sig-list (generate-declared-signature actual-sig declared-types))
                           (implicit-sig-list (generate-implicit-signature actual-sig declared-types))
                           (dispatch-info (gethash k-name *kernel-dispatch-declarations*))
                           (source-loc (if source source
                                           (namestring (uiop/filesystem:native-namestring (first (function-signature-source-location actual-sig)))))))

                      (push (list :name (string-downcase (symbol-name k-name))
                                  :source source-loc
                                  :output output-targets
                                  :phys phys-sig-str
                                  :decl decl-sig-list
                                  :impl implicit-sig-list
                                  :dispatch dispatch-info)
                            blocks-to-emit))))

            (setf blocks-to-emit (remove-duplicates (nreverse blocks-to-emit) :test (function equalp)))

            (dolist (blk blocks-to-emit)
              (let ((dispatch (getf blk :dispatch)))
                (format output-stream "  (:name ~s~%" (getf blk :name))
                (format output-stream "    :source ~s~%" (pathname (getf blk :source)))
                (when (getf blk :output) (format output-stream "    :output-targets ~s~%" (getf blk :output)))
                ;; Emit dispatch declarations before physical/declared signatures
                (let ((global-size-decl (getf dispatch :global-size))
                      (local-size-decl  (getf dispatch :local-size))
                      (num-groups-decl  (getf dispatch :num-groups))
                      (cluster-decl     (getf dispatch :cluster-size-decl))
                      (cluster-dims     (getf dispatch :cluster-size)))
                  (when global-size-decl
                    (format output-stream "    :global-size ")
                    (print-without-packages global-size-decl output-stream)
                    (format output-stream "~%"))
                  (when local-size-decl
                    (format output-stream "    :local-size ")
                    (print-without-packages local-size-decl output-stream)
                    (format output-stream "~%"))
                  (when num-groups-decl
                    (format output-stream "    :num-groups ")
                    (print-without-packages num-groups-decl output-stream)
                    (format output-stream "~%"))
                  ;; Endeavor 152.  BOTH are emitted on purpose:
                  ;;   :cluster-size            -- the declaration, as written
                  ;;   :effective-cluster-size  -- what this target actually built
                  ;; They differ exactly when the kernel degraded, which is the one
                  ;; case a correctness test cannot see.
                  (when cluster-decl
                    (format output-stream "    :cluster-size ")
                    (print-without-packages cluster-decl output-stream)
                    (format output-stream "~%"))
                  (when cluster-dims
                    (format output-stream "    :effective-cluster-size ")
                    (print-without-packages (%effective-cluster-dims cluster-dims) output-stream)
                    (format output-stream "~%")))
                (format output-stream "    :physical-signature ~a~%" (getf blk :phys))
                (format output-stream "    :declared-signature ")
                (print-without-packages (getf blk :decl) output-stream)
                (format output-stream "~%")
                (when (getf blk :impl)
                      (format output-stream "    :implicit-params ")
                      (print-without-packages (getf blk :impl) output-stream)
                      (format output-stream "~%"))
                (format output-stream "  )~%"))))
        (format output-stream "  )~%"))))


;;; =====================================================================
;;; Endeavor 152 Phase 1 (fix) — record the EFFECTIVE cluster extent at codegen
;;;
;;; The previous cut re-derived the effective extent inside serialize-kernels from
;;; *target-backend* / *ir-target-arch*.  That reads the WRONG dynamic state: the
;;; metacrisp is written outside the codegen pass, where *target-backend* is back to
;;; its :generic default -- so a correct sm_90 kernel whose PTX carried
;;; `.reqnctapercluster 4, 1, 1` was reported in metadata as effective (1 1 1).
;;; Precisely the "silently degraded" reading the field exists to make impossible,
;;; produced by the field itself.
;;;
;;; So: record what codegen ACTUALLY DID, at the moment it does it, rather than
;;; re-deriving it afterwards from state that has since changed.
;;;
;;; Stored in the kernel's *kernel-dispatch-declarations* plist rather than a side
;;; table, which gets the lifecycle for free -- that table is cleared per module
;;; (src/compiler.lisp), and the spec runner compiles many files IN-PROCESS with
;;; kernel names like `matmul` recurring, so a side table keyed by symbol would leak
;;; one spec's answer into the next.
;;; =====================================================================

;; src/codegen.lisp  (new)
(defun %record-effective-cluster-dims (kernel-name dims)
  "Write the effective cluster extent into KERNEL-NAME's dispatch plist.
   Returns T if this is the first time (so the caller may warn once)."
  (let* ((plist (gethash kernel-name *kernel-dispatch-declarations*))
         (first-time (null (getf plist :effective-cluster-size))))
    (when plist
      (setf (getf plist :effective-cluster-size) dims)
      (setf (gethash kernel-name *kernel-dispatch-declarations*) plist))
    first-time))

;; src/codegen.lisp
(defun %apply-cluster-dims-attribute (func semantic-function module)
  "Endeavor 152: stamp the cluster dimensions on a PTX entry point, and record what
   was actually built.

   Emits the nvvm.cluster_dim function attribute, which LLVM 21 lowers to
   .explicitcluster + .reqnctapercluster x, y, z on the .entry.  Baking the shape into
   the PTX is what makes the host/kernel agreement DRIVER-ENFORCED rather than a
   convention the hoisting code is trusted to honour.

   Gated on CAPABILITY, not merely on the backend: clusters need sm_90+, so a default
   (sm_80) PTX compile degrades to extent 1 and warns rather than emitting a directive
   the target cannot honour."
  (let* ((kname (semantic-function-name semantic-function))
         (decls (and kname (gethash kname *kernel-dispatch-declarations*)))
         (dims  (and decls (getf decls :cluster-size))))
    (when (and dims (> (reduce (function *) dims) 1))
      (cond
        ((and (eq *target-backend* :ptx)
              (%arch-supports-clusters-p (or *ir-target-arch* :sm_80)))
         (let* ((ctx  (llvm-get-module-context module))
                (key  "nvvm.cluster_dim")
                (val  (format nil "~{~a~^,~}" dims))
                (attr (llvm-create-string-attribute ctx key (length key) val (length val))))
           (log:info "Kernel ~a: stamping cluster dims ~a (.reqnctapercluster)" kname val)
           (llvm-add-attribute-at-index func +llvm-attribute-function-index+ attr)
           (%record-effective-cluster-dims kname dims)))
        (t
         (when (%record-effective-cluster-dims kname (list 1 1 1))
           (%warn-cluster-degraded kname dims)))))))

;; src/analysis/control.lisp
(defun %effective-cluster-dims (dispatch declared)
  "The cluster dims codegen ACTUALLY built for this kernel, as recorded by
   %apply-cluster-dims-attribute.

   Falls back to (1 1 1) when no codegen pass ever stamped one -- which is the honest
   answer, since a kernel whose PTX carries no cluster directive forms clusters of one.
   DECLARED is accepted for symmetry with the caller but deliberately NOT used as a
   fallback: reporting the declaration as though it were the outcome is the exact
   confusion this field exists to prevent."
  (declare (ignore declared))
  (or (getf dispatch :effective-cluster-size) (list 1 1 1)))

;; src/metadata.lisp
(defun serialize-kernels (output-stream kernel-names &key source output-targets)
  "Emits the (:kernels ...) section of the metacrisp file.
   Extended to include :global-size, :local-size, :num-groups dispatch declarations.
   Endeavor 152: also emits :cluster-size (what the SOURCE asked for) and
   :effective-cluster-size (what codegen BUILT).  Both, deliberately -- a degraded
   cluster is otherwise indistinguishable from a working one."
  (when kernel-names
        (format output-stream "(:kernels~%")
        (dolist (k-name (sort (copy-list kernel-names) (function string<) :key (function symbol-name)))
          (let ((sigs (gethash k-name *function-table*))
                (blocks-to-emit nil))
            ;; Use only the FIRST signature (Pass 1 registered, Pass 2 updated)
            (dolist (actual-sig (list (first sigs)))
              (when actual-sig
                    (let* ((phys-sig-str (generate-physical-signature actual-sig))
                           (declared-types (gethash k-name *kernel-declared-signatures*))
                           (decl-sig-list (generate-declared-signature actual-sig declared-types))
                           (implicit-sig-list (generate-implicit-signature actual-sig declared-types))
                           (dispatch-info (gethash k-name *kernel-dispatch-declarations*))
                           (source-loc (if source source
                                           (namestring (uiop/filesystem:native-namestring (first (function-signature-source-location actual-sig)))))))

                      (push (list :name (string-downcase (symbol-name k-name))
                                  :source source-loc
                                  :output output-targets
                                  :phys phys-sig-str
                                  :decl decl-sig-list
                                  :impl implicit-sig-list
                                  :dispatch dispatch-info)
                            blocks-to-emit))))

            (setf blocks-to-emit (remove-duplicates (nreverse blocks-to-emit) :test (function equalp)))

            (dolist (blk blocks-to-emit)
              (let ((dispatch (getf blk :dispatch)))
                (format output-stream "  (:name ~s~%" (getf blk :name))
                (format output-stream "    :source ~s~%" (pathname (getf blk :source)))
                (when (getf blk :output) (format output-stream "    :output-targets ~s~%" (getf blk :output)))
                ;; Emit dispatch declarations before physical/declared signatures
                (let ((global-size-decl (getf dispatch :global-size))
                      (local-size-decl  (getf dispatch :local-size))
                      (num-groups-decl  (getf dispatch :num-groups))
                      (cluster-decl     (getf dispatch :cluster-size-decl))
                      (cluster-dims     (getf dispatch :cluster-size)))
                  (when global-size-decl
                    (format output-stream "    :global-size ")
                    (print-without-packages global-size-decl output-stream)
                    (format output-stream "~%"))
                  (when local-size-decl
                    (format output-stream "    :local-size ")
                    (print-without-packages local-size-decl output-stream)
                    (format output-stream "~%"))
                  (when num-groups-decl
                    (format output-stream "    :num-groups ")
                    (print-without-packages num-groups-decl output-stream)
                    (format output-stream "~%"))
                  ;; Endeavor 152.  BOTH are emitted on purpose:
                  ;;   :cluster-size            -- the declaration, as written
                  ;;   :effective-cluster-size  -- what codegen actually built
                  ;; They differ exactly when the kernel degraded, which is the one
                  ;; case a correctness test cannot see.
                  (when cluster-decl
                    (format output-stream "    :cluster-size ")
                    (print-without-packages cluster-decl output-stream)
                    (format output-stream "~%"))
                  (when cluster-dims
                    (format output-stream "    :effective-cluster-size ")
                    (print-without-packages (%effective-cluster-dims dispatch cluster-dims) output-stream)
                    (format output-stream "~%")))
                (format output-stream "    :physical-signature ~a~%" (getf blk :phys))
                (format output-stream "    :declared-signature ")
                (print-without-packages (getf blk :decl) output-stream)
                (format output-stream "~%")
                (when (getf blk :impl)
                      (format output-stream "    :implicit-params ")
                      (print-without-packages (getf blk :impl) output-stream)
                      (format output-stream "~%"))
                (format output-stream "  )~%"))))
        (format output-stream "  )~%"))))


;;; =====================================================================
;;; Endeavor 152 Phase 1 (fix 2) — the degrade diagnostic must fire on SPIR-V too
;;;
;;; %apply-cluster-dims-attribute was called only from the :ptx branch of
;;; ensure-opencl-kernel-metadata, so an Intel/SPV compile of a clustered kernel
;;; degraded SILENTLY: the metacrisp still read (1 1 1), but only because
;;; %effective-cluster-dims falls back to that when nothing was recorded -- the
;;; right answer arrived by accident rather than by decision, and no warning was
;;; emitted at all.  SPIR-V is the single most likely place for a user to hit this,
;;; since it is the target with no cluster hardware whatsoever.
;;;
;;; The function already gates on capability internally, so it is safe to call for
;;; every entry point regardless of backend.  Hoisting the call out of the `case`
;;; is both the smaller change and the one that cannot drift again.
;;; =====================================================================

;; src/codegen.lisp
(defun ensure-opencl-kernel-metadata (func semantic-function module)
  "Marks a function as a SPIR-V/PTX kernel if it's an entry point.
   Sets the appropriate calling convention (76 for SPIR-V, 71 for PTX).
   Endeavor 126: also stamps the denormal-fp-math attribute (all functions).
   Endeavor 152: stamps cluster dimensions on capable PTX entry points, and records
   the EFFECTIVE extent (warning on degrade) for every entry point on every backend.

   NOTE: Kernel argument metadata (address space, access qualifiers, etc.) is added
   as text during IR printing for SPIR-V."
  (%apply-denormal-attribute func module)
  (when (semantic-function-is-entry-point semantic-function)
        (log:info "Marking function ~a as Kernel for backend ~a"
                  (semantic-function-name semantic-function) *target-backend*)

        (case *target-backend*
          (:spirv
           ;; calling convention spir_kernel (76)
           (llvm-set-function-call-conv func 76)
           ;; Endeavor 126: denormal handling reaches SPIR-V only via an execution mode.
           (%emit-spirv-denorm-execution-mode func module))
          (:ptx
           ;; Use ptx_kernel calling convention (71) so llc emits .entry
           ;; If this crashes on Windows, we will need to revisit nvvm attributes.
           (log:info "Setting CC 71 (ptx_kernel) for function ~a" (semantic-function-name semantic-function))
           (llvm-set-function-call-conv func 71))
          (t
           ;; Default to C calling convention (0) for generic/unknown
           (log:warn "Using default CC (0) for kernel in backend ~a" *target-backend*)
           (llvm-set-function-call-conv func 0)))

        ;; Endeavor 152: OUTSIDE the case on purpose.  This must run for every entry
        ;; point on every backend -- it is what records the effective cluster extent
        ;; and warns when a declared cluster could not be formed.  Gating it per
        ;; backend is what let the SPIR-V degrade go silent.
        (%apply-cluster-dims-attribute func semantic-function module))

  (unless (semantic-function-is-entry-point semantic-function)
    (case *target-backend*
      (:spirv
       ;; Use SPIR_FUNC (75) for non-kernel functions
       (llvm-set-function-call-conv func 75)))))


;;; =====================================================================
;;; Endeavor 152 Phase 2 (front end) — `:multicast` validation
;;;
;;; THE RULE, and it is NOT "the coordinate must be a compile-time constant".
;;; That was the first instinct and it would have refused exactly the load this
;;; endeavour exists to accelerate.  In the shipped matmul:
;;;
;;;     (load-tile B (ring-get B-ring slot) (grid-x grid-k) ...)   ; WANT multicast
;;;
;;; coordinate 0 is `grid-x`, not a constant.  With a (2 1) cluster the two
;;; workgroups differ in `grid-y`, and B's coordinates never mention `grid-y` --
;;; so both want the SAME tile and one fetch serves both.
;;;
;;; The correct test is therefore: **does any coordinate mention the tile-stride
;;; variable bound to a CLUSTERED axis?**
;;;
;;;     (0 grid-x)        cluster (2 1)  -> no grid-y  -> multicast          (rung 10)
;;;     (grid-y grid-x)   cluster (2 1)  -> mentions   -> REFUSE          (errors/11)
;;;     (grid-x grid-k)   cluster (2 1)  -> no grid-y  -> multicast     (real B load)
;;;
;;; WHY THE CHECK LIVES IN load-tile AND NOT load-tile-at.  `load-tile` delegates to
;;; `load-tile-at` after multiplying each grid coord by the tile extent, so by then the
;;; coordinate is `(* (to-ulong grid-y) (~ (extents~ tile) 0))` and the dependency is
;;; buried in arithmetic.  The raw grid coords exist only here.  (That is also a second,
;;; independent reason `load-tile-at` refuses `:multicast` outright -- the first being
;;; that absolute element coords cannot be proven cluster-invariant at all.)
;;;
;;; DELIBERATELY NO ARCH CHECK HERE.  Refusing on a non-sm_90 target would make the two
;;; error specs -- which carry no target directives and so run on the default target --
;;; fail for the wrong reason.  Arch gating belongs with the lowering.
;;; =====================================================================

;; src/analysis/control.lisp  (new)
(defvar *ts-grid-bindings* nil
  "The enclosing tile-stride's loop variables, IN AXIS ORDER, during analysis of its body.
   Endeavor 152: the multicast eligibility test needs to know which symbol is bound to a
   clustered axis.  Nothing else tracked this.")

;; src/analysis/control.lisp  (new)
(defvar *current-kernel-cluster-dims* nil
  "The normalised (x y z) cluster dims of the kernel currently being analysed, or NIL.
   Bound by internal-def-function so a load-tile deep in the body can consult it without
   having to rediscover which kernel it is inside.")

;; src/analysis/control.lisp  (new)
(defun %form-mentions-symbol-p (form sym)
  "T if SYM appears anywhere in FORM.  Symbol identity, not name equality -- a coordinate
   built from a DIFFERENT variable that happens to share a name is a different variable."
  (cond
    ((null form) nil)
    ((symbolp form) (eq form sym))
    ((consp form) (or (%form-mentions-symbol-p (car form) sym)
                      (%form-mentions-symbol-p (cdr form) sym)))
    (t nil)))

;; src/analysis/control.lisp  (new)
(defun %multicast-requested-p (key-args)
  "T if KEY-ARGS asks for a multicast.

   Crisp has no boolean literal yet -- `true` and `false` are still pending -- so the value
   arrives as a bare symbol and a naive non-NIL test would read `:multicast false` as a
   REQUEST.  Treat NIL and anything named FALSE as 'no'.  When the real literals land this
   predicate keeps working unchanged."
  (let ((v (%extract-key-arg key-args :multicast nil)))
    (and v
         (not (and (symbolp v) (string-equal (symbol-name v) "FALSE"))))))

;; src/analysis/control.lisp  (new)
(defun %validate-multicast-request (grid-list location)
  "Refuse a `:multicast` that cannot be honoured, naming the reason.

   `:multicast` is an ASSERTION, not a directive: the user says 'I expect this load to
   multicast' and the compiler either does it or refuses.  A load that quietly declined
   would be a silent 2x bandwidth regression that no correctness test can see -- which is
   the whole reason the key is explicit rather than inferred."
  (let ((dims *current-kernel-cluster-dims*))
    (unless dims
      (error 'crisp-compiler-error
             :message ":multicast requires the kernel to declare a cluster.  Add (cluster-size :set-to N) to the kernel's declare block -- without a cluster there is no group of workgroups to deliver the tile to, so the request cannot be honoured.  This is a hard error rather than a silent fallback because a load-tile that quietly declines to multicast still computes the correct answer, at exactly the bandwidth the declaration was meant to avoid."
             :source-location location))
    (unless (> (reduce (function *) dims) 1)
      (error 'crisp-compiler-error
             :message (format nil ":multicast requires a cluster extent greater than 1, but this kernel's cluster-size is ~a (one workgroup).  There is no peer to share the fetch with."
                              dims)
             :source-location location))
    ;; For every CLUSTERED axis, the coordinates must not depend on that axis's loop
    ;; variable -- otherwise the workgroups of a cluster want DIFFERENT tiles and
    ;; multicasting would deliver one workgroup's tile to another.  That is silent data
    ;; corruption, not a lost optimisation, which is why this is checked rather than trusted.
    (loop for d in dims
          for i from 0
          when (> d 1)
          do (let ((axis-var (nth i *ts-grid-bindings*)))
               (cond
                 ((null axis-var)
                  (error 'crisp-compiler-error
                         :message (format nil ":multicast could not be verified: the cluster is ~a (extent ~a on axis ~a) but no enclosing tile-stride binds a loop variable for that axis, so there is nothing to prove the tile is identical across the cluster against.  Use :multicast only on a load inside a tile-stride whose rank covers the cluster."
                                          dims d i)
                         :source-location location))
                 ((%form-mentions-symbol-p grid-list axis-var)
                  (error 'crisp-compiler-error
                         :message (format nil ":multicast is not possible here -- the tile coordinates ~a depend on ~a, which is the loop variable of cluster axis ~a (extent ~a).  The workgroups of a cluster differ along exactly that axis, so they want DIFFERENT tiles and one fetch cannot serve them; multicasting would deliver one workgroup's tile to another.  Drop :multicast, or move the cluster to an axis this load does not vary along."
                                          grid-list axis-var i d)
                         :source-location location)))))
    t))

;; src/analysis/control.lisp
(defun analyze-tile-stride-expression (expr env context location)
  "Analyzes (tile-stride T [LAYOUT-TAG] <TILE-SPEC> (BINDINGS) BODY...).
   Validates tensor-arity-vs-bindings and tile-arity-vs-bindings, then
   delegates codegen via %expand-tile-stride-form.
   Endeavor 152: publishes BINDINGS as *ts-grid-bindings* so a load-tile in the body can
   test whether its coordinates vary along a clustered axis."
  (multiple-value-bind (strict-p layout-tag tile-spec tile-spec-kind bindings body-forms tensor-form)
      (%tile-stride-parse expr)
    (declare (ignore layout-tag body-forms))
    (let* ((env-resolver
            (lambda (sym)
              (when (symbolp sym)
                    (handler-case
                        (let ((node (analyze-expression sym env context (append location '(1)))))
                          (semantic-node-type node))
                      (error () nil)))))
           (cl-pkg (find-package :crisp-language))
           (ts-sym (intern "TENSOR-STRIDE" cl-pkg))
           (synth-for-ct (if strict-p
                             (list ts-sym tensor-form (third expr) bindings)
                             (list ts-sym tensor-form bindings)))
           (ct (%tensor-stride-resolve-ct synth-for-ct env-resolver location))
           (n (length bindings))
           (canon (and (symbolp tensor-form)
                       (let ((ty (funcall env-resolver tensor-form)))
                         (and ty (%ts-canonicalize-tensor-type ty)))))
           (declared-n (when (and (listp canon) (>= (length canon) 3))
                             (third canon))))
      (when (and (integerp declared-n) (/= declared-n n))
            (error 'crisp-compiler-error
              :message (format nil
                           "tile-stride: tensor has ~A dimension(s) but ~A binding(s) provided"
                         declared-n n)
              :source-location location))
      (when (and (eq tile-spec-kind :size-list)
                 (/= (length tile-spec) n))
            (error 'crisp-compiler-error
              :message (format nil
                           "tile-stride: tile size-list has ~A dimension(s) but tensor has ~A dimension(s)"
                         (length tile-spec) n)
              :source-location location))
      (let ((*ts-grid-bindings* bindings))
        (analyze-expression (%expand-tile-stride-form expr ct location)
                            env context location)))))

;; src/analysis/control.lisp
(defun analyze-load-tile-expression (expr env context location)
  "Endeavor 152: validates a `:multicast` assertion against the kernel's cluster shape and
   the enclosing tile-stride's axis bindings, then delegates to load-tile-at as before.
   The validation must happen HERE -- after delegation the grid coords have been multiplied
   by the tile extents and the axis dependency is no longer visible."
  (let* ((src (second expr))
         (tile (third expr))
         (grid-list (fourth expr))
         (key-args (nthcdr 4 expr))
         (cl-pkg (find-package :crisp-language))
         (mul-sym (intern "*" cl-pkg))
         (extents-sym (intern "EXTENTS~" cl-pkg))
         (aref-sym (intern "~" cl-pkg)))
    (unless (and (listp grid-list) (>= (length grid-list) 1))
      (error 'crisp-compiler-error :message "load-tile: origin must be a non-empty list of grid coords" :source-location location))
    (when (%multicast-requested-p key-args)
      (%validate-multicast-request grid-list location))
    (let ((pixel-coords
           (loop for g in grid-list
                 for i from 0
                 collect (list mul-sym (list (intern "TO-ULONG" cl-pkg) g)
                               (list aref-sym (list extents-sym tile) i)))))
      ;; Strip :multicast before delegating.  load-tile-at refuses the key outright (see its
      ;; overlay), and it has already served its purpose here; the lowering will pick the
      ;; multicast path up from a separate channel when Phase 2 step 3 lands.
      (let ((delegated-keys (loop for (k v) on key-args by (function cddr)
                                  unless (eq k :multicast) append (list k v))))
        (analyze-load-tile-at-expression
         (append (list (intern "LOAD-TILE-AT" cl-pkg) src tile pixel-coords) delegated-keys)
         env context location)))))

;; src/analysis/core.lisp
(defun internal-def-function (name params declarations body location)
  "Endeavor 152 Phase 2: additionally BINDS *current-kernel-cluster-dims* around the body
   analysis, so a load-tile can validate a :multicast assertion without rediscovering which
   kernel encloses it.  Otherwise identical to the Phase 1 definition."
  (log:info "Analyzing function ~s" name)
  (multiple-value-bind (explicit-env return-type)
      (parse-function-declarations params declarations)
    (let* ((*compiler-context* (or *compiler-context* (make-compiler-context)))
           (is-entry-p (loop for d in declarations
                             thereis (and (listp d) (symbolp (first d))
                                          (string-equal (symbol-name (first d)) "ENTRY-POINT"))))
           (is-grid-fn-p (loop for d in declarations
                               thereis (and (listp d) (symbolp (first d))
                                            (string-equal (symbol-name (first d)) "GRID-FUNCTION"))))
           (*in-dispatch-context* (or is-entry-p is-grid-fn-p))
           (*boundary-struct-params*
             (if is-entry-p
                 (loop for param in explicit-env
                       when (%boundary-struct-type-p (parameter-def-type param))
                       collect (string-upcase (symbol-name (parameter-def-name param))))
                 *boundary-struct-params*))
           (*boundary-array-params*
             (if is-entry-p
                 (loop for param in explicit-env
                       when (%array-type-p (parameter-def-type param))
                       collect (string-upcase (symbol-name (parameter-def-name param))))
                 *boundary-array-params*))
           (cluster-dims nil))
      (when (and is-entry-p *boundary-struct-params*)
            (log:debug "Kernel ~a has boundary struct params: ~a" name *boundary-struct-params*))
      (when (and is-entry-p *boundary-array-params*)
            (log:debug "Kernel ~a has boundary array params: ~a" name *boundary-array-params*))
      (when is-grid-fn-p
        (log:info "Compiling grid function ~a (dispatch context)" name)
        (%validate-grid-function-return-type return-type))
      (when is-entry-p
        (let* ((global-size-decl (find "GLOBAL-SIZE" declarations
                                       :key (lambda (x) (when (consp x) (symbol-name (car x))))
                                       :test #'string-equal))
               (local-size-decl  (find "LOCAL-SIZE" declarations
                                       :key (lambda (x) (when (consp x) (symbol-name (car x))))
                                       :test #'string-equal))
               (num-groups-decl  (find "NUM-GROUPS" declarations
                                       :key (lambda (x) (when (consp x) (symbol-name (car x))))
                                       :test #'string-equal))
               (cluster-size-decl (find "CLUSTER-SIZE" declarations
                                        :key (lambda (x) (when (consp x) (symbol-name (car x))))
                                        :test #'string-equal)))
          (setf cluster-dims (%parse-cluster-size-decl cluster-size-decl name declarations))
          (when (or global-size-decl local-size-decl num-groups-decl cluster-size-decl)
            (let ((dispatch-plist
                    (append (when global-size-decl (list :global-size global-size-decl))
                            (when local-size-decl  (list :local-size  local-size-decl))
                            (when num-groups-decl  (list :num-groups  num-groups-decl))
                            (when cluster-size-decl (list :cluster-size-decl cluster-size-decl))
                            (when cluster-dims      (list :cluster-size cluster-dims)))))
              (log:info "Kernel ~a: storing dispatch declarations ~a" name dispatch-plist)
              (setf (gethash name *kernel-dispatch-declarations*) dispatch-plist)))
          (%hp-check-workgroup-bounds name local-size-decl (active-hardware-profile))))
      (let ((*current-kernel-cluster-dims* cluster-dims))
        (internal-compile-function name explicit-env return-type params body declarations
                                   location *compiler-context*)))))


;;; =====================================================================
;;; Endeavor 152 Phase 2 step 3 — the multicast lowering
;;;
;;; THE STRUCTURAL CHANGE, and it is exactly what Phase 0's CUTLASS reading predicted.
;;; Today `expect_tx` and the bulk copy sit INSIDE the same leader guard, which is right
;;; for an ordinary TMA load: one thread per workgroup announces the bytes and issues the
;;; copy, and every workgroup does its own.  Under multicast that is wrong:
;;;
;;;   * the COPY is issued by ONE workgroup for the whole multicast group
;;;   * `expect_tx` must still run in EVERY destination workgroup, on ITS OWN barrier
;;;
;;; (CUTLASS `PipelineTmaAsync::producer_acquire` -- `params_.is_leader` is a lane-0 check
;;; WITHIN a CTA, not a leader CTA; see 00-verification-findings.md Q1b.)  So the guard
;;; splits in two: thread-election outside, workgroup-election only around the copy.
;;;
;;; THE MASK IS A COMPILE-TIME CONSTANT, because v1 accepts only 1-D clusters.  For a
;;; cluster of extent N along a single axis every workgroup is in the SAME multicast group,
;;; so the mask is (1<<N)-1 for all of them and the leader is ctarank 0.  A 2-D cluster
;;; would make the group a row or a column, the mask rank-dependent, and the leader differ
;;; PER OPERAND -- that is real work and it is refused with a message rather than guessed.
;;;
;;; NO NEW STRUCT SLOT.  `semantic-nvvm-tma-tile-copy` cannot gain one in an overlay, and
;;; Endeavor 140 already hit this and solved it with a side table keyed by node identity
;;; (`*tma-copy-ws-leader*`).  Same pattern here.  Safe without clearing: nodes are fresh
;;; objects per compile, so a stale entry can never be reached by EQ from a new node --
;;; the table only grows, by one entry per multicast load compiled in the process.
;;; Should become a real slot when this folds into src.
;;; =====================================================================

;; src/codegen.lisp  (new)
(defvar *tma-copy-multicast* (make-hash-table :test 'eq)
  "semantic-nvvm-tma-tile-copy node -> the cluster dims it should multicast across.
   Mirrors *tma-copy-ws-leader* (Endeavor 140), which exists for the same reason:
   the node struct cannot gain a slot from an overlay.")

;; src/analysis/control.lisp  (new)
(defvar *multicast-cluster-dims* nil
  "Bound by analyze-load-tile-expression around its delegation when the load carried a
   validated :multicast, so the TMA analyzer can tag the node it builds.")

;; src/analysis/control.lisp  (new)
(defun %multicast-1d-extent (dims)
  "The extent of a 1-D cluster, or NIL if DIMS clusters more than one axis.
   v1 supports only 1-D: the mask is then cluster-wide constant."
  (let ((nontrivial (remove-if (lambda (d) (= d 1)) dims)))
    (cond ((null nontrivial) nil)
          ((= (length nontrivial) 1) (first nontrivial))
          (t nil))))

;; src/analysis/control.lisp
(defun %validate-multicast-request (grid-list location)
  "Refuse a `:multicast` that cannot be honoured, naming the reason.

   `:multicast` is an ASSERTION, not a directive: the user says 'I expect this load to
   multicast' and the compiler either does it or refuses.  A load that quietly declined
   would be a silent 2x bandwidth regression that no correctness test can see -- which is
   the whole reason the key is explicit rather than inferred."
  (let ((dims *current-kernel-cluster-dims*))
    (unless dims
      (error 'crisp-compiler-error
             :message ":multicast requires the kernel to declare a cluster.  Add (cluster-size :set-to N) to the kernel's declare block -- without a cluster there is no group of workgroups to deliver the tile to, so the request cannot be honoured.  This is a hard error rather than a silent fallback because a load-tile that quietly declines to multicast still computes the correct answer, at exactly the bandwidth the declaration was meant to avoid."
             :source-location location))
    (unless (> (reduce (function *) dims) 1)
      (error 'crisp-compiler-error
             :message (format nil ":multicast requires a cluster extent greater than 1, but this kernel's cluster-size is ~a (one workgroup).  There is no peer to share the fetch with."
                              dims)
             :source-location location))
    ;; v1 restriction, stated rather than silently mis-lowered.
    (unless (%multicast-1d-extent dims)
      (error 'crisp-compiler-error
             :message (format nil ":multicast currently supports only a ONE-DIMENSIONAL cluster, but cluster-size is ~a.  With more than one clustered axis the multicast group is a row or a column rather than the whole cluster, so the destination mask becomes dependent on each workgroup's rank AND the issuing workgroup differs per operand (A's groups and B's groups partition the cluster differently).  That is real work, not a constant, and guessing it would deliver one workgroup's tile to another.  Use a 1-D cluster such as (2 1) for now."
                              dims)
             :source-location location))
    (loop for d in dims
          for i from 0
          when (> d 1)
          do (let ((axis-var (nth i *ts-grid-bindings*)))
               (cond
                 ((null axis-var)
                  (error 'crisp-compiler-error
                         :message (format nil ":multicast could not be verified: the cluster is ~a (extent ~a on axis ~a) but no enclosing tile-stride binds a loop variable for that axis, so there is nothing to prove the tile is identical across the cluster against.  Use :multicast only on a load inside a tile-stride whose rank covers the cluster."
                                          dims d i)
                         :source-location location))
                 ((%form-mentions-symbol-p grid-list axis-var)
                  (error 'crisp-compiler-error
                         :message (format nil ":multicast is not possible here -- the tile coordinates ~a depend on ~a, which is the loop variable of cluster axis ~a (extent ~a).  The workgroups of a cluster differ along exactly that axis, so they want DIFFERENT tiles and one fetch cannot serve them; multicasting would deliver one workgroup's tile to another.  Drop :multicast, or move the cluster to an axis this load does not vary along."
                                          grid-list axis-var i d)
                         :source-location location)))))
    t))

;; src/analysis/control.lisp
(defun analyze-load-tile-expression (expr env context location)
  "Endeavor 152: validates a `:multicast` assertion against the kernel's cluster shape and
   the enclosing tile-stride's axis bindings, then delegates to load-tile-at, publishing the
   cluster dims so the TMA analyzer can tag the copy node it builds."
  (let* ((src (second expr))
         (tile (third expr))
         (grid-list (fourth expr))
         (key-args (nthcdr 4 expr))
         (cl-pkg (find-package :crisp-language))
         (mul-sym (intern "*" cl-pkg))
         (extents-sym (intern "EXTENTS~" cl-pkg))
         (aref-sym (intern "~" cl-pkg))
         (mcast-p (%multicast-requested-p key-args)))
    (unless (and (listp grid-list) (>= (length grid-list) 1))
      (error 'crisp-compiler-error :message "load-tile: origin must be a non-empty list of grid coords" :source-location location))
    (when mcast-p (%validate-multicast-request grid-list location))
    (let ((pixel-coords
           (loop for g in grid-list
                 for i from 0
                 collect (list mul-sym (list (intern "TO-ULONG" cl-pkg) g)
                               (list aref-sym (list extents-sym tile) i)))))
      (let ((delegated-keys (loop for (k v) on key-args by (function cddr)
                                  unless (eq k :multicast) append (list k v)))
            (*multicast-cluster-dims* (when mcast-p *current-kernel-cluster-dims*)))
        (analyze-load-tile-at-expression
         (append (list (intern "LOAD-TILE-AT" cl-pkg) src tile pixel-coords) delegated-keys)
         env context location)))))

;; Capture the ORIGINAL TMA analyzer once so reloading cannot wrap the wrapper.
(defvar *crisp-152-orig-tma-analyze* nil)
(unless *crisp-152-orig-tma-analyze*
  (setf *crisp-152-orig-tma-analyze* (fdefinition '%analyze-nvvm-tma-load-tile-at)))

;; src/analysis/control.lisp
(defun %analyze-nvvm-tma-load-tile-at (expr env context location)
  "Endeavor 152 wrapper: builds the copy node as before, then tags it as a multicast when the
   enclosing load-tile validated one.  Wrapped rather than copied -- this adds two lines to a
   45-line analyzer."
  (let ((node (funcall *crisp-152-orig-tma-analyze* expr env context location)))
    (when (and node *multicast-cluster-dims*)
      (log:info "load-tile: tagging TMA copy node as multicast across ~a" *multicast-cluster-dims*)
      (setf (gethash node *tma-copy-multicast*) *multicast-cluster-dims*))
    node))

;; src/codegen.lisp
(defun %gen-nvvm-tma-bulk-tensor-g2s-2d (builder module dst-smem-ptr mbar-ptr tensormap-ptr coord0 coord1
                                         &optional (mcast-mask 0) (mcast-p nil))
  "Emits @llvm.nvvm.cp.async.bulk.tensor.g2s.tile.2d(dst_smem, mbar, tensormap, x, y, mcast,
   cachehint, flag_mcast, flag_cachehint).

   Endeavor 152: the intrinsic ALREADY carried the multicast operands -- an i16 destination
   mask and an i1 enable flag -- which Endeavor 137 passed as immarg 0.  Multicast is therefore
   plumbing those two, not a new instruction: with the flag set the emitted PTX gains
   `.multicast::cluster` and the ctaMask operand."
  (let* ((fn-name  "llvm.nvvm.cp.async.bulk.tensor.g2s.tile.2d")
         (void     (llvm-void-type))
         (i8       (llvm-int8-type))
         (i16      (llvm-int16-type))
         (i32      (llvm-int32-type))
         (i64      (llvm-int64-type))
         (i1       (llvm-int1-type))
         (ptr-as3  (llvm-pointer-type i8 3))
         (ptr-gen  (llvm-pointer-type i8 0))
         (n        9)
         (param-types (let ((arr (cffi:foreign-alloc 'llvm-type-ref :count n)))
                        (setf (cffi:mem-aref arr 'llvm-type-ref 0) ptr-as3)
                        (setf (cffi:mem-aref arr 'llvm-type-ref 1) ptr-as3)
                        (setf (cffi:mem-aref arr 'llvm-type-ref 2) ptr-gen)
                        (setf (cffi:mem-aref arr 'llvm-type-ref 3) i32)
                        (setf (cffi:mem-aref arr 'llvm-type-ref 4) i32)
                        (setf (cffi:mem-aref arr 'llvm-type-ref 5) i16)
                        (setf (cffi:mem-aref arr 'llvm-type-ref 6) i64)
                        (setf (cffi:mem-aref arr 'llvm-type-ref 7) i1)
                        (setf (cffi:mem-aref arr 'llvm-type-ref 8) i1)
                        arr))
         (fn-type  (llvm-function-type void param-types n nil))
         (fn       (%spirv-get-or-create-fn module fn-name void param-types n))
         (args     (cffi:foreign-alloc 'llvm-value-ref :count n)))
    (setf (cffi:mem-aref args 'llvm-value-ref 0) dst-smem-ptr)
    (setf (cffi:mem-aref args 'llvm-value-ref 1) mbar-ptr)
    (setf (cffi:mem-aref args 'llvm-value-ref 2) tensormap-ptr)
    (setf (cffi:mem-aref args 'llvm-value-ref 3) coord0)
    (setf (cffi:mem-aref args 'llvm-value-ref 4) coord1)
    (setf (cffi:mem-aref args 'llvm-value-ref 5) (llvm-const-int i16 mcast-mask nil))
    (setf (cffi:mem-aref args 'llvm-value-ref 6) (llvm-const-int i64 0 nil))
    (setf (cffi:mem-aref args 'llvm-value-ref 7) (llvm-const-int i1 (if mcast-p 1 0) nil))
    (setf (cffi:mem-aref args 'llvm-value-ref 8) (llvm-const-int i1 0 nil))
    (let ((call (llvm-build-call2 builder fn-type fn args n "")))
      (cffi:foreign-free args)
      (cffi:foreign-free param-types)
      call)))

;; src/codegen.lisp
(defmethod generate-node-ir ((node semantic-nvvm-tma-tile-copy) builder module var-env
                              di-builder di-scope location-map)
  "Endeavor 137 + 140 + 152 — one bulk TMA copy issued by a single elected leader.
   Leader = laneid==0 (the producer warp's lane 0) inside a warp-spec role block, else global
   tid==0.

   Endeavor 152 splits the guard when the copy is a MULTICAST.  `expect_tx` announces the bytes
   a workgroup EXPECTS TO RECEIVE, so every destination workgroup must run it on its own
   mbarrier; only the leader WORKGROUP (ctarank 0) issues the copy that serves them all.
   Keeping both inside one guard -- correct for an ordinary per-workgroup load -- would leave
   every non-issuing workgroup waiting on a barrier that was never told to expect anything."
  (multiple-value-bind (dv di dst-ptr)
      (generate-node-ir (semantic-nvvm-tma-tile-copy-dst-aref-node node) builder module var-env
                        di-builder di-scope location-map)
    (declare (ignore dv di))
    (multiple-value-bind (sv si src-ptr)
        (generate-node-ir (semantic-nvvm-tma-tile-copy-src-aref-node node) builder module var-env
                          di-builder di-scope location-map)
      (declare (ignore sv si))
      (unless (and dst-ptr src-ptr)
        (error "nvvm-tma-tile-copy: aref did not yield an element pointer (dst ~A src ~A)" dst-ptr src-ptr))
      (let* ((i32-type   (llvm-int32-type))
             (ptr-as3    (llvm-pointer-type (llvm-int8-type) 3))
             (ptr-gen    (llvm-pointer-type (llvm-int8-type) 0))
             (ptr-glob   (llvm-pointer-type (llvm-int8-type) 1))
             (desc-ptr   (%tma-lookup-descriptor-ptr builder var-env
                          (semantic-nvvm-tma-tile-copy-src-name node) ptr-glob))
             (tmap-ptr   (llvm-build-addrspace-cast builder (or desc-ptr src-ptr) ptr-gen "tma_map"))
             (barrier-i  (generate-node-ir (semantic-nvvm-tma-tile-copy-barrier-node node) builder module var-env
                                           di-builder di-scope location-map))
             (mbar-ptr   (llvm-build-int-to-ptr builder barrier-i ptr-as3 "tma_mbar"))
             (coord-vals (loop for cn in (semantic-nvvm-tma-tile-copy-coord-nodes node)
                               collect (%coerce-to-i32 builder
                                          (generate-node-ir cn builder module var-env
                                                             di-builder di-scope location-map))))
             (coord0     (or (second coord-vals) (llvm-const-int i32-type 0 nil)))
             (coord1     (or (first coord-vals)  (llvm-const-int i32-type 0 nil)))
             (mc-dims    (gethash node *tma-copy-multicast*))
             (mc-extent  (and mc-dims (%multicast-1d-extent mc-dims)))
             (mc-mask    (if mc-extent (1- (ash 1 mc-extent)) 0))
             (ws-leader  (gethash node *tma-copy-ws-leader*))
             (is-leader  (if ws-leader
                             (llvm-build-icmp builder +llvm-int-eq+
                                (%ptx-read-warp-sreg builder module "laneid")
                                (llvm-const-int i32-type 0 nil) "is_lane0")
                             (let* ((tid-x (%gen-nvvm-read-tid-x builder module))
                                    (tid-y (%gen-nvvm-read-tid-y builder module))
                                    (tid-z (%gen-nvvm-read-tid-z builder module))
                                    (tid-sum (llvm-build-add builder (llvm-build-add builder tid-x tid-y "txy") tid-z "txyz")))
                               (llvm-build-icmp builder +llvm-int-eq+ tid-sum
                                  (llvm-const-int i32-type 0 nil) "is_tid_0"))))
             (issue-bb   (llvm-append-basic-block (llvm-get-basic-block-parent (llvm-get-insert-block builder)) "tma_issue"))
             (cont-bb    (llvm-append-basic-block (llvm-get-basic-block-parent (llvm-get-insert-block builder)) "tma_cont")))
        (llvm-build-cond-br builder is-leader issue-bb cont-bb)
        (llvm-position-builder-at-end builder issue-bb)
        ;; expect_tx: EVERY workgroup, on its own mbarrier -- including the ones that will not
        ;; issue the multicast, because they are still receiving the bytes.
        (let* ((len-val   (generate-node-ir (semantic-nvvm-tma-tile-copy-tile-length-node node) builder module var-env
                                            di-builder di-scope location-map))
               (elem-b    (semantic-nvvm-tma-tile-copy-elem-bytes node))
               (len-i32   (%coerce-to-i32 builder len-val))
               (tx-bytes  (llvm-build-mul builder len-i32 (llvm-const-int i32-type elem-b nil) "tma_tx_bytes"))
               (mbar-addr (llvm-build-ptr-to-int builder mbar-ptr i32-type "mbar_addr")))
          (%gen-nvvm-mbarrier-arrive-expect-tx builder mbar-addr tx-bytes))
        (cond
          (mc-extent
           ;; Multicast: exactly ONE workgroup per group issues.  With a 1-D cluster every
           ;; workgroup is in the same group, so the leader is ctarank 0 and the mask is the
           ;; whole cluster -- both compile-time constants.
           (let* ((parent    (llvm-get-basic-block-parent (llvm-get-insert-block builder)))
                  (rank      (%ptx-read-warp-sreg builder module "cluster.ctarank"))
                  (is-rank0  (llvm-build-icmp builder +llvm-int-eq+ rank
                                (llvm-const-int i32-type 0 nil) "is_ctarank0"))
                  (mc-bb     (llvm-append-basic-block parent "tma_mcast_issue"))
                  (mc-cont   (llvm-append-basic-block parent "tma_mcast_cont")))
             (log:info "TMA copy: multicast across ~a, mask #x~x, leader ctarank 0" mc-dims mc-mask)
             (llvm-build-cond-br builder is-rank0 mc-bb mc-cont)
             (llvm-position-builder-at-end builder mc-bb)
             (%gen-nvvm-tma-bulk-tensor-g2s-2d builder module dst-ptr mbar-ptr tmap-ptr coord0 coord1
                                               mc-mask t)
             (llvm-build-br builder mc-cont)
             (llvm-position-builder-at-end builder mc-cont)))
          (t
           (%gen-nvvm-tma-bulk-tensor-g2s-2d builder module dst-ptr mbar-ptr tmap-ptr coord0 coord1)))
        (llvm-build-br builder cont-bb)
        (llvm-position-builder-at-end builder cont-bb)
        (values nil nil)))))


;;; =====================================================================
;;; Endeavor 152 — the COMPILER-EMITTED CLUSTER ENTRY FENCE
;;;
;;; FOUND ON METAL: rung 11 compiled, launched, and died with `unspecified launch
;;; failure`.  A control run of the identical kernel with `:multicast` removed ran
;;; correctly, so the fault was multicast-specific rather than the spec's geometry.
;;;
;;; THE CAUSE IS THE ONE THE DESIGN NAMED AND I THEN SKIPPED.  From the sync-cluster
;;; discussion, the first of two obligatory compiler-emitted fences:
;;;
;;;     "After mbarrier init, before the mainloop.  CTA 0 can reach the loop and
;;;      remote-arrive on CTA 1's barrier before CTA 1 has initialized it."
;;;
;;; The emitted PTX was exactly that race:
;;;
;;;     mbarrier.init.shared.b64  [__crisp_mbar_1], %r22;
;;;     fence.proxy.async.shared::cta;
;;;     bar.sync 0;                                  <- WORKGROUP sync only
;;;     cp.async.bulk.tensor...multicast::cluster    <- writes into PEER shared memory
;;;
;;; with ZERO `barrier.cluster` in the module.  `bar.sync` orders the threads of one
;;; workgroup; it says nothing about a PEER workgroup.  So the leader could multicast into
;;; a peer's SMEM and complete a transaction on an mbarrier that peer had not yet
;;; initialised.
;;;
;;; This is why the fence is an OBLIGATION rather than a user-facing choice: the failure is
;;; a launch fault at best, and silent corruption at worst, and nothing about the source
;;; suggests it.  Q2 of Phase 0 verified the fence is sufficient on its own -- the cluster
;;; barrier subsumes intra-workgroup convergence -- so no extra sync-workgroup is needed.
;;;
;;; GATED so non-clustered kernels are byte-identical: emitted only when some kernel in
;;; this module declares a cluster extent > 1.  *kernel-dispatch-declarations* is cleared
;;; per module, so the scan is correctly module-scoped.
;;; =====================================================================

;; src/codegen.lisp  (new)
(defun %gen-nvvm-cluster-barrier (builder)
  "Inline PTX: barrier.cluster.arrive; barrier.cluster.wait;

   The non-`.relaxed` form, deliberately: it carries release/acquire ordering, which is what
   publishes this workgroup's mbarrier initialisation to its peers.  The relaxed form would
   rendezvous without ordering and reintroduce the race it exists to close.

   Matches what NVIDIA's own cooperative_groups cluster_group::sync() emits (verified by
   compiling it with nvcc -arch=sm_90a -ptx; see 00-verification-findings.md Q2)."
  (%build-inline-asm-call builder (llvm-void-type) nil nil
                          "barrier.cluster.arrive; barrier.cluster.wait;" ""))

;; src/codegen.lisp  (new)
(defun %module-has-cluster-p ()
  "T if any kernel in the module being compiled declares a cluster of extent > 1.
   Gates the entry fence so a kernel without clusters emits byte-identical PTX."
  (let ((found nil))
    (maphash (lambda (k plist)
               (declare (ignore k))
               (let ((dims (getf plist :cluster-size)))
                 (when (and dims (> (reduce (function *) dims) 1))
                   (setf found t))))
             *kernel-dispatch-declarations*)
    found))

;; src/codegen.lisp
(defmethod generate-node-ir ((node semantic-make-async-barrier) builder module var-env
                              di-builder di-scope location-map)
  "Endeavor 136: a :linear async barrier is a PHANTOM on PTX — commit_group/wait_group
   need no object, so it emits nothing and returns const 0.  On SPIR-V it owns a
   target(\"spirv.Event\") slot (OpGroupAsyncCopy chains its event through it); the slot
   address rides the ulong barrier binding as an i64 (ptrtoint).  The legacy mbarrier.init
   path below runs only if a future :block/mbarrier mode sets cell-node.

   Endeavor 152: after the workgroup sync that publishes mbarrier.init, a CLUSTERED kernel
   additionally emits a cluster barrier.  bar.sync orders one workgroup's threads and says
   nothing about a peer workgroup, so without it a multicast can land in a peer whose
   mbarrier is not yet initialised."
  (when (semantic-make-async-barrier-spirv-event-p node)
    (let* ((ev-type (%spirv-event-type module))
           (slot    (llvm-build-alloca builder ev-type "async_evt_slot")))
      (llvm-build-store builder (crisp.llvm-bindings:llvm-const-null ev-type) slot)
      (return-from generate-node-ir
        (values (llvm-build-ptr-to-int builder slot (llvm-int64-type) "evt_slot_i") nil))))
  (when (and (eq (semantic-make-async-barrier-barrier-mode node) :block)
             (eq *target-backend* :ptx))
    (let* ((i64-type (llvm-int64-type))
           (i32-type (llvm-int32-type))
           (ring-n   (max 1 (semantic-make-async-barrier-ring-count node)))
           (mbar-gv  (%gen-nvvm-tma-mbar-global module ring-n))
           (tid-x    (%gen-nvvm-read-tid-x builder module))
           (tid-y    (%gen-nvvm-read-tid-y builder module))
           (tid-z    (%gen-nvvm-read-tid-z builder module))
           (tid-sum  (llvm-build-add builder (llvm-build-add builder tid-x tid-y "txy") tid-z "txyz"))
           (is-zero  (llvm-build-icmp builder +llvm-int-eq+ tid-sum (llvm-const-int i32-type 0 nil) "is_tid_0"))
           (init-bb  (llvm-append-basic-block (llvm-get-basic-block-parent (llvm-get-insert-block builder)) "tma_mbar_init"))
           (merge-bb (llvm-append-basic-block (llvm-get-basic-block-parent (llvm-get-insert-block builder)) "tma_mbar_cont")))
      (llvm-build-cond-br builder is-zero init-bb merge-bb)
      (llvm-position-builder-at-end builder init-bb)
      (let ((cnt (llvm-const-int i32-type
                                 (max 1 (semantic-make-async-barrier-load-count node)) nil)))
        (dotimes (i ring-n)
          (%gen-nvvm-mbarrier-init-shared builder module
                                          (%gen-nvvm-mbar-slot-ptr builder mbar-gv i)
                                          cnt)))
      (%gen-nvvm-fence-proxy-async-shared builder)
      (llvm-build-br builder merge-bb)
      (llvm-position-builder-at-end builder merge-bb)
      (%ptx-barrier builder module)
      ;; Endeavor 152: publish this workgroup's mbarrier init to its cluster PEERS.  Without
      ;; this a multicast can land in a peer that has not run mbarrier.init yet -- measured as
      ;; `unspecified launch failure` on an H100.
      (when (%module-has-cluster-p)
        (log:info "cluster kernel: emitting cluster entry fence after mbarrier init")
        (%gen-nvvm-cluster-barrier builder))
      (return-from generate-node-ir
        (values (llvm-build-ptr-to-int builder mbar-gv i64-type "mbar_i") nil))))
  (unless (semantic-make-async-barrier-cell-node node)
    (return-from generate-node-ir (values (llvm-const-int (llvm-int64-type) 0 nil) nil)))
  (let* ((cell-val (generate-node-ir (semantic-make-async-barrier-cell-node node) builder module var-env
                                     di-builder di-scope location-map))
         (i32-type (llvm-int32-type))
         (tid-x    (%gen-nvvm-read-tid-x builder module))
         (tid-y    (%gen-nvvm-read-tid-y builder module))
         (tid-z    (%gen-nvvm-read-tid-z builder module))
         (tid-sum  (llvm-build-add builder (llvm-build-add builder tid-x tid-y "txy") tid-z "txyz"))
         (is-zero  (llvm-build-icmp builder +llvm-int-eq+ tid-sum (llvm-const-int i32-type 0 nil) "is_tid_0"))
         (init-bb  (llvm-append-basic-block (llvm-get-basic-block-parent (llvm-get-insert-block builder)) "mbar_init"))
         (merge-bb (llvm-append-basic-block (llvm-get-basic-block-parent (llvm-get-insert-block builder)) "mbar_cont")))
    (llvm-build-cond-br builder is-zero init-bb merge-bb)
    (llvm-position-builder-at-end builder init-bb)
    (let* ((ntid-x (%gen-nvvm-read-ntid-x builder module))
           (ntid-y (%gen-nvvm-read-ntid-y builder module))
           (ntid-z (%gen-nvvm-read-ntid-z builder module))
           (wg-size (llvm-build-mul builder (llvm-build-mul builder ntid-x ntid-y "nxy") ntid-z "nxyz"))
           (cell-storage (llvm-build-extract-value builder cell-val 0 "cell_storage"))
           (cell-ptr     (llvm-build-extract-value builder cell-storage 0 "cell_ptr")))
      (%gen-nvvm-mbarrier-init-shared builder module cell-ptr wg-size)
      (llvm-build-br builder merge-bb))
    (llvm-position-builder-at-end builder merge-bb)
    (%ptx-barrier builder module)
    (values cell-val nil)))


;;; =====================================================================
;;; Endeavor 152 step 5 — `:mode :cluster`
;;;
;;; A cluster barrier is a `:block` barrier in every respect but ONE: peers may arrive on it.
;;; So the delta is deliberately small and lives in three places:
;;;   * the mode parser accepts :cluster and gates it (arch, backend, cluster declared)
;;;   * the barrier ALLOCATES as an mbarrier, exactly as :block does
;;;   * `signal` becomes a REMOTE arrive -- mapa into each peer's view, then arrive with
;;;     cluster scope -- instead of a local one
;;;
;;; ALL-TO-ALL, NOT LEADER-ONLY.  CUTLASS spreads the reverse-barrier arrivals across the whole
;;; multicast group rather than electing one receiver (sm90_pipeline.hpp: `arrive(dst_blockid_)`
;;; guarded by `is_same_row_or_col`), so every workgroup arrives on every peer's barrier, its own
;;; included.  With group extent N and A arrivals per workgroup each barrier then receives N*A --
;;; which is exactly why the init count is scaled by N.  The two must agree or the barrier either
;;; never completes (count too high -> hang) or completes early (too low -> a peer reads a slot
;;; that is still being written).
;;; =====================================================================

;; src/analysis/control.lisp  (new)
(defun %mbarrier-mode-p (mode)
  "T if MODE denotes a real mbarrier object.  :linear is the backend's group-async-copy handle
   (a phantom on PTX); :block and :cluster are both genuine mbarriers and differ only in reach."
  (and mode (member mode (list :block :cluster)) t))

;; src/codegen.lisp  (new)
(defun %module-cluster-extent ()
  "The 1-D cluster extent declared by some kernel in this module, or NIL.
   *kernel-dispatch-declarations* is cleared per module, so this is module-scoped."
  (let ((found nil))
    (maphash (lambda (k plist)
               (declare (ignore k))
               (let* ((dims (getf plist :cluster-size))
                      (e    (and dims (%multicast-1d-extent dims))))
                 (when (and e (> e 1)) (setf found e))))
             *kernel-dispatch-declarations*)
    found))

;; src/analysis/control.lisp
(defun %parse-async-barrier-keys (expr location)
  "Parse (make-async-barrier &key mode) -> barrier-mode.
   Endeavor 152: also accepts :cluster — an mbarrier that PEER WORKGROUPS may arrive on."
  (let ((keys (rest expr))
        (bmode :linear))
    (unless (evenp (length keys))
      (error 'crisp-compiler-error
        :message "make-async-barrier: keys must be :mode value pairs"
        :source-location location))
    (loop for (k v) on keys by (function cddr) do
      (cond
        ((eq k :mode) (setf bmode v))
        ((eq k :type)
         (error 'crisp-compiler-error
           :message "make-async-barrier: the :type key was removed (def-topology is set aside); use only :mode"
           :source-location location))
        (t (error 'crisp-compiler-error
             :message (format nil "make-async-barrier: unknown key ~S (expected :mode)" k)
             :source-location location))))
    (unless (member bmode (list :linear :block :cluster))
      (error 'crisp-compiler-error
        :message (format nil "make-async-barrier :mode ~S unknown — expected :linear (cp.async / OpGroupAsyncCopy), :block (a workgroup-local mbarrier) or :cluster (an mbarrier peers may arrive on)" bmode)
        :source-location location))
    ;; :block and :cluster are both NVIDIA mbarriers and share the arch gate.
    (when (%mbarrier-mode-p bmode)
      (case crisp.compiler:*target-backend*
        (:spirv
         (error 'crisp-compiler-error
           :message (format nil ":mode ~(~a~) is not supported on Intel / SPIR-V — Intel's fast 2D path (LSC block loads) loads global into registers directly and is not a barrier mode, and Intel has no workgroup-cluster hardware at all. Use :mode :linear, or the direct block-load path." bmode)
           :source-location location))
        (:ptx
         (unless (%arch-supports-block-p (resolved-target-arch))
           (error 'crisp-compiler-error
             :message (format nil ":mode ~(~a~) needs a Hopper-or-newer NVIDIA arch (sm_90+); got ~(~a~). Pass --ir-target-arch=sm_90 (or later)."
                              bmode (resolved-target-arch))
             :source-location location)))))
    ;; :cluster additionally asserts that PEERS EXIST.  Without a declared cluster a remote
    ;; arrive resolves to the signaller's own barrier — releasing something nobody waits on
    ;; while the intended peer waits forever.  At cluster extent 1 the two addresses coincide,
    ;; so such a kernel passes small tests and hangs at scale; hence a hard error, not a degrade.
    (when (eq bmode :cluster)
      (unless (and *current-kernel-cluster-dims*
                   (> (reduce (function *) *current-kernel-cluster-dims*) 1))
        (error 'crisp-compiler-error
          :message ":mode :cluster requires the kernel to declare a cluster of more than one workgroup.  Add (cluster-size :set-to N) to the declare block.  A cluster barrier's whole meaning is that PEER workgroups may arrive on it; with no peers the remote arrive would resolve to this workgroup's own barrier, releasing a barrier nobody is waiting on."
          :source-location location))
      (unless (%multicast-1d-extent *current-kernel-cluster-dims*)
        (error 'crisp-compiler-error
          :message (format nil ":mode :cluster currently supports only a ONE-DIMENSIONAL cluster, but cluster-size is ~a.  With more than one clustered axis the arrival group is a row or a column rather than the whole cluster, so both the peer set and the :arrivals multiplier become rank-dependent."
                           *current-kernel-cluster-dims*)
          :source-location location)))
    bmode))

;; --- signal: the remote arrive ---------------------------------------------------------

;; src/codegen.lisp  (new)
(defvar *signal-cluster-extent* (make-hash-table :test 'eq)
  "semantic-signal node -> cluster group extent, when its barrier is :mode :cluster.
   A side table because the struct cannot gain a slot from an overlay — the same pattern
   Endeavor 140 used for *tma-copy-ws-leader*.  Keyed by node identity, so a stale entry is
   unreachable from a fresh compile's nodes.")

;; src/analysis/control.lisp
(defun analyze-signal-expression (expr env context location)
  "Endeavor 139: (signal (ring-get empty-ring slot)) — the consumer's manual mbarrier.arrive.
   Endeavor 152: when the barrier is :mode :cluster the arrive must reach PEER workgroups, so
   tag the node with the cluster extent for codegen."
  (unless (= (length expr) 2)
    (error 'crisp-compiler-error
      :message (format nil "signal: expected (signal BARRIER), got ~S" expr)
      :source-location location))
  (let* ((bmode (async-barrier-mode-of (second expr)))
         (barrier-node (analyze-expression (second expr) env context (append location (list 1)))))
    (if (eq *target-backend* :ptx)
        (let ((node (make-semantic-signal
                     :barrier-node barrier-node
                     :type 'ulong
                     :source-location location)))
          (when (eq bmode :cluster)
            (let ((ext (and *current-kernel-cluster-dims*
                            (%multicast-1d-extent *current-kernel-cluster-dims*))))
              (when (and ext (> ext 1))
                (log:info "signal: cluster-scoped remote arrive across ~a peers" ext)
                (setf (gethash node *signal-cluster-extent*) ext))))
          node)
        (analyze-expression nil env context location))))

;; src/codegen.lisp  (new)
(defun %gen-nvvm-mapa-shared-cluster (builder addr-i32 rank-i32)
  "Inline PTX: mapa.shared::cluster.u32 $0, $1, $2;
   Maps a shared-memory address in THIS workgroup's view to the same offset in the workgroup with
   the given cluster rank.  This is what makes a remote arrive addressable at all."
  (%build-inline-asm-call builder (llvm-int32-type)
                          (list (llvm-int32-type) (llvm-int32-type))
                          (list addr-i32 rank-i32)
                          "mapa.shared::cluster.u32 $0, $1, $2;" "=r,r,r"))

;; src/codegen.lisp  (new)
(defun %gen-nvvm-mbarrier-arrive-cluster (builder peer-addr-i32)
  "Inline PTX: mbarrier.arrive.shared::cluster.b64 _, [$0];
   Arrives on a PEER workgroup's mbarrier.  The `.shared::cluster` scope is the whole point —
   plain `.shared` (or the llvm.nvvm.mbarrier.arrive.shared intrinsic) arrives LOCALLY, which
   would release a barrier nobody is waiting on."
  (%build-inline-asm-call builder (llvm-void-type)
                          (list (llvm-int32-type)) (list peer-addr-i32)
                          "mbarrier.arrive.shared::cluster.b64 _, [$0];" "r"))

;; src/codegen.lisp
(defmethod generate-node-ir ((node semantic-signal) builder module var-env
                              di-builder di-scope location-map)
  "Endeavor 139 — (signal (ring-get empty slot)): a leader-guarded mbarrier.arrive on the slot's
   mbarrier, releasing it to the producer.  One thread per warp (lane 0) arrives, so the arrival
   count matches :arrivals.

   Endeavor 152 — when the barrier is :mode :cluster the arrive is REMOTE and ALL-TO-ALL: this
   workgroup arrives on EVERY workgroup's copy of the barrier, its own included, via mapa.  That
   mirrors CUTLASS, and it is why the init count is scaled by the group extent: with N peers each
   contributing A arrivals, the barrier must expect N*A."
  (let* ((i32-type  (llvm-int32-type))
         (ptr-as3   (llvm-pointer-type (llvm-int8-type) 3))
         (barrier-i (generate-node-ir (semantic-signal-barrier-node node) builder module var-env
                                      di-builder di-scope location-map))
         (mbar-ptr  (llvm-build-int-to-ptr builder barrier-i ptr-as3 "sig_mbar"))
         (lane      (%ptx-read-warp-sreg builder module "laneid"))
         (is-leader (llvm-build-icmp builder +llvm-int-eq+ lane (llvm-const-int i32-type 0 nil) "sig_leader"))
         (parent    (llvm-get-basic-block-parent (llvm-get-insert-block builder)))
         (arrive-bb (llvm-append-basic-block parent "sig_arrive"))
         (cont-bb   (llvm-append-basic-block parent "sig_cont"))
         (extent    (gethash node *signal-cluster-extent*)))
    (llvm-build-cond-br builder is-leader arrive-bb cont-bb)
    (llvm-position-builder-at-end builder arrive-bb)
    (cond
      ((and extent (> extent 1))
       (let ((addr (llvm-build-ptr-to-int builder mbar-ptr i32-type "sig_mbar_addr")))
         (dotimes (r extent)
           (let* ((rank (llvm-const-int i32-type r nil))
                  (peer (%gen-nvvm-mapa-shared-cluster builder addr rank)))
             (%gen-nvvm-mbarrier-arrive-cluster builder peer)))))
      (t
       (%gen-nvvm-mbarrier-arrive-shared builder module mbar-ptr)))
    (llvm-build-br builder cont-bb)
    (llvm-position-builder-at-end builder cont-bb)
    (values (llvm-const-int (llvm-int64-type) 0 nil) nil)))

;;; =====================================================================
;;; Endeavor 152 step 5 (fix) — force the two CALLERS to recompile.
;;;
;;; SBCL DERIVED the return type of %parse-async-barrier-keys as (MEMBER :LINEAR :BLOCK)
;;; when it compiled these callers, and baked that check into their code.  Widening the
;;; function in an overlay is therefore not enough: the callers still reject :CLUSTER with
;;;     The value :CLUSTER is not of type (MEMBER :LINEAR :BLOCK)
;;;     from the function type declaration.
;;; There is no declaim to relax — the type is inferred, so the only fix is to recompile the
;;; callers against the new definition.  They are reproduced VERBATIM below (extracted from
;;; src, not retyped) purely so that happens; nothing about their behaviour changes.
;;;
;;; A general overlay hazard worth remembering: redefining a function whose return type
;;; SBCL can infer requires redefining its callers too, or they keep checking the old type.
;;; =====================================================================

;; src/analysis/control.lisp  (verbatim — recompilation only)

;; src/analysis/control.lisp  (verbatim — recompilation only)


;;; =====================================================================
;;; Endeavor 152 step 5 (revised) — :cluster is :block PLUS REACH
;;;
;;; WHY THE FIRST CUT WAS ABANDONED.  Returning a third `:mode` value broke on a type SBCL had
;;; INFERRED, not declared:
;;;     The value :CLUSTER is not of type (MEMBER :LINEAR :BLOCK)
;;;     from the function type declaration.
;;; Recompiling the two direct callers did not clear it — the narrowed type had propagated
;;; further than that, and chasing every consumer of a mode value is exactly the kind of
;;; open-ended hunt that should prompt a rethink rather than another grep.
;;;
;;; THE RETHINK IS ALSO THE BETTER DESIGN, and it is what the docs already say: a cluster
;;; barrier is a `:block` barrier in every respect but one — peers may arrive on it.  So keep
;;; the MODE at :block and carry the reach separately.  Consequences, all good:
;;;
;;;   * every existing mode consumer works unchanged and unexamined — allocation, the
;;;     warp-spec :block guard, load-tile's TMA path, ring validation, the arch gate.  A
;;;     cluster barrier IS an mbarrier, so it should take exactly those paths.
;;;   * the blast radius collapses to the two places that genuinely differ: `signal` (a remote
;;;     arrive) and the init count (scaled by the group extent).
;;;   * no inferred type is widened anywhere, so nothing downstream needs recompiling.
;;;
;;; The cost is that `async-barrier-mode-of` reports :block for a cluster barrier.  That is
;;; accurate about the OBJECT and silent about the reach, so anything needing the reach asks
;;; %cluster-barrier-p instead.
;;; =====================================================================

;; src/analysis/control.lisp  (new)
(defvar *cluster-barrier-bindings* (make-hash-table :test 'eq)
  "Barrier binding SYMBOL (or ring symbol) -> T when declared :mode :cluster.
   Parallel to *async-barrier-modes*, which records the OBJECT kind; this records the REACH.")

;; src/codegen.lisp  (new)
(defvar *cluster-barrier-nodes* (make-hash-table :test 'eq)
  "semantic-make-async-barrier node -> cluster group extent, for scaling the mbarrier init
   count.  Side table because the struct cannot gain a slot from an overlay.")

;; src/analysis/control.lisp  (new)
(defun %cluster-barrier-p (barrier-form)
  "T if BARRIER-FORM names a barrier declared :mode :cluster.
   Mirrors async-barrier-mode-of: accepts the barrier SYMBOL or a (ring-get RING i) form,
   in which case the RING's declaration governs (every slot shares it)."
  (let ((ring (%barrier-ring-form-p barrier-form)))
    (or (and ring (gethash ring *cluster-barrier-bindings*))
        (and (symbolp barrier-form) (gethash barrier-form *cluster-barrier-bindings*))
        nil)))

;; src/analysis/control.lisp
(defun %parse-async-barrier-keys (expr location)
  "Parse (make-async-barrier &key mode) -> barrier-mode.

   Endeavor 152: `:cluster` is accepted, gated, and then RETURNED AS :block — a cluster barrier
   is a workgroup-local mbarrier that peers may additionally arrive on, so every existing
   consumer of the mode should treat it as :block.  The reach is recorded separately, against
   this barrier's let-binding name, in *cluster-barrier-bindings*."
  (let ((keys (rest expr))
        (bmode :linear)
        (clusterp nil))
    (unless (evenp (length keys))
      (error 'crisp-compiler-error
        :message "make-async-barrier: keys must be :mode value pairs"
        :source-location location))
    (loop for (k v) on keys by (function cddr) do
      (cond
        ((eq k :mode) (setf bmode v))
        ((eq k :type)
         (error 'crisp-compiler-error
           :message "make-async-barrier: the :type key was removed (def-topology is set aside); use only :mode"
           :source-location location))
        (t (error 'crisp-compiler-error
             :message (format nil "make-async-barrier: unknown key ~S (expected :mode)" k)
             :source-location location))))
    (unless (member bmode (list :linear :block :cluster))
      (error 'crisp-compiler-error
        :message (format nil "make-async-barrier :mode ~S unknown — expected :linear (cp.async / OpGroupAsyncCopy), :block (a workgroup-local mbarrier) or :cluster (an mbarrier peers may arrive on)" bmode)
        :source-location location))
    (when (eq bmode :cluster)
      ;; A BACKWARD kernel downgrades rather than refusing.  The AD walk replays the forward's
      ;; bindings, so the barrier appears in the _GRAD twin -- but cluster-size is a DISPATCH
      ;; declaration and deliberately does NOT propagate (endeavour 146: a schedule is not
      ;; mathematics).  So a backward legitimately has a cluster barrier and legitimately has no
      ;; cluster, and a workgroup-local mbarrier is exactly right for it: it runs no multicast
      ;; pipeline and has no peers to co-ordinate with.  Same principle as %ad-canonicalize-wgmma
      ;; substituting sync MMA for wgmma.
      ;;
      ;; THIS BRANCH WAS LOST AND RESTORED.  Step 10c rebuilt this function from an older copy
      ;; that predated it, which made every :mode :cluster spec fail under --differentiate on the
      ;; endeavour's own refusal.  Kept ahead of the refusal below so the ordering cannot drift.
      (when *current-kernel-is-backward*
        (log:info "backward kernel: downgrading :mode :cluster to :block (a schedule does not propagate into a derivative)")
        (setf bmode :block))
      ;; :cluster asserts that PEERS EXIST.  With no cluster a remote arrive resolves to the
      ;; signaller's own barrier — releasing something nobody waits on while the intended peer
      ;; waits forever.  At extent 1 the two addresses coincide, so such a kernel passes small
      ;; tests and hangs at scale; hence a hard error rather than a degrade.
      (unless (or (eq bmode :block)
                  (and *current-kernel-cluster-dims*
                       (> (reduce (function *) *current-kernel-cluster-dims*) 1)))
        (error 'crisp-compiler-error
          :message ":mode :cluster requires the kernel to declare a cluster of more than one workgroup.  Add (cluster-size :set-to N) to the declare block.  A cluster barrier's whole meaning is that PEER workgroups may arrive on it; with no peers the remote arrive would resolve to this workgroup's own barrier, releasing a barrier nobody is waiting on."
          :source-location location))
      (unless (%multicast-1d-extent *current-kernel-cluster-dims*)
        (error 'crisp-compiler-error
          :message (format nil ":mode :cluster currently supports only a ONE-DIMENSIONAL cluster, but cluster-size is ~a.  With more than one clustered axis the arrival group is a row or a column rather than the whole cluster, so both the peer set and the :arrivals multiplier become rank-dependent."
                           *current-kernel-cluster-dims*)
          :source-location location))
      (when (eq bmode :cluster)
        (setf clusterp t
              bmode :block)))
    ;; :block (which :cluster has now become) is NVIDIA-only.
    (when (eq bmode :block)
      (case crisp.compiler:*target-backend*
        (:spirv
         (error 'crisp-compiler-error
           :message ":mode :block is not supported on Intel / SPIR-V — Intel's fast 2D path (LSC block loads) loads global into registers directly and is not a barrier mode, and Intel has no workgroup-cluster hardware at all, so :mode :cluster is unavailable for the same reason. Use :mode :linear, or the direct block-load path."
           :source-location location))
        (:ptx
         (unless (%arch-supports-block-p (resolved-target-arch))
           (error 'crisp-compiler-error
             :message (format nil ":mode :block / :cluster needs a Hopper-or-newer NVIDIA arch (sm_90+); got ~(~a~). Pass --ir-target-arch=sm_90 (or later)."
                              (resolved-target-arch))
             :source-location location)))))
    ;; Record the reach against this barrier's binding name.  The let analyzer set
    ;; current-binding-name before analyzing us, which is the same hook *async-barrier-modes*
    ;; uses for the mode itself.
    (when clusterp
      (let ((bname (and *compiler-context*
                        (compiler-context-current-binding-name *compiler-context*))))
        (when bname
          (log:info "barrier ~a declared :mode :cluster (peers may arrive)" bname)
          (setf (gethash bname *cluster-barrier-bindings*) t))))
    bmode))

;; --- tag the constructed node so codegen can scale the init count ----------------------

(defvar *crisp-152-orig-amabe* nil)
(unless *crisp-152-orig-amabe*
  (setf *crisp-152-orig-amabe* (fdefinition 'analyze-make-async-barrier-expression)))

;; src/analysis/control.lisp
(defun analyze-make-async-barrier-expression (expr env context location)
  "Endeavor 152 wrapper: builds the barrier node as before, then records the cluster group
   extent against it when the binding was declared :mode :cluster, so codegen can scale the
   mbarrier init count."
  (let ((node (funcall *crisp-152-orig-amabe* expr env context location))
        (bname (and context (compiler-context-current-binding-name context))))
    (when (and node bname (gethash bname *cluster-barrier-bindings*))
      (let ((ext (and *current-kernel-cluster-dims*
                      (%multicast-1d-extent *current-kernel-cluster-dims*))))
        (when (and ext (> ext 1))
          (setf (gethash node *cluster-barrier-nodes*) ext))))
    node))

(defvar *crisp-152-orig-amabre* nil)
(unless *crisp-152-orig-amabre*
  (setf *crisp-152-orig-amabre* (fdefinition 'analyze-make-async-barrier-ring-expression)))

;; src/analysis/control.lisp
(defun analyze-make-async-barrier-ring-expression (expr env context location)
  "Endeavor 152 wrapper — as above, for a barrier RING."
  (let ((node (funcall *crisp-152-orig-amabre* expr env context location))
        (bname (and context (compiler-context-current-binding-name context))))
    (when (and node bname (gethash bname *cluster-barrier-bindings*))
      (let ((ext (and *current-kernel-cluster-dims*
                      (%multicast-1d-extent *current-kernel-cluster-dims*))))
        (when (and ext (> ext 1))
          (setf (gethash node *cluster-barrier-nodes*) ext))))
    node))

;; src/analysis/control.lisp
(defun analyze-signal-expression (expr env context location)
  "Endeavor 139: (signal (ring-get empty-ring slot)) — the consumer's manual mbarrier.arrive.
   Endeavor 152: when the barrier was declared :mode :cluster the arrive must reach PEER
   workgroups, so tag the node with the group extent for codegen."
  (unless (= (length expr) 2)
    (error 'crisp-compiler-error
      :message (format nil "signal: expected (signal BARRIER), got ~S" expr)
      :source-location location))
  (let* ((clusterp (%cluster-barrier-p (second expr)))
         (barrier-node (analyze-expression (second expr) env context (append location (list 1)))))
    (if (eq *target-backend* :ptx)
        (let ((node (make-semantic-signal
                     :barrier-node barrier-node
                     :type 'ulong
                     :source-location location)))
          (when clusterp
            (let ((ext (and *current-kernel-cluster-dims*
                            (%multicast-1d-extent *current-kernel-cluster-dims*))))
              (when (and ext (> ext 1))
                (log:info "signal: cluster-scoped remote arrive across ~a peers" ext)
                (setf (gethash node *signal-cluster-extent*) ext))))
          node)
        (analyze-expression nil env context location))))


;;; =====================================================================
;;; Endeavor 152 step 5 — scale the mbarrier init count for a :cluster barrier
;;;
;;; `:arrivals` is, and stays, a PER-WORKGROUP number: how many transfers one workgroup puts
;;; through one slot in one stage.  A `:cluster` barrier collects more than that, because every
;;; workgroup in the group arrives on every peer's copy (all-to-all, mirroring CUTLASS).  With
;;; group extent N and A arrivals per workgroup the barrier receives N*A, so it must be
;;; INITIALISED to N*A or it never completes.
;;;
;;; The user does not write N*A.  They state what their own workgroup does; the compiler
;;; multiplies by a cluster shape it already knows.  That is the same division of labour the
;;; existing `:arrivals` rule describes — and the alternative is that adding one `cluster-size`
;;; line to a working kernel silently requires editing an unrelated barrier declaration, with a
;;; hang as the penalty for forgetting.
;;;
;;; The NEGATIVE half matters just as much and is asserted by the same rung: the data-arrival
;;; (`full`) ring stays `:block` and its count is NOT scaled, because a multicast completes its
;;; transaction on each destination's OWN barrier — one arrival per workgroup, not N.
;;; =====================================================================

;; src/codegen.lisp
(defmethod generate-node-ir ((node semantic-make-async-barrier) builder module var-env
                              di-builder di-scope location-map)
  "Endeavor 136: a :linear async barrier is a PHANTOM on PTX.  On SPIR-V it owns a
   target(\"spirv.Event\") slot.
   Endeavor 152: emits the cluster entry fence after init for a clustered kernel, and scales the
   mbarrier init count by the cluster group extent for a :mode :cluster barrier."
  (when (semantic-make-async-barrier-spirv-event-p node)
    (let* ((ev-type (%spirv-event-type module))
           (slot    (llvm-build-alloca builder ev-type "async_evt_slot")))
      (llvm-build-store builder (crisp.llvm-bindings:llvm-const-null ev-type) slot)
      (return-from generate-node-ir
        (values (llvm-build-ptr-to-int builder slot (llvm-int64-type) "evt_slot_i") nil))))
  (when (and (eq (semantic-make-async-barrier-barrier-mode node) :block)
             (eq *target-backend* :ptx))
    (let* ((i64-type (llvm-int64-type))
           (i32-type (llvm-int32-type))
           (ring-n   (max 1 (semantic-make-async-barrier-ring-count node)))
           (mbar-gv  (%gen-nvvm-tma-mbar-global module ring-n))
           (tid-x    (%gen-nvvm-read-tid-x builder module))
           (tid-y    (%gen-nvvm-read-tid-y builder module))
           (tid-z    (%gen-nvvm-read-tid-z builder module))
           (tid-sum  (llvm-build-add builder (llvm-build-add builder tid-x tid-y "txy") tid-z "txyz"))
           (is-zero  (llvm-build-icmp builder +llvm-int-eq+ tid-sum (llvm-const-int i32-type 0 nil) "is_tid_0"))
           (init-bb  (llvm-append-basic-block (llvm-get-basic-block-parent (llvm-get-insert-block builder)) "tma_mbar_init"))
           (merge-bb (llvm-append-basic-block (llvm-get-basic-block-parent (llvm-get-insert-block builder)) "tma_mbar_cont"))
           ;; Endeavor 152: N for a :cluster barrier, else NIL.
           (cl-ext   (gethash node *cluster-barrier-nodes*))
           (base-cnt (max 1 (semantic-make-async-barrier-load-count node)))
           (count    (if (and cl-ext (> cl-ext 1)) (* base-cnt cl-ext) base-cnt)))
      (when (and cl-ext (> cl-ext 1))
        (log:info "cluster barrier: :arrivals ~a x group extent ~a -> mbarrier init count ~a"
                  base-cnt cl-ext count))
      (llvm-build-cond-br builder is-zero init-bb merge-bb)
      (llvm-position-builder-at-end builder init-bb)
      (let ((cnt (llvm-const-int i32-type count nil)))
        (dotimes (i ring-n)
          (%gen-nvvm-mbarrier-init-shared builder module
                                          (%gen-nvvm-mbar-slot-ptr builder mbar-gv i)
                                          cnt)))
      (%gen-nvvm-fence-proxy-async-shared builder)
      (llvm-build-br builder merge-bb)
      (llvm-position-builder-at-end builder merge-bb)
      (%ptx-barrier builder module)
      ;; Publish this workgroup's mbarrier init to its cluster PEERS.  Without it a multicast can
      ;; land in a peer that has not run mbarrier.init yet — measured as `unspecified launch
      ;; failure` on an H100.
      (when (%module-has-cluster-p)
        (%gen-nvvm-cluster-barrier builder))
      (return-from generate-node-ir
        (values (llvm-build-ptr-to-int builder mbar-gv i64-type "mbar_i") nil))))
  (unless (semantic-make-async-barrier-cell-node node)
    (return-from generate-node-ir (values (llvm-const-int (llvm-int64-type) 0 nil) nil)))
  (let* ((cell-val (generate-node-ir (semantic-make-async-barrier-cell-node node) builder module var-env
                                     di-builder di-scope location-map))
         (i32-type (llvm-int32-type))
         (tid-x    (%gen-nvvm-read-tid-x builder module))
         (tid-y    (%gen-nvvm-read-tid-y builder module))
         (tid-z    (%gen-nvvm-read-tid-z builder module))
         (tid-sum  (llvm-build-add builder (llvm-build-add builder tid-x tid-y "txy") tid-z "txyz"))
         (is-zero  (llvm-build-icmp builder +llvm-int-eq+ tid-sum (llvm-const-int i32-type 0 nil) "is_tid_0"))
         (init-bb  (llvm-append-basic-block (llvm-get-basic-block-parent (llvm-get-insert-block builder)) "mbar_init"))
         (merge-bb (llvm-append-basic-block (llvm-get-basic-block-parent (llvm-get-insert-block builder)) "mbar_cont")))
    (llvm-build-cond-br builder is-zero init-bb merge-bb)
    (llvm-position-builder-at-end builder init-bb)
    (let* ((ntid-x (%gen-nvvm-read-ntid-x builder module))
           (ntid-y (%gen-nvvm-read-ntid-y builder module))
           (ntid-z (%gen-nvvm-read-ntid-z builder module))
           (wg-size (llvm-build-mul builder (llvm-build-mul builder ntid-x ntid-y "nxy") ntid-z "nxyz"))
           (cell-storage (llvm-build-extract-value builder cell-val 0 "cell_storage"))
           (cell-ptr     (llvm-build-extract-value builder cell-storage 0 "cell_ptr")))
      (%gen-nvvm-mbarrier-init-shared builder module cell-ptr wg-size)
      (llvm-build-br builder merge-bb))
    (llvm-position-builder-at-end builder merge-bb)
    (%ptx-barrier builder module)
    (values cell-val nil)))


;;; =====================================================================
;;; Endeavor 152 step 7 — AD of `:mode :cluster`: the backward DOWNGRADES it to :block
;;;
;;; THE SYMPTOM.  A kernel with a `:mode :cluster` barrier fails under --differentiate with this
;;; endeavour's OWN refusal:
;;;     :mode :cluster requires the kernel to declare a cluster of more than one workgroup.
;;;
;;; THE CAUSE, and it is not a defect in either half.  The AD walk replays the forward's
;;; BINDINGS, so the barrier construction appears in the backward kernel — but `cluster-size` is
;;; a DISPATCH declaration and is deliberately NOT propagated (endeavour 146: scheduling is not
;;; mathematics; a backward inheriting the forward's cluster shape would be a schedule leaking
;;; into the math).  So the backward legitimately has a cluster barrier and legitimately has no
;;; cluster.  Both halves are right; the refusal simply did not know which kernel it was in.
;;;
;;; THE FIX IS A CANONICALIZATION, WITH AN EXACT PRECEDENT.  `%ad-canonicalize-wgmma` already
;;; substitutes the sync MMA for wgmma when building a backward, on the stated grounds that "a
;;; backward is under no obligation to use the same instruction as its forward".  The same
;;; applies here, one level down: a backward is under no obligation to use the same BARRIER REACH
;;; as its forward.  It is not running the forward's cluster pipeline — it has no multicast to
;;; release and no peers to co-ordinate with — so a workgroup-local mbarrier is exactly right.
;;;
;;; WHY NOT PROPAGATE cluster-size INSTEAD?  Because that is the leak.  It would make every
;;; backward kernel inherit a launch geometry chosen for the forward's bandwidth, and the
;;; gradient does not care where the forward's bytes came from.  Rung 03 and rung 05 already
;;; assert the opposite — that a backward carries NO cluster records — and this keeps faith with
;;; them.
;;;
;;; DISCRIMINATION.  The downgrade applies only when analysing a BACKWARD kernel (name ends
;;; `_GRAD`), so a user who writes :mode :cluster without a cluster still gets the error.  That
;;; is what errors/20 asserts, and it keeps working.
;;; =====================================================================

;; src/analysis/control.lisp  (new)
(defvar *current-kernel-is-backward* nil
  "T while analysing an AD-generated backward kernel (its name ends _GRAD).
   Lets a check tell 'the user wrote this' from 'the differentiator generated this'.")

;; src/analysis/core.lisp
(defun internal-def-function (name params declarations body location)
  "Endeavor 152: binds *current-kernel-cluster-dims* and *current-kernel-is-backward* around the
   body analysis.  Otherwise identical to the Phase 2 definition."
  (log:info "Analyzing function ~s" name)
  (multiple-value-bind (explicit-env return-type)
      (parse-function-declarations params declarations)
    (let* ((*compiler-context* (or *compiler-context* (make-compiler-context)))
           (is-entry-p (loop for d in declarations
                             thereis (and (listp d) (symbolp (first d))
                                          (string-equal (symbol-name (first d)) "ENTRY-POINT"))))
           (is-grid-fn-p (loop for d in declarations
                               thereis (and (listp d) (symbolp (first d))
                                            (string-equal (symbol-name (first d)) "GRID-FUNCTION"))))
           (*in-dispatch-context* (or is-entry-p is-grid-fn-p))
           (*boundary-struct-params*
             (if is-entry-p
                 (loop for param in explicit-env
                       when (%boundary-struct-type-p (parameter-def-type param))
                       collect (string-upcase (symbol-name (parameter-def-name param))))
                 *boundary-struct-params*))
           (*boundary-array-params*
             (if is-entry-p
                 (loop for param in explicit-env
                       when (%array-type-p (parameter-def-type param))
                       collect (string-upcase (symbol-name (parameter-def-name param))))
                 *boundary-array-params*))
           (*current-kernel-is-backward*
             (and name (symbolp name)
                  (let ((n (symbol-name name)))
                    (and (>= (length n) 5)
                         (string-equal "_GRAD" (subseq n (- (length n) 5)))))))
           (cluster-dims nil))
      (when (and is-entry-p *boundary-struct-params*)
            (log:debug "Kernel ~a has boundary struct params: ~a" name *boundary-struct-params*))
      (when (and is-entry-p *boundary-array-params*)
            (log:debug "Kernel ~a has boundary array params: ~a" name *boundary-array-params*))
      (when is-grid-fn-p
        (log:info "Compiling grid function ~a (dispatch context)" name)
        (%validate-grid-function-return-type return-type))
      (when is-entry-p
        (let* ((global-size-decl (find "GLOBAL-SIZE" declarations
                                       :key (lambda (x) (when (consp x) (symbol-name (car x))))
                                       :test #'string-equal))
               (local-size-decl  (find "LOCAL-SIZE" declarations
                                       :key (lambda (x) (when (consp x) (symbol-name (car x))))
                                       :test #'string-equal))
               (num-groups-decl  (find "NUM-GROUPS" declarations
                                       :key (lambda (x) (when (consp x) (symbol-name (car x))))
                                       :test #'string-equal))
               (cluster-size-decl (find "CLUSTER-SIZE" declarations
                                        :key (lambda (x) (when (consp x) (symbol-name (car x))))
                                        :test #'string-equal)))
          (setf cluster-dims (%parse-cluster-size-decl cluster-size-decl name declarations))
          (when (or global-size-decl local-size-decl num-groups-decl cluster-size-decl)
            (let ((dispatch-plist
                    (append (when global-size-decl (list :global-size global-size-decl))
                            (when local-size-decl  (list :local-size  local-size-decl))
                            (when num-groups-decl  (list :num-groups  num-groups-decl))
                            (when cluster-size-decl (list :cluster-size-decl cluster-size-decl))
                            (when cluster-dims      (list :cluster-size cluster-dims)))))
              (log:info "Kernel ~a: storing dispatch declarations ~a" name dispatch-plist)
              (setf (gethash name *kernel-dispatch-declarations*) dispatch-plist)))
          (%hp-check-workgroup-bounds name local-size-decl (active-hardware-profile))))
      (let ((*current-kernel-cluster-dims* cluster-dims))
        (internal-compile-function name explicit-env return-type params body declarations
                                   location *compiler-context*)))))

;; src/analysis/control.lisp
(defun %parse-async-barrier-keys (expr location)
  "Parse (make-async-barrier &key mode) -> barrier-mode.

   Endeavor 152: `:cluster` is accepted, gated, and returned as :block — a cluster barrier is a
   workgroup-local mbarrier that peers may additionally arrive on, so every existing consumer of
   the mode should treat it as :block.  The reach is recorded separately.

   In a BACKWARD kernel `:cluster` is downgraded to plain :block: the AD walk replays the
   forward's bindings, but cluster-size is a dispatch declaration and does not propagate, so the
   backward has a cluster barrier and no cluster — by design on both counts."
  (let ((keys (rest expr))
        (bmode :linear)
        (clusterp nil))
    (unless (evenp (length keys))
      (error 'crisp-compiler-error
        :message "make-async-barrier: keys must be :mode value pairs"
        :source-location location))
    (loop for (k v) on keys by (function cddr) do
      (cond
        ((eq k :mode) (setf bmode v))
        ((eq k :type)
         (error 'crisp-compiler-error
           :message "make-async-barrier: the :type key was removed (def-topology is set aside); use only :mode"
           :source-location location))
        (t (error 'crisp-compiler-error
             :message (format nil "make-async-barrier: unknown key ~S (expected :mode)" k)
             :source-location location))))
    (unless (member bmode (list :linear :block :cluster))
      (error 'crisp-compiler-error
        :message (format nil "make-async-barrier :mode ~S unknown — expected :linear (cp.async / OpGroupAsyncCopy), :block (a workgroup-local mbarrier) or :cluster (an mbarrier peers may arrive on)" bmode)
        :source-location location))
    (when (eq bmode :cluster)
      (cond
        ;; BACKWARD kernel: downgrade rather than refuse.  A backward is under no obligation to
        ;; use its forward's barrier reach — it runs no multicast pipeline and has no peers to
        ;; co-ordinate with.  Same principle as %ad-canonicalize-wgmma substituting sync MMA.
        (*current-kernel-is-backward*
         (log:info "backward kernel: downgrading :mode :cluster to :block (the schedule does not propagate into a derivative)")
         (setf bmode :block))
        ((not (and *current-kernel-cluster-dims*
                   (> (reduce (function *) *current-kernel-cluster-dims*) 1)))
         (error 'crisp-compiler-error
           :message ":mode :cluster requires the kernel to declare a cluster of more than one workgroup.  Add (cluster-size :set-to N) to the declare block.  A cluster barrier's whole meaning is that PEER workgroups may arrive on it; with no peers the remote arrive would resolve to this workgroup's own barrier, releasing a barrier nobody is waiting on."
           :source-location location))
        ((not (%multicast-1d-extent *current-kernel-cluster-dims*))
         (error 'crisp-compiler-error
           :message (format nil ":mode :cluster currently supports only a ONE-DIMENSIONAL cluster, but cluster-size is ~a.  With more than one clustered axis the arrival group is a row or a column rather than the whole cluster, so both the peer set and the :arrivals multiplier become rank-dependent."
                            *current-kernel-cluster-dims*)
           :source-location location))
        (t (setf clusterp t
                 bmode :block))))
    (when (eq bmode :block)
      (case crisp.compiler:*target-backend*
        (:spirv
         (error 'crisp-compiler-error
           :message ":mode :block is not supported on Intel / SPIR-V — Intel's fast 2D path (LSC block loads) loads global into registers directly and is not a barrier mode, and Intel has no workgroup-cluster hardware at all, so :mode :cluster is unavailable for the same reason. Use :mode :linear, or the direct block-load path."
           :source-location location))
        (:ptx
         (unless (%arch-supports-block-p (resolved-target-arch))
           (error 'crisp-compiler-error
             :message (format nil ":mode :block / :cluster needs a Hopper-or-newer NVIDIA arch (sm_90+); got ~(~a~). Pass --ir-target-arch=sm_90 (or later)."
                              (resolved-target-arch))
             :source-location location)))))
    (when clusterp
      (let ((bname (and *compiler-context*
                        (compiler-context-current-binding-name *compiler-context*))))
        (when bname
          (log:info "barrier ~a declared :mode :cluster (peers may arrive)" bname)
          (setf (gethash bname *cluster-barrier-bindings*) t))))
    bmode))


;;; =====================================================================
;;; Endeavor 152 (fix) — mapa needs a GENERIC address, not a shared-window offset
;;;
;;; MEASURED ON AN H100.  rung 11 died with:
;;;     Invalid __shared__ read of size 4 bytes
;;;       by thread (0,0,0) in block (1,0,0)
;;;       Address 0x0 is not located in executing CTA
;;; and a second at 0x10 -- which are exactly the shared-window offsets of __crisp_mbar_1 and
;;; __crisp_mbar_2.  So the address reaching mbarrier.arrive.shared::cluster was the UNMAPPED
;;; local offset: mapa was not producing a peer address at all.
;;;
;;; GROUND TRUTH, obtained by compiling NVIDIA's own cluster_group::map_shared_rank() with
;;; nvcc -arch=sm_90a -ptx and reading what it emits:
;;;
;;;     cvt.u64.u32        %tmp, %r4
;;;     cvta.shared.u64    %rd2, %tmp        <- shared offset -> GENERIC
;;;     mapa.u64           %rd3, %rd2, %r5   <- mapa on the GENERIC address, .u64
;;;     cvta.to.shared.u64 %tmp, %rd3        <- back to the shared window
;;;     cvt.u32.u64        %r3, %tmp
;;;     mbarrier.arrive.shared::cluster.b64 _, [%r3];
;;;
;;; I had emitted `mapa.shared::cluster.u32 d, a, b` directly on the shared offset.  That form
;;; did not map, so the arrive hit the executing CTA's own barrier -- which is precisely the
;;; silent-local-arrive failure rung 21's validator was written to catch, arriving instead as a
;;; hardware fault because the sanitizer noticed the address was not CTA-local.
;;;
;;; Emitted as ONE inline-asm block so the whole conversion is atomic and no intermediate leaks
;;; into register allocation, mirroring how the TMA helpers already package multi-step PTX.
;;; =====================================================================

;; src/codegen.lisp
(defun %gen-nvvm-mapa-shared-cluster (builder addr-i32 rank-i32)
  "Map a shared-memory address in THIS workgroup's view to the same offset in the workgroup with
   the given cluster rank, returning a shared-window u32 suitable for
   mbarrier.arrive.shared::cluster.

   The conversion through GENERIC is required, not incidental: `mapa` operates on generic
   addresses.  Handing it a raw shared-window offset silently yields an unmapped address, so the
   subsequent arrive lands on the CALLER'S OWN barrier -- the exact bug this fix repairs, caught
   on hardware as `Address 0x0 is not located in executing CTA`."
  (%build-inline-asm-call builder (llvm-int32-type)
                          (list (llvm-int32-type) (llvm-int32-type))
                          (list addr-i32 rank-i32)
                          (concatenate 'string
                            "{ .reg .b64 %gaddr; .reg .b64 %maddr; "
                            "cvt.u64.u32 %gaddr, $1; "
                            "cvta.shared.u64 %gaddr, %gaddr; "
                            "mapa.u64 %maddr, %gaddr, $2; "
                            "cvta.to.shared.u64 %maddr, %maddr; "
                            "cvt.u32.u64 $0, %maddr; }")
                          "=r,r,r"))


;;; =====================================================================
;;; Endeavor 152 fix B — a :local scratch base must be CTA-RELATIVE, not absolute
;;;
;;; WHAT WAS WRONG.  Crisp passes a :local scratch tensor's base to the kernel as a u64
;;; parameter holding a byte OFFSET (0, 32, ...; see %cuda-emit-local-scratch-tensor-arg),
;;; and %ptx-entry-restore-shared-ptrs-for-implode inttoptr'd that offset straight into an
;;; addrspace(3) pointer.  The offset was therefore used as an ABSOLUTE shared address.
;;;
;;; MEASURED ON AN H100 (tests/spec/152-DSMEM-Cluster/00-verification-findings.md):
;;;
;;;     symbol base, NO cluster    every block  -> 0x400
;;;     symbol base, CLUSTER 2     rank 0       -> 0x400
;;;                                rank 1       -> 0x1000400
;;;     raw address 0, NO cluster                  no error
;;;     raw address 0, CLUSTER 2                   ILLEGAL INSTRUCTION
;;;
;;; So the CTA rank is encoded at bit 24 of a shared address.  A raw 0 names RANK 0's
;;; window; for every other CTA in a cluster it is a PEER's memory, and the hardware
;;; refuses it -- "Address 0x0 is not located in executing CTA", exactly what compute-
;;; sanitizer reported.
;;;
;;; AND IT WAS ALREADY WRONG WITHOUT A CLUSTER.  Dynamic shared memory begins at 0x400,
;;; not 0, so scratch addressed from an absolute 0 sat BELOW the region the launch actually
;;; requested -- underneath the statically-allocated shared, which is where the mbarrier
;;; globals (%make-mbarrier) live.  The hardware tolerates it when no cluster is present,
;;; which is why it has never been visible; clusters are simply the first configuration in
;;; which it says no.  This fix moves scratch into the region the host asked for.
;;;
;;; THE FIX, and it is the mechanism NVCC uses for `extern __shared__`: declare an external
;;; addrspace(3) symbol, which NVPTX lowers to `.extern .shared .align N .b8 sym[]`, and add
;;; its address to the host-supplied offset.  The hardware resolves that symbol per-CTA, so
;;; the rank bits come out right by construction rather than by arithmetic we would have to
;;; get right ourselves.  Validated in Crisp's exact addressing idiom before being written
;;; (put_temp_files_here/lds/lds_fix.cu, Q3): raw st.shared/ld.shared on a u64 register with
;;; a per-tensor offset, under a 2-CTA cluster, correct on every rank.
;;;
;;; WHY HERE.  %ptx-entry-restore-shared-ptrs-for-implode is the single choke point where a
;;; demoted i64 becomes a shared pointer, and it is already gated on :ptx AND entry-point.
;;; Every :local tensor and cell flows through it.  Doing it at the tensor's materialisation
;;; site instead would mean finding, and keeping in step, every construct that reaches
;;; scratch.
;;;
;;; SCOPE, deliberately narrow:
;;;   * addrspace 3 (shared) ONLY.  The predicate this function uses also matches addrspace 5
;;;     (thread-local), which is per-thread state with no cluster dimension and no window
;;;     base to add -- adding one there would corrupt it.
;;;   * mbarriers are NOT affected and must not be: they are module-level addrspace(3)
;;;     GLOBALS (%make-mbarrier), not entry params, so they never pass through here and
;;;     already resolve per-CTA correctly.  That is precisely why the barrier half of the
;;;     cluster work behaved while the scratch half did not.
;;;   * Intel/SPIR-V is untouched -- this function is a no-op off :ptx, and the L0 hoister
;;;     allocates each local tensor its own SLM argument rather than offsets into a blob.
;;; =====================================================================

;; src/codegen.lisp
(defparameter *crisp-dynamic-smem-symbol* "__crisp_dynamic_smem"
  "Name of the external addrspace(3) symbol standing for the start of the kernel's DYNAMIC
   shared memory -- the LLVM spelling of CUDA's `extern __shared__`.  One per module.")

;; src/codegen.lisp
(defun %ptx-dynamic-smem-base (builder module)
  "i64 address of the EXECUTING CTA's dynamic shared-memory window.

   Declares (once per module) an external addrspace(3) symbol and ptrtoints it.  Because the
   symbol carries no initializer it stays a DECLARATION, which NVPTX emits as
   `.extern .shared .align 128 .b8 __crisp_dynamic_smem[]` -- resolved by the hardware to the
   executing CTA's own window, including the cluster rank bits.  Aligned to 128, which is what cp.async.bulk.tensor
   requires of a shared destination; the tensors themselves are packed from it by
   the hoister's layout."
  (let* ((i8   (llvm-int8-type))
         (ty   (crisp.llvm-bindings::llvm-array-type i8 0))
         (existing (crisp.llvm-bindings:llvm-get-named-global module *crisp-dynamic-smem-symbol*))
         (gv   (if (and existing (not (cffi:null-pointer-p existing)))
                   existing
                   (let ((g (crisp.llvm-bindings:llvm-add-global-in-addrspace
                             module ty *crisp-dynamic-smem-symbol* 3)))
                     ;; NO initializer: that is what keeps it a declaration (.extern .shared).
                     ;; 128, not 16: cp.async.bulk.tensor requires a 128-BYTE aligned shared
                     ;; destination.  Q1a measured the window landing at 0x400 anyway, but that
                     ;; is an observation about one driver, not a guarantee -- declare it.
                     (crisp.llvm-bindings::llvm-set-alignment g 128)
                     (log:info "declared ~a (.extern .shared) for CTA-relative scratch"
                               *crisp-dynamic-smem-symbol*)
                     g))))
    (crisp.llvm-bindings:llvm-build-ptr-to-int builder gv (llvm-int64-type) "smem_window_base")))

;; src/codegen.lisp
(defun %ptx-entry-restore-shared-ptrs-for-implode
    (builder components type-spec module is-entry-point)
  "Counterpart to the demoter: at the receive site, the kernel's LLVM param at a demoted slot
   is now an i64.  IMPLODE-VALUE expects a pointer in the original addrspace there, so
   inttoptr each demoted component back before packing.

   Endeavor 152 fix B: for addrspace 3 (SHARED) the incoming i64 is a byte OFFSET chosen by
   the hoister, not an address.  The executing CTA's dynamic shared-memory window base is
   added to it first, so the result is CTA-relative.  addrspace 5 (thread-local) is left
   exactly as it was -- it has no window base to speak of."
  (if (and (eq *target-backend* :ptx) is-entry-point)
      (let ((expected-types (get-expanded-types type-spec module))
            (smem-base nil))
        (loop for comp in components
              for exp-ty in expected-types
              collect (if (and (llvm-type-kind-is-pointer? exp-ty)
                               (%ptx-entry-illegal-addrspace-p
                                (llvm-get-pointer-address-space exp-ty)))
                          (let ((as (llvm-get-pointer-address-space exp-ty)))
                            (log:info "PTX kernel-entry receive: inttoptr i64 -> addrspace(~A) ptr" as)
                            (if (= as 3)
                                (let* ((base (or smem-base
                                                 (setf smem-base
                                                       (%ptx-dynamic-smem-base builder module))))
                                       (abs  (llvm-build-add builder base comp "smem_abs")))
                                  (log:debug "shared param is a hoister OFFSET; rebased on the CTA's window")
                                  (llvm-build-int-to-ptr builder abs exp-ty "demoted_param_to_ptr"))
                                (llvm-build-int-to-ptr builder comp exp-ty "demoted_param_to_ptr")))
                          comp)))
      components))


;;; =====================================================================
;;; Endeavor 152 step 10a — `:multicast` generalised from 1-D to N-D clusters
;;;
;;; WHY THIS MATTERS FOR THE BENCHMARK.  chap3_wgmma's inner loop is ALREADY the classic
;;; 2-D multicast shape, and nobody arranged that -- it falls out of matmul:
;;;
;;;     (load-tile A (ring-get A-ring slot) (grid-y grid-k) ...)   ; mentions grid-y, not grid-x
;;;     (load-tile B (ring-get B-ring slot) (grid-x grid-k) ...)   ; mentions grid-x, not grid-y
;;;
;;; A is identical for every workgroup in a cluster COLUMN, B for every workgroup in a cluster
;;; ROW.  With a 1-D cluster only one of the two can be served; with a 2-D cluster both are,
;;; which is the whole reason CUTLASS clusters in two dimensions.
;;;
;;; THE ANALYSIS WAS ALREADY THERE.  %validate-multicast-request already asked, per clustered
;;; axis, "do these tile coordinates mention that axis's tile-stride variable?"  It threw the
;;; answer away and refused.  KEEPING the answer is the generalisation:
;;;
;;;   coords do NOT mention axis a   -> tile is INVARIANT along a -> a joins the multicast group
;;;   coords DO mention axis a       -> tiles genuinely differ    -> a stays out of the group
;;;   no invariant axes              -> refuse, exactly as before
;;;   every clustered axis invariant -> group is the whole cluster == the old 1-D behaviour
;;;
;;; So 1-D is not special-cased, it is a corner of the general case -- which is the reason to
;;; believe this generalisation rather than a second code path beside the old one.
;;;
;;; WHAT STOPS BEING A CONSTANT.  With a 1-D cluster the ctaMask was the whole cluster and the
;;; issuing leader was ctarank 0, both compile-time.  In N-D the group is a SLICE, so both
;;; depend on the workgroup's position along the axes it is NOT grouped on.  They stay cheap:
;;; a compile-time PATTERN shifted by a runtime offset, plus one equality test per group axis.
;;;
;;;     rank    = c0 + c1*d0 + c2*d0*d1              (Crisp axis order == PTX x,y,z order)
;;;     PATTERN = OR over every coordinate combination on the GROUP axes of (1 << its rank)
;;;     shift   = SUM over the NON-group axes of ctaid[a] * stride[a]
;;;     mask    = PATTERN << shift
;;;     leader  = AND over the group axes of (ctaid[a] == 0)
;;;
;;; For a (Cy Cx) cluster that reduces to exactly the CUTLASS arrangement -- A masked to its
;;; row with leader ctaid.x==0, B to its column with leader ctaid.y==0 -- but it is DERIVED,
;;; so a (4 2) or a 3-D cluster needs no further cases.
;;; =====================================================================

;; src/analysis/control.lisp
(defun %cluster-axis-strides (dims)
  "Rank strides for a cluster shape.  PTX linearises %cluster_ctarank with x fastest, and
   Crisp's cluster-size list is in that same order, so stride[0]=1, stride[1]=d0, ..."
  (let ((s 1))
    (loop for d in dims collect (prog1 s (setf s (* s d))))))

;; src/analysis/control.lisp
(defun %cluster-axis-sreg (axis)
  "NVVM special-register name for a cluster axis index."
  (nth axis (list "cluster.ctaid.x" "cluster.ctaid.y" "cluster.ctaid.z")))

;; src/analysis/control.lisp
(defun %multicast-mask-pattern (dims group-axes)
  "The ctaMask for a multicast group anchored at the cluster origin, as a compile-time integer.

   Every combination of coordinates on the GROUP axes contributes one bit, at that
   combination's linearised rank.  Shifting this pattern by a workgroup's position on the
   NON-group axes slides it onto that workgroup's own slice of the cluster."
  (let ((strides (%cluster-axis-strides dims))
        (pattern 0))
    (labels ((walk (axes acc)
               (if (null axes)
                   (setf pattern (logior pattern (ash 1 acc)))
                   (let ((a (first axes)))
                     (dotimes (c (nth a dims))
                       (walk (rest axes) (+ acc (* c (nth a strides)))))))))
      (walk group-axes 0))
    pattern))

;; src/analysis/control.lisp
(defun %multicast-group-extent (dims group-axes)
  "How many workgroups one multicast serves: the product of the group axes' extents."
  (reduce (function *) (mapcar (lambda (a) (nth a dims)) group-axes) :initial-value 1))

;; src/analysis/control.lisp
(defun %multicast-axis-plan (dims grid-list location &key (errorp t))
  "Classify each clustered axis as INVARIANT (the tile is identical across it, so the axis
   joins the multicast group) or VARYING (the workgroups want different tiles).

   Returns a plist (:dims :group-axes :extent :pattern), or NIL when ERRORP is false and the
   request cannot be honoured.  This is the SINGLE place the group is decided; the validator,
   the analyzer and codegen all read its answer rather than each re-deriving it."
  (let ((group-axes '())
        (varying '()))
    (loop for d in dims
          for i from 0
          when (> d 1)
          do (let ((axis-var (nth i *ts-grid-bindings*)))
               (cond
                 ((null axis-var)
                  (when errorp
                    (error 'crisp-compiler-error
                           :message (format nil ":multicast could not be verified: the cluster is ~a (extent ~a on axis ~a) but no enclosing tile-stride binds a loop variable for that axis, so there is nothing to prove the tile is identical across the cluster against.  Use :multicast only on a load inside a tile-stride whose rank covers the cluster."
                                            dims d i)
                           :source-location location))
                  (return-from %multicast-axis-plan nil))
                 ((%form-mentions-symbol-p grid-list axis-var) (push i varying))
                 (t (push i group-axes)))))
    (setf group-axes (nreverse group-axes)
          varying    (nreverse varying))
    (when (null group-axes)
      (when errorp
        (error 'crisp-compiler-error
               :message (format nil ":multicast is not possible here -- the tile coordinates ~a vary along EVERY clustered axis ~a, so each workgroup of the cluster wants a different tile and one fetch cannot serve them; multicasting would deliver one workgroup's tile to another.  Drop :multicast, or cluster on an axis this load does not vary along (in a matmul, A does not vary along N and B does not vary along M)."
                              grid-list varying)
               :source-location location))
      (return-from %multicast-axis-plan nil))
    (let ((plan (list :dims dims
                      :group-axes group-axes
                      :extent  (%multicast-group-extent dims group-axes)
                      :pattern (%multicast-mask-pattern dims group-axes))))
      (log:info "multicast plan: cluster ~a, invariant axes ~a (group of ~a), mask pattern ~x"
                dims group-axes (getf plan :extent) (getf plan :pattern))
      plan)))

;; src/analysis/control.lisp
(defun %validate-multicast-request (grid-list location)
  "Refuse a `:multicast` that cannot be honoured, naming the reason.

   `:multicast` is an ASSERTION, not a directive: the user says 'I expect this load to
   multicast' and the compiler either does it or refuses.  A load that quietly declined would
   be a silent bandwidth regression no correctness test can see -- which is why the key is
   explicit rather than inferred.

   Endeavor 152 step 10a: the axis classification now lives in %multicast-axis-plan, which
   accepts an N-D cluster provided the tile is invariant along at least one clustered axis."
  (let ((dims *current-kernel-cluster-dims*))
    (unless dims
      (error 'crisp-compiler-error
             :message ":multicast requires the kernel to declare a cluster.  Add (cluster-size :set-to N) to the kernel's declare block -- without a cluster there is no group of workgroups to deliver the tile to, so the request cannot be honoured.  This is a hard error rather than a silent fallback because a load-tile that quietly declines to multicast still computes the correct answer, at exactly the bandwidth the declaration was meant to avoid."
             :source-location location))
    (unless (> (reduce (function *) dims) 1)
      (error 'crisp-compiler-error
             :message (format nil ":multicast requires a cluster of more than one workgroup, but cluster-size is ~a.  A cluster of one has nobody to deliver to." dims)
             :source-location location))
    (%multicast-axis-plan dims grid-list location :errorp t)))


;;; =====================================================================
;;; Endeavor 152 step 10b — the N-D multicast MASK and LEADER, in codegen
;;;
;;; With a 1-D cluster both were compile-time constants: the mask was every CTA in the
;;; cluster, and the leader was ctarank 0.  In N-D the group is a SLICE of the cluster, so
;;; each depends on where the workgroup sits on the axes it is NOT grouped along.
;;;
;;; The cost is two instructions and a special-register read per non-group axis, which is
;;; nothing against a bulk tensor copy -- and crucially the PATTERN itself stays compile-time,
;;; so no loop or table lookup appears in the kernel.
;;; =====================================================================

;; src/codegen.lisp
(defun %gen-multicast-mask-value (builder module plan)
  "The i16 ctaMask for THIS workgroup's multicast group: PATTERN << (position on the
   non-group axes).  When every clustered axis is in the group -- the 1-D case -- there are no
   non-group axes, the shift vanishes and this folds back to the old compile-time constant."
  (let* ((i32     (llvm-int32-type))
         (i16     (llvm-int16-type))
         (dims    (getf plan :dims))
         (group   (getf plan :group-axes))
         (pattern (getf plan :pattern))
         (strides (%cluster-axis-strides dims))
         (shift   nil))
    (loop for d in dims
          for a from 0
          when (and (> d 1) (not (member a group)))
          do (let* ((c    (%ptx-read-warp-sreg builder module (%cluster-axis-sreg a)))
                    (term (llvm-build-mul builder c (llvm-const-int i32 (nth a strides) nil)
                                          "mc_shift_term")))
               (setf shift (if shift (llvm-build-add builder shift term "mc_shift") term))))
    (if (null shift)
        (llvm-const-int i16 pattern nil)
        (let* ((pat32 (llvm-const-int i32 pattern nil))
               (sh    (crisp.llvm-bindings::llvm-build-shl builder pat32 shift "mc_mask32")))
          (llvm-build-trunc builder sh i16 "mc_mask")))))

;; src/codegen.lisp
(defun %gen-multicast-leader-pred (builder module plan)
  "True in exactly ONE workgroup per multicast group: the one at coordinate 0 on every group
   axis.  For a 1-D cluster that is ctarank 0, which is what this replaced."
  (let* ((i32   (llvm-int32-type))
         (dims  (getf plan :dims))
         (group (getf plan :group-axes))
         (pred  nil))
    (loop for a in group
          when (> (nth a dims) 1)
          do (let* ((c   (%ptx-read-warp-sreg builder module (%cluster-axis-sreg a)))
                    (is0 (llvm-build-icmp builder +llvm-int-eq+ c (llvm-const-int i32 0 nil)
                                          (format nil "mc_axis~a_is0" a))))
               (setf pred (if pred (crisp.llvm-bindings::llvm-build-and builder pred is0 "mc_leader") is0))))
    (or pred (llvm-const-int (llvm-int1-type) 1 nil))))

;; src/codegen.lisp
(defun %gen-nvvm-tma-bulk-tensor-g2s-2d (builder module dst-smem-ptr mbar-ptr tensormap-ptr coord0 coord1
                                         &optional (mcast-mask 0) (mcast-p nil))
  "Emits @llvm.nvvm.cp.async.bulk.tensor.g2s.tile.2d(dst_smem, mbar, tensormap, x, y, mcast,
   cachehint, flag_mcast, flag_cachehint).

   Endeavor 152: the intrinsic ALREADY carried the multicast operands -- an i16 destination
   mask and an i1 enable flag -- which Endeavor 137 passed as immarg 0.  Multicast is therefore
   plumbing those two, not a new instruction: with the flag set the emitted PTX gains
   `.multicast::cluster` and the ctaMask operand."
  (let* ((fn-name  "llvm.nvvm.cp.async.bulk.tensor.g2s.tile.2d")
         (void     (llvm-void-type))
         (i8       (llvm-int8-type))
         (i16      (llvm-int16-type))
         (i32      (llvm-int32-type))
         (i64      (llvm-int64-type))
         (i1       (llvm-int1-type))
         (ptr-as3  (llvm-pointer-type i8 3))
         (ptr-gen  (llvm-pointer-type i8 0))
         (n        9)
         (param-types (let ((arr (cffi:foreign-alloc 'llvm-type-ref :count n)))
                        (setf (cffi:mem-aref arr 'llvm-type-ref 0) ptr-as3)
                        (setf (cffi:mem-aref arr 'llvm-type-ref 1) ptr-as3)
                        (setf (cffi:mem-aref arr 'llvm-type-ref 2) ptr-gen)
                        (setf (cffi:mem-aref arr 'llvm-type-ref 3) i32)
                        (setf (cffi:mem-aref arr 'llvm-type-ref 4) i32)
                        (setf (cffi:mem-aref arr 'llvm-type-ref 5) i16)
                        (setf (cffi:mem-aref arr 'llvm-type-ref 6) i64)
                        (setf (cffi:mem-aref arr 'llvm-type-ref 7) i1)
                        (setf (cffi:mem-aref arr 'llvm-type-ref 8) i1)
                        arr))
         (fn-type  (llvm-function-type void param-types n nil))
         (fn       (%spirv-get-or-create-fn module fn-name void param-types n))
         (args     (cffi:foreign-alloc 'llvm-value-ref :count n)))
    (setf (cffi:mem-aref args 'llvm-value-ref 0) dst-smem-ptr)
    (setf (cffi:mem-aref args 'llvm-value-ref 1) mbar-ptr)
    (setf (cffi:mem-aref args 'llvm-value-ref 2) tensormap-ptr)
    (setf (cffi:mem-aref args 'llvm-value-ref 3) coord0)
    (setf (cffi:mem-aref args 'llvm-value-ref 4) coord1)
    ;; Endeavor 152 step 10b: MCAST-MASK is an integer for a compile-time mask (the 1-D
    ;; case) or an already-built i16 LLVM value for an N-D group, whose mask depends on the
    ;; workgroup's position in the cluster.  Accepting both keeps every existing caller.
    (setf (cffi:mem-aref args 'llvm-value-ref 5)
          (if (integerp mcast-mask) (llvm-const-int i16 mcast-mask nil) mcast-mask))
    (setf (cffi:mem-aref args 'llvm-value-ref 6) (llvm-const-int i64 0 nil))
    (setf (cffi:mem-aref args 'llvm-value-ref 7) (llvm-const-int i1 (if mcast-p 1 0) nil))
    (setf (cffi:mem-aref args 'llvm-value-ref 8) (llvm-const-int i1 0 nil))
    (let ((call (llvm-build-call2 builder fn-type fn args n "")))
      (cffi:foreign-free args)
      (cffi:foreign-free param-types)
      call)))

;; src/codegen.lisp

;; src/codegen.lisp
;; Endeavor 152 step 10b: mask/leader now come from the multicast axis plan.
(defmethod generate-node-ir ((node semantic-nvvm-tma-tile-copy) builder module var-env
                              di-builder di-scope location-map)
  "Endeavor 137 + 140 + 152 — one bulk TMA copy issued by a single elected leader.
   Leader = laneid==0 (the producer warp's lane 0) inside a warp-spec role block, else global
   tid==0.

   Endeavor 152 splits the guard when the copy is a MULTICAST.  `expect_tx` announces the bytes
   a workgroup EXPECTS TO RECEIVE, so every destination workgroup must run it on its own
   mbarrier; only the leader WORKGROUP (ctarank 0) issues the copy that serves them all.
   Keeping both inside one guard -- correct for an ordinary per-workgroup load -- would leave
   every non-issuing workgroup waiting on a barrier that was never told to expect anything."
  (multiple-value-bind (dv di dst-ptr)
      (generate-node-ir (semantic-nvvm-tma-tile-copy-dst-aref-node node) builder module var-env
                        di-builder di-scope location-map)
    (declare (ignore dv di))
    (multiple-value-bind (sv si src-ptr)
        (generate-node-ir (semantic-nvvm-tma-tile-copy-src-aref-node node) builder module var-env
                          di-builder di-scope location-map)
      (declare (ignore sv si))
      (unless (and dst-ptr src-ptr)
        (error "nvvm-tma-tile-copy: aref did not yield an element pointer (dst ~A src ~A)" dst-ptr src-ptr))
      (let* ((i32-type   (llvm-int32-type))
             (ptr-as3    (llvm-pointer-type (llvm-int8-type) 3))
             (ptr-gen    (llvm-pointer-type (llvm-int8-type) 0))
             (ptr-glob   (llvm-pointer-type (llvm-int8-type) 1))
             (desc-ptr   (%tma-lookup-descriptor-ptr builder var-env
                          (semantic-nvvm-tma-tile-copy-src-name node) ptr-glob))
             (tmap-ptr   (llvm-build-addrspace-cast builder (or desc-ptr src-ptr) ptr-gen "tma_map"))
             (barrier-i  (generate-node-ir (semantic-nvvm-tma-tile-copy-barrier-node node) builder module var-env
                                           di-builder di-scope location-map))
             (mbar-ptr   (llvm-build-int-to-ptr builder barrier-i ptr-as3 "tma_mbar"))
             (coord-vals (loop for cn in (semantic-nvvm-tma-tile-copy-coord-nodes node)
                               collect (%coerce-to-i32 builder
                                          (generate-node-ir cn builder module var-env
                                                             di-builder di-scope location-map))))
             (coord0     (or (second coord-vals) (llvm-const-int i32-type 0 nil)))
             (coord1     (or (first coord-vals)  (llvm-const-int i32-type 0 nil)))
             (mc-plan    (gethash node *tma-copy-multicast*))
             (mc-extent  (and mc-plan (getf mc-plan :extent)))
             (ws-leader  (gethash node *tma-copy-ws-leader*))
             (is-leader  (if ws-leader
                             (llvm-build-icmp builder +llvm-int-eq+
                                (%ptx-read-warp-sreg builder module "laneid")
                                (llvm-const-int i32-type 0 nil) "is_lane0")
                             (let* ((tid-x (%gen-nvvm-read-tid-x builder module))
                                    (tid-y (%gen-nvvm-read-tid-y builder module))
                                    (tid-z (%gen-nvvm-read-tid-z builder module))
                                    (tid-sum (llvm-build-add builder (llvm-build-add builder tid-x tid-y "txy") tid-z "txyz")))
                               (llvm-build-icmp builder +llvm-int-eq+ tid-sum
                                  (llvm-const-int i32-type 0 nil) "is_tid_0"))))
             (issue-bb   (llvm-append-basic-block (llvm-get-basic-block-parent (llvm-get-insert-block builder)) "tma_issue"))
             (cont-bb    (llvm-append-basic-block (llvm-get-basic-block-parent (llvm-get-insert-block builder)) "tma_cont")))
        (llvm-build-cond-br builder is-leader issue-bb cont-bb)
        (llvm-position-builder-at-end builder issue-bb)
        ;; expect_tx: EVERY workgroup, on its own mbarrier -- including the ones that will not
        ;; issue the multicast, because they are still receiving the bytes.
        (let* ((len-val   (generate-node-ir (semantic-nvvm-tma-tile-copy-tile-length-node node) builder module var-env
                                            di-builder di-scope location-map))
               (elem-b    (semantic-nvvm-tma-tile-copy-elem-bytes node))
               (len-i32   (%coerce-to-i32 builder len-val))
               (tx-bytes  (llvm-build-mul builder len-i32 (llvm-const-int i32-type elem-b nil) "tma_tx_bytes"))
               (mbar-addr (llvm-build-ptr-to-int builder mbar-ptr i32-type "mbar_addr")))
          (%gen-nvvm-mbarrier-arrive-expect-tx builder mbar-addr tx-bytes))
        (cond
          (mc-extent
           ;; Multicast: exactly ONE workgroup per group issues.  Which workgroup, and which
           ;; peers receive, both depend on the group's shape -- see %multicast-axis-plan.
           (let* ((parent    (llvm-get-basic-block-parent (llvm-get-insert-block builder)))
                  ;; Leader predicate is built in the CURRENT block, before the branch.
                  (is-mc-leader (%gen-multicast-leader-pred builder module mc-plan))
                  (mc-bb     (llvm-append-basic-block parent "tma_mcast_issue"))
                  (mc-cont   (llvm-append-basic-block parent "tma_mcast_cont")))
             (log:info "TMA copy: multicast group axes ~a of cluster ~a (serves ~a workgroups, pattern ~x)"
                       (getf mc-plan :group-axes) (getf mc-plan :dims)
                       (getf mc-plan :extent) (getf mc-plan :pattern))
             (llvm-build-cond-br builder is-mc-leader mc-bb mc-cont)
             (llvm-position-builder-at-end builder mc-bb)
             ;; Mask is built INSIDE mc-bb -- the builder is positioned there, so the sreg
             ;; reads and the shift land on the issuing path only.
             (%gen-nvvm-tma-bulk-tensor-g2s-2d builder module dst-ptr mbar-ptr tmap-ptr coord0 coord1
                                               (%gen-multicast-mask-value builder module mc-plan) t)
             (llvm-build-br builder mc-cont)
             (llvm-position-builder-at-end builder mc-cont)))
          (t
           (%gen-nvvm-tma-bulk-tensor-g2s-2d builder module dst-ptr mbar-ptr tmap-ptr coord0 coord1)))
        (llvm-build-br builder cont-bb)
        (llvm-position-builder-at-end builder cont-bb)
        (values nil nil)))))


;;; =====================================================================
;;; Endeavor 152 — the COMPILER-EMITTED CLUSTER ENTRY FENCE
;;;
;;; FOUND ON METAL: rung 11 compiled, launched, and died with `unspecified launch
;;; failure`.  A control run of the identical kernel with `:multicast` removed ran
;;; correctly, so the fault was multicast-specific rather than the spec's geometry.
;;;
;;; THE CAUSE IS THE ONE THE DESIGN NAMED AND I THEN SKIPPED.  From the sync-cluster
;;; discussion, the first of two obligatory compiler-emitted fences:
;;;
;;;     "After mbarrier init, before the mainloop.  CTA 0 can reach the loop and
;;;      remote-arrive on CTA 1's barrier before CTA 1 has initialized it."
;;;
;;; The emitted PTX was exactly that race:
;;;
;;;     mbarrier.init.shared.b64  [__crisp_mbar_1], %r22;
;;;     fence.proxy.async.shared::cta;
;;;     bar.sync 0;                                  <- WORKGROUP sync only
;;;     cp.async.bulk.tensor...multicast::cluster    <- writes into PEER shared memory
;;;
;;; with ZERO `barrier.cluster` in the module.  `bar.sync` orders the threads of one
;;; workgroup; it says nothing about a PEER workgroup.  So the leader could multicast into
;;; a peer's SMEM and complete a transaction on an mbarrier that peer had not yet
;;; initialised.
;;;
;;; This is why the fence is an OBLIGATION rather than a user-facing choice: the failure is
;;; a launch fault at best, and silent corruption at worst, and nothing about the source
;;; suggests it.  Q2 of Phase 0 verified the fence is sufficient on its own -- the cluster
;;; barrier subsumes intra-workgroup convergence -- so no extra sync-workgroup is needed.
;;;
;;; GATED so non-clustered kernels are byte-identical: emitted only when some kernel in
;;; this module declares a cluster extent > 1.  *kernel-dispatch-declarations* is cleared
;;; per module, so the scan is correctly module-scoped.
;;; =====================================================================

;; src/codegen.lisp  (new)

;; src/analysis/control.lisp
(defun analyze-load-tile-expression (expr env context location)
  "Endeavor 152: validates a `:multicast` assertion against the kernel's cluster shape and the
   enclosing tile-stride's axis bindings, then delegates to load-tile-at.

   Step 10a: what gets published to the TMA analyzer is now the multicast AXIS PLAN, not the
   raw cluster dims -- codegen needs to know WHICH axes form the group, since in an N-D cluster
   the group is a slice rather than the whole cluster."
  (let* ((src (second expr))
         (tile (third expr))
         (grid-list (fourth expr))
         (key-args (nthcdr 4 expr))
         (cl-pkg (find-package :crisp-language))
         (mul-sym (intern "*" cl-pkg))
         (extents-sym (intern "EXTENTS~" cl-pkg))
         (aref-sym (intern "~" cl-pkg))
         (mcast-p (%multicast-requested-p key-args))
         (mc-plan nil))
    (unless (and (listp grid-list) (>= (length grid-list) 1))
      (error 'crisp-compiler-error :message "load-tile: origin must be a non-empty list of grid coords" :source-location location))
    (when mcast-p (setf mc-plan (%validate-multicast-request grid-list location)))
    (let ((pixel-coords
           (loop for g in grid-list
                 for i from 0
                 collect (list mul-sym (list (intern "TO-ULONG" cl-pkg) g)
                               (list aref-sym (list extents-sym tile) i)))))
      (let ((delegated-keys (loop for (k v) on key-args by (function cddr)
                                  unless (eq k :multicast) append (list k v)))
            (*multicast-cluster-dims* mc-plan))
        (analyze-load-tile-at-expression
         (append (list (intern "LOAD-TILE-AT" cl-pkg) src tile pixel-coords) delegated-keys)
         env context location)))))

;; src/analysis/control.lisp
(defun %parse-async-barrier-keys (expr location)
  "Parse (make-async-barrier &key mode) -> barrier-mode.

   Step 10c: :mode :cluster accepts an N-D cluster; arrivals are cluster-wide (see below).

   Endeavor 152: `:cluster` is accepted, gated, and then RETURNED AS :block — a cluster barrier
   is a workgroup-local mbarrier that peers may additionally arrive on, so every existing
   consumer of the mode should treat it as :block.  The reach is recorded separately, against
   this barrier's let-binding name, in *cluster-barrier-bindings*."
  (let ((keys (rest expr))
        (bmode :linear)
        (clusterp nil))
    (unless (evenp (length keys))
      (error 'crisp-compiler-error
        :message "make-async-barrier: keys must be :mode value pairs"
        :source-location location))
    (loop for (k v) on keys by (function cddr) do
      (cond
        ((eq k :mode) (setf bmode v))
        ((eq k :type)
         (error 'crisp-compiler-error
           :message "make-async-barrier: the :type key was removed (def-topology is set aside); use only :mode"
           :source-location location))
        (t (error 'crisp-compiler-error
             :message (format nil "make-async-barrier: unknown key ~S (expected :mode)" k)
             :source-location location))))
    (unless (member bmode (list :linear :block :cluster))
      (error 'crisp-compiler-error
        :message (format nil "make-async-barrier :mode ~S unknown — expected :linear (cp.async / OpGroupAsyncCopy), :block (a workgroup-local mbarrier) or :cluster (an mbarrier peers may arrive on)" bmode)
        :source-location location))
    (when (eq bmode :cluster)
      ;; :cluster asserts that PEERS EXIST.  With no cluster a remote arrive resolves to the
      ;; signaller's own barrier — releasing something nobody waits on while the intended peer
      ;; waits forever.  At extent 1 the two addresses coincide, so such a kernel passes small
      ;; tests and hangs at scale; hence a hard error rather than a degrade.
      (unless (and *current-kernel-cluster-dims*
                   (> (reduce (function *) *current-kernel-cluster-dims*) 1))
        (error 'crisp-compiler-error
          :message ":mode :cluster requires the kernel to declare a cluster of more than one workgroup.  Add (cluster-size :set-to N) to the declare block.  A cluster barrier's whole meaning is that PEER workgroups may arrive on it; with no peers the remote arrive would resolve to this workgroup's own barrier, releasing a barrier nobody is waiting on."
          :source-location location))
      ;; Endeavor 152 step 10c: the 1-D restriction is LIFTED.  A :mode :cluster barrier now
      ;; collects arrivals from the WHOLE cluster regardless of its rank, which is deliberately
      ;; the simpler of the two available answers.  The precise alternative -- scoping each
      ;; barrier to the multicast group that feeds it -- is not merely more code: in a 2-D
      ;; matmul cluster A's group is a ROW and B's is a COLUMN, so a single shared `empty` ring
      ;; cannot be scoped to both and the kernel would need one ring per operand.  Full-cluster
      ;; arrivals over-synchronise slightly (a row neighbour waits on a column neighbour that
      ;; never touched its slot) and cost nothing in correctness.  If that shows up in the
      ;; benchmark, per-operand rings are the contained follow-up to measure against it.
      (setf clusterp t
            bmode :block))
    ;; :block (which :cluster has now become) is NVIDIA-only.
    (when (eq bmode :block)
      (case crisp.compiler:*target-backend*
        (:spirv
         (error 'crisp-compiler-error
           :message ":mode :block is not supported on Intel / SPIR-V — Intel's fast 2D path (LSC block loads) loads global into registers directly and is not a barrier mode, and Intel has no workgroup-cluster hardware at all, so :mode :cluster is unavailable for the same reason. Use :mode :linear, or the direct block-load path."
           :source-location location))
        (:ptx
         (unless (%arch-supports-block-p (resolved-target-arch))
           (error 'crisp-compiler-error
             :message (format nil ":mode :block / :cluster needs a Hopper-or-newer NVIDIA arch (sm_90+); got ~(~a~). Pass --ir-target-arch=sm_90 (or later)."
                              (resolved-target-arch))
             :source-location location)))))
    ;; Record the reach against this barrier's binding name.  The let analyzer set
    ;; current-binding-name before analyzing us, which is the same hook *async-barrier-modes*
    ;; uses for the mode itself.
    (when clusterp
      (let ((bname (and *compiler-context*
                        (compiler-context-current-binding-name *compiler-context*))))
        (when bname
          (log:info "barrier ~a declared :mode :cluster (peers may arrive)" bname)
          (setf (gethash bname *cluster-barrier-bindings*) t))))
    bmode))

;; --- tag the constructed node so codegen can scale the init count ----------------------


;; src/codegen.lisp
(defun %module-cluster-extent ()
  "How many workgroups a :mode :cluster barrier must expect arrivals from.

   Endeavor 152 step 10c: this is now the FULL cluster size (the product of every axis), not
   a 1-D extent.  That follows directly from the decision above -- if peers arrive cluster-wide
   then the count must be cluster-wide too.  Getting these two out of step is precisely the
   failure that hangs a GPU: a barrier initialised for fewer arrivals than it receives releases
   early, one initialised for more never releases at all.

   *kernel-dispatch-declarations* is cleared per module, so this is module-scoped."
  (let ((found nil))
    (maphash (lambda (k plist)
               (declare (ignore k))
               (let* ((dims (getf plist :cluster-size))
                      (e    (and dims (reduce (function *) dims))))
                 (when (and e (> e 1)) (setf found e))))
             *kernel-dispatch-declarations*)
    found))


;; src/analysis/control.lisp
;; Endeavor 152 step 10c (corrected): restores the backward-kernel downgrade.
(defun %parse-async-barrier-keys (expr location)
  "Parse (make-async-barrier &key mode) -> barrier-mode.

   Step 10c: :mode :cluster accepts an N-D cluster; arrivals are cluster-wide (see below).

   Endeavor 152: `:cluster` is accepted, gated, and then RETURNED AS :block — a cluster barrier
   is a workgroup-local mbarrier that peers may additionally arrive on, so every existing
   consumer of the mode should treat it as :block.  The reach is recorded separately, against
   this barrier's let-binding name, in *cluster-barrier-bindings*."
  (let ((keys (rest expr))
        (bmode :linear)
        (clusterp nil))
    (unless (evenp (length keys))
      (error 'crisp-compiler-error
        :message "make-async-barrier: keys must be :mode value pairs"
        :source-location location))
    (loop for (k v) on keys by (function cddr) do
      (cond
        ((eq k :mode) (setf bmode v))
        ((eq k :type)
         (error 'crisp-compiler-error
           :message "make-async-barrier: the :type key was removed (def-topology is set aside); use only :mode"
           :source-location location))
        (t (error 'crisp-compiler-error
             :message (format nil "make-async-barrier: unknown key ~S (expected :mode)" k)
             :source-location location))))
    (unless (member bmode (list :linear :block :cluster))
      (error 'crisp-compiler-error
        :message (format nil "make-async-barrier :mode ~S unknown — expected :linear (cp.async / OpGroupAsyncCopy), :block (a workgroup-local mbarrier) or :cluster (an mbarrier peers may arrive on)" bmode)
        :source-location location))
    (when (eq bmode :cluster)
      ;; A BACKWARD kernel DOWNGRADES rather than refusing.  The AD walk replays the forward's
      ;; bindings, so the barrier appears in the _GRAD twin -- but cluster-size is a DISPATCH
      ;; declaration and deliberately does NOT propagate (endeavour 146: a schedule is not
      ;; mathematics).  A backward therefore legitimately has a cluster barrier and legitimately
      ;; has no cluster, and a workgroup-local mbarrier is exactly right: it runs no multicast
      ;; pipeline and has no peers.  Same principle as %ad-canonicalize-wgmma substituting sync
      ;; MMA for wgmma.
      ;;
      ;; THIS BRANCH WAS LOST AND RESTORED.  Step 10c rebuilt this function from a copy that
      ;; predated it, which made every :mode :cluster RING spec fail under --differentiate on
      ;; the endeavour's own refusal.  It must stay ahead of that refusal.
      (when *current-kernel-is-backward*
        (log:info "backward kernel: downgrading :mode :cluster to :block (a schedule does not propagate into a derivative)")
        (setf bmode :block)))
    (when (eq bmode :cluster)
      ;; :cluster asserts that PEERS EXIST.  With no cluster a remote arrive resolves to the
      ;; signaller's own barrier — releasing something nobody waits on while the intended peer
      ;; waits forever.  At extent 1 the two addresses coincide, so such a kernel passes small
      ;; tests and hangs at scale; hence a hard error rather than a degrade.
      (unless (and *current-kernel-cluster-dims*
                   (> (reduce (function *) *current-kernel-cluster-dims*) 1))
        (error 'crisp-compiler-error
          :message ":mode :cluster requires the kernel to declare a cluster of more than one workgroup.  Add (cluster-size :set-to N) to the declare block.  A cluster barrier's whole meaning is that PEER workgroups may arrive on it; with no peers the remote arrive would resolve to this workgroup's own barrier, releasing a barrier nobody is waiting on."
          :source-location location))
      ;; Endeavor 152 step 10c: the 1-D restriction is LIFTED.  A :mode :cluster barrier now
      ;; collects arrivals from the WHOLE cluster regardless of its rank, which is deliberately
      ;; the simpler of the two available answers.  The precise alternative -- scoping each
      ;; barrier to the multicast group that feeds it -- is not merely more code: in a 2-D
      ;; matmul cluster A's group is a ROW and B's is a COLUMN, so a single shared `empty` ring
      ;; cannot be scoped to both and the kernel would need one ring per operand.  Full-cluster
      ;; arrivals over-synchronise slightly (a row neighbour waits on a column neighbour that
      ;; never touched its slot) and cost nothing in correctness.  If that shows up in the
      ;; benchmark, per-operand rings are the contained follow-up to measure against it.
      (setf clusterp t
            bmode :block))
    ;; :block (which :cluster has now become) is NVIDIA-only.
    (when (eq bmode :block)
      (case crisp.compiler:*target-backend*
        (:spirv
         (error 'crisp-compiler-error
           :message ":mode :block is not supported on Intel / SPIR-V — Intel's fast 2D path (LSC block loads) loads global into registers directly and is not a barrier mode, and Intel has no workgroup-cluster hardware at all, so :mode :cluster is unavailable for the same reason. Use :mode :linear, or the direct block-load path."
           :source-location location))
        (:ptx
         (unless (%arch-supports-block-p (resolved-target-arch))
           (error 'crisp-compiler-error
             :message (format nil ":mode :block / :cluster needs a Hopper-or-newer NVIDIA arch (sm_90+); got ~(~a~). Pass --ir-target-arch=sm_90 (or later)."
                              (resolved-target-arch))
             :source-location location)))))
    ;; Record the reach against this barrier's binding name.  The let analyzer set
    ;; current-binding-name before analyzing us, which is the same hook *async-barrier-modes*
    ;; uses for the mode itself.
    (when clusterp
      (let ((bname (and *compiler-context*
                        (compiler-context-current-binding-name *compiler-context*))))
        (when bname
          (log:info "barrier ~a declared :mode :cluster (peers may arrive)" bname)
          (setf (gethash bname *cluster-barrier-bindings*) t))))
    bmode))

;; --- tag the constructed node so codegen can scale the init count ----------------------


;; src/codegen.lisp


;; src/analysis/control.lisp


;;; =====================================================================
;;; Endeavor 152 step 10d — THE 2-D CLUSTER BARRIER FIX (the chapter-4 bug)
;;;
;;; Step 10c lifted the 1-D restriction in %parse-async-barrier-keys and %module-cluster-extent
;;; but MISSED three more uses of %multicast-1d-extent, which returns NIL for any cluster with
;;; more than one non-trivial axis -- that is the function's entire purpose.  So with a (2 2)
;;; cluster:
;;;
;;;   analyze-signal-expression                  ext = NIL -> node never tagged cluster-scoped
;;;   analyze-make-async-barrier-expression      ext = NIL -> init count never scaled
;;;   analyze-make-async-barrier-ring-expression ext = NIL -> init count never scaled
;;;
;;; SILENTLY.  The kernel compiled, the multicast half was perfect, and `signal` lowered as an
;;; ordinary workgroup-local `mbarrier.arrive`.  That is not a slowdown: with multicast, the
;;; group leader writes into every peer's shared memory, so a local-only `empty` lets it
;;; overwrite a ring slot a peer is still reading.
;;;
;;; WHY IT HID.  Every 152 spec and every isolated reproduction used a 1-D cluster (2 1), where
;;; %multicast-1d-extent returns 2 and everything works.  chap4 is the first (2 2) kernel with a
;;; cluster barrier.  Seven structural bisects (warp-spec, dotimes, arch, :initial-state, wgmma,
;;; binding order, tile-shape) all missed it because none of them varied the CLUSTER RANK.
;;; Logging the resolution found it in one run -- %cluster-barrier-p was returning T all along,
;;; so the fault was downstream of where every bisect was looking.
;;;
;;; ALL THREE MUST MOVE TOGETHER, and that is why they are fixed in one place: the init count
;;; and the number of arrivals are two halves of one number.  A barrier initialised for fewer
;;; arrivals than it receives releases early; for more, it never releases at all.  Both are now
;;; the FULL cluster product, matching %module-cluster-extent and the cluster-wide arrival
;;; decision.
;;; =====================================================================
;; src/analysis/control.lisp
(defun analyze-make-async-barrier-expression (expr env context location)
  "Endeavor 152 wrapper: builds the barrier node as before, then records the cluster group
   extent against it when the binding was declared :mode :cluster, so codegen can scale the
   mbarrier init count."
  (let ((node (funcall *crisp-152-orig-amabe* expr env context location))
        (bname (and context (compiler-context-current-binding-name context))))
    (when (and node bname (gethash bname *cluster-barrier-bindings*))
      (let ((ext (and *current-kernel-cluster-dims*
                      (reduce (function *) *current-kernel-cluster-dims*))))
        (when (and ext (> ext 1))
          (setf (gethash node *cluster-barrier-nodes*) ext))))
    node))

;; src/analysis/control.lisp
(defun analyze-make-async-barrier-ring-expression (expr env context location)
  "Endeavor 152 wrapper — as above, for a barrier RING."
  (let ((node (funcall *crisp-152-orig-amabre* expr env context location))
        (bname (and context (compiler-context-current-binding-name context))))
    (when (and node bname (gethash bname *cluster-barrier-bindings*))
      (let ((ext (and *current-kernel-cluster-dims*
                      (reduce (function *) *current-kernel-cluster-dims*))))
        (when (and ext (> ext 1))
          (setf (gethash node *cluster-barrier-nodes*) ext))))
    node))

;; src/analysis/control.lisp

;; src/analysis/control.lisp
(defun analyze-signal-expression (expr env context location)
  "Endeavor 139: (signal (ring-get empty-ring slot)) — the consumer's manual mbarrier.arrive.
   Endeavor 152: when the barrier was declared :mode :cluster the arrive must reach PEER
   workgroups, so tag the node with the group extent for codegen."
  (unless (= (length expr) 2)
    (error 'crisp-compiler-error
      :message (format nil "signal: expected (signal BARRIER), got ~S" expr)
      :source-location location))
  (let* ((clusterp (%cluster-barrier-p (second expr)))
         (barrier-node (analyze-expression (second expr) env context (append location (list 1)))))
    (if (eq *target-backend* :ptx)
        (let ((node (make-semantic-signal
                     :barrier-node barrier-node
                     :type 'ulong
                     :source-location location)))
          (when clusterp
            (let ((ext (and *current-kernel-cluster-dims*
                            (reduce (function *) *current-kernel-cluster-dims*))))
              (when (and ext (> ext 1))
                (log:info "signal: cluster-scoped remote arrive across ~a peers" ext)
                (setf (gethash node *signal-cluster-extent*) ext))))
          node)
        (analyze-expression nil env context location))))


;;; =====================================================================
;;; Endeavor 152 step 5 — scale the mbarrier init count for a :cluster barrier
;;;
;;; `:arrivals` is, and stays, a PER-WORKGROUP number: how many transfers one workgroup puts
;;; through one slot in one stage.  A `:cluster` barrier collects more than that, because every
;;; workgroup in the group arrives on every peer's copy (all-to-all, mirroring CUTLASS).  With
;;; group extent N and A arrivals per workgroup the barrier receives N*A, so it must be
;;; INITIALISED to N*A or it never completes.
;;;
;;; The user does not write N*A.  They state what their own workgroup does; the compiler
;;; multiplies by a cluster shape it already knows.  That is the same division of labour the
;;; existing `:arrivals` rule describes — and the alternative is that adding one `cluster-size`
;;; line to a working kernel silently requires editing an unrelated barrier declaration, with a
;;; hang as the penalty for forgetting.
;;;
;;; The NEGATIVE half matters just as much and is asserted by the same rung: the data-arrival
;;; (`full`) ring stays `:block` and its count is NOT scaled, because a multicast completes its
;;; transaction on each destination's OWN barrier — one arrival per workgroup, not N.
;;; =====================================================================

;; src/codegen.lisp


;;; =====================================================================
;;; BUG 049 — grid padding is FATAL for a kernel that uses its cluster's reach
;;;
;;; The CUDA hoist pads the launch grid up to a multiple of the cluster shape, on the stated
;;; grounds that "the surplus blocks find no tiles left to claim and exit".  True for an ordinary
;;; kernel.  FALSE for one with a multicast load or a :mode :cluster barrier: those surplus
;;; blocks are still CLUSTER MEMBERS.  A multicast addresses them, and a cluster-scoped barrier
;;; waits for them -- and they have already left.
;;;
;;; MEASURED: chap4_cluster_multicast reports `unspecified launch failure` at N=256, where a
;;; 64x256 tile gives a 4x1 grid and a (2 2) cluster pads the second axis 1 -> 2, making HALF of
;;; every cluster padding.  Every larger size runs correctly.  chap3 (same kernel, no cluster)
;;; runs N=256 fine.
;;;
;;; WHY THIS CANNOT BE A COMPILE-TIME REFUSAL: the grid comes from `:derive-from C` and is only
;;; known at launch.  The check therefore has to be emitted INTO the host code, which is what
;;; the hoist half of this fix does.
;;; =====================================================================

;; src/metadata.lisp
(defun %module-uses-cluster-reach-p ()
  "T if anything in this module multicasts a load or declares a :mode :cluster barrier.

   Both tables are populated during analysis and cleared per module, so by serialization time
   they are a complete record of whether the module's kernels depend on peers."
  (or (plusp (hash-table-count *tma-copy-multicast*))
      (plusp (hash-table-count *cluster-barrier-bindings*))))

;; src/metadata.lisp
(defun serialize-kernels (output-stream kernel-names &key source output-targets)
  "Emits the (:kernels ...) section of the metacrisp file.
   Extended to include :global-size, :local-size, :num-groups dispatch declarations.
   Endeavor 152: also emits :cluster-size (what the SOURCE asked for) and
   :effective-cluster-size (what codegen BUILT).  Both, deliberately -- a degraded
   cluster is otherwise indistinguishable from a working one."
  (when kernel-names
        (format output-stream "(:kernels~%")
        (dolist (k-name (sort (copy-list kernel-names) (function string<) :key (function symbol-name)))
          (let ((sigs (gethash k-name *function-table*))
                (blocks-to-emit nil))
            ;; Use only the FIRST signature (Pass 1 registered, Pass 2 updated)
            (dolist (actual-sig (list (first sigs)))
              (when actual-sig
                    (let* ((phys-sig-str (generate-physical-signature actual-sig))
                           (declared-types (gethash k-name *kernel-declared-signatures*))
                           (decl-sig-list (generate-declared-signature actual-sig declared-types))
                           (implicit-sig-list (generate-implicit-signature actual-sig declared-types))
                           (dispatch-info (gethash k-name *kernel-dispatch-declarations*))
                           (source-loc (if source source
                                           (namestring (uiop/filesystem:native-namestring (first (function-signature-source-location actual-sig)))))))

                      (push (list :name (string-downcase (symbol-name k-name))
                                  :source source-loc
                                  :output output-targets
                                  :phys phys-sig-str
                                  :decl decl-sig-list
                                  :impl implicit-sig-list
                                  :dispatch dispatch-info)
                            blocks-to-emit))))

            (setf blocks-to-emit (remove-duplicates (nreverse blocks-to-emit) :test (function equalp)))

            (dolist (blk blocks-to-emit)
              (let ((dispatch (getf blk :dispatch)))
                (format output-stream "  (:name ~s~%" (getf blk :name))
                (format output-stream "    :source ~s~%" (pathname (getf blk :source)))
                (when (getf blk :output) (format output-stream "    :output-targets ~s~%" (getf blk :output)))
                ;; Emit dispatch declarations before physical/declared signatures
                (let ((global-size-decl (getf dispatch :global-size))
                      (local-size-decl  (getf dispatch :local-size))
                      (num-groups-decl  (getf dispatch :num-groups))
                      (cluster-decl     (getf dispatch :cluster-size-decl))
                      (cluster-dims     (getf dispatch :cluster-size)))
                  (when global-size-decl
                    (format output-stream "    :global-size ")
                    (print-without-packages global-size-decl output-stream)
                    (format output-stream "~%"))
                  (when local-size-decl
                    (format output-stream "    :local-size ")
                    (print-without-packages local-size-decl output-stream)
                    (format output-stream "~%"))
                  (when num-groups-decl
                    (format output-stream "    :num-groups ")
                    (print-without-packages num-groups-decl output-stream)
                    (format output-stream "~%"))
                  ;; Endeavor 152.  BOTH are emitted on purpose:
                  ;;   :cluster-size            -- the declaration, as written
                  ;;   :effective-cluster-size  -- what codegen actually built
                  ;; They differ exactly when the kernel degraded, which is the one
                  ;; case a correctness test cannot see.
                  (when cluster-decl
                    (format output-stream "    :cluster-size ")
                    (print-without-packages cluster-decl output-stream)
                    (format output-stream "~%"))
                  ;; BUG 049: does this kernel actually USE its cluster's reach -- a
                  ;; multicast load or a :mode :cluster barrier?  The hoist needs to know,
                  ;; because padding the grid up to the cluster shape is safe for an ordinary
                  ;; clustered kernel (surplus blocks find no tiles and exit) and FATAL for one
                  ;; with reach: the padded blocks are still cluster members that a multicast
                  ;; addresses and a cluster barrier waits on, so they must not simply leave.
                  ;;
                  ;; Deliberately MODULE-scoped and therefore conservative: if any kernel in the
                  ;; module uses reach, every clustered kernel in it declines padding.  Precise
                  ;; per-kernel attribution would mean threading a flag through the whole
                  ;; analysis; over-refusing a kernel that gains nothing from its cluster anyway
                  ;; is the cheaper error, and it is an error in the safe direction.
                  (when (and cluster-dims (%module-uses-cluster-reach-p))
                    (format output-stream "    :cluster-reach t~%"))
                  (when cluster-dims
                    (format output-stream "    :effective-cluster-size ")
                    (print-without-packages (%effective-cluster-dims dispatch cluster-dims) output-stream)
                    (format output-stream "~%")))
                (format output-stream "    :physical-signature ~a~%" (getf blk :phys))
                (format output-stream "    :declared-signature ")
                (print-without-packages (getf blk :decl) output-stream)
                (format output-stream "~%")
                (when (getf blk :impl)
                      (format output-stream "    :implicit-params ")
                      (print-without-packages (getf blk :impl) output-stream)
                      (format output-stream "~%"))
                (format output-stream "  )~%"))))
        (format output-stream "  )~%"))))


;;; =====================================================================
;;; Endeavor 152 Phase 1 (fix 2) — the degrade diagnostic must fire on SPIR-V too
;;;

;;; =====================================================================
;;; Endeavor 152 step 11 — ROTATE the multicast issuer across the group
;;;
;;; THE PROBLEM, measured: multicast costs a flat ~6-8% on chapter 3 regardless of how many
;;; workgroups share a fetch (2-way and 4-way are indistinguishable).  It is not instruction
;;; overhead -- chap4 emits only +20 instructions on 1832, the cluster fence is in the prologue,
;;; and the leader predicate is loop-invariant and hoisted.  It is STRUCTURAL: with multicast
;;; exactly ONE CTA per group issues, so N independent producer pipelines become ONE shared
;;; pipeline feeding N consumers, and the whole group advances at that single issuer's rate.
;;; In a warp-specialised kernel whose entire design is "keep the producer ahead", collapsing
;;; N producers into 1 is the wrong direction.
;;;
;;; AND THE ISSUER WAS STATIC: `ctaid == 0 on the group axes`, computed once before the loop, so
;;; the SAME CTA issued every stage for the kernel's lifetime -- a permanent bottleneck rather
;;; than a rotating duty.  CUTLASS distributes multicast issue across a cluster instead.
;;;
;;; THE ROTATION SOURCE, and why this one.  What we need is a value that changes per PIPELINE
;;; STAGE and is already available where the copy is emitted.  The ring SLOT index is the natural
;;; choice but has been folded into the destination address by codegen time; recovering it means
;;; threading the slot expression down from `analyze-load-tile-expression` and re-generating a
;;; node in a second place.  The MBARRIER ADDRESS is right there and already carries the same
;;; information: a barrier ring is `base + slot*8` (see %gen-nvvm-mbar-slot-ptr), so
;;; `(mbar_addr >> 3)` advances by one per slot.  Zero new plumbing, and it degrades correctly --
;;; a ring of one gives a constant, i.e. exactly the old static leader.
;;;
;;; SCOPE: rotation applies when the group spans exactly ONE clustered axis, which is the case
;;; that matters (in a matmul A's group is a cluster ROW and B's a COLUMN -- both single-axis).
;;; A multi-axis group falls back to the static all-zero leader, which remains correct.
;;;
;;; CORRECTNESS NOTE: rotating WHO issues does not change WHAT is issued.  The ctaMask still
;;; names the whole group, so every member still receives the tile; only the issuing duty moves.
;;; All members still run `expect_tx` on their own mbarrier, exactly as before.
;;; =====================================================================

;; src/codegen.lisp
(defun %gen-multicast-leader-pred (builder module plan &optional rot-src)
  "True in exactly ONE workgroup per multicast group.

   With ROT-SRC (an i32 that advances once per pipeline stage -- in practice the mbarrier
   address) and a single-axis group, the issuing duty ROTATES: the CTA at position
   `rot-src mod extent` along the group axis issues this stage.  Over a ring of stages every
   member takes a turn, so no single CTA is a standing bottleneck.

   Without ROT-SRC, or for a multi-axis group, falls back to the original static leader (position
   0 on every group axis).  Both are correct; only the distribution of work differs."
  (let* ((i32   (llvm-int32-type))
         (dims  (getf plan :dims))
         (group (getf plan :group-axes))
         (live  (remove-if-not (lambda (a) (> (nth a dims) 1)) group)))
    (cond
      ;; ROTATING: one group axis, and a per-stage value to rotate on.
      ((and rot-src (= (length live) 1)
            (let ((e (nth (first live) dims))) (zerop (logand e (1- e)))))   ; power of two
       (let* ((a      (first live))
              (extent (nth a dims))
              (c      (%ptx-read-warp-sreg builder module (%cluster-axis-sreg a)))
              ;; mbarrier ring slots are 8 bytes apart, so >>3 counts stages.
              (stage  (crisp.llvm-bindings::llvm-build-l-shr
                       builder rot-src (llvm-const-int i32 3 nil) "mc_stage"))
              ;; AND, not a remainder: a cluster extent is always a power of two (2/4/8 are the
              ;; only portable values), so `mod extent` is `and (extent-1)` -- cheaper, and it
              ;; needs no URem binding, which the LLVM layer does not currently have.
              (turn   (crisp.llvm-bindings::llvm-build-and
                       builder stage (llvm-const-int i32 (1- extent) nil) "mc_turn")))
         (log:info "multicast: ROTATING issuer across ~a workgroups on cluster axis ~a" extent a)
         (llvm-build-icmp builder +llvm-int-eq+ c turn "mc_leader_rot")))
      (t
       (let ((pred nil))
         (loop for a in live
               do (let* ((c   (%ptx-read-warp-sreg builder module (%cluster-axis-sreg a)))
                         (is0 (llvm-build-icmp builder +llvm-int-eq+ c (llvm-const-int i32 0 nil)
                                               (format nil "mc_axis~a_is0" a))))
                    (setf pred (if pred (crisp.llvm-bindings::llvm-build-and builder pred is0 "mc_leader") is0))))
         (or pred (llvm-const-int (llvm-int1-type) 1 nil)))))))


;; src/codegen.lisp
;; Step 11: pass a per-stage rotation source to the multicast leader predicate.
(defmethod generate-node-ir ((node semantic-nvvm-tma-tile-copy) builder module var-env
                              di-builder di-scope location-map)
  "Endeavor 137 + 140 + 152 — one bulk TMA copy issued by a single elected leader.
   Leader = laneid==0 (the producer warp's lane 0) inside a warp-spec role block, else global
   tid==0.

   Endeavor 152 splits the guard when the copy is a MULTICAST.  `expect_tx` announces the bytes
   a workgroup EXPECTS TO RECEIVE, so every destination workgroup must run it on its own
   mbarrier; only the leader WORKGROUP (ctarank 0) issues the copy that serves them all.
   Keeping both inside one guard -- correct for an ordinary per-workgroup load -- would leave
   every non-issuing workgroup waiting on a barrier that was never told to expect anything."
  (multiple-value-bind (dv di dst-ptr)
      (generate-node-ir (semantic-nvvm-tma-tile-copy-dst-aref-node node) builder module var-env
                        di-builder di-scope location-map)
    (declare (ignore dv di))
    (multiple-value-bind (sv si src-ptr)
        (generate-node-ir (semantic-nvvm-tma-tile-copy-src-aref-node node) builder module var-env
                          di-builder di-scope location-map)
      (declare (ignore sv si))
      (unless (and dst-ptr src-ptr)
        (error "nvvm-tma-tile-copy: aref did not yield an element pointer (dst ~A src ~A)" dst-ptr src-ptr))
      (let* ((i32-type   (llvm-int32-type))
             (ptr-as3    (llvm-pointer-type (llvm-int8-type) 3))
             (ptr-gen    (llvm-pointer-type (llvm-int8-type) 0))
             (ptr-glob   (llvm-pointer-type (llvm-int8-type) 1))
             (desc-ptr   (%tma-lookup-descriptor-ptr builder var-env
                          (semantic-nvvm-tma-tile-copy-src-name node) ptr-glob))
             (tmap-ptr   (llvm-build-addrspace-cast builder (or desc-ptr src-ptr) ptr-gen "tma_map"))
             (barrier-i  (generate-node-ir (semantic-nvvm-tma-tile-copy-barrier-node node) builder module var-env
                                           di-builder di-scope location-map))
             (mbar-ptr   (llvm-build-int-to-ptr builder barrier-i ptr-as3 "tma_mbar"))
             (coord-vals (loop for cn in (semantic-nvvm-tma-tile-copy-coord-nodes node)
                               collect (%coerce-to-i32 builder
                                          (generate-node-ir cn builder module var-env
                                                             di-builder di-scope location-map))))
             (coord0     (or (second coord-vals) (llvm-const-int i32-type 0 nil)))
             (coord1     (or (first coord-vals)  (llvm-const-int i32-type 0 nil)))
             (mc-plan    (gethash node *tma-copy-multicast*))
             (mc-extent  (and mc-plan (getf mc-plan :extent)))
             (ws-leader  (gethash node *tma-copy-ws-leader*))
             (is-leader  (if ws-leader
                             (llvm-build-icmp builder +llvm-int-eq+
                                (%ptx-read-warp-sreg builder module "laneid")
                                (llvm-const-int i32-type 0 nil) "is_lane0")
                             (let* ((tid-x (%gen-nvvm-read-tid-x builder module))
                                    (tid-y (%gen-nvvm-read-tid-y builder module))
                                    (tid-z (%gen-nvvm-read-tid-z builder module))
                                    (tid-sum (llvm-build-add builder (llvm-build-add builder tid-x tid-y "txy") tid-z "txyz")))
                               (llvm-build-icmp builder +llvm-int-eq+ tid-sum
                                  (llvm-const-int i32-type 0 nil) "is_tid_0"))))
             (issue-bb   (llvm-append-basic-block (llvm-get-basic-block-parent (llvm-get-insert-block builder)) "tma_issue"))
             (cont-bb    (llvm-append-basic-block (llvm-get-basic-block-parent (llvm-get-insert-block builder)) "tma_cont")))
        (llvm-build-cond-br builder is-leader issue-bb cont-bb)
        (llvm-position-builder-at-end builder issue-bb)
        ;; expect_tx: EVERY workgroup, on its own mbarrier -- including the ones that will not
        ;; issue the multicast, because they are still receiving the bytes.
        (let* ((len-val   (generate-node-ir (semantic-nvvm-tma-tile-copy-tile-length-node node) builder module var-env
                                            di-builder di-scope location-map))
               (elem-b    (semantic-nvvm-tma-tile-copy-elem-bytes node))
               (len-i32   (%coerce-to-i32 builder len-val))
               (tx-bytes  (llvm-build-mul builder len-i32 (llvm-const-int i32-type elem-b nil) "tma_tx_bytes"))
               (mbar-addr (llvm-build-ptr-to-int builder mbar-ptr i32-type "mbar_addr")))
          (%gen-nvvm-mbarrier-arrive-expect-tx builder mbar-addr tx-bytes))
        (cond
          (mc-extent
           ;; Multicast: exactly ONE workgroup per group issues.  Which workgroup, and which
           ;; peers receive, both depend on the group's shape -- see %multicast-axis-plan.
           (let* ((parent    (llvm-get-basic-block-parent (llvm-get-insert-block builder)))
                  ;; Leader predicate is built in the CURRENT block, before the branch.
                  ;; Step 11 REVERTED, and deliberately kept reachable.  Rotating the issuing
                  ;; duty across the group was MEASURED on an H100 and did not recover the
                  ;; multicast tax: clu2 +mc went 0.92x -> 0.88x at 2048 and 0.94x -> 0.91x at
                  ;; 4096, while the no-multicast controls reproduced within 1-2%.  So rotation
                  ;; costs (the predicate stops being loop-invariant) and buys nothing, which
                  ;; falsifies the hypothesis that the tax was single-issuer serialisation.
                  ;;
                  ;; %gen-multicast-leader-pred still IMPLEMENTS rotation and is exercised by
                  ;; passing a rotation source; omitting it selects the static leader, which is
                  ;; what measurement says to use.  The capability is kept because the hypothesis
                  ;; may yet be right for a DIFFERENT kernel -- one whose producer really is the
                  ;; bottleneck -- and rebuilding it from scratch would be wasteful.
                  (is-mc-leader (%gen-multicast-leader-pred builder module mc-plan))
                  (mc-bb     (llvm-append-basic-block parent "tma_mcast_issue"))
                  (mc-cont   (llvm-append-basic-block parent "tma_mcast_cont")))
             (log:info "TMA copy: multicast group axes ~a of cluster ~a (serves ~a workgroups, pattern ~x)"
                       (getf mc-plan :group-axes) (getf mc-plan :dims)
                       (getf mc-plan :extent) (getf mc-plan :pattern))
             (llvm-build-cond-br builder is-mc-leader mc-bb mc-cont)
             (llvm-position-builder-at-end builder mc-bb)
             ;; Mask is built INSIDE mc-bb -- the builder is positioned there, so the sreg
             ;; reads and the shift land on the issuing path only.
             (%gen-nvvm-tma-bulk-tensor-g2s-2d builder module dst-ptr mbar-ptr tmap-ptr coord0 coord1
                                               (%gen-multicast-mask-value builder module mc-plan) t)
             (llvm-build-br builder mc-cont)
             (llvm-position-builder-at-end builder mc-cont)))
          (t
           (%gen-nvvm-tma-bulk-tensor-g2s-2d builder module dst-ptr mbar-ptr tmap-ptr coord0 coord1)))
        (llvm-build-br builder cont-bb)
        (llvm-position-builder-at-end builder cont-bb)
        (values nil nil)))))


;;; =====================================================================
;;; Endeavor 152 — the COMPILER-EMITTED CLUSTER ENTRY FENCE
;;;
;;; FOUND ON METAL: rung 11 compiled, launched, and died with `unspecified launch
;;; failure`.  A control run of the identical kernel with `:multicast` removed ran
;;; correctly, so the fault was multicast-specific rather than the spec's geometry.
;;;
;;; THE CAUSE IS THE ONE THE DESIGN NAMED AND I THEN SKIPPED.  From the sync-cluster
;;; discussion, the first of two obligatory compiler-emitted fences:
;;;
;;;     "After mbarrier init, before the mainloop.  CTA 0 can reach the loop and
;;;      remote-arrive on CTA 1's barrier before CTA 1 has initialized it."
;;;
;;; The emitted PTX was exactly that race:
;;;
;;;     mbarrier.init.shared.b64  [__crisp_mbar_1], %r22;
;;;     fence.proxy.async.shared::cta;
;;;     bar.sync 0;                                  <- WORKGROUP sync only
;;;     cp.async.bulk.tensor...multicast::cluster    <- writes into PEER shared memory
;;;
;;; with ZERO `barrier.cluster` in the module.  `bar.sync` orders the threads of one
;;; workgroup; it says nothing about a PEER workgroup.  So the leader could multicast into
;;; a peer's SMEM and complete a transaction on an mbarrier that peer had not yet
;;; initialised.
;;;
;;; This is why the fence is an OBLIGATION rather than a user-facing choice: the failure is
;;; a launch fault at best, and silent corruption at worst, and nothing about the source
;;; suggests it.  Q2 of Phase 0 verified the fence is sufficient on its own -- the cluster
;;; barrier subsumes intra-workgroup convergence -- so no extra sync-workgroup is needed.
;;;
;;; GATED so non-clustered kernels are byte-identical: emitted only when some kernel in
;;; this module declares a cluster extent > 1.  *kernel-dispatch-declarations* is cleared
;;; per module, so the scan is correctly module-scoped.
;;; =====================================================================

;; src/codegen.lisp  (new)

;; src/analysis/control.lisp


;; src/codegen.lisp
;; BUG 050: cluster EXIT fence.
(defun generate-function-body (semantic-function func di-subprogram builder module di-builder location-map)
  "Generates the body of the function.
   Threads IS-ENTRY-POINT into INITIALIZE-FUNCTION-PARAMETERS so the
   PTX kernel-entry receive site can inttoptr demoted i64 params back
   to their original-addrspace pointer.
   Binds *kernel-readonly-tensor-syms* around the body codegen so the
   semantic-aref tensor case can attach !invariant.load to direct
   reads of read-only kernel-param tensors."
  (let ((entry-block (llvm-append-basic-block func "entry"))
        (var-env (make-hash-table))
        (param-nodes (semantic-function-param-list semantic-function))
        (return-types (semantic-function-return-type semantic-function))
        (is-entry-point (semantic-function-is-entry-point semantic-function)))

    (log:debug "Positioning builder at entry block...")
    (llvm-position-builder-at-end builder entry-block)

    (initialize-function-parameters builder func param-nodes module var-env is-entry-point)

    (let ((*kernel-readonly-tensor-syms*
           (%collect-readonly-tensor-param-syms semantic-function)))
      (when *kernel-readonly-tensor-syms*
        (log:debug "Read-only tensor params for kernel ~a: ~a"
                   (semantic-function-name semantic-function)
                   (loop for k being the hash-keys of *kernel-readonly-tensor-syms*
                         collect k)))

      (let* ((body-nodes (semantic-function-body semantic-function))
             (is-void-return (or (null return-types)
                                 (equal return-types '(nil))
                                 (and (consp return-types) (symbolp (first return-types)) (string-equal (first return-types) "VOID"))))
             (last-val nil)
             (last-loc nil))
        (dolist (node body-nodes)
          (multiple-value-bind (val loc)
              (generate-expression-ir builder module var-env di-builder di-subprogram location-map node)
            (setf last-val val)
            (setf last-loc loc)))

        ;; BUG 050: a CTA must not LEAVE its cluster while a peer may still be writing into
        ;; its shared memory.  With multicast that is exactly what happens -- the group leader
        ;; issues a copy whose destination is every member's SMEM -- so a member that finishes
        ;; its tiles and returns early can be written into after it is gone.  CUDA requires a
        ;; cluster sync before exit for precisely this reason.
        ;;
        ;; The existing fences are emitted at BARRIER CONSTRUCTION, i.e. in the prologue; there
        ;; was none before `ret`.  The failure is therefore a RACE, and shape-dependent: a narrow
        ;; output tile means less work per workgroup, which widens the window in which one member
        ;; can exit while peers are still streaming.  It reproduced as `unspecified launch
        ;; failure` at a 64x32 tile and vanished under compute-sanitizer, whose serialisation
        ;; closes the window -- the signature of a race rather than a bad address.
        (when (and (eq *target-backend* :ptx) is-entry-point (%module-has-cluster-p))
          (log:info "cluster kernel: emitting exit fence before ret (BUG 050)")
          (%gen-nvvm-cluster-barrier builder))
        (let ((ret-inst (if is-void-return
                            (llvm-build-ret-void builder)
                            (let* ((ret-type-spec (first return-types))
                                   (expected-type (crisp-type-to-llvm-type ret-type-spec module))
                                   (actual-type (llvm-type-of last-val)))
                              (if (and (llvm-type-kind-is-pointer? actual-type)
                                       (not (llvm-type-kind-is-pointer? expected-type)))
                                  (llvm-build-ret builder (llvm-build-load2 builder expected-type last-val "ret_val"))
                                  (llvm-build-ret builder last-val))))))
          (when last-loc (llvm-instruction-set-debug-loc ret-inst last-loc)))))))

