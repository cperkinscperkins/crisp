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
