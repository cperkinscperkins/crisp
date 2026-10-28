;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)
;; EMPTY as of 2026-10-25 -- endeavour 193 folded into tests/run-specs.lisp: parse-hoist-flags + its clause in
;; run-spec-with-hoist; validate-has-die-check (replacing validate-has-llvm-trap), validate-ptx-wait-checks-die-record.

;; tests/run-specs.lisp
(defun %195-ptx-lines-with (ptx-string needle)
  "Endeavour 195.  The lines of PTX-STRING that contain NEEDLE."
  (let ((out '()))
    (with-input-from-string (s ptx-string)
      (loop for line = (read-line s nil) while line
            do (when (search needle line) (push (string-trim '(#\Space #\Tab) line) out))))
    (nreverse out)))

;; tests/run-specs.lisp
(defun %195-check-ptx-relaxed (ptx-string space)
  "Endeavour 195.  PTX-STRING has an ld.relaxed.gpu and an st.relaxed.gpu (in state space SPACE, e.g.
   \".global\" or \".shared\", or any when NIL), no ld.volatile, and NO atom.* read-modify-write:
   atomic-load / atomic-store! must not lower to an RMW."
  (let* ((ld (%195-ptx-lines-with ptx-string (format nil "ld.relaxed.gpu~@[~a~]" space)))
         (st (%195-ptx-lines-with ptx-string (format nil "st.relaxed.gpu~@[~a~]" space)))
         (rmw (%195-ptx-lines-with ptx-string "atom."))
         (vol (%195-ptx-lines-with ptx-string "ld.volatile")))
    (format t "~&  195 PTX: ~d ld.relaxed.gpu~@[~a~], ~d st.relaxed.gpu~@[~a~], ~d atom., ~d ld.volatile~%"
            (length ld) space (length st) space (length rmw) (length vol))
    (cond ((null ld)  (format t "  FAIL: no ld.relaxed.gpu~@[~a~]~%" space) nil)
          ((null st)  (format t "  FAIL: no st.relaxed.gpu~@[~a~]~%" space) nil)
          (rmw        (format t "  FAIL: an atomic RMW is present: ~a~%" (first rmw)) nil)
          (vol        (format t "  FAIL: a volatile load is present: ~a~%" (first vol)) nil)
          (t t))))

;; tests/run-specs.lisp
(defun validate-ptx-relaxed-load-store (file ptx-string)
  "Endeavour 195 / specs 01-03, 05: atomic-load / atomic-store! are ld.relaxed.gpu / st.relaxed.gpu,
   never an atom.* RMW."
  (declare (ignore file))
  (%195-check-ptx-relaxed ptx-string nil))

;; tests/run-specs.lisp
(defun validate-ptx-relaxed-load-store-shared (file ptx-string)
  "Endeavour 195 / spec 04: atomic-load / atomic-store! on workgroup scratch are
   ld.relaxed.gpu.shared / st.relaxed.gpu.shared -- still DEVICE scope."
  (declare (ignore file))
  (%195-check-ptx-relaxed ptx-string ".shared"))

;; tests/run-specs.lisp
(defun validate-spv-relaxed-load-store (spv-path)
  "Endeavour 195 / specs 01, 03: the module has OpAtomicLoad and OpAtomicStore, every one at scope
   Device (1) with semantics Relaxed (0), and no other atomic instruction (no RMW stands in for them).
   Passes with a note when llvm-spirv is unavailable."
  (let ((txt (crisp.compiler::%spv-disasm spv-path)))
    (if (null txt)
        (progn (format t "  (llvm-spirv unavailable -- 195 atomic check skipped)~%") t)
        (let ((consts (make-hash-table :test 'equal)) (loads 0) (stores 0) (bad '()))
          ;; pass 1: integer constants  (`4 Constant TYPE ID VALUE`)
          (with-input-from-string (s txt)
            (loop for line = (read-line s nil) while line
                  do (let ((toks (crisp.compiler::%spv-tokens line)))
                       (when (and (>= (length toks) 5) (string= (second toks) "Constant"))
                         (setf (gethash (fourth toks) consts) (fifth toks))))))
          ;; pass 2: atomics.  `N AtomicLoad TYPE RESULT PTR SCOPE SEM`, `N AtomicStore PTR SCOPE SEM VALUE`
          (with-input-from-string (s txt)
            (loop for line = (read-line s nil) while line
                  do (let* ((toks (crisp.compiler::%spv-tokens line))
                            (op (second toks)))
                       (cond ((null op))
                             ((string= op "AtomicLoad")
                              (incf loads)
                              (unless (and (equal (gethash (sixth toks) consts) "1")
                                           (equal (gethash (seventh toks) consts) "0"))
                                (push line bad)))
                             ((string= op "AtomicStore")
                              (incf stores)
                              (unless (and (equal (gethash (fourth toks) consts) "1")
                                           (equal (gethash (fifth toks) consts) "0"))
                                (push line bad)))
                             ((eql 0 (search "Atomic" op))
                              (push line bad))))))
          (format t "~&  195 SPIR-V: ~d OpAtomicLoad, ~d OpAtomicStore, ~d not Device/Relaxed or other atomic~%"
                  loads stores (length bad))
          (cond ((zerop loads)  (format t "  FAIL: no OpAtomicLoad~%") nil)
                ((zerop stores) (format t "  FAIL: no OpAtomicStore~%") nil)
                (bad (format t "  FAIL: ~a~%" (first bad)) nil)
                (t t))))))
