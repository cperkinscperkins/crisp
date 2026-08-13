;;;; tests/verify-autodiff-parse.lisp
;;;;
;;;; Parser for the ;; VERIFY-AUTODIFF: <body> spec directive.
;;;; Endeavor 103, phase 2.
;;;;
;;;; Independent of the OpenCL runner; safe to load on hosts without an ICD.
;;;; Returns a parsed plist that the runner consumes; spec-runner integration
;;;; lives in phase 3.

(in-package :cl-user)

;;; === Internal token / value helpers ===================================

(defun %vad-tokenize (body)
  "Splits BODY on Space/Tab whitespace into a list of non-empty tokens.
   Whitespace inside `[...]` is preserved -- a bracketed group is one token,
   so vector literals like `A=[1.0 2.0 3.0]` survive intact."
  (let ((tokens nil)
        (start nil)
        (depth 0))
    (loop for i from 0 below (length body)
          for c = (aref body i)
          do (cond
               ((char= c #\[)
                (unless start (setf start i))
                (incf depth))
               ((char= c #\])
                (when (plusp depth) (decf depth)))
               ((and (zerop depth) (or (char= c #\Space) (char= c #\Tab)))
                (when start
                  (push (subseq body start i) tokens)
                  (setf start nil)))
               (t (unless start (setf start i))))
          finally (when start (push (subseq body start) tokens)))
    (nreverse tokens)))

;;; --- Endeavor 145 (P6): 2-D matrix literals -----------------------------
;;;
;;; The tokenizer above now tracks bracket DEPTH rather than a boolean, so a matrix
;;; literal `A=[[1.0 2.0][3.0 4.0]]` survives as ONE token.  With the old boolean the
;;; first `]` ended bracket mode and the remainder was split into separate tokens.

(defun %vad-matrix-literal-p (str)
  "T when STR is a 2-D literal `[[...][...]]` rather than a 1-D `[...]`, decided by
   the first non-space character inside the outer bracket being another `[`."
  (and (> (length str) 1)
       (char= (aref str 0) #\[)
       (let ((i (position-if-not (lambda (c) (member c '(#\Space #\Tab)))
                                 str :start 1)))
         (and i (char= (aref str i) #\[)))))

(defun %vad-parse-matrix-literal (str token)
  "Parses STR of the form `[[r0c0 r0c1 ...][r1c0 ...] ...]` into a list of row lists.
   Rows must all be the same length -- a ragged literal is a spec bug, not a shape the
   runner should try to interpret."
  (unless (and (> (length str) 1)
               (char= (aref str 0) #\[)
               (char= (aref str (1- (length str))) #\]))
    (error "VERIFY-AUTODIFF: matrix literal must be `[[..][..]]`, got ~A" str))
  (let ((rows nil)
        (inner (subseq str 1 (1- (length str)))))
    (let ((i 0) (n (length inner)))
      (loop while (< i n)
            do (let ((c (aref inner i)))
                 (cond
                   ((member c '(#\Space #\Tab)) (incf i))
                   ((char= c #\[)
                    (let ((close (position #\] inner :start i)))
                      (unless close
                        (error "VERIFY-AUTODIFF: unterminated row in matrix literal ~A" str))
                      (push (%vad-parse-vector-literal (subseq inner i (1+ close)) token)
                            rows)
                      (setf i (1+ close))))
                   (t (error "VERIFY-AUTODIFF: unexpected character ~A in matrix literal ~A"
                             c str))))))
    (setf rows (nreverse rows))
    (when (null rows)
      (error "VERIFY-AUTODIFF: empty matrix literal in token ~A" token))
    (let ((w (length (first rows))))
      (dolist (r rows)
        (unless (= (length r) w)
          (error "VERIFY-AUTODIFF: ragged matrix literal in token ~A (row lengths differ)"
                 token))))
    rows))

(defun %vad-generated-matrix-p (str)
  "T when STR is the compact matrix generator form `RxC@START:STEP`.
   Endeavor 145 (P6)."
  (and (position #\@ str)
       (position #\x str :test #'char-equal)
       (< (position #\x str :test #'char-equal) (position #\@ str))))

(defun %vad-parse-generated-matrix (str token)
  "Parses `RxC@START:STEP` into a list of R row-lists, where element (i,j) is
   START + STEP*(i*C + j) — a row-major linear ramp.

   Endeavor 145 (P6).  A matmul gradient test needs matrices big enough to satisfy the
   MMA shape contract (8x16 and 16x16 at the smallest), and writing 384 literals into a
   directive line makes the spec unreadable.  The ramp is deliberately NON-UNIFORM: a
   uniform matrix is equal to its own transpose, so it could not catch a transposed
   operand — which is exactly the kind of error the backward's staged B^T might have."
  (let* ((at (position #\@ str))
         (xp (position #\x str :test #'char-equal))
         (rows (%vad-parse-float (subseq str 0 xp) token))
         (cols (%vad-parse-float (subseq str (1+ xp) at) token))
         (rest (subseq str (1+ at)))
         (colon (position #\: rest))
         (start (%vad-parse-float (if colon (subseq rest 0 colon) rest) token))
         (step  (if colon (%vad-parse-float (subseq rest (1+ colon)) token) 1)))
    (unless (and (integerp rows) (> rows 0) (integerp cols) (> cols 0))
      (error "VERIFY-AUTODIFF: matrix generator needs positive integer RxC, got ~A" str))
    (loop for i from 0 below rows
          collect (loop for j from 0 below cols
                        collect (cl:float (+ start (* step (+ (* i cols) j))) 1.0)))))

(defun %vad-parse-index-spec (str token key)
  "Parses `R,C` into the list (R C), or a bare `I` into the integer I.

   `at.<name>` addresses a 1-D vector with one index and a 2-D matrix with a row,col
   pair.  A comma rather than parens keeps the token free of characters the tokenizer
   would otherwise have to track."
  (let ((comma (position #\, str)))
    (if (null comma)
        (let ((v (%vad-parse-float str token)))
          (unless (and (integerp v) (>= v 0))
            (error "VERIFY-AUTODIFF: ~A must be a non-negative integer, got ~A" key str))
          v)
        (let ((r (%vad-parse-float (subseq str 0 comma) token))
              (c (%vad-parse-float (subseq str (1+ comma)) token)))
          (unless (and (integerp r) (>= r 0) (integerp c) (>= c 0))
            (error "VERIFY-AUTODIFF: ~A must be `row,col` non-negative integers, got ~A"
                   key str))
          (list r c)))))

(defun %vad-parse-vector-literal (str token)
  "Parses STR of the form `[v0 v1 v2 ...]` into a list of real numbers.
   STR must start with `[` and end with `]`."
  (unless (and (> (length str) 1)
               (char= (aref str 0) #\[)
               (char= (aref str (1- (length str))) #\]))
    (error "VERIFY-AUTODIFF: vector literal must be `[v0 v1 ...]`, got ~A" str))
  (let* ((inner (string-trim '(#\Space #\Tab #\Return #\Newline)
                             (subseq str 1 (1- (length str)))))
         (parts (loop with parts = nil
                      with start = nil
                      for i from 0 below (length inner)
                      for c = (aref inner i)
                      do (cond
                           ((or (char= c #\Space) (char= c #\Tab))
                            (when start
                              (push (subseq inner start i) parts)
                              (setf start nil)))
                           (t (unless start (setf start i))))
                      finally (when start
                                (push (subseq inner start) parts))
                              (return (nreverse parts)))))
    (when (null parts)
      (error "VERIFY-AUTODIFF: empty vector literal in token ~A" token))
    (mapcar (lambda (p) (%vad-parse-float p token)) parts)))

(defun %vad-parse-float (str token)
  "Reads STR as a real number, or signals a clear error citing TOKEN.
   Uses READ-FROM-STRING with REALP guard; rejects symbols / lists / etc."
  (let ((v (handler-case (read-from-string str nil nil)
             (error (e)
               (error "VERIFY-AUTODIFF: cannot parse number in token ~A: ~A"
                      token e)))))
    (unless (realp v)
      (error "VERIFY-AUTODIFF: expected a real number in token ~A, got ~A"
             token str))
    v))

(defun %vad-split-kv (token)
  "Splits TOKEN at the first '=' into (key . value-string).
   Errors if no '=' is present."
  (let ((eq-pos (position #\= token)))
    (unless eq-pos
      (error "VERIFY-AUTODIFF: token ~A is not of the form key=value" token))
    (cons (subseq token 0 eq-pos)
          (subseq token (1+ eq-pos)))))

(defparameter *vad-reserved-keys*
  '("atol" "h" "seed-grad" "output-vec" "output-mat" "group" "groups" "precision" "denormal")
  "Option keys that are not input names.")

(defparameter *vad-prefix* "VERIFY-AUTODIFF:")

(defparameter *vad-bare-prefix* "VERIFY-AUTODIFF"
  "Directive name without the terminating colon, so the optional
   `[BACKEND]` pin can be parsed between the two.")

(defparameter *vad-known-runtimes* '(("L0" . :l0) ("CUDA" . :cuda) ("OPENCL" . :opencl))
  "Backend names accepted inside VERIFY-AUTODIFF[...]:, mapped to the
   runner's *AD-RUNTIME* keywords.  Endeavor 147.")

(defun %vad-starts-with (s prefix)
  (and (>= (length s) (length prefix))
       (string= prefix (subseq s 0 (length prefix)))))

(defun %vad-match-directive (line)
  "Recognises `VERIFY-AUTODIFF: <body>` and the endeavor-147 pinned form
   `VERIFY-AUTODIFF[CUDA]: <body>`.

   Returns (values BODY RUNTIME) when LINE is a VERIFY-AUTODIFF directive,
   where RUNTIME is NIL for the bare form (meaning: run on whatever this
   machine has) or a keyword for the pinned form.  Returns NIL when LINE
   is not a VERIFY-AUTODIFF directive at all.

   A pinned backend name that is not recognised is an ERROR rather than a
   silent skip — a typo'd `VERIFY-AUTODIFF[CUDA ]:` that quietly stopped
   verifying anything would be the worst possible failure mode for a test
   directive whose entire job is to catch silent wrongness."
  (unless (%vad-starts-with line *vad-bare-prefix*)
    (return-from %vad-match-directive nil))
  (let ((rest (subseq line (length *vad-bare-prefix*))))
    (cond
      ;; Bare form: "VERIFY-AUTODIFF: ..."
      ((and (> (length rest) 0) (char= (aref rest 0) #\:))
       (values (string-trim '(#\Space #\Tab #\Return #\Newline) (subseq rest 1))
               nil))
      ;; Pinned form: "VERIFY-AUTODIFF[BACKEND]: ..."
      ((and (> (length rest) 0) (char= (aref rest 0) #\[))
       (let ((close (position #\] rest)))
         (unless close
           (error "VERIFY-AUTODIFF: unterminated `[` in directive: ~A" line))
         (let* ((name (string-trim '(#\Space #\Tab)
                                   (subseq rest 1 close)))
                (entry (assoc name *vad-known-runtimes* :test #'string-equal))
                (after (subseq rest (1+ close))))
           (unless entry
             (error "VERIFY-AUTODIFF[~A]: unknown backend; expected one of ~{~A~^, ~}"
                    name (mapcar #'car *vad-known-runtimes*)))
           (unless (and (> (length after) 0) (char= (aref after 0) #\:))
             (error "VERIFY-AUTODIFF[~A]: expected `:` after the backend name in: ~A"
                    name line))
           (values (string-trim '(#\Space #\Tab #\Return #\Newline) (subseq after 1))
                   (cdr entry)))))
      (t nil))))

;;; === Public entry point ===============================================

(defun parse-verify-autodiff (directive-lines)
  "Parses `;; VERIFY-AUTODIFF: <body>` directives from DIRECTIVE-LINES.

   DIRECTIVE-LINES is a list of strings, each one a comment line lifted
   from the spec file (with or without leading `;;`).  Returns NIL when
   no VERIFY-AUTODIFF line is present; signals an error on malformed
   input, missing `atol`, or multiple VERIFY-AUTODIFF lines in one spec.

   Body grammar (whitespace-separated key=value tokens):

     <name>=<float>           Scalar input value.
     <name>=[v0 v1 ...]       Vector input (1D, contiguous-compact).  Phase 5b.
     atol=<float>             Mandatory absolute tolerance for FD-vs-analytical.
     h=<float>                Optional FD step size (default 1e-3).
     seed-grad=<float>        Optional output gradient seed (default 1.0).
     at.<name>=<int>          Index in vector input <name> to perturb / compare.
                              Required for vector inputs that the FD pass touches.
     expect.<name>=<float>    Expected analytical gradient.  For scalar inputs
                              this is the full gradient; for vector inputs it
                              is the gradient at the at.<name> index.
     struct=<name,name,...>   Comma-separated list of dotted-name parents that
                              are struct inputs (passed by value as one kernel
                              arg, with a shadow-struct grad cell as &out).
                              Without this, dotted-name parents are treated as
                              records (SROA'd into per-field plain args).

   Return value, when a directive is present:
     (:inputs         ((<name-string> . <scalar-or-list>) ...)
      :atol           <float>
      :h              <float>
      :seed-grad      <float>
      :at-points      ((<name-string> . <integer>) ...)
      :expected-grads ((<name-string> . <float>) ...)
      :structs        (<name-string> ...))

   In :inputs, the value is a real number for scalar inputs and a list of
   real numbers for vector inputs."
  (let ((matching nil))
    (dolist (line directive-lines)
      (let ((trimmed (string-left-trim '(#\Space #\Tab #\; #\Return #\Newline) line)))
        (multiple-value-bind (body runtime) (%vad-match-directive trimmed)
          (when body
            (push (cons body runtime) matching)))))
    (cond
      ((null matching) nil)
      ((> (length matching) 1)
       (error "Multiple VERIFY-AUTODIFF directives in one spec; at most one allowed."))
      (t
       (let* ((body (car (first matching)))
              (pinned-runtime (cdr (first matching)))
              (tokens (%vad-tokenize body))
              (inputs nil)
              (at-points nil)
              (expected-grads nil)
              (structs nil)
              (atol nil)
              (h 1e-3)
              (seed-grad 1.0)
              (output-vec nil)
              (output-mat nil)
              (group-size 1)
              (group-count 1)
              ;; Endeavor 128 (Phase 5): compile the fwd + bwd kernels under a chosen
              ;; precision / denormal mode so AD can be verified across the FP matrix.
              (precision nil)
              (denormal nil))
         (when (null tokens)
           (error "VERIFY-AUTODIFF: empty body; need at least one input and atol=<float>"))
         (dolist (token tokens)
           (let* ((kv (%vad-split-kv token))
                  (key (car kv))
                  (val-str (cdr kv)))
             (cond
               ((string= key "atol")
                (setf atol (%vad-parse-float val-str token)))
               ((string= key "h")
                (setf h (%vad-parse-float val-str token)))
               ((string= key "seed-grad")
                (setf seed-grad (%vad-parse-float val-str token)))
               ((string= key "precision")
                (cond ((string-equal val-str "fast") (setf precision :fast))
                      ((string-equal val-str "ieee") (setf precision :ieee))
                      (t (error "VERIFY-AUTODIFF: precision must be fast|ieee, got ~A" val-str))))
               ((string= key "denormal")
                (cond ((string-equal val-str "ftz") (setf denormal :ftz))
                      ((string-equal val-str "preserve") (setf denormal :preserve))
                      (t (error "VERIFY-AUTODIFF: denormal must be ftz|preserve, got ~A" val-str))))
               ((string= key "group")
                ;; Endeavor 145 (P6): workgroup (sub-group) size for the launch.  Default 1,
                ;; which is what every pre-145 spec used.  An MMA kernel is SUB-GROUP
                ;; COLLECTIVE and produces nothing at all with a single thread, so it must
                ;; declare the width its `local-size` expects (16 on BMG, 32 on NVIDIA).
                (let ((v (%vad-parse-float val-str token)))
                  (unless (and (integerp v) (> v 0))
                    (error "VERIFY-AUTODIFF: group must be a positive integer, got ~A" val-str))
                  (setf group-size v)))
               ((string= key "groups")
                ;; Endeavor 145 (P8): number of workgroups to dispatch.  Default 1.  >1 is what
                ;; makes the backward's CROSS-WORKGROUP gradient accumulation real: dA reduces
                ;; over the forward's grid-x and dB over grid-y, so several workgroups add into
                ;; the same grad tile and the scatter must be atomic.
                (let ((v (%vad-parse-float val-str token)))
                  (unless (and (integerp v) (> v 0))
                    (error "VERIFY-AUTODIFF: groups must be a positive integer, got ~A" val-str))
                  (setf group-count v)))
               ((string= key "output-mat")
                ;; 145 (P6): output is a 2-D ROWSxCOLS float matrix.  Without this (and
                ;; without output-vec) the runner assumes a scalar cell output.  f(A) for a
                ;; matrix output is the sum of all elements — the same all-ones-seed
                ;; convention output-vec already uses, which keeps f scalar so a
                ;; finite-difference gradient is well defined.
                (let ((x (position #\x val-str :test #'char-equal)))
                  (unless x
                    (error "VERIFY-AUTODIFF: output-mat must be ROWSxCOLS, got ~A" val-str))
                  (let ((r (%vad-parse-float (subseq val-str 0 x) token))
                        (c (%vad-parse-float (subseq val-str (1+ x)) token)))
                    (unless (and (integerp r) (> r 0) (integerp c) (> c 0))
                      (error "VERIFY-AUTODIFF: output-mat must be positive integers ROWSxCOLS, got ~A"
                             val-str))
                    (setf output-mat (list r c)))))
               ((string= key "output-vec")
                ;; Output is a 1D float vector of LENGTH elements (107).
                ;; Without this, the runner assumes a scalar (cell float)
                ;; output.  f(A) for vector outputs is the sum of elements
                ;; (equivalent to dot with all-ones seed).
                (let ((v (%vad-parse-float val-str token)))
                  (unless (and (integerp v) (> v 0))
                    (error "VERIFY-AUTODIFF: output-vec must be a positive integer, got ~A"
                           val-str))
                  (setf output-vec v)))
               ((string= key "struct")
                ;; Comma-separated list of struct-input parent names.
                (let ((parts (loop with parts = nil
                                   with start = 0
                                   for i from 0 below (length val-str)
                                   when (char= (aref val-str i) #\,)
                                     do (push (subseq val-str start i) parts)
                                        (setf start (1+ i))
                                   finally (push (subseq val-str start) parts)
                                           (return (nreverse parts)))))
                  (dolist (p parts)
                    (let ((trimmed (string-trim '(#\Space #\Tab) p)))
                      (when (> (length trimmed) 0)
                        (push trimmed structs))))))
               ((and (>= (length key) 7)
                     (string= "expect." (subseq key 0 7)))
                (push (cons (subseq key 7) (%vad-parse-float val-str token))
                      expected-grads))
               ((and (>= (length key) 3)
                     (string= "at." (subseq key 0 3)))
                ;; 145 (P6): `I` for a vector, `R,C` for a matrix.
                (push (cons (subseq key 3)
                            (%vad-parse-index-spec val-str token key))
                      at-points))
               ((and (> (length val-str) 0) (char= (aref val-str 0) #\[))
                ;; 145 (P6): `[[..][..]]` is a matrix, `[..]` stays a vector.
                (push (cons key (if (%vad-matrix-literal-p val-str)
                                    (%vad-parse-matrix-literal val-str token)
                                    (%vad-parse-vector-literal val-str token)))
                      inputs))
               ;; 145 (P6): compact matrix generator `RxC@START:STEP`.
               ((%vad-generated-matrix-p val-str)
                (push (cons key (%vad-parse-generated-matrix val-str token)) inputs))
               (t
                (push (cons key (%vad-parse-float val-str token)) inputs)))))
         (unless atol
           (error "VERIFY-AUTODIFF: missing mandatory atol=<float>"))
         (when (null inputs)
           (error "VERIFY-AUTODIFF: no input values provided (need at least one <name>=<value>)"))
         (list :inputs (nreverse inputs)
               :atol atol
               :h h
               :seed-grad seed-grad
               :at-points (nreverse at-points)
               :expected-grads (nreverse expected-grads)
               :structs (nreverse structs)
               :output-vec output-vec
               :output-mat output-mat
               :group-size group-size
               :group-count group-count
               :precision precision
               :denormal denormal
               ;; Endeavor 147: NIL for the bare directive (run on whatever
               ;; runtime this machine offers); a keyword when the spec
               ;; pinned one with VERIFY-AUTODIFF[CUDA]: / [L0]:.
               :runtime pinned-runtime))))))
