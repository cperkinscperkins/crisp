;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;;; ============================================================
;;; Endeavor 122 (FFI) Pass 3: a voidp parameter accepts any pointer argument.
;;; FROM: src/type-checker.lisp
;;;
;;; Lifts the def-kernel-exact-only restriction so foreign functions (and any
;;; function) declaring a voidp parameter can be passed a typed pointer such as
;;; the result of (base-ptr~ cell) / (address~ (parent~ cell)). Address-space
;;; differences (e.g. global addrspace 1 -> voidp addrspace 0) are reconciled by
;;; the pointer->pointer addrspacecast already in the value-coercion path.
;;; ============================================================
(defun types-compatible-p (arg-type param-type)
  "Checks if an argument type is compatible with a parameter type."
  (log:debug "COMPAT-CHECK: Arg ~s Param ~s" arg-type param-type)
  (or (types-equivalent-p arg-type param-type)

      ;; Endeavor 122 (FFI): voidp accepts any pointer argument — voidp, a typed
      ;; (c-pointer ...), or a (c-handle ...) (a void** slot; same addrspace-0 ABI).
      (and (symbolp param-type)
           (string-equal (symbol-name param-type) "VOIDP")
           (or (and (symbolp arg-type)
                    (string-equal (symbol-name arg-type) "VOIDP"))
               (and (consp arg-type) (symbolp (first arg-type))
                    (member (symbol-name (first arg-type)) '("C-POINTER" "C-HANDLE")
                            :test #'string-equal))))

      ;; Derived type substitutability check
      ;; If arg-type can substitute for param-type in the derivation hierarchy
      (and (symbolp arg-type)
           (symbolp param-type)
           (is-substitutable-for? arg-type param-type))

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

;;; ============================================================
;;; Endeavor 122 (FFI) Pass 1: def-foreign-function support.
;;;
;;; - register-foreign-function: builds a function-signature (so calls resolve)
;;;   and records the verbatim C name in *foreign-functions*.
;;; - generate-node-ir (semantic-call) override: foreign calls use the verbatim
;;;   C name (no Crisp mangling) and the external declaration gets the target's
;;;   device calling convention so it matches the linked .bc definition.
;;; The def-foreign-function MACRO lives in src/macros.lisp (macros can't overlay).
;;; ============================================================

;; src/macros.lisp (companion to the def-foreign-function macro)
(defun %foreign-c-name (sym)
  "C name to emit for a foreign-function symbol. Verbatim when the symbol was
   written with any lowercase character (i.e. escaped, like |myFunc|), otherwise
   downcased -- the common case, since unescaped Lisp symbols are uppercased on
   read while C library names are typically lowercase."
  (let ((n (symbol-name sym)))
    (if (some #'lower-case-p n) n (string-downcase n))))

;; src/compiler.lisp (or environment.lisp)
(defun register-foreign-function (c-name signature)
  "Registers a (def-foreign-function C-NAME SIGNATURE). SIGNATURE is a Crisp
   arrow spec, possibly wrapped as (function (...)) from #'(...). Builds a
   single function-signature in *function-table* (synthetic param names; only
   the types matter for resolution) and records the verbatim C name in
   *foreign-functions*."
  (let* ((spec (if (and (consp signature) (symbolp (first signature))
                        (string-equal (symbol-name (first signature)) "FUNCTION"))
                   (second signature)
                   signature))
         (arrow-pos (position-if (lambda (x) (and (symbolp x)
                                                  (string-equal (symbol-name x) "=>")))
                                 spec))
         (param-type-specs (subseq spec 0 (or arrow-pos (length spec))))
         (return-types (analyze-return-type-from-spec spec))
         (params (loop for ty in param-type-specs
                       for i from 0
                       collect (make-parameter-def
                                :name (intern (format nil "ARG~a" i) (symbol-package c-name))
                                :type (parse-type-specifier ty)
                                :kind :in)))
         (sig (make-function-signature :name c-name
                                       :parameters params
                                       :return-types return-types)))
    (setf (gethash c-name *function-table*) (list sig))
    (setf (gethash c-name *foreign-functions*) (%foreign-c-name c-name))
    (log:info "FFI: registered foreign function ~a -> C name ~s (~a params, returns ~a)"
              c-name (gethash c-name *foreign-functions*) (length params) return-types)
    c-name))

;; src/codegen.lisp
(defmethod generate-node-ir ((node semantic-call) builder module var-env di-builder di-scope location-map)
  "Generates IR for a function call.

   Endeavor 122 (FFI): a call to a function registered in *foreign-functions*
   uses its verbatim C name (no Crisp type-mangling), and its external
   declaration is given the target's device calling convention (SPIR_FUNC=75 on
   SPV; default on PTX) so the call instruction (which copies the callee's CC)
   matches the definition merged in from the linked .bc."
  ;; Special handling for compiler intrinsic DIE
  (when (eq (semantic-call-name node) 'die)
        (return-from generate-node-ir (%handle-die-intrinsic builder module)))

  (let* ((sig (semantic-call-signature node))
         (return-type-names (function-signature-return-types sig))
         (param-types (mapcar #'parameter-def-type (function-signature-parameters sig))))

    (multiple-value-bind (llvm-fn-type param-count)
        (%build-llvm-function-type module return-type-names param-types)

      (let* ((foreign-c-name (gethash (semantic-call-name node) *foreign-functions*))
             (callee-name
              (if foreign-c-name
                  foreign-c-name
                  (let ((mangled-name (format nil "~a~{_~a~}" (semantic-call-name node)
                                        (mapcar #'mangle-type-spec param-types))))
                    (substitute #\_ #\~ (substitute #\_ #\- (string-downcase mangled-name)))))))

        ;; Foreign: pre-declare with the device calling convention so the call's
        ;; propagated CC matches the linked definition.
        (when foreign-c-name
          (let ((f (llvm-get-named-function module callee-name)))
            (when (cffi:null-pointer-p f)
              (setf f (llvm-add-function module callee-name llvm-fn-type)))
            (when (eq *target-backend* :spirv)
              (llvm-set-function-call-conv f 75))))

        (%build-function-call builder module var-env di-builder di-scope location-map node sig
                              callee-name llvm-fn-type param-types param-count return-type-names)))))



;;; ============================================================
;;; Endeavor 122 (FFI) Pass 4: handles (void**).
;;;
;;; A c-handle is a local slot (alloca) holding a pointer of HELD-TYPE; its value
;;; is the slot address (an addrspace-0 pointer == voidp at the ABI). Pass it to a
;;; foreign function's void** (declared `voidp`) param; the function writes a
;;; pointer into the slot; read it back with get-pointer.
;;;   (make-c-handle (c-pointer :address-space :global))  => c-handle value (alloca)
;;;   (get-pointer <c-handle>)                            => the held pointer
;;; The c-handle LLVM type is `ptr addrspace(0)`; the held type is tracked only in
;;; the Crisp type `(c-handle <held-ptr-type>)` so get-pointer knows what to load.
;;; analyzers registered in register-control-analyzers (src/analysis/control.lisp);
;;; structs in src/semantic.lisp.
;;; ============================================================

;; src/analysis/control.lisp (analyzers)
(defun analyze-make-c-handle (expr env context location)
  "Analyzer for (make-c-handle <held-ptr-type>)."
  (declare (ignore env context))
  (unless (= (length expr) 2)
    (error 'crisp-compiler-error
      :message "make-c-handle expects 1 argument: the held pointer type, e.g. (make-c-handle (c-pointer :address-space :global))"
      :source-location location))
  (let ((held (second expr)))
    (unless (and (consp held) (symbolp (first held))
                 (string-equal (symbol-name (first held)) "C-POINTER"))
      (error 'crisp-compiler-error
        :message (format nil "make-c-handle requires a (c-pointer :address-space ...) type; got ~a" held)
        :source-location location))
    (make-semantic-make-c-handle
     :type (list (intern "C-HANDLE" (find-package :crisp.compiler)) held)
     :held-type held
     :source-location location)))

(defun analyze-get-pointer (expr env context location)
  "Analyzer for (get-pointer <c-handle>) — loads the held pointer from the slot."
  (unless (= (length expr) 2)
    (error 'crisp-compiler-error
      :message "get-pointer expects 1 argument (a c-handle)"
      :source-location location))
  (let* ((handle-node (analyze-expression (second expr) env context (append location '(1))))
         (htype (get-single-value-type handle-node)))
    (unless (and (consp htype) (symbolp (first htype))
                 (string-equal (symbol-name (first htype)) "C-HANDLE"))
      (error 'crisp-compiler-error
        :message (format nil "get-pointer requires a c-handle argument; got type ~a" htype)
        :source-location location))
    (make-semantic-get-pointer
     :type (second htype)
     :handle-node handle-node
     :source-location location)))

;; src/codegen.lisp (codegen)
(defmethod generate-node-ir ((node semantic-make-c-handle) builder module var-env di-builder di-scope location-map)
  "Allocate a local slot (alloca) typed by the held pointer type; the value is
   the slot's address (an addrspace-0 pointer)."
  (declare (ignore var-env di-builder di-scope location-map))
  (let ((held-llvm (crisp-type-to-llvm-type (semantic-make-c-handle-held-type node) module)))
    (crisp.llvm-bindings::llvm-build-alloca builder held-llvm "c_handle_slot")))

(defmethod generate-node-ir ((node semantic-get-pointer) builder module var-env di-builder di-scope location-map)
  "Load the held pointer out of a c-handle slot."
  (let ((held-llvm   (crisp-type-to-llvm-type (semantic-get-pointer-type node) module))
        (handle-val  (generate-node-ir (semantic-get-pointer-handle-node node)
                                       builder module var-env di-builder di-scope location-map)))
    (crisp.llvm-bindings::llvm-build-load2 builder held-llvm handle-val "c_handle_load")))

;; src/codegen/abi.lisp — c-handle resolves to an addrspace-0 opaque pointer.
(defun crisp-type-to-llvm-type (type-spec module)
  "Resolves a Crisp type specifier (simple or parameterized) to an LLVM type.
   Endeavor 122 Pass 4: (c-handle ...) -> addrspace-0 opaque pointer (the slot)."
  (let ((canonical-spec (if (and (consp type-spec)
                                 (symbolp (first type-spec))
                                 (member (symbol-name (first type-spec)) '("CELL" "STORAGE" "VECTOR" "MATRIX" "TENSOR") :test #'string-equal))
                            (progn
                             (log:debug "crisp-type-to-llvm-type: Mangling storage handle list form: ~s" type-spec)
                             (mangle-template-struct-name (first type-spec) (rest type-spec)))
                            type-spec)))
    (let ((result
           (cond
            ((and (listp canonical-spec)
                  (or (eq (first canonical-spec) :function-type)
                      (eq (first canonical-spec) :function-literal)))
              (llvm-pointer-type (llvm-int8-type) 0))
            ((eq canonical-spec 'int)
              (or *cached-int32-type* (llvm-int32-type-in-context (llvm-get-module-context module))))
            ((eq canonical-spec 'long)
              (or *cached-int64-type* (llvm-int64-type-in-context (llvm-get-module-context module))))
            ((or (eq canonical-spec 'keyword) (eq canonical-spec 'symbol))
              (or *cached-int32-type* (llvm-int32-type-in-context (llvm-get-module-context module))))
            ((eq canonical-spec 'voidp)
              (llvm-pointer-type (llvm-int8-type-in-context (llvm-get-module-context module)) 0))
            ;; Endeavor 122 Pass 4: handle slot pointer is addrspace 0 (== voidp).
            ((and (consp canonical-spec) (symbolp (first canonical-spec))
                  (string-equal (symbol-name (first canonical-spec)) "C-HANDLE"))
              (llvm-pointer-type (llvm-int8-type-in-context (llvm-get-module-context module)) 0))
            (t
              (resolve-type-to-llvm canonical-spec)))))
      (when (or (null result) (cffi:null-pointer-p result))
            (error "Failed to resolve LLVM type for type-spec: ~s (canonical: ~s)" type-spec canonical-spec))
      result)))

;; src/types/validation.lisp — (c-handle ...) is a valid type.
(defun valid-type-p (type-spec)
  "Checks if a type specifier is valid.
   Handles simple types, parameterized types, and function literals/types.
   Endeavor 122 Pass 4: accepts (c-handle ...)."
  (or (valid-basic-type-p type-spec)
      (valid-function-type-p type-spec)
      (valid-parameterized-type-p type-spec)
      (and (listp type-spec)
           (symbolp (first type-spec))
           (string-equal (symbol-name (first type-spec)) "C-HANDLE"))
      (and (symbolp type-spec) (gethash type-spec *crisp-type-aliases*))
      (and (listp type-spec)
           (symbolp (first type-spec))
           (or (gethash (first type-spec) *crisp-type-aliases*)
               (gethash (first type-spec) *crisp-template-aliases*)))))
