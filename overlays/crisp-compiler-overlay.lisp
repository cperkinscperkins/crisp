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
