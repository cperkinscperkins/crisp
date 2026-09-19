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
;;;; Emptied 2026-09-18: everything folded into src/ (endeavour 167 sections --
;;;; :let / :prologue / :body / :epilogue -- into src/analysis/control.lisp and
;;;; src/autodiff.lisp).  Previously emptied 2026-09-16 (endeavour 170 + BUG 060).

(in-package :crisp.compiler)


;;; ============================================================================
;;; ENDEAVOUR 172 -- dotimes variants (dec-times, dec-times-by-half, dec-times-by-factor,
;;; do-times-by-doubling, do-times-by-multiply, do-power-step, dec-power-step, each with +).
;;; Decisions D1-D7: tests/spec/172-do-times-variants/do-times-variants.md
;;; ============================================================================

;; src/anf-transform.lisp  (near the top; used by anf-transform AND autodiff)
(defparameter *dotimes-family-names*
  '("DOTIMES" "DOTIMES+"
    "DEC-TIMES" "DEC-TIMES+"
    "DEC-TIMES-BY-HALF" "DEC-TIMES-BY-HALF+"
    "DEC-TIMES-BY-FACTOR" "DEC-TIMES-BY-FACTOR+"
    "DO-TIMES-BY-DOUBLING" "DO-TIMES-BY-DOUBLING+"
    "DO-TIMES-BY-MULTIPLY" "DO-TIMES-BY-MULTIPLY+"
    "DO-POWER-STEP" "DO-POWER-STEP+"
    "DEC-POWER-STEP" "DEC-POWER-STEP+")
  "Endeavour 172: the head names of the counted-loop family.  Every member has the shape
   (HEAD (VAR OPERAND...) BODY...): VAR is bound in BODY, the operands are evaluated once
   before the loop.  ANF and the AD walker treat all of them exactly like dotimes.")

;; src/anf-transform.lisp
(defun %dotimes-family-head-p (head)
  "True when HEAD names a counted-loop family member (dotimes, dec-times, ... and their
   + variants), compared by symbol name so the reading package does not matter."
  (and head (symbolp head)
       (member (symbol-name head) *dotimes-family-names* :test #'string-equal)
       t))

;; src/anf-transform.lisp  (replaces the 092 version: normalizes EVERY binding operand, so
;; it serves dotimes' (var limit [stride]) and the variants' up-to-three operands alike)
(defun %anf-normalize-dotimes (op expr is-nested?)
  "ANF-normalizes a counted-loop family form (OP (VAR OPERAND...) BODY...).  Each operand is
   normalized to an atom (its bindings hoisted ahead of the loop, in order); the body is
   transformed in place, never hoisted.  When IS-NESTED? the loop is bound to a fresh temp."
  (let* ((binding (cadr expr))
         (var (car binding))
         (operands (cdr binding))
         (body (cddr expr))
         (new-operands nil)
         (hoisted nil))
    (dolist (o operands)
      (multiple-value-bind (new-o o-bindings) (anf-normalize o t)
        (push new-o new-operands)
        (setf hoisted (append hoisted o-bindings))))
    (let* ((anf-body (mapcar #'%anf-transform body))
           (anf-loop `(,op (,var ,@(nreverse new-operands)) ,@anf-body)))
      (log:debug "ANF counted loop ~a: ~d operand(s), ~d hoisted binding(s)"
                 op (length operands) (length hoisted))
      (if is-nested?
          (let ((temp (anf-fresh-temp)))
            (values temp (append hoisted `((,temp ,anf-loop)))))
          (values anf-loop hoisted)))))

;; src/semantic.lisp  (NEW struct.  :include makes it a semantic-dotimes, so the core.lisp
;; etypecases -- semantic-node-type / source-location -- cover it with no new clause)
(defstruct (semantic-loop-variant (:include semantic-dotimes))
  "Endeavour 172: a dotimes-family loop other than dotimes itself.
   KIND is one of :dec-times :dec-by-factor :multiply :power-up :power-down.
   Inherited slots: LIMIT-NODE is N (or the limit), STRIDE-NODE the dec-times stride (NIL = 1).
   INIT-NODE is the multiply start (NIL = 1), FACTOR-NODE the factor (NIL = 2).
   VAR-TYPE is the loop variable's type: N's type."
  kind
  init-node
  factor-node
  var-type)

;; src/analysis/control.lisp
(defparameter *loop-variant-specs*
  ;; head                   kind           operand roles (in binding order)
  '(("DEC-TIMES"            :dec-times     (:n &optional :stride))
    ("DEC-TIMES-BY-HALF"    :dec-by-factor (:n))
    ("DEC-TIMES-BY-FACTOR"  :dec-by-factor (:n :factor))
    ("DO-TIMES-BY-DOUBLING" :multiply      (:init :n))
    ("DO-TIMES-BY-MULTIPLY" :multiply      (:init :n :factor))
    ("DO-POWER-STEP"        :power-up      (:n))
    ("DEC-POWER-STEP"       :power-down    (:n)))
  "Endeavour 172: per-head lowering kind and operand roles.  The + variant of each head
   shares its entry (the trailing + is stripped before lookup).")

;; src/analysis/control.lisp
(defun %loop-variant-role-name (role)
  "Display name of a loop-variant operand role: N, init, stride or factor."
  (if (eq role :n) "N" (string-downcase (symbol-name role))))

;; src/analysis/control.lisp
(defun %loop-variant-usage (head-name roles)
  "The usage text for a loop-variant head, e.g. (dec-times (i N [stride]) body...)."
  (let ((parts (loop with opt = nil
                     for r in roles
                     if (eq r '&optional)
                       do (setf opt t)
                     else
                       collect (let ((nm (%loop-variant-role-name r)))
                                 (if opt (format nil "[~a]" nm) nm)))))
    (format nil "(~(~a~) (i~{ ~a~}) body...)" head-name parts)))

;; src/analysis/control.lisp
(defun %analyze-loop-variant-operand (form role head-name env context location)
  "Analyzes one loop-variant operand and enforces D2 and the literal half of D3.
   A non-negative integer literal becomes a ulong literal node; a negative literal, a signed
   or a float operand is an error.  Literal gates: init and stride must be greater than 0,
   factor greater than 1.  Returns the analyzed node."
  (let ((role-name (%loop-variant-role-name role))
        (node nil))
    (cond
      ((integerp form)
       (when (minusp form)
         (error 'crisp-compiler-error
                :message (format nil "~(~a~): ~a must be an unsigned integer (a non-negative literal), got ~a"
                                 head-name role-name form)
                :source-location location))
       (setf node (make-semantic-literal :value-type 'ulong :value form :source-location location)))
      (t
       (setf node (analyze-expression form env context location))
       (let* ((ty (get-single-value-type node))
              (ct (gethash ty *crisp-types*)))
         (unless (and ct (eq (crisp-type-category ct) :unsigned-int))
           (error 'crisp-compiler-error
                  :message (format nil "~(~a~): ~a must be an unsigned integer type, got ~a"
                                   head-name role-name ty)
                  :source-location location)))))
    ;; D3, literal half.  (The runtime half is the codegen guard: zero iterations.)
    (when (and (semantic-literal-p node) (integerp (semantic-literal-value node)))
      (let ((v (semantic-literal-value node)))
        (when (and (member role '(:init :stride)) (< v 1))
          (error 'crisp-compiler-error
                 :message (format nil "~(~a~): ~a must be greater than 0, got ~a" head-name role-name v)
                 :source-location location))
        (when (and (eq role :factor) (< v 2))
          (error 'crisp-compiler-error
                 :message (format nil "~(~a~): factor must be greater than 1, got ~a" head-name v)
                 :source-location location))))
    node))

;; src/analysis/control.lisp
(defun analyze-loop-variant-expression (expr env context location)
  "Analyzes every dotimes variant and its + form (endeavour 172):
     (dec-times            (i N [stride]) body...)    i = ((N-1)/s)*s ... 0, the exact reverse of dotimes
     (dec-times-by-half    (i N) body...)             i = N, N/2, ... 1
     (dec-times-by-factor  (i N factor) body...)      i = N, N/f, ... >= 1
     (do-times-by-doubling (i init N) body...)        i = init, 2*init, ... <= N
     (do-times-by-multiply (i init N factor) body...) i = init, init*f, ... <= N
     (do-power-step        (i N) body...)             i = 1, 2, 4, ... < N
     (dec-power-step       (i N) body...)             i = largest power of 2 below N, ... 1
   Operands must be unsigned (D2); literal gates per D3.  A + form requires every operand to
   be provably uniform (D5).  The loop variable takes N's type and the combined uniformity of
   all operands.  Returns a semantic-loop-variant."
  (let* ((head (car expr))
         (head-name (symbol-name head))
         (plus-p (and (> (length head-name) 1)
                      (char= (cl:char head-name (1- (length head-name))) #\+)))
         (base-name (if plus-p (subseq head-name 0 (1- (length head-name))) head-name))
         (spec (find base-name *loop-variant-specs* :key #'first :test #'string-equal))
         (kind (second spec))
         (roles (third spec))
         (required (loop for r in roles until (eq r '&optional) collect r))
         (all-roles (remove '&optional roles))
         (binding (and (consp (cdr expr)) (second expr))))
    (unless spec
      (error 'crisp-compiler-error
             :message (format nil "Internal: no loop-variant spec for ~a" head-name)
             :source-location location))
    (unless (and (consp binding) (symbolp (first binding))
                 (<= (1+ (length required)) (length binding) (1+ (length all-roles))))
      (error 'crisp-compiler-error
             :message (format nil "Malformed ~(~a~): expected ~a"
                              head-name (%loop-variant-usage base-name roles))
             :source-location location))
    (let* ((var-name (first binding))
           (operand-forms (rest binding))
           (nodes (loop for form in operand-forms
                        for role in all-roles
                        for k from 1
                        collect (cons role (%analyze-loop-variant-operand
                                            form role base-name env context
                                            (append location (list 0 k))))))
           (n-node (cdr (assoc :n nodes)))
           (var-type (get-single-value-type n-node))
           (states (mapcar (lambda (p) (cons (car p) (calculate-uniformity-state (cdr p) env)))
                           nodes))
           (combined (cond ((some (lambda (s) (eq (cdr s) :divergent)) states) :divergent)
                           ((some (lambda (s) (eq (cdr s) :unknown)) states) :unknown)
                           (t :uniform))))
      (log:debug "~a: kind ~s, var ~a : ~a, operand uniformity ~s" head-name kind var-name var-type states)
      (when plus-p
        (let ((bad (find-if-not (lambda (s) (eq (cdr s) :uniform)) states)))
          (when bad
            (error 'crisp-compiler-error
                   :message (format nil "~(~a~) requires every operand to be provably uniform; ~a is ~(~a~).~@[ ~a~]"
                                    head-name (%loop-variant-role-name (car bad)) (cdr bad)
                                    (when (eq (cdr bad) :unknown)
                                      "Use (declare (uniform ...)) if it is uniform."))
                   :source-location location))))
      (let* ((body-env (cons (make-parameter-def :name var-name :type var-type :kind :local
                                                 :uniformity combined)
                             env))
             (*divergent-scope-depth* (if (eq combined :uniform)
                                          *divergent-scope-depth*
                                          (1+ *divergent-scope-depth*)))
             (body-nodes (analyze-body-expressions (cddr expr) body-env context (append location '(1)))))
        (make-semantic-loop-variant :type 'void
                                    :var-name var-name
                                    :var-type var-type
                                    :kind kind
                                    :limit-node n-node
                                    :stride-node (cdr (assoc :stride nodes))
                                    :init-node (cdr (assoc :init nodes))
                                    :factor-node (cdr (assoc :factor nodes))
                                    :body body-nodes
                                    :source-location location)))))

;; src/analysis/control.lisp
(defun register-loop-variant-analyzers ()
  "Endeavour 172: registers analyze-loop-variant-expression for every dotimes variant and its
   + form, under BOTH :crisp-language and :crisp.compiler (as dotimes is).  Called from
   register-control-analyzers, so it survives initialize-compiler's clrhash."
  (dolist (name (remove-if (lambda (n) (member n '("DOTIMES" "DOTIMES+") :test #'string=))
                           *dotimes-family-names*))
    (dolist (pkg (list (find-package :crisp-language) (find-package :crisp.compiler)))
      (when pkg
        (setf (gethash (intern name pkg) *expression-analyzers*) #'analyze-loop-variant-expression))))
  (log:debug "registered ~d loop-variant analyzers" (- (length *dotimes-family-names*) 2)))

;; src/codegen.lisp
(defun %loop-variant-coerce (builder value llvm-type)
  "Zero-extends or truncates the unsigned integer VALUE to LLVM-TYPE (the loop variable's type)."
  (let ((from (crisp.llvm-bindings::llvm-get-int-type-width (llvm-type-of value)))
        (to (crisp.llvm-bindings::llvm-get-int-type-width llvm-type)))
    (cond ((= from to) value)
          ((< from to) (llvm-build-zext builder value llvm-type "lv_zext"))
          (t (llvm-build-trunc builder value llvm-type "lv_trunc")))))

;; src/codegen.lisp
(defmethod generate-node-ir ((node semantic-loop-variant) builder module var-env di-builder di-scope location-map)
  "Generates a dotimes-variant loop (endeavour 172) as a GUARDED, BOTTOM-TESTED loop:
     entry:  operands; GUARD -> pre | exit      (runtime D3 gates: bad operands = zero trips)
     pre:    start value, loop invariants; -> body   (divisions happen only past the guard)
     body:   BODY; next = step(i); cont = test(i) -> body | exit
   Every step is overflow-safe, so termination does not depend on the operand values:
     :dec-times      guard N/=0, s/=0   start ((N-1)/s)*s      cont i >= s       next i - s
     :dec-by-factor  guard N/=0, f>1    start N                cont next /= 0    next i / f
     :multiply       guard init/=0, f>1, init<=N; lim = N/f;   cont i <= lim     next i * f
     :power-up       guard N>1          start 1, lim=(N-1)/2   cont i <= lim     next i * 2
     :power-down     guard N>1          start 2^(W-1-clz(N-1)) cont next /= 0    next i / 2
   The loop variable lives in an alloca (mem2reg promotes it), as in dotimes."
  (let* ((kind (semantic-loop-variant-kind node))
         (var-name (semantic-loop-variant-var-name node))
         (llvm-type (crisp-type-to-llvm-type (semantic-loop-variant-var-type node) module))
         (width (crisp.llvm-bindings::llvm-get-int-type-width llvm-type))
         (current-fn (llvm-get-basic-block-parent (llvm-get-insert-block builder))))
    (flet ((gen (n) (when n
                      (%loop-variant-coerce
                       builder
                       (generate-node-ir n builder module var-env di-builder di-scope location-map)
                       llvm-type)))
           (k (v) (llvm-const-int llvm-type v 0))
           (cmp (pred a b) (llvm-build-icmp builder pred a b "lv_cmp"))
           (all (&rest cs) (reduce (lambda (a b) (crisp.llvm-bindings::llvm-build-and builder a b "lv_guard")) cs)))
      (let* ((n-val (gen (semantic-loop-variant-limit-node node)))
             (s-val (or (gen (semantic-loop-variant-stride-node node)) (k 1)))
             (init-val (or (gen (semantic-loop-variant-init-node node)) (k 1)))
             (f-val (or (gen (semantic-loop-variant-factor-node node)) (k 2)))
             (guard (ecase kind
                      (:dec-times (all (cmp +llvm-int-ne+ n-val (k 0)) (cmp +llvm-int-ne+ s-val (k 0))))
                      (:dec-by-factor (all (cmp +llvm-int-ne+ n-val (k 0)) (cmp +llvm-int-ugt+ f-val (k 1))))
                      (:multiply (all (cmp +llvm-int-ne+ init-val (k 0)) (cmp +llvm-int-ugt+ f-val (k 1))
                                      (cmp +llvm-int-ule+ init-val n-val)))
                      ((:power-up :power-down) (cmp +llvm-int-ugt+ n-val (k 1)))))
             (i-alloca (llvm-build-alloca builder llvm-type (string-downcase (symbol-name var-name))))
             (pre-block (llvm-append-basic-block current-fn "lv_pre"))
             (body-block (llvm-append-basic-block current-fn "lv_body"))
             (exit-block (llvm-append-basic-block current-fn "lv_exit"))
             (lim nil))
        (log:debug "loop-variant codegen: ~s var ~a i~d" kind var-name width)
        (llvm-build-cond-br builder guard pre-block exit-block)
        ;; --- pre: start value + loop invariants (divisions are safe past the guard) ---
        (llvm-position-builder-at-end builder pre-block)
        (let ((start
                (ecase kind
                  (:dec-times
                   (llvm-build-mul builder
                                   (llvm-build-udiv builder (llvm-build-sub builder n-val (k 1) "lv_nm1")
                                                    s-val "lv_q")
                                   s-val "lv_start"))
                  (:dec-by-factor n-val)
                  (:multiply
                   (setf lim (llvm-build-udiv builder n-val f-val "lv_lim"))
                   init-val)
                  (:power-up
                   (setf lim (crisp.llvm-bindings::llvm-build-l-shr builder (llvm-build-sub builder n-val (k 1) "lv_nm1")
                                               (k 1) "lv_lim"))
                   (k 1))
                  (:power-down
                   (let* ((nm1 (llvm-build-sub builder n-val (k 1) "lv_nm1"))
                          (clz (%hw-call builder module (format nil "llvm.ctlz.i~d" width) llvm-type
                                         (list nm1 (llvm-const-int (llvm-int1-type) 0 0)) "lv_clz"))
                          (sh (llvm-build-sub builder (k (1- width)) clz "lv_sh")))
                     (crisp.llvm-bindings::llvm-build-shl builder (k 1) sh "lv_start"))))))
          (llvm-build-store builder start i-alloca))
        (llvm-build-br builder body-block)
        ;; --- body ---
        (llvm-position-builder-at-end builder body-block)
        (let ((body-env (alexandria:copy-hash-table var-env)))
          (setf (gethash var-name body-env) i-alloca)
          (dolist (body-node (semantic-loop-variant-body node))
            (generate-node-ir body-node builder module body-env di-builder di-scope location-map)))
        ;; --- latch: step + continue test, overflow-safe ---
        (unless (terminator-p (llvm-get-insert-block builder))
          (let* ((i-cur (llvm-build-load2 builder llvm-type i-alloca "i_cur"))
                 (next nil)
                 (cont nil))
            (ecase kind
              (:dec-times
               (setf next (llvm-build-sub builder i-cur s-val "i_next")
                     cont (cmp +llvm-int-uge+ i-cur s-val)))
              ((:dec-by-factor :power-down)
               (setf next (if (eq kind :power-down)
                              (crisp.llvm-bindings::llvm-build-l-shr builder i-cur (k 1) "i_next")
                              (llvm-build-udiv builder i-cur f-val "i_next"))
                     cont (cmp +llvm-int-ne+ next (k 0))))
              ((:multiply :power-up)
               (setf next (if (eq kind :power-up)
                              (crisp.llvm-bindings::llvm-build-shl builder i-cur (k 1) "i_next")
                              (llvm-build-mul builder i-cur f-val "i_next"))
                     cont (cmp +llvm-int-ule+ i-cur lim))))
            (llvm-build-store builder next i-alloca)
            (llvm-build-cond-br builder cont body-block exit-block)))
        (llvm-position-builder-at-end builder exit-block)
        (values nil nil)))))

;; src/anf-transform.lisp  (endeavour 172: backward loop head for a family member)
(defun %dotimes-backward-head (head)
  "The head the AD backward walk emits for a forward counted loop HEAD: the plain (non +)
   form, since the backward kernel re-checks nothing about uniformity.  DOTIMES and DOTIMES+
   map to the dotimes symbol exactly as before endeavour 172."
  (let* ((nm (symbol-name head))
         (base (string-right-trim "+" nm)))
    (if (string-equal base "DOTIMES")
        'dotimes
        (intern base (symbol-package head)))))

;; src/anf-transform.lisp  (endeavour 172: whole-function copy of the src/ definition at line 164;
;; the ONLY change is the DOTIMES/DOTIMES+ name test -> %dotimes-family-head-p)
(defun anf-normalize (expr is-nested?)
  "Returns (VALUES normalized-expr bindings-list).
   Phase 1c: added opaque pass-through for load-tile-at / store-tile-at
   and their internal *-bwd / bare load-tile / store-tile variants."
  (cond
   ((anf-is-atomic? expr)
     (values expr nil))

   ((consp expr)
     (let ((op (car expr)))
       (when (and (symbolp op)
                  (macro-function op)
                  (not (member op '(when when+ unless unless+ cond cond+ if if+ return dotimes dotimes+ while set! declare progn let
                                          template-instantiation def-function def-kernel def-kernel-exact make-scratch-cell make-scratch-vector make-scratch-matrix make-scratch-tensor as quote compiler-no-op
                                          make-cell make-vector make-matrix make-tensor))))
             (multiple-value-bind (expanded changed) (macroexpand-1 expr)
               (when changed
                     (return-from anf-normalize (anf-normalize expanded is-nested?)))))
       (cond
        ((and (symbolp op)
              (member (symbol-name op)
                      '("LOAD-TILE-AT" "STORE-TILE-AT"
                        "%LOAD-TILE-AT-BWD" "%STORE-TILE-AT-BWD"
                        "LOAD-TILE" "STORE-TILE"
                        ;; Endeavor 132 (MMA) — store-fragment / make-register-tile carry
                        ;; coord / dim LISTS that must stay opaque to ANF.
                        "STORE-FRAGMENT" "MAKE-REGISTER-TILE" "MMA-ACCUMULATE-VIA-TILE"
                        ;; Endeavour 158: PREFETCH-TILE carries a coord tuple AND a :size
                        ;; tuple, and ANF flattened BOTH into bindings, so
                        ;;     (prefetch-tile A (grid-y grid-k) :size (32 16))
                        ;; arrived at the backward walk as
                        ;;     (LET ((%ANF-T-1 (GRID-Y GRID-K)) (%ANF-T-2 (32 16))) ...)
                        ;; where %ANF-T-1 reads as a CALL to a function named GRID-Y --
                        ;; really a tile-stride index -- reporting "Function GRID-Y is not
                        ;; differentiable".  Endeavour 146 had ALREADY placed PREFETCH-TILE
                        ;; on %backward-skip-fn-p as the pure scheduling hint it is; AD
                        ;; never got to use that entry because ANF destroyed the form
                        ;; first.  This is the third blocker 142/14's skip note predicted,
                        ;; named there as "in ANF rather than AD".
                        ;;
                        ;; Safe by construction: anf-transform runs on the AD path ONLY
                        ;; (see src/macros.lisp:982, "the forward still analyses the
                        ;; original form"), so no shipped prefetch kernel's forward
                        ;; lowering can be affected by this entry.
                        "PREFETCH-TILE")
                      :test #'string=))
          (if is-nested?
              (let ((temp (anf-fresh-temp)))
                (values temp `((,temp ,expr))))
              (values expr nil)))
        ((eq op 'set!)
          (%anf-normalize-set! expr is-nested?))
        ((member op '(if when unless))
          (%anf-normalize-if op expr is-nested?))
        ((member op '(if+ when+ unless+))
          (%anf-normalize-if+ op expr is-nested?))
        ((eq op 'cond)
          (%anf-normalize-cond expr is-nested?))
        ((eq op 'let)
          (%anf-normalize-let expr is-nested?))
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
        ;; Endeavor 126 (pass 5b): with-precision is a codegen precision annotation,
        ;; transparent to the derivative STRUCTURE. For the backward/AD pipeline, ANF
        ;; it as a progn of its body (drop the region wrapper). The FORWARD kernel
        ;; keeps the region precision (its semantic-with-precision codegen is
        ;; untouched); only the backward pipeline drops it, so the backward ops use
        ;; the ambient precision — correct for the gradient value.
        ((and (symbolp op) (string-equal (symbol-name op) "WITH-PRECISION"))
          (let ((body (cddr expr)))
            (if (= (length body) 1)
                ;; Single value form (the common case): ANF it directly so the
                ;; backward walk sees the bare expression, not a progn wrapper.
                (anf-normalize (car body) is-nested?)
                ;; Multi-form body: fall back to progn semantics.
                (anf-normalize (cons 'progn body) is-nested?))))
        ((and (symbolp op) (%dotimes-family-head-p op))
          (%anf-normalize-dotimes op expr is-nested?))
        ((and (symbolp op) (string-equal (symbol-name op) "WHILE"))
          (%anf-normalize-while op expr is-nested?))
        ((and (symbolp op)
              (member (symbol-name op)
                      '("ATOMIC-ADD!" "ATOMIC-SUB!" "ATOMIC-INC!" "ATOMIC-DEC!"
                        "ATOMIC-MIN!" "ATOMIC-MAX!" "ATOMIC-XCHG!" "ATOMIC-SET!")
                      :test #'string=))
          (%anf-normalize-atomic op expr is-nested?))
        (t
          (let ((args (cdr expr)))
            (multiple-value-bind (anf-args bindings) (anf-normalize-args args)
              (let ((call `(,op ,@anf-args)))
                (if is-nested?
                    (let ((temp (anf-fresh-temp)))
                      (values temp (append bindings `((,temp ,call)))))
                    (values call bindings)))))))))

   (t (error "Unsupported form for anf-transform: ~S" expr))))

;; src/autodiff.lisp  (endeavour 172: whole-function copy of the src/ definition at line 1059;
;; the ONLY change is the DOTIMES/DOTIMES+ name test -> %dotimes-family-head-p)
(defun %collect-locally-bound-vars (body-forms)
  "Returns a list of distinct symbols introduced as bindings anywhere
   inside BODY-FORMS (a list of forms).  Includes single-value bindings
   `(v expr)`, multi-value bindings `(v0 v1 ... expr)`, the induction var
   of nested DOTIMES, and the bound vars of nested LET.  Recurses through
   LET / DOTIMES / IF / PROGN / WHEN / UNLESS bodies.  SET! and DECLARE
   introduce no bindings, so they are not scanned.  Used by the AD walker
   to identify adjoint allocas that must be reset at the top of each
   backward loop iteration."
  (let ((vars nil))
    (labels ((push-var (v)
                       (when (and (symbolp v) (not (member v vars :test #'eq)))
                             (push v vars)))
             (scan (form)
                   (cond
                    ((or (null form) (symbolp form) (not (consp form))) nil)
                    ((not (symbolp (car form))) nil)
                    ((or (string-equal (symbol-name (car form)) "DECLARE")
                         (string-equal (symbol-name (car form)) "SET!")) nil)
                    ((string-equal (symbol-name (car form)) "LET")
                      (dolist (b (cadr form))
                        (when (and (consp b) (symbolp (car b)))
                              (push-var (car b))))
                      (dolist (b (cddr form)) (scan b)))
                    ((%dotimes-family-head-p (car form))
                      (let ((binding (cadr form)))
                        (when (and (consp binding) (symbolp (car binding)))
                              (push-var (car binding))))
                      (dolist (b (cddr form)) (scan b)))
                    ((string-equal (symbol-name (car form)) "IF")
                      (when (caddr form) (scan (caddr form)))
                      (when (cadddr form) (scan (cadddr form))))
                    ((or (string-equal (symbol-name (car form)) "WHEN")
                         (string-equal (symbol-name (car form)) "UNLESS"))
                      (dolist (sub (cddr form)) (scan sub)))
                    ((string-equal (symbol-name (car form)) "PROGN")
                      (dolist (sub (cdr form)) (scan sub)))
                    ;; Single-value binding: (v expr)
                    ((and (= (length form) 2) (symbolp (car form)))
                      (push-var (car form)))
                    ;; Multi-value binding: (v0 v1 ... expr) where all but last are syms
                    ((and (>= (length form) 3)
                          (every #'symbolp (butlast form)))
                      (dolist (v (butlast form)) (push-var v)))
                    (t nil))))
      (dolist (f body-forms) (scan f)))
    (nreverse vars)))

;; src/autodiff.lisp  (endeavour 172: whole-function copy of the src/ definition at line 1991;
;; the ONLY change is the DOTIMES/DOTIMES+ name test -> %dotimes-family-head-p)
(defun generate-backward-walk (flat-anf inputs outputs input-types output-types
                                        &key kernel-pkg)
  "Walks an ANF body backwards to accumulate adjoints.
   Phase 1c: adds LOAD-TILE-AT / STORE-TILE-AT clauses to process-form
   that emit %load-tile-at-bwd / %store-tile-at-bwd with the correct
   adjoint symbols.  Also extends the LET case to auto-allocate paired
   <var>_ADJ scratch tensors for make-scratch-* bindings.

   Bug 032 fix: SET! on a local-scratch tile (target neither input nor
   output) now emits a proper consume + reset pair so the RHS chain rule
   propagates through tile mutations.

   Endeavor 146: FLAT-ANF is normalized before anything reads it, and the assembled
   backward gets one fixup on the way out.  See %ad-normalize-anf-for-backward for what
   the normalizations are and why their order matters, and %ad-ensure-ring-adj-bindings
   for the gap the fixup covers (the top-level adjoint collection below does not know the
   ring constructors, so a ring bound at kernel top level otherwise gets no adjoint)."
  (setf flat-anf (%ad-normalize-anf-for-backward flat-anf))
  ;; Endeavour 170: (S C (op-sincos-approx X)) is a multi-value binding, and the multi-value clause
  ;; in process-form only differentiates REGISTERED functions -- so it would contribute NOTHING and
  ;; the gradient would be silently zero (BUG 063).  Splitting it into (S (op-sin-approx X)) and
  ;; (C (op-cos-approx X)) hands it to the ordinary per-op rules: dx = cos(x)*s_adj - sin(x)*c_adj.
  (setf flat-anf (%hw-split-sincos-bindings flat-anf))
  (let ((*ad-barrier-ring-syms* (%ad-collect-barrier-ring-syms flat-anf))
        (*ad-view-alias-map*    (%ad-collect-view-aliases flat-anf)))
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
    (let ((*record-param-field-adjs* record-param-field-adjs-ht)
          ;; Endeavor 123 (FFI-AD): map each pointer temp bound via
          ;; (t (base-ptr~ src)) to its source storage sym, so a foreign call's
          ;; pointer arg can route its shadow to <src>_GRAD.
          (*ffi-baseptr-src*
           (let ((ht (make-hash-table :test 'eq)))
             (loop for form in flat-anf
                     when (and (consp form) (= (length form) 2)
                               (symbolp (car form))
                               (consp (cadr form)) (symbolp (caadr form))
                               (string-equal (symbol-name (caadr form)) "BASE-PTR~")
                               (symbolp (second (cadr form))))
                   do (setf (gethash (car form) ht) (second (cadr form))))
             ht)))
      (let ((backward-forms nil)
            (adjoint-map (make-hash-table :test 'equal))
            (tensor-inputs-ht
             (let ((ht (make-hash-table :test 'eq)))
               (loop for sym in inputs
                     for typ in input-types
                       when (%crisp-float-tensor-type-p typ)
                     do (setf (gethash sym ht) typ))
               ht))
            ;; Bug 032: collect locally-bound scratch tile syms (those
            ;; bound via make-scratch-vector / -matrix / -tensor / -cell
            ;; anywhere in flat-anf) so the `~` and SET! backward cases
            ;; can route indexed accesses on them to their _ADJ tensor
            ;; instead of polluting the scalar adjoint-map.
            (scratch-tile-syms
             (let ((ht (make-hash-table :test 'eq)))
               (loop for form in flat-anf
                       when (and (consp form) (= (length form) 2)
                                 (symbolp (car form))
                                 (consp (cadr form)) (symbolp (caadr form))
                                 (member (symbol-name (caadr form))
                                         '("MAKE-SCRATCH-VECTOR" "MAKE-SCRATCH-MATRIX"
                                                                 "MAKE-SCRATCH-TENSOR" "MAKE-SCRATCH-CELL")
                                         :test #'string=))
                     do (setf (gethash (car form) ht) t))
               ht)))
        ;; BUG 037: publish the staged-tile -> global-source map and the scratch-tile set so the
        ;; primal replay can read a staged tile's values from where they actually came from.
        (setf *ad-tile-src-map* (%mma-ad-tile-source-map flat-anf)
              *ad-scratch-syms* scratch-tile-syms)
        ;; Endeavour 149 (AD primal replay): start this kernel with no outstanding replay
        ;; requests, and publish the &out parameters.  Those are the only globals the
        ;; forward may have mutated -- inputs are read-only under --differentiate -- so a
        ;; replayed statement that READS one is rebuilding a tile from memory the backward
        ;; cannot vouch for.  %ad-replay-check-safe refuses on exactly that.
        (setf *ad-replay-pending* nil
              *ad-output-syms* outputs)
        ;; Endeavor 124 C/A2: the adjoint-typing decision now lives in one place
        ;; (%ad-promotes-to-double-p / %ad-zero) shared with the sub-fn, FFI and
        ;; value-if/let paths.
        (flet ((promotes-to-double-p (t-spec) (%ad-promotes-to-double-p t-spec)))
          (let* ((any-output-double (some #'promotes-to-double-p output-types))
                 (*ad-any-output-double* any-output-double)
                 (intermediate-zero (%ad-zero any-output-double)))
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
                                            (let* ((param-syms (getf hof-data :param-syms))
                                                   (fn-param-idx (getf hof-data :fn-param-idx))
                                                   (body-forms (getf hof-data :body-forms))
                                                   (fn-arg (nth fn-param-idx args))
                                                   (concrete-fn (cond
                                                                 ((and (consp fn-arg) (eq (car fn-arg) 'function))
                                                                   (cadr fn-arg))
                                                                 ((symbolp fn-arg) fn-arg)
                                                                 (t nil))))
                                              (unless concrete-fn
                                                (error "Cannot inline-differentiate HOF ~A:  could not resolve concrete fn from arg ~A" fn fn-arg))
                                              (let* ((fn-param (nth fn-param-idx param-syms))
                                                     (subst-alist
                                                      (loop for p in param-syms
                                                            for a in args
                                                            for i from 0
                                                              unless (= i fn-param-idx)
                                                            collect (cons p a)))
                                                     (subst-body (mapcar (lambda (f) (%subst-form f subst-alist)) body-forms))
                                                     (concrete-body (mapcar (lambda (f) (%remove-funcall f fn-param concrete-fn))
                                                                        subst-body))
                                                     (anf-body (mapcar #'anf-transform concrete-body))
                                                     (hof-flat (flatten-anf-body anf-body))
                                                     (hof-flat-norm
                                                      (let ((last-f (car (last hof-flat))))
                                                        (if (or (symbolp last-f)
                                                                (and (consp last-f) (eq (first last-f) 'return)))
                                                            hof-flat
                                                            (let ((ret-sym (intern (format nil "%HOF_RET_~A" (symbol-name v))
                                                                                   (symbol-package v))))
                                                              (append (butlast hof-flat)
                                                                (list (list ret-sym last-f) ret-sym))))))
                                                     (return-vars (%extract-return-vars hof-flat-norm)))
                                                (dolist (rv return-vars)
                                                  (setf (gethash rv adjoint-map) (local-adj v)))
                                                (dolist (hf-form (reverse hof-flat-norm))
                                                  (when (and (consp hf-form) (= (length hf-form) 2) (symbolp (car hf-form)))
                                                        (let ((hv (car hf-form))
                                                              (hexpr (cadr hf-form)))
                                                          (%handle-single-value-backward hv hexpr adjoint-map #'emit #'local-adj
                                                                                         :hof-handler-fn #'hof-inline-backward
                                                                                         :error-on-unknown t
                                                                                         :tensor-inputs-ht nil
                                                                                         :scratch-tile-syms scratch-tile-syms))))))))
                     (process-form (form emit-fn)
                       ;; VJP REGISTRY DISPATCH (see the registry block in this overlay).
                       ;; Runs BEFORE the hand-written clauses and DECLINES (NIL) when nothing
                       ;; applies, so an empty registry is provably a no-op and migration can
                       ;; proceed one primitive at a time.
                       (let* ((%vjp-binding (when (and (consp form) (= (length form) 2)
                                                       (symbolp (car form)) (consp (cadr form)))
                                              (car form)))
                              (%vjp-target (if %vjp-binding (cadr form) form))
                              (%vjp (%try-vjp %vjp-target
                                             (list :flat-anf flat-anf
                                                   :inputs inputs
                                                   :outputs outputs
                                                   :local-adj #'local-adj
                                                   :binding-var %vjp-binding
                                                   :kernel-pkg kernel-pkg))))
                        (if %vjp
                            (unless (eq %vjp :inert) (funcall emit-fn %vjp))
                            (cond
                                    ((and (consp form) (symbolp (car form))
                                          (string-equal (symbol-name (car form)) "DECLARE")) nil)

                                    ;; Endeavor 145 P8: a tile load/store in VALUE position.
                                    ;; ANF binds a compound form to a temp whenever it sits in
                                    ;; value position — and the epilogue of
                                    ;; matrix-multiply-tile-stride ends with
                                    ;; `(store-tile C-tile C (grid-y grid-x))`, so a
                                    ;; multi-workgroup matmul reaches the walk as
                                    ;; `(%t (store-tile-at ...))` rather than a bare statement.
                                    ;; Every tile-load/store rule below matches only the
                                    ;; STATEMENT shape, so the binding fell through to
                                    ;; %handle-single-value-backward and errored with
                                    ;; "Function STORE-TILE-AT is not differentiable".
                                    ;; These forms are void — their "value" is meaningless — so
                                    ;; unwrap the temp and re-dispatch as the statement it is.
                                    ;; Fixes the register-tile AND scratch paths uniformly.
                                    ((and (consp form) (= (length form) 2) (symbolp (car form))
                                          (consp (cadr form)) (symbolp (caadr form))
                                          (member (symbol-name (caadr form))
                                                  ;; All VOID forms.  make-register-tile is
                                                  ;; deliberately absent — that one really is a
                                                  ;; value binding and must keep its temp.
                                                  '("STORE-TILE-AT" "LOAD-TILE-AT"
                                                    "STORE-TILE" "LOAD-TILE"
                                                    "MMA-ACCUMULATE-VIA-TILE" "STORE-FRAGMENT")
                                                  :test #'string=))
                                      (process-form (cadr form) emit-fn))

                                    ;; Endeavor 145 P3b: the tile-level MMA backward.
                                    ;; C-tile += A-tile . B-tile  =>  dA = dC.B^T, dB = A^T.dC.
                                    ;; Falls through to the old silent-drop only when the
                                    ;; shapes / staging sources are not compile-time
                                    ;; recoverable, so a kernel we cannot differentiate
                                    ;; correctly is never given a bogus gradient.
                                    ((and (consp form) (symbolp (car form))
                                          (string-equal (symbol-name (car form))
                                                        "MMA-ACCUMULATE-VIA-TILE")
                                          (>= (length form) 5))
                                      (let ((bwd (%mma-via-tile-backward-logged
                                                  form
                                                  (%mma-ad-tile-dims-map flat-anf)
                                                  (%mma-ad-tile-source-map flat-anf)
                                                  inputs outputs #'local-adj kernel-pkg)))
                                        (when bwd (funcall emit-fn bwd))))

                                    ;; Phase 1c: load-tile-at forward → backward.
                                    ((and (consp form) (symbolp (car form))
                                          (string-equal (symbol-name (car form)) "LOAD-TILE-AT"))
                                      (let* ((src (second form))
                                             (tile (third form))
                                             (origins (fourth form))
                                             (key-args (nthcdr 4 form))
                                             (transpose-v (%tlc-extract-transpose-key key-args))
                                             (src-adj (%tlc-bwd-adj-name src inputs outputs
                                                                         #'local-adj kernel-pkg))
                                             (tile-adj (%tlc-bwd-adj-name tile inputs outputs
                                                                          #'local-adj kernel-pkg))
                                             (bwd-sym (intern "%LOAD-TILE-AT-BWD"
                                                              (find-package :crisp-language)))
                                             (bwd-form (if transpose-v
                                                           (list bwd-sym src-adj tile-adj origins :transpose transpose-v)
                                                           (list bwd-sym src-adj tile-adj origins))))
                                        (funcall emit-fn bwd-form)))

                                    ;; Endeavor 145 P3b: a REGISTER-tile store.  Must be caught
                                    ;; BEFORE the scratch-tensor rule below, which would emit
                                    ;; %STORE-TILE-AT-BWD against an adjoint whose name is about
                                    ;; to be SROA-exploded away.  The backward of "write the
                                    ;; accumulator out to C" is "seed the accumulator's adjoint
                                    ;; from C_GRAD", fragment by fragment.  The origin coords are
                                    ;; unscaled first: the store-tile macro multiplied the tile-ID
                                    ;; by (~ (extents~ TILE) i), which is meaningless for a
                                    ;; register tile — the tile-ID inside is what we want.
                                    ((and (consp form) (symbolp (car form))
                                          (or (string-equal (symbol-name (car form)) "STORE-TILE-AT")
                                              (string-equal (symbol-name (car form)) "STORE-TILE"))
                                          ;; Endeavor 146: ACCUMULATORS only.  An :operand
                                          ;; tile's adjoint is a scratch matrix (Gap 4), so
                                          ;; the register loader below does not apply to it.
                                          (%mma-ad-register-accumulator-tile-p (second form)
                                                                               flat-anf))
                                      (let* ((tile (second form))
                                             (dest (third form))
                                             (origins (mapcar #'%mma-ad-unscale-tile-origin
                                                              (fourth form)))
                                             (tile-adj (%tlc-bwd-adj-name tile inputs outputs
                                                                          #'local-adj kernel-pkg))
                                             (dest-adj (%tlc-bwd-adj-name dest inputs outputs
                                                                          #'local-adj kernel-pkg))
                                             (bwd-sym (intern "%LOAD-REGISTER-TILE-ACC"
                                                              (find-package :crisp-language))))
                                        (log:debug "145 P3b register-tile store bwd: ~a <- ~a origins=~a"
                                                   tile-adj dest-adj origins)
                                        (funcall emit-fn (list bwd-sym tile-adj dest-adj origins))))

                                    ;; Phase 1c: store-tile-at forward → backward.
                                    ((and (consp form) (symbolp (car form))
                                          (string-equal (symbol-name (car form)) "STORE-TILE-AT"))
                                      (let* ((tile (second form))
                                             (dest (third form))
                                             (origins (fourth form))
                                             (key-args (nthcdr 4 form))
                                             (transpose-v (%tlc-extract-transpose-key key-args))
                                             (tile-adj (%tlc-bwd-adj-name tile inputs outputs
                                                                          #'local-adj kernel-pkg))
                                             (dest-adj (%tlc-bwd-adj-name dest inputs outputs
                                                                          #'local-adj kernel-pkg))
                                             (bwd-sym (intern "%STORE-TILE-AT-BWD"
                                                              (find-package :crisp-language)))
                                             (bwd-form (if transpose-v
                                                           (list bwd-sym tile-adj dest-adj origins :transpose transpose-v)
                                                           (list bwd-sym tile-adj dest-adj origins))))
                                        (funcall emit-fn bwd-form)))

                                    ((and (consp form) (symbolp (car form))
                                          (string-equal (symbol-name (car form)) "SET!"))
                                      (%gfw-process-set! form emit-fn #'local-adj inputs outputs scratch-tile-syms intermediate-zero kernel-pkg))

                                    ((and (consp form) (symbolp (car form))
                                          (string-equal (symbol-name (car form)) "LET"))
                                      (let* ((bindings (cadr form))
                                             (augmented-bindings (%augment-scratch-adj-bindings bindings kernel-pkg))
                                             (body (cddr form)))
                                        (%gfw-process-let form emit-fn #'process-form bindings augmented-bindings body)))

                                    ((and (consp form) (symbolp (car form))
                                          (%dotimes-family-head-p (car form)))
                                      (let* ((binding (cadr form))
                                             (body (cddr form))
                                             (local-vars (%collect-locally-bound-vars body)))
                                        (%gfw-process-dotimes form emit-fn #'process-form binding body local-vars adjoint-map intermediate-zero)))

                                    ((and (consp form) (symbolp (car form))
                                          (string-equal (symbol-name (car form)) "IF"))
                                      (let* ((cond-form (cadr form))
                                             (then-form (caddr form))
                                             (else-form (cadddr form)))
                                        (%gfw-process-if form emit-fn #'process-form cond-form then-form else-form)))

                                    ;; Bug 032 fix part 2: WHEN and UNLESS were not handled
                                    ;; by the AD walker, so any forms inside them (including
                                    ;; the load/store-tile-at inner body's set!s after
                                    ;; workgroup-stride expansion) were silently dropped.
                                    ;; Desugar them to IF + PROGN here and let the IF case
                                    ;; handle the rest.
                                    ((and (consp form) (symbolp (car form))
                                          (string-equal (symbol-name (car form)) "WHEN"))
                                      (let* ((pkg (find-package :crisp-language))
                                             (if-sym (intern "IF" pkg))
                                             (progn-sym (intern "PROGN" pkg))
                                             (cond-form (cadr form))
                                             (body (cddr form))
                                             (then (cond ((null body) 'nil)
                                                         ((= (length body) 1) (first body))
                                                         (t (cons progn-sym body)))))
                                        (process-form (list if-sym cond-form then 'nil) emit-fn)))

                                    ((and (consp form) (symbolp (car form))
                                          (string-equal (symbol-name (car form)) "UNLESS"))
                                      (let* ((pkg (find-package :crisp-language))
                                             (if-sym (intern "IF" pkg))
                                             (progn-sym (intern "PROGN" pkg))
                                             (cond-form (cadr form))
                                             (body (cddr form))
                                             (then (cond ((null body) 'nil)
                                                         ((= (length body) 1) (first body))
                                                         (t (cons progn-sym body)))))
                                        ;; (unless C B) = (if C nil B) — pass B as the else slot.
                                        (process-form (list if-sym cond-form 'nil then) emit-fn)))

                                    ((and (consp form) (symbolp (car form))
                                          (string-equal (symbol-name (car form)) "PROGN"))
                                      (dolist (sub (reverse (cdr form)))
                                        (process-form sub emit-fn)))

                                    ;; Endeavor 123 (FFI-AD): a foreign function called as a
                                    ;; VOID STATEMENT (=> nil), e.g. (c_vsin n inptr outptr).
                                    ;; It is not a value binding, so it must be recognized by
                                    ;; its head being a registered foreign function — otherwise
                                    ;; it is misparsed as a multi-value binding below and
                                    ;; silently dropped. There is no return seed (void).
                                    ((and (consp form) (symbolp (car form))
                                          (let ((info (gethash (car form) *differentiable-functions*)))
                                            (and info (getf info :foreign))))
                                      (%emit-foreign-backward (car form) (cdr form) nil
                                                              (symbol-package (car form))
                                                              emit-fn #'local-adj))

                                    ;; BUG 038: an ordinary differentiable SUB-FUNCTION called as
                                    ;; a VOID STATEMENT, e.g. (stage A tile) or (scale_into A C).
                                    ;; Endeavor 123 added the clause above for the FOREIGN case
                                    ;; and for exactly this reason; the non-foreign case never
                                    ;; got one, so such a call fell through to the multi-value
                                    ;; BINDING clause below — `(STAGE A TILE)` is length 3 with an
                                    ;; all-symbol butlast, so that clause read STAGE and A as
                                    ;; bound variables and TILE as the producing expression.  TILE
                                    ;; is a symbol rather than a cons, so its body never ran and
                                    ;; the call was SILENTLY DROPPED — no gradient flowed through
                                    ;; the sub-function at all (137/04's backward had zero global
                                    ;; writes).  Statements and multi-value bindings are
                                    ;; indistinguishable by shape after ANF, which is the same
                                    ;; trap as the 145 P1 replay bug.
                                    ;;
                                    ;; Void, so there is no return seed: t-adj-forms is NIL, as in
                                    ;; the foreign case.  Handle (tensor) contributions are routed
                                    ;; by %emit-sub-fn-backward through the callee's &out
                                    ;; grad-handles, so the chain rule lands inside the sub-fn.
                                    ;; A binding never matches here: its CAR is the bound temp,
                                    ;; not a registered function.
                                    ;; The second disjunct matters: a sub-function whose companion
                                    ;; could not be built has been UNREGISTERED, so the gethash
                                    ;; alone would miss it and the call would be dropped exactly
                                    ;; as before.  A retained body is sufficient on its own.
                                    ((and (consp form) (symbolp (car form))
                                          (or (let ((info (gethash (car form) *differentiable-functions*)))
                                                (and info (not (getf info :foreign))))
                                              (%ad-sub-fn-inlinable-p (car form))))
                                      (let* ((fn (car form))
                                             (info (gethash fn *differentiable-functions*)))
                                        (log:debug "038: void sub-fn call backward for ~a" fn)
                                        ;; Prefer INLINING the callee's body: it needs no
                                        ;; companion, so it is immune to every way companion
                                        ;; generation can quietly decline, and it gives the
                                        ;; body's statements (load-tile above all) the same
                                        ;; treatment they would get in a kernel.  Fall back to
                                        ;; the companion when there is no body to inline —
                                        ;; notably FFI, and recursion.
                                        (unless (%ad-inline-sub-fn-backward fn (cdr form)
                                                                            emit-fn #'process-form)
                                          (%emit-sub-fn-backward fn (cdr form)
                                                                 (getf info :bkwd-name)
                                                                 nil
                                                                 (getf info :n-float-params)
                                                                 (symbol-package fn)
                                                                 emit-fn #'local-adj "BW"))))

                                    ((and (listp form) (= (length form) 2) (symbolp (car form)))
                                      (%handle-single-value-backward (car form) (cadr form)
                                                                     adjoint-map emit-fn #'local-adj
                                                                     :hof-handler-fn #'hof-inline-backward
                                                                     :error-on-unknown t
                                                                     :tensor-inputs-ht tensor-inputs-ht
                                                                     :scratch-tile-syms scratch-tile-syms))

                                    ((and (listp form) (>= (length form) 3)
                                          (symbolp (car form))
                                          (every #'symbolp (butlast form)))
                                      (let* ((result-vars (butlast form))
                                             (expr (car (last form))))
                                        (when (and (consp expr)
                                                   (symbolp (car expr))
                                                   (gethash (car expr) *differentiable-functions*))
                                              (let* ((fn (car expr))
                                                     (args (cdr expr))
                                                     (info (gethash fn *differentiable-functions*))
                                                     (bkwd (getf info :bkwd-name))
                                                     (n-fp (getf info :n-float-params))
                                                     (pkg (symbol-package (car result-vars)))
                                                     (t-adjs (mapcar #'local-adj result-vars)))
                                                ;; Endeavor 123 (FFI-AD): foreign multi-return
                                                ;; routes through the shadow-aware emitter.
                                                (if (getf info :foreign)
                                                    (%emit-foreign-backward fn args t-adjs pkg
                                                                            emit-fn #'local-adj)
                                                    (%emit-sub-fn-backward fn args bkwd t-adjs n-fp pkg
                                                                           emit-fn #'local-adj "BW"))))))

                                    (t nil))))))

              (let ((reversed-body (reverse flat-anf)))
                (dolist (form reversed-body)
                  (process-form form #'emit)))

              (loop for in in inputs
                    for in-type in input-types do
                      (let* ((in-grad (intern (format nil "~A_GRAD" (symbol-name in))
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
                        ;; Endeavor 124 (AD issues) C: under any-output-double the
                        ;; adjoint runs in double, but a float/small-int input's grad
                        ;; cell is float — down-cast at the write to match the cell.
                        (let ((write-val
                               (if (and any-output-double
                                        (not (promotes-to-double-p in-type))
                                        (or is-cell-input is-scalar-wrapped))
                                   `(to-float ,(local-adj in))
                                   (local-adj in))))
                          (cond
                           (is-tensor-input nil)
                           (is-cell-input (emit `(set! (~ ,in-grad) ,write-val)))
                           (is-scalar-wrapped (emit `(set! (~ ,in-grad) ,write-val)))
                           (t (emit `(set! ,in-grad ,write-val)))))))

              (let* ((typed-zero-for
                      (lambda (orig-sym)
                        (let* ((idx (position orig-sym inputs))
                               (in-type (when idx (nth idx input-types))))
                          ;; Endeavor 124 (AD issues) C: when ANY output promotes to
                          ;; double, the whole backward chain runs in double — INCLUDING
                          ;; float-input adjoints — so the adjoint accumulations don't mix
                          ;; float and double. The narrower grad cell is reconciled by a
                          ;; down-cast at the grad-cell write below.
                          (cond
                           (in-type
                             (%ad-zero (or (promotes-to-double-p in-type) any-output-double)))
                           (any-output-double (%ad-zero t))
                           (t (%ad-zero nil))))))
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
                                                                        "MAKE-SCRATCH-TENSOR" "MAKE-SCRATCH-CELL"
                                                                        "MAKE-REGISTER-TILE")
                                                :test #'string=))
                            collect (let* ((var (car form))
                                           (var-adj (intern (format nil "~A_ADJ" (symbol-name var))
                                                            (or kernel-pkg (symbol-package var)))))
                                      (list var-adj (%mma-ad-adj-init (cadr form))))))
                     (result `(let ,(append scratch-adj-bindings local-bindings)
                                ,@(nreverse backward-forms))))
                (log:debug "145: assembled backward AST:~%~s" result)
                ;; Endeavor 146: bind any ring adjoint the walk NAMED but did not BIND.
                ;; FLAT-ANF here is the normalized anf (see the setf at the top), so ring
                ;; constructors are already in their canonical scratch-ring form.
                (let ((final (%ad-ensure-ring-adj-bindings result flat-anf kernel-pkg)))
                  (log:debug "146: backward after ring-adjoint fixup:~%~s" final)
                  ;; Endeavour 149: close the kernel's TOP-LEVEL statement sequence.  Every
                  ;; inner scope had its chance to refill a tile as it closed (see
                  ;; %gfw-process-let / %gfw-process-dotimes); this is the outermost one, so
                  ;; whatever is still pending here is a primal nothing in the kernel can
                  ;; rebuild, and %ad-replay-finish refuses.  Applied to FINAL rather than to
                  ;; RESULT so the ring-adjoint fixup has already run: replay is spliced into
                  ;; the body of the same outer LET that fixup adds bindings to.
                  (%ad-prune-dead-scratch (%ad-replay-finish final flat-anf))))))))))))

;; src/autodiff.lisp  (endeavour 172: whole-function copy of line 1468; emits the loop's own head)
(defun %gfw-process-dotimes (form emit-fn process-form-fn binding body local-vars adjoint-map intermediate-zero)
  "Unchanged except that it publishes the loop variable in *ad-loop-vars* while walking the
   body, so a VJP dispatched inside can ask what coordinate it is being evaluated at.  A
   pipelined ring operand needs this: its primal lives at the CONSUMING iteration, and the
   forward's load sites record other stages' origins.

   ENDEAVOUR 149: a tile re-staged each iteration has no single primal value, so its replay
   belongs HERE -- inside the loop body, ahead of the consumers, evaluated afresh for each
   value of the loop variable.  That falls out of emitting at this scope: the replayed
   statements close over BINDING exactly as the forward's did.

   ENDEAVOUR 172: emits the forward loop's own head (less any +), so a dec-times / by-factor /
   power-step loop replays with its own iteration sequence rather than as a dotimes."
  (let ((local-forms nil)
        (inherited-replay-requests (copy-list *ad-replay-pending*))
        (*ad-loop-vars* (if (and (consp binding) (symbolp (car binding)))
                            (cons (car binding) *ad-loop-vars*)
                            *ad-loop-vars*)))
    (flet ((local-emit (f) (push f local-forms)))
      (dolist (b (reverse body))
        (funcall process-form-fn b #'local-emit)))
    (let ((zero-resets
           (loop for v in local-vars
                 for adv = (gethash v adjoint-map)
                   when adv
                 collect `(set! ,adv ,intermediate-zero)))
          (replay (%ad-replay-forms-for-scope body inherited-replay-requests)))
      (funcall emit-fn `(,(%dotimes-backward-head (car form)) ,binding ,@zero-resets ,@replay ,@(nreverse local-forms))))))

;; src/analysis/control.lisp  (endeavour 172: whole-function copy of line 4613; the ONLY change is
;; the (register-loop-variant-analyzers) call after the DOTIMES registration)
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
  ;; Endeavour 172: dec-times, dec-times-by-half/-by-factor, do-times-by-doubling/-by-multiply,
  ;; do-power-step, dec-power-step, and every + form.
  (register-loop-variant-analyzers)
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

;;; ---------------------------------------------------------------------------
;;; Endeavour 172 follow-on: plain dotimes had the same unbounded-loop hole the variants
;;; gate against -- (dotimes (i n 0) ...) spun forever, as did a negative stride on a signed
;;; dotimes.  Same rule as decision D3: literal is a compile error, runtime runs zero times.
;;; ---------------------------------------------------------------------------

;; src/analysis/control.lisp  (whole-function copy of line 1901; adds the literal stride gate)
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
      ;; Endeavour 172: a literal stride of 0 (or negative) can never advance the loop variable
      ;; -- that is an unbounded loop, which Crisp forbids.  (A stride computed at runtime is
      ;; caught by the codegen guard instead: it runs ZERO iterations.)
      (when (and stride-node (semantic-literal-p stride-node)
                 (integerp (semantic-literal-value stride-node))
                 (< (semantic-literal-value stride-node) 1))
        (error 'crisp-compiler-error
          :message (format nil "dotimes: stride must be greater than 0, got ~a"
                           (semantic-literal-value stride-node))
          :source-location location))
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

;; src/codegen.lisp  (whole-function copy of line 4003; adds the stride-ok entry guard)
(defmethod generate-node-ir ((node semantic-dotimes) builder module var-env di-builder di-scope location-map)
  "Generates IR for (dotimes (var limit [stride]) body...).
   Uses alloca+branch loop pattern (consistent with semantic-if).
   LLVM mem2reg promotes the alloca to a phi node during optimization."
  (let* ((limit-node  (semantic-dotimes-limit-node node))
         (stride-node (semantic-dotimes-stride-node node))
         (var-name    (semantic-dotimes-var-name node))
         (body        (semantic-dotimes-body node))
         ;; Determine LLVM type and signed/unsigned comparison from limit type
         (limit-type  (get-single-value-type limit-node))
         (limit-ct    (gethash limit-type *crisp-types*))
         (is-unsigned (and limit-ct (eq (crisp-type-category limit-ct) :unsigned-int)))
         (cmp-pred    (if is-unsigned +llvm-int-ult+ +llvm-int-slt+))
         (llvm-type   (crisp-type-to-llvm-type limit-type module))
         ;; Current function
         (current-fn  (llvm-get-basic-block-parent (llvm-get-insert-block builder)))
         ;; Generate limit value in current block
         (limit-val   (generate-node-ir limit-node builder module var-env di-builder di-scope location-map))
         ;; Generate stride value (or constant 1)
         (stride-val  (if stride-node
                          (generate-node-ir stride-node builder module var-env di-builder di-scope location-map)
                          (llvm-const-int llvm-type 1 0)))
         ;; Endeavour 172 -- BUG: (dotimes (i n 0) ...) never terminated.  A stride that cannot
         ;; advance the loop variable runs ZERO iterations rather than spinning forever.  Folds
         ;; away for the constant strides that every existing dotimes has.
         (stride-ok   (llvm-build-icmp builder (if is-unsigned +llvm-int-ne+ +llvm-int-sgt+)
                                       stride-val (llvm-const-int llvm-type 0 0) "dt_stride_ok"))
         ;; Alloca for the loop variable; initialize to 0
         (i-alloca    (llvm-build-alloca builder llvm-type (string-downcase (symbol-name var-name))))
         (_           (llvm-build-store builder (llvm-const-int llvm-type 0 0) i-alloca))
         ;; Basic blocks
         (check-block (llvm-append-basic-block current-fn "dt_check"))
         (body-block  (llvm-append-basic-block current-fn "dt_body"))
         (exit-block  (llvm-append-basic-block current-fn "dt_exit")))
    (declare (ignore _))
    ;; Branch from current block into loop check -- but only if the stride can advance it
    (llvm-build-cond-br builder stride-ok check-block exit-block)
    ;; --- Check Block: if i < limit goto body else goto exit ---
    (llvm-position-builder-at-end builder check-block)
    (let* ((i-val   (llvm-build-load2 builder llvm-type i-alloca "i"))
           (cond-v  (llvm-build-icmp builder cmp-pred i-val limit-val "dt_cond")))
      (llvm-build-cond-br builder cond-v body-block exit-block))
    ;; --- Body Block ---
    (llvm-position-builder-at-end builder body-block)
    (let ((body-env (alexandria:copy-hash-table var-env)))
      ;; Expose the loop variable via the alloca so var-read loads from it
      (setf (gethash var-name body-env) i-alloca)
      ;; Generate body expressions
      (dolist (body-node body)
        (generate-node-ir body-node builder module body-env di-builder di-scope location-map))
      ;; Increment: i += stride
      (let* ((i-cur  (llvm-build-load2 builder llvm-type i-alloca "i_cur"))
             (i-next (llvm-build-add builder i-cur stride-val "i_next")))
        (llvm-build-store builder i-next i-alloca)))
    ;; Branch back to check (unless body already terminated, e.g. explicit return)
    (unless (terminator-p (llvm-get-insert-block builder))
      (llvm-build-br builder check-block))
    ;; --- Exit Block ---
    (llvm-position-builder-at-end builder exit-block)
    ;; dotimes returns void
    (values nil nil)))
