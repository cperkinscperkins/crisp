;;;
;;;  sbcl --script ./scripts/gen-specials.lisp
;;;
;;;  Regenerates src/specials.lisp -- the early SPECIAL proclamation file.
;;;
;;;  WHY THIS EXISTS
;;;  ---------------
;;;  `(let ((*foo* x)) ...)` only creates a DYNAMIC binding if *FOO* is already known
;;;  special AT THE MOMENT THAT LET IS COMPILED.  If the defvar lives in a file that
;;;  crisp.asd compiles LATER, the binding silently becomes LEXICAL: the dynamic value
;;;  never changes, every reader downstream sees NIL, and SBCL says nothing louder than
;;;  a STYLE-WARNING -- which ASDF muffles, and which ql:quickload muffles again along
;;;  with every real WARNING (see call-with-quiet-compilation in quicklisp/impl-util.lisp).
;;;
;;;  That is not hypothetical.  Endeavor 152's ten cluster/multicast specs failed in CI
;;;  for exactly this reason: `internal-def-function` (src/analysis/core.lisp, component
;;;  22) binds *CURRENT-KERNEL-CLUSTER-DIMS*, whose defvar sits in src/analysis/control.lisp
;;;  (component 24).  Cold-compiled, the binding was lexical and every cluster kernel was
;;;  told it had not declared a cluster.
;;;
;;;  The hazard is STRUCTURAL, not incidental: overlays/ are the last components in the
;;;  system, so code written there always sees every defvar.  Folding that code back into
;;;  src/ moves it in front of the defvars it depends on.  Every future fold re-creates
;;;  this unless the proclamation happens first.
;;;
;;;  So: one file, loaded second (right after src/package), that proclaims every global
;;;  in the system special before any of them can be bound.  Values, docstrings and the
;;;  defvars themselves stay exactly where they are.
;;;
;;;  This scans the same way scripts/map-globals.lisp does -- READ over src/**/*.lisp,
;;;  collecting DEFVAR/DEFPARAMETER -- so the list here and the rows of
;;;  docs/globals_matrix.csv are drawn from one source of truth.
;;;

(require :asdf)

;; Load Quicklisp FIRST, as its own toplevel form: `sbcl --script` skips ~/.sbclrc, so the
;; QL package does not exist yet, and the reader would choke on `ql:` in any form below.
(let ((quicklisp-init (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file quicklisp-init)
    (load quicklisp-init)))

(defpackage :crisp.gen-specials
  (:use :cl)
  (:export :main))

(in-package :crisp.gen-specials)

(defun load-project ()
  "Load Crisp so every package exists before we READ source that uses package prefixes."
  (push (uiop:getcwd) ql:*local-project-directories*)
  (ql:register-local-projects)
  (ql:quickload "crisp" :silent t))

(defun collect-from-file (path)
  "Return an alist of (package-name . list-of-symbol-names) for the DEFVAR/DEFPARAMETER
   forms in PATH.  Tracks IN-PACKAGE as it reads, since src/ spans several packages and a
   proclamation has to name the symbol in its HOME package to have any effect."
  (let ((result (make-hash-table :test #'equal))
        (current-package "CRISP.COMPILER"))
    (with-open-file (in path :direction :input :if-does-not-exist nil)
      (when in
        (loop
          (let ((form (handler-case (read in nil :eof)
                        (error () :error))))
            (cond
              ((eq form :eof) (return))
              ((eq form :error) nil)
              ((and (consp form) (symbolp (first form)))
               (let ((op (symbol-name (first form))))
                 (cond
                   ((string= op "IN-PACKAGE")
                    (setf current-package (string (second form))))
                   ((member op '("DEFVAR" "DEFPARAMETER") :test #'string=)
                    (let ((name (second form)))
                      (when (symbolp name)
                        (pushnew (symbol-name name) (gethash current-package result)
                                 :test #'string=)))))))
              (t nil))))))
    (let ((alist '()))
      (maphash (lambda (k v) (push (cons k v) alist)) result)
      alist)))

(defun merge-alists (alists)
  "Fold per-file alists into one package -> sorted-names table."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (alist alists)
      (dolist (entry alist)
        (dolist (name (cdr entry))
          (pushnew name (gethash (car entry) table) :test #'string=))))
    (let ((out '()))
      (maphash (lambda (k v) (push (cons k (sort v #'string<)) out)) table)
      (sort out #'string< :key #'car))))

(defun emit (grouped path)
  "Write the declaim file.  Output is sorted so regeneration produces a stable diff."
  (with-open-file (out path :direction :output :if-exists :supersede
                            :if-does-not-exist :create)
    (format out ";;;; src/specials.lisp -- GENERATED FILE, DO NOT EDIT BY HAND.~%")
    (format out ";;;;~%")
    (format out ";;;; Regenerate with:  sbcl --script ./scripts/gen-specials.lisp~%")
    (format out ";;;;~%")
    (format out ";;;; Proclaims every global in src/ special BEFORE any file that binds one is~%")
    (format out ";;;; compiled.  Without this, a `(let ((*foo* x)) ...)` compiled before *FOO*'s~%")
    (format out ";;;; defvar becomes a LEXICAL binding -- silently, because ASDF muffles the~%")
    (format out ";;;; style-warning and ql:quickload muffles warnings outright.  The defvars~%")
    (format out ";;;; themselves keep their homes, their values and their docstrings; this file~%")
    (format out ";;;; only fixes WHEN the compiler learns they are special.~%")
    (format out ";;;;~%")
    (format out ";;;; See scripts/gen-specials.lisp for the full rationale.~%~%")
    (dolist (entry grouped)
      (format out "(in-package :~(~a~))~%~%" (car entry))
      (format out "(declaim (special~%")
      (dolist (name (cdr entry))
        (format out "          ~a~%" name))
      (format out "          ))~%~%"))
    (format out ";;;; end of generated file~%")))

(defun asd-component-files ()
  "The .lisp files that are actually COMPONENTS of the `crisp` system, in load order.

   Deliberately NOT `(directory \"src/**/*.lisp\")`: src/hoist/, src/hoist-cuda/ and
   src/hoist-l0/ live under src/ but belong to the separate hoist systems, and their
   packages do not exist when this file is loaded as component #2.  Scanning them would
   emit an (in-package :crisp.hoist.cuda) that fails at build time.  The hoist systems
   have their own load order and would need their own generated file."
  (let ((files '()))
    (with-open-file (in "crisp.asd" :direction :input)
      (loop for line = (read-line in nil :eof)
            until (eq line :eof)
            do (let ((start (search "(:file \"" line)))
                 (when start
                   (let* ((from (+ start (length "(:file \"")))
                          (end  (position #\" line :start from)))
                     (when end
                       (let ((name (subseq line from end)))
                         (unless (string= name "src/specials")
                           (push (concatenate 'string name ".lisp") files)))))))))
    (nreverse files)))

(defun main ()
  (load-project)
  (let* ((src-files (asd-component-files))
         (grouped (merge-alists (mapcar #'collect-from-file src-files))))
    (emit grouped "src/specials.lisp")
    (format t "~&Wrote src/specials.lisp~%")
    (dolist (entry grouped)
      (format t "  ~a: ~a globals~%" (car entry) (length (cdr entry))))
    (format t "  TOTAL: ~a~%" (reduce #'+ grouped :key (lambda (e) (length (cdr e)))))))

(main)
