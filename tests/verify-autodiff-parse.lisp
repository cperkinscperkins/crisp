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
        (in-brackets nil))
    (loop for i from 0 below (length body)
          for c = (aref body i)
          do (cond
               (in-brackets
                (when (char= c #\])
                  (setf in-brackets nil)))
               ((char= c #\[)
                (unless start (setf start i))
                (setf in-brackets t))
               ((or (char= c #\Space) (char= c #\Tab))
                (when start
                  (push (subseq body start i) tokens)
                  (setf start nil)))
               (t (unless start (setf start i))))
          finally (when start (push (subseq body start) tokens)))
    (nreverse tokens)))

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
  '("atol" "h" "seed-grad" "output-vec" "precision" "denormal")
  "Option keys that are not input names.")

(defparameter *vad-prefix* "VERIFY-AUTODIFF:")

(defun %vad-starts-with (s prefix)
  (and (>= (length s) (length prefix))
       (string= prefix (subseq s 0 (length prefix)))))

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
        (when (%vad-starts-with trimmed *vad-prefix*)
          (push trimmed matching))))
    (cond
      ((null matching) nil)
      ((> (length matching) 1)
       (error "Multiple VERIFY-AUTODIFF directives in one spec; at most one allowed."))
      (t
       (let* ((line (first matching))
              (body (string-trim '(#\Space #\Tab #\Return #\Newline)
                                 (subseq line (length *vad-prefix*))))
              (tokens (%vad-tokenize body))
              (inputs nil)
              (at-points nil)
              (expected-grads nil)
              (structs nil)
              (atol nil)
              (h 1e-3)
              (seed-grad 1.0)
              (output-vec nil)
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
                (let ((v (%vad-parse-float val-str token)))
                  (unless (and (integerp v) (>= v 0))
                    (error "VERIFY-AUTODIFF: at.~A must be a non-negative integer, got ~A"
                           (subseq key 3) val-str))
                  (push (cons (subseq key 3) v) at-points)))
               ((and (> (length val-str) 0) (char= (aref val-str 0) #\[))
                (push (cons key (%vad-parse-vector-literal val-str token))
                      inputs))
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
               :precision precision
               :denormal denormal))))))
