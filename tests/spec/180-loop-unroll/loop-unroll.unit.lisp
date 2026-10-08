(in-package :cl-user)

(defpackage :crisp.test.loop-unroll
  (:use :cl :parachute))

(in-package :crisp.test.loop-unroll)

;;; ENDEAVOUR 180 -- loop unrolling.
;;;
;;; The specs prove the SHIPPED module (loads per trip in the SPIR-V, .pragma "nounroll" in the PTX)
;;; and the gradients on metal.  This file pins what they cannot see: the declaration parser, the
;;; per-target default policy, the UNOPTIMISED IR's !llvm.loop node for each form on each target, and
;;; the reduce-vec / loop-vector-stride expansions that carry the request to the loop.

(define-test loop-unroll-test
  "Endeavour 180: (declare (unroll ...)), the loop-vector-stride default, reduce-vec :unroll.")

(defun %read-all (string)
  "Every form in STRING, read in :crisp-language as the compiler reads a .crisp file."
  (let ((*package* (find-package :crisp-language)))
    (with-input-from-string (s string)
      (loop for f = (read s nil :eof) until (eq f :eof) collect f))))

(defun %ir (source &key (target :spirv))
  "The UNOPTIMISED LLVM IR of SOURCE compiled in-process for TARGET (:spirv under the bmg profile,
   :ptx under h100) -- before default<O3>, so the !llvm.loop nodes are exactly as emitted."
  (crisp.compiler:initialize-compiler :log-level :error
                                      :hardware-profile (if (eq target :ptx) "h100" "bmg"))
  (let ((module (crisp.llvm-bindings:llvm-module-create "u180"))
        (builder (crisp.llvm-bindings:llvm-create-builder)))
    (unwind-protect
         (let ((crisp.compiler:*target-backend* target))
           (crisp.compiler:compile-module (%read-all source) module builder nil nil nil)
           (let ((p (crisp.llvm-bindings:llvm-print-module-to-string module)))
             (unwind-protect (cffi:foreign-string-to-lisp p)
               (crisp.llvm-bindings:llvm-dispose-message p))))
      (crisp.llvm-bindings:llvm-dispose-builder builder)
      (crisp.llvm-bindings:llvm-dispose-module module))))

(defun %count (needle haystack)
  (loop with start = 0 for pos = (search needle haystack :start2 start)
        while pos count t do (setf start (1+ pos))))

(defparameter *types* "
(def-type f-vec (vector float :address-space :global :align :compact))
(def-type d-vec (vector double :address-space :global :align :compact))
(def-type out-c (cell float :address-space :global))
")

(defun %lvs-kernel (vec-type decl)
  (format nil "~a (def-kernel u_lvs (A &out B) (declare #'(~a &out ~a => nil))
     (loop-vector-stride A (i) ~a (set! (~~ B i) (~~ A i))))" *types* vec-type vec-type decl))

(defun %count-hint (n) (format nil "!\"llvm.loop.unroll.count\", i32 ~d}" n))

;;; --- the declaration parser ------------------------------------------

(defun %split (body-string)
  (crisp.compiler::%split-loop-body-declarations (%read-all body-string) 'dotimes nil))

(define-test (loop-unroll-test parser-reads-each-form)
  "(unroll 4) -> (:count 4), (unroll t) -> (:full), (unroll nil) -> (:disable); the body is the rest."
  (multiple-value-bind (body spec) (%split "(declare (unroll 4)) (foo)")
    (is equal '(:count 4) spec)
    (is = 1 (length body)))
  (is equal '(:full) (nth-value 1 (%split "(declare (unroll t)) (foo)")))
  (is equal '(:disable) (nth-value 1 (%split "(declare (unroll nil)) (foo)"))))

(define-test (loop-unroll-test parser-leaves-an-undeclared-body-alone)
  "No declaration: spec NIL and the very same body list (the analyzer then passes EXPR unchanged)."
  (let ((forms (%read-all "(foo) (bar)")))
    (multiple-value-bind (body spec)
        (crisp.compiler::%split-loop-body-declarations forms 'dotimes nil)
      (false spec)
      (is eq forms body))))

(define-test (loop-unroll-test explicit-request-beats-the-stream-default)
  "loop-vector-stride writes %unroll-default only when there is no unroll; the parser still lets an
   explicit unroll win whichever comes first."
  (is equal '(:count 8)
      (nth-value 1 (%split "(declare (%unroll-default v)) (declare (unroll 8)) (foo)"))))

(define-test (loop-unroll-test parser-refuses-bad-requests)
  "Zero, negative, non-literal, malformed, doubled and foreign declarations are compile errors."
  (dolist (b '("(declare (unroll 0)) (foo)" "(declare (unroll -1)) (foo)" "(declare (unroll n)) (foo)"
               "(declare (unroll 4 8)) (foo)" "(declare (unroll)) (foo)"
               "(declare (unroll 4)) (declare (unroll 2)) (foo)" "(declare (grid-level)) (foo)"))
    (fail (%split b) 'crisp.compiler:crisp-compiler-error b)))

;;; --- the per-target default policy -------------------------------------

(defun %policy (spec target)
  (let ((crisp.compiler:*target-backend* target))
    (multiple-value-list (crisp.compiler::%effective-loop-unroll spec))))

(define-test (loop-unroll-test stream-default-is-16-bytes-in-flight-on-spirv)
  "SPIR-V: 16 bytes / element size, capped at x8; a factor of 1 emits nothing."
  (is equal '(:count 4) (%policy '(:stream 4) :spirv))
  (is equal '(:count 2) (%policy '(:stream 8) :spirv))
  (is equal '(:count 8) (%policy '(:stream 2) :spirv))
  (is equal '(:count 8) (%policy '(:stream 1) :spirv))
  (is equal '(nil) (%policy '(:stream 16) :spirv)))

(define-test (loop-unroll-test no-stream-default-on-ptx)
  "PTX: no default (LLVM's NVPTX unroller and ptxas already unroll the stream) -- but an explicit
   request is honoured on every target."
  (is equal '(nil) (%policy '(:stream 4) :ptx))
  (is equal '(:count 3) (%policy '(:count 3) :ptx))
  (is equal '(:disable) (%policy '(:disable) :ptx)))

;;; --- the unoptimised IR ---------------------------------------------------

(define-test (loop-unroll-test dotimes-latch-carries-each-form)
  "dotimes: the back-edge carries a distinct self-referential loop ID with the request."
  (dolist (case '(("4" "!\"llvm.loop.unroll.count\", i32 4}")
                  ("t" "!\"llvm.loop.unroll.full\"}")
                  ("nil" "!\"llvm.loop.unroll.disable\"}")))
    (let ((ir (%ir (format nil "~a (def-kernel u_dt (A &out out) (declare #'(f-vec &out out-c => nil))
                  (let ((acc 0.0)) (dotimes (k 4) (declare (unroll ~a)) (set! acc (+ acc (~~ A k))))
                    (set! (~~ out) acc)))" *types* (first case)))))
      (is = 1 (%count "br label %dt_check, !llvm.loop !" ir) (first case))
      (true (search "= distinct !{!" ir) (first case))
      (true (search (second case) ir) (first case)))))

(define-test (loop-unroll-test lvs-default-sized-by-element)
  "loop-vector-stride with no declaration, SPIR-V: x4 for float, x2 for double."
  (is = 1 (%count (%count-hint 4) (%ir (%lvs-kernel "f-vec" ""))))
  (is = 1 (%count (%count-hint 2) (%ir (%lvs-kernel "d-vec" "")))))

(define-test (loop-unroll-test lvs-default-absent-on-ptx)
  "loop-vector-stride with no declaration, PTX: no !llvm.loop at all."
  (is = 0 (%count "llvm.loop" (%ir (%lvs-kernel "f-vec" "") :target :ptx))))

(define-test (loop-unroll-test lvs-explicit-replaces-default)
  "An explicit (unroll 8) is the ONLY hint -- the default does not also appear."
  (let ((ir (%ir (%lvs-kernel "f-vec" "(declare (unroll 8))"))))
    (is = 1 (%count (%count-hint 8) ir))
    (is = 0 (%count (%count-hint 4) ir))))

(define-test (loop-unroll-test reduce-vec-unroll-reaches-its-loop)
  "reduce-vec :unroll 2 -> the stream loop carries count 2, not the default 4."
  (let ((ir (%ir (format nil "~a (def-kernel u_rv (A &out out) (declare #'(f-vec &out out-c => nil)
                  (global-size :set-to 128) (local-size :set-to 64))
                  (reduce-vec #'+ A 0.0 out :strategy :atomic :unroll 2))" *types*))))
    (is = 1 (%count (%count-hint 2) ir))
    (is = 0 (%count (%count-hint 4) ir))))

;;; --- the expansions ---------------------------------------------------------

(define-test (loop-unroll-test reduce-vec-moves-unroll-to-the-loop)
  ":unroll leaves grid-reduce!'s keys and heads the loop-vector-stride body as a declaration."
  (let* ((e (let ((*package* (find-package :crisp-language)))
              (crisp.compiler::%reduce-vec-expand
               (read-from-string "(reduce-vec #'+ A 0.0 out :strategy :atomic :unroll 2)"))))
         (lvs (fourth e))
         (gr (fifth e)))
    (is equal '(:strategy :atomic) (nthcdr 5 gr))
    (is string= "DECLARE" (symbol-name (first (fourth lvs))))
    (is string= "UNROLL" (symbol-name (first (second (fourth lvs)))))
    (is = 2 (second (second (fourth lvs))))))

(defun %lvs-dotimes-body (body-string)
  "The body of the dotimes that loop-vector-stride expands to."
  (let* ((e (crisp.compiler::%expand-loop-vector-stride-form
             (first (%read-all (format nil "(loop-vector-stride v (i) ~a)" body-string))) nil))
         (iters-let (fourth e))
         (dt (third iters-let)))
    (cddr dt)))

(define-test (loop-unroll-test lvs-expansion-carries-the-request)
  "No declaration -> (declare (%unroll-default V)); (unroll 8) -> moved to the dotimes as written."
  (let ((b (%lvs-dotimes-body "(foo i)")))
    (is string= "%UNROLL-DEFAULT" (symbol-name (first (second (first b))))))
  (let ((b (%lvs-dotimes-body "(declare (unroll 8)) (foo i)")))
    (is string= "UNROLL" (symbol-name (first (second (first b)))))
    (is = 2 (length b))))

;;; The runner only reports a unit FILE as passing if it loads (its aggregate parachute gate is
;;; effectively empty), so run this suite here and turn a quiet assertion failure into a load error.
;;; Afterwards leave the compiler as the runner expects it: no hardware profile.
(let* ((report (unwind-protect (test 'loop-unroll-test)
                 (crisp.compiler:initialize-compiler :log-level :error)))
       (failures (parachute:tests-with-status :failed report)))
  (when failures
    (error "loop-unroll-test: ~d failed" (length failures))))
