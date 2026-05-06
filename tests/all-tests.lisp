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
                          #:visit-toplevel-form
                          #:char #:short #:float #:double #:truncate #:floor
                          #:ceil #:round
                          #:ceil #:round
                          #:let #:return)
  (:shadowing-import-from :common-lisp #:cond #:when #:unless))


(in-package :crisp.tests)

(defun validate-ir-with-clang (ir-string)
  "Uses the clang command-line tool to validate LLVM IR.
  Returns (values t nil) on success.
  Returns (values nil error-message) on failure."
  (handler-case
      (uiop:with-temporary-file (:stream stream :pathname path :type "ll")
        (write-string ir-string stream)
        (finish-output stream) ; Ensure the file is written to disk
        (multiple-value-bind (output error-output exit-code)
            ;; We run clang, telling it to treat input as IR (-x ir), compile only (-c),
          ;; and output to the null device.
          (uiop:run-program (list "clang" "-x" "ir" "-c" (uiop:native-namestring path)
                                  "-o" (uiop:native-namestring (uiop:null-device-pathname)))
            :output nil
            :error-output :string
            :ignore-error-status t)
          (declare (ignore output))
          (if (zerop exit-code)
              (values t nil) ; Success!
              (values nil (format nil "clang verification failed with exit code ~a:~%~a" exit-code error-output)))))
    ;; A more general fallback for other Lisp implementations
    (error (c)
      (if (search "No such file or directory" (princ-to-string c))
          (values nil (format nil "clang command not found. LLVM verifier could not be run.~%  ~a" c))
          (values nil (format nil "An error occurred while trying to run clang.~%  ~a" c))))))

(defmacro is-valid-ir (ir-form &optional (description "'is-valid-ir' check"))
  "A Parachute test that uses clang to validate generated IR."
  `(multiple-value-bind (success-p message) (validate-ir-with-clang ,ir-form)
     (true success-p (format nil "~a~%~:[~;~%LLVM verifier message:~%~a~]"
                       ,description (not success-p) message))))

(defmacro is-invalid-ir (ir-form &optional (description "'is-invalid-ir' check"))
  "A Parachute test that uses clang to validate generated IR."
  `(multiple-value-bind (success-p message) (validate-ir-with-clang ,ir-form)
     (true success-p (format nil "~a~%~:[~;~%LLVM verifier message:~%~a~]"
                       ,description (not success-p) message))))


(define-test crisp-compiler)

(defun count-substring (substring string)
  "Counts the number of non-overlapping occurrences of a substring."
  (let ((count 0)
        (len (length substring)))
    (loop for start = (search substring string)
          while start
          do (incf count)
            (setf string (subseq string (+ start len))))
    count))

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
             (let ((ir (compile-crisp-file-to-string "tests/spec/002-type-conversion/types.crisp")))
               (true (search "fadd float" ir)
                     "Expected to find 'fadd float' instruction.")))

(define-test (crisp-compiler di-type-generation)
             (let ((ir (compile-crisp-file-to-string "tests/spec/002-type-conversion/types.crisp" :debug-p t)))
               (true (search "!DIBasicType(name: \"uint\"" ir))
               (true (search "!DIBasicType(name: \"float\"" ir))))

(define-test (crisp-compiler promotion-casts)
             (let ((ir (compile-crisp-file-to-string "tests/spec/002-type-conversion/promotions.crisp")))
               (true (search "sitofp i32" ir))
               (true (search "uitofp i32" ir))
               (true (search "sext i8" ir))
               (true (search "fpext float" ir))))

(define-test (crisp-compiler explicit-casts)
             (let ((ir (compile-crisp-file-to-string "tests/spec/002-type-conversion/casts.crisp")))
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
                   'crisp-unknown-type-error)
             (is equal (list (intern "CELL_LONG_GLOBAL" :crisp.compiler)) (analyze-return-type-from-spec '(int => (cell long)))))

(define-test (analyzer environment-from-spec)
             (is equalp (list (crisp.compiler::make-parameter-def :name 'a :type 'int :kind :in)
                              (crisp.compiler::make-parameter-def :name 'b :type 'float :kind :in))
                 (analyze-environment-from-spec '(a b) '(int float => nil)))
             (fail (analyze-environment-from-spec '(a) '(bar => nil))
                   'crisp-unknown-type-error)
             (is equalp (list (crisp.compiler::make-parameter-def :name 'a
                                                                  :type (intern "CELL_LONG_GLOBAL" :crisp.compiler)
                                                                  :kind :in))
                 (analyze-environment-from-spec '(a) '((cell long) => nil))))

(define-test (analyzer return-type-from-list)
             (is equal '(int) (analyze-return-type-from-list '((return-type int))))
             (is equal '(float) (analyze-return-type-from-list '((return-type float))))
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
                            (true (search "ret i32 %iop_tmp, !dbg" ir)))))

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

(define-test (analyzer let-multi-value-bind)
             "Tests the semantic analysis of a multi-value 'let' binding."
             ;; We need a clean function table for this test to avoid conflicts.
             (let ((crisp.compiler::*function-table* (make-hash-table)))
               ;; Manually register a function signature that returns multiple values.
               (crisp.compiler::register-function-signature
                '(def-function test-mvr () (declare #'(=> int float))) nil)

               (let* ((crisp-form '(def-function has-mvb ()
                                                 (declare #'(=> int))
                                                 (let ((a b (test-mvr)))
                                                   a)))
                      (expanded-form (macroexpand-1 crisp-form))
                      (ast (eval expanded-form)))

                 (let* ((return-node (first (semantic-function-body ast)))
                        (let-node (semantic-return-value-node return-node)))
                   (true (typep let-node 'semantic-let))

                   ;; Check the bindings
                   (is = 2 (length (semantic-let-bindings let-node)))
                   (let* ((binding-a (first (semantic-let-bindings let-node)))
                          (binding-b (second (semantic-let-bindings let-node)))
                          (val-node-a (cdr binding-a))
                          (val-node-b (cdr binding-b)))
                     (is eq 'a (car binding-a))
                     (true (typep val-node-a 'semantic-extract-value))
                     (is = 0 (crisp.compiler::semantic-extract-value-index val-node-a))
                     (is eq 'int (crisp.compiler::semantic-extract-value-type val-node-a))

                     (is eq 'b (car binding-b))
                     (true (typep val-node-b 'semantic-extract-value))
                     (is = 1 (crisp.compiler::semantic-extract-value-index val-node-b))
                     (is eq 'float (crisp.compiler::semantic-extract-value-type val-node-b)))))))

#+(or) ;; Disabled pending def-record refactor
(define-test (analyzer make-scratch-cell-in-def-function)
             "Tests the semantic analysis of 'make-scratch-cell' within a function."
             (let* ((crisp-form '(def-function test-scratch ()
                                               (declare #'(=> (cell int)))
                                               (make-scratch-cell int)))
                    (expanded-form (macroexpand-1 crisp-form))
                    (ast (eval expanded-form)))

               ;; Check the overall structure
               (true (typep ast 'semantic-function) "The top-level AST node should be a semantic-function.")
               (is equal (list (intern "CELL_INT_GLOBAL_READ-WRITE" :crisp.compiler)) (crisp.compiler::semantic-function-return-type ast) "The function's return type should be (cell_int_global_read-write).")

               (let* ((return-node (first (semantic-function-body ast)))
                      (value-node (semantic-return-value-node return-node)))
                 (true (typep return-node 'semantic-return) "The function body should contain a semantic-return.")
                 (true (typep value-node 'semantic-literal) "The return value should be a semantic-literal.")
                 (is equal '(cell int) (crisp.compiler::semantic-literal-value-type value-node) "The literal's type should be (cell int)."))))

(define-test (analyzer phase-3-reconnaissance)
             "Tests the shallow analysis pass for building the call graph and finding originators."
             (let* ((forms '((def-function kernel (i) (declare #'(int => int)) (fun-a i))
                             (def-function fun-a (i) (declare #'(int => int)) (fun-b i))
                             (def-function fun-b (i) (declare #'(int => int))
                                           (let ((sc (make-scratch-cell int)))
                                             (+ i (fun-c sc))))
                             (def-function fun-c (sc) (declare #'((cell int) => int)) (+ 7 (fun-d sc)))
                             (def-function fun-d (sc) (declare #'((cell int) => int)) 8)))
                    ;; We need a clean environment for this test.
                    (crisp.compiler::*function-table* (make-hash-table))
                    (crisp.compiler::*call-graph* (make-hash-table))
                    (crisp.compiler::*originator-functions* (make-hash-table)))

               (crisp.compiler::analyze-signatures-pass forms)

               ;; Test 1: Was the originator function correctly identified?
               (true (gethash 'fun-b crisp.compiler::*originator-functions*)
                     "fun-b should be identified as an originator function.")
               (is = 1 (hash-table-count crisp.compiler::*originator-functions*)
                   "There should be exactly one originator function.")

               ;; Test 2: Was the call graph built correctly?
               (is equal '(fun-a) (gethash 'kernel crisp.compiler::*call-graph*))
               (is equal '(fun-b) (gethash 'fun-a crisp.compiler::*call-graph*))
               (is equal '(+ fun-c) (sort (copy-list (gethash 'fun-b crisp.compiler::*call-graph*)) #'string<))
               (is equal '(+ fun-d) (sort (copy-list (gethash 'fun-c crisp.compiler::*call-graph*)) #'string<))))

(define-test (analyzer phase-4-propagation)
             "Tests the backward propagation of implicit arguments through the call graph."
             (let* ((crisp.compiler::*call-graph* (make-hash-table))
                    (crisp.compiler::*originator-functions* (make-hash-table))
                    (crisp.compiler::*implicit-arg-map* (make-hash-table)))

               ;; 1. Manually set up the state from Phase 3.
               ;;    kernel -> fun-a -> fun-b (originator) -> fun-c
               (setf (gethash 'kernel crisp.compiler::*call-graph*) '(fun-a))
               (setf (gethash 'fun-a crisp.compiler::*call-graph*) '(fun-b))
               (setf (gethash 'fun-b crisp.compiler::*call-graph*) '(fun-c))
               (setf (gethash 'fun-c crisp.compiler::*call-graph*) '(fun-d))
               (setf (gethash 'fun-d crisp.compiler::*call-graph*) nil)
               (setf (gethash 'fun-b crisp.compiler::*originator-functions*) t)
               ;; Seed the implicit-arg-map for fun-b (originator) with the new (name . type) format
               (setf (gethash 'fun-b crisp.compiler::*implicit-arg-map*)
                 '((__sc . (cell int global read-write))))

               ;; 2. Run the propagation function.
               (crisp.compiler::propagate-implicit-arguments)

               ;; 3. Verify the results.
               (true (gethash 'fun-b crisp.compiler::*implicit-arg-map*) "Originator fun-b should be in the map.")
               (true (gethash 'fun-a crisp.compiler::*implicit-arg-map*) "Carrier fun-a should be in the map.")
               (true (gethash 'kernel crisp.compiler::*implicit-arg-map*) "Carrier kernel should be in the map.")
               (false (gethash 'fun-c crisp.compiler::*implicit-arg-map*) "Callee fun-c should NOT be in the map.")
               (is = 3 (hash-table-count crisp.compiler::*implicit-arg-map*) "Exactly 3 functions should be in the map.")))

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

(define-test (codegen let-multi-value-bind)
             "Tests that the LLVM IR for a multi-value 'let' bind is correct."
             ;; To test a call between two functions, we must compile them into the same module.
             (let* ((forms '((def-function test-mvr (x)
                                           (declare #'(int => int int))
                                           (return x (+ x 1)))
                             (def-function test-mvr-user (a)
                                           (declare #'(int => int))
                                           (let ((v w (test-mvr a)))
                                             (+ v w)))))
                    (ir (with-output-to-string (s)
                          (let ((*standard-output* s))
                            (let* ((module (llvm-module-create "test_mvb_module"))
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
               ;; Check for the single call to the MVR function
               (is = 1 (count-substring "call { i32, i32 } @test_mvr_int" ir)
                   "Should contain exactly one call to the multi-value return function.")

               ;; Check for the extractvalue instructions
               (true (search "%extract_0 = extractvalue { i32, i32 } %call_tmp, 0" ir))
               (true (search "%extract_1 = extractvalue { i32, i32 } %call_tmp, 1" ir))

               ;; Check that the extracted values are stored in variables 'v' and 'w'
               (true (search "store i32 %extract_0, ptr %v" ir))
               (true (search "store i32 %extract_1, ptr %w" ir))))

(define-test (codegen multiple-value-return)
             "Tests that a function returning multiple values generates correct IR."
             (let ((ir (compile-crisp-form-to-ir-string
                        '(def-function test-mvr ()
                                       (declare (return-type int float long))
                                       (return 7 3.14 (as-long 42))))))
               (is-valid-ir ir "Generated IR for MVR should be valid.")

               (true (search "define { i32, float, i64 } @test_mvr()" ir)
                     "Function should be defined to return a struct { i32, float, i64 }.")

               ;; LLVM can optimize constant returns into a single `ret` instruction with an aggregate constant.
               ;; We check for the components of the return instruction to make the test less brittle.
               (true (search "ret { i32, float, i64 } { i32 7" ir)
                     "The return instruction should start correctly and contain the integer constant.")
               (true (search "float 0x40091EB860000000" ir) ; Hex representation of 3.14
                     "The return instruction should contain the float constant.")
               (true (search "i64 42 }" ir)
                     "The return instruction should contain the long constant and end correctly.")))

#+(or) ;; Disabled pending def-record refactor
(define-test (codegen make-scratch-cell)
             "Tests that make-scratch-cell uses implicit arguments."
             ;; Manually register the implicit args for this test function
             ;; because compile-crisp-form-to-ir-string doesn't run the full analysis pass.
             (setf (gethash 'test-scratch crisp.compiler::*implicit-arg-map*) '(:storage-ptr :storage-size))

             (let ((ir (compile-crisp-form-to-ir-string
                        '(def-function test-scratch ()
                                       (declare (return-type (cell int)))
                                       (make-scratch-cell int)))))
               (is-valid-ir ir)

               ;; Check that we are loading the implicit arguments
               ;; Note: The exact variable names depend on how they are stored in var-env.
               ;; internal-def-function adds them as __storage_ptr and __storage_size.
               (true (search "load i64, ptr %__storage_ptr" ir) "Should load the storage pointer.")
               (true (search "load i64, ptr %__storage_size" ir) "Should load the storage size.")

               ;; Check for the cast from i64 to ptr
               (true (search "inttoptr i64" ir) "Should cast the storage pointer to a pointer type.")

               ;; Check that we are inserting the pointer and size into the struct
               ;; Check for insertvalue (constructing the cell struct)
               ;; Note: The struct name might vary (e.g. %CELL_INT vs %CELL_INT.0), so we just check for insertion.
               (true (search "insertvalue %CELL" ir) "Should insert into named Cell struct.")))

#+(or) ;; Disabled pending def-record refactor
(define-test (codegen cell-parameter-explosion)
             "Tests that a function with a cell parameter is compiled to take a pointer argument."
             (let ((ir (compile-crisp-form-to-ir-string
                        '(def-function test-cell-param (c)
                                       (declare (type c (cell int)) (return-type int))
                                       (return 0)))))
               (is-valid-ir ir)
               ;; Updated for Phase 5: Cell types are passed as pointers (handles)
               (true (search "define i32 @test_cell_param_cell_int" ir)
                     "Function should be defined with correct mangled name.")
               (true (search "(ptr" ir)
                     "Function signature should use a pointer for the CELL argument.")))

#+(or) ;; Disabled pending def-record refactor
(define-test (codegen cell-argument-explosion)
             "Tests that passing a cell to a function passes it as a pointer."
             ;; Updated for Phase 5
             (let ((ir (compile-crisp-form-to-ir-string
                        '(def-function pass-cell (c)
                                       (declare (type c (cell int)) (return-type int))
                                       (take-cell c)))))
               (is-valid-ir ir)

               ;; Should pass the cell as a single pointer
               (true (search "call i32 @take_cell_cell_int" ir) "Should call the function.")
               (true (search "(ptr" ir) "Should pass a pointer argument.")))

(define-test (codegen def-record-explosion)
             "Tests that def-record types are exploded into individual parameters in the IR."
             (let ((ir (compile-crisp-file-to-string "tests/spec/010-def-record/14-def-record-implose-explode.crisp")))
               (is-valid-ir ir)
               (true (search "define i32 @take_point_v_point(i32 %0, i32 %1)" ir)
                     "Function signature should be exploded into individual fields (i32, i32).")
               (true (search "insertvalue %V-POINT undef, i32 %0, 0" ir)
                     "Should start reconstructing the V-POINT record from the first argument.")
               (true (search "insertvalue %V-POINT %X_ins, i32 %1, 1" ir)
                     "Should continue reconstructing the V-POINT record from the second argument.")
               (true (search "extractvalue %V-POINT" ir)
                     "Should extract values from the V-POINT record to pass them.")
               (true (search "call i32 @take_point_v_point(i32 %X_val, i32 %Y_val)" ir)
                     "Should call the function with exploded arguments.")))


(define-test template-macro-exists
             (true (macro-function 'crisp.compiler::with-template-type) "with-template-type should be a defined macro"))

(define-test gen-macro-creation
             (let ((form '(with-template-type (T)
                                              (def-function test-gen-macro (x)
                                                            (declare #'(T => T))
                                                            x))))
               (eval form)
               (true (macro-function (intern "GEN-TEST-GEN-MACRO")) "gen-test-gen-macro should be defined")
               (true (macro-function (intern "TEST-GEN-MACRO-TYPE")) "test-gen-macro-type should be defined")))

(define-test template-instantiation
             (let ((form '(with-template-type (T)
                                              (def-function test-instantiation (x)
                                                            (declare #'(T => T))
                                                            x))))
               (eval form)
               (let* ((gen-form '(gen-test-instantiation int))
                      (expanded (macroexpand-1 gen-form))) ;; Expanded form should be (TEMPLATE-INSTANTIATION (PROGN (DEF-FUNCTION ...)))
                 (true (listp expanded))
                 (is eq (intern "TEMPLATE-INSTANTIATION" :crisp.compiler) (first expanded))
                 (let* ((progn-form (second expanded))
                        (def-func (second progn-form)))
                   (is eq 'progn (first progn-form))
                   (is eq 'def-function (first def-func))
                   (is eq 'test-instantiation (second def-func))
                   (let ((decl (find-if (lambda (x) (and (listp x) (eq (first x) 'declare))) (cdddr def-func))))
                     (true decl "Should have a declaration")
                     (let ((sig (second decl)))
                       ;; Signature should be (INT => INT)
                       (is equal '(function (int => int)) sig)))))))

(define-test reader-macro-reading
             (let ((input "(<T> (def-function test-reader (x) (declare #'(T => T)) x))"))
               (let ((form (read-from-string input)))
                 ;; Form should be (|<T>| (def-function ...))
                 ;; And |<T>| should be a macro that expands to (with-template-type (T) ...)
                 (true (listp form))
                 (let ((macro-symbol (first form)))
                   (true (symbolp macro-symbol))
                   (is string= "<T>" (symbol-name macro-symbol))
                   (true (macro-function macro-symbol) "|<T>| should be a defined macro") ;; Check expansion
                   (let ((expanded (macroexpand-1 form)))
                     (is eq 'with-template-type (first expanded))
                     (is equal '(T) (second expanded)))))))

(define-test reader-macro-conflict
             ;; Test that the reader macro doesn't break standard symbols or operators
             (let ((input "(< a b) (string< \"a\" \"b\") (<= a b) (<< a 1)"))
               (let ((forms (read-from-string (format nil "(~a)" input))))
                 ;; Should read as ((< a b) (string< "a" "b") (<= a b) (<< a 1))
                 (true (listp forms))
                 (is = 4 (length forms))

                 ;; Check < operator
                 (let ((op1 (first (first forms))))
                   (is string= "<" (symbol-name op1))
                   (false (macro-function op1) "< should not be a macro"))

                 ;; Check string< symbol
                 (let ((op2 (first (second forms))))
                   (is string= "STRING<" (symbol-name op2))
                   (false (macro-function op2) "string< should not be a macro"))

                 ;; Check <= operator
                 (let ((op3 (first (third forms))))
                   (is string= "<=" (symbol-name op3))
                   (false (macro-function op3) "<= should not be a macro"))

                 ;; Check << operator
                 (let ((op4 (first (fourth forms))))
                   (is string= "<<" (symbol-name op4))
                   (false (macro-function op4) "<< should not be a macro")))))
(define-test (crisp-compiler visit-toplevel-form-check)
             "Verifies that visit-toplevel-form correctly recursively visits nodes."
             (let ((visited-paths '()))
               (visit-toplevel-form
                '(progn
                  (def-function f1 () nil)
                  (progn
                   (def-function f2 () nil)))
                '(0)
                (lambda (form loc)
                  (push (list (second form) loc) visited-paths)))
               ;; We expect:
               ;; 1. f1 at (0 0)
               ;; 2. f2 at (0 1 0)
               ;; Since we push to a list, they will be in reverse order.
               (true (equal visited-paths '((f2 (0 1 0)) (f1 (0 0))))
                     (format nil "Expected traversal paths to match, got: ~a" visited-paths))))

(define-test (crisp-compiler template-instantiation-hook-check)
             "Verifies that the template hook is correctly set up."
             ;; 1. It should be initialized (non-nil)
             (true crisp.compiler::*template-instantiator-fn*
                   "Template hook should be initialized.")

             ;; 2. It should be equal to #'ensure-template-instantiation
             (is eq #'crisp.compiler::ensure-template-instantiation crisp.compiler::*template-instantiator-fn*))

(define-test (crisp-compiler parse-function-declarations-check)
             "Verifies the unified function signature parsing logic."

             ;; Case 1: #'(...) syntax (Modern)
             (multiple-value-bind (env return-types)
                 (crisp.compiler::parse-function-declarations '(a b)
                                                              '((function (int float => int))))
               (is equalp (list (crisp.compiler::make-parameter-def :name 'a :type 'int :kind :in)
                                (crisp.compiler::make-parameter-def :name 'b :type 'float :kind :in)) env)
               (is equal '(int) return-types))

             ;; Case 2: Legacy (type ...) and (return-type ...) syntax
             ;; Note: Legacy parser currently assumes all params match the list in (type names... type)
             (multiple-value-bind (env return-types)
                 (crisp.compiler::parse-function-declarations '(x y)
                                                              '((type x y int) (return-type int)))
               (is equalp (list (crisp.compiler::make-parameter-def :name 'x :type 'int :kind :in)
                                (crisp.compiler::make-parameter-def :name 'y :type 'int :kind :in)) env)
               (is equal '(int) return-types))

             ;; Case 3: Mixed (Function spec takes precedence)
             (multiple-value-bind (env return-types)
                 (crisp.compiler::parse-function-declarations '(a)
                                                              '((function (float => float)) (type a int)))
               (is equalp (list (crisp.compiler::make-parameter-def :name 'a :type 'float :kind :in)) env)
               (is equal '(float) return-types)))
