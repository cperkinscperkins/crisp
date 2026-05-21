;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)


;; src/analysis/control.lisp
;;
;; Endeavor 111 Phase 1a — load-tile-coords / store-tile-coords primitives.
;;
;; These are the "explicit coords" variants of load-tile / store-tile.  They
;; expand into a workgroup-stride-shaped cooperative loop with bounds
;; checking and an implicit local-barrier.
;;
;; API (sub-step 1a, src-first universally):
;;   (load-tile-coords  <src-global> <dest-tile> (origin-coords...) &key (identity 0) transpose)
;;   (store-tile-coords <src-tile> <dest-global> (origin-coords...) &key transformF transpose)
;;
;; Semantics:
;;   load-tile-coords:
;;     - For each tile coord (cooperatively across the workgroup), compute the
;;       corresponding source coord = origin + tile-coord (or transposed map
;;       for :transpose t).
;;     - If source coord is in-bounds, copy source[src-coord] -> tile[tile-coord].
;;     - If source coord is out-of-bounds, write the :identity value to
;;       tile[tile-coord] (default 0).
;;     - Ends with (local-barrier) so subsequent reads see the loaded tile.
;;
;;   store-tile-coords:
;;     - Starts with (local-barrier) so all prior tile writes are visible.
;;     - For each tile coord (cooperatively), compute dest coord = origin +
;;       tile-coord (or transposed).
;;     - If dest coord is in-bounds, write tile[tile-coord] (optionally run
;;       through :transformF first) to dest[dest-coord].  Out-of-bounds
;;       tile slots are silently skipped (no :identity equivalent on store).
;;     - Ends with (local-barrier).
;;
;; Transpose handling (Phase 1a):
;;   - :transpose nil or absent: identity coord map.
;;   - :transpose t: swap the innermost two dims of the coord map.  Requires
;;     arity >= 2; arity 1 with :transpose t is a compile error.
;;   - Explicit permutation lists (e.g. '(0 2 1)): deferred.


(defun %extract-key-arg (key-args keyword default)
  "Parses a &key-style plist KEY-ARGS for KEYWORD, returning its value or
   DEFAULT if absent.  Phase 1a helper for load-tile-coords / store-tile-coords
   keyword parsing."
  (loop for (k v) on key-args by #'cddr
        when (eq k keyword) return v
        finally (cl:return default)))


(defun %tlc-transpose-permutation (n transpose-form location)
  "Returns the coord permutation list implied by TRANSPOSE-FORM for a tile of
   arity N.  Returns NIL for identity (no transpose).  Errors on invalid
   combinations.  Phase 1a: only NIL and T are supported; explicit permutation
   lists are deferred."
  (cond
    ((null transpose-form) nil)
    ((or (eq transpose-form t)
         (and (symbolp transpose-form)
              (string-equal (symbol-name transpose-form) "T")))
     (when (< n 2)
       (error 'crisp-compiler-error
              :message ":transpose t requires tensor arity >= 2 (1D tensors have nothing to transpose)"
              :source-location location))
     ;; Swap innermost two dims of the identity permutation.
     (let ((p (loop for i from 0 below n collect i)))
       (rotatef (nth (- n 2) p) (nth (- n 1) p))
       p))
    (t
     (error 'crisp-compiler-error
            :message (format nil
                             ":transpose ~S not supported in Phase 1a (only nil and t are accepted)"
                             transpose-form)
            :source-location location))))


(defun %tlc-coop-loop-skeleton (n tile-sym local-bindings tile-coord-syms
                                tile-extent-syms lid-syms lws-syms inner-form
                                cl-pkg)
  "Builds the cooperative N-dim workgroup-strided nest used by
   load-tile-coords and store-tile-coords.  At each level:
     (dotimes (K_k TE_k LWS_k)
       (let ((tile-coord-k (+ K_k LID_k)))
         (when (< tile-coord-k TE_k)
           <inner>)))
   Returns the nested form.  Local-bindings is the outer let's binding list
   (passed through unchanged; caller adds tensor/extent/lid/lws bindings).
   Tile-coord-syms / tile-extent-syms / lid-syms / lws-syms must be lists of
   length n."
  (declare (ignore tile-sym local-bindings))
  (let ((let-sym     (intern "LET" cl-pkg))
        (dotimes-sym (intern "DOTIMES" cl-pkg))
        (when-sym    (intern "WHEN" cl-pkg))
        (plus-sym    (intern "+" cl-pkg))
        (lt-sym      (intern "<" cl-pkg))
        (k-syms      (loop for i from 0 below n collect (gensym (format nil "K~A" i))))
        (acc inner-form))
    (loop for i from (1- n) downto 0
          for tc-sym  = (nth i tile-coord-syms)
          for te-sym  = (nth i tile-extent-syms)
          for lid-sym = (nth i lid-syms)
          for lws-sym = (nth i lws-syms)
          for k-sym   = (nth i k-syms)
          do (setf acc
                   (list dotimes-sym
                         (list k-sym te-sym lws-sym)
                         (list let-sym
                               (list (list tc-sym (list plus-sym k-sym lid-sym)))
                               (list when-sym
                                     (list lt-sym tc-sym te-sym)
                                     acc)))))
    acc))


(defun %tlc-source-coord-exprs (n origin-syms tile-coord-syms perm plus-sym)
  "Returns a list of N source-coord expressions: source-coord[k] = origin[k]
   + tile-coord[perm[k]].  PERM is NIL for identity (no transpose) or a
   permutation list of length N."
  (loop for k from 0 below n
        for src-tile-idx = (if perm (nth k perm) k)
        collect (list plus-sym (nth k origin-syms) (nth src-tile-idx tile-coord-syms))))


(defun %tlc-all-in-bounds-form (n src-coord-exprs global-extent-syms
                                lt-sym and-sym)
  "Builds an AND of per-dim bounds checks: (and (< src-coord[k] ge[k]) ...).
   For N=1, returns just the single comparison."
  (let ((tests (loop for k from 0 below n
                     collect (list lt-sym (nth k src-coord-exprs) (nth k global-extent-syms)))))
    (if (= (length tests) 1)
        (first tests)
        (cons and-sym tests))))


;; src/analysis/control.lisp
(defun %expand-load-tile-coords-form (expr location)
  "Pure expansion of (load-tile-coords SRC TILE (ORIGIN...) &key (identity 0) transpose).
   Returns a let/dotimes/when nest that cooperatively loads the tile, ending
   with (local-barrier)."
  (let* ((src-form     (second expr))
         (tile-form    (third expr))
         (origin-list  (fourth expr))
         (key-args     (nthcdr 4 expr)))
    (unless (and (listp origin-list)
                 (>= (length origin-list) 1))
      (error 'crisp-compiler-error
             :message "load-tile-coords: origin must be a non-empty list of coord forms"
             :source-location location))
    (let* ((identity-form  (%extract-key-arg key-args :identity 0))
           (transpose-form (%extract-key-arg key-args :transpose nil))
           (n              (length origin-list))
           (perm           (%tlc-transpose-permutation n transpose-form location))
           (cl-pkg         (find-package :crisp-language))
           (let-sym             (intern "LET" cl-pkg))
           (progn-sym           (intern "PROGN" cl-pkg))
           (if-sym              (intern "IF" cl-pkg))
           (set-sym             (intern "SET!" cl-pkg))
           (aref-sym            (intern "~" cl-pkg))
           (extents-tilde-sym   (intern "EXTENTS~" cl-pkg))
           (get-local-id-sym    (intern "GET-LOCAL-ID" cl-pkg))
           (get-lws-sym         (intern "GET-LOCAL-WORK-SIZE" cl-pkg))
           (local-barrier-sym   (intern "LOCAL-BARRIER" cl-pkg))
           (to-ulong-sym        (intern "TO-ULONG" cl-pkg))
           (plus-sym            (intern "+" cl-pkg))
           (lt-sym              (intern "<" cl-pkg))
           (and-sym             (intern "AND" cl-pkg))
           (src-sym  (gensym "SRC"))
           (tile-sym (gensym "TILE"))
           (ident-sym (gensym "IDENT"))
           (origin-syms       (loop for i from 0 below n collect (gensym (format nil "ORIG~A" i))))
           (tile-coord-syms   (loop for i from 0 below n collect (gensym (format nil "TLC~A" i))))
           (tile-extent-syms  (loop for i from 0 below n collect (gensym (format nil "TE~A" i))))
           (global-extent-syms (loop for i from 0 below n collect (gensym (format nil "GE~A" i))))
           (lid-syms          (loop for i from 0 below n collect (gensym (format nil "LID~A" i))))
           (lws-syms          (loop for i from 0 below n collect (gensym (format nil "LWS~A" i))))
           ;; Source coord expressions: src[k] = origin[k] + tile-coord[perm[k]]
           (src-coord-exprs   (%tlc-source-coord-exprs n origin-syms tile-coord-syms perm plus-sym))
           ;; The innermost body:  (if (and-bounds) (set! tile = src[..]) (set! tile = identity))
           (tile-aref         (cons aref-sym (cons tile-sym tile-coord-syms)))
           (src-aref          (cons aref-sym (cons src-sym src-coord-exprs)))
           (bounds-form       (%tlc-all-in-bounds-form n src-coord-exprs
                                                       global-extent-syms lt-sym and-sym))
           (inner-body        (list if-sym
                                    bounds-form
                                    (list set-sym tile-aref src-aref)
                                    (list set-sym tile-aref ident-sym)))
           (loop-nest (%tlc-coop-loop-skeleton n tile-sym nil tile-coord-syms
                                               tile-extent-syms lid-syms lws-syms
                                               inner-body cl-pkg))
           (outer-bindings
            (append
             (list (list src-sym src-form)
                   (list tile-sym tile-form)
                   (list ident-sym identity-form))
             ;; Origin coords are wrapped in (to-ulong ...) so that the inner
             ;; arithmetic (+ origin tile-coord) is type-consistent regardless
             ;; of whether the user passed int literals or already-ulong values.
             (loop for i from 0 below n
                   for o-sym in origin-syms
                   collect (list o-sym (list to-ulong-sym (nth i origin-list))))
             (loop for i from 0 below n
                   for te-sym in tile-extent-syms
                   collect (list te-sym (list aref-sym (list extents-tilde-sym tile-sym) i)))
             (loop for i from 0 below n
                   for ge-sym in global-extent-syms
                   collect (list ge-sym (list aref-sym (list extents-tilde-sym src-sym) i)))
             (loop for i from 0 below n
                   for lid-sym in lid-syms
                   collect (list lid-sym (list get-local-id-sym i)))
             (loop for i from 0 below n
                   for lws-sym in lws-syms
                   collect (list lws-sym (list get-lws-sym i))))))
      (list let-sym outer-bindings
            (list progn-sym
                  loop-nest
                  (list local-barrier-sym))))))


;; src/analysis/control.lisp
(defun %expand-store-tile-coords-form (expr location)
  "Pure expansion of (store-tile-coords TILE DEST (ORIGIN...) &key transformF transpose).
   Returns a let/progn nest with (local-barrier) BEFORE and AFTER the
   cooperative store loop.  TransformF is applied per-element (unary)."
  (let* ((tile-form    (second expr))
         (dest-form    (third expr))
         (origin-list  (fourth expr))
         (key-args     (nthcdr 4 expr)))
    (unless (and (listp origin-list)
                 (>= (length origin-list) 1))
      (error 'crisp-compiler-error
             :message "store-tile-coords: origin must be a non-empty list of coord forms"
             :source-location location))
    (let* ((transformF-form (%extract-key-arg key-args :transformF nil))
           (transpose-form  (%extract-key-arg key-args :transpose nil))
           (n               (length origin-list))
           (perm            (%tlc-transpose-permutation n transpose-form location))
           (cl-pkg          (find-package :crisp-language))
           (let-sym             (intern "LET" cl-pkg))
           (progn-sym           (intern "PROGN" cl-pkg))
           (when-sym            (intern "WHEN" cl-pkg))
           (set-sym             (intern "SET!" cl-pkg))
           (funcall-sym         (intern "FUNCALL" cl-pkg))
           (aref-sym            (intern "~" cl-pkg))
           (extents-tilde-sym   (intern "EXTENTS~" cl-pkg))
           (get-local-id-sym    (intern "GET-LOCAL-ID" cl-pkg))
           (get-lws-sym         (intern "GET-LOCAL-WORK-SIZE" cl-pkg))
           (local-barrier-sym   (intern "LOCAL-BARRIER" cl-pkg))
           (to-ulong-sym        (intern "TO-ULONG" cl-pkg))
           (plus-sym            (intern "+" cl-pkg))
           (lt-sym              (intern "<" cl-pkg))
           (and-sym             (intern "AND" cl-pkg))
           (tile-sym (gensym "TILE"))
           (dest-sym (gensym "DEST"))
           (origin-syms       (loop for i from 0 below n collect (gensym (format nil "ORIG~A" i))))
           (tile-coord-syms   (loop for i from 0 below n collect (gensym (format nil "TLC~A" i))))
           (tile-extent-syms  (loop for i from 0 below n collect (gensym (format nil "TE~A" i))))
           (global-extent-syms (loop for i from 0 below n collect (gensym (format nil "GE~A" i))))
           (lid-syms          (loop for i from 0 below n collect (gensym (format nil "LID~A" i))))
           (lws-syms          (loop for i from 0 below n collect (gensym (format nil "LWS~A" i))))
           ;; Dest coord expressions: dest[k] = origin[k] + tile-coord[perm[k]]
           (dest-coord-exprs  (%tlc-source-coord-exprs n origin-syms tile-coord-syms perm plus-sym))
           (tile-aref         (cons aref-sym (cons tile-sym tile-coord-syms)))
           (dest-aref         (cons aref-sym (cons dest-sym dest-coord-exprs)))
           (bounds-form       (%tlc-all-in-bounds-form n dest-coord-exprs
                                                       global-extent-syms lt-sym and-sym))
           ;; Value to store: transformF(tile[..]) if transformF supplied, else tile[..]
           (value-form (if transformF-form
                           (list funcall-sym transformF-form tile-aref)
                           tile-aref))
           ;; The innermost body: (when bounds (set! dest = value))
           (inner-body (list when-sym
                             bounds-form
                             (list set-sym dest-aref value-form)))
           (loop-nest (%tlc-coop-loop-skeleton n tile-sym nil tile-coord-syms
                                               tile-extent-syms lid-syms lws-syms
                                               inner-body cl-pkg))
           (outer-bindings
            (append
             (list (list tile-sym tile-form)
                   (list dest-sym dest-form))
             (loop for i from 0 below n
                   for o-sym in origin-syms
                   collect (list o-sym (list to-ulong-sym (nth i origin-list))))
             (loop for i from 0 below n
                   for te-sym in tile-extent-syms
                   collect (list te-sym (list aref-sym (list extents-tilde-sym tile-sym) i)))
             (loop for i from 0 below n
                   for ge-sym in global-extent-syms
                   collect (list ge-sym (list aref-sym (list extents-tilde-sym dest-sym) i)))
             (loop for i from 0 below n
                   for lid-sym in lid-syms
                   collect (list lid-sym (list get-local-id-sym i)))
             (loop for i from 0 below n
                   for lws-sym in lws-syms
                   collect (list lws-sym (list get-lws-sym i))))))
      (list let-sym outer-bindings
            (list progn-sym
                  (list local-barrier-sym)   ; barrier BEFORE
                  loop-nest
                  (list local-barrier-sym))))))   ; barrier AFTER


(defun analyze-load-tile-coords-expression (expr env context location)
  "Analyzer for (load-tile-coords SRC TILE (ORIGIN...) &key (identity 0) transpose).
   Delegates codegen via %expand-load-tile-coords-form."
  (analyze-expression (%expand-load-tile-coords-form expr location)
                      env context location))


(defun analyze-store-tile-coords-expression (expr env context location)
  "Analyzer for (store-tile-coords TILE DEST (ORIGIN...) &key transformF transpose).
   Delegates codegen via %expand-store-tile-coords-form."
  (analyze-expression (%expand-store-tile-coords-form expr location)
                      env context location))


;; Register the analyzers.  These are NEW forms (not present in src), so we
;; can register at the bottom of register-control-analyzers — overriding it
;; with a whole-function replacement that adds the LOAD-TILE-COORDS and
;; STORE-TILE-COORDS entries at the tail.
(defun register-control-analyzers ()
  "Registers all control flow expression analyzers, including loop-vector-stride,
   tensor-stride, grid-stride, tile-stride, hardware-stride, workgroup-stride,
   and (111 Phase 1a) load-tile-coords / store-tile-coords."
  (def-expression-analyzer function analyze-function-literal)
  (def-expression-analyzer common-lisp:function analyze-function-literal)
  (def-expression-analyzer funcall analyze-funcall-expression)
  (def-expression-analyzer let analyze-let-expression)
  (def-expression-analyzer common-lisp:let analyze-let-expression)
  (def-expression-analyzer let* analyze-let-expression)
  (def-expression-analyzer common-lisp:let* analyze-let-expression)
  (def-expression-analyzer progn analyze-progn-expression)
  (def-expression-analyzer sizeof analyze-sizeof-expression)
  (def-expression-analyzer compiler-no-op analyze-compiler-no-op)
  (def-expression-analyzer is-set? analyze-is-set-expression)
  (def-expression-analyzer if analyze-if-expression)
  (def-expression-analyzer when analyze-when-expression)
  (def-expression-analyzer common-lisp:when analyze-when-expression)
  (def-expression-analyzer unless analyze-unless-expression)
  (def-expression-analyzer common-lisp:unless analyze-unless-expression)
  (def-expression-analyzer return analyze-return-expression)
  (def-expression-analyzer explicit-return analyze-return-expression)
  (def-expression-analyzer semantic-return analyze-return-expression)
  (def-expression-analyzer quote analyze-quote)
  (def-expression-analyzer if+ analyze-static-if-expression)
  (def-expression-analyzer when+ analyze-static-when-expression)
  (def-expression-analyzer unless+ analyze-static-unless-expression)
  (def-expression-analyzer def-function analyze-nested-def-function)
  (def-expression-analyzer template-instantiation analyze-template-instantiation)
  (def-expression-analyzer common-lisp:eval-when analyze-eval-when)
  (let ((sym-cl (intern "LENGTH~" (find-package :crisp-language)))
        (sym-cc (intern "LENGTH~" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-length-tilde-expression)
    (setf (gethash sym-cc *expression-analyzers*) #'analyze-length-tilde-expression))
  (let ((sym-cl (intern "DOTIMES" (find-package :crisp-language)))
        (sym-cc (intern "DOTIMES" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-dotimes-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-dotimes-expression)))
  (let ((sym-cl (intern "LOOP-VECTOR-STRIDE" (find-package :crisp-language)))
        (sym-cc (intern "LOOP-VECTOR-STRIDE" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-loop-vector-stride-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-loop-vector-stride-expression)))
  (let ((sym-cl (intern "TENSOR-STRIDE" (find-package :crisp-language)))
        (sym-cc (intern "TENSOR-STRIDE" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-tensor-stride-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-tensor-stride-expression)))
  (let ((sym-cl (intern "GRID-STRIDE" (find-package :crisp-language)))
        (sym-cc (intern "GRID-STRIDE" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-grid-stride-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-grid-stride-expression)))
  (let ((sym-cl (intern "TILE-STRIDE" (find-package :crisp-language)))
        (sym-cc (intern "TILE-STRIDE" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-tile-stride-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-tile-stride-expression)))
  (let ((sym-cl (intern "HARDWARE-STRIDE" (find-package :crisp-language)))
        (sym-cc (intern "HARDWARE-STRIDE" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-hardware-stride-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-hardware-stride-expression)))
  (let ((sym-cl (intern "WORKGROUP-STRIDE" (find-package :crisp-language)))
        (sym-cc (intern "WORKGROUP-STRIDE" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-workgroup-stride-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-workgroup-stride-expression)))
  ;; 110: warp helper builtins.  Registered via a sibling helper that lives
  ;; in src after the Phase 0 merge.
  (register-warp-builtins)
  ;; 111 Phase 1a: load-tile-coords / store-tile-coords
  (let ((sym-cl (intern "LOAD-TILE-COORDS" (find-package :crisp-language)))
        (sym-cc (intern "LOAD-TILE-COORDS" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-load-tile-coords-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-load-tile-coords-expression)))
  (let ((sym-cl (intern "STORE-TILE-COORDS" (find-package :crisp-language)))
        (sym-cc (intern "STORE-TILE-COORDS" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-store-tile-coords-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-store-tile-coords-expression))))
