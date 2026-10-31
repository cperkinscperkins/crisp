;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)
;; EMPTY as of 2026-10-29 -- endeavours 196-199's validators folded into tests/run-specs.lisp.

;;; Endeavour 200 (sort_v2 contest) -- BUG 138 validators.

;; tests/run-specs.lisp
(defun %200-helper-names (text)
  "The __crisp_ash_* / __crisp_popcount_* names mentioned in TEXT."
  (remove-duplicates (cl-ppcre:all-matches-as-strings "__crisp_(?:ash|popcount)_[a-z]+" text) :test #'string=))

;; tests/run-specs.lisp
(defun validate-ptx-200-helpers-inline (file ptx-string)
  "Endeavour 200 / BUG 138: on PTX the ash / popcount helpers are inlined -- no call.uni reaches one,
   and the shift and popc instructions are in the kernel."
  (declare (ignore file))
  (let ((calls (cl-ppcre:all-matches-as-strings "call(?:\\.uni)?[^;]*__crisp_(?:ash|popcount)_[a-z]+" ptx-string)))
    (cond (calls (format t "  FAIL: a helper is still called: ~a~%" (first calls)) nil)
          ((not (cl-ppcre:scan "\\bpopc\\.b32" ptx-string)) (format t "  FAIL: no popc.b32~%") nil)
          ((not (cl-ppcre:scan "\\bsh[lr]\\.b32|\\bshr\\.u32" ptx-string)) (format t "  FAIL: no 32-bit shift~%") nil)
          (t t))))

;; tests/run-specs.lisp
(defun validate-spv-200-helpers-noinline (spv-path)
  "Endeavour 200 / BUG 138: on SPIR-V every ash / popcount helper keeps FunctionControl DontInline (2)
   -- the BMG needs it (BUG 120 family).  Passes with a note when llvm-spirv is unavailable."
  (let ((txt (crisp.compiler::%spv-disasm spv-path)))
    (if (null txt)
        (progn (format t "  NOTE: llvm-spirv unavailable; DontInline not checked~%") t)
        (let ((names (%200-helper-names txt))
              (bad nil))
          (dolist (nm names)
            (let* ((id (cl-ppcre:register-groups-bind (i) ((format nil "Name (\\d+) \"~a\"" nm) txt) i))
                   (ctl (and id (cl-ppcre:register-groups-bind (c)
                                    ((format nil "(?m)^5 Function \\d+ ~a (\\d+) " id) txt)
                                  (parse-integer c)))))
              (unless (and ctl (logtest ctl 2))
                (push (format nil "~a (control ~a)" nm ctl) bad))))
          (cond ((null names) (format t "  FAIL: no ash / popcount helper in the module~%") nil)
                (bad (format t "  FAIL: helpers without DontInline: ~{~a~^, ~}~%" bad) nil)
                (t t))))))
