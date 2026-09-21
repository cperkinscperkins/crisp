;;;; overlays/hoist-cuda/crisp-hoist-cuda-overlay.lisp
;;;;
;;;; Runtime patches for the CUDA hoister.  Applied via late binding -- last definition wins.
;;;;
;;;; NOTE THE SHAPE CONSTRAINT, learned when this file was last emptied (2026-08-26): a
;;;; late-binding wrapper that captures (fdefinition 'f) into a defvar and then redefines f
;;;; CANNOT be pasted into src/ as-is, because there the capture would grab the function being
;;;; replaced and recurse forever.  Folding one back means splitting it into a base plus a
;;;; wrapper that calls the base BY NAME, as emit-launch / %emit-launch-base already are.
;;;; The wrappers below are written knowing that -- see the fold-back note on each.

(in-package :crisp.hoist.cuda)

;;;; ===========================================================================
;;;; Endeavour 175 — resolve SYMBOLIC scratch sizes (CUDA side, option (i)).
;;;; ===========================================================================
;;;; src/hoist-cuda/main.lisp
;;;;
;;;; A scratch tensor may be sized with a KEYWORD rather than an integer --
;;;; (make-scratch-vector float :match-num-warps-per-workgroup).  The compiler passes that
;;;; through into the metacrisp as :size-expr, and %cuda-scratch-dims accepted only an integer
;;;; or a list of integers, so such a kernel died at hoist.  Same bug as the L0 side; see
;;;; overlays/hoist-l0/crisp-hoist-l0-overlay.lisp for the full trace and
;;;; tests/spec/175-reductions/02 for the spec that keeps it fixed.
;;;;
;;;; WHY CUDA RESOLVES TO AN INTEGER WHILE L0 EMITS A C++ EXPRESSION.
;;;;
;;;; This asymmetry is deliberate and was chosen with eyes open, not overlooked.
;;;;
;;;; On L0 each workgroup-local tensor gets its OWN allocation --
;;;; zeKernelSetArgumentValue(kernel, i, bytes, nullptr) -- so one buffer's size is
;;;; independent of every other, and making it a C++ expression over named geometry constants
;;;; costs nothing and lets the launcher re-size itself when retuned.
;;;;
;;;; CUDA carves ALL local scratch out of ONE dynamic-shared blob: compute-total-shared-bytes
;;;; sums every local param into a single number, that number becomes the sharedMemBytes launch
;;;; argument, and each param is handed a running byte OFFSET into the blob (the BUG 046 fix).
;;;; Making one size an expression makes the blob total an expression, and then this decision
;;;; in %emit-launch-base can no longer be made:
;;;;
;;;;     (when (and shared-bytes (> shared-bytes 32768))
;;;;       ... cuFuncSetAttribute(..., CU_FUNC_ATTRIBUTE_MAX_DYNAMIC_SHARED_SIZE_BYTES, N))
;;;;
;;;; Whether to request the >48KB opt-in is a HOIST-TIME choice about a value that would only
;;;; exist at launch.  Plumbing that properly means expression-valued offsets, an
;;;; expression-valued blob total, and a runtime-conditional attribute call -- reworking the
;;;; shared-memory path that BUG 046 only just stabilised.
;;;;
;;;; So CUDA folds the symbolic size to an integer using the DECLARED geometry.  The practical
;;;; limitation, stated plainly: retuning a CUDA launcher's block size means regenerating it,
;;;; because its scratch sizes were fixed when it was generated.  The L0 launcher re-sizes
;;;; itself.  Worth an entry in plan/bugs.md rather than leaving the difference implicit.

(defvar *cuda-wg-size* nil
  "Endeavour 175: the DECLARED workgroup size (total threads) for the kernel currently being
   emitted, or NIL when no (local-size :set-to ...) was declared.  Bound per kernel by the
   emit-main wrapper below.")

(defun %cuda-scratch-warp-size ()
  "Lanes per warp for scratch sizing on NVIDIA: always 32.

   DELIBERATELY NOT the active profile's :simd-width, and this is a correctness point rather
   than a simplification.  The compiler's %173-warp-size -- the value the KERNEL computes its
   warp count from -- short-circuits to 32 whenever the target is :ptx, on the grounds that
   NVIDIA's warp has been 32 lanes on every part ever shipped; :simd-width describes the
   SPIR-V subgroup width a driver would otherwise choose.

   So reading :simd-width here would desync the host from the kernel in exactly the case 173
   calls out: --hardware-profile=bmg with --ir-target=ptx, which a dual-backend spec produces.
   The kernel would compute ceil(wg/32) warps while the host sized the buffer for ceil(wg/16) --
   twice as many slots, and a reduction reading the tail would find garbage.  Mirroring the
   PTX branch keeps the two in step by construction.

   If a future NVIDIA part ever ships a warp that is not 32, this and %173-warp-size's PTX
   branch must change TOGETHER."
  32)

(defun %cuda-scratch-symbolic-size-p (size-expr)
  "T when SIZE-EXPR is a symbolic (keyword) scratch size rather than a concrete extent."
  (keywordp size-expr))

(defun %cuda-resolve-symbolic-size (size-expr param-name)
  "The integer element count for a symbolic rank-1 scratch size, from the DECLARED geometry.
   Errors with an explanation rather than guessing when the geometry is not declared."
  (let ((name (symbol-name size-expr))
        (wg   *cuda-wg-size*)
        (warp (%cuda-scratch-warp-size)))
    (flet ((need-wg ()
             (or wg
                 (error "Scratch tensor ~a: :size-expr ~a needs the workgroup size, but this~%~
                         kernel declares no compile-time (local-size :set-to N).~%~
                         The CUDA hoister resolves a symbolic scratch size to a NUMBER at~%~
                         generation time, because all workgroup-local scratch shares one~%~
                         dynamic-shared blob whose total must be known to size the launch.~%~
                         Either declare a local-size, or give this buffer an explicit integer extent."
                        param-name size-expr))))
      (cond
        ((string-equal name "MATCH-WORKGROUP-SIZE")
         (need-wg))
        ((string-equal name "MATCH-NUM-WARPS-PER-WORKGROUP")
         ;; CEILING, matching the design doc's (ceil (get-local-work-size) (get-warp-size)) and
         ;; the L0 resolver.  A workgroup that is not a whole multiple of the warp still has a
         ;; final PARTIAL warp whose leader writes a slot; floor would size the buffer one
         ;; element short and that write would land past the end.
         (ceiling (need-wg) warp))
        ((string-equal name "MATCH-NUM-WORKGROUPS")
         (error "Scratch tensor ~a: :size-expr :match-num-workgroups is not implemented yet.~%~
                 Its value is the grid's group count, which the generated launcher may compute at~%~
                 RUNTIME from the device's SM count -- so it is not available here.~%~
                 That arrives with grid-reduce-last-man!, the first construct to need it.~%~
                 For now, size this buffer with an explicit integer."
                param-name))
        (t
         (error "Scratch tensor ~a: unknown symbolic :size-expr ~a.~%~
                 The sizes this hoister can resolve are :match-workgroup-size and~%~
                 :match-num-warps-per-workgroup.  (:match-warp-tile is recorded in the metacrisp~%~
                 for tooling but has no host-side meaning, so it cannot size a buffer here.)"
                param-name size-expr))))))

;;; --- the two resolution points ----------------------------------------------
;;;
;;; %cuda-scratch-dims feeds the EMITTERS (extents / strides / length) and %cuda-local-param-bytes
;;; feeds the SIZER (the blob total and the per-param offsets).  Both must agree, which is the
;;; whole reason %cuda-local-param-bytes exists -- its own docstring says so.  They are patched
;;; together here for exactly that reason: teaching one and not the other would give a kernel
;;; correct extents inside a blob too small to hold them.

(defvar *orig-cuda-scratch-dims* (fdefinition '%cuda-scratch-dims)
  "Captured once at overlay load.  FOLD-BACK: becomes %cuda-scratch-dims-base, called by name.")

(defun %cuda-scratch-dims (size-expr rank param-name)
  "Overlay wrapper: a SYMBOLIC (keyword) size resolves to an integer extent at rank 1;
   everything else defers to the original integer/list rule.

   Rank > 1 is refused.  A symbolic size names ONE length, and the original's scalar rule makes
   a SQUARE tensor of that size in every dimension -- for a workgroup-derived size that would be
   wg^rank elements of shared memory (64^3 = 262144 for a 64-thread group), which is never what
   anyone meant.  The existing rank-3 uses in 074/01 and 074/03 never reached a hoist run to
   find this out."
  (if (%cuda-scratch-symbolic-size-p size-expr)
      (if (= rank 1)
          (list (%cuda-resolve-symbolic-size size-expr param-name))
          (error "Scratch tensor ~a: a symbolic :size-expr (~a) names ONE length, so it is only~%~
                  meaningful for a rank-1 scratch vector; this tensor has rank ~d.~%~
                  Give explicit per-dimension extents instead, e.g. (make-scratch-matrix float (8 16))."
                 param-name size-expr rank))
      (funcall *orig-cuda-scratch-dims* size-expr rank param-name)))

(defvar *orig-cuda-local-param-bytes* (fdefinition '%cuda-local-param-bytes)
  "Captured once at overlay load.  FOLD-BACK: becomes %cuda-local-param-bytes-base.")

(defun %cuda-local-param-bytes (param param-type)
  "Overlay wrapper: a rank-1 symbolic scratch size now contributes its resolved byte count to
   the dynamic-shared blob instead of NIL.

   The original returned NIL for a non-integer :size-expr, on the stated grounds that
   %cuda-scratch-dims hard-errors on such a tensor so it never reaches an emitter.  That
   reasoning was sound and is now FALSE -- the wrapper above makes rank-1 symbolic sizes legal,
   so this had to be taught too or the blob would be sized as though the buffer were absent
   while the emitters happily handed the kernel offsets into it."
  (let ((size-expr (and (tensor-type-p param-type) (getf param :size-expr))))
    (if (and size-expr
             (%cuda-scratch-symbolic-size-p size-expr)
             (= (let ((n3 (third param-type))) (if (integerp n3) n3 1)) 1))
        (let* ((param-name (getf param :name))
               (elem-str   (crisp-type-to-cpp-type (second param-type)))
               (elem-bytes (%hoist-elem-type-bytes elem-str))
               (count      (%cuda-resolve-symbolic-size size-expr param-name)))
          (values (* count elem-bytes) :tensor))
        (funcall *orig-cuda-local-param-bytes* param param-type))))

;;; --- latching the geometry the two resolvers read ---------------------------

(defun %cuda-declared-wg-size (dispatch-info)
  "Total declared threads per workgroup from DISPATCH-INFO, or NIL when no compile-time
   local-size was declared.  Reads (local-size :set-to ...) exactly as %emit-launch-base does,
   so the scratch size and the block size cannot disagree about what the workgroup is."
  (let* ((local-decl (and dispatch-info (getf dispatch-info :local-size)))
         (ls-rest    (when local-decl (cdr local-decl)))
         (ls-set-to  (when ls-rest (getf ls-rest :set-to))))
    (cond
      ((integerp ls-set-to) ls-set-to)
      ((consp ls-set-to)
       ;; Product of the declared dims, defaulting each missing one to 1.
       (let ((x (or (first ls-set-to) 1))
             (y (or (second ls-set-to) 1))
             (z (or (third ls-set-to) 1)))
         (and (integerp x) (integerp y) (integerp z) (* x y z))))
      (t nil))))

(defvar *orig-cuda-emit-main* (fdefinition 'emit-main)
  "Captured once at overlay load.  FOLD-BACK: becomes %emit-main-base, called by name.")

(defun emit-main (stream kernel-name ptx-path declared-sig aliases records
                  &optional dispatch-info compute-units)
  "Overlay wrapper: bind the declared workgroup size for the symbolic scratch resolvers, then
   emit exactly as before.  Bound HERE because both resolution points run inside this call --
   emit-kernel-args for the emitters, compute-total-shared-bytes for the blob total."
  (let ((*cuda-wg-size* (%cuda-declared-wg-size dispatch-info)))
    (funcall *orig-cuda-emit-main*
             stream kernel-name ptx-path declared-sig aliases records
             dispatch-info compute-units)))

;;; NO generate-cuda-launcher WRAPPER IS NEEDED.  An earlier draft wrapped it to latch the
;;; profile's :simd-width into a special -- which meant re-parsing the metacrisp a second time
;;; just to reach the plist, since emit-main receives only :compute-units.  Pinning the warp at
;;; 32 (see %cuda-scratch-warp-size) makes the profile irrelevant here, so the extra parse and
;;; the extra wrapper both went away.  The workgroup size is the only geometry this needs, and
;;; emit-main already has it.
