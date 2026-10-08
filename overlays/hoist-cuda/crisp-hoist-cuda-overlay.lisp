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

(in-package :crisp.hoist.cuda)

;;;; ---------------------------------------------------------------------------------------
;;;; ENDEAVOUR 181 -- :match-num-workgroups global scratch (last-man's partials, one per workgroup).
;;;; kernelParams[] holds ADDRESSES and cuLaunchKernel reads them at launch, so the buffer's host
;;;; variables are declared with the other arguments (zero for now) and filled -- alloc, zero, sizes --
;;;; immediately before the launch lambda, once gridX/gridY/gridZ are final (after the cluster fix-up).
;;;;
;;;; FOLD NOTE: the wrapper below captures the src definition (see this file's header).  Folding: the
;;;; MATCH-NUM-WORKGROUPS branch goes at the top of %cuda-emit-global-scratch-tensor-arg, and
;;;; emit-launch replaces its src definition outright (it calls %emit-launch-base by name).
;;;; ---------------------------------------------------------------------------------------

;; src/hoist-cuda/main.lisp
(defvar *cuda-deferred-scratch* '()
  "Endeavour 181.  C++ blocks (strings, newest first) that size and allocate :match-num-workgroups global
   scratch, held back by the argument walk and injected by emit-launch once the grid is final.")

;; src/hoist-cuda/main.lisp
(defun %cuda-num-workgroups-size-p (size-expr)
  "T when SIZE-EXPR is the symbolic :match-num-workgroups."
  (and (keywordp size-expr) (string-equal (symbol-name size-expr) "MATCH-NUM-WORKGROUPS")))

;; src/hoist-cuda/main.lisp  (FOLD: becomes the first branch of %cuda-emit-global-scratch-tensor-arg)
(defvar *181-cuda-global-scratch-base* (fdefinition '%cuda-emit-global-scratch-tensor-arg))

;; src/hoist-cuda/main.lisp
(defun %cuda-emit-global-scratch-tensor-arg (stream param param-name param-type arg-index)
  "A GLOBAL scratch tensor (an implicit parameter).  Endeavour 181: a rank-1 :match-num-workgroups vector
   is sized by the GRID, which the launcher may compute at run time, so its six host variables are only
   DECLARED here (kernelParams[] takes their addresses) and *cuda-deferred-scratch* gets the block that
   fills them before the launch.  Returns (values next-index arg-names) like the concrete path."
  (let ((rank (let ((n3 (third param-type))) (if (integerp n3) n3 1))))
    (if (not (and (%cuda-num-workgroups-size-p (getf param :size-expr)) (= rank 1)))
        (funcall *181-cuda-global-scratch-base* stream param param-name param-type arg-index)
        (let* ((elem-str   (crisp-type-to-cpp-type (second param-type)))
               (elem-bytes (%hoist-elem-type-bytes elem-str))
               (cpp        (substitute #\_ #\- param-name))
               (names      (list (format nil "~a_ptr" cpp)
                                 (format nil "~a_byte_size" cpp)
                                 (format nil "~a_off0" cpp)
                                 (format nil "~a_str0" cpp)
                                 (format nil "~a_ext0" cpp)
                                 (format nil "~a_length" cpp))))
          (format stream "~%    // GLOBAL scratch tensor: ~a (rank=1, ~a, one element per workgroup)~%" param-name elem-str)
          (format stream "    //   :size-expr :match-num-workgroups -- sized and allocated just before the launch,~%")
          (format stream "    //   once the grid is known; kernelParams[] reads these variables at launch time.~%")
          (format stream "    CUdeviceptr ~a_ptr = 0;~%" cpp)
          (format stream "    uint64_t ~a_byte_size = 0ULL;~%" cpp)
          (format stream "    uint64_t ~a_off0 = 0ULL;~%" cpp)
          (format stream "    uint64_t ~a_str0 = 1ULL;~%" cpp)
          (format stream "    uint64_t ~a_ext0 = 0ULL;~%" cpp)
          (format stream "    uint64_t ~a_length = 0ULL;~%" cpp)
          (push (with-output-to-string (s)
                  (format s "    // GLOBAL scratch ~a: one element per workgroup (:match-num-workgroups), zeroed once~%" param-name)
                  (format s "    ~a_length = (uint64_t)gridX * gridY * gridZ;~%" cpp)
                  (format s "    ~a_ext0 = ~a_length;~%" cpp cpp)
                  (format s "    ~a_byte_size = ~a_length * ~dULL;~%" cpp cpp elem-bytes)
                  (format s "    CUDA_CHECK(cuMemAlloc(&~a_ptr, ~a_byte_size));~%" cpp cpp)
                  (format s "    CUDA_CHECK(cuMemsetD8(~a_ptr, 0, ~a_byte_size));~%" cpp cpp))
                *cuda-deferred-scratch*)
          (values (+ arg-index 6) names)))))

;; src/hoist-cuda/main.lisp
(defun emit-launch (stream dispatch-info shared-bytes &optional compute-units kernel-name out-tile)
  "Endeavor 152: renders %emit-launch-base to a string and injects the
   cluster grid reconciliation immediately BEFORE the launch lambda -- i.e. after every strategy
   has finished computing gridX/gridY/gridZ and after the device-limit clamping, so the
   reconciliation is the last word on the grid.

   Endeavour 181: the :match-num-workgroups scratch blocks (*cuda-deferred-scratch*) are injected at the
   same anchor, AFTER the fix-up, so they size from the grid that is actually launched."
  (let* ((body (with-output-to-string (s)
                 (%emit-launch-base s dispatch-info shared-bytes compute-units kernel-name out-tile)))
         (fixup (%cuda-cluster-grid-fixup-string dispatch-info))
         (scratch (format nil "~{~a~}" (reverse *cuda-deferred-scratch*)))
         (inject (concatenate 'string fixup scratch)))
    (setf *cuda-deferred-scratch* '())
    (if (string= inject "")
        (write-string body stream)
        ;; Anchor: the launch lambda, emitted exactly once by every path.  If it ever moves we
        ;; must NOT silently drop the injection -- a clustered kernel would launch with an
        ;; unreconciled grid, and a :match-num-workgroups buffer would never be allocated.
        (let ((pos (search "auto _crisp_launch" body)))
          (cond
            ((and (null pos) (string/= scratch ""))
             ;; An unallocated buffer is a crash on the device, not a degraded launch -- refuse.
             (error "Endeavour 181: could not find the _crisp_launch anchor in emit-launch output for kernel ~a, so its :match-num-workgroups scratch cannot be allocated."
                    kernel-name))
            ((null pos)
             (warn "Endeavor 152: could not find the _crisp_launch anchor in emit-launch output for kernel ~a; cluster grid reconciliation NOT emitted."
                   kernel-name)
             (write-string body stream))
            (t
             ;; Back up to the start of that line so the injected block is not spliced into it.
             (let ((line-start (let ((nl (position #\Newline body :end pos :from-end t)))
                                 (if nl (1+ nl) 0))))
               (write-string body stream :end line-start)
               (write-string inject stream)
               (write-string body stream :start line-start))))))))
