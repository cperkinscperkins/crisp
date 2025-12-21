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

;; --- Compile-Time Utilities ---

(defun compiler-no-op ()
  "A no-op function that returns no values. 
   Used as the expansion target for compile-time macros when evaluated in the host environment."
  (values))

(defmacro c-t-output (&rest args)
  "Compile-Time Output. Evaluates arguments at macro-expansion time and prints them."
  (let ((output-string
         (with-output-to-string (s)
           (dolist (arg args)
             (let ((val (eval arg)))
               (format s "~a " val))))))
    (format *standard-output* "~&~a~%" output-string)
    ;; Return a no-op form for the compiler to process (and ignore)
    `(compiler-no-op)))


;; Core Language Macros
;; ====================

(defmacro def-function (name params &rest body-and-location)
  "Defines a new, thread-level Crisp function."
  (when (string-equal (symbol-name name) "~REF~")
        (error 'crisp-illegal-overload-error :name name))
  ;; Find the position of our injected :source-location keyword.
  (let* ((loc-pos (position :source-location body-and-location))
         ;; The source location is the value right after the keyword.
         (source-location (when loc-pos (nth (1+ loc-pos) body-and-location)))
         ;; The "real" body is everything before the keyword.
         (body (if loc-pos (subseq body-and-location 0 loc-pos) body-and-location)))
    (log:debug "which package?: ~a ~%" *package*)

    ;; Eagerly register the signature for single-pass compilation scenarios.
    ;; This ensures that when loading a file, function signatures are known
    ;; before they are called by subsequent functions in the same file.
    (register-function-signature `(def-function ,name ,params ,@body) source-location)

    (log:debug "name: ~a  params: ~a  body: ~a ~%source-location: ~a~%"
               name params body source-location)
    ;; Handle declarations (this part is tricky, let's simplify)
    (let* ((declare-forms
            (loop for form in body
                  while (and (listp form) (eq (car form) 'declare))
                  collect form))
           (declarations (loop for form in declare-forms append (rest form)))
           (body-forms (nthcdr (length declare-forms) body)))

      `(internal-def-function
        ',name
        ',params
        ',declarations ;  '(((type a b int)) ((return-type int)))
        ',body-forms ;  '((+ a b))
        ,source-location))))

(defmacro with-struct-accessors (struct-type bindings &body body)
  "Iterates over the members of a struct type, binding accessor symbols to the provided variables.
   Bindings: (aos-var [soa-var] [:access type])
   Returns a PROGN containing the expanded body forms."
  (let* ((aos-var (first bindings))
         (rest-bindings (rest bindings))
         ;; Manual parsing of optional SOA-VAR and keys
         (soa-var (if (and rest-bindings (not (keywordp (first rest-bindings))))
                      (pop rest-bindings)
                      nil))
         (access (let ((k (getf rest-bindings :access)))
                   (if k k :public)))
         (struct-def (gethash struct-type *crisp-structs*)))

    (unless struct-def
      (error "Unknown struct type '~a' in with-struct-accessors." struct-type))

    (let ((forms '()))
      (dolist (member (crisp-struct-definition-members struct-def))
        (let* ((member-name (first member))
               (aos-accessor-name
                (ecase access
                  (:public (intern (format nil "~a~~" member-name)))
                  (:raw (intern (format nil "~~~a~~" member-name)))))
               (soa-accessor-name (intern (format nil "~a~~" member-name))))

          (let ((expanded-body
                 (mapcar (lambda (form)
                           (let ((f (subst aos-accessor-name aos-var form)))
                             (if soa-var
                                 (subst soa-accessor-name soa-var f)
                                 f)))
                     body)))
            (setf forms (append forms expanded-body)))))

      `(progn ,@forms))))

(defmacro def-struct (name &rest members)
  "Defines a new Crisp struct type."
  (let* ((parsed-members (mapcar #'parse-struct-member-spec members))
         (constructor-name (intern (format nil "MAKE-~a" name))))
    ;; Register at macro-expansion time (for visibility to subsequent code)
    (register-struct-definition name parsed-members)
    ;; Emit code to register using eval-when, AND the constructor MACRO
    `(progn
      (eval-when (:compile-toplevel :load-toplevel :execute)
        (register-struct-definition ',name ',parsed-members))

      (defmacro ,constructor-name (&rest args)
        (let ((reordered (validate-and-reorder-struct-args ',name ',parsed-members args)))
          `(%construct-struct ,',name ,@reordered)))

      ,@(let ((runtime-index 0)
              (pkg (symbol-package name)))
          (loop for member-spec in parsed-members
                collect
                  (let* ((member-name (first member-spec))
                         (is-ct (and (consp member-spec) (eq (third member-spec) :c-t)))
                         (value (when is-ct (fourth member-spec))) ;; (name type :c-t value)
                         (accessor-name (intern (format nil "~a~~" member-name) pkg)))
                    (if is-ct
                        ;; Generate Compile-Time Constant Accessor Macro
                        `(defmacro ,accessor-name (obj)
                           (declare (ignore obj))
                           ;; If a value is provided, return it as a constant.
                           (if ',value
                               '',value
                               ;; Otherwise error? Or return nil? User should provide value.
                               (error "Compile-time struct member ~a accessed but has no constant value defined." ',member-name)))
                        ;; Generate Runtime Accessor Function
                        (let ((idx runtime-index))
                          (incf runtime-index)
                          `(def-function ,accessor-name ((obj ,name))
                                         (return (%extract-struct-member obj ,idx))))))))
      ,@(let ((runtime-index 0)
              (pkg (symbol-package name)))
          (loop for member-spec in parsed-members
                  unless (and (consp member-spec) (eq (third member-spec) :c-t))
                collect
                  (let* ((member-name (first member-spec))
                         (raw-accessor-name (intern (format nil "~~~a~~" member-name) pkg))
                         (idx runtime-index))
                    (incf runtime-index)
                    `(def-function ,raw-accessor-name ((obj ,name))
                                   (declare (crisp-system-generated))
                                   (return (%extract-struct-member obj ,idx)))))))))

(defmacro def-setter (name args &body body)
  "Defines a setter function (which is just a def-function but semantically intended for use with set!).
   The return type is implicitly nil/void. We append (return) to ensure this."
  (when (string-equal (symbol-name name) "~REF~")
        (error 'crisp-illegal-overload-error :name name))
  (let ((setter-name (intern (format nil "~a_SET!" (symbol-name name)) (symbol-package name))))
    `(def-function ,setter-name ,args ,@body (return))))

(defmacro r-t-assert (test &rest args)
  "Asserts that TEST is true at runtime. If not, terminates kernel.
   Args (message strings etc) are currently ignored."
  (declare (ignore args))
  (if *runtime-checks-enabled*
      `(unless ,test (die))
      nil))

(defmacro c-t-assert (condition message)
  "Compile-Time Assertion."
  `(eval-when (:compile-toplevel :load-toplevel :execute)
     (unless ,condition
       (error "Compile-Time Assertion Failed: ~a" ,message))))

(defmacro r-t-assert-0 (test &rest args)
  "Asserts that TEST is true at runtime (placeholder for thread-0 check)."
  `(r-t-assert ,test ,@args))
