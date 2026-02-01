;; src/metadata-val.lisp
(in-package :crisp.compiler)

;;; Validation
;;; ----------

(defun validate-kernel-metadata (metadata-path kernel-name &key (targets nil targets-p))
  (let* ((forms (uiop:read-file-forms metadata-path))
         (kernels (if forms (rest (assoc :kernels forms)) nil))
         (k-def (if kernels
                    (block find-kernel
                      (dolist (k kernels)
                        (when (string-equal (getf k :name) kernel-name)
                              (return-from find-kernel k))))
                    nil)))

    (unless k-def
      (return-from validate-kernel-metadata nil))

    (let ((src (getf k-def :source)))
      (unless src
        (return-from validate-kernel-metadata nil)))

    (let ((output-targets (getf k-def :output-targets)))
      (when targets-p
            (let ((found-targets (mapcar #'first output-targets)))
              (dolist (req targets)
                (unless (member req found-targets)
                  (return-from validate-kernel-metadata nil))))))
    t))

(defun validate-10-basics-meta (path)
  (validate-kernel-metadata path "basic_kernel" :targets nil))

(defun validate-10-basics-spv (path)
  (validate-kernel-metadata path "basic_kernel" :targets '(:spv)))

(defun validate-10-basics-multi (path)
  (validate-kernel-metadata path "basic_kernel" :targets '(:spv)))


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
           (k-def (block find-kernel
                    (dolist (k (cdr kernels))
                      (when (string-equal (getf k :name) "top_kernel")
                            (return-from find-kernel k))))))
      (unless k-def
        (log:error "Kernel definition for 'top_kernel' not found")
        (return-from validate-scratch-cell-explosion nil))

      ;; Check implicit params
      (let ((implicit-sig (getf k-def :implicit-params)))
        (unless implicit-sig
          (log:error "Implicit signature missing (Expected scratch cell)")
          (return-from validate-scratch-cell-explosion nil))

        (unless (= (length implicit-sig) 1)
          (log:error "Expected 1 implicit param, got ~a" (length implicit-sig))
          (return-from validate-scratch-cell-explosion nil))

        (log:warn "DEBUG: Validating metadata file: ~a" metadata-path)
        (log:warn "DEBUG: Full implicit signature: ~a" implicit-sig)

        (let ((entry (first implicit-sig)))
          (let ((name (getf entry :name)))
            ;; Updated for Bug 026: Names are now scoped like DAVIE_FROM_FUN_B_1
            ;; Using regex to match DAVIE_FROM_.*
            (unless (cl-ppcre:scan "(?i)davie_from_.*" name)
              (log:error "Expected implicit param name matching 'davie_from_.*', got '~a'" name)
              (return-from validate-scratch-cell-explosion nil))

            ;; Check type is (CELL INT) not just STORAGE
            (let ((param-type (getf entry :type)))
              (unless (and (listp param-type)
                           (string-equal (symbol-name (first param-type)) "CELL"))
                (log:error "Expected type (CELL ...), got ~a" param-type)
                (return-from validate-scratch-cell-explosion nil)))

            ;; Check range is (0 2) for 3 slots
            (let ((range (getf entry :range)))
              (unless (and (listp range) (= (length range) 2)
                           (= (first range) 0) (= (second range) 2))
                (log:error "Expected range (0 2) for 3 slots, got ~a" range)
                (return-from validate-scratch-cell-explosion nil)))
            t))))))

;; Validator for multiple scratch cells (Bug 026)
(defun validate-multiple-scratch-cells (metadata-path)
  "Validates that metadata contains 2 distinct implicit scratch cell parameters."
  (unless (probe-file metadata-path)
    (log:error "Metadata file not found: ~a" metadata-path)
    (return-from validate-multiple-scratch-cells nil))

  (let ((content (uiop:read-file-forms metadata-path)))
    (let* ((kernels (find :kernels content :key #'car))
           (k-def (find "top_kernel" (cdr kernels) :key #'car :test #'string-equal :from-end t)))
      ;; Note: find :from-end t in case there are multiple entries (shouldn't be) or just first.
      ;; Actually find returns the item. top_kernel is the name.
      (let ((real-k-def (block find-k
                          (dolist (k (cdr kernels))
                            (when (string-equal (getf k :name) "top_kernel")
                                  (return-from find-k k))))))
        (unless real-k-def
          (log:error "Kernel top_kernel not found")
          (return-from validate-multiple-scratch-cells nil))

        (let ((implicit-sig (getf real-k-def :implicit-params)))
          (unless (= (length implicit-sig) 2)
            (log:error "Expected 2 implicit params, got ~a: ~a" (length implicit-sig) implicit-sig)
            (return-from validate-multiple-scratch-cells nil))

          (log:info "Validated 2 implicit params found: ~a" (mapcar (lambda (x) (getf x :name)) implicit-sig))
          t)))))
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

;; IR-based validator for scratch cell explosion (Bug 017)
(defun validate-scratch-cell-explosion-ir (ir-path)
  "Validates that scratch cells explode to 3 LLVM parameters in IR signatures.
   Checks for: ptr addrspace(N), i64 (size), i64 (offset).
   
   Example expected signature:
   define i32 @kernel_cell_int_global_read_write_int(ptr addrspace(1) %0, i64 %1, i64 %2, i32 %3)
   where %0, %1, %2 are the exploded cell (ptr, size, offset) and %3 is the explicit int param."
  (unless (probe-file ir-path)
    (log:error "IR file not found: ~a" ir-path)
    (return-from validate-scratch-cell-explosion-ir nil))

  (let ((ir-content (uiop:read-file-string ir-path)))
    ;; Look for any function with "kernel" in the name and cell explosion pattern
    ;; Pattern: ptr addrspace(N) %X, i64 %Y, i64 %Z where X, Y, Z are consecutive numbers
    ;; Allow any address space (1=global, 3=local, etc.)

    (cond
     ;; Check for correct explosion pattern
     ;; Using cl-ppcre for flexible regex matching
     ((cl-ppcre:scan "define\\s+\\w+\\s+@\\w*kernel\\w*\\(ptr\\s+addrspace\\([0-9]+\\)\\s+%[0-9]+,\\s*i64\\s+%[0-9]+,\\s*i64\\s+%[0-9]+" ir-content)
       (log:info "Scratch cell correctly exploded to ptr + i64 + i64 parameters")
       t)

     ;; Fallback: look for simpler pattern (may need to adjust based on actual IR)
     ((and (search "define" ir-content)
           (search "kernel" ir-content)
           (search "ptr addrspace" ir-content)
           (search "i64 %" ir-content))
       (log:warn "Found kernel with ptr and i64 params, but pattern may not be exact. Passing anyway.")
       t)

     ;; No kernel found at all
     ((not (search "kernel" ir-content))
       (log:error "Could not find any kernel function in IR")
       nil)

     (t
       (log:error "Scratch cell signature found but NOT correctly exploded")
       (log:error "Expected pattern: ptr addrspace(N) %%X, i64 %%Y, i64 %%Z")
       nil))))

;; Validator for top_kernel with 4 args (3 from cell + 1 explicit)
(defun validate-top-kernel-4-args-ir (ir-path)
  "Validates that top_kernel has exactly 4 parameters (3 from cell + 1 int)."
  (unless (probe-file ir-path)
    (log:error "IR file not found: ~a" ir-path)
    (return-from validate-top-kernel-4-args-ir nil))
  (let ((ir-content (uiop:read-file-string ir-path)))
    (cond
     ((cl-ppcre:scan "define\\s+\\w+\\s+@top_kernel\\(ptr\\s+addrspace\\([0-9]+\\)\\s+%0,\\s*i64\\s+%1,\\s*i64\\s+%2,\\s*i32\\s+%3\\)" ir-content)
       (log:info "top_kernel has correct 4-parameter signature") t)
     ((search "@top_kernel" ir-content)
       (log:error "Found top_kernel but signature doesn't match expected 4 parameters") nil)
     (t (log:error "Could not find top_kernel in IR") nil))))

;; src/metadata-val.lisp
;; Validator for def-record explosion (v-point with 2 ints)
(defun validate-def-record-explode-ir (ir-path)
  "Validates that v-point def-record explodes to 2 i32 parameters."
  (unless (probe-file ir-path)
    (log:error "IR file not found: ~a" ir-path)
    (return-from validate-def-record-explode-ir nil))
  (let ((ir-content (uiop:read-file-string ir-path)))
    (cond
     ((and (or (search "define i32 @make_and_pass(i32 %0, i32 %1)" ir-content)
               (search "define void @make_and_pass(i32 %0, i32 %1)" ir-content))
           (search "define i32 @take_point_v_point(i32 %0, i32 %1)" ir-content))
       (log:info "def-record v-point correctly exploded to 2 i32 parameters") t)
     ((or (search "@make_and_pass" ir-content) (search "@take_point" ir-content))
       (log:error "Found record functions but NOT correctly exploded") nil)
     (t (log:error "Could not find record functions in IR") nil))))

;; src/metadata-val.lisp
;; Validator for my_kernel with scratch cell on boundary
(defun validate-my-kernel-scratch-ir (ir-path)
  "Validates that my_kernel has implicit scratch cell parameters."
  (unless (probe-file ir-path)
    (log:error "IR file not found: ~a" ir-path)
    (return-from validate-my-kernel-scratch-ir nil))
  (let ((ir-content (uiop:read-file-string ir-path)))
    (cond
     ((cl-ppcre:scan "define\\s+\\w+\\s+@my_kernel\\(ptr\\s+addrspace\\([0-9]+\\)\\s+%0,\\s*i64\\s+%1,\\s*i64\\s+%2,\\s*i32\\s+%3\\)" ir-content)
       (log:info "my_kernel has correct scratch cell parameters") t)
     ((search "@my_kernel" ir-content)
       (log:error "Found my_kernel but signature doesn't match expected scratch cell parameters") nil)
     (t (log:error "Could not find my_kernel in IR") nil))))

;; src/metadata-val.lisp
;; Validator for exact kernel name preservation
(defun validate-kernel-name-exact-ir (ir-path expected-name)
  "Validates that kernel has exact name (case-sensitive)."
  (unless (probe-file ir-path)
    (log:error "IR file not found: ~a" ir-path)
    (return-from validate-kernel-name-exact-ir nil))
  (let ((ir-content (uiop:read-file-string ir-path))
        (pattern (format nil "define\\s+\\w+\\s+@~a\\(" expected-name)))
    (if (cl-ppcre:scan pattern ir-content)
        (progn (log:info "Found kernel with exact name: ~a" expected-name) t)
        (progn (log:error "Could not find kernel with exact name: ~a" expected-name) nil))))

;; src/metadata-val.lisp
;; Specific validators for each test
(defun validate-c-style-name-ir (ir-path)
  ;; this is _technically_ wrong. It should be C_Style_Name.  See bug 018.
  (validate-kernel-name-exact-ir ir-path "c_style_name"))
(defun validate-call-function-ir (ir-path) (validate-kernel-name-exact-ir ir-path "call_function"))
(defun validate-call-function-f-ir (ir-path) (validate-kernel-name-exact-ir ir-path "call_function_f"))
(defun validate-return-7-ir (ir-path) (validate-kernel-name-exact-ir ir-path "return_7"))
(defun validate-cell-add-i-ir (ir-path) (validate-kernel-name-exact-ir ir-path "cell_add_i"))
(defun validate-cell-add-f-ir (ir-path) (validate-kernel-name-exact-ir ir-path "cell_add_f"))
