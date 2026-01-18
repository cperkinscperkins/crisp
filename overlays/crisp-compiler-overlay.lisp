(in-package :crisp.compiler)

;; src/metadata-val.lisp
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
(defun validate-c-style-name-ir (ir-path) (validate-kernel-name-exact-ir ir-path "c_Style_Name"))
(defun validate-call-function-ir (ir-path) (validate-kernel-name-exact-ir ir-path "call_function"))
(defun validate-call-function-f-ir (ir-path) (validate-kernel-name-exact-ir ir-path "call_function_f"))
(defun validate-return-7-ir (ir-path) (validate-kernel-name-exact-ir ir-path "return_7"))
(defun validate-cell-add-i-ir (ir-path) (validate-kernel-name-exact-ir ir-path "cell_add_i"))
(defun validate-cell-add-f-ir (ir-path) (validate-kernel-name-exact-ir ir-path "cell_add_f"))
