;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)


;; src/analysis/control.lisp
;;
;; Endeavor 111 Phase 0: tile-stride and hardware-stride are now OUTER LOOPS
;; over chunk origins.
;;
;; Under the new model, the body executes once per workgroup per chunk.
;; Each <binding> is bound to the global origin coordinate of the current
;; chunk (e.g. for a vector of length 30 with tile-size 10, the binding
;; takes values 0, 10, 20).  Workgroups divide the chunk-origins via a
;; get-workgroup-id / get-num-groups strided pattern.
;;
;; This replaces the previous delegate-to-tensor-stride implementations
;; which iterated per-coord and were semantically incompatible with the
;; cooperative load-tile / store-tile helpers landing in Phase 1.
;;
;; tile-stride and hardware-stride :workgroup-idx share the same outer-loop
;; structure; they differ only in the per-dim chunk-size source:
;;   - tile-stride: literal size-list or extents of a tile-tensor
;;   - hardware-stride :workgroup-idx: (get-local-size k)
;; The shared expansion lives in %expand-workgroup-strided-outer-loop.
;;
;; hardware-stride :warp-idx is its own custom expansion: always 1D, the
;; chunk size is the (placeholder) warp width, and iteration is warp-strided
;; rather than workgroup-strided.


;; src/analysis/control.lisp
(defun %expand-workgroup-strided-outer-loop (tensor-form n bindings body-forms
                                             tile-size-source-fn
                                             location)
  "Builds an N-dim outer loop over chunk origins.  The body executes once per
   workgroup per chunk; each binding is bound to the chunk's global origin
   coord in its dim.  Workgroups divide chunks via a get-workgroup-id +
   get-num-groups strided pattern.

   TENSOR-FORM is the problem-space tensor (used for extents and length).
   N is the chunk arity (== bindings arity).
   BINDINGS is a list of N symbols receiving the origin coord per dim.
   BODY-FORMS is the user's body (already helper-rewritten by the caller).
   TILE-SIZE-SOURCE-FN(k) returns the expression supplying chunk-size in
   dim k — literal int (tile-stride size-list), extents read (tile-tensor),
   or (get-local-size k) (hardware-stride :workgroup-idx).

   Caller is responsible for any arity/CT validation prior to calling this."
  (declare (ignore location))
  (let* ((cl-pkg (find-package :crisp-language))
         (let-sym             (intern "LET" cl-pkg))
         (declare-sym         (intern "DECLARE" cl-pkg))
         (workgroup-level-sym (intern "WORKGROUP-LEVEL" cl-pkg))
         (dotimes-sym         (intern "DOTIMES" cl-pkg))
         (when-sym            (intern "WHEN" cl-pkg))
         (progn-sym           (intern "PROGN" cl-pkg))
         (aref-sym            (intern "~" cl-pkg))
         (extents-tilde-sym   (intern "EXTENTS~" cl-pkg))
         (get-wg-id-sym       (intern "GET-WORKGROUP-ID" cl-pkg))
         (get-num-groups-sym  (intern "GET-NUM-GROUPS" cl-pkg))
         (plus-sym            (intern "+" cl-pkg))
         (mul-sym             (intern "*" cl-pkg))
         (lt-sym              (intern "<" cl-pkg))
         (t-sym (gensym "T"))
         (ts-syms  (loop for i from 0 below n collect (gensym (format nil "TS~A"   i))))
         (e-syms   (loop for i from 0 below n collect (gensym (format nil "E~A"    i))))
         (gid-syms (loop for i from 0 below n collect (gensym (format nil "WGID~A" i))))
         (ng-syms  (loop for i from 0 below n collect (gensym (format nil "NG~A"   i))))
         (k-syms   (loop for i from 0 below n collect (gensym (format nil "K~A"    i))))
         (inner-body (if (= (length body-forms) 1)
                         (first body-forms)
                         (cons progn-sym body-forms)))
         ;; Build the nest from innermost out.  At each level:
         ;;   (dotimes (K_k E_k (* TS_k NG_k))
         ;;     (let ((b_k (+ K_k (* WGID_k TS_k))))
         ;;       (when (< b_k E_k)
         ;;         <inner>)))
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
                                       (list when-sym
                                             (list lt-sym b-sym e-sym)
                                             acc)))))
            acc))
         (outer-bindings
          (append
           (list (list t-sym tensor-form))
           (loop for i from 0 below n
                 for ts-sym in ts-syms
                 collect (list ts-sym (funcall tile-size-source-fn i)))
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
(defun %expand-tile-stride-form (expr ct location)
  "Pure expansion of (tile-stride T [LAYOUT-TAG] <TILE-SPEC> (BINDINGS) BODY...).
   Outer loop over tile origins, workgroup-strided.  Body executes once per
   workgroup per tile-origin; each binding is bound to the tile's global
   origin coord in its dim.  CT is currently ignored at expansion time —
   layout-tag validation against the tensor's static CT still happens in
   analyze-tile-stride-expression."
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
           ;; Capture the size source expressions before helper rewrite so
           ;; tile-indices can use the gensym-bound TS-k vars built by the
           ;; shared outer-loop helper.  We pre-allocate the TS-k syms here
           ;; and pass them down to both the helper rewriter and the loop
           ;; builder, ensuring a single point of evaluation.
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
           ;; tile-indices(b_k) → (/ b_k TS_k), referencing the shared ts gensym.
           (rewritten-body (%tile-helpers-rewrite body-forms n
                                                  (lambda (k) (nth k ts-syms)))))
      (%expand-workgroup-strided-outer-loop-with-ts-syms
       tensor-form n bindings rewritten-body ts-syms tile-size-expr-fn location))))


;; src/analysis/control.lisp
(defun %expand-workgroup-strided-outer-loop-with-ts-syms
    (tensor-form n bindings body-forms ts-syms tile-size-expr-fn location)
  "Variant of %expand-workgroup-strided-outer-loop that takes a pre-allocated
   list of TS gensyms (so the caller's body rewriter can refer to them by
   name).  Otherwise identical in shape."
  (declare (ignore location))
  (let* ((cl-pkg (find-package :crisp-language))
         (let-sym             (intern "LET" cl-pkg))
         (declare-sym         (intern "DECLARE" cl-pkg))
         (workgroup-level-sym (intern "WORKGROUP-LEVEL" cl-pkg))
         (dotimes-sym         (intern "DOTIMES" cl-pkg))
         (when-sym            (intern "WHEN" cl-pkg))
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
                                       (list when-sym
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


;; src/analysis/control.lisp
(defun %expand-hw-workgroup-idx-form (tensor-form bindings body-forms location)
  "Outer-loop expansion for hardware-stride :workgroup-idx.  Chunk-size per
   dim = (get-local-size k).  Helpers get rewritten with the bound LS gensyms
   so tile-indices uses a single point of evaluation."
  (let* ((n (length bindings))
         (cl-pkg (find-package :crisp-language))
         (get-local-size-sym (intern "GET-LOCAL-WORK-SIZE" cl-pkg))
         (ts-syms (loop for i from 0 below n
                        collect (gensym (format nil "LS~A" i))))
         (size-expr-fn (lambda (k) (list get-local-size-sym k)))
         (rewritten-body (%tile-helpers-rewrite body-forms n
                                                 (lambda (k) (nth k ts-syms)))))
    (%expand-workgroup-strided-outer-loop-with-ts-syms
     tensor-form n bindings rewritten-body ts-syms size-expr-fn location)))


;; src/analysis/control.lisp
(defun %expand-hw-warp-idx-form (tensor-form bindings body-forms location)
  "Outer-loop expansion for hardware-stride :warp-idx.  Always 1D.

   Iteration model: each warp processes warp-sized chunks of the flattened
   global execution space.  Warps stride over chunks with stride =
   warp-size * total-warps.

   Currently uses a placeholder warp-size of 32 — should switch to
   (get-warp-size) once that builtin is implemented (then NVIDIA/Intel
   stay correct, AMD's 64-wide wavefronts also become correct)."
  (declare (ignore location))
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
         ;; Rewrite tile-indices in the body using the bound WS gensym so
         ;; (tile-indices warp-orig) → (/ warp-orig WS).
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
;; Endeavor 111 Phase 0: tile-coords and tensor-coords helpers are removed
;; from the language.  Under outer-loop tile-stride semantics, the
;; <bindings> already are the global origin coord of the chunk, and intra-
;; tile coordinates come from a workgroup-stride binding rather than from
;; a per-thread breakdown of a problem-space coord.
;;
;; Only tile-indices survives — its math (floor binding / tile-size) is
;; unchanged, but its INPUT now means "tile origin in problem space"
;; rather than "per-thread problem coord."  Same formula, new meaning.

(defun %tile-helper-name-p (sym)
  "Returns :indices if SYM is the tile-indices helper macro name, else NIL.
   tile-coords and tensor-coords were removed in endeavor 111 Phase 0."
  (when (symbolp sym)
    (when (string-equal (symbol-name sym) "TILE-INDICES")
      :indices)))


(defun %tile-helper-call-expansion (helper-kind helper-args tile-size-fn n-tile cl-pkg)
  "Returns a list of N expansion forms for a tile-indices helper call.
   Only :indices is supported under outer-loop tile-stride semantics."
  (case helper-kind
    (:indices
     (unless (= (length helper-args) n-tile)
       (error 'crisp-compiler-error
              :message (format nil "tile-indices: expected ~A argument(s) to match tile arity, got ~A"
                               n-tile (length helper-args))
              :source-location nil))
     (%tile-helper-build-indices helper-args tile-size-fn cl-pkg))
    (t
     (error 'crisp-compiler-error
            :message (format nil "Unknown tile-stride helper kind: ~S" helper-kind)
            :source-location nil))))


;; src/analysis/control.lisp
;;
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


(defun %expand-workgroup-stride-form (expr location)
  "Pure expansion of (workgroup-stride T (BINDINGS) BODY...).  N-dim nested
   dotimes where each thread strides by local-work-size starting at its
   local-id.  Returns a let/dotimes/when tree suitable for analysis."
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
           (let-sym             (intern "LET" cl-pkg))
           (dotimes-sym         (intern "DOTIMES" cl-pkg))
           (when-sym            (intern "WHEN" cl-pkg))
           (progn-sym           (intern "PROGN" cl-pkg))
           (aref-sym            (intern "~" cl-pkg))
           (extents-tilde-sym   (intern "EXTENTS~" cl-pkg))
           (get-local-id-sym    (intern "GET-LOCAL-ID" cl-pkg))
           (get-lws-sym         (intern "GET-LOCAL-WORK-SIZE" cl-pkg))
           (plus-sym            (intern "+" cl-pkg))
           (lt-sym              (intern "<" cl-pkg))
           (t-sym (gensym "T"))
           (e-syms   (loop for i from 0 below n collect (gensym (format nil "E~A"    i))))
           (lid-syms (loop for i from 0 below n collect (gensym (format nil "LID~A"  i))))
           (lws-syms (loop for i from 0 below n collect (gensym (format nil "LWS~A"  i))))
           (k-syms   (loop for i from 0 below n collect (gensym (format nil "K~A"    i))))
           (inner-body (if (= (length body-forms) 1)
                           (first body-forms)
                           (cons progn-sym body-forms)))
           ;; Build the nest from innermost out.  At each level:
           ;;   (dotimes (K_k E_k LWS_k)
           ;;     (let ((b_k (+ K_k LID_k)))
           ;;       (when (< b_k E_k)
           ;;         <inner>)))
           (nest
            (let ((acc inner-body))
              (loop for i from (1- n) downto 0
                    for b-sym  = (nth i bindings)
                    for e-sym  = (nth i e-syms)
                    for lid-sym = (nth i lid-syms)
                    for lws-sym = (nth i lws-syms)
                    for k-sym  = (nth i k-syms)
                    do (setf acc
                             (list dotimes-sym
                                   (list k-sym e-sym lws-sym)
                                   (list let-sym
                                         (list (list b-sym
                                                     (list plus-sym k-sym lid-sym)))
                                         (list when-sym
                                               (list lt-sym b-sym e-sym)
                                               acc)))))
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
                   collect (list lws-sym (list get-lws-sym i))))))
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


;; src/analysis/control.lisp
;;
;; Whole-function replacement of register-control-analyzers, adding
;; WORKGROUP-STRIDE registration.  Source ends with HARDWARE-STRIDE; we
;; add WORKGROUP-STRIDE at the tail so the merge target is unambiguous.
(defun register-control-analyzers ()
  "Registers all control flow expression analyzers, including loop-vector-stride,
   tensor-stride (105), grid-stride (105), tile-stride (109), hardware-stride
   (109), and workgroup-stride (110)."
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
  ;; 109 Passes 5-7: hardware-stride
  (let ((sym-cl (intern "HARDWARE-STRIDE" (find-package :crisp-language)))
        (sym-cc (intern "HARDWARE-STRIDE" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-hardware-stride-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-hardware-stride-expression)))
  ;; 110: workgroup-stride
  (let ((sym-cl (intern "WORKGROUP-STRIDE" (find-package :crisp-language)))
        (sym-cc (intern "WORKGROUP-STRIDE" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-workgroup-stride-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-workgroup-stride-expression)))
  ;; 110: warp helper builtins.  Registered here (rather than in the GPU-builtin
  ;; dolist in initialize-expression-analyzers) because that dolist is part of
  ;; a long defun we'd rather not whole-replace.  These setf entries survive
  ;; the subsequent GPU-builtin dolist since it touches different keys.
  (register-warp-builtins))


;; src/analysis/core.lisp
;;
;; 110 — warp helper builtins.  Three zero-arg builtins returning uint:
;;   (warp-id)    → SPIR-V SubgroupId
;;   (warp-lane)  → SPIR-V SubgroupLocalInvocationId
;;   (warp-count) → SPIR-V NumSubgroups
;;
;; They register the same analyzer (%analyze-gpu-builtin) used by other GPU
;; builtins; their return-type metadata lives in %gpu-builtin-info (overridden
;; below).  Codegen lives in the %call-spirv-uint-global-builtin helper plus
;; new cases in generate-node-ir for semantic-gpu-builtin.

(defun register-warp-builtins ()
  "Registers the warp-id / warp-lane / warp-count GPU builtins in
   *expression-analyzers* for both :crisp-language and :crisp.compiler."
  (let ((cl-pkg (find-package :crisp-language))
        (cc-pkg (find-package :crisp.compiler)))
    (dolist (entry '(("WARP-ID"    :warp-id)
                     ("WARP-LANE"  :warp-lane)
                     ("WARP-COUNT" :warp-count)))
      (let* ((name-str (first entry))
             (kw       (second entry))
             (fn       (let ((kw0 kw) (ns0 name-str))
                         (lambda (expr env context location)
                           (%analyze-gpu-builtin kw0 ns0 expr env context location))))
             (sym-cl (intern name-str cl-pkg))
             (sym-cc (intern name-str cc-pkg)))
        (setf (gethash sym-cl *expression-analyzers*) fn)
        (unless (eq sym-cl sym-cc)
          (setf (gethash sym-cc *expression-analyzers*) fn))))))


;; src/analysis/core.lisp
;;
;; Whole-function replacement of %gpu-builtin-info, adding return-type
;; metadata for the warp helper builtins.
(defun %gpu-builtin-info (builtin-kw)
  "Returns (base-return-type accepts-dim-p) for a GPU builtin keyword.
   BASE-RETURN-TYPE: return type when called with no args (nil = void).
   ACCEPTS-DIM-P: T if the builtin accepts a scalar dimension arg 0/1/2."
  (case builtin-kw
    ((:get-global-id :get-local-id :get-workgroup-id :get-num-groups
      :get-local-work-size :get-global-work-size :get-global-offset
      :get-global-id-abs)
     (list 'ulong3 t))
    (:get-work-dim          (list 'uint  nil))
    ((:get-local-linear-id :get-local-linear-size
      :get-global-linear-id :get-global-linear-size
      :get-total-threads :get-total-groups)
     (list 'ulong nil))
    ((:local-barrier :mem-fence)
     (list nil nil))
    ;; 110 — warp helpers (scalar uint, no dim arg)
    ((:warp-id :warp-lane :warp-count)
     (list 'uint nil))
    (t (error "Unknown GPU builtin: ~a" builtin-kw))))


;; src/codegen.lisp
;;
;; L0-safe scalar SPIR-V builtin: load from an addrspace(1) i32 global
;; @__spirv_BuiltIn<NAME> with zeroinitializer.  Mirrors the vec3 helper
;; (%call-spirv-vec3-builtin) so the LLVM-SPIRV translator emits a
;; SPIR-V OpVariable BuiltIn decoration rather than an import-linkage
;; function declaration (which causes ZE_RESULT_ERROR_INVALID_MODULE_UNLINKED
;; on Level Zero).
(defun %call-spirv-uint-global-builtin (builder module spirv-name)
  "Loads from an addrspace(1) i32 global @__spirv_BuiltIn<SPIRV-NAME>."
  (let* ((gvar-name (format nil "__spirv_BuiltIn~a" spirv-name))
         (i32-type  (crisp.llvm-bindings::llvm-int32-type))
         (existing  (crisp.llvm-bindings::llvm-get-named-global module gvar-name))
         (gvar      (if (cffi:null-pointer-p existing)
                        (let ((g (crisp.llvm-bindings::llvm-add-global-in-addrspace module i32-type gvar-name 1)))
                          (crisp.llvm-bindings::llvm-set-initializer g (crisp.llvm-bindings::llvm-const-null i32-type))
                          g)
                        existing)))
    (crisp.llvm-bindings::llvm-build-load2 builder i32-type gvar (string-downcase spirv-name))))


;; src/codegen.lisp
;;
;; Whole-method replacement of the semantic-gpu-builtin codegen dispatcher,
;; adding cases for :warp-id, :warp-lane, :warp-count.  Returns i32 (uint).
(defmethod generate-node-ir ((node semantic-gpu-builtin) builder module var-env di-builder di-scope location-map)
  "Generates LLVM IR for a GPU built-in function call."
  (declare (ignore var-env di-builder di-scope location-map))
  (let* ((bname (semantic-gpu-builtin-builtin-name node))
         (dim   (semantic-gpu-builtin-dimension node)))
    (log:info "Generating GPU builtin IR: ~a dim=~a" bname dim)
    (labels
        ((vec3-or-scalar (spirv-name)
           (let ((vec (%call-spirv-vec3-builtin builder module spirv-name)))
             (if dim
                 (values (%extract-vec3-i64 builder vec dim (format nil "~a_~a" (string-downcase spirv-name) dim)) nil)
                 (values vec nil)))))
      (case bname
        ;; --- Primitive 3D/scalar vector builtins ---
        (:get-global-id       (vec3-or-scalar "GlobalInvocationId"))
        (:get-local-id        (vec3-or-scalar "LocalInvocationId"))
        (:get-workgroup-id    (vec3-or-scalar "WorkgroupId"))
        (:get-num-groups      (vec3-or-scalar "NumWorkgroups"))
        (:get-local-work-size (vec3-or-scalar "WorkgroupSize"))
        (:get-global-work-size (vec3-or-scalar "GlobalSize"))
        (:get-global-offset   (vec3-or-scalar "GlobalOffset"))
        ;; --- Synthesized: GlobalInvocationId + GlobalOffset ---
        (:get-global-id-abs
         (let* ((gid  (%call-spirv-vec3-builtin builder module "GlobalInvocationId"))
                (goff (%call-spirv-vec3-builtin builder module "GlobalOffset")))
           (if dim
               (let* ((gid-n  (%extract-vec3-i64 builder gid  dim "gid_n"))
                      (goff-n (%extract-vec3-i64 builder goff dim "goff_n")))
                 (values (crisp.llvm-bindings::llvm-build-add builder gid-n goff-n "gid_abs_n") nil))
               (values (crisp.llvm-bindings::llvm-build-add builder gid goff "gid_abs") nil))))
        ;; --- WorkDim (hidden kernel parameter, uint) ---
        (:get-work-dim
         (values (%call-spirv-uint-builtin builder module "WorkDim") nil))
        ;; --- Synthesized scalar builtins ---
        (:get-local-linear-id
         (values (%gen-local-linear-id builder module) nil))
        (:get-local-linear-size
         (values (%gen-product-of-vec3 builder module "WorkgroupSize" "local_linear_size") nil))
        (:get-global-linear-id
         (values (%gen-global-linear-id builder module) nil))
        ((:get-global-linear-size :get-total-threads)
         (values (%gen-product-of-vec3 builder module "GlobalSize" "total_threads") nil))
        (:get-total-groups
         (values (%gen-product-of-vec3 builder module "NumWorkgroups" "total_groups") nil))
        ;; --- 110: warp helpers (scalar uint, L0-safe addrspace(1) globals) ---
        (:warp-id
         (values (%call-spirv-uint-global-builtin builder module "SubgroupId") nil))
        (:warp-lane
         (values (%call-spirv-uint-global-builtin builder module "SubgroupLocalInvocationId") nil))
        (:warp-count
         (values (%call-spirv-uint-global-builtin builder module "NumSubgroups") nil))
        ;; --- Barriers (void) ---
        (:local-barrier (%gen-spirv-control-barrier builder module))
        (:mem-fence     (%gen-spirv-memory-barrier  builder module))
        (t (error "generate-node-ir: unknown GPU builtin ~a" bname))))))


;; src/macros.lisp
;;
;; Whole-function replacement of %expand-stride-macros-in-form, adding
;; WORKGROUP-STRIDE dispatch.  The AD pre-pass uses this walker to fully
;; expand stride macros before anf-transform runs (since anf doesn't know
;; stride forms by name).  Without this, a differentiable kernel containing
;; workgroup-stride would leave the form unexpanded going into ANF.
(defun %expand-stride-macros-in-form (form type-resolver-fn location)
  "Recursively walks FORM and rewrites tensor-stride / grid-stride /
   loop-vector-stride / tile-stride / hardware-stride / workgroup-stride
   forms into their expansions."
  (cond
    ((atom form) form)
    ((not (and (consp form) (symbolp (car form))))
     (mapcar (lambda (sub) (%expand-stride-macros-in-form sub type-resolver-fn location)) form))
    (t
     (let ((op-name (symbol-name (car form))))
       (cond
         ((string-equal op-name "TENSOR-STRIDE")
          (let* ((walked (cons (car form)
                               (mapcar (lambda (sub)
                                         (%expand-stride-macros-in-form sub type-resolver-fn location))
                                       (cdr form))))
                 (ct (%tensor-stride-resolve-ct walked type-resolver-fn location)))
            (%expand-tensor-stride-form walked ct location)))
         ((string-equal op-name "GRID-STRIDE")
          (let ((walked (cons (car form)
                              (mapcar (lambda (sub)
                                        (%expand-stride-macros-in-form sub type-resolver-fn location))
                                      (cdr form)))))
            (%expand-grid-stride-form walked location)))
         ((string-equal op-name "LOOP-VECTOR-STRIDE")
          (let ((walked (cons (car form)
                              (mapcar (lambda (sub)
                                        (%expand-stride-macros-in-form sub type-resolver-fn location))
                                      (cdr form)))))
            (%expand-loop-vector-stride-form walked location)))
         ((string-equal op-name "TILE-STRIDE")
          (let* ((walked (cons (car form)
                               (mapcar (lambda (sub)
                                         (%expand-stride-macros-in-form sub type-resolver-fn location))
                                       (cdr form))))
                 (cl-pkg (find-package :crisp-language))
                 (ts-sym (intern "TENSOR-STRIDE" cl-pkg))
                 (strict-p (keywordp (third walked)))
                 (tile-pos (if strict-p 3 2))
                 (bindings (nth (1+ tile-pos) walked))
                 (synth-for-ct (if strict-p
                                   (list ts-sym (second walked) (third walked) bindings)
                                   (list ts-sym (second walked) bindings)))
                 (ct (%tensor-stride-resolve-ct synth-for-ct type-resolver-fn location)))
            (%expand-tile-stride-form walked ct location)))
         ((string-equal op-name "HARDWARE-STRIDE")
          (let* ((walked (cons (car form)
                               (mapcar (lambda (sub)
                                         (%expand-stride-macros-in-form sub type-resolver-fn location))
                                       (cdr form))))
                 (cl-pkg (find-package :crisp-language))
                 (ts-sym (intern "TENSOR-STRIDE" cl-pkg))
                 ;; Detect strict variant: 3rd is layout-tag, 4th is hw-tag.
                 (third (third walked))
                 (strict-p (and (keywordp third)
                                (member third '(:row-major :col-major :contiguous-last :contiguous-first))))
                 (hw-pos (if strict-p 3 2))
                 (bindings (nth (1+ hw-pos) walked))
                 (synth-for-ct (if strict-p
                                   (list ts-sym (second walked) (third walked) bindings)
                                   (list ts-sym (second walked) bindings)))
                 (ct (%tensor-stride-resolve-ct synth-for-ct type-resolver-fn location)))
            (%expand-hardware-stride-form walked ct location)))
         ((string-equal op-name "WORKGROUP-STRIDE")
          (let ((walked (cons (car form)
                              (mapcar (lambda (sub)
                                        (%expand-stride-macros-in-form sub type-resolver-fn location))
                                      (cdr form)))))
            (%expand-workgroup-stride-form walked location)))
         (t
          (cons (car form)
                (mapcar (lambda (sub)
                          (%expand-stride-macros-in-form sub type-resolver-fn location))
                        (cdr form)))))))))
