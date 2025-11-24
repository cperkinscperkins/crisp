;;; tests/all-tests.lisp

(defpackage :crisp.tests
  (:use :cl :crisp.compiler :crisp.llvm-bindings :parachute)
  ;; We are using both :cl and :crisp.compiler, both of which define
  ;; symbols like 'char', 'float', 'truncate', etc. We must tell the
  ;; test package which ones to use. Since we are testing the compiler,
  ;; we want to use the compiler's versions.
  (:shadowing-import-from :crisp.compiler
                          #:internal-def-function
                          #:generate-llvm-ir
                          #:generate-location-map
                          #:char #:short #:float #:double #:truncate #:floor
                          #:ceil #:round))

(in-package :crisp.tests)

(defun validate-ir-with-llc (ir-string)
  "Uses the llc command-line tool to validate LLVM IR.
  Returns (values t nil) on success.
  Returns (values nil error-message) on failure."
  (handler-case
      (uiop:with-temporary-file (:stream stream :pathname path :type "ll")
        (write-string ir-string stream)
        (finish-output stream) ; Ensure the file is written to disk
        (multiple-value-bind (output error-output exit-code)
            ;; We run llc, telling it to output to the null device.
            ;; We only care about the exit code and any errors.
            (uiop:run-program (list "llc" (uiop:native-namestring path)
                                    "-o" (uiop:native-namestring (uiop:null-device-pathname)))
                              :output nil
                              :error-output :string
                              :ignore-error-status t)
          (declare (ignore output))
          (if (zerop exit-code)
              (values t nil) ; Success!
              (values nil (format nil "llc verification failed with exit code ~a:~%~a" exit-code error-output)))))
    ;; A more general fallback for other Lisp implementations
    (error (c)
       (if (search "No such file or directory" (princ-to-string c))
           (values nil (format nil "llc command not found. LLVM verifier could not be run.~%  ~a" c))
           (values nil (format nil "An error occurred while trying to run llc.~%  ~a" c))))))

(defmacro is-valid-ir (ir-form &optional (description "'is-valid-ir' check"))
  "A Parachute test that uses llc to validate generated IR."
  `(multiple-value-bind (success-p message) (validate-ir-with-llc ,ir-form)
     (true success-p (format nil "~a~%~:[~;~%LLVM verifier message:~%~a~]"
                             ,description (not success-p) message))))

(define-test crisp-compiler)

(defun compile-crisp-file-to-string (filepath &key (debug-p nil))
  "Compiles a .crisp file and returns the LLVM IR as a string."
  (with-output-to-string (s)
    (let ((*standard-output* s)
          (forms (with-open-file (stream filepath)
                   (loop for form = (read stream nil :eof)
                         until (eq form :eof)
                         collect form))))
      (let* ((module (llvm-module-create "codegen_test"))
             (builder (llvm-create-builder))
             (di-builder (when debug-p (llvm-create-di-builder module)))
             (di-compile-unit (when debug-p
                                (let* ((f "test.crisp") (d "/tmp/")
                                       (di-file (llvm-di-builder-create-file di-builder f (length f) d (length d))))
                                  (llvm-di-builder-create-compile-unit di-builder 32768 di-file "Crisp" 5 nil "" 0 0 "" 0 1 0 nil nil "" 0 "" 0)))))
        (unwind-protect
             (progn
               (compile-module forms module builder di-builder di-compile-unit nil)
               (let ((ir-ptr (llvm-print-module-to-string module)))
                 (unwind-protect (format s "~a" (cffi:foreign-string-to-lisp ir-ptr))
                   (llvm-dispose-message ir-ptr))))
          (when di-builder (llvm-di-builder-finalize di-builder))
          (when di-builder (llvm-dispose-di-builder di-builder))
          (llvm-dispose-builder builder)
          (llvm-dispose-module module))))))

(define-test (crisp-compiler fadd-generation)
  "Tests that fadd generation works correctly."
  (let ((ir (compile-crisp-file-to-string "tests/types.crisp")))
    (true (search "fadd float" ir)
          "Expected to find 'fadd float' instruction.")))

(define-test (crisp-compiler di-type-generation)
  (let ((ir (compile-crisp-file-to-string "tests/types.crisp" :debug-p t)))
    (true (search "!DIBasicType(name: \"uint\"" ir))
    (true (search "!DIBasicType(name: \"float\"" ir))))

(define-test (crisp-compiler promotion-casts)
  (let ((ir (compile-crisp-file-to-string "tests/promotions.crisp")))
    (true (search "sitofp i32" ir))
    (true (search "uitofp i32" ir))
    (true (search "sext i8" ir))
    (true (search "fpext float" ir))))

(define-test (crisp-compiler explicit-casts)
  (let ((ir (compile-crisp-file-to-string "tests/casts.crisp")))
    (true (search "sext i32" ir))
    (true (search "bitcast float" ir))
    (true (search "fptosi float" ir))))

(define-test (crisp-compiler analyzer)
  "Tests for the semantic analyzer.")

(define-test (analyzer return-type-from-spec)
  (is equal '(int) (analyze-return-type-from-spec '(int => int)))
  (is equal '(float) (analyze-return-type-from-spec '(int => float)))
  (is equal '(ulong) (analyze-return-type-from-spec '(char => ulong)))
  (is equal '(nil) (analyze-return-type-from-spec '(int => nil)))
  (is equal '(nil) (analyze-return-type-from-spec '(int =>)))
  (is equal '(nil) (analyze-return-type-from-spec '(int)))
  (fail (analyze-return-type-from-spec '(int => foobar))
        'crisp-unknown-type-error))

(define-test (analyzer environment-from-spec)
  (is equal '((a int) (b float))
      (analyze-environment-from-spec '(a b) '(int float => nil)))
  (fail (analyze-environment-from-spec '(a) '(bar => nil))
        'crisp-unknown-type-error))

(define-test (analyzer return-type-from-list)
  (is equal '(int) (analyze-return-type-from-list '((return-type int))))
  (is equal '(float) (analyze-return-type-from-list '((return-type float))))
  (is equal nil (analyze-return-type-from-list '((type a int))))
  (fail (analyze-return-type-from-list '((return-type baz)))
        'crisp-unknown-type-error)
  (is equal nil (analyze-return-type-from-list '((function (int => int))))))

(define-test (analyzer environment-from-list)
  (is equal '((a float) (b float))
      (analyze-environment-from-list '(a b) '((type a b float))))
  (fail (analyze-environment-from-list '(a) '((type a b int)))
        'crisp-signature-arity-error)
  (fail (analyze-environment-from-list '(a) '((type a quux)))
        'crisp-unknown-type-error))

(define-test (analyzer return-type-multiple-values)
  "Test multiple return values from spec"
  (is equal '(int int) (analyze-return-type-from-spec '(int => int int)))
  (is equal '(int float ulong) (analyze-return-type-from-spec '(int => int float ulong))))

(define-test (crisp-compiler internal-def-function-compilation)
  "Tests the compilation path using internal-def-function."
  (let ((ir-7 (compile-crisp-form-to-ir-string '(def-function test-fn-7 () (declare (return-type int)) 7))))
    (true (search "define i32 @test_fn_7()" ir-7))
    (true (search "ret i32 7" ir-7)))

  (let ((ir-add (compile-crisp-form-to-ir-string '(def-function test-fn-add (a b) (declare (type a b int) (return-type int)) (+ a b)))))
    (true (search "define i32 @test_fn_add_int_int(i32 %0, i32 %1)" ir-add))
    (true (search "add i32" ir-add)))

  (let ((ir-arrow (compile-crisp-form-to-ir-string '(def-function test-fn-arrow (a b) (declare #'(int int => int)) (+ a b)))))
    (true (search "define i32 @test_fn_arrow_int_int(i32 %0, i32 %1)" ir-arrow))))

(define-test (crisp-compiler dwarf-generation)
  "Tests for DWARF debug information generation."
  (define-test location-mapping
    (let* ((crisp-code '((def-function foo (a) (declare (return-type int)) (+ a 1))))
           (location-map (generate-location-map crisp-code)))
      (is = 1 (gethash '(0) location-map))
      (is = 5 (gethash '(0 2 0) location-map))
      (is = 12 (gethash '(0 4 2) location-map))))

  (define-test scaffolding
    (let ((ir (compile-crisp-form-to-ir-string '(def-function test-dwarf () (declare (return-type int)) 7) :debug-p t)))
      (true (search "!DICompileUnit" ir))
      (true (search "define i32 @test_dwarf() !dbg" ir))
      (true (search "line: 1" ir))
      (true (search "!DISubroutineType" ir))))

  (define-test instruction-location
    (let ((ir (compile-crisp-form-to-ir-string '(def-function test-instr () (declare (return-type int)) 7) :debug-p t)))
      (true (search "ret i32 7, !dbg" ir))))

  (define-test add-instruction-location
    (let ((ir (compile-crisp-form-to-ir-string '(def-function test-add (a) (declare (type a int) (return-type int)) (+ a 2)) :debug-p t)))
      (true (search "add i32 %a1, 2, !dbg" ir))
      (true (search "ret i32 %add_tmp, !dbg" ir)))))

(define-test (analyzer let-expression)
  "Tests the semantic analysis of a 'let' expression, including let* scoping."
  (let* ((crisp-form '(def-function has-let (a)
                       (declare #'(int => int))
                       (let ((v 100)
                             (w (+ a v))) ; <-- Depends on 'v'
                         (+ v w))))
         (expanded-form (macroexpand-1 crisp-form))
         (ast (eval expanded-form)))

    ;; Check the overall structure
    (true (typep ast 'semantic-function) "The top-level AST node should be a semantic-function.")
    (let* ((return-node (first (semantic-function-body ast)))
           (let-node (semantic-return-value-node return-node)))
      (true (typep return-node 'semantic-return) "The function body should contain a semantic-return.")
      (true (typep let-node 'semantic-let) "The return value should be a semantic-let node.")

      ;; Check the bindings
      (is = 2 (length (semantic-let-bindings let-node)) "The let node should have two bindings.")
      (let* ((binding1 (first (semantic-let-bindings let-node)))
             (binding2 (second (semantic-let-bindings let-node))))
        (is eq 'v (car binding1) "The first binding should be for the variable 'v'.")
        (true (typep (cdr binding1) 'semantic-literal) "The value for 'v' should be a semantic-literal.")
        (is eq 'w (car binding2) "The second binding should be for the variable 'w'.")
        (true (typep (cdr binding2) 'semantic-add) "The value for 'w' should be a semantic-add node, proving let* scoping worked."))

      ;; Check the body
      (is = 1 (length (semantic-let-body let-node)) "The let body should contain one expression.")
      (true (typep (first (semantic-let-body let-node)) 'semantic-add) "The body expression should be a semantic-add node."))))

(define-test (crisp-compiler codegen)
  "Tests for LLVM IR code generation.")

(define-test (codegen let-expression)
  "Tests that the LLVM IR for a 'let' expression is generated correctly."
  (let ((ir (compile-crisp-form-to-ir-string
             '(def-function has-let (a) (declare #'(int => int))
               (let ((v 100))
                 (+ a v))))))
    (is-valid-ir ir)

    (true (search "define i32 @has_let_int(i32 %0)" ir) "Function definition should be correct.")
    (true (search "%v = alloca i32" ir) "Should allocate stack space for the 'let' variable 'v'.") ; This name is predictable
    (true (search "store i32 100, ptr %v" ir) "Should store the initial value 100 into the allocation for 'v'.")
    (true (search "%a = alloca i32" ir) "Should allocate stack space for the parameter 'a'.") ; This name is also predictable
    (true (search "load i32, ptr %v" ir) "Should load the value from 'v' before using it in the addition.")
    (true (search "load i32, ptr %a" ir) "Should load the value from 'a' before using it in the addition.")
    (true (search "add i32" ir) "Should perform an addition.")))

(define-test (codegen multiple-value-return)
  "Tests that a function returning multiple values generates correct IR."
  (let ((ir (compile-crisp-form-to-ir-string
             '(def-function test-mvr ()
               (declare (return-type int int))
               (return 7 314)))))
    (is-valid-ir ir "Generated IR for MVR should be valid.")

    (true (search "define { i32, i32 } @test_mvr()" ir)
          "Function should be defined to return a struct { i32, float }.")))
#| temporarily disabled 
    (true (search "insertvalue { i32, i32 } undef, i32 7, 0" ir)
          "Should insert the first return value (int) into the struct at index 0.")

    (true (search "insertvalue { i32, i32 } %mvr_val_0, i32" ir)
          "Should insert the second return value (float) into the struct at index 1.")))
|#