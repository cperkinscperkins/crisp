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

;;; Endeavour 201 -- :match-global-size scratch (one element per thread in the grid).

;; tests/run-specs.lisp
(defun %vad-resolve-symbolic-size (size kern forms)
  "Endeavour 176.  SIZE (an implicit param's :size-expr) as an element COUNT.  An integer is returned as
   is.  A symbolic size -- implicit reduction scratch is :match-num-warps-per-workgroup (local sweep) or
   :match-num-workgroups (last-man's global partials, since 181) -- is resolved by the same rules as the
   hoisters (%l0-scratch-symbolic-expr): ceiling division for warps, warp width 32 when no profile is
   recorded, both from KERN's declared local size and the SIMD width found in FORMS; the group count is
   the LAUNCH's (*vad-group-count*), which is what the kernel's get-num-groups will report."
  (if (not (keywordp size))
      size
      (let* ((name (symbol-name size))
             (ls (getf kern :local-size))            ; (local-size :set-to N) or (local-size :set-to (A B))
             (n (and (consp ls) (third ls)))
             (n (cond ((integerp n) n)
                      ((and (consp n) (eq (car n) 'quote)) (reduce #'* (second n)))
                      ((and (consp n) (every #'integerp n)) (reduce #'* n))
                      (t nil)))
             (warp (or (%vad-find-simd-width forms) 32)))
        (cond ((string-equal name "MATCH-NUM-WORKGROUPS")
               (or *vad-group-count*
                   (error "%vad-resolve-symbolic-size: :match-num-workgroups needs the launch's group count, and no VERIFY-AUTODIFF pass is active")))
              ;; Endeavour 201: one element per thread in the grid (a look-back-scan's status words).
              ((and (string-equal name "MATCH-GLOBAL-SIZE") n)
               (* (or *vad-group-count*
                      (error "%vad-resolve-symbolic-size: :match-global-size needs the launch's group count, and no VERIFY-AUTODIFF pass is active"))
                  n))
              ((null n)
               (error "%vad-resolve-symbolic-size: symbolic :size-expr ~s needs a compile-time (local-size :set-to N); kernel declares ~s"
                      size ls))
              ((string-equal name "MATCH-WORKGROUP-SIZE") n)
              ((string-equal name "MATCH-NUM-WARPS-PER-WORKGROUP") (ceiling n warp))
              (t (error "%vad-resolve-symbolic-size: unsupported symbolic :size-expr ~s" size))))))
