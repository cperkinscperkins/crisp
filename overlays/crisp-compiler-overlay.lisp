;;;; crisp-compiler-overlay.lisp — late-bound fixes for the CRISP.COMPILER package.
;;;;
;;;; APPEND full replacement definitions here while developing; they are loaded after src/ and
;;;; win by late binding.  Do NOT patch in place -- append, and note above each one which src
;;;; file it belongs to, so it can be folded back later.
;;;;
;;;; TWO THINGS THAT BITE (both learned the hard way, endeavour 165):
;;;;
;;;;   * A HANDLER REGISTERED BY OBJECT IS NOT LATE-BOUND.  src/autodiff.lisp does
;;;;     (register-vjp "MMA-ACCUMULATE-VIA-TILE" #'%vjp-mma-accumulate-via-tile), which captures
;;;;     the function OBJECT at load time.  Redefining that defun here is DEAD CODE until you
;;;;     also re-register.  The failure is partial and therefore nasty: a callee overridden by
;;;;     name goes live while its caller stays stale.
;;;;
;;;;   * NEVER PUT A DOUBLE QUOTE INSIDE A DOCSTRING.  It closes the string early and the rest of
;;;;     the prose becomes BODY FORMS -- the first bare word is then an unbound variable, and the
;;;;     build emits no warning.  It fails only when the function is CALLED.  Cost: a red CI.
;;;;
;;;; Emptied 2026-09-16: everything folded into src/ (endeavour 170 + BUG 060).

(in-package :crisp.compiler)


;;; ======================================================================
;;; Endeavor 167 — matrix-multiply-tile-stride sections: :let / :prologue / :body / :epilogue
;;; ======================================================================
;;;
;;; WHY.  84 of the 128 matmul benchmark kernels do not call the macro, and 62 of those are
;;; shape-compatible with it TODAY -- they hand-write its expansion, right down to a literal
;;; :epilogue keyword sitting inside a plain tile-stride where it is inert.  That is the
;;; all-or-nothing failure mode: the macro owned the K loop and offered nothing around it, so
;;; the moment a kernel needed one binding scoped over the loop, or one prefetch before it,
;;; the only escape was to write the expansion out by hand -- and then it was forked forever.
;;;
;;; :let closes the binding gap (22 files bind tiles inside tile-stride and cannot move them
;;; out), :prologue closes the per-tile-setup gap (18 files), and :body exists so the split
;;; between prologue and reduction is stated rather than guessed.

;; src/analysis/control.lisp
(defparameter *mmts-sections* '(:let :prologue :body :epilogue)
  "The section markers of matrix-multiply-tile-stride, in their REQUIRED order.
   Closed set: a keyword in section position that is not here is an error, because the
   pre-167 behaviour for a typo'd marker was to silently fold it into the reduction body.")

;; src/analysis/control.lisp
(defun %mmts-section-error (message location)
  "Signal a section-grammar error for matrix-multiply-tile-stride."
  (error 'crisp-compiler-error
         :message (concatenate 'string "matrix-multiply-tile-stride: " message)
         :source-location location))

;; src/analysis/control.lisp
(defun %mmts-split-sections (body &optional location)
  "Split a matrix-multiply-tile-stride BODY into its four sections.
   Returns (values LET-BINDINGS PROLOGUE-FORMS REDUCTION-FORMS EPILOGUE-FORMS).

   GRAMMAR.  Sections are introduced by a bare keyword at the top level of the body and run
   until the next marker, so every section but :let holds an implicit progn.  :let holds
   exactly one binding group.  The markers must appear in the order given by *mmts-sections*
   and at most once each.

   ORDER IS ENFORCED, NOT ENCOURAGED.  The split is positional, so a :prologue written after
   :epilogue would still lower to code that runs BEFORE the K loop -- the text would read one
   way and execute another with nothing to warn you.

   LEGACY SHAPE.  With neither :let nor :prologue present the body may stay unmarked and the
   reduction is simply everything before :epilogue, exactly as %mmts-split-epilogue did.  That
   is what keeps the 41 pre-167 call sites compiling untouched.  Once :let or :prologue appears
   the boundary between prologue and reduction is no longer inferable, so :body is required."
  (let ((marks '()))
    (loop for f in body
          for i from 0
          when (keywordp f)
            do (unless (member f *mmts-sections*)
                 (%mmts-section-error
                  (format nil "unknown section keyword ~s. The sections are ~{~s~^, ~} and the set is closed -- a keyword in section position that is not one of them is almost always a typo, and before 167 it was silently folded into the reduction body."
                          f *mmts-sections*)
                  location))
               (push (cons f i) marks))
    (setf marks (nreverse marks))
    ;; No duplicates: a repeated marker has no sensible reading (first wins discards the
    ;; second's forms, last wins discards the first's, concatenating reorders code across
    ;; the K loop -- the one thing this grammar exists to make explicit).
    (dolist (m marks)
      (let ((kw (car m)))
        (when (> (count kw marks :key #'car) 1)
          (%mmts-section-error
           (format nil "section ~s appears more than once. Each section may appear at most once; merge the forms into a single ~:*~s block." kw)
           location))))
    ;; In order.
    (let ((seen (mapcar #'car marks)))
      (unless (equal seen (remove-if-not (lambda (s) (member s seen)) *mmts-sections*))
        (%mmts-section-error
         (format nil "sections out of order: found ~{~s~^ ~}, but they must appear in the order ~{~s~^ ~}. The split is positional, so an out-of-order section still lowers to its own slot -- the code would read in one order and execute in another."
                 seen *mmts-sections*)
         location)))
    (labels ((section (kw)
               (let ((hit (assoc kw marks)))
                 (when hit
                   (let* ((start (1+ (cdr hit)))
                          (next  (loop for m in marks
                                       when (> (cdr m) (cdr hit)) return (cdr m))))
                     (subseq body start (or next (length body)))))))
             (present (kw) (and (assoc kw marks) t)))
      (let* ((leading   (subseq body 0 (if marks (cdr (first marks)) (length body))))
             (let-forms (section :let))
             (prologue  (section :prologue))
             (marked    (section :body))
             (epilogue  (section :epilogue)))
        ;; :let takes ONE binding group, not a form sequence.  The asymmetry is easy to trip
        ;; over because the other three take an implicit progn.
        ;; A single form that merely IS a list is not enough: (fill-tile C-tile 0.0) passes
        ;; that test and then dies much later naming FILL-TILE as if it were a variable.
        ;; Every element must be a (var ... value) binding.
        (when (present :let)
          (unless (and (= (length let-forms) 1)
                       (listp (first let-forms))
                       (every (lambda (b) (and (consp b) (>= (length b) 2) (symbolp (first b))))
                              (first let-forms)))
            (%mmts-section-error
             ":let takes exactly one binding group -- a list of (variable value) bindings, e.g. :let ((C-tile (make-register-tile float (8 16) 0.0))). Unlike :prologue / :body / :epilogue it does not hold statements, so a bare form here is almost certainly a section that should have been :prologue."
             location)))
        ;; Once :let or :prologue appears, the prologue/reduction boundary is not inferable.
        (when (and (or (present :let) (present :prologue)) (not (present :body)))
          (%mmts-section-error
           "an explicit :body is required once :let or :prologue is used -- without it there is no way to tell where the prologue ends and the K-step reduction begins, and guessing would silently move a warm-up into the loop (or a load out of it)."
           location))
        ;; Unmarked leading forms ARE the body in the legacy shape (the only marker there is
        ;; :epilogue).  Once :body is explicit they have nowhere to go, so they are an error
        ;; rather than a silently-dropped or silently-prepended block.
        (when (and (present :body) leading)
          (%mmts-section-error
           (format nil "~d form~:p appear before the first section marker ~s, but this call has an explicit :body. Move them into :prologue (to run once per output tile) or into :body (to run once per K-step)."
                   (length leading) (car (first marks)))
           location))
        (values (when (present :let) (first let-forms))
                prologue
                (if (present :body) marked leading)
                epilogue)))))


;; src/analysis/control.lisp
(defun %mmts-reset-forms (c-tile let-bindings tile-spec reset-value fill-sym sync-sym)
  "The per-OUTPUT-TILE accumulator reset (BUG 036), decided by WHERE the C-tile is bound.

   Measured 2026-09-17 by compiling both shapes and reading the LLVM IR: a register tile
   bound INSIDE tile-stride emits its zero CompositeConstruct + store in the grid-x loop
   body, after grid-x is stored and before the K loop is entered -- precisely the slot this
   function's fill would occupy.  Bound in the ENCLOSING let it lands in the kernel entry
   block instead, once per WORKGROUP, which is the BUG 036 exposure.

   So:
     * register tile in :let      -> NOTHING.  The binding already is the per-tile reset;
                                    a fill here would be a redundant full-tile zero-write on
                                    the hot path, correct and invisible to MMA_CORRECT.
     * register tile outside      -> fill to its DECLARED INIT (pre-167 behaviour, kept).
     * scratch tile, either place -> fill to 0.0 PLUS a barrier.  make-scratch-matrix takes
                                    no init, so a scratch tile never self-resets wherever it
                                    is bound; and fill-tile on scratch is a workgroup-
                                    collective write that inserts no barrier of its own, so
                                    the macro (its caller) supplies one.  Endeavour 167
                                    behaviour change: before this, %mmts-lower gated the
                                    reset on REGISTER-P and scratch got nothing, leaving
                                    every scratch call site to hand-write it."
  (let* ((entry      (and (listp let-bindings) (assoc c-tile let-bindings)))
         (register-p (and (listp tile-spec) tile-spec (every #'integerp tile-spec))))
    (cond
      ;; Bound in :let and it is a register tile -> the binding resets it. Emit nothing.
      ((and entry (%register-tile-init-form-p (second entry))) nil)
      ;; Register tile bound in the enclosing let.
      ((and register-p (null entry)) (list (list fill-sym c-tile reset-value)))
      ;; Everything else is a scratch accumulator: fill + barrier.
      (t (list (list fill-sym c-tile 0.0) (list sync-sym))))))

;; src/analysis/control.lisp
(defun %mmts-lower (c-form c-tile tile-spec k-form k-step grid-y grid-x grid-k body location
                    &optional (reset-value 0.0))
  "The tile-stride (over TILE-SPEC) + grid-k K/k-step reduction loop.

   Endeavor 167 shape:

     (tile-stride C TILE-SPEC (grid-y grid-x)
       [ (let (:let BINDINGS)      ; only when :let is present
           RESET
           PROLOGUE...
           (dotimes (grid-k (/ K k-step)) BODY...)
           EPILOGUE...) ])

   With no :let the wrapping let is omitted entirely, so the legacy call sites lower to
   byte-identical IR.  RESET comes BEFORE the prologue deliberately: that is what lets a
   prologue seed the accumulator (a bias tile) instead of being clobbered by the macro.

   Endeavor 137: no auto-store -- the :epilogue holds the explicit store + any fusion.
   Endeavor 150: refuses a map-elements! on the accumulator inside the reduction body,
   where the accumulator is only a partial sum."
  (multiple-value-bind (let-bindings prologue-body reduction-body epilogue-body)
      (%mmts-split-sections body location)
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
           (let-sym         (intern "LET" cl-pkg))
           (div-sym         (intern "/" cl-pkg))
           (to-ulong-sym    (intern "TO-ULONG" cl-pkg))
           (fill-sym        (intern "FILL-TILE" cl-pkg))
           (sync-sym        (intern "SYNC-WORKGROUP" cl-pkg))
           (reset-forms     (%mmts-reset-forms c-tile let-bindings tile-spec reset-value
                                               fill-sym sync-sym))
           (k-loop          (list* dotimes-sym
                                   (list grid-k
                                         (list div-sym
                                               (list to-ulong-sym k-form)
                                               (list to-ulong-sym k-step)))
                                   reduction-body))
           (inner           (append reset-forms prologue-body (list k-loop) epilogue-body)))
      (append (list tile-stride-sym c-form tile-spec (list grid-y grid-x))
              (if let-bindings
                  (list (list* let-sym let-bindings inner))
                  inner)))))

;; src/analysis/control.lisp
(defun %mmts-let-accumulator-entry (c-tile body location)
  "The :let binding of C-TILE in a matrix-multiply-tile-stride BODY, or NIL.

   With :let the accumulator's dims and declared init sit INSIDE the macro form, so the
   lowering reads its own argument instead of peeking at the enclosing let the way
   %mmts-register-dims-map has to.  That is what lifts the pre-167 constraint that a
   register accumulator be bound in the directly-enclosing let."
  (multiple-value-bind (let-bindings) (%mmts-split-sections body location)
    (and (listp let-bindings) (assoc c-tile let-bindings))))

;; src/analysis/control.lisp
(defun analyze-matrix-multiply-tile-stride-expression (expr env context location)
  "Analyzer for (matrix-multiply-tile-stride C C-tile K <k-step> (gy gx gk) SECTIONS...).

   A register C-tile needs a COMPILE-TIME (M N) size-list tile-spec (a register tile has no
   extents), a scratch C-tile is a real tensor and passes itself as the spec.  Pre-167 the
   register case could only be recognised by the pre-lowering in src/mma.lisp, which reads
   the ENCLOSING let; when the tile is bound in :let the constructor is right here, so this
   path handles it and the emitted inner let trips the SROA explosion on its own."
  (multiple-value-bind (c-form c-tile k-form k-step gy gx gk body)
      (%mmts-parse expr location)
    (let* ((entry     (%mmts-let-accumulator-entry c-tile body location))
           (ctor      (and entry (second entry)))
           (reg-ctor  (and ctor (%register-tile-init-form-p ctor) ctor))
           ;; A :let-bound C-tile cannot name ITSELF as the tile-spec: tile-stride reads the
           ;; spec outside the let the lowering emits, where the symbol is not yet bound
           ;; ("Unknown variable C-TILE").  Both tile constructors carry compile-time dims in
           ;; the same position -- (make-register-tile elem (M N) init) and
           ;; (make-scratch-matrix elem (M N)) -- so the spec comes from the binding.
           (tile-spec (if (and ctor (consp ctor) (listp (third ctor))
                               (every #'integerp (third ctor)))
                          (third ctor)
                          c-tile))
           (reset-val (if reg-ctor (fourth reg-ctor) 0.0)))
      (analyze-expression
       (%mmts-lower c-form c-tile tile-spec k-form k-step gy gx gk body location reset-val)
       env context location))))


;; src/analysis/control.lisp — RE-REGISTRATION (see the header note).
;;
;; src/analysis/control.lisp registers the analyzer BY OBJECT:
;;   (setf (gethash sym *expression-analyzers*) #'analyze-matrix-multiply-tile-stride-expression)
;; which captures the function at load time.  Redefining the defun above is dead code until
;; the table is re-pointed at the new one -- the classic overlay trap.
(let ((sym-cl (intern "MATRIX-MULTIPLY-TILE-STRIDE" (find-package :crisp-language)))
      (sym-cc (intern "MATRIX-MULTIPLY-TILE-STRIDE" (find-package :crisp.compiler))))
  (setf (gethash sym-cl *expression-analyzers*) #'analyze-matrix-multiply-tile-stride-expression)
  (unless (eq sym-cl sym-cc)
    (setf (gethash sym-cc *expression-analyzers*) #'analyze-matrix-multiply-tile-stride-expression)))


;; src/analysis/core.lisp
(defun %mmts-scan-sections (args)
  "Pass-1 scan for a matrix-multiply-tile-stride form's ARGS (the form's cdr).

   WHY THIS EXISTS.  Pass 1 lifts every make-scratch-matrix / make-scratch-cell into an
   implicit kernel argument named <binding>_FROM_<kernel>_<n>, taking <binding> from
   compiler-context-current-binding-name -- which only the LET scanner ever sets.  A macro
   form is not a let, so a scratch tile declared in :let was scanned with no binding name,
   registered as __STORAGE_FROM_<kernel>_<n>, and then codegen went looking for
   A-TILE_FROM_<kernel>_<n> and found nothing:

     Missing implicit argument A-TILE_FROM_MM_LET_ENVELOPE_1 for (TENSOR FLOAT 2 LOCAL ...)

   The storage was allocated -- it was simply allocated under the wrong name.  So the scan
   has to walk :let the way scan-operator walks a let's bindings.

   Mirrors that scanner exactly, including its rule that a MULTIPLE-VALUE binding sets no
   current-binding-name (there is no single variable to name the storage after)."
  (let ((body (nthcdr 5 args)))
    (dolist (a (subseq args 0 (min 5 (length args))))
      (scan-form a))
    (multiple-value-bind (bindings prologue reduction epilogue)
        (%mmts-split-sections body nil)
      (let ((old (compiler-context-current-binding-name *compiler-context*)))
        (dolist (b bindings)
          (when (consp b)
            (let ((named (= (length b) 2)))
              (when named
                (setf (compiler-context-current-binding-name *compiler-context*) (first b)))
              (scan-form (car (last b)))
              (when named
                (setf (compiler-context-current-binding-name *compiler-context*) old))))))
      (dolist (f prologue)  (scan-form f))
      (dolist (f reduction) (scan-form f))
      (dolist (f epilogue)  (scan-form f)))))

;; src/analysis/core.lisp — scan-operator is a GENERIC function, so a method is late-bound
;; and needs no re-registration (unlike the analyzer table above).
(defmethod scan-operator ((op (eql (intern "MATRIX-MULTIPLY-TILE-STRIDE" (find-package :crisp-language)))) args)
  (%mmts-scan-sections args))

(defmethod scan-operator ((op (eql (intern "MATRIX-MULTIPLY-TILE-STRIDE" (find-package :crisp.compiler)))) args)
  (%mmts-scan-sections args))


;; src/autodiff.lisp
(defun %mma-ad-expand-mmts-in-form (form reg-map)
  "Recursively lower every matrix-multiply-tile-stride in FORM (endeavor 145 P8: the AD path
   must do this before ANF).

   THE THIRD CALLER.  %mmts-lower has three: the scratch analyzer in analysis/control.lisp,
   the register pre-lowering in mma.lisp, and this one.  All three destructure through
   %mmts-parse, so 167's sections reach all three -- but each one independently decides the
   TILE-SPEC, and this one decided it from REG-MAP alone (the enclosing let's register-tile
   bindings).  A C-tile declared in the macro's own :let is not in that map, so the spec fell
   back to the C-tile SYMBOL, which the emitted lowering then binds INSIDE the let that
   tile-stride's spec is read outside of:

     Crisp compilation failed ... Unknown variable C-TILE

   under --differentiate only, while the forward pass compiled clean.  So the :let binding is
   consulted first here, exactly as analyze-matrix-multiply-tile-stride-expression does, and
   REG-MAP remains the fallback for the pre-167 enclosing-let shape."
  (cond
    ((not (consp form)) form)
    ((%mmts-head-p form)
     (multiple-value-bind (c-form c-tile k-form k-step gy gx gk body)
         (%mmts-parse form nil)
       (let* ((entry     (assoc c-tile reg-map))
              (let-entry (%mmts-let-accumulator-entry c-tile body nil))
              (ctor      (and let-entry (second let-entry)))
              (reg-ctor  (and ctor (%register-tile-init-form-p ctor) ctor))
              (tile-spec (cond
                           ;; Declared in :let -- take the dims from the constructor.
                           ((and ctor (consp ctor) (listp (third ctor))
                                 (every #'integerp (third ctor)))
                            (third ctor))
                           ;; Pre-167: a register tile in the enclosing let.
                           (entry (second entry))
                           (t c-tile)))
              (reset-val (cond (reg-ctor (fourth reg-ctor))
                               (entry    (third entry))
                               (t        0.0))))
         (%mmts-lower c-form c-tile tile-spec k-form k-step gy gx gk
                      (mapcar (lambda (f) (%mma-ad-expand-mmts-in-form f reg-map)) body)
                      nil
                      reset-val))))
    (t (mapcar (lambda (f) (%mma-ad-expand-mmts-in-form f reg-map)) form))))
