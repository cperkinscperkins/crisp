;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;;; ============================================================
;;; 092-dotimes
;;; ============================================================

;; src/analysis/control.lisp
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

;; src/codegen.lisp
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
         ;; Alloca for the loop variable; initialize to 0
         (i-alloca    (llvm-build-alloca builder llvm-type (string-downcase (symbol-name var-name))))
         (_           (llvm-build-store builder (llvm-const-int llvm-type 0 0) i-alloca))
         ;; Basic blocks
         (check-block (llvm-append-basic-block current-fn "dt_check"))
         (body-block  (llvm-append-basic-block current-fn "dt_body"))
         (exit-block  (llvm-append-basic-block current-fn "dt_exit")))
    (declare (ignore _))
    ;; Branch from current block into loop check
    (llvm-build-br builder check-block)
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

;; src/analysis/control.lisp
;; Redefine register-control-analyzers to include dotimes registration.
;; This ensures the analyzer survives initialize-compiler's clrhash.
(defun register-control-analyzers ()
  "Registers all control flow expression analyzers, including length~ and dotimes."
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
  ;; length~ — dual-package registration (source in :crisp-language, ANF output in :crisp.compiler)
  (let ((sym-cl (intern "LENGTH~" (find-package :crisp-language)))
        (sym-cc (intern "LENGTH~" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-length-tilde-expression)
    (setf (gethash sym-cc *expression-analyzers*) #'analyze-length-tilde-expression))
  ;; dotimes — dual-package registration:
  ;;   crisp-language::dotimes for .crisp source files
  ;;   cl::dotimes for ANF-transformed output (anf-transform rebuilds with cl::dotimes)
  (let ((sym-cl (intern "DOTIMES" (find-package :crisp-language)))
        (sym-cc (intern "DOTIMES" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-dotimes-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-dotimes-expression))))

;; src/analysis/core.lisp
;; Redefine semantic-node-type to include semantic-dotimes.
(defun semantic-node-type (node)
  "Returns the Crisp type of a semantic node.
Extended for 092-dotimes."
  (etypecase node
    (semantic-dotimes (semantic-dotimes-type node))
    (semantic-literal (semantic-literal-value-type node))
    (semantic-device-vec-literal (semantic-device-vec-literal-vec-type node))
    (semantic-var-read (semantic-var-read-type node))
    (semantic-add (semantic-add-type node))
    (semantic-sub (semantic-sub-type node))
    (semantic-mul (semantic-mul-type node))
    (semantic-div (semantic-div-type node))
    (semantic-sin (semantic-sin-type node))
    (semantic-cos (semantic-cos-type node))
    (semantic-lt 'int)
    (semantic-gt 'int)
    (semantic-le 'int)
    (semantic-ge 'int)
    (semantic-eq 'int)
    (semantic-neq 'int)
    (semantic-if (semantic-if-type node))
    (semantic-set! 'void)
    (semantic-aref (semantic-aref-type node))
    (semantic-value-cast (semantic-value-cast-type node))
    (semantic-let (semantic-let-type node))
    (semantic-bitcast (semantic-bitcast-type node))
    (semantic-fp-truncate-cast (semantic-fp-truncate-cast-type node))
    (semantic-truncate (semantic-truncate-type node))
    (semantic-explicit-return (semantic-explicit-return-type node))
    (semantic-call (semantic-call-type node))
    (semantic-funcall (semantic-funcall-type node))
    (semantic-extract-value (semantic-extract-value-type node))
    (semantic-insert-value (semantic-insert-value-type node))
    (semantic-struct-construction (semantic-struct-construction-type node))
    (semantic-ct-array (semantic-ct-array-type node))
    (semantic-progn (semantic-progn-type node))
    (semantic-struct-member-update (semantic-struct-member-update-type node))
    (semantic-sizeof (semantic-sizeof-type node))
    (semantic-make-view (semantic-make-view-type node))
    (semantic-atomic-rmw (semantic-atomic-rmw-type node))
    (semantic-stride-view (semantic-stride-view-type node))
    (semantic-gpu-builtin (semantic-gpu-builtin-type node))))

;; src/analysis/core.lisp
;; Redefine semantic-node-source-location to include semantic-dotimes.
(defun semantic-node-source-location (node)
  "Returns the source location of a semantic node.
Extended for 092-dotimes."
  (etypecase node
    (semantic-dotimes (semantic-dotimes-source-location node))
    (semantic-literal (semantic-literal-source-location node))
    (semantic-device-vec-literal (semantic-device-vec-literal-source-location node))
    (semantic-var-read (semantic-var-read-source-location node))
    (semantic-value-cast (semantic-value-cast-source-location node))
    (semantic-bitcast (semantic-bitcast-source-location node))
    (semantic-let (semantic-let-source-location node))
    (semantic-fp-truncate-cast (semantic-fp-truncate-cast-source-location node))
    (semantic-truncate (semantic-truncate-source-location node))
    (semantic-add (semantic-add-source-location node))
    (semantic-sub (semantic-sub-source-location node))
    (semantic-mul (semantic-mul-source-location node))
    (semantic-div (semantic-div-source-location node))
    (semantic-sin (semantic-sin-source-location node))
    (semantic-cos (semantic-cos-source-location node))
    (semantic-lt (semantic-lt-source-location node))
    (semantic-gt (semantic-gt-source-location node))
    (semantic-le (semantic-le-source-location node))
    (semantic-ge (semantic-ge-source-location node))
    (semantic-sizeof (semantic-sizeof-source-location node))
    (semantic-eq (semantic-eq-source-location node))
    (semantic-neq (semantic-neq-source-location node))
    (semantic-if (semantic-if-source-location node))
    (semantic-set! (semantic-set!-source-location node))
    (semantic-aref (semantic-aref-source-location node))
    (semantic-explicit-return (semantic-explicit-return-source-location node))
    (semantic-call (semantic-call-source-location node))
    (semantic-funcall (semantic-funcall-source-location node))
    (semantic-extract-value (semantic-extract-value-source-location node))
    (semantic-insert-value (semantic-insert-value-source-location node))
    (semantic-struct-construction (semantic-struct-construction-source-location node))
    (semantic-ct-array (semantic-ct-array-source-location node))
    (semantic-progn (semantic-progn-source-location node))
    (semantic-struct-member-update (semantic-struct-member-update-source-location node))
    (semantic-make-view (semantic-make-view-source-location node))
    (semantic-atomic-rmw (semantic-atomic-rmw-source-location node))
    (semantic-stride-view (semantic-stride-view-source-location node))
    (semantic-gpu-builtin (semantic-gpu-builtin-source-location node))))
