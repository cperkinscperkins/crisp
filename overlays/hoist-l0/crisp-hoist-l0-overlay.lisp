(in-package :crisp.hoist.l0)

;; Overlay file for crisp-hoist-l0
;; Add late-binding fixes here as needed


;;; =========================================================
;;; Scratch tensor hoist: local memory support
;;; =========================================================
;;
;; src/hoist-l0/main.lisp
;;
;; Redefines generate-kernel-arguments-with-usm to add a new branch for
;; implicit scratch tensors with :address-space :local.  These are allocated
;; as L0 local (workgroup-shared) memory rather than USM:
;;
;;   zeKernelSetArgumentValue(kernel, N, BYTE_SIZE, nullptr)  ; local alloc
;;
;; The remaining args (byte-size, offsets, strides, extents, length) are
;; scalar uint64_t values computed from :size-expr and the element type.
;;
;; The scratch tensor is NOT pushed to allocations (no copyback or BUFFER
;; printout — it is local memory, not accessible from the host).
;;
;; Convention: strides in ELEMENTS (consistent with existing USM tensor branch).
;;   stride[0]=1 (innermost), stride[k] = size-expr^k  for compact layout.
;; Bytesize = size-expr^N * sizeof(elem).

(defun generate-kernel-arguments-with-usm (stream declared-sig aliases records context-var device-var)
  "Generate kernel argument setup code with USM allocation for cells/tensors.
   Handles:
     cell                   — 3 args (ptr, byte-size, offset)
     local scratch tensor   — 3N+3 args; ptr as nullptr local alloc (NEW)
     tensor/vector/matrix   — 3N+3 args; USM allocation
     def-struct             — 1 arg (aggregate by value, sizeof struct)
     def-record             — exploded scalar args
     (array T N)            — 1 arg, passed by value (iota-initialized T[N])
     scalar/dvec            — 1 arg"
  (format stream "    // Set up kernel arguments~%")
  (format stream "    ze_device_mem_alloc_desc_t deviceDesc = { ZE_STRUCTURE_TYPE_DEVICE_MEM_ALLOC_DESC };~%")
  (format stream "    ze_host_mem_alloc_desc_t hostDesc = { ZE_STRUCTURE_TYPE_HOST_MEM_ALLOC_DESC };~%~%")

  (let ((arg-index  0)
        (allocations '()))

    (dolist (param declared-sig)
      (let* ((param-name  (getf param :name))
             (raw-type    (getf param :type))
             (param-type  (resolve-type-alias raw-type aliases))
             (param-dir   (getf param :direction))
             (param-as    (getf param :address-space))
             (is-local    (member param-as '(:local "LOCAL" local) :test #'string-equal)))

        (cond

         ;; ---- cell parameters (3 kernel args: ptr, byte-size, offset) ----
         ((cell-type-p param-type)
          (let* ((base-type      (cell-base-type param-type))
                 (is-array-cell  (%array-type-p base-type))
                 (base-type-str  (if is-array-cell
                                     (crisp-type-to-cpp-type (%array-element-type base-type))
                                     (crisp-type-to-cpp-type base-type)))
                 (elem-count     (if is-array-cell (%array-size base-type) 1))
                 (param-name-cpp (substitute #\_ #\- param-name))
                 (size-var       (format nil "~a_size" param-name-cpp))
                 (ptr-var        (format nil "~a_ptr"  param-name-cpp)))

            (if is-local
                ;; --- LOCAL MEMORY ---
                (progn
                 (format stream "~%    // Configure LOCAL memory for ~a~%" param-name)
                 (format stream "    size_t ~a = ~a;  // ~a~%"
                   size-var elem-count
                   (if is-array-cell "Array cell: N elements" "Cell is a single scalar"))
                 (format stream "    uint64_t ~a_bytes = ~a * sizeof(~a);~%" size-var size-var base-type-str)
                 (format stream "    uint64_t ~a_offset = 0;~%" param-name-cpp)
                 (format stream "    // Arg ~d: Local Pointer (Size=~a)~%" arg-index size-var)
                 (format stream "    zeKernelSetArgumentValue(kernel, ~d, ~a_bytes, nullptr);~%"
                   arg-index size-var)
                 (format stream "    // Arg ~d: Size (bytes)~%" (+ arg-index 1))
                 (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_bytes);~%"
                   (+ arg-index 1) size-var)
                 (format stream "    // Arg ~d: Offset (bytes)~%" (+ arg-index 2))
                 (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_offset);~%~%"
                   (+ arg-index 2) param-name-cpp))

                ;; --- GLOBAL MEMORY (USM) ---
                (progn
                 (format stream "~%    // Allocate USM memory for ~a~%" param-name)
                 (format stream "    size_t ~a = ~a;  // ~a~%"
                   size-var elem-count
                   (if is-array-cell "Array cell: N elements" "Cell is a single scalar"))
                 (format stream "    ~a* ~a = nullptr;~%" base-type-str ptr-var)
                 (format stream "    result = zeMemAllocShared(~a, &deviceDesc, &hostDesc,~%"
                   context-var)
                 (format stream "        ~a * sizeof(~a), 1, ~a, (void**)&~a);~%"
                   size-var base-type-str device-var ptr-var)
                 (format stream "    if (result != ZE_RESULT_SUCCESS) {~%")
                 (format stream "        std::cerr << \"ERROR: zeMemAllocShared failed for ~a\" << std::endl;~%"
                   param-name)
                 (format stream "        return 1;~%")
                 (format stream "    }~%")
                 (format stream "    // Initialize data~%")
                 (if is-array-cell
                     (format stream "    for (size_t _i = 0; _i < ~a; _i++) ~a[_i] = (~a)_i;~%"
                       size-var ptr-var base-type-str)
                     (format stream "    memset(~a, 0, ~a * sizeof(~a));~%" ptr-var size-var base-type-str))
                 (format stream "    // Arg ~d: Base Pointer~%" arg-index)
                 (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(void*), &~a);~%"
                   arg-index ptr-var)
                 (format stream "    // Arg ~d: Size (bytes)~%" (+ arg-index 1))
                 (format stream "    uint64_t ~a_bytes = ~a * sizeof(~a);~%" size-var size-var base-type-str)
                 (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_bytes);~%"
                   (+ arg-index 1) size-var)
                 (format stream "    // Arg ~d: Offset (bytes)~%" (+ arg-index 2))
                 (format stream "    uint64_t ~a_offset = 0;~%" param-name-cpp)
                 (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_offset);~%~%"
                   (+ arg-index 2) param-name-cpp)
                 (push (list :name     param-name
                             :ptr      ptr-var
                             :size-var size-var
                             :direction param-dir
                             :access   (getf param :access))
                       allocations)))

            (incf arg-index 3)))

         ;; ---- LOCAL scratch tensor (implicit side-channel, :address-space :local) ----
         ;; Arg 0:   zeKernelSetArgumentValue(kernel, N, BYTESIZE, nullptr)  -- local alloc
         ;; Args 1+: bytesize, offsets[0..rank-1], strides[0..rank-1], extents[0..rank-1], length
         ;; NOT pushed to allocations — local memory, no host copyback.
         ((and (tensor-type-p param-type) is-local)
          (let* ((rank        (let ((n3 (third param-type)))
                                (if (integerp n3) n3 1)))
                 (size-expr   (getf param :size-expr))
                 (elem-type   (second param-type))
                 (elem-str    (crisp-type-to-cpp-type elem-type))
                 (elem-bytes  (if (or (string-equal elem-str "double")
                                      (string-equal elem-str "int64_t")
                                      (string-equal elem-str "uint64_t")) 8 4))
                 (param-name-cpp (substitute #\_ #\- param-name)))

            (unless (integerp size-expr)
              (error "Local scratch tensor ~a has non-integer :size-expr ~a. ~
                      Only literal integer sizes are supported in the L0 hoist launcher."
                     param-name size-expr))

            ;; Compact strides in elements: stride[0]=1, stride[k]=size-expr^k
            ;; Extents: all = size-expr.  Length = size-expr^N.  Bytesize = length * elem-bytes.
            (multiple-value-bind (extents strides)
                (%tensor-compact-extents-strides rank size-expr)
              (let* ((length    (* (expt size-expr rank)))
                     (bytesize  (* length elem-bytes))
                     (offsets   (make-list rank :initial-element 0)))

                (format stream "~%    // LOCAL scratch tensor: ~a (rank=~d, ~a, ~d elems, ~d bytes)~%"
                        param-name rank elem-str length bytesize)

                ;; Arg N: local memory allocation — nullptr + bytesize
                (format stream "    // Arg ~d: local ptr (~d bytes of workgroup-local memory)~%"
                        arg-index bytesize)
                (format stream "    zeKernelSetArgumentValue(kernel, ~d, ~dULL, nullptr);~%"
                        arg-index bytesize)
                (incf arg-index)

                ;; Arg N+1: byte-size
                (format stream "    // Arg ~d: byte-size = ~d~%" arg-index bytesize)
                (format stream "    uint64_t ~a_byte_size = ~dULL;~%" param-name-cpp bytesize)
                (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_byte_size);~%"
                        arg-index param-name-cpp)
                (incf arg-index)

                ;; Args N+2 .. N+1+rank: offsets (all zero)
                (loop for k from 0 below rank do
                  (format stream "    // Arg ~d: offset[~d] = 0~%" arg-index k)
                  (format stream "    uint64_t ~a_off~d = 0ULL;~%" param-name-cpp k)
                  (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_off~d);~%"
                          arg-index param-name-cpp k)
                  (incf arg-index))

                ;; Args N+2+rank .. N+1+2*rank: strides (compact element strides)
                (loop for k from 0 below rank do
                  (format stream "    // Arg ~d: stride[~d] = ~d (elements, compact)~%"
                          arg-index k (nth k strides))
                  (format stream "    uint64_t ~a_str~d = ~dULL;~%" param-name-cpp k (nth k strides))
                  (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_str~d);~%"
                          arg-index param-name-cpp k)
                  (incf arg-index))

                ;; Args N+2+2*rank .. N+1+3*rank: extents
                (loop for k from 0 below rank do
                  (format stream "    // Arg ~d: extent[~d] = ~d~%" arg-index k (nth k extents))
                  (format stream "    uint64_t ~a_ext~d = ~dULL;~%" param-name-cpp k (nth k extents))
                  (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_ext~d);~%"
                          arg-index param-name-cpp k)
                  (incf arg-index))

                ;; Last arg: length
                (format stream "    // Arg ~d: length = ~d~%" arg-index length)
                (format stream "    uint64_t ~a_length = ~dULL;~%" param-name-cpp length)
                (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_length);~%~%"
                        arg-index param-name-cpp)
                (incf arg-index)

                ;; No copyback — local memory is not host-accessible.
                ))))

         ;; ---- GLOBAL scratch tensor (implicit side-channel, :address-space :global) ----
         ;; Identified by: tensor type + NOT local + :size-expr present in metadata.
         ;; Allocates USM shared memory, zero-initializes (scratch semantics: unknown initial state).
         ;; NOT pushed to allocations — scratch storage, not a user-declared output buffer.
         ;; No BUFFER printout — the test validates via the explicit out param, not the scratch.
         ((and (tensor-type-p param-type) (not is-local) (getf param :size-expr))
          (let* ((rank        (let ((n3 (third param-type)))
                                (if (integerp n3) n3 1)))
                 (size-expr   (getf param :size-expr))
                 (elem-type   (second param-type))
                 (elem-str    (crisp-type-to-cpp-type elem-type))
                 (elem-bytes  (if (or (string-equal elem-str "double")
                                     (string-equal elem-str "int64_t")
                                     (string-equal elem-str "uint64_t")) 8 4))
                 (param-name-cpp (substitute #\_ #\- param-name))
                 (ptr-var     (format nil "~a_ptr" param-name-cpp)))

            (unless (integerp size-expr)
              (error "Global scratch tensor ~a has non-integer :size-expr ~a. ~
                      Only literal integer sizes are supported in the L0 hoist launcher."
                     param-name size-expr))

            (multiple-value-bind (extents strides)
                (%tensor-compact-extents-strides rank size-expr)
              (let* ((length    (expt size-expr rank))
                     (bytesize  (* length elem-bytes))
                     (offsets   (make-list rank :initial-element 0)))

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
                (format stream "    // Arg ~d: global scratch ptr~%" arg-index)
                (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(void*), &~a);~%"
                        arg-index ptr-var)
                (incf arg-index)

                ;; Arg 1: byte-size
                (format stream "    // Arg ~d: byte-size = ~d~%" arg-index bytesize)
                (format stream "    uint64_t ~a_byte_size = ~dULL;~%" param-name-cpp bytesize)
                (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_byte_size);~%"
                        arg-index param-name-cpp)
                (incf arg-index)

                ;; Offsets (all zero)
                (loop for k from 0 below rank do
                  (format stream "    // Arg ~d: offset[~d] = 0~%" arg-index k)
                  (format stream "    uint64_t ~a_off~d = 0ULL;~%" param-name-cpp k)
                  (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_off~d);~%"
                          arg-index param-name-cpp k)
                  (incf arg-index))

                ;; Strides (compact element strides)
                (loop for k from 0 below rank do
                  (format stream "    // Arg ~d: stride[~d] = ~d (elements, compact)~%"
                          arg-index k (nth k strides))
                  (format stream "    uint64_t ~a_str~d = ~dULL;~%" param-name-cpp k (nth k strides))
                  (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_str~d);~%"
                          arg-index param-name-cpp k)
                  (incf arg-index))

                ;; Extents
                (loop for k from 0 below rank do
                  (format stream "    // Arg ~d: extent[~d] = ~d~%" arg-index k (nth k extents))
                  (format stream "    uint64_t ~a_ext~d = ~dULL;~%" param-name-cpp k (nth k extents))
                  (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_ext~d);~%"
                          arg-index param-name-cpp k)
                  (incf arg-index))

                ;; Length
                (format stream "    // Arg ~d: length = ~d~%" arg-index length)
                (format stream "    uint64_t ~a_length = ~dULL;~%" param-name-cpp length)
                (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_length);~%~%"
                        arg-index param-name-cpp)
                (incf arg-index)

                ;; No allocations push — scratch tensor is not a user-facing output buffer.
                ;; (memory is leaked in the harness; acceptable for test programs)
                ))))

         ;; ---- tensor/vector/matrix parameters (3N+3 kernel args, global USM) ----
         ((tensor-type-p param-type)
          (let* ((rank        (or (getf param :rank)
                                  (let ((n3 (third param-type)))
                                    (if (integerp n3) n3 1))))
                 (elem-type   (second param-type))
                 (align       (getf param :align))
                 (elem-str    (crisp-type-to-cpp-type elem-type))
                 (dim-extent  4)  ; test harness: 4 elements per dimension
                 (param-name-cpp (substitute #\_ #\- param-name))
                 (ptr-var     (format nil "~a_ptr" param-name-cpp))
                 (size-var    (format nil "~a_len" param-name-cpp)))

            (multiple-value-bind (extents strides)
                (%tensor-compact-extents-strides rank dim-extent)
              (let* ((total-elems (* (first strides) (first extents)))
                     (offsets     (make-list rank :initial-element 0))
                     (elem-bytes  (if (or (string-equal elem-str "double")
                                         (string-equal elem-str "int64_t")
                                         (string-equal elem-str "uint64_t")) 8 4))
                     (byte-size   (* total-elems elem-bytes))
                     (layout-str  (if (member align '(:strided strided)
                                              :test (lambda (a b) (string-equal (string a) (string b))))
                                      "compact (strided param, harness uses compact)"
                                      "compact")))

                (format stream "~%    // Tensor argument: ~a (rank=~d, ~a, ~d elements, ~a)~%"
                        param-name rank elem-str total-elems layout-str)
                (format stream "    ~a* ~a = nullptr;~%" elem-str ptr-var)
                (format stream "    result = zeMemAllocShared(~a, &deviceDesc, &hostDesc,~%"
                        context-var)
                (format stream "        ~d * sizeof(~a), 1, ~a, (void**)&~a);~%"
                        total-elems elem-str device-var ptr-var)
                (format stream "    if (result != ZE_RESULT_SUCCESS) {~%")
                (format stream "        std::cerr << \"ERROR: zeMemAllocShared failed for ~a\" << std::endl;~%"
                        param-name)
                (format stream "        return 1;~%")
                (format stream "    }~%")
                (format stream "    for (size_t _i = 0; _i < ~d; _i++) ~a[_i] = (~a)_i;~%"
                        total-elems ptr-var elem-str)

                (format stream "    // Arg ~d: ~a PTR~%" arg-index param-name)
                (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(void*), &~a);~%"
                        arg-index ptr-var)
                (incf arg-index)

                (format stream "    // Arg ~d: ~a BYTE_SIZE = ~d~%" arg-index param-name byte-size)
                (format stream "    uint64_t ~a_byte_size = ~dULL;~%" param-name-cpp byte-size)
                (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_byte_size);~%"
                        arg-index param-name-cpp)
                (incf arg-index)

                (loop for k from 0 below rank do
                  (format stream "    // Arg ~d: ~a OFFSET_~d = ~d~%" arg-index param-name k (nth k offsets))
                  (format stream "    uint64_t ~a_off~d = ~dULL;~%" param-name-cpp k (nth k offsets))
                  (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_off~d);~%"
                          arg-index param-name-cpp k)
                  (incf arg-index))

                (loop for k from 0 below rank do
                  (format stream "    // Arg ~d: ~a STRIDE_~d = ~d~%" arg-index param-name k (nth k strides))
                  (format stream "    uint64_t ~a_str~d = ~dULL;~%" param-name-cpp k (nth k strides))
                  (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_str~d);~%"
                          arg-index param-name-cpp k)
                  (incf arg-index))

                (loop for k from 0 below rank do
                  (format stream "    // Arg ~d: ~a EXTENT_~d = ~d~%" arg-index param-name k (nth k extents))
                  (format stream "    uint64_t ~a_ext~d = ~dULL;~%" param-name-cpp k (nth k extents))
                  (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_ext~d);~%"
                          arg-index param-name-cpp k)
                  (incf arg-index))

                (format stream "    // Arg ~d: ~a LENGTH = ~d~%" arg-index param-name total-elems)
                (format stream "    uint64_t ~a_length = ~dULL;~%" param-name-cpp total-elems)
                (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_length);~%~%"
                        arg-index param-name-cpp)
                (incf arg-index)

                (push (list :name      param-name
                            :ptr       ptr-var
                            :size-var  (format nil "~d" total-elems)
                            :direction param-dir
                            :access    (getf param :access))
                      allocations)))))

         ;; ---- def-struct parameters (1 kernel arg: aggregate by value) ----
         ((struct-type-p-l0 param-type)
          (let* ((base-type      (%struct-base-type param-type))
                 (resolved-base  (resolve-type-alias base-type aliases))
                 (struct-def     (%find-struct-def-l0 resolved-base))
                 (struct-members (cddr struct-def))
                 (param-name-cpp (format-cpp-identifier param-name))
                 (var-name       (format nil "~a_val" param-name-cpp))
                 (struct-type-str (format-cpp-identifier resolved-base)))
            (format stream "~%    // Struct argument: ~a (~a)~%" param-name struct-type-str)
            (format stream "    ~a ~a;~%" struct-type-str var-name)
            (%struct-emit-fields stream var-name struct-members aliases)
            (format stream "    // Arg ~d: ~a~%" arg-index param-name)
            (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(~a), &~a);~%~%"
              arg-index struct-type-str var-name)
            (incf arg-index)))

         ;; ---- def-record parameters (exploded to scalar args) ----
         ((record-type-p param-type records)
          (let* ((base-type    (record-base-type param-type))
                 (record-def   (find-record-def param-type records))
                 (record-members (cddr record-def))
                 (param-name-cpp (format-cpp-identifier param-name))
                 (var-name       (format nil "~a_val" param-name-cpp))
                 (struct-type-str (format-cpp-identifier base-type)))
            (format stream "~%    // Record argument: ~a (~a)~%" param-name struct-type-str)
            (format stream "    ~a ~a;~%" struct-type-str var-name)
            (setf arg-index (%record-field-args stream record-members var-name arg-index records aliases))
            (format stream "~%")))

         ;; ---- (array T N) direct parameters (1 arg, by value, iota-initialized) ----
         ((%array-type-p param-type)
          (let* ((elem-type      (%array-element-type param-type))
                 (arr-size       (%array-size param-type))
                 (elem-type-str  (crisp-type-to-cpp-type elem-type))
                 (param-name-cpp (format-cpp-identifier param-name))
                 (arr-var        (format nil "~a_arg" param-name-cpp)))
            (format stream "~%    // Array argument: ~a (~a ~a[~a])~%"
                    param-name elem-type-str param-name-cpp arr-size)
            (format stream "    ~a ~a[~a];~%" elem-type-str arr-var arr-size)
            (format stream "    for (int _i = 0; _i < ~a; _i++) ~a[_i] = (~a)_i;~%"
                    arr-size arr-var elem-type-str)
            (format stream "    // Arg ~d: ~a~%" arg-index param-name)
            (format stream "    zeKernelSetArgumentValue(kernel, ~d, ~a * sizeof(~a), ~a);~%~%"
                    arg-index arr-size elem-type-str arr-var)
            (incf arg-index)))

         ;; ---- scalar parameters ----
         ((symbolp param-type)
          (let* ((type-str (crisp-type-to-cpp-type param-type)))
            (multiple-value-bind (dvec-base dvec-width) (%dvec-parse param-type)
              (if dvec-base
                  (let ((init-str (format nil "{~{~a~^, ~}}"
                                          (loop for i from 0 below dvec-width
                                                collect (+ arg-index 42 i)))))
                    (format stream "    ~a ~a_arg = ~a;~%" type-str param-name init-str)
                    (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(~a), &~a_arg);~%~%"
                      arg-index type-str param-name))
                  (progn
                    (format stream "    ~a ~a_arg = ~d;  // TODO: Set actual value~%"
                      type-str param-name (+ arg-index 42))
                    (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(~a), &~a_arg);~%~%"
                      arg-index type-str param-name)))))
          (incf arg-index)))))

    (nreverse allocations)))




