(in-package :crisp.hoist.l0)


;;; ===================================================================
;;; Endeavour 162 completion — the last naive width site in the L0 hoist.
;;;
;;; The Intel hoist already HAS the correct table, %elem-type-bytes (8/4/2/1), and its SLM emitter
;;; already uses it -- which is why BMG's bf16 results were never affected.  Only the GLOBAL
;;; scratch emitter still carried the inline "everything not 64-bit is 4 bytes" rule, so a 16-bit
;;; global scratch was allocated at `length * sizeof(elem)` (correct) and described to the kernel
;;; as `length * 4` (twice the truth).  Same divergence-within-one-function as the CUDA pair.
;;;
;;; Reproduced verbatim from src/hoist-l0/main.lisp with one expression replaced, round-trip
;;; verified against the original.
;;; ===================================================================

;; src/hoist-l0/main.lisp
(defun %l0-emit-global-scratch-tensor-arg (stream param param-name param-type context-var device-var arg-index)
  (let* ((rank (let ((n3 (third param-type)))
                 (if (integerp n3) n3 1)))
         (size-expr (getf param :size-expr))
         (elem-type (second param-type))
         (elem-str (crisp-type-to-cpp-type elem-type))
         (elem-bytes (%elem-type-bytes elem-str))
         (param-name-cpp (substitute #\_ #\- param-name))
         (ptr-var (format nil "~a_ptr" param-name-cpp)))
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
        ;; Allocate USM shared memory, zero-initialized
        (format stream "    ~a* ~a = nullptr;~%" elem-str ptr-var)
        (format stream "    result = zeMemAllocShared(~a, &deviceDesc, &hostDesc,~%"
          context-var)
        (format stream "        ~dULL * sizeof(~a), 1, ~a, (void**)&~a);~%"
          length elem-str device-var ptr-var)
        (format stream "    if (result != ZE_RESULT_SUCCESS) {~%")
        (format stream "        std::cerr << \"ERROR: zeMemAllocShared failed for ~a\" << std::endl;~%"
          param-name)
        (format stream "        return 1;~%")
        (format stream "    }~%")
        (format stream "    memset(~a, 0, ~dULL * sizeof(~a));  // scratch: zero-init~%"
          ptr-var length elem-str)
        ;; Arg 0: global USM pointer
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
