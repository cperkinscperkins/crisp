;;; tests/test-def-kernel.lisp

(in-package :crisp.tests)

(define-test (crisp-compiler def-kernel-generation)
             "Tests that def-kernel expands to a function with marshalled arguments."

             ;; We need to register the types used in the test
             ;; in-c and out-c are referenced in declares.
             ;; For the test environment, we just need to ensure the types exist.
             ;; We can use evaluating forms to set up environment.

             (let ((forms '((def-type in-c (cell long :address-space :global ))
                            (def-type out-c (cell long :address-space :global ))

                            (def-kernel cell_add (threshold A B &out C)
                                        (declare #'(long in-c in-c &out out-c))
                                        (when (> threshold (as-long 255))
                                              (let ((a (~ A))
                                                    (b (~ B)))
                                                (set! (~ C) (+ a b))))))))

               ;; Use the existing helper from all-tests.lisp if available via package,
               ;; or redefine/inline a simplified version if not exported.
               ;; compile-crisp-form-to-ir-string takes a single form.
               ;; Here we have a dependencies chain.
               ;; So we should probably use compile-module or just compile the full list.

               (let ((ir (with-output-to-string (s)
                           (let ((*standard-output* s)
                                 (crisp.compiler::*function-table* (make-hash-table))
                                 (crisp.compiler::*target-backend* :spirv))
                             (let* ((module (llvm-module-create "kernel_test"))
                                    (builder (llvm-create-builder)))
                               (unwind-protect
                                   (progn
                                    (compile-module forms module builder nil nil nil)
                                    (let ((ir-ptr (llvm-print-module-to-string module)))
                                      (unwind-protect (format s "~a" (cffi:foreign-string-to-lisp ir-ptr))
                                        (llvm-dispose-message ir-ptr))))
                                 (llvm-dispose-builder builder)
                                 (llvm-dispose-module module)))))))

                 (is-valid-ir ir)

                 ;; Verify the signature is unrolled/marshalled
                 ;; We expect: define spir_kernel void @cell_add_... (i64, ptr, i64, i64, ...)
                 ;; The exact name mangle depends on types, but we know it should NOT take %CELL structs directly.
                 (true (search "define spir_kernel void @cell_add" ir))
                 (true (search "(i64 %0, ptr addrspace(1) %1, i64 %2, i64 %3, ptr addrspace(1) %4, i64 %5, i64 %6, ptr addrspace(1) %7, i64 %8, i64 %9)" ir)
                       "Kernel signature should contain expanded arguments: 1 (long) + 3 (cell) + 3 (cell) + 3 (cell) = 10 args."))))
