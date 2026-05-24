;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)


;; ======================================================================
;; Endeavor 113 — async load-tile / store-tile (Phase 1)
;; ======================================================================

;; src/analysis/control.lisp
;;
;; Phase 1a forward analyzer for REQUEST-LOAD-TILE-COORDS.  Degrades to
;; the sync load-tile-coords expansion; tacks on a phantom ulong token
;; so the surrounding `(let ((tok (request-...))) ...)` form has a value
;; to bind.  Phase 1b will replace this with backend-specific async
;; lowering for :spirv and :ptx.
;;
;; Phase 1d gating: errors out if *target-backend* is :generic (i.e.
;; no --ir-target).  Matches the spec from the 113 plan and the 087
;; design intent (request-* and the other GPU-builtin family don't have
;; meaningful generic LLVM).

;; Phase 1d gate (missing-target / single-outstanding) defers to 1b/1c
;; once real backend-specific code paths exist.  In 1a the fallback path
;; works for any *target-backend* (including :generic), so refusing
;; :generic would just block the spec runner's default pass for no
;; reason.

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

(defun analyze-request-load-tile-coords-expression (expr env context location)
  "Phase 1a analyzer for request-load-tile-coords.  Reuses the sync
   divergence guard then delegates to the fallback expansion."
  (%tlc-check-not-divergent "request-load-tile-coords" location)
  (analyze-expression (%expand-request-load-tile-coords-form expr location)
                      env context location))

(defun analyze-await-request-expression (expr env context location)
  "Phase 1a analyzer for await-request.  In fallback mode the matching
   request-* has already emitted its barrier, so this is a no-op that
   just yields a phantom ulong 0.  Validates arity."
  (unless (= (length expr) 2)
    (error 'crisp-compiler-error
           :message (format nil "await-request: expected (await-request TOKEN), got ~S" expr)
           :source-location location))
  (let ((cl-pkg (find-package :crisp-language)))
    (analyze-expression (list (intern "TO-ULONG" cl-pkg) 0)
                        env context location)))

;; Register the two new analyzers.  Because initialize-compiler calls
;; initialize-expression-analyzers which clrhashes *expression-analyzers*
;; and re-runs the register-* funcs, top-level registrations at overlay
;; load time get wiped.  Whole-function redefine register-control-analyzers
;; to add the two new entries at the end.  Body verbatim from
;; src/analysis/control.lisp with the 113 block appended.

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
  (let ((sym-cl (intern "AWAIT-REQUEST" (find-package :crisp-language)))
        (sym-cc (intern "AWAIT-REQUEST" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-await-request-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-await-request-expression))))


;; src/macros.lisp
;;
;; AD pre-rewrite: normalise REQUEST-LOAD-TILE-COORDS -> LOAD-TILE-COORDS
;; and AWAIT-REQUEST -> NIL before the backward walker sees them.  This
;; keeps generate-backward-walk innocent of async semantics — the
;; gradient flow is identical to the sync case.
;;
;; This is a whole-function replacement of %expand-stride-macros-in-form
;; from src/macros.lisp with two new clauses added at the end of the
;; cond.  Runs only inside %generate-backward-kernel-ast (the sole caller).

(defun %expand-stride-macros-in-form (form type-resolver-fn location)
  "Recursively walks FORM and rewrites tensor-stride / grid-stride /
   loop-vector-stride / tile-stride / hardware-stride / workgroup-stride
   forms into their expansions.  Endeavor 113: also normalises
   request-load-tile-coords -> load-tile-coords and await-request -> nil
   for the backward pass."
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
         ;; --- Endeavor 113 Phase 1a AD pre-rewrite. ---
         ;; request-load-tile-coords -> load-tile-coords (sync).  AD has
         ;; no use for async; the backward scatter pattern is naturally
         ;; barrier-bound.  Recurse into args so any nested stride
         ;; macros in the origin list are still expanded.
         ((string-equal op-name "REQUEST-LOAD-TILE-COORDS")
          (let ((sync-sym (intern "LOAD-TILE-COORDS" (find-package :crisp-language))))
            (cons sync-sym
                  (mapcar (lambda (sub)
                            (%expand-stride-macros-in-form sub type-resolver-fn location))
                          (cdr form)))))
         ;; await-request -> nil.  process-form's null/atom catchall
         ;; emits nothing for the backward pass, which is exactly what
         ;; we want (the load-tile-coords-bwd inside it has its own
         ;; barriers).
         ((string-equal op-name "AWAIT-REQUEST")
          nil)
         (t
          (cons (car form)
                (mapcar (lambda (sub)
                          (%expand-stride-macros-in-form sub type-resolver-fn location))
                        (cdr form)))))))))
