;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;;;; ============================================================================
;;;; REFACTORING: Single-Pass vs Multi-Pass Clarity
;;;; ============================================================================
;;;; This overlay implements Option 1 from the refactoring analysis:
;;;;   - Add mode predicates for clarity
;;;;   - Remove redundant single-pass-call-stack
;;;;   - Simplify recursion detection
;;;;   - Replace direct *call-graph* checks with named predicates

;;;; ============================================================================
;;;; PATCH 1: Mode Predicates
;;;; ============================================================================

(defun multi-pass-mode-p ()
  "Returns T if in multi-pass compilation mode, NIL if in single-pass mode.

   Multi-pass mode builds a call graph, propagates implicit arguments, and
   allows forward references. Single-pass requires dependency-ordered code."
  (not (null *call-graph*)))

(defun single-pass-mode-p ()
  "Returns T if in single-pass compilation mode, NIL if in multi-pass mode.

   Single-pass mode compiles each form immediately as read, requiring functions
   to be defined before use (no forward references). Used for fast JIT compilation."
  (null *call-graph*))

;;;; ============================================================================
;;;; PATCH 2: Simplified Recursion Detection
;;;; ============================================================================
;;;; File: src/analysis/core.lisp
;;;; Removes single-pass-call-stack, uses current-compiling-function directly

(defun %compile-standard-function (form location module builder di-builder di-compile-unit location-map)
  "Helper: Compiles a standard (non-generic) function definition."
  (let* ((name (second form))
         (context *compiler-context*))
    (setf (compiler-context-current-compiling-function context) name)
    ;; PATCHED: Removed push/pop of single-pass-call-stack
    (unwind-protect
        (let* ((form-with-location (append form (list :source-location `',location)))
               (expanded-form (macroexpand-1 form-with-location))
               (semantic-node (eval expanded-form)))
          ;; Handle implicit templates which return nil
          (when semantic-node
                (log:info "Generating IR for function ~a in module ~a" name module)
                (generate-llvm-ir semantic-node module builder di-builder di-compile-unit location-map)))
      ;; Cleanup: clear current function (replaces pop of stack)
      (setf (compiler-context-current-compiling-function context) nil))))

;;;; ============================================================================
;;;; PATCH 3: Use Mode Predicates in scan-for-carriers
;;;; ============================================================================
;;;; File: src/environment.lisp

(defun scan-for-carriers (name body)
  "Performs a single-pass look-ahead to detect if the function is a carrier.

   This logic is ONLY executed in single-pass mode. It serves two purposes:
   1. Early originator detection - finds make-scratch-cell BEFORE env is built
   2. Upward carrier propagation - copies implicit args from callees to callers

   In multi-pass mode, this analysis is handled by analyze-signatures-pass."
  (when (single-pass-mode-p)
        (with-peek-scratch-counter
         (let ((*scanning-function-name* name))
           (setf (compiler-context-scanning-function-name *compiler-context*) name)
           (multiple-value-bind (is-originator callees) (shallow-analyze-body body)
             (when (or is-originator (some (lambda (callee)
                                             (or (gethash callee *implicit-arg-map*)
                                                 (member callee *side-channel-originators*)))
                                       callees))
                   (log:debug "Single-pass: Pre-scan of ~s found call to a carrier/originator. Marking as carrier." name)

                   ;; Union all implicit args from ALL callees
                   (let ((all-implicits nil))
                     (dolist (callee callees)
                       (let ((callee-imps (gethash callee *implicit-arg-map*)))
                         (when callee-imps
                               (setf all-implicits (union all-implicits callee-imps :test #'equal)))))

                     (when all-implicits
                           (setf (gethash name *implicit-arg-map*) all-implicits)))))))))

;;;; ============================================================================
;;;; PATCH 4: Simplified Recursion Detection in analyze-function-call
;;;; ============================================================================
;;;; File: src/analysis/core.lisp

(defun analyze-function-call (op expr env context location)
  "Analyzes a call to a user-defined function."
  (log:debug "Analyzing function call to ~s. Current function: ~s" op (compiler-context-current-compiling-function context))

  ;; PATCHED: Use mode predicates and simplified recursion check
  (if (multi-pass-mode-p)
      (when (compiler-context-current-compiling-function context)
            (pushnew op (gethash (compiler-context-current-compiling-function context) *call-graph*)))
      (when (eq op (compiler-context-current-compiling-function context))
            (error 'crisp-recursion-error :form op :source-location (append location '(0)))))

  ;; PATCHED: Use single-pass-mode-p predicate
  (let ((implicit-args-required (gethash op *implicit-arg-map*)))
    (when (and (single-pass-mode-p) implicit-args-required)
          (setf (gethash (compiler-context-current-compiling-function context) *implicit-arg-map*) implicit-args-required))

    (let* ((arg-forms (rest expr))
           (explicit-arg-nodes (loop for arg-form in arg-forms
                                     for i from 1
                                     collect (analyze-expression arg-form env context (append location (list i)))))
           (explicit-arg-types (mapcar #'get-single-value-type explicit-arg-nodes))
           (signature (resolve-best-signature op explicit-arg-types context)))

      (let ((final-arg-nodes
             (if implicit-args-required
                 (let ((implicit-arg-nodes
                        (loop for (param-name . param-type) in implicit-args-required
                              collect (let ((found (find-variable-in-env param-name env)))
                                        (if found
                                            (make-semantic-var-read :name param-name :type (parameter-def-type found) :source-location location)
                                            (error "Compiler bug: Carrier function ~s is missing implicit argument ~s."
                                              (compiler-context-current-compiling-function context) param-name))))))
                   (append implicit-arg-nodes explicit-arg-nodes))
                 explicit-arg-nodes)))

        (unless (= (length explicit-arg-types) (length (function-signature-parameters signature)))
          (error 'crisp-signature-arity-error
            :expected (length (function-signature-parameters signature))
            :inferred (length explicit-arg-types)
            :source-location location))

        (let ((augmented-signature
               (if implicit-args-required
                   (let ((implicit-params (loop for (param-name . param-type) in implicit-args-required
                                                collect (make-parameter-def :name param-name :type param-type :kind :in))))
                     (make-function-signature
                      :name (function-signature-name signature)
                      :parameters (append implicit-params (function-signature-parameters signature))
                      :return-types (function-signature-return-types signature)
                      :source-location (function-signature-source-location signature)
                      :is-template-p (function-signature-is-template-p signature)
                      :template-params (function-signature-template-params signature)))
                   signature)))

          (make-semantic-call :name (function-signature-name augmented-signature)
                              :type (function-signature-return-types augmented-signature)
                              :args final-arg-nodes
                              :signature augmented-signature
                              :source-location location))))))

(log:info "Compiler overlay loaded: Mode predicates + simplified single-pass")
