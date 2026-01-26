;;;
;;;  sbcl --load  ./scripts/map-globals.lisp --non-interactive
;;;

(require :sb-introspect)
(require :asdf)

(defpackage :crisp.map-globals
  (:use :cl)
  (:export :main))

(in-package :crisp.map-globals)

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

(defparameter *globals-table* (make-hash-table :test #'equal))
;; Key: Global Name String
;; Value: Alist of (Function-NameString . Code)

(defparameter *all-functions* '())
(defparameter *collected-globals* '())

;;; ---------------------------------------------------------------------------
;;; Usage Tracking
;;; ---------------------------------------------------------------------------

(defun collect-global-def (name)
  (let ((s (symbol-name name)))
    (pushnew s *collected-globals* :test #'string=)))

(defun usage-code (usage-list)
  (let ((r (member :read usage-list))
        (w (member :write usage-list)))
    (cond
     ((and r w) "RW")
     (w "W")
     (r "R")
     (t ""))))

(defun register-usage (func-name global-name access-type)
  (let ((entry (gethash global-name *globals-table*)))
    (let ((func-entry (assoc func-name entry :test #'string=)))
      (unless func-entry
        (setf func-entry (cons func-name nil))
        (push func-entry (gethash global-name *globals-table*)))
      (pushnew access-type (cdr func-entry)))))

;;; ---------------------------------------------------------------------------
;;; Mutation Logic
;;; ---------------------------------------------------------------------------

(defparameter *mutating-accessors*
              ;; Name -> Index of arg that is mutated
              '(("GETHASH" . 1)
                ("AREF" . 0)
                ("SVREF" . 0)
                ("ELT" . 0)
                ("CHAR" . 0)
                ("SCHAR" . 0)
                ("SLOT-VALUE" . 0)
                ("CAR" . 0) ("CDR" . 0)
                ("FIRST" . 0) ("REST" . 0)))

(defparameter *mutating-functions*
              '(("REMHASH" . 1)
                ("CLRHASH" . 0)
                ("FILL" . 0)
                ("REPLACE" . 0)
                ("NREVERSE" . 0)
                ("SORT" . 0)
                ("DELETE" . 0)
                ("DELETE-IF" . 0)
                ("RPLACA" . 0)
                ("RPLACD" . 0)
                ("NBUTLAST" . 0)
                ("NCONC" . 0)))

;;; ---------------------------------------------------------------------------
;;; Walker
;;; ---------------------------------------------------------------------------

(defun walk-body (func-name body)
  (labels ((walker (form context)
                   (cond
                    ;; 1. SYMBOL
                    ((symbolp form)
                      (let ((s (symbol-name form)))
                        (when (member s *collected-globals* :test #'string=)
                              (let ((access (if (eq context :write) :write :read)))
                                (register-usage func-name s access)))))

                    ;; 2. CONS: Expression
                    ((consp form)
                      (let ((op (if (symbolp (car form)) (symbol-name (car form)) nil))
                            (args (cdr form)))

                        (cond
                         ;; --- SETF / SETQ ---
                         ((or (string= op "SETQ") (string= op "SETF"))
                           (do ((curr args (cddr curr)))
                               ((not (consp curr)))
                             (let ((place (car curr))
                                   (val (if (consp (cdr curr)) (cadr curr) nil)))
                               (walker place :write)
                               (when val (walker val :read)))))

                         ;; --- Mutation Macros ---
                         ((or (string= op "INCF") (string= op "DECF") (string= op "POP"))
                           (let ((place (if (consp args) (car args) nil)))
                             (when place
                                   (walker place :write)
                                   (if (and (string/= op "POP") (cdr args) (consp (cdr args)))
                                       (walker (cadr args) :read)
                                       nil))))

                         ((string= op "PUSH")
                           (let ((val (if (consp args) (car args) nil))
                                 (place (if (consp (cdr args)) (cadr args) nil)))
                             (when val (walker val :read))
                             (when place (walker place :write))))

                         ;; --- LET / LET* ---
                         ((or (string= op "LET") (string= op "LET*"))
                           (let ((bindings (if (consp args) (car args) nil))
                                 (body (if (consp args) (cdr args) nil)))
                             (when (listp bindings)
                                   (dolist (b bindings)
                                     (cond
                                      ((consp b)
                                        (when (symbolp (car b)) (walker (car b) :write)) ;; VAR is WRITTEN (shadowed/bound)
                                        (walker (cadr b) :read)) ;; VAL is READ
                                      ((symbolp b)
                                        (walker b :write))))) ;; VAR init to NIL
                             ;; Walk body forms - Implicit PROGN
                             (dolist (f body) (walker f :read))))

                         ;; --- Standard Call / Macro ---
                         (t
                           ;; Helper to check proper list
                           (let ((is-proper (and (listp args) (null (cdr (last args))))))
                             (if (eq context :write)
                                 ;; Context :WRITE
                                 (let ((accessor-info (if is-proper (assoc op *mutating-accessors* :test #'string=) nil)))
                                   (if accessor-info
                                       (let ((mutated-arg-idx (cdr accessor-info)))
                                         (loop for arg in args
                                               for i from 0
                                               do (if (= i mutated-arg-idx)
                                                      (walker arg :write)
                                                      (walker arg :read))))

                                       ;; Unknown/Improper
                                       (do ((curr args (cdr curr)))
                                           ((atom curr) (when curr (walker curr :read)))
                                         (walker (car curr) :read))))

                                 ;; Context :READ
                                 (let ((mutator-info (if is-proper (assoc op *mutating-functions* :test #'string=) nil)))
                                   (if mutator-info
                                       (let ((mutated-arg-idx (cdr mutator-info)))
                                         (loop for arg in args
                                               for i from 0
                                               do (if (= i mutated-arg-idx)
                                                      (walker arg :write)
                                                      (walker arg :read))))
                                       ;; Not a known mutator, all reads
                                       (do ((curr args (cdr curr)))
                                           ((atom curr) (when curr (walker curr :read)))
                                         (walker (car curr) :read)))))))))))))
    (dolist (form body) (walker form :read))))

;;; ---------------------------------------------------------------------------
;;; Scanning
;;; ---------------------------------------------------------------------------

(defun scan-for-globals (form)
  (when (and (consp form) (symbolp (first form)))
        (let ((op (symbol-name (first form))))
          (when (member op '("DEFVAR" "DEFPARAMETER") :test #'string=)
                (let ((name (second form)))
                  (when (symbolp name)
                        (collect-global-def name)))))))

(defun scan-for-functions (form)
  (when (and (consp form) (symbolp (car form)))
        (let ((op (symbol-name (car form))))
          (cond
           ((member op '("DEFUN" "DEFMACRO" "DEF-FUNCTION" "DEF-KERNEL" "DEF-GRID-FUNCTION" "DEFMETHOD") :test #'string=)
             (let ((name (second form))
                   (body (cddr form)))
               (when (symbolp name)
                     (let ((s-name (symbol-name name)))
                       (pushnew s-name *all-functions* :test #'string=)
                       (walk-body s-name body)))))))))

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
;;; Main
;;; ---------------------------------------------------------------------------

(defun generate-csv ()
  ;; Debug: Check missing globals status
  (dolist (target '("*STRUCT-NAME-PREFIX*" "*DEFER-STRUCT-VALIDATION*" "*SIDE-CHANNEL-ORIGINATORS*"))
    (if (member target *collected-globals* :test #'string=)
        (format t "~&[DEBUG] Found global definition for ~a~%" target)
        (format t "~&[DEBUG] WARNING: Missing definition for ~a~%" target)))

  ;; 1. Full Matrix (R & W)
  (with-open-file (out "docs/globals_matrix.csv" :direction :output :if-exists :supersede)
    (format out "~&Global Variable")
    (let ((active-functions
           (loop for fn in *all-functions*
                   when (loop for g in *collected-globals*
                                thereis (assoc fn (gethash g *globals-table*) :test #'string=))
                 collect fn)))

      (dolist (fn active-functions) (format out ",~a" fn))
      (format out "~%")

      (dolist (g *collected-globals*)
        (let ((usages (gethash g *globals-table*)))
          (format out "~a" g)
          (dolist (fn active-functions)
            (let ((u (assoc fn usages :test #'string=)))
              (format out ",~a" (if u (usage-code (cdr u)) ""))))
          (format out "~%"))))
    (format t "~&Generated globals_matrix.csv~%"))

  ;; 2. Writes Only Matrix (W & RW)
  (with-open-file (out "docs/globals_matrix_writes.csv" :direction :output :if-exists :supersede)
    (format out "~&Global Variable")
    (let ((writing-functions
           (loop for fn in *all-functions*
                   when (loop for g in *collected-globals*
                              for u = (assoc fn (gethash g *globals-table*) :test #'string=)
                                thereis (and u (member :write (cdr u))))
                 collect fn)))

      (dolist (fn writing-functions) (format out ",~a" fn))
      (format out "~%")

      (dolist (g *collected-globals*)
        (let ((usages (gethash g *globals-table*)))
          (format out "~a" g)
          (dolist (fn writing-functions)
            (let ((u (assoc fn usages :test #'string=)))
              (format out ",~a" (if u (usage-code (cdr u)) ""))))
          (format out "~%"))))
    (format t "~&Generated globals_matrix_writes.csv~%")))

(defun main ()
  (load-project)
  (let ((src-files (directory "src/**/*.lisp")))
    (dolist (f src-files) (process-file f #'scan-for-globals))
    (dolist (f src-files) (process-file f #'scan-for-functions)))
  (generate-csv))

(main)
