(in-package :crisp.hoist.l0)

;; Overlay file for crisp-hoist-l0
;; Add late-binding fixes here as needed


;;;; ============================================================
;;;; SROA: def-record array fields explode to N individual args.
;;;; When a def-record has an (array T N) field, the compiler now
;;;; SROA's it to N individual T parameters in the physical signature.
;;;; %record-field-args must match: emit N individual
;;;; zeKernelSetArgumentValue calls instead of one array call.
;;;; ============================================================

;; src/hoist-l0/main.lisp
(defun %record-field-args (stream members var-path arg-index records aliases)
  "Recursively emit field initialization and zeKernelSetArgumentValue calls
   for all leaf fields of a record, following nested records.
   Array-typed members are SROA'd: iota-initialized and passed as N
   individual scalar args (one per element), matching the compiler's
   physical signature which explodes (array T N) to N scalar slots.
   Returns the updated arg-index after consuming all fields."
  (let ((idx arg-index))
    (dolist (member members)
      (let* ((field-sym       (first member))
             (field-type-raw  (second member))
             (field-type      (resolve-type-alias field-type-raw aliases))
             (field-name-cpp  (format-cpp-identifier field-sym))
             (field-path      (format nil "~a.~a" var-path field-name-cpp)))
        (cond
         ;; Array member — SROA: iota-init, then N individual zeKernelSetArgumentValue calls
         ((%array-type-p field-type)
          (let* ((elem-type (%array-element-type field-type))
                 (arr-size  (%array-size field-type))
                 (elem-str  (crisp-type-to-cpp-type elem-type)))
            (format stream "    // Iota-init array member ~a (~a elements, SROA'd to ~a scalar args)~%"
                    field-path arr-size arr-size)
            (format stream "    for (int _i = 0; _i < ~a; _i++) ~a[_i] = (~a)_i;~%"
                    arr-size field-path elem-str)
            (loop for i from 0 below arr-size do
              (format stream "    // Arg ~d: ~a[~d]~%" idx field-path i)
              (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(~a), &~a[~d]);~%"
                      idx elem-str field-path i)
              (incf idx))))
         ;; Nested record — recurse into its members
         ((record-type-p field-type records)
          (let* ((nested-def     (find-record-def field-type records))
                 (nested-members (cddr nested-def)))
            (setf idx (%record-field-args stream nested-members field-path idx records aliases))))
         ;; Scalar leaf — type-appropriate init, individual arg
         (t
          (let* ((cpp-type (crisp-type-to-cpp-type field-type))
                 (init-val (cond ((string= cpp-type "float")  "1.0f")
                                 ((string= cpp-type "double") "1.0")
                                 (t "1"))))
            (format stream "    ~a = ~a;~%" field-path init-val)
            (format stream "    // Arg ~d: ~a~%" idx field-path)
            (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(~a), &~a);~%"
                    idx cpp-type field-path)
            (incf idx))))))
    idx))


