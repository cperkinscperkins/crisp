(in-package :crisp.hoist.l0)

;;;; ===========================================================================
;;;; Endeavour 175 — resolve SYMBOLIC scratch sizes in the generated host code.
;;;; ===========================================================================
;;;; src/hoist-l0/main.lisp
;;;;
;;;; THE BUG THIS CLOSES.  A scratch tensor may be sized with a KEYWORD rather than an
;;;; integer -- (make-scratch-vector float :match-num-warps-per-workgroup).  The compiler
;;;; passes that keyword through verbatim into the metacrisp as :size-expr (by design; see
;;;; below), and until now %l0-scratch-dims accepted only an integer or a list of integers
;;;; and errored on everything else:
;;;;
;;;;   Error: Scratch tensor sv_from_wg_warp_scratch_1: :size-expr
;;;;          MATCH-NUM-WARPS-PER-WORKGROUP is neither an integer nor a list of 1 integers.
;;;;
;;;; So a symbolic size compiled cleanly, emitted metadata, and then died at HOIST.  Nothing
;;;; caught it because no spec combined a symbolic size with a TEST-HOIST run: 074 and 075
;;;; use :match-workgroup-size / :match-warp-tile in compile-only and metadata-only specs.
;;;; tests/spec/175-reductions/02 is the first, and it exists to keep this fixed.
;;;;
;;;; WHY THE HOISTER RESOLVES THIS AND NOT THE COMPILER.  Crisp is a kernel-only language
;;;; with no runtime.  The generated .cpp is SAMPLE host code the user may adapt or discard,
;;;; and the real global/local sizes are chosen by whoever performs the enqueue.  The
;;;; (local-size ...) declaration is author INTENT -- used to fit and comment the generated
;;;; launcher -- not a fact the compiler may fold against.  Folding the size to a literal at
;;;; compile time would bake in an assumption the host is free to violate: a kernel handed a
;;;; 4-element scratch buffer could be launched with 8 warps and corrupt silently.
;;;;
;;;; Hence the size is emitted as a C++ EXPRESSION over named geometry constants, not as a
;;;; number.  Editing wg_size in the generated launcher re-sizes every dependent scratch
;;;; buffer, which is the entire point of a symbolic size; a baked literal would reduce
;;;; :match-num-warps-per-workgroup to "a comment that computed a 4 at build time".
;;;;
;;;; SCOPED TO RANK 1 deliberately.  A symbolic size names ONE length, and %l0-scratch-dims'
;;;; scalar rule makes a SQUARE tensor of that size in every dimension -- which for a rank-3
;;;; scratch at :match-workgroup-size would be wg^3 elements of SLM (64^3 = 262144 for a
;;;; 64-thread group).  That is not a meaning anyone wants, and the existing rank-3 uses in
;;;; 074/01 and 074/03 never reached a hoist run to discover it.  Rank > 1 therefore keeps
;;;; today's behaviour (an error), with a message that now says why.
;;;;
;;;; :match-num-workgroups IS DELIBERATELY NOT IMPLEMENTED HERE.  Under
;;;; (global-size ... :strategy :strided) the generated launcher computes its group count at
;;;; RUNTIME from zeDeviceGetProperties, so the value does not exist at hoist time at all --
;;;; it needs the group-count variable plumbed through %l0-emit-group-count.  That work
;;;; belongs with grid-reduce-last-man!, whose globalScratchVec is the first thing that needs
;;;; it.  Asking for it now gets a clear refusal rather than a wrong buffer.

(defvar *l0-simd-width* nil
  "Endeavour 175: the active hardware profile's :simd-width (lanes per warp), or NIL.
   Latched by %l0-latch-hardware-profile; consumed by the symbolic scratch-size resolver.")

(defvar *orig-l0-latch-hardware-profile*
  (fdefinition '%l0-latch-hardware-profile)
  "Captured once at overlay load so the wrapper cannot recurse into itself on reload.")

(defun %l0-latch-hardware-profile (data)
  "Overlay wrapper: the original latch, plus :simd-width for the 175 scratch-size resolver.
   Returns the profile, as the original does -- callers bind it."
  (let ((profile (funcall *orig-l0-latch-hardware-profile* data)))
    (setf *l0-simd-width* (getf profile :simd-width))
    profile))

;;; --- the symbolic size vocabulary -------------------------------------------

(defparameter *l0-scratch-warp-size-fallback* 32
  "Lanes per warp assumed when no hardware profile is active.  Matches the compiler's own
   fallback in %173-warp-size, and MUST stay equal to it: the kernel computes its warp count
   from one and the host sizes the buffer from the other, so a disagreement is a wrong answer
   rather than a failure.")

(defun %l0-scratch-warp-size ()
  "Lanes per warp for scratch sizing: the active profile's :simd-width, else the fallback."
  (or *l0-simd-width* *l0-scratch-warp-size-fallback*))

(defun %l0-scratch-symbolic-size-p (size-expr)
  "T when SIZE-EXPR is a symbolic (keyword) scratch size rather than a concrete extent."
  (keywordp size-expr))

(defun %l0-scratch-symbolic-expr (size-expr param-name)
  "The C++ expression (a string) giving the ELEMENT COUNT for a symbolic rank-1 scratch size,
   in terms of the geometry constants %l0-emit-geometry-constants emits.

   Returns a second value: a short human phrase for the generated comment."
  (let ((name (symbol-name size-expr)))
    (cond
      ((string-equal name "MATCH-WORKGROUP-SIZE")
       (values "wg_size" "one element per thread in the workgroup"))
      ((string-equal name "MATCH-NUM-WARPS-PER-WORKGROUP")
       ;; CEILING division, matching the design doc's (ceil (get-local-work-size)
       ;; (get-warp-size)).  A workgroup that is not a whole multiple of the warp still has a
       ;; final PARTIAL warp, and that warp's leader writes a slot like any other -- floor
       ;; would hand it a buffer one element short and it would write past the end.
       (values "((wg_size + warp_size - 1u) / warp_size)"
               "one element per warp in the workgroup"))
      ((string-equal name "MATCH-NUM-WORKGROUPS")
       (error "Scratch tensor ~a: :size-expr :match-num-workgroups is not implemented yet.~%~
               Its value is the grid's group count, which under (global-size ... :strategy :strided) the~%~
               generated launcher computes at RUNTIME from zeDeviceGetProperties -- so it cannot be~%~
               resolved here without plumbing the group-count variable through the dispatch emitter.~%~
               That arrives with grid-reduce-last-man!, which is the first construct to need it.~%~
               For now, size this buffer with an explicit integer."
              param-name))
      (t
       (error "Scratch tensor ~a: unknown symbolic :size-expr ~a.~%~
               The sizes this hoister can resolve are :match-workgroup-size and~%~
               :match-num-warps-per-workgroup.  (:match-warp-tile is recorded in the metacrisp~%~
               for tooling but has no host-side meaning, so it cannot size a buffer here.)"
              param-name size-expr)))))

;;; --- geometry constants -----------------------------------------------------
;;;
;;; Emitted for EVERY kernel, not only those with symbolic scratch, so that
;;; %l0-emit-dispatch can always phrase zeKernelSetGroupSize in terms of them.  Two unused
;;; block-scope consts cost nothing in C++ and keep one launch geometry in one place.
;;;
;;; They are emitted just BEFORE the argument-setup block.  That matters: kernel arguments are
;;; set well ahead of zeKernelSetGroupSize in the generated main() (~line 149 vs ~285), and the
;;; two regions share one brace scope, so constants declared here are visible to both.

(defun %l0-dispatch-local-dims (dispatch-info)
  "The declared workgroup dims (X Y) from DISPATCH-INFO, defaulting to (1 1) exactly as
   %l0-emit-dispatch does.  Kept in step with that function on purpose -- the scratch size and
   the group size must agree about what the workgroup is."
  (let* ((local-decl (getf dispatch-info :local-size))
         (ls-rest    (when local-decl (cdr local-decl)))
         (ls-set-to  (when ls-rest (getf ls-rest :set-to)))
         (local-x (cond ((integerp ls-set-to) ls-set-to)
                        ((and (listp ls-set-to) (first ls-set-to)) (first ls-set-to))
                        (t 1)))
         (local-y (cond ((and (listp ls-set-to) (second ls-set-to)) (second ls-set-to))
                        (t 1))))
    (list local-x local-y)))

(defun %l0-emit-geometry-constants (stream dispatch-info)
  "Emit the named launch-geometry constants the scratch sizes and the group size are both
   phrased against.  One place to edit when re-tuning a launch."
  (destructuring-bind (local-x local-y) (%l0-dispatch-local-dims dispatch-info)
    (let ((warp (%l0-scratch-warp-size)))
      (format stream "~%    // ---- Launch geometry -------------------------------------------------~%")
      (format stream "    // The workgroup-local scratch sizes below are EXPRESSIONS over these,~%")
      (format stream "    // so they follow whatever geometry you launch with.~%")
      (format stream "    // NOTE: if you retune the launch, change the zeKernelSetGroupSize call~%")
      (format stream "    // further down TO MATCH -- it carries its own literals, and a mismatch~%")
      (format stream "    // gives you scratch buffers sized for the geometry you replaced.~%")
      (format stream "    const uint32_t wg_size_x = ~du;~%" local-x)
      (format stream "    const uint32_t wg_size_y = ~du;~%" local-y)
      (format stream "    const uint32_t wg_size   = wg_size_x * wg_size_y;~%")
      (format stream "    const uint32_t warp_size = ~du;   // ~a~%"
              warp
              (if *l0-simd-width*
                  "hardware profile :simd-width"
                  "no active hardware profile -- Crisp's default warp width"))
      (format stream "    (void)wg_size; (void)warp_size;~%")
      (format stream "    // --------------------------------------------------------------------~%~%"))))

(defvar *orig-generate-kernel-arguments-with-usm*
  (fdefinition 'generate-kernel-arguments-with-usm)
  "Captured once at overlay load.")

(defun generate-kernel-arguments-with-usm (stream declared-sig aliases records
                                           context-var device-var dispatch-info)
  "Overlay wrapper: emit the launch-geometry constants first, then the original argument walk
   unchanged.  A wrapper rather than an edit because the original is long and this needs only
   a prologue."
  (%l0-emit-geometry-constants stream dispatch-info)
  (funcall *orig-generate-kernel-arguments-with-usm*
           stream declared-sig aliases records context-var device-var dispatch-info))

;;; --- the resolver itself ----------------------------------------------------

(defvar *orig-l0-scratch-dims* (fdefinition '%l0-scratch-dims)
  "Captured once at overlay load.")

(defun %l0-scratch-dims (size-expr rank param-name)
  "Overlay wrapper: a SYMBOLIC (keyword) size is legal at rank 1 and is reported as such;
   everything else defers to the original integer/list rule."
  (if (%l0-scratch-symbolic-size-p size-expr)
      (if (= rank 1)
          ;; The caller below never uses this for a symbolic size -- it takes the expression
          ;; path -- but returning something well-formed keeps any other caller honest.
          (list (%l0-scratch-symbolic-expr size-expr param-name))
          (error "Scratch tensor ~a: a symbolic :size-expr (~a) names ONE length, so it is only~%~
                  meaningful for a rank-1 scratch vector; this tensor has rank ~d.~%~
                  (The scalar-size rule would make a SQUARE tensor -- that size in EVERY~%~
                  dimension -- which for a workgroup-derived size is almost never intended.)~%~
                  Give explicit per-dimension extents instead, e.g. (make-scratch-matrix float (8 16))."
                 param-name size-expr rank))
      (funcall *orig-l0-scratch-dims* size-expr rank param-name)))

(defun %l0-emit-symbolic-local-scratch-arg (stream param-name param-type arg-index size-expr)
  "Emit the 6 kernel arguments (3*rank+3 at rank 1) for a workgroup-local scratch VECTOR whose
   length is a symbolic size, phrasing every one as a C++ expression over the geometry
   constants.  Mirrors %l0-emit-local-scratch-tensor-arg's argument ORDER exactly:
   ptr, byte-size, offset[0], stride[0], extent[0], length."
  (multiple-value-bind (count-expr phrase)
      (%l0-scratch-symbolic-expr size-expr param-name)
    (let* ((elem-type (second param-type))
           (elem-str  (crisp-type-to-cpp-type elem-type))
           (elem-bytes (%elem-type-bytes elem-str))
           (cpp (substitute #\_ #\- param-name))
           (idx arg-index))
      (format stream "~%    // LOCAL scratch vector: ~a (rank=1, ~a, ~a)~%" param-name elem-str phrase)
      (format stream "    //   :size-expr ~a -- resolved as an EXPRESSION, not a literal, so it~%" size-expr)
      (format stream "    //   tracks the launch geometry above rather than freezing this build's value.~%")
      (format stream "    const uint64_t ~a_elems     = (uint64_t)~a;~%" cpp count-expr)
      (format stream "    const uint64_t ~a_byte_size = ~a_elems * ~dULL;~%" cpp cpp elem-bytes)
      ;; Arg N: local memory allocation -- nullptr + bytesize
      (format stream "    // Arg ~d: local ptr (~a_byte_size bytes of workgroup-local memory)~%" idx cpp)
      (format stream "    zeKernelSetArgumentValue(kernel, ~d, ~a_byte_size, nullptr);~%" idx cpp)
      (incf idx)
      ;; Arg N+1: byte-size (must be an lvalue -- the API takes its address)
      (format stream "    // Arg ~d: byte-size~%" idx)
      (format stream "    uint64_t ~a_byte_size_arg = ~a_byte_size;~%" cpp cpp)
      (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_byte_size_arg);~%" idx cpp)
      (incf idx)
      ;; Arg N+2: offset[0]
      (format stream "    // Arg ~d: offset[0] = 0~%" idx)
      (format stream "    uint64_t ~a_off0 = 0ULL;~%" cpp)
      (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_off0);~%" idx cpp)
      (incf idx)
      ;; Arg N+3: stride[0] -- 1 element, compact, independent of the length
      (format stream "    // Arg ~d: stride[0] = 1 (elements, compact)~%" idx)
      (format stream "    uint64_t ~a_str0 = 1ULL;~%" cpp)
      (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_str0);~%" idx cpp)
      (incf idx)
      ;; Arg N+4: extent[0]
      (format stream "    // Arg ~d: extent[0]~%" idx)
      (format stream "    uint64_t ~a_ext0 = ~a_elems;~%" cpp cpp)
      (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_ext0);~%" idx cpp)
      (incf idx)
      ;; Arg N+5: length
      (format stream "    // Arg ~d: length~%" idx)
      (format stream "    uint64_t ~a_length = ~a_elems;~%" cpp cpp)
      (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_length);~%~%" idx cpp)
      (incf idx)
      idx)))

(defvar *orig-l0-emit-local-scratch-tensor-arg*
  (fdefinition '%l0-emit-local-scratch-tensor-arg)
  "Captured once at overlay load.")

(defun %l0-emit-local-scratch-tensor-arg (stream param param-name param-type arg-index)
  "Overlay wrapper: a rank-1 symbolic size takes the expression emitter; every other scratch
   tensor is emitted exactly as before.  Delegating rather than copying keeps the original
   3N+3 walk as the single source of truth for the concrete case."
  (let ((size-expr (getf param :size-expr))
        (rank (let ((n3 (third param-type))) (if (integerp n3) n3 1))))
    (if (and (%l0-scratch-symbolic-size-p size-expr) (= rank 1))
        (%l0-emit-symbolic-local-scratch-arg stream param-name param-type arg-index size-expr)
        (funcall *orig-l0-emit-local-scratch-tensor-arg*
                 stream param param-name param-type arg-index))))

;;; --- why zeKernelSetGroupSize is NOT phrased against these constants ---------
;;;
;;; TRIED AND REVERTED, recorded so it is not retried blind.  Rewriting the emitted line to
;;; `zeKernelSetGroupSize(kernel, wg_size_x, wg_size_y, 1)` would make the geometry block the
;;; single source of truth, which is the obvious next step and does work.  It also breaks NINE
;;; specs, because their STRATEGY-EXPECT directives pin that call's literal text:
;;;
;;;   089-strategy/10, /11, /12, /13, /15, /16-exact-tiled-oversubscribe, /16-local-with-derive,
;;;   /17   and   118-async-misc/10-tile-stride-metal
;;;
;;; That is not incidental test brittleness: 089-strategy exists precisely to pin the workgroup
;;; size each dispatch strategy chose, read off the launch call.  Moving the value into a
;;; constant relocates the observable those specs were written around, so the directives would
;;; have to be rewritten to assert the constant instead.  That is a deliberate change to what
;;; the suite pins, not a side effect of this endeavour, so it is left alone.
;;;
;;; CONSEQUENCE, stated plainly: the workgroup size appears TWICE in the generated launcher --
;;; once as wg_size_x/wg_size_y here, once as literals in zeKernelSetGroupSize.  A user who
;;; retunes one and not the other gets a scratch buffer sized for the old geometry.  The
;;; comment emitted in the geometry block names the other site so the edit is at least
;;; discoverable.  Closing the gap properly means updating those nine directives.
