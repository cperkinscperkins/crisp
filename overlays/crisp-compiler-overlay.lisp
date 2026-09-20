;;;; crisp-compiler-overlay.lisp — late-bound fixes for the CRISP.COMPILER package.
;;;;
;;;; APPEND full replacement definitions here while developing; they are loaded after src/ and
;;;; win by late binding.  Do NOT patch in place -- append, and note above each one which src
;;;; file it belongs to, so it can be folded back later.
;;;;
;;;; TWO THINGS THAT BITE (both learned the hard way, endeavour 165):
;;;;
;;;;   * A HANDLER REGISTERED BY OBJECT IS NOT LATE-BOUND.  src/autodiff.lisp does
;;;;     (register-vjp "MMA-ACCUMULATE-VIA-TILE" #'%vjp-mma-accumulate-via-tile), which captures
;;;;     the function OBJECT at load time.  Redefining that defun here is DEAD CODE until you
;;;;     also re-register.  The failure is partial and therefore nasty: a callee overridden by
;;;;     name goes live while its caller stays stale.
;;;;
;;;;   * NEVER PUT A DOUBLE QUOTE INSIDE A DOCSTRING.  It closes the string early and the rest of
;;;;     the prose becomes BODY FORMS -- the first bare word is then an unbound variable, and the
;;;;     build emits no warning.  It fails only when the function is CALLED.  Cost: a red CI.
;;;;
;;;; Emptied 2026-09-19: everything folded into src/ (endeavour 172 -- the dotimes family,
;;;; semantic-loop-variant + BUG 065's dotimes stride gate -- into src/semantic.lisp,
;;;; src/anf-transform.lisp, src/analysis/control.lisp, src/autodiff.lisp and
;;;; src/codegen.lisp).  Previously emptied 2026-09-18 (endeavour 167).

(in-package :crisp.compiler)


;;; ---------------------------------------------------------------------------
;;; Endeavour 173 — reject `let*`.
;;; ---------------------------------------------------------------------------
;;; src/analysis/control.lisp  (register-control-analyzers, near the let entries)
;;;
;;; Crisp's LET is ALREADY SEQUENTIAL and destructures multiple values, so `let*` adds
;;; nothing.  :crisp-language deliberately does not import let/let* from CL, so `let*` in
;;; Crisp source is MINTED as a fresh symbol -- yet register-control-analyzers aliased it
;;; onto analyze-let-expression, so it compiled forward and emitted byte-identical SPIR-V.
;;;
;;; Only the expression analyzer knew.  The uniformity pre-pass matches the operator name
;;; "LET" exactly (%uni-analyze-let's caller, src/analysis/core.lisp), and the AD walk runs
;;; before semantic analysis and knows only `let`.  So `let*` worked until someone added
;;; --differentiate, then failed with "Function SET! is not differentiable" -- blaming an
;;; operator that differentiates fine.  Found in 173: all four A|D specs failed that way
;;; with no shuffle involved.  Forward-legal / backward-fatal / blames a bystander is worse
;;; than refused, so: refused.
;;;
;;; Done by name rather than by symbol because the registration and the reader disagree about
;;; which package LET* lands in; re-pointing every key whose symbol-name is "LET*" covers the
;;; crisp.compiler, common-lisp and crisp-language spellings without guessing.

(defun %analyze-let-star-rejected (expr env context location)
  "Signals a clear error for `let*`, which is not a Crisp form.  Crisp's LET is already
   sequential (later bindings see earlier ones) and destructures multiple values, so LET*
   is redundant; it was previously aliased onto LET in the expression analyzer only, which
   made it compile forward and fail under --differentiate naming an unrelated operator."
  (declare (ignore expr env context))
  (error 'crisp-compiler-error
         :message "Crisp has no LET*. Use LET — Crisp's LET is already sequential, so later bindings may refer to earlier ones"
         :source-location location))

;;; TWO registration sites alias LET*, and the SECOND one wins:
;;;   src/analysis/control.lisp  register-control-analyzers  -> analyze-let-expression
;;;   src/mma.lisp               register-mma-analyzers      -> analyze-let-with-tile-explosion
;;; The mma one interns "LET*" into :crisp-language, and THAT intern is what mints the very
;;; symbol the Crisp reader later reuses for user source.  Hooking only the control site is
;;; dead code -- mma overwrites it, by function OBJECT, moments later.  So both are hooked.
;;;
;;; ONLY the :crisp-language spelling is rejected.  `common-lisp::LET*` stays registered: no
;;; lowering generates a crisp-language LET* form (the tile/stride lowerings all intern "LET"),
;;; but leaving the CL spelling alone costs nothing and keeps this surgical.

(defun %173-reject-let-star ()
  "Re-points the :crisp-language LET* analyzer at %ANALYZE-LET-STAR-REJECTED.  Called from
   both registration wrappers below, since either may run last."
  (let* ((p (find-package :crisp-language))
         (sym (and p (intern "LET*" p))))
    (when sym
      (setf (gethash sym *expression-analyzers*) '%analyze-let-star-rejected)
      (log:debug "173: LET* rejected (~a in ~a)" sym (package-name (symbol-package sym))))))

(defvar *orig-register-control-analyzers*
  (fdefinition 'register-control-analyzers)
  "The src/ definition, captured once at overlay load so the wrapper cannot recurse into
   itself if this file is reloaded (a defvar does not re-evaluate).")

(defun register-control-analyzers ()
  "Overlay wrapper: original registration, then reject LET*.  Must hook a register-* fn
   rather than setf at top level -- initialize-compiler clrhashes *expression-analyzers*."
  (funcall *orig-register-control-analyzers*)
  (%173-reject-let-star))

(defvar *orig-register-mma-analyzers*
  (fdefinition 'register-mma-analyzers)
  "As above, for the site that actually wins the LET* key.")

(defun register-mma-analyzers ()
  "Overlay wrapper: original registration, then reject LET* again -- this site re-registers
   it by function object after register-control-analyzers has run."
  (funcall *orig-register-mma-analyzers*)
  (%173-reject-let-star))


;;; ---------------------------------------------------------------------------
;;; Endeavour 173 — (warp-size), decision D2.
;;; ---------------------------------------------------------------------------
;;; src/analysis/core.lisp  (register-warp-builtins, beside warp-id/warp-lane/warp-count)
;;;
;;; warp-size is NOT a runtime builtin like its three siblings.  It folds to an integer
;;; LITERAL at analysis time, resolved from the active hardware profile's :simd-width (32
;;; with no profile).  That is the whole point of D2: a literal is legal where a runtime
;;; value is not -- as a loop limit, as the default `width` of a shuffle, and as the operand
;;; of a 172 `+` form, which requires every operand to be provably uniform.  A runtime
;;; SubgroupSize builtin could be none of those.
;;;
;;; Folding also means the uniformity pre-pass and the AD walk never see a WARP-SIZE operator
;;; at all -- by the time either runs it is an ordinary constant.  So, unlike the stale
;;; "GET-WARP-SIZE" entry sitting in %uni-builtin-state, no uniformity registration is needed.
;;;
;;; NOTE it is NOT (warp-count).  warp-count is warps per workgroup; warp-size is lanes per
;;; warp.  They will be confused; the error text below says so.

(defun %173-warp-size ()
  "Lanes per warp for the current compilation: the active hardware profile's :simd-width,
   else 32.  Single source of truth -- the shuffle width rules and the SPIR-V subgroup-size
   gate must agree with this, or a kernel could be checked against one width and run at
   another."
  (let ((profile (active-hardware-profile)))
    (or (and profile (getf profile :simd-width)) 32)))

(defun %analyze-warp-size (expr env context location)
  "Analyzer for (warp-size) -- folds to a uint literal.  See %173-WARP-SIZE."
  (declare (ignore env context))
  (when (cdr expr)
    (error 'crisp-compiler-error
           :message (format nil "(warp-size) takes no arguments, got ~a. It is lanes-per-warp, a compile-time constant from the hardware profile's :simd-width — you may be looking for (warp-count), which is warps-per-workgroup"
                            (length (cdr expr)))
           :source-location location))
  (let ((n (%173-warp-size)))
    (log:debug "173: (warp-size) folded to ~a" n)
    (make-semantic-literal :value-type 'uint :value n :source-location location)))

(defvar *orig-register-warp-builtins*
  (fdefinition 'register-warp-builtins)
  "Captured once at overlay load so the wrapper cannot recurse into itself on reload.")

(defun register-warp-builtins ()
  "Overlay wrapper: the original warp-id/warp-lane/warp-count registration, plus WARP-SIZE.
   Registered into BOTH :crisp-language and :crisp.compiler, as the original does -- user
   source reads in :crisp-language, and an unregistered spelling there is silently minted as
   a fresh symbol rather than reported (the trap that hid the LET* aliasing above)."
  (funcall *orig-register-warp-builtins*)
  (let* ((cl-pkg (find-package :crisp-language))
         (cc-pkg (find-package :crisp.compiler))
         (sym-cl (intern "WARP-SIZE" cl-pkg))
         (sym-cc (intern "WARP-SIZE" cc-pkg)))
    (setf (gethash sym-cl *expression-analyzers*) '%analyze-warp-size)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) '%analyze-warp-size))))


;;; ---------------------------------------------------------------------------
;;; Endeavour 173 — the four shuffle ops: node + analyzer.
;;; ---------------------------------------------------------------------------
;;; NEW struct (belongs in src/semantic.lisp when folded back); analyzer belongs beside the
;;; endeavour-170 one in src/analysis/ops.lisp.
;;;
;;; WHY ITS OWN NODE rather than reusing semantic-hw-op (170's one-node-for-every-hardware-
;;; math-op).  Two reasons, the first decisive:
;;;
;;;   * WIDTH MUST NOT BE AN ARGUMENT NODE.  As a hw-op arg it would be subject to ANF, and
;;;     codegen would have to HOPE it was still a literal by the time it arrived.  Here it is
;;;     a resolved INTEGER SLOT, fixed at analysis time and immune to every later pass.
;;;   * The rule that decides compile-error-vs-inverse-permutation for a runtime target index
;;;     has no home inside %hw-op-backward, whose every other branch is pointwise arithmetic.
;;;
;;; A new struct is fine in an overlay -- nothing in src/ references it.  Only REDEFINING an
;;; existing struct is forbidden.  The two etypecase dispatchers are WRAPPED, not copied, so
;;; there is no 75-line duplicate to drift; generate-node-ir is a defgeneric, so it just gets
;;; a method (see the codegen section below).

(defstruct semantic-shuffle
  "A warp shuffle.  OP is :idx / :up / :down / :xor.  TYPE is the result type, which is
   always the type of VALUE.  INDEX is the analyzed target-lane / delta / mask node.  WIDTH
   is a RESOLVED POSITIVE INTEGER (segment width in lanes), never a node -- see the header."
  type op value index width source-location)

(defparameter *shuffle-op-names*
  '(("SHUFFLE" . :idx) ("SHUFFLE-UP" . :up) ("SHUFFLE-DOWN" . :down) ("SHUFFLE-XOR" . :xor))
  "Crisp operator name -> shuffle op keyword.")

(defparameter *shuffle-value-types*
  '(int uint float long ulong double)
  "Scalar types a shuffle may move.  The 32-bit ones are one hardware instruction; the
   64-bit ones are decomposed into hi/lo halves by codegen (D9).")

(defun %shuffle-literal-integer (node)
  "The integer value of NODE if it is a compile-time integer literal, else NIL.
   (warp-size) folds to such a literal, so (shuffle v n (warp-size)) is accepted."
  (when (and (semantic-literal-p node)
             (integerp (semantic-literal-value node)))
    (semantic-literal-value node)))

(defun %shuffle-resolve-width (width-node op-name location)
  "Validates and returns the segment width for a shuffle (D4).  WIDTH-NODE may be NIL, in
   which case the width is the whole warp."
  (let ((warp (%173-warp-size)))
    (if (null width-node)
        warp
        (let ((w (%shuffle-literal-integer width-node)))
          (cond
            ((null w)
             (error 'crisp-compiler-error
                    :message (format nil "~a: the segment width must be a constant known at compile time. A lane-varying width is meaningless -- every lane has to agree which lanes it exchanges with -- and the power-of-two and not-wider-than-the-warp rules can only be checked statically"
                                     op-name)
                    :source-location location))
            ((or (<= w 0) (/= 0 (logand w (1- w))))
             (error 'crisp-compiler-error
                    :message (format nil "~a: the segment width must be a power of two, got ~a. The hardware divides the warp into ALIGNED blocks, so ~a has no lowering at all"
                                     op-name w w)
                    :source-location location))
            ((> w warp)
             (error 'crisp-compiler-error
                    :message (format nil "~a: a segment width of ~a is wider than the warp it segments (~a lanes under the active hardware profile). A segment cannot exceed the warp that contains it"
                                     op-name w warp)
                    :source-location location))
            (t w))))))

(defun %analyze-shuffle (expr env context location)
  "Analyzes (shuffle|shuffle-up|shuffle-down|shuffle-xor VALUE INDEX [WIDTH]).
   See the section header for why this builds its own node rather than a semantic-hw-op."
  (let* ((op-name (symbol-name (first expr)))
         (op (cdr (assoc op-name *shuffle-op-names* :test #'string=)))
         (args (rest expr)))
    (unless (member (length args) '(2 3))
      (error 'crisp-compiler-error
             :message (format nil "~a expects <value> and <~a>, with an optional trailing width -- 2 or 3 arguments, got ~a"
                              op-name
                              (case op (:idx "target-lane") (:xor "lane-mask") (t "delta"))
                              (length args))
             :source-location location))
    (let* ((value-node (analyze-expression (first args) env context (append location '(1))))
           (index-node (analyze-expression (second args) env context (append location '(2))))
           (width-node (when (third args)
                         (analyze-expression (third args) env context (append location '(3)))))
           (value-type (get-single-value-type value-node))
           (width (%shuffle-resolve-width width-node op-name location)))
      (unless (member value-type *shuffle-value-types*)
        (error 'crisp-compiler-error
               :message (format nil "~a cannot move a value of type ~a. A shuffle exchanges a scalar register between lanes; the supported types are ~{~a~^, ~}"
                                op-name value-type *shuffle-value-types*)
               :source-location location))
      ;; D5 -- an xor mask that cannot stay inside its segment.  Checkable only when the mask
      ;; is a literal; a RUNTIME mask is the reduction idiom (it comes from dec-times-by-half+)
      ;; and is accepted.
      (when (eq op :xor)
        (let ((m (%shuffle-literal-integer index-node)))
          (when (and m (>= m width))
            (error 'crisp-compiler-error
                   :message (format nil "shuffle-xor: a lane-mask of ~a reaches outside its segment of ~a lanes. XOR by a mask SMALLER than the segment can never leave it, which is the only case with a meaning; ~a >= ~a asks to read a lane the segmentation forbids"
                                    m width m width)
                   :source-location location))))
      ;; D6 -- every lane must reach a warp collective.
      (%shuffle-check-not-divergent op-name location)
      (log:debug "173: ~a op=~a type=~a width=~a" op-name op value-type width)
      (make-semantic-shuffle :type value-type :op op :value value-node
                             :index index-node :width width
                             :source-location location))))

;;; --- dispatch wiring: wrap, never copy ---

(defvar *orig-semantic-node-type* (fdefinition 'semantic-node-type)
  "Captured once; the etypecase in src/analysis/core.lisp is ~75 lines and must not be
   duplicated here, so it is delegated to rather than reproduced.")

(defun semantic-node-type (node)
  "Overlay wrapper: semantic-shuffle, else the original etypecase."
  (if (semantic-shuffle-p node)
      (semantic-shuffle-type node)
      (funcall *orig-semantic-node-type* node)))

(defvar *orig-semantic-node-source-location* (fdefinition 'semantic-node-source-location)
  "As above.")

(defun semantic-node-source-location (node)
  "Overlay wrapper: semantic-shuffle, else the original etypecase."
  (if (semantic-shuffle-p node)
      (semantic-shuffle-source-location node)
      (funcall *orig-semantic-node-source-location* node)))

;;; --- registration ---

(defvar *orig-register-ops-analyzers*
  (fdefinition 'register-ops-analyzers)
  "Captured once at overlay load.")

(defun register-ops-analyzers ()
  "Overlay wrapper: the original op analyzers, plus the four shuffles under both
   :crisp-language and :crisp.compiler."
  (funcall *orig-register-ops-analyzers*)
  (let ((cl-pkg (find-package :crisp-language))
        (cc-pkg (find-package :crisp.compiler)))
    (dolist (entry *shuffle-op-names*)
      (let ((sym-cl (intern (car entry) cl-pkg))
            (sym-cc (intern (car entry) cc-pkg)))
        (setf (gethash sym-cl *expression-analyzers*) '%analyze-shuffle)
        (unless (eq sym-cl sym-cc)
          (setf (gethash sym-cc *expression-analyzers*) '%analyze-shuffle))))))


;;; ---------------------------------------------------------------------------
;;; Endeavour 173 — shuffle codegen (PTX + SPIR-V).
;;; ---------------------------------------------------------------------------
;;; src/codegen.lisp
;;;
;;; THE ONE REAL SEMANTIC DIFFERENCE BETWEEN THE BACKENDS, and it decides this whole design:
;;; when a shift runs off the end, PTX's shfl.sync.up/down return the caller's OWN value (the
;;; instruction has a predicate for exactly that), but SPIR-V says an out-of-range
;;; OpGroupNonUniformShuffleUp/Down is UNDEFINED.  Crisp promises the CUDA rule, so SPIR-V
;;; cannot simply use the matching opcode.
;;;
;;; Rather than shuffle-then-select, the target lane itself is CLAMPED TO THE CALLER when the
;;; source would be out of range, and a plain OpGroupNonUniformShuffle reads it.  Reading your
;;; own lane returns your own value -- which IS the rule -- so one shuffle does the job with no
;;; select, and (usefully) no select binding, which llvm-bindings does not have.
;;;
;;; The validity flag is folded in arithmetically: target = lane -/+ delta*zext(valid).  When
;;; invalid that term is zero and the target is the caller's own lane.
;;;
;;; SEGMENTATION falls out of the same formula.  With k = lane & (width-1):
;;;     idx   target = (lane & ~(width-1)) | (idx & (width-1))
;;; which at width = warp reduces to idx & (warp-1) -- i.e. CUDA's "srcLane modulo width" --
;;; because lane < warp makes the first term zero.  So there is ONE formula, not two.
;;;
;;; xor keeps the native opcode on both backends (bfly / OpGroupNonUniformShuffleXor): D5
;;; guarantees mask < width, so an xor can never leave its segment and needs no arithmetic.
;;; That matters -- xor is the hot path for reductions and stays a single instruction.

(defun %shuffle-index-i32 (builder idx-val idx-type)
  "Narrows a shuffle index/delta/mask to the i32 the hardware ops take."
  (let ((i32 (crisp.llvm-bindings::llvm-int32-type)))
    (case idx-type
      ((long ulong) (crisp.llvm-bindings::llvm-build-trunc builder idx-val i32 "shfl_idx"))
      ((int uint) idx-val)
      (t (error 'crisp-compiler-error
                :message (format nil "a shuffle index must be an integer, got ~a" idx-type))))))

(defun %shuffle-ptx (builder module op val idx width)
  "One 32-bit shuffle via the NVVM intrinsics, which map 1:1 to shfl.sync.{idx,up,down,bfly}.

   The `c` operand packs the segment mask with the clamp value exactly as CUDA does:
   c = ((warpSize - width) << 8) | clamp, where clamp is 0 for .up and 0x1f otherwise.
   Membermask is the full warp, which is legitimate because D6 rejects a shuffle reached
   from divergent control flow -- every lane is here."
  (let* ((i32 (crisp.llvm-bindings::llvm-int32-type))
         (warp (%173-warp-size))
         (clamp (if (eq op :up) 0 #x1f))
         (c (logior (ash (- warp width) 8) clamp))
         (name (ecase op
                 (:idx  "llvm.nvvm.shfl.sync.idx.i32")
                 (:up   "llvm.nvvm.shfl.sync.up.i32")
                 (:down "llvm.nvvm.shfl.sync.down.i32")
                 (:xor  "llvm.nvvm.shfl.sync.bfly.i32"))))
    (log:debug "173 ptx shuffle: ~a width=~a c=#x~x" name width c)
    (%coop-call builder module name i32
                (list i32 i32 i32 i32)
                (list (crisp.llvm-bindings::llvm-const-int i32 #xFFFFFFFF nil)
                      val idx
                      (crisp.llvm-bindings::llvm-const-int i32 c nil)))))

(defun %shuffle-spv-target (builder lane op idx width)
  "The absolute target lane for a SPIR-V shuffle -- see the section header.  Clamps to LANE
   itself when the source would leave the segment, which reproduces the CUDA own-value rule."
  (let* ((i32 (crisp.llvm-bindings::llvm-int32-type))
         (wmask (crisp.llvm-bindings::llvm-const-int i32 (1- width) nil))
         (k (crisp.llvm-bindings::llvm-build-and builder lane wmask "shfl_k")))
    (ecase op
      (:idx
       (let ((base (crisp.llvm-bindings::llvm-build-and
                    builder lane
                    (crisp.llvm-bindings::llvm-const-int
                     i32 (logand (lognot (1- width)) #xFFFFFFFF) nil)
                    "shfl_base"))
             (off (crisp.llvm-bindings::llvm-build-and builder idx wmask "shfl_off")))
         (crisp.llvm-bindings::llvm-build-or builder base off "shfl_tgt")))
      (:up
       ;; valid = k >= delta
       (let* ((p (crisp.llvm-bindings::llvm-build-icmp
                  builder crisp.llvm-bindings::+llvm-int-uge+ k idx "shfl_ok"))
              (vz (crisp.llvm-bindings::llvm-build-zext builder p i32 "shfl_okz"))
              (d (crisp.llvm-bindings::llvm-build-mul builder idx vz "shfl_d")))
         (crisp.llvm-bindings::llvm-build-sub builder lane d "shfl_tgt")))
      (:down
       ;; valid = k + delta < width
       (let* ((sum (crisp.llvm-bindings::llvm-build-add builder k idx "shfl_sum"))
              (p (crisp.llvm-bindings::llvm-build-icmp
                  builder crisp.llvm-bindings::+llvm-int-ult+ sum
                  (crisp.llvm-bindings::llvm-const-int i32 width nil) "shfl_ok"))
              (vz (crisp.llvm-bindings::llvm-build-zext builder p i32 "shfl_okz"))
              (d (crisp.llvm-bindings::llvm-build-mul builder idx vz "shfl_d")))
         (crisp.llvm-bindings::llvm-build-add builder lane d "shfl_tgt"))))))

(defun %shuffle-spv (builder module op val idx width)
  "One 32-bit shuffle via the SPIR-V group-non-uniform ops.  Scope operand 3 = Subgroup."
  (%shuffle-check-pinned nil)
  (let* ((i32 (crisp.llvm-bindings::llvm-int32-type))
         (scope (crisp.llvm-bindings::llvm-const-int i32 3 nil)))
    (if (eq op :xor)
        (%coop-call builder module "__spirv_GroupNonUniformShuffleXor" i32
                    (list i32 i32 i32) (list scope val idx))
        (let* ((lane (%call-spirv-uint-global-builtin builder module "SubgroupLocalInvocationId"))
               (target (%shuffle-spv-target builder lane op idx width)))
          (%coop-call builder module "__spirv_GroupNonUniformShuffle" i32
                      (list i32 i32 i32) (list scope val target))))))

(defun %shuffle-emit-i32 (builder module op val idx width)
  "One 32-bit shuffle on the active backend."
  (if (eq *target-backend* :ptx)
      (%shuffle-ptx builder module op val idx width)
      (%shuffle-spv builder module op val idx width)))

(defun %shuffle-emit-i64 (builder module op val64 idx width)
  "D9: the hardware moves 32 bits, so a 64-bit value is split into hi/lo halves, shuffled
   SEPARATELY, and recombined.  Both halves take the same op, index and width, so the two
   shuffles agree about which lane they are reading."
  (let* ((i32 (crisp.llvm-bindings::llvm-int32-type))
         (i64 (crisp.llvm-bindings::llvm-int64-type))
         (lo (crisp.llvm-bindings::llvm-build-trunc builder val64 i32 "shfl_lo"))
         (hi64 (crisp.llvm-bindings::llvm-build-l-shr
                builder val64 (crisp.llvm-bindings::llvm-const-int i64 32 nil) "shfl_hi64"))
         (hi (crisp.llvm-bindings::llvm-build-trunc builder hi64 i32 "shfl_hi"))
         (slo (%shuffle-emit-i32 builder module op lo idx width))
         (shi (%shuffle-emit-i32 builder module op hi idx width))
         (zlo (crisp.llvm-bindings::llvm-build-zext builder slo i64 "shfl_zlo"))
         (zhi (crisp.llvm-bindings::llvm-build-zext builder shi i64 "shfl_zhi"))
         (hish (crisp.llvm-bindings::llvm-build-shl
                builder zhi (crisp.llvm-bindings::llvm-const-int i64 32 nil) "shfl_hish")))
    (crisp.llvm-bindings::llvm-build-or builder hish zlo "shfl_join")))

(defmethod generate-node-ir ((node semantic-shuffle) builder module var-env di-builder di-scope location-map)
  "A warp shuffle.  Floats ride through the integer path by bitcast -- the hardware moves
   bits, not numbers -- and 64-bit values are decomposed (D9)."
  (flet ((gen (n) (generate-node-ir n builder module var-env di-builder di-scope location-map)))
    (let* ((ty (semantic-shuffle-type node))
           (op (semantic-shuffle-op node))
           (width (semantic-shuffle-width node))
           (idx-node (semantic-shuffle-index node))
           (val (gen (semantic-shuffle-value node)))
           (idx (%shuffle-index-i32 builder (gen idx-node)
                                    (get-single-value-type idx-node)))
           (i32 (crisp.llvm-bindings::llvm-int32-type))
           (i64 (crisp.llvm-bindings::llvm-int64-type)))
      (log:debug "173 codegen shuffle: op=~a ty=~a width=~a backend=~a" op ty width *target-backend*)
      (values
       (ecase ty
         ((int uint)
          (%shuffle-emit-i32 builder module op val idx width))
         ((float)
          (let* ((bits (crisp.llvm-bindings::llvm-build-bit-cast builder val i32 "shfl_fbits"))
                 (res (%shuffle-emit-i32 builder module op bits idx width)))
            (crisp.llvm-bindings::llvm-build-bit-cast
             builder res (resolve-type-to-llvm 'float) "shfl_fval")))
         ((long ulong)
          (%shuffle-emit-i64 builder module op val idx width))
         ((double)
          (let* ((bits (crisp.llvm-bindings::llvm-build-bit-cast builder val i64 "shfl_dbits"))
                 (res (%shuffle-emit-i64 builder module op bits idx width)))
            (crisp.llvm-bindings::llvm-build-bit-cast
             builder res (resolve-type-to-llvm 'double) "shfl_dval"))))
       nil))))


;;; ---------------------------------------------------------------------------
;;; Endeavour 173 — D6 (convergence) and D7 (pinned subgroup size).
;;; ---------------------------------------------------------------------------
;;; src/analysis/control.lisp (D6, beside %tlc-check-not-divergent) and
;;; src/codegen.lisp (D7, beside %emit-spirv-subgroup-size-execution-mode).

(defun %shuffle-check-not-divergent (op-name location)
  "D6: a shuffle is a warp collective and every lane must reach it.

   Deliberately NOT %tlc-check-not-divergent: that one explains a deadlocking internal
   sync-workgroup, which is not what goes wrong here, and it would reject a case that is
   actually fine.

   THE WARP-SPECIALIZATION EXEMPTION.  Endeavour 139 role blocks also set
   *in-divergent-conditional*, but that divergence is BETWEEN warps -- every lane of any one
   warp takes the same role. A warp collective is therefore still fully converged inside a
   role block, so a shuffle there is legal.  What breaks a shuffle is divergence WITHIN a
   warp, which is what an ordinary thread-divergent conditional produces."
  (when (and *in-divergent-conditional* (not *in-warp-spec-block*))
    (error 'crisp-compiler-error
           :message (format nil "~a is a warp collective and cannot appear inside a thread-divergent conditional (if / when / unless / cond): the lanes that arrive would be asking for data from lanes that never will. Shuffle in every lane UNCONDITIONALLY and gate only what you do with the result, or use a uniform condition (if+ / when+ / unless+, or one based on get-workgroup-id rather than get-local-id)"
                            op-name)
           :source-location location)))

;;; --- D7: on SPIR-V a shuffling kernel must have a pinned subgroup size ---
;;;
;;; The check runs at CODEGEN, not analysis, because that is where the answer exists: the
;;; kernel's dispatch declarations and the active profile are both resolved by then, and 156's
;;; pinning decision is made at function setup (codegen.lisp:522) BEFORE any body node is
;;; generated.  So the flag below is always set by the time a shuffle asks about it.
;;;
;;; COUPLING, stated openly: %173-SUBGROUP-PINNED-P mirrors the four conditions in
;;; %emit-spirv-subgroup-size-execution-mode.  It must track that function.  The alternative --
;;; inspecting the emitted metadata -- has no binding, and guessing would be worse than a
;;; documented mirror that errors/06 exercises.

(defvar *173-subgroup-pinned* nil
  "T when the kernel currently being generated had its SPIR-V subgroup size pinned by 156.")

(defun %173-subgroup-pinned-p (semantic-function)
  "The four 156 conditions, mirrored.  See the coupling note above."
  (let* ((profile (active-hardware-profile))
         (simd    (and profile (getf profile :simd-width)))
         (kname   (semantic-function-name semantic-function))
         (disp    (and kname (gethash kname *kernel-dispatch-declarations*)))
         (dims    (and disp (%hp-local-size-dims (getf disp :local-size))))
         (total   (and dims (reduce #'* dims))))
    (and (integerp simd) total (>= total simd) (zerop (mod total simd)))))

(defvar *orig-emit-spirv-subgroup-size-execution-mode*
  (fdefinition '%emit-spirv-subgroup-size-execution-mode)
  "Captured once at overlay load.")

(defun %emit-spirv-subgroup-size-execution-mode (func module semantic-function)
  "Overlay wrapper: unchanged behaviour, plus it records whether the size was pinned so a
   shuffle in this kernel can refuse to be compiled against a width nobody guaranteed."
  (setf *173-subgroup-pinned* (%173-subgroup-pinned-p semantic-function))
  (log:debug "173: subgroup pinned for ~a = ~a"
             (semantic-function-name semantic-function) *173-subgroup-pinned*)
  (funcall *orig-emit-spirv-subgroup-size-execution-mode* func module semantic-function))

(defun %shuffle-check-pinned (location)
  "D7.  On Intel the driver picks the subgroup size (8, 16 or 32) unless the kernel pins it,
   and a reduction written for 16 lanes that runs on 32 does not crash -- it returns a wrong
   answer.  So a shuffling kernel that cannot be pinned is refused rather than compiled
   against an assumed 32.  NVIDIA is exempt: its warp has been 32 lanes on every architecture
   shipped, so there is nothing to pin."
  (unless (or (eq *target-backend* :ptx) *173-subgroup-pinned*)
    (error 'crisp-compiler-error
           :message "this kernel uses a shuffle, but its SPIR-V subgroup size cannot be pinned, so the warp width it would run at is whatever the driver chooses (8, 16 or 32 on Intel) rather than the width this kernel was compiled against. Pinning needs an active hardware profile naming a :simd-width AND a compile-time (local-size :set-to N) whose total is a whole multiple of it. Crisp refuses rather than assuming 32: a reduction written for one width and run at another returns a wrong answer instead of failing"
           :source-location location)))
