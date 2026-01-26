;; tests/test-storage-handles.lisp
(in-package :crisp.tests)

(define-test (crisp-compiler test-storage-handles)

             (true
              (let ((result (crisp.compiler::expand-storage-handle-type-specifier '(cell int))))
                (and (string-equal "CELL" (symbol-name (first result)))
                     (string-equal "INT" (symbol-name (second result)))
                     (eq :global (third result))
                     (eq :read-write (fourth result)))))

             (true
              (let ((result (crisp.compiler::expand-storage-handle-type-specifier '(cell int :local))))
                (eq :local (third result))))

             (true
              (let ((result (crisp.compiler::expand-storage-handle-type-specifier '(cell int :address-space :private))))
                (eq :private (third result))))

             (true
              (let ((result (crisp.compiler::expand-storage-handle-type-specifier '(cell int :local :read-only))))
                (and (eq :local (third result))
                     (eq :read-only (fourth result)))))

             (true
              (let ((result (crisp.compiler::expand-storage-handle-type-specifier '(cell int :address-space global))))
                (eq :global (third result))))

             (fail (crisp.compiler::expand-storage-handle-type-specifier '(cell int :invalid-key)))

             (fail (crisp.compiler::expand-storage-handle-type-specifier '(cell int :address-space)))

             (true
              (let ((result (crisp.compiler::expand-storage-handle-type-specifier '(cell int :local :global))))
                (eq :global (third result)))))
