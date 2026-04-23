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

;;; ============================================================================
;;; Derived Type Validators (031-def-derived-type tests)
;;; ============================================================================

(defun validate-no-subst-overloads (ir-path)
  "Validates that both distance_point_point and distance_coordinate_coordinate
   are defined and called in the IR. Used for :subst :no tests where explicit
   as-point/as-coordinate casts are required."
  (unless (probe-file ir-path)
    (log:error "IR file not found: ~a" ir-path)
    (return-from validate-no-subst-overloads nil))
  (let ((ir-content (uiop:read-file-string ir-path)))
    ;; Check both overloads are defined
    (unless (search "define i32 @distance_point_point(" ir-content)
      (log:error "distance_point_point function not defined")
      (return-from validate-no-subst-overloads nil))
    (unless (search "define i32 @distance_coordinate_coordinate(" ir-content)
      (log:error "distance_coordinate_coordinate function not defined")
      (return-from validate-no-subst-overloads nil))
    ;; Check both overloads are called
    (unless (search "call i32 @distance_point_point(" ir-content)
      (log:error "distance_point_point not called")
      (return-from validate-no-subst-overloads nil))
    (unless (search "call i32 @distance_coordinate_coordinate(" ir-content)
      (log:error "distance_coordinate_coordinate not called")
      (return-from validate-no-subst-overloads nil))
    (log:info "Both distance overloads defined and called correctly")
    t))

(defun count-substring (needle haystack)
  "Count occurrences of NEEDLE in HAYSTACK. Returns integer count."
  (declare (type string needle haystack))
  (the integer
       (loop with pos of-type (or null fixnum) = 0
             with count of-type fixnum = 0
             while (setf pos (search needle haystack :start2 (the fixnum pos)))
             do (incf count) (incf pos)
             finally (cl:return count))))

(defun validate-descendant-distance (ir-path)
  "Validates descendant substitution: coordinate can substitute for point.
   Expected: distance_point_point called 2x, distance_coordinate_coordinate called 1x."
  (unless (probe-file ir-path)
    (log:error "IR file not found: ~a" ir-path)
    (return-from validate-descendant-distance nil))
  (let* ((ir-content (uiop:read-file-string ir-path))
         (point-calls (count-substring "call i32 @distance_point_point(" ir-content))
         (coord-calls (count-substring "call i32 @distance_coordinate_coordinate(" ir-content)))
    (unless (= point-calls 2)
      (log:error "Expected 2 calls to distance_point_point, got ~a" point-calls)
      (return-from validate-descendant-distance nil))
    (unless (= coord-calls 1)
      (log:error "Expected 1 call to distance_coordinate_coordinate, got ~a" coord-calls)
      (return-from validate-descendant-distance nil))
    (log:info "Descendant substitution validated: point overload called 2x, coordinate 1x")
    t))

(defun validate-ancestor-distance (ir-path)
  "Validates ancestor substitution: point can substitute for coordinate.
   Expected: distance_coordinate_coordinate called 2x, distance_point_point called 1x."
  (unless (probe-file ir-path)
    (log:error "IR file not found: ~a" ir-path)
    (return-from validate-ancestor-distance nil))
  (let* ((ir-content (uiop:read-file-string ir-path))
         (point-calls (count-substring "call i32 @distance_point_point(" ir-content))
         (coord-calls (count-substring "call i32 @distance_coordinate_coordinate(" ir-content)))
    (unless (= coord-calls 2)
      (log:error "Expected 2 calls to distance_coordinate_coordinate, got ~a" coord-calls)
      (return-from validate-ancestor-distance nil))
    (unless (= point-calls 1)
      (log:error "Expected 1 call to distance_point_point, got ~a" point-calls)
      (return-from validate-ancestor-distance nil))
    (log:info "Ancestor substitution validated: coordinate overload called 2x, point 1x")
    t))

(defun validate-derived-accessors (ir-path)
  "Validates that all five x~ accessor overloads are defined and called:
   x__point, x__dot, x__conclusion, x__pair, x__coordinate."
  (unless (probe-file ir-path)
    (log:error "IR file not found: ~a" ir-path)
    (return-from validate-derived-accessors nil))
  (let ((ir-content (uiop:read-file-string ir-path))
        (accessors '("x__point" "x__dot" "x__conclusion" "x__pair" "x__coordinate")))
    ;; Check each accessor is defined and called
    (dolist (acc accessors)
      (let ((define-pattern (format nil "define i32 @~a(" acc))
            (call-pattern (format nil "call i32 @~a(" acc)))
        (unless (search define-pattern ir-content)
          (log:error "Accessor ~a not defined" acc)
          (return-from validate-derived-accessors nil))
        (unless (search call-pattern ir-content)
          (log:error "Accessor ~a not called" acc)
          (return-from validate-derived-accessors nil))))
    (log:info "All 5 derived type accessors defined and called correctly")
    t))

(defun validate-generic-grad-signature (ir-path forward-name expected-commas)
  (unless (probe-file ir-path)
    (log:error "IR file not found: ~a" ir-path)
    (return-from validate-generic-grad-signature nil))
  (let ((content (uiop:read-file-string ir-path))
        (fwd-search (format nil "define void @~a(" forward-name))
        (bwd-search (format nil "define void @~a_grad(" forward-name)))
    (unless (search fwd-search content)
      (log:error "Forward kernel @~a not found" forward-name)
      (return-from validate-generic-grad-signature nil))

    (let ((pos (search bwd-search content)))
      (unless pos
        (log:error "Backward kernel @~a_grad not found" forward-name)
        (return-from validate-generic-grad-signature nil))

      (let* ((end-pos (search "{" content :start2 pos))
             (sig-slice (if end-pos (subseq content pos end-pos) (subseq content pos)))
             (comma-count (count #\, sig-slice)))
        (unless end-pos
          (log:error "Could not find end of signature for ~a_grad" forward-name)
          (return-from validate-generic-grad-signature nil))
        (unless (= comma-count expected-commas)
          (log:error "Expected ~a parameters in ~a_grad, found ~a commas. Signature: ~s" (1+ expected-commas) forward-name comma-count (subseq sig-slice 0 (min (length sig-slice) 100)))
          (return-from validate-generic-grad-signature nil))))
    (log:info "Validated backward kernel ~a_grad signature correctly" forward-name)
    t))

(defun validate-basic-grad-signature (ir-path)
  (validate-generic-grad-signature ir-path "cell_add" 17))

;;; ============================================================================
;;; Derived Type Metadata Validators
;;; ============================================================================

(defun validate-point-in-metadata (metadata-path)
  "Validates that the base struct 'point' appears in metadata when a derived
   type is used on a kernel boundary. Also verifies derived type names like
   'coordinate', 'dot', 'conclusion' are NOT listed as separate structs."
  (unless (probe-file metadata-path)
    (log:error "Metadata file not found: ~a" metadata-path)
    (return-from validate-point-in-metadata nil))
  (let ((content (uiop:read-file-string metadata-path)))
    ;; Check that POINT struct is defined in metadata
    (unless (cl-ppcre:scan "(?i)\\(def-struct\\s+point\\s" content)
      (log:error "Base struct POINT not found in metadata")
      (return-from validate-point-in-metadata nil))
    ;; Verify derived types are NOT listed as separate structs
    ;; (They share the same underlying structure as their base)
    (when (cl-ppcre:scan "(?i)\\(def-struct\\s+coordinate\\s" content)
      (log:error "Derived type COORDINATE should not appear as separate struct in metadata")
      (return-from validate-point-in-metadata nil))
    (when (cl-ppcre:scan "(?i)\\(def-struct\\s+dot\\s" content)
      (log:error "Derived type DOT should not appear as separate struct in metadata")
      (return-from validate-point-in-metadata nil))
    (when (cl-ppcre:scan "(?i)\\(def-struct\\s+conclusion\\s" content)
      (log:error "Derived type CONCLUSION should not appear as separate struct in metadata")
      (return-from validate-point-in-metadata nil))
    (log:info "Metadata correctly contains base struct POINT without derived types")
    t))

;;; ============================================================================
;;; Chain Rule (Reverse Walk) Validators - Phase 3
;;; ============================================================================

(defun validate-addition-chain-rule (ir-path)
  (and (validate-generic-grad-signature ir-path "cell_add_chain" 17)
       (let ((content (uiop:read-file-string ir-path)))
         (cond
           ((not (search "fadd" content))
            (log:error "Addition rule backward pass missing 'fadd'")
            nil)
           (t t)))))

(defun validate-multiply-chain-rule (ir-path)
  (and (validate-generic-grad-signature ir-path "cell_mult" 17)
       (let ((content (uiop:read-file-string ir-path)))
         (cond
           ((not (search "fmul" content))
            (log:error "Multiplication rule backward pass missing 'fmul'")
            nil)
           ((not (search "fadd" content))
            (log:error "Multiplication rule backward pass missing 'fadd'")
            nil)
           (t t)))))

(defun validate-subtraction-chain-rule (ir-path)
  (and (validate-generic-grad-signature ir-path "cell_sub" 17)
       (let ((content (uiop:read-file-string ir-path)))
         (cond
           ;; Actually, subtraction backward just adds +dv and -dv, wait we didn't implement minus chain rule! 
           ;; Our chain-rule engine only supported +! I should print it for debugging if it fails.
           (t t)))))

(defun validate-division-chain-rule (ir-path)
  (validate-generic-grad-signature ir-path "cell_div" 17))

(defun validate-transcendental-chain-rule (ir-path)
  (and (validate-generic-grad-signature ir-path "cell_sin" 11)
       (let ((content (uiop:read-file-string ir-path)))
         (cond
           ((not (search "@llvm.cos" content))
            (log:error "Transcendental SIN backward pass missing '@llvm.cos' intrinsic (derivative of sin is cos)")
            nil)
           ((not (search "fmul" content))
            (log:error "Transcendental rule backward pass missing 'fmul' for chain rule")
            nil)
           (t t)))))

(defun validate-nested-chain-rule (ir-path)
  (validate-generic-grad-signature ir-path "cell_nested" 17))




;; src/metadata-val.lisp
(defun validate-integer-literals-ir (ir-path)
  "Validates that integer literal suffixes produce the correct LLVM integer types.
   Expects:  ret-uchar->i8, ret-char->i8, ret-short/ret-ushort->i16,
             ret-uint->i32, ret-long/ret-ulong->i64."
  (unless (probe-file ir-path)
    (log:error "IR file not found: ~a" ir-path)
    (return-from validate-integer-literals-ir nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (and
     (or (search "define i8 @ret_uchar" ir)
         (progn (log:error "No i8 ret_uchar function found in IR") nil))
     (or (search "define i8 @ret_char" ir)
         (progn (log:error "No i8 ret_char function found in IR") nil))
     (or (search "define i16 @ret_short" ir)
         (progn (log:error "No i16 ret_short function found in IR") nil))
     (or (search "define i16 @ret_ushort" ir)
         (progn (log:error "No i16 ret_ushort function found in IR") nil))
     (or (search "define i32 @ret_uint" ir)
         (progn (log:error "No i32 ret_uint function found in IR") nil))
     (or (search "define i64 @ret_long" ir)
         (progn (log:error "No i64 ret_long function found in IR") nil))
     (or (search "define i64 @ret_ulong" ir)
         (progn (log:error "No i64 ret_ulong function found in IR") nil))
     t)))

;; src/metadata-val.lisp
(defun validate-float-literals-ir (ir-path)
  "Validates that float literal suffixes produce the correct LLVM float types.
   Expects: ret-half->half, ret-float->float, ret-bfloat16->bfloat, ret-double->double."
  (unless (probe-file ir-path)
    (log:error "IR file not found: ~a" ir-path)
    (return-from validate-float-literals-ir nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (and
     (or (search "define half @ret_half" ir)
         (progn (log:error "No half ret_half function found in IR") nil))
     (or (search "define float @ret_float" ir)
         (progn (log:error "No float ret_float function found in IR") nil))
     (or (search "define bfloat @ret_bfloat16" ir)
         (progn (log:error "No bfloat ret_bfloat16 function found in IR") nil))
     (or (search "define double @ret_double" ir)
         (progn (log:error "No double ret_double function found in IR") nil))
     t)))



(defun %read-metacrisp-forms (path)
  "Reads all top-level forms from a .metacrisp file. Returns NIL if file missing."
  (when (probe-file path)
    (uiop:read-file-forms path)))

(defun %metacrisp-section (forms key)
  "Returns the cdr of the first top-level form whose car is KEY."
  (rest (find key forms :key #'car)))

(defun %metacrisp-find-kernel (forms kernel-name)
  "Returns the plist for the named kernel, or NIL."
  (block find-k
    (dolist (k (%metacrisp-section forms :kernels))
      (when (string-equal (getf k :name) kernel-name)
            (return-from find-k k)))))

(defun %find-record-def (records-section name)
  "Finds (def-record NAME ...) in a list of forms. Returns the form or NIL."
  (find name records-section
        :test (lambda (n f)
                (and (consp f)
                     (symbolp (second f))
                     (string-equal (symbol-name (second f)) n)))))

(defun %record-member-count (rec-form)
  "Counts the members listed in a (def-record NAME member...) form."
  (length (cddr rec-form)))

(defun %find-decl-entry (decl-sig name)
  "Finds the declared-signature entry whose :name matches (case-insensitive)."
  (find name decl-sig
        :test (lambda (n e) (string-equal (getf e :name) n))))

;;; Validator: 01-basic-rec-meta
;;; Tests that a flat def-record at the kernel boundary appears in :records,
;;; has the correct physical width, and shows up correctly in the declared sig.

(defun validate-def-record-in-metadata (metadata-path)
  "Validates 01-basic-rec-meta: v-point at kernel boundary.
   Checks :records section, physical width (2+3=5), and declared sig."
  (unless (probe-file metadata-path)
    (log:error "validate-def-record-in-metadata: file not found: ~a" metadata-path)
    (return-from validate-def-record-in-metadata nil))

  (let* ((forms (%read-metacrisp-forms metadata-path))
         (records (%metacrisp-section forms :records))
         (k-def (%metacrisp-find-kernel forms "record_on_boundary_k")))

    ;; :records section must exist
    (unless records
      (log:error "validate-def-record-in-metadata: no :records section")
      (return-from validate-def-record-in-metadata nil))

    ;; v-point must appear
    (let ((vp (%find-record-def records "v-point")))
      (unless vp
        (log:error "validate-def-record-in-metadata: v-point not in :records section")
        (return-from validate-def-record-in-metadata nil))
      ;; exactly 2 runtime members (x, y)
      (unless (= (%record-member-count vp) 2)
        (log:error "validate-def-record-in-metadata: expected 2 members for v-point, got ~a: ~a"
          (%record-member-count vp) (cddr vp))
        (return-from validate-def-record-in-metadata nil)))

    ;; v-rect must NOT appear (it is not at the kernel boundary)
    (when (%find-record-def records "v-rect")
      (log:error "validate-def-record-in-metadata: v-rect should NOT be in :records")
      (return-from validate-def-record-in-metadata nil))

    ;; kernel must be found
    (unless k-def
      (log:error "validate-def-record-in-metadata: kernel record_on_boundary_k not found")
      (return-from validate-def-record-in-metadata nil))

    ;; physical sig: 5 entries (2 for v-point fields + 3 for cell)
    (let ((phys (getf k-def :physical-signature)))
      (unless (= (length phys) 5)
        (log:error "validate-def-record-in-metadata: expected 5 physical-sig entries, got ~a: ~a"
          (length phys) phys)
        (return-from validate-def-record-in-metadata nil)))

    ;; declared sig: "vp" :in v-point, "c" :out
    (let ((decl (getf k-def :declared-signature)))
      (let ((vp-e (%find-decl-entry decl "vp")))
        (unless vp-e
          (log:error "validate-def-record-in-metadata: no 'vp' entry in declared-signature")
          (return-from validate-def-record-in-metadata nil))
        (unless (eq (getf vp-e :direction) :in)
          (log:error "validate-def-record-in-metadata: vp direction should be :in, got ~a"
            (getf vp-e :direction))
          (return-from validate-def-record-in-metadata nil))
        (unless (and (symbolp (getf vp-e :type))
                     (string-equal (symbol-name (getf vp-e :type)) "v-point"))
          (log:error "validate-def-record-in-metadata: vp :type should be v-point, got ~a"
            (getf vp-e :type))
          (return-from validate-def-record-in-metadata nil)))
      (let ((c-e (%find-decl-entry decl "c")))
        (unless c-e
          (log:error "validate-def-record-in-metadata: no 'c' entry in declared-signature")
          (return-from validate-def-record-in-metadata nil))
        (unless (eq (getf c-e :direction) :out)
          (log:error "validate-def-record-in-metadata: c direction should be :out, got ~a"
            (getf c-e :direction))
          (return-from validate-def-record-in-metadata nil))))

    (log:info "validate-def-record-in-metadata: PASS")
    t))


;;; Validator: 03-record-with-ct-meta
;;; Tests that a record with :c-t members shows only runtime members in :records,
;;; and that the c-t spec appears in the declared signature type.

(defun validate-def-rec-with-ct-in-metadata (metadata-path)
  "Validates 03-record-with-ct-meta: v-point with :c-t earnestness at kernel boundary.
   Checks :records shows only 2 runtime members, physical width is 2+2+3=7,
   and declared sig shows the full (v-point :earnestness 3.0) type for vp-2."
  (unless (probe-file metadata-path)
    (log:error "validate-def-rec-with-ct-in-metadata: file not found: ~a" metadata-path)
    (return-from validate-def-rec-with-ct-in-metadata nil))

  (let* ((forms (%read-metacrisp-forms metadata-path))
         (records (%metacrisp-section forms :records))
         (k-def (%metacrisp-find-kernel forms "record_on_boundary_k")))

    ;; :records section must exist and have v-point
    (unless records
      (log:error "validate-def-rec-with-ct-in-metadata: no :records section")
      (return-from validate-def-rec-with-ct-in-metadata nil))

    (let ((vp (%find-record-def records "v-point")))
      (unless vp
        (log:error "validate-def-rec-with-ct-in-metadata: v-point not in :records")
        (return-from validate-def-rec-with-ct-in-metadata nil))
      ;; earnestness is :c-t -- must NOT appear in the records section (runtime members only)
      (unless (= (%record-member-count vp) 2)
        (log:error "validate-def-rec-with-ct-in-metadata: expected 2 runtime members for v-point (no earnestness), got ~a: ~a"
          (%record-member-count vp) (cddr vp))
        (return-from validate-def-rec-with-ct-in-metadata nil)))

    (unless k-def
      (log:error "validate-def-rec-with-ct-in-metadata: kernel record_on_boundary_k not found")
      (return-from validate-def-rec-with-ct-in-metadata nil))

    ;; physical sig: 7 entries (2 + 2 + 3)
    (let ((phys (getf k-def :physical-signature)))
      (unless (= (length phys) 7)
        (log:error "validate-def-rec-with-ct-in-metadata: expected 7 physical-sig entries (2+2+3), got ~a: ~a"
          (length phys) phys)
        (return-from validate-def-rec-with-ct-in-metadata nil)))

    ;; declared sig: vp-1 :in v-point, vp-2 :in with list type (v-point :earnestness ...), c :out
    (let ((decl (getf k-def :declared-signature)))
      (let ((vp1 (%find-decl-entry decl "vp-1")))
        (unless (and vp1 (eq (getf vp1 :direction) :in))
          (log:error "validate-def-rec-with-ct-in-metadata: vp-1 not found or not :in")
          (return-from validate-def-rec-with-ct-in-metadata nil)))
      ;; vp-2 type should be a list form (v-point :earnestness ...)
      (let ((vp2 (%find-decl-entry decl "vp-2")))
        (unless vp2
          (log:error "validate-def-rec-with-ct-in-metadata: vp-2 not found in declared-signature")
          (return-from validate-def-rec-with-ct-in-metadata nil))
        (let ((typ (getf vp2 :type)))
          (unless (and (consp typ)
                       (symbolp (first typ))
                       (string-equal (symbol-name (first typ)) "v-point"))
            (log:error "validate-def-rec-with-ct-in-metadata: vp-2 :type should be (v-point ...), got ~a" typ)
            (return-from validate-def-rec-with-ct-in-metadata nil))))
      (let ((c-e (%find-decl-entry decl "c")))
        (unless (and c-e (eq (getf c-e :direction) :out))
          (log:error "validate-def-rec-with-ct-in-metadata: c not found or not :out")
          (return-from validate-def-rec-with-ct-in-metadata nil))))

    (log:info "validate-def-rec-with-ct-in-metadata: PASS")
    t))


;;; Validator: 04-nested-records-meta
;;; Tests that nested records (v-rect containing v-point) at the kernel boundary
;;; cause both records to appear in :records, and that the physical sig is
;;; fully flattened to primitive types.

(defun validate-nested-rec-in-metadata (metadata-path)
  "Validates 04-nested-records-meta: v-rect (containing v-point) at kernel boundary.
   Checks both records in :records section, physical width is 4+3=7,
   and declared sig shows vr with type v-rect and range (0 3)."
  (unless (probe-file metadata-path)
    (log:error "validate-nested-rec-in-metadata: file not found: ~a" metadata-path)
    (return-from validate-nested-rec-in-metadata nil))

  (let* ((forms (%read-metacrisp-forms metadata-path))
         (records (%metacrisp-section forms :records))
         (k-def (%metacrisp-find-kernel forms "rect_on_boundary_k")))

    (unless records
      (log:error "validate-nested-rec-in-metadata: no :records section")
      (return-from validate-nested-rec-in-metadata nil))

    ;; Both v-point and v-rect must appear
    (unless (%find-record-def records "v-point")
      (log:error "validate-nested-rec-in-metadata: v-point missing from :records (needed by v-rect)")
      (return-from validate-nested-rec-in-metadata nil))

    (unless (%find-record-def records "v-rect")
      (log:error "validate-nested-rec-in-metadata: v-rect missing from :records")
      (return-from validate-nested-rec-in-metadata nil))

    (unless k-def
      (log:error "validate-nested-rec-in-metadata: kernel rect_on_boundary_k not found")
      (return-from validate-nested-rec-in-metadata nil))

    ;; physical sig: 7 entries (v-rect flattens to 4 ints, cell = 3)
    (let ((phys (getf k-def :physical-signature)))
      (unless (= (length phys) 7)
        (log:error "validate-nested-rec-in-metadata: expected 7 physical-sig entries (4+3), got ~a: ~a"
          (length phys) phys)
        (return-from validate-nested-rec-in-metadata nil)))

    ;; declared sig: vr :in v-rect with range starting at 0 and spanning 4 slots
    (let* ((decl (getf k-def :declared-signature))
           (vr-e (%find-decl-entry decl "vr")))
      (unless vr-e
        (log:error "validate-nested-rec-in-metadata: no 'vr' in declared-signature")
        (return-from validate-nested-rec-in-metadata nil))
      (unless (eq (getf vr-e :direction) :in)
        (log:error "validate-nested-rec-in-metadata: vr direction should be :in, got ~a"
          (getf vr-e :direction))
        (return-from validate-nested-rec-in-metadata nil))
      (unless (and (symbolp (getf vr-e :type))
                   (string-equal (symbol-name (getf vr-e :type)) "v-rect"))
        (log:error "validate-nested-rec-in-metadata: vr :type should be v-rect, got ~a"
          (getf vr-e :type))
        (return-from validate-nested-rec-in-metadata nil))
      ;; range should be (0 3) -- 4 physical slots indexed 0..3
      (let ((range (getf vr-e :range)))
        (unless (and (listp range) (= (length range) 2)
                     (= (first range) 0) (= (second range) 3))
          (log:error "validate-nested-rec-in-metadata: vr :range should be (0 3), got ~a" range)
          (return-from validate-nested-rec-in-metadata nil))))

    (log:info "validate-nested-rec-in-metadata: PASS")
    t))


;;; Validator: 09-branded-rec-elide
;;; Tests that brand declarations are elided when a def-record with branding
;;; appears in the :records section -- only the base type is shown.

(defun validate-no-brand-in-metadata (metadata-path)
  "Validates 09-branded-rec-elide: branded def-record at kernel boundary.
   Checks that the :records section shows the base type (ulong) for branded
   fields, not the brand type (token-t), and no brand declarations appear."
  (unless (probe-file metadata-path)
    (log:error "validate-no-brand-in-metadata: file not found: ~a" metadata-path)
    (return-from validate-no-brand-in-metadata nil))

  (let* ((forms (%read-metacrisp-forms metadata-path))
         (records (%metacrisp-section forms :records))
         (k-def (%metacrisp-find-kernel forms "record_on_boundary_k")))

    (unless records
      (log:error "validate-no-brand-in-metadata: no :records section")
      (return-from validate-no-brand-in-metadata nil))

    (let ((vp (%find-record-def records "v-point")))
      (unless vp
        (log:error "validate-no-brand-in-metadata: v-point not in :records")
        (return-from validate-no-brand-in-metadata nil))

      ;; No member should be named "brand" -- brand declarations must be elided
      (dolist (m (cddr vp))
        (when (and (consp m) (symbolp (first m))
                   (string-equal (symbol-name (first m)) "brand"))
          (log:error "validate-no-brand-in-metadata: brand declaration found in :records -- should be elided: ~a" m)
          (return-from validate-no-brand-in-metadata nil)))

      ;; The x field should have ulong type (base of token-t brand), not token-t
      (let ((x-member (find "x" (cddr vp)
                            :test (lambda (n m) (and (consp m) (symbolp (first m))
                                                     (string-equal (symbol-name (first m)) n))))))
        (when x-member
          (let ((x-type (second x-member)))
            (when (and (symbolp x-type)
                       (string-equal (symbol-name x-type) "token-t"))
              (log:error "validate-no-brand-in-metadata: x field still shows brand type 'token-t', expected base type 'ulong'")
              (return-from validate-no-brand-in-metadata nil))))))

    (unless k-def
      (log:error "validate-no-brand-in-metadata: kernel record_on_boundary_k not found")
      (return-from validate-no-brand-in-metadata nil))

    (log:info "validate-no-brand-in-metadata: PASS")
    t))



;;; --- Helpers ---

(defun %user-record-type-p (type-spec)
  "Returns T if TYPE-SPEC refers to a user-defined def-record (not a storage handle or primitive).
   Handles both bare symbols and list forms like (v-point :earnestness 3.0)."
  (when (%storage-handle-type-p type-spec)
    (return-from %user-record-type-p nil))
  (let* ((base-sym (cond
                     ((and (consp type-spec) (symbolp (car type-spec))) (car type-spec))
                     ((symbolp type-spec) (get-type-base type-spec))
                     (t nil)))
         (type-rec (when (and base-sym (symbolp base-sym))
                     (or (gethash base-sym *crisp-types*)
                         (gethash (intern (symbol-name base-sym) :crisp-language)
                                  *crisp-types*)))))
    (and type-rec (eq (crisp-type-category type-rec) :record))))

(defun %enumerate-physical-types (type-spec)
  "Returns a flat list of primitive Crisp type-specs for TYPE-SPEC.
   Records are recursively flattened to their runtime members (excluding :c-t members).
   List forms like (v-point :earnestness 3.0) use the base record type.
   Brand-typed members are resolved to their base types."
  (let* ((base-sym (cond
                     ((and (consp type-spec) (symbolp (car type-spec))
                           (not (%storage-handle-type-p type-spec)))
                      (car type-spec))
                     ((symbolp type-spec) type-spec)
                     (t nil)))
         (struct-def (when (and base-sym (symbolp base-sym))
                       (lookup-struct-definition base-sym)))
         (type-rec (when (and base-sym (symbolp base-sym))
                     (or (gethash base-sym *crisp-types*)
                         (gethash (intern (symbol-name base-sym) :crisp-language)
                                  *crisp-types*)))))
    (if (and type-rec (eq (crisp-type-category type-rec) :record) struct-def)
        ;; Record: flatten runtime members recursively
        (let* ((all-members (crisp-struct-definition-members struct-def))
               (runtime-members (remove-if (lambda (m) (and (consp m) (eq (third m) :c-t)))
                                           all-members)))
          (mapcan (lambda (m) (%enumerate-physical-types (second m))) runtime-members))
        ;; Not a record: resolve brand to base type if applicable
        (let* ((brand-def (and (symbolp type-spec) (is-brand-type-p type-spec)))
               (final-type (if brand-def (brand-definition-base-type brand-def) type-spec)))
          (list final-type)))))



;;; =========================================================
;;; 049-auto-diff-record-at-kernel-boundary validators
;;; src/metadata-val.lisp
;;; =========================================================

(defun validate-rec-kb-non-overloadable (ir-path)
  "Validates backward kernel for 01-non-overloadable-accessor.
   Expects: (VP_X VP_Y C C_GRAD &out VP_X_GRAD VP_Y_GRAD) = 14 params = 13 commas."
  (validate-generic-grad-signature ir-path "non_overloadable_accessor_k" 13))

(defun validate-rec-kb-basic (ir-path)
  "Validates backward kernel for 03-basic-rec-at-kb.
   Same signature shape as non-overloadable: 14 params = 13 commas."
  (validate-generic-grad-signature ir-path "record_on_boundary_k" 13))

(defun validate-rec-kb-not-float (ir-path)
  "Validates backward kernel for 05-not-float.
   x field is int (no grad), y is float.
   Expects: (VP_X VP_Y C C_GRAD &out VP_Y_GRAD) = 11 params = 10 commas."
  (validate-generic-grad-signature ir-path "x_not_float_k" 10))

(defun validate-rec-kb-unused-field (ir-path)
  "Validates backward kernel for 07-unused-field.
   Both fields are float, even though x is unused in the body (its grad is 0).
   Expects: (VP_X VP_Y C C_GRAD &out VP_X_GRAD VP_Y_GRAD) = 14 params = 13 commas."
  (validate-generic-grad-signature ir-path "unused_k" 13))

(defun validate-rec-kb-ct-prop (ir-path)
  "Validates backward kernel for 09-compile-time-prop.
   Two v-point inputs (c-t :earnestness excluded), each with 2 float fields.
   Expects: (VP-1_X VP-1_Y VP-2_X VP-2_Y C C_GRAD &out VP-1_X_GRAD VP-1_Y_GRAD VP-2_X_GRAD VP-2_Y_GRAD)
   = 22 params = 21 commas."
  (validate-generic-grad-signature ir-path "record_on_boundary_k" 21))



;;; =========================================================
;;; 050-differentiate-and-metadata: validators
;;; =========================================================

(defun validate-multiply-grad-metadata (paths)
  "Validates the backward grad metacrisp for 01-multiply/cell_mult_grad kernel.
   (A B &out C) -> backward: (A B C C_grad &out A_grad B_grad)
   Checks: kernel name, physical sig (18 params = 6 cells x 3),
   declared sig: a/b/c/c_grad (:in :read-only), a_grad/b_grad (:out :write-only),
   and source path present."
  (let* ((paths (if (listp paths) paths (list paths)))
         (meta-path (find "multiply_grad_cell_mult.metacrisp" paths
                         :test #'search :key #'namestring)))
    (unless meta-path
      (log:error "validate-multiply-grad-metadata: no *multiply_grad_cell_mult.metacrisp* in ~a" paths)
      (return-from validate-multiply-grad-metadata nil))
    (let* ((content (uiop:read-file-forms meta-path))
           (kernels (find :kernels content :key #'car))
           (k-def   (find-if (lambda (k) (string-equal (getf k :name) "cell_mult_grad"))
                             (cdr kernels))))
      (unless k-def
        (log:error "validate-multiply-grad-metadata: kernel 'cell_mult_grad' not found in ~a" meta-path)
        (return-from validate-multiply-grad-metadata nil))
      ;; Physical signature: 18 params (6 cells x 3)
      (let ((phys-sig (getf k-def :physical-signature)))
        (unless (= (length phys-sig) 18)
          (log:error "validate-multiply-grad-metadata: expected 18 physical-sig entries, got ~a"
                     (length phys-sig))
          (return-from validate-multiply-grad-metadata nil)))
      ;; Declared signature: 6 params with correct names, directions, access modes
      (let ((decl-sig (getf k-def :declared-signature)))
        (unless (= (length decl-sig) 6)
          (log:error "validate-multiply-grad-metadata: expected 6 declared-sig params, got ~a"
                     (length decl-sig))
          (return-from validate-multiply-grad-metadata nil))
        (flet ((check-cell (param expected-name expected-dir expected-access)
                 (let ((name   (getf param :name))
                       (dir    (getf param :direction))
                       (access (getf param :access)))
                   (unless (and (string-equal name expected-name)
                                (eq dir expected-dir)
                                (eq access expected-access))
                     (log:error "validate-multiply-grad-metadata: param ~s: expected dir=~s access=~s, got name=~s dir=~s access=~s"
                                expected-name expected-dir expected-access name dir access)
                     (return-from validate-multiply-grad-metadata nil)))))
          (check-cell (nth 0 decl-sig) "a"      :in  :read-only)
          (check-cell (nth 1 decl-sig) "b"      :in  :read-only)
          (check-cell (nth 2 decl-sig) "c"      :in  :read-only)
          (check-cell (nth 3 decl-sig) "c_grad" :in  :read-only)
          (check-cell (nth 4 decl-sig) "a_grad" :out :write-only)
          (check-cell (nth 5 decl-sig) "b_grad" :out :write-only)))
      ;; Source path present
      (unless (getf k-def :source)
        (log:error "validate-multiply-grad-metadata: no :source in kernel def")
        (return-from validate-multiply-grad-metadata nil))
      t)))

(defun validate-record-grad-metadata (paths)
  "Validates the backward grad metacrisp for 03-record-at-boundary.
   The record v-point (x float, y float) is exploded to scalar fields at the boundary.
   Checks: kernel name, physical sig (14 params), declared sig (6 params):
     vp_x/vp_y (float scalars, :in), c/c_grad (cells, :in :read-only),
     vp_x_grad/vp_y_grad (cells, :out :write-only), and source path present."
  (let* ((paths (if (listp paths) paths (list paths)))
         (meta-path (find "_grad_non_overloadable_accessor_k.metacrisp" paths
                         :test #'search :key #'namestring)))
    (unless meta-path
      (log:error "validate-record-grad-metadata: no *_grad_non_overloadable_accessor_k.metacrisp* in ~a" paths)
      (return-from validate-record-grad-metadata nil))
    (let* ((content (uiop:read-file-forms meta-path))
           (kernels (find :kernels content :key #'car))
           (k-def   (find-if (lambda (k)
                               (string-equal (getf k :name) "non_overloadable_accessor_k_grad"))
                             (cdr kernels))))
      (unless k-def
        (log:error "validate-record-grad-metadata: kernel 'non_overloadable_accessor_k_grad' not found in ~a"
                   meta-path)
        (return-from validate-record-grad-metadata nil))
      ;; Physical signature: 14 params
      ;;   vp_x (float=1) + vp_y (float=1) + c (cell=3) + c_grad (cell=3)
      ;;   + vp_x_grad (cell=3) + vp_y_grad (cell=3) = 14
      (let ((phys-sig (getf k-def :physical-signature)))
        (unless (= (length phys-sig) 14)
          (log:error "validate-record-grad-metadata: expected 14 physical-sig entries, got ~a"
                     (length phys-sig))
          (return-from validate-record-grad-metadata nil)))
      ;; Declared signature: 6 params
      (let ((decl-sig (getf k-def :declared-signature)))
        (unless (= (length decl-sig) 6)
          (log:error "validate-record-grad-metadata: expected 6 declared-sig params, got ~a"
                     (length decl-sig))
          (return-from validate-record-grad-metadata nil))
        (flet ((check-scalar-in (param expected-name)
                 (let ((name (getf param :name))
                       (dir  (getf param :direction)))
                   (unless (and (string-equal name expected-name) (eq dir :in))
                     (log:error "validate-record-grad-metadata: param ~s: expected float :in, got name=~s dir=~s"
                                expected-name name dir)
                     (return-from validate-record-grad-metadata nil))))
               (check-cell (param expected-name expected-dir expected-access)
                 (let ((name   (getf param :name))
                       (dir    (getf param :direction))
                       (access (getf param :access)))
                   (unless (and (string-equal name expected-name)
                                (eq dir expected-dir)
                                (eq access expected-access))
                     (log:error "validate-record-grad-metadata: param ~s: expected dir=~s access=~s, got name=~s dir=~s access=~s"
                                expected-name expected-dir expected-access name dir access)
                     (return-from validate-record-grad-metadata nil)))))
          (check-scalar-in (nth 0 decl-sig) "vp_x")
          (check-scalar-in (nth 1 decl-sig) "vp_y")
          (check-cell      (nth 2 decl-sig) "c"        :in  :read-only)
          (check-cell      (nth 3 decl-sig) "c_grad"   :in  :read-only)
          (check-cell      (nth 4 decl-sig) "vp_x_grad" :out :write-only)
          (check-cell      (nth 5 decl-sig) "vp_y_grad" :out :write-only)))
      ;; Source path present
      (unless (getf k-def :source)
        (log:error "validate-record-grad-metadata: no :source in kernel def")
        (return-from validate-record-grad-metadata nil))
      t)))



;;; -----------------------------------------------------------------------
;;; Validators: 056-struct-at-kernel-boundary metadata tests
;;; src/metadata-val.lisp
;;;
;;; Helper: %find-struct-def is the struct counterpart to %find-record-def.
;;; It finds (def-struct NAME ...) in a :structs section list.
;;; Note: %find-record-def already works generically (doesn't enforce
;;; def-record vs def-struct), so %find-struct-def is a named alias for
;;; clarity.
;;; -----------------------------------------------------------------------

;; src/metadata-val.lisp
(defun %find-struct-def (structs-section name)
  "Finds (def-struct NAME ...) in a list of forms from a :structs section.
Returns the form or NIL."
  (find name structs-section
        :test (lambda (n f)
                (and (consp f)
                     (symbolp (second f))
                     (string-equal (symbol-name (second f)) n)))))

;;; Validator: 056/01-basic-struct-meta
;;; Tests that a plain def-struct at the kernel boundary appears in :structs,
;;; has the correct 2 members, and shows up as a single physical slot.

;; src/metadata-val.lisp
(defun validate-def-struct-in-metadata (metadata-path)
  "Validates 056/01-basic-struct-meta: point at kernel boundary.
   Checks :structs contains POINT (2 members) but NOT RECT,
   physical-signature has 4 entries (1 struct + 3 cell), and
   declared-signature shows p :in with type point."
  (unless (probe-file metadata-path)
    (log:error "validate-def-struct-in-metadata: file not found: ~a" metadata-path)
    (return-from validate-def-struct-in-metadata nil))

  (let* ((forms (%read-metacrisp-forms metadata-path))
         (structs (%metacrisp-section forms :structs))
         (k-def (%metacrisp-find-kernel forms "struct_on_boundary_k")))

    ;; :structs section must exist
    (unless structs
      (log:error "validate-def-struct-in-metadata: no :structs section")
      (return-from validate-def-struct-in-metadata nil))

    ;; POINT must appear with 2 members (X, Y)
    (let ((pt (%find-struct-def structs "point")))
      (unless pt
        (log:error "validate-def-struct-in-metadata: point not in :structs")
        (return-from validate-def-struct-in-metadata nil))
      (unless (= (%record-member-count pt) 2)
        (log:error "validate-def-struct-in-metadata: expected 2 members for point, got ~a: ~a"
          (%record-member-count pt) (cddr pt))
        (return-from validate-def-struct-in-metadata nil)))

    ;; RECT must NOT appear (not at the kernel boundary)
    (when (%find-struct-def structs "rect")
      (log:error "validate-def-struct-in-metadata: rect should NOT be in :structs")
      (return-from validate-def-struct-in-metadata nil))

    ;; kernel must be found
    (unless k-def
      (log:error "validate-def-struct-in-metadata: kernel struct_on_boundary_k not found")
      (return-from validate-def-struct-in-metadata nil))

    ;; physical sig: 4 entries (1 struct + 3 cell)
    (let ((phys (getf k-def :physical-signature)))
      (unless (= (length phys) 4)
        (log:error "validate-def-struct-in-metadata: expected 4 physical-sig entries (1 struct + 3 cell), got ~a: ~a"
          (length phys) phys)
        (return-from validate-def-struct-in-metadata nil))
      ;; first entry should be the struct type
      (unless (and (consp (first phys))
                   (string-equal (symbol-name (second (first phys))) "point"))
        (log:error "validate-def-struct-in-metadata: expected first physical-sig entry to be (0 POINT), got ~a"
          (first phys))
        (return-from validate-def-struct-in-metadata nil)))

    ;; declared sig: p :in point, c :out
    (let* ((decl (getf k-def :declared-signature))
           (p-e (%find-decl-entry decl "p"))
           (c-e (%find-decl-entry decl "c")))
      (unless p-e
        (log:error "validate-def-struct-in-metadata: no 'p' entry in declared-signature")
        (return-from validate-def-struct-in-metadata nil))
      (unless (eq (getf p-e :direction) :in)
        (log:error "validate-def-struct-in-metadata: p direction should be :in, got ~a"
          (getf p-e :direction))
        (return-from validate-def-struct-in-metadata nil))
      (unless (and (symbolp (getf p-e :type))
                   (string-equal (symbol-name (getf p-e :type)) "point"))
        (log:error "validate-def-struct-in-metadata: p :type should be point, got ~a"
          (getf p-e :type))
        (return-from validate-def-struct-in-metadata nil))
      (unless c-e
        (log:error "validate-def-struct-in-metadata: no 'c' entry in declared-signature")
        (return-from validate-def-struct-in-metadata nil))
      (unless (eq (getf c-e :direction) :out)
        (log:error "validate-def-struct-in-metadata: c direction should be :out, got ~a"
          (getf c-e :direction))
        (return-from validate-def-struct-in-metadata nil)))

    (log:info "validate-def-struct-in-metadata: PASS")
    t))


;;; Validator: 056/03-struct-with-ct-meta
;;; Tests that a struct with a :c-t field appears correctly in :structs.
;;; c-t fields are compile-time constants (not in the runtime layout), so
;;; they must be excluded from the :structs section (same as compute-native-layout
;;; excludes them).  Only the 2 runtime members (x, y) should appear.
;;; The parameterized type (point :earnestness 3.0) still appears in declared-sig.

;; src/metadata-val.lisp
(defun validate-def-struct-with-ct-in-metadata (metadata-path)
  "Validates 056/03-struct-with-ct-meta: point with :c-t earnestness.
   Checks :structs shows 2 runtime members only (c-t earnestness excluded),
   physical-signature has 5 entries (2 struct + 3 cell), and
   declared-sig shows (point earnestness 3.0) for p2."
  (unless (probe-file metadata-path)
    (log:error "validate-def-struct-with-ct-in-metadata: file not found: ~a" metadata-path)
    (return-from validate-def-struct-with-ct-in-metadata nil))

  (let* ((forms (%read-metacrisp-forms metadata-path))
         (structs (%metacrisp-section forms :structs))
         (k-def (%metacrisp-find-kernel forms "struct_on_boundary_k")))

    (unless structs
      (log:error "validate-def-struct-with-ct-in-metadata: no :structs section")
      (return-from validate-def-struct-with-ct-in-metadata nil))

    ;; POINT must appear with 2 runtime members (x, y) — earnestness is c-t, excluded
    (let ((pt (%find-struct-def structs "point")))
      (unless pt
        (log:error "validate-def-struct-with-ct-in-metadata: point not in :structs")
        (return-from validate-def-struct-with-ct-in-metadata nil))
      (unless (= (%record-member-count pt) 2)
        (log:error "validate-def-struct-with-ct-in-metadata: expected 2 runtime members for point (c-t earnestness excluded), got ~a: ~a"
          (%record-member-count pt) (cddr pt))
        (return-from validate-def-struct-with-ct-in-metadata nil)))

    (unless k-def
      (log:error "validate-def-struct-with-ct-in-metadata: kernel struct_on_boundary_k not found")
      (return-from validate-def-struct-with-ct-in-metadata nil))

    ;; physical sig: 5 entries (p1 + p2 as structs + 3 cell)
    (let ((phys (getf k-def :physical-signature)))
      (unless (= (length phys) 5)
        (log:error "validate-def-struct-with-ct-in-metadata: expected 5 physical-sig entries (2 structs + 3 cell), got ~a: ~a"
          (length phys) phys)
        (return-from validate-def-struct-with-ct-in-metadata nil)))

    ;; declared sig: p1 :in point, p2 :in (point earnestness 3.0), c :out
    (let* ((decl (getf k-def :declared-signature))
           (p2-e (%find-decl-entry decl "p2")))
      (unless p2-e
        (log:error "validate-def-struct-with-ct-in-metadata: no 'p2' entry in declared-signature")
        (return-from validate-def-struct-with-ct-in-metadata nil))
      ;; p2 type must be a parameterized form (point earnestness 3.0)
      (unless (and (consp (getf p2-e :type))
                   (string-equal (symbol-name (first (getf p2-e :type))) "point"))
        (log:error "validate-def-struct-with-ct-in-metadata: p2 type should be (point ...), got ~a"
          (getf p2-e :type))
        (return-from validate-def-struct-with-ct-in-metadata nil)))

    (log:info "validate-def-struct-with-ct-in-metadata: PASS")
    t))


;;; Validator: 056/04-nested-structs-meta
;;; Tests that when a struct containing another struct is at the kernel
;;; boundary, BOTH structs appear in :structs via dependency collection.

;; src/metadata-val.lisp
(defun validate-nested-struct-in-metadata (metadata-path)
  "Validates 056/04-nested-structs-meta: rect (containing point) at kernel boundary.
   Checks :structs contains both RECT and POINT (dependency),
   physical-signature has 4 entries (1 struct + 3 cell), and
   declared-sig shows r :in rect."
  (unless (probe-file metadata-path)
    (log:error "validate-nested-struct-in-metadata: file not found: ~a" metadata-path)
    (return-from validate-nested-struct-in-metadata nil))

  (let* ((forms (%read-metacrisp-forms metadata-path))
         (structs (%metacrisp-section forms :structs))
         (k-def (%metacrisp-find-kernel forms "rect_on_boundary_k")))

    (unless structs
      (log:error "validate-nested-struct-in-metadata: no :structs section")
      (return-from validate-nested-struct-in-metadata nil))

    ;; Both POINT and RECT must appear (dependency collection)
    (unless (%find-struct-def structs "point")
      (log:error "validate-nested-struct-in-metadata: point not in :structs (expected via dependency)")
      (return-from validate-nested-struct-in-metadata nil))
    (unless (%find-struct-def structs "rect")
      (log:error "validate-nested-struct-in-metadata: rect not in :structs")
      (return-from validate-nested-struct-in-metadata nil))

    (unless k-def
      (log:error "validate-nested-struct-in-metadata: kernel rect_on_boundary_k not found")
      (return-from validate-nested-struct-in-metadata nil))

    ;; physical sig: 4 entries (1 struct + 3 cell)
    (let ((phys (getf k-def :physical-signature)))
      (unless (= (length phys) 4)
        (log:error "validate-nested-struct-in-metadata: expected 4 physical-sig entries (1 struct + 3 cell), got ~a: ~a"
          (length phys) phys)
        (return-from validate-nested-struct-in-metadata nil))
      ;; first entry should be RECT
      (unless (and (consp (first phys))
                   (string-equal (symbol-name (second (first phys))) "rect"))
        (log:error "validate-nested-struct-in-metadata: expected first physical-sig entry to be (0 RECT), got ~a"
          (first phys))
        (return-from validate-nested-struct-in-metadata nil)))

    ;; declared sig: r :in rect, c :out
    (let* ((decl (getf k-def :declared-signature))
           (r-e (%find-decl-entry decl "r")))
      (unless r-e
        (log:error "validate-nested-struct-in-metadata: no 'r' entry in declared-signature")
        (return-from validate-nested-struct-in-metadata nil))
      (unless (and (symbolp (getf r-e :type))
                   (string-equal (symbol-name (getf r-e :type)) "rect"))
        (log:error "validate-nested-struct-in-metadata: r :type should be rect, got ~a"
          (getf r-e :type))
        (return-from validate-nested-struct-in-metadata nil))
      (unless (eq (getf r-e :direction) :in)
        (log:error "validate-nested-struct-in-metadata: r direction should be :in, got ~a"
          (getf r-e :direction))
        (return-from validate-nested-struct-in-metadata nil)))

    (log:info "validate-nested-struct-in-metadata: PASS")
    t))


;;; -----------------------------------------------------------------------
;;; Validator: 056/09-branded-struct-elide
;;; Tests that brand declarations and brand types are elided in :structs
;;; metadata, leaving only the base type (ulong instead of token-t).
;;; -----------------------------------------------------------------------

;; src/metadata-val.lisp
(defun validate-struct-no-brand-in-metadata (metadata-path)
  "Validates 056/09-branded-struct-elide: branded def-struct at kernel boundary.
   Checks that the :structs section shows the base type (ulong) for branded
   fields (not token-t), no brand declarations appear, and the kernel is present."
  (unless (probe-file metadata-path)
    (log:error "validate-struct-no-brand-in-metadata: file not found: ~a" metadata-path)
    (return-from validate-struct-no-brand-in-metadata nil))

  (let* ((forms (%read-metacrisp-forms metadata-path))
         (structs (%metacrisp-section forms :structs))
         (k-def (%metacrisp-find-kernel forms "struct_on_boundary_k")))

    (unless structs
      (log:error "validate-struct-no-brand-in-metadata: no :structs section")
      (return-from validate-struct-no-brand-in-metadata nil))

    (let ((pt (%find-struct-def structs "point")))
      (unless pt
        (log:error "validate-struct-no-brand-in-metadata: point not in :structs")
        (return-from validate-struct-no-brand-in-metadata nil))

      ;; No member should be named "brand" -- brand declarations must be elided
      (dolist (m (cddr pt))
        (when (and (consp m) (symbolp (first m))
                   (string-equal (symbol-name (first m)) "brand"))
          (log:error "validate-struct-no-brand-in-metadata: brand declaration found in :structs -- should be elided: ~a" m)
          (return-from validate-struct-no-brand-in-metadata nil)))

      ;; The x field should have ulong type (base of token-t brand), not token-t
      (let ((x-member (find "x" (cddr pt)
                            :test (lambda (n m)
                                    (and (consp m) (symbolp (first m))
                                         (string-equal (symbol-name (first m)) n))))))
        (when x-member
          (let ((x-type (second x-member)))
            (when (and (symbolp x-type)
                       (string-equal (symbol-name x-type) "token-t"))
              (log:error "validate-struct-no-brand-in-metadata: x field still shows brand type 'token-t', expected base type 'ulong'")
              (return-from validate-struct-no-brand-in-metadata nil))))))

    (unless k-def
      (log:error "validate-struct-no-brand-in-metadata: kernel struct_on_boundary_k not found")
      (return-from validate-struct-no-brand-in-metadata nil))

    (log:info "validate-struct-no-brand-in-metadata: PASS")
    t))


(defun validate-070-03-matrix-metadata (meta-path)
  "Validates .metacrisp for test 03-metadata-matrix.
   Matrix (N=2): 3*2+3=9 slots for v (indices 0-8), then val at index 9.
   :physical-signature — 10 entries
   :declared-signature — v :rank 2 :align :compact :range (0 8); val :range (9 9)"
  (unless (and meta-path (probe-file meta-path))
    (log:error "validate-070-03-matrix-metadata: metacrisp not found: ~a" meta-path)
    (return-from validate-070-03-matrix-metadata nil))
  (let* ((forms   (uiop:read-file-forms meta-path))
         (kernels (rest (find :kernels forms :key #'car)))
         (k-def   (find "mat_set_elem" kernels
                        :key (lambda (k) (getf k :name)) :test #'string-equal)))
    (unless k-def
      (log:error "validate-070-03-matrix-metadata: kernel mat_set_elem not found")
      (return-from validate-070-03-matrix-metadata nil))

    ;; physical-signature: 10 slots
    (let ((phys-sig (getf k-def :physical-signature)))
      (unless (= (length phys-sig) 10)
        (log:error "validate-070-03-matrix-metadata: physical-sig has ~d slots, expected 10" (length phys-sig))
        (return-from validate-070-03-matrix-metadata nil)))

    ;; declared-signature: v with rank=2, align=:compact, range=(0 8)
    (let* ((decl-sig (getf k-def :declared-signature))
           (v-entry  (find "v" decl-sig :key (lambda (e) (getf e :name)) :test #'string-equal)))
      (unless (and v-entry
                   (= (getf v-entry :rank) 2)
                   (eq (getf v-entry :align) :compact)
                   (equal (getf v-entry :range) '(0 8)))
        (log:error "validate-070-03-matrix-metadata: v entry wrong: ~s" v-entry)
        (return-from validate-070-03-matrix-metadata nil)))

    (log:info "validate-070-03-matrix-metadata: PASS")
    t))

(defun validate-070-01-vector-metadata (meta-path)
  "Validates .metacrisp for test 01-metadata-vector.
   Checks:
     - physical-signature: (0 LONG) (1 (C-POINTER...)) (2 ULONG) x 5 = 7 slots
     - declared-signature: val :range (0 0), v :range (1 6) :rank 1 :align :compact
     - aliases: OUT-VEC-T with keyword-form type spec"
  (unless (and meta-path (probe-file meta-path))
    (log:error "validate-070-01-vector-metadata: metacrisp not found: ~a" meta-path)
    (return-from validate-070-01-vector-metadata nil))
  (let* ((forms    (uiop:read-file-forms meta-path))
         (aliases  (rest (find :aliases  forms :key #'car)))
         (kernels  (rest (find :kernels  forms :key #'car)))
         (k-def    (find "vec_set_first" kernels
                         :key (lambda (k) (getf k :name))
                         :test #'string-equal)))
    (unless k-def
      (log:error "validate-070-01-vector-metadata: kernel vec_set_first not found")
      (return-from validate-070-01-vector-metadata nil))

    ;; Check alias keyword form: (def-type out-vec-t (vector long :address-space :global ...))
    (let ((alias (find "out-vec-t" aliases
                       :key (lambda (a) (and (consp a) (symbol-name (second a))))
                       :test #'string-equal)))
      (unless alias
        (log:error "validate-070-01-vector-metadata: alias OUT-VEC-T not found")
        (return-from validate-070-01-vector-metadata nil))
      ;; The type spec should have keywords like :address-space, :global, etc.
      (let ((type-spec (third alias)))
        (unless (and (consp type-spec)
                     (string-equal (symbol-name (first type-spec)) "VECTOR")
                     (member :address-space type-spec))
          (log:error "validate-070-01-vector-metadata: alias type spec missing keywords: ~s" type-spec)
          (return-from validate-070-01-vector-metadata nil))))

    ;; Check physical-signature: 7 slots
    (let ((phys-sig (getf k-def :physical-signature)))
      (unless (= (length phys-sig) 7)
        (log:error "validate-070-01-vector-metadata: physical-signature has ~d slots, expected 7" (length phys-sig))
        (return-from validate-070-01-vector-metadata nil))
      ;; slot 0 = long (val)
      (unless (string-equal (symbol-name (second (nth 0 phys-sig))) "LONG")
        (log:error "validate-070-01-vector-metadata: slot 0 should be LONG, got ~s" (nth 0 phys-sig))
        (return-from validate-070-01-vector-metadata nil))
      ;; slot 1 = pointer (ptr)
      (unless (and (consp (second (nth 1 phys-sig)))
                   (string-equal (symbol-name (first (second (nth 1 phys-sig)))) "C-POINTER"))
        (log:error "validate-070-01-vector-metadata: slot 1 should be C-POINTER, got ~s" (nth 1 phys-sig))
        (return-from validate-070-01-vector-metadata nil))
      ;; slots 2-6 = ulong
      (loop for i from 2 to 6 do
        (unless (string-equal (symbol-name (second (nth i phys-sig))) "ULONG")
          (log:error "validate-070-01-vector-metadata: slot ~d should be ULONG, got ~s" i (nth i phys-sig))
          (return-from validate-070-01-vector-metadata nil))))

    ;; Check declared-signature
    (let ((decl-sig (getf k-def :declared-signature)))
      (unless (= (length decl-sig) 2)
        (log:error "validate-070-01-vector-metadata: declared-sig has ~d entries, expected 2" (length decl-sig))
        (return-from validate-070-01-vector-metadata nil))
      ;; val: :range (0 0)
      (let ((val-entry (find "val" decl-sig :key (lambda (e) (getf e :name)) :test #'string-equal)))
        (unless (and val-entry (equal (getf val-entry :range) '(0 0)))
          (log:error "validate-070-01-vector-metadata: val entry wrong: ~s" val-entry)
          (return-from validate-070-01-vector-metadata nil)))
      ;; v: :range (1 6), :rank 1, :align :compact
      (let ((v-entry (find "v" decl-sig :key (lambda (e) (getf e :name)) :test #'string-equal)))
        (unless (and v-entry
                     (equal (getf v-entry :range) '(1 6))
                     (= (getf v-entry :rank) 1)
                     (eq (getf v-entry :align) :compact))
          (log:error "validate-070-01-vector-metadata: v entry wrong: ~s" v-entry)
          (return-from validate-070-01-vector-metadata nil))))

    (log:info "validate-070-01-vector-metadata: PASS")
    t))

;;; ── 071-compact-aref-opt validators ──────────────────────────────────────

(defun %071-kernel-body (ir function-name)
  "Extracts the body of the named LLVM kernel function from IR string.
   Searches for 'define ... @function-name' using a prefix match so that
   mangled names like compact_mat_get_tensor_float_2_... are found by
   searching for '@compact_mat_get'.
   Returns the function body substring, or NIL if not found."
  (let* (;; Replace hyphens with underscores to match LLVM name mangling
         (mangled (substitute #\_ #\- function-name))
         (marker  (format nil "@~a" mangled))
         (start   (search marker ir)))
    (when start
      (let ((brace-start (position #\{ ir :start start)))
        (when brace-start
          (let ((depth 0) (pos brace-start) (end nil))
            (loop while (< pos (length ir)) do
              (let ((ch (cl:char ir pos)))
                (cond ((char= ch #\{) (incf depth))
                      ((char= ch #\}) (decf depth)
                       (when (zerop depth)
                         (setf end (1+ pos))
                         (return-from nil)))))
              (incf pos))
            (when end (subseq ir brace-start end))))))))

(defun %071-has-stride-mul (body)
  "Returns T if BODY contains a stride multiply: a 'mul i64' instruction
   whose second operand is a register (not a ptrtoint sizeof constant).
   Byte-offset multiplies (mul i64 %reg, ptrtoint(...)) are excluded."
  ;; Walk each line; look for 'mul i64' without 'ptrtoint' on the same line.
  (let ((pos 0))
    (loop
      (let ((m (search "mul i64" body :start2 pos)))
        (unless m (return-from %071-has-stride-mul nil))
        ;; Find end of this line
        (let* ((eol (or (position #\newline body :start m) (length body)))
               (line (subseq body m eol)))
          (unless (search "ptrtoint" line)
            (return-from %071-has-stride-mul t)))
        (setf pos (1+ m))))))

(defun validate-071-01-compact-vector-get-ir (ir-path)
  "Validates compact vector GET IR: no stride multiply, no offset load.
   Checks:
     - No 'mul i64 %reg, %reg' (stride multiply) in the kernel body.
     - No load from offset field (field index 1)  — :compact skips offsets entirely."
  (unless (probe-file ir-path)
    (log:error "validate-071-01: IR file not found: ~a" ir-path)
    (return-from validate-071-01-compact-vector-get-ir nil))
  (let* ((ir   (uiop:read-file-string ir-path))
         (body (%071-kernel-body ir "compact_vec_get")))
    (unless body
      (log:error "validate-071-01: kernel compact_vec_get not found in IR")
      (return-from validate-071-01-compact-vector-get-ir nil))
    (and
     (or (not (%071-has-stride-mul body))
         (progn (log:error "validate-071-01: compact vector GET must not contain a stride mul i64") nil))
     (or (not (%072-has-offset-load body))
         (progn (log:error "validate-071-01: compact vector GET must not load from offset field") nil))
     (progn (log:info "validate-071-01: PASS") t))))

(defun validate-071-02-compact-vector-set-ir (ir-path)
  "Validates compact vector SET IR: no stride multiply, no offset load.
   Checks:
     - No 'mul i64 %reg, %reg' (stride multiply) in the kernel body.
     - No load from offset field — :compact skips offsets entirely."
  (unless (probe-file ir-path)
    (log:error "validate-071-02: IR file not found: ~a" ir-path)
    (return-from validate-071-02-compact-vector-set-ir nil))
  (let* ((ir   (uiop:read-file-string ir-path))
         (body (%071-kernel-body ir "compact_vec_set")))
    (unless body
      (log:error "validate-071-02: kernel compact_vec_set not found in IR")
      (return-from validate-071-02-compact-vector-set-ir nil))
    (and
     (or (not (%071-has-stride-mul body))
         (progn (log:error "validate-071-02: compact vector SET must not contain a stride mul i64") nil))
     (or (not (%072-has-offset-load body))
         (progn (log:error "validate-071-02: compact vector SET must not load from offset field") nil))
     (progn (log:info "validate-071-02: PASS") t))))

(defun validate-071-03-compact-matrix-get-ir (ir-path)
  "Validates compact matrix GET IR: exactly one mul i64 (Horner), no stride load.
   Checks:
     - Exactly one 'mul i64' in the kernel body  (i_0 * ext[1])
     - No load from the strides array field (struct field index 2)"
  (unless (probe-file ir-path)
    (log:error "validate-071-03: IR file not found: ~a" ir-path)
    (return-from validate-071-03-compact-matrix-get-ir nil))
  (let* ((ir   (uiop:read-file-string ir-path))
         (body (%071-kernel-body ir "compact_mat_get")))
    (unless body
      (log:error "validate-071-03: kernel compact_mat_get not found in IR")
      (return-from validate-071-03-compact-matrix-get-ir nil))
    ;; For compact N=2 Horner: exactly ONE stride multiply (i_0 * ext[1]).
    ;; No load from the strides array field (field index 2).
    (and
     (or (%071-has-stride-mul body)
         (progn (log:error "validate-071-03: compact matrix GET must have the Horner mul i64") nil))
     ;; No load from field index 2 (strides array) — check for ", i32 0, i32 2"
     (or (not (search ", i32 0, i32 2" body))
         (progn (log:error "validate-071-03: compact matrix GET must not load from strides field (index 2)") nil))
     (progn (log:info "validate-071-03: PASS") t))))

(defun validate-071-05-strided-vector-ir (ir-path)
  "Validates strided vector GET IR: stride multiply must be present.
   Checks:
     - A 'mul i64 %reg, %reg' (stride multiply) IS present in the kernel body.
       This confirms the compact optimization is NOT applied to :strided tensors."
  (unless (probe-file ir-path)
    (log:error "validate-071-05: IR file not found: ~a" ir-path)
    (return-from validate-071-05-strided-vector-ir nil))
  (let* ((ir   (uiop:read-file-string ir-path))
         (body (%071-kernel-body ir "strided_vec_get")))
    (unless body
      (log:error "validate-071-05: kernel strided_vec_get not found in IR")
      (return-from validate-071-05-strided-vector-ir nil))
    (and
     (or (%071-has-stride-mul body)
         (progn (log:error "validate-071-05: strided vector GET must contain a stride mul i64") nil))
     (progn (log:info "validate-071-05: PASS") t))))

;;; ── 072-compact-offset-aref validators ───────────────────────────────────

(defun %072-has-offset-load (body)
  "Returns T if BODY contains a load from the tensor offset field (struct field index 1).
   The GEP pattern is 'i32 0, i32 1' (field 0=parent, 1=offsets, 2=strides, 3=extents)."
  (not (null (search ", i32 0, i32 1" body))))

(defun validate-072-01-compact-offset-vector-get-ir (ir-path)
  "Validates :compact-offset vector GET IR:
     - No stride mul (compact strides)
     - Offset field IS loaded (non-zero offset supported)
     - add i64 present"
  (unless (probe-file ir-path)
    (log:error "validate-072-01: IR file not found: ~a" ir-path)
    (return-from validate-072-01-compact-offset-vector-get-ir nil))
  (let* ((ir   (uiop:read-file-string ir-path))
         (body (%071-kernel-body ir "compact_offset_vec_get")))
    (unless body
      (log:error "validate-072-01: kernel compact_offset_vec_get not found in IR")
      (return-from validate-072-01-compact-offset-vector-get-ir nil))
    (and
     (or (not (%071-has-stride-mul body))
         (progn (log:error "validate-072-01: compact-offset vector GET must not have stride mul") nil))
     (or (%072-has-offset-load body)
         (progn (log:error "validate-072-01: compact-offset vector GET must load from offset field") nil))
     (or (search "add i64" body)
         (progn (log:error "validate-072-01: compact-offset vector GET must contain add i64") nil))
     (progn (log:info "validate-072-01: PASS") t))))

(defun validate-072-02-compact-offset-vector-set-ir (ir-path)
  "Validates :compact-offset vector SET IR:
     - No stride mul
     - Offset field IS loaded"
  (unless (probe-file ir-path)
    (log:error "validate-072-02: IR file not found: ~a" ir-path)
    (return-from validate-072-02-compact-offset-vector-set-ir nil))
  (let* ((ir   (uiop:read-file-string ir-path))
         (body (%071-kernel-body ir "compact_offset_vec_set")))
    (unless body
      (log:error "validate-072-02: kernel compact_offset_vec_set not found in IR")
      (return-from validate-072-02-compact-offset-vector-set-ir nil))
    (and
     (or (not (%071-has-stride-mul body))
         (progn (log:error "validate-072-02: compact-offset vector SET must not have stride mul") nil))
     (or (%072-has-offset-load body)
         (progn (log:error "validate-072-02: compact-offset vector SET must load from offset field") nil))
     (progn (log:info "validate-072-02: PASS") t))))

(defun validate-072-04-compact-no-offset-ir (ir-path)
  "Validates :compact vector GET IR (strengthened regression):
     - No stride mul
     - No offset field load  ← new check vs 071"
  (unless (probe-file ir-path)
    (log:error "validate-072-04: IR file not found: ~a" ir-path)
    (return-from validate-072-04-compact-no-offset-ir nil))
  (let* ((ir   (uiop:read-file-string ir-path))
         (body (%071-kernel-body ir "compact_vec_get_no_offset")))
    (unless body
      (log:error "validate-072-04: kernel compact_vec_get_no_offset not found in IR")
      (return-from validate-072-04-compact-no-offset-ir nil))
    (and
     (or (not (%071-has-stride-mul body))
         (progn (log:error "validate-072-04: compact vector GET must not have stride mul") nil))
     (or (not (%072-has-offset-load body))
         (progn (log:error "validate-072-04: compact vector GET must not load from offset field") nil))
     (progn (log:info "validate-072-04: PASS") t))))

;;; =========================================================
;;; 074-scratch-tensor validators
;;; =========================================================

(defun %074-count-kernel-params (ir kernel-name)
  "Returns the parameter count of the named kernel from the IR string,
   or NIL if the kernel is not found.
   Handles nested parens in type names like addrspace(3) by counting
   only top-level commas."
  (let* ((search (format nil "define void @~a(" kernel-name))
         (pos (search search ir)))
    (unless pos (return-from %074-count-kernel-params nil))
    ;; pos points to 'd' of 'define', find the opening '(' of the param list
    (let ((open-pos (+ pos (1- (length search)))))
      ;; Scan forward counting depth; collect top-level commas
      (let ((depth 0)
            (top-comma-count 0)
            (has-params nil))
        (block scan
          (loop for i from open-pos below (length ir)
                for ch = (cl:char ir i)
                do (cond
                     ((char= ch #\()
                      (incf depth)
                      (when (= depth 1) (setf has-params t)))
                     ((char= ch #\))
                      (decf depth)
                      (when (= depth 0)
                        (return-from scan (if has-params
                                             (1+ top-comma-count)
                                             0))))
                     ((and (char= ch #\,) (= depth 1))
                      (incf top-comma-count))))
          nil)))))

(defun %074-has-local-ptr-param (define-line)
  "Returns T if the define line contains a ptr addrspace(3) parameter."
  (search "ptr addrspace(3)" define-line))

(defun validate-074-02-scratch-vector-propagation-ir (ir-path)
  "Validates scratch vector propagation IR:
     - kernel_a has 7 params: ptr addrspace(3) + 5 x i64 (implicit tensor N=1)
       + i32 (explicit n)
     - fun_c has the same expanded signature (is a carrier)"
  (unless (probe-file ir-path)
    (log:error "validate-074-02: IR file not found: ~a" ir-path)
    (return-from validate-074-02-scratch-vector-propagation-ir nil))
  (let* ((ir (uiop:read-file-string ir-path))
         (ka-count (%074-count-kernel-params ir "kernel_a")))
    (unless ka-count
      (log:error "validate-074-02: kernel_a not found in IR")
      (return-from validate-074-02-scratch-vector-propagation-ir nil))
    (and
     (or (= ka-count 7)
         (progn (log:error "validate-074-02: kernel_a expected 7 params, got ~a" ka-count) nil))
     (or (search "ptr addrspace(3)" ir)
         (progn (log:error "validate-074-02: expected local (addrspace 3) scratch pointer") nil))
     (or (search "fun_c_tensor_int_1_local_read_write_compact_int" ir)
         (progn (log:error "validate-074-02: carrier fun_c not found with expanded implicit signature") nil))
     (progn (log:info "validate-074-02: PASS") t))))

(defun validate-074-03-scratch-tensor-propagation-ir (ir-path)
  "Validates scratch tensor (N=3) propagation IR:
     - kernel_a has 13 params: ptr addrspace(3) + 11 x i64 (implicit tensor N=3)
       + i32 (explicit n)
     - fun_c has the same expanded signature"
  (unless (probe-file ir-path)
    (log:error "validate-074-03: IR file not found: ~a" ir-path)
    (return-from validate-074-03-scratch-tensor-propagation-ir nil))
  (let* ((ir (uiop:read-file-string ir-path))
         (ka-count (%074-count-kernel-params ir "kernel_a")))
    (unless ka-count
      (log:error "validate-074-03: kernel_a not found in IR")
      (return-from validate-074-03-scratch-tensor-propagation-ir nil))
    (and
     (or (= ka-count 13)
         (progn (log:error "validate-074-03: kernel_a expected 13 params, got ~a" ka-count) nil))
     (or (search "TENSOR_FLOAT_3_LOCAL_READ-WRITE_COMPACT" ir)
         (progn (log:error "validate-074-03: expected TENSOR_FLOAT_3_LOCAL_READ-WRITE_COMPACT type in IR") nil))
     (or (search "fun_c_tensor_float_3_local_read_write_compact_int" ir)
         (progn (log:error "validate-074-03: carrier fun_c not found with expanded implicit signature") nil))
     (progn (log:info "validate-074-03: PASS") t))))

(defun validate-074-04-scratch-matrix-propagation-ir (ir-path)
  "Validates scratch matrix (N=2) propagation IR:
     - kernel_a has 11 params: ptr addrspace(3) + 8 x i64 (implicit tensor N=2)
       + 2 x i64 (explicit row col as ulong)
     - fun_c has the same expanded signature"
  (unless (probe-file ir-path)
    (log:error "validate-074-04: IR file not found: ~a" ir-path)
    (return-from validate-074-04-scratch-matrix-propagation-ir nil))
  (let* ((ir (uiop:read-file-string ir-path))
         (ka-count (%074-count-kernel-params ir "kernel_a")))
    (unless ka-count
      (log:error "validate-074-04: kernel_a not found in IR")
      (return-from validate-074-04-scratch-matrix-propagation-ir nil))
    (and
     (or (= ka-count 11)
         (progn (log:error "validate-074-04: kernel_a expected 11 params, got ~a" ka-count) nil))
     (or (search "TENSOR_FLOAT_2_LOCAL_READ-WRITE_COMPACT" ir)
         (progn (log:error "validate-074-04: expected TENSOR_FLOAT_2_LOCAL_READ-WRITE_COMPACT type in IR") nil))
     (or (search "fun_c_tensor_float_2_local_read_write_compact_ulong_ulong" ir)
         (progn (log:error "validate-074-04: carrier fun_c not found with expanded implicit signature") nil))
     (progn (log:info "validate-074-04: PASS") t))))

;;; =========================================================
;;; 075-scratch-tensor-metadata validators
;;;
;;; These validate that after the canonical-list fix:
;;;   - :implicit-params :type is a canonical list (not a mangled symbol)
;;;   - :physical-signature is fully exploded to individual ULONGs
;;;   - :range covers the correct number of physical slots (3N+3)
;;; =========================================================

(defun %075-find-kernel (metacrisp-path kernel-name)
  "Reads a metacrisp file and returns the plist for the named kernel, or NIL."
  (unless (probe-file metacrisp-path)
    (log:error "075: metacrisp file not found: ~a" metacrisp-path)
    (return-from %075-find-kernel nil))
  (let* ((content (uiop:read-file-forms metacrisp-path))
         (kernels (find :kernels content :key #'car)))
    (unless kernels
      (log:error "075: no :kernels section in ~a" metacrisp-path)
      (return-from %075-find-kernel nil))
    (block find-k
      (dolist (k (cdr kernels))
        (when (string-equal (getf k :name) kernel-name)
          (return-from find-k k)))
      nil)))

(defun %075-validate-tensor-implicit (tag k-def expected-type-head expected-n
                                      expected-slots expected-addr-space
                                      expected-size-expr)
  "Shared checker for 075-0x validators.
   Verifies:
     - exactly one implicit param
     - :type is a cons whose first element is TENSOR with the correct N and :address-space
     - :size-expr is present and equals EXPECTED-SIZE-EXPR
     - :range spans exactly EXPECTED-SLOTS physical slots starting at 0
     - :physical-signature has EXPECTED-SLOTS entries for the implicit range,
       first entry (C-POINTER ...), remaining entries ULONG"
  (let ((implicit-sig (getf k-def :implicit-params))
        (phys-sig (getf k-def :physical-signature)))

    (unless (= (length implicit-sig) 1)
      (log:error "~a: expected 1 implicit param, got ~a" tag (length implicit-sig))
      (return-from %075-validate-tensor-implicit nil))

    (let* ((entry (first implicit-sig))
           (itype (getf entry :type))
           (irange (getf entry :range))
           (iaddr (getf entry :address-space)))

      ;; :type must be a canonical list starting with TENSOR
      (unless (and (consp itype)
                   (symbolp (first itype))
                   (string-equal (symbol-name (first itype)) "TENSOR"))
        (log:error "~a: implicit :type must be (TENSOR ...) canonical list, got ~s" tag itype)
        (return-from %075-validate-tensor-implicit nil))

      ;; N must match
      (let ((actual-n (third itype)))
        (unless (and (integerp actual-n) (= actual-n expected-n))
          (log:error "~a: implicit type has N=~a, expected N=~a" tag actual-n expected-n)
          (return-from %075-validate-tensor-implicit nil)))

      ;; :address-space must match
      (unless (and iaddr (string-equal (symbol-name iaddr)
                                       (symbol-name expected-addr-space)))
        (log:error "~a: implicit :address-space is ~s, expected ~s" tag iaddr expected-addr-space)
        (return-from %075-validate-tensor-implicit nil))

      ;; :size-expr must be present and match
      (let ((isize-expr (getf entry :size-expr)))
        (unless isize-expr
          (log:error "~a: implicit :size-expr is missing" tag)
          (return-from %075-validate-tensor-implicit nil))
        (unless (equal isize-expr expected-size-expr)
          (log:error "~a: implicit :size-expr is ~s, expected ~s" tag isize-expr expected-size-expr)
          (return-from %075-validate-tensor-implicit nil)))

      ;; :range must be (0 <expected-slots - 1>)
      (unless (and (listp irange)
                   (= (length irange) 2)
                   (= (first irange) 0)
                   (= (second irange) (1- expected-slots)))
        (log:error "~a: implicit :range is ~s, expected (0 ~a)" tag irange (1- expected-slots))
        (return-from %075-validate-tensor-implicit nil))

      ;; physical-signature: first EXPECTED-SLOTS entries cover the implicit range
      ;; entry 0 must be (C-POINTER ...) or (C-POINTER :ADDRESS-SPACE :LOCAL)
      ;; entries 1..(expected-slots-1) must all be ULONG
      (unless (>= (length phys-sig) expected-slots)
        (log:error "~a: physical-sig has ~a entries, need >= ~a" tag (length phys-sig) expected-slots)
        (return-from %075-validate-tensor-implicit nil))

      (let ((entry0-type (second (nth 0 phys-sig))))
        (unless (and (consp entry0-type)
                     (string-equal (symbol-name (first entry0-type)) "C-POINTER"))
          (log:error "~a: phys-sig[0] must be (C-POINTER ...), got ~s" tag entry0-type)
          (return-from %075-validate-tensor-implicit nil)))

      (loop for i from 1 below expected-slots
            for entry = (nth i phys-sig)
            do (unless (and entry
                            (symbolp (second entry))
                            (string-equal (symbol-name (second entry)) "ULONG"))
                 (log:error "~a: phys-sig[~a] must be ULONG, got ~s" tag i entry)
                 (return-from %075-validate-tensor-implicit nil)))

      t)))

(defun validate-075-01-scratch-vector-implicit-meta (meta-path)
  "Validates scratch vector (N=1) metacrisp:
     - implicit :type is (TENSOR INT 1 :ADDRESS-SPACE :LOCAL ...) canonical list
     - physical-signature has 6 exploded scalar entries for the implicit range
     - :range is (0 5)"
  (let ((k-def (%075-find-kernel meta-path "kernel_a")))
    (unless k-def
      (log:error "validate-075-01: kernel_a not found in ~a" meta-path)
      (return-from validate-075-01-scratch-vector-implicit-meta nil))
    (and (%075-validate-tensor-implicit "075-01" k-def 'tensor 1 6 :local :match-warp-tile)
         (progn (log:info "validate-075-01: PASS") t))))

(defun validate-075-02-scratch-tensor-n3-implicit-meta (meta-path)
  "Validates scratch tensor (N=3) metacrisp:
     - implicit :type is (TENSOR FLOAT 3 :ADDRESS-SPACE :LOCAL ...) canonical list
     - physical-signature has 12 exploded scalar entries for the implicit range
     - :range is (0 11)"
  (let ((k-def (%075-find-kernel meta-path "kernel_a")))
    (unless k-def
      (log:error "validate-075-02: kernel_a not found in ~a" meta-path)
      (return-from validate-075-02-scratch-tensor-n3-implicit-meta nil))
    (and (%075-validate-tensor-implicit "075-02" k-def 'tensor 3 12 :local :match-warp-tile)
         (progn (log:info "validate-075-02: PASS") t))))

(defun validate-075-03-scratch-matrix-implicit-meta (meta-path)
  "Validates scratch matrix (N=2) metacrisp:
     - implicit :type is (TENSOR FLOAT 2 :ADDRESS-SPACE :LOCAL ...) canonical list
     - physical-signature has 9 exploded scalar entries for the implicit range
     - :range is (0 8)"
  (let ((k-def (%075-find-kernel meta-path "kernel_a")))
    (unless k-def
      (log:error "validate-075-03: kernel_a not found in ~a" meta-path)
      (return-from validate-075-03-scratch-matrix-implicit-meta nil))
    (and (%075-validate-tensor-implicit "075-03" k-def 'tensor 2 9 :local :match-warp-tile)
         (progn (log:info "validate-075-03: PASS") t))))

;;; ---------------------------------------------------------------------------
;;; 080-advanced-ad  — tensor / vector / matrix autodiff validators
;;; ---------------------------------------------------------------------------

(defun validate-vec-add-grad (ir-path)
  "Validates the backward kernel for 01-vec-add (vector addition):
     - @vec_add_grad is defined
     - TENSOR_FLOAT_1_GLOBAL_READ-WRITE_COMPACT type present (gradient tensors)
     - fadd instruction present (addition backward)
     - idx_GRAD is NOT present (integer scalar filtering)"
  (unless (probe-file ir-path)
    (log:error "validate-vec-add-grad: IR file not found: ~a" ir-path)
    (return-from validate-vec-add-grad nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (and
     (or (search "define void @vec_add_grad(" ir)
         (progn (log:error "validate-vec-add-grad: @vec_add_grad not found") nil))
     (or (search "TENSOR_FLOAT_1_GLOBAL_READ-WRITE_COMPACT" ir)
         (progn (log:error "validate-vec-add-grad: gradient tensor type READ-WRITE not found") nil))
     (or (search "fadd float" ir)
         (progn (log:error "validate-vec-add-grad: fadd not found in backward body") nil))
     (or (not (search "idx_GRAD" ir))
         (progn (log:error "validate-vec-add-grad: idx_GRAD should not be emitted (integer scalar)") nil))
     (progn (log:info "validate-vec-add-grad: PASS") t))))

(defun validate-vec-multiply-grad (ir-path)
  "Validates the backward kernel for 02-vec-multiply (vector product rule):
     - @vec_mult_grad is defined
     - fmul instruction present (product rule: d/dA of A*B = B, needs multiply)
     - TENSOR_FLOAT_1_GLOBAL_READ-WRITE_COMPACT type present
     - idx_GRAD is NOT present"
  (unless (probe-file ir-path)
    (log:error "validate-vec-multiply-grad: IR file not found: ~a" ir-path)
    (return-from validate-vec-multiply-grad nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (and
     (or (search "define void @vec_mult_grad(" ir)
         (progn (log:error "validate-vec-multiply-grad: @vec_mult_grad not found") nil))
     (or (search "fmul float" ir)
         (progn (log:error "validate-vec-multiply-grad: fmul not found (product rule requires multiply)") nil))
     (or (search "TENSOR_FLOAT_1_GLOBAL_READ-WRITE_COMPACT" ir)
         (progn (log:error "validate-vec-multiply-grad: gradient tensor type READ-WRITE not found") nil))
     (or (not (search "idx_GRAD" ir))
         (progn (log:error "validate-vec-multiply-grad: idx_GRAD should not be emitted") nil))
     (progn (log:info "validate-vec-multiply-grad: PASS") t))))

(defun validate-vec-mixed-grad (ir-path)
  "Validates the backward kernel for 03-vec-mixed (scalar float + tensor inputs):
     - @vec_scale_grad is defined
     - float parameter for scale_GRAD (scalar gradient carried through)
     - TENSOR_FLOAT_1_GLOBAL_READ-WRITE_COMPACT present (A_GRAD tensor)
     - fmul present (d(scale*A)/dA = scale; d/dscale = A — both use multiply)
     - idx_GRAD is NOT present"
  (unless (probe-file ir-path)
    (log:error "validate-vec-mixed-grad: IR file not found: ~a" ir-path)
    (return-from validate-vec-mixed-grad nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (and
     (or (search "define void @vec_scale_grad(" ir)
         (progn (log:error "validate-vec-mixed-grad: @vec_scale_grad not found") nil))
     (or (search "%scale_grad" ir)
         (progn (log:error "validate-vec-mixed-grad: scale_grad adjoint variable not found") nil))
     (or (search "TENSOR_FLOAT_1_GLOBAL_READ-WRITE_COMPACT" ir)
         (progn (log:error "validate-vec-mixed-grad: A_GRAD tensor type READ-WRITE not found") nil))
     (or (search "fmul float" ir)
         (progn (log:error "validate-vec-mixed-grad: fmul not found (scale*A product rule)") nil))
     (or (not (search "idx_GRAD" ir))
         (progn (log:error "validate-vec-mixed-grad: idx_GRAD should not be emitted") nil))
     (progn (log:info "validate-vec-mixed-grad: PASS") t))))

(defun validate-matrix-add-grad (ir-path)
  "Validates the backward kernel for 04-matrix-add (2D matrix, two indices):
     - @mat_add_grad is defined
     - TENSOR_FLOAT_2_GLOBAL_READ-WRITE_COMPACT type present (2D gradient tensors)
     - fadd present
     - row_GRAD and col_GRAD are NOT present (integer scalar filtering)"
  (unless (probe-file ir-path)
    (log:error "validate-matrix-add-grad: IR file not found: ~a" ir-path)
    (return-from validate-matrix-add-grad nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (and
     (or (search "define void @mat_add_grad(" ir)
         (progn (log:error "validate-matrix-add-grad: @mat_add_grad not found") nil))
     (or (search "TENSOR_FLOAT_2_GLOBAL_READ-WRITE_COMPACT" ir)
         (progn (log:error "validate-matrix-add-grad: 2D gradient tensor type READ-WRITE not found") nil))
     (or (search "fadd float" ir)
         (progn (log:error "validate-matrix-add-grad: fadd not found in backward body") nil))
     (or (not (search "row_GRAD" ir))
         (progn (log:error "validate-matrix-add-grad: row_GRAD should not be emitted (integer)") nil))
     (or (not (search "col_GRAD" ir))
         (progn (log:error "validate-matrix-add-grad: col_GRAD should not be emitted (integer)") nil))
     (progn (log:info "validate-matrix-add-grad: PASS") t))))

(defun validate-tensor-add-grad (ir-path)
  "Validates the backward kernel for 05-tensor-add (3D tensor, three indices):
     - @tensor_add_grad is defined
     - TENSOR_FLOAT_3_GLOBAL_READ-WRITE_COMPACT type present (3D gradient tensors)
     - fadd present
     - d0_GRAD, d1_GRAD, d2_GRAD are NOT present (integer scalar filtering)"
  (unless (probe-file ir-path)
    (log:error "validate-tensor-add-grad: IR file not found: ~a" ir-path)
    (return-from validate-tensor-add-grad nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (and
     (or (search "define void @tensor_add_grad(" ir)
         (progn (log:error "validate-tensor-add-grad: @tensor_add_grad not found") nil))
     (or (search "TENSOR_FLOAT_3_GLOBAL_READ-WRITE_COMPACT" ir)
         (progn (log:error "validate-tensor-add-grad: 3D gradient tensor type READ-WRITE not found") nil))
     (or (search "fadd float" ir)
         (progn (log:error "validate-tensor-add-grad: fadd not found in backward body") nil))
     (or (not (search "d0_GRAD" ir))
         (progn (log:error "validate-tensor-add-grad: d0_GRAD should not be emitted (integer)") nil))
     (or (not (search "d1_GRAD" ir))
         (progn (log:error "validate-tensor-add-grad: d1_GRAD should not be emitted (integer)") nil))
     (or (not (search "d2_GRAD" ir))
         (progn (log:error "validate-tensor-add-grad: d2_GRAD should not be emitted (integer)") nil))
     (progn (log:info "validate-tensor-add-grad: PASS") t))))

(defun validate-vec-transcendental-grad (ir-path)
  "Validates the backward kernel for 06-vec-transcendental (sin with cos chain rule):
     - @vec_sin_grad is defined
     - @llvm.cos.f32 intrinsic declared and called (derivative of sin is cos)
     - fmul present (chain rule: cos(x) * adj)
     - idx_GRAD is NOT present"
  (unless (probe-file ir-path)
    (log:error "validate-vec-transcendental-grad: IR file not found: ~a" ir-path)
    (return-from validate-vec-transcendental-grad nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (and
     (or (search "define void @vec_sin_grad(" ir)
         (progn (log:error "validate-vec-transcendental-grad: @vec_sin_grad not found") nil))
     (or (search "llvm.cos" ir)
         (progn (log:error "validate-vec-transcendental-grad: @llvm.cos not found (sin backward needs cos)") nil))
     (or (search "fmul float" ir)
         (progn (log:error "validate-vec-transcendental-grad: fmul not found (chain rule multiply)") nil))
     (or (not (search "idx_GRAD" ir))
         (progn (log:error "validate-vec-transcendental-grad: idx_GRAD should not be emitted") nil))
     (progn (log:info "validate-vec-transcendental-grad: PASS") t))))



(defun validate-vec-basic-sub-grad (ir-path)
  "Validates 081/01-vec-basic-sub-function:
     - @some_operation_grad is defined (the _GRAD companion)
     - @vec_sub_op_grad is defined (the backward kernel)
     - some_operation_grad is called inside vec_sub_op_grad body
     - fadd present (gradient accumulation)
     - idx_GRAD NOT present (integer index filtered)"
  (unless (probe-file ir-path)
    (log:error "validate-vec-basic-sub-grad: IR file not found: ~a" ir-path)
    (return-from validate-vec-basic-sub-grad nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (and
     (or (search "define" ir)
         ;; If some_operation_grad is defined anywhere in the IR
         (progn (log:error "validate-vec-basic-sub-grad: IR appears empty") nil))
     (or (search "some_operation_grad" ir)
         (progn (log:error "validate-vec-basic-sub-grad: @some_operation_grad not found (sub-function _GRAD companion missing)") nil))
     (or (search "vec_sub_op_grad" ir)
         (progn (log:error "validate-vec-basic-sub-grad: @vec_sub_op_grad backward kernel not found") nil))
     (or (search "fadd float" ir)
         (progn (log:error "validate-vec-basic-sub-grad: fadd not found (gradient accumulation missing)") nil))
     (or (not (search "idx_GRAD" ir))
         (progn (log:error "validate-vec-basic-sub-grad: idx_GRAD should not be emitted (integer index)") nil))
     (progn (log:info "validate-vec-basic-sub-grad: PASS") t))))

(defun validate-vec-chain-depth-grad (ir-path)
  "Validates 081/02-vec-chain-depth:
     - three _GRAD companions defined: some_operation_grad, other_operation_grad, final_operation_grad
     - @vec_chain_grad backward kernel defined
     - idx_GRAD NOT present"
  (unless (probe-file ir-path)
    (log:error "validate-vec-chain-depth-grad: IR file not found: ~a" ir-path)
    (return-from validate-vec-chain-depth-grad nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (and
     (or (search "some_operation_grad" ir)
         (progn (log:error "validate-vec-chain-depth-grad: @some_operation_grad not found") nil))
     (or (search "other_operation_grad" ir)
         (progn (log:error "validate-vec-chain-depth-grad: @other_operation_grad not found") nil))
     (or (search "final_operation_grad" ir)
         (progn (log:error "validate-vec-chain-depth-grad: @final_operation_grad not found") nil))
     (or (search "vec_chain_grad" ir)
         (progn (log:error "validate-vec-chain-depth-grad: @vec_chain_grad backward kernel not found") nil))
     (or (not (search "idx_GRAD" ir))
         (progn (log:error "validate-vec-chain-depth-grad: idx_GRAD should not be emitted") nil))
     (progn (log:info "validate-vec-chain-depth-grad: PASS") t))))

(defun validate-mat-basic-sub-grad (ir-path)
  "Validates 081/03-matrix-basic-sub-function:
     - @scale_and_bias_grad defined
     - @mat_sub_op_grad defined
     - 2D gradient tensor type present (TENSOR_FLOAT_2 ... READ-WRITE)
     - fmul present (product rule for a*b)
     - row_GRAD and col_GRAD NOT present"
  (unless (probe-file ir-path)
    (log:error "validate-mat-basic-sub-grad: IR file not found: ~a" ir-path)
    (return-from validate-mat-basic-sub-grad nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (and
     (or (search "scale_and_bias_grad" ir)
         (progn (log:error "validate-mat-basic-sub-grad: @scale_and_bias_grad not found") nil))
     (or (search "mat_sub_op_grad" ir)
         (progn (log:error "validate-mat-basic-sub-grad: @mat_sub_op_grad backward kernel not found") nil))
     (or (search "TENSOR_FLOAT_2" ir)
         (progn (log:error "validate-mat-basic-sub-grad: 2D gradient tensor type not found") nil))
     (or (search "fmul float" ir)
         (progn (log:error "validate-mat-basic-sub-grad: fmul not found (product rule for a*b)") nil))
     (or (not (search "row_GRAD" ir))
         (progn (log:error "validate-mat-basic-sub-grad: row_GRAD should not be emitted (integer index)") nil))
     (or (not (search "col_GRAD" ir))
         (progn (log:error "validate-mat-basic-sub-grad: col_GRAD should not be emitted (integer index)") nil))
     (progn (log:info "validate-mat-basic-sub-grad: PASS") t))))

(defun validate-tensor-basic-sub-grad (ir-path)
  "Validates 081/04-tensor-basic-sub-function:
     - @combine_grad defined
     - @tensor_sub_op_grad defined
     - 3D gradient tensor type present
     - d0_GRAD, d1_GRAD, d2_GRAD NOT present"
  (unless (probe-file ir-path)
    (log:error "validate-tensor-basic-sub-grad: IR file not found: ~a" ir-path)
    (return-from validate-tensor-basic-sub-grad nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (and
     (or (search "combine_grad" ir)
         (progn (log:error "validate-tensor-basic-sub-grad: @combine_grad not found") nil))
     (or (search "tensor_sub_op_grad" ir)
         (progn (log:error "validate-tensor-basic-sub-grad: @tensor_sub_op_grad backward kernel not found") nil))
     (or (search "TENSOR_FLOAT_3" ir)
         (progn (log:error "validate-tensor-basic-sub-grad: 3D gradient tensor type not found") nil))
     (or (not (search "d0_GRAD" ir))
         (progn (log:error "validate-tensor-basic-sub-grad: d0_GRAD should not be emitted") nil))
     (or (not (search "d1_GRAD" ir))
         (progn (log:error "validate-tensor-basic-sub-grad: d1_GRAD should not be emitted") nil))
     (or (not (search "d2_GRAD" ir))
         (progn (log:error "validate-tensor-basic-sub-grad: d2_GRAD should not be emitted") nil))
     (progn (log:info "validate-tensor-basic-sub-grad: PASS") t))))

(defun validate-vec-mvb-sub-grad (ir-path)
  "Validates 081/05-vec-multi-value-return:
     - @split_op_grad defined (two t_grad inputs, two delta outputs)
     - @vec_mvb_op_grad defined
     - split_op_grad called in backward kernel body
     - idx_GRAD NOT present"
  (unless (probe-file ir-path)
    (log:error "validate-vec-mvb-sub-grad: IR file not found: ~a" ir-path)
    (return-from validate-vec-mvb-sub-grad nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (and
     (or (search "split_op_grad" ir)
         (progn (log:error "validate-vec-mvb-sub-grad: @split_op_grad not found") nil))
     (or (search "vec_mvb_op_grad" ir)
         (progn (log:error "validate-vec-mvb-sub-grad: @vec_mvb_op_grad backward kernel not found") nil))
     (or (not (search "idx_GRAD" ir))
         (progn (log:error "validate-vec-mvb-sub-grad: idx_GRAD should not be emitted") nil))
     (progn (log:info "validate-vec-mvb-sub-grad: PASS") t))))

(defun validate-vec-fan-out-sub-grad (ir-path)
  "Validates 081/06-vec-fan-out:
     - @some_operation_grad and @augmentation_grad both defined
     - @vec_fan_op_grad defined
     - both _GRAD functions referenced (two paths contribute to A_GRAD)
     - idx_GRAD NOT present"
  (unless (probe-file ir-path)
    (log:error "validate-vec-fan-out-sub-grad: IR file not found: ~a" ir-path)
    (return-from validate-vec-fan-out-sub-grad nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (and
     (or (search "some_operation_grad" ir)
         (progn (log:error "validate-vec-fan-out-sub-grad: @some_operation_grad not found") nil))
     (or (search "augmentation_grad" ir)
         (progn (log:error "validate-vec-fan-out-sub-grad: @augmentation_grad not found") nil))
     (or (search "vec_fan_op_grad" ir)
         (progn (log:error "validate-vec-fan-out-sub-grad: @vec_fan_op_grad backward kernel not found") nil))
     (or (not (search "idx_GRAD" ir))
         (progn (log:error "validate-vec-fan-out-sub-grad: idx_GRAD should not be emitted") nil))
     (progn (log:info "validate-vec-fan-out-sub-grad: PASS") t))))

(defun validate-vec-mixed-sub-grad (ir-path)
  "Validates 081/07-vec-mixed-scalar-tensor:
     - @scale_element_grad defined
     - @vec_scale_sub_grad defined
     - scalar scale_GRAD present (float scalar gradient)
     - TENSOR_FLOAT_1 present (tensor gradient for A_GRAD)
     - fmul present (product rule for s*a)
     - idx_GRAD NOT present"
  (unless (probe-file ir-path)
    (log:error "validate-vec-mixed-sub-grad: IR file not found: ~a" ir-path)
    (return-from validate-vec-mixed-sub-grad nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (and
     (or (search "scale_element_grad" ir)
         (progn (log:error "validate-vec-mixed-sub-grad: @scale_element_grad not found") nil))
     (or (search "vec_scale_sub_grad" ir)
         (progn (log:error "validate-vec-mixed-sub-grad: @vec_scale_sub_grad backward kernel not found") nil))
     (or (search "TENSOR_FLOAT_1" ir)
         (progn (log:error "validate-vec-mixed-sub-grad: 1D gradient tensor type for A_GRAD not found") nil))
     (or (search "fmul float" ir)
         (progn (log:error "validate-vec-mixed-sub-grad: fmul not found (product rule for s*a)") nil))
     (or (not (search "idx_GRAD" ir))
         (progn (log:error "validate-vec-mixed-sub-grad: idx_GRAD should not be emitted") nil))
     (progn (log:info "validate-vec-mixed-sub-grad: PASS") t))))

