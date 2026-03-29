;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;;; ============================================================
;;; Phase 1: (array T N) type system support
;;; ============================================================

;;; src/types/validation.lisp
(defun %array-type-p (type-spec)
  "Returns T if TYPE-SPEC is a list form whose head is the symbol ARRAY.
   Used throughout the array implementation to identify (array T N) type specs."
  (and (consp type-spec)
       (symbolp (cl:first type-spec))
       (string-equal (symbol-name (cl:first type-spec)) "ARRAY")))

;;; src/types/validation.lisp
(defun valid-parameterized-type-p (type-spec)
  "Checks if type-spec is a valid parameterized type (cell, templates, array, etc).
   Extended to recognise (array T N) where T is a valid non-array basic type
   and N is a positive integer.  Nested arrays signal a crisp-compiler-error."
  (cl:when (consp type-spec)
    (cl:let* ((expanded (canonicalize-type-specifier type-spec))
              (base-type (cl:first expanded))
              (params (cl:rest expanded)))
      (cl:cond
        ;; Base type must be a symbol
        ((not (symbolp base-type)) nil)

        ;; Exclude special forms (FUNCTION, QUOTE, etc.)
        ((excluded-template-base-type-p base-type) nil)

        ;; (array T N) — compile-time fixed array type
        ((%array-type-p expanded)
         (cl:let ((elem-type (cl:first params))
                  (count     (cl:second params)))
           ;; Nesting is illegal — signal a named error so CHECK-FAIL: "nested" matches
           (cl:when (%array-type-p elem-type)
             (error 'crisp-compiler-error
                    :message (format nil "Array type cannot be nested: ~s is illegal. Use def-struct or a cell instead."
                                     type-spec)))
           ;; Validate: exactly 2 args, valid non-array element type, positive integer count
           (and (= (cl:length params) 2)
                (valid-basic-type-p elem-type)
                (integerp count)
                (> count 0))))

        ;; Handle valid struct/type with optional keyword properties
        ((and (or (gethash base-type *crisp-structs*)
                  (gethash base-type *crisp-types*))
              (or (null params)
                  (keywordp (cl:first params))))
         t)

        ;; Standard template instantiation
        ((symbolp base-type)
         (%validate-template-instantiation base-type params))

        (t nil)))))

;;; src/types/validation.lisp
(defun resolve-type-to-llvm (type-spec)
  "Resolves a Crisp type specifier to an LLVM type reference.
   Extended to handle (array T N) → LLVM [N x T_llvm]."
  (cl:let ((*resolve-depth* (1+ *resolve-depth*)))
    (cl:when (> *resolve-depth* 50)
      (cl:error "Infinite recursion detected in resolve-type-to-llvm for ~s" type-spec))

    (cl:cond
      ;; (array T N) → [N x T_llvm]
      ((%array-type-p type-spec)
       (cl:let ((elem-type (cl:second type-spec))
                (count     (cl:third type-spec)))
         (log:info "resolve-type-to-llvm: (array ~a ~a) -> [~a x ...]" elem-type count count)
         ;; llvm-array-type not yet exported from package.lisp — use :: until patched
         (crisp.llvm-bindings::llvm-array-type (resolve-type-to-llvm elem-type) count)))

      ;; Derived Type - resolve to base type (MUST come before *crisp-types* check)
      ((cl:and (cl:symbolp type-spec)
         (cl:let* ((node-direct (cl:gethash type-spec *type-derivation-graph*))
                   (node-alt (cl:when (not node-direct)
                               (cl:gethash (cl:intern (cl:symbol-name type-spec)
                                                      (cl:find-package :crisp-language))
                                           *type-derivation-graph*)))
                   (node (or node-direct node-alt)))
           (and node (type-node-original-type node))))
       (cl:let* ((node-direct (cl:gethash type-spec *type-derivation-graph*))
                 (node-alt (cl:when (not node-direct)
                             (cl:gethash (cl:intern (cl:symbol-name type-spec)
                                                    (cl:find-package :crisp-language))
                                         *type-derivation-graph*)))
                 (actual-type (if node-direct type-spec
                                  (cl:intern (cl:symbol-name type-spec)
                                             (cl:find-package :crisp-language))))
                 (base-type (get-type-base actual-type)))
         (resolve-type-to-llvm base-type)))

      ;; Built-in Scalar
      ((cl:and (cl:symbolp type-spec) (cl:gethash type-spec *crisp-types*))
       (cl:funcall (crisp-type-llvm-type-fn (cl:gethash type-spec *crisp-types*))))

      ;; Type Alias (Symbol)
      ((cl:and (cl:symbolp type-spec) (cl:gethash type-spec *crisp-type-aliases*))
       (resolve-type-to-llvm (cl:gethash type-spec *crisp-type-aliases*)))

      ;; C-Pointer with properties: e.g. (c-pointer :address-space :global)
      ((cl:and (cl:consp type-spec) (cl:eq (cl:first type-spec) 'c-pointer))
       (cl:let* ((args (cl:rest type-spec))
                 (as-key (cl:getf args :address-space))
                 (as-val (encode-address-space as-key)))
         (llvm-pointer-type (llvm-int8-type) as-val)))

      ;; Struct (Pre-existing)
      ((cl:and (cl:symbolp type-spec) (find-struct-definition-by-name type-spec))
       (ensure-struct-llvm-type type-spec))

      ;; Enumerations (map to i32)
      ((cl:and (cl:symbolp type-spec) (cl:gethash type-spec *crisp-enums*))
       (llvm-int32-type))

      ;; Keyword/Symbol/Quote (map to i32)
      ((cl:or (cl:member type-spec '(keyword symbol quote))
         (cl:and (cl:consp type-spec) (cl:member (cl:first type-spec) '(keyword symbol quote))))
       (llvm-int32-type))

      ;; Parameterized Structs (On-Demand Instantiation) OR Mangled Symbols
      ((cl:or (cl:and (cl:consp type-spec)
                (valid-type-p type-spec)
                (find-template-robust (cl:first type-spec)))
         (cl:and (cl:symbolp type-spec)
           (cl:let ((parts (unmangle-template-struct-name type-spec)))
             (cl:and parts (cl:consp parts) (find-template-robust (cl:first parts))))))
       (cl:let* ((canonical (canonicalize-type-specifier type-spec))
                 (is-cons (cl:consp canonical))
                 (unmangled (cl:if is-cons canonical (unmangle-template-struct-name canonical)))
                 (base (cl:first unmangled))
                 (raw-args (cl:rest unmangled))
                 (mangled (mangle-template-struct-name base raw-args)))
         (cl:unless (find-struct-definition-by-name mangled)
           (cl:let ((crisp.compiler::*defer-struct-validation* nil))
             (ensure-template-instantiation base raw-args
                                            (cl:lambda (form location)
                                              (cl:eval form)
                                              (cl:when (cl:and (boundp '*current-module*) *current-module*)
                                                (compile-toplevel-form form location
                                                                       *current-module*
                                                                       *current-builder*
                                                                       *current-di-builder*
                                                                       *current-di-compile-unit*
                                                                       *current-location-map*))))))
         (cl:unless (find-struct-definition-by-name mangled)
           (cl:error "Type Resolution: FAILED to instantiate struct ~a" mangled))
         (resolve-type-to-llvm mangled)))

      ;; Generic List Wrapper
      ((cl:consp type-spec)
       (resolve-type-to-llvm (cl:first type-spec)))

      (t
       (cl:let ((alias-match (cl:loop for k being the hash-keys of *crisp-type-aliases*
                               when (cl:string-equal (cl:symbol-name k) (cl:symbol-name type-spec))
                               return k)))
         (cl:if alias-match
                (resolve-type-to-llvm (cl:gethash alias-match *crisp-type-aliases*))
                (cl:error "Cannot resolve type to LLVM: ~a" type-spec)))))))
