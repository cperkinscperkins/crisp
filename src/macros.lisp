;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.

;; src/macros.lisp
(in-package :crisp.compiler)

(defmacro let (bindings &body body)
  "A unified 'let' for Crisp that works in both Kernels and Macros.
   - It is SEQUENTIAL (like CL:LET*).
   - It supports Multi-Value-Binding (MVB) destructuring.
   
   Example:
     (let ((a 1)
           (b 2)
           ((q r) (floor 10 3)))
       (+ a b q r))

   This macro expands into a nest of CL:LET* and CL:MULTIPLE-VALUE-BIND
   forms, suitable for execution in the Lisp host (macros/tests).
   
   When compiling Kernels, the Crisp Compiler intercepts the 'let' symbol
   directly and uses its own semantic analyzer, ignoring this macro."

  (cl:cond
    ;; Base Case: No bindings left -> just the body (in a progn)
    ((null bindings)
     `(progn ,@body))

    ;; Recursive Case: Process one binding
    (t
     (cl:let* ((binding (first bindings))
               (rest-bindings (rest bindings)))
       (cl:cond
         ;; Case 1: Explicit Destructuring -> ((a b) (values 1 2))
         ((and (listp binding) (listp (first binding)))
          (cl:let ((vars (first binding))
                   (val-form (second binding)))
            `(multiple-value-bind ,vars ,val-form
               (let ,rest-bindings ,@body))))

         ;; Case 2: Flattened Destructuring -> (a b (values 1 2))
         ((and (listp binding) (> (length binding) 2))
          (cl:let* ((vars (butlast binding))
                    (val-form (first (last binding))))
            `(multiple-value-bind ,vars ,val-form
               (let ,rest-bindings ,@body))))

         ;; Case 3: Standard Binding -> (a 1) or (a) or a
         (t
          ;; Normalize 'a' to '(a nil)' and '(a)' to '(a nil)' if needed, 
          ;; but CL:LET* handles (a) and a natively.
          `(cl:let* (,binding)
             (let ,rest-bindings ,@body))))))))
;; --- Branching Macros ---

(defmacro when (test &body body)
  `(if ,test (progn ,@body)))

(defmacro unless (test &body body)
  `(if (not ,test) (progn ,@body)))

(defmacro cond (&rest clauses)
  (if (null clauses)
      nil
      (let* ((clause (first clauses))
             (rest (rest clauses))
             (test (first clause))
             (forms (rest clause)))
        (if (or (eq test 'else) (eq test t))
            `(progn ,@forms)
            `(if ,test
                 (progn ,@forms)
                 (cond ,@rest))))))

(defmacro if+ (test then &optional else)
  "Compile-time conditional. Evaluates TEST at macro-expansion time.
   Errors if TEST cannot be evaluated (e.g. relies on runtime values)."
  (cl:let ((val (handler-case (eval test)
                  (error (e)
                    (error "IF+ condition failed to evaluate at compile time: ~s.~%Error: ~a" test e)))))
    (if val
        then
        else)))
