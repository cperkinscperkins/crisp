;;;; tests/verify-autodiff-runner.lisp
;;;;
;;;; On-metal AD verification runner.  Provides VERIFY-AUTODIFF, which takes
;;;; a forward + backward SPV pair and verifies that the analytical gradient
;;;; emitted by the backward kernel matches a central-difference numerical
;;;; gradient computed by running the forward kernel at x +/- h.
;;;;
;;;; Phase 1 scope (endeavor 103): scalar-cell-in / scalar-cell-out only.
;;;; Tensor/record/struct inputs come in later phases.
;;;;
;;;; Entry point:
;;;;
;;;;   (verify-autodiff fwd-spv-path bwd-spv-path fwd-kernel-name
;;;;                    &key bwd-kernel-name x seed-grad h atol verbose)
;;;;     => (values pass-p analytical numerical diff)
;;;;
;;;; This file loads OpenCL via CFFI at load time.  Loading it on a host
;;;; without an OpenCL ICD will signal at the (cffi:use-foreign-library)
;;;; step -- callers wanting to soft-skip should wrap LOAD in HANDLER-CASE.

(in-package :cl-user)

(unless (find-package :cffi)
  (format t "~&; Loading CFFI for verify-autodiff runner...~%")
  (ql:quickload :cffi :silent t))

;;; === Runtime selection ================================================
;;;
;;; *ad-runtime* picks which on-metal runtime VERIFY-AUTODIFF dispatches
;;; through:
;;;   :l0     -- Level Zero via ze_loader (default; SPV-correct on BMG).
;;;   :opencl -- OpenCL via the platform ICD (legacy; regressed on BMG
;;;              under recent Intel Graphics driver -- see bug 031).
;;;
;;; *ad-device* is the L0 device handle, set by runtime-init when L0 is
;;; the active runtime.  L0 helpers that need the device read it from
;;; this dynamic var so the per-helper dispatch signatures can stay
;;; identical to the OpenCL ones (which pass context + queue).

(defvar *ad-runtime* :l0
  "Which on-metal runtime VERIFY-AUTODIFF uses: :l0 or :opencl.")

(defvar *ad-device* nil
  "L0 device handle (ze_device_handle_t) bound by runtime-init.  NIL when
   *AD-RUNTIME* is :opencl or when no runtime is initialised.")

(defvar *ad-context* nil
  "Active L0 context handle (ze_context_handle_t), bound by RUNTIME-INIT
   when *AD-RUNTIME* is :l0.  L0 helpers that need the context for
   transient command-queue/list creation read it from here.  NIL under
   :opencl.")

;;; === Level Zero bindings ==============================================
;;;
;;; Loaded eagerly so the L0 dispatch path is callable from any test
;;; that loads this runner.  If ze_loader.dll is missing, this signals
;;; at load time -- mirror the existing OpenCL-load failure mode.

(load (merge-pathnames "l0-bindings.lisp"
                       (make-pathname :defaults #.(or *compile-file-pathname*
                                                      *load-pathname*
                                                      *default-pathname-defaults*)
                                      :name nil :type nil)))

;;; === OpenCL Constants =================================================

(defconstant +CL-SUCCESS+ 0)
(defconstant +CL-DEVICE-TYPE-GPU+ 4)
(defconstant +CL-MEM-READ-WRITE+ 1)
(defconstant +CL-MEM-COPY-HOST-PTR+ 4)

;;; === OpenCL CFFI Bindings =============================================
;;;
;;; cl_ulong / cl_bitfield are unsigned long long (64-bit) per the OpenCL
;;; spec on all platforms.  CFFI :ulong is C unsigned long, which is 32-bit
;;; on Windows LLP64 -- so always use :uint64 for cl_ulong-typed args.

(cffi:define-foreign-library opencl
                             (:windows "OpenCL.dll")
                             (:unix "libOpenCL.so")
                             (t (:default "libOpenCL")))

(cffi:use-foreign-library opencl)

(cffi:defcfun ("clGetPlatformIDs" cl-get-platform-ids) :int
              (num-entries :uint) (platforms :pointer) (num-platforms :pointer))

(cffi:defcfun ("clGetDeviceIDs" cl-get-device-ids) :int
              (platform :pointer) (device-type :uint64) (num-entries :uint)
              (devices :pointer) (num-devices :pointer))

(cffi:defcfun ("clCreateContext" cl-create-context) :pointer
              (properties :pointer) (num-devices :uint) (devices :pointer)
              (pfn-notify :pointer) (user-data :pointer) (errcode-ret :pointer))

(cffi:defcfun ("clCreateCommandQueue" cl-create-command-queue) :pointer
              (context :pointer) (device :pointer) (properties :uint64) (errcode-ret :pointer))

(cffi:defcfun ("clCreateProgramWithIL" cl-create-program-with-il) :pointer
              (context :pointer) (il :pointer) (length :size) (errcode-ret :pointer))

(cffi:defcfun ("clBuildProgram" cl-build-program) :int
              (program :pointer) (num-devices :uint) (device-list :pointer)
              (options :string) (pfn-notify :pointer) (user-data :pointer))

(cffi:defcfun ("clCreateKernel" cl-create-kernel) :pointer
              (program :pointer) (kernel-name :string) (errcode-ret :pointer))

(cffi:defcfun ("clCreateBuffer" cl-create-buffer) :pointer
              (context :pointer) (flags :uint64) (size :size)
              (host-ptr :pointer) (errcode-ret :pointer))

(cffi:defcfun ("clSetKernelArg" cl-set-kernel-arg) :int
              (kernel :pointer) (arg-index :uint) (arg-size :size) (arg-value :pointer))

(cffi:defcfun ("clEnqueueNDRangeKernel" cl-enqueue-ndrange-kernel) :int
              (command-queue :pointer) (kernel :pointer) (work-dim :uint)
              (global-work-offset :pointer) (global-work-size :pointer) (local-work-size :pointer)
              (num-events-in-wait-list :uint) (event-wait-list :pointer) (event :pointer))

(cffi:defcfun ("clEnqueueReadBuffer" cl-enqueue-read-buffer) :int
              (command-queue :pointer) (buffer :pointer) (blocking-read :uint)
              (offset :size) (size :size) (ptr :pointer)
              (num-events-in-wait-list :uint) (event-wait-list :pointer) (event :pointer))

(cffi:defcfun ("clEnqueueWriteBuffer" cl-enqueue-write-buffer) :int
              (command-queue :pointer) (buffer :pointer) (blocking-write :uint)
              (offset :size) (size :size) (ptr :pointer)
              (num-events-in-wait-list :uint) (event-wait-list :pointer) (event :pointer))

(cffi:defcfun ("clFinish" cl-finish) :int
              (command-queue :pointer))

(cffi:defcfun ("clReleaseMemObject" cl-release-mem-object) :int
              (memobj :pointer))

(cffi:defcfun ("clReleaseKernel" cl-release-kernel) :int
              (kernel :pointer))

(cffi:defcfun ("clReleaseProgram" cl-release-program) :int
              (program :pointer))

(cffi:defcfun ("clReleaseCommandQueue" cl-release-command-queue) :int
              (command-queue :pointer))

(cffi:defcfun ("clReleaseContext" cl-release-context) :int
              (context :pointer))

;;; === Helpers ===========================================================

(defmacro check-cl (form)
  `(let ((err ,form))
     (unless (= err +CL-SUCCESS+)
       (error "OpenCL error in ~a: ~a" ',form err))))

(defun read-spv-file (path)
  "Reads a SPIR-V binary file into a freshly-allocated (unsigned-byte 8) array."
  (with-open-file (stream path :direction :input :element-type '(unsigned-byte 8))
    (let* ((length (file-length stream))
           (data (make-array length :element-type '(unsigned-byte 8))))
      (read-sequence data stream)
      data)))

(defun opencl-create-program-and-kernel (context spv-data kernel-name)
  "Builds an OpenCL program from SPV-DATA and creates KERNEL-NAME.
   Returns (values program kernel)."
  (cffi:with-foreign-object (err :int)
    (cffi:with-foreign-object (il-ptr :uchar (length spv-data))
      (loop for i from 0 below (length spv-data)
            do (setf (cffi:mem-aref il-ptr :uchar i) (aref spv-data i)))
      (let* ((program (cl-create-program-with-il context il-ptr (length spv-data) err)))
        (check-cl (cffi:mem-ref err :int))
        (check-cl (cl-build-program program 0 (cffi:null-pointer) (cffi:null-pointer) (cffi:null-pointer) (cffi:null-pointer)))
        (let ((kernel (cl-create-kernel program kernel-name err)))
          (check-cl (cffi:mem-ref err :int))
          (values program kernel))))))

(defun opencl-create-float-cell-buffer (context)
  "Creates a 4-byte read/write cl_mem buffer for a single-float cell."
  (cffi:with-foreign-object (err :int)
    (let ((buffer (cl-create-buffer context +CL-MEM-READ-WRITE+ 4 (cffi:null-pointer) err)))
      (check-cl (cffi:mem-ref err :int))
      buffer)))

(defun opencl-write-float-cell (queue buffer value)
  "Writes VALUE (a single-float) to the 1-element float buffer."
  (cffi:with-foreign-object (data :float 1)
    (setf (cffi:mem-aref data :float 0) value)
    (check-cl (cl-enqueue-write-buffer queue buffer 1 0 4 data 0 (cffi:null-pointer) (cffi:null-pointer)))))

(defun opencl-read-float-cell (queue buffer)
  "Reads the single float from BUFFER and returns it."
  (cffi:with-foreign-object (result :float 1)
    (check-cl (cl-enqueue-read-buffer queue buffer 1 0 4 result 0 (cffi:null-pointer) (cffi:null-pointer)))
    (cffi:mem-aref result :float 0)))

(defun opencl-bind-cell-arg (kernel base-index buffer &key (byte-size 4) (offset 0))
  "Binds a Crisp cell to KERNEL starting at BASE-INDEX (3 args: parent ptr,
   byte_size, offset).  Reflects the post-:access-removal cell layout
   (3-tuple).  Sizes use :uint64 to match the kernel's i64 params on Windows."
  (cffi:with-foreign-objects ((arg0 :pointer) (arg1 :uint64) (arg2 :uint64))
    (setf (cffi:mem-ref arg0 :pointer) buffer)
    (setf (cffi:mem-ref arg1 :uint64) byte-size)
    (setf (cffi:mem-ref arg2 :uint64) offset)
    (check-cl (cl-set-kernel-arg kernel (+ base-index 0) (cffi:foreign-type-size :pointer) arg0))
    (check-cl (cl-set-kernel-arg kernel (+ base-index 1) (cffi:foreign-type-size :uint64) arg1))
    (check-cl (cl-set-kernel-arg kernel (+ base-index 2) (cffi:foreign-type-size :uint64) arg2))))

(defun opencl-launch-kernel-1d (queue kernel &key (global-size 1) (group-size 1))
  "Launches KERNEL with a 1D ND-range of GLOBAL-SIZE and waits for it to finish."
  (cffi:with-foreign-object (gs :size 1)
    (setf (cffi:mem-aref gs :size 0) global-size)
    (check-cl (cl-enqueue-ndrange-kernel queue kernel 1 (cffi:null-pointer) gs (cffi:null-pointer) 0 (cffi:null-pointer) (cffi:null-pointer))))
  (check-cl (cl-finish queue)))

;;; --- Phase 5b helpers: vectors + plain scalars -----------------------

(defun opencl-create-float-buffer (context n-elements)
  "Creates a read/write cl_mem buffer holding N-ELEMENTS single-float values."
  (cffi:with-foreign-object (err :int)
    (let ((buffer (cl-create-buffer context +CL-MEM-READ-WRITE+
                                    (* 4 n-elements)
                                    (cffi:null-pointer) err)))
      (check-cl (cffi:mem-ref err :int))
      buffer)))

(defun opencl-write-float-vector (queue buffer values)
  "Writes a list of float VALUES into BUFFER (one float per element)."
  (let ((n (length values)))
    (cffi:with-foreign-object (data :float n)
      (loop for v in values
            for i from 0
            do (setf (cffi:mem-aref data :float i) (cl:float v 1.0)))
      (check-cl (cl-enqueue-write-buffer queue buffer 1 0 (* 4 n) data
                                         0 (cffi:null-pointer) (cffi:null-pointer))))))

(defun opencl-read-float-vector (queue buffer n)
  "Reads N single-floats from BUFFER and returns them as a list."
  (cffi:with-foreign-object (data :float n)
    (check-cl (cl-enqueue-read-buffer queue buffer 1 0 (* 4 n) data
                                      0 (cffi:null-pointer) (cffi:null-pointer)))
    (loop for i from 0 below n
          collect (cffi:mem-aref data :float i))))

(defun opencl-read-float-vector-elem (queue buffer i)
  "Reads a single float at index I from BUFFER."
  (cffi:with-foreign-object (data :float 1)
    (check-cl (cl-enqueue-read-buffer queue buffer 1 (* 4 i) 4 data
                                      0 (cffi:null-pointer) (cffi:null-pointer)))
    (cffi:mem-aref data :float 0)))

(defun opencl-bind-vector-arg (kernel base-index buffer length)
  "Binds a 1D contiguous-compact float vector to KERNEL starting at BASE-INDEX.
   6 args: parent ptr, parent byte_size, offset, stride[0], extent[0], length.
   Sizes use :uint64 to match the kernel's i64 params on Windows."
  (cffi:with-foreign-objects ((arg0 :pointer)
                              (arg1 :uint64) (arg2 :uint64)
                              (arg3 :uint64) (arg4 :uint64) (arg5 :uint64))
    (setf (cffi:mem-ref arg0 :pointer) buffer
          (cffi:mem-ref arg1 :uint64) (* 4 length)  ; parent byte_size
          (cffi:mem-ref arg2 :uint64) 0             ; offset
          (cffi:mem-ref arg3 :uint64) 1             ; stride[0]
          (cffi:mem-ref arg4 :uint64) length        ; extent[0]
          (cffi:mem-ref arg5 :uint64) length)       ; length
    (check-cl (cl-set-kernel-arg kernel (+ base-index 0) (cffi:foreign-type-size :pointer) arg0))
    (check-cl (cl-set-kernel-arg kernel (+ base-index 1) (cffi:foreign-type-size :uint64) arg1))
    (check-cl (cl-set-kernel-arg kernel (+ base-index 2) (cffi:foreign-type-size :uint64) arg2))
    (check-cl (cl-set-kernel-arg kernel (+ base-index 3) (cffi:foreign-type-size :uint64) arg3))
    (check-cl (cl-set-kernel-arg kernel (+ base-index 4) (cffi:foreign-type-size :uint64) arg4))
    (check-cl (cl-set-kernel-arg kernel (+ base-index 5) (cffi:foreign-type-size :uint64) arg5))))

(defun opencl-bind-matrix-arg (kernel base-index buffer rows cols)
  "Endeavor 145 (P6): binds a 2-D contiguous-compact row-major float matrix to KERNEL
   starting at BASE-INDEX.  9 args, in the order the tensor record declares its fields:
   parent ptr, parent byte_size, offset[0], offset[1], stride[0], stride[1],
   extent[0], extent[1], length.

   Row-major strides are (cols, 1).  An :align :compact tensor's `~` accessor ignores the
   strides, but the arguments still exist in the ABI and must be bound."
  (cffi:with-foreign-objects ((a0 :pointer) (a1 :uint64) (a2 :uint64) (a3 :uint64)
                              (a4 :uint64) (a5 :uint64) (a6 :uint64) (a7 :uint64)
                              (a8 :uint64))
    (setf (cffi:mem-ref a0 :pointer) buffer
          (cffi:mem-ref a1 :uint64) (* 4 rows cols)
          (cffi:mem-ref a2 :uint64) 0
          (cffi:mem-ref a3 :uint64) 0
          (cffi:mem-ref a4 :uint64) cols
          (cffi:mem-ref a5 :uint64) 1
          (cffi:mem-ref a6 :uint64) rows
          (cffi:mem-ref a7 :uint64) cols
          (cffi:mem-ref a8 :uint64) (* rows cols))
    (check-cl (cl-set-kernel-arg kernel (+ base-index 0) (cffi:foreign-type-size :pointer) a0))
    (loop for k from 1 below 9
          for obj in (list a1 a2 a3 a4 a5 a6 a7 a8)
          do (check-cl (cl-set-kernel-arg kernel (+ base-index k)
                                          (cffi:foreign-type-size :uint64) obj)))))

(defun opencl-bind-uint64-scalar-arg (kernel arg-index value)
  "Binds a plain i64 / uint64 scalar at ARG-INDEX."
  (cffi:with-foreign-object (arg :uint64)
    (setf (cffi:mem-ref arg :uint64) value)
    (check-cl (cl-set-kernel-arg kernel arg-index (cffi:foreign-type-size :uint64) arg))))

(defun opencl-bind-float-scalar-arg (kernel arg-index value)
  "Binds a plain (unboxed) float32 scalar at ARG-INDEX.  Used for record
   field inputs that SROA into bare floats at the kernel boundary."
  (cffi:with-foreign-object (arg :float)
    (setf (cffi:mem-ref arg :float) (cl:float value 1.0))
    (check-cl (cl-set-kernel-arg kernel arg-index (cffi:foreign-type-size :float) arg))))

(defun opencl-bind-int32-scalar-arg (kernel arg-index value)
  "Binds a plain (unboxed) i32 scalar at ARG-INDEX.  Used for record
   field inputs declared `int` that SROA into bare i32 at the kernel boundary."
  (cffi:with-foreign-object (arg :int32)
    (setf (cffi:mem-ref arg :int32) value)
    (check-cl (cl-set-kernel-arg kernel arg-index (cffi:foreign-type-size :int32) arg))))

(defun opencl-bind-struct-by-value-arg (kernel arg-index fields total-bytes)
  "Binds a struct passed by value at ARG-INDEX.  FIELDS is a list of plists,
   each `(:value V :ftype :float|:int32 :offset BYTE-OFFSET)` in declaration
   order.  Packs the fields into TOTAL-BYTES of host memory and submits via
   clSetKernelArg.  Used for `def-struct` parameters at the kernel boundary
   (which are NOT SROA'd -- they cross the boundary as one struct value)."
  (cffi:with-foreign-object (data :uint8 total-bytes)
    ;; Zero initialise so any padding bytes are well-defined.
    (loop for i from 0 below total-bytes
          do (setf (cffi:mem-aref data :uint8 i) 0))
    (dolist (f fields)
      (let ((offset (getf f :offset))
            (ftype  (getf f :ftype))
            (value  (getf f :value)))
        (case ftype
          (:float
           (setf (cffi:mem-ref (cffi:inc-pointer data offset) :float)
                 (cl:float value 1.0)))
          (:int32
           (setf (cffi:mem-ref (cffi:inc-pointer data offset) :int32) value))
          (t (error "opencl-bind-struct-by-value-arg: unsupported ftype ~A" ftype)))))
    (check-cl (cl-set-kernel-arg kernel arg-index total-bytes data))))

;;; === Entry Point =======================================================

;;; --- Input descriptor (phase 5b / phase A / phase B) ----------------
;;;
;;; Each input is classified into one of six kinds, controlling buffer
;;; allocation, arg-width, and FD strategy:
;;;
;;;   :scalar-float        -- wrapped (cell float),  3 fwd args, FD perturbs cell
;;;   :scalar-float-plain  -- plain float32,         1 fwd arg,  FD perturbs value
;;;                           (used for float record fields that SROA at boundary)
;;;   :scalar-int32-plain  -- plain i32,             1 fwd arg,  no FD (int grad = 0)
;;;                           (used for int record fields that SROA at boundary)
;;;   :scalar-ulong        -- plain i64,             1 fwd arg,  no FD (grad = 0)
;;;   :vector-float        -- 1D compact tensor,     6 fwd args, FD perturbs at :perturb-i
;;;   :struct-by-value     -- struct passed by value, 1 fwd arg,  FD perturbs each
;;;                           float field; grad is a single cell-of-shadow-struct
;;;                           with N*4 bytes of float fields (phase B).
;;;
;;; Heuristics from directive value + name:
;;;   - List value                          => :vector-float
;;;   - Dotted name + parent in :structs    => folded into :struct-by-value desc
;;;   - Integer value, dot in name          => :scalar-int32-plain (record field)
;;;   - Integer value, no dot               => :scalar-ulong (top-level scalar)
;;;   - Real value, dot in name             => :scalar-float-plain (record field)
;;;   - Real value, no dot                  => :scalar-float (cell-wrapped)

(defun %vad-flatten-values (value)
  "Endeavor 145 (P6): a matrix input's directive value is a list of ROW lists; the device
   buffer is flat row-major.  Flattens one level when needed, leaving a 1-D vector's value
   untouched, so the matrix and vector paths can share the FD / write code."
  (if (and (listp value) value (listp (first value)))
      (apply #'append value)
      value))

(defun %vad-classify-input (value at-points name)
  "Returns plist describing input kind given the parsed VALUE.
   AT-POINTS is the parser's at-points alist; used to attach :perturb-i."
  (cond
    ;; Endeavor 145 (P6): a list of LISTS is a 2-D matrix.  Checked before the vector
    ;; case, which would otherwise take it and report a length of ROWS.
    ((and (listp value) value (listp (first value)))
     (let ((at (cdr (assoc name at-points :test #'string=)))
           (rows (length value))
           (cols (length (first value))))
       (list :kind :matrix-float
             :rows rows
             :cols cols
             :length (* rows cols)
             ;; :perturb-i is the FLAT index; the directive gives (row col).
             :perturb-i (and at (consp at) (+ (* (first at) cols) (second at)))
             :perturb-rc at
             :arg-width 9
             :grad-arg-width 9)))
    ((listp value)
     (let ((at (cdr (assoc name at-points :test #'string=))))
       (list :kind :vector-float
             :length (length value)
             :perturb-i at
             :arg-width 6
             :grad-arg-width 6)))
    ((integerp value)
     (cond
       ;; Dotted name (e.g. "P.x") + integer value => record field of `int`
       ;; type, plain i32 at boundary; cell-of-float grad (4 bytes).
       ((find #\. name)
        (list :kind :scalar-int32-plain
              :perturb-i nil
              :arg-width 1
              :grad-arg-width 3))   ; cell-of-float grad
       (t
        (list :kind :scalar-ulong
              :perturb-i nil
              :arg-width 1
              :grad-arg-width 3))))   ; cell-of-double grad
    ((realp value)
     (cond
       ;; Dotted name (e.g. "P.x") => record field, plain float at boundary.
       ((find #\. name)
        (list :kind :scalar-float-plain
              :perturb-i nil
              :arg-width 1
              :grad-arg-width 3))   ; cell-of-float grad
       (t
        (list :kind :scalar-float
              :perturb-i nil
              :arg-width 3
              :grad-arg-width 3))))
    (t
     (error "VERIFY-AUTODIFF: cannot classify input ~A with value ~A"
            name value))))

(defun %vad-ftype-for-value (value)
  "Returns the host-side scalar type for a directive value: :float for reals,
   :int32 for integers.  Used when packing struct-by-value fields."
  (cond ((integerp value) :int32)
        ((realp value)    :float)
        (t (error "%vad-ftype-for-value: cannot classify value ~A" value))))

(defun %vad-dotted-parent (name)
  "If NAME contains a dot, returns the substring before the first dot.
   Otherwise returns NIL."
  (let ((dot (position #\. name)))
    (and dot (subseq name 0 dot))))

(defun %vad-read-y (queue output-buf output-vec-length)
  "Reads the kernel's output as a scalar y value.  For cell outputs this is
   just the cell value.  For vector outputs (107) it is the sum of all
   elements — equivalent to dot(output, all-ones-seed), which makes f(A)
   scalar and matches the backward's all-ones gradient seed."
  (if output-vec-length
      (cffi:with-foreign-object (data :float output-vec-length)
        (read-bytes-from-buffer queue output-buf data (* 4 output-vec-length))
        (loop for i from 0 below output-vec-length
              sum (cffi:mem-aref data :float i)))
      (read-float-cell queue output-buf)))

(defun %vad-zero-output (queue output-buf output-vec-length)
  "Zeros the output buffer (cell or vector)."
  (if output-vec-length
      (write-float-vector queue output-buf
                          (make-list output-vec-length :initial-element 0.0))
      (write-float-cell queue output-buf 0.0)))

(defun %vad-seed-grad-output (queue grad-buf output-vec-length seed-value)
  "Writes the backward gradient seed: SEED-VALUE for a cell output, or
   SEED-VALUE replicated across all elements for a vector output."
  (if output-vec-length
      (write-float-vector queue grad-buf
                          (make-list output-vec-length :initial-element seed-value))
      (write-float-cell queue grad-buf seed-value)))

(defun %vad-make-descriptors (inputs at-points &optional structs output-vec-length
                                                        output-mat-dims
                              &key (fwd-prefix-args 0) (bwd-prefix-args 0))
  "Builds the per-input descriptor list, threading cumulative arg offsets.

   STRUCTS is a list of parent-name strings declared as `struct=...` in
   the directive.  Any input whose dotted-name parent appears in STRUCTS
   is folded into a single :struct-by-value descriptor (one kernel arg
   carrying the packed struct value, plus a single shadow-struct grad
   cell as &out).  Inputs not folded keep their normal classification.

   Each descriptor is a plist with these keys pre-allocated:
     :name :value :kind :length :perturb-i
     :arg-width :fwd-arg-base :bwd-arg-base
     :grad-arg-width :grad-arg-base
     :buffer :grad-buffer
   And for :struct-by-value also:
     :fields :total-bytes :grad-bytes

   Returns (values DESCRIPTORS OUTPUT-FWD-BASE OUTPUT-BWD-BASE
                   GRAD-OUTPUT-BWD-BASE)."
  (let ((descs nil)
        ;; Both bases start at their respective prefix counts so any
        ;; implicit local-scratch vectors at the head of the kernel
        ;; signature are accounted for before user-declared inputs.
        (fwd-base fwd-prefix-args)
        (bwd-base bwd-prefix-args)
        (struct-descs-by-name (make-hash-table :test 'equal)))
    (dolist (entry inputs)
      (let* ((name (car entry))
             (value (cdr entry))
             (parent (%vad-dotted-parent name))
             (is-struct-field (and parent (member parent structs :test #'string=))))
        (cond
          (is-struct-field
           ;; Either start a new struct descriptor or extend an existing one.
           (let* ((field-name name)
                  (field-only-name (subseq name (1+ (length parent))))
                  (ftype (%vad-ftype-for-value value))
                  (existing (gethash parent struct-descs-by-name)))
             (cond
               (existing
                (let* ((fields (getf existing :fields))
                       (next-offset (* 4 (length fields)))
                       (new-field (list :name field-name
                                        :field field-only-name
                                        :value value
                                        :ftype ftype
                                        :offset next-offset)))
                  (setf (getf existing :fields)
                        (append fields (list new-field)))
                  (setf (getf existing :total-bytes)
                        (+ 4 (getf existing :total-bytes)))
                  (setf (getf existing :grad-bytes)
                        (+ 4 (getf existing :grad-bytes)))))
               (t
                (let ((sd (list :name parent
                                :value nil
                                :kind :struct-by-value
                                :length nil
                                :perturb-i nil
                                :arg-width 1
                                :fwd-arg-base fwd-base
                                :bwd-arg-base bwd-base
                                :grad-arg-width 3
                                :grad-arg-base nil
                                :buffer nil
                                :grad-buffer nil
                                :fields (list (list :name field-name
                                                    :field field-only-name
                                                    :value value
                                                    :ftype ftype
                                                    :offset 0))
                                :total-bytes 4
                                :grad-bytes 4)))
                  (setf (gethash parent struct-descs-by-name) sd)
                  (push sd descs)
                  (incf fwd-base 1)
                  (incf bwd-base 1))))))
          (t
           (let ((cls (%vad-classify-input value at-points name)))
             (push (list :name name
                         :value value
                         :kind (getf cls :kind)
                         :length (getf cls :length)
                         :rows (getf cls :rows)
                         :cols (getf cls :cols)
                         :perturb-i (getf cls :perturb-i)
                         :perturb-rc (getf cls :perturb-rc)
                         :arg-width (getf cls :arg-width)
                         :fwd-arg-base fwd-base
                         :bwd-arg-base bwd-base
                         :grad-arg-width (getf cls :grad-arg-width)
                         :grad-arg-base nil
                         :buffer nil
                         :grad-buffer nil)
                   descs)
             (incf fwd-base (getf cls :arg-width))
             (incf bwd-base (getf cls :arg-width)))))))
    (setf descs (nreverse descs))
    ;; Output is either a cell (3 args: ptr, byte-size, offset) or a
    ;; 1D-compact vector (6 args: ptr, byte-size, offset, stride, extent, length).
    ;; output-vec-length non-nil triggers the vector ABI for the output AND
    ;; its grad (107: per-element kernels need a vector seed).
    (let* ((output-width (cond (output-mat-dims 9) (output-vec-length 6) (t 3)))
           (output-fwd-base fwd-base)
           (output-bwd-base bwd-base)
           (grad-output-bwd-base (+ output-bwd-base output-width))
           (grad-input-base     (+ grad-output-bwd-base output-width)))
      (let ((cur grad-input-base))
        (dolist (d descs)
          (setf (getf d :grad-arg-base) cur)
          (incf cur (getf d :grad-arg-width))))
      (values descs output-fwd-base output-bwd-base grad-output-bwd-base))))

(defun %vad-output-length-for-input (desc)
  "Returns the buffer element count needed for a forward input buffer,
   or NIL when no buffer is needed (plain scalars / struct-by-value bound directly)."
  (case (getf desc :kind)
    (:scalar-float       1)
    (:vector-float       (getf desc :length))
    (:matrix-float       (getf desc :length))   ; rows*cols (145 P6)
    (:scalar-float-plain nil)   ; no forward buffer; bound on each launch
    (:scalar-int32-plain nil)   ; no forward buffer; bound on each launch
    (:scalar-ulong       nil)
    (:struct-by-value    nil))) ; no fwd buffer; bytes packed each launch

(defun %vad-grad-bytes-for (desc)
  "Returns byte-size for the gradient buffer for input DESC."
  (case (getf desc :kind)
    (:scalar-float       4)                            ; cell of float
    (:scalar-float-plain 4)                            ; cell of float
    (:scalar-int32-plain 4)                            ; cell of float (int->float-grad)
    (:scalar-ulong       8)                            ; cell of double
    (:vector-float       (* 4 (getf desc :length)))    ; vector of float
    (:matrix-float       (* 4 (getf desc :length)))    ; matrix of float (145 P6)
    (:struct-by-value    (getf desc :grad-bytes))))    ; shadow struct bytes


(defun verify-autodiff (fwd-spv-path bwd-spv-path fwd-kernel-name
                       &key
                         (bwd-kernel-name (concatenate 'string fwd-kernel-name "_grad"))
                         inputs
                         at-points
                         structs
                         output-vec-length
                         ;; 145 (P6): (ROWS COLS) when the kernel's output is a 2-D
                         ;; matrix.  output-vec-length is set to ROWS*COLS alongside it,
                         ;; so every buffer-sized path (read-y, zero, seed) works
                         ;; unchanged; this only widens the ABI to 9 args and switches
                         ;; the binding.
                         output-mat-dims
                         ;; 145 (P6): threads per group.  1 = pre-145 behaviour.
                         (group-size 1)
                         ;; 145 (P8): number of workgroups.  >1 exercises the backward's
                         ;; cross-workgroup atomic gradient accumulation.
                         (group-count 1)
                         fwd-implicit-params
                         bwd-implicit-params
                         (seed-grad 1.0)
                         (h 1e-3)
                         (atol 1e-2)
                         verbose)
  "On-metal AD verification for a Crisp differentiable kernel.

   INPUTS is an alist (NAME-STRING . VALUE) in declaration order.  VALUE is:
     - a real number      -> scalar cell-of-float input (kernel takes 3 args)
     - an integer         -> scalar ulong input         (kernel takes 1 arg)
     - a list of reals    -> 1D contiguous-compact      (kernel takes 6 args)

   AT-POINTS is an alist (NAME-STRING . INDEX) giving the perturbation /
   comparison index for each vector input.

   Output is assumed to be a single (cell float) at the kernel boundary.

   For each PERTURBABLE input (scalar-float or vector-float-with-at):
     - Run forward at +h / -h perturbation -> central-difference FD.
   Then one backward run with all primals + seed-grad reads analytical
   gradients (scalar inputs: full cell; vector inputs: value at at-index).
   Per-input |analytical - numerical| is compared against ATOL.

   Returns (values PASS-P RESULTS).  RESULTS is a list of plists, one per
   perturbable input, in declaration order:
       (:name <string>
        :analytical <float>
        :numerical <float>
        :diff <float>)

   Phase 5b scope (endeavor 103): single (cell float) output; 1D compact
   vectors only.  Multi-dim tensors / records / structs are later phases."
  (flet ((vlog (control &rest args)
           (when verbose (apply #'format t control args))))
    (let* ((context nil) (queue nil)
           (fwd-program nil) (fwd-kernel nil)
           (bwd-program nil) (bwd-kernel nil)
           (descs nil) (output-fwd-base nil) (output-bwd-base nil)
           (grad-output-bwd-base nil)
           (output-buf nil) (output-grad-buf nil)
           (pass-p nil) (results nil))
      (unwind-protect
          (progn
           (when (null inputs)
             (error "VERIFY-AUTODIFF: no inputs supplied"))

           ;; Sum implicit-param arg widths (default 6 per local-scratch
           ;; vector).  Both kernels can carry implicit params: the
           ;; forward kernel via user (let ((tile (make-scratch-vector
           ;; ...)))), the backward via AD-minted tile_ADJ shadows.
           (let ((fwd-prefix-args
                  (reduce #'+ fwd-implicit-params
                          :key (lambda (p) (getf p :arg-width 6))
                          :initial-value 0))
                 (bwd-prefix-args
                  (reduce #'+ bwd-implicit-params
                          :key (lambda (p) (getf p :arg-width 6))
                          :initial-value 0)))
             (multiple-value-setq (descs output-fwd-base output-bwd-base grad-output-bwd-base)
               (%vad-make-descriptors inputs at-points structs output-vec-length
                                      output-mat-dims
                                      :fwd-prefix-args fwd-prefix-args
                                      :bwd-prefix-args bwd-prefix-args)))

           (multiple-value-bind (ctx q) (runtime-init)
             (setf context ctx
                   queue   q))

           (vlog "~&;   Loading kernels: ~a / ~a (~a input~:p)~%"
                 fwd-kernel-name bwd-kernel-name (length inputs))
           (let ((fwd-spv (read-spv-file fwd-spv-path))
                 (bwd-spv (read-spv-file bwd-spv-path)))
             (multiple-value-bind (p k) (create-program-and-kernel context fwd-spv fwd-kernel-name)
               (setf fwd-program p fwd-kernel k))
             (multiple-value-bind (p k) (create-program-and-kernel context bwd-spv bwd-kernel-name)
               (setf bwd-program p bwd-kernel k)))

           ;; --- Allocate input/grad buffers per descriptor.
           (dolist (d descs)
             (let ((n (%vad-output-length-for-input d)))
               (when n
                 (setf (getf d :buffer) (create-float-buffer context n))))
             ;; Grad buffer is always a single allocation; its byte-size depends
             ;; on kind (4 for float-cell, 8 for double-cell, 4*len for vector).
             (setf (getf d :grad-buffer)
                   (runtime-create-grad-buffer context (%vad-grad-bytes-for d))))
           ;; Output buffer: 1 element for scalar-cell output, N for vector.
           ;; Grad output (seed) buffer: same shape as output.
           (setf output-buf
                 (if output-vec-length
                     (create-float-buffer context output-vec-length)
                     (create-float-cell-buffer context))
                 output-grad-buf
                 (if output-vec-length
                     (create-float-buffer context output-vec-length)
                     (create-float-cell-buffer context)))

           (labels
               ((arg-base-for (d kernel)
                  "Picks DESC's arg-base based on which kernel we're binding to.
                   For the backward kernel this includes the implicit-param
                   prefix offset already baked into :bwd-arg-base."
                  (cond
                   ((eq kernel fwd-kernel) (getf d :fwd-arg-base))
                   ((eq kernel bwd-kernel) (getf d :bwd-arg-base))
                   (t (error "arg-base-for: unknown kernel handle ~A" kernel))))
                (apply-primals (kernel perturb-desc delta &optional perturb-field)
                  "Stages every input for the next launch of KERNEL.
                   When PERTURB-DESC is non-NIL, perturbs that input by DELTA.
                   PERTURB-FIELD names the specific :struct-by-value field to
                   perturb (the field-name string, e.g. \"P.x\"); ignored for
                   non-struct inputs."
                  (dolist (d descs)
                    (case (getf d :kind)
                      (:scalar-float
                       (let* ((v (cl:float (getf d :value) 1.0))
                              (vv (if (eq d perturb-desc)
                                      (cl:float (+ v delta) 1.0) v)))
                         (write-float-cell queue (getf d :buffer) vv)))
                      (:scalar-float-plain
                       (let* ((v (cl:float (getf d :value) 1.0))
                              (vv (if (eq d perturb-desc)
                                      (cl:float (+ v delta) 1.0) v)))
                         (bind-float-scalar-arg kernel (arg-base-for d kernel) vv)))
                      (:scalar-int32-plain
                       (bind-int32-scalar-arg kernel (arg-base-for d kernel) (getf d :value)))
                      (:scalar-ulong
                       (bind-uint64-scalar-arg kernel (arg-base-for d kernel) (getf d :value)))
                      ;; 145 (P6): matrices share this path — :perturb-i is a FLAT index
                      ;; and the device buffer is flat row-major.
                      ((:vector-float :matrix-float)
                       (let* ((vals (%vad-flatten-values (getf d :value)))
                              (i    (getf d :perturb-i))
                              (perturbed
                               (if (eq d perturb-desc)
                                   (loop for v in vals
                                         for k from 0
                                         collect (if (eql k i)
                                                     (+ (cl:float v 1.0) delta)
                                                     v))
                                   vals)))
                         (write-float-vector queue (getf d :buffer) perturbed)))
                      (:struct-by-value
                       (let* ((fields-raw (getf d :fields))
                              (perturbed-fields
                               (if (and (eq d perturb-desc) perturb-field)
                                   (loop for f in fields-raw
                                         collect (if (string= (getf f :name) perturb-field)
                                                     (let ((f2 (copy-list f)))
                                                       (setf (getf f2 :value)
                                                             (+ (cl:float (getf f :value) 1.0) delta))
                                                       f2)
                                                     f))
                                   fields-raw)))
                         (bind-struct-by-value-arg kernel (arg-base-for d kernel)
                                                   perturbed-fields
                                                   (getf d :total-bytes)))))))
                (bind-static-input-args (kernel)
                  "Binds the inputs that have a persistent backing buffer
                   (cells and vectors).  Plain floats, ulongs, and structs
                   are bound on every iteration by APPLY-PRIMALS."
                  (dolist (d descs)
                    (let ((base (arg-base-for d kernel)))
                      (case (getf d :kind)
                        (:scalar-float (bind-cell-arg kernel base (getf d :buffer)))
                        (:vector-float (bind-vector-arg kernel base (getf d :buffer) (getf d :length)))
                        ;; 145 (P6)
                        (:matrix-float (bind-matrix-arg kernel base (getf d :buffer)
                                                        (getf d :rows) (getf d :cols)))))))
                (bind-grad-args ()
                  (dolist (d descs)
                    (let ((base (getf d :grad-arg-base)))
                      (case (getf d :kind)
                        ((:scalar-float :scalar-float-plain :scalar-int32-plain)
                         (bind-cell-arg bwd-kernel base (getf d :grad-buffer)))
                        (:scalar-ulong
                         (bind-cell-arg bwd-kernel base (getf d :grad-buffer)
                                        :byte-size 8))
                        (:vector-float
                         (bind-vector-arg bwd-kernel base (getf d :grad-buffer)
                                          (getf d :length)))
                        ;; 145 (P6)
                        (:matrix-float
                         (bind-matrix-arg bwd-kernel base (getf d :grad-buffer)
                                          (getf d :rows) (getf d :cols)))
                        (:struct-by-value
                         ;; Shadow grad cell: cell-of-shadow-struct (byte_size = sum
                         ;; of shadow-promoted field sizes, 4 per field for phase B).
                         (bind-cell-arg bwd-kernel base (getf d :grad-buffer)
                                        :byte-size (getf d :grad-bytes)))))))
                (zero-grads ()
                  (dolist (d descs)
                    (case (getf d :kind)
                      ((:scalar-float :scalar-float-plain :scalar-int32-plain)
                       (write-float-cell queue (getf d :grad-buffer) 0.0))
                      ((:vector-float :matrix-float)   ; 145 (P6)
                       (write-float-vector queue (getf d :grad-buffer)
                                           (make-list (getf d :length)
                                                      :initial-element 0.0)))
                      (:scalar-ulong
                       (cffi:with-foreign-object (data :uint64 1)
                         (setf (cffi:mem-aref data :uint64 0) 0)
                         (write-bytes-to-buffer queue (getf d :grad-buffer) data 8)))
                      (:struct-by-value
                       (let ((nbytes (getf d :grad-bytes)))
                         (cffi:with-foreign-object (data :uint8 nbytes)
                           (loop for i from 0 below nbytes
                                 do (setf (cffi:mem-aref data :uint8 i) 0))
                           (write-bytes-to-buffer queue (getf d :grad-buffer) data nbytes))))))))

             ;; Bind any forward-kernel implicit-params (local-mem scratch
             ;; vectors declared via make-scratch-vector inside the kernel).
             ;; Must precede static input binds so the declared input slots
             ;; line up.
             (dolist (p fwd-implicit-params)
               (case (getf p :arg-width)
                 ;; 145 (P6): a 2-D local scratch tile is 9 args.  An MMA backward has
                 ;; several (the forward's staged tiles, their _ADJ pairs, and the
                 ;; backward's own transposed-operand staging).
                 (9 (bind-local-scratch-matrix-arg
                     fwd-kernel (getf p :base)
                     (getf p :rows) (getf p :cols) (getf p :elem-bytes)))
                 (6 (bind-local-scratch-vector-arg
                     fwd-kernel (getf p :base)
                     (getf p :n-elements) (getf p :elem-bytes)))
                 (t (bind-local-scratch-cell-arg
                     fwd-kernel (getf p :base) (getf p :elem-bytes)))))
             ;; Static binds: buffer-backed inputs bound once.
             (bind-static-input-args fwd-kernel)
             (cond
               (output-mat-dims                                   ; 145 (P6)
                (bind-matrix-arg fwd-kernel output-fwd-base output-buf
                                 (first output-mat-dims) (second output-mat-dims)))
               (output-vec-length
                (bind-vector-arg fwd-kernel output-fwd-base output-buf output-vec-length))
               (t (bind-cell-arg fwd-kernel output-fwd-base output-buf)))
             ;; Backward-kernel implicit-params: the original scratch tiles
             ;; PLUS any AD-minted tile_ADJ shadows.
             (dolist (p bwd-implicit-params)
               (case (getf p :arg-width)
                 ;; 145 (P6): a 2-D local scratch tile is 9 args.  An MMA backward has
                 ;; several (the forward's staged tiles, their _ADJ pairs, and the
                 ;; backward's own transposed-operand staging).
                 (9 (bind-local-scratch-matrix-arg
                     bwd-kernel (getf p :base)
                     (getf p :rows) (getf p :cols) (getf p :elem-bytes)))
                 (6 (bind-local-scratch-vector-arg
                     bwd-kernel (getf p :base)
                     (getf p :n-elements) (getf p :elem-bytes)))
                 (t (bind-local-scratch-cell-arg
                     bwd-kernel (getf p :base) (getf p :elem-bytes)))))
             (bind-static-input-args bwd-kernel)
             (if output-vec-length
                 (progn
                   (if output-mat-dims                            ; 145 (P6)
                       (progn
                         (bind-matrix-arg bwd-kernel output-bwd-base output-buf
                                          (first output-mat-dims) (second output-mat-dims))
                         (bind-matrix-arg bwd-kernel grad-output-bwd-base output-grad-buf
                                          (first output-mat-dims) (second output-mat-dims)))
                       (progn
                         (bind-vector-arg bwd-kernel output-bwd-base       output-buf      output-vec-length)
                         (bind-vector-arg bwd-kernel grad-output-bwd-base  output-grad-buf output-vec-length))))
                 (progn
                   (bind-cell-arg bwd-kernel output-bwd-base       output-buf)
                   (bind-cell-arg bwd-kernel grad-output-bwd-base  output-grad-buf)))
             (bind-grad-args)

             ;; --- Forward at unperturbed primals, capture Y.
             ;; Y is scalar for cell output, sum-of-elements for vector output.
             ;; The vector case treats f(A) = sum_i C[i] = dot(C, all-ones-seed);
             ;; df/dA[k] = sum_i (dC[i]/dA[k]) which is exactly the per-element
             ;; gradient summed across the output vector — the same value that
             ;; AD writes into A_grad[k].
             (apply-primals fwd-kernel nil 0.0)
             (if output-vec-length
                 (write-float-vector queue output-buf
                                     (make-list output-vec-length :initial-element 0.0))
                 (%vad-zero-output queue output-buf output-vec-length))
             (launch-kernel-1d queue fwd-kernel :group-size group-size :global-size group-count)
             (let ((y-at-primals (%vad-read-y queue output-buf output-vec-length)))
               (vlog "~&;   y(primals) = ~a~%" y-at-primals)

               ;; --- Per-input central-difference FD --------------------
               (let ((fd-rows nil))
                 (dolist (d descs)
                   (case (getf d :kind)
                     (:scalar-ulong nil) ; skip
                     (:scalar-int32-plain
                      ;; Int has no continuous derivative.  Mark numerical as
                      ;; :skipped so the FD-vs-analytical comparison ignores
                      ;; this field.  Authors should use expect.<name>=<value>
                      ;; in the directive to verify the analytical grad
                      ;; against whatever the AD machinery's known result is
                      ;; (e.g. 0.0 for record-at-boundary int fields; the
                      ;; chain-rule value for struct-at-boundary int fields
                      ;; via the shadow-struct mechanism).
                      (push (cons (getf d :name) :skipped) fd-rows)
                      (vlog "~&;   d/d~a: skipped (int — no FD comparison)~%"
                            (getf d :name)))
                     ((:scalar-float :scalar-float-plain)
                      (apply-primals fwd-kernel d h)
                      (%vad-zero-output queue output-buf output-vec-length)
                      (launch-kernel-1d queue fwd-kernel :group-size group-size :global-size group-count)
                      (let ((y-plus (%vad-read-y queue output-buf output-vec-length)))
                        (apply-primals fwd-kernel d (- h))
                        (%vad-zero-output queue output-buf output-vec-length)
                        (launch-kernel-1d queue fwd-kernel :group-size group-size :global-size group-count)
                        (let* ((y-minus (%vad-read-y queue output-buf output-vec-length))
                               (grad (/ (- y-plus y-minus) (* 2.0 h))))
                          (push (cons (getf d :name) grad) fd-rows)
                          (vlog "~&;   d/d~a: y+=~a y-=~a num=~a~%"
                                (getf d :name) y-plus y-minus grad))))
                     ((:vector-float :matrix-float)     ; 145 (P6)
                      (let ((at (getf d :perturb-i)))
                        (when at
                          (apply-primals fwd-kernel d h)
                          (%vad-zero-output queue output-buf output-vec-length)
                          (launch-kernel-1d queue fwd-kernel :group-size group-size :global-size group-count)
                          (let ((y-plus (%vad-read-y queue output-buf output-vec-length)))
                            (apply-primals fwd-kernel d (- h))
                            (%vad-zero-output queue output-buf output-vec-length)
                            (launch-kernel-1d queue fwd-kernel :group-size group-size :global-size group-count)
                            (let* ((y-minus (%vad-read-y queue output-buf output-vec-length))
                                   (grad (/ (- y-plus y-minus) (* 2.0 h))))
                              (push (cons (getf d :name) grad) fd-rows)
                              (vlog "~&;   d/d~a[~a]: y+=~a y-=~a num=~a~%"
                                    (getf d :name) at y-plus y-minus grad))))))
                     (:struct-by-value
                      ;; FD per float field; int fields mark numerical as
                      ;; :skipped (see :scalar-int32-plain comment above).
                      (dolist (f (getf d :fields))
                        (let ((fname (getf f :name)))
                          (case (getf f :ftype)
                            (:int32
                             (push (cons fname :skipped) fd-rows)
                             (vlog "~&;   d/d~a: skipped (int field — no FD comparison)~%" fname))
                            (:float
                             (apply-primals fwd-kernel d h fname)
                             (%vad-zero-output queue output-buf output-vec-length)
                             (launch-kernel-1d queue fwd-kernel :group-size group-size :global-size group-count)
                             (let ((y-plus (%vad-read-y queue output-buf output-vec-length)))
                               (apply-primals fwd-kernel d (- h) fname)
                               (%vad-zero-output queue output-buf output-vec-length)
                               (launch-kernel-1d queue fwd-kernel :group-size group-size :global-size group-count)
                               (let* ((y-minus (%vad-read-y queue output-buf output-vec-length))
                                      (grad (/ (- y-plus y-minus) (* 2.0 h))))
                                 (push (cons fname grad) fd-rows)
                                 (vlog "~&;   d/d~a (struct field): y+=~a y-=~a num=~a~%"
                                       fname y-plus y-minus grad))))))))))

                 ;; --- Backward with primals + seed.
                 ;; The FD loop's last forward perturbation left output-buf in
                 ;; a perturbed state.  For cell outputs we restore y-at-primals
                 ;; directly; for vector outputs we re-run the unperturbed
                 ;; forward to repopulate the buffer with the correct per-element
                 ;; primals (we never saved the vector, only its scalar sum).
                 (apply-primals bwd-kernel nil 0.0)
                 (if output-vec-length
                     (progn
                       (apply-primals fwd-kernel nil 0.0)
                       (%vad-zero-output queue output-buf output-vec-length)
                       (launch-kernel-1d queue fwd-kernel :group-size group-size :global-size group-count))
                     (write-float-cell queue output-buf y-at-primals))
                 (%vad-seed-grad-output queue output-grad-buf output-vec-length
                                        (cl:float seed-grad 1.0))
                 (zero-grads)
                 (launch-kernel-1d queue bwd-kernel :group-size group-size :global-size group-count)

                 ;; --- Read analytical grads per perturbable input.
                 (let ((ana-rows nil))
                   (dolist (d descs)
                     (case (getf d :kind)
                       (:scalar-ulong nil)
                       ((:scalar-float :scalar-float-plain :scalar-int32-plain)
                        (push (cons (getf d :name)
                                    (read-float-cell queue (getf d :grad-buffer)))
                              ana-rows))
                       ((:vector-float :matrix-float)   ; 145 (P6)
                        (let ((at (getf d :perturb-i)))
                          (when at
                            (push (cons (getf d :name)
                                        (read-float-vector-elem queue
                                                                (getf d :grad-buffer)
                                                                at))
                                  ana-rows))))
                       (:struct-by-value
                        ;; Read N floats from the shadow grad cell, in field
                        ;; declaration order (offsets 0, 4, 8, ...).
                        (let ((nbytes (getf d :grad-bytes)))
                          (cffi:with-foreign-object (raw :uint8 nbytes)
                            (read-bytes-from-buffer queue (getf d :grad-buffer) raw nbytes)
                            (format *error-output* "~&[DBG] struct ~A grad raw bytes:" (getf d :name))
                            (loop for i from 0 below nbytes
                                  do (format *error-output* " ~2,'0X" (cffi:mem-aref raw :uint8 i)))
                            (format *error-output* "~%")))
                        (loop for f in (getf d :fields)
                              for i from 0
                              do (push (cons (getf f :name)
                                             (read-float-vector-elem queue
                                                                     (getf d :grad-buffer)
                                                                     i))
                                       ana-rows)))))

                   (setf fd-rows  (nreverse fd-rows)
                         ana-rows (nreverse ana-rows))
                   ;; Build per-field results.  When FD was skipped (int
                   ;; fields), :numerical and :diff are :skipped and pass-p
                   ;; ignores those entries; expect.<name> still verifies
                   ;; :analytical against the directive's value.
                   (setf results
                         (loop for (name . num) in fd-rows
                               for ana = (cdr (assoc name ana-rows :test #'string=))
                               collect (list :name name
                                             :analytical ana
                                             :numerical num
                                             :diff (if (eq num :skipped)
                                                       :skipped
                                                       (abs (- ana num))))))
                   (setf pass-p (every (lambda (r)
                                         (or (eq (getf r :diff) :skipped)
                                             (< (getf r :diff) atol)))
                                       results))
                   (vlog "~&;   pass-p = ~a~%" pass-p))))))

        ;; Cleanup
        (when output-buf      (runtime-release-buffer context output-buf))
        (when output-grad-buf (runtime-release-buffer context output-grad-buf))
        (dolist (d descs)
          (when (getf d :buffer)      (runtime-release-buffer context (getf d :buffer)))
          (when (getf d :grad-buffer) (runtime-release-buffer context (getf d :grad-buffer))))
        (when fwd-kernel  (runtime-release-kernel fwd-kernel))
        (when fwd-program (runtime-release-program fwd-program))
        (when bwd-kernel  (runtime-release-kernel bwd-kernel))
        (when bwd-program (runtime-release-program bwd-program))
        (runtime-shutdown context queue))

      (values pass-p results))))


;;; ======================================================================
;;; === Level Zero helpers (parallel to the opencl-* layer above) ========
;;; ======================================================================
;;;
;;; Each l0-* helper has the same arity and same logical role as the
;;; matching opencl-* helper, so the dispatch shim below can pick between
;;; them on (*ad-runtime*) without the caller (or VERIFY-AUTODIFF body)
;;; knowing which runtime is in play.
;;;
;;; Two adapter notes:
;;;
;;;   1. The "queue" arg the OpenCL helpers take is ignored under L0:
;;;      USM-shared allocations are host-addressable, so read/write are
;;;      just (setf (cffi:mem-ref ...)).  And dispatch creates a fresh
;;;      command queue + list per launch (cheap and stateless; can be
;;;      pooled later if it shows up in profiling).
;;;
;;;   2. The L0 device handle is held in *AD-DEVICE* (a dynamic var),
;;;      set by RUNTIME-INIT before any L0 helper runs.  Helpers that
;;;      need the device read it from there instead of taking it as
;;;      an extra arg, preserving the OpenCL-helper signatures.

(defun l0-make-zeroed-struct (struct-name)
  "Allocate a foreign struct sized for STRUCT-NAME and zero-fill it.
   Caller must (cffi:foreign-free) the returned pointer."
  (let* ((n (cffi:foreign-type-size (list :struct struct-name)))
         (p (cffi:foreign-alloc :uchar :count n)))
    (loop for i from 0 below n do (setf (cffi:mem-aref p :uchar i) 0))
    p))

(defun l0-create-program-and-kernel (context spv-data kernel-name)
  "L0 counterpart of OPENCL-CREATE-PROGRAM-AND-KERNEL.  CONTEXT is the
   L0 ze_context_handle_t.  Reads device from *AD-DEVICE*.  Returns
   (values module kernel) where MODULE plays the role OpenCL's program
   plays (release with ZE-MODULE-DESTROY)."
  (let* ((il-len (length spv-data))
         (il-ptr (cffi:foreign-alloc :uchar :count il-len))
         (desc   (l0-make-zeroed-struct 'ze-module-desc))
         (kdesc  (l0-make-zeroed-struct 'ze-kernel-desc))
         (name-bytes (length kernel-name))
         (name-c (cffi:foreign-alloc :char :count (1+ name-bytes))))
    (unwind-protect
        (progn
         (loop for i from 0 below il-len
               do (setf (cffi:mem-aref il-ptr :uchar i) (aref spv-data i)))
         (setf (cffi:foreign-slot-value desc '(:struct ze-module-desc) 'stype)
               +ZE-STYPE-MODULE-DESC+
               (cffi:foreign-slot-value desc '(:struct ze-module-desc) 'format)
               +ZE-MODULE-FORMAT-IL-SPIRV+
               (cffi:foreign-slot-value desc '(:struct ze-module-desc) 'input-size)
               il-len
               (cffi:foreign-slot-value desc '(:struct ze-module-desc) 'p-input-module)
               il-ptr)
         (cffi:with-foreign-objects ((mod-out :pointer) (log-out :pointer))
           (setf (cffi:mem-ref log-out :pointer) (cffi:null-pointer))
           (let ((err (ze-module-create context *ad-device* desc mod-out log-out)))
             (unless (= err +ZE-RESULT-SUCCESS+)
               (let ((blog (ze-fetch-build-log (cffi:mem-ref log-out :pointer))))
                 (error "L0 zeModuleCreate(~a) failed: 0x~X~@[~%  build log:~%~A~]"
                        kernel-name err blog)))
             (let ((module (cffi:mem-ref mod-out :pointer))
                   (log    (cffi:mem-ref log-out :pointer)))
               (unless (cffi:null-pointer-p log)
                 (ze-module-build-log-destroy log))
               (loop for i from 0 below name-bytes
                     do (setf (cffi:mem-aref name-c :char i)
                              (char-code (char kernel-name i))))
               (setf (cffi:mem-aref name-c :char name-bytes) 0)
               (setf (cffi:foreign-slot-value kdesc '(:struct ze-kernel-desc) 'stype)
                     +ZE-STYPE-KERNEL-DESC+
                     (cffi:foreign-slot-value kdesc '(:struct ze-kernel-desc) 'p-kernel-name)
                     name-c)
               (cffi:with-foreign-object (kern-out :pointer)
                 (check-ze (ze-kernel-create module kdesc kern-out))
                 (values module (cffi:mem-ref kern-out :pointer)))))))
      (cffi:foreign-free il-ptr)
      (cffi:foreign-free desc)
      (cffi:foreign-free kdesc)
      (cffi:foreign-free name-c))))

(defun l0-alloc-shared (context bytes alignment)
  "Allocate a USM-shared buffer of BYTES with ALIGNMENT.  Returns the
   host-addressable pointer."
  (let ((dev-desc (l0-make-zeroed-struct 'ze-device-mem-alloc-desc))
        (hst-desc (l0-make-zeroed-struct 'ze-host-mem-alloc-desc)))
    (unwind-protect
        (progn
         (setf (cffi:foreign-slot-value dev-desc '(:struct ze-device-mem-alloc-desc) 'stype)
               +ZE-STYPE-DEVICE-MEM-ALLOC-DESC+
               (cffi:foreign-slot-value hst-desc '(:struct ze-host-mem-alloc-desc) 'stype)
               +ZE-STYPE-HOST-MEM-ALLOC-DESC+)
         (cffi:with-foreign-object (pp :pointer)
           (check-ze (ze-mem-alloc-shared context dev-desc hst-desc bytes alignment
                                          *ad-device* pp))
           (cffi:mem-ref pp :pointer)))
      (cffi:foreign-free dev-desc)
      (cffi:foreign-free hst-desc))))

(defun l0-create-float-cell-buffer (context)
  (l0-alloc-shared context 4 4))

(defun l0-write-float-cell (queue buffer value)
  (declare (ignore queue))
  (setf (cffi:mem-ref buffer :float) (cl:float value 1.0)))

(defun l0-read-float-cell (queue buffer)
  (declare (ignore queue))
  (cffi:mem-ref buffer :float))

(defun l0-create-float-buffer (context n-elements)
  (l0-alloc-shared context (* 4 n-elements) 4))

(defun l0-write-float-vector (queue buffer values)
  (declare (ignore queue))
  (loop for v in values
        for i from 0
        do (setf (cffi:mem-aref buffer :float i) (cl:float v 1.0))))

(defun l0-opencl-read-float-vector (queue buffer n)
  (declare (ignore queue))
  (loop for i from 0 below n
        collect (cffi:mem-aref buffer :float i)))

(defun l0-opencl-read-float-vector-elem (queue buffer i)
  (declare (ignore queue))
  (cffi:mem-aref buffer :float i))

(defun l0-bind-cell-arg (kernel base-index buffer &key (byte-size 4) (offset 0))
  "L0 cell binding: 3 args at BASE-INDEX, BASE+1, BASE+2."
  (cffi:with-foreign-objects ((p-ptr :pointer) (p-bs :uint64) (p-off :uint64))
    (setf (cffi:mem-ref p-ptr :pointer) buffer
          (cffi:mem-ref p-bs :uint64) byte-size
          (cffi:mem-ref p-off :uint64) offset)
    (check-ze (ze-kernel-set-argument-value kernel (+ base-index 0)
                                            (cffi:foreign-type-size :pointer) p-ptr))
    (check-ze (ze-kernel-set-argument-value kernel (+ base-index 1)
                                            (cffi:foreign-type-size :uint64) p-bs))
    (check-ze (ze-kernel-set-argument-value kernel (+ base-index 2)
                                            (cffi:foreign-type-size :uint64) p-off))))

(defun l0-bind-vector-arg (kernel base-index buffer length)
  "L0 1D-vector binding: 6 args (ptr, parent-byte_size, offset, stride[0],
   extent[0], length).  Mirrors OPENCL-BIND-VECTOR-ARG exactly."
  (cffi:with-foreign-objects ((p-ptr :pointer)
                              (p-bs :uint64) (p-off :uint64)
                              (p-stride :uint64) (p-extent :uint64) (p-len :uint64))
    (setf (cffi:mem-ref p-ptr :pointer) buffer
          (cffi:mem-ref p-bs :uint64) (* 4 length)
          (cffi:mem-ref p-off :uint64) 0
          (cffi:mem-ref p-stride :uint64) 1
          (cffi:mem-ref p-extent :uint64) length
          (cffi:mem-ref p-len :uint64) length)
    (check-ze (ze-kernel-set-argument-value kernel (+ base-index 0)
                                            (cffi:foreign-type-size :pointer) p-ptr))
    (check-ze (ze-kernel-set-argument-value kernel (+ base-index 1)
                                            (cffi:foreign-type-size :uint64) p-bs))
    (check-ze (ze-kernel-set-argument-value kernel (+ base-index 2)
                                            (cffi:foreign-type-size :uint64) p-off))
    (check-ze (ze-kernel-set-argument-value kernel (+ base-index 3)
                                            (cffi:foreign-type-size :uint64) p-stride))
    (check-ze (ze-kernel-set-argument-value kernel (+ base-index 4)
                                            (cffi:foreign-type-size :uint64) p-extent))
    (check-ze (ze-kernel-set-argument-value kernel (+ base-index 5)
                                            (cffi:foreign-type-size :uint64) p-len))))

(defun l0-bind-matrix-arg (kernel base-index buffer rows cols)
  "L0 2-D matrix binding: 9 args.  Mirrors OPENCL-BIND-MATRIX-ARG exactly."
  (cffi:with-foreign-objects ((a0 :pointer) (a1 :uint64) (a2 :uint64) (a3 :uint64)
                              (a4 :uint64) (a5 :uint64) (a6 :uint64) (a7 :uint64)
                              (a8 :uint64))
    (setf (cffi:mem-ref a0 :pointer) buffer
          (cffi:mem-ref a1 :uint64) (* 4 rows cols)
          (cffi:mem-ref a2 :uint64) 0
          (cffi:mem-ref a3 :uint64) 0
          (cffi:mem-ref a4 :uint64) cols
          (cffi:mem-ref a5 :uint64) 1
          (cffi:mem-ref a6 :uint64) rows
          (cffi:mem-ref a7 :uint64) cols
          (cffi:mem-ref a8 :uint64) (* rows cols))
    (check-ze (ze-kernel-set-argument-value kernel (+ base-index 0)
                                            (cffi:foreign-type-size :pointer) a0))
    (loop for k from 1 below 9
          for obj in (list a1 a2 a3 a4 a5 a6 a7 a8)
          do (check-ze (ze-kernel-set-argument-value kernel (+ base-index k)
                                                     (cffi:foreign-type-size :uint64) obj)))))

(defun l0-bind-uint64-scalar-arg (kernel arg-index value)
  (cffi:with-foreign-object (p :uint64)
    (setf (cffi:mem-ref p :uint64) value)
    (check-ze (ze-kernel-set-argument-value kernel arg-index
                                            (cffi:foreign-type-size :uint64) p))))

(defun l0-bind-float-scalar-arg (kernel arg-index value)
  (cffi:with-foreign-object (p :float)
    (setf (cffi:mem-ref p :float) (cl:float value 1.0))
    (check-ze (ze-kernel-set-argument-value kernel arg-index
                                            (cffi:foreign-type-size :float) p))))

(defun l0-bind-int32-scalar-arg (kernel arg-index value)
  (cffi:with-foreign-object (p :int32)
    (setf (cffi:mem-ref p :int32) value)
    (check-ze (ze-kernel-set-argument-value kernel arg-index
                                            (cffi:foreign-type-size :int32) p))))

(defun l0-bind-struct-by-value-arg (kernel arg-index fields total-bytes)
  (cffi:with-foreign-object (data :uint8 total-bytes)
    (loop for i from 0 below total-bytes
          do (setf (cffi:mem-aref data :uint8 i) 0))
    (dolist (f fields)
      (let ((offset (getf f :offset))
            (ftype  (getf f :ftype))
            (value  (getf f :value)))
        (case ftype
          (:float (setf (cffi:mem-ref (cffi:inc-pointer data offset) :float)
                        (cl:float value 1.0)))
          (:int32 (setf (cffi:mem-ref (cffi:inc-pointer data offset) :int32) value))
          (t (error "l0-bind-struct-by-value-arg: unsupported ftype ~A" ftype)))))
    (check-ze (ze-kernel-set-argument-value kernel arg-index total-bytes data))))

(defun l0-opencl-launch-kernel-1d (queue kernel &key (global-size 1) (group-size 1))
  "L0 launch: sets group size to (1,1,1), launches with (GLOBAL-SIZE,1,1)
   groups.  Creates a fresh command queue + list per call (cheap; pool
   later if needed)."
  (declare (ignore queue))
  (let ((context nil))
    ;; We need the context for queue/list creation.  *ad-context* is bound
    ;; by RUNTIME-INIT.
    (setf context *ad-context*)
    ;; 145 (P6): GROUP-SIZE threads per group.  Default 1 (pre-145 behaviour); an MMA
    ;; kernel needs its full sub-group or the cooperative ops do nothing at all.
    (check-ze (ze-kernel-set-group-size kernel group-size 1 1))
    (cffi:with-foreign-objects ((gc '(:struct ze-group-count))
                                (cl-desc '(:struct ze-command-list-desc))
                                (cq-desc '(:struct ze-command-queue-desc))
                                (cl-out :pointer)
                                (cq-out :pointer)
                                (cl-arr :pointer))
      (setf (cffi:foreign-slot-value gc '(:struct ze-group-count) 'x) global-size
            (cffi:foreign-slot-value gc '(:struct ze-group-count) 'y) 1
            (cffi:foreign-slot-value gc '(:struct ze-group-count) 'z) 1)
      (loop for i from 0 below (cffi:foreign-type-size '(:struct ze-command-list-desc))
            do (setf (cffi:mem-aref cl-desc :uchar i) 0))
      (loop for i from 0 below (cffi:foreign-type-size '(:struct ze-command-queue-desc))
            do (setf (cffi:mem-aref cq-desc :uchar i) 0))
      (setf (cffi:foreign-slot-value cl-desc '(:struct ze-command-list-desc) 'stype)
            +ZE-STYPE-COMMAND-LIST-DESC+
            (cffi:foreign-slot-value cq-desc '(:struct ze-command-queue-desc) 'stype)
            +ZE-STYPE-COMMAND-QUEUE-DESC+)
      (check-ze (ze-command-list-create context *ad-device* cl-desc cl-out))
      (check-ze (ze-command-queue-create context *ad-device* cq-desc cq-out))
      (let ((cl-h (cffi:mem-ref cl-out :pointer))
            (cq-h (cffi:mem-ref cq-out :pointer)))
        (unwind-protect
            (progn
             (check-ze (ze-command-list-append-launch-kernel
                        cl-h kernel gc (cffi:null-pointer) 0 (cffi:null-pointer)))
             (check-ze (ze-command-list-close cl-h))
             (setf (cffi:mem-ref cl-arr :pointer) cl-h)
             (check-ze (ze-command-queue-execute-command-lists
                        cq-h 1 cl-arr (cffi:null-pointer)))
             (check-ze (ze-command-queue-synchronize cq-h +ZE-UINT64-MAX+)))
          (ze-command-list-destroy cl-h)
          (ze-command-queue-destroy cq-h))))))


;;; ======================================================================
;;; === Dispatch shims ===================================================
;;; ======================================================================
;;;
;;; Bare-name helpers that pick between :opencl and :l0 on (*ad-runtime*).
;;; VERIFY-AUTODIFF's body calls these unprefixed names, so flipping the
;;; runtime is a single defvar setf.
;;;
;;; Implementation note: the shims dispatch via (funcall (ecase ...) args)
;;; instead of (ecase ... (:opencl (opencl-foo args))).  The funcall form
;;; keeps the impl-fn symbols quoted ('opencl-foo, 'l0-foo) so they do
;;; NOT appear as "(opencl-foo " patterns -- which keeps text-level
;;; rename passes from accidentally turning the shims into infinite
;;; self-recursion.  Yes, this is ugly; it is also the smallest change
;;; that keeps the verify-autodiff body identical-looking under either
;;; runtime.

(defun create-program-and-kernel (context spv-data kernel-name)
  (funcall (ecase *ad-runtime*
             (:opencl 'opencl-create-program-and-kernel)
             (:l0     'l0-create-program-and-kernel))
           context spv-data kernel-name))

(defun create-float-cell-buffer (context)
  (funcall (ecase *ad-runtime*
             (:opencl 'opencl-create-float-cell-buffer)
             (:l0     'l0-create-float-cell-buffer))
           context))

(defun write-float-cell (queue buffer value)
  (funcall (ecase *ad-runtime*
             (:opencl 'opencl-write-float-cell)
             (:l0     'l0-write-float-cell))
           queue buffer value))

(defun read-float-cell (queue buffer)
  (funcall (ecase *ad-runtime*
             (:opencl 'opencl-read-float-cell)
             (:l0     'l0-read-float-cell))
           queue buffer))

(defun bind-cell-arg (kernel base-index buffer &key (byte-size 4) (offset 0))
  (funcall (ecase *ad-runtime*
             (:opencl 'opencl-bind-cell-arg)
             (:l0     'l0-bind-cell-arg))
           kernel base-index buffer :byte-size byte-size :offset offset))

(defun launch-kernel-1d (queue kernel &key (global-size 1) (group-size 1))
  (funcall (ecase *ad-runtime*
             (:opencl 'opencl-launch-kernel-1d)
             (:l0     'l0-opencl-launch-kernel-1d))
           queue kernel :global-size global-size :group-size group-size))

(defun create-float-buffer (context n-elements)
  (funcall (ecase *ad-runtime*
             (:opencl 'opencl-create-float-buffer)
             (:l0     'l0-create-float-buffer))
           context n-elements))

(defun write-float-vector (queue buffer values)
  (funcall (ecase *ad-runtime*
             (:opencl 'opencl-write-float-vector)
             (:l0     'l0-write-float-vector))
           queue buffer values))

(defun read-float-vector (queue buffer n)
  (funcall (ecase *ad-runtime*
             (:opencl 'opencl-read-float-vector)
             (:l0     'l0-opencl-read-float-vector))
           queue buffer n))

(defun read-float-vector-elem (queue buffer i)
  (funcall (ecase *ad-runtime*
             (:opencl 'opencl-read-float-vector-elem)
             (:l0     'l0-opencl-read-float-vector-elem))
           queue buffer i))

(defun bind-vector-arg (kernel base-index buffer length)
  (funcall (ecase *ad-runtime*
             (:opencl 'opencl-bind-vector-arg)
             (:l0     'l0-bind-vector-arg))
           kernel base-index buffer length))

(defun bind-matrix-arg (kernel base-index buffer rows cols)
  (funcall (ecase *ad-runtime*
             (:opencl 'opencl-bind-matrix-arg)
             (:l0     'l0-bind-matrix-arg))
           kernel base-index buffer rows cols))

(defun bind-local-scratch-matrix-arg (kernel base-index rows cols elem-bytes)
  (funcall (ecase *ad-runtime*
             (:opencl 'opencl-bind-local-scratch-matrix-arg)
             (:l0     'l0-bind-local-scratch-matrix-arg))
           kernel base-index rows cols elem-bytes))

(defun bind-uint64-scalar-arg (kernel arg-index value)
  (funcall (ecase *ad-runtime*
             (:opencl 'opencl-bind-uint64-scalar-arg)
             (:l0     'l0-bind-uint64-scalar-arg))
           kernel arg-index value))

(defun bind-float-scalar-arg (kernel arg-index value)
  (funcall (ecase *ad-runtime*
             (:opencl 'opencl-bind-float-scalar-arg)
             (:l0     'l0-bind-float-scalar-arg))
           kernel arg-index value))

(defun bind-int32-scalar-arg (kernel arg-index value)
  (funcall (ecase *ad-runtime*
             (:opencl 'opencl-bind-int32-scalar-arg)
             (:l0     'l0-bind-int32-scalar-arg))
           kernel arg-index value))

(defun bind-struct-by-value-arg (kernel arg-index fields total-bytes)
  (funcall (ecase *ad-runtime*
             (:opencl 'opencl-bind-struct-by-value-arg)
             (:l0     'l0-bind-struct-by-value-arg))
           kernel arg-index fields total-bytes))

;;; --- Byte-level buffer I/O dispatchers --------------------------------
;;;
;;; A handful of call sites in %vad-* and VERIFY-AUTODIFF copy raw bytes
;;; in or out of buffers that don't fit the float-cell / float-vector
;;; abstractions: :scalar-ulong grad buffers (8 bytes), :struct-by-value
;;; grad shadows (NBYTES), and vector outputs in %vad-read-y.  These
;;; dispatchers wrap those copies.
;;;
;;; Under :opencl the host pointer is staged in/out via cl-enqueue-*.
;;; Under :l0 the USM-shared pointer IS the host pointer, so the copy
;;; collapses to a memcpy.

(defun write-bytes-to-buffer (queue buffer host-ptr nbytes)
  "Copies NBYTES from host-pointer HOST-PTR into runtime BUFFER."
  (ecase *ad-runtime*
    (:opencl
     (check-cl (cl-enqueue-write-buffer queue buffer 1 0 nbytes host-ptr
                                        0 (cffi:null-pointer) (cffi:null-pointer))))
    (:l0
     (loop for i from 0 below nbytes
           do (setf (cffi:mem-aref buffer :uint8 i)
                    (cffi:mem-aref host-ptr :uint8 i))))))

(defun read-bytes-from-buffer (queue buffer host-ptr nbytes)
  "Copies NBYTES from runtime BUFFER into host-pointer HOST-PTR."
  (ecase *ad-runtime*
    (:opencl
     (check-cl (cl-enqueue-read-buffer queue buffer 1 0 nbytes host-ptr
                                       0 (cffi:null-pointer) (cffi:null-pointer))))
    (:l0
     (loop for i from 0 below nbytes
           do (setf (cffi:mem-aref host-ptr :uint8 i)
                    (cffi:mem-aref buffer :uint8 i))))))

;;; --- Local-scratch vector binding -------------------------------------
;;;
;;; The AD pass auto-mints a `<tile>_ADJ` shadow next to every local-mem
;;; tile that participates in a load-tile-at / store-tile-at AD
;;; expansion (and the original tile itself is also a kernel param under
;;; that rewriting).  These show up as 6-arg vector descriptors with
;;; `:local` addrspace at the start of the backward kernel's arg list,
;;; before the forward primals.
;;;
;;; Binding a :local pointer differs from binding a :global pointer:
;;;   - the pointer arg is set with HOST_PTR = NULL and arg-size =
;;;     bytes-of-local-mem-to-allocate (the runtime allocates the local
;;;     memory at launch time)
;;;   - the 5 i64 metadata args (byte_size, offset, stride[0], extent[0],
;;;     length) are set to their normal compact-vector values
;;;
;;; Both OpenCL and L0 use the same wire form.

(defun opencl-bind-local-scratch-cell-arg (kernel base-index byte-size)
  "Binds a :local addrspace cell at BASE-INDEX (3 args)."
  (cffi:with-foreign-objects ((arg1 :uint64) (arg2 :uint64))
    (setf (cffi:mem-ref arg1 :uint64) byte-size
          (cffi:mem-ref arg2 :uint64) 0)
    (check-cl (cl-set-kernel-arg kernel (+ base-index 0) byte-size (cffi:null-pointer)))
    (check-cl (cl-set-kernel-arg kernel (+ base-index 1) (cffi:foreign-type-size :uint64) arg1))
    (check-cl (cl-set-kernel-arg kernel (+ base-index 2) (cffi:foreign-type-size :uint64) arg2))))

(defun l0-bind-local-scratch-cell-arg (kernel base-index byte-size)
  "L0 counterpart: NULL pArgValue + byte-size for the local mem alloc."
  (cffi:with-foreign-objects ((p-bs :uint64) (p-off :uint64))
    (setf (cffi:mem-ref p-bs :uint64) byte-size
          (cffi:mem-ref p-off :uint64) 0)
    (check-ze (ze-kernel-set-argument-value kernel (+ base-index 0) byte-size (cffi:null-pointer)))
    (check-ze (ze-kernel-set-argument-value kernel (+ base-index 1) (cffi:foreign-type-size :uint64) p-bs))
    (check-ze (ze-kernel-set-argument-value kernel (+ base-index 2) (cffi:foreign-type-size :uint64) p-off))))

(defun bind-local-scratch-cell-arg (kernel base-index byte-size)
  (funcall (ecase *ad-runtime*
             (:opencl 'opencl-bind-local-scratch-cell-arg)
             (:l0     'l0-bind-local-scratch-cell-arg))
           kernel base-index byte-size))

(defun opencl-bind-local-scratch-vector-arg (kernel base-index n-elements elem-bytes)
  "Binds a :local addrspace 1D-compact scratch vector at BASE-INDEX (6 args)."
  (let ((byte-size (* n-elements elem-bytes)))
    (check-cl (cl-set-kernel-arg kernel (+ base-index 0) byte-size (cffi:null-pointer))))
  (cffi:with-foreign-objects ((arg1 :uint64) (arg2 :uint64)
                              (arg3 :uint64) (arg4 :uint64) (arg5 :uint64))
    (setf (cffi:mem-ref arg1 :uint64) (* n-elements elem-bytes) ; parent byte_size
          (cffi:mem-ref arg2 :uint64) 0                          ; offset
          (cffi:mem-ref arg3 :uint64) 1                          ; stride[0]
          (cffi:mem-ref arg4 :uint64) n-elements                 ; extent[0]
          (cffi:mem-ref arg5 :uint64) n-elements)                ; length
    (check-cl (cl-set-kernel-arg kernel (+ base-index 1) (cffi:foreign-type-size :uint64) arg1))
    (check-cl (cl-set-kernel-arg kernel (+ base-index 2) (cffi:foreign-type-size :uint64) arg2))
    (check-cl (cl-set-kernel-arg kernel (+ base-index 3) (cffi:foreign-type-size :uint64) arg3))
    (check-cl (cl-set-kernel-arg kernel (+ base-index 4) (cffi:foreign-type-size :uint64) arg4))
    (check-cl (cl-set-kernel-arg kernel (+ base-index 5) (cffi:foreign-type-size :uint64) arg5))))

(defun opencl-bind-local-scratch-matrix-arg (kernel base-index rows cols elem-bytes)
  "Endeavor 145 (P6): binds a :local addrspace 2-D compact scratch matrix (9 args).
   Slot 0 is the local-memory allocation (size, NULL pointer); the rest is the tensor
   record, row-major."
  (check-cl (cl-set-kernel-arg kernel (+ base-index 0) (* rows cols elem-bytes)
                               (cffi:null-pointer)))
  (cffi:with-foreign-objects ((a1 :uint64) (a2 :uint64) (a3 :uint64) (a4 :uint64)
                              (a5 :uint64) (a6 :uint64) (a7 :uint64) (a8 :uint64))
    (setf (cffi:mem-ref a1 :uint64) (* rows cols elem-bytes)
          (cffi:mem-ref a2 :uint64) 0
          (cffi:mem-ref a3 :uint64) 0
          (cffi:mem-ref a4 :uint64) cols
          (cffi:mem-ref a5 :uint64) 1
          (cffi:mem-ref a6 :uint64) rows
          (cffi:mem-ref a7 :uint64) cols
          (cffi:mem-ref a8 :uint64) (* rows cols))
    (loop for k from 1 below 9
          for obj in (list a1 a2 a3 a4 a5 a6 a7 a8)
          do (check-cl (cl-set-kernel-arg kernel (+ base-index k)
                                          (cffi:foreign-type-size :uint64) obj)))))

(defun l0-bind-local-scratch-matrix-arg (kernel base-index rows cols elem-bytes)
  "L0 counterpart: NULL pArgValue + byte-size for the local mem alloc, then the 8
   tensor-record scalars."
  (check-ze (ze-kernel-set-argument-value kernel (+ base-index 0)
                                          (* rows cols elem-bytes) (cffi:null-pointer)))
  (cffi:with-foreign-objects ((a1 :uint64) (a2 :uint64) (a3 :uint64) (a4 :uint64)
                              (a5 :uint64) (a6 :uint64) (a7 :uint64) (a8 :uint64))
    (setf (cffi:mem-ref a1 :uint64) (* rows cols elem-bytes)
          (cffi:mem-ref a2 :uint64) 0
          (cffi:mem-ref a3 :uint64) 0
          (cffi:mem-ref a4 :uint64) cols
          (cffi:mem-ref a5 :uint64) 1
          (cffi:mem-ref a6 :uint64) rows
          (cffi:mem-ref a7 :uint64) cols
          (cffi:mem-ref a8 :uint64) (* rows cols))
    (loop for k from 1 below 9
          for obj in (list a1 a2 a3 a4 a5 a6 a7 a8)
          do (check-ze (ze-kernel-set-argument-value kernel (+ base-index k)
                                                     (cffi:foreign-type-size :uint64) obj)))))

(defun l0-bind-local-scratch-vector-arg (kernel base-index n-elements elem-bytes)
  "L0 counterpart: NULL pArgValue + byte-size for the local mem alloc."
  (let ((byte-size (* n-elements elem-bytes)))
    (check-ze (ze-kernel-set-argument-value kernel (+ base-index 0)
                                            byte-size (cffi:null-pointer))))
  (cffi:with-foreign-objects ((arg1 :uint64) (arg2 :uint64)
                              (arg3 :uint64) (arg4 :uint64) (arg5 :uint64))
    (setf (cffi:mem-ref arg1 :uint64) (* n-elements elem-bytes)
          (cffi:mem-ref arg2 :uint64) 0
          (cffi:mem-ref arg3 :uint64) 1
          (cffi:mem-ref arg4 :uint64) n-elements
          (cffi:mem-ref arg5 :uint64) n-elements)
    (check-ze (ze-kernel-set-argument-value kernel (+ base-index 1)
                                            (cffi:foreign-type-size :uint64) arg1))
    (check-ze (ze-kernel-set-argument-value kernel (+ base-index 2)
                                            (cffi:foreign-type-size :uint64) arg2))
    (check-ze (ze-kernel-set-argument-value kernel (+ base-index 3)
                                            (cffi:foreign-type-size :uint64) arg3))
    (check-ze (ze-kernel-set-argument-value kernel (+ base-index 4)
                                            (cffi:foreign-type-size :uint64) arg4))
    (check-ze (ze-kernel-set-argument-value kernel (+ base-index 5)
                                            (cffi:foreign-type-size :uint64) arg5))))

(defun bind-local-scratch-vector-arg (kernel base-index n-elements elem-bytes)
  (funcall (ecase *ad-runtime*
             (:opencl 'opencl-bind-local-scratch-vector-arg)
             (:l0     'l0-bind-local-scratch-vector-arg))
           kernel base-index n-elements elem-bytes))


;;; ======================================================================
;;; === Runtime init / shutdown / per-object release =====================
;;; ======================================================================
;;;
;;; The grad-buffer allocation, context+queue lifecycle, and per-object
;;; release calls used to be inlined into VERIFY-AUTODIFF as raw cl-*
;;; calls.  They are now lifted to runtime-aware wrappers so the body
;;; is runtime-agnostic top-to-bottom.

(defun runtime-init ()
  "Initialise the active runtime (per *AD-RUNTIME*) and return
   (values context queue).  For :opencl, both are OpenCL handles.  For
   :l0, CONTEXT is a ze_context_handle_t and QUEUE is NIL (L0 launches
   create transient command queues); *AD-DEVICE* and *AD-CONTEXT* are
   also bound for L0 helpers to read."
  (ecase *ad-runtime*
    (:opencl
     (cffi:with-foreign-objects ((platforms :pointer 1)
                                 (devices :pointer 1))
       (check-cl (cl-get-platform-ids 1 platforms (cffi:null-pointer)))
       (let ((platform (cffi:mem-aref platforms :pointer 0)))
         (check-cl (cl-get-device-ids platform +CL-DEVICE-TYPE-GPU+ 1 devices (cffi:null-pointer)))
         (let ((device (cffi:mem-aref devices :pointer 0)))
           (cffi:with-foreign-object (err :int)
             (let ((ctx (cl-create-context (cffi:null-pointer) 1
                                           (cffi:foreign-alloc :pointer :initial-element device)
                                           (cffi:null-pointer) (cffi:null-pointer) err)))
               (check-cl (cffi:mem-ref err :int))
               (let ((q (cl-create-command-queue ctx device 0 err)))
                 (check-cl (cffi:mem-ref err :int))
                 (values ctx q))))))))
    (:l0
     (check-ze (ze-init +ZE-INIT-FLAG-GPU-ONLY+))
     (cffi:with-foreign-objects ((n-drv :uint32) (drv :pointer)
                                 (n-dev :uint32) (dev :pointer)
                                 (ctx-out :pointer))
       (setf (cffi:mem-ref n-drv :uint32) 0)
       (check-ze (ze-driver-get n-drv (cffi:null-pointer)))
       (when (zerop (cffi:mem-ref n-drv :uint32))
         (error "RUNTIME-INIT: no L0 drivers found"))
       (setf (cffi:mem-ref n-drv :uint32) 1)
       (check-ze (ze-driver-get n-drv drv))
       (let ((driver (cffi:mem-ref drv :pointer)))
         (setf (cffi:mem-ref n-dev :uint32) 0)
         (check-ze (ze-device-get driver n-dev (cffi:null-pointer)))
         (when (zerop (cffi:mem-ref n-dev :uint32))
           (error "RUNTIME-INIT: no L0 devices found"))
         (setf (cffi:mem-ref n-dev :uint32) 1)
         (check-ze (ze-device-get driver n-dev dev))
         (let ((device (cffi:mem-ref dev :pointer))
               (ctx-desc (l0-make-zeroed-struct 'ze-context-desc)))
           (unwind-protect
               (progn
                (setf (cffi:foreign-slot-value ctx-desc '(:struct ze-context-desc) 'stype)
                      +ZE-STYPE-CONTEXT-DESC+)
                (check-ze (ze-context-create driver ctx-desc ctx-out))
                (let ((ctx (cffi:mem-ref ctx-out :pointer)))
                  (setf *ad-device* device
                        *ad-context* ctx)
                  (values ctx nil)))
             (cffi:foreign-free ctx-desc))))))))

(defun runtime-shutdown (context queue)
  "Tear down the runtime handles returned by RUNTIME-INIT."
  (ecase *ad-runtime*
    (:opencl
     (when queue   (cl-release-command-queue queue))
     (when context (cl-release-context context)))
    (:l0
     (when context (ze-context-destroy context))
     (setf *ad-device* nil
           *ad-context* nil))))

(defun runtime-create-grad-buffer (context bytes)
  "Allocate a grad-output buffer of BYTES bytes (cl_mem under :opencl,
   USM-shared ptr under :l0)."
  (ecase *ad-runtime*
    (:opencl
     (cffi:with-foreign-object (err :int)
       (let ((buf (cl-create-buffer context +CL-MEM-READ-WRITE+
                                    bytes (cffi:null-pointer) err)))
         (check-cl (cffi:mem-ref err :int))
         buf)))
    (:l0
     (l0-alloc-shared context bytes 8))))

(defun runtime-release-buffer (context buffer)
  (ecase *ad-runtime*
    (:opencl (cl-release-mem-object buffer))
    (:l0     (ze-mem-free context buffer))))

(defun runtime-release-kernel (kernel)
  (ecase *ad-runtime*
    (:opencl (cl-release-kernel kernel))
    (:l0     (ze-kernel-destroy kernel))))

(defun runtime-release-program (program)
  "Release a program (OpenCL) / module (L0)."
  (ecase *ad-runtime*
    (:opencl (cl-release-program program))
    (:l0     (ze-module-destroy program))))

