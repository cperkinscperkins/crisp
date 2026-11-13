;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)
;; EMPTY as of 2026-11-11 -- validate-ptx-tcgen05-acc-ring / -qint-ring (the "], 512;" needle),
;; endeavour 213's validate-ptx-tcgen05-transb(-ring) and endeavour 215's
;; validate-ptx-tcgen05-vector-stores-f32 / -f16 folded into tests/run-specs.lisp.
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

;; tests/run-specs.lisp  (endeavour 216, before validate-spv-200-helpers-noinline)
;;;; Endeavour 216 -- ldmatrix for 16-bit mma.sync fragments.  See tests/spec/216-ldmatrix/.
;;;; Needles are whole instruction spellings: the word "ldmatrix" alone would also match a kernel name.

(defun %216-check-one-warp (label ptx-string mma-needle)
  "Endeavour 216 specs 01 / 02: one warp, a 64x64 register tile, K = 16 per stage -- 4 A fragments (one
   ldmatrix.x4 each) and 8 B fragments (one ldmatrix.x2.trans each) feed 32 m16n8k16 MMAs (MMA-NEEDLE), and
   no fragment element is read with a scalar ld.shared.b16 any more."
  (%208-check-counts
   label ptx-string
   (list (list mma-needle 32 "4 x 8 fragments of a 64x64 tile, one K = 16 step")
         (list "ldmatrix.sync.aligned.m8n8.x4.shared.b16" 4 "one per A fragment (16x16): 64 rows / 16")
         (list "ldmatrix.sync.aligned.m8n8.x2.trans.shared.b16" 8 "one per B fragment (16x8): 64 columns / 8")
         (list "ld.shared.b16" 0 "the per-element fragment reads are gone"))))

(defun validate-ptx-216-ldmatrix-fp16 (file ptx-string)
  "Endeavour 216 spec 01: fp16 fragments from shared memory by ldmatrix (see %216-check-one-warp)."
  (declare (ignore file))
  (%216-check-one-warp "216-ldmatrix-fp16" ptx-string "mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32"))

(defun validate-ptx-216-ldmatrix-bf16 (file ptx-string)
  "Endeavour 216 spec 02: bf16 fragments from shared memory by ldmatrix (see %216-check-one-warp)."
  (declare (ignore file))
  (%216-check-one-warp "216-ldmatrix-bf16" ptx-string "mma.sync.aligned.m16n8k16.row.col.f32.bf16.bf16.f32"))

(defun validate-ptx-216-ldmatrix-ring (file ptx-string)
  "Endeavour 216 spec 03: the 4-warp contest kernel with a 3-slot cp.async ring -- fragments come from
   (ring-get A-RING slot) by ldmatrix, and the ring keeps (3-1) x 2 cp.async groups in flight.  The
   ldmatrix COUNTS are not pinned: LLVM merges some of the four warps' unrolled branches (which differ only
   in address constants), so how many copies survive is LLVM's choice, not the compiler's."
  (declare (ignore file))
  (%208-check-counts
   "216-ldmatrix-ring" ptx-string
   (list (list "mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32" :some "the fp16 MMAs")
         (list "ldmatrix.sync.aligned.m8n8.x4.shared.b16" :some "A fragments from a ring slot")
         (list "ldmatrix.sync.aligned.m8n8.x2.trans.shared.b16" :some "B fragments from a ring slot")
         (list "ld.shared.b16" 0 "no per-element fragment reads")
         ;; LLVM prints the operand after a space AND a tab.
         (list (format nil "cp.async.wait_group ~c4" #\Tab) 1 "a 3-slot ring with 2 arrivals keeps 4 groups in flight"))))

(defun validate-ptx-216-global-fragment (file ptx-string)
  "Endeavour 216 spec 04: fragments read from GLOBAL memory are not ldmatrix (it reads only .shared): one
   fp16 MMA, 8 + 4 per-element 16-bit global loads, no ldmatrix."
  (declare (ignore file))
  (%208-check-counts
   "216-global-fragment" ptx-string
   (list (list "mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32" 1 "one fragment MMA")
         (list "ldmatrix.sync" 0 "a global source keeps the per-element reads")
         (list "ld.global.nc.b16" 12 "8 A elements + 4 B elements"))))


;; tests/run-specs.lisp  (endeavour 216: replaces the two definitions of the same name above)
(defun %216-check-one-warp (label ptx-string mma-needle)
  "Endeavour 216 specs 01 / 02: one warp, a 64x64 register tile, K = 16 per stage.  Forward: 4 A fragments
   (one ldmatrix.x4 each) and 8 B fragments (one ldmatrix.x2.trans each) feed 32 m16n8k16 MMAs.
   Under --differentiate the PTX holds the forward kernel AND the _grad kernel's two backward GEMMs, whose
   operands are materialized transposes and a staged dC -- shared tiles, so ldmatrix too:
     dA = dC (64x64) . B^T (64x16): A = dC, 4 row frags x 4 K steps = 16 x4; B = B^T, 2 col frags x 4 = 8 x2.trans; 32 MMAs
     dB = A^T (16x64) . dC (64x64): A = A^T, 1 x 4 = 4 x4;  B = dC, 8 x 4 = 32 x2.trans;                     32 MMAs
   so 96 MMAs, 24 x4, 48 x2.trans.  Either way no fragment element is read with a scalar ld.shared.b16."
  (let ((d (and (boundp '*compile-differentiate*) *compile-differentiate*)))
    (%208-check-counts
     label ptx-string
     (list (list mma-needle (if d 96 32) "forward 4 x 8 fragments x 1 K step (+ dA and dB, 32 each, under --differentiate)")
           (list "ldmatrix.sync.aligned.m8n8.x4.shared.b16" (if d 24 4) "one per A fragment: forward 4 (+ dA 16 + dB 4)")
           (list "ldmatrix.sync.aligned.m8n8.x2.trans.shared.b16" (if d 48 8) "one per B fragment: forward 8 (+ dA 8 + dB 32)")
           (list "ld.shared.b16" 0 "the per-element fragment reads are gone")))))

(defun validate-ptx-216-global-fragment (file ptx-string)
  "Endeavour 216 spec 04: fragments read from GLOBAL memory are not ldmatrix (it reads only .shared): one
   fp16 MMA, 8 + 4 per-element 16-bit global loads, no ldmatrix.  Under --differentiate the _grad kernel
   adds its own global reads (36 in all), so only the absence of ldmatrix and the presence of the 16-bit
   global loads are pinned there."
  (declare (ignore file))
  (let ((d (and (boundp '*compile-differentiate*) *compile-differentiate*)))
    (%208-check-counts
     "216-global-fragment" ptx-string
     (append
      (list (list "ldmatrix.sync" 0 "a global source keeps the per-element reads")
            (list "ld.global.nc.b16" (if d :some 12) "8 A elements + 4 B elements"))
      (unless d
        (list (list "mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32" 1 "one fragment MMA")))))))


;;; ---------------------------------------------------------------------------------------------------
;;; Endeavour 217 -- XOR-swizzled ldmatrix scratch tiles (TDD validators, written before the feature).
;;; The swizzle's footprint in PTX is xor.b64 in the shared-memory address arithmetic; 216's kernels
;;; have none (checked: 216 spec 01 shape, the contest ring kernel, 217 specs 02-05 on today's compiler).
;;; ---------------------------------------------------------------------------------------------------

;; tests/run-specs.lisp
(defun validate-ptx-217-swizzle-k32 (file ptx-string)
  "Endeavour 217 spec 02: one warp, 64x64 register tile, K = 32 per stage, tiles A 64x32 (64-byte pitch)
   and B 32x64 (128-byte pitch) -- both swizzle-eligible.  Forward: 8 ldmatrix.x4 + 16 ldmatrix.x2.trans
   feed 64 MMAs; no per-element ld.shared.b16; the swizzle's xor.b64 present.  Under --differentiate the
   _grad kernel's backward GEMMs add their own (192 MMAs, 32 x4, 64 x2.trans on today's compiler), so only
   presence, the absence of scalar reads and the xor are pinned there."
  (declare (ignore file))
  (let ((d (and (boundp '*compile-differentiate*) *compile-differentiate*)))
    (%208-check-counts
     "217-swizzle-k32" ptx-string
     (list (list "mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32" (if d :some 64) "4 x 8 fragments x 2 K steps")
           (list "ldmatrix.sync.aligned.m8n8.x4.shared.b16" (if d :some 8) "4 A row fragments x 2 K steps")
           (list "ldmatrix.sync.aligned.m8n8.x2.trans.shared.b16" (if d :some 16) "8 B column fragments x 2 K steps")
           (list "ld.shared.b16" 0 "no per-element fragment reads")
           (list "xor.b" :some "the swizzle in the tile addressing")))))

;; tests/run-specs.lisp
(defun validate-ptx-217-swizzle-ring (file ptx-string)
  "Endeavour 217 spec 03: the contest ring kernel with swizzled ring slots.  Presence only (LLVM merges the
   four warps' branches -- see validate-ptx-216-ldmatrix-ring), plus the swizzle's xor.b64."
  (declare (ignore file))
  (%208-check-counts
   "217-swizzle-ring" ptx-string
   (list (list "mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32" :some "the fp16 MMAs")
         (list "ldmatrix.sync.aligned.m8n8.x4.shared.b16" :some "A fragments from a ring slot")
         (list "ldmatrix.sync.aligned.m8n8.x2.trans.shared.b16" :some "B fragments from a ring slot")
         (list "ld.shared.b16" 0 "no per-element fragment reads")
         (list (format nil "cp.async.wait_group ~c4" #\Tab) 1 "a 3-slot ring with 2 arrivals keeps 4 groups in flight")
         (list "xor.b" :some "the swizzle in the slot addressing"))))

;; tests/run-specs.lisp
(defun validate-ptx-217-second-reader (file ptx-string)
  "Endeavour 217 spec 04 (D-217-2): A-TILE is read by ldmatrix AND copied out by store-tile (per-element
   ld.shared.b16 through the aref path).  The tile stays swizzled -- xor.b64 present -- and the echo's
   scalar shared reads are still there.  Whether the echo reads the RIGHT elements is a metal claim."
  (declare (ignore file))
  (let ((d (and (boundp '*compile-differentiate*) *compile-differentiate*)))
    (%208-check-counts
     "217-second-reader" ptx-string
     (list (list "mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32" (if d :some 64) "4 x 8 fragments x 2 K steps")
           (list "ldmatrix.sync.aligned.m8n8.x4.shared.b16" (if d :some 8) "A fragments")
           (list "ldmatrix.sync.aligned.m8n8.x2.trans.shared.b16" (if d :some 16) "B fragments")
           (list "ld.shared.b16" :some "the store-tile echo of A-TILE reads it element by element")
           (list "xor.b" :some "A-TILE (and B-TILE) swizzled despite the second reader")))))

;; tests/run-specs.lisp
(defun validate-ptx-217-no-swizzle (file ptx-string)
  "Endeavour 217 spec 05: neither tile is swizzle-eligible (A 48x16: 1536 bytes is not a whole number of
   1024-byte blocks; B 16x48: 96-byte pitch is not a power of two), so no xor.b64 -- in the forward or, under
   --differentiate, the backward (its transposes and staged dC have the same odd shapes).  Both stay
   ldmatrix sources."
  (declare (ignore file))
  (let ((d (and (boundp '*compile-differentiate*) *compile-differentiate*)))
    (%208-check-counts
     "217-no-swizzle" ptx-string
     (list (list "mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32" (if d :some 18) "3 x 6 fragments x 1 K step")
           (list "ldmatrix.sync.aligned.m8n8.x4.shared.b16" (if d :some 3) "A fragments")
           (list "ldmatrix.sync.aligned.m8n8.x2.trans.shared.b16" (if d :some 6) "B fragments")
           (list "ld.shared.b16" 0 "no per-element fragment reads")
           (list "xor.b" 0 "nothing swizzled")))))
