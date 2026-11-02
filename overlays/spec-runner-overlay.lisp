;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)
;; EMPTY as of 2026-10-30 -- endeavours 200 / 201 folded into tests/run-specs.lisp: %200-helper-names,
;; validate-ptx-200-helpers-inline, validate-spv-200-helpers-noinline (before main); %vad-resolve-symbolic-size
;; (:match-global-size) replaced in place.
;; EMPTY as of 2026-10-29 -- endeavours 196-199's validators folded into tests/run-specs.lisp.

;; tests/run-specs.lisp
(defun validate-cuda-launch-is-fatal (crisp-file cu-files)
  "BUG 135: every generated harness ends the program on a failed launch, rather than reporting
   success and comparing buffers nothing wrote."
  (declare (ignore crisp-file))
  (and cu-files
       (every (lambda (cu)
                (let ((text (uiop:read-file-string cu)))
                  (cond ((not (search "CUDA_CHECK(_crisp_launch_result);" text))
                         (format t "FAIL: ~a does not check its launch.~%" (file-namestring cu))
                         nil)
                        ((search "launch error:" text)
                         (format t "FAIL: ~a still reports a failed launch and carries on.~%" (file-namestring cu))
                         nil)
                        (t t))))
              cu-files)))

;; tests/run-specs.lisp
(defun validate-ptx-no-minnctapersm (file ptx-text)
  "Endeavour 182: the entry asks for no occupancy.  BUG 135: a .maxntid is fine, it is not a request
   for occupancy; validate-ptx-no-launch-bounds is the stricter check."
  (declare (ignore file))
  (cond ((null ptx-text) (format t "FAIL: no PTX text~%") nil)
        ((search ".minnctapersm" ptx-text)
         (format t "FAIL: unexpected .minnctapersm in the PTX.~%") nil)
        (t t)))

(defun validate-ptx-no-launch-bounds (file ptx-text)
  "BUG 135: the entry carries neither launch bound.  This is what ptxas gets when the workgroup size
   is not fixed at compile time, or under (occupancy-target nil)."
  (declare (ignore file))
  (cond ((null ptx-text) (format t "FAIL: no PTX text~%") nil)
        ((or (search ".minnctapersm" ptx-text) (search ".maxntid" ptx-text))
         (format t "FAIL: unexpected launch bounds (.maxntid / .minnctapersm) in the PTX.~%") nil)
        (t t)))

(defun validate-ptx-maxntid-288 (file ptx-text)
  "BUG 135: a 288-thread workgroup says so with .maxntid, and asks for no occupancy."
  (declare (ignore file))
  (cond ((null ptx-text) (format t "FAIL: no PTX text~%") nil)
        ((not (search ".maxntid 288" ptx-text))
         (format t "FAIL: no .maxntid 288 in the PTX.~%") nil)
        ((search ".minnctapersm" ptx-text)
         (format t "FAIL: unexpected .minnctapersm in the PTX.~%") nil)
        (t t)))

(defun validate-ptx-maxnreg-96 (file ptx-text)
  "BUG 135: (max-registers 96) reached the PTX, alongside the workgroup's .maxntid."
  (declare (ignore file))
  (cond ((null ptx-text) (format t "FAIL: no PTX text~%") nil)
        ((not (search ".maxnreg 96" ptx-text))
         (format t "FAIL: no .maxnreg 96 in the PTX.~%") nil)
        ((not (search ".maxntid 288" ptx-text))
         (format t "FAIL: .maxnreg without the workgroup's .maxntid.~%") nil)
        (t t)))

(defun validate-ptx-no-maxnreg (file ptx-text)
  "BUG 135: (warn-max-registers N) changes nothing in the PTX."
  (declare (ignore file))
  (cond ((null ptx-text) (format t "FAIL: no PTX text~%") nil)
        ((search ".maxnreg" ptx-text)
         (format t "FAIL: unexpected .maxnreg in the PTX.~%") nil)
        (t t)))

;; tests/run-specs.lisp
(defun validate-ptx-opt-out-entry (file ptx-text)
  "BUG 135: (occupancy-target nil) took every launch bound off RV_OPTOUT's own entry.  Only that entry
   is checked: its _GRAD kernel does not inherit scheduling declarations (BUG 075), and at 288 threads
   the bound is what lets it launch."
  (declare (ignore file))
  (let* ((start (and ptx-text (search ".entry rv_optout(" ptx-text)))
         (end (and start (position #\{ ptx-text :start start)))
         (header (and end (subseq ptx-text start end))))
    (cond ((null header) (format t "FAIL: no rv_optout entry in the PTX.~%") nil)
          ((or (search ".maxntid" header) (search ".minnctapersm" header))
           (format t "FAIL: unexpected launch bounds on the rv_optout entry.~%") nil)
          (t t))))
