(in-package :crisp.hoist.l0)

;;; ===========================================================================
;;; Endeavour 166 — device memory
;;;
;;; The generated L0 launcher used to allocate every kernel parameter as SHARED
;;; USM (zeMemAllocShared) and then fill, zero and print it straight through the
;;; same pointer the kernel reads.  That is the easy path and it hid a whole
;;; class of bug: a kernel reading a host-written buffer with no explicit copy
;;; works under shared and breaks under device, so we had no evidence the
;;; generated code would survive a real device-memory integration and no test
;;; that would have caught it.
;;;
;;; Every parameter is now a DEVICE allocation plus a pinned-host staging mirror:
;;;
;;;     X_ptr    zeMemAllocDevice  — what the kernel sees
;;;     X_host   zeMemAllocHost    — what the host fills, and reads back into
;;;
;;; The host writes X_host, one staging command list copies every mirror to the
;;; device before the launch, and the buffer-print reads back the other way.
;;;
;;; Measured on BMG before doing this (see tests/spec/166-device-memory/166-device-memory.md):
;;; shared was NOT streaming operands over PCIe and paid no first-launch fault-in
;;; cost, so this is not a fix for a performance bug.  It is worth 8.9% at
;;; N=2048 and ~0 elsewhere, and it buys predictability and an honest ABI.
;;; ===========================================================================

(defvar *l0-staging* nil
  "Accumulates (:dev PTR-VAR :host HOST-VAR :bytes EXPR) for every device buffer emitted
   while generating one kernel's arguments.  GENERATE-KERNEL-ARGUMENTS-WITH-USM binds it and
   drains it into a single host-to-device staging block.

   It is a special rather than a return value because the three emitters that allocate
   (%L0-EMIT-CELL-ARG, %L0-EMIT-TENSOR-ARG, %L0-EMIT-GLOBAL-SCRATCH-TENSOR-ARG) have three
   different return conventions -- one returns an index, two return an index and a plist --
   and threading a fourth value through all of them would have been a larger change than the
   feature.")

(defun %l0-emit-staged-alloc (stream context-var device-var type-str ptr-var host-var
                              count-expr param-name)
  "Emit a DEVICE allocation and its pinned-host staging mirror for one kernel parameter.

   COUNT-EXPR is a C++ expression for the ELEMENT count (a literal or a variable); the byte
   size is formed as `COUNT-EXPR * sizeof(TYPE-STR)` and recorded, so the copy and the
   allocation can never disagree about the size.

   The mirror is zeMemAllocHost rather than malloc for the same reason the benchmark probe
   used pinned memory: an unpinned source makes the driver stage the copy through a bounce
   buffer of its own, which is a second variable nobody asked for."
  (let ((bytes (format nil "~a * sizeof(~a)" count-expr type-str)))
    (format stream "    ~a* ~a = nullptr;   // device~%" type-str ptr-var)
    (format stream "    ~a* ~a = nullptr;   // host staging mirror~%" type-str host-var)
    (format stream "    result = zeMemAllocDevice(~a, &deviceDesc,~%" context-var)
    (format stream "        ~a, 1, ~a, (void**)&~a);~%" bytes device-var ptr-var)
    (format stream "    if (result != ZE_RESULT_SUCCESS) {~%")
    (format stream "        std::cerr << \"ERROR: zeMemAllocDevice failed for ~a\" << std::endl;~%"
      param-name)
    (format stream "        return 1;~%")
    (format stream "    }~%")
    (format stream "    result = zeMemAllocHost(~a, &hostDesc,~%" context-var)
    (format stream "        ~a, 1, (void**)&~a);~%" bytes host-var)
    (format stream "    if (result != ZE_RESULT_SUCCESS) {~%")
    (format stream "        std::cerr << \"ERROR: zeMemAllocHost failed for ~a\" << std::endl;~%"
      param-name)
    (format stream "        return 1;~%")
    (format stream "    }~%")
    (push (list :dev ptr-var :host host-var :bytes bytes) *l0-staging*)
    bytes))

(defun %l0-emit-h2d-staging (stream context-var device-var)
  "Emit one host-to-device copy for every buffer recorded in *L0-STAGING*.

   Deliberately its OWN command list and queue rather than an append to `cmdList`.  cmdList
   is re-executed by the --mma-bench loop, so staging appended there would be re-run and
   TIMED on every benchmark iteration -- it would show up as kernel time and nobody would see
   why.  A launcher pays for one extra queue at startup instead."
  (when *l0-staging*
    (format stream "~%    // Stage host -> device.~%")
    (format stream "    // The kernel reads DEVICE memory, so a host-side fill that is never~%")
    (format stream "    // copied is simply lost -- silently, with the buffer holding whatever~%")
    (format stream "    // the allocator handed back.~%")
    (format stream "    {~%")
    (format stream "        ze_command_list_desc_t _stgListDesc = { ZE_STRUCTURE_TYPE_COMMAND_LIST_DESC };~%")
    (format stream "        ze_command_list_handle_t _stgList;~%")
    (format stream "        result = zeCommandListCreate(~a, ~a, &_stgListDesc, &_stgList);~%"
      context-var device-var)
    (format stream "        if (result != ZE_RESULT_SUCCESS) {~%")
    (format stream "            std::cerr << \"ERROR: staging zeCommandListCreate failed: \" << result << std::endl;~%")
    (format stream "            return 1;~%")
    (format stream "        }~%")
    (format stream "        ze_command_queue_desc_t _stgQueueDesc = { ZE_STRUCTURE_TYPE_COMMAND_QUEUE_DESC };~%")
    (format stream "        ze_command_queue_handle_t _stgQueue;~%")
    (format stream "        result = zeCommandQueueCreate(~a, ~a, &_stgQueueDesc, &_stgQueue);~%"
      context-var device-var)
    (format stream "        if (result != ZE_RESULT_SUCCESS) {~%")
    (format stream "            std::cerr << \"ERROR: staging zeCommandQueueCreate failed: \" << result << std::endl;~%")
    (format stream "            return 1;~%")
    (format stream "        }~%")
    (dolist (s (reverse *l0-staging*))
      (format stream "        zeCommandListAppendMemoryCopy(_stgList, ~a, ~a, ~a, nullptr, 0, nullptr);~%"
        (getf s :dev) (getf s :host) (getf s :bytes)))
    (format stream "        zeCommandListClose(_stgList);~%")
    (format stream "        zeCommandQueueExecuteCommandLists(_stgQueue, 1, &_stgList, nullptr);~%")
    (format stream "        zeCommandQueueSynchronize(_stgQueue, UINT64_MAX);~%")
    (format stream "        zeCommandListDestroy(_stgList);~%")
    (format stream "        zeCommandQueueDestroy(_stgQueue);~%")
    (format stream "    }~%~%")))

(defun %l0-emit-d2h-readback (stream alloc)
  "Emit a device-to-host copy of one allocation into its staging mirror.

   Only needed where the host actually reads the buffer, which is the buffer print, so this
   is emitted INSIDE the print's `size <= 512` guard -- a launcher for a large tensor should
   not drag the whole thing back across the bus to not print it."
  (let ((ptr (getf alloc :ptr))
        (host (getf alloc :host))
        (size-v (getf alloc :size-var)))
    (when host
      (format stream "        {   // read back for printing~%")
      (format stream "            ze_command_list_handle_t _rdList;~%")
      (format stream "            zeCommandListCreate(context, device, &cmdListDesc, &_rdList);~%")
      (format stream "            zeCommandListAppendMemoryCopy(_rdList, ~a, ~a, ~a * sizeof(*~a), nullptr, 0, nullptr);~%"
        host ptr size-v ptr)
      (format stream "            zeCommandListClose(_rdList);~%")
      (format stream "            zeCommandQueueExecuteCommandLists(cmdQueue, 1, &_rdList, nullptr);~%")
      (format stream "            zeCommandQueueSynchronize(cmdQueue, UINT64_MAX);~%")
      (format stream "            zeCommandListDestroy(_rdList);~%")
      (format stream "        }~%"))))


;;; ---------------------------------------------------------------------------
;;; src/hoist-l0/main.lisp
;;; ---------------------------------------------------------------------------

(defun %l0-emit-cell-arg (stream param param-name param-type param-dir is-local aliases context-var device-var arg-index)
  "Emit the 3 kernel arguments for a cell parameter (ptr, byte-size, offset).

   Endeavour 166: the GLOBAL branch now allocates device memory plus a host staging mirror.
   The initialisation -- iota for an array cell, zero for a scalar cell -- writes the MIRROR;
   %L0-EMIT-H2D-STAGING copies it to the device before the launch.  The LOCAL branch is
   untouched: local memory is never host-visible in the first place."
  (declare (ignore aliases))
  (let* ((base-type (cell-base-type param-type))
         (is-array-cell (%array-type-p base-type))
         (base-type-str (if is-array-cell
                            (crisp-type-to-cpp-type (%array-element-type base-type))
                            (crisp-type-to-cpp-type base-type)))
         (elem-count (if is-array-cell (%array-size base-type) 1))
         (param-name-cpp (substitute #\_ #\- param-name))
         (size-var (format nil "~a_size" param-name-cpp))
         (ptr-var (format nil "~a_ptr" param-name-cpp))
         (host-var (format nil "~a_host" param-name-cpp))
         (alloc nil))
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

        ;; --- GLOBAL MEMORY (device + staging mirror) ---
        (progn
         (format stream "~%    // Allocate DEVICE memory for ~a (+ host staging mirror)~%" param-name)
         (format stream "    size_t ~a = ~a;  // ~a~%"
           size-var elem-count
           (if is-array-cell "Array cell: N elements" "Cell is a single scalar"))
         (%l0-emit-staged-alloc stream context-var device-var base-type-str
                                ptr-var host-var size-var param-name)
         (format stream "    // Initialize data (into the host mirror; staged below)~%")
         (if is-array-cell
             (format stream "    for (size_t _i = 0; _i < ~a; _i++) ~a[_i] = (~a)_i;~%"
               size-var host-var base-type-str)
             (format stream "    memset(~a, 0, ~a * sizeof(~a));~%" host-var size-var base-type-str))
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
         (setf alloc (list :name param-name
                           :ptr ptr-var
                           :host host-var
                           :size-var size-var
                           :direction param-dir
                           :access (getf param :access)))))
    (values (+ arg-index 3) alloc)))


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


(defun %l0-emit-tensor-arg (stream param param-name param-type param-dir context-var device-var arg-index dispatch-info)
  "Emit the 3N+3 kernel arguments for a declared tensor parameter.

   Endeavour 166: device memory plus a host staging mirror.  Every fill this function
   emits -- the deterministic --mma-test fill for A/B, the zero for C, the pad-with zero,
   the plain iota -- now writes the MIRROR and is staged to the device before the launch.
   The MMA host reference (%L0-EMIT-MMA-REFERENCE) is unaffected: it already copies C back
   itself and recomputes A/B rather than reading them, so it works against a device pointer
   exactly as it did against a shared one."
  (let* ((rank (or (getf param :rank)
                   (let ((n3 (third param-type)))
                     (if (integerp n3) n3 1))))
         (elem-type (second param-type))
         (align (getf param :align))
         (elem-str (crisp-type-to-cpp-type elem-type))
         (param-name-cpp (substitute #\_ #\- param-name))
         (ptr-var (format nil "~a_ptr" param-name-cpp))
         (host-var (format nil "~a_host" param-name-cpp))
         ;; Endeavor 134: assign an MMA role (A=first input, B=second input, C=&out) and
         ;; override the tensor extents accordingly.
         (mma-role (when (and *mma-test-dims* (= rank 2))
                     (if (%mma-out-dir-p param-dir)
                         :c
                         (prog1 (if (zerop *mma-input-counter*) :a :b)
                           (incf *mma-input-counter*)))))
         (extents-list
           (if mma-role
               (destructuring-bind (m n k) *mma-test-dims*
                 (ecase mma-role (:a (list m k)) (:b (list k n)) (:c (list m n))))
               (let ((lst (make-list rank :initial-element 4)))
                 (let* ((global-decl (getf dispatch-info :global-size))
                        (strategy (getf (cdr global-decl) :strategy))
                        (derive-from (getf (cdr global-decl) :derive-from))
                        (tile-shape (getf (cdr global-decl) :tile-shape)))
                   (declare (ignore strategy))
                   (when (and tile-shape derive-from
                              (member param-name (if (listp derive-from) derive-from (list derive-from))
                                      :test (lambda (a b) (string-equal (string a) (string b)))))
                     (loop for k from 0 below (min rank (length tile-shape)) do
                       (let* ((tx (nth k tile-shape)) (base (nth k lst)) (padded (* (ceiling base tx) tx)))
                         (setf (nth k lst) padded)))))
                 lst))))
    (multiple-value-bind (extents strides)
        (%tensor-compact-extents-strides rank extents-list)
      (let* ((total-elems (* (first strides) (first extents)))
             (offsets (make-list rank :initial-element 0))
             (elem-bytes (%elem-type-bytes elem-str))
             (byte-size (* total-elems elem-bytes))
             (layout-str (if (member align '(:strided strided)
                                     :test (lambda (a b) (string-equal (string a) (string b))))
                             "compact (strided param, harness uses compact)" "compact"))
             (current-idx arg-index))
        (format stream "~%    // Tensor argument: ~a (rank=~d, ~a, ~d elements, ~a)~%"
          param-name rank elem-str total-elems layout-str)
        (%l0-emit-staged-alloc stream context-var device-var elem-str
                               ptr-var host-var (format nil "~d" total-elems) param-name)
        ;; Initialise data -- into the host mirror.
        (let* ((global-decl (getf dispatch-info :global-size))
               (pad-with (getf (cdr global-decl) :pad-with)))
          (cond
            ;; MMA test: A/B get a deterministic non-uniform fill; C is zeroed.
            ((member mma-role '(:a :b))
             ;; Endeavour 155: a 16-bit float buffer is uint16_t in C++, so a plain cast wrote
             ;; the INTEGER 1..4 as a bit pattern -- which reads back as a SUBNORMAL near 6e-8,
             ;; not as 1..4.  The GPU then multiplied denormal noise while the host reference
             ;; computed with 1..4, so they could never agree.  Encode properly instead.
             (let ((conv (%l0-f16-encoder elem-type)))
               (if conv
                   (format stream "    for (size_t _i = 0; _i < ~d; _i++) ~a[_i] = ~a((float)(_i % ~d));~%"
                     total-elems host-var conv (%l0-mma-fill-modulus mma-role))
                   (format stream "    for (size_t _i = 0; _i < ~d; _i++) ~a[_i] = (~a)(_i % ~d);~%"
                     total-elems host-var elem-str (%l0-mma-fill-modulus mma-role)))))
            ((eq mma-role :c)
             (format stream "    memset(~a, 0, ~d * sizeof(~a));~%" host-var total-elems elem-str))
            ((and pad-with (eql pad-with 0))
             (format stream "    memset(~a, 0, ~d * sizeof(~a));~%" host-var total-elems elem-str))
            (t
             (format stream "    for (size_t _i = 0; _i < ~d; _i++) ~a[_i] = (~a)_i;~%" total-elems host-var elem-str))))
        (format stream "    // Arg ~d: ~a PTR~%" current-idx param-name)
        (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(void*), &~a);~%" current-idx ptr-var)
        (incf current-idx)
        (format stream "    // Arg ~d: ~a BYTE_SIZE = ~d~%" current-idx param-name byte-size)
        (format stream "    uint64_t ~a_byte_size = ~dULL;~%" param-name-cpp byte-size)
        (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_byte_size);~%" current-idx param-name-cpp)
        (incf current-idx)
        (loop for k from 0 below rank do
          (format stream "    // Arg ~d: ~a OFFSET_~d = ~d~%" current-idx param-name k (nth k offsets))
          (format stream "    uint64_t ~a_off~d = ~dULL;~%" param-name-cpp k (nth k offsets))
          (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_off~d);~%" current-idx param-name-cpp k)
          (incf current-idx))
        (loop for k from 0 below rank do
          (format stream "    // Arg ~d: ~a STRIDE_~d = ~d~%" current-idx param-name k (nth k strides))
          (format stream "    uint64_t ~a_str~d = ~dULL;~%" param-name-cpp k (nth k strides))
          (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_str~d);~%" current-idx param-name-cpp k)
          (incf current-idx))
        (loop for k from 0 below rank do
          (format stream "    // Arg ~d: ~a EXTENT_~d = ~d~%" current-idx param-name k (nth k extents))
          (format stream "    uint64_t ~a_ext~d = ~dULL;~%" param-name-cpp k (nth k extents))
          (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_ext~d);~%" current-idx param-name-cpp k)
          (incf current-idx))
        (format stream "    // Arg ~d: ~a LENGTH = ~d~%" current-idx param-name total-elems)
        (format stream "    uint64_t ~a_length = ~dULL;~%" param-name-cpp total-elems)
        (format stream "    zeKernelSetArgumentValue(kernel, ~d, sizeof(uint64_t), &~a_length);~%~%" current-idx param-name-cpp)
        (incf current-idx)
        (values current-idx
          (list :name param-name :ptr ptr-var :host host-var
                :size-var (format nil "~d" total-elems)
                :direction param-dir :access (getf param :access)
                ;; Endeavour 155: the host reference needs to know how to READ this buffer.
                :elem-type elem-type
                :mma-role mma-role :base param-name-cpp))))))


(defun generate-kernel-arguments-with-usm (stream declared-sig aliases records context-var device-var dispatch-info)
  "Generate kernel argument setup code with DEVICE allocation for cells/tensors.
   Handles:
     cell                   — 3 args (ptr, byte-size, offset)
     local scratch tensor   — 3N+3 args; ptr as nullptr local alloc
     tensor/vector/matrix   — 3N+3 args; device allocation + host staging mirror
     def-struct             — 1 arg (aggregate by value, sizeof struct)
     def-record             — exploded scalar args
     (array T N)            — 1 arg, passed by value (iota-initialized T[N])
     scalar/dvec            — 1 arg

   Endeavour 166: binds *L0-STAGING* around the parameter walk and emits ONE host-to-device
   staging block afterwards, rather than a copy per parameter.  One block because the copies
   have no ordering constraint between them and a single submit is one round trip instead of
   N; after the walk because the emitters run before any command list exists."
  (format stream "    // Set up kernel arguments~%")
  (format stream "    ze_device_mem_alloc_desc_t deviceDesc = { ZE_STRUCTURE_TYPE_DEVICE_MEM_ALLOC_DESC };~%")
  (format stream "    ze_host_mem_alloc_desc_t hostDesc = { ZE_STRUCTURE_TYPE_HOST_MEM_ALLOC_DESC };~%~%")

  (let ((arg-index 0)
        (allocations '())
        (*l0-staging* '()))

    (dolist (param declared-sig)
      (let* ((param-name (getf param :name))
             (raw-type (getf param :type))
             (param-type (resolve-type-alias raw-type aliases))
             (param-dir (getf param :direction))
             (param-as (getf param :address-space))
             (is-local (member param-as '(:local "LOCAL" local) :test #'string-equal)))

        (cond
         ((cell-type-p param-type)
           (multiple-value-bind (new-idx alloc)
               (%l0-emit-cell-arg stream param param-name param-type param-dir is-local aliases context-var device-var arg-index)
             (setf arg-index new-idx)
             (when alloc (push alloc allocations))))

         ((and (tensor-type-p param-type) is-local)
           (setf arg-index (%l0-emit-local-scratch-tensor-arg stream param param-name param-type arg-index)))

         ((and (tensor-type-p param-type) (not is-local) (getf param :size-expr))
           (setf arg-index (%l0-emit-global-scratch-tensor-arg stream param param-name param-type context-var device-var arg-index)))

         ((tensor-type-p param-type)
           (multiple-value-bind (new-idx alloc)
               (%l0-emit-tensor-arg stream param param-name param-type param-dir context-var device-var arg-index dispatch-info)
             (setf arg-index new-idx)
             (when alloc (push alloc allocations))))

         ((struct-type-p-l0 param-type)
           (setf arg-index (%l0-emit-struct-arg stream param param-name param-type aliases arg-index)))

         ((record-type-p param-type records)
           (setf arg-index (%l0-emit-record-arg stream param param-name param-type records aliases arg-index)))

         ((%array-type-p param-type)
           (setf arg-index (%l0-emit-array-arg stream param param-name param-type arg-index)))

         ((symbolp param-type)
           (setf arg-index (%l0-emit-scalar-arg stream param-name param-type arg-index))))))

    (%l0-emit-h2d-staging stream context-var device-var)

    (nreverse allocations)))


(defun generate-cpp-main (stream kernel-name spv-path declared-sig aliases records &optional dispatch-info)
  "Generate C++ main.  Endeavor 134: under --mma-test, appends a host-reference C=A·B check.
   Endeavor 150: buffer-print cap raised 100 -> 512 so MMA-sized output tiles are printable
   and can be checked with a HOIST-EXPECT: BUFFER expectation.

   Endeavour 166: the buffer print reads the HOST MIRROR, and copies the device buffer into
   it first.  Printing `X_ptr[i]` would now be a host dereference of device memory -- which
   on Level Zero is not a compile error and not necessarily a crash, so getting this wrong
   would have shown up as wrong NUMBERS in HOIST-EXPECT rather than as a failure that names
   itself."
  (format stream "int main() {~%")
  (format stream "    ze_result_t result;~%")
  (format stream "    std::cout << \"Level Zero Launcher for kernel: ~a\" << std::endl;~%~%" kernel-name)
  (generate-l0-init stream)
  (when spv-path (generate-module-loading stream spv-path))
  (setf *mma-input-counter* 0)          ; reset role assignment for this kernel
  (let ((allocations (generate-kernel-launch stream kernel-name declared-sig aliases records dispatch-info)))
    (format stream "    // Verify Output (skipped if large)~%")
    (dolist (alloc allocations)
      (let ((name (getf alloc :name))
            (ptr (getf alloc :ptr))
            (host (getf alloc :host))
            (size-v (getf alloc :size-var)))
        (format stream "    if (~a <= 512) {~%" size-v)
        (%l0-emit-d2h-readback stream alloc)
        (format stream "        std::cout << \"BUFFER ~a: \";~%" name)
        (format stream "        for (size_t i = 0; i < ~a; i++) {~%" size-v)
        (format stream "            std::cout << ~a[i] << (i == ~a - 1 ? \"\" : \" \");~%"
          (or host ptr) size-v)
        (format stream "        }~%")
        (format stream "        std::cout << std::endl;~%")
        (format stream "    }~%")))
    ;; Endeavour 155: was (and *mma-test-dims* (not *mma-bench-iters*)) -- see header.
    (when *mma-test-dims*
      (%l0-emit-mma-reference stream allocations))
    (format stream "    std::cout << \"Success!\" << std::endl;~%")
    (format stream "    return 0;~%")
    (format stream "}~%")))
