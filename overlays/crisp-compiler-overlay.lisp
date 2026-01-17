;;; Fix for Bug 013: Recursive def-type hangs
;;; v8: Added fix for parse-type-specifier in environment.lisp

(in-package :crisp.compiler)
;; src/metadata.lisp
;; Validator for def-record parameter explosion (Bug 015/017)
(defun validate-def-record-explosion (metadata-path)
  "Validates that def-record types are exploded in physical signatures."
  (unless (probe-file metadata-path)
    (log:error "Metadata file not found: ~a" metadata-path)
    (return-from validate-def-record-explosion nil))

  (let ((content (uiop:read-file-forms metadata-path)))
    (let* ((kernels (find :kernels content :key #'car))
           (k-def (find "make_and_pass" (cdr kernels) :key #'car :test #'string-equal)))
      (unless k-def
        (log:error "Kernel definition for 'make_and_pass' not found")
        (return-from validate-def-record-explosion nil))

      ;; Check physical signature
      (let ((phys-sig (getf (cdr k-def) :physical-signature)))
        (unless phys-sig
          (log:error "Physical signature missing")
          (return-from validate-def-record-explosion nil))

        ;; Point def-record has 2 runtime members (x int, y int)
        ;; So it should explode to 2 parameters
        (unless (= (length phys-sig) 2)
          (log:error "Expected 2 exploded parameters for Point, got ~a: ~a" (length phys-sig) phys-sig)
          (return-from validate-def-record-explosion nil))

        ;; Verify both are INT type
        (let ((type-0 (second (first phys-sig)))
              (type-1 (second (second phys-sig))))
          (unless (and (symbolp type-0) (string-equal (symbol-name type-0) "INT"))
            (log:error "Expected first param to be INT, got ~a" type-0)
            (return-from validate-def-record-explosion nil))
          (unless (and (symbolp type-1) (string-equal (symbol-name type-1) "INT"))
            (log:error "Expected second param to be INT, got ~a" type-1)
            (return-from validate-def-record-explosion nil))

          t)))))

;; Validator for scratch cell explosion (Bug 015/017)
(defun validate-scratch-cell-explosion (metadata-path)
  "Validates that scratch cells explode to 3 slots in metadata."
  (unless (probe-file metadata-path)
    (log:error "Metadata file not found: ~a" metadata-path)
    (return-from validate-scratch-cell-explosion nil))

  (let ((content (uiop:read-file-forms metadata-path)))
    (let* ((kernels (find :kernels content :key #'car))
           (k-def (find "top_kernel" (cdr kernels) :key #'car :test #'string-equal)))
      (unless k-def
        (log:error "Kernel definition for 'top_kernel' not found")
        (return-from validate-scratch-cell-explosion nil))

      ;; Check implicit params
      (let ((implicit-sig (getf (cdr k-def) :implicit-params)))
        (unless implicit-sig
          (log:error "Implicit signature missing (Expected scratch cell)")
          (return-from validate-scratch-cell-explosion nil))

        (unless (= (length implicit-sig) 1)
          (log:error "Expected 1 implicit param, got ~a" (length implicit-sig))
          (return-from validate-scratch-cell-explosion nil))

        (let ((entry (first implicit-sig)))
          ;; Check name is "sc" (the actual scratch cell variable name)
          (unless (string-equal (first entry) "sc")
            (log:error "Expected implicit param name 'sc', got '~a'" (first entry))
            (return-from validate-scratch-cell-explosion nil))

          ;; Check type is (CELL INT) not just STORAGE
          (let ((param-type (getf (cdr entry) :type)))
            (unless (and (listp param-type)
                         (string-equal (symbol-name (first param-type)) "CELL"))
              (log:error "Expected type (CELL ...), got ~a" param-type)
              (return-from validate-scratch-cell-explosion nil)))

          ;; Check range is (0 2) for 3 slots
          (let ((range (getf (cdr entry) :range)))
            (unless (and (listp range) (= (length range) 2)
                         (= (first range) 0) (= (second range) 2))
              (log:error "Expected range (0 2) for 3 slots, got ~a" range)
              (return-from validate-scratch-cell-explosion nil))

            t))))))
