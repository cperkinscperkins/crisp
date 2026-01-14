;;; src/type-checker.lisp
(in-package :crisp.compiler)

;;; =========================================================
;;; Semantic Type Checking & Promotion
;;; =========================================================

(defun get-promoted-type (type-a-name type-b-name)
  "Determines result type of binary operation with alias resolution."
  (cl:let ((type-a-name (resolve-type-alias type-a-name))
           (type-b-name (resolve-type-alias type-b-name)))
    (if (eq type-a-name type-b-name)
        type-a-name
        (let ((type-a (gethash type-a-name *crisp-types*))
              (type-b (gethash type-b-name *crisp-types*)))
          (cond
           ((or (null type-a) (null type-b)) nil)
           ((and (eq (crisp-type-category type-a) (crisp-type-category type-b))
                 (> (crisp-type-size type-b) (crisp-type-size type-a)))
             type-b-name)
           ((and (eq (crisp-type-category type-a) (crisp-type-category type-b))
                 (> (crisp-type-size type-a) (crisp-type-size type-b)))
             type-a-name)
           ((and (member (crisp-type-category type-a) '(:signed-int :unsigned-int))
                 (eq (crisp-type-category type-b) :float))
             type-b-name)
           ((and (member (crisp-type-category type-b) '(:signed-int :unsigned-int))
                 (eq (crisp-type-category type-a) :float))
             type-a-name)
           (t nil))))))

(defun types-compatible-p (arg-type param-type)
  "Checks if an argument type is compatible with a parameter type."
  (log:debug "COMPAT-CHECK: Arg ~s Param ~s" arg-type param-type)
  (or (types-equivalent-p arg-type param-type)
      ;; Keyword Literal -> Keyword Symbol
      ;; Value: (keyword :foo) or (:keyword :foo), Param: keyword
      (and (consp arg-type)
           (or (eq (first arg-type) 'keyword) (eq (first arg-type) :keyword))
           (or (eq param-type 'keyword) (eq param-type :keyword)
               (eq param-type 'common-lisp:keyword)))

      ;; KEYWORD Literal -> Enum Type
      ;; Value: (keyword :red), Param: color (where :red is in color)
      (and (consp arg-type)
           (or (eq (first arg-type) 'keyword) (eq (first arg-type) :keyword))
           (symbolp param-type)
           (let ((enum-def (gethash param-type *crisp-enums*))
                 (key (second arg-type)))
             (and enum-def
                  (assoc key (crisp.compiler::enumeration-def-members enum-def)))))

      ;; Incomplete/Composite Type compatibility:
      ;; 1. (PANTS :COLOR :RED) is compatible with PANTS
      (and (listp arg-type)
           (valid-type-p arg-type)
           (symbolp param-type)
           (eq (first arg-type) param-type))
      ;; 2. PANTS_COLOR_RED (symbol) is compatible with PANTS
      (and (symbolp arg-type)
           (symbolp param-type)
           (let ((unmangled (unmangle-template-struct-name arg-type)))
             (log:info "COMPAT: Unmangling ~s -> ~s. Param: ~s" arg-type unmangled param-type)
             (and (consp unmangled)
                  (eq (first unmangled) param-type))))

      (and (listp arg-type) (eq (first arg-type) :function-literal)
           (listp param-type) (eq (first param-type) :function-type)
           ;; Verify signature match
           (let* ((literal-name (second arg-type))
                  (expected-ret (second param-type))
                  (expected-params (getf (cddr param-type) :params))
                  (sigs (gethash literal-name *function-table*)))
             ;; Find ANY signature of literal-name that matches the expected type
             (some (lambda (sig)
                     (and (equal (function-signature-return-types sig) expected-ret)
                          (equal (mapcar #'parameter-def-type (function-signature-parameters sig)) expected-params)))
                 sigs)))))

(defun types-list-compatible-p (arg-types param-types)
  "Checks if a list of argument types is compatible with a list of parameter types."
  (and (= (length arg-types) (length param-types))
       (every #'types-compatible-p arg-types param-types)))

(defun resolve-best-signature (op explicit-arg-types)
  "Finds the best matching function signature for the given operator and argument types.
   Attempts template instantiation if no immediate match is found."
  (let ((signatures (gethash op *function-table*))
        (signature nil))

    (unless signatures
      (log:debug "DUMP KEYS: ~s" (loop for k being the hash-keys of *function-table*
                                         when (string-equal (symbol-name k) (symbol-name op))
                                       collect (format nil "~s (~a)" k (package-name (symbol-package k))))))
    (setf signature (find-if (lambda (sig)
                               (let ((match (types-list-compatible-p explicit-arg-types (mapcar #'parameter-def-type (function-signature-parameters sig)))))
                                 match))
                        signatures))

    (unless signature
      (log:debug "NO SIGNATURE FOUND IMMEDIATELY. TRYING INSTANTIATION.")

      ;; 1. Try Lazy Instantiation for &optional / &key
      (let ((generic-def (gethash op *generic-functions*)))
        (when generic-def
              (log:info "Found generic function ~a, attempting lazy instantiation..." op)
              (let ((new-sig (instantiate-generic-function generic-def explicit-arg-types nil ; location unavailable here
                                                          )))
                (when new-sig
                      (setf signature new-sig)))))

      ;; 2. Try Template Instantiator (C++ Style)
      (when (and (not signature) *template-instantiator-fn*)
            (loop repeat 3 until signature do
                    (if (funcall *template-instantiator-fn* op explicit-arg-types
                          (lambda (form location)
                            (compile-toplevel-form form location *current-module* *current-builder* *current-di-builder* *current-di-compile-unit* *current-location-map*)))
                        (progn
                         (setf signatures (gethash op *function-table*))
                         (setf signature (find-if (lambda (sig)
                                                    (types-list-compatible-p explicit-arg-types (mapcar #'parameter-def-type (function-signature-parameters sig))))
                                             signatures)))
                        (cl:return)))))

    (unless signature
      (error "No matching function overload found for '~a' with argument types ~a." op explicit-arg-types))

    signature))
