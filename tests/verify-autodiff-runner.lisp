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

(defun create-program-and-kernel (context spv-data kernel-name)
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

(defun create-float-cell-buffer (context)
  "Creates a 4-byte read/write cl_mem buffer for a single-float cell."
  (cffi:with-foreign-object (err :int)
    (let ((buffer (cl-create-buffer context +CL-MEM-READ-WRITE+ 4 (cffi:null-pointer) err)))
      (check-cl (cffi:mem-ref err :int))
      buffer)))

(defun write-float-cell (queue buffer value)
  "Writes VALUE (a single-float) to the 1-element float buffer."
  (cffi:with-foreign-object (data :float 1)
    (setf (cffi:mem-aref data :float 0) value)
    (check-cl (cl-enqueue-write-buffer queue buffer 1 0 4 data 0 (cffi:null-pointer) (cffi:null-pointer)))))

(defun read-float-cell (queue buffer)
  "Reads the single float from BUFFER and returns it."
  (cffi:with-foreign-object (result :float 1)
    (check-cl (cl-enqueue-read-buffer queue buffer 1 0 4 result 0 (cffi:null-pointer) (cffi:null-pointer)))
    (cffi:mem-aref result :float 0)))

(defun bind-cell-arg (kernel base-index buffer &key (byte-size 4) (offset 0))
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

(defun launch-kernel-1d (queue kernel &key (global-size 1))
  "Launches KERNEL with a 1D ND-range of GLOBAL-SIZE and waits for it to finish."
  (cffi:with-foreign-object (gs :size 1)
    (setf (cffi:mem-aref gs :size 0) global-size)
    (check-cl (cl-enqueue-ndrange-kernel queue kernel 1 (cffi:null-pointer) gs (cffi:null-pointer) 0 (cffi:null-pointer) (cffi:null-pointer))))
  (check-cl (cl-finish queue)))

;;; --- Phase 5b helpers: vectors + plain scalars -----------------------

(defun create-float-buffer (context n-elements)
  "Creates a read/write cl_mem buffer holding N-ELEMENTS single-float values."
  (cffi:with-foreign-object (err :int)
    (let ((buffer (cl-create-buffer context +CL-MEM-READ-WRITE+
                                    (* 4 n-elements)
                                    (cffi:null-pointer) err)))
      (check-cl (cffi:mem-ref err :int))
      buffer)))

(defun write-float-vector (queue buffer values)
  "Writes a list of float VALUES into BUFFER (one float per element)."
  (let ((n (length values)))
    (cffi:with-foreign-object (data :float n)
      (loop for v in values
            for i from 0
            do (setf (cffi:mem-aref data :float i) (cl:float v 1.0)))
      (check-cl (cl-enqueue-write-buffer queue buffer 1 0 (* 4 n) data
                                         0 (cffi:null-pointer) (cffi:null-pointer))))))

(defun read-float-vector (queue buffer n)
  "Reads N single-floats from BUFFER and returns them as a list."
  (cffi:with-foreign-object (data :float n)
    (check-cl (cl-enqueue-read-buffer queue buffer 1 0 (* 4 n) data
                                      0 (cffi:null-pointer) (cffi:null-pointer)))
    (loop for i from 0 below n
          collect (cffi:mem-aref data :float i))))

(defun read-float-vector-elem (queue buffer i)
  "Reads a single float at index I from BUFFER."
  (cffi:with-foreign-object (data :float 1)
    (check-cl (cl-enqueue-read-buffer queue buffer 1 (* 4 i) 4 data
                                      0 (cffi:null-pointer) (cffi:null-pointer)))
    (cffi:mem-aref data :float 0)))

(defun bind-vector-arg (kernel base-index buffer length)
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

(defun bind-uint64-scalar-arg (kernel arg-index value)
  "Binds a plain i64 / uint64 scalar at ARG-INDEX."
  (cffi:with-foreign-object (arg :uint64)
    (setf (cffi:mem-ref arg :uint64) value)
    (check-cl (cl-set-kernel-arg kernel arg-index (cffi:foreign-type-size :uint64) arg))))

(defun bind-float-scalar-arg (kernel arg-index value)
  "Binds a plain (unboxed) float32 scalar at ARG-INDEX.  Used for record
   field inputs that SROA into bare floats at the kernel boundary."
  (cffi:with-foreign-object (arg :float)
    (setf (cffi:mem-ref arg :float) (cl:float value 1.0))
    (check-cl (cl-set-kernel-arg kernel arg-index (cffi:foreign-type-size :float) arg))))

;;; === Entry Point =======================================================

;;; --- Input descriptor (phase 5b / phase A) ---------------------------
;;;
;;; Each input is classified into one of four kinds, controlling buffer
;;; allocation, arg-width, and FD strategy:
;;;
;;;   :scalar-float        -- wrapped (cell float), 3 fwd args, FD perturbs cell
;;;   :scalar-float-plain  -- plain float32,        1 fwd arg,  FD perturbs value
;;;                           (used for record-field inputs that SROA at boundary)
;;;   :scalar-ulong        -- plain i64,            1 fwd arg,  no FD (grad = 0)
;;;   :vector-float        -- 1D compact tensor,    6 fwd args, FD perturbs at :perturb-i
;;;
;;; The dot-in-name heuristic distinguishes :scalar-float-plain from
;;; :scalar-float: dotted names (e.g. \"P.x\") are taken to be record
;;; fields and bind as plain floats; bare names (\"x\") bind as cells.

(defun %vad-classify-input (value at-points name)
  "Returns plist describing input kind given the parsed VALUE.
   AT-POINTS is the parser's at-points alist; used to attach :perturb-i."
  (cond
    ((listp value)
     (let ((at (cdr (assoc name at-points :test #'string=))))
       (list :kind :vector-float
             :length (length value)
             :perturb-i at
             :arg-width 6
             :grad-arg-width 6)))
    ((integerp value)
     (list :kind :scalar-ulong
           :perturb-i nil
           :arg-width 1
           :grad-arg-width 3))   ; cell-of-double grad
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

(defun %vad-make-descriptors (inputs at-points)
  "Builds the per-input descriptor list, threading cumulative arg offsets.
   Forward arg layout is just the inputs in declaration order, followed by
   the output cell (3 args).  Backward layout adds: incoming grad cell (3),
   then each input's outgoing gradient slot (width per-input).

   Each descriptor is a plist with these keys pre-allocated (so
   subsequent (setf (getf desc KEY) VAL) calls modify the existing cons in
   place rather than building a new list that the caller never sees):

     :name :value :kind :length :perturb-i
     :arg-width :arg-base
     :grad-arg-width :grad-arg-base
     :buffer :grad-buffer

   Returns (values DESCRIPTORS OUTPUT-FWD-BASE OUTPUT-BWD-BASE
                   GRAD-OUTPUT-BWD-BASE)."
  (let ((descs nil)
        (fwd-base 0)
        (bwd-base 0))
    (dolist (entry inputs)
      (let* ((name (car entry))
             (value (cdr entry))
             (cls (%vad-classify-input value at-points name)))
        ;; Pre-allocate every mutable slot so subsequent setf-getf works.
        (push (list :name name
                    :value value
                    :kind (getf cls :kind)
                    :length (getf cls :length)
                    :perturb-i (getf cls :perturb-i)
                    :arg-width (getf cls :arg-width)
                    :arg-base fwd-base
                    :grad-arg-width (getf cls :grad-arg-width)
                    :grad-arg-base nil
                    :buffer nil
                    :grad-buffer nil)
              descs)
        (incf fwd-base (getf cls :arg-width))
        (incf bwd-base (getf cls :arg-width))))
    (setf descs (nreverse descs))
    (let* ((output-fwd-base fwd-base)
           (output-bwd-base bwd-base)
           (grad-output-bwd-base (+ output-bwd-base 3)) ; output cell width = 3
           (grad-input-base     (+ grad-output-bwd-base 3)))
      ;; In-place fill of :grad-arg-base.  Each descriptor already has the
      ;; slot, so setf-getf modifies the existing cons.
      (let ((cur grad-input-base))
        (dolist (d descs)
          (setf (getf d :grad-arg-base) cur)
          (incf cur (getf d :grad-arg-width))))
      (values descs output-fwd-base output-bwd-base grad-output-bwd-base))))

(defun %vad-output-length-for-input (desc)
  "Returns the buffer element count needed for a forward input buffer,
   or NIL when no buffer is needed (plain scalars are bound directly)."
  (case (getf desc :kind)
    (:scalar-float       1)
    (:vector-float       (getf desc :length))
    (:scalar-float-plain nil)   ; no forward buffer; bound on each launch
    (:scalar-ulong       nil)))

(defun %vad-grad-bytes-for (desc)
  "Returns byte-size for the gradient buffer for input DESC."
  (case (getf desc :kind)
    (:scalar-float       4)                            ; cell of float
    (:scalar-float-plain 4)                            ; cell of float
    (:scalar-ulong       8)                            ; cell of double
    (:vector-float       (* 4 (getf desc :length)))))  ; vector of float


(defun verify-autodiff (fwd-spv-path bwd-spv-path fwd-kernel-name
                       &key
                         (bwd-kernel-name (concatenate 'string fwd-kernel-name "_grad"))
                         inputs
                         at-points
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
    (let* ((platform nil) (device nil) (context nil) (queue nil)
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

           (multiple-value-setq (descs output-fwd-base output-bwd-base grad-output-bwd-base)
             (%vad-make-descriptors inputs at-points))

           (cffi:with-foreign-objects ((platforms :pointer 1)
                                       (devices :pointer 1))
             (check-cl (cl-get-platform-ids 1 platforms (cffi:null-pointer)))
             (setf platform (cffi:mem-aref platforms :pointer 0))
             (check-cl (cl-get-device-ids platform +CL-DEVICE-TYPE-GPU+ 1 devices (cffi:null-pointer)))
             (setf device (cffi:mem-aref devices :pointer 0)))

           (cffi:with-foreign-object (err :int)
             (setf context (cl-create-context (cffi:null-pointer) 1
                                              (cffi:foreign-alloc :pointer :initial-element device)
                                              (cffi:null-pointer) (cffi:null-pointer) err))
             (setf queue (cl-create-command-queue context device 0 err)))

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
                   (let ((bytes (%vad-grad-bytes-for d)))
                     (cffi:with-foreign-object (err :int)
                       (let ((buf (cl-create-buffer context +CL-MEM-READ-WRITE+
                                                    bytes (cffi:null-pointer) err)))
                         (check-cl (cffi:mem-ref err :int))
                         buf)))))
           (setf output-buf      (create-float-cell-buffer context)
                 output-grad-buf (create-float-cell-buffer context))

           (labels
               ((apply-primals (kernel perturb-desc delta)
                  "Stages every input for the next launch of KERNEL.  Cell and
                   vector inputs write their backing buffer (already bound);
                   plain-float and ulong inputs bind their kernel arg directly
                   (no buffer).  When PERTURB-DESC is non-NIL, perturbs that
                   one input by DELTA:
                     :scalar-float        shifts cell value
                     :scalar-float-plain  shifts bound float value
                     :vector-float        shifts only element at :perturb-i"
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
                         (bind-float-scalar-arg kernel (getf d :arg-base) vv)))
                      (:scalar-ulong
                       (bind-uint64-scalar-arg kernel (getf d :arg-base) (getf d :value)))
                      (:vector-float
                       (let* ((vals (getf d :value))
                              (i    (getf d :perturb-i))
                              (perturbed
                               (if (eq d perturb-desc)
                                   (loop for v in vals
                                         for k from 0
                                         collect (if (eql k i)
                                                     (+ (cl:float v 1.0) delta)
                                                     v))
                                   vals)))
                         (write-float-vector queue (getf d :buffer) perturbed))))))
                (bind-static-input-args (kernel)
                  "Binds the inputs that have a persistent backing buffer
                   (cells and vectors).  Plain floats and ulongs are bound
                   on every iteration by APPLY-PRIMALS."
                  (dolist (d descs)
                    (let ((base (getf d :arg-base)))
                      (case (getf d :kind)
                        (:scalar-float (bind-cell-arg kernel base (getf d :buffer)))
                        (:vector-float (bind-vector-arg kernel base (getf d :buffer) (getf d :length)))))))
                (bind-grad-args ()
                  (dolist (d descs)
                    (let ((base (getf d :grad-arg-base)))
                      (case (getf d :kind)
                        ((:scalar-float :scalar-float-plain)
                         (bind-cell-arg bwd-kernel base (getf d :grad-buffer)))
                        (:scalar-ulong
                         ;; Cell-of-double grad: same 3-arg shape, byte_size = 8.
                         (bind-cell-arg bwd-kernel base (getf d :grad-buffer)
                                        :byte-size 8))
                        (:vector-float
                         (bind-vector-arg bwd-kernel base (getf d :grad-buffer)
                                          (getf d :length)))))))
                (zero-grads ()
                  (dolist (d descs)
                    (case (getf d :kind)
                      ((:scalar-float :scalar-float-plain)
                       (write-float-cell queue (getf d :grad-buffer) 0.0))
                      (:vector-float (write-float-vector queue (getf d :grad-buffer)
                                                         (make-list (getf d :length)
                                                                    :initial-element 0.0)))
                      (:scalar-ulong
                       ;; cell-of-double, write 8 zero bytes
                       (cffi:with-foreign-object (data :uint64 1)
                         (setf (cffi:mem-aref data :uint64 0) 0)
                         (check-cl (cl-enqueue-write-buffer queue (getf d :grad-buffer)
                                                            1 0 8 data
                                                            0 (cffi:null-pointer)
                                                            (cffi:null-pointer)))))))))

             ;; Static binds: buffer-backed inputs bound once.
             (bind-static-input-args fwd-kernel)
             (bind-cell-arg fwd-kernel output-fwd-base output-buf)
             (bind-static-input-args bwd-kernel)
             (bind-cell-arg bwd-kernel output-bwd-base       output-buf)
             (bind-cell-arg bwd-kernel grad-output-bwd-base  output-grad-buf)
             (bind-grad-args)

             ;; --- Forward at unperturbed primals, capture Y.
             (apply-primals fwd-kernel nil 0.0)
             (write-float-cell queue output-buf 0.0)
             (launch-kernel-1d queue fwd-kernel)
             (let ((y-at-primals (read-float-cell queue output-buf)))
               (vlog "~&;   y(primals) = ~a~%" y-at-primals)

               ;; --- Per-input central-difference FD --------------------
               (let ((fd-rows nil))
                 (dolist (d descs)
                   (case (getf d :kind)
                     (:scalar-ulong nil) ; skip
                     ((:scalar-float :scalar-float-plain)
                      (apply-primals fwd-kernel d h)
                      (write-float-cell queue output-buf 0.0)
                      (launch-kernel-1d queue fwd-kernel)
                      (let ((y-plus (read-float-cell queue output-buf)))
                        (apply-primals fwd-kernel d (- h))
                        (write-float-cell queue output-buf 0.0)
                        (launch-kernel-1d queue fwd-kernel)
                        (let* ((y-minus (read-float-cell queue output-buf))
                               (grad (/ (- y-plus y-minus) (* 2.0 h))))
                          (push (cons (getf d :name) grad) fd-rows)
                          (vlog "~&;   d/d~a: y+=~a y-=~a num=~a~%"
                                (getf d :name) y-plus y-minus grad))))
                     (:vector-float
                      (let ((at (getf d :perturb-i)))
                        (when at
                          (apply-primals fwd-kernel d h)
                          (write-float-cell queue output-buf 0.0)
                          (launch-kernel-1d queue fwd-kernel)
                          (let ((y-plus (read-float-cell queue output-buf)))
                            (apply-primals fwd-kernel d (- h))
                            (write-float-cell queue output-buf 0.0)
                            (launch-kernel-1d queue fwd-kernel)
                            (let* ((y-minus (read-float-cell queue output-buf))
                                   (grad (/ (- y-plus y-minus) (* 2.0 h))))
                              (push (cons (getf d :name) grad) fd-rows)
                              (vlog "~&;   d/d~a[~a]: y+=~a y-=~a num=~a~%"
                                    (getf d :name) at y-plus y-minus grad))))))))

                 ;; --- Backward with primals + seed.
                 (apply-primals bwd-kernel nil 0.0)
                 (write-float-cell queue output-buf y-at-primals)
                 (write-float-cell queue output-grad-buf (cl:float seed-grad 1.0))
                 (zero-grads)
                 (launch-kernel-1d queue bwd-kernel)

                 ;; --- Read analytical grads per perturbable input.
                 (let ((ana-rows nil))
                   (dolist (d descs)
                     (case (getf d :kind)
                       (:scalar-ulong nil)
                       ((:scalar-float :scalar-float-plain)
                        (push (cons (getf d :name)
                                    (read-float-cell queue (getf d :grad-buffer)))
                              ana-rows))
                       (:vector-float
                        (let ((at (getf d :perturb-i)))
                          (when at
                            (push (cons (getf d :name)
                                        (read-float-vector-elem queue
                                                                (getf d :grad-buffer)
                                                                at))
                                  ana-rows))))))

                   (setf fd-rows  (nreverse fd-rows)
                         ana-rows (nreverse ana-rows))
                   (setf results
                         (loop for (name . num) in fd-rows
                               for ana = (cdr (assoc name ana-rows :test #'string=))
                               collect (list :name name
                                             :analytical ana
                                             :numerical num
                                             :diff (abs (- ana num)))))
                   (setf pass-p (every (lambda (r) (< (getf r :diff) atol)) results))
                   (vlog "~&;   pass-p = ~a~%" pass-p))))))

        ;; Cleanup
        (when output-buf      (cl-release-mem-object output-buf))
        (when output-grad-buf (cl-release-mem-object output-grad-buf))
        (dolist (d descs)
          (when (getf d :buffer)      (cl-release-mem-object (getf d :buffer)))
          (when (getf d :grad-buffer) (cl-release-mem-object (getf d :grad-buffer))))
        (when fwd-kernel  (cl-release-kernel fwd-kernel))
        (when fwd-program (cl-release-program fwd-program))
        (when bwd-kernel  (cl-release-kernel bwd-kernel))
        (when bwd-program (cl-release-program bwd-program))
        (when queue   (cl-release-command-queue queue))
        (when context (cl-release-context context)))

      (values pass-p results))))
