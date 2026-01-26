;;;
;;;  sbcl --load  ./scripts/call-graph.lisp --non-interactive
;;;

(require :sb-introspect)
(require :asdf)

(defpackage :crisp.call-graph
  (:use :cl)
  (:export :main))

(in-package :crisp.call-graph)

;;; ---------------------------------------------------------------------------
;;; Project Loading 
;;; ---------------------------------------------------------------------------

(defun load-project ()
  (format t "~&Loading Crisp system to ensure packages exist...~%")
  (let ((cwd (uiop:getcwd)))
    (push cwd ql:*local-project-directories*))
  (ql:register-local-projects)
  (handler-case
      (ql:quickload "crisp" :silent t)
    (error (e)
      (format *error-output* "~&Warning: Failed to load crisp system: ~a~%" e)
      (format *error-output* "Continuing, but READ might fail on package prefixes.~%"))))

;;; ---------------------------------------------------------------------------
;;; Data Structures
;;; ---------------------------------------------------------------------------

(defparameter *call-graph* (make-hash-table :test #'equal))
;; Key: Caller Name (String)
;; Value: List of Callee Names (Strings)

(defparameter *all-functions* '()) ; List of strings
(defparameter *defined-functions-set* (make-hash-table :test #'equal)) ; Set for fast lookup

;;; ---------------------------------------------------------------------------
;;; Filtering
;;; ---------------------------------------------------------------------------

(defparameter *ignored-functions*
              '("LET" "LET*" "COND" "IF" "WHEN" "UNLESS" "RETURN" "SETF" "SETQ" "PROGN"
                      "CASE" "TYPECASE" "ETYPECASE" "CTYPECASE" "MULTIPLE-VALUE-BIND"
                      "MULTIPLE-VALUE-CALL" "UNWIND-PROTECT" "BLOCK" "TAGBODY" "GO"
                      "LOOP" "DO" "DOTIMES" "DOLIST" "ASSERT" "CHECK-TYPE" "LOCALLY"
                      "RETURN-FROM" "THROW" "CATCH" "DECLAIM" "DECLARE"))

;;; ---------------------------------------------------------------------------
;;; Walker
;;; ---------------------------------------------------------------------------

(defun register-call (caller callee)
  (let ((callee-s (symbol-name callee)))
    ;; Only register if callee is one of OUR functions
    (when (gethash callee-s *defined-functions-set*)
          (let ((current (gethash caller *call-graph*)))
            (pushnew callee-s current :test #'string=)
            (setf (gethash caller *call-graph*) current)))))

(defun walk-body (func-name body)
  (labels ((walker (form)
                   (cond
                    ;; 1. CONS: Expression
                    ((consp form)
                      (let ((op (car form))
                            (args (cdr form)))

                        (cond
                         ;; Special Form: QUOTE -> Stop
                         ((eq op 'QUOTE) nil)

                         ;; Symbol Operator -> Register Call
                         ((symbolp op)
                           (register-call func-name op)
                           ;; Recurse on args
                           (if (listp args)
                               (dolist (arg args) (walker arg))
                               (walker args)))

                         ;; Complex Operator (e.g. ((lambda ...) args) or bindings) -> Walk Op too
                         (t
                           (walker op)
                           (if (listp args)
                               (dolist (arg args) (walker arg))
                               (walker args))))))

                    ;; 2. Atom: Ignore
                    (t nil))))

    ;; Iterate body forms
    (dolist (form body) (walker form))))

;;; ---------------------------------------------------------------------------
;;; Scanning
;;; ---------------------------------------------------------------------------

(defun scan-definitions (form)
  (when (and (consp form) (symbolp (car form)))
        (let ((op (symbol-name (car form))))
          (cond
           ((member op '("DEFUN" "DEFMACRO" "DEF-FUNCTION" "DEF-KERNEL" "DEF-GRID-FUNCTION" "DEFMETHOD") :test #'string=)
             (let ((name (second form)))
               (when (symbolp name)
                     (let ((s-name (symbol-name name)))
                       (unless (member s-name *ignored-functions* :test #'string=)
                         (pushnew s-name *all-functions* :test #'string=)
                         (setf (gethash s-name *defined-functions-set*) t))))))))))

(defun scan-calls (form)
  (when (and (consp form) (symbolp (car form)))
        (let ((op (symbol-name (car form))))
          (cond
           ((member op '("DEFUN" "DEFMACRO" "DEF-FUNCTION" "DEF-KERNEL" "DEF-GRID-FUNCTION" "DEFMETHOD") :test #'string=)
             (let ((name (second form))
                   (body (cddr form)))
               (when (symbolp name)
                     (let ((s-name (symbol-name name)))
                       (unless (member s-name *ignored-functions* :test #'string=)
                         (walk-body s-name body))))))))))

(defun process-file (path pass-fn)
  (with-open-file (in path :direction :input :if-does-not-exist nil)
    (when in
          (loop
           (let ((form (handler-case (read in nil :eof) (error (e) :error))))
             (cond
              ((eq form :eof) (return))
              ((eq form :error) nil)
              (t (funcall pass-fn form))))))))

;;; ---------------------------------------------------------------------------
;;; Output
;;; ---------------------------------------------------------------------------

(defparameter *printed-functions* (make-hash-table :test #'equal))

(defun print-tree (node depth visited stream)
  ;; Simple indentation loop
  (dotimes (i depth) (format stream " "))
  (format stream "- ~a" node)

  (cond
   ;; 1. Recursion Check (Cycle in current stack)
   ((member node visited :test #'string=)
     (format stream " [RECURSION]~%"))

   ;; 2. Already Expanded Check (Global DAG optimization)
   ((gethash node *printed-functions*)
     (format stream " [See above]~%"))

   ;; 3. Expand Children
   (t
     (setf (gethash node *printed-functions*) t)
     (let ((callees (gethash node *call-graph*))
           (new-visited (cons node visited)))
       (format stream "~%")
       (dolist (child callees)
         (print-tree child (+ depth 2) new-visited stream))))))

(defun find-roots ()
  ;; Roots are defined functions that are NOT called by any other defined function
  (let ((called-set (make-hash-table :test #'equal)))
    (maphash (lambda (k v)
               (declare (ignore k))
               (dolist (callee v)
                 (setf (gethash callee called-set) t)))
             *call-graph*)

    (let ((roots '()))
      (dolist (fn *all-functions*)
        (unless (gethash fn called-set)
          (push fn roots)))

      ;; Sort: MAIN first, then alphabetical
      (sort roots (lambda (a b)
                    (cond
                     ((string= a "MAIN") t)
                     ((string= b "MAIN") nil)
                     (t (string< a b))))))))

(defun generate-report ()
  (with-open-file (out "call_graph.md" :direction :output :if-exists :supersede)
    (format out "# Application Call Graph~%~%")
    (format out "This graph shows the hierarchy of internal function calls.~%")
    (format out "Nodes marked `[RECURSION]` indicate a cycle.~%")
    (format out "Nodes marked `[See above]` have been expanded previously in the document.~%~%")

    (clrhash *printed-functions*) ;; Reset global visited

    (let ((roots (find-roots)))
      (format out "## Roots (Entry Points & Unused Functions)~%")
      (dolist (root roots)
        (print-tree root 0 '() out)
        (format out "~%"))

      (format t "~&Generated call_graph.md with ~a roots.~%" (length roots)))))

(defun main ()
  (load-project)
  (let* ((all-files (directory "src/**/*.lisp"))
         (src-files (remove-if (lambda (f)
                                 (let ((dirs (pathname-directory f)))
                                   (or (member "hoist" dirs :test #'string-equal)
                                       (member "hoist-l0" dirs :test #'string-equal))))
                        all-files)))

    (format t "~&Scanning ~a files (excluded hoist/hoist-l0)...~%" (length src-files))

    ;; Pass 1: Collect definitions
    (dolist (f src-files) (process-file f #'scan-definitions))
    (format t "~&Identified ~a internal functions.~%" (length *all-functions*))

    ;; Pass 2: Analyze calls
    (dolist (f src-files) (process-file f #'scan-calls))

    ;; Pass 3: Normalize (Reverse) lists to restore source order
    (maphash (lambda (k v)
               (setf (gethash k *call-graph*) (nreverse v)))
             *call-graph*))
  (generate-report))

(main)
