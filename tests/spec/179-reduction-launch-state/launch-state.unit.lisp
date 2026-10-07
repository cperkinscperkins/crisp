(in-package :cl-user)

(defpackage :crisp.test.launch-state
  (:use :cl :parachute))

;;; The metacrisp is READ back as data; its symbols (type aliases, C-POINTER, ...) land here.
(defpackage :crisp.test.launch-state.meta
  (:use))

(in-package :crisp.test.launch-state)

;;; ENDEAVOUR 179 -- a reduction kernel must be launchable twice.
;;;
;;; D1: every last-man election (single-variable grid-reduce-last-man!, and the fused independent and
;;;     dependent grid-reduce! forms) draws tickets from a global counter with atomic-add!.  The kernel
;;;     must put that counter back to zero itself, or the second launch elects nobody and the output
;;;     silently keeps the first launch's answer.  Checked on the unoptimized IR: after the ticket draw
;;;     (an `atomicrmw add` on addrspace(1)) there must be a `store i32 0` to addrspace(1).  Nothing
;;;     else in these kernels stores an i32 zero to global memory -- the data is float, the election
;;;     flag is local -- so the store IS the reset.  (Before 179 the count is exactly zero.)
;;;
;;; D2: :atomic and :cas combine INTO the output cell, so the host must put the identity there before
;;;     every launch; the kernel cannot (deciding who is first needs a grid sync).  The metacrisp says
;;;     so on the output's :declared-signature entry as :launch-init (:identity <value>).  Last-man
;;;     overwrites its output, so it carries no :launch-init.
;;;
;;; The on-metal half of D1 is the existing last-man VERIFY-AUTODIFF specs in 175-178: since 179 the
;;; runner zeroes global scratch once at bind, not before every launch, so each finite-difference
;;; probe is a re-launch.

;;; --- helpers --------------------------------------------------------

(defun %with-source (source fn)
  "Writes SOURCE to a temporary .crisp file and calls FN with its path."
  (uiop:with-temporary-file (:pathname p :type "crisp" :keep nil)
    (with-open-file (s p :direction :output :if-exists :supersede)
      (write-string source s))
    (funcall fn p)))

(defun %ir-for (source)
  "Unoptimized LLVM IR for SOURCE."
  (%with-source source #'crisp.spec-runner::compile-crisp-file-to-ir-string))

(defun %kernel-lines (ir kernel)
  "The lines of KERNEL's body in IR, from its define to the closing brace."
  (with-input-from-string (s ir)
    (loop with in = nil
          for l = (read-line s nil) while l
          when (and (not in) (search (format nil "define void @~a(" kernel) l)) do (setf in t)
          else when (and in (string= (string-trim " " l) "}")) do (loop-finish)
          else when in collect l)))

(defun %global-zero-stores-after-ticket (source kernel)
  "Count of `store i32 0, ptr addrspace(1)` lines in KERNEL that follow its first global atomicrmw add.
   NIL if the kernel draws no ticket at all."
  (let* ((lines (%kernel-lines (%ir-for source) kernel))
         (tail (member-if (lambda (l) (and (search "atomicrmw add" l) (search "addrspace(1)" l))) lines)))
    (when tail
      (count-if (lambda (l) (search "store i32 0, ptr addrspace(1)" l)) (rest tail)))))

(defun %expect-one-reset (source)
  "Two claims, kept apart so a failure says which: the kernel DRAWS a ticket (else the probe is
   wrong, not the compiler), and exactly one zero store to global follows it."
  (let ((n (%global-zero-stores-after-ticket source "probe")))
    (true n "the kernel draws a ticket (atomicrmw add on addrspace(1))")
    (is eql 1 n "exactly one counter reset after the ticket draw")))

(defun %read-forms (path)
  (with-open-file (s path)
    (let ((*package* (find-package :crisp-language)))
      (loop for f = (read s nil :eof) until (eq f :eof) collect f))))

(defun %declared-signature (source)
  "Compiles SOURCE, writes its metacrisp, and returns the first kernel's :declared-signature."
  (%with-source source
    (lambda (p)
      (crisp.spec-runner::compile-crisp-file-to-ir-string p)
      (let ((paths (crisp.compiler::generate-metadata-for-file
                    p (make-pathname :type "metacrisp" :defaults p) :forms (%read-forms p))))
        (unwind-protect
             (with-open-file (s (first paths))
               (let ((*package* (find-package :crisp.test.launch-state.meta))
                     (*read-eval* nil))
                 (let* ((sections (loop for f = (read s nil :eof) until (eq f :eof) collect f))
                        (kernels (cdr (assoc :kernels sections))))
                   (getf (first kernels) :declared-signature))))
          (dolist (m paths) (ignore-errors (delete-file m))))))))

(defun %launch-init (source param)
  "The :launch-init plist of PARAM (a lowercase name) in SOURCE's metacrisp, or NIL."
  (let ((entry (find param (%declared-signature source)
                     :key (lambda (e) (getf e :name)) :test #'string=)))
    (assert entry () "no declared parameter ~s in the metacrisp" param)
    (getf entry :launch-init)))

;;; --- kernels --------------------------------------------------------

(defparameter *single*
  "(def-type out-c (cell float :address-space :global))
   (def-kernel probe (&out out)
     (declare #'(&out out-c => nil)
              (global-size :set-to 256)
              (local-size  :set-to 64))
     (let ((a (to-float (get-global-linear-id))))
       (grid-reduce! #'+ a 0.0 out~a)))"
  "Single-variable grid-reduce!; ~a is the trailing keys (e.g. \" :strategy :atomic\").")

(defparameter *independent*
  "(def-type out-c (cell float :address-space :global))
   (def-kernel probe (&out o1 o2)
     (declare #'(&out out-c out-c => nil)
              (global-size :set-to 256)
              (local-size  :set-to 64))
     (let ((a (to-float (get-global-linear-id)))
           (b (to-float (get-global-linear-id))))
       (grid-reduce! ((#'+ a 0.0 o1) (#'+ b 0.0 o2))~a)))")

(defparameter *dependent*
  "(def-type out-c  (cell float :address-space :global))
   (def-type uout-c (cell ulong :address-space :global))
   (def-function argmax-combine (val-a idx-a val-b idx-b)
     (declare #'(float ulong float ulong => float ulong))
     (if (or (> val-a val-b)
             (and (= val-a val-b) (< idx-a idx-b)))
         (return val-a idx-a)
         (return val-b idx-b)))
   (def-kernel probe (&out outv outi)
     (declare #'(&out out-c uout-c => nil)
              (global-size :set-to 256)
              (local-size  :set-to 64))
     (let ((v (to-float (rem (to-int (get-global-linear-id)) 100)))
           (i (get-global-linear-id)))
       (grid-reduce! #'argmax-combine
                     ((v (type-min float) outv)
                      (i (type-max ulong) outi)))))")

(defparameter *reduce-vec*
  "(def-type in-vec (vector float :address-space :global :align :compact))
   (def-type out-c  (cell float :address-space :global))
   (def-kernel probe (A &out out)
     (declare #'(in-vec &out out-c => nil)
              (global-size :set-to 256)
              (local-size  :set-to 64))
     (reduce-vec #'+ A 0.0 out~a))")

(defun %src (template &optional (keys "")) (format nil template keys))

;;; --- D1: the kernel resets its own ticket counter -------------------

(define-test launch-state
  "Endeavour 179: reduction kernels are launchable twice.")

(define-test (launch-state last-man-single-resets-counter)
  "Single-variable grid-reduce! (default :last-man-standing) zeroes its counter after the election."
  (%expect-one-reset (%src *single*)))

(define-test (launch-state last-man-explicit-strategy-resets-counter)
  "The same when :last-man-standing is written out."
  (%expect-one-reset (%src *single* " :strategy :last-man-standing")))

(define-test (launch-state last-man-independent-resets-counter)
  "The fused independent form: ONE ticket, ONE election, so exactly ONE reset."
  (%expect-one-reset (%src *independent*)))

(define-test (launch-state last-man-dependent-resets-counter)
  "The fused dependent form (last-man only) zeroes its counter."
  (%expect-one-reset (%src *dependent*)))

(define-test (launch-state reduce-vec-default-resets-counter)
  "reduce-vec's default strategy is last-man, so it inherits the reset."
  (%expect-one-reset (%src *reduce-vec*)))

;;; --- D2: :atomic / :cas outputs say they need the identity ----------

(define-test (launch-state atomic-output-needs-identity)
  ":atomic accumulates into OUT, so OUT must hold the identity before every launch."
  (let ((li (%launch-init (%src *single* " :strategy :atomic") "out")))
    (true li)
    (is = 0.0 (getf li :identity))))

(define-test (launch-state cas-output-needs-identity)
  ":cas combines into OUT; the recorded value is the call's identity, not a blanket zero."
  (let ((li (%launch-init
             "(def-type out-c (cell float :address-space :global))
              (def-kernel probe (&out out)
                (declare #'(&out out-c => nil)
                         (global-size :set-to 256)
                         (local-size  :set-to 64))
                (let ((a (to-float (get-global-linear-id))))
                  (grid-reduce! #'max a -1000.0 out :strategy :cas)))"
             "out")))
    (true li)
    (is = -1000.0 (getf li :identity))))

(define-test (launch-state independent-atomic-annotates-every-output)
  "An independent :atomic call accumulates into each clause's cell, so each one is annotated."
  (let ((src (%src *independent* " :strategy :atomic")))
    (is = 0.0 (getf (%launch-init src "o1") :identity))
    (is = 0.0 (getf (%launch-init src "o2") :identity))))

(define-test (launch-state reduce-vec-atomic-annotates-output)
  "reduce-vec passes :strategy :atomic through to grid-reduce!, and the annotation follows."
  (is = 0.0 (getf (%launch-init (%src *reduce-vec* " :strategy :atomic") "out") :identity)))

(define-test (launch-state last-man-output-needs-nothing)
  "Last-man OVERWRITES its output, so it carries no :launch-init."
  (false (%launch-init (%src *single*) "out")))

;; A quiet `is` failure does not fail the load, and the runner only sees load errors -- so error here.
(let* ((report (test 'launch-state))
       (failures (parachute:results-with-status :failed report)))
  (when failures
    (error "launch-state: ~d result(s) failed:~{~%    ~a~}" (length failures)
           (mapcar (lambda (r) (let ((s (princ-to-string r))) (subseq s 0 (min 160 (length s)))))
                   failures))))
