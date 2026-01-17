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


;; src/environment.lisp
;; FIX for Bug 015/017: Use actual cell type from *implicit-arg-map*
(defun inject-implicit-arguments (name explicit-env)
  "Injects implicit arguments into the environment if the function is a carrier."
  (let* ((implicit-info (gethash name *implicit-arg-map*))
         (implicit-env (when implicit-info
                             ;; implicit-info is now: ((name . type) ...)
                             (loop for (param-name . param-type) in implicit-info
                                   collect (make-parameter-def
                                            :name param-name
                                            :type param-type
                                            :kind :in)))))
    (append implicit-env explicit-env)))
;; src/analysis/structs.lisp
;; FIX for Bug 015/017: Store actual cell type instead of hardcoded :storage
;; CORRECTED VERSION (fixes the ''cell and ''__sc issues)
(defun analyze-scratch-expression (expr env location)
  "Analyzes a (make-scratch-cell ...) expression.
 In single-pass mode, this marks the current function as an originator."
  (declare (ignore env)) ; We don't use env yet.
  (unless (and (= (length expr) 2) (symbolp (cadr expr)))
    (error "Malformed make-scratch-cell form: ~a. Expected (make-scratch-cell <type>)" expr))

  ;; --- Phase 5: Single-Pass Originator Detection ---
  ;; If *call-graph* is nil, we are in single-pass mode.
  (when (null *call-graph*)
        (log:debug "Single-pass: Found originator form in ~s. Marking it." *current-compiling-function*)
        ;; BEFORE: (setf (gethash *current-compiling-function* *implicit-arg-map*) '(:storage))
        ;; AFTER: Store the actual cell type
        (let* ((inner-type (cadr expr))
               (raw-spec (list 'cell inner-type))
               (canonical-spec (expand-storage-handle-type-specifier raw-spec)))
          ;; Store: (name . type) - for now use generated name __sc
          ;; Later: extract :name from make-scratch-cell keywords
          (setf (gethash *current-compiling-function* *implicit-arg-map*)
            (list (cons '__sc canonical-spec)))))

  (let ((inner-type (cadr expr)))
    ;; Ensure the inner type is valid
    (unless (gethash inner-type *crisp-types*)
      (error 'crisp-unknown-type-error :type-name inner-type :source-location location))

    ;; Construct raw spec and expand/canonicalize it (e.g. inject defaults)
    ;; We use expand-storage-handle-type-specifier directly to get the LIST form, not the mangled symbol.
    (let* ((raw-spec (list 'cell inner-type))
           (canonical-spec (expand-storage-handle-type-specifier raw-spec)))

      ;; Ensure instantiation
      (unless (valid-parameterized-type-p canonical-spec)
        (error "Failed to instantiate template for ~a (raw: ~a)" canonical-spec raw-spec))

      (make-semantic-literal :value-type canonical-spec
                             :value nil ; No real value yet
                             :source-location location))))
;; src/analysis/core.lisp
;; FIX for Bug 015/017: Carrier propagation should copy from callee
;; Lines around 50 and 64 set '(:storage) - need to copy actual implicit info

;; NOTE: These fixes handle the Two-Pass analysis mode
;; The single-pass mode is handled by scan-for-carriers in environment.lisp

(defun mark-carriers-pass (originators)
  "Marks carrier functions during two-pass mode."
  (let ((work-list (copy-list originators))
        (visited (make-hash-table)))
    (loop while work-list
          for fn-name = (pop work-list)
          do (unless (gethash fn-name visited)
               (setf (gethash fn-name visited) t)
               ;; Copy implicit info from callee if it has any
               (let ((callers (gethash fn-name *reverse-call-graph*)))
                 (dolist (caller callers)
                   (unless (gethash caller *implicit-arg-map*)
                     ;; BEFORE: (setf (gethash caller *implicit-arg-map*) '(:storage))
                     ;; AFTER: Copy from callee
                     (let ((callee-implicit (gethash fn-name *implicit-arg-map*)))
                       (when callee-implicit
                             (setf (gethash caller *implicit-arg-map*) callee-implicit)
                             (push caller work-list))))))))))
;; src/analysis/core.lisp
;; FIX for Bug 015/017: propagate-implicit-arguments should copy from callees
;; ADDED LOGGING VERSION to verify this is being called
(defun propagate-implicit-arguments ()
  "Phase 4: Traverses the call graph backwards from originators to find all carriers."
  (log:info "OVERLAY: propagate-implicit-arguments called with ~a originators"
            (hash-table-count *originator-functions*))
  (let ((worklist '()))
    ;; 1. Seed the worklist with all originator functions.
    ;; NOTE: Don't set their *implicit-arg-map* here - analyze-scratch-expression already did
    (loop for fn-name being the hash-keys of *originator-functions*
          do (progn
              (log:info "OVERLAY: Originator ~a has implicit-args: ~a"
                        fn-name (gethash fn-name *implicit-arg-map*))
              (push fn-name worklist)))

    ;; 2. Process the worklist until it's empty.
    (loop while worklist
          do (let* ((callee (pop worklist))
                    (callee-implicit (gethash callee *implicit-arg-map*))
                    ;; Find all functions that call the current callee.
                    (callers (loop for caller being the hash-keys of *call-graph*
                                   using (hash-value callees)
                                     when (member callee callees)
                                   collect caller)))
               (log:debug "OVERLAY: Processing callee ~a with implicit ~a, callers: ~a"
                          callee callee-implicit callers)
               (dolist (caller callers)
                 ;; If this caller isn't already marked as a carrier, copy from callee and add to worklist.
                 (unless (gethash caller *implicit-arg-map*)
                   ;; BEFORE: (setf (gethash caller *implicit-arg-map*) '(:storage))
                   ;; AFTER: Copy from callee
                   (when callee-implicit
                         (log:info "OVERLAY: Marking ~a as carrier (copied from ~a): ~a"
                                   caller callee callee-implicit)
                         (setf (gethash caller *implicit-arg-map*) callee-implicit)
                         (push caller worklist))))))))

;; src/analysis/core.lisp
;; FIX for Bug 015/017: analyze-function-call needs to use actual param names from map

(defun analyze-function-call (op expr env location)
  "Analyzes a call to a user-defined function."
  (log:debug "Analyzing function call to ~s. Current function: ~s" op *current-compiling-function*)
  (if *call-graph*
      (when *current-compiling-function*
            (pushnew op (gethash *current-compiling-function* *call-graph*)))
      (when (member op *single-pass-call-stack*)
            (error 'crisp-recursion-error :form op :source-location (append location '(0)))))

  (let ((implicit-args-required (gethash op *implicit-arg-map*)))
    (when (and (null *call-graph*) implicit-args-required)
          (setf (gethash *current-compiling-function* *implicit-arg-map*) implicit-args-required))

    (let* ((arg-forms (rest expr))
           (explicit-arg-nodes (loop for arg-form in arg-forms
                                     for i from 1
                                     collect (analyze-expression arg-form env (append location (list i)))))
           (explicit-arg-types (mapcar #'get-single-value-type explicit-arg-nodes))
           (signature (resolve-best-signature op explicit-arg-types)))

      (let ((final-arg-nodes
             (if implicit-args-required
                 (let ((implicit-arg-nodes
                        ;; BEFORE: Loop through keywords :storage
                        ;; AFTER: Loop through cons cells (name . type)
                        (loop for (param-name . param-type) in implicit-args-required
                              collect (let ((found (find-variable-in-env param-name env)))
                                        (if found
                                            (make-semantic-var-read :name param-name :type (parameter-def-type found) :source-location location)
                                            (error "Compiler bug: Carrier function ~s is missing implicit argument ~s."
                                              *current-compiling-function* param-name))))))
                   (append implicit-arg-nodes explicit-arg-nodes))
                 explicit-arg-nodes)))

        (unless (= (length explicit-arg-types) (length (function-signature-parameters signature)))
          (error 'crisp-signature-arity-error
            :expected (length (function-signature-parameters signature))
            :inferred (length explicit-arg-types)
            :source-location location))

        ;; ... rest of function unchanged ...
        (let ((ret-type (function-signature-return-types signature)))
          #|(let ((is-void (or (eq ret-type 'void)
                             (and (symbolp ret-type) (string-equal (symbol-name ret-type) "VOID"))
                             (and (consp ret-type)
                                  (let ((head (first ret-type)))
                                    (or (eq head 'void)
                                        (and (symbolp head) (string-equal (symbol-name head) "VOID")))))))
                (when (and (or (string= (symbol-name op) "~") (string= (symbol-name op) "~REF~"))
                           is-void)
                      (error "Cannot dereference a Cell of type VOID. Specify an element type (e.g. (cell int)) or avoid using the dereference operator (~~)."))))
          |#
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
                                :source-location location)))))))
;; src/environment.lisp  
;; FIX for Bug 015/017: scan-for-carriers should copy from callees
(defun scan-for-carriers (name body)
  "Performs a single-pass look-ahead to detect if the function is a carrier."
  (when (null *call-graph*)
        (multiple-value-bind (is-originator callees) (shallow-analyze-body body)
          (when (or is-originator (some (lambda (callee)
                                          (or (gethash callee *implicit-arg-map*)
                                              (member callee *side-channel-originators*)))
                                      callees))
                (log:debug "Single-pass: Pre-scan of ~s found call to a carrier/originator. Marking as carrier." name)
                ;; BEFORE: (setf (gethash name *implicit-arg-map*) '(:storage))
                ;; AFTER: Copy from first callee that has implicit params
                (let ((callee-with-implicits
                       (find-if (lambda (c) (gethash c *implicit-arg-map*)) callees)))
                  (if callee-with-implicits
                      ;; Copy from callee
                      (setf (gethash name *implicit-arg-map*)
                        (gethash callee-with-implicits *implicit-arg-map*))
                      ;; Originator case - will be set later by analyze-scratch-expression
                      nil))))))


(defun scan-for-carriers (name body)
  "Performs a single-pass look-ahead to detect if the function is a carrier."
  (when (null *call-graph*)
        (multiple-value-bind (is-originator callees) (shallow-analyze-body body)
          (when (or is-originator (some (lambda (callee)
                                          (or (gethash callee *implicit-arg-map*)
                                              (member callee *side-channel-originators*)))
                                      callees))
                (log:debug "Single-pass: Pre-scan of ~s found call to a carrier/originator. Marking as carrier." name)
                ;; BEFORE: (setf (gethash name *implicit-arg-map*) '(:storage))
                ;; AFTER: Copy from first callee that has implicit params
                (let ((callee-with-implicits
                       (find-if (lambda (c) (gethash c *implicit-arg-map*)) callees)))
                  (if callee-with-implicits
                      ;; Copy from callee
                      (setf (gethash name *implicit-arg-map*)
                        (gethash callee-with-implicits *implicit-arg-map*))
                      ;; Originator case - will be set later by analyze-scratch-expression
                      nil))))))


;; src/codegen.lisp lines 272-359
;; FIX for Bug 015/017: Support both __sc (new) and __storage (legacy) parameter names
;; This is a CLEAN version to replace the malformed one in the overlay
(defmethod generate-node-ir ((node semantic-literal) builder module var-env di-builder di-scope location-map)
  "Generates IR for a literal value."
  (let* ((type-spec (semantic-literal-value-type node))
         (value (semantic-literal-value node))
         (llvm-type (unless (member type-spec '(keyword symbol quote))
                      (crisp-type-to-llvm-type type-spec module)))
         (result
          (cond
           ;; Handle parameterized types
           ((or (eq type-spec 'keyword) (eq type-spec 'symbol) (eq type-spec 'quote))
             (let ((ival (resolve-keyword-constant value)))
               (llvm-const-int (llvm-int32-type) ival nil)))

           ((listp type-spec)
             (let ((base-type (first type-spec)))
               (cond
                ((or (eq base-type :function-literal) (eq base-type :function-type))
                  (llvm-get-undef llvm-type))

                ((or (eq base-type 'keyword) (eq base-type 'symbol))
                  (let ((ival (resolve-keyword-constant value)))
                    (llvm-const-int (llvm-int32-type) ival nil)))

                ((eq base-type 'cell)
                  ;; FIXED: Check for both __sc (new convention) and __storage (legacy)
                  (let* ((storage-var-name (or (when (gethash '__sc var-env) '__sc) '__storage))
                         (storage-alloca (gethash storage-var-name var-env)))
                    (unless storage-alloca
                      (error "Missing implicit argument ~a for make-scratch-cell. Environment keys: ~s"
                        storage-var-name (alexandria:hash-table-keys var-env)))

                    (let* ((storage-type (crisp-type-to-llvm-type 'storage module))
                           (storage-val (llvm-build-load2 builder storage-type storage-alloca "storage_val"))
                           (mangled-name (mangle-template-struct-name base-type (rest type-spec)))
                           (cell-struct-type (ensure-struct-llvm-type mangled-name))
                           (cell-undef (llvm-get-undef cell-struct-type))
                           (cell-0 (llvm-build-insert-value builder cell-undef storage-val 0 "parent"))
                           (cell-1 (llvm-build-insert-value builder cell-0
                                                            (llvm-const-int (llvm-int64-type) 0 nil)
                                                            1 "offset"))
                           (cell-handle (llvm-build-alloca builder cell-struct-type "cell_lit_handle")))
                      (llvm-build-store builder cell-1 cell-handle)
                      cell-handle)))

                (t (error "Codegen not implemented for literal of type ~a" type-spec)))))

           ;; Handle simple or singleton types
           ((or (symbolp type-spec)
                (and (consp type-spec) (member (first type-spec) '(keyword symbol quote))))
             (let ((type-sym (if (consp type-spec) (first type-spec) type-spec)))
               (cond
                ((or (gethash type-spec *crisp-enums*)
                     (member type-sym '(keyword symbol quote)))
                  (let* ((val (resolve-keyword-constant value))
                         (target-type (or llvm-type (llvm-int32-type)))
                         (val-i64 (llvm-const-int (llvm-int64-type) (ldb (byte 64 0) val) nil)))
                    (llvm-build-trunc builder val-i64 target-type "enum_trunc")))

                (t
                  (let ((crisp-type (gethash type-sym *crisp-types*)))
                    (unless crisp-type
                      (error "Codegen: Literal type ~a not found in *crisp-types* or *crisp-enums*" type-spec))
                    (cond
                     ((member (crisp-type-category crisp-type) '(:signed-int :unsigned-int))
                       (if (zerop value)
                           (llvm-const-null llvm-type)
                           (let ((val-i64 (llvm-const-int (llvm-int64-type) (ldb (byte 64 0) value) nil)))
                             (if (= (crisp-type-size crisp-type) 64)
                                 val-i64
                                 (llvm-build-trunc builder val-i64 llvm-type "int_trunc")))))
                     ((eq (crisp-type-category crisp-type) :float)
                       (llvm-const-real llvm-type (coerce value 'double-float)))
                     ((eq (crisp-type-category crisp-type) :void) nil)
                     (t (error "Codegen for literal of unknown type category: ~a" type-spec))))))))

           (t (error "Codegen not implemented for literal of type ~a" type-spec))))

         (di-location
          (when (and di-builder di-scope location-map)
                (let* ((loc (semantic-node-source-location node))
                       (line (gethash loc location-map 0)))
                  (llvm-di-builder-create-debug-location (llvm-get-module-context module)
                                                         line 0 di-scope (cffi:null-pointer))))))
    (values result di-location)))
;; src/analysis/structs.lisp
;; FIX for Bug 015/017: Store actual cell type in BOTH single-pass and two-pass modes
(defun analyze-scratch-expression (expr env location)
  "Analyzes a (make-scratch-cell ...) expression.
 This marks the current function as an originator in BOTH analysis modes."
  (declare (ignore env)) ; We don't use env yet.
  (unless (and (= (length expr) 2) (symbolp (cadr expr)))
    (error "Malformed make-scratch-cell form: ~a. Expected (make-scratch-cell <type>)" expr))

  ;; --- Originator Detection (both single-pass and two-pass) ---
  ;; Store the actual cell type and name in *implicit-arg-map*
  (log:debug "Originator: Found make-scratch-cell in ~s" *current-compiling-function*)
  (let* ((inner-type (cadr expr))
         (raw-spec (list 'cell inner-type))
         (canonical-spec (expand-storage-handle-type-specifier raw-spec)))
    ;; Store: (name . type) - for now use generated name __sc
    ;; Later: extract :name from make-scratch-cell keywords
    (setf (gethash *current-compiling-function* *implicit-arg-map*)
      (list (cons '__sc canonical-spec))))

  (let ((inner-type (cadr expr)))
    ;; Ensure the inner type is valid
    (unless (gethash inner-type *crisp-types*)
      (error 'crisp-unknown-type-error :type-name inner-type :source-location location))

    ;; Construct raw spec and expand/canonicalize it (e.g. inject defaults)
    (let* ((raw-spec (list 'cell inner-type))
           (canonical-spec (expand-storage-handle-type-specifier raw-spec)))

      ;; Ensure instantiation
      (unless (valid-parameterized-type-p canonical-spec)
        (error "Failed to instantiate template for ~a (raw: ~a)" canonical-spec raw-spec))

      (make-semantic-literal :value-type canonical-spec
                             :value nil ; No real value yet
                             :source-location location))))


;; src/analysis/core.lisp  
;; FIX for Bug 015/017: Extract scratch cell type during Pass 1 scanning
;; This specialized scan-operator method handles make-scratch-cell specifically
(defmethod scan-operator ((op (eql 'make-scratch-cell)) args)
  "Scans make-scratch-cell and extracts the type for *implicit-arg-map*."
  (setf *scan-is-originator* t)

  ;; Extract the type argument: (make-scratch-cell TYPE)
  (when (and args (symbolp (first args)))
        (let* ((inner-type (first args))
               (raw-spec (list 'cell inner-type))
               (canonical-spec (expand-storage-handle-type-specifier raw-spec)))
          ;; Store in *implicit-arg-map* for this function
          ;; Use generated name __sc for now
          (log:debug "Pass 1: Detected make-scratch-cell with type ~a in ~a"
                     canonical-spec *scanning-function-name*)
          (setf (gethash *scanning-function-name* *implicit-arg-map*)
            (list (cons '__sc canonical-spec)))))

  ;; Continue scanning arguments
  (dolist (arg args) (scan-form arg)))


;; src/analysis/core.lisp or src/types/registry.lisp
;; FIX for Bug 015/017: Add dynamic variable for function name during Pass 1 scanning
(defvar *scanning-function-name* nil
        "The name of the function currently being scanned in Pass 1.")

;; src/analysis/core.lisp
;; FIX for Bug 015/017: Provide function name context during Pass 1 scanning
;; This modifies analyze-signatures-pass to bind *scanning-function-name*
(defun analyze-signatures-pass (forms)
  "Pass 1: Iterates through forms to find and register function signatures."
  (walk-code-forms forms
                   (lambda (form location)
                     (let* ((name (second form))
                            (body (cdddr form)))
                       ;; 1. Register the explicit signature.
                       (register-function-signature form location)
                       ;; 2. Perform shallow analysis for call graph and originators.
                       ;; FIXED: Bind the function name so scan-operator can access it
                       (let ((*scanning-function-name* name))
                         (multiple-value-bind (is-originator callees)
                             (shallow-analyze-body body)
                           (when is-originator
                                 (setf (gethash name *originator-functions*) t))
                           (setf (gethash name *call-graph*) callees)))))))
