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


;; src/analysis/control.lisp
;;
;; Endeavor 111 Phase 1d — convergence checker.
;;
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


;; src/analysis/control.lisp
;;
;; %uniform-when / %uniform-if — internal forms used by the stride-macro
;; expansions whose bounds-check conditions are workgroup-uniform (every
;; thread in the workgroup evaluates the same value, so every thread takes
;; the same branch).  They have the same semantics as when/if but do NOT
;; set *in-divergent-conditional* on the analyzed branches, so load-tile-
;; coords / store-tile-coords inside them remain legal.
;;
;; If a user wrote `when` instead, the analyzer would conservatively assume
;; the condition could be thread-divergent and reject the inner load/store.

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


;; src/analysis/control.lisp
;;
;; Whole-function replacement of analyze-if-expression-impl, adding the
;; *in-divergent-conditional* binding around the two-branch analysis path.
;; When the condition is constant-folded to a literal, only one branch is
;; analyzed and no runtime divergence is introduced — no flag set in that
;; path.  When both branches must be analyzed (runtime if), wrap both in a
;; binding of *in-divergent-conditional* to T.
;;
;; When/unless/cond all delegate to this impl, so they're covered.  if+ uses
;; the same impl with enforce-constant=t, which always either constant-folds
;; or errors before reaching the two-branch path — also safe.
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


;; src/analysis/control.lisp
;;
;; Endeavor 111 Phase 1b — bare load-tile / store-tile sugar.
;;
;; (load-tile  <src-global> <dest-tile> &key (identity 0) transpose)
;; (store-tile <src-tile> <dest-global> &key transformF transpose)
;;
;; Inside a tile-stride or hardware-stride :workgroup-idx body, these get
;; rewritten by the body walker into their -coords equivalents, with the
;; surrounding stride's binding syms injected as the origin coord list:
;;
;;   (tile-stride T (4) (orig)
;;     (load-tile T tile))
;;     ↓
;;   (tile-stride T (4) (orig)
;;     (load-tile-coords T tile (orig)))
;;
;; Inside hardware-stride :warp-idx, bare load-tile / store-tile is a
;; compile error (workgroup-cooperative primitive in warp-grouped context
;; would deadlock at the barrier).  Outside any stride context, also a
;; compile error pointing the user to load-tile-coords / store-tile-coords.

(defun %rewrite-bare-tile-in-form (form origin-binding-syms cl-pkg)
  "Rewrites bare (load-tile ...) / (store-tile ...) inside FORM into their
   -coords equivalents using ORIGIN-BINDING-SYMS as the origin list.  Does
   NOT recurse into nested tile-stride / hardware-stride / workgroup-stride
   forms — those manage their own body rewrites."
  (cond
    ((atom form) form)
    ((not (and (consp form) (symbolp (car form))))
     (mapcar (lambda (sub) (%rewrite-bare-tile-in-form sub origin-binding-syms cl-pkg))
             form))
    (t
     (let ((op-name (symbol-name (car form))))
       (cond
         ((string-equal op-name "LOAD-TILE")
          ;; (load-tile SRC TILE &key ...) → (load-tile-coords SRC TILE (ORIGIN-SYMS) &key ...)
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
          ;; (store-tile TILE DEST &key ...) → (store-tile-coords TILE DEST (ORIGIN-SYMS) &key ...)
          (when (< (length form) 3)
            (error 'crisp-compiler-error
                   :message "store-tile: expected (store-tile TILE DEST [&key ...])"
                   :source-location nil))
          (let ((stc-sym (intern "STORE-TILE-COORDS" cl-pkg))
                (tile    (second form))
                (dest    (third form))
                (key-args (nthcdr 3 form)))
            (append (list stc-sym tile dest origin-binding-syms) key-args)))
         ((or (string-equal op-name "TILE-STRIDE")
              (string-equal op-name "HARDWARE-STRIDE")
              (string-equal op-name "WORKGROUP-STRIDE"))
          ;; Nested stride contexts manage their own body rewriting.
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
   error message (e.g. \"hardware-stride :warp-idx\")."
  (cond
    ((atom form) nil)
    ((not (and (consp form) (symbolp (car form))))
     (dolist (sub form) (%detect-bare-load-store-tile-in-form sub path)))
    (t
     (let ((op-name (symbol-name (car form))))
       (cond
         ((or (string-equal op-name "LOAD-TILE")
              (string-equal op-name "STORE-TILE"))
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
          ;; Nested stride: stop recursing; that context will handle its own body.
          nil)
         (t
          (dolist (sub (cdr form))
            (%detect-bare-load-store-tile-in-form sub path))))))))


;; src/analysis/control.lisp
;;
;; Whole-function replacement of %expand-workgroup-strided-outer-loop-with-ts-syms,
;; using %uniform-when (workgroup-uniform bounds check) instead of regular
;; when.  The per-dim bounds test (< b-sym e-sym) where b-sym is the chunk
;; origin and e-sym is the tensor extent is workgroup-uniform: every thread
;; in the workgroup sees the same b-sym and e-sym values, so they all take
;; the same branch.  Using %uniform-when avoids tripping the Phase 1d
;; divergence check for legitimate nested load-tile-coords / store-tile-coords.
(defun %expand-workgroup-strided-outer-loop-with-ts-syms
    (tensor-form n bindings body-forms ts-syms tile-size-expr-fn location)
  "Workgroup-strided outer loop, with the per-dim bounds check routed
   through %uniform-when so it doesn't trip the divergence checker."
  (declare (ignore location))
  (let* ((cl-pkg (find-package :crisp-language))
         (let-sym             (intern "LET" cl-pkg))
         (declare-sym         (intern "DECLARE" cl-pkg))
         (workgroup-level-sym (intern "WORKGROUP-LEVEL" cl-pkg))
         (dotimes-sym         (intern "DOTIMES" cl-pkg))
         ;; Phase 1d: workgroup-uniform bounds check uses %uniform-when.
         (uniform-when-sym    (intern "%UNIFORM-WHEN" cl-pkg))
         (progn-sym           (intern "PROGN" cl-pkg))
         (aref-sym            (intern "~" cl-pkg))
         (extents-tilde-sym   (intern "EXTENTS~" cl-pkg))
         (get-wg-id-sym       (intern "GET-WORKGROUP-ID" cl-pkg))
         (get-num-groups-sym  (intern "GET-NUM-GROUPS" cl-pkg))
         (plus-sym            (intern "+" cl-pkg))
         (mul-sym             (intern "*" cl-pkg))
         (lt-sym              (intern "<" cl-pkg))
         (t-sym (gensym "T"))
         (e-syms   (loop for i from 0 below n collect (gensym (format nil "E~A"    i))))
         (gid-syms (loop for i from 0 below n collect (gensym (format nil "WGID~A" i))))
         (ng-syms  (loop for i from 0 below n collect (gensym (format nil "NG~A"   i))))
         (k-syms   (loop for i from 0 below n collect (gensym (format nil "K~A"    i))))
         (inner-body (if (= (length body-forms) 1)
                         (first body-forms)
                         (cons progn-sym body-forms)))
         (nest
          (let ((acc inner-body))
            (loop for i from (1- n) downto 0
                  for b-sym  = (nth i bindings)
                  for ts-sym = (nth i ts-syms)
                  for e-sym  = (nth i e-syms)
                  for gid-sym = (nth i gid-syms)
                  for ng-sym = (nth i ng-syms)
                  for k-sym  = (nth i k-syms)
                  do (setf acc
                           (list dotimes-sym
                                 (list k-sym e-sym (list mul-sym ts-sym ng-sym))
                                 (list let-sym
                                       (list (list b-sym
                                                   (list plus-sym k-sym
                                                         (list mul-sym gid-sym ts-sym))))
                                       (list uniform-when-sym
                                             (list lt-sym b-sym e-sym)
                                             acc)))))
            acc))
         (outer-bindings
          (append
           (list (list t-sym tensor-form))
           (loop for i from 0 below n
                 for ts-sym in ts-syms
                 collect (list ts-sym (funcall tile-size-expr-fn i)))
           (loop for i from 0 below n
                 for e-sym in e-syms
                 collect (list e-sym (list aref-sym (list extents-tilde-sym t-sym) i)))
           (loop for i from 0 below n
                 for gid-sym in gid-syms
                 collect (list gid-sym (list get-wg-id-sym i)))
           (loop for i from 0 below n
                 for ng-sym in ng-syms
                 collect (list ng-sym (list get-num-groups-sym i))))))
    (list let-sym outer-bindings
          (list declare-sym (list workgroup-level-sym))
          nest)))


;; src/analysis/control.lisp
;;
;; Whole-function replacement of %expand-tile-stride-form, adding the
;; bare load-tile / store-tile body walker call before %tile-helpers-rewrite.
;; Otherwise identical to the src version.
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
           (body-with-load-store-rewritten
            (%rewrite-bare-load-store-tile-in-body body-forms bindings cl-pkg))
           (rewritten-body (%tile-helpers-rewrite body-with-load-store-rewritten n
                                                  (lambda (k) (nth k ts-syms)))))
      (%expand-workgroup-strided-outer-loop-with-ts-syms
       tensor-form n bindings rewritten-body ts-syms tile-size-expr-fn location))))


;; src/analysis/control.lisp
;;
;; Whole-function replacement of %expand-hw-workgroup-idx-form, adding the
;; same bare load-tile / store-tile body walker call.
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
         (body-with-load-store-rewritten
          (%rewrite-bare-load-store-tile-in-body body-forms bindings cl-pkg))
         (rewritten-body (%tile-helpers-rewrite body-with-load-store-rewritten n
                                                 (lambda (k) (nth k ts-syms)))))
    (%expand-workgroup-strided-outer-loop-with-ts-syms
     tensor-form n bindings rewritten-body ts-syms size-expr-fn location)))


;; src/analysis/control.lisp
;;
;; Whole-function replacement of %expand-hw-warp-idx-form, adding the
;; bare load-tile / store-tile detection pass.  Body is checked BEFORE
;; helper rewrite; bare load/store-tile in this context errors with a
;; clear message about the workgroup-cooperative primitive incompatibility.
(defun %expand-hw-warp-idx-form (tensor-form bindings body-forms location)
  "Outer-loop expansion for hardware-stride :warp-idx.  Always 1D.  Phase 1b:
   pre-checks the body for bare load-tile / store-tile (compile error if
   found — incompatible with warp-grouped chunking)."
  (declare (ignore location))
  ;; Phase 1b: bare load-tile / store-tile inside :warp-idx is a compile error.
  (dolist (f body-forms)
    (%detect-bare-load-store-tile-in-form f "hardware-stride :warp-idx"))
  (let* ((cl-pkg (find-package :crisp-language))
         (let-sym             (intern "LET" cl-pkg))
         (declare-sym         (intern "DECLARE" cl-pkg))
         (grid-level-sym      (intern "GRID-LEVEL" cl-pkg))
         (dotimes-sym         (intern "DOTIMES" cl-pkg))
         (when-sym            (intern "WHEN" cl-pkg))
         (progn-sym           (intern "PROGN" cl-pkg))
         (to-ulong-sym        (intern "TO-ULONG" cl-pkg))
         (len-tilde-sym       (intern "LENGTH~" cl-pkg))
         (get-glid-sym        (intern "GET-GLOBAL-LINEAR-ID" cl-pkg))
         (get-glsize-sym      (intern "GET-GLOBAL-LINEAR-SIZE" cl-pkg))
         (plus-sym            (intern "+" cl-pkg))
         (mul-sym             (intern "*" cl-pkg))
         (div-sym             (intern "/" cl-pkg))
         (lt-sym              (intern "<" cl-pkg))
         (t-sym         (gensym "T"))
         (ws-sym        (gensym "WSIZE"))
         (len-sym       (gensym "LEN"))
         (glid-sym      (gensym "GLID"))
         (glsize-sym    (gensym "GLSIZE"))
         (mywarp-sym    (gensym "MYWARP"))
         (numwarps-sym  (gensym "NUMWARPS"))
         (k-sym         (gensym "K"))
         (var-name      (first bindings))
         (rewritten-body (%tile-helpers-rewrite body-forms 1
                                                 (lambda (k)
                                                   (declare (ignore k))
                                                   ws-sym)))
         (inner-body (if (= (length rewritten-body) 1)
                         (first rewritten-body)
                         (cons progn-sym rewritten-body)))
         (inner-when (list when-sym
                           (list lt-sym var-name len-sym)
                           inner-body))
         (inner-let (list let-sym
                          (list (list var-name
                                      (list plus-sym k-sym
                                            (list mul-sym mywarp-sym ws-sym))))
                          inner-when))
         (dotimes-form (list dotimes-sym
                             (list k-sym len-sym (list mul-sym ws-sym numwarps-sym))
                             inner-let))
         (outer-let (list let-sym
                          (list (list t-sym       tensor-form)
                                (list ws-sym      (list to-ulong-sym 32))
                                (list len-sym     (list len-tilde-sym t-sym))
                                (list glid-sym    (list get-glid-sym))
                                (list glsize-sym  (list get-glsize-sym))
                                (list mywarp-sym  (list div-sym glid-sym ws-sym))
                                (list numwarps-sym (list div-sym glsize-sym ws-sym)))
                          (list declare-sym (list grid-level-sym))
                          dotimes-form)))
    outer-let))


;; src/analysis/control.lisp
;;
;; Bare load-tile / store-tile analyzers.  These only fire when the bare
;; form appears OUTSIDE any tile-stride / hardware-stride :workgroup-idx
;; body (since those expansions walk the body and rewrite bare forms before
;; analysis sees them).  The analyzer's only job is to emit a clear error
;; directing the user to the -coords variants for context-free use.

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


;; src/analysis/control.lisp
;;
;; Endeavor 111 Phase 1c — AD backward primitives.
;;
;; (%load-tile-coords-bwd SRC-ADJ TILE-ADJ (ORIGIN...) &key transpose)
;; (%store-tile-coords-bwd TILE-ADJ DEST-ADJ (ORIGIN...) &key transpose)
;;
;; Compiler-internal primitives emitted by generate-backward-walk as the
;; backward-pass counterparts of load-tile-coords / store-tile-coords.
;;
;; Semantics:
;;   %load-tile-coords-bwd:
;;     For each tile coord lc, if (orig + lc) is in-bounds for SRC-ADJ,
;;     atomic-add! SRC-ADJ[orig+lc] += TILE-ADJ[lc].
;;     Atomic because multiple workgroups in a tile-stride loop may
;;     contribute to the same global element of SRC-ADJ in principle.
;;
;;   %store-tile-coords-bwd:
;;     For each tile coord lc, if (orig + lc) is in-bounds for DEST-ADJ,
;;     plain set! TILE-ADJ[lc] += DEST-ADJ[orig+lc].  Non-atomic — each
;;     tile slot is written by exactly one thread within the workgroup-
;;     cooperative loop.
;;
;; Both emit barriers (after for the load-bwd, before+after for store-bwd)
;; mirroring the forward primitives.  Transpose is passed through verbatim.
;;
;; Phase 1c initial: transformF and explicit transpose permutation lists
;; are not yet supported on the backward side; emitting them would be a
;; sub-step (chain-rule with transformF derivative; perm-aware swap).

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


;; src/anf-transform.lisp
;;
;; Endeavor 111 Phase 1c — anf-normalize override.
;;
;; ANF tries to hoist function-call arguments into fresh temp bindings.
;; That's wrong for load-tile-coords / store-tile-coords because their
;; third arg is a *literal list of coord forms* (e.g. (0) or (orig-y orig-x)),
;; not a callable.  Default ANF treats the list as a `(0 ...)` function
;; call, recursing into 0 as the operator and erroring.
;;
;; Fix: add a pre-cond clause that treats these forms (and their backward
;; counterparts, and the bare load-tile / store-tile sugar) as opaque
;; statements — pass through with no arg normalization.  This preserves
;; their structure into flat-anf so generate-backward-walk can recognize
;; them for the role-swap emission.
;;
;; This is a whole-function replacement of anf-normalize.
(defun anf-normalize (expr is-nested?)
  "Returns (VALUES normalized-expr bindings-list).
   Phase 1c: added opaque pass-through for load-tile-coords / store-tile-coords
   and their internal *-bwd / bare load-tile / store-tile variants."
  (cond
   ((anf-is-atomic? expr)
     (values expr nil))

   ((consp expr)
     (let ((op (car expr)))
       (when (and (symbolp op)
                  (macro-function op)
                  (not (member op '(when when+ unless unless+ cond cond+ if if+ return dotimes set! declare progn let
                                          template-instantiation def-function def-kernel def-kernel-exact make-scratch-cell make-scratch-vector make-scratch-matrix make-scratch-tensor as quote compiler-no-op
                                          make-cell make-vector make-matrix make-tensor))))
             (multiple-value-bind (expanded changed) (macroexpand-1 expr)
               (when changed
                     (return-from anf-normalize (anf-normalize expanded is-nested?)))))
       (cond
        ;; Phase 1c: tile-coords primitives (forward, backward, and bare sugar)
        ;; pass through opaquely.  Their third arg is a literal coord list, not
        ;; a callable, so ANF must not recurse into it.
        ((and (symbolp op)
              (member (symbol-name op)
                      '("LOAD-TILE-COORDS" "STORE-TILE-COORDS"
                        "%LOAD-TILE-COORDS-BWD" "%STORE-TILE-COORDS-BWD"
                        "LOAD-TILE" "STORE-TILE")
                      :test #'string=))
          (if is-nested?
              (let ((temp (anf-fresh-temp)))
                (values temp `((,temp ,expr))))
              (values expr nil)))
        ((eq op 'set!)
          (let ((place (cadr expr))
                (value (caddr expr)))
            (multiple-value-bind (new-place place-bindings) (anf-normalize-place place)
              (multiple-value-bind (new-val val-bindings) (anf-normalize value t)
                (let ((set-expr `(set! ,new-place ,new-val))
                      (all-bindings (append place-bindings val-bindings)))
                  (if is-nested?
                      (let ((temp (anf-fresh-temp)))
                        (values temp (append all-bindings `((,temp ,set-expr)))))
                      (values set-expr all-bindings)))))))
        ((member op '(if when unless))
          (multiple-value-bind (cond-expr cond-bindings) (anf-normalize (cadr expr) t)
            (let* ((true-branch (%anf-transform (caddr expr)))
                   (false-branch-raw (if (>= (length expr) 4) (cadddr expr) nil))
                   (false-branch (if false-branch-raw (%anf-transform false-branch-raw) nil))
                   (anf-if (if false-branch
                               `(,op ,cond-expr ,true-branch ,false-branch)
                               `(,op ,cond-expr ,true-branch))))
              (if is-nested?
                  (let ((temp (anf-fresh-temp)))
                    (values temp (append cond-bindings `((,temp ,anf-if)))))
                  (values anf-if cond-bindings)))))
        ((member op '(if+ when+ unless+))
          (let* ((cond-expr (cadr expr))
                 (true-branch (%anf-transform (caddr expr)))
                 (false-branch-raw (if (>= (length expr) 4) (cadddr expr) nil))
                 (false-branch (if false-branch-raw (%anf-transform false-branch-raw) nil))
                 (anf-if (if false-branch
                             `(,op ,cond-expr ,true-branch ,false-branch)
                             `(,op ,cond-expr ,true-branch))))
            (if is-nested?
                (let ((temp (anf-fresh-temp)))
                  (values temp `((,temp ,anf-if))))
                (values anf-if nil))))
        ((eq op 'cond)
          (let ((anf-clauses (mapcar (lambda (clause)
                                       (let* ((pred (car clause))
                                              (body (cadr clause))
                                              (anf-pred (if (eq pred 'else)
                                                            'else
                                                            (%anf-transform pred)))
                                              (anf-body (%anf-transform body)))
                                         `(,anf-pred ,anf-body)))
                                 (cdr expr))))
            (let ((anf-cond `(cond ,@anf-clauses)))
              (if is-nested?
                  (let ((temp (anf-fresh-temp)))
                    (values temp `((,temp ,anf-cond))))
                  (values anf-cond nil)))))
        ((eq op 'let)
          (let* ((orig-bindings (cadr expr))
                 (body-and-decls (cddr expr))
                 (decls (loop for f in body-and-decls while (and (listp f) (eq (car f) 'declare)) collect f))
                 (body-forms (nthcdr (length decls) body-and-decls))
                 (new-bindings nil))
            (dolist (bind orig-bindings)
              (let* ((vars (if (listp (car bind)) (car bind) (butlast bind)))
                     (val (if (listp (car bind)) (cadr bind) (car (last bind)))))
                (multiple-value-bind (new-val val-bindings) (anf-normalize val nil)
                  (setf new-bindings (append new-bindings val-bindings))
                  (setf new-bindings (append new-bindings (list `(,@vars ,new-val)))))))
            (let* ((anf-body (mapcar #'%anf-transform body-forms))
                   (hoisted-decls (loop for d in decls collect `(declare ,d)))
                   (anf-progn (if (> (length anf-body) 1) `(progn ,@anf-body) (car anf-body))))
              (if is-nested?
                  (let ((temp (anf-fresh-temp)))
                    (values temp (append new-bindings hoisted-decls `((,temp ,anf-progn)))))
                  (values anf-progn (append new-bindings hoisted-decls))))))
        ((eq op 'declare)
          (if is-nested?
              (let ((temp (anf-fresh-temp)))
                (values temp `((,temp ,expr))))
              (values expr nil)))
        ((eq op 'return)
          (multiple-value-bind (new-args bindings) (anf-normalize-args (cdr expr))
            (let ((anf-ret `(return ,@new-args)))
              (if is-nested?
                  (let ((temp (anf-fresh-temp)))
                    (values temp (append bindings `((,temp ,anf-ret)))))
                  (values anf-ret bindings)))))
        ((eq op 'as)
          (let ((type-spec (cadr expr))
                (val (caddr expr)))
            (multiple-value-bind (new-val bindings) (anf-normalize val t)
              (let ((anf-as `(as ,type-spec ,new-val)))
                (if is-nested?
                    (let ((temp (anf-fresh-temp)))
                      (values temp (append bindings `((,temp ,anf-as)))))
                    (values anf-as bindings))))))
        ((eq op 'make-scratch-cell)
          (let ((type-spec (cadr expr)))
            (let ((anf-msc `(make-scratch-cell ,type-spec)))
              (if is-nested?
                  (let ((temp (anf-fresh-temp)))
                    (values temp `((,temp ,anf-msc))))
                  (values anf-msc nil)))))
        ((member op '(make-scratch-vector make-scratch-matrix make-scratch-tensor))
          (let ((anf-form `(,op ,@(cdr expr))))
            (if is-nested?
                (let ((temp (anf-fresh-temp)))
                  (values temp `((,temp ,anf-form))))
                (values anf-form nil))))
        ((member op '(make-cell make-vector make-matrix make-tensor))
          (let* ((source (cadr expr))
                 (rest-args (cddr expr)))
            (multiple-value-bind (new-source source-bindings)
                (anf-normalize source t)
              (let ((anf-form `(,op ,new-source ,@rest-args)))
                (if is-nested?
                    (let ((temp (anf-fresh-temp)))
                      (values temp (append source-bindings `((,temp ,anf-form)))))
                    (values anf-form source-bindings))))))
        ((member op '(quote template-instantiation compiler-no-op def-function def-kernel def-kernel-exact eval-when))
          (if is-nested?
              (let ((temp (anf-fresh-temp)))
                (values temp `((,temp ,expr))))
              (values expr nil)))
        ((eq op 'progn)
          (let ((anf-body (mapcar #'%anf-transform (cdr expr))))
            (let ((anf-progn `(progn ,@anf-body)))
              (if is-nested?
                  (let ((temp (anf-fresh-temp)))
                    (values temp `((,temp ,anf-progn))))
                  (values anf-progn nil)))))
        ((and (symbolp op) (string-equal (symbol-name op) "DOTIMES"))
          (let* ((binding (cadr expr))
                 (var (car binding))
                 (limit (cadr binding))
                 (stride (third binding))
                 (body (cddr expr)))
            (multiple-value-bind (new-limit limit-bindings) (anf-normalize limit t)
              (if stride
                  (multiple-value-bind (new-stride stride-bindings) (anf-normalize stride t)
                    (let* ((anf-body (mapcar #'%anf-transform body))
                           (anf-dotimes `(,op (,var ,new-limit ,new-stride) ,@anf-body)))
                      (if is-nested?
                          (let ((temp (anf-fresh-temp)))
                            (values temp (append limit-bindings stride-bindings `((,temp ,anf-dotimes)))))
                          (values anf-dotimes (append limit-bindings stride-bindings)))))
                  (let* ((anf-body (mapcar #'%anf-transform body))
                         (anf-dotimes `(,op (,var ,new-limit) ,@anf-body)))
                    (if is-nested?
                        (let ((temp (anf-fresh-temp)))
                          (values temp (append limit-bindings `((,temp ,anf-dotimes)))))
                        (values anf-dotimes limit-bindings)))))))
        ((and (symbolp op)
              (member (symbol-name op)
                      '("ATOMIC-ADD!" "ATOMIC-SUB!" "ATOMIC-INC!" "ATOMIC-DEC!"
                        "ATOMIC-MIN!" "ATOMIC-MAX!" "ATOMIC-XCHG!" "ATOMIC-SET!")
                      :test #'string=))
          (let ((place (cadr expr))
                (rest-args (cddr expr)))
            (multiple-value-bind (new-place place-bindings) (anf-normalize-place place)
              (multiple-value-bind (anf-args arg-bindings) (anf-normalize-args rest-args)
                (let ((call `(,op ,new-place ,@anf-args))
                      (all-bindings (append place-bindings arg-bindings)))
                  (if is-nested?
                      (let ((temp (anf-fresh-temp)))
                        (values temp (append all-bindings `((,temp ,call)))))
                      (values call all-bindings)))))))
        (t
          (let ((args (cdr expr)))
            (multiple-value-bind (anf-args bindings) (anf-normalize-args args)
              (let ((call `(,op ,@anf-args)))
                (if is-nested?
                    (let ((temp (anf-fresh-temp)))
                      (values temp (append bindings `((,temp ,call)))))
                    (values call bindings)))))))))

   (t (error "Unsupported form for anf-transform: ~S" expr))))


;; src/autodiff.lisp
;;
;; Endeavor 111 Phase 1c — extend %backward-skip-fn-p to recognize the
;; make-scratch-* constructors as gradient-inert.  A scratch buffer's
;; construction carries no gradient (it's a workspace allocation); its
;; CONTENTS are what flow gradients, and those are handled by the
;; load-tile-coords / store-tile-coords backward rules and any other
;; cooperative ops inside the let's body.
;;
;; Whole-function replacement of %backward-skip-fn-p, adding MAKE-SCRATCH-*
;; to the prefix list.
(defun %backward-skip-fn-p (fn-sym)
  "Returns T if FN-SYM should be silently skipped in the AD backward walk."
  (let ((name (symbol-name fn-sym)))
    (cl:flet ((prefix-or-mangled-p (prefix)
                (let ((plen (length prefix)))
                  (or (string= name prefix)
                      (and (> (length name) plen)
                           (string= (subseq name 0 plen) prefix)
                           (cl:char= (cl:char name plen) #\_))))))
      (or
       (find #\% name)
       (string= name "AS")
       (and (>= (length name) 3) (string= (subseq name 0 3) "AS-"))
       (loop for suffix in '("ULONG" "LONG" "UINT" "INT" "USHORT" "SHORT" "UCHAR" "CHAR" "BOOL")
                when (and (>= (length name) (+ 3 (length suffix)))
                          (string= (subseq name 0 3) "TO-")
                          (string= (subseq name (- (length name) (length suffix))) suffix))
                return t)
       (loop for prefix in '("NUM-ROWS" "NUM-COLS" "GET-LAYOUT" "BYTES~"
                             "LENGTH~" "EXTENTS~" "STRIDES~" "PARENT~"
                             "CONTIGUOUS-TERM~" "ELEMENT-TYPE~" "ADDRESS-SPACE~"
                             "ALIGN~" "NUM-DIMS~" "OFFSET~"
                             "MAKE-MATRIX" "MAKE-VECTOR" "MAKE-CELL" "MAKE-TENSOR"
                             ;; 111 Phase 1c: scratch constructors are gradient-inert.
                             "MAKE-SCRATCH-CELL" "MAKE-SCRATCH-VECTOR"
                             "MAKE-SCRATCH-MATRIX" "MAKE-SCRATCH-TENSOR"
                             "TRANSPOSE" "TRANSPOSE!" "ROW" "COL" "SLICE"
                             "GET-GLOBAL-ID" "GET-LOCAL-ID" "GET-WORKGROUP-ID"
                             "GET-NUM-GROUPS" "GET-LOCAL-WORK-SIZE"
                             "GET-GLOBAL-WORK-SIZE" "GET-GLOBAL-OFFSET"
                             "GET-GLOBAL-ID-ABS" "GET-WORK-DIM"
                             "GET-LOCAL-LINEAR-ID" "GET-LOCAL-LINEAR-SIZE"
                             "GET-GLOBAL-LINEAR-ID" "GET-GLOBAL-LINEAR-SIZE"
                             "GET-TOTAL-THREADS" "GET-TOTAL-GROUPS"
                             "LOCAL-BARRIER" "MEM-FENCE")
             when (prefix-or-mangled-p prefix) return t)))))


;; src/autodiff.lisp
;;
;; Endeavor 111 Phase 1c — generate-backward-walk override.
;;
;; Adds two new clauses to process-form:
;;   - LOAD-TILE-COORDS  → emit (%load-tile-coords-bwd  <src>_GRAD <tile>_ADJ origins :transpose ...)
;;   - STORE-TILE-COORDS → emit (%store-tile-coords-bwd <tile>_ADJ <dest>_GRAD origins :transpose ...)
;;
;; Extends the LET case to auto-allocate paired <var>_ADJ scratch tensors
;; for each (make-scratch-*) binding via %augment-scratch-adj-bindings.

(defun %augment-scratch-adj-bindings (bindings kernel-pkg)
  "For each binding (var (make-scratch-X ...)), inject a paired
   (var_ADJ (make-scratch-X ...)) binding right after.  For other bindings,
   pass through unchanged.  Phase 1c initial: assumes same-element-type
   adjoint (no ulong→double promotion yet)."
  (loop for b in bindings
        if (and (consp b) (= (length b) 2) (symbolp (car b))
                (consp (cadr b)) (symbolp (caadr b))
                (member (symbol-name (caadr b))
                        '("MAKE-SCRATCH-VECTOR" "MAKE-SCRATCH-MATRIX"
                          "MAKE-SCRATCH-TENSOR" "MAKE-SCRATCH-CELL")
                        :test #'string=))
          append (list b
                       (let* ((var (car b))
                              (var-adj (intern (format nil "~A_ADJ" (symbol-name var))
                                               (or kernel-pkg (symbol-package var))))
                              (init (cadr b)))
                         (list var-adj init)))
        else collect b))


(defun %tlc-bwd-adj-name (sym inputs outputs local-adj-fn kernel-pkg)
  "Returns the backward-pass adjoint symbol for a forward arg SYM:
     - if SYM is in INPUTS or OUTPUTS  → <SYM>_GRAD  (kernel param)
     - otherwise (let-bound local)     → <SYM>_ADJ  (direct intern; NOT
       via local-adj-fn, because local-adj-fn would add the sym to the
       adjoint-map, which causes the wrapping let to scalar-initialize it
       — wrong for tensor adjoints.  The auto-allocated LET binding for
       <var>_ADJ as a make-scratch-* is the only initializer needed.)"
  (declare (ignore local-adj-fn))
  (cond
    ((or (member sym inputs) (member sym outputs))
     (intern (format nil "~A_GRAD" (symbol-name sym))
             (or kernel-pkg (symbol-package sym))))
    (t
     (intern (format nil "~A_ADJ" (symbol-name sym))
             (or kernel-pkg (symbol-package sym))))))


(defun %tlc-extract-transpose-key (key-args)
  "Returns the value of :transpose in KEY-ARGS, or NIL if absent."
  (loop for (k v) on key-args by #'cddr
        when (eq k :transpose) return v
        finally (cl:return nil)))


(defun generate-backward-walk (flat-anf inputs outputs input-types output-types
                               &key kernel-pkg)
  "Walks an ANF body backwards to accumulate adjoints.
   Phase 1c: adds LOAD-TILE-COORDS / STORE-TILE-COORDS clauses to process-form
   that emit %load-tile-coords-bwd / %store-tile-coords-bwd with the correct
   adjoint symbols.  Also extends the LET case to auto-allocate paired
   <var>_ADJ scratch tensors for make-scratch-* bindings."
  (let* ((record-temp-entries
          (loop for form in flat-anf
                when (and (consp form) (= (length form) 2)
                          (symbolp (car form))
                          (consp (cadr form))
                          (symbolp (caadr form))
                          (string-equal (symbol-name (caadr form)) "%CONSTRUCT-STRUCT"))
                collect
                (let* ((temp-sym (car form))
                       (expr (cadr form))
                       (record-name (second expr))
                       (pkg (or kernel-pkg (symbol-package temp-sym))))
                  (when (or (%crisp-record-type-p record-name)
                            (%crisp-struct-type-p record-name))
                    (let* ((fields (%get-record-runtime-fields record-name))
                           (field-alist
                            (loop for (fname ftype) in fields
                                  collect (cons (symbol-name fname)
                                                (intern (format nil "~a_~a_ADJ"
                                                                (symbol-name temp-sym)
                                                                (symbol-name fname))
                                                        pkg)))))
                      (cons temp-sym field-alist))))))
         (record-temp-entries (remove nil record-temp-entries))
         (record-param-field-adjs-ht
          (let ((ht (when (or record-temp-entries *record-param-field-adjs*)
                      (make-hash-table :test 'eq))))
            (when ht
              (when *record-param-field-adjs*
                (maphash (lambda (k v) (setf (gethash k ht) v))
                         *record-param-field-adjs*))
              (dolist (entry record-temp-entries)
                (setf (gethash (car entry) ht) (cdr entry))))
            ht)))
    (let ((*record-param-field-adjs* record-param-field-adjs-ht))
      (let ((backward-forms nil)
            (adjoint-map (make-hash-table :test 'equal))
            (tensor-inputs-ht
             (let ((ht (make-hash-table :test 'eq)))
               (loop for sym  in inputs
                     for typ  in input-types
                     when (%crisp-float-tensor-type-p typ)
                     do (setf (gethash sym ht) typ))
               ht)))
        (cl:flet ((promotes-to-double-p (t-spec)
                    (let ((promoted (%promote-to-float-adjoint t-spec)))
                      (or (eq promoted 'double)
                          (and (consp promoted) (eq (second promoted) 'double))))))
          (let* ((any-output-double (some #'promotes-to-double-p output-types))
                 (intermediate-zero (if any-output-double '(as double 0.0) 0.0)))
            (labels ((local-adj (v)
                       (or (gethash v adjoint-map)
                           (let ((adv (intern (format nil "~A_ADJ" (symbol-name v))
                                              (or kernel-pkg (symbol-package v)))))
                             (setf (gethash v adjoint-map) adv)
                             adv)))
                     (emit (form)
                       (push form backward-forms))
                     (hof-inline-backward (fn args v)
                       (let* ((hof-data (gethash fn *differentiable-hof-store*)))
                         (unless hof-data
                           (error "HOF ~A not found in *differentiable-hof-store*" fn))
                         (let* ((param-syms   (getf hof-data :param-syms))
                                (fn-param-idx (getf hof-data :fn-param-idx))
                                (body-forms   (getf hof-data :body-forms))
                                (fn-arg       (nth fn-param-idx args))
                                (concrete-fn  (cond
                                                ((and (consp fn-arg) (eq (car fn-arg) 'function))
                                                 (cadr fn-arg))
                                                ((symbolp fn-arg) fn-arg)
                                                (t nil))))
                           (unless concrete-fn
                             (error "Cannot inline-differentiate HOF ~A:  could not resolve concrete fn from arg ~A" fn fn-arg))
                           (let* ((fn-param      (nth fn-param-idx param-syms))
                                  (subst-alist
                                   (loop for p in param-syms
                                         for a in args
                                         for i from 0
                                         unless (= i fn-param-idx)
                                         collect (cons p a)))
                                  (subst-body    (mapcar (lambda (f) (%subst-form f subst-alist)) body-forms))
                                  (concrete-body (mapcar (lambda (f) (%remove-funcall f fn-param concrete-fn))
                                                         subst-body))
                                  (anf-body      (mapcar #'anf-transform concrete-body))
                                  (hof-flat      (flatten-anf-body anf-body))
                                  (hof-flat-norm
                                   (let ((last-f (car (last hof-flat))))
                                     (if (or (symbolp last-f)
                                             (and (consp last-f) (eq (first last-f) 'return)))
                                         hof-flat
                                         (let ((ret-sym (intern (format nil "%HOF_RET_~A" (symbol-name v))
                                                                (symbol-package v))))
                                           (append (butlast hof-flat)
                                                   (list (list ret-sym last-f) ret-sym))))))
                                  (return-vars   (%extract-return-vars hof-flat-norm)))
                             (dolist (rv return-vars)
                               (setf (gethash rv adjoint-map) (local-adj v)))
                             (dolist (hf-form (reverse hof-flat-norm))
                               (when (and (consp hf-form) (= (length hf-form) 2) (symbolp (car hf-form)))
                                 (let ((hv    (car hf-form))
                                       (hexpr (cadr hf-form)))
                                   (%handle-single-value-backward hv hexpr adjoint-map #'emit #'local-adj
                                                                  :hof-handler-fn #'hof-inline-backward
                                                                  :error-on-unknown t
                                                                  :tensor-inputs-ht nil))))))))
                     (process-form (form emit-fn)
                       (cond
                         ((and (consp form) (symbolp (car form))
                               (string-equal (symbol-name (car form)) "DECLARE")) nil)

                         ;; Phase 1c: load-tile-coords forward → backward.
                         ((and (consp form) (symbolp (car form))
                               (string-equal (symbol-name (car form)) "LOAD-TILE-COORDS"))
                          (let* ((src      (second form))
                                 (tile     (third form))
                                 (origins  (fourth form))
                                 (key-args (nthcdr 4 form))
                                 (transpose-v (%tlc-extract-transpose-key key-args))
                                 (src-adj (%tlc-bwd-adj-name src inputs outputs
                                                              #'local-adj kernel-pkg))
                                 (tile-adj (%tlc-bwd-adj-name tile inputs outputs
                                                               #'local-adj kernel-pkg))
                                 (bwd-sym (intern "%LOAD-TILE-COORDS-BWD"
                                                  (find-package :crisp-language)))
                                 (bwd-form (if transpose-v
                                               (list bwd-sym src-adj tile-adj origins :transpose transpose-v)
                                               (list bwd-sym src-adj tile-adj origins))))
                            (funcall emit-fn bwd-form)))

                         ;; Phase 1c: store-tile-coords forward → backward.
                         ((and (consp form) (symbolp (car form))
                               (string-equal (symbol-name (car form)) "STORE-TILE-COORDS"))
                          (let* ((tile     (second form))
                                 (dest     (third form))
                                 (origins  (fourth form))
                                 (key-args (nthcdr 4 form))
                                 (transpose-v (%tlc-extract-transpose-key key-args))
                                 (tile-adj (%tlc-bwd-adj-name tile inputs outputs
                                                               #'local-adj kernel-pkg))
                                 (dest-adj (%tlc-bwd-adj-name dest inputs outputs
                                                                #'local-adj kernel-pkg))
                                 (bwd-sym (intern "%STORE-TILE-COORDS-BWD"
                                                  (find-package :crisp-language)))
                                 (bwd-form (if transpose-v
                                               (list bwd-sym tile-adj dest-adj origins :transpose transpose-v)
                                               (list bwd-sym tile-adj dest-adj origins))))
                            (funcall emit-fn bwd-form)))

                         ((and (consp form) (symbolp (car form))
                               (string-equal (symbol-name (car form)) "SET!"))
                          (let ((place (cadr form))
                                (val   (caddr form)))
                            (when (and (consp place) (eq (car place) '~) (symbolp val))
                              (let ((target  (cadr place))
                                    (indices (cddr place)))
                                (cond
                                  ((member target outputs)
                                   (let ((tgt-grad (intern (format nil "~A_GRAD" (symbol-name target))
                                                           (symbol-package target))))
                                     (funcall emit-fn `(set! ,(local-adj val)
                                                             (+ ,(local-adj val) (~ ,tgt-grad ,@indices))))))
                                  ((member target inputs)
                                   (error "Cannot differentiate: kernel mutates input parameter ~A via (set! (~~ ~A) ...). Only output parameters may be written."
                                          target target))
                                  (t nil))))))

                         ((and (consp form) (symbolp (car form))
                               (string-equal (symbol-name (car form)) "LET"))
                          (let* ((bindings (cadr form))
                                 ;; Phase 1c: auto-allocate <var>_ADJ paired scratch.
                                 (augmented-bindings (%augment-scratch-adj-bindings bindings kernel-pkg))
                                 (body (cddr form))
                                 (local-forms nil))
                            (cl:flet ((local-emit (f) (push f local-forms)))
                              (dolist (b (reverse body))
                                (process-form b #'local-emit))
                              (dolist (b (reverse bindings))
                                (when (and (consp b) (= (length b) 2) (symbolp (car b)))
                                  (process-form b #'local-emit))))
                            (funcall emit-fn `(let ,augmented-bindings ,@(nreverse local-forms)))))

                         ((and (consp form) (symbolp (car form))
                               (string-equal (symbol-name (car form)) "DOTIMES"))
                          (let* ((binding (cadr form))
                                 (body (cddr form))
                                 (local-vars (%collect-locally-bound-vars body))
                                 (local-forms nil))
                            (cl:flet ((local-emit (f) (push f local-forms)))
                              (dolist (b (reverse body))
                                (process-form b #'local-emit)))
                            (let ((zero-resets
                                   (loop for v in local-vars
                                         for adv = (gethash v adjoint-map)
                                         when adv
                                         collect `(set! ,adv ,intermediate-zero))))
                              (funcall emit-fn
                                       `(dotimes ,binding
                                          ,@zero-resets
                                          ,@(nreverse local-forms))))))

                         ((and (consp form) (symbolp (car form))
                               (string-equal (symbol-name (car form)) "IF"))
                          (let* ((cond-form (cadr form))
                                 (then-form (caddr form))
                                 (else-form (cadddr form))
                                 (then-local nil)
                                 (else-local nil))
                            (when then-form
                              (process-form then-form (lambda (f) (push f then-local))))
                            (when (and else-form (not (null else-form)))
                              (process-form else-form (lambda (f) (push f else-local))))
                            (let ((then-body (cond
                                               ((null then-local) nil)
                                               ((= (length then-local) 1) (first then-local))
                                               (t `(progn ,@(nreverse then-local)))))
                                  (else-body (cond
                                               ((null else-local) nil)
                                               ((= (length else-local) 1) (first else-local))
                                               (t `(progn ,@(nreverse else-local))))))
                              (funcall emit-fn
                                       (if else-body
                                           `(if ,cond-form ,(or then-body 'nil) ,else-body)
                                           `(if ,cond-form ,(or then-body 'nil)))))))

                         ((and (consp form) (symbolp (car form))
                               (string-equal (symbol-name (car form)) "PROGN"))
                          (dolist (sub (reverse (cdr form)))
                            (process-form sub emit-fn)))

                         ((and (listp form) (= (length form) 2) (symbolp (car form)))
                          (%handle-single-value-backward (car form) (cadr form)
                                                         adjoint-map emit-fn #'local-adj
                                                         :hof-handler-fn #'hof-inline-backward
                                                         :error-on-unknown t
                                                         :tensor-inputs-ht tensor-inputs-ht))

                         ((and (listp form) (>= (length form) 3)
                               (symbolp (car form))
                               (every #'symbolp (butlast form)))
                          (let* ((result-vars (butlast form))
                                 (expr        (car (last form))))
                            (when (and (consp expr)
                                       (symbolp (car expr))
                                       (gethash (car expr) *differentiable-functions*))
                              (let* ((fn   (car expr))
                                     (args (cdr expr))
                                     (info (gethash fn *differentiable-functions*))
                                     (bkwd (getf info :bkwd-name))
                                     (n-fp (getf info :n-float-params))
                                     (pkg  (symbol-package (car result-vars)))
                                     (t-adjs (mapcar #'local-adj result-vars)))
                                (%emit-sub-fn-backward fn args bkwd t-adjs n-fp pkg
                                                       emit-fn #'local-adj "BW")))))

                         (t nil))))

              (let ((reversed-body (reverse flat-anf)))
                (dolist (form reversed-body)
                  (process-form form #'emit)))

              (loop for in in inputs
                    for in-type in input-types do
                      (let* ((in-grad    (intern (format nil "~A_GRAD" (symbol-name in))
                                                 (or kernel-pkg (symbol-package in))))
                             (canon-type (canonicalize-type-specifier
                                          (if (listp in-type) in-type (list in-type))))
                             (is-cell-input
                              (and (consp canon-type)
                                   (string-equal (symbol-name (first canon-type)) "CELL")))
                             (is-tensor-input
                              (or (%crisp-float-tensor-type-p in-type)
                                  (%crisp-integer-tensor-type-p in-type)))
                             (is-scalar-wrapped
                              (and (not is-cell-input) (not is-tensor-input)
                                   (or (%crisp-integer-scalar-type-p in-type)
                                       (%crisp-float-type-p in-type)))))
                        (cond
                          (is-tensor-input nil)
                          (is-cell-input     (emit `(set! (~ ,in-grad) ,(local-adj in))))
                          (is-scalar-wrapped (emit `(set! (~ ,in-grad) ,(local-adj in))))
                          (t                 (emit `(set! ,in-grad ,(local-adj in)))))))

              (let* ((typed-zero-for
                      (lambda (orig-sym)
                        (let* ((idx (position orig-sym inputs))
                               (in-type (when idx (nth idx input-types))))
                          (cond
                            (in-type
                             (if (promotes-to-double-p in-type) '(as double 0.0) 0.0))
                            (any-output-double '(as double 0.0))
                            (t 0.0)))))
                     (local-bindings (loop for v being the hash-keys of adjoint-map
                                           using (hash-value adv)
                                           collect `(,adv ,(funcall typed-zero-for v))))
                     ;; Phase 1c: auto-allocate <var>_ADJ paired scratch
                     ;; tensors for each make-scratch-* binding in flat-anf.
                     ;; The forward let-bindings already give us <var>; the
                     ;; backward wants both <var> and <var>_ADJ.
                     ;; Phase 1c initial: assumes same element-type (no
                     ;; ulong→double promotion yet; defer to a sub-step).
                     (scratch-adj-bindings
                      (loop for form in flat-anf
                            when (and (consp form) (= (length form) 2)
                                      (symbolp (car form))
                                      (consp (cadr form)) (symbolp (caadr form))
                                      (member (symbol-name (caadr form))
                                              '("MAKE-SCRATCH-VECTOR" "MAKE-SCRATCH-MATRIX"
                                                "MAKE-SCRATCH-TENSOR" "MAKE-SCRATCH-CELL")
                                              :test #'string=))
                            collect (let* ((var (car form))
                                           (var-adj (intern (format nil "~A_ADJ" (symbol-name var))
                                                            (or kernel-pkg (symbol-package var)))))
                                      (list var-adj (cadr form)))))
                     (result `(let ,(append scratch-adj-bindings local-bindings)
                                ,@(nreverse backward-forms))))
                result))))))))


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
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-store-tile-coords-expression)))
  ;; 111 Phase 1b: bare load-tile / store-tile.  Only invoked when the form
  ;; appears OUTSIDE a tile-stride / hardware-stride :workgroup-idx body
  ;; (inside, the body walker rewrites them before analysis).  These error
  ;; with a clear message pointing to the -coords variants.
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
  ;; 111 Phase 1d: %uniform-when — internal-use, compiler-generated
  ;; workgroup-uniform conditional that does NOT set the divergence flag.
  ;; Used by tile-stride / hardware-stride :workgroup-idx outer-loop bounds.
  (let ((sym-cl (intern "%UNIFORM-WHEN" (find-package :crisp-language)))
        (sym-cc (intern "%UNIFORM-WHEN" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-%uniform-when-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-%uniform-when-expression)))
  ;; 111 Phase 1c: AD backward primitives.  Emitted by generate-backward-walk
  ;; as counterparts of load-tile-coords / store-tile-coords.
  (let ((sym-cl (intern "%LOAD-TILE-COORDS-BWD" (find-package :crisp-language)))
        (sym-cc (intern "%LOAD-TILE-COORDS-BWD" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-%load-tile-coords-bwd-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-%load-tile-coords-bwd-expression)))
  (let ((sym-cl (intern "%STORE-TILE-COORDS-BWD" (find-package :crisp-language)))
        (sym-cc (intern "%STORE-TILE-COORDS-BWD" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-%store-tile-coords-bwd-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-%store-tile-coords-bwd-expression))))
