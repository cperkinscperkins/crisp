;; tests/test-storage-handles.lisp
(in-package :crisp.tests)

(define-test (crisp-compiler test-storage-handles)

             ;; Policy: :address-space has no default.  Incomplete cell spec
             ;; preserves the missing slot as nil.
             (true
              (let ((result (crisp.compiler::expand-storage-handle-type-specifier '(cell int))))
                (and (string-equal "CELL" (symbol-name (first result)))
                     (string-equal "INT" (symbol-name (second result)))
                     (null (third result))
                     (= 3 (length result)))))

             (true
              (let ((result (crisp.compiler::expand-storage-handle-type-specifier '(cell int :local))))
                (eq :local (third result))))

             (true
              (let ((result (crisp.compiler::expand-storage-handle-type-specifier '(cell int :address-space :private))))
                (eq :private (third result))))

             ;; :access is now ignored; only address-space is kept
             (true
              (let ((result (crisp.compiler::expand-storage-handle-type-specifier '(cell int :local))))
                (and (eq :local (third result))
                     (= 3 (length result)))))

             (true
              (let ((result (crisp.compiler::expand-storage-handle-type-specifier '(cell int :address-space global))))
                (eq :global (third result))))

             (fail (crisp.compiler::expand-storage-handle-type-specifier '(cell int :invalid-key)))

             (fail (crisp.compiler::expand-storage-handle-type-specifier '(cell int :address-space)))

             (true
              (let ((result (crisp.compiler::expand-storage-handle-type-specifier '(cell int :local :global))))
                (eq :global (third result)))))
