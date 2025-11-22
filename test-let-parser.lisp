;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.

;; tests/test-let-parser.lisp
(in-package :crisp.compiler)

(defun test-let-parsing ()
  "Parses a function with a 'let' expression and prints the resulting AST."
  (format t "~&--- Testing 'let' parser ---~%")
  
  ;; 1. Define the Crisp code as a Lisp form.
  ;;    We use a slightly more complex let to test multiple bindings.
  (let ((crisp-form '(def-function has-let (a)
                       (declare #'(int => int))
                       (let ((v 100)
                             (w (+ a 5)))
                         (+ v w)))))

    ;; 2. Expand the def-function macro to get the call to internal-def-function.
    (let ((expanded-form (macroexpand-1 crisp-form)))
      
      ;; 3. Evaluate the expanded form. This runs the semantic analyzer
      ;;    and returns the semantic-function AST node.
      (let ((ast (eval expanded-form)))
        
        ;; 4. Print the AST for inspection.
        (format t "~&Generated AST:~%")
        (pprint ast)
        (format t "~&--- Test complete ---~%")))))

;; To run this test from your REPL:
;; (test-let-parsing)
