(in-package :cl-user)

(defpackage :crisp.test.last-man-sweep
  (:use :cl :parachute))

;;; The metacrisp is READ back as data; its symbols (type aliases, C-POINTER, ...) land here.
(defpackage :crisp.test.last-man-sweep.meta
  (:use))

(in-package :crisp.test.last-man-sweep)

;;; ENDEAVOUR 181 -- lift last-man's "num_groups <= local size" cap.
;;;
;;; A: the elected workgroup's final sweep is STRIDED -- each thread seeds from partial `lid` (as
;;;    before) and then folds partials lid+ls, lid+2ls, ... in a counted dotimes+ -- so it covers any
;;;    number of workgroups.  The old guard, (<= (get-num-groups 0) (get-local-linear-size)), is gone
;;;    from all three lowering sites; the new one checks the PARTIALS BUFFER: (<= ... (length~ gv)).
;;; B: the implicit partials buffer is sized :match-num-workgroups, one slot per workgroup, rather than
;;;    :match-workgroup-size (which only sufficed while the cap held).
;;;
;;; These pin the FORM of the expansion and the metacrisp.  Whether it computes the right thing with
;;; more workgroups than threads is the on-metal specs' job (01-06 L0, 07-09 CUDA, 10 autodiff).

;;; --- helpers --------------------------------------------------------

(defun %read-crisp (string)
  "STRING read as one form in the crisp-language package, as the compiler reads source."
  (let ((*package* (find-package :crisp-language)))
    (read-from-string string)))

(defun %named-p (x name)
  (and (symbolp x) (string-equal (symbol-name x) name)))

(defun %subforms (tree)
  "Every cons in TREE (TREE included), depth first."
  (when (consp tree)
    (cons tree (loop for x on tree
                     while (consp x)
                     append (%subforms (car x))))))

(defun %mentions-p (tree name)
  "True when a symbol named NAME occurs anywhere in TREE."
  (cond ((symbolp tree) (%named-p tree name))
        ((consp tree) (or (%mentions-p (car tree) name) (%mentions-p (cdr tree) name)))
        (t nil)))

(defun %group-count-guards (expansion)
  "The r-t-assert-0 forms in EXPANSION whose test reads the group count."
  (remove-if-not (lambda (f) (and (%named-p (car f) "R-T-ASSERT-0")
                                  (%mentions-p (second f) "GET-NUM-GROUPS")))
                 (%subforms expansion)))

(defun %elected-branch (expansion)
  "The (when+ (= (~ flag) 1u) ...) form: the elected workgroup's final sweep."
  (find-if (lambda (f) (%named-p (car f) "WHEN+")) (%subforms expansion)))

(defun %check-sweep (expansion n-buffers)
  "The A claims, kept apart so a failure says which.  N-BUFFERS is how many partials buffers the
   expansion has (one per clause); each gets its own guard."
  (let ((guards (%group-count-guards expansion))
        (elected (%elected-branch expansion)))
    (is = n-buffers (length guards) "one group-count guard per partials buffer")
    (true (every (lambda (g) (%mentions-p (second g) "LENGTH~")) guards)
          "every guard compares the group count with a partials buffer's length")
    (false (some (lambda (g) (%mentions-p (second g) "GET-LOCAL-LINEAR-SIZE")) guards)
           "no guard caps the group count at the local size")
    (true elected "the expansion has an elected-workgroup branch")
    (when elected
      (true (find-if (lambda (f) (%named-p (car f) "DOTIMES+")) (%subforms elected))
            "the elected sweep has a counted dotimes+ over the extra strides")
      (true (%mentions-p elected "GET-LOCAL-LINEAR-SIZE")
            "the stride is the local size"))))

(defun %with-source (source fn)
  "Writes SOURCE to a temporary .crisp file and calls FN with its path."
  (uiop:with-temporary-file (:pathname p :type "crisp" :keep nil)
    (with-open-file (s p :direction :output :if-exists :supersede)
      (write-string source s))
    (funcall fn p)))

(defun %read-forms (path)
  (with-open-file (s path)
    (let ((*package* (find-package :crisp-language)))
      (loop for f = (read s nil :eof) until (eq f :eof) collect f))))

(defun %implicit-params (source)
  "Compiles SOURCE, writes its metacrisp, and returns the first kernel's :implicit-params."
  (%with-source source
    (lambda (p)
      (crisp.spec-runner::compile-crisp-file-to-ir-string p)
      (let ((paths (crisp.compiler::generate-metadata-for-file
                    p (make-pathname :type "metacrisp" :defaults p) :forms (%read-forms p))))
        (unwind-protect
             (with-open-file (s (first paths))
               (let ((*package* (find-package :crisp.test.last-man-sweep.meta))
                     (*read-eval* nil))
                 (let* ((sections (loop for f = (read s nil :eof) until (eq f :eof) collect f))
                        (kernels (cdr (assoc :kernels sections))))
                   (getf (first kernels) :implicit-params))))
          (dolist (m paths) (ignore-errors (delete-file m))))))))

(defun %global-scratch-size-exprs (source)
  "The :size-expr of every :global implicit TENSOR in SOURCE's first kernel (cells excluded -- by their
   type, not by a NIL size: the metacrisp is read into a package that does not use CL, so its NIL is
   just another symbol)."
  (loop for p in (%implicit-params source)
        for type = (getf p :type)
        when (and (eq (getf p :address-space) :global)
                  (consp type)
                  (string= (symbol-name (first type)) "TENSOR"))
          collect (getf p :size-expr)))

;;; --- forms ----------------------------------------------------------

(defparameter *single-form*
  "(grid-reduce-last-man! #'+ v 0.0 out
     :local-scratch-vec sv :global-scratch-vec gv :atomic-counter ctr :election-flag-cell flag)")

(defparameter *independent-form*
  "(grid-reduce! ((#'+ a 0.0 o1) (#'max b 0ul o2)))")

(defparameter *dependent-form*
  "(grid-reduce! #'argmax-combine ((v (type-min float) outv) (i (type-max ulong) outi)))")

(defparameter *single-kernel*
  "(def-type out-c (cell float :address-space :global))
   (def-kernel probe (&out out)
     (declare #'(&out out-c => nil)
              (global-size :set-to 4096)
              (local-size  :set-to 32))
     (let ((a (to-float (get-workgroup-id 0))))
       (grid-reduce! #'+ a 0.0 out)))")

(defparameter *reduce-vec-kernel*
  "(def-type in-vec (vector float :address-space :global :align :compact))
   (def-type out-c  (cell float :address-space :global))
   (def-kernel probe (A &out out)
     (declare #'(in-vec &out out-c => nil)
              (global-size :derive-from A :strategy :strided)
              (local-size  :set-to 32))
     (reduce-vec #'+ A 0.0 out))")

;;; --- A: the strided sweep, at all three lowering sites ---------------

(define-test last-man-sweep)

(define-test (last-man-sweep single-variable-sweep-is-strided)
  (%check-sweep (crisp.compiler::%grid-reduce-last-man-expand (%read-crisp *single-form*)) 1))

(define-test (last-man-sweep independent-sweep-is-strided)
  (%check-sweep (crisp.compiler::%fused-grid-reduce-form (%read-crisp *independent-form*)) 2))

(define-test (last-man-sweep dependent-sweep-is-strided)
  (%check-sweep (crisp.compiler::%fused-grid-reduce-dependent-form (%read-crisp *dependent-form*)) 2))

;;; --- B: the implicit partials are one per workgroup ------------------

(define-test (last-man-sweep implicit-partials-match-num-workgroups)
  (is equal '(:match-num-workgroups) (%global-scratch-size-exprs *single-kernel*)
      "grid-reduce!'s implicit partials buffer is sized one per workgroup"))

(define-test (last-man-sweep reduce-vec-partials-match-num-workgroups)
  (is equal '(:match-num-workgroups) (%global-scratch-size-exprs *reduce-vec-kernel*)
      "reduce-vec's implicit partials buffer is sized one per workgroup"))

;; A quiet `is` failure does not fail the load, and the runner only sees load errors -- so error here.
(let* ((report (test 'last-man-sweep))
       (failures (parachute:results-with-status :failed report)))
  (when failures
    (error "last-man-sweep: ~d result(s) failed:~{~%    ~a~}" (length failures)
           (mapcar (lambda (r) (let ((s (princ-to-string r))) (subseq s 0 (min 160 (length s)))))
                   failures))))
