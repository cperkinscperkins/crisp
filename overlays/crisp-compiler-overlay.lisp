;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins
;;;;
;;;; (Empty — Endeavor 130's hardware-profile logic graduated to
;;;;  src/hardware-profile.lisp.  Append new in-progress definitions here.)

(in-package :crisp.compiler)

;;; ===================================================================
;;; Endeavor 132 — register-tile RESIDENCY (2026-07-05)
;;;
;;; A `make-register-tile` accumulator was one monolithic record variable
;;; (e.g. 64x64 = a {{4xfloat}x32} nested aggregate) that the K-loop rewrote
;;; WHOLESALE via `(set! C-tile (%construct-struct ...))`.  That single
;;; loop-carried aggregate cannot be scalarized by SROA (it survives as a
;;; struct-typed PHI), so the NVPTX backend drops it to `.local` memory —
;;; measured 4896-byte stack frame, ~2300 ld/st.local around the MMAs, even
;;; under opt -O3.  Proven fix (benchmarks/matmul; verified in-process with
;;; opt -O3 -> llc: 0 vs 1024-byte depot): explode the tile into N INDIVIDUAL
;;; per-fragment mutable variables, each set! independently.  Each becomes a
;;; small {4xfloat} value that SROA/mem2reg keeps in registers.
;;;
;;; The N fragment variables must be LET-bound in the enclosing scope (so they
;;; survive the K-loop and reach the post-loop store-tile).  mma-accumulate-
;;; via-tile fires inside the loop and cannot create such bindings — so the
;;; rewrite is hosted at the `let`: a source->source transform that explodes a
;;; (V (make-register-tile T (M N) INIT)) binding into N per-fragment bindings
;;; and rewrites the body's via-tile/store-tile references to V.  We hook it by
;;; wrapping the `let`/`let*` analyzer (same table-override mechanism as the
;;; store-tile overload), deferring to the untouched analyze-let-expression.
;;; ===================================================================

(defun %head-name-eq (head name)
  "T if HEAD is a symbol whose name is NAME (package-insensitive)."
  (and (symbolp head) (string-equal (symbol-name head) name)))

(defun %register-tile-init-form-p (form)
  "T if FORM is a (make-register-tile T (M N) INIT) constructor."
  (and (consp form) (= (length form) 4) (%head-name-eq (first form) "MAKE-REGISTER-TILE")
       (listp (third form)) (= (length (third form)) 2)))

(defun %register-tile-frag-syms (var m n)
  "The N per-fragment variable symbols for tile VAR of shape MxN (row-major
   fragment grid), interned in VAR's package with a `$F<i>' suffix."
  (let ((nfrags (* (floor m 16) (floor n 8))))
    (loop for i below nfrags
          collect (intern (format nil "~a$F~d" (symbol-name var) i) (symbol-package var)))))

(defun %emit-per-frag-accumulate (a b entry)
  "Per-fragment expansion of (mma-accumulate-via-tile _ V A B): one set!/frag,
   matching analyze-mma-accumulate-via-tile's index/layout math."
  (destructuring-bind (m n syms) (cdr entry)
    (let ((m-frags (floor m 16)) (n-frags (floor n 8)))
      `(progn
         ,@(loop for mi below m-frags append
                 (loop for nj below n-frags
                       for idx = (+ (* mi n-frags) nj)
                       collect `(set! ,(nth idx syms)
                                      (mma-accumulate ,(nth idx syms)
                                                      (load-fragment-a ,a (,mi 0))
                                                      (load-fragment-b ,b (0 ,nj))))))))))

(defun %emit-per-frag-store (dest tile-id entry)
  "Per-fragment expansion of (store-tile V DEST (BTY BTX)): one store-fragment
   per fragment, matching analyze-store-tile-mma's runtime-offset math."
  (destructuring-bind (m n syms) (cdr entry)
    (let ((m-frags (floor m 16)) (n-frags (floor n 8))
          (bty (first tile-id)) (btx (second tile-id)))
      `(progn
         ,@(loop for mi below m-frags append
                 (loop for nj below n-frags
                       for idx = (+ (* mi n-frags) nj)
                       collect `(store-fragment ,(nth idx syms)
                                                ,dest
                                                ((+ (* ,bty ,m-frags) ,mi)
                                                 (+ (* ,btx ,n-frags) ,nj)))))))))

(defun %explode-rewrite-body-form (form tiles)
  "Recursively rewrite body FORM: replace via-tile / store-tile references to
   any exploded tile in TILES (alist V -> (V m n syms)) with per-fragment progns;
   otherwise recurse structurally."
  (cond
    ((not (consp form)) form)
    ((and (%head-name-eq (first form) "MMA-ACCUMULATE-VIA-TILE") (= (length form) 5)
          (assoc (third form) tiles))
     (destructuring-bind (shape v a b) (cdr form)
       ;; Still enforce the shape check the analyzer would have run — the explosion
       ;; pre-empts analyze-mma-accumulate-via-tile, so validate here too.
       (%check-mma-shape shape nil)
       (%emit-per-frag-accumulate a b (assoc v tiles))))
    ((and (%head-name-eq (first form) "STORE-TILE") (= (length form) 4)
          (assoc (second form) tiles))
     (destructuring-bind (v dest tile-id) (cdr form)
       (%emit-per-frag-store dest tile-id (assoc v tiles))))
    (t (mapcar (lambda (f) (%explode-rewrite-body-form f tiles)) form))))

(defun %explode-register-tiles (let-expr)
  "Source->source: explode any (V (make-register-tile T (M N) INIT)) binding in
   LET-EXPR into N (V$Fi (make-register-fragment 16 8 INIT)) bindings, and rewrite
   the body's via-tile/store-tile references to V into per-fragment progns.  A
   no-op (returns LET-EXPR unchanged) when no register-tile binding is present."
  (if (not (and (consp let-expr) (>= (length let-expr) 2) (listp (second let-expr))))
      let-expr
      (let* ((head (first let-expr))
             (bindings (second let-expr))
             (body (cddr let-expr))
             (tiles '()))
        (let ((new-bindings
                (loop for b in bindings
                      append
                      (if (and (consp b) (= (length b) 2) (symbolp (first b))
                               (%register-tile-init-form-p (second b)))
                          (destructuring-bind (mrt elem dims init) (second b)
                            (declare (ignore mrt elem))
                            (destructuring-bind (m n) dims
                              (let ((syms (%register-tile-frag-syms (first b) m n)))
                                (push (list (first b) m n syms) tiles)
                                (loop for s in syms
                                      collect (list s `(make-register-fragment 16 8 ,init))))))
                          (list b)))))
          (if (null tiles)
              let-expr
              `(,head ,new-bindings
                      ,@(mapcar (lambda (f) (%explode-rewrite-body-form f tiles)) body)))))))

(defun analyze-let-with-tile-explosion (expr env context location)
  "let/let* analyzer wrapper: explode register-tile bindings into per-fragment
   mutable variables (register residency, Endeavor 132), then defer to the
   normal let analysis."
  (analyze-let-expression (%explode-register-tiles expr) env context location))

(defun register-mma-analyzers ()
  "Registers the MMA expression analyzers in *expression-analyzers* for both
   :crisp-language and :crisp.compiler.  Called from initialize-expression-analyzers
   (which clrhash-es the table on every compiler init, so a load-time setf would not
   survive).  Overlay: adds the let/let* wrapper for register-tile residency."
  (let ((cl-pkg (find-package :crisp-language))
        (cc-pkg (find-package :crisp.compiler)))
    (dolist (entry (list (cons "MAKE-REGISTER-FRAGMENT" #'analyze-make-register-fragment)
                         (cons "STORE-FRAGMENT"          #'analyze-store-fragment)
                         (cons "LOAD-FRAGMENT-A"         #'analyze-load-fragment-a)
                         (cons "LOAD-FRAGMENT-B"         #'analyze-load-fragment-b)
                         (cons "MMA-ACCUMULATE"          #'analyze-mma-accumulate)
                         (cons "MAKE-REGISTER-TILE"      #'analyze-make-register-tile)
                         (cons "MMA-ACCUMULATE-VIA-TILE" #'analyze-mma-accumulate-via-tile)
                         (cons "INNER-DIMENSION"         #'analyze-inner-dimension)
                         ;; store-tile OVERLOAD: runs after register-control-analyzers,
                         ;; so this wins; it delegates to the SLM store-tile for non-tiles.
                         (cons "STORE-TILE"              #'analyze-store-tile-mma)
                         ;; let/let* WRAPPER: explode register-tile accumulators into
                         ;; per-fragment mutable vars before the normal let analysis.
                         (cons "LET"                     #'analyze-let-with-tile-explosion)
                         (cons "LET*"                    #'analyze-let-with-tile-explosion)))
      (let ((sym-cl (intern (car entry) cl-pkg))
            (sym-cc (intern (car entry) cc-pkg)))
        (setf (gethash sym-cl *expression-analyzers*) (cdr entry))
        (unless (eq sym-cl sym-cc)
          (setf (gethash sym-cc *expression-analyzers*) (cdr entry)))))))
