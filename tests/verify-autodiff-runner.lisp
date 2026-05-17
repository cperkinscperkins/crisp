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

(defun bind-int32-scalar-arg (kernel arg-index value)
  "Binds a plain (unboxed) i32 scalar at ARG-INDEX.  Used for record
   field inputs declared `int` that SROA into bare i32 at the kernel boundary."
  (cffi:with-foreign-object (arg :int32)
    (setf (cffi:mem-ref arg :int32) value)
    (check-cl (cl-set-kernel-arg kernel arg-index (cffi:foreign-type-size :int32) arg))))

(defun bind-struct-by-value-arg (kernel arg-index fields total-bytes)
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
          (t (error "bind-struct-by-value-arg: unsupported ftype ~A" ftype)))))
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

(defun %vad-make-descriptors (inputs at-points &optional structs)
  "Builds the per-input descriptor list, threading cumulative arg offsets.

   STRUCTS is a list of parent-name strings declared as `struct=...` in
   the directive.  Any input whose dotted-name parent appears in STRUCTS
   is folded into a single :struct-by-value descriptor (one kernel arg
   carrying the packed struct value, plus a single shadow-struct grad
   cell as &out).  Inputs not folded keep their normal classification.

   Each descriptor is a plist with these keys pre-allocated:
     :name :value :kind :length :perturb-i
     :arg-width :arg-base
     :grad-arg-width :grad-arg-base
     :buffer :grad-buffer
   And for :struct-by-value also:
     :fields :total-bytes :grad-bytes

   Returns (values DESCRIPTORS OUTPUT-FWD-BASE OUTPUT-BWD-BASE
                   GRAD-OUTPUT-BWD-BASE)."
  (let ((descs nil)
        (fwd-base 0)
        (bwd-base 0)
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
                                :arg-base fwd-base
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
                         :perturb-i (getf cls :perturb-i)
                         :arg-width (getf cls :arg-width)
                         :arg-base fwd-base
                         :grad-arg-width (getf cls :grad-arg-width)
                         :grad-arg-base nil
                         :buffer nil
                         :grad-buffer nil)
                   descs)
             (incf fwd-base (getf cls :arg-width))
             (incf bwd-base (getf cls :arg-width)))))))
    (setf descs (nreverse descs))
    (let* ((output-fwd-base fwd-base)
           (output-bwd-base bwd-base)
           (grad-output-bwd-base (+ output-bwd-base 3)) ; output cell width = 3
           (grad-input-base     (+ grad-output-bwd-base 3)))
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
    (:struct-by-value    (getf desc :grad-bytes))))    ; shadow struct bytes


(defun verify-autodiff (fwd-spv-path bwd-spv-path fwd-kernel-name
                       &key
                         (bwd-kernel-name (concatenate 'string fwd-kernel-name "_grad"))
                         inputs
                         at-points
                         structs
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
             (%vad-make-descriptors inputs at-points structs))

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
               ((apply-primals (kernel perturb-desc delta &optional perturb-field)
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
                         (bind-float-scalar-arg kernel (getf d :arg-base) vv)))
                      (:scalar-int32-plain
                       (bind-int32-scalar-arg kernel (getf d :arg-base) (getf d :value)))
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
                         (bind-struct-by-value-arg kernel (getf d :arg-base)
                                                   perturbed-fields
                                                   (getf d :total-bytes)))))))
                (bind-static-input-args (kernel)
                  "Binds the inputs that have a persistent backing buffer
                   (cells and vectors).  Plain floats, ulongs, and structs
                   are bound on every iteration by APPLY-PRIMALS."
                  (dolist (d descs)
                    (let ((base (getf d :arg-base)))
                      (case (getf d :kind)
                        (:scalar-float (bind-cell-arg kernel base (getf d :buffer)))
                        (:vector-float (bind-vector-arg kernel base (getf d :buffer) (getf d :length)))))))
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
                      (:vector-float (write-float-vector queue (getf d :grad-buffer)
                                                         (make-list (getf d :length)
                                                                    :initial-element 0.0)))
                      (:scalar-ulong
                       (cffi:with-foreign-object (data :uint64 1)
                         (setf (cffi:mem-aref data :uint64 0) 0)
                         (check-cl (cl-enqueue-write-buffer queue (getf d :grad-buffer)
                                                            1 0 8 data
                                                            0 (cffi:null-pointer)
                                                            (cffi:null-pointer)))))
                      (:struct-by-value
                       (let ((nbytes (getf d :grad-bytes)))
                         (cffi:with-foreign-object (data :uint8 nbytes)
                           (loop for i from 0 below nbytes
                                 do (setf (cffi:mem-aref data :uint8 i) 0))
                           (check-cl (cl-enqueue-write-buffer queue (getf d :grad-buffer)
                                                              1 0 nbytes data
                                                              0 (cffi:null-pointer)
                                                              (cffi:null-pointer))))))))))

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
                     (:scalar-int32-plain
                      ;; Int has no continuous derivative; canonical num = 0.0.
                      ;; Analytical read step compares against this; expect.<name>=0.0
                      ;; gives an explicit check that the int grad cell is zero.
                      (push (cons (getf d :name) 0.0) fd-rows)
                      (vlog "~&;   d/d~a: skipped (int); num=0.0~%" (getf d :name)))
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
                                    (getf d :name) at y-plus y-minus grad))))))
                     (:struct-by-value
                      ;; FD per float field; int fields get canonical num=0.
                      (dolist (f (getf d :fields))
                        (let ((fname (getf f :name)))
                          (case (getf f :ftype)
                            (:int32
                             (push (cons fname 0.0) fd-rows)
                             (vlog "~&;   d/d~a: skipped (int field); num=0.0~%" fname))
                            (:float
                             (apply-primals fwd-kernel d h fname)
                             (write-float-cell queue output-buf 0.0)
                             (launch-kernel-1d queue fwd-kernel)
                             (let ((y-plus (read-float-cell queue output-buf)))
                               (apply-primals fwd-kernel d (- h) fname)
                               (write-float-cell queue output-buf 0.0)
                               (launch-kernel-1d queue fwd-kernel)
                               (let* ((y-minus (read-float-cell queue output-buf))
                                      (grad (/ (- y-plus y-minus) (* 2.0 h))))
                                 (push (cons fname grad) fd-rows)
                                 (vlog "~&;   d/d~a (struct field): y+=~a y-=~a num=~a~%"
                                       fname y-plus y-minus grad))))))))))

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
                       ((:scalar-float :scalar-float-plain :scalar-int32-plain)
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
                                  ana-rows))))
                       (:struct-by-value
                        ;; Read N floats from the shadow grad cell, in field
                        ;; declaration order (offsets 0, 4, 8, ...).
                        (let ((nbytes (getf d :grad-bytes)))
                          (cffi:with-foreign-object (raw :uint8 nbytes)
                            (check-cl (cl-enqueue-read-buffer queue (getf d :grad-buffer)
                                                              1 0 nbytes raw
                                                              0 (cffi:null-pointer)
                                                              (cffi:null-pointer)))
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
