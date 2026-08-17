;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)


;;; =====================================================================
;;; Endeavor 152 — spec validators
;;;
;;; Two different calling conventions in this harness, hence two shapes below:
;;;   PTX validators       (fn FILE PTX-STRING)  -- run-spec-ptx-{in-process,binary}
;;;   metadata validators  (fn METACRISP-PATH)   -- the --metadata pass
;;; =====================================================================

;; tests/run-specs.lisp
(defun validate-ptx-cluster-dims (file ptx-string)
  "Endeavor 152 rung 01/02 — the kernel's cluster shape must reach the PTX.

   A kernel can declare (cluster-size ...) and compile perfectly while emitting no
   cluster directive at all -- that was the behaviour before this endeavor, since an
   unrecognised declare clause is silently ignored.  The kernel would then launch
   unclustered, compute the correct answer, and lose every bit of the bandwidth
   reduction the declaration was written for.  No correctness test can see that, so
   this validator reads the emitted instruction instead."
  (declare (ignore file))
  (let ((missing '()))
    (dolist (exp '(".explicitcluster" ".reqnctapercluster"))
      (unless (search exp ptx-string) (push exp missing)))
    (cond
      (missing
       (format *error-output* "FAIL: PTX carries no cluster directive; missing ~{~a~^ and ~}.~%  A kernel declaring cluster-size that emits no .reqnctapercluster will launch UNCLUSTERED and still be numerically correct.~%"
               (nreverse missing))
       nil)
      (t t))))

;; tests/run-specs.lisp
(defun %152-metacrisp-text (path)
  "Read a metacrisp file (or the first of a list) as text.  Text rather than READ:
   the metacrisp is written in the compiler's packages, so READing it here would
   intern or fail on symbols this package does not have."
  (let ((p (if (listp path) (first path) path)))
    (and p (probe-file p) (uiop:read-file-string p))))

;; tests/run-specs.lisp
(defun validate-metacrisp-cluster-extent (path)
  "Endeavor 152 rung 03 — the EFFECTIVE cluster extent must be an assertable artefact.

   Asserts the metacrisp carries BOTH :cluster-size (what the source asked for) and
   :effective-cluster-size (what codegen actually built), and that on this capable
   target they agree -- the declaration here is 4, so the effective extent must not
   be 1.

   The two fields exist precisely because they can DISAGREE: a kernel whose cluster
   collapsed still computes the right answer, so 'it passed' proves nothing about
   whether a cluster was formed."
  (let ((txt (%152-metacrisp-text path)))
    (cond
      ((null txt) (format *error-output* "FAIL: metacrisp unreadable.~%") nil)
      ((not (search ":cluster-size" txt))
       (format *error-output* "FAIL: metacrisp has no :cluster-size record.~%") nil)
      ((not (search ":effective-cluster-size" txt))
       (format *error-output* "FAIL: metacrisp has no :effective-cluster-size record -- without it a degraded cluster is indistinguishable from a working one.~%") nil)
      ((search ":effective-cluster-size (1 1 1)" txt)
       (format *error-output* "FAIL: :effective-cluster-size is (1 1 1) on a cluster-capable target -- the cluster did NOT form, though the kernel would still compute correctly.~%") nil)
      (t t))))

;; tests/run-specs.lisp
(defun validate-cluster-degrade-warning (path)
  "Endeavor 152 rung 05 — a cluster that could not be formed must SAY SO in metadata.

   On a target without cluster support the declaration stands but the effective extent
   collapses to 1.  This asserts that the collapse is RECORDED, i.e. that both fields
   are present and effective is (1 1 1).

   NOTE ON SCOPE, deliberately narrower than the rung's prose: the harness hands a
   metadata validator only the metacrisp PATH, so the log4cl WARNING itself is not
   visible from here.  The warning is verified by hand (and by the compiler's own
   log level); what is machine-checked is the durable artefact, which is the thing a
   benchmark harness would assert on anyway."
  (let ((txt (%152-metacrisp-text path)))
    (cond
      ((null txt) (format *error-output* "FAIL: metacrisp unreadable.~%") nil)
      ((not (search ":cluster-size" txt))
       (format *error-output* "FAIL: metacrisp has no :cluster-size record -- the DECLARATION should survive even when the cluster degrades.~%") nil)
      ((not (search ":effective-cluster-size (1 1 1)" txt))
       (format *error-output* "FAIL: expected :effective-cluster-size (1 1 1) on a target without cluster support; the degrade was not recorded.~%") nil)
      (t t))))

;;; =====================================================================
;;; Endeavor 152 — validator arity fix
;;;
;;; The harness picks its runner from the FLAGS, not from the validator: a
;;; TEST-WITH carrying --ir-target=ptx goes to run-spec-ptx-binary, which calls
;;; (fn FILE PTX-STRING) -- two arguments -- even when the flags ALSO carry
;;; --metadata.  The one-argument metadata convention only applies to a pass whose
;;; flags are metadata-only.
;;;
;;; Rungs 03 and 05 need BOTH (--metadata for the record, --ir-target/-arch to reach
;;; a cluster-capable target), so they land in the two-argument runner.  These
;;; therefore take (FILE IGNORED-TEXT) and locate the metacrisp themselves, next to
;;; the source file.
;;; =====================================================================

;; tests/run-specs.lisp
(defun %152-find-metacrisp (file)
  "The .metacrisp emitted next to FILE.  The writer suffixes the kernel name
   (<stem>_<kernel>.metacrisp), so glob rather than compute the name."
  (let* ((dir (make-pathname :name nil :type nil :defaults file))
         (stem (pathname-name file))
         (hits (directory (merge-pathnames (format nil "~a*.metacrisp" stem) dir))))
    (first hits)))

;; tests/run-specs.lisp
(defun validate-metacrisp-cluster-extent (file &optional ignored)
  "Endeavor 152 rung 03 — the EFFECTIVE cluster extent must be an assertable artefact.

   Asserts the metacrisp carries BOTH :cluster-size (what the source asked for) and
   :effective-cluster-size (what codegen actually built), and that on this capable
   target they agree -- the declaration is 4, so effective must not be (1 1 1).

   The two fields exist precisely because they CAN disagree: a kernel whose cluster
   collapsed still computes the right answer, so 'it passed' proves nothing about
   whether a cluster was formed."
  (declare (ignore ignored))
  (let* ((mp (%152-find-metacrisp file))
         (txt (and mp (uiop:read-file-string mp))))
    (cond
      ((null txt)
       (format *error-output* "FAIL: no .metacrisp found next to ~a~%" (file-namestring file)) nil)
      ((not (search ":cluster-size" txt))
       (format *error-output* "FAIL: metacrisp has no :cluster-size record.~%") nil)
      ((not (search ":effective-cluster-size" txt))
       (format *error-output* "FAIL: metacrisp has no :effective-cluster-size record -- without it a degraded cluster is indistinguishable from a working one.~%") nil)
      ((search ":effective-cluster-size (1 1 1)" txt)
       (format *error-output* "FAIL: :effective-cluster-size is (1 1 1) on a cluster-capable target -- the cluster did NOT form, though the kernel still computes correctly.~%") nil)
      (t t))))

;; tests/run-specs.lisp
(defun validate-cluster-degrade-warning (file &optional ignored)
  "Endeavor 152 rung 05 — a cluster that could not be formed must SAY SO in metadata.

   On a target without cluster support the declaration stands but the effective extent
   collapses to 1.  This asserts the collapse is RECORDED: both fields present, and
   effective (1 1 1).

   NOTE ON SCOPE, deliberately narrower than the rung's prose: this validator sees
   files, not the compiler's stderr, so the log4cl WARNING itself is not machine-checked
   here.  What is checked is the durable artefact -- which is what a benchmark harness
   would assert on anyway, and the reason the effective extent is recorded at all."
  (declare (ignore ignored))
  (let* ((mp (%152-find-metacrisp file))
         (txt (and mp (uiop:read-file-string mp))))
    (cond
      ((null txt)
       (format *error-output* "FAIL: no .metacrisp found next to ~a~%" (file-namestring file)) nil)
      ((not (search ":cluster-size" txt))
       (format *error-output* "FAIL: metacrisp has no :cluster-size record -- the DECLARATION should survive even when the cluster degrades.~%") nil)
      ((not (search ":effective-cluster-size (1 1 1)" txt))
       (format *error-output* "FAIL: expected :effective-cluster-size (1 1 1) on a target without cluster support; the degrade was not recorded.~%") nil)
      (t t))))

;;; =====================================================================
;;; Endeavor 152 — forward --metadata through the PTX binary runner
;;;
;;; run-spec-ptx-binary builds the compiler's argv itself and forwards exactly ONE
;;; flag from the spec's TEST-WITH list: --ir-target-arch=.  Everything else is
;;; dropped.  So a directive like
;;;
;;;   ;; TEST-WITH[--metadata --ir-target=ptx --ir-target-arch=sm_90] : validate-...
;;;
;;; routes here (because of --ir-target=ptx), silently loses --metadata, and no
;;; .metacrisp is ever written -- the validator then fails looking for a file that
;;; was never generated.  Nothing reports the dropped flag.
;;;
;;; Forwarding --metadata is the general fix: any spec that wants to assert on the
;;; metacrisp AND pin a target arch needs both flags to survive.  Kept narrow on
;;; purpose -- this adds one flag rather than forwarding the whole list, because the
;;; runner sets --ir-target itself and passing it twice would be its own bug.
;;;
;;; The generated .metacrisp is deliberately NOT cleaned up here: the existing
;;; cleanup removes only out-path (the .ptx), and the metadata branch of the runner
;;; owns metacrisp cleanup.  Spec dirs already accumulate these under *keep-work*.
;;; =====================================================================

;; tests/run-specs.lisp
(defun run-spec-ptx-binary (file &key (validator nil) (flags nil))
  (let* ((base-name (if *compile-differentiate* (format nil "~a_grad" (pathname-name file)) (pathname-name file)))
         (bin (get-binary-path))
         (out-path (make-pathname :name base-name :type "ptx" :defaults file))
         (args (list (uiop:native-namestring file) "--ir-target=ptx" (format nil "--log-level=~a" cl-user::*log-level*))))
    (when (probe-file out-path) (delete-file out-path))
    (when *compile-debug* (push "--debug" args))
    (when *compile-differentiate* (push "--differentiate" args))
    (when *compile-single-pass* (push "--single-pass" args))
    ;; Endeavor 137: forward --ir-target-arch=<ID> from the TEST-WITH flags to the binary — a
    ;; separate crisp-compile.exe process can't see the in-process *ir-target-arch* dynamic
    ;; binding, so a :block (sm_90+) test gates on the default sm_80 without this.
    (let ((af (find-if (lambda (f) (and (stringp f) (search "--ir-target-arch=" f))) flags)))
      (when af (push af args)))
    ;; Endeavor 152: forward --metadata too.  A spec that wants to assert on the
    ;; .metacrisp *and* pin an arch carries both flags; dropping this one meant the
    ;; metacrisp was never written and the validator failed on a missing file.
    (when (find-if (lambda (f) (and (stringp f) (string= f "--metadata"))) flags)
      (push "--metadata" args))

    (multiple-value-bind (output error-output exit-code)
        (uiop:run-program (cons (uiop:native-namestring bin) args)
          :output :string
          :error-output :string
          :ignore-error-status t)
      (declare (ignore output))
      (cond
       ((not (zerop exit-code))
         (format *error-output* "FAIL (Compiler Exit Code ~a)~%~a~%" exit-code error-output)
         nil)
       ((probe-file out-path)
         (let ((res (if validator
                        (let* ((ptx-content (uiop:read-file-string out-path))
                               (sym (if (symbolp validator) validator
                                        (find-symbol (string-upcase (string validator)) :crisp.spec-runner))))
                          (if (and sym (fboundp sym))
                              (funcall sym file ptx-content)
                              (progn
                                (format *error-output* "FAIL: Validator ~a not found~%" validator)
                                nil)))
                        t)))
           (when res
             (format t "PASS (Generated .ptx)~%"))
           (unless *keep-work* (delete-file out-path))
           res))
       (t
         (format *error-output* "FAIL (No PTX generated)~%~a~%" error-output)
         nil)))))

;;; =====================================================================
;;; Endeavor 152 — the same validator, in both packages the harness searches
;;;
;;; The two runner paths resolve a validator name DIFFERENTLY:
;;;   PTX path       (find-symbol ... :crisp.spec-runner)  and calls (fn FILE TEXT)
;;;   metadata path  (fboundp sym) else :crisp.compiler    and calls (fn PATH)
;;;
;;; Rung 03 carries --ir-target=ptx so it takes the first; rung 05 carries
;;; --ir-target=spv with --metadata so it takes the second, and reported
;;; "Validator fn VALIDATE-CLUSTER-DEGRADE-WARNING not found" purely because the
;;; definition lived in the other package.
;;;
;;; Rather than move it -- which would break rung 03 -- define the metadata-arity
;;; version in :crisp.compiler as well.  Both delegate to the same check so the two
;;; cannot drift.
;;; =====================================================================

(in-package :crisp.compiler)

;; tests/run-specs.lisp
(defun %152-degrade-check (metacrisp-path)
  "Shared body: assert a degraded cluster is RECORDED in the metacrisp.

   On a target with no cluster support the declaration stands but the effective extent
   collapses to 1.  The kernel is still correct -- which is exactly why the collapse has
   to be visible somewhere a test can read."
  (let* ((p (if (listp metacrisp-path) (first metacrisp-path) metacrisp-path))
         (txt (and p (probe-file p) (uiop:read-file-string p))))
    (cond
      ((null txt)
       (format *error-output* "FAIL: metacrisp not found (~a).~%" metacrisp-path) nil)
      ((not (search ":cluster-size" txt))
       (format *error-output* "FAIL: metacrisp has no :cluster-size record -- the DECLARATION should survive even when the cluster degrades.~%") nil)
      ((not (search ":effective-cluster-size (1 1 1)" txt))
       (format *error-output* "FAIL: expected :effective-cluster-size (1 1 1) on a target without cluster support; the degrade was not recorded.~%") nil)
      (t t))))

;; tests/run-specs.lisp
(defun validate-cluster-degrade-warning (metacrisp-path)
  "Endeavor 152 rung 05, metadata-path arity (one argument: the .metacrisp path).

   NOTE ON SCOPE, narrower than the rung's prose: a validator sees files, not the
   compiler's stderr, so the log4cl WARNING is not machine-checked here.  What is
   checked is the durable artefact -- which is what a benchmark harness would assert
   on anyway, and the whole reason the effective extent is recorded."
  (%152-degrade-check metacrisp-path))

(in-package :crisp.spec-runner)

;; tests/run-specs.lisp
(defun validate-cluster-degrade-warning (file &optional ignored)
  "Endeavor 152 rung 05, PTX-path arity (FILE plus the emitted text, which is ignored).
   Delegates to the same check as the :crisp.compiler definition."
  (declare (ignore ignored))
  (crisp.compiler::%152-degrade-check (%152-find-metacrisp file)))

;;; =====================================================================
;;; Endeavor 152 — metadata validators under --differentiate
;;;
;;; THE SYMPTOM.  Rungs 03 and 05 failed the --differentiate pass while their kernels
;;; differentiated perfectly.  Rungs 01 and 02, asserting the same feature, passed.
;;;
;;; THE CAUSE, and it is not autodiff.  A .ptx holds the WHOLE MODULE, so under
;;; --differentiate `_grad.ptx` carries TWO entries -- forward and backward -- and the
;;; forward's .reqnctapercluster is still there for 01/02's PTX validator to find.  A
;;; .metacrisp is written PER KERNEL, and under --differentiate only the BACKWARD
;;; kernel's file is emitted.  So a validator asserting on the FORWARD kernel's
;;; dispatch record simply has no file to read.
;;;
;;; WHY THE FIRST SKIP REASON WAS WRONG.  It said the backward "does not propagate
;;; cluster-size" and called that a decision owed by a later phase.  Endeavour 146
;;; already settled it: scheduling is not mathematics.  cluster-size says WHERE THE
;;; BYTES ARRIVE; it has no place in a derivative, and a backward kernel inheriting it
;;; would be the leak, not the fix.  Nothing is owed.
;;;
;;; SO ASSERT THAT.  Handed a backward metacrisp, these validators now check that the
;;; scheduling declaration did NOT leak into it.  That turns a skip into a real test,
;;; and it is a test worth having: it fails the day something starts copying dispatch
;;; declarations onto generated backward kernels.
;;; =====================================================================

(in-package :crisp.compiler)

;; tests/run-specs.lisp
(defun %152-backward-metacrisp-p (txt)
  "T if TXT is a BACKWARD kernel's metacrisp.  The AD pass names its kernel <name>_grad
   and writes it to its own file, so the kernel name is the reliable tell."
  (and txt (search "_grad\"" txt)))

;; tests/run-specs.lisp
(defun %152-assert-no-schedule-leak (txt what)
  "Endeavour 146's thesis as an assertion: a backward kernel must NOT carry the
   forward's scheduling declarations.  cluster-size is data movement -- it changes when
   and where bytes arrive, not what is computed -- so a derivative has no use for it and
   its presence would mean a schedule had leaked into the math."
  (cond
    ((search ":cluster-size" txt)
     (format *error-output* "FAIL (~a): the BACKWARD kernel's metacrisp carries :cluster-size.  Scheduling declarations must not propagate into a derivative -- cluster-size says where bytes arrive, not what is computed.~%" what)
     nil)
    ((search ":effective-cluster-size" txt)
     (format *error-output* "FAIL (~a): the BACKWARD kernel's metacrisp carries :effective-cluster-size.~%" what)
     nil)
    (t t)))

;; tests/run-specs.lisp
(defun %152-degrade-check (metacrisp-path)
  "Rung 05.  On a FORWARD metacrisp: assert the degrade was recorded (declaration kept,
   effective extent collapsed to 1).  On a BACKWARD one: assert the schedule did not leak."
  (let* ((p (if (listp metacrisp-path) (first metacrisp-path) metacrisp-path))
         (txt (and p (probe-file p) (uiop:read-file-string p))))
    (cond
      ((null txt)
       (format *error-output* "FAIL: metacrisp not found (~a).~%" metacrisp-path) nil)
      ((%152-backward-metacrisp-p txt)
       (%152-assert-no-schedule-leak txt "rung 05 backward"))
      ((not (search ":cluster-size" txt))
       (format *error-output* "FAIL: metacrisp has no :cluster-size record -- the DECLARATION should survive even when the cluster degrades.~%") nil)
      ((not (search ":effective-cluster-size (1 1 1)" txt))
       (format *error-output* "FAIL: expected :effective-cluster-size (1 1 1) on a target without cluster support; the degrade was not recorded.~%") nil)
      (t t))))

;; tests/run-specs.lisp
(defun %152-extent-check (metacrisp-path)
  "Rung 03.  On a FORWARD metacrisp: assert both records exist and the cluster actually
   formed.  On a BACKWARD one: assert the schedule did not leak."
  (let* ((p (if (listp metacrisp-path) (first metacrisp-path) metacrisp-path))
         (txt (and p (probe-file p) (uiop:read-file-string p))))
    (cond
      ((null txt)
       (format *error-output* "FAIL: metacrisp not found (~a).~%" metacrisp-path) nil)
      ((%152-backward-metacrisp-p txt)
       (%152-assert-no-schedule-leak txt "rung 03 backward"))
      ((not (search ":cluster-size" txt))
       (format *error-output* "FAIL: metacrisp has no :cluster-size record.~%") nil)
      ((not (search ":effective-cluster-size" txt))
       (format *error-output* "FAIL: metacrisp has no :effective-cluster-size record -- without it a degraded cluster is indistinguishable from a working one.~%") nil)
      ((search ":effective-cluster-size (1 1 1)" txt)
       (format *error-output* "FAIL: :effective-cluster-size is (1 1 1) on a cluster-capable target -- the cluster did NOT form, though the kernel still computes correctly.~%") nil)
      (t t))))

;; tests/run-specs.lisp
(defun validate-cluster-degrade-warning (metacrisp-path)
  "Rung 05, metadata-path arity (one argument: the .metacrisp path)."
  (%152-degrade-check metacrisp-path))

;; tests/run-specs.lisp
(defun validate-metacrisp-cluster-extent (metacrisp-path)
  "Rung 03, metadata-path arity (one argument: the .metacrisp path)."
  (%152-extent-check metacrisp-path))

(in-package :crisp.spec-runner)

;; tests/run-specs.lisp
(defun validate-cluster-degrade-warning (file &optional ignored)
  "Rung 05, PTX-path arity (FILE plus emitted text, which is ignored)."
  (declare (ignore ignored))
  (crisp.compiler::%152-degrade-check (%152-find-metacrisp file)))

;; tests/run-specs.lisp
(defun validate-metacrisp-cluster-extent (file &optional ignored)
  "Rung 03, PTX-path arity (FILE plus emitted text, which is ignored)."
  (declare (ignore ignored))
  (crisp.compiler::%152-extent-check (%152-find-metacrisp file)))
