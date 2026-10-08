(in-package :crisp.hoist.l0)


;;;; ---------------------------------------------------------------------------------------
;;;; ENDEAVOUR 181 -- :match-num-workgroups global scratch (last-man's partials, one per workgroup).
;;;; The group count is only known once %l0-emit-dispatch has emitted `groupCount` (under :strided it
;;;; is computed at RUN TIME from the device), and zeKernelSetArgumentValue COPIES its value -- so the
;;;; buffer's whole block (alloc, zero, six set-args) is DEFERRED and emitted after the group count.
;;;;
;;;; FOLD NOTE: the two wrappers below capture the src definition (see the CUDA overlay's header for
;;;; why that shape cannot be pasted into src/).  Folding: the MATCH-NUM-WORKGROUPS branch goes into
;;;; %l0-emit-global-scratch-tensor-arg's symbolic branch, and generate-kernel-launch calls
;;;; %l0-emit-deferred-scratch right after %l0-emit-dispatch, binding *l0-deferred-scratch* around both.
;;;; ---------------------------------------------------------------------------------------

;; src/hoist-l0/main.lisp
(defvar *l0-deferred-scratch* '()
  "Endeavour 181.  C++ blocks (strings, newest first) for global scratch whose size is the group count,
   held back by the argument walk and written out by %l0-emit-deferred-scratch once %l0-emit-dispatch
   has declared `groupCount`.")

;; src/hoist-l0/main.lisp
(defun %l0-num-workgroups-size-p (size-expr)
  "T when SIZE-EXPR is the symbolic :match-num-workgroups."
  (and (keywordp size-expr) (string-equal (symbol-name size-expr) "MATCH-NUM-WORKGROUPS")))

;; src/hoist-l0/main.lisp
(defun %l0-deferred-global-scratch-block (param-name param-type context-var device-var arg-index)
  "Endeavour 181.  The C++ block (a string) that allocates a rank-1 GLOBAL scratch vector of one element
   per workgroup and binds its 6 kernel arguments (ptr, byte-size, offset[0], stride[0], extent[0],
   length -- %l0-emit-symbolic-global-scratch-arg's order).  It is emitted AFTER the group count, so it
   reads `groupCount` directly.  Zeroed once, as all global scratch is (endeavour 179's contract), by a
   memory fill on the main command list with a barrier before the launch that follows -- no staging
   mirror, because there is nothing to copy."
  (let* ((elem-str   (crisp-type-to-cpp-type (second param-type)))
         (elem-bytes (%elem-type-bytes elem-str))
         (cpp        (substitute #\_ #\- param-name))
         (idx        arg-index))
    (with-output-to-string (s)
      (format s "~%    // GLOBAL scratch vector: ~a (rank=1, ~a, one element per workgroup in the grid)~%" param-name elem-str)
      (format s "    //   :size-expr :match-num-workgroups -- allocated HERE, after the group count above,~%")
      (format s "    //   because under :strided that count is only known at run time.~%")
      (format s "    const uint64_t ~a_elems = (uint64_t)groupCount.groupCountX * groupCount.groupCountY * groupCount.groupCountZ;~%" cpp)
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

;; src/hoist-l0/main.lisp  (FOLD: becomes a branch of %l0-emit-global-scratch-tensor-arg)
(defvar *181-l0-symbolic-global-scratch-base* (fdefinition '%l0-emit-symbolic-global-scratch-arg))

;; src/hoist-l0/main.lisp
(defun %l0-emit-symbolic-global-scratch-arg (stream param-name param-type context-var device-var arg-index size-expr)
  "BUG 094 / endeavour 181.  A rank-1 GLOBAL scratch vector with a symbolic size.  :match-num-workgroups
   is DEFERRED (see %l0-deferred-global-scratch-block); every other symbolic size is emitted in place,
   phrased against the geometry constants.  Returns the next argument index either way."
  (cond
    ((%l0-num-workgroups-size-p size-expr)
     (format stream "~%    // GLOBAL scratch vector: ~a -- args ~d..~d are bound AFTER the group count (see below).~%"
             param-name arg-index (+ arg-index 5))
     (push (%l0-deferred-global-scratch-block param-name param-type context-var device-var arg-index)
           *l0-deferred-scratch*)
     (+ arg-index 6))
    (t (funcall *181-l0-symbolic-global-scratch-base*
                stream param-name param-type context-var device-var arg-index size-expr))))

;; src/hoist-l0/main.lisp
(defun %l0-emit-deferred-scratch (stream)
  "Endeavour 181.  Writes the held-back :match-num-workgroups scratch blocks, oldest first, and clears
   them.  Called right after %l0-emit-dispatch, which is where `groupCount` is declared."
  (when *l0-deferred-scratch*
    (format stream "~%    // ---- Scratch sized by the group count (endeavour 181) ----~%")
    (dolist (block (reverse *l0-deferred-scratch*))
      (write-string block stream))
    (setf *l0-deferred-scratch* '())))

;; src/hoist-l0/main.lisp  (FOLD: generate-kernel-launch calls %l0-emit-deferred-scratch after this)
(defvar *181-l0-emit-dispatch-base* (fdefinition '%l0-emit-dispatch))

;; src/hoist-l0/main.lisp
(defun %l0-emit-dispatch (stream global-decl local-decl num-groups-decl)
  "Emit zeKernelSetGroupSize and ze_group_count_t based on dispatch declarations, then (endeavour 181)
   the scratch blocks that had to wait for the group count."
  (funcall *181-l0-emit-dispatch-base* stream global-decl local-decl num-groups-decl)
  (%l0-emit-deferred-scratch stream))
