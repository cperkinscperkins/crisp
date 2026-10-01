(in-package :crisp.hoist.l0)



;; src/hoist-l0/main.lisp  (new -- BUG 094 / endeavour 176 stage A; place just before
;;  %l0-emit-global-scratch-tensor-arg)
(defun %l0-emit-symbolic-global-scratch-arg (stream param-name param-type context-var device-var arg-index size-expr)
  "BUG 094.  Emit the 6 kernel arguments (3*rank+3 at rank 1) for a GLOBAL scratch VECTOR whose length
   is a SYMBOLIC size, phrasing every size as a C++ expression over the geometry constants -- the
   global counterpart of %l0-emit-symbolic-local-scratch-arg.  Argument ORDER matches
   %l0-emit-global-scratch-tensor-arg exactly: ptr, byte-size, offset[0], stride[0], extent[0], length.

   Allocation and zero-initialisation go through the same staged path as the literal-size case
   (%l0-emit-staged-alloc + a zeroed host mirror), with the element count as an expression; the
   staging copy is emitted later in the same function body, where <name>_elems is still in scope.

   Endeavour 176 needs this for grid-reduce-last-man!'s implicit :global-scratch-vec."
  (multiple-value-bind (count-expr phrase)
      (%l0-scratch-symbolic-expr size-expr param-name)
    (let* ((elem-type  (second param-type))
           (elem-str   (crisp-type-to-cpp-type elem-type))
           (elem-bytes (%elem-type-bytes elem-str))
           (cpp        (substitute #\_ #\- param-name))
           (ptr-var    (format nil "~a_ptr" cpp))
           (host-var   (format nil "~a_host" cpp))
           (elems-var  (format nil "~a_elems" cpp))
           (idx        arg-index))
      (format stream "~%    // GLOBAL scratch vector: ~a (rank=1, ~a, ~a)~%" param-name elem-str phrase)
      (format stream "    //   :size-expr ~a -- resolved as an EXPRESSION, not a literal, so it~%" size-expr)
      (format stream "    //   tracks the launch geometry above rather than freezing this build's value.~%")
      (format stream "    const uint64_t ~a = (uint64_t)~a;~%" elems-var count-expr)
      (%l0-emit-staged-alloc stream context-var device-var elem-str ptr-var host-var elems-var param-name)
      (format stream "    memset(~a, 0, ~a * sizeof(~a));  // scratch: zero-init (staged below)~%"
              host-var elems-var elem-str)
      ;; Arg N: global device pointer
      (format stream "    // Arg ~d: global scratch ptr~%" idx)
      (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(void*), &~a);~%" idx ptr-var)
      (incf idx)
      ;; Arg N+1: byte-size
      (format stream "    // Arg ~d: byte-size~%" idx)
      (format stream "    uint64_t ~a_byte_size = ~a * ~dULL;~%" cpp elems-var elem-bytes)
      (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_byte_size);~%" idx cpp)
      (incf idx)
      ;; Arg N+2: offset[0]
      (format stream "    // Arg ~d: offset[0] = 0~%" idx)
      (format stream "    uint64_t ~a_off0 = 0ULL;~%" cpp)
      (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_off0);~%" idx cpp)
      (incf idx)
      ;; Arg N+3: stride[0] -- 1 element, compact
      (format stream "    // Arg ~d: stride[0] = 1 (elements, compact)~%" idx)
      (format stream "    uint64_t ~a_str0 = 1ULL;~%" cpp)
      (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_str0);~%" idx cpp)
      (incf idx)
      ;; Arg N+4: extent[0]
      (format stream "    // Arg ~d: extent[0]~%" idx)
      (format stream "    uint64_t ~a_ext0 = ~a;~%" cpp elems-var)
      (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_ext0);~%" idx cpp)
      (incf idx)
      ;; Arg N+5: length
      (format stream "    // Arg ~d: length~%" idx)
      (format stream "    uint64_t ~a_length = ~a;~%" cpp elems-var)
      (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_length);~%~%" idx cpp)
      (incf idx)
      idx)))

;; src/hoist-l0/main.lisp  (only change: the rank-1 symbolic branch before the non-integer refusal)
(defun %l0-emit-global-scratch-tensor-arg (stream param param-name param-type context-var device-var arg-index)
  "Emit the 3N+3 kernel arguments for a GLOBAL scratch tensor (an implicit parameter).

   Endeavour 166: device memory plus a host staging mirror.  The zero-initialisation this
   path has always done now writes the MIRROR and is staged across, which is the part that
   fails silently if it is forgotten -- scratch is never printed, so a launcher whose scratch
   holds allocator garbage produces a wrong answer with nothing on stdout to say so.  That is
   what tests/spec/166-device-memory/03 exists to catch."
  (let* ((rank (let ((n3 (third param-type)))
                 (if (integerp n3) n3 1)))
         (size-expr (getf param :size-expr))
         (elem-type (second param-type))
         (elem-str (crisp-type-to-cpp-type elem-type))
         (elem-bytes (%elem-type-bytes elem-str))
         (param-name-cpp (substitute #\_ #\- param-name))
         (ptr-var (format nil "~a_ptr" param-name-cpp))
         (host-var (format nil "~a_host" param-name-cpp)))
    ;; BUG 094: a rank-1 SYMBOLIC size is phrased as a C++ expression over the geometry constants.
    (when (and (%l0-scratch-symbolic-size-p size-expr) (= rank 1))
      (return-from %l0-emit-global-scratch-tensor-arg
        (%l0-emit-symbolic-global-scratch-arg stream param-name param-type context-var device-var
                                              arg-index size-expr)))
    (unless (integerp size-expr)
      (error "Global scratch tensor ~a has non-integer :size-expr ~a. ~
              Only literal integer sizes are supported in the L0 hoist launcher."
        param-name size-expr))
    (multiple-value-bind (extents strides)
        (%tensor-compact-extents-strides rank (make-list rank :initial-element size-expr))
      (let* ((length (expt size-expr rank))
             (bytesize (* length elem-bytes))
             (current-idx arg-index))
        (format stream "~%    // GLOBAL scratch tensor: ~a (rank=~d, ~a, ~d elems, ~d bytes)~%"
          param-name rank elem-str length bytesize)
        (%l0-emit-staged-alloc stream context-var device-var elem-str
                               ptr-var host-var (format nil "~dULL" length) param-name)
        (format stream "    memset(~a, 0, ~dULL * sizeof(~a));  // scratch: zero-init (staged below)~%"
          host-var length elem-str)
        ;; Arg 0: global device pointer
        (format stream "    // Arg ~d: global scratch ptr~%" current-idx)
        (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(void*), &~a);~%"
          current-idx ptr-var)
        (incf current-idx)
        ;; Arg 1: byte-size
        (format stream "    // Arg ~d: byte-size = ~d~%" current-idx bytesize)
        (format stream "    uint64_t ~a_byte_size = ~dULL;~%" param-name-cpp bytesize)
        (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_byte_size);~%"
          current-idx param-name-cpp)
        (incf current-idx)
        ;; Offsets (all zero)
        (loop for k from 0 below rank do
                (format stream "    // Arg ~d: offset[~d] = 0~%" current-idx k)
                (format stream "    uint64_t ~a_off~d = 0ULL;~%" param-name-cpp k)
                (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_off~d);~%"
                  current-idx param-name-cpp k)
                (incf current-idx))
        ;; Strides (compact element strides)
        (loop for k from 0 below rank do
                (format stream "    // Arg ~d: stride[~d] = ~d (elements, compact)~%"
                  current-idx k (nth k strides))
                (format stream "    uint64_t ~a_str~d = ~dULL;~%" param-name-cpp k (nth k strides))
                (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_str~d);~%"
                  current-idx param-name-cpp k)
                (incf current-idx))
        ;; Extents
        (loop for k from 0 below rank do
                (format stream "    // Arg ~d: extent[~d] = ~d~%" current-idx k (nth k extents))
                (format stream "    uint64_t ~a_ext~d = ~dULL;~%" param-name-cpp k (nth k extents))
                (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_ext~d);~%"
                  current-idx param-name-cpp k)
                (incf current-idx))
        ;; Length
        (format stream "    // Arg ~d: length = ~d~%" current-idx length)
        (format stream "    uint64_t ~a_length = ~dULL;~%" param-name-cpp length)
        (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_length);~%~%"
          current-idx param-name-cpp)
        (incf current-idx)
        current-idx))))
