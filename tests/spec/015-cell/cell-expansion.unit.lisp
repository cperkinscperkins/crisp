;; tests/spec/015-cell/cell-expansion.unit.lisp

(in-package :crisp.compiler)

(parachute:define-test cell-expansion-tests
                       :parent :crisp.tests

                       (parachute:test expand-storage-handle-defaults
                                       (parachute:is equal
                                                     '(cell int :global :read-write)
                                                     (expand-storage-handle-type-specifier '(cell int))))

                       (parachute:test expand-storage-handle-explicit-keywords
                                       (parachute:is equal
                                                     '(cell int :local :read-only)
                                                     (expand-storage-handle-type-specifier '(cell int :address-space :local :access :read-only))))

                       ;; This is the regression case: :direction :out should be ignored
                       (parachute:test expand-storage-handle-ignore-unknown-keywords
                                       (parachute:is equal
                                                     '(cell int :global :read-write)
                                                     (expand-storage-handle-type-specifier '(cell int :direction :out :address-space :global))))

                       ;; This is the regression case: 'global symbol should be treated as :global keyword
                       (parachute:test expand-storage-handle-symbol-normalization
                                       (parachute:is equal
                                                     '(cell int :global :read-write)
                                                     (expand-storage-handle-type-specifier '(cell int :address-space global)))))
