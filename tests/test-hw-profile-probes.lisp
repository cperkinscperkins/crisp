;; tests/test-hw-profile-probes.lisp
;;
;; Keeps scripts/hw-profile/'s query programs in step with *hardware-profile-schema*.
;;
;; WHY THIS EXISTS.  The probes are standalone C++/CUDA programs that print a paste-ready
;; `def-hardware-profile` form.  Nothing linked them to the schema they are printing, so they
;; drifted silently for four endeavours, and the two worst cases were both silent:
;;
;;   * query-l0.cpp emitted only :mma-shapes '((8 16 8)).  %check-mma-shape is a HARD compile
;;     error on an unlisted shape, so a profile pasted from it refused every bf16/fp16/int8
;;     MMA kernel -- the whole 16-bit half of the benchmark suite.
;;   * query-cuda.cu omitted the typed (:double 8 8 4) entry.  Without it `double` resolves via
;;     the width rule to (16 8 4), which is in the PTX ISA but is NOT an NVVM intrinsic in
;;     LLVM 21.1.5: it assembles and emits an `.extern .func` call with NO diagnostic.
;;
;; Neither failure is visible from the Lisp side, and neither probe can run on a CI box (one
;; needs a Level Zero device, the other CUDA).  So this tests the ONE thing that is checkable
;; without hardware: that the KEY NAMES the probes print are the key names the compiler accepts.
;;
;; It checks BOTH directions, and the second is the one that catches real drift:
;;
;;   A. every key a probe prints is a schema key      -> catches a renamed/removed schema key
;;   B. every key a vendor's BUILT-IN profile uses is  -> catches a probe falling behind the
;;      printed or named by that vendor's probe          profile we actually ship

(in-package :crisp.tests)

(defparameter *hw-probe-files*
  '(("scripts/hw-profile/query-l0.cpp"  . "BMG")
    ("scripts/hw-profile/query-cuda.cu" . "H100"))
  "Probe source -> the upcased built-in profile name that probe is the reference for.")

(defun %probe-line-key (line)
  "The profile KEY a probe source LINE prints, or NIL.

   A key is a colon-token at the START of a printf format literal, after optional indentation
   and optional `;` comment markers -- which is exactly where a key lands in the emitted form,
   whether live (`\"  :simd-width %u\"`) or suggested (`\"  ; :wgmma-shapes\"`).

   Anchoring at the literal's start is what keeps VALUES out.  `(:double 8 8 4)` is an
   :mma-shapes ENTRY, not a key, and it is preceded by `(`; the legend lines start `;;` then a
   word.  Lines with no string literal at all (the C++ header prose, which also names keys) are
   skipped, so only what is actually PRINTED counts."
  (let ((q (position #\" line)))
    (when q
      (let ((i (1+ q))
            (n (length line)))
        ;; skip indentation and any comment markers
        (loop while (and (< i n) (member (cl:char line i) '(#\Space #\;))) do (incf i))
        (when (and (< i n) (char= (cl:char line i) #\:))
          (let ((start (1+ i)))
            (loop while (and (< i n)
                             (or (alphanumericp (cl:char line i))
                                 (member (cl:char line i) '(#\: #\-))))
                  do (incf i))
            (let ((name (subseq line start i)))
              (when (and (plusp (length name))
                         ;; a bare ":" or a run of colons is not a key
                         (alpha-char-p (cl:char name 0)))
                (intern (string-upcase name) :keyword)))))))))

(defun %probe-keys (path)
  "Every profile key PATH's printf statements mention, live or commented, as keywords."
  (let ((keys '()))
    (with-open-file (s (merge-pathnames path (uiop:getcwd)) :direction :input)
      (loop for line = (read-line s nil nil)
            while line
            do (let ((k (%probe-line-key line)))
                 (when k (pushnew k keys)))))
    (nreverse keys)))

(define-test hw-profile-probe-schema
  "The hw-profile query programs agree with *hardware-profile-schema*.")

;;; --- Direction A: a probe must not print a key the compiler would reject ---------------

(define-test (hw-profile-probe-schema probes-print-only-schema-keys)
  "Every key the probes print is a key register-hardware-profile accepts.

   A probe that prints an unknown key hands the user a form that fails with 'unknown key',
   which reads as their mistake rather than ours."
  (let ((valid (mapcar #'car crisp.compiler::*hardware-profile-schema*)))
    (dolist (entry *hw-probe-files*)
      (let* ((path (car entry))
             (keys (%probe-keys path)))
        ;; A probe that suddenly mentions NO keys means the scanner broke, not that the
        ;; probe is clean -- that would make this whole test vacuously green.
        (true (>= (length keys) 8)
              "~a: found only ~a key(s); the scanner is probably broken" path (length keys))
        (dolist (k keys)
          (true (member k valid)
                "~a prints ~s, which is not in *hardware-profile-schema*.  Valid keys: ~s"
                path k valid))))))

;;; --- Direction B: a probe must not fall behind the profile we ship ---------------------

(define-test (hw-profile-probe-schema probes-cover-their-builtin-profile)
  "Every key a vendor's built-in profile uses is printed or named by that vendor's probe.

   This is the direction that catches real drift: `bmg` gained :mma-lowerings in endeavour 156
   and three :mma-shapes entries by 159, while query-l0.cpp still printed one shape and no
   lowerings at all.  Anyone following the README got a profile that refused half the suite."
  (dolist (entry *hw-probe-files*)
    (let* ((path (car entry))
           (profile-name (cdr entry))
           (profile (gethash profile-name crisp.compiler::*hardware-profiles*)))
      (true profile
            "built-in profile ~s is not registered; register-builtin-hardware-profiles ~
             should have run from initialize-compiler" profile-name)
      (when profile
        (let ((probe-keys (%probe-keys path)))
          (loop for (k nil) on profile by #'cddr
                do (true (member k probe-keys)
                         "~a never mentions ~s, but the built-in ~a profile uses it — ~
                          a user following this probe gets a profile missing that key"
                         path k profile-name)))))))
