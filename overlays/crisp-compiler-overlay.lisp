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


