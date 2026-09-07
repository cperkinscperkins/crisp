;;;; overlays/hoist-cuda/crisp-hoist-cuda-overlay.lisp
;;;;
;;;; Runtime patches for the CUDA hoister.  Applied via late binding -- last definition wins.
;;;;
;;;; EMPTY BY DESIGN.  Its contents were folded into src/hoist-cuda/main.lisp on 2026-08-26.
;;;;
;;;; The two residents were late-binding WRAPPERS -- they captured (fdefinition 'emit-launch)
;;;; and (fdefinition 'emit-kernel-args) into a defvar and then redefined those names.  That
;;;; shape cannot be pasted into src/, where there is only one definition: the capture would
;;;; grab the function being replaced and the wrapper would recurse forever.  So each was
;;;; split into a base plus a wrapper that calls the base by name:
;;;;
;;;;     %emit-launch-base       + emit-launch
;;;;     %emit-kernel-args-base  + emit-kernel-args
;;;;
;;;; Callers were untouched -- both public names keep their signature and return value.
;;;;
;;;; If you add a patch here, remember the same constraint applies on the way back out.

(in-package :crisp.hoist.cuda)


;;; ===================================================================
;;; Endeavour 165 — the CUDA MMA host reference follows the kernel's ELEMENT TYPE.
;;;
;;; %cuda-emit-mma-reference emitted the on-metal C = A.B check entirely in float, so against an
;;; fp64 kernel it would read 8-byte buffers as 4-byte floats.  MMA_WRONG would then have been a
;;; statement about the HARNESS rather than the kernel -- i.e. a wasted GPU rental.  Caught by
;;; reading the generator BEFORE booking the pod.
;;;
;;; The information was already there: :elem-type is on every allocation as a C++ type string and
;;; emit-readback, twenty lines below, has always used it.  Only this reference hardcoded float.
;;;
;;; THE TOLERANCE FOLLOWS THE TYPE, and at 64 bits that is the point.  tf32 keeps 1e-2 relative
;;; (it carries ~10 mantissa bits); fp64 gets 1e-10, tight enough that a path which silently
;;; computed in single precision FAILS.  That is the same discriminating property the endeavour's
;;; benchmark oracle has, for the same reason: a check that cannot tell fp64 from fp32 is a green
;;; light with no information in it.
;;;
;;; NOTE FOR THE SRC PATCH: %cuda-emit-mma-reference REPLACES src/hoist-cuda/main.lisp:1711.
;;; ===================================================================

;; src/hoist-cuda/main.lisp
(defun %cuda-emit-mma-reference (stream allocations)
  "Emit a stride-agnostic host reference C = A.B (copy A/B/C back to host, compare).

   Endeavour 165: the reference follows the kernel's ELEMENT TYPE instead of being emitted in
   float throughout.  Against an fp64 kernel the old form read 8-byte buffers as 4-byte floats,
   so MMA_WRONG would have been a statement about the HARNESS, not the kernel -- and would have
   burned a GPU rental to say nothing.

   :elem-type is already on every allocation as a C++ type string; emit-readback beside this
   function has always used it.  Only this reference hardcoded float.

   THE TOLERANCE FOLLOWS THE TYPE, which is the whole point at 64 bits.  tf32 keeps 1e-2 relative
   because tf32 carries ~10 mantissa bits.  fp64 gets 1e-10 -- tight enough that a path which
   silently computed in single precision FAILS, the same discriminating property the endeavour's
   benchmark oracle has.  Run at tf32's tolerance an fp64 check would pass on an fp32 result and
   tell us nothing.

   Float emission is byte-identical to before."
  (destructuring-bind (m n k) *mma-test-dims*
    (let ((a (find :a allocations :key (lambda (x) (getf x :mma-role))))
          (b (find :b allocations :key (lambda (x) (getf x :mma-role))))
          (c (find :c allocations :key (lambda (x) (getf x :mma-role)))))
      (when (and a b c)
        (let* ((ab (getf a :base)) (ac (getf a :count)) (at (or (getf a :elem-type) "float"))
               (bb (getf b :base)) (bc (getf b :count)) (bt (or (getf b :elem-type) "float"))
               (cb (getf c :base)) (cc (getf c :count)) (ct (or (getf c :elem-type) "float"))
               (doublep (string= ct "double"))
               ;; The accumulator is the OUTPUT's type: that is what the kernel actually
               ;; produced and what we are checking.
               (acct    ct)
               (zero    (if doublep "0.0" "0.0f"))
               (rel     (if doublep "1e-10" "1e-2f"))
               (abs     (if doublep "1e-12" "1e-3f"))
               (scale-suffix (if doublep "" "f")))
          (format stream "~%    // Endeavor 134: MMA host reference C = A.B (stride-agnostic)~%")
          (format stream "    // Endeavour 165: element type ~a, tolerance ~a rel / ~a abs~%" ct rel abs)
          (format stream "    {~%")
          (format stream "      ~a* ~a_h = new ~a[~d]; CUDA_CHECK(cuMemcpyDtoH(~a_h, ~a_ptr, ~d * sizeof(~a)));~%" at ab at ac ab ab ac at)
          (format stream "      ~a* ~a_h = new ~a[~d]; CUDA_CHECK(cuMemcpyDtoH(~a_h, ~a_ptr, ~d * sizeof(~a)));~%" bt bb bt bc bb bb bc bt)
          (format stream "      ~a* ~a_h = new ~a[~d]; CUDA_CHECK(cuMemcpyDtoH(~a_h, ~a_ptr, ~d * sizeof(~a)));~%" ct cb ct cc cb cb cc ct)
          ;; OpenMP-parallel: this O(N^3) host C=A.B check dominated the large-size sweep (68
          ;; GFLOP at 4096 = minutes single-threaded).  reduction(+:mma_bad) avoids data races;
          ;; the pragma is a harmless no-op if the harness is built without -fopenmp.
          (format stream "      uint64_t mma_bad = 0;~%")
          (format stream "      #pragma omp parallel for schedule(static) reduction(+:mma_bad)~%")
          (format stream "      for (uint64_t i = 0; i < ~dULL; i++) for (uint64_t j = 0; j < ~dULL; j++) {~%" m n)
          (format stream "        ~a acc = ~a;~%" acct zero)
          (format stream "        for (uint64_t kk = 0; kk < ~dULL; kk++)~%" k)
          (format stream "            acc += ~a_h[i*~a_str0 + kk*~a_str1] * ~a_h[kk*~a_str0 + j*~a_str1];~%" ab ab ab bb bb bb)
          (when (/= *mma-scale* 1)
            (format stream "        acc = acc * ~d.0~a;   // --mma-scale (MMA fired ~d times per fragment)~%"
                    *mma-scale* scale-suffix *mma-scale*))
          (format stream "        ~a got = ~a_h[i*~a_str0 + j*~a_str1];~%" acct cb cb cb)
          (format stream "        ~a d = got - acc; if (d < 0) d = -d;~%" acct)
          (format stream "        if (d > ~a * (acc < 0 ? -acc : acc) + ~a) mma_bad++;~%" rel abs)
          (format stream "      }~%")
          (format stream "      std::cout << (mma_bad == 0 ? \"MMA_CORRECT\" : \"MMA_WRONG\");~%")
          (format stream "      if (mma_bad) std::cout << \" (\" << mma_bad << \" mismatches)\";~%")
          (format stream "      std::cout << std::endl;~%")
          (format stream "      delete[] ~a_h; delete[] ~a_h; delete[] ~a_h;~%" ab bb cb)
          (format stream "    }~%"))))))
