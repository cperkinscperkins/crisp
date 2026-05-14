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
  "Splits BODY on Space/Tab whitespace into a list of non-empty tokens."
  (let ((tokens nil)
        (start nil))
    (loop for i from 0 below (length body)
          for c = (aref body i)
          do (cond
               ((or (char= c #\Space) (char= c #\Tab))
                (when start
                  (push (subseq body start i) tokens)
                  (setf start nil)))
               (t (unless start (setf start i))))
          finally (when start (push (subseq body start) tokens)))
    (nreverse tokens)))

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
  '("atol" "h" "seed-grad")
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

     <name>=<float>           Input value for kernel scalar input <name>.
                              Required: at least one input.
     atol=<float>             Mandatory absolute tolerance for FD-vs-analytical.
     h=<float>                Optional FD step size (default 1e-3).
     seed-grad=<float>        Optional output gradient seed (default 1.0).
     expect.<name>=<float>    Optional expected analytical gradient for
                              input <name>.  Multiple allowed.

   Return value, when a directive is present:
     (:inputs         ((<name-string> . <float>) ...)
      :atol           <float>
      :h              <float>
      :seed-grad      <float>
      :expected-grads ((<name-string> . <float>) ...))"
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
              (expected-grads nil)
              (atol nil)
              (h 1e-3)
              (seed-grad 1.0))
         (when (null tokens)
           (error "VERIFY-AUTODIFF: empty body; need at least one input and atol=<float>"))
         (dolist (token tokens)
           (let* ((kv (%vad-split-kv token))
                  (key (car kv))
                  (val (%vad-parse-float (cdr kv) token)))
             (cond
               ((string= key "atol")      (setf atol val))
               ((string= key "h")         (setf h val))
               ((string= key "seed-grad") (setf seed-grad val))
               ((and (>= (length key) 7)
                     (string= "expect." (subseq key 0 7)))
                (push (cons (subseq key 7) val) expected-grads))
               (t
                (push (cons key val) inputs)))))
         (unless atol
           (error "VERIFY-AUTODIFF: missing mandatory atol=<float>"))
         (when (null inputs)
           (error "VERIFY-AUTODIFF: no input values provided (need at least one <name>=<float>)"))
         (list :inputs (nreverse inputs)
               :atol atol
               :h h
               :seed-grad seed-grad
               :expected-grads (nreverse expected-grads)))))))
