;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;; ---------------------------------------------------------------------------

(in-package :crisp.compiler)

;;; --- START PATCHES ---

;; src/types.lisp - Bug 012: Type alias resolution helper
(defun resolve-type-alias (type-spec)
  "Fully resolves a type alias chain with cycle detection."
  (if (and (symbolp type-spec)
           (boundp '*crisp-type-aliases*)
           (gethash type-spec *crisp-type-aliases*))
      (cl:let ((seen (make-hash-table :test 'eq)))
        (loop for name = type-spec then (gethash name *crisp-type-aliases*)
              while (and (symbolp name)
                         (gethash name *crisp-type-aliases*)
                         (not (gethash name seen)))
              do (setf (gethash name seen) t)
              finally (cl:return name)))
      type-spec))

;; src/type-checker.lisp - Bug 012: get-promoted-type with alias resolution  
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

;; src/types.lisp - Bug 012: types-equivalent-p with alias resolution
(defun types-equivalent-p (t1 t2)
  "Checks if two types are equivalent, with alias resolution and template handling."
  ;; Resolve aliases FIRST, then run all other checks on resolved types
  (cl:let ((t1 (resolve-type-alias t1))
           (t2 (resolve-type-alias t2)))
    (cl:cond
      ((or (equal t1 t2)
           (and (symbolp t1) (symbolp t2) (string-equal (symbol-name t1) (symbol-name t2))))
       t)
      ;; Treat VOID and NIL as equivalent return types
      ((or (and (symbolp t1) (string-equal t1 "VOID") (null t2))
           (and (null t1) (symbolp t2) (string-equal t2 "VOID")))
       t)
      ;; Handle parameterized struct (POINT FLOAT) vs mangled name POINT_FLOAT
      ((and (consp t1) (symbolp t2))
       (let* ((expanded (if (member (symbol-name (cl:first t1)) '("CELL") :test #'string-equal)
                            (canonicalize-type-specifier t1)
                            t1))
              (base-type (cl:first expanded))
              (params (rest expanded)))
         (if (and (symbolp base-type)
                  (not (excluded-template-base-type-p base-type)))
             (progn
              (cl:when (gethash base-type *template-registry*)
                (cl:let ((instantiated-form
                          (funcall *template-instantiator-fn* base-type params
                            (lambda (form location)
                              (if (boundp '*current-module*)
                                  (compile-toplevel-form form location
                                                         *current-module*
                                                         *current-builder*
                                                         *current-di-builder*
                                                         *current-di-compile-unit*
                                                         *current-location-map*)
                                  (eval form))))))
                  instantiated-form
                  t))
              (cl:let ((mangled (mangle-template-struct-name base-type params)))
                (cl:cond
                  ((eq mangled t2) t)
                  ((string-equal (symbol-name mangled) (symbol-name t2)) t)
                  (t nil))))
             nil)))
      ((and (symbolp t1) (consp t2))
       (types-equivalent-p t2 t1))
      ;; Parameterized struct vs parameterized struct
      ((and (cl:consp t1) (cl:consp t2))
       (cl:let ((e1 (cl:if (cl:member (cl:symbol-name (cl:first t1)) '("CELL") :test #'cl:string-equal)
                           (canonicalize-type-specifier t1)
                           t1))
                (e2 (cl:if (cl:member (cl:symbol-name (cl:first t2)) '("CELL") :test #'cl:string-equal)
                           (canonicalize-type-specifier t2)
                           t2)))
         (cl:equal e1 e2)))
      ;; Keyword vs Enum
      ((and (or (member t1 '(keyword :keyword symbol common-lisp:symbol))
                (and (symbolp t1) (member (symbol-name t1) '("KEYWORD" "SYMBOL") :test #'string-equal)))
            (gethash t2 *crisp-enums*)) t)
      ((and (or (member t2 '(keyword :keyword symbol common-lisp:symbol))
                (and (symbolp t2) (member (symbol-name t2) '("KEYWORD" "SYMBOL") :test #'string-equal)))
            (gethash t1 *crisp-enums*)) t)
      ;; Handle mismatched wrapping (e.g. (INT) vs INT)
      ((and (consp t1) (= (length t1) 1) (valid-type-p (cl:first t1)) (types-equivalent-p (cl:first t1) t2)) t)
      ((and (consp t2) (= (length t2) 1) (valid-type-p (cl:first t2)) (types-equivalent-p t1 (cl:first t2))) t)
      (t nil))))
;; src/codegen.lisp - Bug 012: build-cast-if-needed with alias resolution
(defun build-cast-if-needed (builder from-val from-type-name to-type-name)
  "Builds LLVM cast instruction if types differ, with alias resolution."
  ;; Resolve aliases first
  (cl:let ((from-type-name (resolve-type-alias from-type-name))
           (to-type-name (resolve-type-alias to-type-name)))
    (if (equal from-type-name to-type-name)
        (progn
         (log:debug "build-cast-if-needed: No cast needed for ~s" from-type-name)
         from-val)
        (let* ((from-type (if (symbolp from-type-name) (gethash from-type-name *crisp-types*) nil))
               (to-type (if (symbolp to-type-name) (gethash to-type-name *crisp-types*) nil))
               (to-llvm-type (resolve-type-to-llvm to-type-name))
               (from-cat (get-type-cat-safe from-type-name from-type))
               (to-cat (get-type-cat-safe to-type-name to-type)))
          (log:debug "build-cast-if-needed: Casting from ~s to ~s" from-type-name to-type-name)
          (cond
           ((and (member from-cat (quote (:signed-int :unsigned-int)))
                 (eq to-cat (quote :float)))
             (if (eq from-cat (quote :signed-int))
                 (llvm-build-si-to-fp builder from-val to-llvm-type "si2fp_cast")
                 (llvm-build-ui-to-fp builder from-val to-llvm-type "ui2fp_cast")))
           ((and (member from-cat (quote (:signed-int :unsigned-int)))
                 (member to-cat (quote (:signed-int :unsigned-int))))
             (let ((from-size (crisp-type-size from-type))
                   (to-size (crisp-type-size to-type)))
               (cond
                ((< to-size from-size)
                  (llvm-build-trunc builder from-val to-llvm-type "trunc_cast"))
                ((> to-size from-size)
                  (if (eq from-cat (quote :signed-int))
                      (llvm-build-sext builder from-val to-llvm-type "sext_cast")
                      (llvm-build-zext builder from-val to-llvm-type "zext_cast")))
                (t from-val))))
           ((and (eq from-cat (quote :float)) (eq to-cat (quote :float)))
             (let ((from-size (crisp-type-size from-type))
                   (to-size (crisp-type-size to-type)))
               (cond
                ((< to-size from-size)
                  (llvm-build-fp-trunc builder from-val to-llvm-type "fptrunc_cast"))
                ((> to-size from-size)
                  (llvm-build-fp-ext builder from-val to-llvm-type "fpext_cast"))
                (t from-val))))
           ((and (eq from-cat (quote :float)) (member to-cat (quote (:signed-int :unsigned-int))))
             (if (eq to-cat (quote :signed-int))
                 (llvm-build-fp-to-si builder from-val to-llvm-type "fp2si_cast")
                 (llvm-build-fp-to-ui builder from-val to-llvm-type "fp2ui_cast")))
           ((and (member from-cat (quote (:signed-int :unsigned-int)))
                 (eq to-cat (quote :pointer)))
             (llvm-build-int-to-ptr builder from-val to-llvm-type "int2ptr_cast"))
           ((and (eq from-cat (quote :pointer))
                 (member to-cat (quote (:signed-int :unsigned-int))))
             (llvm-build-ptr-to-int builder from-val to-llvm-type "ptr2int_cast"))
           ((and (eq from-cat (quote :pointer))
                 (eq to-cat (quote :pointer)))
             (let ((from-as (llvm-get-pointer-address-space (llvm-type-of from-val)))
                   (to-as (llvm-get-pointer-address-space to-llvm-type)))
               (if (= from-as to-as)
                   (llvm-build-bit-cast builder from-val to-llvm-type "ptr2ptr_cast")
                   (llvm-build-addrspace-cast builder from-val to-llvm-type "ptr2ptr_ascast"))))
           (t
             (log:error "CODEGEN CAST ERROR: ~a -> ~a" from-type-name to-type-name)
             (log:error "  From Type: ~a (cat: ~a)" from-type from-cat)
             (log:error "  To Type:   ~a (cat: ~a)" to-type to-cat)
             (log:error "  Value dump: ~a" (llvm-print-value-to-string from-val))
             (error "Unsupported value cast from ~a to ~a" from-type-name to-type-name)))))))
