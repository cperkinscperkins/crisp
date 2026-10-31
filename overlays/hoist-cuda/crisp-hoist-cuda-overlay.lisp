;;;; overlays/hoist-cuda/crisp-hoist-cuda-overlay.lisp
;;;;
;;;; Runtime patches for the CUDA hoister.  Applied via late binding -- last definition wins.
;;;;
;;;; NOTE THE SHAPE CONSTRAINT, learned when this file was last emptied (2026-08-26): a
;;;; late-binding wrapper that captures (fdefinition 'f) into a defvar and then redefines f
;;;; CANNOT be pasted into src/ as-is, because there the capture would grab the function being
;;;; replaced and recurse forever.  Folding one back means splitting it into a base plus a
;;;; wrapper that calls the base BY NAME, as emit-launch / %emit-launch-base already are.
;;;;
;;;; EMPTY AGAIN as of 2026-09-22.  Endeavour 175 (symbolic scratch sizes, CUDA side) folded
;;;; into src/hoist-cuda/main.lisp:
;;;;   emit-main               -- split per the constraint above into %emit-main-base plus a
;;;;                             wrapper that binds *cuda-wg-size* and calls the base by name
;;;;   %cuda-scratch-dims     -- symbolic branch is now its first cond clause
;;;;   %cuda-local-param-bytes-- symbolic clause added to its inner count cond, so the sizer
;;;;                             and the emitters still resolve the size the same way

;;;;
;;;; EMPTY AGAIN as of 2026-10-08.  Endeavour 181 (:match-num-workgroups scratch) folded into
;;;; src/hoist-cuda/main.lisp: *cuda-deferred-scratch*, %cuda-num-workgroups-size-p,
;;;; %cuda-emit-num-workgroups-scratch-arg (the wrapper's branch, now a named function that
;;;; %cuda-emit-global-scratch-tensor-arg returns early into), and emit-launch (injects the
;;;; deferred blocks at the _crisp_launch anchor, after the cluster fix-up).
;;;; EMPTY as of 2026-10-25 -- endeavour 193 folded: %193-cuda-emit-die-report / -log-report, the site tables
;;;; bound in generate-cuda-launcher and reported at the top of emit-readback (src/hoist-cuda/main.lisp);
;;;; the shared helpers into src/hoist/common.lisp.
(in-package :crisp.hoist.cuda)

;;;; ---------------------------------------------------------------------------------------------
;;;; Endeavour 201 -- :match-global-size global scratch (one element per THREAD in the grid:
;;;; workgroups x workgroup size), the look-back-scan's status words.  Deferred to the launch anchor
;;;; exactly like 181's :match-num-workgroups; the workgroup size is the DECLARED one (*cuda-wg-size*),
;;;; which is also what the launch uses for its block dimensions.
;;;; FOLD: give %cuda-emit-num-workgroups-scratch-arg a SIZE-EXPR parameter and pass it from
;;;; %cuda-emit-global-scratch-tensor-arg; drop *201-scratch-size-expr* and the wrapper.
;;;; ---------------------------------------------------------------------------------------------

;; src/hoist-cuda/main.lisp
(defvar *201-scratch-size-expr* nil
  "Endeavour 201 (overlay only).  The :size-expr of the global scratch tensor being emitted, bound by
   the %cuda-emit-global-scratch-tensor-arg wrapper so %cuda-emit-num-workgroups-scratch-arg can tell
   :match-global-size from :match-num-workgroups without a signature change.")

;; src/hoist-cuda/main.lisp
(defun %cuda-global-size-size-p (size-expr)
  "Endeavour 201.  T when SIZE-EXPR is the symbolic :match-global-size (one element per thread in the
   grid)."
  (and (keywordp size-expr) (string-equal (symbol-name size-expr) "MATCH-GLOBAL-SIZE")))

;; src/hoist-cuda/main.lisp
(defun %cuda-num-workgroups-size-p (size-expr)
  "T when SIZE-EXPR is sized by the grid: the symbolic :match-num-workgroups (181) or :match-global-size
   (201, the grid times the declared workgroup size).  Both are deferred to the launch anchor."
  (and (keywordp size-expr)
       (or (string-equal (symbol-name size-expr) "MATCH-NUM-WORKGROUPS")
           (%cuda-global-size-size-p size-expr))))

;; src/hoist-cuda/main.lisp
(defvar *201-orig-cuda-emit-global-scratch-tensor-arg* (fdefinition '%cuda-emit-global-scratch-tensor-arg))
(defun %cuda-emit-global-scratch-tensor-arg (stream param param-name param-type arg-index)
  "Endeavour 201 wrapper (overlay only): binds *201-scratch-size-expr* to PARAM's :size-expr around the
   original emitter.  FOLD: see the section header."
  (let ((*201-scratch-size-expr* (getf param :size-expr)))
    (funcall *201-orig-cuda-emit-global-scratch-tensor-arg* stream param param-name param-type arg-index)))

;; src/hoist-cuda/main.lisp
(defun %cuda-emit-num-workgroups-scratch-arg (stream param-name param-type arg-index)
  "Endeavour 181.  A rank-1 GLOBAL scratch vector of :size-expr :match-num-workgroups -- one element per
   workgroup -- is sized by the GRID, which the launcher may compute at run time.  kernelParams[] holds
   ADDRESSES and cuLaunchKernel reads them at launch, so the six host variables are only DECLARED here and
   *cuda-deferred-scratch* gets the block that sizes, allocates and zeroes the buffer; emit-launch injects
   it before the launch lambda.  Returns (values next-index arg-names) like the concrete path.

   Endeavour 201: under :match-global-size (*201-scratch-size-expr*) the length is the grid times the
   DECLARED workgroup size, baked in as a number -- the launch's block dimensions are baked the same way."
  (let* ((elem-str   (crisp-type-to-cpp-type (second param-type)))
         (elem-bytes (%hoist-elem-type-bytes elem-str))
         (cpp        (substitute #\_ #\- param-name))
         (per-thread (%cuda-global-size-size-p *201-scratch-size-expr*))
         (wg         (when per-thread
                       (or *cuda-wg-size*
                           (error "Scratch tensor ~a: :size-expr :match-global-size (one element per thread in the grid) needs the workgroup size, but this kernel declares no compile-time (local-size :set-to N)."
                                  param-name))))
         (what       (if per-thread "thread" "workgroup"))
         (size-kw    (if per-thread ":match-global-size" ":match-num-workgroups"))
         (names      (list (format nil "~a_ptr" cpp)
                           (format nil "~a_byte_size" cpp)
                           (format nil "~a_off0" cpp)
                           (format nil "~a_str0" cpp)
                           (format nil "~a_ext0" cpp)
                           (format nil "~a_length" cpp))))
    (format stream "~%    // GLOBAL scratch tensor: ~a (rank=1, ~a, one element per ~a)~%" param-name elem-str what)
    (format stream "    //   :size-expr ~a -- sized and allocated just before the launch,~%" size-kw)
    (format stream "    //   once the grid is known; kernelParams[] reads these variables at launch time.~%")
    (format stream "    CUdeviceptr ~a_ptr = 0;~%" cpp)
    (format stream "    uint64_t ~a_byte_size = 0ULL;~%" cpp)
    (format stream "    uint64_t ~a_off0 = 0ULL;~%" cpp)
    (format stream "    uint64_t ~a_str0 = 1ULL;~%" cpp)
    (format stream "    uint64_t ~a_ext0 = 0ULL;~%" cpp)
    (format stream "    uint64_t ~a_length = 0ULL;~%" cpp)
    (push (with-output-to-string (s)
            (format s "    // GLOBAL scratch ~a: one element per ~a (~a), zeroed once~%" param-name what size-kw)
            (if per-thread
                (format s "    ~a_length = (uint64_t)gridX * gridY * gridZ * ~dULL;~%" cpp wg)
                (format s "    ~a_length = (uint64_t)gridX * gridY * gridZ;~%" cpp))
            (format s "    ~a_ext0 = ~a_length;~%" cpp cpp)
            (format s "    ~a_byte_size = ~a_length * ~dULL;~%" cpp cpp elem-bytes)
            (format s "    CUDA_CHECK(cuMemAlloc(&~a_ptr, ~a_byte_size));~%" cpp cpp)
            (format s "    CUDA_CHECK(cuMemsetD8(~a_ptr, 0, ~a_byte_size));~%" cpp cpp))
          *cuda-deferred-scratch*)
    (values (+ arg-index 6) names)))
