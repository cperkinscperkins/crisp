;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)
;; EMPTY as of 2026-11-04 -- endeavour 207's sync int8 validators folded into tests/run-specs.lisp.
;; EMPTY as of 2026-11-02 -- BUG 135's validators folded into tests/run-specs.lisp.
;; EMPTY as of 2026-10-30 -- endeavours 200 / 201 folded into tests/run-specs.lisp: %200-helper-names,
;; validate-ptx-200-helpers-inline, validate-spv-200-helpers-noinline (before main); %vad-resolve-symbolic-size
;; (:match-global-size) replaced in place.
;; EMPTY as of 2026-10-29 -- endeavours 196-199's validators folded into tests/run-specs.lisp.

;;;; ======================================================================
;;;; Endeavour 208 -- tcgen05 validators.  See tests/spec/208-tcgen05/tcgen05.md.
;;;; ======================================================================

;; tests/run-specs.lisp
(defun %208-count (needle haystack)
  "Endeavour 208.  Non-overlapping occurrences of NEEDLE in HAYSTACK."
  (loop with start = 0
        for p = (search needle haystack :start2 start)
        while p
        count t
        do (setf start (+ p (length needle)))))

;; tests/run-specs.lisp
(defun %208-check-counts (label ptx-string expectations)
  "Endeavour 208.  EXPECTATIONS is a list of (NEEDLE COUNT WHY); COUNT :some means at least one.
   Every mismatch is reported, not just the first; T when all hold."
  (let ((ok t))
    (dolist (e expectations ok)
      (destructuring-bind (needle want why) e
        (let ((got (%208-count needle ptx-string)))
          (unless (if (eq want :some) (plusp got) (= got want))
            (setf ok nil)
            (format *error-output* "FAIL (~a): ~s occurs ~a time~:p, expected ~a -- ~a~%"
                    label needle got want why)))))))

;; tests/run-specs.lisp
(defun validate-ptx-tcgen05-sync (file ptx-string)
  "Endeavour 208 spec 01: one synchronous 128x128x64 bf16 tcgen05 accumulate, stored with tcgen05.ld.
   Counts every piece of the lowering, and pins the two descriptor constants (the instruction
   descriptor for bf16 x bf16 -> f32, M = N = 128, and the 128-byte-swizzle shared-memory
   descriptor's fixed bits) -- ptxas cannot check either, they are runtime operands."
  (declare (ignore file))
  (%208-check-counts
   "tcgen05-sync" ptx-string
   (list (list ".target sm_100a" 1 "tcgen05 is sm_100a-only")
         (list "tcgen05.alloc.cta_group::1.sync.aligned.shared::cta.b32 [" 1 "one allocation at entry")
         (list "], 128;" 1 "128 columns: one f32 128x128 accumulator")
         (list "tcgen05.relinquish_alloc_permit.cta_group::1.sync.aligned;" 1 "relinquished right after allocating")
         (list "tcgen05.mma.cta_group::1.kind::f16 [" 4 "K = 64 is four K = 16 MMAs")
         (list "tcgen05.commit.cta_group::1.mbarrier::arrive::one.shared::cluster.b64" 1 "one commit for the synchronous site")
         (list "tcgen05.ld.sync.aligned.32x32b.x32.b32" 4 "N = 128 is four 32-column loads")
         (list "tcgen05.wait::ld.sync.aligned;" 4 "each load waited")
         (list "tcgen05.dealloc.cta_group::1.sync.aligned.b32" 1 "freed before ret")
         (list "136316048" :some "the instruction descriptor: f32 D, bf16 A/B, K-major, N>>3 = 16, M>>4 = 8")
         (list "4611756662049538048" :some "the smem descriptor: LBO 16, SBO 1024, version 1, SWIZZLE_128B"))))

;; tests/run-specs.lisp
(defun validate-ptx-tcgen05-loop (file ptx-string)
  "Endeavour 208 spec 02: the synchronous accumulate inside a K loop inside tile-stride.  The loop body
   is emitted once, so the counts match spec 01; the descriptor pins bf16, M = N = 128."
  (declare (ignore file))
  (%208-check-counts
   "tcgen05-loop" ptx-string
   (list (list "tcgen05.alloc.cta_group::1.sync.aligned.shared::cta.b32 [" 1 "one allocation at entry")
         (list "], 128;" 1 "128 columns")
         (list "tcgen05.mma.cta_group::1.kind::f16 [" 4 "four K = 16 MMAs in the loop body")
         (list "tcgen05.commit.cta_group::1.mbarrier::arrive::one.shared::cluster.b64" 1 "one synchronous site")
         (list "tcgen05.ld.sync.aligned.32x32b.x32.b32" 4 "N = 128: four 32-column loads")
         (list "tcgen05.dealloc.cta_group::1.sync.aligned.b32" 1 "freed before ret")
         (list "136316048" :some "the instruction descriptor: bf16, M = N = 128"))))

;; tests/run-specs.lisp
(defun validate-ptx-tcgen05-warpspec (file ptx-string)
  "Endeavour 208 spec 03: the synchronous accumulate in a 4-warp consumer role that is NOT at warp 0.
   256 columns (one 128 x 256 accumulator), eight 32-column loads, the N = 256 descriptor."
  (declare (ignore file))
  (%208-check-counts
   "tcgen05-warpspec" ptx-string
   (list (list "tcgen05.alloc.cta_group::1.sync.aligned.shared::cta.b32 [" 1 "one allocation at entry")
         (list "], 256;" 1 "256 columns")
         (list "tcgen05.mma.cta_group::1.kind::f16 [" 4 "four K = 16 MMAs")
         (list "tcgen05.commit.cta_group::1.mbarrier::arrive::one.shared::cluster.b64" 1 "one synchronous site")
         (list "tcgen05.ld.sync.aligned.32x32b.x32.b32" 8 "N = 256: eight 32-column loads")
         (list "tcgen05.dealloc.cta_group::1.sync.aligned.b32" 1 "freed before ret")
         (list "138413200" :some "the instruction descriptor: bf16, M = 128, N = 256"))))

;; tests/run-specs.lisp
(defun validate-ptx-tcgen05-pipeline (file ptx-string)
  "Endeavour 208 spec 04: the asynchronous three-role pipeline.  Exactly TWO commits -- the
   :on-complete slot release after each K-step's MMAs and the (tcgen05-commit acc-full) after the K
   loop -- and NO compiler-owned mbarrier: nothing in the kernel is synchronous."
  (declare (ignore file))
  (%208-check-counts
   "tcgen05-pipeline" ptx-string
   (list (list "tcgen05.alloc.cta_group::1.sync.aligned.shared::cta.b32 [" 1 "one allocation at entry")
         (list "], 256;" 1 "256 columns")
         (list "tcgen05.mma.cta_group::1.kind::f16 [" 4 "four K = 16 MMAs per K-step")
         (list "tcgen05.commit.cta_group::1.mbarrier::arrive::one.shared::cluster.b64" 2 ":on-complete + tcgen05-commit")
         (list "__crisp_tc_mbar_" 0 "no synchronous site, so no compiler-owned mbarrier")
         (list "tcgen05.ld.sync.aligned.32x32b.x32.b32" 8 "N = 256: eight 32-column loads")
         (list "tcgen05.dealloc.cta_group::1.sync.aligned.b32" 1 "freed before ret"))))

;; tests/run-specs.lisp
(defun validate-ptx-tcgen05-acc-ring (file ptx-string)
  "Endeavour 208 spec 05: the pipeline over a 2-slot accumulator ring -- all 512 columns allocated, the
   asynchronous commits only, and the direct store of a 128 x 256 accumulator."
  (declare (ignore file))
  (%208-check-counts
   "tcgen05-acc-ring" ptx-string
   (list (list "], 512;" 2 "512 columns allocated and freed: two 128 x 256 accumulators")
         (list "tcgen05.mma.cta_group::1.kind::f16 [" 4 "four K = 16 MMAs per K-step")
         (list "tcgen05.commit.cta_group::1.mbarrier::arrive::one.shared::cluster.b64" 2 ":on-complete + tcgen05-commit")
         (list "__crisp_tc_mbar_" 0 "nothing synchronous")
         (list "tcgen05.ld.sync.aligned.32x32b.x32.b32" 8 "N = 256: eight 32-column loads"))))

;; tests/run-specs.lisp
(defun validate-ptx-tcgen05-tma-store (file ptx-string)
  "Endeavour 208 spec 06: the bf16 epilogue through the TMA.  N = 256 is four 64-column chunks; per chunk
   two tcgen05.ld (64 f32), 32 bf16x2 conversions, 8 swizzled 16-byte row writes, two box stores and a
   commit.  No st.global: every element leaves through the TMA."
  (declare (ignore file))
  (%208-check-counts
   "tcgen05-tma-store" ptx-string
   (list (list "tcgen05.ld.sync.aligned.32x32b.x32.b32" 8 "4 chunks x 2 loads")
         (list "cvt.rn.bf16x2.f32" 128 "4 chunks x 32 packed pairs, round to nearest even")
         (list "st.shared.v4.b32" 32 "4 chunks x 8 row writes")
         (list "cp.async.bulk.tensor.2d.global.shared::cta.bulk_group" 8 "4 chunks x 2 boxes")
         (list "cp.async.bulk.commit_group" 4 "one per chunk")
         (list "st.global" 0 "the TMA writes C"))))

;; tests/run-specs.lisp
(defun validate-ptx-tcgen05-tf32 (file ptx-string)
  "Endeavour 208 spec 07: kind::tf32 -- four K = 8 MMAs, and the descriptor with a/b_format TF32 = 2."
  (declare (ignore file))
  (%208-check-counts
   "tcgen05-tf32" ptx-string
   (list (list "tcgen05.mma.cta_group::1.kind::tf32 [" 4 "K = 32 is four K = 8 MMAs")
         (list "kind::f16" 0 "no 16-bit kind")
         (list "136317200" :some "the descriptor: f32 D, tf32 A/B, N>>3 = 16, M>>4 = 8"))))

;; tests/run-specs.lisp
(defun validate-ptx-tcgen05-acc-ring (file ptx-string)
  "Endeavour 208 spec 05: the pipeline over a 2-slot accumulator ring -- all 512 columns allocated and
   freed, the asynchronous commits only, and the direct store of a 128 x 256 accumulator."
  (declare (ignore file))
  (%208-check-counts
   "tcgen05-acc-ring" ptx-string
   (list (list ", 512;" 2 "512 columns: the alloc ([addr], 512) and the dealloc (taddr, 512)")
         (list "tcgen05.mma.cta_group::1.kind::f16 [" 4 "four K = 16 MMAs per K-step")
         (list "tcgen05.commit.cta_group::1.mbarrier::arrive::one.shared::cluster.b64" 2 ":on-complete + tcgen05-commit")
         (list "__crisp_tc_mbar_" 0 "nothing synchronous")
         (list "tcgen05.ld.sync.aligned.32x32b.x32.b32" 8 "N = 256: eight 32-column loads"))))
