;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;;; ============================================================
;;; Template instantiation fix: is-compiling detection
;;; ============================================================

;; src/templates.lisp
;; BUG: ensure-template-instantiation uses (boundp 'crisp.compiler::*current-module*)
;; to decide whether a template is being compiled or just analyzed.
;; *current-module* is a symbol-macro (define-symbol-macro), NOT a defvar, so
;; (boundp ...) always returns NIL -- making is-compiling permanently NIL.
;; Consequence: during Pass 2's pre-pass, %should-instantiate-template returns NIL
;; for :analyzed templates (because is-compiling=NIL), so their bodies are never
;; compiled into the module -- they stay as LLVM 'declare' instead of 'define'.
;; FIX: check *compiler-session* (which IS a defvar) and its module slot directly.
(defun ensure-template-instantiation (name explicit-arg-types compiler-callback)
  "Called by the compiler to auto-instantiate templates.
   compiler-callback is (lambda (form location) ...).
   Fixed: is-compiling now uses *compiler-session* instead of boundp on symbol-macro."
  (let* ((templates (gethash name *template-registry*))
         (struct-name (%resolve-template-name name))
         (templates (or templates (when struct-name (gethash struct-name *template-registry*))))
         (match-sets nil))

    (setf match-sets (try-infer-template-types (or struct-name name) explicit-arg-types))

    (unless match-sets
      (loop for tmpl in templates
            for params = (template-data-parameters tmpl)
            do (when (= (length explicit-arg-types) (length params))
                     (push (list tmpl explicit-arg-types) match-sets))))

    (let ((did-work nil))
      (loop for (tmpl inferred-types) in match-sets do
              (let* ((key          (cons (template-data-name tmpl) inferred-types))
                     (status       (gethash key *instantiated-templates*))
                     ;; FIX: *current-module* is a symbol-macro, not defvar.
                     ;; (boundp '*current-module*) always NIL.  Check the session directly.
                     (is-compiling (and *compiler-session*
                                        (compiler-session-module *compiler-session*))))

                (when (%should-instantiate-template key status is-compiling)
                      (log:info "Auto-specializing template ~a for types ~a (Status: ~a, Is-Compiling: ~a)"
                                name inferred-types status is-compiling)

                      (let ((instantiated-code (instantiate-template tmpl inferred-types)))
                        (loop for form in (rest instantiated-code)
                              do (let ((is-wrapper
                                        ;; _WRAPPER functions have c-t fields typed as type-spec/address-space/etc
                                        ;; which map to void in LLVM — illegal as parameter types.
                                        ;; Eval them to register overloads; never compile to IR.
                                        (and (consp form)
                                             (symbolp (car form))
                                             (string-equal (symbol-name (car form)) "DEF-FUNCTION")
                                             (symbolp (second form))
                                             (search "_WRAPPER" (symbol-name (second form))
                                                     :test #'char-equal))))
                                   (if (and is-compiling (not is-wrapper))
                                       (funcall compiler-callback form nil)
                                       (eval form))))

                        (setf (gethash key *instantiated-templates*) (if is-compiling :compiled :analyzed))
                        (setf did-work t)))))
      did-work)))

;;; ============================================================
;;; 093-loop-vector-stride: SPIR-V builtin calling convention fix
;;; ============================================================

;; src/codegen.lisp
;; The LLVM-SPIRV translator translates __spirv_BuiltIn* GLOBAL VARIABLES in
;; addrspace(1) to SPIR-V OpVariable BuiltIn decorations.
;; Function-call style declare's produce OpDecorate LinkageAttributes Import which
;; leave the module unresolved — Level Zero fails zeKernelCreate with
;; ZE_RESULT_ERROR_INVALID_MODULE_UNLINKED (0x78000018).
;; Fix: create external addrspace(1) constant globals and load from them.
(cffi:defcfun ("LLVMAddGlobalInAddressSpace" %llvm-add-global-in-addrspace) :pointer
  (module    :pointer)
  (type      :pointer)
  (name      :string)
  (addrspace :unsigned-int))

(cffi:defcfun ("LLVMGetNamedGlobal" %llvm-get-named-global) :pointer
  (module :pointer)
  (name   :string))

(cffi:defcfun ("LLVMSetLinkage" %llvm-set-linkage) :void
  (global  :pointer)
  (linkage :unsigned-int))

(cffi:defcfun ("LLVMSetInitializer" %llvm-set-initializer) :void
  (global      :pointer)
  (const-val   :pointer))

(defun %call-spirv-vec3-builtin (builder module spirv-name)
  "Emits a load from @__spirv_BuiltIn<SPIRV-NAME> addrspace(1) global with zeroinitializer.
   The LLVM-SPIRV translator maps addrspace(1) globals named __spirv_BuiltIn* to SPIR-V
   OpVariable BuiltIn decorations.  Using a zeroinitializer (CommonLinkage) suppresses the
   import linkage that an external declaration generates, preventing the
   ZE_RESULT_ERROR_INVALID_MODULE_UNLINKED error from Level Zero at runtime."
  (let* ((gvar-name (format nil "__spirv_BuiltIn~a" spirv-name))
         (vec3-type (crisp-type-to-llvm-type 'ulong3 module))
         (existing  (%llvm-get-named-global module gvar-name))
         (gvar      (if (cffi:null-pointer-p existing)
                        (let ((g (%llvm-add-global-in-addrspace module vec3-type gvar-name 1)))
                          ;; zeroinitializer → CommonLinkage (8); suppresses import linkage attr
                          (%llvm-set-initializer g (llvm-const-null vec3-type))
                          g)
                        existing)))
    (llvm-build-load2 builder vec3-type gvar (string-downcase spirv-name))))

;;; ============================================================
;;; 093-loop-vector-stride
;;; ============================================================

;; src/analysis/control.lisp
;; Extend analyze-length-tilde-expression to also recognise VECTOR and MATRIX types.
;; Both are syntactic sugar for (tensor T 1 ...) / (tensor T 2 ...), so they share
;; the same runtime struct layout and the same length~ accessor.
(defun analyze-length-tilde-expression (expr env context location)
  "Analyzes (length~ arr).
   For (array T N): returns compile-time constant N as ulong literal.
   For tensor/vector/matrix types: dispatches to the runtime length~ accessor.
   Signals crisp-compiler-error if argument is none of the above."
  (unless (= (length expr) 2)
    (error 'crisp-compiler-error
           :message "length~ expects exactly 1 argument: (length~ arr)"
           :source-location location))
  (let* ((arg-node  (analyze-expression (second expr) env context location))
         (raw-type  (semantic-node-type arg-node))
         (arg-type  (resolve-type-alias
                     (if (and (listp raw-type) (= (length raw-type) 1) (listp (first raw-type)))
                         (first raw-type)
                         raw-type)))
         ;; Expand vector/matrix sugar so we can inspect the canonical form
         (expanded  (expand-storage-handle-type-specifier (resolve-type-alias arg-type)))
         ;; A type is tensor-like if it's a mangled tensor symbol, a canonical (tensor ...) list,
         ;; or if expanding it yields a (tensor ...) list (i.e. vector/matrix sugar).
         (is-tensor (let ((resolved (resolve-type-alias arg-type)))
                      (or (and (symbolp resolved)
                               (let* ((parts (unmangle-template-struct-name resolved))
                                      (base  (first parts)))
                                 (and base (string-equal (symbol-name base) "TENSOR"))))
                          (and (listp resolved)
                               (symbolp (first resolved))
                               (string-equal (symbol-name (first resolved)) "TENSOR"))
                          ;; VECTOR / MATRIX expand to (tensor ...) via expand-storage-handle-type-specifier
                          (and (listp expanded)
                               (symbolp (first expanded))
                               (string-equal (symbol-name (first expanded)) "TENSOR"))))))
    (cond
     ;; Tensor / vector / matrix: delegate to the runtime length~ accessor
     (is-tensor
      (log:info "length~~: tensor/vector/matrix type ~a -> delegating to runtime accessor" arg-type)
      (analyze-function-call 'length~ expr env context location))
     ;; Fixed-size array: compile-time constant
     ((%array-type-p arg-type)
      (let* ((n-raw (third arg-type))
             (n     (etypecase n-raw
                      (integer n-raw)
                      (symbol  (parse-integer (symbol-name n-raw))))))
        (log:info "length~~: array type ~a -> N=~a" arg-type n)
        (make-semantic-literal :value-type 'ulong
                               :value      (coerce n '(unsigned-byte 64))
                               :source-location location)))
     ;; Neither: error
     (t
      (error 'crisp-compiler-error
             :message (format nil "length~~ requires an (array T N), tensor, vector, or matrix type, got ~a"
                              arg-type)
             :source-location location)))))

;; src/analysis/control.lisp
(defun analyze-loop-vector-stride-expression (expr env context location)
  "Analyzes (loop-vector-stride VEC (VAR) BODY...).
   VEC must be a vector/matrix/tensor expression; VAR is bound to the element index (ulong).
   Expands at analysis time to:
     (let ((gid   (get-global-id 0))
           (gsize (get-global-work-size 0))
           (len   (length~ VEC)))
       (declare (grid-level))
       (dotimes (k len gsize)
         (let ((VAR (+ k gid)))
           (when (< VAR len)
             BODY...))))
   The (declare (grid-level)) enforces dispatch context and prevents nesting."
  (unless (and (>= (length expr) 3)
               (listp (third expr))
               (= (length (third expr)) 1)
               (symbolp (first (third expr))))
    (error 'crisp-compiler-error
           :message "Malformed loop-vector-stride: expected (loop-vector-stride VEC (VAR) BODY...)"
           :source-location location))
  (let* ((vec-form   (second expr))
         (var-name   (first (third expr)))
         (body-forms (cdddr expr))
         ;; Gensym internal names to prevent variable capture
         (gid-sym   (gensym "GID"))
         (gsize-sym (gensym "GSIZE"))
         (len-sym   (gensym "LEN"))
         (k-sym     (gensym "K"))
         ;; Use crisp-language symbols so the analyzer dispatch table recognises them
         (cl-pkg         (find-package :crisp-language))
         (let-sym        (intern "LET"                  cl-pkg))
         (declare-sym    (intern "DECLARE"              cl-pkg))
         (grid-level-sym (intern "GRID-LEVEL"           cl-pkg))
         (dotimes-sym    (intern "DOTIMES"              cl-pkg))
         (when-sym       (intern "WHEN"                 cl-pkg))
         (get-gid-sym    (intern "GET-GLOBAL-ID"        cl-pkg))
         (get-gsize-sym  (intern "GET-GLOBAL-WORK-SIZE" cl-pkg))
         (len-tilde-sym  (intern "LENGTH~"              cl-pkg))
         (plus-sym       (intern "+"                    cl-pkg))
         (lt-sym         (intern "<"                    cl-pkg)))
    (let* ((inner-when
            ;; (when (< VAR len__) body...)
            (list* when-sym
                   (list lt-sym var-name len-sym)
                   body-forms))
           (inner-let
            ;; (let ((VAR (+ k__ gid__))) <inner-when>)
            (list let-sym
                  (list (list var-name (list plus-sym k-sym gid-sym)))
                  inner-when))
           (dotimes-form
            ;; (dotimes (k__ len__ gsize__) <inner-let>)
            (list dotimes-sym
                  (list k-sym len-sym gsize-sym)
                  inner-let))
           (expansion
            ;; (let ((gid__ ...) (gsize__ ...) (len__ ...))
            ;;   (declare (grid-level))
            ;;   <dotimes-form>)
            (list let-sym
                  (list (list gid-sym   (list get-gid-sym 0))
                        (list gsize-sym (list get-gsize-sym 0))
                        (list len-sym   (list len-tilde-sym vec-form)))
                  (list declare-sym (list grid-level-sym))
                  dotimes-form)))
      (analyze-expression expansion env context location))))

;; src/analysis/control.lisp
;; Redefine register-control-analyzers to include loop-vector-stride registration.
(defun register-control-analyzers ()
  "Registers all control flow expression analyzers, including loop-vector-stride."
  (def-expression-analyzer function analyze-function-literal)
  (def-expression-analyzer common-lisp:function analyze-function-literal)
  (def-expression-analyzer funcall analyze-funcall-expression)
  (def-expression-analyzer let analyze-let-expression)
  (def-expression-analyzer common-lisp:let analyze-let-expression)
  (def-expression-analyzer let* analyze-let-expression)
  (def-expression-analyzer common-lisp:let* analyze-let-expression)
  (def-expression-analyzer progn analyze-progn-expression)
  (def-expression-analyzer sizeof analyze-sizeof-expression)
  (def-expression-analyzer compiler-no-op analyze-compiler-no-op)
  (def-expression-analyzer is-set? analyze-is-set-expression)
  (def-expression-analyzer if analyze-if-expression)
  (def-expression-analyzer when analyze-when-expression)
  (def-expression-analyzer common-lisp:when analyze-when-expression)
  (def-expression-analyzer unless analyze-unless-expression)
  (def-expression-analyzer common-lisp:unless analyze-unless-expression)
  (def-expression-analyzer return analyze-return-expression)
  (def-expression-analyzer explicit-return analyze-return-expression)
  (def-expression-analyzer semantic-return analyze-return-expression)
  (def-expression-analyzer quote analyze-quote)
  (def-expression-analyzer if+ analyze-static-if-expression)
  (def-expression-analyzer when+ analyze-static-when-expression)
  (def-expression-analyzer unless+ analyze-static-unless-expression)
  (def-expression-analyzer def-function analyze-nested-def-function)
  (def-expression-analyzer template-instantiation analyze-template-instantiation)
  (def-expression-analyzer common-lisp:eval-when analyze-eval-when)
  ;; length~
  (let ((sym-cl (intern "LENGTH~" (find-package :crisp-language)))
        (sym-cc (intern "LENGTH~" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-length-tilde-expression)
    (setf (gethash sym-cc *expression-analyzers*) #'analyze-length-tilde-expression))
  ;; dotimes
  (let ((sym-cl (intern "DOTIMES" (find-package :crisp-language)))
        (sym-cc (intern "DOTIMES" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-dotimes-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-dotimes-expression)))
  ;; loop-vector-stride — dual-package registration
  (let ((sym-cl (intern "LOOP-VECTOR-STRIDE" (find-package :crisp-language)))
        (sym-cc (intern "LOOP-VECTOR-STRIDE" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-loop-vector-stride-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-loop-vector-stride-expression))))
