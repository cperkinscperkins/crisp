;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)

;; tests/run-specs.lisp
;; Endeavour 192 (cache-hints) -- PTX validators.  Each takes (FILE PTX-STRING) like the other PTX
;; validators.  They look only at the OPCODE token of each ld.global / st.global line, split on ".",
;; so a qualifier is a whole part ("cg", "nc", "L1::no_allocate", "L2::evict_first", "L2::256B", "v4").
(defun %c192-access-opcodes (ptx-string prefix)
  "Endeavour 192.  The opcode token of every PTX line whose opcode starts with PREFIX
   (\"ld.global\" or \"st.global\"), in order."
  (let ((out '()))
    (with-input-from-string (s ptx-string)
      (loop for line = (read-line s nil) while line
            do (let* ((trimmed (string-left-trim '(#\Space #\Tab) line))
                      (end (or (position-if (lambda (c) (member c '(#\Space #\Tab))) trimmed)
                               (length trimmed)))
                      (op (subseq trimmed 0 end)))
                 (when (and (>= (length op) (length prefix))
                            (string= prefix op :end2 (length prefix)))
                   (push op out)))))
    (nreverse out)))

(defun %c192-parts (opcode)
  "Endeavour 192.  OPCODE split on \".\"."
  (uiop:split-string opcode :separator "."))

(defun %c192-hinted-p (opcode)
  "Endeavour 192.  T when OPCODE carries a cache hint: a cache operator (cg cs lu cv) or any
   L1::/L2:: qualifier.  .nc is NOT a hint (it is inferred read-only-ness)."
  (some (lambda (q) (or (member q '("cg" "cs" "lu" "cv") :test #'string=) (search "::" q)))
        (%c192-parts opcode)))

(defun %c192-has (opcode &rest quals)
  "Endeavour 192.  T when OPCODE has every qualifier in QUALS as a whole part."
  (let ((parts (%c192-parts opcode)))
    (every (lambda (q) (member q parts :test #'string=)) quals)))

(defun %c192-ptx-version (ptx-string)
  "Endeavour 192.  The module's .version as a number (7.4 -> 74), or NIL."
  (let ((p (search ".version " ptx-string)))
    (when p
      (let* ((s (subseq ptx-string (+ p 9) (min (length ptx-string) (+ p 16))))
             (dot (position #\. s)))
        (when dot
          (ignore-errors
           (+ (* 10 (parse-integer s :end dot))
              (parse-integer s :start (1+ dot) :junk-allowed t))))))))

(defun %c192-fail (fmt &rest args)
  "Endeavour 192.  Print a FAIL line and return NIL."
  (format *error-output* "FAIL: ~?~%" fmt args)
  nil)

(defun %c192-check (ptx-string &key load-pred store-pred (min-version 74))
  "Endeavour 192.  Shared body: every ld.global satisfies LOAD-PRED and every st.global satisfies
   STORE-PRED (a NIL predicate skips that side), each side non-empty when checked, and the PTX ISA
   is at least MIN-VERSION (NIL skips)."
  (let ((lds (%c192-access-opcodes ptx-string "ld.global"))
        (sts (%c192-access-opcodes ptx-string "st.global"))
        (ver (%c192-ptx-version ptx-string)))
    (cond ((and load-pred (null lds)) (%c192-fail "no ld.global in the PTX"))
          ((and store-pred (null sts)) (%c192-fail "no st.global in the PTX"))
          ((and load-pred (notevery load-pred lds))
           (%c192-fail "load(s) without the expected cache hint: ~{~a~^, ~}" (remove-if load-pred lds)))
          ((and store-pred (notevery store-pred sts))
           (%c192-fail "store(s) without the expected cache hint: ~{~a~^, ~}" (remove-if store-pred sts)))
          ((and min-version (or (null ver) (< ver min-version)))
           (%c192-fail "PTX ISA .version ~a is below ~a (eviction priorities / prefetch sizes need 7.4)"
                       ver min-version))
          (t t))))

(defun %c192-streaming-p (op)
  "Endeavour 192.  The :streaming qualifiers."
  (%c192-has op "L1::no_allocate" "L2::evict_first"))

(defun %c192-unhinted-p (op)
  "Endeavour 192.  No cache hint (.nc allowed)."
  (not (%c192-hinted-p op)))

(defun %c192-vector-p (op)
  "Endeavour 192.  A vector access: .v2 / .v4 / .v8 part."
  (some (lambda (q) (member q '("v2" "v4" "v8") :test #'string=)) (%c192-parts op)))

(defun validate-ptx-cache-streaming-loads (file ptx-string)
  "Endeavour 192 / spec 01: every load L1::no_allocate.L2::evict_first, no store hinted, ISA >= 7.4."
  (declare (ignore file))
  (%c192-check ptx-string :load-pred #'%c192-streaming-p :store-pred #'%c192-unhinted-p))

(defun validate-ptx-cache-streaming-stores (file ptx-string)
  "Endeavour 192 / spec 02: every store L1::no_allocate.L2::evict_first, no load hinted, ISA >= 7.4."
  (declare (ignore file))
  (%c192-check ptx-string :load-pred #'%c192-unhinted-p :store-pred #'%c192-streaming-p))

(defun validate-ptx-cache-reused (file ptx-string)
  "Endeavour 192 / spec 03: every load and store carries L2::evict_last."
  (declare (ignore file))
  (flet ((p (op) (%c192-has op "L2::evict_last")))
    (%c192-check ptx-string :load-pred #'p :store-pred #'p)))

(defun validate-ptx-cache-no-l1 (file ptx-string)
  "Endeavour 192 / spec 04: every load is ld.global.cg and every store st.global.cg.  (.cg is an old
   cache operator, so no ISA floor is asserted.)"
  (declare (ignore file))
  (flet ((p (op) (%c192-has op "cg")))
    (%c192-check ptx-string :load-pred #'p :store-pred #'p :min-version nil)))

(defun validate-ptx-cache-prefetch-256 (file ptx-string)
  "Endeavour 192 / spec 05 (sm_80): every load is streaming AND L2::256B; ISA raised to >= 7.4."
  (declare (ignore file))
  (flet ((p (op) (and (%c192-streaming-p op) (%c192-has op "L2::256B"))))
    (%c192-check ptx-string :load-pred #'p)))

(defun validate-ptx-no-cache-hints (file ptx-string)
  "Endeavour 192 / spec 06: :cache :default emits no hint on any ld/st."
  (declare (ignore file))
  (%c192-check ptx-string :load-pred #'%c192-unhinted-p :store-pred #'%c192-unhinted-p
                          :min-version nil))

(defun validate-ptx-cache-mixed (file ptx-string)
  "Endeavour 192 / spec 07: A is :streaming, B is not, both loaded symmetrically -> the streaming loads
   are exactly half of all loads (and there are some)."
  (declare (ignore file))
  (let* ((lds (%c192-access-opcodes ptx-string "ld.global"))
         (hinted (count-if #'%c192-streaming-p lds))
         (plain (count-if #'%c192-unhinted-p lds)))
    (cond ((zerop hinted) (%c192-fail "no streaming load (expected A's loads hinted)"))
          ((/= (+ hinted plain) (length lds))
           (%c192-fail "loads with an unexpected hint: ~{~a~^, ~}" lds))
          ((/= hinted plain)
           (%c192-fail "~d streaming vs ~d plain loads; A and B are symmetric, so the hint went to the wrong argument"
                       hinted plain))
          (t t))))

(defun validate-ptx-cache-view-inherits (file ptx-string)
  "Endeavour 192 / spec 08: the float4 view of a :streaming input -> every load vector-width,
   .nc, and streaming."
  (declare (ignore file))
  (flet ((p (op) (and (%c192-vector-p op) (%c192-has op "nc") (%c192-streaming-p op))))
    (%c192-check ptx-string :load-pred #'p)))

(defun validate-ptx-view-loads-nc (file ptx-string)
  "Endeavour 192 / spec 09 (BUG 134): lane access to a float4 view of a read-only input -> every load
   .nc and vector-width, no cache hint."
  (declare (ignore file))
  (flet ((p (op) (and (%c192-vector-p op) (%c192-has op "nc") (%c192-unhinted-p op))))
    (%c192-check ptx-string :load-pred #'p :min-version nil)))

(defun validate-ptx-cache-cell-reused (file ptx-string)
  "Endeavour 192 / spec 10: some load (the cell K) carries L2::evict_last; no store is hinted."
  (declare (ignore file))
  (let ((lds (%c192-access-opcodes ptx-string "ld.global"))
        (sts (%c192-access-opcodes ptx-string "st.global")))
    (cond ((notany (lambda (op) (%c192-has op "L2::evict_last")) lds)
           (%c192-fail "no L2::evict_last load (expected the :reused cell's read): ~{~a~^, ~}" lds))
          ((some #'%c192-hinted-p sts) (%c192-fail "hinted store(s): ~{~a~^, ~}" sts))
          (t t))))

;; tests/run-specs.lisp
;; Endeavour 192 -- SPIR-V validators.  Two-package delegation, as for the 155/157/180 SPIR-V
;; validators: the runner resolves validator names here; the implementations live in :crisp.compiler.
(defun validate-spv-cache-streaming-loads (spv-path)
  (funcall (find-symbol "VALIDATE-SPV-CACHE-STREAMING-LOADS" :crisp.compiler) spv-path))

(defun validate-spv-cache-streaming-stores (spv-path)
  (funcall (find-symbol "VALIDATE-SPV-CACHE-STREAMING-STORES" :crisp.compiler) spv-path))

;; tests/run-specs.lisp
(defun %c192-entry-text (ptx-string name-part)
  "Endeavour 192.  The PTX text of the first .entry whose name contains NAME-PART, up to the next
   .entry (or the end), or NIL."
  (let ((start 0))
    (loop
      (let ((p (search ".entry " ptx-string :start2 start)))
        (unless p (return nil))
        (let* ((name-end (or (position #\( ptx-string :start p) (length ptx-string)))
               (name (subseq ptx-string (+ p 7) name-end))
               (next (search ".entry " ptx-string :start2 (1+ p))))
          (when (search name-part name)
            (return (subseq ptx-string p (or next (length ptx-string)))))
          (setf start (1+ p)))))))

(defun validate-ptx-cache-adjoints-unhinted (file ptx-string)
  "Endeavour 192 / spec 14 (--differentiate): in the _grad kernel, some load (a primal read of a
   :streaming cell) is streaming, and no store (the adjoints) carries any cache hint."
  (declare (ignore file))
  (let ((grad (%c192-entry-text ptx-string "_grad")))
    (if (null grad)
        (%c192-fail "no _grad entry in the --differentiate PTX")
        (let ((lds (%c192-access-opcodes grad "ld.global"))
              (sts (%c192-access-opcodes grad "st.global")))
          (cond ((notany #'%c192-streaming-p lds)
                 (%c192-fail "_grad: no streaming load (the primal x / y reads keep their hint): ~{~a~^, ~}" lds))
                ((null sts) (%c192-fail "_grad: no st.global (expected the adjoint stores)"))
                ((some #'%c192-hinted-p sts)
                 (%c192-fail "_grad: hinted adjoint store(s) -- shadow buffers must not inherit :cache: ~{~a~^, ~}" sts))
                (t t))))))
