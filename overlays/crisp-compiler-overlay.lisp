;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)


;;; ===================================================================
;;; Endeavor 130 (hardware profiles) — Phase 0: def-hardware-profile
;;; registration + canonical key schema + per-key value validation.
;;; (For the eventual merge: the defvar belongs in src/types/registry.lisp
;;;  with the other registries; the schema + functions in a new
;;;  src/hardware-profile.lisp.)
;;; ===================================================================

;; src/types/registry.lisp
(defvar *hardware-profiles* (make-hash-table :test 'equal)
  "Endeavor 130: upcased profile-name string -> normalized plist of the target's
   capabilities/limits.  Populated by def-hardware-profile / register-hardware-profile.")

;; src/hardware-profile.lisp
(defparameter *hardware-profile-schema*
  '((:simd-width                  . :pos-int)
    (:compute-units               . :pos-int)
    (:max-registers-per-cu        . :pos-int)
    (:max-registers-per-thread    . :pos-int)
    (:max-total-threads-per-block . :pos-int)
    (:max-concurrent-kernels      . :pos-int)
    (:native-cache-line-size      . :pos-int)   ; bytes
    (:max-shared-memory-per-block . :size)      ; KB/MB/GB/TB literal -> bytes
    (:l2-cache-size               . :size)
    (:max-work-group-dims         . :dims3)     ; (x y z) positive ints
    (:mma-shapes                  . :mma-shapes)) ; list of (M N K) triples
  "Endeavor 130: canonical hardware-profile keys and their value types.  Every key
   is KNOWN from Phase 0 (so profiles are typo-checked and may be complete); the
   CONSUMERS that read each key are added phase by phase.  Unknown keys are a
   compile error; any subset may be specified (missing keys are fine).")

;; src/hardware-profile.lisp
(defun %hp-parse-size (v)
  "Parse a size value into bytes: a positive integer, or a size-literal symbol
   like 227KB / 50MB / 8GB / 2TB.  Returns the byte count, or NIL if unparseable."
  (cond
    ((and (integerp v) (plusp v)) v)
    ((symbolp v)
     (let* ((name (string-upcase (symbol-name v)))
            (n (length name)))
       (when (> n 2)
         (let ((mult (cond ((string= (subseq name (- n 2)) "KB") 1024)
                           ((string= (subseq name (- n 2)) "MB") (expt 1024 2))
                           ((string= (subseq name (- n 2)) "GB") (expt 1024 3))
                           ((string= (subseq name (- n 2)) "TB") (expt 1024 4))
                           (t nil))))
           (when mult
             (let ((num (ignore-errors (parse-integer name :end (- n 2)))))
               (when (and num (plusp num)) (* num mult))))))))
    (t nil)))

;; src/hardware-profile.lisp
(defun %hp-unquote (v)
  "Unwrap (quote X) -> X; otherwise return V unchanged."
  (if (and (consp v) (eq (car v) 'quote)) (cadr v) v))

;; src/hardware-profile.lisp
(defun %hp-3-pos-ints-p (x)
  "T if X is a list of exactly 3 positive integers."
  (and (listp x) (= (length x) 3)
       (every (lambda (e) (and (integerp e) (plusp e))) x)))

;; src/hardware-profile.lisp
(defun %hp-validate-value (profile-name key type raw)
  "Validate/normalize RAW for KEY of TYPE.  Signals a clear compile error on a
   malformed value; returns the normalized value (sizes in bytes, lists unquoted)."
  (ecase type
    (:pos-int
     (unless (and (integerp raw) (plusp raw))
       (error "def-hardware-profile ~a: key ~a expects a positive integer, got ~s."
              profile-name key raw))
     raw)
    (:size
     (let ((bytes (%hp-parse-size raw)))
       (unless bytes
         (error "def-hardware-profile ~a: key ~a expects a byte count or size literal (e.g. 227KB, 50MB, 8GB), got ~s."
                profile-name key raw))
       bytes))
    (:dims3
     (let ((d (%hp-unquote raw)))
       (unless (%hp-3-pos-ints-p d)
         (error "def-hardware-profile ~a: key ~a expects a list of 3 positive integers, got ~s."
                profile-name key raw))
       d))
    (:mma-shapes
     (let ((shapes (%hp-unquote raw)))
       (unless (and (listp shapes) shapes (every #'%hp-3-pos-ints-p shapes))
         (error "def-hardware-profile ~a: key ~a expects a non-empty list of (M N K) positive-integer triples, got ~s."
                profile-name key raw))
       shapes))))

;; src/hardware-profile.lisp
(defun register-hardware-profile (name proplist)
  "Endeavor 130 Phase 0: parse, validate, and register a hardware profile.
   Unknown key -> error; malformed value -> error; duplicate key within one
   profile -> error; missing keys are fine (a partial profile is valid).  Keyed in
   *hardware-profiles* by the upcased profile name (package-agnostic)."
  (unless (symbolp name)
    (error "def-hardware-profile: expected a name symbol, got ~s." name))
  (when (oddp (length proplist))
    (error "def-hardware-profile ~a: keys and values must pair up (odd number of elements)." name))
  (let ((normalized nil)
        (seen nil))
    (loop for (key val) on proplist by #'cddr do
      (unless (keywordp key)
        (error "def-hardware-profile ~a: expected a keyword key, got ~s." name key))
      (let ((entry (assoc key *hardware-profile-schema*)))
        (unless entry
          (error "def-hardware-profile ~a: unknown key ~a.  Valid keys: ~{~a~^ ~}."
                 name key (mapcar #'car *hardware-profile-schema*)))
        (when (member key seen)
          (error "def-hardware-profile ~a: duplicate key ~a." name key))
        (push key seen)
        (setf (getf normalized key) (%hp-validate-value name key (cdr entry) val))))
    (setf (gethash (string-upcase (symbol-name name)) *hardware-profiles*) normalized)
    name))
