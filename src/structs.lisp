;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.

(in-package :crisp.compiler)

;; Std140 Layout (GPU Alignment)
;; =============================

(defun get-std140-base-alignment (type-spec)
  "Returns the base alignment (N) for a given type according to std140 rules.
  For scalars, N is the size of the scalar.
  For vectors, it is 2N or 4N.
  For arrays/structs, it is rounded up to vec4 alignment (16)."
  ;; Resolve type aliases first
  (cl:let ((resolved-type (if (and (symbolp type-spec) (gethash type-spec *crisp-type-aliases*))
                              (loop for name = type-spec then (gethash name *crisp-type-aliases*)
                                    while (and (symbolp name) (gethash name *crisp-type-aliases*))
                                    finally (cl:return name))
                              type-spec)))
    (cl:cond
      ((or (eq resolved-type 'float) (eq resolved-type 'int) (eq resolved-type 'uint)) 4)
      ((or (eq resolved-type 'double) (eq resolved-type 'long) (eq resolved-type 'ulong)) 8)
      ((or (eq resolved-type 'char) (eq resolved-type 'uchar)) 1)
      ((or (eq resolved-type 'short) (eq resolved-type 'ushort) (eq resolved-type 'half) (eq resolved-type 'bfloat16)) 2)
      ;; TODO: Handle vectors here (will need vector support first)
      ((or (eq resolved-type 'bool)) 4) ;; booleans are 4 bytes in std140
      ((eq type-spec 'c-pointer) 8) ;; c-pointer is 8 bytes
      ((and (consp type-spec) (eq (first type-spec) 'c-pointer)) 8)
      ;; Cells are pointers (8 bytes) - Check mangled name
      ((and (symbolp type-spec)
            (> (length (symbol-name type-spec)) 5)
            (string-equal (subseq (symbol-name type-spec) 0 5) "CELL_"))
       8)
      ;; Structs align to 16 bytes (vec4)
      ((gethash type-spec *crisp-structs*) 16)
      ;; Parameterized Structs (e.g. (POINT INT))
      ((and (consp type-spec) (valid-type-p type-spec))
       (cl:let ((base (first type-spec)))
         (cl:cond
           ;; Cells are pointers (8 bytes aligned to 8)
           ((string-equal (symbol-name base) "CELL") 8)
           (t
            (cl:let ((mangled (mangle-template-struct-name (first type-spec) (rest type-spec))))
              (if (gethash mangled *crisp-structs*)
                  16
                  (error "Valid type ~a but struct def not found after check alignment." type-spec)))))))
      (t
       (error "Unknown type for alignment: ~a" type-spec)))))


(defun get-std140-size (type-spec)
  "Returns the size (in bytes) of a type. Does not include padding for alignment context."
  ;; Resolve type aliases first
  (cl:let ((resolved-type (if (and (symbolp type-spec) (gethash type-spec *crisp-type-aliases*))
                              (loop for name = type-spec then (gethash name *crisp-type-aliases*)
                                    while (and (symbolp name) (gethash name *crisp-type-aliases*))
                                    finally (cl:return name))
                              type-spec)))
    (cl:cond
      ((or (eq resolved-type 'float) (eq resolved-type 'int) (eq resolved-type 'uint)) 4)
      ((or (eq resolved-type 'double) (eq resolved-type 'long) (eq resolved-type 'ulong)) 8)
      ((or (eq resolved-type 'char) (eq resolved-type 'uchar)) 1)
      ((or (eq resolved-type 'short) (eq resolved-type 'ushort) (eq resolved-type 'half) (eq resolved-type 'bfloat16)) 2)
      ((eq resolved-type 'bool) 4)
      ((eq resolved-type 'c-pointer) 8) ;; c-pointer is 8 bytes
      ((and (consp type-spec) (eq (first type-spec) 'c-pointer)) 8)
      ;; Cells are pointers (8 bytes) - Check mangled name
      ((and (symbolp type-spec)
            (> (length (symbol-name type-spec)) 5)
            (string-equal (subseq (symbol-name type-spec) 0 5) "CELL_"))
       8)
      ;; Structs - Retrieve cached size
      ((gethash type-spec *crisp-structs*)
       (crisp-struct-definition-total-size (gethash type-spec *crisp-structs*)))
      ;; Parameterized Structs
      ((and (consp type-spec) (valid-type-p type-spec))
       (cl:let ((base (first type-spec)))
         (cl:cond
           ;; Cells are pointers (8 bytes)
           ((string-equal (symbol-name base) "CELL") 8)
           (t
            (cl:let ((mangled (mangle-template-struct-name (first type-spec) (rest type-spec))))
              (if (gethash mangled *crisp-structs*)
                  (crisp-struct-definition-total-size (gethash mangled *crisp-structs*))
                  (error "Valid type ~a but struct def not found after check size." type-spec)))))))
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
                (alignment (get-std140-base-alignment type))
                (size (get-std140-size type))
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
                (size (get-std140-size type)))
        (push member expanded-members)
        (incf current-offset size)))

    (values (nreverse expanded-members) current-offset)))

(defun register-struct-definition (name members &optional (category :struct))
  "Registers a struct or record definition in the global registry."
  (cl:let ((name (if (consp name)
                     (crisp.compiler::mangle-template-struct-name (first name) (rest name))
                     name)))
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

        ;; Register as a valid Crisp type for type checking
        (setf (gethash name *crisp-types*)
          (make-crisp-type
           :name name
           :llvm-type-fn (lambda () (ensure-struct-llvm-type name))
           :size (* total-size 8)
           :category category))))))

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
