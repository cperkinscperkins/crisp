;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)
;; EMPTY as of 2026-11-11 -- endeavours 211 / 212's validators (%211-helper-names,
;; validate-ptx-211-shift-rotate, validate-spv-211-helpers-noinline, validate-ptx-212-vote,
;; validate-spv-212-vote) folded into tests/run-specs.lisp.
;; EMPTY as of 2026-11-09 -- endeavour 210's validators (validate-ptx-tma-grid-constant,
;; validate-ptx-transform-scale3, validate-ptx-wgmma-store-pairs-only) folded into tests/run-specs.lisp.
;; EMPTY as of 2026-11-06 -- endeavour 208's tcgen05 validators folded into tests/run-specs.lisp.
;; EMPTY as of 2026-11-04 -- endeavour 207's sync int8 validators folded into tests/run-specs.lisp.
;; EMPTY as of 2026-11-02 -- BUG 135's validators folded into tests/run-specs.lisp.
;; EMPTY as of 2026-10-30 -- endeavours 200 / 201 folded into tests/run-specs.lisp: %200-helper-names,
;; validate-ptx-200-helpers-inline, validate-spv-200-helpers-noinline (before main); %vad-resolve-symbolic-size
;; (:match-global-size) replaced in place.
;; EMPTY as of 2026-10-29 -- endeavours 196-199's validators folded into tests/run-specs.lisp.

;; ---------------------------------------------------------------------------------------------------
;; Address codegen (typed GEP, 2026-11-11): constant byte offsets now fold into the address arithmetic,
;; so an `add.s64 %rd, %rd, 512;` also ends in ", 512;".  The 512-column needle is pinned to the
;; tcgen05.alloc form ("], 512;", as spec 01 pins "], 128;") and the dealloc is required separately.
;; tests/run-specs.lisp
(defun validate-ptx-tcgen05-acc-ring (file ptx-string)
  "Endeavour 208 spec 05: the pipeline over a 2-slot accumulator ring -- all 512 columns allocated and
   freed, the asynchronous commits only, and the direct store of a 128 x 256 accumulator."
  (declare (ignore file))
  (%208-check-counts
   "tcgen05-acc-ring" ptx-string
   (list (list "], 512;" 1 "512 columns: the alloc ([addr], 512)")
         (list "tcgen05.dealloc.cta_group::1.sync.aligned.b32" 1 "freed before ret")
         (list "tcgen05.mma.cta_group::1.kind::f16 [" 4 "four K = 16 MMAs per K-step")
         (list "tcgen05.commit.cta_group::1.mbarrier::arrive::one.shared::cluster.b64" 2 ":on-complete + tcgen05-commit")
         (list "__crisp_tc_mbar_" 0 "nothing synchronous")
         (list "tcgen05.ld.sync.aligned.32x32b.x32.b32" 8 "N = 256: eight 32-column loads"))))
;; tests/run-specs.lisp
(defun validate-ptx-tcgen05-qint-ring (file ptx-string)
  "Endeavour 208 spec 11: the three-role pipeline on def-qint operands, two s32 128 x 256 accumulators
   (512 columns).  Two commits (the :on-complete slot release and acc-full), eight loads per tile,
   the N = 256 int8 descriptor."
  (declare (ignore file))
  (%208-check-counts
   "tcgen05-qint-ring" ptx-string
   (list (list "], 512;" 1 "512 columns allocated: two s32 128 x 256 accumulators")
         (list "tcgen05.dealloc.cta_group::1.sync.aligned.b32" 1 "freed before ret")
         (list "tcgen05.mma.cta_group::1.kind::i8 [" 4 "four K = 32 MMAs per K-step")
         (list "tcgen05.commit.cta_group::1.mbarrier::arrive::one.shared::cluster.b64" 2 "slot release + acc-full")
         (list "tcgen05.ld.sync.aligned.32x32b.x32.b32" 8 "N = 256: eight 32-column loads")
         (list "138413216" :some "the instruction descriptor: S32, INT8 x INT8, N>>3 = 32, M>>4 = 8")
         (list "cvt.rn.f32" 0 "stored as (accum q-a), never through float"))))

;; ===================================================================================================
;; Endeavour 213: tcgen05 :b-major :mn validators (tests/spec/213-tcgen05-transb/).
;; ===================================================================================================

;; tests/run-specs.lisp
(defun validate-ptx-tcgen05-transb (file ptx-string)
  "Endeavour 213 spec 01: one synchronous 128x128x64 f16 tcgen05 accumulate with an MN-major (K N) B.
   Pins the instruction descriptor with the transpose-B bit (f32 D, f16 A/B, A K-major, B MN-major,
   N>>3 = 16, M>>4 = 8 -> 136380432), the MN-major B shared-memory descriptor (LBO 8192, SBO 1024,
   version 1, SWIZZLE_128B -> 4611756662083026944), and three TMA copies (A + B's two 64-wide boxes).
   ptxas cannot check either descriptor: they are runtime operands."
  (declare (ignore file))
  (%208-check-counts
   "tcgen05-transb" ptx-string
   (list (list ".target sm_100a" 1 "tcgen05 is sm_100a-only")
         (list "tcgen05.mma.cta_group::1.kind::f16 [" 4 "K = 64 is four K = 16 MMAs")
         (list "136380432" :some "the instruction descriptor: f16, B MN-major (bit 16), N = 128, M = 128")
         (list "4611756662083026944" :some "the MN-major B descriptor: LBO 8192, SBO 1024, version 1, SWIZZLE_128B")
         (list "4611756662049538048" :some "A keeps the K-major descriptor")
         (list "cp.async.bulk.tensor" 3 "A plus B's two 64-wide boxes"))))

;; tests/run-specs.lisp
(defun validate-ptx-tcgen05-transb-ring (file ptx-string)
  "Endeavour 213 spec 02: the warp-specialized 128 x 256 ring kernel with an MN-major (64 256) B.  The
   loop body is emitted once: four kind::f16 MMAs, the instruction descriptor 138477584 (f16, B MN-major,
   N>>3 = 32, M>>4 = 8), the MN-major B descriptor, and five TMA copies (A + B's four 64-wide boxes)."
  (declare (ignore file))
  (%208-check-counts
   "tcgen05-transb-ring" ptx-string
   (list (list "tcgen05.mma.cta_group::1.kind::f16 [" 4 "four K = 16 MMAs in the loop body")
         (list "138477584" :some "the instruction descriptor: f16, B MN-major (bit 16), N = 256, M = 128")
         (list "4611756662083026944" :some "the MN-major B descriptor: LBO 8192, SBO 1024, version 1, SWIZZLE_128B")
         (list "cp.async.bulk.tensor" 5 "A plus B's four 64-wide boxes"))))
