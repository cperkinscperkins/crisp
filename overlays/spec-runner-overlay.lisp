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

(in-package :crisp.spec-runner)

;; tests/run-specs.lisp
(defun %152-index-of (needle hay)
  "Character index of NEEDLE in HAY, or NIL."
  (search needle hay))

;; tests/run-specs.lisp
(defun validate-ptx-multicast (file ptx-string)
  "Endeavor 152 rung 10 — assert the multicast MECHANISM engaged, not merely that the kernel
   compiled.

   This is the assertion that cannot be replaced by a correctness test.  A load-tile which
   quietly declined to multicast produces BYTE-IDENTICAL results -- each workgroup simply does
   its own fetch of the same tile -- so only the emitted instruction can distinguish a working
   multicast from a fallback.

   Four things are checked, and the last is the one that took the research:
     1. the bulk-tensor copy carries `.multicast::cluster`
     2. the leader is elected from `%cluster_ctarank` (one WORKGROUP issues, not one thread)
     3. `mbarrier.arrive.expect_tx` is present
     4. expect_tx PRECEDES the multicast copy in the emitted text -- i.e. it sits OUTSIDE the
        ctarank guard.  Every destination workgroup must announce the bytes it expects to
        RECEIVE on its own mbarrier; only the issuing one runs the copy.  Emitting expect_tx
        inside the guard would leave every non-issuing workgroup waiting forever on a barrier
        that was never told to expect anything -- a hang, not a wrong number."
  (declare (ignore file))
  (let ((mc  (%152-index-of "multicast::cluster" ptx-string))
        (rank (%152-index-of "%cluster_ctarank" ptx-string))
        (etx (%152-index-of "mbarrier.arrive.expect_tx" ptx-string)))
    (cond
      ((null mc)
       (format *error-output* "FAIL: no `.multicast::cluster` in the emitted PTX -- the load did NOT multicast.  It would still compute the correct answer, at the bandwidth :multicast was written to avoid.~%")
       nil)
      ((null rank)
       (format *error-output* "FAIL: `.multicast::cluster` is emitted but %cluster_ctarank is never read, so no WORKGROUP leader is elected.  Every workgroup would issue the same multicast.~%")
       nil)
      ((null etx)
       (format *error-output* "FAIL: no mbarrier.arrive.expect_tx -- destination workgroups would never be told how many bytes to await.~%")
       nil)
      ((> etx mc)
       (format *error-output* "FAIL: mbarrier.arrive.expect_tx appears AFTER the multicast copy, which means it is inside the leader guard.  Non-issuing workgroups would wait on a barrier that was never told to expect anything -- a hang.~%")
       nil)
      (t t))))

;;; =====================================================================
;;; Endeavor 152 (fix) — pick the metacrisp that matches the PASS, not the first on disk
;;;
;;; run-spec-ptx-binary deletes the .ptx it generated but NOT the .metacrisp, so those
;;; accumulate in the spec directory.  A full-suite run therefore leaves BOTH
;;;     <stem>_<kernel>.metacrisp          (forward, written by the default phase)
;;;     <stem>_grad_<kernel>.metacrisp     (backward, written by the --differentiate phase)
;;; and %152-find-metacrisp took `(first hits)` — whichever the filesystem happened to return.
;;;
;;; That is why 03 passes in isolation and on a 152-only filter, but can fail in a full run:
;;; the forward validator reads the BACKWARD file, sees no :cluster-size, and reports the
;;; cluster as degraded.  A stale-artifact bug wearing a feature bug's costume.
;;;
;;; Select by the pass we are actually in: *compile-differentiate* says which kernel this run
;;; produced, so ask for that file rather than guessing.
;;; =====================================================================

;; tests/run-specs.lisp
(defun %152-find-metacrisp (file)
  "The .metacrisp for the kernel THIS pass compiled, next to FILE.

   Under --differentiate the compiler emits only the backward kernel's sidecar
   (<stem>_grad_<kernel>.metacrisp); otherwise the forward's.  Both can be present on disk at
   once because the runner does not clean them up, so choose deliberately instead of taking
   whatever `directory` lists first."
  (let* ((dir  (make-pathname :name nil :type nil :defaults file))
         (stem (pathname-name file))
         (hits (directory (merge-pathnames (format nil "~a*.metacrisp" stem) dir)))
         (gradp (lambda (p) (search "_grad" (pathname-name p))))
         (want  (if *compile-differentiate*
                    (remove-if-not gradp hits)
                    (remove-if gradp hits))))
    (or (first want) (first hits))))

(in-package :crisp.spec-runner)

;; tests/run-specs.lisp
(defun validate-ptx-cluster-barrier (file ptx-string)
  "Endeavor 152 rung 20 — a :mode :cluster barrier must be a REAL mbarrier object.
   Asserts only that; the remote arrive that distinguishes it is rung 21's job."
  (declare (ignore file))
  (if (search "mbarrier.init" ptx-string)
      t
      (progn (format *error-output* "FAIL: no mbarrier.init — a :cluster barrier must allocate a real mbarrier, as :block does.~%")
             nil)))

;; tests/run-specs.lisp
(defun validate-ptx-cluster-remote-arrive (file ptx-string)
  "Endeavor 152 rung 21 — `signal` on a :cluster barrier must arrive on PEERS.

   The distinguishing instruction pair is `mapa.shared::cluster` (map this address into a peer's
   view) followed by `mbarrier.arrive.shared::cluster`.  A lowering that emitted the ordinary
   local arrive would release the SIGNALLER'S OWN barrier — which nobody waits on — while the
   peer waits forever.  At cluster extent 1 both resolve to the same address, so that bug passes
   every small test and only hangs at scale.  Hence: read the instruction."
  (declare (ignore file))
  (let ((mapa (search "mapa.shared::cluster" ptx-string))
        (arr  (search "mbarrier.arrive.shared::cluster" ptx-string)))
    (cond
      ((null mapa)
       (format *error-output* "FAIL: no `mapa.shared::cluster` — nothing maps the barrier into a peer's view, so any arrive is local.~%") nil)
      ((null arr)
       (format *error-output* "FAIL: no `mbarrier.arrive.shared::cluster` — the arrive is not cluster-scoped, so it releases this workgroup's own barrier.~%") nil)
      ((> mapa arr)
       (format *error-output* "FAIL: the cluster arrive precedes the mapa that computes its peer address.~%") nil)
      (t t))))

;; tests/run-specs.lisp
(defun validate-ptx-cluster-ring-arrivals (file ptx-string)
  "Endeavor 152 rung 22 — :arrivals is per-workgroup and the COMPILER multiplies.

   The kernel declares a 2-workgroup cluster, a :block `full` ring with :arrivals 1, and a
   :cluster `empty` ring with :arrivals 2.  So the emitted mbarrier init counts must be:
       full  -> 1   (NOT scaled: a multicast completes on each destination's OWN barrier)
       empty -> 4   (2 per workgroup x 2 workgroups arriving all-to-all)
   Both halves are asserted.  Scaling the wrong one is as fatal as scaling neither: a `full`
   barrier initialised to 2 would never complete, and an `empty` initialised to 2 would complete
   early and let a workgroup overwrite a slot a peer was still reading."
  (declare (ignore file))
  (let ((has1 (search "mov.b32 	%r11, 1;" ptx-string))
        (has4 (search ", 4;" ptx-string)))
    (declare (ignorable has1))
    (cond
      ((null (search "mbarrier.init" ptx-string))
       (format *error-output* "FAIL: no mbarrier.init at all.~%") nil)
      ((null has4)
       (format *error-output* "FAIL: no init count of 4 — the :cluster ring's :arrivals 2 was not scaled by the group extent 2.  The barrier would complete one full round of arrivals early.~%") nil)
      (t t))))


;;; =====================================================================
;;; Endeavor 152 (harness fix) — --metadata never worked on the PTX path
;;;
;;; SYMPTOM, reported as "152/03 is flaky": it fails under
;;;     sbcl --non-interactive --load tests/run-specs.lisp --filter=152
;;; but never under --use-binary, and occasionally passes in-process.
;;;
;;; IT IS NOT FLAKY.  It is deterministic per path, and the apparent randomness is STALE
;;; ARTIFACTS: a .metacrisp left behind by an earlier --use-binary run is still on disk, so the
;;; in-process run's validator finds one and passes.  Delete it and the in-process run fails
;;; every time with `metacrisp not found (NIL)`.
;;;
;;; THE REAL CAUSE is a pre-existing harness gap, not anything endeavour 152 introduced.
;;; run-single-spec-pass computes EMIT-METADATA from the flags and then passes it only to the
;;; SPIR-V runners:
;;;     ((eq ir-target :spirv)  (run-spec-spirv-in-process file :emit-metadata emit-metadata ...))
;;;     ((eq ir-target :ptx)    (run-spec-ptx-in-process    file :validator validator))
;;; so `--metadata --ir-target=ptx` has NEVER produced a sidecar in-process.  (The binary path
;;; had the same hole; endeavour 152 patched that one earlier by sniffing the flag list, which
;;; fixed the symptom on one path only.)
;;;
;;; Fixed here the way the SPIR-V path already does it: compile-crisp-file-to-ptx takes
;;; :emit-metadata, binds *emit-metadata*, calls generate-metadata-for-file with a :ptx output
;;; target, and returns the sidecar paths as a second value.
;;;
;;; ALSO: both PTX paths now DELETE the sidecars they generate, as the SPIR-V path does.  Leaving
;;; them on disk is what made a deterministic failure look intermittent, and it is the same
;;; staleness that made a forward validator read a `_grad` sidecar earlier in this endeavour.
;;; =====================================================================

;; tests/run-specs.lisp
(defun compile-crisp-file-to-ptx (filepath &key (emit-metadata nil))
  "Compiles a .crisp file to .ptx and returns (values out-path meta-paths).
   Endeavor 152: honours :emit-metadata, mirroring compile-crisp-file-to-spirv."
  (let* ((base-name (if *compile-differentiate* (format nil "~a_grad" (pathname-name filepath)) (pathname-name filepath)))
         (out-path (make-pathname :name base-name :type "ptx" :defaults filepath))
         (meta-base-path (make-pathname :name base-name :type nil :defaults filepath))
         (meta-paths nil)
         (*standard-output* (make-broadcast-stream)))
    (when (probe-file out-path) (delete-file out-path))

    (let (;; Use a FRESH environment for each spec to ensure isolation
          (crisp.compiler::*struct-name-prefix* (format nil "S_~a_" (substitute #\_ #\- (pathname-name filepath))))
          (forms (progn
                  (crisp.compiler:initialize-compiler :log-level cl-user::*log-level*
                                                      :differentiate *compile-differentiate*)
                  (let ((*package* (find-package :crisp-language)))
                    (with-open-file (stream filepath)
                      (loop for form = (read stream nil :eof)
                            until (eq form :eof)
                            collect form))))))
      (let* ((module (crisp.llvm-bindings:llvm-module-create (pathname-name filepath)))
             (builder (crisp.llvm-bindings:llvm-create-builder)))
        (unwind-protect
            (progn
             (let ((crisp.compiler:*target-backend* :ptx)
                   (crisp.compiler::*emit-metadata* emit-metadata))
               (crisp.compiler:compile-module forms module builder nil nil nil)
               (crisp.compiler:compile-to-ptx
                module out-path
                :compute-capability (crisp.compiler::ptx-compute-capability-string))
               (when emit-metadata
                 (setf meta-paths
                       (crisp.compiler::generate-metadata-for-file
                        filepath meta-base-path
                        :output-targets (list (list :ptx out-path))
                        :forms forms)))))
          (crisp.llvm-bindings:llvm-dispose-builder builder)
          (crisp.llvm-bindings:llvm-dispose-module module))))

    (if (probe-file out-path)
        (values out-path meta-paths)
        (values nil nil))))

;; tests/run-specs.lisp
(defun run-spec-ptx-in-process (file &key (emit-metadata nil) (validator nil))
  "Endeavor 152: accepts :emit-metadata so a spec combining --metadata with --ir-target=ptx
   actually gets a sidecar.  The validator keeps the PTX-path arity (FILE PTX-TEXT); validators
   that assert on metadata locate the sidecar themselves."
  (handler-case
      (multiple-value-bind (out-path meta-paths)
          (compile-crisp-file-to-ptx file :emit-metadata emit-metadata)
        (if out-path
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
                (format t "PASS (Generated ~a)~%" (file-namestring out-path)))
              ;; Clean BOTH artifacts.  Leaving sidecars behind is what made this failure look
              ;; intermittent in the first place.
              (unless *keep-work*
                (when (probe-file out-path) (delete-file out-path))
                (dolist (mp (if (listp meta-paths) meta-paths (list meta-paths)))
                  (when (and mp (probe-file mp)) (delete-file mp))))
              res)
            (progn (format *error-output* "FAIL (No PTX generated)~%") nil)))
    (error (e)
      (uiop:print-backtrace :condition e)
      (format *error-output* "FAIL (Condition: ~a)~%" e)
      nil)))

;; tests/run-specs.lisp  (patched call site: pass :emit-metadata to the PTX in-process runner)


;; tests/run-specs.lisp  (verbatim except ONE call site: the PTX in-process runner now
;; receives :emit-metadata, which the dispatcher had always computed and then passed only
;; to the SPIR-V runners.)
(defun run-single-spec-pass (file flags &optional validator)
  "Execute a single pass of a spec file with specific flags active.
   Extended: --runtime-checks routes to run-spec-runtime-checks-pass;
   --*-math-precision=KEY routes to run-spec-precision-pass."
  ;; NEW: --runtime-checks is handled as a dedicated path — compile with
  ;; runtime assertions enabled and call the validator with the IR string.
  (when (member "--runtime-checks" flags :test #'string=)
    (format t "(RT-Checks)... ")
    (return-from run-single-spec-pass
      (run-spec-runtime-checks-pass file validator)))

  ;; Endeavor 126: precision runs — compile and hand the IR to a precision validator.
  (when (some (lambda (f) (or (search "--force-math-precision=" f)
                              (search "--math-precision=" f)
                              (search "--denormal-handling=" f)))
              flags)
    (format t "(Precision)... ")
    (return-from run-single-spec-pass
      (run-spec-precision-pass file flags validator)))

  ;; Original dispatch (unchanged from base run-specs.lisp):
  (let ((*use-binary*         (or *use-binary*         (member "--use-binary"    flags :test #'string=)))
        (*compile-single-pass* (or *compile-single-pass* (member "--single-pass"  flags :test #'string=)))
        (*compile-debug*       (or *compile-debug*       (member "--debug"        flags :test #'string=)))
        (*compile-differentiate* (or *compile-differentiate* (member "--differentiate" flags :test #'string=)))
        ;; Endeavor 137: honor --ir-target-arch=<ID> in TEST-WITH flags so the in-process
        ;; PTX/SPV compile gates + compute-capability match the CLI (else :block gates on sm_80).
        (crisp.compiler::*ir-target-arch*
          (let ((af (find-if (lambda (f) (and (stringp f) (search "--ir-target-arch=" f))) flags)))
            (if af
                (intern (string-upcase (subseq af (length "--ir-target-arch="))) :keyword)
                crisp.compiler::*ir-target-arch*)))
        (emit-metadata (member "--metadata" flags :test #'string=))
        (ir-target (cond
                     ((member "--ir-target=spv"    flags :test #'string=) :spirv)
                     ((member "--ir-target=ptx"    flags :test #'string=) :ptx)
                     ((member "--ir-target=llvmir" flags :test #'string=) :llvmir)
                     ((member "--metadata"         flags :test #'string=) :spirv)
                     (t nil))))

    ;; Endeavor 144: skip a SPIR-V pass when this machine cannot do one — either because
    ;; SKIP_SPIRV_TESTS says so, or because the translator is not actually invocable (a
    ;; CUDA-only box: bin/ is gitignored, so llvm-spirv is simply absent).  Detection keeps
    ;; the three SPIR-V entry points (here, COMPILE-WITH, EXPECT-STDERR) consistent.
    (when (and (eq ir-target :spirv)
               (or (and (uiop:getenv "SKIP_SPIRV_TESTS") t)
                   (not (spirv-toolchain-available-p))))
      (format t "SKIP (no SPIR-V toolchain on this machine)~%")
      (return-from run-single-spec-pass t))

    (if *use-binary*
        (cond
          ((eq ir-target :spirv)  (run-spec-spirv-binary file :emit-metadata emit-metadata :validator validator))
          ((eq ir-target :ptx)    (run-spec-ptx-binary file :validator validator :flags flags))
          ((eq ir-target :llvmir) (run-spec-llvmir-binary file :validator validator))
          (t (run-spec-binary file)))
        (cond
          ((eq ir-target :spirv)  (run-spec-spirv-in-process file :emit-metadata emit-metadata :validator validator))
          ((eq ir-target :ptx)    (run-spec-ptx-in-process file :emit-metadata emit-metadata :validator validator))
          ((eq ir-target :llvmir) (run-spec-llvmir-in-process file :validator validator))
          (t (run-spec-lisp-loader file))))))


;; tests/run-specs.lisp
(defun validate-ptx-cluster-remote-arrive (file ptx-string)
  "Endeavor 152 rung 21 — `signal` on a :cluster barrier must arrive on PEERS.

   UPDATED after a hardware finding.  The first version looked for `mapa.shared::cluster`, which
   was the form Crisp emitted -- and that form DOES NOT MAP.  Compiling NVIDIA's own
   cluster_group::map_shared_rank() shows the required sequence goes through a GENERIC address:

       cvta.shared.u64    <generic>, <shared offset>
       mapa.u64           <peer>,    <generic>, <rank>
       cvta.to.shared.u64 <shared>,  <peer>
       mbarrier.arrive.shared::cluster.b64 _, [<shared>];

   Handing `mapa` a raw shared-window offset silently yields an UNMAPPED address, so the arrive
   lands on the caller's own barrier -- exactly the silent-local-arrive failure this validator
   exists to catch.  On an H100 that surfaced as
       Invalid __shared__ read ... Address 0x0 is not located in executing CTA.

   So the assertion is now on the CONVERSION, not merely on the presence of a mapa: a `mapa` that
   is not bracketed by the generic round-trip is the bug, not the fix."
  (declare (ignore file))
  (let ((cvta-in  (search "cvta.shared.u64" ptx-string))
        (mapa     (search "mapa.u64" ptx-string))
        (cvta-out (search "cvta.to.shared.u64" ptx-string))
        (arr      (search "mbarrier.arrive.shared::cluster" ptx-string))
        (oldform  (search "mapa.shared::cluster" ptx-string)))
    (cond
      (oldform
       (format *error-output* "FAIL: emits `mapa.shared::cluster` on a raw shared offset.  That form does not map -- the arrive would land on the CALLER'S OWN barrier while the peer waits forever.  Use the generic round-trip (cvta.shared.u64 -> mapa.u64 -> cvta.to.shared.u64).~%") nil)
      ((null arr)
       (format *error-output* "FAIL: no `mbarrier.arrive.shared::cluster` -- the arrive is not cluster-scoped.~%") nil)
      ((null mapa)
       (format *error-output* "FAIL: no `mapa.u64` -- nothing maps the barrier into a peer's view, so any arrive is local.~%") nil)
      ((or (null cvta-in) (null cvta-out))
       (format *error-output* "FAIL: `mapa.u64` is present but not bracketed by the generic conversion (cvta.shared.u64 in, cvta.to.shared.u64 out).  mapa operates on GENERIC addresses; a raw shared offset yields an unmapped result.~%") nil)
      ((> mapa arr)
       (format *error-output* "FAIL: the cluster arrive precedes the mapa that computes its peer address.~%") nil)
      (t t))))
