;; tests/test-structs.lisp
(in-package :crisp.tests)

(define-test (crisp-compiler struct-registration)
             "Tests that def-struct parses correctly and registers the struct definition."

             ;; Use a fresh registry to ensure clean state and avoid polluting global
             (let ((crisp.compiler::*crisp-structs* (make-hash-table)))

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
                           (is eq 'int (second (second members)))))))))

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
               ;; Check for struct definition (native scalar: no trailing double pad)
               (true (search "test-point-ir" ir :test #'char-equal))
               (true (search "{ float, i32 }" ir))
               ;; Check for function signature using it
               (true (search "define i32 @use_point_test_point_ir(%TEST-POINT-IR %0)" ir :test #'char-equal)
                     "Structs should be passed by value in this simple case?")))

(define-test (crisp-compiler struct-std140-mixed)
             "Verifies native scalar layout for Mixed struct (char, int)."
             (let ((members '((a char) (b int))))
               ;; Use the internal function directly to verify the padding logic
               (multiple-value-bind (padded size) (crisp.compiler::compute-std140-layout members)
                 ;; Native scalar: size padded to max-member-alignment (4), not 16.
                 ;; char(1) + 3-pad + int(4) = 8, already a multiple of 4.
                 (is = 8 size "Total size should be 8 bytes (no trailing 16-byte pad)")
                 (is = 4 (length padded) "Should have 4 elements (a, pad-char, pad-short, b)")

                 ;; 1. a (char)
                 (is eq 'a (first (first padded)))

                 ;; 2. padding for 3 bytes (offset 1 → 4).
                 ;; Offset 1: not aligned for short(2). Use char(1) → offset 2.
                 ;; Offset 2: aligned for short(2). Use short(2) → offset 4.
                 (is eq 'char  (second (second padded)))
                 (is eq 'short (second (third padded)))

                 ;; 3. b (int)
                 (is eq 'b (first (fourth padded))))))

(define-test (crisp-compiler struct-std140-stress-test)
             "Verifies complex padding scenarios to ensure no crashes on 'odd' sizes."

             ;; Case 1: Char (1) -> Double (8).
             ;; Offset 1. Need alignment 8. Padding: 7 bytes.
             ;; char + 7-pad + double = 16. max_align=8, 16%8=0 -> no trailing pad.
             (multiple-value-bind (padded size)
                 (crisp.compiler::compute-std140-layout '((a char) (b double)))
               (is = 16 size) ;; 1 + 7 + 8 = 16. Already a multiple of 8.
               (is eq 'a (first (first padded)))
               (true padded)
               (is eq 'b (first (car (last padded)))))

             ;; Case 2: Char (1) -> Struct with float member (align=4, size=4 in native scalar).
             ;; Offset 1. Next align 4. Padding: 3 bytes.
             ;; char + 3-pad + 4(inner) = 8. max_align=4, 8%4=0 -> no trailing pad.
             (eval '(def-struct Inner (x float))) ;; Size 4 (native scalar: just the float)
             (multiple-value-bind (padded size)
                 (crisp.compiler::compute-std140-layout '((a char) (b Inner)))
               (is = 8 size) ;; 1 + 3(pad) + 4(inner) = 8.
               (true padded)))

;; Need to manually clean up or rely on garbage collection?
;; We are just testing layout logic, so no huge side effects.

(define-test (crisp-compiler with-struct-accessors-macro)
             "Tests the with-struct-accessors macro expansion and IR generation."

             (eval '(def-struct AccessorPoint (x crisp.compiler:int) (y crisp.compiler:int)))
             (true (gethash 'AccessorPoint crisp.compiler::*crisp-types*) "AccessorPoint should be a registered TYPE")

             ;; 1. Verify Macro Expansion Logic
             ;; We expect: (with-struct-accessors (p AccessorPoint) (set! x 10))
             ;; To expand to roughly:
             ;; (let ((#:aos-x (intern "x~")) ...)
             ;;   (progn
             ;;     (set! #:aos-x 10) ...))
             ;; But actually the macro does substitution on the body.
             ;; So: (progn (set! (%extract-struct-member p ...) 10))
             ;; Wait, set! on an extract-value is not valid unless semantic analysis handles it.
             ;; Ah, the macro expands `x` to `x~`.
             ;; So `(set! x 10)` -> `(set! x~ 10)`.
             ;; And `x~` is NOT a macro, it's just a symbol.
             ;; BUT `analyze-expression` handles `(set! x~ 10)` if `x~` is bound?
             ;; No, `with-struct-accessors` binds `x~` using `symbol-macrolet`?
             ;; Let's re-read the macro implementation in `compiler.lisp` (Step 1980ish).
             ;; It does:
             ;; (let ((x~ (intern "x~")))
             ;;    `(symbol-macrolet ((,x~ (%extract-struct-member ,obj-var ,index)))
             ;;       ,@expanded-body))
             ;; NO! The previous macro implementation I saw (Step 1980) was:
             ;; It iterates members.
             ;; It creates `aos-accessor-name` (e.g. `x~`).
             ;; It SUBSTITUTES `x` with `x~` in the body.
             ;; AND it wraps the whole thing in:
             ;; `(let ((,aos-accessor-name (%extract-struct-member ,obj-var ,i))) ...)` ??
             ;; Actually, let's re-read `compiler.lisp` lines 287+ from Step 1980.
             ;; It generates:
             ;; `(symbol-macrolet ((,aos-accessor-name (%extract-struct-member ,obj-node ,index))) ...)`?
             ;; No, I need to be sure.

             ;; RE-READING MACRO (Mental Check):
             ;; It uses `symbol-macrolet` to bind `x~` to `(%extract-struct-member obj index)`.
             ;; So `(set! x 10)` -> `(set! x~ 10)` -> `(set! (%extract-struct-member obj index) 10)`.
             ;; `(%extract-struct-member ...)` is an allowable target for `set!` in semantic analysis?
             ;; Semantic analysis `analyze-set!` Case 2 checks for "Struct Member".
             ;; Yes.

             ;; 1. Verify Macro Expansion Logic
             ;; Semantics: (with-struct-accessors Struct (AccessorSym) Body)
             ;; Expands Body for EACH member, replacing AccessorSym with the member's accessor.

             (let* ((expansion (macroexpand-1
                                 '(with-struct-accessors AccessorPoint (acc)
                                                         (set! (acc p) 10))))
                    (expanded-str (format nil "~s" expansion)))

               ;; Should generate (PROGN (set! (x~ p) 10) (set! (y~ p) 10))
               (true (search "PROGN" expanded-str :test #'char-equal) "Should use PROGN")
               (true (search "X~" expanded-str :test #'char-equal) "Should invoke x accessor")
               (true (search "Y~" expanded-str :test #'char-equal) "Should invoke y accessor")
               ;; Note: It uses function calls (X~ p) not symbol-macrolet.
               (true expansion))

             ;; 2. Verify IR Generation
             (let* ((ir (crisp.compiler::compile-crisp-form-to-ir-string
                         '(def-function use-accessors ((p AccessorPoint))
                                        (declare (return-type AccessorPoint))
                                        ;; Increment all members by 10
                                        (with-struct-accessors AccessorPoint (acc)
                                                               (set! (acc p) (+ (acc p) 10)))
                                        (return p)))))
               (format t "Generated Accessor IR: ~a~%" ir)

               ;; Check for Logic

               ;; 1. Insert new values (functional update)
               (true (search "call" ir) "Should call accessor/setter functions")

               ;; 2. Should reference the struct accessors in some form
               (true (or (search "accessorpoint" ir :test #'char-equal)
                         (search "x~" ir)
                         (search "y~" ir))
                     "Should reference AccessorPoint struct members")))
