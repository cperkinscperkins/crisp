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
