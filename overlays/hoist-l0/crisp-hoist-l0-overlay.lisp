;;;; EMPTY as of 2026-10-25 -- endeavour 193 folded: the shared report helpers into src/hoist/common.lisp
;;;; (exported from crisp.hoist); %193-l0-emit-die-report / -log-report, and the site tables bound in
;;;; generate-l0-launcher and reported at the end of generate-kernel-launch (src/hoist-l0/main.lisp).
(in-package :crisp.hoist.l0)

;;;; ---------------------------------------------------------------------------------------------
;;;; Endeavour 201 -- :match-global-size global scratch (one element per THREAD in the grid:
;;;; workgroups x workgroup size), the look-back-scan's status words.  Deferred past the group count
;;;; exactly like 181's :match-num-workgroups, with the element count multiplied by wg_size.
;;;; FOLD: give %l0-deferred-global-scratch-block a SIZE-EXPR parameter and pass it from
;;;; %l0-emit-global-scratch-tensor-arg; drop *201-scratch-size-expr* and the wrapper.
;;;; ---------------------------------------------------------------------------------------------

;; src/hoist-l0/main.lisp
(defvar *201-scratch-size-expr* nil
  "Endeavour 201 (overlay only).  The :size-expr of the global scratch tensor being emitted, bound by
   the %l0-emit-global-scratch-tensor-arg wrapper so %l0-deferred-global-scratch-block can tell
   :match-global-size from :match-num-workgroups without a signature change.")

;; src/hoist-l0/main.lisp
(defun %l0-global-size-size-p (size-expr)
  "Endeavour 201.  T when SIZE-EXPR is the symbolic :match-global-size (one element per thread in the
   grid)."
  (and (keywordp size-expr) (string-equal (symbol-name size-expr) "MATCH-GLOBAL-SIZE")))

;; src/hoist-l0/main.lisp
(defun %l0-num-workgroups-size-p (size-expr)
  "T when SIZE-EXPR is sized by the group count: the symbolic :match-num-workgroups (181) or
   :match-global-size (201, the group count times wg_size).  Both are only known once the dispatch has
   declared `groupCount`, so both are deferred."
  (and (keywordp size-expr)
       (or (string-equal (symbol-name size-expr) "MATCH-NUM-WORKGROUPS")
           (%l0-global-size-size-p size-expr))))

;; src/hoist-l0/main.lisp
(defvar *201-orig-l0-emit-global-scratch-tensor-arg* (fdefinition '%l0-emit-global-scratch-tensor-arg))
(defun %l0-emit-global-scratch-tensor-arg (stream param param-name param-type context-var device-var arg-index)
  "Endeavour 201 wrapper (overlay only): binds *201-scratch-size-expr* to PARAM's :size-expr around the
   original emitter.  FOLD: see the section header."
  (let ((*201-scratch-size-expr* (getf param :size-expr)))
    (funcall *201-orig-l0-emit-global-scratch-tensor-arg*
             stream param param-name param-type context-var device-var arg-index)))

;; src/hoist-l0/main.lisp

(defun %l0-deferred-global-scratch-block (param-name param-type context-var device-var arg-index)
  "Endeavour 181.  The C++ block (a string) that allocates a rank-1 GLOBAL scratch vector of one element
   per workgroup and binds its 6 kernel arguments (ptr, byte-size, offset[0], stride[0], extent[0],
   length -- %l0-emit-symbolic-global-scratch-arg's order).  It is emitted AFTER the group count, so it
   reads `groupCount` directly.  Zeroed once, as all global scratch is (endeavour 179's contract), by a
   memory fill on the main command list with a barrier before the launch that follows -- no staging
   mirror, because there is nothing to copy.

   Endeavour 201: under :match-global-size (*201-scratch-size-expr*) the count is the group count times
   wg_size -- one element per thread in the grid."
  (let* ((elem-str   (crisp-type-to-cpp-type (second param-type)))
         (elem-bytes (%elem-type-bytes elem-str))
         (cpp        (substitute #\_ #\- param-name))
         (idx        arg-index)
         (per-thread (%l0-global-size-size-p *201-scratch-size-expr*)))
    ;; No log4cl here: crisp-hoist-l0 is a standalone app that does not load it.
    (with-output-to-string (s)
      (format s "~%    // GLOBAL scratch vector: ~a (rank=1, ~a, one element per ~a in the grid)~%"
              param-name elem-str (if per-thread "thread" "workgroup"))
      (format s "    //   :size-expr ~a -- allocated HERE, after the group count above,~%"
              (if per-thread ":match-global-size" ":match-num-workgroups"))
      (format s "    //   because under :strided that count is only known at run time.~%")
      (format s "    const uint64_t ~a_elems = (uint64_t)groupCount.groupCountX * groupCount.groupCountY * groupCount.groupCountZ~a;~%"
              cpp (if per-thread " * wg_size" ""))
      (format s "    ~a* ~a_ptr = nullptr;~%" elem-str cpp)
      (format s "    result = zeMemAllocDevice(~a, &deviceDesc,~%" context-var)
      (format s "        ~a_elems * sizeof(~a), 1, ~a, (void**)&~a_ptr);~%" cpp elem-str device-var cpp)
      (format s "    if (result != ZE_RESULT_SUCCESS) {~%")
      (format s "        std::cerr << \"ERROR: zeMemAllocDevice failed for ~a\" << std::endl;~%" param-name)
      (format s "        return 1;~%")
      (format s "    }~%")
      (format s "    static const uint8_t ~a_zero = 0;   // scratch: zero-init once, ahead of the launch~%" cpp)
      (format s "    zeCommandListAppendMemoryFill(cmdList, ~a_ptr, &~a_zero, 1, ~a_elems * sizeof(~a), nullptr, 0, nullptr);~%"
              cpp cpp cpp elem-str)
      (format s "    zeCommandListAppendBarrier(cmdList, nullptr, 0, nullptr);~%")
      (format s "    // Arg ~d: global scratch ptr~%" idx)
      (format s "    zeKernelSetArgumentValue(kernel, ~d, sizeof(void*), &~a_ptr);~%" idx cpp)
      (incf idx)
      (format s "    // Arg ~d: byte-size~%" idx)
      (format s "    uint64_t ~a_byte_size = ~a_elems * ~dULL;~%" cpp cpp elem-bytes)
      (format s "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_byte_size);~%" idx cpp)
      (incf idx)
      (format s "    // Arg ~d: offset[0] = 0~%" idx)
      (format s "    uint64_t ~a_off0 = 0ULL;~%" cpp)
      (format s "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_off0);~%" idx cpp)
      (incf idx)
      (format s "    // Arg ~d: stride[0] = 1 (elements, compact)~%" idx)
      (format s "    uint64_t ~a_str0 = 1ULL;~%" cpp)
      (format s "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_str0);~%" idx cpp)
      (incf idx)
      (format s "    // Arg ~d: extent[0]~%" idx)
      (format s "    uint64_t ~a_ext0 = ~a_elems;~%" cpp cpp)
      (format s "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_ext0);~%" idx cpp)
      (incf idx)
      (format s "    // Arg ~d: length~%" idx)
      (format s "    uint64_t ~a_length = ~a_elems;~%" cpp cpp)
      (format s "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_length);~%~%" idx cpp))))
