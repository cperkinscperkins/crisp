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

;; NOTE (Phase 1): *hardware-profiles* and *requested-hardware-profile* defvars now
;; live in src/compiler.lisp (near the precision vars), because initialize-compiler
;; references them.

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

;;; ===================================================================
;;; Endeavor 130 (hardware profiles) — Phase 1: selection + first
;;; consumer (workgroup / local-size bounds).
;;; (For the eventual merge: these belong in src/hardware-profile.lisp.)
;;; ===================================================================

;; src/hardware-profile.lisp
(defun active-hardware-profile ()
  "Resolve the requested hardware profile (--hardware-profile) to its normalized
   plist, or NIL if none was requested.  Errors if a profile was requested but is
   not registered (a typo'd flag, or a name no def-hardware-profile defines)."
  (when *requested-hardware-profile*
    (let ((p (gethash (string-upcase *requested-hardware-profile*) *hardware-profiles*)))
      (unless p
        (error "Hardware profile ~s not found.  Define it with def-hardware-profile (in a .crisp file passed to the compiler).  Known profiles: ~{~a~^ ~}."
               *requested-hardware-profile*
               (loop for k being the hash-keys of *hardware-profiles* collect k)))
      p)))

;; src/hardware-profile.lisp
(defun %hp-local-size-dims (local-size-decl)
  "Extract concrete (X Y Z) workgroup dims from a (local-size :set-to <val>) decl,
   normalizing a scalar or short list to three dims.  Returns NIL when the local
   size is not compile-time-known (:derive-from / :strategy / absent), in which
   case profile bounds can't be checked."
  (when (consp local-size-decl)
    (let ((v (getf (cdr local-size-decl) :set-to)))
      (cond
        ((and (integerp v) (plusp v)) (list v 1 1))
        ((and (listp v) v (<= 1 (length v) 3)
              (every (lambda (x) (and (integerp x) (plusp x))) v))
         (append v (make-list (- 3 (length v)) :initial-element 1)))
        (t nil)))))

;; src/hardware-profile.lisp
(defun %hp-check-workgroup-bounds (kernel-name local-size-decl profile)
  "Endeavor 130 Phase 1: when PROFILE is active and the local size is
   compile-time-known, error if the workgroup exceeds the profile's
   :max-total-threads-per-block or any :max-work-group-dims axis.  Missing keys are
   skipped (a partial profile simply checks less)."
  (when profile
    (let ((dims (%hp-local-size-dims local-size-decl)))
      (when dims
        (let ((max-total (getf profile :max-total-threads-per-block))
              (max-dims   (getf profile :max-work-group-dims)))
          (when max-total
            (let ((total (reduce #'* dims)))
              (when (> total max-total)
                (error "Kernel ~a: local-size ~a = ~a threads exceeds the hardware profile's :max-total-threads-per-block (~a)."
                       kernel-name dims total max-total))))
          (when max-dims
            (loop for d in dims for m in max-dims for axis from 0
                  when (> d m)
                  do (error "Kernel ~a: local-size axis ~a (~a) exceeds the hardware profile's :max-work-group-dims axis ~a (~a)."
                            kernel-name axis d axis m))))))))

;;; ===================================================================
;;; Endeavor 130 (hardware profiles) — Phase 2: :max-shared-memory-per-block
;;; (local / SLM bounds).  Reuses generate-implicit-signature to enumerate a
;;; kernel's local scratch and sums bytes like the hoist's compute-total-shared-bytes.
;;; (For the eventual merge: src/hardware-profile.lisp.)
;;; ===================================================================

;; src/hardware-profile.lisp
(defun %hp-scratch-elem-bytes (elem-type)
  "Bytes per scratch element, matching the hoist's rule (compute-total-shared-bytes):
   64-bit element types -> 8, everything else -> 4 (the width the launcher reserves)."
  (let ((n (cond ((symbolp elem-type) (symbol-name elem-type))
                 ((consp elem-type)   (symbol-name (first elem-type)))
                 (t ""))))
    (if (member (string-upcase n) '("DOUBLE" "LONG" "ULONG" "INT64" "UINT64" "F64" "I64" "U64")
                :test #'string=)
        8 4)))

;; src/hardware-profile.lisp
(defun %hp-kernel-shared-bytes (kernel-name)
  "Total local (shared) memory bytes a kernel reserves, summed from its implicit
   scratch signature (matching the hoist's `(* (expt size-expr rank) elem-bytes)`).
   Returns the byte total, or NIL if any local scratch size is not a compile-time
   integer (then the bound can't be checked and is skipped)."
  (let ((sig (first (gethash kernel-name *function-table*))))
    (when sig
      (let ((total 0) (known t))
        (dolist (p (generate-implicit-signature sig nil))
          (let ((as        (getf p :address-space))
                (type      (getf p :type))
                (size-expr (getf p :size-expr)))
            (when (and as (string-equal (string as) "LOCAL"))
              ;; size-expr is a SCALAR (vector: total = size^rank) or a LIST of dims
              ;; (matrix/tensor: total = product).  Symbolic sizes -> can't check (skip).
              (let* ((is-tensor (and (consp type)
                                     (member (symbol-name (first type))
                                             '("TENSOR" "VECTOR" "MATRIX") :test #'string-equal)))
                     (rank (if (and is-tensor (integerp (third type))) (third type) 1))
                     (elem (if (consp type) (second type) type))
                     (count (cond
                              ((integerp size-expr) (expt size-expr rank))
                              ((and (listp size-expr) size-expr (every #'integerp size-expr))
                               (reduce #'* size-expr))
                              (t nil))))
                (if count
                    (incf total (* count (%hp-scratch-elem-bytes elem)))
                    (setf known nil))))))
        (when known total)))))

;; src/hardware-profile.lisp
(defun %hp-check-shared-memory (kernel-name profile)
  "Endeavor 130 Phase 2: error if KERNEL-NAME's local/shared memory exceeds the
   profile's :max-shared-memory-per-block.  Skipped if the profile omits that key or
   the total isn't compile-time-known."
  (let ((cap (and profile (getf profile :max-shared-memory-per-block))))
    (when cap
      (let ((used (%hp-kernel-shared-bytes kernel-name)))
        (when (and used (> used cap))
          (error "Kernel ~a: uses ~a bytes of local/shared memory, exceeding the hardware profile's :max-shared-memory-per-block (~a bytes)."
                 kernel-name used cap))))))

;; src/hardware-profile.lisp  (driver, called at the end of compile-module)
(defun %hp-check-all-shared-memory ()
  "Endeavor 130 Phase 2: after a module compiles (all signatures, incl. implicit
   scratch, finalized), validate every kernel's local memory against the active
   hardware profile."
  (let ((profile (active-hardware-profile)))
    (when profile
      (dolist (k *compiled-kernels*)
        (%hp-check-shared-memory k profile)))))

;;; ===================================================================
;;; Endeavor 130 (hardware profiles) — Phase 5: carry the ACTIVE profile
;;; into the metacrisp so the hoist (and, later, runtime compilation) can
;;; use it.  Only the SELECTED profile is emitted (like structs/aliases,
;;; on need); the whole normalized profile is copied (not a subset), so we
;;; never have to reparse it downstream.
;;; (For the eventual merge: src/hardware-profile.lisp / src/metadata.lisp.)
;;; ===================================================================

;; src/hardware-profile.lisp
(defun %hp-serialize-active-profile (stream)
  "Emit the active hardware profile (the one --hardware-profile / a topology named)
   as a top-level metacrisp form, keeping its name.  Values are the normalized
   (already-parsed) form: sizes in bytes, lists resolved.  Emits nothing when no
   profile is active."
  (let ((profile (active-hardware-profile)))
    (when profile
      (format stream "(:hardware-profile~%  (:name ~s" (string-upcase *requested-hardware-profile*))
      (loop for (k v) on profile by #'cddr
            do (format stream "~%   ~s ~s" k v))
      (format stream "))~%~%"))))
