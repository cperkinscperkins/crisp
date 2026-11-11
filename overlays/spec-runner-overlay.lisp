;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)
;; EMPTY as of 2026-11-09 -- endeavour 210's validators (validate-ptx-tma-grid-constant,
;; validate-ptx-transform-scale3, validate-ptx-wgmma-store-pairs-only) folded into tests/run-specs.lisp.
;; EMPTY as of 2026-11-06 -- endeavour 208's tcgen05 validators folded into tests/run-specs.lisp.
;; EMPTY as of 2026-11-04 -- endeavour 207's sync int8 validators folded into tests/run-specs.lisp.
;; EMPTY as of 2026-11-02 -- BUG 135's validators folded into tests/run-specs.lisp.
;; EMPTY as of 2026-10-30 -- endeavours 200 / 201 folded into tests/run-specs.lisp: %200-helper-names,
;; validate-ptx-200-helpers-inline, validate-spv-200-helpers-noinline (before main); %vad-resolve-symbolic-size
;; (:match-global-size) replaced in place.
;; EMPTY as of 2026-10-29 -- endeavours 196-199's validators folded into tests/run-specs.lisp.

;;;; Endeavour 211 -- shift / rotate validators.  See tests/spec/211-shift-rotate/.

;; tests/run-specs.lisp  (NEW, endeavour 211; before main)
(defun %211-helper-names (text)
  "The __crisp_shift_* / __crisp_rotate_* helper names mentioned in TEXT."
  (remove-duplicates (cl-ppcre:all-matches-as-strings "__crisp_(?:shift|rotate)_(?:left|right)_[a-z]+" text)
                     :test #'string=))

;; tests/run-specs.lisp  (NEW, endeavour 211; before main)
(defun validate-ptx-211-shift-rotate (file ptx-string)
  "Endeavour 211: on PTX a 32-bit rotate by a run-time count is ONE funnel shift (shf.l.wrap.b32 and
   shf.r.wrap.b32 both present), the module has no selp.b32 (the select chain a run-time ash needs), and
   no call reaches a __crisp_shift / __crisp_rotate helper (they inline on PTX)."
  (declare (ignore file))
  (let ((calls (cl-ppcre:all-matches-as-strings "call(?:\\.uni)?[^;]*__crisp_(?:shift|rotate)_" ptx-string))
        (selps (cl-ppcre:all-matches-as-strings "\\bselp\\.b32" ptx-string)))
    (cond (calls (format t "  FAIL: a helper is still called: ~a~%" (first calls)) nil)
          ((not (cl-ppcre:scan "\\bshf\\.l\\.wrap\\.b32" ptx-string)) (format t "  FAIL: no shf.l.wrap.b32~%") nil)
          ((not (cl-ppcre:scan "\\bshf\\.r\\.wrap\\.b32" ptx-string)) (format t "  FAIL: no shf.r.wrap.b32~%") nil)
          (selps (format t "  FAIL: ~a selp.b32 (a select chain survived)~%" (length selps)) nil)
          (t t))))

;; tests/run-specs.lisp  (NEW, endeavour 211; before main)
(defun validate-spv-211-helpers-noinline (spv-path)
  "Endeavour 211: on SPIR-V every __crisp_shift_* / __crisp_rotate_* helper keeps FunctionControl
   DontInline (2) -- the BMG needs it (BUG 120 family).  Passes with a note when llvm-spirv is unavailable."
  (let ((txt (crisp.compiler::%spv-disasm spv-path)))
    (if (null txt)
        (progn (format t "  NOTE: llvm-spirv unavailable; DontInline not checked~%") t)
        (let ((names (%211-helper-names txt))
              (bad nil))
          (dolist (nm names)
            (let* ((id (cl-ppcre:register-groups-bind (i) ((format nil "Name (\\d+) \"~a\"" nm) txt) i))
                   (ctl (and id (cl-ppcre:register-groups-bind (c)
                                    ((format nil "(?m)^5 Function \\d+ ~a (\\d+) " id) txt)
                                  (parse-integer c)))))
              (unless (and ctl (logtest ctl 2))
                (push (format nil "~a (control ~a)" nm ctl) bad))))
          (cond ((< (length names) 4)
                 (format t "  FAIL: expected 4 shift / rotate helpers, found ~a: ~{~a~^, ~}~%" (length names) names) nil)
                (bad (format t "  FAIL: helpers without DontInline: ~{~a~^, ~}~%" bad) nil)
                (t t))))))

;;;; Endeavour 212 -- warp vote validators.  See tests/spec/212-warp-vote/.

;; tests/run-specs.lisp  (NEW, endeavour 212; before main)
(defun validate-ptx-212-vote (file ptx-string)
  "Endeavour 212: on PTX each vote is ONE vote.sync instruction with the full member mask --
   vote.sync.ballot.b32, vote.sync.any.pred and vote.sync.all.pred all present, each with mask -1 -- and the
   module has no shfl.sync (a vote is not built from shuffles)."
  (declare (ignore file))
  (let ((votes (cl-ppcre:all-matches-as-strings "vote\\.sync\\.(?:ballot\\.b32|any\\.pred|all\\.pred)[^;]*;" ptx-string)))
    (cond ((not (cl-ppcre:scan "vote\\.sync\\.ballot\\.b32" ptx-string)) (format t "  FAIL: no vote.sync.ballot.b32~%") nil)
          ((not (cl-ppcre:scan "vote\\.sync\\.any\\.pred" ptx-string)) (format t "  FAIL: no vote.sync.any.pred~%") nil)
          ((not (cl-ppcre:scan "vote\\.sync\\.all\\.pred" ptx-string)) (format t "  FAIL: no vote.sync.all.pred~%") nil)
          ((find-if-not (lambda (v) (cl-ppcre:scan ",\\s*-1;$" v)) votes)
           (format t "  FAIL: a vote without the full member mask: ~a~%" (find-if-not (lambda (v) (cl-ppcre:scan ",\\s*-1;$" v)) votes)) nil)
          ((cl-ppcre:scan "\\bshfl\\.sync" ptx-string) (format t "  FAIL: a shfl.sync in a vote-only kernel~%") nil)
          (t t))))

;; tests/run-specs.lisp  (NEW, endeavour 212; before main)
(defun validate-spv-212-vote (spv-path)
  "Endeavour 212: on SPIR-V the votes are the group-non-uniform ops -- GroupNonUniformBallot,
   GroupNonUniformAny and GroupNonUniformAll present, with the GroupNonUniformBallot and GroupNonUniformVote
   capabilities declared (a strict driver refuses the ops without them) -- and no GroupNonUniformShuffle.
   Passes with a note when llvm-spirv is unavailable."
  (let ((txt (crisp.compiler::%spv-disasm spv-path)))
    (if (null txt)
        (progn (format t "  NOTE: llvm-spirv unavailable; votes not checked~%") t)
        (let ((missing (remove-if (lambda (re) (cl-ppcre:scan re txt))
                                  '("(?m)^\\d+ GroupNonUniformBallot " "(?m)^\\d+ GroupNonUniformAny "
                                    "(?m)^\\d+ GroupNonUniformAll " "Capability GroupNonUniformBallot\\b"
                                    "Capability GroupNonUniformVote\\b"))))
          (cond (missing (format t "  FAIL: missing from the SPIR-V: ~{~a~^, ~}~%" missing) nil)
                ((cl-ppcre:scan "GroupNonUniformShuffle" txt) (format t "  FAIL: a shuffle in a vote-only kernel~%") nil)
                (t t))))))
