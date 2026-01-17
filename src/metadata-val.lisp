;; src/metadata-val.lisp
(in-package :crisp.compiler)

(defun validate-12-multiple-kernels (paths)
  "Validates that multiple kernel metadata files are generated."
  (unless (listp paths)
    (log:error "Validation Failed: Expected list of paths, got ~a" paths)
    (return-from validate-12-multiple-kernels nil))

  (let ((result t))
    ;; Check k_one
    (let ((p1 (find "_k_one.metacrisp" paths :test #'search :key #'namestring)))
      (if p1
          (unless (validate-kernel-metadata p1 "k_one")
            (log:error "Validation Failed: k_one metadata invalid")
            (setf result nil))
          (progn
           (log:error "Validation Failed: k_one metadata file not found in ~a" paths)
           (setf result nil))))

    ;; Check k_two
    (let ((p2 (find "_k_two.metacrisp" paths :test #'search :key #'namestring)))
      (if p2
          (unless (validate-kernel-metadata p2 "k_two")
            (log:error "Validation Failed: k_two metadata invalid")
            (setf result nil))
          (progn
           (log:error "Validation Failed: k_two metadata file not found in ~a" paths)
           (setf result nil))))

    result))

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

        ;; V-POINT def-record has 2 runtime members (x int, y int)
        ;; So it should explode to 2 parameters
        (unless (= (length phys-sig) 2)
          (log:error "Expected 2 exploded parameters for V-POINT, got ~a: ~a" (length phys-sig) phys-sig)
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
;; src/metadata-val.lisp
;; IR-based validator for Bug 015 (def-record explosion)
(defun validate-def-record-explosion-ir (ir-path)
  "Validates that def-record types are exploded in LLVM IR signatures.
   Takes a path to a .ll file containing LLVM IR."
  (unless (probe-file ir-path)
    (log:error "IR file not found: ~a" ir-path)
    (return-from validate-def-record-explosion-ir nil))

  (let ((ir-content (uiop:read-file-string ir-path)))
    ;; Check for the exploded signature: define void @make_and_pass(i32 %0, i32 %1)
    ;; V-POINT has 2 INT fields, so should be exploded to 2 i32 parameters
    (cond
     ((search "define void @make_and_pass(i32 %0, i32 %1)" ir-content)
       ;; Also verify take_point is exploded
       (if (search "define i32 @take_point_v_point(i32 %0, i32 %1)" ir-content)
           t
           (progn
            (log:error "take_point not exploded in IR")
            nil)))

     ((search "define void @make_and_pass(%V-POINT" ir-content)
       (log:error "make_and_pass signature NOT exploded - found V-POINT aggregate")
       nil)

     (t
       (log:error "Could not find make_and_pass signature in IR")
       nil))))
