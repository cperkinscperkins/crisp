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
    (true (search "{ float, i32 }" ir))
    ;; Check for function signature using it
    (true (search "define i32 @use_point_test_point_ir(%TEST-POINT-IR %0)" ir :test #'char-equal)
        "Structs should be passed by value in this simple case?")))
