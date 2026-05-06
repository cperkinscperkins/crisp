;; tests/spec/015-cell/cell-expansion.unit.lisp

(in-package :crisp.compiler)

(parachute:define-test cell-expansion-tests
                       :parent crisp.compiler::crisp.tests)

(parachute:define-test (cell-expansion-tests expand-storage-handle-defaults)
                       (parachute:is equal
                                     '(cell int :global)
                                     (expand-storage-handle-type-specifier '(cell int))))

(parachute:define-test (cell-expansion-tests expand-storage-handle-explicit-keywords)
                       (parachute:is equal
                                     '(cell int :local)
                                     (expand-storage-handle-type-specifier '(cell int :address-space :local))))

;; This is the regression case: :direction :out should be ignored
(parachute:define-test (cell-expansion-tests expand-storage-handle-ignore-unknown-keywords)
                       (parachute:is equal
                                     '(cell int :global)
                                     (expand-storage-handle-type-specifier '(cell int :direction :out :address-space :global))))

;; This is the regression case: 'global symbol should be treated as :global keyword
(parachute:define-test (cell-expansion-tests expand-storage-handle-symbol-normalization)
                       (parachute:is equal
                                     '(cell int :global)
                                     (expand-storage-handle-type-specifier '(cell int :address-space global))))
