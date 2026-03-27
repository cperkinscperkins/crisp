;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;; src/codegen.lisp
(defun %generate-let-binding (binding builder module let-env di-builder di-scope location-map memoized-aggregates)
  "Helper: Generates IR for a single let binding.
   Updates let-env with the new binding and returns the alloca.
   Extended to use llvm-build-extract-element for device-vector aggregates
   instead of llvm-build-extract-value (which is for struct aggregates only)."
  (let* ((var-name (car binding))
         (val-node (cdr binding))
         (llvm-type-name (get-single-value-type val-node)))

    (let ((val-ir
           (if (typep val-node 'semantic-extract-value)
               ;; If it's an extract, check if we've already generated the aggregate.
               (let* ((agg-node  (semantic-extract-value-aggregate-node val-node))
                      (agg-type  (semantic-node-type agg-node))
                      (ct        (%dvec-type-lookup agg-type))
                      (is-dvec   (and ct (eq (crisp-type-category ct) :device-vector)))
                      (agg-val   (or (gethash agg-node memoized-aggregates)
                                     ;; If not, generate and memoize it.
                                     (let ((new-agg-val (generate-expression-ir builder module let-env di-builder di-scope location-map agg-node)))
                                       (setf (gethash agg-node memoized-aggregates) new-agg-val)
                                       new-agg-val)))
                      (index     (semantic-extract-value-index val-node)))
                 (if is-dvec
                     ;; Device-vector: use extractelement (takes i32 index value)
                     (llvm-build-extract-element builder agg-val
                                                 (llvm-const-int (llvm-int32-type) index nil)
                                                 (format nil "comp_~d" index))
                     ;; Struct aggregate: use extractvalue (existing behaviour)
                     (llvm-build-extract-value builder agg-val index (format nil "extract_~a" index))))
               ;; Otherwise, it's a simple binding.
               ;; SENSITIVE CONTEXT UPDATE: We must set *compiler-context* binding name
               ;; so that make-scratch-cell can reconstruct the unique ID (sc_from_Fn_N).
               (let ((old-binding (compiler-context-current-binding-name *compiler-context*)))
                 (setf (compiler-context-current-binding-name *compiler-context*) var-name)
                 (unwind-protect
                     (generate-expression-ir builder module let-env di-builder di-scope location-map val-node)
                   (setf (compiler-context-current-binding-name *compiler-context*) old-binding))))))

      ;; Allocate and store
      (let ((alloca (llvm-build-alloca builder (crisp-type-to-llvm-type llvm-type-name module) (string-downcase var-name))))
        (llvm-build-store builder val-ir alloca)
        (setf (gethash var-name let-env) alloca)
        alloca))))
