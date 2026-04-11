(in-package :crisp.hoist.l0)

;; Overlay file for crisp-hoist-l0
;; Add late-binding fixes here as needed

;;; -----------------------------------------------------------------------
;;; Tensor support for L0 hoist
;;; src/hoist-l0/main.lisp
;;;
;;; Tensor (and vector/matrix sugar) parameters are exploded to 3N+3 scalar
;;; args at the ABI level:  PTR, BYTE_SIZE, OFF_0..N-1, STR_0..N-1,
;;; EXT_0..N-1, LENGTH.
;;;
;;; The hoist harness:
;;;   1. Allocates USM for the element storage.
;;;   2. Initialises it (iota for :out, zeros for :in, both otherwise).
;;;   3. Emits zeKernelSetArgumentValue calls in ABI order.
;;;   4. Pushes an allocation record so copyback printing works.
;;;
;;; Layout strategy (test harness): compact row-major, EXTENT=4 per dim.
;;;   N=1: extents=[4],       strides=[1],    offsets=[0],     length=4
;;;   N=2: extents=[4,4],     strides=[4,1],  offsets=[0,0],   length=16
;;;   N=3: extents=[4,4,4],   strides=[16,4,1], offsets=[0,0,0], length=64
;;; -----------------------------------------------------------------------

(defun tensor-type-p (param-type)
  "Returns T if PARAM-TYPE is a tensor/vector/matrix type specifier."
  (and (consp param-type)
       (symbolp (first param-type))
       (member (symbol-name (first param-type))
               '("TENSOR" "VECTOR" "MATRIX") :test #'string-equal)))

(defun %tensor-compact-extents-strides (n dim-extent)
  "Returns (values extents strides) for a compact N-dim tensor.
   Each dimension has extent DIM-EXTENT.
   strides are in elements (innermost = 1)."
  (let* ((extents (make-list n :initial-element dim-extent))
         (strides (make-list n :initial-element 1)))
    ;; stride_k = product of extents_{k+1..N-1}
    (loop for k from (- n 2) downto 0 do
      (setf (nth k strides) (* (nth (1+ k) strides) dim-extent)))
    (values extents strides)))

;;; Redefine generate-kernel-arguments-with-usm to add tensor branch.
;;; src/hoist-l0/main.lisp

(defun generate-kernel-arguments-with-usm (stream declared-sig aliases records context-var device-var)
  "Generate kernel argument setup code with USM allocation for cells/tensors.
   Handles:
     cell           — 3 args (ptr, byte-size, offset); cell-of-(array T N) uses N-element USM
     tensor/vector/matrix — 3N+3 args (ptr, byte-size, off×N, str×N, ext×N, length)
     def-struct     — 1 arg (aggregate by value, sizeof struct)
     def-record     — exploded scalar args; array members are single by-value args
     (array T N)    — 1 arg, passed by value (iota-initialized T[N])
     scalar/dvec    — 1 arg"
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
                 ;; Use crisp-type-to-cpp-type for both cases: fixes hyphens and long→int64_t
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
                     ;; Iota initialization for array cells: ptr[i] = (T)i
                     (format stream "    for (size_t _i = 0; _i < ~a; _i++) ~a[_i] = (~a)_i;~%"
                       size-var ptr-var base-type-str)
                     ;; Original initialization for scalar cells
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

         ;; ---- tensor/vector/matrix parameters (3N+3 kernel args) ----
         ((tensor-type-p param-type)
          (let* ((rank        (or (getf param :rank) 1))
                 (elem-type   (second param-type))
                 (align       (getf param :align))
                 (elem-str    (crisp-type-to-cpp-type elem-type))
                 (dim-extent  4)  ; test harness: 4 elements per dimension
                 (param-name-cpp (substitute #\_ #\- param-name))
                 (ptr-var     (format nil "~a_ptr" param-name-cpp))
                 (size-var    (format nil "~a_len" param-name-cpp)))

            (multiple-value-bind (extents strides)
                (%tensor-compact-extents-strides rank dim-extent)
              (let* ((total-elems (reduce #'* extents))
                     (offsets     (make-list rank :initial-element 0))
                     (byte-size   (* total-elems (if (string-equal elem-str "float") 4
                                                     (if (string-equal elem-str "double") 8
                                                         (if (or (string-equal elem-str "int64_t")
                                                                 (string-equal elem-str "uint64_t")) 8 4))))))
                (declare (ignore align))

                (format stream "~%    // Tensor argument: ~a (rank=~d, ~a, ~d elements, compact)~%"
                        param-name rank elem-str total-elems)

                ;; Allocate USM
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
                ;; Initialize: iota
                (format stream "    for (size_t _i = 0; _i < ~d; _i++) ~a[_i] = (~a)_i;~%"
                        total-elems ptr-var elem-str)

                ;; ABI order: PTR, BYTE_SIZE, OFF_0..N-1, STR_0..N-1, EXT_0..N-1, LENGTH
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

                ;; Push to allocations for copyback
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
                  ;; Device vector: aggregate init {N, N+1, ...}
                  (let ((init-str (format nil "{~{~a~^, ~}}"
                                          (loop for i from 0 below dvec-width
                                                collect (+ arg-index 42 i)))))
                    (format stream "    ~a ~a_arg = ~a;~%" type-str param-name init-str)
                    (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(~a), &~a_arg);~%~%"
                      arg-index type-str param-name))
                  ;; Regular scalar
                  (progn
                    (format stream "    ~a ~a_arg = ~d;  // TODO: Set actual value~%"
                      type-str param-name (+ arg-index 42))
                    (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(~a), &~a_arg);~%~%"
                      arg-index type-str param-name)))))
          (incf arg-index)))))

    (nreverse allocations)))




