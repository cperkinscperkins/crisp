(in-package :crisp.compiler)

;;; Endeavour 217 rung 01 -- the swizzle RULE, checked as arithmetic (no GPU, no PTX).
;;;
;;; The compiler owns two pure functions (src/mma.lisp when folded):
;;;   (%217-swizzle-shift PITCH-BYTES TILE-BYTES) -> S, or NIL when the tile is not swizzled
;;;   (%217-swizzle-offset OFF S)                 -> OFF xor (((OFF >> S) & 7) << 4)
;;; with S = max(7, log2 PITCH) for a power-of-two PITCH >= 32 whose tile is a whole number of
;;; 2^(S+3)-byte blocks.  These tests are what make "conflict-free" and "same bytes, permuted" claims
;;; rather than hopes:
;;;   - only bits 4-6 move: a 16-byte chunk stays whole (cp.async writes 16 B, an ldmatrix row is 16 B);
;;;   - the map is a bijection of the tile onto itself (nothing written outside it, nothing lost);
;;;   - every ldmatrix phase (8 rows x 16 B at a column that is a multiple of 8 halves, rows starting at a
;;;     multiple of 8) hits 8 distinct 16-byte bank groups -- and, the checker's positive control, the
;;;     UNSWIZZLED layout does not, for pitches >= 64;
;;;   - every 128-byte run of cp.async chunk writes still hits 8 distinct bank groups.
;;;
;;; IN-PACKAGE :crisp.compiler and :parent crisp.tests ON PURPOSE (see 173-shuffles/warp-size.unit.lisp):
;;; run-specs executes exactly one suite, crisp.compiler::crisp.tests; a test without that parent loads,
;;; prints PASS, and never runs.  The functions are looked up at run time so this file loads (and its
;;; tests FAIL) before they exist.
;;;
;;; Checked before the feature: against a reference implementation of the rule all 62434 assertions pass;
;;; with an identity "swizzle" (today's layout) the conflict-freeness tests fail
;;; (put_temp_files_here/217/unit_check.lisp [neg]).

(defun %217-unit-fn (name)
  "The function crisp.compiler::NAME, or NIL while it does not exist."
  (let ((sym (find-symbol name :crisp.compiler)))
    (and sym (fboundp sym) (symbol-function sym))))

(defun %217-unit-shift (pitch bytes) (funcall (%217-unit-fn "%217-SWIZZLE-SHIFT") pitch bytes))
(defun %217-unit-swz (off s) (funcall (%217-unit-fn "%217-SWIZZLE-OFFSET") off s))

(defparameter *217-unit-eligible*
  ;; (rows cols) of 16-bit tiles that must be swizzled, and the S each must get.
  '(((64 16) 7)      ; 32-byte pitch  (216 spec 01's A)
    ((64 32) 7)      ; 64-byte pitch  (217 spec 02's A)
    ((128 32) 7)     ; 64-byte pitch  (the contest ring's A slot)
    ((32 64) 7)      ; 128-byte pitch (217 spec 02's B)
    ((16 64) 7)      ; 128-byte pitch, 2 KB (216 spec 01's B)
    ((32 128) 8)     ; 256-byte pitch (the contest ring's B slot)
    ((64 256) 9)))   ; 512-byte pitch

(defparameter *217-unit-refused*
  ;; (pitch-bytes tile-bytes) that must NOT be swizzled.
  '((16 2048)        ; 16-byte pitch: 8 rows already span 8 bank groups
    (32 1536)        ; 48 x 16 half: not a whole number of 1024-byte blocks (217 spec 05's A)
    (96 1536)        ; 16 x 48 half: pitch not a power of two (217 spec 05's B)
    (48 3072)        ; pitch not a power of two
    (256 1024)))     ; 4 rows of 256 B: less than one 2048-byte block

(defun %217-unit-groups-distinct-p (offsets)
  "T when the byte OFFSETS fall in pairwise different 16-byte bank groups (bits 4-6)."
  (let ((groups (mapcar (lambda (o) (ldb (byte 3 4) o)) offsets)))
    (= (length (remove-duplicates groups)) (length groups))))

(parachute:define-test swizzle-217-tests
  :parent crisp.compiler::crisp.tests)

(parachute:define-test (swizzle-217-tests functions-exist)
  (parachute:true (%217-unit-fn "%217-SWIZZLE-SHIFT") "crisp.compiler::%217-swizzle-shift is defined")
  (parachute:true (%217-unit-fn "%217-SWIZZLE-OFFSET") "crisp.compiler::%217-swizzle-offset is defined"))

(parachute:define-test (swizzle-217-tests shift-table)
  :depends-on (functions-exist)
  (loop for ((rows cols) s) in *217-unit-eligible*
        do (parachute:is = s (%217-unit-shift (* 2 cols) (* 2 rows cols))
                         "~ax~a half tile -> S = ~a" rows cols s))
  (loop for (pitch bytes) in *217-unit-refused*
        do (parachute:false (%217-unit-shift pitch bytes) "pitch ~a, ~a bytes -> not swizzled" pitch bytes)))

(parachute:define-test (swizzle-217-tests chunk-preserving-bijection)
  :depends-on (functions-exist)
  (loop for ((rows cols) s) in *217-unit-eligible*
        for bytes = (* 2 rows cols)
        for image = (make-array bytes :element-type 'bit :initial-element 0)
        do (loop for off from 0 below bytes by 2
                 for new = (%217-unit-swz off s)
                 do (parachute:is = (ldb (byte 4 0) off) (ldb (byte 4 0) new) "byte within the chunk kept (~a)" off)
                    (parachute:true (< -1 new bytes) "~ax~a: offset ~a maps inside the tile" rows cols off)
                    (if (< -1 new bytes) (setf (sbit image new) 1)))
           (parachute:is = (/ bytes 2) (count 1 image) "~ax~a: every element lands on its own slot" rows cols)))

(parachute:define-test (swizzle-217-tests ldmatrix-phases-conflict-free)
  :depends-on (functions-exist)
  (loop for ((rows cols) s) in *217-unit-eligible*
        for pitch = (* 2 cols)
        do (loop for r0 from 0 below rows by 8
                 do (loop for c0 from 0 below cols by 8
                          for plain = (loop for i below 8 collect (+ (* (+ r0 i) pitch) (* 2 c0)))
                          do (parachute:true
                              (%217-unit-groups-distinct-p (mapcar (lambda (o) (%217-unit-swz o s)) plain))
                              "~ax~a: ldmatrix rows ~a-~a at column ~a are conflict-free" rows cols r0 (+ r0 7) c0)))
           ;; positive control: the checker does see today's conflicts
           (if (>= pitch 64)
               (parachute:false (%217-unit-groups-distinct-p (loop for i below 8 collect (* i pitch)))
                                "~ax~a: the UNSWIZZLED layout conflicts (control)" rows cols))))

(parachute:define-test (swizzle-217-tests cp-async-writes-conflict-free)
  :depends-on (functions-exist)
  (loop for ((rows cols) s) in *217-unit-eligible*
        for bytes = (* 2 rows cols)
        do (loop for run from 0 below bytes by 128
                 do (parachute:true
                     (%217-unit-groups-distinct-p (loop for k below 8 collect (%217-unit-swz (+ run (* 16 k)) s)))
                     "~ax~a: the 8 chunks at byte ~a land in 8 bank groups" rows cols run))))
