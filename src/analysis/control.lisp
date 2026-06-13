;;; src/analysis/control.lisp
(in-package :crisp.compiler)

(defun ensure-branch-compatibility (then-node else-node location)
  "Unifies types of then/else branches. Returns (values unified-type new-then new-else)."
  (let ((t-type (semantic-node-type then-node)))
    (unless else-node
      ;; Propagate THEN type if no ELSE (implicitly returns void/nil or 0? 
      ;; Actually, for IF expression correctness, missing else implies value is unlikely to be used
      ;; unless it matches the implicit else value (int 0). 
      ;; For now, just return t-type. 
      (return-from ensure-branch-compatibility (values t-type then-node nil)))

    (let ((e-type (semantic-node-type else-node))
          (t-single (get-single-value-type then-node))
          (e-single (get-single-value-type else-node)))
      (if (equal t-type e-type)
          (values t-type then-node else-node)
          (let ((promoted (get-promoted-type t-single e-single)))
            (cond
             (promoted
               ;; Insert Casts
               (values promoted
                 (if (equal t-type promoted) then-node (create-implicit-cast then-node promoted location))
                 (if (equal e-type promoted) else-node (create-implicit-cast else-node promoted location))))

             ;; Special Case: Literal 0 (Int) can promote to any Pointer -> NULL
             ((and (eq t-single 'int) (typep then-node 'semantic-literal) (= (semantic-literal-value then-node) 0)
                   (listp e-type) (member (first e-type) '(ptr array)))
               (values e-type (create-implicit-cast then-node e-type location) else-node))

             ((and (eq e-single 'int) (typep else-node 'semantic-literal) (= (semantic-literal-value else-node) 0)
                   (listp t-type) (member (first t-type) '(ptr array)))
               (values t-type then-node (create-implicit-cast else-node t-type location)))

             ;; Void Compatibility: If one branch is NIL (void), unify to NIL (void).
             ;; This supports (when ...) and (unless ...) which return NIL on one path.
             ((or (null t-single) (null e-single))
               (values '(nil) then-node else-node))

             (t
               (error "Branch type mismatch in IF expression. Then: ~a, Else: ~a" t-type e-type))))))))




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


;; load-tile-coords / store-tile-coords (and the bare load-tile / store-tile
;; that rewrite to them) contain internal (local-barrier) calls.  Inside a
;; thread-divergent (if / when / unless / cond) where some threads enter the
;; branch and others don't, only some threads hit the barrier — deadlock.
;;
;; The compiler tracks divergent-conditional context via the dynamic
;; defvar *in-divergent-conditional*.  Set to T inside the analyzed branches
;; of a runtime if-expression (when both branches are analyzed, i.e. the
;; condition wasn't constant-folded).  The load-tile-coords / store-tile-coords
;; analyzers check the flag at entry and error if set.
;;
;; if+ / when+ / unless+ are compile-time conditionals — they DCE to a single
;; branch before analysis, so no runtime divergence is introduced.

(defvar *in-divergent-conditional* nil
  "T when the analyzer is currently inside a thread-divergent if/when/unless/cond
   branch (i.e. the conditional's test was not constant-folded).  Used by the
   load-tile-coords / store-tile-coords analyzers to reject placement that
   would deadlock at their internal local-barriers.

   Compiler-generated workgroup-uniform whens (e.g. the per-dim bounds check
   that wraps tile-stride / hardware-stride :workgroup-idx bodies) use the
   internal %uniform-when form instead, whose analyzer does NOT set this flag.")

(defun analyze-%uniform-if-impl (expr env context location)
  "Internal-use: structurally identical to analyze-if-expression-impl but
   does NOT bind *in-divergent-conditional* on the two-branch path.  Use
   only from compiler-generated forms whose conditions are guaranteed
   workgroup-uniform."
  (let* ((raw-cond-node (analyze-expression (second expr) env context (append location '(1))))
         (cond-node (try-constant-fold raw-cond-node)))
    (when (typep cond-node 'semantic-literal)
          (let ((val (semantic-literal-value cond-node)))
            (if (or (null val) (and (integerp val) (= val 0)))
                (if (fourth expr)
                    (return-from analyze-%uniform-if-impl (analyze-expression (fourth expr) env context (append location '(3))))
                    (return-from analyze-%uniform-if-impl (make-semantic-literal :value-type 'int :value 0 :source-location location)))
                (return-from analyze-%uniform-if-impl (analyze-expression (third expr) env context (append location '(2)))))))
    ;; Two-branch path — NO flag binding (caller asserts workgroup-uniform).
    (let* ((then-node (analyze-expression (third expr) env context (append location '(2))))
           (else-node (if (fourth expr) (analyze-expression (fourth expr) env context (append location '(3))) nil)))
      (multiple-value-bind (unified-type final-then final-else)
          (ensure-branch-compatibility then-node else-node location)
        (make-semantic-if :type unified-type
                          :condition-node cond-node
                          :then-node final-then
                          :else-node final-else
                          :source-location location)))))


(defun analyze-%uniform-when-expression (expr env context location)
  "Internal: like when, but workgroup-uniform — does not set
   *in-divergent-conditional*.  Used by compiler-generated stride bounds-
   checks; not exposed to user code."
  (let ((cond (second expr))
        (body (cons 'progn (cddr expr))))
    (analyze-%uniform-if-impl `(if ,cond ,body) env context location)))


(defun %tlc-check-not-divergent (op-name location)
  "Signals a clear compile error if (op-name) appears inside a thread-divergent
   conditional.  Call from load-tile-coords / store-tile-coords analyzers."
  (when *in-divergent-conditional*
    (error 'crisp-compiler-error
           :message (format nil
                            "~A cannot appear inside a thread-divergent conditional (if / when / unless / cond).  It contains an internal local-barrier that would deadlock when only some threads enter the branch.  Compile-time conditionals (if+ / when+ / unless+) are safe.  If you need a guarded copy, use a non-divergent condition (e.g. one based on get-workgroup-id, not get-local-id) or restructure the kernel."
                            op-name)
           :source-location location)))


(defun analyze-load-tile-coords-expression (expr env context location)
  "Analyzer for (load-tile-coords SRC TILE (ORIGIN...) &key (identity 0) transpose).
   Rejects placement inside a thread-divergent conditional, then delegates
   codegen via %expand-load-tile-coords-form."
  (%tlc-check-not-divergent "load-tile-coords" location)
  (analyze-expression (%expand-load-tile-coords-form expr location)
                      env context location))


(defun analyze-store-tile-coords-expression (expr env context location)
  "Analyzer for (store-tile-coords TILE DEST (ORIGIN...) &key transformF transpose).
   Rejects placement inside a thread-divergent conditional, then delegates
   codegen via %expand-store-tile-coords-form."
  (%tlc-check-not-divergent "store-tile-coords" location)
  (analyze-expression (%expand-store-tile-coords-form expr location)
                      env context location))

(defun analyze-if-expression-impl (expr env context location &key enforce-constant)
  (let* ((raw-cond-node (analyze-expression (second expr) env context (append location '(1))))
         (cond-node (try-constant-fold raw-cond-node)))

    ;; DCE Optimization: If condition is a constant int/bool literal, analyze ONLY the live branch.
    ;; No runtime divergence — analyze the live branch without setting the divergent flag.
    (when (typep cond-node 'semantic-literal)
          (let ((val (semantic-literal-value cond-node)))
            ;; Treat 0 and NIL as false, everything else as true.
            (if (or (null val) (and (integerp val) (= val 0)))
                ;; Constant False -> Analyze Else only, skip Then.
                (if (fourth expr)
                    (return-from analyze-if-expression-impl (analyze-expression (fourth expr) env context (append location '(3))))
                    (return-from analyze-if-expression-impl (make-semantic-literal :value-type 'int :value 0 :source-location location))) ; Empty else -> Constant False
                ;; Constant True -> Analyze Then only, skip Else.
                (return-from analyze-if-expression-impl (analyze-expression (third expr) env context (append location '(2)))))))

    ;; If we are here, the condition is NOT a constant.
    (when enforce-constant
          (error "IF+ condition failed to evaluate at compile time: ~a" expr))

    ;; Phase 1d: both branches will be analyzed → runtime divergence.  Bind
    ;; *in-divergent-conditional* to T for the branch analyses so that any
    ;; load-tile-coords / store-tile-coords inside either branch is rejected.
    (let* ((*in-divergent-conditional* t)
           (then-node (analyze-expression (third expr) env context (append location '(2))))
           (else-node (if (fourth expr) (analyze-expression (fourth expr) env context (append location '(3))) nil)))

      (multiple-value-bind (unified-type final-then final-else)
          (ensure-branch-compatibility then-node else-node location)

        (make-semantic-if :type unified-type
                          :condition-node cond-node
                          :then-node final-then
                          :else-node final-else
                          :source-location location)))))

(defun analyze-if-expression (expr env context location)
  (analyze-if-expression-impl expr env context location :enforce-constant nil))

(defun analyze-static-if-expression (expr env context location)
  (analyze-if-expression-impl expr env context location :enforce-constant t))

(defun analyze-when-expression (expr env context location)
  ;; Delegate to analyze-if-expression to leverage DCE.
  ;; (when cond body...) -> (if cond (progn body...) nil)
  (let ((cond (second expr))
        (body (cons 'progn (cddr expr))))
    (analyze-if-expression `(if ,cond ,body) env context location)))

(defun analyze-static-when-expression (expr env context location)
  (let ((cond (second expr))
        (body (cons 'progn (cddr expr))))
    (analyze-static-if-expression `(if ,cond ,body) env context location)))

(defun analyze-unless-expression (expr env context location)
  ;; Delegate to analyze-if-expression to leverage DCE.
  ;; (unless cond body...) -> (if cond nil (progn body...))
  (let ((cond (second expr))
        (body (cons 'progn (cddr expr))))
    (analyze-if-expression `(if ,cond nil ,body) env context location)))

(defun analyze-static-unless-expression (expr env context location)
  (let ((cond (second expr))
        (body (cons 'progn (cddr expr))))
    (analyze-static-if-expression `(if ,cond nil ,body) env context location)))



(defun %strip-execution-context-declares (body-forms)
  "Strips leading (declare ...) forms from BODY-FORMS.
   Returns (values remaining-body all-decl-specs).
   Uses string-equal matching so package of 'declare doesn't matter."
  (let ((decl-forms (loop for f in body-forms
                          while (and (listp f)
                                     (symbolp (car f))
                                     (string-equal (symbol-name (car f)) "DECLARE"))
                          collect f))
        )
    (values (nthcdr (length decl-forms) body-forms)
            (loop for d in decl-forms append (rest d)))))

(defun %check-context-declarations (decl-specs location)
  "Checks DECL-SPECS for (grid-level) and (workgroup-level) declarations.
   Enforces that:
   - (grid-level) requires *in-dispatch-context* and cannot be nested.
   - (workgroup-level) cannot be nested inside another workgroup-level context.
   Returns (values has-grid-level has-workgroup-level)."
  (let ((has-grid-level (find "GRID-LEVEL" decl-specs
                              :key (lambda (x) (when (consp x) (symbol-name (car x))))
                              :test #'string-equal))
        (has-workgroup-level (find "WORKGROUP-LEVEL" decl-specs
                                   :key (lambda (x) (when (consp x) (symbol-name (car x))))
                                   :test #'string-equal)))

    (when has-grid-level
      (unless *in-dispatch-context*
        (error 'crisp-compiler-error
          :message "Grid-level context cannot appear in a thread-level function. A dispatch context (def-kernel or def-grid-function) is required."
          :source-location location))
      (when *in-grid-level-context*
        (error 'crisp-compiler-error
          :message "Grid-level contexts cannot be nested. Sequential usage is allowed but nesting is not."
          :source-location location)))

    (when has-workgroup-level
      (when *in-workgroup-level-context*
        (error 'crisp-compiler-error
          :message "Workgroup-level contexts cannot be nested inside another workgroup-level context."
          :source-location location)))

    (values has-grid-level has-workgroup-level)))

(defun analyze-let-expression (expr env context location)
  "Analyzes a `(let ...)` expression.
   Extended (091): strips leading declare forms from the body, checks for
   (grid-level) and (workgroup-level) declarations, and enforces nesting rules."
  (unless (and (>= (length expr) 2) (listp (cadr expr)))
    (error "Malformed let form: ~a" expr))

  (let* ((binding-forms (cadr expr))
         (raw-body (cddr expr)))

    ;; Strip leading declares and check for execution-context declarations
    (multiple-value-bind (body-forms decl-specs)
        (%strip-execution-context-declares raw-body)
      (multiple-value-bind (has-grid-level has-workgroup-level)
          (%check-context-declarations decl-specs location)

        ;; Bind context vars for the body analysis
        (let ((*in-grid-level-context* (or *in-grid-level-context* has-grid-level))
              (*in-workgroup-level-context* (or *in-workgroup-level-context* has-workgroup-level)))

          ;; Implement let* scoping by sequentially building the environment.
          (multiple-value-bind (final-env analyzed-bindings)
              (let ((current-env env)
                    (bindings-list '()))
                (loop for binding in binding-forms
                      for i from 0 do
                        (log:debug "Analyzing let binding form: ~s" binding)

                        (let ((is-flat-mvb (and (> (length binding) 2)
                                                (not (listp (first binding))))))

                          (let* ((binding-vars (if is-flat-mvb
                                                   (butlast binding)
                                                   (if (and (= (length binding) 2) (listp (first binding)))
                                                       (first binding)
                                                       (list (first binding)))))
                                 (init-form (first (last binding)))
                                 (current-binding-name (if (= (length binding-vars) 1) (first binding-vars) nil))
                                 (init-node
                                  (let ((old-name (compiler-context-current-binding-name context)))
                                    (when current-binding-name
                                          (setf (compiler-context-current-binding-name context) current-binding-name))
                                    (unwind-protect
                                        (analyze-expression init-form current-env context
                                                            (append location '(1) (list i) (list (if is-flat-mvb (length binding-vars) 1))))
                                      (when current-binding-name
                                            (setf (compiler-context-current-binding-name context) old-name)))))
                                 (init-node-types (semantic-node-type init-node)))

                            (cond
                             ((= (length binding-vars) 1)
                               (let* ((var-name (first binding-vars))
                                      (var-type (get-single-value-type init-node)))
                                 (log:warn "ANALYZE-LET VAR: ~a -> Inferred Type: ~a" var-name var-type)
                                 (push (cons var-name init-node) bindings-list)
                                 (setf current-env (cons (make-parameter-def :name var-name :type var-type :kind :local) current-env))))

                             ((> (length binding-vars) 1)
                               (unless (listp init-node-types)
                                 (error "Cannot destructure a single-value return into multiple variables at ~a. Got type ~a for binding ~a."
                                   (semantic-node-source-location init-node) init-node-types binding))
                               (unless (>= (length init-node-types) (length binding-vars))
                                 (error "Not enough return values from ~a to bind ~a variables at ~a" init-form (length binding-vars) (semantic-node-source-location init-node)))

                               (loop for var-name in binding-vars
                                     for j from 0 do
                                       (let* ((var-type (nth j init-node-types))
                                              (extract-node (make-semantic-extract-value
                                                             :type var-type
                                                             :aggregate-node init-node
                                                             :index j
                                                             :source-location (semantic-node-source-location init-node))))
                                         (push (cons var-name extract-node) bindings-list)
                                         (setf current-env (cons (make-parameter-def :name var-name :type var-type :kind :local) current-env)))))
                             (t (error "Malformed let binding: ~a" binding))))))
                (values current-env (reverse bindings-list)))

            (let* ((analyzed-body (analyze-body-expressions body-forms final-env context (append location '(2))))
                   (last-body-node (first (last analyzed-body)))
                   (return-type (if last-body-node (semantic-node-type last-body-node) 'nil)))
              (log:debug "Analyzed let bindings: ~s~% Analyzed body nodes: ~s~% Let return type: ~s"
                         analyzed-bindings analyzed-body return-type)
              (make-semantic-let :type return-type
                                 :bindings analyzed-bindings
                                 :body analyzed-body
                                 :source-location location))))))))

(defun analyze-progn-expression (expr env context location)
  "Analyzes a `(progn ...)` expression.
   Extended (091): strips leading declare forms, checks for
   (grid-level) and (workgroup-level) declarations, and enforces nesting rules."
  (let ((raw-body (cdr expr)))

    ;; Strip leading declares and check for execution-context declarations
    (multiple-value-bind (body-forms decl-specs)
        (%strip-execution-context-declares raw-body)
      (multiple-value-bind (has-grid-level has-workgroup-level)
          (%check-context-declarations decl-specs location)

        ;; Bind context vars for the body analysis
        (let ((*in-grid-level-context* (or *in-grid-level-context* has-grid-level))
              (*in-workgroup-level-context* (or *in-workgroup-level-context* has-workgroup-level))
              (nodes '()))
          (dolist (form body-forms)
            (push (analyze-expression form env context location) nodes))
          (setf nodes (nreverse nodes))
          (let ((last-node (first (last nodes))))
            (make-semantic-progn
             :type (if last-node (semantic-node-type last-node) 'void)
             :body nodes
             :source-location location)))))))


(defun analyze-return-expression (expr env context location)
  "Analyzes a `(return ...)` expression.
   FIX: A 1-element list whose sole element is a symbol (e.g. (INDEX-T)) is always
   treated as a return-types list, not a parameterized type. This mirrors the fix
   in validate-return-types."
  (let* ((value-forms (rest expr))
         (value-nodes (loop for form in value-forms
                            for i from 1
                            collect (analyze-expression form env context (append location (list i)))))

         ;; Flatten types to check against signature
         ;; FIX: Also treat 1-element symbol lists as return-type lists, not parameterized types
         (all-inferred-types (if value-nodes
                                 (loop for node in value-nodes
                                         append (let ((t-spec (semantic-node-type node)))
                                                  (if (and (listp t-spec)
                                                           (or (not (valid-type-p t-spec))
                                                               (and (= (length t-spec) 1)
                                                                    (symbolp (first t-spec)))))
                                                      t-spec
                                                      (list t-spec))))
                                 '(nil)))

         ;; Context
         (current-func (compiler-context-current-compiling-function context))
         (sig (if current-func (first (gethash current-func *function-table*)) nil))
         (declared-ret (if sig (function-signature-return-types sig) nil))

         ;; Check for invalid return (Deferred Error 04)
         (is-kernel (member '(entry-point) (compiler-context-declarations context) :test #'equal))
         (invalid-return-p (and declared-ret
                                (or (null declared-ret) (equal declared-ret '(nil)))
                                value-nodes
                                is-kernel
                                (not (every (lambda (n)
                                              (let ((t-spec (semantic-node-type n)))
                                                (or (eq t-spec :void)
                                                    (eq t-spec 'void)
                                                    (equal t-spec '(void))
                                                    (equal t-spec '(nil))
                                                    (null t-spec))))
                                         value-nodes)))))

    (when invalid-return-p
          (let* ((node (first value-nodes))
                 (is-explicit-nil (and (= (length value-nodes) 1)
                                       (or (and (typep node 'semantic-literal)
                                                (null (semantic-literal-value node)))
                                           (and (typep node 'semantic-progn)
                                                (equal (semantic-node-type node) '(nil))
                                                (null (semantic-progn-body node)))))))
            (unless is-explicit-nil
              (error 'crisp-compiler-error :message (format nil "Invalid Return: Function declared to return VOID/NIL but returned a value. Declared: ~a" declared-ret) :source-location location))))

    (let ((return-types all-inferred-types))

      ;; Truncation Logic
      (when (and declared-ret (not (equal declared-ret '(nil))))
            (let ((num-declared (length declared-ret))
                  (num-inferred (length all-inferred-types)))

              (when (> num-inferred num-declared)
                    (log:info "Truncating return values for ~a. declared: ~a inferred: ~a" current-func declared-ret all-inferred-types)
                    (let ((new-nodes '())
                          (captured 0))
                      (loop for node in value-nodes
                            while (< captured num-declared)
                            do (let* ((type (semantic-node-type node))
                                      (is-mv (and (listp type) (not (valid-type-p type))))
                                      (count (if is-mv (length type) 1)))
                                 (cond
                                  (is-mv
                                    (loop for i from 0 below count
                                          while (< captured num-declared)
                                          do (push (make-semantic-extract-value :type (nth i type) :aggregate-node node :index i :source-location (semantic-node-source-location node)) new-nodes)
                                            (incf captured)))
                                  (t
                                    (push node new-nodes)
                                    (incf captured)))))
                      (setf value-nodes (nreverse new-nodes))
                      (setf return-types declared-ret)))))

      (make-semantic-explicit-return :type return-types
                                     :value-nodes value-nodes
                                     :source-location location))))

(defun analyze-function-literal (expr env context location)
  "Analyzes (function x) or #'(...)"
  (declare (ignore env context))
  (let ((fn-name (second expr)))
    ;; Check if the function exists (simplistic check for now)
    (unless (or (fboundp fn-name) (gethash fn-name *function-table*))
      (log:warn "Function literal ~a refers to unknown function (at compile time)." fn-name))

    (make-semantic-literal
     :value-type `(:function-literal ,fn-name)
     :value fn-name
     :source-location location)))

(defun analyze-funcall-expression (expr env context location)
  "Analyzes a (funcall f args...) form."
  (let* ((func-expr (second expr))
         (args-exprs (cddr expr))
         (func-node (analyze-expression func-expr env context location))
         (func-type (semantic-node-type func-node)))

    ;; Check if the function expression resolved to a function type or literal.
    ;; e.g. (:function-type (int) :params (int int)) 
    ;; or (:function-literal +)

    (let ((signature-return-type nil)
          (signature-params nil))

      (cond
       ;; Case 1: Function Type (e.g. from a parameter)
       ((and (listp func-type) (eq (first func-type) :function-type))
         (setf signature-return-type (second func-type)) ; (int)
         (setf signature-params (getf (cddr func-type) :params))) ;; Case 2: Function Literal (e.g. #'+)
       ((and (listp func-type) (eq (first func-type) :function-literal))
         (let ((name (second func-type)))
           ;; Sub-case 2a: It is a primitive/special-form with an analyzer (e.g. +)
           (when (gethash name *expression-analyzers*)
                 ;; Re-dispatch as if it were a direct call: (+ a b)
                 (let ((new-expr (cons name args-exprs)))
                   (return-from analyze-funcall-expression
                                (funcall (gethash name *expression-analyzers*) new-expr env context location))))

           ;; Sub-case 2b: It is a user function. Lower to direct semantic-call.
           (let* ((arg-nodes (loop for arg in args-exprs collect (analyze-expression arg env context location)))
                  (arg-types (mapcar #'semantic-node-type arg-nodes))
                  (signatures (gethash name *function-table*))
                  (match (find-if (lambda (sig)
                                    (equal arg-types (mapcar #'parameter-def-type (function-signature-parameters sig))))
                             signatures)))
             (unless match
               (error "No matching signature for funcall of literal ~a with types ~a. Table count: ~a" name arg-types (hash-table-count *function-table*)))

             (return-from analyze-funcall-expression
                          (make-semantic-call
                           :name name
                           :type (function-signature-return-types match)
                           :args arg-nodes
                           :signature match
                           :source-location location)))))

       (t
         (error "First argument to funcall must be a function type or literal. Got ~a" func-type)))

      ;; Continued Case 1 logic (Function Type)
      ;; Verify argument count
      (unless (= (length args-exprs) (length signature-params))
        (error 'crisp-signature-arity-error :expected (length signature-params) :inferred (length args-exprs)))

      ;; Analyze and check arguments
      (let ((arg-nodes
             (loop for arg-expr in args-exprs
                   for expected-type in signature-params
                   for i from 0
                   collect (let ((node (analyze-expression arg-expr env context location)))
                             ;; Type check
                             (unless (equal (semantic-node-type node) expected-type)
                               (error 'crisp-type-error :expected expected-type :inferred (semantic-node-type node) :source-location location))
                             node))))
        (make-semantic-funcall
         :func-node func-node
         :type signature-return-type ; e.g. (int)
         :args arg-nodes
         :source-location location)))))

(defun analyze-quote (expr env context location)
  (declare (ignore env context))
  (let ((val (second expr)))
    (cond
     ((keywordp val) (make-semantic-literal :value-type 'keyword :value val :source-location location))
     ((symbolp val) (make-semantic-literal :value-type 'symbol :value val :source-location location))
     (t (make-semantic-literal :value-type 'quote :value val :source-location location)))))

(defun analyze-sizeof-expression (expr env context location)
  (declare (ignore env context))
  (unless (= (length expr) 2)
    (error "sizeof expects exactly 1 argument: (sizeof type)"))
  (let* ((raw-type (second expr))
         (type-spec (parse-type-specifier raw-type)))
    (unless (valid-type-p type-spec)
      (error 'crisp-unknown-type-error :type-name raw-type :source-location location))
    (make-semantic-sizeof :type 'ulong
                          :target-type type-spec
                          :source-location location)))

(defun analyze-compiler-no-op (expr env context location)
  "Analyzes a (compiler-no-op) form, which results in a void literal.
   Used by compile-time macros (c-t-assert, c-t-output) to emit no code."
  (declare (ignore expr env context))
  (make-semantic-literal :value-type 'void :value nil :source-location location))

(defun analyze-nested-def-function (expr env context location)
  "Analyzes a nested `(def-function ...)` expression (e.g. from a template)."
  (declare (ignore env))
  (unless (compiler-context-allow-nested-def-function context)
    (error "Unsupported form 'DEF-FUNCTION' found in function body."))

  (unless (and *current-module* *current-builder*)
    (error "Cannot compile nested def-function without active LLVM context."))

  ;; Compile the function as a top-level form
  (compile-toplevel-form expr location *current-module* *current-builder* *current-di-builder* *current-di-compile-unit* *current-location-map*)

  ;; Return a void literal so it doesn't affect the expression value
  (make-semantic-literal :value-type 'void :value nil :source-location location))

(defun analyze-template-instantiation (expr env context location)
  "Analyzes a `(template-instantiation ...)` form, allowing nested def-functions."
  (let ((old-allow (compiler-context-allow-nested-def-function context))
        (body (second expr)))
    (setf (compiler-context-allow-nested-def-function context) t)
    (unwind-protect
        (progn
         (log:info "ANALYZE-TEMPLATE-INSTANTIATION: Body=~a" body)
         ;; Eval the body to ensure macros (defmacro) and struct definitions (eval-when)
         ;; are registered in the current environment BEFORE analysis proceeds.
         ;; This allows subsequent forms in the function to usage the newly defined macros.
         ;; This allows subsequent forms in the function to usage the newly defined macros.
         (eval body)

         (let ((sym (find-symbol "MAKE-POINT_FLOAT" "CRISP-LANGUAGE")))
           (if sym
               (log:info "Check: MAKE-POINT_FLOAT in CRISP-LANGUAGE. Macro? ~a" (macro-function sym))
               (log:info "Check: MAKE-POINT_FLOAT NOT FOUND in CRISP-LANGUAGE")))

         ;; The body is typically a PROGN or a single form.
         ;; We analyze it recursively to generate IR for functions.
         (analyze-expression body env context location))
      ;; Cleanup
      (setf (compiler-context-allow-nested-def-function context) old-allow))))

(defun analyze-eval-when (expr env context location)
  "Analyzes (eval-when ...) forms by ignoring them in the runtime IR.
   Side effects (like struct registration) should have already occurred during macro expansion."
  (declare (ignore expr env context))
  (make-semantic-literal :value-type 'void :value nil :source-location location))

(defun analyze-is-set-expression (expr env context location)
  "Analyzes (is-set? var). Returns 1 (true) if var is bound in env, 0 (false) otherwise."
  (declare (ignore context))
  (let ((var (second expr)))
    (unless (symbolp var)
      (error "is-set? expects a symbol, got ~s" var))
    ;; Since this is a compile-time check for optional parameters in specialized templates,
    ;; the 'env' contains *only* the parameters present for this specific specialization.
    (if (find-variable-in-env var env)
        (make-semantic-literal :value-type 'int :value 1 :source-location location)
        (make-semantic-literal :value-type 'int :value 0 :source-location location))))





(defun analyze-length-tilde-expression (expr env context location)
  "Analyzes (length~ arr).
   For (array T N): returns compile-time constant N as ulong literal.
   For tensor/vector/matrix types: dispatches to the runtime length~ accessor.
   Signals crisp-compiler-error if argument is none of the above."
  (unless (= (length expr) 2)
    (error 'crisp-compiler-error
           :message "length~ expects exactly 1 argument: (length~ arr)"
           :source-location location))
  (let* ((arg-node  (analyze-expression (second expr) env context location))
         (raw-type  (semantic-node-type arg-node))
         (arg-type  (resolve-type-alias
                     (if (and (listp raw-type) (= (length raw-type) 1) (listp (first raw-type)))
                         (first raw-type)
                         raw-type)))
         ;; Expand vector/matrix sugar so we can inspect the canonical form
         (expanded  (expand-storage-handle-type-specifier (resolve-type-alias arg-type)))
         ;; A type is tensor-like if it's a mangled tensor symbol, a canonical (tensor ...) list,
         ;; or if expanding it yields a (tensor ...) list (i.e. vector/matrix sugar).
         (is-tensor (let ((resolved (resolve-type-alias arg-type)))
                      (or (and (symbolp resolved)
                               (let* ((parts (unmangle-template-struct-name resolved))
                                      (base  (first parts)))
                                 (and base (string-equal (symbol-name base) "TENSOR"))))
                          (and (listp resolved)
                               (symbolp (first resolved))
                               (string-equal (symbol-name (first resolved)) "TENSOR"))
                          ;; VECTOR / MATRIX expand to (tensor ...) via expand-storage-handle-type-specifier
                          (and (listp expanded)
                               (symbolp (first expanded))
                               (string-equal (symbol-name (first expanded)) "TENSOR"))))))
    (cond
     ;; Tensor / vector / matrix: delegate to the runtime length~ accessor
     (is-tensor
      (log:info "length~~: tensor/vector/matrix type ~a -> delegating to runtime accessor" arg-type)
      (analyze-function-call 'length~ expr env context location))
     ;; Fixed-size array: compile-time constant
     ((%array-type-p arg-type)
      (let* ((n-raw (third arg-type))
             (n     (etypecase n-raw
                      (integer n-raw)
                      (symbol  (parse-integer (symbol-name n-raw))))))
        (log:info "length~~: array type ~a -> N=~a" arg-type n)
        (make-semantic-literal :value-type 'ulong
                               :value      (coerce n '(unsigned-byte 64))
                               :source-location location)))
     ;; Neither: error
     (t
      (error 'crisp-compiler-error
             :message (format nil "length~~ requires an (array T N), tensor, vector, or matrix type, got ~a"
                              arg-type)
             :source-location location)))))


(defun analyze-dotimes-expression (expr env context location)
  "Analyzes (dotimes (var limit [stride]) body...).
   VAR is bound as the limit's type (int, ulong, etc.) in the body.
   STRIDE is optional; defaults to literal 1 of the limit's type.
   Returns a semantic-dotimes node (type void)."
  (unless (and (>= (length expr) 2) (listp (second expr)) (>= (length (second expr)) 2))
    (error 'crisp-compiler-error
           :message "Malformed dotimes: expected (dotimes (var limit [stride]) body...)"
           :source-location location))
  (let* ((binding    (second expr))
         (var-name   (first binding))
         (limit-form (second binding))
         (stride-form (third binding))   ;; NIL when omitted
         (body-forms (cddr expr))
         ;; Analyze limit
         (limit-node (analyze-expression limit-form env context (append location '(0))))
         (limit-type (get-single-value-type limit-node))
         (limit-ct   (gethash limit-type *crisp-types*)))
    ;; Validate: limit must be a registered integer type
    (unless (and limit-ct (member (crisp-type-category limit-ct)
                                  '(:signed-int :unsigned-int)))
      (error 'crisp-compiler-error
             :message (format nil "dotimes limit must be an integer type, got ~a" limit-type)
             :source-location location))
    ;; Analyze stride if provided
    (let ((stride-node (when stride-form
                         (analyze-expression stride-form env context (append location '(0 1))))))
      ;; Extend env: bind var as the limit's type
      (let* ((body-env  (cons (make-parameter-def :name var-name :type limit-type :kind :local) env))
             (body-nodes (analyze-body-expressions body-forms body-env context (append location '(1)))))
        (make-semantic-dotimes :type 'void
                               :var-name var-name
                               :limit-node limit-node
                               :stride-node stride-node
                               :body body-nodes
                               :source-location location)))))




;; ==========================================================================
;; Endeavor 107 — make stride macros AD-able by expanding them BEFORE the
;; AD pipeline walks the kernel body.
;;
;; Background
;; ----------
;; loop-vector-stride / tensor-stride / grid-stride were implemented as
;; expression analyzers (run during the analysis phase of forward
;; compilation).  But %generate-backward-kernel-ast in src/macros.lisp
;; walks the kernel's RAW source body through `anf-transform` BEFORE the
;; analyzer phase runs.  When the AD pass sees `(tensor-stride A (i) ...)`,
;; it never expands the macro — it falls through to "Function X is not
;; differentiable" once the walk reaches some opcode inside the unexpanded
;; body.  Result: every test that used a stride macro had to be tagged
;; `forward-only`, even when its chain rule was otherwise well-defined.
;;
;; Fix
;; ---
;; Extract the analyzer-time expansion logic into source-to-source helper
;; functions:
;;   %expand-tensor-stride-form         (form ct location)        → expansion
;;   %expand-grid-stride-form           (form location)           → expansion
;;   %expand-loop-vector-stride-form    (form location)           → expansion
;;
;; The analyzers call these helpers (passing the env-resolved CT).  A new
;; AD pre-pass — %expand-stride-macros-in-form — walks the kernel body and
;; rewrites every stride form into its expansion before anf-transform sees
;; it.  The pre-pass resolves CT statically via the kernel's signature-types
;; (no env needed for the bare-symbol case which covers all of 092/093/105).
;;
;; Forward IR is unchanged in shape (the analyzers still drive the forward
;; compile).  Backward IR sees an `if + dotimes + let + set!` tree which AD
;; already knows how to walk.

;; --------------------------------------------------------------------------
;; Source-to-source expansion helpers.  Pure: no env, no analyze-expression.
;; Each takes the source form + (for tensor-stride) the resolved CT, and
;; returns the expanded source form ready for either analyze-expression
;; (forward path) or anf-transform (backward path).


;; ======================================================================
;; Endeavor: stride macros — exact-iter-count rewrite (Group A)
;;
;; Group A is the 1-D family of grid-stride loops that all share the same
;; broken pattern:
;;
;;   (dotimes (k LEN GSIZE)            ; k = 0, GSIZE, 2*GSIZE, ...
;;     (let ((flat (+ k GID)))
;;       (if (< flat LEN) BODY ())))
;;
;; The per-iteration `if (< flat LEN)` is a runtime bounds check that
;; LLVM SCEV can't always remove (the dotimes trip count covers all gid
;; values, so the predicate depends on `gid + k * gsize` and is not
;; loop-invariant).  Hand-written CUDA writes the loop as
;; `for (int i = gid; i < n; i += gstride)` — a single-counter affine
;; loop the unroller / vectorizer handle aggressively.
;;
;; New shape mirrors that:
;;
;;   (let ((iters (if (>= GID LEN)
;;                    (to-ulong 0)
;;                    (+ (to-ulong 1) (/ (- (- LEN (to-ulong 1)) GID) GSIZE)))))
;;     (dotimes (k iters)
;;       (let ((flat (+ GID (* k GSIZE))))
;;         BODY)))
;;
;; iters formula: 1 + floor((len - 1 - gid) / gsize) for gid < len, else 0.
;; The outer guard short-circuits the (len - 1 - gid) underflow when
;; gid >= len or len = 0.
;;
;; Macros covered here (all share the shared helper):
;;   - tensor-stride        — N-D tensor walk (decode flat → coords inside)
;;   - grid-stride          — synthetic N-D walk over a size-list
;;   - hardware-stride
;;       :warp-idx          — 1D warp-strided walk over flattened linear domain
;;   - loop-vector-stride   — 1D walk over a vector (refactor for consistency)
;;
;; AD compatibility: backward walker recognises LET, IF (in let-binding
;; init position), DOTIMES, PROGN — all forms used here.  The IF in the
;; iters compute returns an integer count, not a differentiable value,
;; so AD handles it as straight control flow.

(defun %build-exact-iter-count-form (start-sym stride-sym len-sym cl-pkg)
  "Returns an expression that computes the exact iteration count for a
   grid-stride loop starting at START-SYM and stepping by STRIDE-SYM,
   visiting only positions < LEN-SYM.  All three symbols name ULONG values.

   Formula:
     iters = (start >= len) ? 0
                            : 1 + (len - 1 - start) / stride

   The outer (>= start len) guard short-circuits the (len - 1 - start)
   ulong underflow when start >= len or len = 0."
  (let ((if-sym       (intern "IF" cl-pkg))
        (ge-sym       (intern ">=" cl-pkg))
        (plus-sym     (intern "+" cl-pkg))
        (minus-sym    (intern "-" cl-pkg))
        (div-sym      (intern "/" cl-pkg))
        (to-ulong-sym (intern "TO-ULONG" cl-pkg)))
    (let ((zero (list to-ulong-sym 0))
          (one  (list to-ulong-sym 1)))
      (list if-sym
            (list ge-sym start-sym len-sym)
            zero
            (list plus-sym
                  one
                  (list div-sym
                        (list minus-sym
                              (list minus-sym len-sym one)
                              start-sym)
                        stride-sym))))))


(defun %expand-tensor-stride-form (expr ct location)
  "Pure expansion of (tensor-stride T [LAYOUT-TAG] (BINDINGS...) BODY...).
   CT must be :last or :first (already resolved by caller).  Returns the
   expanded let+dotimes tree.  Validates form shape only — strict-tag vs
   CT agreement and tensor-arity checks are the caller's job.

   New shape: exact-iter-count + simple dotimes (no per-iter bounds check)."
  (let* ((strict-p   (keywordp (third expr)))
         (bindings   (if strict-p (fourth expr) (third expr)))
         (body-forms (if strict-p (cddddr expr) (cdddr expr)))
         (tensor-form (second expr)))
    (unless (and bindings (listp bindings) (every #'symbolp bindings)
                 (>= (length bindings) 1))
      (error 'crisp-compiler-error
             :message (if strict-p
                          "Malformed tensor-stride: expected (tensor-stride TENSOR LAYOUT-TAG (BINDING ...) BODY...)"
                          "Malformed tensor-stride: expected (tensor-stride TENSOR (BINDING ...) BODY...)")
             :source-location location))
    (let* ((n           (length bindings))
           (t-sym       (gensym "T"))
           (gid-sym     (gensym "GID"))
           (gsize-sym   (gensym "GSIZE"))
           (len-sym     (gensym "LEN"))
           (iters-sym   (gensym "ITERS"))
           (k-sym       (gensym "K"))
           (flat-sym    (gensym "FLAT"))
           (extents-syms (loop for i from 0 below n collect (gensym (format nil "E~A" i))))
           (cl-pkg          (find-package :crisp-language))
           (let-sym         (intern "LET"                 cl-pkg))
           (declare-sym     (intern "DECLARE"             cl-pkg))
           (grid-level-sym  (intern "GRID-LEVEL"          cl-pkg))
           (dotimes-sym     (intern "DOTIMES"             cl-pkg))
           (progn-sym       (intern "PROGN"               cl-pkg))
           (get-gid-sym     (intern "GET-GLOBAL-ID"        cl-pkg))
           (get-gsize-sym   (intern "GET-GLOBAL-WORK-SIZE" cl-pkg))
           (len-tilde-sym   (intern "LENGTH~"             cl-pkg))
           (extents-tilde   (intern "EXTENTS~"            cl-pkg))
           (aref-sym        (intern "~"                   cl-pkg))
           (plus-sym        (intern "+"                   cl-pkg))
           (mul-sym         (intern "*"                   cl-pkg))
           (extent-bindings
            (loop for esym in extents-syms
                  for i from 0
                  collect (list esym (list aref-sym (list extents-tilde t-sym) i))))
           (stride-bindings (%ts-build-stride-bindings extents-syms ct))
           (decode-bindings (if (= n 1)
                                (list (list (first bindings) flat-sym))
                                (%ts-build-decode-bindings flat-sym bindings
                                                           (mapcar #'first stride-bindings)
                                                           ct)))
           (inner-body (if (= (length body-forms) 1)
                           (first body-forms)
                           (cons progn-sym body-forms)))
           ;; Decode multi-D coords + body, run unconditionally.
           (decode-let (list let-sym decode-bindings inner-body))
           ;; flat = gid + k * gsize
           (flat-let (list let-sym
                           (list (list flat-sym
                                       (list plus-sym gid-sym
                                             (list mul-sym k-sym gsize-sym))))
                           decode-let))
           (dotimes-form (list dotimes-sym
                               (list k-sym iters-sym)
                               flat-let))
           (iters-let (list let-sym
                            (list (list iters-sym
                                        (%build-exact-iter-count-form
                                         gid-sym gsize-sym len-sym cl-pkg)))
                            dotimes-form))
           (outer-let
            (list* let-sym
                   (append (list (list t-sym     tensor-form)
                                 (list gid-sym   (list get-gid-sym 0))
                                 (list gsize-sym (list get-gsize-sym 0))
                                 (list len-sym   (list len-tilde-sym t-sym)))
                           extent-bindings
                           stride-bindings)
                   (list (list declare-sym (list grid-level-sym))
                         iters-let))))
      outer-let)))

(defun %expand-grid-stride-form (expr location)
  "Pure expansion of (grid-stride (SIZE-LIST) (BINDINGS) BODY...).  No type
   info needed — grid-stride is always rightmost-binding-gets-warp.

   New shape: exact-iter-count + simple dotimes (no per-iter bounds check)."
  (unless (and (>= (length expr) 4)
               (listp (second expr)) (listp (third expr))
               (every #'symbolp (third expr))
               (>= (length (second expr)) 1)
               (= (length (second expr)) (length (third expr))))
    (error 'crisp-compiler-error
           :message "Malformed grid-stride: expected (grid-stride (SIZE ...) (BINDING ...) BODY...) with size and binding arity matching and >= 1"
           :source-location location))
  (let* ((size-forms     (second expr))
         (bindings       (third expr))
         (body-forms     (cdddr expr))
         (n              (length bindings))
         (cl-pkg          (find-package :crisp-language))
         (let-sym         (intern "LET"                 cl-pkg))
         (declare-sym     (intern "DECLARE"             cl-pkg))
         (grid-level-sym  (intern "GRID-LEVEL"          cl-pkg))
         (dotimes-sym     (intern "DOTIMES"             cl-pkg))
         (progn-sym       (intern "PROGN"               cl-pkg))
         (get-gid-sym     (intern "GET-GLOBAL-ID"        cl-pkg))
         (get-gsize-sym   (intern "GET-GLOBAL-WORK-SIZE" cl-pkg))
         (plus-sym        (intern "+"                   cl-pkg))
         (mul-sym         (intern "*"                   cl-pkg))
         (to-ulong-sym    (intern "TO-ULONG"            cl-pkg))
         (gid-sym         (gensym "GID"))
         (gsize-sym       (gensym "GSIZE"))
         (len-sym         (gensym "LEN"))
         (iters-sym       (gensym "ITERS"))
         (k-sym           (gensym "K"))
         (flat-sym        (gensym "FLAT"))
         (extents-syms    (loop for i from 0 below n collect (gensym (format nil "E~A" i))))
         (size-bindings   (loop for esym in extents-syms
                                for form in size-forms
                                collect (list esym (list to-ulong-sym form))))
         (len-form        (if (= n 1)
                              (first extents-syms)
                              (reduce (lambda (a b) (list mul-sym a b)) extents-syms)))
         (stride-bindings (%ts-build-stride-bindings extents-syms :last))
         (decode-bindings (if (= n 1)
                              (list (list (first bindings) flat-sym))
                              (%ts-build-decode-bindings flat-sym bindings
                                                         (mapcar #'first stride-bindings)
                                                         :last)))
         (inner-body (if (= (length body-forms) 1)
                         (first body-forms)
                         (cons progn-sym body-forms)))
         (decode-let (list let-sym decode-bindings inner-body))
         (flat-let (list let-sym
                         (list (list flat-sym
                                     (list plus-sym gid-sym
                                           (list mul-sym k-sym gsize-sym))))
                         decode-let))
         (dotimes-form (list dotimes-sym
                             (list k-sym iters-sym)
                             flat-let))
         (iters-let (list let-sym
                          (list (list iters-sym
                                      (%build-exact-iter-count-form
                                       gid-sym gsize-sym len-sym cl-pkg)))
                          dotimes-form))
         (outer-let
          (list* let-sym
                 (append (list (list gid-sym   (list get-gid-sym 0))
                               (list gsize-sym (list get-gsize-sym 0)))
                         size-bindings
                         (list (list len-sym len-form))
                         stride-bindings)
                 (list (list declare-sym (list grid-level-sym))
                       iters-let))))
    outer-let))


(defun %expand-loop-vector-stride-form (expr location)
  "Pure expansion of (loop-vector-stride VEC (VAR) BODY...).
   Refactored to use %build-exact-iter-count-form for consistency with
   the rest of Group A.  Same behaviour as the earlier rewrite — single
   counter dotimes, body runs unconditionally."
  (unless (and (>= (length expr) 3)
               (listp (third expr))
               (= (length (third expr)) 1)
               (symbolp (first (third expr))))
    (error 'crisp-compiler-error
           :message "Malformed loop-vector-stride: expected (loop-vector-stride VEC (VAR) BODY...)"
           :source-location location))
  (let* ((vec-form        (second expr))
         (var-name        (first (third expr)))
         (body-forms      (cdddr expr))
         (gid-sym         (gensym "GID"))
         (gsize-sym       (gensym "GSIZE"))
         (len-sym         (gensym "LEN"))
         (iters-sym       (gensym "ITERS"))
         (k-sym           (gensym "K"))
         (cl-pkg          (find-package :crisp-language))
         (let-sym         (intern "LET"                 cl-pkg))
         (declare-sym     (intern "DECLARE"             cl-pkg))
         (grid-level-sym  (intern "GRID-LEVEL"          cl-pkg))
         (dotimes-sym     (intern "DOTIMES"             cl-pkg))
         (progn-sym       (intern "PROGN"               cl-pkg))
         (get-gid-sym     (intern "GET-GLOBAL-ID"        cl-pkg))
         (get-gsize-sym   (intern "GET-GLOBAL-WORK-SIZE" cl-pkg))
         (len-tilde-sym   (intern "LENGTH~"             cl-pkg))
         (plus-sym        (intern "+"                   cl-pkg))
         (mul-sym         (intern "*"                   cl-pkg))
         (i-binding       (list var-name
                                (list plus-sym gid-sym
                                      (list mul-sym k-sym gsize-sym))))
         (inner-body (if (= (length body-forms) 1)
                         (first body-forms)
                         (cons progn-sym body-forms)))
         (inner-let   (list let-sym (list i-binding) inner-body))
         (dotimes-form (list dotimes-sym (list k-sym iters-sym) inner-let))
         (iters-let   (list let-sym
                            (list (list iters-sym
                                        (%build-exact-iter-count-form
                                         gid-sym gsize-sym len-sym cl-pkg)))
                            dotimes-form))
         (expansion (list let-sym
                          (list (list gid-sym   (list get-gid-sym   0))
                                (list gsize-sym (list get-gsize-sym 0))
                                (list len-sym   (list len-tilde-sym vec-form)))
                          (list declare-sym (list grid-level-sym))
                          iters-let)))
    expansion))

(defun analyze-loop-vector-stride-expression (expr env context location)
  "Analyzes (loop-vector-stride VEC (VAR) BODY...).  Delegates to
   %expand-loop-vector-stride-form."
  (analyze-expression (%expand-loop-vector-stride-form expr location)
                      env context location))



;; ==========================================================================
;; Endeavor 105 — tensor-stride and grid-stride.
;;
;; Phase A (this commit): safe `tensor-stride` analyzer.  Mirrors
;; analyze-loop-vector-stride-expression in src/analysis/control.lisp but
;; generalizes to N dimensions.  Form:
;;
;;   (tensor-stride T (b0 b1 ... b_{N-1}) BODY...)
;;
;; Expands to a single linear dotimes over total length, then decodes
;; multi-D coords from the flat index.  Decode direction depends on the
;; tensor's static contiguous-term (CT):
;;   :last  — warp varies last binding (row-major-style).
;;            flat = i0*s0 + i1*s1 + ... + i_{N-1}
;;            s_k = product(extents[k+1..N-1]); s_{N-1} = 1
;;   :first — warp varies first binding (col-major-style).
;;            flat = i_{N-1}*s_{N-1} + ... + i_0
;;            s_k = product(extents[0..k-1]); s_0 = 1
;;
;; Decode without `mod` (no user-facing op): i = flat / s; rem = flat - i*s.

(defun %ts-build-decode-bindings (flat-sym binding-syms stride-syms ct)
  "Builds the let* binding list that decodes FLAT-SYM into BINDING-SYMS using
   STRIDE-SYMS (per-iteration-strides for each dim, length N or N-1) under
   contiguous-term CT (:last or :first).

   For CT :last:  i0 = flat/s0; rem1 = flat - i0*s0; i1 = rem1/s1; ...; i_{N-1} = rem_{N-1}
   For CT :first: i_{N-1} = flat/s_{N-1}; rem1 = flat - i_{N-1}*s_{N-1}; ...; i_0 = rem_{N-1}"
  (let* ((cl-pkg  (find-package :crisp-language))
         (div-sym (intern "/"  cl-pkg))
         (sub-sym (intern "-"  cl-pkg))
         (mul-sym (intern "*"  cl-pkg))
         (n       (length binding-syms))
         (ordered-bindings (if (eq ct :first)
                               (reverse binding-syms)
                               binding-syms)))
    ;; ordered-bindings[k] gets stride-syms[k] for k < N-1; last gets rem.
    ;; For N=1, no decode needed — caller handles that case separately.
    (let ((bindings nil)
          (current-flat flat-sym))
      (loop for k from 0 below (1- n)
            for bsym = (nth k ordered-bindings)
            for s    = (nth k stride-syms)
            for next-rem = (gensym "REM")
            do (push (list bsym (list div-sym current-flat s)) bindings)
               (push (list next-rem (list sub-sym current-flat
                                          (list mul-sym bsym s)))
                     bindings)
               (setf current-flat next-rem))
      ;; Last binding takes the final remainder
      (push (list (nth (1- n) ordered-bindings) current-flat) bindings)
      (nreverse bindings))))

(defun %ts-build-stride-bindings (extents-syms ct)
  "Returns a list of (stride-sym stride-form) bindings for the per-iteration
   strides, in dim-index order (s_0 .. s_{N-2}).  For N=1, returns NIL.

   For CT :last:  s_k = product(E_{k+1} .. E_{N-1})
   For CT :first: s_k = product(E_0     .. E_{k-1})  but iteration uses these
                  in reverse, so we build s_{N-1} .. s_1 instead.
   Returned bindings have the same indexing convention as %ts-build-decode-bindings."
  (let* ((cl-pkg  (find-package :crisp-language))
         (mul-sym (intern "*" cl-pkg))
         (n       (length extents-syms))
         (result  nil))
    (when (= n 1)
      (return-from %ts-build-stride-bindings nil))
    (case ct
      (:last
       ;; ordered-bindings[k] corresponds to dim k; needs s_k = E_{k+1} * .. * E_{N-1}
       (loop for k from 0 below (1- n)
             for sym = (gensym (format nil "S~A" k))
             for factors = (subseq extents-syms (1+ k))
             for form = (if (= (length factors) 1)
                            (first factors)
                            (reduce (lambda (a b) (list mul-sym a b)) factors))
             do (push (list sym form) result)))
      (:first
       ;; ordered-bindings is reversed; ordered-bindings[k] corresponds to dim N-1-k.
       ;; Needs s = E_0 * .. * E_{N-2-k} for k = 0 .. N-2.
       (loop for k from 0 below (1- n)
             for dim-idx = (- n 2 k)
             for sym = (gensym (format nil "S~A" k))
             for factors = (subseq extents-syms 0 (1+ dim-idx))
             for form = (if (= (length factors) 1)
                            (first factors)
                            (reduce (lambda (a b) (list mul-sym a b)) factors))
             do (push (list sym form) result))))
    (nreverse result)))

(defun %ts-canonicalize-tensor-type (raw-type)
  "Resolves RAW-TYPE down to the canonical 6-tuple (TENSOR elem N addr aln ct).
   Mirrors %083-require-2d-tensor's normalisation but is arity-agnostic.
   Returns the 6-tuple, or NIL when RAW-TYPE isn't a tensor."
  (let* ((resolved (resolve-type-alias raw-type))
         (resolved (if (and (listp resolved) (= (length resolved) 1) (listp (first resolved)))
                       (first resolved)
                       resolved))
         (canon (cond
                  ((and (listp resolved)
                        (symbolp (first resolved))
                        (string-equal (symbol-name (first resolved)) "TENSOR"))
                   resolved)
                  ((symbolp resolved)
                   (let ((u (unmangle-template-struct-name resolved)))
                     (if (and (listp u) (symbolp (first u))
                              (string-equal (symbol-name (first u)) "TENSOR"))
                         u nil)))
                  ((and (listp resolved)
                        (symbolp (first resolved))
                        (member (symbol-name (first resolved))
                                '("VECTOR" "MATRIX") :test #'string-equal))
                   (canonicalize-type-specifier resolved))
                  (t nil))))
    canon))

(defun %ts-layout-tag-to-ct (tag n location)
  "Maps a strict layout-tag to its effective contiguous-term (:last or :first).
   Validates the tag and (for :row-major / :col-major) the 2D restriction."
  (case tag
    (:row-major
     (unless (= n 2)
       (error 'crisp-compiler-error
              :message (format nil "tensor-stride :row-major requires a 2D tensor, got ~A bindings" n)
              :source-location location))
     :last)
    (:col-major
     (unless (= n 2)
       (error 'crisp-compiler-error
              :message (format nil "tensor-stride :col-major requires a 2D tensor, got ~A bindings" n)
              :source-location location))
     :first)
    (:contiguous-last  :last)
    (:contiguous-first :first)
    (otherwise
     (error 'crisp-compiler-error
            :message (format nil "tensor-stride: unknown layout-tag ~S (expected :row-major, :col-major, :contiguous-last, or :contiguous-first)" tag)
            :source-location location))))




(defun analyze-tensor-stride-expression (expr env context location)
  "Analyzes (tensor-stride T [LAYOUT-TAG] (BINDINGS...) BODY...).
   Delegates expansion to %expand-tensor-stride-form (shared with the AD
   pre-pass).  Env-based CT resolution: pre-analyzes the tensor form to
   read its static type."
  (let* ((tensor-form (second expr))
         (env-resolver
          (lambda (sym)
            (when (symbolp sym)
              (handler-case
                  (let ((node (analyze-expression sym env context (append location '(1)))))
                    (semantic-node-type node))
                (error () nil)))))
         (static-ct (%resolve-tensor-form-ct tensor-form env-resolver))
         ;; Strict variant validation reuses %tensor-stride-resolve-ct.  For the
         ;; safe variant fall back to %tensor-stride-resolve-ct's default chain.
         (ct (%tensor-stride-resolve-ct expr env-resolver location))
         ;; Bindings-arity vs declared-N check (env path only — pre-pass relies
         ;; on the type-resolver miss for non-symbol tensor forms).
         (strict-p (keywordp (third expr)))
         (bindings (if strict-p (fourth expr) (third expr)))
         (n (length bindings))
         (canon (and (symbolp tensor-form)
                     (let ((ty (funcall env-resolver tensor-form)))
                       (and ty (%ts-canonicalize-tensor-type ty)))))
         (declared-n (when (and (listp canon) (>= (length canon) 3))
                       (third canon))))
    (declare (ignore static-ct))
    (when (and (integerp declared-n) (/= declared-n n))
      (error 'crisp-compiler-error
             :message (format nil
                              "tensor-stride: tensor has ~A dimension(s) but ~A binding(s) provided"
                              declared-n n)
             :source-location location))
    (analyze-expression (%expand-tensor-stride-form expr ct location)
                        env context location)))

;; ==========================================================================
;; Phase C — grid-stride.  No tensor: a size-list and a bindings-list.
;; Total iteration = product of sizes.  Iteration is always row-major
;; (rightmost binding gets the warp).  Equivalent to safe tensor-stride
;; with CT=:last, but bypasses tensor introspection.
;;
;;   (grid-stride (<size-list>) (<bindings>) BODY...)


(defun analyze-grid-stride-expression (expr env context location)
  "Analyzes (grid-stride (SIZE-LIST) (BINDINGS) BODY...).  Delegates to
   %expand-grid-stride-form."
  (analyze-expression (%expand-grid-stride-form expr location)
                      env context location))



;; ============================================================================
;; Endeavor 109 — tile-stride (Pass 1: safe + size-list, no helpers yet).
;;
;; Per the chapter doc 14/11 implementation note, the iteration loop for
;; tile-stride is identical to tensor-stride.  The tile spec (size-list or
;; tile-tensor) is only consumed by the helper macros (tile-coords /
;; tile-indices / tensor-coords) which expand inside the body — those are
;; added in Pass 4.  For Pass 1, the analyzer parses the tile-spec for shape
;; validation, ignores it for codegen, and delegates the loop expansion
;; to %expand-tensor-stride-form.
;;
;; Form variants (parsing precedence):
;;   (tile-stride T (SIZE-LIST) (BINDINGS) BODY...)            ; safe + size-list
;;   (tile-stride T <tile-tensor> (BINDINGS) BODY...)          ; safe + tile-tensor (Pass 2)
;;   (tile-stride T :tag (SIZE-LIST) (BINDINGS) BODY...)       ; strict + size-list (Pass 3)
;;   (tile-stride T :tag <tile-tensor> (BINDINGS) BODY...)     ; strict + tile-tensor (Pass 3)

;; src/analysis/control.lisp
(defun %tile-stride-parse (expr)
  "Returns (values strict-p layout-tag tile-spec tile-spec-kind bindings body-forms tensor-form)
   for a tile-stride EXPR.  TILE-SPEC-KIND is one of :size-list or :tile-tensor.
   Form-shape validation only — does not check arity vs tensor."
  (let* ((tensor-form (second expr))
         (third       (third expr))
         (strict-p    (keywordp third))
         (layout-tag  (when strict-p third))
         (tile-pos    (if strict-p 3 2))
         (tile-spec   (nth tile-pos expr))
         (bind-pos    (1+ tile-pos))
         (bindings    (nth bind-pos expr))
         (body-forms  (nthcdr (1+ bind-pos) expr))
         (tile-spec-kind
          (cond
            ((and (listp tile-spec)
                  (>= (length tile-spec) 1)
                  (every #'integerp tile-spec))
             :size-list)
            ((or (symbolp tile-spec)
                 (and (consp tile-spec) (symbolp (car tile-spec))))
             :tile-tensor)
            (t
             (error 'crisp-compiler-error
                    :message (format nil "tile-stride: tile spec must be a size-list of integers or a tile-tensor reference, got ~S" tile-spec)
                    :source-location nil)))))
    (values strict-p layout-tag tile-spec tile-spec-kind bindings body-forms tensor-form)))





(defun %expand-hw-workgroup-idx-form (tensor-form bindings body-forms location)
  "Outer-loop expansion for hardware-stride :workgroup-idx.  Phase 1b:
   pre-walks the body to rewrite bare load-tile / store-tile into their
   -coords forms using the bindings as the origin."
  (let* ((n (length bindings))
         (cl-pkg (find-package :crisp-language))
         (get-local-size-sym (intern "GET-LOCAL-WORK-SIZE" cl-pkg))
         (ts-syms (loop for i from 0 below n
                        collect (gensym (format nil "LS~A" i))))
         (size-expr-fn (lambda (k) (list get-local-size-sym k)))
         ;; Phase 1b rewrite (before helper rewrite).
         (rewritten-body
          (%rewrite-bare-load-store-tile-in-body body-forms bindings cl-pkg)))
    (%expand-workgroup-strided-outer-loop-with-ts-syms
     tensor-form n bindings rewritten-body ts-syms size-expr-fn location)))




(defun %expand-hw-warp-idx-form (tensor-form bindings body-forms location)
  "Outer-loop expansion for hardware-stride :warp-idx.  Always 1D.
   Bare load-tile / store-tile inside :warp-idx remain a compile error.

   New shape: exact-iter-count + simple dotimes (no per-iter bounds check).
   Loop start  = mywarp * ws         (warp-uniform within a warp)
   Loop stride = ws * numwarps       (warp-uniform across the device)
   Loop var    = start + k * stride."
  (declare (ignore location))
  (dolist (f body-forms)
    (%detect-bare-load-store-tile-in-form f "hardware-stride :warp-idx"))
  (let* ((cl-pkg              (find-package :crisp-language))
         (let-sym             (intern "LET"                    cl-pkg))
         (declare-sym         (intern "DECLARE"                cl-pkg))
         (grid-level-sym      (intern "GRID-LEVEL"             cl-pkg))
         (dotimes-sym         (intern "DOTIMES"                cl-pkg))
         (progn-sym           (intern "PROGN"                  cl-pkg))
         (to-ulong-sym        (intern "TO-ULONG"               cl-pkg))
         (len-tilde-sym       (intern "LENGTH~"                cl-pkg))
         (get-glid-sym        (intern "GET-GLOBAL-LINEAR-ID"   cl-pkg))
         (get-glsize-sym      (intern "GET-GLOBAL-LINEAR-SIZE" cl-pkg))
         (plus-sym            (intern "+"                      cl-pkg))
         (mul-sym             (intern "*"                      cl-pkg))
         (div-sym             (intern "/"                      cl-pkg))
         (t-sym         (gensym "T"))
         (ws-sym        (gensym "WSIZE"))
         (len-sym       (gensym "LEN"))
         (glid-sym      (gensym "GLID"))
         (glsize-sym    (gensym "GLSIZE"))
         (mywarp-sym    (gensym "MYWARP"))
         (numwarps-sym  (gensym "NUMWARPS"))
         (start-sym     (gensym "WSTART"))
         (stride-sym    (gensym "WSTRIDE"))
         (iters-sym     (gensym "ITERS"))
         (k-sym         (gensym "K"))
         (var-name      (first bindings))
         (inner-body (if (= (length body-forms) 1)
                         (first body-forms)
                         (cons progn-sym body-forms)))
         (var-let (list let-sym
                        (list (list var-name
                                    (list plus-sym mywarp-sym
                                          (list mul-sym k-sym numwarps-sym))))
                        inner-body))
         (dotimes-form (list dotimes-sym
                             (list k-sym iters-sym)
                             var-let))
         (iters-let (list let-sym
                          (list (list iters-sym
                                      (%build-exact-iter-count-form
                                       start-sym stride-sym len-sym cl-pkg)))
                          dotimes-form))
         (outer-let (list let-sym
                          (list (list t-sym        tensor-form)
                                (list ws-sym       (list to-ulong-sym 32))
                                (list len-sym      (list len-tilde-sym t-sym))
                                (list glid-sym     (list get-glid-sym))
                                (list glsize-sym   (list get-glsize-sym))
                                (list mywarp-sym   (list div-sym glid-sym ws-sym))
                                (list numwarps-sym (list div-sym glsize-sym ws-sym))
                                (list start-sym    (list mul-sym mywarp-sym ws-sym))
                                (list stride-sym   (list mul-sym ws-sym numwarps-sym)))
                          (list declare-sym (list grid-level-sym))
                          iters-let)))
    outer-let))

(defun %expand-tile-stride-form (expr ct location)
  "Pure expansion of (tile-stride T [LAYOUT-TAG] <TILE-SPEC> (BINDINGS) BODY...).
   Outer loop over tile origins, workgroup-strided.  Phase 1b: pre-walks the
   body to rewrite bare load-tile / store-tile into their -coords forms using
   the tile-stride's binding syms as the origin."
  (declare (ignore ct))
  (multiple-value-bind (strict-p layout-tag tile-spec tile-spec-kind bindings body-forms tensor-form)
      (%tile-stride-parse expr)
    (declare (ignore strict-p layout-tag))
    (unless (and (listp bindings)
                 (every #'symbolp bindings)
                 (>= (length bindings) 1))
      (error 'crisp-compiler-error
             :message "Malformed tile-stride: expected (tile-stride TENSOR [LAYOUT-TAG] <TILE-SPEC> (BINDING ...) BODY...)"
             :source-location location))
    (let* ((n (length bindings))
           (cl-pkg (find-package :crisp-language))
           (to-ulong-sym      (intern "TO-ULONG" cl-pkg))
           (aref-sym          (intern "~" cl-pkg))
           (extents-tilde-sym (intern "EXTENTS~" cl-pkg))
           (ts-syms (loop for i from 0 below n
                          collect (gensym (format nil "TS~A" i))))
           (tile-size-expr-fn
            (ecase tile-spec-kind
              (:size-list
               (let ((sizes tile-spec))
                 (lambda (k) (list to-ulong-sym (nth k sizes)))))
              (:tile-tensor
               (let ((tile-form tile-spec))
                 (lambda (k)
                   (list aref-sym (list extents-tilde-sym tile-form) k))))))
           ;; Phase 1b: rewrite bare load-tile / store-tile in body BEFORE
           ;; helper rewrite (and before any expansion).  Tile-stride bindings
           ;; are the chunk origin coords, which become the -coords origin list.
           (rewritten-body
            (%rewrite-bare-load-store-tile-in-body body-forms bindings cl-pkg)))
      (%expand-workgroup-strided-outer-loop-with-ts-syms
       tensor-form n bindings rewritten-body ts-syms tile-size-expr-fn location))))

;; src/analysis/control.lisp
(defun analyze-tile-stride-expression (expr env context location)
  "Analyzes (tile-stride T [LAYOUT-TAG] <TILE-SPEC> (BINDINGS) BODY...).
   Validates tensor-arity-vs-bindings and tile-arity-vs-bindings, then
   delegates codegen via %expand-tile-stride-form."
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
      (analyze-expression (%expand-tile-stride-form expr ct location)
                          env context location))))


(defun %hardware-stride-parse (expr)
  "Returns (values strict-p layout-tag hw-tag bindings body-forms tensor-form)
   for a hardware-stride EXPR.  Form-shape validation only — does not check
   arity vs tensor."
  (let* ((tensor-form (second expr))
         (third       (third expr))
         (strict-p    (and (keywordp third)
                           (member third '(:row-major :col-major :contiguous-last :contiguous-first))))
         (layout-tag  (when strict-p third))
         (hw-tag-pos  (if strict-p 3 2))
         (hw-tag      (nth hw-tag-pos expr))
         (bind-pos    (1+ hw-tag-pos))
         (bindings    (nth bind-pos expr))
         (body-forms  (nthcdr (1+ bind-pos) expr)))
    (unless (member hw-tag '(:workgroup-idx :warp-idx))
      (error 'crisp-compiler-error
             :message (format nil "hardware-stride: unknown hw-tag ~S (expected :workgroup-idx or :warp-idx)" hw-tag)
             :source-location nil))
    (values strict-p layout-tag hw-tag bindings body-forms tensor-form)))

;; Custom expansion for :warp-idx.  Unlike :workgroup-idx (which can delegate
;; to tensor-stride because dim-0 iteration aligns with single-dim global-size),
;; :warp-idx must iterate linearly over the FLATTENED global execution space.
;; This matters when global-size has arity > 1 — tensor-stride's gid/gsize
;; would only see dim 0, missing the rest of the enqueue.
(defun %expand-warp-idx-form (tensor-form bindings body-forms location)
  "Linear-flatten expansion for hardware-stride :warp-idx.  Always 1 binding."
  (declare (ignore location))
  (let* ((var-name (first bindings))
         (gid-sym (gensym "GID"))
         (gsize-sym (gensym "GSIZE"))
         (len-sym (gensym "LEN"))
         (k-sym (gensym "K"))
         (cl-pkg (find-package :crisp-language))
         (let-sym (intern "LET" cl-pkg))
         (declare-sym (intern "DECLARE" cl-pkg))
         (grid-level-sym (intern "GRID-LEVEL" cl-pkg))
         (dotimes-sym (intern "DOTIMES" cl-pkg))
         (if-sym (intern "IF" cl-pkg))
         (progn-sym (intern "PROGN" cl-pkg))
         (get-glid-sym   (intern "GET-GLOBAL-LINEAR-ID"   cl-pkg))
         (get-glsize-sym (intern "GET-GLOBAL-LINEAR-SIZE" cl-pkg))
         (len-tilde-sym  (intern "LENGTH~" cl-pkg))
         (plus-sym (intern "+" cl-pkg))
         (lt-sym   (intern "<" cl-pkg))
         (inner-body (if (= (length body-forms) 1)
                         (first body-forms)
                         (cons progn-sym body-forms)))
         (inner-if  (list if-sym (list lt-sym var-name len-sym) inner-body))
         (inner-let (list let-sym
                          (list (list var-name (list plus-sym k-sym gid-sym)))
                          inner-if))
         (dotimes-form (list dotimes-sym
                             (list k-sym len-sym gsize-sym)
                             inner-let))
         (expansion (list let-sym
                          (list (list gid-sym   (list get-glid-sym))
                                (list gsize-sym (list get-glsize-sym))
                                (list len-sym   (list len-tilde-sym tensor-form)))
                          (list declare-sym (list grid-level-sym))
                          dotimes-form)))
    expansion))




(defun %rewrite-bare-tile-in-form (form origin-binding-syms cl-pkg)
  "Rewrites bare (load-tile ...) / (store-tile ...) inside FORM into their
   -coords equivalents using ORIGIN-BINDING-SYMS as the origin list.  Does
   NOT recurse into nested tile-stride / hardware-stride / workgroup-stride
   forms — those manage their own body rewrites.
   Endeavor 113 Phase 2: also handles bare (request-load-tile ...)."
  (cond
    ((atom form) form)
    ((not (and (consp form) (symbolp (car form))))
     (mapcar (lambda (sub) (%rewrite-bare-tile-in-form sub origin-binding-syms cl-pkg))
             form))
    (t
     (let ((op-name (symbol-name (car form))))
       (cond
         ((string-equal op-name "LOAD-TILE")
          (when (< (length form) 3)
            (error 'crisp-compiler-error
                   :message "load-tile: expected (load-tile SRC TILE [&key ...])"
                   :source-location nil))
          (let ((ltc-sym (intern "LOAD-TILE-COORDS" cl-pkg))
                (src     (second form))
                (tile    (third form))
                (key-args (nthcdr 3 form)))
            (append (list ltc-sym src tile origin-binding-syms) key-args)))
         ((string-equal op-name "STORE-TILE")
          (when (< (length form) 3)
            (error 'crisp-compiler-error
                   :message "store-tile: expected (store-tile TILE DEST [&key ...])"
                   :source-location nil))
          (let ((stc-sym (intern "STORE-TILE-COORDS" cl-pkg))
                (tile    (second form))
                (dest    (third form))
                (key-args (nthcdr 3 form)))
            (append (list stc-sym tile dest origin-binding-syms) key-args)))
         ;; --- Endeavor 113 Phase 2: bare request-load-tile sugar. ---
         ((string-equal op-name "REQUEST-LOAD-TILE")
          (when (< (length form) 3)
            (error 'crisp-compiler-error
                   :message "request-load-tile: expected (request-load-tile SRC TILE [&key ...])"
                   :source-location nil))
          (let ((rltc-sym (intern "REQUEST-LOAD-TILE-COORDS" cl-pkg))
                (src      (second form))
                (tile     (third form))
                (key-args (nthcdr 3 form)))
            (append (list rltc-sym src tile origin-binding-syms) key-args)))
         ;; --- Endeavor 113 Phase 3: bare request-store-tile sugar. ---
         ((string-equal op-name "REQUEST-STORE-TILE")
          (when (< (length form) 3)
            (error 'crisp-compiler-error
                   :message "request-store-tile: expected (request-store-tile TILE DEST [&key ...])"
                   :source-location nil))
          (let ((rstc-sym (intern "REQUEST-STORE-TILE-COORDS" cl-pkg))
                (tile     (second form))
                (dest     (third form))
                (key-args (nthcdr 3 form)))
            (append (list rstc-sym tile dest origin-binding-syms) key-args)))
         ((or (string-equal op-name "TILE-STRIDE")
              (string-equal op-name "HARDWARE-STRIDE")
              (string-equal op-name "WORKGROUP-STRIDE"))
          form)
         (t
          (cons (car form)
                (mapcar (lambda (sub)
                          (%rewrite-bare-tile-in-form sub origin-binding-syms cl-pkg))
                        (cdr form)))))))))


(defun %rewrite-bare-load-store-tile-in-body (body-forms origin-binding-syms cl-pkg)
  "Walks BODY-FORMS top-down and rewrites bare load-tile / store-tile to
   their -coords equivalents.  Used by tile-stride and hardware-stride
   :workgroup-idx body expansion."
  (mapcar (lambda (f) (%rewrite-bare-tile-in-form f origin-binding-syms cl-pkg))
          body-forms))




(defun %detect-bare-load-store-tile-in-form (form path)
  "Recursively walks FORM and signals a compile error if a bare (load-tile ...)
   or (store-tile ...) call appears.  PATH is the context name used in the
   error message (e.g. \"hardware-stride :warp-idx\").
   Endeavor 113 Phase 2: also detects bare (request-load-tile ...)."
  (cond
    ((atom form) nil)
    ((not (and (consp form) (symbolp (car form))))
     (dolist (sub form) (%detect-bare-load-store-tile-in-form sub path)))
    (t
     (let ((op-name (symbol-name (car form))))
       (cond
         ((or (string-equal op-name "LOAD-TILE")
              (string-equal op-name "STORE-TILE")
              (string-equal op-name "REQUEST-LOAD-TILE")
              (string-equal op-name "REQUEST-STORE-TILE"))
          (error 'crisp-compiler-error
                 :message (format nil
                                  "~A: bare ~A is not allowed inside ~A — it is a workgroup-cooperative primitive whose internal local-barrier would deadlock in a warp-grouped chunking context.  Use ~A-coords with explicit origin coords if you need to copy data here, or restructure the kernel."
                                  (string-downcase op-name)
                                  (string-downcase op-name)
                                  path
                                  (string-downcase op-name))
                 :source-location nil))
         ((or (string-equal op-name "TILE-STRIDE")
              (string-equal op-name "HARDWARE-STRIDE")
              (string-equal op-name "WORKGROUP-STRIDE"))
          nil)
         (t
          (dolist (sub (cdr form))
            (%detect-bare-load-store-tile-in-form sub path))))))))



;; ======================================================================
;; src/analysis/control.lisp — %expand-workgroup-strided-outer-loop-with-ts-syms
;;   (used by tile-stride and hardware-stride :workgroup-idx — Group B)
;; ======================================================================
;;
;; Old shape (per dim):
;;
;;   (dotimes (k_i E_i (* TS_i NG_i))     ; k_i = 0, TS_i*NG_i, 2*TS_i*NG_i, ...
;;     (let ((b_i (+ k_i (* GID_i TS_i))))
;;       (%uniform-when (< b_i E_i)
;;         <next-dim-or-body>)))
;;
;; Where:
;;   GID_i = get-workgroup-id i      (workgroup-uniform)
;;   NG_i  = get-num-groups i        (workgroup-uniform)
;;   TS_i  = tile size               (workgroup-uniform / compile-time)
;;   E_i   = extents[i]              (workgroup-uniform)
;;
;; The `%uniform-when` is workgroup-uniform (b_i is workgroup-uniform),
;; but it's NOT loop-invariant — b_i changes every iteration.  llc emits
;; it as a per-iter `setp + @p bra` inside the body, and opt -O3 can only
;; sometimes elide it.
;;
;; New shape (per dim): per-workgroup exact-iter-count over chunk origins.
;;
;;   START_i  = GID_i * TS_i              (this WG's chunk origin in dim i)
;;   STRIDE_i = TS_i * NG_i               (distance between chunk origins)
;;   ITERS_i  = (START_i >= E_i) ? 0
;;                               : 1 + (E_i - 1 - START_i) / STRIDE_i
;;   (dotimes (j_i ITERS_i)
;;     (let ((b_i (+ START_i (* j_i STRIDE_i))))
;;       <next-dim-or-body>))
;;
;; No %uniform-when needed.  Divergence checker is happy because there's
;; no conditional to check.

(defun %expand-workgroup-strided-outer-loop-with-ts-syms
    (tensor-form n bindings body-forms ts-syms tile-size-expr-fn location)
  "Workgroup-strided outer loop over chunk origins.  Per-workgroup exact
   iter count per dim — body runs unconditionally."
  (declare (ignore location))
  (let* ((cl-pkg              (find-package :crisp-language))
         (let-sym             (intern "LET"                cl-pkg))
         (declare-sym         (intern "DECLARE"            cl-pkg))
         (workgroup-level-sym (intern "WORKGROUP-LEVEL"    cl-pkg))
         (dotimes-sym         (intern "DOTIMES"            cl-pkg))
         (progn-sym           (intern "PROGN"              cl-pkg))
         (aref-sym            (intern "~"                  cl-pkg))
         (extents-tilde-sym   (intern "EXTENTS~"           cl-pkg))
         (get-wg-id-sym       (intern "GET-WORKGROUP-ID"   cl-pkg))
         (get-num-groups-sym  (intern "GET-NUM-GROUPS"     cl-pkg))
         (plus-sym            (intern "+"                  cl-pkg))
         (mul-sym             (intern "*"                  cl-pkg))
         (t-sym (gensym "T"))
         (e-syms      (loop for i from 0 below n collect (gensym (format nil "E~A"      i))))
         (gid-syms    (loop for i from 0 below n collect (gensym (format nil "WGID~A"   i))))
         (ng-syms     (loop for i from 0 below n collect (gensym (format nil "NG~A"     i))))
         (start-syms  (loop for i from 0 below n collect (gensym (format nil "START~A"  i))))
         (stride-syms (loop for i from 0 below n collect (gensym (format nil "STRIDE~A" i))))
         (iters-syms  (loop for i from 0 below n collect (gensym (format nil "ITERS~A"  i))))
         (k-syms      (loop for i from 0 below n collect (gensym (format nil "K~A"      i))))
         (inner-body (if (= (length body-forms) 1)
                         (first body-forms)
                         (cons progn-sym body-forms)))
         (nest
          (let ((acc inner-body))
            (loop for i from (1- n) downto 0
                  for b-sym      = (nth i bindings)
                  for start-sym  = (nth i start-syms)
                  for stride-sym = (nth i stride-syms)
                  for iters-sym  = (nth i iters-syms)
                  for k-sym      = (nth i k-syms)
                  do (setf acc
                           (list dotimes-sym
                                 (list k-sym iters-sym)
                                 (list let-sym
                                       (list (list b-sym
                                                   (list plus-sym start-sym
                                                         (list mul-sym k-sym stride-sym))))
                                       acc))))
            acc))
         (outer-bindings
          (append
           (list (list t-sym tensor-form))
           ;; ts_i  = tile size (from caller)
           (loop for i from 0 below n
                 for ts-sym in ts-syms
                 collect (list ts-sym (funcall tile-size-expr-fn i)))
           ;; e_i   = extents[i]
           (loop for i from 0 below n
                 for e-sym in e-syms
                 collect (list e-sym (list aref-sym (list extents-tilde-sym t-sym) i)))
           ;; gid_i = get-workgroup-id i
           (loop for i from 0 below n
                 for gid-sym in gid-syms
                 collect (list gid-sym (list get-wg-id-sym i)))
           ;; ng_i  = get-num-groups i
           (loop for i from 0 below n
                 for ng-sym in ng-syms
                 collect (list ng-sym (list get-num-groups-sym i)))
           ;; start_i  = gid_i * ts_i
           (loop for i from 0 below n
                 for start-sym in start-syms
                 for gid-sym   in gid-syms
                 for ts-sym    in ts-syms
                 collect (list start-sym (list mul-sym gid-sym ts-sym)))
           ;; stride_i = ts_i * ng_i
           (loop for i from 0 below n
                 for stride-sym in stride-syms
                 for ts-sym     in ts-syms
                 for ng-sym     in ng-syms
                 collect (list stride-sym (list mul-sym ts-sym ng-sym)))
           ;; iters_i  = exact count given start_i, stride_i, e_i
           (loop for i from 0 below n
                 for iters-sym in iters-syms
                 for start-sym in start-syms
                 for stride-sym in stride-syms
                 for e-sym     in e-syms
                 collect (list iters-sym
                               (%build-exact-iter-count-form
                                start-sym stride-sym e-sym cl-pkg))))))
    (list let-sym outer-bindings
          (list declare-sym (list workgroup-level-sym))
          nest)))


(defun %expand-hardware-stride-form (expr ct location)
  "Pure expansion of (hardware-stride T [LAYOUT-TAG] <HW-TAG> (BINDINGS) BODY...).

   :workgroup-idx — N-dim outer loop with chunk-size = (get-local-size k)
                    per dim.  Shares structure with tile-stride; body runs
                    once per workgroup per chunk.
   :warp-idx       — 1D outer loop with chunk-size = warp width (currently
                     hardcoded to 32 as a placeholder for (get-warp-size)).
                     Body runs once per warp per chunk.  Iteration is
                     warp-strided over the flattened global execution space."
  (declare (ignore ct))
  (multiple-value-bind (strict-p layout-tag hw-tag bindings body-forms tensor-form)
      (%hardware-stride-parse expr)
    (declare (ignore strict-p layout-tag))
    (unless (and (listp bindings) (every #'symbolp bindings) (>= (length bindings) 1))
      (error 'crisp-compiler-error
             :message "Malformed hardware-stride: expected (hardware-stride TENSOR [LAYOUT-TAG] <HW-TAG> (BINDING ...) BODY...)"
             :source-location location))
    (when (and (eq hw-tag :warp-idx) (/= (length bindings) 1))
      (error 'crisp-compiler-error
             :message "hardware-stride :warp-idx must have exactly 1 binding — warp iteration is always linear over the flattened global execution space"
             :source-location location))
    (ecase hw-tag
      (:workgroup-idx
       (%expand-hw-workgroup-idx-form tensor-form bindings body-forms location))
      (:warp-idx
       (%expand-hw-warp-idx-form tensor-form bindings body-forms location)))))

(defun analyze-hardware-stride-expression (expr env context location)
  "Analyzes (hardware-stride T [LAYOUT-TAG] <HW-TAG> (BINDINGS) BODY...).
   Validates arity (:warp-idx must be 1 binding, :workgroup-idx must match
   tensor arity) and delegates codegen via %expand-hardware-stride-form."
  (multiple-value-bind (strict-p layout-tag hw-tag bindings body-forms tensor-form)
      (%hardware-stride-parse expr)
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
      (when (and (eq hw-tag :warp-idx) (/= n 1))
        (error 'crisp-compiler-error
               :message "hardware-stride :warp-idx must have exactly 1 binding — warp iteration is always linear over the flattened global execution space"
               :source-location location))
      (when (and (eq hw-tag :workgroup-idx)
                 (integerp declared-n) (/= declared-n n))
        (error 'crisp-compiler-error
               :message (format nil
                                "hardware-stride :workgroup-idx: tensor has ~A dimension(s) but ~A binding(s) provided"
                                declared-n n)
               :source-location location))
      (analyze-expression (%expand-hardware-stride-form expr ct location)
                          env context location))))



;; Endeavor 110: workgroup-stride
;;
;; Cooperative inner loop for a workgroup to walk a tile's coordinates.
;; The body executes once per (thread × visit), with each binding bound to
;; the local coord within the tile's dim.  Threads step by local-work-size
;; per dim, starting at their local-id, until the dim's extent is reached.
;;
;; Scenarios handled by the bounds check:
;;   A. tile > workgroup: each thread iterates multiple times.
;;   B. tile < workgroup: threads with local-id beyond extent skip.
;;
;; Does NOT inject an end barrier (per chapter 13).  Caller inserts
;; (local-barrier) explicitly when needed.

(defun %workgroup-stride-parse (expr)
  "Returns (values bindings body-forms tensor-form) for a workgroup-stride EXPR.
   Form-shape validation only — does not check tensor arity vs bindings arity."
  (let* ((tensor-form (second expr))
         (bindings    (third expr))
         (body-forms  (cdddr expr)))
    (values bindings body-forms tensor-form)))


;; ======================================================================
;; src/analysis/control.lisp — %expand-workgroup-stride-form (Group C)
;; ======================================================================
;;
;; Cooperative inner loop for a workgroup to walk a tile's coordinates.
;; Per dim, each thread strides by LWS_i starting at LID_i.
;;
;; Old shape (per dim):
;;
;;   (dotimes (k_i E_i LWS_i)            ; k_i = 0, LWS_i, 2*LWS_i, ...
;;     (let ((b_i (+ k_i LID_i)))
;;       (when (< b_i E_i)
;;         <inner-or-next-dim>)))
;;
;; Two scenarios the old `when` guards:
;;   A. tile > workgroup → some threads iterate multiple times; the tail
;;      iteration may go past extent for some threads.
;;   B. tile < workgroup → threads with LID_i ≥ E_i never enter the body.
;;
;; The `when (< b_i E_i)` is THREAD-DIVERGENT (different threads, different
;; LID_i) — the SCEV unroller can't remove it.
;;
;; New shape (per dim): exact per-thread iter count, no inner guard.
;;
;;   ITERS_i = (LID_i >= E_i) ? 0
;;                            : 1 + (E_i - 1 - LID_i) / LWS_i
;;   (dotimes (j_i ITERS_i)
;;     (let ((b_i (+ LID_i (* j_i LWS_i))))
;;       <inner-or-next-dim>))
;;
;; All ITERS_i bindings sit at the outer LET so the nest stays flat.
;; Threads in scenario B compute ITERS_i = 0 and skip the dim entirely.
;; In both scenarios the body is unconditional — no per-iter compare.
;;
;; Does NOT inject an end barrier (per chapter 13).  Caller inserts
;; (local-barrier) explicitly when needed.

(defun %expand-workgroup-stride-form (expr location)
  "Pure expansion of (workgroup-stride T (BINDINGS) BODY...).  N-dim nested
   per-thread cooperative loop.  Each dim's iter count is computed up
   front (per thread) so the inner dotimes is a single-counter, body-
   unconditional loop the unroller can attack."
  (multiple-value-bind (bindings body-forms tensor-form)
      (%workgroup-stride-parse expr)
    (unless (and (listp bindings)
                 (every #'symbolp bindings)
                 (>= (length bindings) 1))
      (error 'crisp-compiler-error
             :message "Malformed workgroup-stride: expected (workgroup-stride TENSOR (BINDING ...) BODY...)"
             :source-location location))
    (let* ((n (length bindings))
           (cl-pkg              (find-package :crisp-language))
           (let-sym             (intern "LET"                 cl-pkg))
           (dotimes-sym         (intern "DOTIMES"             cl-pkg))
           (progn-sym           (intern "PROGN"               cl-pkg))
           (aref-sym            (intern "~"                   cl-pkg))
           (extents-tilde-sym   (intern "EXTENTS~"            cl-pkg))
           (get-local-id-sym    (intern "GET-LOCAL-ID"        cl-pkg))
           (get-lws-sym         (intern "GET-LOCAL-WORK-SIZE" cl-pkg))
           (plus-sym            (intern "+"                   cl-pkg))
           (mul-sym             (intern "*"                   cl-pkg))
           (t-sym (gensym "T"))
           (e-syms     (loop for i from 0 below n collect (gensym (format nil "E~A"     i))))
           (lid-syms   (loop for i from 0 below n collect (gensym (format nil "LID~A"   i))))
           (lws-syms   (loop for i from 0 below n collect (gensym (format nil "LWS~A"   i))))
           (iters-syms (loop for i from 0 below n collect (gensym (format nil "ITERS~A" i))))
           (k-syms     (loop for i from 0 below n collect (gensym (format nil "K~A"     i))))
           (inner-body (if (= (length body-forms) 1)
                           (first body-forms)
                           (cons progn-sym body-forms)))
           ;; Build the nest from innermost out.  At each level:
           ;;   (dotimes (K_i ITERS_i)
           ;;     (let ((b_i (+ LID_i (* K_i LWS_i))))
           ;;       <inner-or-next-dim>))
           (nest
            (let ((acc inner-body))
              (loop for i from (1- n) downto 0
                    for b-sym     = (nth i bindings)
                    for lid-sym   = (nth i lid-syms)
                    for lws-sym   = (nth i lws-syms)
                    for k-sym     = (nth i k-syms)
                    for iters-sym = (nth i iters-syms)
                    do (setf acc
                             (list dotimes-sym
                                   (list k-sym iters-sym)
                                   (list let-sym
                                         (list (list b-sym
                                                     (list plus-sym lid-sym
                                                           (list mul-sym k-sym lws-sym))))
                                         acc))))
              acc))
           (outer-bindings
            (append
             (list (list t-sym tensor-form))
             (loop for i from 0 below n
                   for e-sym in e-syms
                   collect (list e-sym (list aref-sym (list extents-tilde-sym t-sym) i)))
             (loop for i from 0 below n
                   for lid-sym in lid-syms
                   collect (list lid-sym (list get-local-id-sym i)))
             (loop for i from 0 below n
                   for lws-sym in lws-syms
                   collect (list lws-sym (list get-lws-sym i)))
             ;; Per-dim exact-iter-count, one per thread.
             (loop for i from 0 below n
                   for iters-sym in iters-syms
                   for lid-sym   in lid-syms
                   for lws-sym   in lws-syms
                   for e-sym     in e-syms
                   collect (list iters-sym
                                 (%build-exact-iter-count-form
                                  lid-sym lws-sym e-sym cl-pkg))))))
      (list let-sym outer-bindings nest))))


(defun analyze-workgroup-stride-expression (expr env context location)
  "Analyzes (workgroup-stride T (BINDINGS) BODY...).  Validates arity-vs-tensor
   then delegates codegen via %expand-workgroup-stride-form."
  (multiple-value-bind (bindings body-forms tensor-form)
      (%workgroup-stride-parse expr)
    (declare (ignore body-forms))
    (let* ((env-resolver
            (lambda (sym)
              (when (symbolp sym)
                (handler-case
                    (let ((node (analyze-expression sym env context (append location '(1)))))
                      (semantic-node-type node))
                  (error () nil)))))
           (n (length bindings))
           (canon (and (symbolp tensor-form)
                       (let ((ty (funcall env-resolver tensor-form)))
                         (and ty (%ts-canonicalize-tensor-type ty)))))
           (declared-n (when (and (listp canon) (>= (length canon) 3))
                         (third canon))))
      (when (and (integerp declared-n) (/= declared-n n))
        (error 'crisp-compiler-error
               :message (format nil
                                "workgroup-stride: tensor has ~A dimension(s) but ~A binding(s) provided"
                                declared-n n)
               :source-location location))
      (analyze-expression (%expand-workgroup-stride-form expr location)
                          env context location))))




(defun analyze-load-tile-expression (expr env context location)
  "Bare (load-tile SRC TILE &key ...) outside a stride context — compile
   error pointing the user to load-tile-coords."
  (declare (ignore expr env context))
  (error 'crisp-compiler-error
         :message "load-tile is only valid inside a tile-stride or hardware-stride :workgroup-idx body, where its origin coords are inferred from the surrounding stride bindings.  Use (load-tile-coords SRC TILE (ORIGIN...) ...) for explicit coordinate forms."
         :source-location location))


(defun analyze-store-tile-expression (expr env context location)
  "Bare (store-tile TILE DEST &key ...) outside a stride context — compile
   error pointing the user to store-tile-coords."
  (declare (ignore expr env context))
  (error 'crisp-compiler-error
         :message "store-tile is only valid inside a tile-stride or hardware-stride :workgroup-idx body, where its origin coords are inferred from the surrounding stride bindings.  Use (store-tile-coords TILE DEST (ORIGIN...) ...) for explicit coordinate forms."
         :source-location location))


(defun %expand-load-tile-coords-bwd-form (expr location)
  "Pure expansion of (%load-tile-coords-bwd SRC-ADJ TILE-ADJ (ORIGIN...) &key transpose).
   Cooperative scatter-add via atomic-add!."
  (let* ((src-adj-form  (second expr))
         (tile-adj-form (third expr))
         (origin-list   (fourth expr))
         (key-args      (nthcdr 4 expr)))
    (unless (and (listp origin-list) (>= (length origin-list) 1))
      (error 'crisp-compiler-error
             :message "%load-tile-coords-bwd: origin must be a non-empty list of coord forms"
             :source-location location))
    (let* ((transpose-form (%extract-key-arg key-args :transpose nil))
           (n              (length origin-list))
           (perm           (%tlc-transpose-permutation n transpose-form location))
           (cl-pkg         (find-package :crisp-language))
           (let-sym             (intern "LET" cl-pkg))
           (progn-sym           (intern "PROGN" cl-pkg))
           (when-sym            (intern "WHEN" cl-pkg))
           (aref-sym            (intern "~" cl-pkg))
           (extents-tilde-sym   (intern "EXTENTS~" cl-pkg))
           (get-local-id-sym    (intern "GET-LOCAL-ID" cl-pkg))
           (get-lws-sym         (intern "GET-LOCAL-WORK-SIZE" cl-pkg))
           (local-barrier-sym   (intern "LOCAL-BARRIER" cl-pkg))
           (to-ulong-sym        (intern "TO-ULONG" cl-pkg))
           (plus-sym            (intern "+" cl-pkg))
           (lt-sym              (intern "<" cl-pkg))
           (and-sym             (intern "AND" cl-pkg))
           (atomic-add-sym      (intern "ATOMIC-ADD!" cl-pkg))
           (src-adj-sym  (gensym "SRC-ADJ"))
           (tile-adj-sym (gensym "TILE-ADJ"))
           (origin-syms       (loop for i from 0 below n collect (gensym (format nil "ORIG~A" i))))
           (tile-coord-syms   (loop for i from 0 below n collect (gensym (format nil "TLC~A" i))))
           (tile-extent-syms  (loop for i from 0 below n collect (gensym (format nil "TE~A" i))))
           (global-extent-syms (loop for i from 0 below n collect (gensym (format nil "GE~A" i))))
           (lid-syms          (loop for i from 0 below n collect (gensym (format nil "LID~A" i))))
           (lws-syms          (loop for i from 0 below n collect (gensym (format nil "LWS~A" i))))
           (src-coord-exprs   (%tlc-source-coord-exprs n origin-syms tile-coord-syms perm plus-sym))
           (tile-aref         (cons aref-sym (cons tile-adj-sym tile-coord-syms)))
           (src-aref          (cons aref-sym (cons src-adj-sym src-coord-exprs)))
           (bounds-form       (%tlc-all-in-bounds-form n src-coord-exprs
                                                       global-extent-syms lt-sym and-sym))
           ;; Inner body: scatter-add tile_adj[lc] into src_adj[orig+lc] via atomic-add!.
           ;; Skip silently when out of bounds (no contribution).
           (inner-body        (list when-sym
                                    bounds-form
                                    (list atomic-add-sym src-aref tile-aref)))
           (loop-nest (%tlc-coop-loop-skeleton n tile-adj-sym nil tile-coord-syms
                                               tile-extent-syms lid-syms lws-syms
                                               inner-body cl-pkg))
           (outer-bindings
            (append
             (list (list src-adj-sym src-adj-form)
                   (list tile-adj-sym tile-adj-form))
             (loop for i from 0 below n
                   for o-sym in origin-syms
                   collect (list o-sym (list to-ulong-sym (nth i origin-list))))
             (loop for i from 0 below n
                   for te-sym in tile-extent-syms
                   collect (list te-sym (list aref-sym (list extents-tilde-sym tile-adj-sym) i)))
             (loop for i from 0 below n
                   for ge-sym in global-extent-syms
                   collect (list ge-sym (list aref-sym (list extents-tilde-sym src-adj-sym) i)))
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


(defun %expand-store-tile-coords-bwd-form (expr location)
  "Pure expansion of (%store-tile-coords-bwd TILE-ADJ DEST-ADJ (ORIGIN...) &key transpose).
   Cooperative non-atomic accumulate into local tile_adj.  Barriers before
   and after so prior tile_adj writes are visible and subsequent ones see
   the result."
  (let* ((tile-adj-form (second expr))
         (dest-adj-form (third expr))
         (origin-list   (fourth expr))
         (key-args      (nthcdr 4 expr)))
    (unless (and (listp origin-list) (>= (length origin-list) 1))
      (error 'crisp-compiler-error
             :message "%store-tile-coords-bwd: origin must be a non-empty list of coord forms"
             :source-location location))
    (let* ((transpose-form (%extract-key-arg key-args :transpose nil))
           (n              (length origin-list))
           (perm           (%tlc-transpose-permutation n transpose-form location))
           (cl-pkg         (find-package :crisp-language))
           (let-sym             (intern "LET" cl-pkg))
           (progn-sym           (intern "PROGN" cl-pkg))
           (when-sym            (intern "WHEN" cl-pkg))
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
           (tile-adj-sym (gensym "TILE-ADJ"))
           (dest-adj-sym (gensym "DEST-ADJ"))
           (origin-syms       (loop for i from 0 below n collect (gensym (format nil "ORIG~A" i))))
           (tile-coord-syms   (loop for i from 0 below n collect (gensym (format nil "TLC~A" i))))
           (tile-extent-syms  (loop for i from 0 below n collect (gensym (format nil "TE~A" i))))
           (global-extent-syms (loop for i from 0 below n collect (gensym (format nil "GE~A" i))))
           (lid-syms          (loop for i from 0 below n collect (gensym (format nil "LID~A" i))))
           (lws-syms          (loop for i from 0 below n collect (gensym (format nil "LWS~A" i))))
           (dest-coord-exprs  (%tlc-source-coord-exprs n origin-syms tile-coord-syms perm plus-sym))
           (tile-aref         (cons aref-sym (cons tile-adj-sym tile-coord-syms)))
           (dest-aref         (cons aref-sym (cons dest-adj-sym dest-coord-exprs)))
           (bounds-form       (%tlc-all-in-bounds-form n dest-coord-exprs
                                                       global-extent-syms lt-sym and-sym))
           ;; tile_adj[lc] += dest_adj[orig+lc].  No atomic — each tile slot
           ;; is written by exactly one thread in the workgroup-cooperative loop.
           (acc-form          (list plus-sym tile-aref dest-aref))
           (inner-body        (list when-sym
                                    bounds-form
                                    (list set-sym tile-aref acc-form)))
           (loop-nest (%tlc-coop-loop-skeleton n tile-adj-sym nil tile-coord-syms
                                               tile-extent-syms lid-syms lws-syms
                                               inner-body cl-pkg))
           (outer-bindings
            (append
             (list (list tile-adj-sym tile-adj-form)
                   (list dest-adj-sym dest-adj-form))
             (loop for i from 0 below n
                   for o-sym in origin-syms
                   collect (list o-sym (list to-ulong-sym (nth i origin-list))))
             (loop for i from 0 below n
                   for te-sym in tile-extent-syms
                   collect (list te-sym (list aref-sym (list extents-tilde-sym tile-adj-sym) i)))
             (loop for i from 0 below n
                   for ge-sym in global-extent-syms
                   collect (list ge-sym (list aref-sym (list extents-tilde-sym dest-adj-sym) i)))
             (loop for i from 0 below n
                   for lid-sym in lid-syms
                   collect (list lid-sym (list get-local-id-sym i)))
             (loop for i from 0 below n
                   for lws-sym in lws-syms
                   collect (list lws-sym (list get-lws-sym i))))))
      (list let-sym outer-bindings
            (list progn-sym
                  (list local-barrier-sym)
                  loop-nest
                  (list local-barrier-sym))))))


(defun analyze-%load-tile-coords-bwd-expression (expr env context location)
  "Analyzer for compiler-internal %load-tile-coords-bwd."
  (analyze-expression (%expand-load-tile-coords-bwd-form expr location)
                      env context location))


(defun analyze-%store-tile-coords-bwd-expression (expr env context location)
  "Analyzer for compiler-internal %store-tile-coords-bwd."
  (analyze-expression (%expand-store-tile-coords-bwd-form expr location)
                      env context location))

  
  


(defun %expand-request-load-tile-coords-form (expr location)
  "Phase 1a: degrade-to-sync.  Expand to (PROGN <sync-load-tile-coords> 0)
   so the result has a ulong-typed phantom token for the surrounding let."
  (let* ((cl-pkg     (find-package :crisp-language))
         (progn-sym  (intern "PROGN" cl-pkg))
         (to-ulong   (intern "TO-ULONG" cl-pkg))
         (sync-sym   (intern "LOAD-TILE-COORDS" cl-pkg))
         (sync-expr  (cons sync-sym (rest expr)))
         (sync-form  (%expand-load-tile-coords-form sync-expr location)))
    (list progn-sym sync-form (list to-ulong 0))))

;; Phase 3: symmetric fallback for the store side.

(defun %expand-request-store-tile-coords-form (expr location)
  "Phase 3 fallback: degrade-to-sync.  Expand to
   (PROGN <sync-store-tile-coords> 0) — same phantom-token shape as the
   load side.  Real async store (where hardware supports it) lands in
   114 Phase E."
  (let* ((cl-pkg     (find-package :crisp-language))
         (progn-sym  (intern "PROGN" cl-pkg))
         (to-ulong   (intern "TO-ULONG" cl-pkg))
         (sync-sym   (intern "STORE-TILE-COORDS" cl-pkg))
         (sync-expr  (cons sync-sym (rest expr)))
         (sync-form  (%expand-store-tile-coords-form sync-expr location)))
    (list progn-sym sync-form (list to-ulong 0))))


(defun analyze-request-load-tile-coords-expression (expr env context location)
  "114 Phase B: emit semantic-nvvm-cp-async-tile-copy on :ptx target;
   fall back to sync expansion elsewhere (including :spirv, which is
   blocked — see 114 Phase A notes)."
  (%tlc-check-not-divergent "request-load-tile-coords" location)
  (case *target-backend*
    (:ptx
     (let* ((src-form    (second expr))
            (tile-form   (third expr))
            (origin-list (fourth expr))
            (src-node    (analyze-expression src-form env context (append location '(1))))
            (tile-node   (analyze-expression tile-form env context (append location '(2))))
            (origin-nodes (loop for o in origin-list for i from 0
                                collect (analyze-expression
                                         o env context
                                         (append location (list 3 i))))))
       (make-semantic-nvvm-cp-async-tile-copy
        :src-node     src-node
        :tile-node    tile-node
        :origin-nodes origin-nodes
        :type         'ulong
        :source-location location)))
    (t
     (analyze-expression (%expand-request-load-tile-coords-form expr location)
                         env context location))))

(defun analyze-request-store-tile-coords-expression (expr env context location)
  "Phase 3 analyzer for request-store-tile-coords.  Same divergence guard
   as the sync form, then delegates to the fallback expansion."
  (%tlc-check-not-divergent "request-store-tile-coords" location)
  (analyze-expression (%expand-request-store-tile-coords-form expr location)
                      env context location))



(defun analyze-await-request-expression (expr env context location)
  "114 Phase B: emit semantic-nvvm-cp-async-wait on :ptx; no-op fallback elsewhere."
  (unless (= (length expr) 2)
    (error 'crisp-compiler-error
           :message (format nil "await-request: expected (await-request TOKEN), got ~S" expr)
           :source-location location))
  (case *target-backend*
    (:ptx
     (make-semantic-nvvm-cp-async-wait
      :type 'ulong
      :source-location location))
    (t
     (analyze-expression
      (list (intern "TO-ULONG" (find-package :crisp-language)) 0)
      env context location))))


(defun register-control-analyzers ()
  "Registers all control flow expression analyzers, including loop-vector-stride,
   tensor-stride, grid-stride, tile-stride, hardware-stride, workgroup-stride,
   and (111 Phase 1a) load-tile-coords / store-tile-coords.
   Endeavor 113: also registers request-load-tile-coords and await-request."
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
  (register-warp-builtins)
  (let ((sym-cl (intern "LOAD-TILE-COORDS" (find-package :crisp-language)))
        (sym-cc (intern "LOAD-TILE-COORDS" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-load-tile-coords-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-load-tile-coords-expression)))
  (let ((sym-cl (intern "STORE-TILE-COORDS" (find-package :crisp-language)))
        (sym-cc (intern "STORE-TILE-COORDS" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-store-tile-coords-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-store-tile-coords-expression)))
  (let ((sym-cl (intern "LOAD-TILE" (find-package :crisp-language)))
        (sym-cc (intern "LOAD-TILE" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-load-tile-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-load-tile-expression)))
  (let ((sym-cl (intern "STORE-TILE" (find-package :crisp-language)))
        (sym-cc (intern "STORE-TILE" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-store-tile-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-store-tile-expression)))
  (let ((sym-cl (intern "%UNIFORM-WHEN" (find-package :crisp-language)))
        (sym-cc (intern "%UNIFORM-WHEN" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-%uniform-when-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-%uniform-when-expression)))
  (let ((sym-cl (intern "%LOAD-TILE-COORDS-BWD" (find-package :crisp-language)))
        (sym-cc (intern "%LOAD-TILE-COORDS-BWD" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-%load-tile-coords-bwd-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-%load-tile-coords-bwd-expression)))
  (let ((sym-cl (intern "%STORE-TILE-COORDS-BWD" (find-package :crisp-language)))
        (sym-cc (intern "%STORE-TILE-COORDS-BWD" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-%store-tile-coords-bwd-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-%store-tile-coords-bwd-expression)))
  ;; --- Endeavor 113 Phase 1a: async tile load + await. ---
  (let ((sym-cl (intern "REQUEST-LOAD-TILE-COORDS" (find-package :crisp-language)))
        (sym-cc (intern "REQUEST-LOAD-TILE-COORDS" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-request-load-tile-coords-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-request-load-tile-coords-expression)))
  ;; --- Endeavor 113 Phase 3: async tile store. ---
  (let ((sym-cl (intern "REQUEST-STORE-TILE-COORDS" (find-package :crisp-language)))
        (sym-cc (intern "REQUEST-STORE-TILE-COORDS" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-request-store-tile-coords-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-request-store-tile-coords-expression)))
  (let ((sym-cl (intern "AWAIT-REQUEST" (find-package :crisp-language)))
        (sym-cc (intern "AWAIT-REQUEST" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-await-request-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-await-request-expression))))

