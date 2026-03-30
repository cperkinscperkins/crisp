;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.

(in-package :crisp.compiler)

;; Std140 Layout (GPU Alignment)
;; =============================

(defun get-std140-base-alignment (type-spec)
  "Returns the base alignment (N) for a given type according to std140 rules.
   Extended to handle (array T N): arrays align to 16 bytes (vec4) per std140."
  (cl:let* ((alias-resolved (resolve-type-alias type-spec))
            (resolved-type (get-type-base alias-resolved)))
    (cl:cond
      ;; (array T N) -> 16-byte alignment per std140 array rules
      ((%array-type-p type-spec) 16)
      ((%array-type-p alias-resolved) 16)
      ((or (eq resolved-type 'float) (eq resolved-type 'int) (eq resolved-type 'uint)) 4)
      ((or (eq resolved-type 'double) (eq resolved-type 'long) (eq resolved-type 'ulong)) 8)
      ((or (eq resolved-type 'char) (eq resolved-type 'uchar)) 1)
      ((or (eq resolved-type 'short) (eq resolved-type 'ushort)
           (eq resolved-type 'half) (eq resolved-type 'bfloat16)) 2)
      ((or (eq resolved-type 'bool)) 4)
      ((eq type-spec 'c-pointer) 8)
      ((and (consp type-spec) (eq (cl:first type-spec) 'c-pointer)) 8)
      ((and (symbolp type-spec)
            (> (cl:length (symbol-name type-spec)) 5)
            (string-equal (cl:subseq (symbol-name type-spec) 0 5) "CELL_"))
       8)
      ((gethash type-spec *crisp-structs*) 16)
      ((and (consp type-spec) (valid-type-p type-spec))
       (cl:let ((base (cl:first type-spec)))
         (cl:cond
           ((string-equal (symbol-name base) "CELL") 8)
           (t
            (cl:let ((mangled (mangle-template-struct-name (cl:first type-spec) (cl:rest type-spec))))
              (if (gethash mangled *crisp-structs*)
                  16
                  (error "Valid type ~a but struct def not found after check alignment." type-spec)))))))
      (t (error "Unknown type for alignment: ~a" type-spec)))))

;;; src/structs.lisp
(defun get-std140-size (type-spec)
  "Returns the size (in bytes) of a type.
   Extended to handle (array T N): size is N * element-size, rounded up to 16-byte stride per std140."
  (cl:let* ((alias-resolved (resolve-type-alias type-spec))
            (resolved-type (get-type-base alias-resolved)))
    (cl:cond
      ;; (array T N) -> N * ceil(elem-size, 16) per std140 array element stride
      ((%array-type-p type-spec)
       (cl:let* ((elem-type (cl:second type-spec))
                 (n         (cl:third type-spec))
                 (elem-size (get-std140-size elem-type))
                 ;; std140: each array element is padded to vec4 (16-byte) stride
                 (stride    (+ elem-size (calculate-std140-padding elem-size 16))))
         (* n stride)))
      ((%array-type-p alias-resolved)
       (get-std140-size alias-resolved))
      ((or (eq resolved-type 'float) (eq resolved-type 'int) (eq resolved-type 'uint)) 4)
      ((or (eq resolved-type 'double) (eq resolved-type 'long) (eq resolved-type 'ulong)) 8)
      ((or (eq resolved-type 'char) (eq resolved-type 'uchar)) 1)
      ((or (eq resolved-type 'short) (eq resolved-type 'ushort)
           (eq resolved-type 'half) (eq resolved-type 'bfloat16)) 2)
      ((eq resolved-type 'bool) 4)
      ((eq resolved-type 'c-pointer) 8)
      ((and (consp type-spec) (eq (cl:first type-spec) 'c-pointer)) 8)
      ((and (symbolp type-spec)
            (> (cl:length (symbol-name type-spec)) 5)
            (string-equal (cl:subseq (symbol-name type-spec) 0 5) "CELL_"))
       8)
      ((gethash type-spec *crisp-structs*)
       (crisp-struct-definition-total-size (gethash type-spec *crisp-structs*)))
      ((and (consp type-spec) (valid-type-p type-spec))
       (cl:let ((base (cl:first type-spec)))
         (cl:cond
           ((string-equal (symbol-name base) "CELL") 8)
           (t
            (cl:let* ((mangled (mangle-template-struct-name (cl:first type-spec) (cl:rest type-spec)))
                      (struct-info (gethash mangled *crisp-structs*)))
              (if struct-info
                  (crisp-struct-definition-total-size struct-info)
                  (error "Valid type ~a but struct def not found for size." type-spec)))))))
      (t (error "Unknown type for size: ~a" type-spec)))))

(defun calculate-std140-padding (current-offset alignment)
  "Calculates padding needed to reach the next alignment boundary."
  (cl:let ((remainder (mod current-offset alignment)))
    (if (zerop remainder)
        0
        (- alignment remainder))))


(defun compute-std140-layout (members)
  "Takes a list of (name type) members.
  Returns a list of:
    - Expanded members with `_pad` fields inserted.
    - Total struct size (padded to 16 bytes).
  
  Returns (values expanded-members total-size)"
  ;; Filter out compile-time properties (marked with :c-t)
  (cl:let* ((runtime-members (remove-if (lambda (m) (and (consp m) (eq (third m) :c-t))) members))
            (current-offset 0)
            (expanded-members '()))
    (dolist (member runtime-members)
      (cl:let* ((name (first member))
                (type (second member))
                (alignment (get-std140-base-alignment type)) ;; Calls new version
                (size (get-std140-size type)) ;; Calls new version
                (padding (calculate-std140-padding current-offset alignment)))
        (declare (ignore name))

        ;; Insert padding if needed
        (cl:when (> padding 0)
          (cl:let ((pad-remaining padding)
                   (pad-idx 0)
                   (pad-current-offset current-offset))
            (loop while (> pad-remaining 0) do
                    (cl:let* ((pad-member
                               (cl:cond
                                 ;; Only use larger types if we are aligned for them!
                                 ((and (>= pad-remaining 8) (zerop (mod pad-current-offset 8))) (list 'double 8))
                                 ((and (>= pad-remaining 4) (zerop (mod pad-current-offset 4))) (list 'int 4))
                                 ((and (>= pad-remaining 2) (zerop (mod pad-current-offset 2))) (list 'short 2))
                                 (t (list 'char 1))))
                              (pad-type (first pad-member))
                              (pad-size (second pad-member))
                              (pad-name (intern (format nil "_PAD_~a_~a" current-offset pad-idx))))

                      (push (list pad-name pad-type) expanded-members)
                      (decf pad-remaining pad-size)
                      (incf pad-current-offset pad-size)
                      (incf pad-idx))))
          (incf current-offset padding))

        ;; Add the actual member
        (push member expanded-members)
        (incf current-offset size)))

    ;; Final structure padding to multiple of 16 (vec4 alignment)
    (cl:let ((final-padding (calculate-std140-padding current-offset 16)))
      (cl:when (> final-padding 0)
        (cl:let ((pad-remaining final-padding)
                 (pad-idx 0)
                 (pad-current-offset current-offset))
          (loop while (> pad-remaining 0) do
                  (cl:let* ((pad-member
                             (cl:cond
                               ((and (>= pad-remaining 8) (zerop (mod pad-current-offset 8))) (list 'double 8))
                               ((and (>= pad-remaining 4) (zerop (mod pad-current-offset 4))) (list 'int 4))
                               ((and (>= pad-remaining 2) (zerop (mod pad-current-offset 2))) (list 'short 2))
                               (t (list 'char 1))))
                            (pad-type (first pad-member))
                            (pad-size (second pad-member))
                            (pad-name (intern (format nil "_PAD_EA_~a" pad-idx))))

                    (push (list pad-name pad-type) expanded-members)
                    (decf pad-remaining pad-size)
                    (incf pad-current-offset pad-size)
                    (incf pad-idx)))))
      (incf current-offset final-padding))

    (values (nreverse expanded-members) current-offset)))

;; Struct Logic
;; ============

;; Global for testing isolation
(defvar *struct-name-prefix* "")
(defparameter *record-definitions* (make-hash-table))

;; Recursive / Multipass Support
;; Recursive / Multipass Support
;; (Moved globals to types.lisp to allow access from valid-type-p)

(defun ensure-struct-llvm-type (name)
  "Ensures the LLVM struct type exists for the given struct name.
   Handles forward declarations and recursion."
  (cl:let ((name (if (consp name)
                     (crisp.compiler::mangle-template-struct-name (first name) (rest name))
                     name)))
    (log:debug "ensure-struct-llvm-type called with ~s (mangled: ~s)" name name)
    (cl:let ((def (find-struct-definition-by-name name)))
      (cl:unless def
        (error "Unknown struct type: ~a" name))

      ;; Return cached type if available
      (cl:when (crisp-struct-definition-llvm-type def)
        (return-from ensure-struct-llvm-type (crisp-struct-definition-llvm-type def)))

      ;; Create the named struct (opaque first) to handle recursion
      (cl:let* ((ctx (llvm-get-module-context *current-module*))
                (full-name (format nil "~a~a" *struct-name-prefix* (symbol-name (crisp-struct-definition-name def))))
                ;; FIX: Check if the type already exists in the module (e.g. from a previous pass or duplicate instantiation)
                (existing-type (crisp.llvm-bindings:llvm-get-type-by-name *current-module* full-name))
                (struct-type (if (and existing-type (not (cffi:null-pointer-p existing-type)))
                                 existing-type
                                 (llvm-struct-create-named ctx full-name))))
        ;; CACHE IT IMMEDIATELY
        (setf (crisp-struct-definition-llvm-type def) struct-type)

        (cl:let ((element-types '()))
          (dolist (member-spec (crisp-struct-definition-padded-members def))
            (cl:let* ((type-name (second member-spec))
                      (resolved-type (resolve-type-to-llvm type-name)))
              (log:info "Member ~a (type ~a) resolved to LLVM type: ~a" (first member-spec) type-name resolved-type)
              (cl:unless resolved-type
                (error "Failed to resolve type ~a for member ~a" type-name (first member-spec)))
              (push resolved-type element-types)))

          ;; Set the body
          (log:info "Setting struct body for ~a. Element count: ~d" name (length element-types))
          (cl:let ((types-array (cffi:foreign-alloc :pointer :count (length element-types))))
            (loop for type in (reverse element-types)
                  for i from 0
                  do (setf (cffi:mem-aref types-array :pointer i) type))
            (log:info "Calling LLVMStructSetBody...")
            (llvm-struct-set-body struct-type types-array (length element-types) nil) ; packed=nil
            (log:info "LLVMStructSetBody done.")
            (cffi:foreign-free types-array)))

        struct-type))))

(defun find-struct-definition-by-name (name-or-symbol)
  "Robustly finds a struct definition by symbol or name string, ignoring package."
  (cl:when (consp name-or-symbol) (return-from find-struct-definition-by-name nil))
  (cl:let ((def (gethash name-or-symbol *crisp-structs*)))
    (if def
        def
        ;; Fallback: Scan for name match
        (if (or (symbolp name-or-symbol) (stringp name-or-symbol))
            (cl:let ((target-name (string (if (symbolp name-or-symbol) (symbol-name name-or-symbol) name-or-symbol))))
              (maphash (lambda (k v)
                         (cl:when (string-equal (symbol-name k) target-name)
                           (return-from find-struct-definition-by-name v)))
                       *crisp-structs*)
              nil)
            nil))))


(defun compute-record-layout (members)
  "Computes layout for records (virtual, no padding)."
  (cl:let* ((runtime-members (remove-if (lambda (m) (and (consp m) (eq (third m) :c-t))) members))
            (current-offset 0)
            (expanded-members '()))
    (dolist (member runtime-members)
      (cl:let* ((type (second member))
                (size (get-std140-size type))) ;; Calls new version
        (push member expanded-members)
        (incf current-offset size)))

    (values (nreverse expanded-members) current-offset)))

(defun lookup-struct-definition (type-name)
  "Looks up a struct definition, handling derived types and package issues.
   Returns the struct definition or NIL if not found.

   This function:
   1. Resolves derived types to their base type using get-type-base
   2. Tries package-agnostic lookup (current package, then :crisp-language)
   3. Works for both structs and records (both stored in *crisp-structs*)"
  (let* ((base-type (get-type-base type-name))
         ;; Try direct lookup with base type
         (def-direct (gethash base-type *crisp-structs*))
         ;; Try package-agnostic lookup if needed
         (def-alt (cl:when (and (not def-direct) (symbolp base-type))
                    (gethash (intern (symbol-name base-type)
                                     (find-package :crisp-language))
                             *crisp-structs*))))
    (or def-direct def-alt)))




(defun register-struct-definition (name members &optional (category :struct))
  "Registers a struct or record definition in the global registry.
   Extended: for records, validates that no (array T N) member has N > 16."
  ;; Cap check: virtual arrays in records are limited to N <= 16
  (cl:when (eq category :record)
    (dolist (m members)
      (cl:let ((type (cl:if (and (consp m) (>= (cl:length m) 2)) (cl:second m) nil)))
        (cl:when (and type (%array-type-p type))
          (let* ((count-raw (cl:third type))
                 (count (etypecase count-raw
                          (integer count-raw)
                          (symbol  (parse-integer (symbol-name count-raw))))))
            (cl:when (> count 16)
              (error 'crisp-compiler-error
                     :message (format nil "Record virtual array '~a' exceeds maximum size: N=~a > 16. Use def-struct or a cell for large arrays."
                                      (cl:first m) count))))))))
  (cl:let ((name (cl:if (consp name)
                     (mangle-template-struct-name (cl:first name) (cl:rest name))
                     name)))
    (handler-case
        (multiple-value-bind (padded-members total-size)
            (if (eq category :record)
                (compute-record-layout members)
                (compute-std140-layout members))
          (cl:let ((indices (make-hash-table :test #'eq)))
            (loop for m in padded-members
                  for i from 0
                  do (setf (gethash (car m) indices) i))
            (setf (gethash name *crisp-structs*)
              (make-crisp-struct-definition
               :name name
               :members members
               :padded-members padded-members
               :field-indices indices
               :total-size total-size))
            (setf (gethash name *crisp-types*)
              (make-crisp-type
               :name name
               :llvm-type-fn (lambda () (ensure-struct-llvm-type name))
               :size (* total-size 8)
               :category category))))
      (error (c)
        (cl:when *defer-struct-validation*
          (log:info "Deferring struct registration for ~a. dependency missing/error: ~a" name c)
          (return-from register-struct-definition
                       (push (list name members category) *pending-struct-definitions*)))
        (error c)))))

(defun finalize-struct-definitions ()
  "Iteratively attempts to register pending structs. Errors if a cycle or unknown type persists."
  (log:info "Finalizing ~d pending struct definitions..." (length *pending-struct-definitions*))
  (cl:let ((progress-made t))
    (loop while (and *pending-struct-definitions* progress-made) do
            (setf progress-made nil)
            (cl:let ((current-pending (reverse *pending-struct-definitions*))
                     (still-pending '()))
              (setf *pending-struct-definitions* nil) ;; Clear global queue for this pass

              (dolist (item current-pending)
                (cl:let ((name (first item))
                         (members (second item))
                         (category (third item)))
                  (log:debug "Retrying registration for ~a..." name)
                  (handler-case
                      (progn
                       (register-struct-definition name members category)
                       (cl:cond
                         ;; If it ended up back in the queue, we didn't succeed (still deferred)
                         ((find name *pending-struct-definitions* :key #'first :test #'equal)
                          (push item still-pending))
                         (t
                          (setf progress-made t)
                          (log:info "Successfully registered deferred struct: ~a" name))))
                    (error (c)
                      ;; Should not happen given register-struct-definition catches errors,
                      ;; but for safety:
                      (log:warn "Unexpected error during finalize: ~a" c)
                      (push item *pending-struct-definitions*)))))

              ;; Update pending list with those that failed this pass
              ;; Note: *pending-struct-definitions* might have new items if logic changes,
              ;; but here we just restore the ones we couldn't handle.
              ;; Since register-struct-definition pushes to *pending*, we merge or verify.
              ;; Actually our register-struct-definition pushes ON ERROR. 
              ;; So if we are running inside finalize, we should probably handle the error LOCALLY
              ;; to distinguish "still waiting" vs "new error", but reusing the logic is fine.
              ;; However, we cleared *pending* at the start. So register-struct-definition will have repopulated it.
        )))

  (cl:when *pending-struct-definitions*
    (error "Could not resolve all struct definitions. cycles or unknown types detected: ~a"
      (mapcar #'first *pending-struct-definitions*))))

(defun parse-struct-member-spec (spec)
  "Parses a struct member specification.
   Supports (name type) and (name type :c-t [value])."
  (cl:cond
    ;; (name type)
    ((and (listp spec) (= (length spec) 2))
     spec)
    ;; (name type :c-t [value])
    ((and (listp spec) (>= (length spec) 3) (eq (third spec) :c-t))
     spec)
    (t (error "Invalid struct member spec: ~a" spec))))

(defun validate-and-reorder-struct-args (struct-name defined-members args)
  "Validates and reorders keyword arguments for a struct constructor macro."
  ;; 0. Identify Runtime vs Compile-Time members
  (cl:let* ((runtime-members (remove-if (lambda (m) (and (consp m) (eq (third m) :c-t))) defined-members))
            ;; Required CT members are those marked :c-t but have NO value (incomplete)
            (ct-required-members (remove-if-not (lambda (m) (and (consp m) (eq (third m) :c-t) (null (fourth m)))) defined-members))
            (processed-args (make-hash-table :test 'eq))
            (ordered-values '()))

    ;; 1. Parse into a hash table
    (cl:let ((ptr args))
      (loop while ptr do
              (cl:let ((key (first ptr))
                       (val (second ptr)))
                (cl:unless (keywordp key)
                  (error "Struct constructor for ~a requires keyword arguments. Found: ~s" struct-name key))
                (cl:unless (second ptr)
                  (error "Struct constructor for ~a has missing value for key: ~s" struct-name key))
                (cl:when (gethash key processed-args)
                  (error "Struct constructor for ~a has duplicate key: ~s" struct-name key))

                (setf (gethash key processed-args) val)
                (setf ptr (cddr ptr)))))

    ;; 2. Validate and Reorder Runtime Arguments (Construction Payload)
    (loop for (member-name member-type) in runtime-members do
            (cl:let* ((kw (intern (symbol-name member-name) :keyword))
                      (val (gethash kw processed-args)))
              (cl:unless val
                (error "Struct constructor for ~a missing required argument: ~s" struct-name kw))
              (push val ordered-values)))

    ;; 3. Validate Compile-Time Required Arguments (Validation Only, not part of runtime payload)
    (loop for member in ct-required-members do
            (cl:let* ((member-name (first member))
                      (kw (intern (symbol-name member-name) :keyword))
                      (val (gethash kw processed-args)))
              (cl:unless val
                (error "Struct constructor for ~a missing required compile-time argument: ~s" struct-name kw))))

    ;; 4. Check for unknown keys (against ALL members, including compile-time ones)
    (maphash (lambda (k v)
               (declare (ignore v))
               (cl:unless (find k defined-members :key (lambda (m) (intern (symbol-name (first m)) :keyword)))
                 (error "Struct constructor for ~a has unknown argument: ~s" struct-name k)))
             processed-args)

    (nreverse ordered-values)))
