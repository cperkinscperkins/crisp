;; tests/test-structs.lisp
(in-package :crisp.tests)

(define-test (crisp-compiler struct-registration)
             "Tests that def-struct parses correctly and registers the struct definition."

             ;; Clear registry to ensure clean state
             (eval '(clrhash crisp.compiler::*crisp-structs*))

             (let ((form '(def-struct test-point
                                      (x int)
                                      (y int))))

               ;; Macroexpand/Eval to trigger registration (since def-struct registers at compile-time/execution-time)
               (eval form)

               (let ((struct-def (gethash 'test-point crisp.compiler::*crisp-structs*)))
                 (true struct-def "Struct 'test-point should be registered.")

                 (when struct-def
                       (is eq 'test-point (crisp.compiler::crisp-struct-definition-name struct-def))
                       (let ((members (crisp.compiler::crisp-struct-definition-members struct-def)))
                         (is = 2 (length members))
                         ;; Check member 1: (x int)
                         (is eq 'x (first (first members)))
                         (is eq 'int (second (first members)))
                         ;; Check member 2: (y:int) -> Parsed as (y int)
                         (is eq 'y (first (second members)))
                         (is eq 'int (second (second members))))))))


(define-test (crisp-compiler struct-llvm-ir)
             "Tests that using a struct in a function signature generates correct LLVM IR."

             (eval '(def-struct test-point-ir (x float) (y int)))

             (true (gethash 'test-point-ir crisp.compiler::*crisp-structs*) "Struct should be in registry")
             (true (crisp.compiler::valid-type-p 'test-point-ir) "Struct should be a valid type")

             (let* ((ir (crisp.compiler::compile-crisp-form-to-ir-string
                         '(def-function use-point ((p test-point-ir))
                                        (declare (return-type int))
                                        (return 0)))))

               (format t "Generated IR: ~a~%" ir)
               (true ir)
               ;; Check for struct definition
               (true (search "test-point-ir" ir :test #'char-equal))
               (true (search "{ float, i32, double }" ir))
               ;; Check for function signature using it
               (true (search "define i32 @use_point_test_point_ir(%TEST-POINT-IR %0)" ir :test #'char-equal)
                     "Structs should be passed by value in this simple case?")))

(define-test (crisp-compiler struct-std140-mixed)
             "Verifies std140 layout for Mixed struct (char, int)."
             (let ((members '((a char) (b int))))
               ;; Use the internal function directly to verify the padding logic
               (multiple-value-bind (padded size) (crisp.compiler::compute-std140-layout members)
                 (is = 16 size "Total size should be 16 bytes")
                 (is = 5 (length padded) "Should have 5 elements (a, pad1, pad2, b, padEA)")

                 ;; 1. a (char)
                 (is eq 'a (first (first padded)))

                 ;; 2. padding for 3 bytes (char + short)
                 ;; Note: names are implementation detail (_PAD_0_1 etc)
                 (is eq 'char (second (second padded)))
                 (is eq 'short (second (third padded)))

                 ;; 3. b (int)
                 (is eq 'b (first (fourth padded)))

                 ;; 4. padding for remaining 8 bytes (double)
                 ;; _PAD_EA (8 bytes)
                 (is eq 'double (second (fifth padded))))))
