;;;; overlays/hoist-cuda/crisp-hoist-cuda-overlay.lisp
;;;;
;;;; Runtime patches for CUDA hoist improvements.
;;;; Applied via late binding - last definition wins.

(in-package :crisp.hoist.cuda)


;;; =====================================================================
;;; Endeavor 152 rung 04 — clustered launch in the CUDA hoist
;;;
;;; WHAT THIS DOES *NOT* DO, and why.  It does not switch to cuLaunchKernelEx.
;;; Crisp bakes the cluster shape into the PTX (.reqnctapercluster, emitted by
;;; %apply-cluster-dims-attribute), so the size is COMPILE-TIME FIXED -- which is
;;; precisely the case a plain launch handles, and the reason CUDA C++ offers
;;; __cluster_dims__ alongside the ordinary <<<>>> syntax.  cuLaunchKernelEx with
;;; CU_LAUNCH_ATTRIBUTE_CLUSTER_DIMENSION is for setting the shape DYNAMICALLY at
;;; launch, which we deliberately do not support (there is no :derive-from).
;;;
;;;   *** ASSUMPTION TO VERIFY ON THE POD (rung 04). ***  If a .reqnctapercluster
;;;   kernel in fact requires cuLaunchKernelEx, the launch fails LOUDLY with
;;;   CUDA_ERROR_INVALID_CLUSTER_SIZE rather than silently mis-running, so this is a
;;;   safe thing to be wrong about -- but it is an assumption, not a measurement.
;;;
;;; WHAT IT DOES DO: enforce grid divisibility, which IS measured.  The driver
;;; rejects a non-divisible grid per axis with CUDA_ERROR_INVALID_CLUSTER_SIZE
;;; (H100 PCIe, CUDA 12.4 -- see 00-verification-findings.md).  So something must
;;; happen, and the two strategies must differ:
;;;   :strided -- PAD up.  The tile-stride loop covers every tile, so the surplus
;;;               blocks simply find nothing to claim and exit.
;;;   :exact   -- ERROR.  No stride loop: padding would launch blocks with no tile,
;;;               truncating would skip tiles.  Neither is acceptable.
;;;
;;; The grid fix-up is INJECTED into emit-launch's output rather than emit-launch
;;; being copied.  emit-launch is 208 lines with one caller; transcribing it into an
;;; overlay to add ten lines in the middle is a worse risk than a documented,
;;; single-anchor text insertion in what is already a C++ *text generator*.  The
;;; anchor is the sole `unsigned int gridX = ` line every strategy branch emits.
;;; =====================================================================

(in-package :crisp.hoist.cuda)

;; src/hoist-cuda/main.lisp
(defun generate-cuda-launcher (metacrisp-path)
  "Generate CUDA Driver API C++ launcher code from metacrisp file.
   Endeavor 152: also threads :effective-cluster-size (what codegen actually built,
   NOT what the source declared) into dispatch-info, so the launch can enforce the
   driver's grid-divisibility requirement."
  (let* ((data     (parse-metacrisp-file metacrisp-path))
         (kernels  (metacrisp-kernels data))
         (aliases  (metacrisp-aliases data))
         ;; Endeavor 130 Phase 5: an active hardware profile's :compute-units
         ;; OVERRIDES the runtime device query for grid sizing (so a deliberately
         ;; shrunken profile actually takes effect host-side).
         (hw-profile (metacrisp-hardware-profile data))
         (hw-compute-units (getf hw-profile :compute-units))
         (base-name (pathname-name metacrisp-path)))

    (format t "Processing ~a~%" metacrisp-path)
    (format t "  Kernels: ~a~%" (length kernels))

    (when (null kernels)
      (format t "WARNING: No kernels found in ~a. Nothing to hoist.~%" metacrisp-path))

    (let ((*hoist-current-structs* (metacrisp-structs data)))
      (dolist (kernel kernels)
        (let* ((kernel-name    (getf kernel :name))
               (declared-sig  (getf kernel :declared-signature))
               (implicit-sig  (getf kernel :implicit-params))
               (dispatch-info (let ((gs (getf kernel :global-size))
                                    (ls (getf kernel :local-size))
                                    (ng (getf kernel :num-groups))
                                    (cd (getf kernel :effective-cluster-size)))
                                 (when (or gs ls ng cd)
                                   (append (when gs (list :global-size gs))
                                           (when ls (list :local-size  ls))
                                           (when ng (list :num-groups  ng))
                                           (when cd (list :effective-cluster-size cd))))))
               (comparable-range-start
                 (lambda (param)
                   (let ((r (getf param :range)))
                     (if (listp r) (first r) -1))))
               (full-sig      (sort (append declared-sig implicit-sig) #'<
                                    :key comparable-range-start))
               (output-targets (getf kernel :output-targets)))

          (let* ((ptx-path-entry (assoc :ptx output-targets))
                 (ptx-path  (when ptx-path-entry (second ptx-path-entry)))
                 (suffix    (format nil "_~a" kernel-name))
                 (name-part (if (uiop:string-suffix-p base-name suffix)
                                base-name
                                (format nil "~a~a" base-name suffix)))
                 (output-name (format nil "~a_CUDA.cu" name-part))
                 (output-path (make-pathname :name (pathname-name output-name)
                                             :type "cu"
                                             :defaults metacrisp-path)))

            (if (null ptx-path)
                (format t "WARNING: No PTX target found for kernel ~a. Skipping host generation.~%"
                        kernel-name)
                (progn
                 (format t "  Generating: ~a~%" output-name)
                 (let ((dvec-types (%collect-dvec-types declared-sig aliases)))
                   (with-open-file (stream output-path :direction :output :if-exists :supersede)
                     (emit-preamble stream metacrisp-path kernel-name output-name)
                     (emit-includes stream)
                     (emit-typedefs stream aliases)
                     (emit-cuda-dvec-ostream-operators stream dvec-types)
                     (emit-structs stream (append (metacrisp-records data) (metacrisp-structs data)))
                     (emit-helpers stream)
                     (emit-main stream kernel-name ptx-path full-sig aliases
                                (metacrisp-records data) dispatch-info
                                hw-compute-units)))
                 (format t "  Done: ~a~%" (namestring output-path))))))))))

;; src/hoist-cuda/main.lisp  (new)
(defun %cuda-cluster-grid-fixup-string (dispatch-info)
  "The C++ that reconciles the computed grid with the cluster shape, or \"\" when the
   kernel has no cluster.  See the header comment for why the two strategies differ."
  (let* ((dims (and dispatch-info (getf dispatch-info :effective-cluster-size)))
         (cx (or (first dims) 1))
         (cy (or (second dims) 1))
         (cz (or (third dims) 1)))
    (if (or (null dims) (<= (* cx cy cz) 1))
        ""
        (let* ((gs (and dispatch-info (getf dispatch-info :global-size)))
               (strategy (and (consp gs) (getf (cdr gs) :strategy)))
               (exact-p (and strategy (symbolp strategy)
                             (string-equal (symbol-name strategy) "EXACT")))
               (s (make-string-output-stream)))
          (format s "~%    // --- Endeavor 152: cluster grid reconciliation ---~%")
          (format s "    // The driver requires gridDim %% clusterDim == 0 on EVERY axis and~%")
          (format s "    // rejects a non-divisible grid with CUDA_ERROR_INVALID_CLUSTER_SIZE.~%")
          (format s "    { const unsigned int _ccx = ~d, _ccy = ~d, _ccz = ~d;~%" cx cy cz)
          (if exact-p
              (progn
                (format s "      // :strategy :exact has no stride loop -- padding would launch blocks~%")
                (format s "      // with no tile, and truncating would silently skip tiles.~%")
                (format s "      if ((gridX %% _ccx) || (gridY %% _ccy) || (gridZ %% _ccz)) {~%")
                (format s "        std::cerr << \"error: grid (\" << gridX << \",\" << gridY << \",\" << gridZ~%")
                (format s "                  << \") is not divisible by cluster (~d,~d,~d).\"~%" cx cy cz)
                (format s "                  << \"  :strategy :exact cannot pad (blocks with no tile) or truncate\"~%")
                (format s "                  << \" (skipped tiles).  Use :strategy :strided, or a :tile-shape that\"~%")
                (format s "                  << \" divides the problem evenly by the cluster shape.\" << std::endl;~%")
                (format s "        return;~%")
                (format s "      }~%"))
              (progn
                (format s "      // :strategy :strided has a tile-stride loop, so padding UP is safe:~%")
                (format s "      // the surplus blocks find no tiles left to claim and exit.~%")
                (format s "      unsigned int _px = ((gridX + _ccx - 1) / _ccx) * _ccx;~%")
                (format s "      unsigned int _py = ((gridY + _ccy - 1) / _ccy) * _ccy;~%")
                (format s "      unsigned int _pz = ((gridZ + _ccz - 1) / _ccz) * _ccz;~%")
                (format s "      if (_px != gridX || _py != gridY || _pz != gridZ) {~%")
                (format s "        std::cerr << \"note: grid padded (\" << gridX << \",\" << gridY << \",\" << gridZ~%")
                (format s "                  << \") -> (\" << _px << \",\" << _py << \",\" << _pz~%")
                (format s "                  << \") for cluster (~d,~d,~d)\" << std::endl;~%" cx cy cz)
                (format s "      }~%")
                (format s "      gridX = _px; gridY = _py; gridZ = _pz;~%")))
          (format s "    }~%")
          (get-output-stream-string s)))))

;; Capture the ORIGINAL emit-launch once, so reloading this overlay cannot wrap the
;; wrapper.  defvar does not re-initialise, and the `unless` guards a fresh image.
(defvar *crisp-152-orig-emit-launch* nil)
(unless *crisp-152-orig-emit-launch*
  (setf *crisp-152-orig-emit-launch* (fdefinition 'emit-launch)))

;; src/hoist-cuda/main.lisp
(defun emit-launch (stream dispatch-info shared-bytes &optional compute-units kernel-name out-tile)
  "Endeavor 152 wrapper around the original emit-launch: renders it to a string and
   injects the cluster grid reconciliation immediately after the grid dimensions are
   computed and before the launch that consumes them.

   Wrapped rather than copied on purpose -- the original is 208 lines and this adds
   about ten in the middle of it."
  (let* ((body (with-output-to-string (s)
                 (funcall *crisp-152-orig-emit-launch*
                          s dispatch-info shared-bytes compute-units kernel-name out-tile)))
         (fixup (%cuda-cluster-grid-fixup-string dispatch-info)))
    (if (string= fixup "")
        (write-string body stream)
        ;; Anchor: the single `unsigned int gridX = ` line that every strategy branch
        ;; emits.  If the anchor ever disappears we must NOT silently drop the fix-up --
        ;; a clustered kernel would then launch with an unreconciled grid and be
        ;; rejected by the driver with no explanation of why.
        (let ((pos (search "unsigned int gridX = " body)))
          (cond
            ((null pos)
             (warn "Endeavor 152: could not find the gridX anchor in emit-launch output for kernel ~a; cluster grid reconciliation NOT emitted."
                   kernel-name)
             (write-string body stream))
            (t
             (let ((eol (position #\Newline body :start pos)))
               (write-string body stream :end (1+ eol))
               (write-string fixup stream)
               (write-string body stream :start (1+ eol)))))))))


;;; =====================================================================
;;; Endeavor 152 rung 04 (fix) — `%%` is a printf escape, not a CL format escape
;;;
;;; CL's FORMAT only treats `~` specially; `%` passes through verbatim.  Writing
;;; `%%` (C printf habit) therefore emitted a LITERAL `%%` into the generated C++.
;;; In the comment that is merely wrong-looking; in the :exact branch it produced
;;; `(gridX %% _ccx)`, which does not compile.
;;;
;;; It hid because no spec in this endeavor declares :strategy :exact WITH a cluster,
;;; so the broken branch is never generated -- and the :strided branch, which is the
;;; one every spec exercises, has no modulus in it at all.
;;; =====================================================================

;; src/hoist-cuda/main.lisp
(defun %cuda-cluster-grid-fixup-string (dispatch-info)
  "The C++ that reconciles the computed grid with the cluster shape, or \"\" when the
   kernel has no cluster.

   :strided pads the grid up (the tile-stride loop covers every tile, so surplus
   blocks simply find nothing to claim); :exact refuses, because it has no stride loop
   and so can neither pad (blocks with no tile) nor truncate (skipped tiles).

   The driver rejects a non-divisible grid per axis with CUDA_ERROR_INVALID_CLUSTER_SIZE
   -- measured on H100 PCIe / CUDA 12.4, see 00-verification-findings.md -- so doing
   nothing is not an option."
  (let* ((dims (and dispatch-info (getf dispatch-info :effective-cluster-size)))
         (cx (or (first dims) 1))
         (cy (or (second dims) 1))
         (cz (or (third dims) 1)))
    (if (or (null dims) (<= (* cx cy cz) 1))
        ""
        (let* ((gs (and dispatch-info (getf dispatch-info :global-size)))
               (strategy (and (consp gs) (getf (cdr gs) :strategy)))
               (exact-p (and strategy (symbolp strategy)
                             (string-equal (symbol-name strategy) "EXACT")))
               (s (make-string-output-stream)))
          (format s "~%    // --- Endeavor 152: cluster grid reconciliation ---~%")
          (format s "    // The driver requires gridDim % clusterDim == 0 on EVERY axis and~%")
          (format s "    // rejects a non-divisible grid with CUDA_ERROR_INVALID_CLUSTER_SIZE.~%")
          (format s "    { const unsigned int _ccx = ~d, _ccy = ~d, _ccz = ~d;~%" cx cy cz)
          (if exact-p
              (progn
                (format s "      // :strategy :exact has no stride loop -- padding would launch blocks~%")
                (format s "      // with no tile, and truncating would silently skip tiles.~%")
                (format s "      if ((gridX % _ccx) || (gridY % _ccy) || (gridZ % _ccz)) {~%")
                (format s "        std::cerr << \"error: grid (\" << gridX << \",\" << gridY << \",\" << gridZ~%")
                (format s "                  << \") is not divisible by cluster (~d,~d,~d).\"~%" cx cy cz)
                (format s "                  << \"  :strategy :exact cannot pad (blocks with no tile) or truncate\"~%")
                (format s "                  << \" (skipped tiles).  Use :strategy :strided, or a :tile-shape that\"~%")
                (format s "                  << \" divides the problem evenly by the cluster shape.\" << std::endl;~%")
                (format s "        return;~%")
                (format s "      }~%"))
              (progn
                (format s "      // :strategy :strided has a tile-stride loop, so padding UP is safe:~%")
                (format s "      // the surplus blocks find no tiles left to claim and exit.~%")
                (format s "      unsigned int _px = ((gridX + _ccx - 1) / _ccx) * _ccx;~%")
                (format s "      unsigned int _py = ((gridY + _ccy - 1) / _ccy) * _ccy;~%")
                (format s "      unsigned int _pz = ((gridZ + _ccz - 1) / _ccz) * _ccz;~%")
                (format s "      if (_px != gridX || _py != gridY || _pz != gridZ) {~%")
                (format s "        std::cerr << \"note: grid padded (\" << gridX << \",\" << gridY << \",\" << gridZ~%")
                (format s "                  << \") -> (\" << _px << \",\" << _py << \",\" << _pz~%")
                (format s "                  << \") for cluster (~d,~d,~d)\" << std::endl;~%" cx cy cz)
                (format s "      }~%")
                (format s "      gridX = _px; gridY = _py; gridZ = _pz;~%")))
          (format s "    }~%")
          (get-output-stream-string s)))))

;;; =====================================================================
;;; Endeavor 152 rung 04/11 (fix) — inject AFTER the grid is final, not after gridX
;;;
;;; FOUND ON METAL.  The first cut anchored on `unsigned int gridX = `, which is wrong
;;; twice over and each way was invisible locally:
;;;
;;;  1. The TILE-SHAPE dispatch path declares the axes on SEPARATE lines --
;;;         unsigned int gridX = ...;   <- anchor matched here
;;;         unsigned int gridY = ...;   <- declared AFTER the injected block
;;;         unsigned int gridZ = 1;
;;;     so the emitted C++ referenced gridY/gridZ before they existed:
;;;         error: identifier "gridY" is undefined
;;;     The :set-to path declares all three on ONE line, which is why rung 04 passed on
;;;     the H100 and rung 11 did not.
;;;
;;;  2. Even where all three existed, the injection preceded the DEVICE GRID LIMIT
;;;     clamping, which lowers gridX toward maxGridDimX -- and a clamp applied after a
;;;     divisibility pad can BREAK the divisibility again.  That one would not have been a
;;;     compile error; it would have been an intermittent CUDA_ERROR_INVALID_CLUSTER_SIZE
;;;     on large problems only.
;;;
;;; Both fixed by moving the anchor to `auto _crisp_launch`, the lambda every strategy
;;; emits once, immediately after ALL grid computation and immediately before the launch
;;; that consumes it.  Injecting BEFORE that line means the reconciliation always sees the
;;; final values of all three axes.
;;;
;;; WHY LOCAL TESTING MISSED IT: there is no nvcc on the dev box, so every TEST-HOIST[CUDA]
;;; spec SKIPs.  The broken .cu WAS generated locally and I read it -- but I checked only
;;; that the block appeared, not that the identifiers it referenced were in scope yet.
;;; Generating C++ and reading it is not the same as compiling it.
;;; =====================================================================

;; src/hoist-cuda/main.lisp
(defun emit-launch (stream dispatch-info shared-bytes &optional compute-units kernel-name out-tile)
  "Endeavor 152 wrapper around the original emit-launch: renders it to a string and injects the
   cluster grid reconciliation immediately BEFORE the launch lambda -- i.e. after every strategy
   has finished computing gridX/gridY/gridZ and after the device-limit clamping, so the
   reconciliation is the last word on the grid."
  (let* ((body (with-output-to-string (s)
                 (funcall *crisp-152-orig-emit-launch*
                          s dispatch-info shared-bytes compute-units kernel-name out-tile)))
         (fixup (%cuda-cluster-grid-fixup-string dispatch-info)))
    (if (string= fixup "")
        (write-string body stream)
        ;; Anchor: the launch lambda, emitted exactly once by every path.  If it ever moves we
        ;; must NOT silently drop the fix-up -- a clustered kernel would then launch with an
        ;; unreconciled grid and be rejected by the driver with no explanation.
        (let ((pos (search "auto _crisp_launch" body)))
          (cond
            ((null pos)
             (warn "Endeavor 152: could not find the _crisp_launch anchor in emit-launch output for kernel ~a; cluster grid reconciliation NOT emitted."
                   kernel-name)
             (write-string body stream))
            (t
             ;; Back up to the start of that line so the injected block is not spliced into it.
             (let ((line-start (let ((nl (position #\Newline body :end pos :from-end t)))
                                 (if nl (1+ nl) 0))))
               (write-string body stream :end line-start)
               (write-string fixup stream)
               (write-string body stream :start line-start))))))))

;;; =====================================================================
;;; BUG 046 — a LOCAL scratch CELL aliases the first LOCAL scratch TENSOR
;;;
;;; THE SYMPTOM, and it is silent data corruption on real hardware.  A kernel holding
;;; both a scratch tensor and a scratch cell writes them to the SAME shared memory:
;;;
;;;     (load-tile A tile (0 grid-x))
;;;     (set! (~ acc) 99.0)
;;;     (store-tile tile C (grid-y grid-x))
;;;
;;;     BUFFER a: 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15
;;;     BUFFER c: 99 1 2 3 4 5 6 7 99 1 2 3 4 5 6 7   <- element 0 of every tile clobbered
;;;
;;; Verified on an H100.  ORDERING is what has hidden it: move the `set!` above
;;; tile-stride and the output is perfectly correct, because the tile load simply
;;; overwrites the cell.  It is only visible when a cell write interleaves with tile use,
;;; which is why no spec has ever caught it.
;;;
;;; THE CAUSE.  BUG 034 gave scratch TENSORS a running offset allocator
;;; (*cuda-shared-scratch-offset*) so they would not alias each other.  Cells were never
;;; added to it -- %cuda-emit-cell-arg emits `<name>_local_ptr = 0` unconditionally -- so
;;; every cell sits at offset 0, on top of the first tile.
;;;
;;; THE DEEPER CAUSE, which is what this fix actually addresses.  The hoister computed the
;;; shared-memory layout TWICE, independently: compute-total-shared-bytes summed the bytes
;;; for the launch parameter, while the emitters assigned offsets.  Two computations of one
;;; number is what let them disagree, and simply teaching the cell emitter to bump the
;;; counter would leave that structure in place to fail again.  So both now consult a
;;; SINGLE layout function.
;;;
;;; WHY CELLS GO AFTER TENSORS rather than being interleaved into the existing counter.
;;; Interleaving would shift every tensor offset in every existing kernel -- a 4-byte cell
;;; ahead of a tile would leave that tile at offset 4, wrecking the natural alignment the
;;; async/TMA paths depend on.  Placing cells after the tensors leaves every current tensor
;;; offset BYTE-IDENTICAL to today, so this fix cannot regress a working kernel.
;;;
;;; INTEL IS UNAFFECTED and deliberately untouched: the L0 hoister allocates each local
;;; tensor its own runtime SLM argument (zeKernelSetArgumentValue(..., bytes, nullptr))
;;; rather than carving offsets out of one blob, so it has nothing to alias.
;;; =====================================================================

;; src/hoist-cuda/main.lisp
(defun %cuda-local-param-bytes (param param-type)
  "Bytes of dynamic shared memory one LOCAL param occupies, or NIL if it occupies none.
   Returns a second value, :tensor or :cell, naming which region it belongs to.

   The element-size rule mirrors the one the emitters use, deliberately: this function
   exists so the sizer and the emitters cannot disagree, which is only true if it computes
   what they compute."
  (let* ((is-tensor (tensor-type-p param-type))
         (elem-type (if is-tensor (second param-type) (cell-base-type param-type)))
         (elem-str  (crisp-type-to-cpp-type elem-type))
         (elem-bytes (if (or (string-equal elem-str "double")
                             (string-equal elem-str "int64_t")
                             (string-equal elem-str "uint64_t"))
                         8 4)))
    (if is-tensor
        (let* ((rank (let ((n3 (third param-type))) (if (integerp n3) n3 1)))
               (size-expr (getf param :size-expr))
               (count (cond ((integerp size-expr) (expt size-expr rank))
                            ((and (listp size-expr) (every (function integerp) size-expr))
                             (reduce (function *) size-expr))
                            ;; %cuda-scratch-dims hard-errors on anything else, so such a
                            ;; tensor never reaches an emitter and contributes nothing.
                            (t nil))))
          (when count (values (* count elem-bytes) :tensor)))
        (let ((count (if (%array-type-p (cell-base-type param-type))
                         (%array-size (cell-base-type param-type))
                         1)))
          (values (* count elem-bytes) :cell)))))

;; src/hoist-cuda/main.lisp
(defun %cuda-shared-layout (declared-sig aliases)
  "THE single source of truth for the CUDA hoister's dynamic-shared layout.

   Returns (values TENSOR-BYTES CELL-BASE TOTAL-BYTES).  Scratch tensors are packed from
   offset 0 exactly as BUG 034 laid them out; cells follow, starting at CELL-BASE.

   CELL-BASE is rounded up to 8 so a double or int64 cell lands naturally aligned even
   when the tensors ahead of it total an odd multiple of 4.  TOTAL-BYTES includes that
   padding -- the launch must request every byte the kernel can address, and it is exactly
   this kind of quiet divergence between size and offsets that BUG 046 was."
  (let ((tensor-bytes 0)
        (cell-bytes 0))
    (dolist (param declared-sig)
      (let* ((param-type (resolve-type-alias (getf param :type) aliases))
             (param-as   (getf param :address-space))
             (is-local   (member param-as (list :local "LOCAL" (quote local))
                                 :test (function string-equal))))
        (when (and is-local (or (tensor-type-p param-type) (cell-type-p param-type)))
          (multiple-value-bind (bytes region) (%cuda-local-param-bytes param param-type)
            (when bytes
              (if (eq region :tensor)
                  (incf tensor-bytes bytes)
                  (incf cell-bytes bytes)))))))
    (let ((cell-base (* 8 (ceiling tensor-bytes 8))))
      (values tensor-bytes
              cell-base
              (if (zerop cell-bytes) tensor-bytes (+ cell-base cell-bytes))))))

;; src/hoist-cuda/main.lisp
(defun compute-total-shared-bytes (declared-sig aliases)
  "Sum up all local-memory tensor byte-sizes for the sharedMemBytes launch param.

   BUG 046: now delegates to %cuda-shared-layout so the number requested at launch and the
   offsets handed to the kernel are computed ONCE, by the same code."
  (nth-value 2 (%cuda-shared-layout declared-sig aliases)))

;; src/hoist-cuda/main.lisp
(defvar *cuda-shared-cell-offset* 0
  "Running byte offset for LOCAL scratch CELLS, which live above the scratch tensors.
   Set per kernel by the emit-kernel-args wrapper from %cuda-shared-layout; bumped by
   %cuda-emit-cell-arg.  BUG 046 -- before this existed every cell sat at offset 0 and
   silently overwrote the first tile.")

;; src/hoist-cuda/main.lisp
(defun %cuda-emit-cell-arg (stream param param-name param-type param-dir is-local aliases arg-index)
  "BUG 046: a LOCAL cell now draws a DISTINCT shared-memory offset from
   *cuda-shared-cell-offset* instead of hard-coding 0 on top of the first scratch tile.
   The GLOBAL branch is untouched."
  (declare (ignore param aliases))
  (let* ((base-type      (cell-base-type param-type))
         (is-array-cell  (%array-type-p base-type))
         (base-type-str  (if is-array-cell
                             (crisp-type-to-cpp-type (%array-element-type base-type))
                             (crisp-type-to-cpp-type base-type)))
         (elem-count     (if is-array-cell (%array-size base-type) 1))
         (param-name-cpp (substitute #\_ #\- param-name))
         (size-var       (format nil "~a_size" param-name-cpp))
         (ptr-var        (format nil "~a_ptr"  param-name-cpp))
         (arg-names      '())
         (alloc          nil))
    (if is-local
        ;; LOCAL MEMORY — a distinct slice of the shared blob, above the scratch tensors
        (let* ((elem-bytes (if (or (string-equal base-type-str "double")
                                   (string-equal base-type-str "int64_t")
                                   (string-equal base-type-str "uint64_t"))
                               8 4))
               (bytesize (* elem-count elem-bytes))
               (offset   *cuda-shared-cell-offset*))
          (setf *cuda-shared-cell-offset* (+ *cuda-shared-cell-offset* bytesize))
          (format stream "~%    // LOCAL cell: ~a (~d bytes, shared offset ~d)~%"
                  param-name bytesize offset)
          (format stream "    uint64_t ~a_local_ptr = ~dULL;  // shared offset~%"
                  param-name-cpp offset)
          (format stream "    uint64_t ~a_bytes = ~a * sizeof(~a);~%" size-var elem-count base-type-str)
          (format stream "    uint64_t ~a_offset = 0;~%" param-name-cpp)
          (push (format nil "~a_local_ptr" param-name-cpp) arg-names)
          (push (format nil "~a_bytes" size-var) arg-names)
          (push (format nil "~a_offset" param-name-cpp) arg-names))

        ;; GLOBAL MEMORY — cuMemAlloc + cuMemcpyHtoD
        (progn
          (format stream "~%    // Cell: ~a (~a)~%" param-name base-type-str)
          (format stream "    size_t ~a = ~a;~%" size-var elem-count)
          (format stream "    CUdeviceptr ~a;~%" ptr-var)
          (format stream "    CUDA_CHECK(cuMemAlloc(&~a, ~a * sizeof(~a)));~%"
                  ptr-var size-var base-type-str)
          (format stream "    {~%")
          (format stream "        ~a* h = new ~a[~a];~%" base-type-str base-type-str size-var)
          (if is-array-cell
              (format stream "        for (size_t _i = 0; _i < ~a; _i++) h[_i] = (~a)_i;~%"
                      size-var base-type-str)
              (format stream "        memset(h, 0, ~a * sizeof(~a));~%" size-var base-type-str))
          (format stream "        CUDA_CHECK(cuMemcpyHtoD(~a, h, ~a * sizeof(~a)));~%"
                  ptr-var size-var base-type-str)
          (format stream "        delete[] h;~%")
          (format stream "    }~%")
          (format stream "    uint64_t ~a_bytes = ~a * sizeof(~a);~%" size-var size-var base-type-str)
          (format stream "    uint64_t ~a_offset = 0;~%" param-name-cpp)
          (push (format nil "~a" ptr-var) arg-names)
          (push (format nil "~a_bytes" size-var) arg-names)
          (push (format nil "~a_offset" param-name-cpp) arg-names)
          (setf alloc (list :name      param-name
                            :ptr       ptr-var
                            :size-var  (format nil "~a" size-var)
                            :elem-type base-type-str
                            :direction param-dir))))
    (values (+ arg-index 3) (nreverse arg-names) alloc)))

;; src/hoist-cuda/main.lisp
;;
;; WRAPPED, not transcribed: emit-kernel-args is ~120 lines with one job to add -- seed the
;; cell offset for this kernel.  Copying it into the overlay would put a second stale copy
;; of a busy function in the tree.  Same approach, and same reasoning, as the emit-launch
;; wrapper above.  The captured original still resets *cuda-shared-scratch-offset* itself.
(defvar *crisp-045-orig-emit-kernel-args* nil)
(unless *crisp-045-orig-emit-kernel-args*
  (setf *crisp-045-orig-emit-kernel-args* (fdefinition 'emit-kernel-args)))

(defun emit-kernel-args (stream declared-sig aliases records dispatch-info)
  "BUG 046 wrapper: seeds *cuda-shared-cell-offset* from %cuda-shared-layout so LOCAL
   cells are laid out ABOVE the scratch tensors rather than on top of the first one."
  ;; NOTE: no log4cl here on purpose -- the hoister is built as its own application and
  ;; does not depend on log4cl (src/hoist-cuda/main.lisp contains zero log: calls).  The
  ;; layout it chose is visible in the emitted .cu as a `shared offset` comment per param.
  (setf *cuda-shared-cell-offset* (nth-value 1 (%cuda-shared-layout declared-sig aliases)))
  (funcall *crisp-045-orig-emit-kernel-args* stream declared-sig aliases records dispatch-info))
