;;; Fix for Bug 013: Recursive def-type hangs
;;; v8: Added fix for parse-type-specifier in environment.lisp

(in-package :crisp.compiler)

;; Ensure helper is present
(defun resolve-type-alias (type-spec)
  "Fully resolves a type alias chain, returning the underlying type.
   Includes cycle detection to prevent infinite loops."

  ;; DEBUG LOGGING
  ;; (format *error-output* "[resolve-type-alias] Checking: ~a~%" type-spec)

  (if (and (symbolp type-spec)
           (boundp '*crisp-type-aliases*)
           (gethash type-spec *crisp-type-aliases*))
      ;; It's an alias - resolve with cycle detection
      (cl:let ((seen (make-hash-table :test 'eq)))
        (loop for name = type-spec then (gethash name *crisp-type-aliases*)
              while (and (symbolp name)
                         (gethash name *crisp-type-aliases*)
                         (not (gethash name seen)))
              do
                ;; (format *error-output* "[resolve-type-alias] Resolving loop: ~a -> ~a~%" name (gethash name *crisp-type-aliases*))
                (setf (gethash name seen) t)
              finally
                (if (gethash name seen)
                    (progn
                     (format *error-output* "[resolve-type-alias] CYCLE DETECTED for ~a. Stopping.~%" name)
                     (cl:return name))
                    (cl:return name))))
      ;; Not an alias - return as-is
      type-spec))

;; FIX: %resolve-alias-strict in macros.lisp
(defun %resolve-alias-strict (spec)
  (%resolve-alias-strict-checked spec nil))

(defun %resolve-alias-strict-checked (spec seen)
  (if (member spec seen :test #'equal)
      (progn
       (format *error-output* "[resolve-alias-strict] Cycle detected for ~a. Stopping.~%" spec)
       spec)
      (let ((base (if (consp spec) (first spec) spec))
            (args (if (consp spec) (rest spec) nil))
            (new-seen (cons spec seen)))
        (if (symbolp base)
            (let ((alias-def (gethash base *crisp-template-aliases*)))
              (if alias-def
                  (let ((params (car alias-def))
                        (type-spec (cdr alias-def)))
                    (if params
                        (let* ((arity (length params))
                               (required-args (subseq args 0 (min (length args) arity)))
                               (rest-args (subseq args (length required-args)))
                               (substitutions (pairlis params required-args)))
                          (let ((expanded (sublis substitutions type-spec)))
                            (if (and rest-args (consp expanded))
                                (%resolve-alias-strict-checked (append expanded rest-args) new-seen)
                                (%resolve-alias-strict-checked expanded new-seen))))
                        (if args
                            (%resolve-alias-strict-checked (append (if (consp type-spec) type-spec (list type-spec)) args) new-seen)
                            (%resolve-alias-strict-checked type-spec new-seen))))
                  (let ((simple (gethash base *crisp-type-aliases*)))
                    (if simple
                        (%resolve-alias-strict-checked simple new-seen)
                        spec))))
            spec))))


;; FROM: src/types.lisp
;; Fix for Bug 013: canonicalize-type-specifier infinite loop
(defun canonicalize-type-specifier (spec)
  "Canonicalizes type specifiers."

  ;; DEBUG LOGGING
  ;; (when (symbolp spec) (format *error-output* "[canonicalize] Processing symbol: ~a~%" spec))

  ;; First, apply storage handle expansion
  (cl:when (consp spec)
    (setf spec (expand-storage-handle-type-specifier spec)))

  (cl:let ((base (if (consp spec) (cl:first spec) spec))
           (args (if (consp spec) (rest spec) nil)))
    (cl:cond
      ((symbolp base)
       ;; 1. Check Template Aliases (def-type)
       (cl:let ((alias-def (gethash base *crisp-template-aliases*)))
         (cl:if alias-def
                (cl:let ((params (car alias-def))
                         (type-spec (cdr alias-def)))
                  ;; Instantiate the alias
                  (cl:if params
                         (cl:let* ((arity (length params))
                                   (required-args (subseq args 0 (min (length args) arity)))
                                   (rest-args (subseq args (length required-args)))
                                   (substitutions (pairlis params required-args)))
                           ;; Apply substitution to the base spec
                           (cl:let ((expanded-base (sublis substitutions type-spec)))
                             ;; Append any extra args (overrides) to the result if it's a list
                             (cl:if (and rest-args (consp expanded-base))
                                    (canonicalize-type-specifier (append expanded-base rest-args))
                                    (canonicalize-type-specifier expanded-base))))
                         ;; No params? Just return the aliased type + args??
                         ;; If alias had no params, but we passed args, they are overrides.
                         (cl:if args
                                (canonicalize-type-specifier (append (if (consp type-spec) type-spec (list type-spec)) args))

                                ;; FIX: Use resolve-type-alias cycle detection here! 
                                (let ((resolved (resolve-type-alias base)))
                                  (if (equal resolved base)
                                      ;; Cycle detected (A->A), return base as canonical 
                                      (progn
                                       (format *error-output* "[canonicalize-type-specifier] Alias Cycle detected for ~a, returning base.~%" base)
                                       (list base))
                                      ;; Recurse safely
                                      (canonicalize-type-specifier resolved))))))

                ;; 2. Standard Templates
                (cl:let* ((template-data (first (gethash base *template-registry*)))
                          (params (and template-data (template-data-parameters template-data))))
                  (cl:if params
                         (cl:let ((full-args (cl:loop for param in params
                                             for i from 0
                                             for arg = (nth i args)
                                             collect (cl:if arg
                                                            arg
                                                            ;; Check for default value in param spec (Name Default)
                                                            (cl:if (and (consp param) (second param))
                                                                   (second param)
                                                                   nil)))))
                           (cons base (remove-if #'null full-args)))

                         ;; Not a template, return as is (normalized to list)
                         (cl:if (consp spec) spec (list spec)))))))
      ((consp spec) spec)
      (t (list spec)))))

(defun valid-parameterized-type-p (type-spec)
  "Checks if type-spec is a valid parameterized type (cell, templates, etc)."
  (cl:when (consp type-spec)
    (cl:let* ((expanded (canonicalize-type-specifier type-spec))
              (base-type (cl:first expanded))
              (params (rest expanded)))
      (cl:cond
        ((not (symbolp base-type)) nil)
        ((excluded-template-base-type-p base-type) nil)

        ;; 0. Check if base-type identifies a valid type/struct itself.
        ((and (or (gethash base-type *crisp-structs*)
                  (gethash base-type *crisp-types*))
              (or (null params) ;; (INT) is valid (wrapper)
                  (keywordp (first params)))) ;; (INT :BITS 32) is valid. (INT INT) is NOT.
                                             t)

        ;; Standard Template Instantiation
        ((symbolp base-type)
         (cl:let* ((template-args params)
                   (mangled-name (mangle-template-struct-name base-type template-args)))
           (or (gethash mangled-name *crisp-structs*)
               (cl:let ((templates (or (gethash base-type *template-registry*)
                                       (cl:let ((found nil))
                                         (maphash (cl:lambda (k v)
                                                    (cl:when (and (symbolp k) (string-equal (symbol-name k) (symbol-name base-type)))
                                                      (cl:setf found v)))
                                                  *template-registry*)
                                         found))))
                 (cl:when templates
                   (if (and (boundp '*template-instantiator-fn*) *template-instantiator-fn*)
                       (progn
                        (funcall *template-instantiator-fn* base-type template-args
                          (lambda (form loc)
                            (declare (ignore loc))
                            (if (and (boundp '*current-module*) *current-module*)
                                (compile-toplevel-form form nil
                                                       *current-module*
                                                       *current-builder*
                                                       *current-di-builder*
                                                       *current-di-compile-unit*
                                                       *current-location-map*)
                                (eval form))))
                        (cl:let ((res (gethash mangled-name *crisp-structs*)))
                          t)) ;; Always return T if template found/instantiated
                       (progn (log:warn "Template instantiator not bound/found") nil)))))))
        (t nil)))))

(defun valid-type-p (type-spec)
  "Checks if a type specifier is valid.
   Handles simple types, parameterized types, and function literals/types."
  (or (valid-basic-type-p type-spec)
      (valid-function-type-p type-spec)
      (valid-parameterized-type-p type-spec)
      ;; Check aliases
      (and (symbolp type-spec) (gethash type-spec *crisp-type-aliases*))
      (and (listp type-spec)
           (symbolp (first type-spec))
           (or (gethash (first type-spec) *crisp-type-aliases*)
               (gethash (first type-spec) *crisp-template-aliases*)))))

;; FROM: src/structs.lisp
(defun get-std140-base-alignment (type-spec)
  "Returns the base alignment (N) for a given type according to std140 rules.
   For scalars, N is the size of the scalar.
   For vectors, it is 2N or 4N.
   For arrays/structs, it is rounded up to vec4 alignment (16)."
  ;; Resolve type aliases first with cycle detection
  (cl:let ((resolved-type (resolve-type-alias type-spec)))
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


;; FROM: src/structs.lisp
(defun get-std140-size (type-spec)
  "Returns the size (in bytes) of a type. Does not include padding for alignment context."
  ;; Resolve type aliases first with cycle detection
  (cl:let ((resolved-type (resolve-type-alias type-spec)))
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
      ;; Structs
      ((gethash type-spec *crisp-structs*)
       (crisp-struct-definition-total-size (gethash type-spec *crisp-structs*))) ;; CORRECTED: Use struct accessor!
      ;; Parameterized Structs
      ((and (consp type-spec) (valid-type-p type-spec))
       (cl:let ((base (first type-spec)))
         (cl:cond
           ((string-equal (symbol-name base) "CELL") 8)
           (t
            (cl:let ((mangled (mangle-template-struct-name (first type-spec) (rest type-spec))))
              (cl:let ((struct-info (gethash mangled *crisp-structs*)))
                (if struct-info
                    (crisp-struct-definition-total-size struct-info) ;; CORRECTED: Use struct accessor!
                    (error "Valid type ~a but struct def not found after check size." type-spec))))))))
      (t
       (error "Unknown type for size: ~a" type-spec)))))


;; Redefine compute-std140-layout to force usage of new get-std140-size
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

;; Redefine compute-record-layout to force usage of new get-std140-size
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

;; FIX: parse-type-specifier in environment.lisp
(defun parse-type-specifier (spec)
  "Parses a single type specifier, handling basic types, parameterized types,
   and function types like #'(int => int)."
  (cond
   ;; 0. Type Aliases -- FIX: Use resolve-type-alias for cycle detection
   ((and (symbolp spec) (gethash spec *crisp-type-aliases*))
     (let ((resolved (resolve-type-alias spec)))
       (cond
        ((equal resolved spec)
          ;; Cycle detected or identity.
          ;; Don't recurse. Check validity.
          (if (valid-type-p spec)
              spec
              (error 'crisp-unknown-type-error :type-name spec)))
        (t
          (log:info "PARSE: Resolving Alias ~a -> ~a" spec resolved)
          (parse-type-specifier resolved)))))

   ;; 0.1 Template Aliases (e.g. (in-cell int))
   ((and (listp spec) (symbolp (first spec)) (gethash (first spec) *crisp-template-aliases*))
     (let* ((alias-name (first spec))
            (args (rest spec))
            (alias-def (gethash alias-name *crisp-template-aliases*))
            (params (car alias-def))
            (body-spec (cdr alias-def))
            (arity (length params))
            (required-args (subseq args 0 (min (length args) arity)))
            (rest-args (subseq args (length required-args)))
            (substitutions (pairlis params required-args)))
       (let ((expanded (sublis substitutions body-spec)))
         (let ((final-spec (if (and rest-args (consp expanded))
                               (append expanded rest-args)
                               (if rest-args ;; Fix if expanded is atom but more args exist
                                   (cons expanded rest-args)
                                   expanded))))
           (parse-type-specifier final-spec)))))

   ;; 0.2 Simple Alias as List Head (e.g. (int-cell :access :read-only))
   ((and (listp spec) (symbolp (first spec)) (gethash (first spec) *crisp-type-aliases*))
     (let* ((alias-name (first spec))
            (args (rest spec))
            (expanded-base (gethash alias-name *crisp-type-aliases*)))
       ;; If alias expands to a list, append args. If symbol, make a new list.
       (let ((final-spec (if (listp expanded-base)
                             (append expanded-base args)
                             (cons expanded-base args))))
         (log:info "EXPAND-ALIAS-HEAD: ~a -> ~a" spec final-spec)
         (parse-type-specifier final-spec))))

   ;; Standard symbol: e.g. 'int'
   ((and (symbolp spec) (valid-type-p spec)) spec)

   ;; Storage Handle Symbols (e.g. CELL, VECTOR...) 
   ((and (symbolp spec) (member (symbol-name spec) '("CELL" "VECTOR" "MATRIX" "TENSOR") :test #'string-equal))
     (log:info "PARSE: Promoting symbol ~a to list (~a)" spec spec)
     (parse-type-specifier (list spec)))

   ;; Function Type: #'(int => int)
   ((and (listp spec) (member (first spec) '(function common-lisp:function)))
     (let* ((sig (if (listp (second spec)) (second spec) (rest spec))))
       `(:function-type ,(analyze-return-type-from-spec sig)
                        :params ,(mapcar #'parse-type-specifier
                                   (subseq sig 0 (position '=> sig))))))

   ;; Storage Handle Constructor Rules
   ((and (listp spec) (member (symbol-name (first spec)) '("CELL" "VECTOR" "MATRIX" "TENSOR") :test #'string-equal))
     (log:info "PARSE: Calling expand for ~s" spec)
     (let ((canonical (expand-storage-handle-type-specifier spec)))
       (if (valid-type-p canonical)
           (let ((base (first canonical))
                 (params (rest canonical)))
             (let ((resolved-params (mapcar (lambda (p) (if (valid-type-p p) (parse-type-specifier p) p)) params)))
               (mangle-template-struct-name base resolved-params)))
           (error 'crisp-unknown-type-error :type-name spec))))

   ;; Function Type/Literal
   ((and (listp spec) (valid-function-type-p spec)) spec)

   ;; Generic Parameterized Type: e.g. '(point float)
   ((and (listp spec) (valid-type-p spec))
     (log:info "PARSE: Generic path for ~s" spec)
     (let* ((base (first spec))
            (params (rest spec))
            (arity (get-template-arity base)))
       (let ((resolved-params (mapcar (lambda (p) (if (valid-type-p p) (parse-type-specifier p) p)) params)))
         (if (and arity (> arity 0))
             (mangle-template-struct-name base resolved-params)
             (if resolved-params
                 (cons base resolved-params)
                 base)))))

   ;; Unknown?
   (t
     (log:error "PARSE: Unknown type spec: ~s" spec)
     (error 'crisp-unknown-type-error :type-name spec))))
