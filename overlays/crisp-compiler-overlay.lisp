;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

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


