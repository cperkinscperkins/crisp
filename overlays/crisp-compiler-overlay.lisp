;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)


;; src/codegen.lisp
;; Fix: Same cross-package issue as get-promoted-type — CRISP-LANGUAGE::USHORT2 vs
;; CRISP.COMPILER::USHORT2 are the same semantic type but different symbols.
;; `equal` for symbols is eq, so the no-op check fails and it falls through to the
;; derived-type path where eq on get-type-base returns NIL → error.
;; Fix: add a same-name cross-package no-op check after alias resolution.
(defun build-cast-if-needed (builder module from-val from-type-name to-type-name)
  "Builds LLVM cast instruction if types differ, with alias resolution.
   MODULE is required to resolve types correctly.
   Cross-package same-name fix: USHORT2 may be in :crisp-language or :crisp.compiler;
   treat same symbol-name as no-op cast."
  ;; Resolve aliases first
  (cl:let ((from-type-name (resolve-type-alias from-type-name))
           (to-type-name (resolve-type-alias to-type-name)))
    ;; Fast path: identical (eq)
    (if (equal from-type-name to-type-name)
        (progn
         (log:debug "build-cast-if-needed: No cast needed for ~s" from-type-name)
         from-val)
        ;; Cross-package same-name: CRISP.COMPILER::USHORT2 == CRISP-LANGUAGE::USHORT2
        (if (and (symbolp from-type-name) (symbolp to-type-name)
                 (string= (symbol-name from-type-name) (symbol-name to-type-name)))
            (progn
             (log:debug "build-cast-if-needed: cross-package same-name, no cast needed for ~s" from-type-name)
             from-val)
            (let* ((from-type (if (symbolp from-type-name) (gethash from-type-name *crisp-types*) nil))
                   (to-type (if (symbolp to-type-name) (gethash to-type-name *crisp-types*) nil))
                   (to-llvm-type (crisp-type-to-llvm-type to-type-name module))
                   (from-cat (get-type-cat-safe from-type-name from-type))
                   (to-cat (get-type-cat-safe to-type-name to-type)))
              (log:debug "build-cast-if-needed: Casting from ~s to ~s" from-type-name to-type-name)
              (cond
               ((and (member from-cat '(:signed-int :unsigned-int))
                     (eq to-cat :float))
                 (if (eq from-cat :signed-int)
                     (llvm-build-si-to-fp builder from-val to-llvm-type "si2fp_cast")
                     (llvm-build-ui-to-fp builder from-val to-llvm-type "ui2fp_cast")))
               ((and (member from-cat '(:signed-int :unsigned-int))
                     (member to-cat '(:signed-int :unsigned-int)))
                 (let ((from-size (crisp-type-size from-type))
                       (to-size (crisp-type-size to-type)))
                   (cond
                    ((< to-size from-size)
                      (llvm-build-trunc builder from-val to-llvm-type "trunc_cast"))
                    ((> to-size from-size)
                      (if (eq from-cat :signed-int)
                          (llvm-build-sext builder from-val to-llvm-type "sext_cast")
                          (llvm-build-zext builder from-val to-llvm-type "zext_cast")))
                    (t from-val))))
               ((and (eq from-cat :float) (eq to-cat :float))
                 (let ((from-size (crisp-type-size from-type))
                       (to-size (crisp-type-size to-type)))
                   (cond
                    ((< to-size from-size)
                      (llvm-build-fp-trunc builder from-val to-llvm-type "fptrunc_cast"))
                    ((> to-size from-size)
                      (llvm-build-fp-ext builder from-val to-llvm-type "fpext_cast"))
                    (t from-val))))
               ((and (eq from-cat :float) (member to-cat '(:signed-int :unsigned-int)))
                 (if (eq to-cat :signed-int)
                     (llvm-build-fp-to-si builder from-val to-llvm-type "fp2si_cast")
                     (llvm-build-fp-to-ui builder from-val to-llvm-type "fp2ui_cast")))
               ((and (member from-cat '(:signed-int :unsigned-int))
                     (eq to-cat :pointer))
                 (let ((as (llvm-get-pointer-address-space to-llvm-type)))
                   (if (= as 0)
                       (llvm-build-int-to-ptr builder from-val to-llvm-type "int2ptr_cast")
                       (let* ((generic-ptr-type (crisp-type-to-llvm-type '(c-pointer) module))
                              (tmp-ptr (llvm-build-int-to-ptr builder from-val generic-ptr-type "int2generic")))
                         (llvm-build-addrspace-cast builder tmp-ptr to-llvm-type "generic2as_cast")))))
               ((and (eq from-cat :pointer) (member to-cat '(:signed-int :unsigned-int)))
                 (llvm-build-ptr-to-int builder from-val to-llvm-type "ptr2int_cast"))
               ((and (eq from-cat :pointer) (eq to-cat :pointer))
                 (let ((from-as (llvm-get-pointer-address-space (llvm-type-of from-val)))
                       (to-as (llvm-get-pointer-address-space to-llvm-type)))
                   (if (= from-as to-as)
                       (llvm-build-bit-cast builder from-val to-llvm-type "ptr2ptr_cast")
                       (llvm-build-addrspace-cast builder from-val to-llvm-type "ptr2ptr_ascast"))))
               ;; Handle casts between derived types with same base type (same memory layout)
               ((and (symbolp from-type-name) (symbolp to-type-name))
                 (cl:let ((from-base (get-type-base from-type-name))
                          (to-base (get-type-base to-type-name)))
                   (if (eq from-base to-base)
                       (progn
                        (log:debug "Derived type cast: ~a -> ~a (same base ~a, no-op)"
                                   from-type-name to-type-name from-base)
                        from-val)
                       (progn
                        (log:error "CODEGEN CAST ERROR: ~a -> ~a" from-type-name to-type-name)
                        (log:error "  From Type: ~a (cat: ~a, base: ~a)" from-type from-cat from-base)
                        (log:error "  To Type:   ~a (cat: ~a, base: ~a)" to-type to-cat to-base)
                        (log:error "  Value dump: ~a" (llvm-print-value-to-string from-val))
                        (error "Unsupported value cast from ~a to ~a" from-type-name to-type-name)))))
               (t
                (log:error "CODEGEN CAST ERROR: ~a -> ~a" from-type-name to-type-name)
                (log:error "  From Type: ~a (cat: ~a)" from-type from-cat)
                (log:error "  To Type:   ~a (cat: ~a)" to-type to-cat)
                (log:error "  Value dump: ~a" (llvm-print-value-to-string from-val))
                (error "Unsupported value cast from ~a to ~a" from-type-name to-type-name))))))))

;; src/type-checker.lisp
;; Fix: Device vector types are registered in *both* :crisp-language (CRISP-LANGUAGE::USHORT2)
;; and :crisp.compiler (CRISP.COMPILER::USHORT2), but they are distinct symbols (not imported).
;; When (~ u2) is analyzed for a (cell ushort2 ...) parameter, the element type is reconstructed
;; via unmangle-template-struct-name which uses :crisp.compiler as the base package, yielding
;; CRISP.COMPILER::USHORT2.  Meanwhile ##(3us 4) produces CRISP-LANGUAGE::USHORT2.
;; The eq fast-path in get-promoted-type then fails, and the category+size fallback returns NIL
;; because both sides have identical size (no winner) and no float-int promotion applies.
;; Fix: add a same-name cross-package fallback between the eq check and DAG dominance.
;; This is safe: Crisp has a unique type name registry — two symbols with the same symbol-name
;; represent the same semantic type.
(defun get-promoted-type (type-a-name type-b-name)
  "Determines result type of binary operation with alias resolution.
   Now uses type derivation hierarchy (DAG) for promotion rules.
   Cross-package same-name fix: device vector types like USHORT2 may be interned in
   :crisp-language or :crisp.compiler depending on the code path; treat same symbol-name
   as the same type after alias resolution."
  (cl:let ((type-a-name (resolve-type-alias type-a-name))
           (type-b-name (resolve-type-alias type-b-name)))
    (cond
      ;; Fast path: identical symbols
      ((eq type-a-name type-b-name)
       type-a-name)
      ;; Cross-package same-name: CRISP.COMPILER::USHORT2 vs CRISP-LANGUAGE::USHORT2
      ((and (symbolp type-a-name) (symbolp type-b-name)
            (string= (symbol-name type-a-name) (symbol-name type-b-name)))
       (log:debug "get-promoted-type: cross-package same-name match ~a == ~a" type-a-name type-b-name)
       type-a-name)
      ;; Try DAG-based dominance resolution
      (t
       (cl:let ((dominant-type (resolve-dominance type-a-name type-b-name)))
         (log:debug "get-promoted-type: ~a + ~a => dominant=~a" type-a-name type-b-name dominant-type)
         (if dominant-type
             dominant-type
             ;; Fall back to category + size promotion for types not in hierarchy
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
                (t nil)))))))))
