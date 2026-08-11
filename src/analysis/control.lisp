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

             ;; Void Compatibility. If BOTH branches are void, the if is void (a
             ;; statement (when ...) / (unless ...)).
             ((and (null t-single) (null e-single))
               (values '(nil) then-node else-node))
             ;; If only ONE branch is void — e.g. (if cond nil X), as produced by a
             ;; value-position (unless+ cond X) => (if+ cond nil X), or (if cond X nil)
             ;; — unify to the OTHER branch's real type. The void branch contributes
             ;; no value and its path is left undef by codegen (safe: under a uniform
             ;; if+/when+/unless+ condition that branch is untaken; for a plain
             ;; divergent if, using the value on the void path is the caller's
             ;; pre-existing undefined behaviour). This lets such an if be used as a
             ;; value, e.g. (set! (~ r) (unless+ ...)).
             ((null t-single)
               (values e-type then-node else-node))
             ((null e-single)
               (values t-type then-node else-node))

             (t
               (error "Branch type mismatch in IF expression. Then: ~a, Else: ~a" t-type e-type))))))))


;; These are the "explicit coords" variants of load-tile / store-tile.  They
;; expand into a workgroup-stride-shaped cooperative loop with bounds
;; checking and an implicit sync-workgroup.
;;
;; API (sub-step 1a, src-first universally):
;;   (load-tile-at  <src-global> <dest-tile> (origin-coords...) &key (identity 0) transpose)
;;   (store-tile-at <src-tile> <dest-global> (origin-coords...) &key transformF transpose)
;;
;; Semantics:
;;   load-tile-at:
;;     - For each tile coord (cooperatively across the workgroup), compute the
;;       corresponding source coord = origin + tile-coord (or transposed map
;;       for :transpose t).
;;     - If source coord is in-bounds, copy source[src-coord] -> tile[tile-coord].
;;     - If source coord is out-of-bounds, write the :identity value to
;;       tile[tile-coord] (default 0).
;;     - Ends with (sync-workgroup) so subsequent reads see the loaded tile.
;;
;;   store-tile-at:
;;     - Starts with (sync-workgroup) so all prior tile writes are visible.
;;     - For each tile coord (cooperatively), compute dest coord = origin +
;;       tile-coord (or transposed).
;;     - If dest coord is in-bounds, write tile[tile-coord] (optionally run
;;       through :transformF first) to dest[dest-coord].  Out-of-bounds
;;       tile slots are silently skipped (no :identity equivalent on store).
;;     - Ends with (sync-workgroup).
;;
;; Transpose handling (Phase 1a):
;;   - :transpose nil or absent: identity coord map.
;;   - :transpose t: swap the innermost two dims of the coord map.  Requires
;;     arity >= 2; arity 1 with :transpose t is a compile error.
;;   - Explicit permutation lists (e.g. '(0 2 1)): deferred.


(defun %extract-key-arg (key-args keyword default)
  "Parses a &key-style plist KEY-ARGS for KEYWORD, returning its value or
   DEFAULT if absent.  Phase 1a helper for load-tile-at / store-tile-at
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
   load-tile-at and store-tile-at.  At each level:
     (dotimes (K_k TE_k LWS_k)
       (let ((tile-coord-k (+ K_k LID_k)))
         (when (< tile-coord-k TE_k)
           <inner>)))
   Returns the nested form.  Local-bindings is the outer let's binding list
   (passed through unchanged; caller adds tensor/extent/lid/lws bindings).
   Tile-coord-syms / tile-extent-syms / lid-syms / lws-syms must be lists of
   length n."
  (declare (ignore tile-sym local-bindings))
  (let ((let-sym (intern "LET" cl-pkg))
        (dotimes-sym (intern "DOTIMES" cl-pkg))
        (when-sym (intern "WHEN" cl-pkg))
        (plus-sym (intern "+" cl-pkg))
        (lt-sym (intern "<" cl-pkg))
        (k-syms (loop for i from 0 below n collect (gensym (format nil "K~A" i))))
        (acc inner-form))
    (loop for i from (1- n) downto 0
          for tc-sym = (nth i tile-coord-syms)
          for te-sym = (nth i tile-extent-syms)
          for lid-sym = (nth i lid-syms)
          for lws-sym = (nth i lws-syms)
          for k-sym = (nth i k-syms)
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

(defun %expand-load-tile-at-form (expr location)
  "Pure expansion of (load-tile-at SRC TILE (ORIGIN...) &key (identity 0) transpose).
   Returns a let/dotimes/when nest that cooperatively loads the tile, ending
   with (sync-workgroup)."
  (let* ((src-form (second expr))
         (tile-form (third expr))
         (origin-list (fourth expr))
         (key-args (nthcdr 4 expr)))
    (unless (and (listp origin-list)
                 (>= (length origin-list) 1))
      (error 'crisp-compiler-error
        :message "load-tile-at: origin must be a non-empty list of coord forms"
        :source-location location))
    (let* ((identity-form (%extract-key-arg key-args :identity 0))
           (transpose-form (%extract-key-arg key-args :transpose nil))
           (n (length origin-list))
           (perm (%tlc-transpose-permutation n transpose-form location))
           (cl-pkg (find-package :crisp-language))
           (let-sym (intern "LET" cl-pkg))
           (progn-sym (intern "PROGN" cl-pkg))
           (if-sym (intern "IF" cl-pkg))
           (set-sym (intern "SET!" cl-pkg))
           (aref-sym (intern "~" cl-pkg))
           (extents-tilde-sym (intern "EXTENTS~" cl-pkg))
           (get-local-id-sym (intern "GET-LOCAL-ID" cl-pkg))
           (get-lws-sym (intern "GET-LOCAL-WORK-SIZE" cl-pkg))
           (sync-workgroup-sym (intern "SYNC-WORKGROUP" cl-pkg))
           (to-ulong-sym (intern "TO-ULONG" cl-pkg))
           (plus-sym (intern "+" cl-pkg))
           (lt-sym (intern "<" cl-pkg))
           (and-sym (intern "AND" cl-pkg))
           (src-sym (gensym "SRC"))
           (tile-sym (gensym "TILE"))
           (ident-sym (gensym "IDENT"))
           (origin-syms (loop for i from 0 below n collect (gensym (format nil "ORIG~A" i))))
           (tile-coord-syms (loop for i from 0 below n collect (gensym (format nil "TLC~A" i))))
           (tile-extent-syms (loop for i from 0 below n collect (gensym (format nil "TE~A" i))))
           (global-extent-syms (loop for i from 0 below n collect (gensym (format nil "GE~A" i))))
           (lid-syms (loop for i from 0 below n collect (gensym (format nil "LID~A" i))))
           (lws-syms (loop for i from 0 below n collect (gensym (format nil "LWS~A" i))))
           ;; Source coord expressions: src[k] = origin[k] + tile-coord[perm[k]]
           (src-coord-exprs (%tlc-source-coord-exprs n origin-syms tile-coord-syms perm plus-sym))
           ;; The innermost body:  (if (and-bounds) (set! tile = src[..]) (set! tile = identity))
           (tile-aref (cons aref-sym (cons tile-sym tile-coord-syms)))
           (src-aref (cons aref-sym (cons src-sym src-coord-exprs)))
           (bounds-form (%tlc-all-in-bounds-form n src-coord-exprs
                                                 global-extent-syms lt-sym and-sym))
           (inner-body (list if-sym
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
                  (list sync-workgroup-sym))))))


;; Endeavor 136 (Chapter 1) — async variant of %expand-load-tile-at-form.  Same cooperative
;; N-D coop loop, but each in-bounds element is a non-blocking (%cp-async-copy-elem tile src)
;; instead of a (set!), and the loop is followed by (%cp-async-commit) instead of
;; (sync-workgroup) — the await lowers to cp.async.wait_group(0).  OOB elements still use a
;; sync (set! identity) — immediate, and unaffected by the async group.
(defun %expand-async-load-tile-at-form (expr location)
  "Async (cp.async) expansion of (load-tile-at SRC TILE (ORIGIN...) &key (identity 0)
   transpose barrier).  Cooperative cp.async copy + commit_group; the matching await
   emits wait_group(0)."
  (let* ((src-form (second expr))
         (tile-form (third expr))
         (origin-list (fourth expr))
         (key-args (nthcdr 4 expr)))
    (unless (and (listp origin-list) (>= (length origin-list) 1))
      (error 'crisp-compiler-error
        :message "load-tile-at: origin must be a non-empty list of coord forms"
        :source-location location))
    (let* ((identity-form (%extract-key-arg key-args :identity 0))
           (transpose-form (%extract-key-arg key-args :transpose nil))
           (n (length origin-list))
           (perm (%tlc-transpose-permutation n transpose-form location))
           (cl-pkg (find-package :crisp-language))
           (let-sym (intern "LET" cl-pkg))
           (progn-sym (intern "PROGN" cl-pkg))
           (if-sym (intern "IF" cl-pkg))
           (set-sym (intern "SET!" cl-pkg))
           (aref-sym (intern "~" cl-pkg))
           (extents-tilde-sym (intern "EXTENTS~" cl-pkg))
           (get-local-id-sym (intern "GET-LOCAL-ID" cl-pkg))
           (get-lws-sym (intern "GET-LOCAL-WORK-SIZE" cl-pkg))
           (to-ulong-sym (intern "TO-ULONG" cl-pkg))
           (plus-sym (intern "+" cl-pkg))
           (lt-sym (intern "<" cl-pkg))
           (and-sym (intern "AND" cl-pkg))
           (cp-async-copy-sym (intern "%CP-ASYNC-COPY-ELEM" cl-pkg))
           (cp-async-commit-sym (intern "%CP-ASYNC-COMMIT" cl-pkg))
           (src-sym (gensym "SRC"))
           (tile-sym (gensym "TILE"))
           (ident-sym (gensym "IDENT"))
           (origin-syms (loop for i from 0 below n collect (gensym (format nil "ORIG~A" i))))
           (tile-coord-syms (loop for i from 0 below n collect (gensym (format nil "TLC~A" i))))
           (tile-extent-syms (loop for i from 0 below n collect (gensym (format nil "TE~A" i))))
           (global-extent-syms (loop for i from 0 below n collect (gensym (format nil "GE~A" i))))
           (lid-syms (loop for i from 0 below n collect (gensym (format nil "LID~A" i))))
           (lws-syms (loop for i from 0 below n collect (gensym (format nil "LWS~A" i))))
           (src-coord-exprs (%tlc-source-coord-exprs n origin-syms tile-coord-syms perm plus-sym))
           (tile-aref (cons aref-sym (cons tile-sym tile-coord-syms)))
           (src-aref (cons aref-sym (cons src-sym src-coord-exprs)))
           (bounds-form (%tlc-all-in-bounds-form n src-coord-exprs
                                                 global-extent-syms lt-sym and-sym))
           ;; in-bounds -> async copy;  out-of-bounds -> sync identity store.
           (inner-body (list if-sym
                             bounds-form
                             (list cp-async-copy-sym tile-aref src-aref)
                             (list set-sym tile-aref ident-sym)))
           (loop-nest (%tlc-coop-loop-skeleton n tile-sym nil tile-coord-syms
                                               tile-extent-syms lid-syms lws-syms
                                               inner-body cl-pkg))
           (outer-bindings
            (append
              (list (list src-sym src-form)
                    (list tile-sym tile-form)
                    (list ident-sym identity-form))
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
                  (list cp-async-commit-sym))))))

;; src/analysis/control.lisp
(defun %expand-store-tile-at-form (expr location)
  "Pure expansion of (store-tile-at TILE DEST (ORIGIN...) &key transformF transpose).
   Returns a let/progn nest with (sync-workgroup) BEFORE and AFTER the
   cooperative store loop.  TransformF is applied per-element (unary)."
  (let* ((tile-form (second expr))
         (dest-form (third expr))
         (origin-list (fourth expr))
         (key-args (nthcdr 4 expr)))
    (unless (and (listp origin-list)
                 (>= (length origin-list) 1))
      (error 'crisp-compiler-error
        :message "store-tile-at: origin must be a non-empty list of coord forms"
        :source-location location))
    (let* ((transformF-form (%extract-key-arg key-args :transformF nil))
           (transpose-form (%extract-key-arg key-args :transpose nil))
           (n (length origin-list))
           (perm (%tlc-transpose-permutation n transpose-form location))
           (cl-pkg (find-package :crisp-language))
           (let-sym (intern "LET" cl-pkg))
           (progn-sym (intern "PROGN" cl-pkg))
           (when-sym (intern "WHEN" cl-pkg))
           (set-sym (intern "SET!" cl-pkg))
           (funcall-sym (intern "FUNCALL" cl-pkg))
           (aref-sym (intern "~" cl-pkg))
           (extents-tilde-sym (intern "EXTENTS~" cl-pkg))
           (get-local-id-sym (intern "GET-LOCAL-ID" cl-pkg))
           (get-lws-sym (intern "GET-LOCAL-WORK-SIZE" cl-pkg))
           (sync-workgroup-sym (intern "SYNC-WORKGROUP" cl-pkg))
           (to-ulong-sym (intern "TO-ULONG" cl-pkg))
           (plus-sym (intern "+" cl-pkg))
           (lt-sym (intern "<" cl-pkg))
           (and-sym (intern "AND" cl-pkg))
           (tile-sym (gensym "TILE"))
           (dest-sym (gensym "DEST"))
           (origin-syms (loop for i from 0 below n collect (gensym (format nil "ORIG~A" i))))
           (tile-coord-syms (loop for i from 0 below n collect (gensym (format nil "TLC~A" i))))
           (tile-extent-syms (loop for i from 0 below n collect (gensym (format nil "TE~A" i))))
           (global-extent-syms (loop for i from 0 below n collect (gensym (format nil "GE~A" i))))
           (lid-syms (loop for i from 0 below n collect (gensym (format nil "LID~A" i))))
           (lws-syms (loop for i from 0 below n collect (gensym (format nil "LWS~A" i))))
           ;; Dest coord expressions: dest[k] = origin[k] + tile-coord[perm[k]]
           (dest-coord-exprs (%tlc-source-coord-exprs n origin-syms tile-coord-syms perm plus-sym))
           (tile-aref (cons aref-sym (cons tile-sym tile-coord-syms)))
           (dest-aref (cons aref-sym (cons dest-sym dest-coord-exprs)))
           (bounds-form (%tlc-all-in-bounds-form n dest-coord-exprs
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
                  (list sync-workgroup-sym) ; barrier BEFORE
                  loop-nest
                  (list sync-workgroup-sym)))))) ; barrier AFTER


;; load-tile-at / store-tile-at (and the bare load-tile / store-tile
;; that rewrite to them) contain internal (sync-workgroup) calls.  Inside a
;; thread-divergent (if / when / unless / cond) where some threads enter the
;; branch and others don't, only some threads hit the barrier — deadlock.
;;
;; The compiler tracks divergent-conditional context via the dynamic
;; defvar *in-divergent-conditional*.  Set to T inside the analyzed branches
;; of a runtime if-expression (when both branches are analyzed, i.e. the
;; condition wasn't constant-folded).  The load-tile-at / store-tile-at
;; analyzers check the flag at entry and error if set.
;;
;; if+ / when+ / unless+ are compile-time conditionals — they DCE to a single
;; branch before analysis, so no runtime divergence is introduced.

(defvar *in-divergent-conditional* nil
        "T when the analyzer is currently inside a thread-divergent if/when/unless/cond
   branch (i.e. the conditional's test was not constant-folded).  Used by the
   load-tile-at / store-tile-at analyzers to reject placement that
   would deadlock at their internal sync-workgroups.

   Compiler-generated workgroup-uniform whens (e.g. the per-dim bounds check
   that wraps tile-stride / hardware-stride :workgroup-idx bodies) use the
   internal %uniform-when form instead, whose analyzer does NOT set this flag.")

(defvar *in-warp-spec-block* nil
        "Endeavor 139 (Chapter 3), decision B: T when analyzing the body of a
   with-warp-specialization role block.  Such a block is warp-DIVERGENT (different warps run
   different roles), which sets *in-divergent-conditional* — but a :block (TMA) load-tile there is
   SAFE: it is leader-issued and mbarrier-tracked, with no workgroup collective to deadlock.  So
   %tlc-check-not-divergent relaxes when this is set.  A workgroup collective (sync-workgroup, a
   cooperative :linear load) inside a role block WOULD deadlock and is rejected separately.")

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
   conditional.  Call from load-tile-at / store-tile-at analyzers.
   NOTE (Endeavor 139): a with-warp-specialization role block ALSO sets *in-divergent-conditional*,
   but its callers gate this on (not *in-warp-spec-block*) and apply the mode-aware
   %warp-spec-check-block-only instead — a :block load there is leader-issued and safe."
  (when *in-divergent-conditional*
        (error 'crisp-compiler-error
          :message (format nil
                       "~A cannot appear inside a thread-divergent conditional (if / when / unless / cond).  It contains an internal sync-workgroup that would deadlock when only some threads enter the branch.  Compile-time conditionals (if+ / when+ / unless+) are safe.  If you need a guarded copy, use a non-divergent condition (e.g. one based on get-workgroup-id, not get-local-id) or restructure the kernel."
                     op-name)
          :source-location location)))

(defun %warp-spec-check-sync (builtin-kw name-str location)
  "Endeavor 139 (decision B): the sync/fence builtins inside a role block.  A workgroup collective
   (sync-workgroup) DEADLOCKS — only one role's warps reach it — so it is forbidden; warp-scoped
   ops (sync-warp, mem-fence) are fine.  Outside a warp-spec block, defer to the normal
   thread-divergent check."
  (if *in-warp-spec-block*
      (when (eq builtin-kw :sync-workgroup)
        (error 'crisp-compiler-error
          :message "sync-workgroup cannot appear inside a with-warp-specialization role block — it is a workgroup collective and only one role's warps reach it, so it deadlocks.  Synchronize the producer and consumer through the barrier rings (await / signal) instead; sync-warp is fine for intra-warp ordering."
          :source-location location))
      (%tlc-check-not-divergent name-str location)))


(defun %warp-spec-check-block-only (op-name mode location)
  "Endeavor 139 (decision B): inside a with-warp-specialization role block, only a :block (TMA,
   leader-issued) tile op is safe.  A synchronous (no-barrier) or :linear tile op is a WORKGROUP
   COLLECTIVE — its cooperative copy has all threads participate — so with only one role's warps
   present it deadlocks.  MODE is the resolved barrier :mode, or NIL for a synchronous op."
  (when (and *in-warp-spec-block* (not (eq mode :block)))
    (error 'crisp-compiler-error
      :message (format nil
                   "~A inside a with-warp-specialization role block must use a :block barrier — a ~A tile op is a workgroup-collective cooperative copy that deadlocks when only some warps run the block.  Stage with (make-async-barrier[-ring] :mode :block) on the producer; for the consumer's write-back use per-thread stores or a warp-scoped path (there is no :block store yet)."
                   op-name (if mode (string-downcase (symbol-name mode)) "synchronous"))
      :source-location location)))

(defun analyze-load-tile-at-expression (expr env context location)
  "Analyzer for (load-tile-at SRC TILE (ORIGIN...) &key (identity 0) transpose barrier).
   Rejects placement inside a thread-divergent conditional. If :barrier is provided
   and target is :ptx, emits semantic-nvvm-cp-async-tile-copy. Otherwise, delegates
   codegen via %expand-load-tile-at-form."
  ;; Endeavor 139: inside a warp-spec block, %warp-spec-check-block-only (after mode resolution)
  ;; governs instead of the thread-divergent check.
  (unless *in-warp-spec-block* (%tlc-check-not-divergent "load-tile-at" location))
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
         (analyze-expression (%expand-async-load-tile-at-form expr location)
                             env context location))
        ((and barrier-form (eq mode :linear) (eq *target-backend* :spirv)
              (<= (length (fourth expr)) 2))
         ;; Endeavor 136 (Chapter 1, SPV): 1D -> one OpGroupAsyncCopy; 2D -> per-row.
         (analyze-expression (%expand-spirv-async-load-tile-at-form expr location)
                             env context location))
        (t
         (analyze-expression (%expand-load-tile-at-form expr location)
                             env context location))))))

(defun %analyze-nvvm-tma-load-tile-at (expr env context location)
  "Endeavor 137 (Chapter 1.5, Phase 2) — analyze (load-tile-at SRC TILE (ORIGIN...) :barrier BAR)
   for a NVIDIA :block barrier into a semantic-nvvm-tma-tile-copy.  Codegen emits one bulk
   cp.async.bulk.tensor copy issued by an elected leader, tracked by BAR's mbarrier.  We build
   the dest/source as aref-at-base forms so codegen can reuse the aref element-address machinery
   for the SLM tile base (addrspace 3) and the source tensor base (addrspace 1, the STAND-IN
   tensormap pointer).  The ORIGIN coords become the TMA {x,y} tile-box operands (element units)."
  (let* ((src-form     (second expr))
         (tile-form    (third expr))
         (origin-list  (fourth expr))
         (key-args     (nthcdr 4 expr))
         (barrier-form (%extract-key-arg key-args :barrier nil))
         (cl-pkg       (find-package :crisp-language))
         (aref-sym     (intern "~" cl-pkg))
         (length-sym   (intern "LENGTH~" cl-pkg))
         (to-ulong-sym (intern "TO-ULONG" cl-pkg))
         (rank         (length origin-list))
         (base-idx     (make-list rank :initial-element (list to-ulong-sym 0)))
         (dst-aref     (list* aref-sym tile-form base-idx))
         (src-aref     (list* aref-sym src-form base-idx))
         (dst-node     (analyze-expression dst-aref env context (append location '(1))))
         (src-node     (analyze-expression src-aref env context (append location '(2))))
         (coord-nodes  (loop for o in origin-list for i from 0
                             collect (analyze-expression o env context (append location (list 3 i)))))
         (barrier-node (analyze-expression barrier-form env context (append location '(4))))
         ;; tx byte count for mbarrier.arrive.expect_tx = (length~ TILE) * elem-bytes.
         (len-node     (analyze-expression (list length-sym tile-form) env context (append location '(5))))
         (elem-type    (semantic-node-type dst-node))
         (elem-bytes   (case (if (listp elem-type) (first elem-type) elem-type)
                         ((int uint float) 4)
                         ((long ulong double) 8)
                         (t (error 'crisp-compiler-error
                              :message (format nil "load-tile :block: element type ~S needs 4 or 8 bytes" elem-type)
                              :source-location location)))))
    ;; Endeavor 140 (warp-spec leader): tag the copy node when it is analyzed inside a
    ;; with-warp-specialization role block, so codegen elects laneid==0 of the producer warp
    ;; (not global tid==0) — making consumer-first warp specialization first-class and removing
    ;; the producer-first ordering constraint.
    (let ((node (make-semantic-nvvm-tma-tile-copy
                 :dst-aref-node dst-node
                 :src-aref-node src-node
                 :coord-nodes coord-nodes
                 :barrier-node barrier-node
                 :tile-length-node len-node
                 :elem-bytes elem-bytes
                 :src-name (and (symbolp src-form) src-form)
                 :type 'nil
                 :source-location location)))
      (when *in-warp-spec-block*
        (setf (gethash node *tma-copy-ws-leader*) t))
      node)))

(defun %expand-spirv-async-load-tile-at-form (expr location)
  "Endeavor 136 (Chapter 1, SPV) — async load-tile-at via OpGroupAsyncCopy.
   Rank 1: one collective (%spirv-async-copy <tile[0]> <src[ORIGIN]> <tile-length> BAR)
   of the whole contiguous run.  Rank 2 (M x N tile from a strided source): a runtime
   (dotimes (r M) (%spirv-async-copy <tile[r,0]> <src[ORIGIN0+r,ORIGIN1]> N BAR)) — one
   OpGroupAsyncCopy PER ROW, each copying N contiguous elements, its event chained
   through the barrier's spirv.Event slot.  The matching await lowers to OpGroupWaitEvents."
  (let* ((src-form (second expr))
         (tile-form (third expr))
         (origin-list (fourth expr))
         (key-args (nthcdr 4 expr))
         (barrier-form (%extract-key-arg key-args :barrier nil))
         (rank (length origin-list))
         (cl-pkg (find-package :crisp-language))
         (let-sym (intern "LET" cl-pkg))
         (aref-sym (intern "~" cl-pkg))
         (length-tilde-sym (intern "LENGTH~" cl-pkg))
         (extents-tilde-sym (intern "EXTENTS~" cl-pkg))
         (dotimes-sym (intern "DOTIMES" cl-pkg))
         (plus-sym (intern "+" cl-pkg))
         (to-int-sym (intern "TO-INT" cl-pkg))
         (to-ulong-sym (intern "TO-ULONG" cl-pkg))
         (copy-sym (intern "%SPIRV-ASYNC-COPY" cl-pkg))
         (src-sym (gensym "SRC"))
         (tile-sym (gensym "TILE")))
    (ecase rank
      (1
       (list let-sym (list (list src-sym src-form)
                           (list tile-sym tile-form))
             (list copy-sym
                   (list aref-sym tile-sym (list to-ulong-sym 0))               ;; dest run start (as3)
                   (list aref-sym src-sym (list to-ulong-sym (first origin-list))) ;; source run start (as1)
                   (list length-tilde-sym tile-sym)                             ;; element count
                   barrier-form)))
      (2
       (let ((nrows-sym  (gensym "NROWS"))
             (rowlen-sym (gensym "ROWLEN"))
             (r-sym      (gensym "R"))
             (origin0    (first origin-list))
             (origin1    (second origin-list)))
         (list let-sym
               (list (list src-sym src-form)
                     (list tile-sym tile-form)
                     ;; M rows (dotimes bound = int); N contiguous elements per row.
                     (list nrows-sym  (list to-int-sym (list aref-sym (list extents-tilde-sym tile-sym) 0)))
                     (list rowlen-sym (list aref-sym (list extents-tilde-sym tile-sym) 1)))
               (list dotimes-sym (list r-sym nrows-sym)
                     (list copy-sym
                           ;; dest: contiguous tile row r start
                           (list aref-sym tile-sym (list to-ulong-sym r-sym) (list to-ulong-sym 0))
                           ;; source: strided row (ORIGIN0 + r, ORIGIN1)
                           (list aref-sym src-sym
                                 (list plus-sym (list to-ulong-sym origin0) (list to-ulong-sym r-sym))
                                 (list to-ulong-sym origin1))
                           rowlen-sym
                           barrier-form))))))))

(defun analyze-%spirv-async-copy-expression (expr env context location)
  "Analyzer for (%spirv-async-copy <dst-aref> <src-aref> <num> BARRIER) — one collective
   OpGroupAsyncCopy.  dst/src are aref forms (codegen reuses their element-address 3rd
   value); num is the element count; BARRIER carries the chained spirv.Event slot."
  (let* ((dst-node (analyze-expression (second expr) env context (append location '(1))))
         (src-node (analyze-expression (third expr) env context (append location '(2))))
         (num-node (analyze-expression (fourth expr) env context (append location '(3))))
         (barrier-node (analyze-expression (fifth expr) env context (append location '(4))))
         (elem-type (semantic-node-type dst-node)))
    (make-semantic-spirv-async-copy
     :dst-aref-node dst-node
     :src-aref-node src-node
     :num-node num-node
     :elem-type (if (listp elem-type) (first elem-type) elem-type)
     :barrier-node barrier-node
     :type 'nil
     :source-location location)))

(defun analyze-%cp-async-copy-elem-expression (expr env context location)
  "Analyzer for (%cp-async-copy-elem <dst-aref> <src-aref>) — one non-blocking cp.async of a
   single element, dst (SLM) <- src (global).  Both operands are aref forms; codegen grabs
   each element's address (the aref's 3rd return value) and emits cp.async.ca.shared.global."
  (let* ((dst-node (analyze-expression (second expr) env context (append location '(1))))
         (src-node (analyze-expression (third expr) env context (append location '(2))))
         (elem-type (semantic-node-type dst-node))
         (elem-bytes (case (if (listp elem-type) (first elem-type) elem-type)
                       ((int uint float) 4)
                       ((long ulong double) 8)
                       (t (error 'crisp-compiler-error
                            :message (format nil "%cp-async-copy-elem: element type ~S needs 4 or 8 bytes" elem-type)
                            :source-location location)))))
    (make-semantic-cp-async-copy-elem
     :dst-aref-node dst-node
     :src-aref-node src-node
     :elem-bytes elem-bytes
     :type 'nil
     :source-location location)))

(defun analyze-%cp-async-commit-expression (expr env context location)
  "Analyzer for (%cp-async-commit) — emits cp.async.commit_group."
  (declare (ignore env context))
  (unless (= (length expr) 1)
    (error 'crisp-compiler-error :message "%cp-async-commit: takes no arguments"
      :source-location location))
  (make-semantic-cp-async-commit :type 'nil :source-location location))


(defun analyze-store-tile-at-expression (expr env context location)
  "Analyzer for (store-tile-at TILE DEST (ORIGIN...) &key transformF transpose).
   Rejects placement inside a thread-divergent conditional, then delegates
   codegen via %expand-store-tile-at-form."
  (let ((key-args (nthcdr 4 expr)))
    (when (and (getf key-args :barrier) (getf key-args :transformF))
          (error 'crisp-compiler-error :message "Cannot use :barrier and :transformF together" :source-location location))
    (unless *in-warp-spec-block* (%tlc-check-not-divergent "store-tile-at" location))
    ;; Endeavor 139 (decision B): a store-tile in a role block is a workgroup-collective cooperative
    ;; store (there is no :block store path) — resolve its mode for the message and reject.
    (%warp-spec-check-block-only "store-tile"
                                 (let ((b (%extract-key-arg key-args :barrier nil)))
                                   (and b (async-barrier-mode-of b)))
                                 location))
  (analyze-expression (%expand-store-tile-at-form expr location)
                      env context location))

(defun analyze-await-expression (expr env context location)
  "Emits semantic-nvvm-cp-async-wait on :ptx; no-op fallback elsewhere.
   Endeavor 139: for a warp-spec ring (has :initial-state) the :phase is
   (initial-phase ring-count) so codegen can inject the multi-lap flipping parity."
  (unless (= (length expr) 2)
    (error 'crisp-compiler-error
      :message (format nil "await: expected (await BARRIER), got ~S" expr)
      :source-location location))
  (let ((barrier-node (analyze-expression (second expr) env context (append location '(1))))
        (mode (async-barrier-mode-of (second expr))))
    (cond
      ((and (eq mode :block) (eq *target-backend* :ptx))
       (make-semantic-nvvm-tma-wait
        :barrier-node barrier-node
        :load-count (barrier-load-count-of (second expr))
        ;; Endeavor 139: a warp-spec ring -> (initial-phase ring-count) for the flipping await;
        ;; a plain 138 ring -> NIL (re-init await).
        :phase (let ((ip (barrier-initial-phase-of (second expr))))
                 (when ip (list ip (barrier-ring-count-of (second expr)))))
        :type 'ulong
        :source-location location))
      ((eq mode :block)
       (analyze-expression nil env context location))
      ((eq *target-backend* :ptx)
       (make-semantic-nvvm-cp-async-wait
        :barrier-node barrier-node
        :group-count (* (1- (barrier-ring-count-of (second expr)))
                        (barrier-load-count-of (second expr)))
        :type 'ulong
        :source-location location))
      ((eq *target-backend* :spirv)
       (make-semantic-spirv-group-wait
        :barrier-node barrier-node
        :type 'ulong
        :source-location location))
      (t
       (analyze-expression nil env context location)))))

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

    ;; Calculate uniformity state of the condition
    (let ((cond-uniformity (calculate-uniformity-state cond-node env)))

      ;; Phase 1d: both branches will be analyzed → runtime divergence.  Bind
      ;; *in-divergent-conditional* to T for the branch analyses so that any
      ;; load-tile-at / store-tile-at inside either branch is rejected.
      ;;
      ;; Endeavor 138: ...but ONLY when the condition can actually diverge.  A
      ;; workgroup-UNIFORM condition takes every thread down the same branch, so an internal
      ;; sync-workgroup cannot deadlock and the tile op is safe.  We already compute
      ;; COND-UNIFORMITY and already trust it for *divergent-scope-depth* (right below); using
      ;; it here too is what makes this check's own advice ("use a non-divergent condition")
      ;; actually achievable — previously a uniform guard was rejected identically, which made
      ;; the guarded prefetch of a pipelined ring loop (`(when (< next-k n-k-steps) ...)`,
      ;; uniform in the K-loop counter) impossible to express.
      (let* ((*in-divergent-conditional* (if (eq cond-uniformity :uniform)
                                             *in-divergent-conditional*
                                             t))
             (*divergent-scope-depth* (if (not (eq cond-uniformity :uniform))
                                          (1+ *divergent-scope-depth*)
                                          *divergent-scope-depth*))
             (then-node (analyze-expression (third expr) env context (append location '(2))))
             (else-node (if (fourth expr) (analyze-expression (fourth expr) env context (append location '(3))) nil)))

      (multiple-value-bind (unified-type final-then final-else)
          (ensure-branch-compatibility then-node else-node location)

        (make-semantic-if :type unified-type
                          :condition-node cond-node
                          :then-node final-then
                          :else-node final-else
                          :source-location location))))))

(defun analyze-if-expression (expr env context location)
  (analyze-if-expression-impl expr env context location :enforce-constant nil))

(defun analyze-if+-expression (expr env context location)
  "Strictly checks that the condition is workgroup-uniform at compile time.
   If unknown, prompts for a declare uniform."
  (let* ((raw-cond-node (analyze-expression (second expr) env context (append location '(1))))
         (cond-node (try-constant-fold raw-cond-node))
         (cond-uniformity (calculate-uniformity-state cond-node env)))
    (unless (eq cond-uniformity :uniform)
      (error 'crisp-compiler-error
        :message (format nil "if+ requires a provably uniform condition. Condition was inferred as ~a. If you are certain it is uniform, use (declare (uniform ...)) or (let ((u (to-workgroup-uniform ...))) ...) to assert uniformity." cond-uniformity)
        :source-location location))
    ;; Condition is proven uniform. Hand off to uniform-if-impl which does NOT increment scope depth.
    (analyze-%uniform-if-impl expr env context location)))

(defun analyze-static-if-expression (expr env context location)
  (analyze-if-expression-impl expr env context location :enforce-constant t))

(defun analyze-when-expression (expr env context location)
  ;; Delegate to analyze-if-expression to leverage DCE.
  ;; (when cond body...) -> (if cond (progn body...) nil)
  (let ((cond (second expr))
        (body (cons 'progn (cddr expr))))
    (analyze-if-expression `(if ,cond ,body) env context location)))

(defun analyze-when+-expression (expr env context location)
  (let ((cond (second expr))
        (body (cons 'progn (cddr expr))))
    (analyze-if+-expression `(if+ ,cond ,body) env context location)))

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

(defun analyze-unless+-expression (expr env context location)
  (let ((cond (second expr))
        (body (cons 'progn (cddr expr))))
    (analyze-if+-expression `(if+ ,cond nil ,body) env context location)))

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
                          collect f)))
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



(defvar *to-uniform-allowed* nil
  "T only while analyzing a let-binding initializer that is itself a direct
   to-warp-uniform / to-workgroup-uniform form.")

(defun %to-uniform-form-p (form)
  "T if FORM is a direct (to-warp-uniform ...) or (to-workgroup-uniform ...)."
  (and (consp form) (symbolp (car form))
       (member (symbol-name (car form))
               '("TO-WARP-UNIFORM" "TO-WORKGROUP-UNIFORM")
               :test #'string=)))

(defun analyze-let-expression (expr env context location)
  "Analyzes a `(let ...)` expression.
   Extended (091): strips leading declare forms from the body, checks for
   (grid-level) and (workgroup-level) declarations, and enforces nesting rules.
   Extended (120): propagates each binding's uniformity from its init."
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
                                        ;; Endeavor 120 gap #4: permit to-*-uniform only when it
                                        ;; is the direct initializer of this binding.
                                        (let ((*to-uniform-allowed* (%to-uniform-form-p init-form)))
                                          (analyze-expression init-form current-env context
                                                              (append location '(1) (list i) (list (if is-flat-mvb (length binding-vars) 1)))))
                                      (when current-binding-name
                                            (setf (compiler-context-current-binding-name context) old-name)))))
                                 (init-node-types (semantic-node-type init-node))
                                 ;; Endeavor 120: uniformity of the init, computed in the
                                 ;; pre-binding environment (let* sequential scope).
                                 (init-uniformity (calculate-uniformity-state init-node current-env)))

                            (cond
                             ((= (length binding-vars) 1)
                               (let* ((var-name (first binding-vars))
                                      (var-type (get-single-value-type init-node)))
                                 (log:warn "ANALYZE-LET VAR: ~a -> Inferred Type: ~a Uniformity: ~a" var-name var-type init-uniformity)
                                 (push (cons var-name init-node) bindings-list)
                                 (setf current-env (cons (make-parameter-def :name var-name :type var-type :kind :local
                                                                             :uniformity init-uniformity)
                                                         current-env))))

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
                                         (setf current-env (cons (make-parameter-def :name var-name :type var-type :kind :local
                                                                                     :uniformity init-uniformity)
                                                                 current-env)))))
                             (t (error "Malformed let binding: ~a" binding))))))
                (values current-env (reverse bindings-list)))

            ;; Endeavor 120 gap #2/#3: apply (declare (uniform v)) hints from the
            ;; let block. Only let-bound variables are eligible (so the hint
            ;; cannot leak into an outer scope's shared parameter-def). A hint on
            ;; a provably-divergent binding is an error -- the user can always use
            ;; a plain if/when/dotimes instead, so an unsafe assertion buys
            ;; nothing.
            (let ((let-bound-names (mapcar #'car analyzed-bindings)))
              (dolist (uvar (loop for d in decl-specs
                                  when (and (consp d) (symbolp (car d))
                                            (string-equal (symbol-name (car d)) "UNIFORM"))
                                  append (rest d)))
                (cond
                 ((not (member uvar let-bound-names))
                  (log:warn "(declare (uniform ~s)) ignored: not a variable bound by this let." uvar))
                 (t
                  (let ((pd (find-variable-in-env uvar final-env)))
                    (cond
                     ((null pd)
                      (log:warn "(declare (uniform ~s)): binding not found." uvar))
                     ((eq (parameter-def-uniformity pd) :divergent)
                      (error 'crisp-compiler-error
                        :message (format nil "(declare (uniform ~a)) is invalid: ~a is provably divergent in this scope. Use a plain if/when/dotimes instead."
                                         uvar uvar)
                        :source-location location))
                     (t
                      (log:debug "Endeavor 120: (declare (uniform ~a)) -> :uniform (was ~a)"
                                 uvar (parameter-def-uniformity pd))
                      (setf (parameter-def-uniformity pd) :uniform))))))))

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

(defun analyze-with-precision-expression (expr env context location)
  "Endeavor 126 (pass 5): analyzes (with-precision (KEY) body...), KEY = fast|ieee.
   Produces a semantic-with-precision node carrying the region MODE + body nodes; its
   codegen scopes *math-precision* over just the body (respecting the --force lock).
   The region's value is the last body form's value (like progn). KEY may be written
   parenthesised — (with-precision (ieee) ...) — or bare."
  (let* ((spec  (second expr))
         (key   (if (consp spec) (first spec) spec))
         (kname (and (symbolp key) (symbol-name key)))
         (mode  (cond ((and kname (string-equal kname "FAST")) :fast)
                      ((and kname (string-equal kname "IEEE")) :ieee)
                      (t (error 'crisp-compiler-error
                           :message (format nil "with-precision: expected (fast) or (ieee), got ~a" spec)
                           :source-location location))))
         (nodes (loop for form in (cddr expr)
                      collect (analyze-expression form env context location)))
         (last-node (first (last nodes))))
    (make-semantic-with-precision
     :type (if last-node (semantic-node-type last-node) 'void)
     :mode mode
     :body nodes
     :source-location location)))


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
  (let* ((arg-node (analyze-expression (second expr) env context location))
         (raw-type (semantic-node-type arg-node))
         (arg-type (resolve-type-alias
                    (if (and (listp raw-type) (= (length raw-type) 1) (listp (first raw-type)))
                        (first raw-type)
                        raw-type)))
         ;; Expand vector/matrix sugar so we can inspect the canonical form
         (expanded (expand-storage-handle-type-specifier (resolve-type-alias arg-type)))
         ;; A type is tensor-like if it's a mangled tensor symbol, a canonical (tensor ...) list,
         ;; or if expanding it yields a (tensor ...) list (i.e. vector/matrix sugar).
         (is-tensor (let ((resolved (resolve-type-alias arg-type)))
                      (or (and (symbolp resolved)
                               (let* ((parts (unmangle-template-struct-name resolved))
                                      (base (first parts)))
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
              (n (etypecase n-raw
                   (integer n-raw)
                   (symbol (parse-integer (symbol-name n-raw))))))
         (log:info "length~~: array type ~a -> N=~a" arg-type n)
         (make-semantic-literal :value-type 'ulong
                                :value (coerce n '(unsigned-byte 64))
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
  (let* ((binding (second expr))
         (var-name (first binding))
         (limit-form (second binding))
         (stride-form (third binding)) ;; NIL when omitted
         (body-forms (cddr expr))
         ;; Analyze limit
         (limit-node (analyze-expression limit-form env context (append location '(0))))
         (limit-type (get-single-value-type limit-node))
         (limit-ct (gethash limit-type *crisp-types*)))
    ;; Validate: limit must be a registered integer type
    (unless (and limit-ct (member (crisp-type-category limit-ct)
                                  '(:signed-int :unsigned-int)))
      (error 'crisp-compiler-error
        :message (format nil "dotimes limit must be an integer type, got ~a" limit-type)
        :source-location location))
    ;; Analyze stride if provided
    ;; Analyze stride if provided
    (let ((stride-node (when stride-form
                             (analyze-expression stride-form env context (append location '(0 1))))))
      ;; Check uniformity
      (let* ((limit-uniformity (calculate-uniformity-state limit-node env))
             (stride-uniformity (if stride-node (calculate-uniformity-state stride-node env) :uniform))
             (is-divergent (or (eq limit-uniformity :divergent) (eq stride-uniformity :divergent)
                               (eq limit-uniformity :unknown) (eq stride-uniformity :unknown))))
        ;; Extend env: bind var as the limit's type, inheriting uniformity from the limit
        (let* ((body-env (cons (make-parameter-def :name var-name :type limit-type :kind :local :uniformity limit-uniformity) env))
               (*divergent-scope-depth* (if is-divergent (1+ *divergent-scope-depth*) *divergent-scope-depth*))
               (body-nodes (analyze-body-expressions body-forms body-env context (append location '(1)))))
          (make-semantic-dotimes :type 'void
                                 :var-name var-name
                                 :limit-node limit-node
                                 :stride-node stride-node
                                 :body body-nodes
                                 :source-location location))))))

(defun analyze-dotimes+-expression (expr env context location)
  "Strictly checks that the limit (and stride) are workgroup-uniform."
  (let* ((binding (second expr))
         (limit-form (second binding))
         (stride-form (third binding))
         (limit-node (analyze-expression limit-form env context (append location '(0))))
         (stride-node (when stride-form (analyze-expression stride-form env context (append location '(0 1)))))
         (limit-uniformity (calculate-uniformity-state limit-node env))
         (stride-uniformity (if stride-node (calculate-uniformity-state stride-node env) :uniform)))
    (unless (and (eq limit-uniformity :uniform) (eq stride-uniformity :uniform))
      (error 'crisp-compiler-error
        :message "dotimes+ requires provably uniform limit and stride."
        :source-location location))
    (analyze-dotimes-expression expr env context location)))


(defun analyze-while-expression (expr env context location)
  "Analyzes (while condition body...).
   Returns a semantic-while node (type void)."
  (unless (>= (length expr) 2)
    (error 'crisp-compiler-error
      :message "Malformed while: expected (while condition body...)"
      :source-location location))
  (let* ((condition-form (second expr))
         (body-forms (cddr expr))
         (condition-node (analyze-expression condition-form env context (append location '(0))))
         (condition-type (get-single-value-type condition-node))
         (condition-ct (gethash condition-type *crisp-types*)))
    (unless (and condition-ct (member (crisp-type-category condition-ct)
                                      '(:boolean :signed-int :unsigned-int)))
      (error 'crisp-compiler-error
        :message (format nil "while condition must be a boolean or integer type, got ~a" condition-type)
        :source-location location))
    (let ((body-nodes (analyze-body-expressions body-forms env context (append location '(1)))))
      (make-semantic-while :type 'void
                           :condition-node condition-node
                           :body body-nodes
                           :source-location location))))

(defun analyze-uniformity-state (expr env context location)
  (unless (= (length expr) 2)
    (error 'crisp-compiler-error :message "uniformity-state expects 1 argument" :source-location location))
  ;; Evaluate the expression for its uniformity state (compile time)
  (let* ((arg-node (analyze-expression (second expr) env context (append location '(1))))
         (state (calculate-uniformity-state arg-node env)))
    (make-semantic-literal :value-type 'keyword :value state :source-location location)))

(defun analyze-provably-uniform? (expr env context location)
  (unless (= (length expr) 2)
    (error 'crisp-compiler-error :message "provably-uniform? expects 1 argument" :source-location location))
  (let* ((arg-node (analyze-expression (second expr) env context (append location '(1))))
         (state (calculate-uniformity-state arg-node env)))
    ;; Endeavor 124 (AD issues) B: Crisp represents booleans as int (comparisons
    ;; fold to int 1/0; the if-DCE treats 0/NIL as false). Returning an int 1/0
    ;; literal — rather than a 'boolean t/NIL literal that has no LLVM type —
    ;; keeps this compile-time predicate MATERIALIZABLE, so it survives being
    ;; recomputed inside a backward kernel's forward-recompute let-binding.
    (make-semantic-literal :value-type 'int :value (if (eq state :uniform) 1 0) :source-location location)))

(defun analyze-provably-divergent? (expr env context location)
  (unless (= (length expr) 2)
    (error 'crisp-compiler-error :message "provably-divergent? expects 1 argument" :source-location location))
  (let* ((arg-node (analyze-expression (second expr) env context (append location '(1))))
         (state (calculate-uniformity-state arg-node env)))
    ;; See analyze-provably-uniform? — int 1/0 (Crisp's bool repr), not 'boolean.
    (make-semantic-literal :value-type 'int :value (if (eq state :divergent) 1 0) :source-location location)))



(defun analyze-to-workgroup-uniform (expr env context location)
  (unless *to-uniform-allowed*
    (error 'crisp-compiler-error
      :message "to-workgroup-uniform may only be used as the initializer of a let binding, e.g. (let ((u (to-workgroup-uniform ...))) ...)."
      :source-location location))
  (unless (= (length expr) 2)
    (error 'crisp-compiler-error :message "to-workgroup-uniform expects 1 argument" :source-location location))
  (let* ((val-node (let ((*to-uniform-allowed* nil))
                     (analyze-expression (second expr) env context (append location '(1)))))
         (type (get-single-value-type val-node)))
    (make-semantic-to-workgroup-uniform :type type :value-node val-node :source-location location)))

;; src/analysis/control.lisp
(defun analyze-to-warp-uniform (expr env context location)
  (unless *to-uniform-allowed*
    (error 'crisp-compiler-error
      :message "to-warp-uniform may only be used as the initializer of a let binding, e.g. (let ((u (to-warp-uniform ...))) ...)."
      :source-location location))
  (unless (= (length expr) 2)
    (error 'crisp-compiler-error :message "to-warp-uniform expects 1 argument" :source-location location))
  (let* ((val-node (let ((*to-uniform-allowed* nil))
                     (analyze-expression (second expr) env context (append location '(1)))))
         (type (get-single-value-type val-node)))
    (make-semantic-to-warp-uniform :type type :value-node val-node :source-location location)))

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
  (let ((if-sym (intern "IF" cl-pkg))
        (ge-sym (intern ">=" cl-pkg))
        (plus-sym (intern "+" cl-pkg))
        (minus-sym (intern "-" cl-pkg))
        (div-sym (intern "/" cl-pkg))
        (to-ulong-sym (intern "TO-ULONG" cl-pkg)))
    (let ((zero (list to-ulong-sym 0))
          (one (list to-ulong-sym 1)))
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
  (let* ((strict-p (keywordp (third expr)))
         (bindings (if strict-p (fourth expr) (third expr)))
         (body-forms (if strict-p (cddddr expr) (cdddr expr)))
         (tensor-form (second expr)))
    (unless (and bindings (listp bindings) (every #'symbolp bindings)
                 (>= (length bindings) 1))
      (error 'crisp-compiler-error
        :message (if strict-p
                     "Malformed tensor-stride: expected (tensor-stride TENSOR LAYOUT-TAG (BINDING ...) BODY...)"
                     "Malformed tensor-stride: expected (tensor-stride TENSOR (BINDING ...) BODY...)")
        :source-location location))
    (let* ((n (length bindings))
           (t-sym (gensym "T"))
           (gid-sym (gensym "GID"))
           (gsize-sym (gensym "GSIZE"))
           (len-sym (gensym "LEN"))
           (iters-sym (gensym "ITERS"))
           (k-sym (gensym "K"))
           (flat-sym (gensym "FLAT"))
           (extents-syms (loop for i from 0 below n collect (gensym (format nil "E~A" i))))
           (cl-pkg (find-package :crisp-language))
           (let-sym (intern "LET" cl-pkg))
           (declare-sym (intern "DECLARE" cl-pkg))
           (grid-level-sym (intern "GRID-LEVEL" cl-pkg))
           (dotimes-sym (intern "DOTIMES" cl-pkg))
           (progn-sym (intern "PROGN" cl-pkg))
           (get-gid-sym (intern "GET-GLOBAL-ID" cl-pkg))
           (get-gsize-sym (intern "GET-GLOBAL-WORK-SIZE" cl-pkg))
           (len-tilde-sym (intern "LENGTH~" cl-pkg))
           (extents-tilde (intern "EXTENTS~" cl-pkg))
           (aref-sym (intern "~" cl-pkg))
           (plus-sym (intern "+" cl-pkg))
           (mul-sym (intern "*" cl-pkg))
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
              (append (list (list t-sym tensor-form)
                            (list gid-sym (list get-gid-sym 0))
                            (list gsize-sym (list get-gsize-sym 0))
                            (list len-sym (list len-tilde-sym t-sym)))
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
  (let* ((size-forms (second expr))
         (bindings (third expr))
         (body-forms (cdddr expr))
         (n (length bindings))
         (cl-pkg (find-package :crisp-language))
         (let-sym (intern "LET" cl-pkg))
         (declare-sym (intern "DECLARE" cl-pkg))
         (grid-level-sym (intern "GRID-LEVEL" cl-pkg))
         (dotimes-sym (intern "DOTIMES" cl-pkg))
         (progn-sym (intern "PROGN" cl-pkg))
         (get-gid-sym (intern "GET-GLOBAL-ID" cl-pkg))
         (get-gsize-sym (intern "GET-GLOBAL-WORK-SIZE" cl-pkg))
         (plus-sym (intern "+" cl-pkg))
         (mul-sym (intern "*" cl-pkg))
         (to-ulong-sym (intern "TO-ULONG" cl-pkg))
         (gid-sym (gensym "GID"))
         (gsize-sym (gensym "GSIZE"))
         (len-sym (gensym "LEN"))
         (iters-sym (gensym "ITERS"))
         (k-sym (gensym "K"))
         (flat-sym (gensym "FLAT"))
         (extents-syms (loop for i from 0 below n collect (gensym (format nil "E~A" i))))
         (size-bindings (loop for esym in extents-syms
                              for form in size-forms
                              collect (list esym (list to-ulong-sym form))))
         (len-form (if (= n 1)
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
            (append (list (list gid-sym (list get-gid-sym 0))
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
  (let* ((vec-form (second expr))
         (var-name (first (third expr)))
         (body-forms (cdddr expr))
         (gid-sym (gensym "GID"))
         (gsize-sym (gensym "GSIZE"))
         (len-sym (gensym "LEN"))
         (iters-sym (gensym "ITERS"))
         (k-sym (gensym "K"))
         (cl-pkg (find-package :crisp-language))
         (let-sym (intern "LET" cl-pkg))
         (declare-sym (intern "DECLARE" cl-pkg))
         (grid-level-sym (intern "GRID-LEVEL" cl-pkg))
         (dotimes-sym (intern "DOTIMES" cl-pkg))
         (progn-sym (intern "PROGN" cl-pkg))
         (get-gid-sym (intern "GET-GLOBAL-ID" cl-pkg))
         (get-gsize-sym (intern "GET-GLOBAL-WORK-SIZE" cl-pkg))
         (len-tilde-sym (intern "LENGTH~" cl-pkg))
         (plus-sym (intern "+" cl-pkg))
         (mul-sym (intern "*" cl-pkg))
         (i-binding (list var-name
                          (list plus-sym gid-sym
                                (list mul-sym k-sym gsize-sym))))
         (inner-body (if (= (length body-forms) 1)
                         (first body-forms)
                         (cons progn-sym body-forms)))
         (inner-let (list let-sym (list i-binding) inner-body))
         (dotimes-form (list dotimes-sym (list k-sym iters-sym) inner-let))
         (iters-let (list let-sym
                          (list (list iters-sym
                                      (%build-exact-iter-count-form
                                       gid-sym gsize-sym len-sym cl-pkg)))
                          dotimes-form))
         (expansion (list let-sym
                          (list (list gid-sym (list get-gid-sym 0))
                                (list gsize-sym (list get-gsize-sym 0))
                                (list len-sym (list len-tilde-sym vec-form)))
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
  (let* ((cl-pkg (find-package :crisp-language))
         (div-sym (intern "/" cl-pkg))
         (sub-sym (intern "-" cl-pkg))
         (mul-sym (intern "*" cl-pkg))
         (n (length binding-syms))
         (ordered-bindings (if (eq ct :first)
                               (reverse binding-syms)
                               binding-syms)))
    ;; ordered-bindings[k] gets stride-syms[k] for k < N-1; last gets rem.
    ;; For N=1, no decode needed — caller handles that case separately.
    (let ((bindings nil)
          (current-flat flat-sym))
      (loop for k from 0 below (1- n)
            for bsym = (nth k ordered-bindings)
            for s = (nth k stride-syms)
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
  (let* ((cl-pkg (find-package :crisp-language))
         (mul-sym (intern "*" cl-pkg))
         (n (length extents-syms))
         (result nil))
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
    (:contiguous-last :last)
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



;;; =====================================================================
;;; Endeavor 143 — infer :tile-shape from the tile-stride form
;;;
;;; The dispatch grid for a tiled kernel is ceil(extent[k] / tile[k]) per axis, so the host
;;; needs the tile extents.  Those extents are ALREADY written in the body:
;;;
;;;     (tile-stride C (32 32) (grid-y grid-x) ...)
;;;
;;; but until now the host only learned them if the user ALSO repeated them in a declaration:
;;;
;;;     (global-size :derive-from C :strategy :strided :tile-shape (32 32))
;;;
;;; and when the declaration was missing the hoist silently emitted a 1-D occupancy grid, which
;;; under an N-D tile-stride loop serializes an axis (measured: 7.6x on BMG — see the hoist-l0
;;; overlay notes).  A survey of this repo found **59 of 61** tile-stride kernels omitting the
;;; declaration, the author's own benchmarks included.  A 59/61 miss rate is not a discipline
;;; problem, it is a bad default: the compiler was discarding information it already had.
;;;
;;; So: infer it.  The explicit :tile-shape remains available and always wins; if it DISAGREES
;;; with the body we warn rather than silently preferring one.
;;;
;;; Conservative by design — inference only fires when all of these hold:
;;;   * the tile spec is a literal size-list (a :tile-tensor spec, as produced by
;;;     matrix-multiply-tile-stride, carries its extents in a tile tensor we cannot read here)
;;;   * the kernel declares :strategy :strided or :exact (the two the tile grid applies to)
;;;   * no :tile-shape is already present
;;;   * the tile-stride tensor matches :derive-from, or the scalar :derive-from list has the
;;;     same rank as the tile spec — otherwise we would be inferring a grid for a different
;;;     iteration space than the one declared
;;;
;;; Hooked into %tile-stride-parse rather than analyze-tile-stride-expression: the parser is the
;;; one place every tile-stride form funnels through, it already owns the grammar (including the
;;; optional layout tag), and it is 25 lines instead of 120.  Recording is idempotent, so being
;;; called again during codegen is harmless.

;; src/analysis/control.lisp  (new)
(defvar *kernel-inferred-tile-shapes* (make-hash-table :test #'eq)
  "Maps kernel name symbol -> the tile-shape this pass inferred from its tile-stride form.
   Lets us tell an inference/inference conflict (two tile-stride forms of different shape in
   one kernel) apart from a declaration/body conflict, so the warning can say which it is.")

;; src/analysis/control.lisp  (new)
(defun %ts-normalize-derive-from (derive)
  "Strip a (quote ...) wrapper from a :derive-from value — the docs show both
   `:derive-from (width height)` and `:derive-from '(width height)`."
  (if (and (consp derive) (symbolp (car derive))
           (string-equal (symbol-name (car derive)) "QUOTE"))
      (second derive)
      derive))

;; src/analysis/control.lisp  (new)
(defun %ts-derive-from-agrees-p (derive tensor-form tile-spec)
  "True when a tile grid built from TILE-SPEC describes the same iteration space the kernel
   declared with :derive-from.  A tensor :derive-from must name the very tensor being strided;
   a scalar list must have the same rank as the tile spec."
  (let ((d (%ts-normalize-derive-from derive)))
    (cond
     ((null d) nil)
     ((symbolp d) (and (symbolp tensor-form)
                       (string-equal (symbol-name d) (symbol-name tensor-form))))
     ((listp d) (= (length d) (length tile-spec)))
     (t nil))))

;; src/analysis/control.lisp  (new)
(defun %ts-maybe-infer-tile-shape (tensor-form tile-spec tile-spec-kind)
  "Enrich the current kernel's dispatch declaration with an inferred :tile-shape.

   Writes into *kernel-dispatch-declarations*, which is what both the metacrisp writer
   (src/metadata.lisp) and the MMA analyzers already read — so the inferred value reaches the
   hoist backends with no change to either.  Silent no-op unless every condition in the header
   comment holds."
  (when (eq tile-spec-kind :size-list)
    (let* ((ctx  *compiler-context*)
           (fn   (and ctx (compiler-context-current-compiling-function ctx)))
           (disp (and fn (gethash fn *kernel-dispatch-declarations*))))
      (when disp
        (let* ((key  (if (getf disp :global-size) :global-size :num-groups))
               (decl (getf disp key)))
          (when (consp decl)
            (let* ((opts     (cdr decl))
                   (strategy (getf opts :strategy))
                   (declared (getf opts :tile-shape))
                   (derive   (getf opts :derive-from))
                   (sname    (and strategy (symbolp strategy) (symbol-name strategy)))
                   (tiled-p  (and sname (or (string-equal sname "STRIDED")
                                            (string-equal sname "EXACT")))))
              (cond
               ((not tiled-p)
                 (log:debug "tile-shape inference: kernel ~a strategy ~a is not tiled; skipping"
                            fn strategy))
               ;; Already carries a shape — verify rather than overwrite.
               (declared
                 (unless (equal declared tile-spec)
                   (if (equal (gethash fn *kernel-inferred-tile-shapes*) declared)
                       (log:warn "Kernel ~a has tile-stride forms of DIFFERENT shapes (~a and ~a).  :tile-shape was inferred as ~a; declare it explicitly to choose."
                                 fn declared tile-spec declared)
                       (log:warn "Kernel ~a declares :tile-shape ~a but its tile-stride form uses ~a.  The declaration wins; one of them is wrong."
                                 fn declared tile-spec))))
               ((not (%ts-derive-from-agrees-p derive tensor-form tile-spec))
                 (log:debug "tile-shape inference: kernel ~a :derive-from ~a does not agree with  tile-stride over ~a ~a; skipping"
                            fn derive tensor-form tile-spec))
               (t
                 (let ((new-decl (append decl (list :tile-shape tile-spec))))
                   (setf (gethash fn *kernel-inferred-tile-shapes*) tile-spec)
                   (setf (gethash fn *kernel-dispatch-declarations*)
                         (let ((copy (copy-list disp)))
                           (setf (getf copy key) new-decl)
                           copy))
                   (log:info "Kernel ~a: inferred :tile-shape ~a from its tile-stride form  (no explicit declaration)."
                             fn tile-spec)))))))))))



(defun %tile-stride-parse (expr)
  "Returns (values strict-p layout-tag tile-spec tile-spec-kind bindings body-forms tensor-form)
   for a tile-stride EXPR.  TILE-SPEC-KIND is one of :size-list or :tile-tensor.
   Form-shape validation only — does not check arity vs tensor.

   Endeavor 143: also infers :tile-shape into the kernel's dispatch declaration when the user
   did not write one (see %ts-maybe-infer-tile-shape).  Parsing is unchanged."
  (let* ((tensor-form (second expr))
         (third (third expr))
         (strict-p (keywordp third))
         (layout-tag (when strict-p third))
         (tile-pos (if strict-p 3 2))
         (tile-spec (nth tile-pos expr))
         (bind-pos (1+ tile-pos))
         (bindings (nth bind-pos expr))
         (body-forms (nthcdr (1+ bind-pos) expr))
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
    (ignore-errors (%ts-maybe-infer-tile-shape tensor-form tile-spec tile-spec-kind))
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
         (size-expr-fn (lambda (k) (list get-local-size-sym k))))
    (%expand-workgroup-strided-outer-loop-with-ts-syms
     tensor-form n bindings body-forms ts-syms size-expr-fn location)))


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
  (let* ((cl-pkg (find-package :crisp-language))
         (let-sym (intern "LET" cl-pkg))
         (declare-sym (intern "DECLARE" cl-pkg))
         (grid-level-sym (intern "GRID-LEVEL" cl-pkg))
         (dotimes-sym (intern "DOTIMES" cl-pkg))
         (progn-sym (intern "PROGN" cl-pkg))
         (to-ulong-sym (intern "TO-ULONG" cl-pkg))
         (len-tilde-sym (intern "LENGTH~" cl-pkg))
         (get-glid-sym (intern "GET-GLOBAL-LINEAR-ID" cl-pkg))
         (get-glsize-sym (intern "GET-GLOBAL-LINEAR-SIZE" cl-pkg))
         (plus-sym (intern "+" cl-pkg))
         (mul-sym (intern "*" cl-pkg))
         (div-sym (intern "/" cl-pkg))
         (t-sym (gensym "T"))
         (ws-sym (gensym "WSIZE"))
         (len-sym (gensym "LEN"))
         (glid-sym (gensym "GLID"))
         (glsize-sym (gensym "GLSIZE"))
         (mywarp-sym (gensym "MYWARP"))
         (numwarps-sym (gensym "NUMWARPS"))
         (start-sym (gensym "WSTART"))
         (stride-sym (gensym "WSTRIDE"))
         (iters-sym (gensym "ITERS"))
         (k-sym (gensym "K"))
         (var-name (first bindings))
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
                          (list (list t-sym tensor-form)
                                (list ws-sym (list to-ulong-sym 32))
                                (list len-sym (list len-tilde-sym t-sym))
                                (list glid-sym (list get-glid-sym))
                                (list glsize-sym (list get-glsize-sym))
                                (list mywarp-sym (list div-sym glid-sym ws-sym))
                                (list numwarps-sym (list div-sym glsize-sym ws-sym))
                                (list start-sym (list mul-sym mywarp-sym ws-sym))
                                (list stride-sym (list mul-sym ws-sym numwarps-sym)))
                          (list declare-sym (list grid-level-sym))
                          iters-let)))
    outer-let))



(defun %expand-tile-stride-swizzled (tensor-form bindings body-forms ts-syms
                                     tile-size-expr-fn strip-width location)
  "Endeavor 144 Phase 1: the GROUPED (column-strip) rank-2 tile-stride expansion.

   Replaces the per-axis nest with ONE grid-strided loop over the flat tile index, then
   delinearizes through a STRIP-WIDTH-wide column strip.  See the header block for the mapping
   and its bijectivity argument; because the map is a bijection over [0, nt_rows*nt_cols) and
   the loop grid-strides that flat range, coverage is exactly preserved for ANY grid size —
   including an oversubscribed or under-dispatched one, where a naive 'swizzle the per-axis
   start' would double-visit or miss tiles."
  (declare (ignore location))
  (let* ((cl-pkg (find-package :crisp-language))
         (let-sym      (intern "LET" cl-pkg))
         (declare-sym  (intern "DECLARE" cl-pkg))
         (wg-level-sym (intern "WORKGROUP-LEVEL" cl-pkg))
         (dotimes-sym  (intern "DOTIMES" cl-pkg))
         (progn-sym    (intern "PROGN" cl-pkg))
         (aref-sym     (intern "~" cl-pkg))
         (extents-sym  (intern "EXTENTS~" cl-pkg))
         (wgid-sym     (intern "GET-WORKGROUP-ID" cl-pkg))
         (numgrp-sym   (intern "GET-NUM-GROUPS" cl-pkg))
         (to-ulong-sym (intern "TO-ULONG" cl-pkg))
         (if-sym       (intern "IF" cl-pkg))
         (lt-sym       (intern "<" cl-pkg))
         (plus-sym     (intern "+" cl-pkg))
         (minus-sym    (intern "-" cl-pkg))
         (mul-sym      (intern "*" cl-pkg))
         (div-sym      (intern "/" cl-pkg))
         (rem-sym      (intern "REM" cl-pkg))
         (t-sym    (gensym "TSW"))
         (e0 (gensym "E0")) (e1 (gensym "E1"))
         (nt0 (gensym "NT0")) (nt1 (gensym "NT1"))
         (total (gensym "TOTAL")) (lwg (gensym "LWG")) (nwg (gensym "NWG"))
         (iters (gensym "ITERS")) (k (gensym "K")) (tid (gensym "TID"))
         (wsym (gensym "W")) (tpg (gensym "TPG"))
         (grp (gensym "GRP")) (idg (gensym "IDG"))
         (fc (gensym "FC")) (gc (gensym "GC"))
         (row-sym (first bindings)) (col-sym (second bindings))
         (ts0 (first ts-syms)) (ts1 (second ts-syms))
         (inner-body (if (= (length body-forms) 1)
                         (first body-forms)
                         (cons progn-sym body-forms))))
    (list let-sym
          (list
           (list t-sym tensor-form)
           (list ts0 (funcall tile-size-expr-fn 0))
           (list ts1 (funcall tile-size-expr-fn 1))
           (list e0 (list aref-sym (list extents-sym t-sym) 0))
           (list e1 (list aref-sym (list extents-sym t-sym) 1))
           ;; nt_i = ceil(e_i / ts_i) — tile ROWS and tile COLS of the output
           (list nt0 (list div-sym (list plus-sym e0 (list minus-sym ts0 (list to-ulong-sym 1))) ts0))
           (list nt1 (list div-sym (list plus-sym e1 (list minus-sym ts1 (list to-ulong-sym 1))) ts1))
           (list total (list mul-sym nt0 nt1))
           ;; Flatten the workgroup id and the grid, so one loop grid-strides the flat tile range.
           (list lwg (list plus-sym
                           (list mul-sym (list wgid-sym 1) (list numgrp-sym 0))
                           (list wgid-sym 0)))
           (list nwg (list mul-sym (list numgrp-sym 0) (list numgrp-sym 1)))
           (list iters (%build-exact-iter-count-form lwg nwg total cl-pkg)))
          (list declare-sym (list wg-level-sym))
          (list dotimes-sym (list k iters)
                (list let-sym (list (list tid (list plus-sym lwg (list mul-sym k nwg)))
                                    (list wsym (list to-ulong-sym strip-width)))
                      (list let-sym (list (list tpg (list mul-sym wsym nt0)))
                            (list let-sym (list (list grp (list div-sym tid tpg))
                                                (list idg (list rem-sym tid tpg)))
                                  (list let-sym (list (list fc (list mul-sym grp wsym)))
                                        ;; gc = min(W, nt1 - fc): the final strip may be narrower.
                                        (list let-sym
                                              (list (list gc (list if-sym
                                                                   (list lt-sym (list minus-sym nt1 fc) wsym)
                                                                   (list minus-sym nt1 fc)
                                                                   wsym)))
                                              (list let-sym
                                                    (list (list row-sym (list div-sym idg gc))
                                                          (list col-sym (list plus-sym fc (list rem-sym idg gc))))
                                                    inner-body))))))))))

(defun %expand-tile-stride-form (expr ct location)
  "Pure expansion of (tile-stride T [LAYOUT-TAG] <TILE-SPEC> (BINDINGS) BODY...).
   Outer loop over tile origins, workgroup-strided.  Phase 1b: pre-walks the
   body to rewrite bare load-tile / store-tile into their -coords forms using
   the tile-stride's binding syms as the origin.

   Endeavor 144 Phase 1: when the visit order should be GROUPED (rank 2, compile-time tile
   size-list, an active profile with :l2-cache-size — see %tile-visit-strip-width), emit the
   L2-aware column-strip walk instead.  Everything else takes the original linear expansion
   completely unchanged."
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
           (to-ulong-sym (intern "TO-ULONG" cl-pkg))
           (aref-sym (intern "~" cl-pkg))
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
           (strip-width (%tile-visit-log-decision
                         n tile-spec-kind tile-spec
                         (%tile-visit-strip-width
                          n (when (eq tile-spec-kind :size-list) tile-spec)))))
      (if (> strip-width 1)
          (%expand-tile-stride-swizzled tensor-form bindings body-forms ts-syms
                                        tile-size-expr-fn strip-width location)
          (%expand-workgroup-strided-outer-loop-with-ts-syms
           tensor-form n bindings body-forms ts-syms tile-size-expr-fn location)))))

;; src/analysis/control.lisp
;; Endeavor 144 Phase 1 — visibility on the visit-order decision.  Logged (log4cl, so it
;; costs nothing at --log-level=off) because "did the swizzle actually engage?" is otherwise
;; invisible: the choice leaves no trace in the kernel source and only a subtle one in the IR.
;; src/analysis/control.lisp
(defun %tile-visit-log-decision (n tile-spec-kind tile-spec strip-width)
  "Report the tile visit-order decision for one tile-stride expansion."
  (log:info "tile-visit: rank=~a spec-kind=~a spec=~a -> strip-width=~a (~a)"
            n tile-spec-kind tile-spec strip-width
            (if (> strip-width 1) "GROUPED" "linear"))
  strip-width)

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
         (third (third expr))
         (strict-p (and (keywordp third)
                        (member third '(:row-major :col-major :contiguous-last :contiguous-first))))
         (layout-tag (when strict-p third))
         (hw-tag-pos (if strict-p 3 2))
         (hw-tag (nth hw-tag-pos expr))
         (bind-pos (1+ hw-tag-pos))
         (bindings (nth bind-pos expr))
         (body-forms (nthcdr (1+ bind-pos) expr)))
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
         (get-glid-sym (intern "GET-GLOBAL-LINEAR-ID" cl-pkg))
         (get-glsize-sym (intern "GET-GLOBAL-LINEAR-SIZE" cl-pkg))
         (len-tilde-sym (intern "LENGTH~" cl-pkg))
         (plus-sym (intern "+" cl-pkg))
         (lt-sym (intern "<" cl-pkg))
         (inner-body (if (= (length body-forms) 1)
                         (first body-forms)
                         (cons progn-sym body-forms)))
         (inner-if (list if-sym (list lt-sym var-name len-sym) inner-body))
         (inner-let (list let-sym
                          (list (list var-name (list plus-sym k-sym gid-sym)))
                          inner-if))
         (dotimes-form (list dotimes-sym
                             (list k-sym len-sym gsize-sym)
                             inner-let))
         (expansion (list let-sym
                          (list (list gid-sym (list get-glid-sym))
                                (list gsize-sym (list get-glsize-sym))
                                (list len-sym (list len-tilde-sym tensor-form)))
                          (list declare-sym (list grid-level-sym))
                          dotimes-form)))
    expansion))


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

;; Endeavor 135: binds GRID TERMS (tile-IDs), not element origins.  The bare tile forms
;; (load-tile / store-tile / position-tile) already scale a grid coord by the tile extent,
;; so an element origin would DOUBLE-SCALE (out of bounds for any multi-tile launch).  Per
;; dim: NT_i = ceil(E_i/ts_i); start_i = gid_i; stride_i = ng_i; b_i = gid_i + k_i*ng_i (a
;; TILE-ID).  Shared by tile-stride (ts = tile size) and hardware-stride :workgroup-idx
;; (ts = get-local-work-size).
(defun %expand-workgroup-strided-outer-loop-with-ts-syms
    (tensor-form n bindings body-forms ts-syms tile-size-expr-fn location)
  "Workgroup-strided outer loop over TILE-IDs.  Per-workgroup exact iter count per dim —
   body runs unconditionally, with each binding bound to a tile-ID (0-based chunk index),
   grid-strided by the number of workgroups."
  (declare (ignore location))
  (let* ((cl-pkg (find-package :crisp-language))
         (let-sym (intern "LET" cl-pkg))
         (declare-sym (intern "DECLARE" cl-pkg))
         (workgroup-level-sym (intern "WORKGROUP-LEVEL" cl-pkg))
         (dotimes-sym (intern "DOTIMES" cl-pkg))
         (progn-sym (intern "PROGN" cl-pkg))
         (aref-sym (intern "~" cl-pkg))
         (extents-tilde-sym (intern "EXTENTS~" cl-pkg))
         (get-wg-id-sym (intern "GET-WORKGROUP-ID" cl-pkg))
         (get-num-groups-sym (intern "GET-NUM-GROUPS" cl-pkg))
         (to-ulong-sym (intern "TO-ULONG" cl-pkg))
         (plus-sym (intern "+" cl-pkg))
         (minus-sym (intern "-" cl-pkg))
         (mul-sym (intern "*" cl-pkg))
         (div-sym (intern "/" cl-pkg))
         (t-sym (gensym "T"))
         (e-syms (loop for i from 0 below n collect (gensym (format nil "E~A" i))))
         (nt-syms (loop for i from 0 below n collect (gensym (format nil "NT~A" i))))
         (gid-syms (loop for i from 0 below n collect (gensym (format nil "WGID~A" i))))
         (ng-syms (loop for i from 0 below n collect (gensym (format nil "NG~A" i))))
         (start-syms (loop for i from 0 below n collect (gensym (format nil "START~A" i))))
         (stride-syms (loop for i from 0 below n collect (gensym (format nil "STRIDE~A" i))))
         (iters-syms (loop for i from 0 below n collect (gensym (format nil "ITERS~A" i))))
         (k-syms (loop for i from 0 below n collect (gensym (format nil "K~A" i))))
         (inner-body (if (= (length body-forms) 1)
                         (first body-forms)
                         (cons progn-sym body-forms)))
         (nest
          (let ((acc inner-body))
            (loop for i from (1- n) downto 0
                  for b-sym = (nth i bindings)
                  for start-sym = (nth i start-syms)
                  for stride-sym = (nth i stride-syms)
                  for iters-sym = (nth i iters-syms)
                  for k-sym = (nth i k-syms)
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
            ;; ts_i  = chunk size (tile size / local-work-size, from caller)
            (loop for i from 0 below n
                  for ts-sym in ts-syms
                  collect (list ts-sym (funcall tile-size-expr-fn i)))
            ;; e_i   = extents[i]
            (loop for i from 0 below n
                  for e-sym in e-syms
                  collect (list e-sym (list aref-sym (list extents-tilde-sym t-sym) i)))
            ;; nt_i  = ceil(e_i / ts_i) = (e_i + ts_i - 1) / ts_i   (number of tiles)
            (loop for i from 0 below n
                  for nt-sym in nt-syms
                  for e-sym in e-syms
                  for ts-sym in ts-syms
                  collect (list nt-sym
                                (list div-sym
                                      (list plus-sym e-sym
                                            (list minus-sym ts-sym (list to-ulong-sym 1)))
                                      ts-sym)))
            ;; gid_i = get-workgroup-id i
            (loop for i from 0 below n
                  for gid-sym in gid-syms
                  collect (list gid-sym (list get-wg-id-sym i)))
            ;; ng_i  = get-num-groups i
            (loop for i from 0 below n
                  for ng-sym in ng-syms
                  collect (list ng-sym (list get-num-groups-sym i)))
            ;; start_i  = gid_i           (this WG's first tile-id)
            (loop for i from 0 below n
                  for start-sym in start-syms
                  for gid-sym in gid-syms
                  collect (list start-sym gid-sym))
            ;; stride_i = ng_i            (grid-stride in tile units)
            (loop for i from 0 below n
                  for stride-sym in stride-syms
                  for ng-sym in ng-syms
                  collect (list stride-sym ng-sym))
            ;; iters_i  = exact count over the TILE count nt_i
            (loop for i from 0 below n
                  for iters-sym in iters-syms
                  for start-sym in start-syms
                  for stride-sym in stride-syms
                  for nt-sym in nt-syms
                  collect (list iters-sym
                                (%build-exact-iter-count-form
                                 start-sym stride-sym nt-sym cl-pkg))))))
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
;; (sync-workgroup) explicitly when needed.

(defun %workgroup-stride-parse (expr)
  "Returns (values bindings body-forms tensor-form) for a workgroup-stride EXPR.
   Form-shape validation only — does not check tensor arity vs bindings arity."
  (let* ((tensor-form (second expr))
         (bindings (third expr))
         (body-forms (cdddr expr)))
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
;; (sync-workgroup) explicitly when needed.

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
           (cl-pkg (find-package :crisp-language))
           (let-sym (intern "LET" cl-pkg))
           (dotimes-sym (intern "DOTIMES" cl-pkg))
           (progn-sym (intern "PROGN" cl-pkg))
           (aref-sym (intern "~" cl-pkg))
           (extents-tilde-sym (intern "EXTENTS~" cl-pkg))
           (get-local-id-sym (intern "GET-LOCAL-ID" cl-pkg))
           (get-lws-sym (intern "GET-LOCAL-WORK-SIZE" cl-pkg))
           (plus-sym (intern "+" cl-pkg))
           (mul-sym (intern "*" cl-pkg))
           (t-sym (gensym "T"))
           (e-syms (loop for i from 0 below n collect (gensym (format nil "E~A" i))))
           (lid-syms (loop for i from 0 below n collect (gensym (format nil "LID~A" i))))
           (lws-syms (loop for i from 0 below n collect (gensym (format nil "LWS~A" i))))
           (iters-syms (loop for i from 0 below n collect (gensym (format nil "ITERS~A" i))))
           (k-syms (loop for i from 0 below n collect (gensym (format nil "K~A" i))))
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
                    for b-sym = (nth i bindings)
                    for lid-sym = (nth i lid-syms)
                    for lws-sym = (nth i lws-syms)
                    for k-sym = (nth i k-syms)
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
                    for lid-sym in lid-syms
                    for lws-sym in lws-syms
                    for e-sym in e-syms
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


(defun %expand-load-tile-at-bwd-form (expr location)
  "Pure expansion of (%load-tile-at-bwd SRC-ADJ TILE-ADJ (ORIGIN...) &key transpose).
   Cooperative scatter-add via atomic-add!."
  (let* ((src-adj-form (second expr))
         (tile-adj-form (third expr))
         (origin-list (fourth expr))
         (key-args (nthcdr 4 expr)))
    (unless (and (listp origin-list) (>= (length origin-list) 1))
      (error 'crisp-compiler-error
        :message "%load-tile-at-bwd: origin must be a non-empty list of coord forms"
        :source-location location))
    (let* ((transpose-form (%extract-key-arg key-args :transpose nil))
           (n (length origin-list))
           (perm (%tlc-transpose-permutation n transpose-form location))
           (cl-pkg (find-package :crisp-language))
           (let-sym (intern "LET" cl-pkg))
           (progn-sym (intern "PROGN" cl-pkg))
           (when-sym (intern "WHEN" cl-pkg))
           (aref-sym (intern "~" cl-pkg))
           (extents-tilde-sym (intern "EXTENTS~" cl-pkg))
           (get-local-id-sym (intern "GET-LOCAL-ID" cl-pkg))
           (get-lws-sym (intern "GET-LOCAL-WORK-SIZE" cl-pkg))
           (sync-workgroup-sym (intern "SYNC-WORKGROUP" cl-pkg))
           (to-ulong-sym (intern "TO-ULONG" cl-pkg))
           (plus-sym (intern "+" cl-pkg))
           (lt-sym (intern "<" cl-pkg))
           (and-sym (intern "AND" cl-pkg))
           (atomic-add-sym (intern "ATOMIC-ADD!" cl-pkg))
           (src-adj-sym (gensym "SRC-ADJ"))
           (tile-adj-sym (gensym "TILE-ADJ"))
           (origin-syms (loop for i from 0 below n collect (gensym (format nil "ORIG~A" i))))
           (tile-coord-syms (loop for i from 0 below n collect (gensym (format nil "TLC~A" i))))
           (tile-extent-syms (loop for i from 0 below n collect (gensym (format nil "TE~A" i))))
           (global-extent-syms (loop for i from 0 below n collect (gensym (format nil "GE~A" i))))
           (lid-syms (loop for i from 0 below n collect (gensym (format nil "LID~A" i))))
           (lws-syms (loop for i from 0 below n collect (gensym (format nil "LWS~A" i))))
           (src-coord-exprs (%tlc-source-coord-exprs n origin-syms tile-coord-syms perm plus-sym))
           (tile-aref (cons aref-sym (cons tile-adj-sym tile-coord-syms)))
           (src-aref (cons aref-sym (cons src-adj-sym src-coord-exprs)))
           (bounds-form (%tlc-all-in-bounds-form n src-coord-exprs
                                                 global-extent-syms lt-sym and-sym))
           ;; Inner body: scatter-add tile_adj[lc] into src_adj[orig+lc] via atomic-add!.
           ;; Skip silently when out of bounds (no contribution).
           (inner-body (list when-sym
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
                  (list sync-workgroup-sym))))))


(defun %expand-store-tile-at-bwd-form (expr location)
  "Pure expansion of (%store-tile-at-bwd TILE-ADJ DEST-ADJ (ORIGIN...) &key transpose).
   Cooperative non-atomic accumulate into local tile_adj.  Barriers before
   and after so prior tile_adj writes are visible and subsequent ones see
   the result."
  (let* ((tile-adj-form (second expr))
         (dest-adj-form (third expr))
         (origin-list (fourth expr))
         (key-args (nthcdr 4 expr)))
    (unless (and (listp origin-list) (>= (length origin-list) 1))
      (error 'crisp-compiler-error
        :message "%store-tile-at-bwd: origin must be a non-empty list of coord forms"
        :source-location location))
    (let* ((transpose-form (%extract-key-arg key-args :transpose nil))
           (n (length origin-list))
           (perm (%tlc-transpose-permutation n transpose-form location))
           (cl-pkg (find-package :crisp-language))
           (let-sym (intern "LET" cl-pkg))
           (progn-sym (intern "PROGN" cl-pkg))
           (when-sym (intern "WHEN" cl-pkg))
           (set-sym (intern "SET!" cl-pkg))
           (aref-sym (intern "~" cl-pkg))
           (extents-tilde-sym (intern "EXTENTS~" cl-pkg))
           (get-local-id-sym (intern "GET-LOCAL-ID" cl-pkg))
           (get-lws-sym (intern "GET-LOCAL-WORK-SIZE" cl-pkg))
           (sync-workgroup-sym (intern "SYNC-WORKGROUP" cl-pkg))
           (to-ulong-sym (intern "TO-ULONG" cl-pkg))
           (plus-sym (intern "+" cl-pkg))
           (lt-sym (intern "<" cl-pkg))
           (and-sym (intern "AND" cl-pkg))
           (tile-adj-sym (gensym "TILE-ADJ"))
           (dest-adj-sym (gensym "DEST-ADJ"))
           (origin-syms (loop for i from 0 below n collect (gensym (format nil "ORIG~A" i))))
           (tile-coord-syms (loop for i from 0 below n collect (gensym (format nil "TLC~A" i))))
           (tile-extent-syms (loop for i from 0 below n collect (gensym (format nil "TE~A" i))))
           (global-extent-syms (loop for i from 0 below n collect (gensym (format nil "GE~A" i))))
           (lid-syms (loop for i from 0 below n collect (gensym (format nil "LID~A" i))))
           (lws-syms (loop for i from 0 below n collect (gensym (format nil "LWS~A" i))))
           (dest-coord-exprs (%tlc-source-coord-exprs n origin-syms tile-coord-syms perm plus-sym))
           (tile-aref (cons aref-sym (cons tile-adj-sym tile-coord-syms)))
           (dest-aref (cons aref-sym (cons dest-adj-sym dest-coord-exprs)))
           (bounds-form (%tlc-all-in-bounds-form n dest-coord-exprs
                                                 global-extent-syms lt-sym and-sym))
           ;; tile_adj[lc] += dest_adj[orig+lc].  No atomic — each tile slot
           ;; is written by exactly one thread in the workgroup-cooperative loop.
           (acc-form (list plus-sym tile-aref dest-aref))
           (inner-body (list when-sym
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
                  (list sync-workgroup-sym)
                  loop-nest
                  (list sync-workgroup-sym))))))


(defun analyze-%load-tile-at-bwd-expression (expr env context location)
  "Analyzer for compiler-internal %load-tile-at-bwd."
  (analyze-expression (%expand-load-tile-at-bwd-form expr location)
                      env context location))


(defun analyze-%store-tile-at-bwd-expression (expr env context location)
  "Analyzer for compiler-internal %store-tile-at-bwd."
  (analyze-expression (%expand-store-tile-at-bwd-form expr location)
                      env context location))


(defun %rewrite-bare-tile-in-form (form origin-binding-syms cl-pkg)
  (cond
   ((atom form) form)
   ((not (and (consp form) (symbolp (car form))))
     (mapcar (lambda (sub) (%rewrite-bare-tile-in-form sub origin-binding-syms cl-pkg))
         form))
   (t
     (let ((op-name (symbol-name (car form))))
       (cond
        ((or (string-equal op-name "LOAD-TILE")
             (string-equal op-name "REQUEST-LOAD-TILE"))
          (if (>= (length form) 4)
              (cons (car form) (mapcar (lambda (sub) (%rewrite-bare-tile-in-form sub origin-binding-syms cl-pkg)) (cdr form)))
              (let ((sym (car form))
                    (src (second form))
                    (tile (third form))
                    (key-args (nthcdr 3 form)))
                (append (list sym src tile origin-binding-syms) key-args))))
        ((or (string-equal op-name "STORE-TILE")
             (string-equal op-name "REQUEST-STORE-TILE"))
          (if (>= (length form) 4)
              (cons (car form) (mapcar (lambda (sub) (%rewrite-bare-tile-in-form sub origin-binding-syms cl-pkg)) (cdr form)))
              (let ((sym (car form))
                    (tile (second form))
                    (dest (third form))
                    (key-args (nthcdr 3 form)))
                (append (list sym tile dest origin-binding-syms) key-args))))
        (t (cons (car form)
                 (mapcar (lambda (sub) (%rewrite-bare-tile-in-form sub origin-binding-syms cl-pkg))
                     (cdr form)))))))))

(defun %rewrite-bare-load-store-tile-in-body (body-forms origin-binding-syms cl-pkg)
  (mapcar (lambda (f) (%rewrite-bare-tile-in-form f origin-binding-syms cl-pkg))
      body-forms))

(defun %detect-bare-load-store-tile-in-form (form path)
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
          (when (< (length form) 4)
                (error 'crisp-compiler-error
                  :message (format nil "~A: bare ~A is not allowed inside ~A..."
                             (string-downcase op-name) (string-downcase op-name) path)
                  :source-location nil)))
        (t
          (dolist (sub (cdr form))
            (%detect-bare-load-store-tile-in-form sub path))))))))

(defun analyze-load-tile-expression (expr env context location)
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
    (let ((pixel-coords
           (loop for g in grid-list
                 for i from 0
                 collect (list mul-sym (list (intern "TO-ULONG" cl-pkg) g)
                               (list aref-sym (list extents-sym tile) i)))))
      (analyze-load-tile-at-expression
       (append (list (intern "LOAD-TILE-AT" cl-pkg) src tile pixel-coords) key-args)
       env context location))))

(defun analyze-store-tile-expression (expr env context location)
  (let* ((tile (second expr))
         (dest (third expr))
         (grid-list (fourth expr))
         (key-args (nthcdr 4 expr))
         (cl-pkg (find-package :crisp-language))
         (mul-sym (intern "*" cl-pkg))
         (extents-sym (intern "EXTENTS~" cl-pkg))
         (aref-sym (intern "~" cl-pkg)))
    (unless (and (listp grid-list) (>= (length grid-list) 1))
      (error 'crisp-compiler-error :message "store-tile: origin must be a non-empty list of grid coords" :source-location location))
    (let ((pixel-coords
           (loop for g in grid-list
                 for i from 0
                 collect (list mul-sym (list (intern "TO-ULONG" cl-pkg) g)
                               (list aref-sym (list extents-sym tile) i)))))
      (analyze-store-tile-at-expression
       (append (list (intern "STORE-TILE-AT" cl-pkg) tile dest pixel-coords) key-args)
       env context location))))

(defun analyze-load-local-expression (expr env context location)
  "Analyzer for (load-local global-tensor scratch-tensor &key identity barrier)."
  (let* ((src (second expr))
         (dest (third expr))
         (key-args (nthcdr 3 expr))
         (src-node (analyze-expression src env context (append location '(1))))
         (src-type (semantic-node-type src-node)))
    (unless (%tensor-type-p src-type)
      (error 'crisp-compiler-error :message "load-local: source must be a tensor" :source-location location))
    (let ((num-dims (%get-tensor-arity src-type))
          (cl-pkg (find-package :crisp-language)))
      (analyze-load-tile-at-expression
       (append (list (intern "LOAD-TILE-AT" cl-pkg) src dest
                     (loop repeat num-dims collect 0))
               key-args)
       env context location))))

(defun analyze-store-global-expression (expr env context location)
  "Analyzer for (store-global scratch-tensor global-tensor &key (transformF #'identityF) barrier)."
  (let* ((src (second expr))
         (dest (third expr))
         (key-args (nthcdr 3 expr))
         (dest-node (analyze-expression dest env context (append location '(2))))
         (dest-type (semantic-node-type dest-node)))
    (unless (%tensor-type-p dest-type)
      (error 'crisp-compiler-error :message "store-global: destination must be a tensor" :source-location location))
    (let ((num-dims (%get-tensor-arity dest-type))
          (cl-pkg (find-package :crisp-language)))
      (analyze-store-tile-at-expression
       (append (list (intern "STORE-TILE-AT" cl-pkg) src dest
                     (loop repeat num-dims collect 0))
               key-args)
       env context location))))

(defun %parse-async-barrier-keys (expr location)
  "Parse (make-async-barrier &key mode) -> barrier-mode (Endeavor 137).
   Omitted :mode is arch-automatic (resolved elsewhere; defaults to :linear here).  :type was
   removed with def-topology.  Validates the mode and gates :block per backend/arch."
  (let ((keys (rest expr))
        (bmode :linear))
    (unless (evenp (length keys))
      (error 'crisp-compiler-error
        :message "make-async-barrier: keys must be :mode value pairs"
        :source-location location))
    (loop for (k v) on keys by #'cddr do
      (cond
        ((eq k :mode) (setf bmode v))
        ((eq k :type)
         (error 'crisp-compiler-error
           :message "make-async-barrier: the :type key was removed (def-topology is set aside); use only :mode"
           :source-location location))
        (t (error 'crisp-compiler-error
             :message (format nil "make-async-barrier: unknown key ~S (expected :mode)" k)
             :source-location location))))
    (unless (member bmode '(:linear :block))
      (error 'crisp-compiler-error
        :message (format nil "make-async-barrier :mode ~S unknown — expected :linear (cp.async / OpGroupAsyncCopy) or :block (CuTensorMap)" bmode)
        :source-location location))
    ;; Endeavor 137: :block is NVIDIA-CuTensorMap only.  Gated on real backends (:ptx/:spirv);
    ;; the GENERIC compile-check pass has no arch and lowers :block to the sync fallback.
    (when (eq bmode :block)
      (case crisp.compiler:*target-backend*
        (:spirv
         (error 'crisp-compiler-error
           :message ":mode :block is not supported on Intel / SPIR-V — Intel's fast 2D path (LSC block loads) loads global into registers directly and is not a barrier mode. Use :mode :linear, or the direct block-load path."
           :source-location location))
        (:ptx
         (unless (%arch-supports-block-p (resolved-target-arch))
           (error 'crisp-compiler-error
             :message (format nil ":mode :block needs a Hopper-or-newer NVIDIA arch (sm_90+) for TMA / CuTensorMap; got ~(~a~). Pass --ir-target-arch=sm_90 (or later)."
                              (resolved-target-arch))
             :source-location location)))))
    bmode))

(defun analyze-make-async-barrier-expression (expr env context location)
  "Endeavor 136/137: (make-async-barrier &key mode).  :linear is a PHANTOM barrier on PTX —
   commit_group/wait_group need no object, so we codegen a constant 0; on SPV it owns a
   target(\"spirv.Event\") slot to chain OpGroupAsyncCopy events.  The node carries :mode so
   load-tile/await pick the lowering (Endeavor 137 mode-threading)."
  (declare (ignore env))
  (let ((bmode (%parse-async-barrier-keys expr location)))
    ;; Endeavor 137: record the barrier's binding name -> resolved mode so load-tile/await
    ;; can pick the lowering.  The let analyzer set current-binding-name before analyzing us.
    (let ((bname (and context (compiler-context-current-binding-name context))))
      (when bname
        (setf (gethash bname *async-barrier-modes*) bmode))
      (make-semantic-make-async-barrier
       :cell-node nil                 ;; phantom — no mbarrier SLM object
       :barrier-mode bmode
       ;; Endeavor 137 Phase 2d: mbarrier init arrival count = #block loads sharing this barrier
       ;; (scan-counted).  Default 1 for a single-load barrier.
       :load-count (max 1 (or (and bname (gethash bname *async-barrier-load-count*)) 1))
     ;; SPV :linear needs a target("spirv.Event") slot to chain OpGroupAsyncCopy events
     ;; through; PTX commit_group/wait_group needs none (const-0 phantom).
       :spirv-event-p (and (eq crisp.compiler:*target-backend* :spirv) (eq bmode :linear))
       :type 'ulong
       :source-location location))))

(defun %check-barrier-ring-arrivals (arrivals bmode location)
  "Endeavor 138: validate :arrivals on a barrier ring.  Positive compile-time integer, and
   REQUIRED for EVERY barrier ring — both modes need the per-stage transfer count:
     :block  -> the mbarrier init ARRIVAL count.
     :linear -> the loads-per-stage factor in the cp.async wait_group((ring-count-1)*arrivals).
   (An earlier note said :linear ignored it; Endeavor 138's :linear ring pipelining needs it too,
   and requiring it for both keeps an arch-automatic ring kernel portable — the same :arrivals
   works whether the arch resolves to :block on sm_90 or :linear on sm_80.)

   Why explicit and not inferred: for :block the count must be exact — a hardware mbarrier
   completes only when BOTH its arrival count and its transaction bytes are met, so too high HANGS
   the kernel and too low reads a half-arrived tile.  A single make-async-barrier can be inferred
   (one stage in the text), but through a RING the prologue AND the main loop both load it, so the
   textual tally (2 prologue + 2 loop = 4) is NOT the per-stage count (2).  Static 'per phase'
   grouping is fragile and fails silently on the GPU, so we ask."
  (when (and arrivals (not (and (integerp arrivals) (plusp arrivals))))
    (error 'crisp-compiler-error
      :message (format nil "make-async-barrier-ring: :arrivals must be a positive compile-time integer, got ~S" arrivals)
      :source-location location))
  (when (null arrivals)
    (error 'crisp-compiler-error
      :message (concatenate 'string
                 "make-async-barrier-ring requires :arrivals — how many transfers EACH SLOT tracks "
                 "per pipeline stage (i.e. how many load-tiles name one slot in a single stage; the "
                 "classic A+B staging is 2).  It is explicit rather than inferred because a ring's "
                 "prologue and main loop both load the same ring, so counting load-tiles textually "
                 "does not give the per-stage count — and a wrong count "
                 (if (eq bmode :block)
                     "hangs the GPU (mbarrier arrival count)."
                     "breaks the pipeline overlap (cp.async wait_group depth).")
                 "  e.g. (make-async-barrier-ring :ring-count 3 :mode " (string-downcase (symbol-name bmode)) " :arrivals 2)")
      :source-location location)))

(defun analyze-make-async-barrier-ring-expression (expr env context location)
  "Endeavor 138 (Chapter 2): (make-async-barrier-ring &key ring-count mode arrivals) -> a ring
   of RING-COUNT async barriers for pipelining.

   Unification: a plain (make-async-barrier) is simply a RING OF 1.  Both build the same
   semantic-make-async-barrier node; this one just sets :ring-count N.  Codegen allocates
   [N x i64] of SLM mbarriers and yields the BASE address as an i64 — so (ring-get r i) is
   nothing but (base + i*8), which load-tile/await already inttoptr back to an mbarrier ptr.
   That means the whole 137 barrier path is reused verbatim for every slot.

   :ARRIVALS is how many transfers EACH SLOT tracks per pipeline stage.  It is REQUIRED for every
   barrier ring (both modes) — the mbarrier arrival count on :block, the cp.async wait_group depth
   factor on :linear — see %check-barrier-ring-arrivals for why it is explicit not scan-inferred."
  (declare (ignore env))
  (let* ((keys (rest expr))
         (n    (getf keys :ring-count))
         (arr  (getf keys :arrivals))
         (init-state (getf keys :initial-state))
         ;; Endeavor 139: :initial-state -> the awaiter's starting try_wait.parity phase.
         ;; :waiting -> 0 (blocks until first arrival); :signaled -> 1 (passes immediately on a
         ;; fresh mbarrier).  Absent -> NIL (a plain 138 ring whose await re-inits each step).
         (init-phase (cond ((null init-state) nil)
                           ((eq init-state :waiting)  0)
                           ((eq init-state :signaled) 1)
                           (t (error 'crisp-compiler-error
                                :message (format nil "make-async-barrier-ring: :initial-state must be :signaled or :waiting, got ~S" init-state)
                                :source-location location))))
         (bmode (%parse-async-barrier-keys
                 ;; reuse the single-barrier key parser (validation + arch gating) by handing it
                 ;; just the :mode pair — :ring-count / :arrivals / :initial-state are ours.
                 (list* (first expr)
                        (let ((m (getf keys :mode)))
                          (when m (list :mode m))))
                 location)))
    (unless (evenp (length keys))
      (error 'crisp-compiler-error
        :message "make-async-barrier-ring: keys must be :key value pairs"
        :source-location location))
    (loop for (k nil) on keys by #'cddr do
      (unless (member k '(:ring-count :mode :arrivals :initial-state))
        (error 'crisp-compiler-error
          :message (format nil "make-async-barrier-ring: unknown key ~S (expected :ring-count, :mode, :arrivals or :initial-state)" k)
          :source-location location)))
    (unless (and (integerp n) (plusp n))
      (error 'crisp-compiler-error
        :message (format nil "make-async-barrier-ring: :ring-count must be a positive compile-time integer, got ~S" n)
        :source-location location))
    ;; Endeavor 138: :linear ring pipelining is PTX-only for now.  On SPIR-V a :linear ring would
    ;; need N target("spirv.Event") slots + per-slot OpGroupWaitEvents (deferred).  A non-ring
    ;; :linear barrier (ring-count 1) is fine on SPV — guard only a genuine ring (n > 1).
    (when (and (eq crisp.compiler:*target-backend* :spirv) (eq bmode :linear) (> n 1))
      (error 'crisp-compiler-error
        :message "make-async-barrier-ring: :mode :linear rings are not yet implemented on SPIR-V (would need per-slot spirv.Event chaining). Use a single (make-async-barrier :mode :linear) for non-pipelined async on Intel, or :mode :block on NVIDIA sm_90+."
        :source-location location))
    (%check-barrier-ring-arrivals arr bmode location)
    (let ((bname (and context (compiler-context-current-binding-name context)))
          (count (max 1 (or arr 1))))
      (when bname
        (setf (gethash bname *async-barrier-modes*) bmode)
        (setf (gethash bname *async-barrier-ring-counts*) n)
        ;; Publish the EXPLICIT count under the ring's binding so barrier-load-count-of can serve
        ;; every consumer (notably await's re-init) from the one table — a ring slot re-armed with
        ;; a count that disagrees with its init is exactly the hang/torn-tile bug :arrivals exists
        ;; to prevent.
        (setf (gethash bname *async-barrier-load-count*) count)
        ;; Endeavor 139: the ring's initial await phase (marks it a warp-spec producer/consumer ring).
        (when init-phase (setf (gethash bname *async-barrier-initial-phase*) init-phase)))
      (make-semantic-make-async-barrier
       :cell-node nil
       :barrier-mode bmode
       :ring-count n
       ;; Endeavor 138: EXPLICIT for a ring (never scan-counted — see the check above).
       :load-count count
       :initial-phase init-phase
       :spirv-event-p (and (eq crisp.compiler:*target-backend* :spirv) (eq bmode :linear))
       :type 'ulong
       :source-location location))))

(defun %barrier-ring-form-p (form)
  "T if FORM is (ring-get RING i) naming an async-barrier RING; returns the ring symbol."
  (and (consp form)
       (symbolp (first form))
       (string-equal (symbol-name (first form)) "RING-GET")
       (symbolp (second form))
       (gethash (second form) *async-barrier-ring-counts*)
       (second form)))

(defun barrier-load-count-of (barrier-form)
  "Endeavor 137\138: the mbarrier arrival count for the barrier a load-tile/await refers to.
   BARRIER-FORM is either the barrier variable SYMBOL, or — Endeavor 138 — a
   (ring-get BARRIER-RING i) form, in which case the count is the RING's (every slot shares it:
   each stage issues the same loads).  Defaults to 1.

   For a single barrier this is the scan-counted tally of :block loads naming it; for a ring it is
   the user's explicit :arrivals, recorded under the ring's binding by
   analyze-make-async-barrier-ring-expression.  Both land in *async-barrier-load-count*, so
   consumers need only resolve the ring and look up one table.

   This MUST agree with the count the barrier was init'd with — await re-inits the mbarrier to
   restart it at phase 0, and re-arming with the wrong count either hangs the kernel (too high)
   or completes it on a half-arrived tile (too low)."
  (let ((ring (%barrier-ring-form-p barrier-form)))
    (max 1 (or (and ring (gethash ring *async-barrier-load-count*))
               (and (symbolp barrier-form) (gethash barrier-form *async-barrier-load-count*))
               1))))

(defun barrier-ring-count-of (barrier-form)
  "Endeavor 138: the RING DEPTH of the barrier a load-tile/await refers to (1 for a plain,
   non-ring barrier).  BARRIER-FORM is either the barrier symbol or a (ring-get RING i) form;
   resolves to the ring and looks up *async-barrier-ring-counts*.  Used to size the :linear
   cp.async.wait_group idiom: keep (ring-count - 1) stages of groups in flight."
  (let ((ring (%barrier-ring-form-p barrier-form)))
    (max 1 (or (and ring (gethash ring *async-barrier-ring-counts*))
               (and (symbolp barrier-form) (gethash barrier-form *async-barrier-ring-counts*))
               1))))

(defun analyze-signal-expression (expr env context location)
  "Endeavor 139: (signal (ring-get empty-ring slot)) — the consumer's manual mbarrier.arrive on an
   empty ring slot, releasing it to the producer.  PTX/:block only (mbarrier); a no-op on other
   backends (the generic compile-check pass has no mbarriers)."
  (unless (= (length expr) 2)
    (error 'crisp-compiler-error
      :message (format nil "signal: expected (signal BARRIER), got ~S" expr)
      :source-location location))
  (let ((barrier-node (analyze-expression (second expr) env context (append location '(1)))))
    (if (eq *target-backend* :ptx)
        (make-semantic-signal
         :barrier-node barrier-node
         :type 'ulong
         :source-location location)
        ;; No mbarriers off the PTX/:block path — signal is a no-op there.
        (analyze-expression nil env context location))))

(defun barrier-initial-phase-of (barrier-form)
  "Endeavor 139: the initial await phase (0/1) of the barrier a load-tile/await refers to, or NIL
   if it is a plain 138 ring (no :initial-state).  BARRIER-FORM is the barrier SYMBOL or a
   (ring-get RING i) form.  A non-NIL value selects the warp-spec await (phase-tracked, no re-init)."
  (let ((ring (%barrier-ring-form-p barrier-form)))
    (or (and ring (gethash ring *async-barrier-initial-phase*))
        (and (symbolp barrier-form) (gethash barrier-form *async-barrier-initial-phase*)))))

(defun async-barrier-mode-of (barrier-form)
  "Endeavor 137/138: resolved :mode (:linear/:block) of the barrier a load-tile/await refers to.
   BARRIER-FORM is either the barrier variable SYMBOL, or — Endeavor 138 — a
   (ring-get BARRIER-RING i) form, in which case the mode is the RING's (every slot shares it).
   Defaults to :linear when unknown (bare/older barriers)."
  (let ((ring (%barrier-ring-form-p barrier-form)))
    (or (and ring (gethash ring *async-barrier-modes*))
        (and (symbolp barrier-form) (gethash barrier-form *async-barrier-modes*))
        :linear)))


;;; ===================================================================
;;; Endeavor 139 (Chapter 3) — warp specialization.
;;; ===================================================================

(defun %role-name-eq (a b)
  "Role identity: package-insensitive symbol-name compare, so :producer (keyword) and a
   bare producer symbol both match.  Roles are normally keywords."
  (and (symbolp a) (symbolp b) (string-equal (symbol-name a) (symbol-name b))))

(defun %parse-warp-specialization (expr location)
  "Parse (with-warp-specialization (ROLE COUNT ...) (ROLE BODY...) ...).
   Returns (values role-counts role-blocks): role-counts an ordered list of (role . count);
   role-blocks an alist role -> body-forms.  Validates: even ROLE/COUNT plist with positive
   integer counts; every block names a declared role; every declared role has exactly one block;
   no duplicate blocks."
  (let ((role-spec (second expr))
        (blocks    (cddr expr)))
    (unless (and (listp role-spec) (plusp (length role-spec)) (evenp (length role-spec)))
      (error 'crisp-compiler-error
        :message "with-warp-specialization: first argument must be a (ROLE COUNT ...) list, e.g. (:producer 1 :consumer 3)"
        :source-location location))
    (let ((role-counts (loop for (role count) on role-spec by #'cddr
                             do (unless (and (symbolp role) (integerp count) (plusp count))
                                  (error 'crisp-compiler-error
                                    :message (format nil "with-warp-specialization: each ROLE COUNT must be a symbol and a positive integer, got ~S ~S" role count)
                                    :source-location location))
                             collect (cons role count))))
      (unless blocks
        (error 'crisp-compiler-error
          :message "with-warp-specialization: expected one (ROLE BODY...) block per declared role"
          :source-location location))
      (let ((role-blocks
             (loop for blk in blocks
                   do (unless (and (consp blk) (symbolp (first blk)))
                        (error 'crisp-compiler-error
                          :message (format nil "with-warp-specialization: each role block must be (ROLE BODY...), got ~S" blk)
                          :source-location location))
                   collect (cons (first blk) (rest blk)))))
        ;; every block names a declared role
        (dolist (blk role-blocks)
          (unless (assoc (car blk) role-counts :test #'%role-name-eq)
            (error 'crisp-compiler-error
              :message (format nil "with-warp-specialization: block role ~S is not one of the declared roles ~S"
                               (car blk) (mapcar #'car role-counts))
              :source-location location)))
        ;; exactly one block per declared role
        (dolist (rc role-counts)
          (let ((matches (count (car rc) role-blocks :key #'car :test #'%role-name-eq)))
            (when (zerop matches)
              (error 'crisp-compiler-error
                :message (format nil "with-warp-specialization: declared role ~S has no (~S ...) block" (car rc) (car rc))
                :source-location location))
            (when (> matches 1)
              (error 'crisp-compiler-error
                :message (format nil "with-warp-specialization: role ~S has ~a blocks; expected exactly one" (car rc) matches)
                :source-location location))))
        (values role-counts role-blocks)))))

(defun %lower-warp-specialization (expr location)
  "Endeavor 139 / 146: the PURE SYNTACTIC lowering of with-warp-specialization.  Returns the
   replacement form; it analyses nothing and has no side effects.

   EXTRACTED FROM THE ANALYZER in endeavour 146 so the AD walk can reuse it.  The walk runs
   BEFORE semantic analysis, so without this it sees the raw construct and reads a role block
   `(:consumer ...)` as a call to a function named CONSUMER.

   TWO CONSUMERS, ONE LOWERING.  The alternative was a second, hand-written warp-gated rewrite
   inside the AD normalizer — which would be free to drift from this one, and a gradient that
   is correct for a kernel nobody runs is worse than no gradient at all.  Note this differs
   from how wgmma is handled in the same normalizer: there the backward deliberately uses a
   DIFFERENT instruction from the forward (sync MMA rather than warpgroup-async), which is a
   real semantic choice.  Here the backward wants the SAME expansion the forward gets, only
   earlier — reuse, not substitution.

   (with-warp-specialization (ROLE COUNT ...) (ROLE BODY...) ...).  Splits the
   workgroup by WARP — warp k runs the role whose cumulative count range contains k.  Lowers to a
   warp-id-gated nested if: (let ((wsid (to-int (warp-id)))) (if (< wsid t1) BODY1 (if (< wsid t2)
   BODY2 ...))) where t_i is the running sum of role counts.  Role blocks are warp-UNIFORM (all
   lanes of a warp take the same branch) but workgroup-DIVERGENT — so an internal workgroup
   collective (sync-workgroup, a cooperative load-tile) inside a block would DEADLOCK.  Forbidding
   those is decision B, enforced when the load path is added (Chapter 3 step 2); the skeleton here
   just lowers the branch."
  (multiple-value-bind (role-counts role-blocks) (%parse-warp-specialization expr location)
    (let* ((cl        (find-package :crisp-language))
           (let-sym   (intern "LET" cl))
           (if-sym    (intern "IF" cl))
           (lt-sym    (intern "<" cl))
           (progn-sym (intern "PROGN" cl))
           (to-int-sym (intern "TO-INT" cl))
           (warp-id-sym (intern "WARP-ID" cl))
           (wsid      (gensym "WSID"))
           (n         (length role-counts))
           ;; each role's body wrapped in a progn (in declaration order)
           (bodies    (loop for (role . count) in role-counts
                            do (progn count)
                            collect (cons progn-sym
                                          (cdr (assoc role role-blocks :test #'%role-name-eq)))))
           ;; running-sum upper bounds t_1..t_n
           (thresholds (let ((acc 0))
                         (loop for (role . count) in role-counts
                               do (progn role) (incf acc count)
                               collect acc)))
           ;; Nested if with the LAST role as the final else — decision C guarantees warps
           ;; [t_{n-1}, t_n) are exactly that role and there are none beyond t_n, so we need no
           ;; numeric fall-through (which would clash types with the void role bodies).  For a
           ;; single role there is no branch at all.
           (nest (let ((acc (car (last bodies))))
                   (loop for i from (- n 2) downto 0
                         do (setf acc (list if-sym
                                            (list lt-sym wsid (nth i thresholds))
                                            (nth i bodies)
                                            acc)))
                   acc)))
      ;; (warp-id) is the STABLE block-local warp index — on PTX it now synthesizes
      ;; local-linear-id/32 (Endeavor 139 fixed it from the volatile %warpid); on SPV it is
      ;; SubgroupId.  Either way it is safe for the producer/consumer split.
      (list let-sym (list (list wsid (list to-int-sym (list warp-id-sym))))
            nest))))

(defun analyze-with-warp-specialization-expression (expr env context location)
  "Endeavor 139: analyzes (with-warp-specialization ...) by lowering it with
   %lower-warp-specialization and analysing the result.

   Decision B: bind *in-warp-spec-block* around the role-block analysis so a :block load-tile
   inside a role block is permitted (leader-issued, no workgroup sync) despite the
   warp-divergent branch the expansion introduces."
  (let ((*in-warp-spec-block* t))
    (analyze-expression (%lower-warp-specialization expr location)
                        env context location)))

(defun analyze-make-c-handle (expr env context location)
  "Analyzer for (make-c-handle <held-ptr-type>)."
  (declare (ignore env context))
  (unless (= (length expr) 2)
    (error 'crisp-compiler-error
      :message "make-c-handle expects 1 argument: the held pointer type, e.g. (make-c-handle (c-pointer :address-space :global))"
      :source-location location))
  (let ((held (second expr)))
    (unless (and (consp held) (symbolp (first held))
                 (string-equal (symbol-name (first held)) "C-POINTER"))
      (error 'crisp-compiler-error
        :message (format nil "make-c-handle requires a (c-pointer :address-space ...) type; got ~a" held)
        :source-location location))
    (make-semantic-make-c-handle
     :type (list (intern "C-HANDLE" (find-package :crisp.compiler)) held)
     :held-type held
     :source-location location)))

(defun analyze-get-pointer (expr env context location)
  "Analyzer for (get-pointer <c-handle>) — loads the held pointer from the slot."
  (unless (= (length expr) 2)
    (error 'crisp-compiler-error
      :message "get-pointer expects 1 argument (a c-handle)"
      :source-location location))
  (let* ((handle-node (analyze-expression (second expr) env context (append location '(1))))
         (htype (get-single-value-type handle-node)))
    (unless (and (consp htype) (symbolp (first htype))
                 (string-equal (symbol-name (first htype)) "C-HANDLE"))
      (error 'crisp-compiler-error
        :message (format nil "get-pointer requires a c-handle argument; got type ~a" htype)
        :source-location location))
    (make-semantic-get-pointer
     :type (second htype)
     :handle-node handle-node
     :source-location location)))


(defun analyze-fill-tile-expression (expr env context location)
  "(fill-tile T V) for a scratch/SLM tile — workgroup-collective fill of every element of
   the tensor T to V.  No barrier is inserted; the caller syncs before reading.  Register
   tiles are handled earlier in the SROA explosion and never reach here."
  (unless (= (length expr) 3)
    (error 'crisp-compiler-error
      :message "fill-tile: expected (fill-tile <tile> <value>)"
      :source-location location))
  (let* ((tensor (second expr))
         (val    (third expr))
         (tnode  (analyze-expression tensor env context (append location '(1))))
         (ttype  (semantic-node-type tnode)))
    (unless (%tensor-type-p ttype)
      (error 'crisp-compiler-error
        :message "fill-tile: first argument must be a tile (vector / matrix / tensor)."
        :source-location location))
    (let* ((arity    (%get-tensor-arity ttype))
           (cl-pkg   (find-package :crisp-language))
           (ws-sym   (intern "WORKGROUP-STRIDE" cl-pkg))
           (aref-sym (intern "~" cl-pkg))
           (set-sym  (intern "SET!" cl-pkg))
           (bindings (loop repeat arity collect (gensym "FI"))))
      (analyze-expression
       (list ws-sym tensor bindings
             (list set-sym (list* aref-sym tensor bindings) val))
       env context location))))


;; ======================================================================
;; Endeavor 135 — matrix-multiply-tile-stride
;;
;; Envelope/body macro for tiled matmul.  SUGAR over the (grid-correct) tile-stride: strides
;; C's output tiles (grid-y/grid-x as TILE-IDs), runs a K/k-step reduction loop (grid-k, the
;; fastest-changing binding), then AUTO-STORES C-tile back to C.  The body stages + accumulates.
;;
;;   (matrix-multiply-tile-stride C C-tile K <k-step> (grid-y grid-x grid-k) BODY...)
;;     =>  (tile-stride C C-tile (grid-y grid-x)
;;           (dotimes (grid-k (/ (to-ulong K) (to-ulong <k-step>))) BODY...)
;;           (store-tile C-tile C (grid-y grid-x)))
;;
;; %mmts-parse / %mmts-lower are shared with the register-tile pre-lowering in src/mma.lisp
;; (%expand-matmul-tile-stride-register-forms).  A register-tile C-tile is a record-of-fragments
;; the SROA explosion turns into C-tile$Fi + rewrites store-tile/mma — so a register-tile matmul
;; is pre-lowered BEFORE the explosion (in analyze-let-with-tile-explosion) with a compile-time
;; (M N) size-list tile-spec (a register tile has no extents~); a scratch C-tile is a real tensor
;; and takes THIS ordinary analyzer path (tile-tensor spec).
(defun %mmts-parse (expr location)
  "Validate + destructure a matrix-multiply-tile-stride form.  Returns
   (values c-form c-tile k-form k-step grid-y grid-x grid-k body)."
  (let* ((c-tile   (third expr))
         (k-step   (fifth expr))
         (bindings (sixth expr))
         (body     (nthcdr 6 expr)))
    (declare (ignore c-tile))
    ;; Old pre-k-step 4-arg shape: the grid bindings sit in the <k-step> slot.
    (when (listp k-step)
      (error 'crisp-compiler-error
        :message "matrix-multiply-tile-stride: missing scalar <k-step> before the grid bindings — expected (matrix-multiply-tile-stride C C-tile K <k-step> (grid-y grid-x grid-k) BODY...)"
        :source-location location))
    (unless (and (listp bindings) (= (length bindings) 3) (every #'symbolp bindings))
      (error 'crisp-compiler-error
        :message "matrix-multiply-tile-stride: expected exactly three grid bindings (grid-y grid-x grid-k)"
        :source-location location))
    (unless body
      (error 'crisp-compiler-error
        :message "matrix-multiply-tile-stride: empty body"
        :source-location location))
    (values (second expr) (third expr) (fourth expr) k-step
            (first bindings) (second bindings) (third bindings) body)))

(defun %mmts-split-epilogue (body)
  "Endeavor 137: split a matrix-multiply-tile-stride body at the :epilogue marker into
   (values reduction-body epilogue-body).  Forms before :epilogue run once per K-step
   (the reduction); forms after run once per tile, post-reduction (grid-y/grid-x in scope,
   C-tile complete) — that is where the user's store-tile (and any fusion) go.  No :epilogue
   -> (values body nil)."
  (let ((pos (position :epilogue body)))
    (if pos
        (values (subseq body 0 pos) (subseq body (1+ pos)))
        (values body nil))))

(defun %form-tree-mentions-store-tile-p (forms)
  "T if any form in the tree FORMS is a (store-tile ...) / (store-tile-at ...) call."
  (labels ((walk (f)
             (cond
               ((not (consp f)) nil)
               ((and (symbolp (car f))
                     (member (symbol-name (car f)) '("STORE-TILE" "STORE-TILE-AT")
                             :test #'string-equal))
                t)
               (t (some #'walk f)))))
    (some #'walk forms)))

(defun %mmts-lower (c-form c-tile tile-spec k-form k-step grid-y grid-x grid-k body location
                    &optional (reset-value 0.0))
  "The tile-stride (over TILE-SPEC) + grid-k K/k-step reduction loop.  Endeavor 137: NO
   auto-store — the body's :epilogue section (post-reduction, per tile) holds the explicit
   store + any fusion.  Warns if the C-tile is never stored.

   BUG 036: emits a per-OUTPUT-TILE reset of the accumulator to RESET-VALUE before the K-loop.
   Without it a workgroup that strides onto a second tile carries the first tile's partial sums.
   A scratch C-tile's fill is workgroup-collective, so it is followed by a sync-workgroup; a
   register tile's is per-lane and needs none."
  (declare (ignore location))
  (multiple-value-bind (reduction-body epilogue-body) (%mmts-split-epilogue body)
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
           ;; A register tile's spec is the compile-time (M N) size list; a scratch tile's is
           ;; the tile tensor itself.
           (register-p      (and (listp tile-spec) tile-spec (every #'integerp tile-spec)))
           ;; REGISTER TILES ONLY.  A scratch C-tile is deliberately left alone: endeavor 135
           ;; documented that contract in 135/01-macro-envelope — "The macro does NOT auto-reset
           ;; a scratch C-tile — the user owns init" — and 135/02 duly resets by hand.  The
           ;; measured bug was a REGISTER tile, whose init lives in a make-register-tile binding
           ;; OUTSIDE the loop where the user cannot reach it per-tile; that asymmetry is exactly
           ;; why the register path needs the macro to own the reset and the scratch path does
           ;; not.  (sync-sym is retained for the scratch path should that contract ever change;
           ;; a collective fill would need it.)
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

(defun analyze-matrix-multiply-tile-stride-expression (expr env context location)
  "Scratch-tensor path for (matrix-multiply-tile-stride C C-tile K <k-step> (gy gx gk) BODY...).
   Lowers with the tile-tensor C-tile (tile-stride reads its extents~).  Register-tile C-tiles
   are pre-lowered in analyze-let-with-tile-explosion, before SROA explosion, so never reach here."
  (multiple-value-bind (c-form c-tile k-form k-step gy gx gk body)
      (%mmts-parse expr location)
    (analyze-expression (%mmts-lower c-form c-tile c-tile k-form k-step gy gx gk body location)
                        env context location)))


(defun register-control-analyzers ()
  "Registers all control flow expression analyzers, including loop-vector-stride,
   tensor-stride, grid-stride, tile-stride, hardware-stride, workgroup-stride,
   and (111 Phase 1a) load-tile-at / store-tile-at.
   Endeavor 113: also registers request-load-tile-at and await-request."
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
  (def-expression-analyzer if+ analyze-if+-expression)
  (def-expression-analyzer when+ analyze-when+-expression)
  (def-expression-analyzer unless+ analyze-unless+-expression)
  (def-expression-analyzer dotimes+ analyze-dotimes+-expression)
  ;; Endeavor 126 (pass 5): with-precision — register under BOTH :crisp-language and
  ;; :crisp.compiler so a form read in either package dispatches (cf. warp builtins).
  (let ((sym-cl (intern "WITH-PRECISION" (find-package :crisp-language)))
        (sym-cc (intern "WITH-PRECISION" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-with-precision-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-with-precision-expression)))
  ;; Endeavor 139 (Chapter 3): warp specialization — the warp-role split.
  (let ((sym-cl (intern "WITH-WARP-SPECIALIZATION" (find-package :crisp-language)))
        (sym-cc (intern "WITH-WARP-SPECIALIZATION" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-with-warp-specialization-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-with-warp-specialization-expression)))
  (def-expression-analyzer uniformity-state analyze-uniformity-state)
  (def-expression-analyzer provably-uniform? analyze-provably-uniform?)
  (def-expression-analyzer provably-divergent? analyze-provably-divergent?)
  (def-expression-analyzer to-workgroup-uniform analyze-to-workgroup-uniform)
  (def-expression-analyzer to-warp-uniform analyze-to-warp-uniform)
  ;; Endeavor 122 (FFI) Pass 4: handle forms (analyzers live in the overlay).
  (def-expression-analyzer make-c-handle analyze-make-c-handle)
  (def-expression-analyzer get-pointer analyze-get-pointer)
  (def-expression-analyzer return analyze-return-expression)
  (def-expression-analyzer explicit-return analyze-return-expression)
  (def-expression-analyzer semantic-return analyze-return-expression)
  (def-expression-analyzer quote analyze-quote)

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
  (let ((sym-cl (intern "WHILE" (find-package :crisp-language)))
        (sym-cc (intern "WHILE" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-while-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-while-expression)))
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
  ;; (Old element-coordinate load/store aliases removed — endeavor 135 rename.
  ;;  The load-tile-at / store-tile-at primitives are registered below.)
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
  ;; Endeavor 135 — matrix-multiply-tile-stride (scratch path) + fill-tile.
  (let ((sym-cl (intern "MATRIX-MULTIPLY-TILE-STRIDE" (find-package :crisp-language)))
        (sym-cc (intern "MATRIX-MULTIPLY-TILE-STRIDE" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-matrix-multiply-tile-stride-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-matrix-multiply-tile-stride-expression)))
  (let ((sym-cl (intern "FILL-TILE" (find-package :crisp-language)))
        (sym-cc (intern "FILL-TILE" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-fill-tile-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-fill-tile-expression)))
  (let ((sym-cl (intern "LOAD-LOCAL" (find-package :crisp-language)))
        (sym-cc (intern "LOAD-LOCAL" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-load-local-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-load-local-expression)))
  (let ((sym-cl (intern "STORE-GLOBAL" (find-package :crisp-language)))
        (sym-cc (intern "STORE-GLOBAL" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-store-global-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-store-global-expression)))
  (let ((sym-cl (intern "%UNIFORM-WHEN" (find-package :crisp-language)))
        (sym-cc (intern "%UNIFORM-WHEN" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-%uniform-when-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-%uniform-when-expression)))
  (let ((sym-cl (intern "%LOAD-TILE-AT-BWD" (find-package :crisp-language)))
        (sym-cc (intern "%LOAD-TILE-AT-BWD" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-%load-tile-at-bwd-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-%load-tile-at-bwd-expression)))
  (let ((sym-cl (intern "%STORE-TILE-AT-BWD" (find-package :crisp-language)))
        (sym-cc (intern "%STORE-TILE-AT-BWD" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-%store-tile-at-bwd-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-%store-tile-at-bwd-expression)))
  (let ((sym-cl (intern "AWAIT" (find-package :crisp-language)))
        (sym-cc (intern "AWAIT" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-await-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-await-expression)))
  ;; Endeavor 139 (Chapter 3): signal — the consumer's manual mbarrier.arrive on an empty ring.
  (let ((sym-cl (intern "SIGNAL" (find-package :crisp-language)))
        (sym-cc (intern "SIGNAL" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-signal-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-signal-expression)))
  (let ((sym-cl (intern "LOAD-TILE-AT" (find-package :crisp-language)))
        (sym-cc (intern "LOAD-TILE-AT" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-load-tile-at-expression)
    (setf (gethash sym-cc *expression-analyzers*) #'analyze-load-tile-at-expression))
  (let ((sym-cl (intern "STORE-TILE-AT" (find-package :crisp-language)))
        (sym-cc (intern "STORE-TILE-AT" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-store-tile-at-expression)
    (setf (gethash sym-cc *expression-analyzers*) #'analyze-store-tile-at-expression))
  (let ((sym-cl (intern "MAKE-ASYNC-BARRIER" (find-package :crisp-language)))
        (sym-cc (intern "MAKE-ASYNC-BARRIER" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-make-async-barrier-expression)
    (setf (gethash sym-cc *expression-analyzers*) #'analyze-make-async-barrier-expression))
  ;; Endeavor 138 (Chapter 2): a ring of async barriers for pipelining.
  (let ((sym-cl (intern "MAKE-ASYNC-BARRIER-RING" (find-package :crisp-language)))
        (sym-cc (intern "MAKE-ASYNC-BARRIER-RING" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-make-async-barrier-ring-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-make-async-barrier-ring-expression)))
  ;; Endeavor 136 (Chapter 1): internal forms produced by the async load-tile-at expansion.
  (let ((sym-cl (intern "%CP-ASYNC-COPY-ELEM" (find-package :crisp-language)))
        (sym-cc (intern "%CP-ASYNC-COPY-ELEM" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-%cp-async-copy-elem-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-%cp-async-copy-elem-expression)))
  (let ((sym-cl (intern "%CP-ASYNC-COMMIT" (find-package :crisp-language)))
        (sym-cc (intern "%CP-ASYNC-COMMIT" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-%cp-async-commit-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-%cp-async-commit-expression)))
  ;; Endeavor 136 (Chapter 1, SPV): internal form from the async SPV load-tile expansion.
  (let ((sym-cl (intern "%SPIRV-ASYNC-COPY" (find-package :crisp-language)))
        (sym-cc (intern "%SPIRV-ASYNC-COPY" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-%spirv-async-copy-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-%spirv-async-copy-expression))))
