;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)


;; overlays/spec-runner-overlay.lisp
;; Endeavour 159 Phase B rung 01.
(defun validate-ptx-fp16-sync-mma (file ptx-string)
  "Endeavour 159 Phase B — the NVIDIA sync MMA lowered at fp16.  Asserts the TWO-SIDED
   invariant, not mere existence: the full m16n8k16 f16 mnemonic is present AND no tf32 MMA
   instruction remains.

   The full mnemonic matters.  Two plausible NVVM spellings for this operation
   (llvm.nvvm.mma.m16n8k16.row.col.f16.f32 and ...bf16.f32) pass the LLVM verifier as
   UNRESOLVED EXTERNAL CALLS -- they emit no instruction at all, while still leaving an
   `mma.m16n8k16...` substring in the PTX.  A prefix match would green-light a kernel that
   computes nothing.

   The negative half is 155/02's lesson carried to NVIDIA: a module in which MOST operands were
   still f32 satisfied that endeavour's original 'some operand is 16-bit somewhere' check, and
   that weak form is exactly what let the defect survive unnoticed."
  (declare (ignore file))
  (let ((want "mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32"))
    (cond
      ((not (search want ptx-string))
       (format *error-output* "FAIL: fp16 sync MMA absent — expected ~s~%" want)
       (when (search "mma.sync.aligned.m16n8k8.row.col.f32.tf32.tf32.f32" ptx-string)
         (format *error-output*
                 "  (the tf32 instruction was emitted instead — :elem did not reach the PTX branch)~%"))
       nil)
      ((search "tf32" ptx-string)
       (format *error-output*
               "FAIL: fp16 MMA present but tf32 survives in the same module — some A/B path~%~
                       still mints tf32 fragments (the 155/02 partial-conversion failure mode).~%")
       nil)
      (t t))))

;; overlays/spec-runner-overlay.lisp
;; (REPLACES compile-crisp-file-to-ptx, tests/run-specs.lisp:2081 -- endeavour 159 Phase B.)
;;
;; ONE CHANGE, marked below: initialize-compiler now receives :hardware-profile.
;;
;; WHY.  run-single-spec-pass (run-specs.lisp:961-970) already binds *compile-hardware-profile*
;; from a TEST-WITH --hardware-profile= flag, and compile-crisp-file-to-spirv already forwards it
;; (run-specs.lisp:1163, carrying the comment "Endeavour 155: the missing argument -- see
;; header.").  The PTX twin never did, so a PTX spec could PASS the flag and still compile with no
;; profile active.  That is endeavour 155's SPV-fixed / PTX-untouched asymmetry showing up in the
;; harness rather than the compiler.
;;
;; It stayed invisible because no PTX spec had needed a profile before: NVIDIA register-tile specs
;; either predate the profile requirement or pass their shapes literally.  The first spec to need
;; it (159/01, an fp16 register tile) fails with the compiler's own diagnostic -- "load-tile into a
;; register-tile requires a hardware profile (pass --hardware-profile)" -- while visibly passing
;; that very flag.
(defun compile-crisp-file-to-ptx (filepath &key (emit-metadata nil))
  "Compiles a .crisp file to .ptx and returns (values out-path meta-paths).
   Endeavor 152: honours :emit-metadata, mirroring compile-crisp-file-to-spirv.
   Endeavour 159: forwards *compile-hardware-profile*, likewise mirroring that twin -- without
   it a TEST-WITH --hardware-profile= flag was parsed, bound, and then silently dropped."
  (let* ((base-name (if *compile-differentiate* (format nil "~a_grad" (pathname-name filepath)) (pathname-name filepath)))
         (out-path (make-pathname :name base-name :type "ptx" :defaults filepath))
         (meta-base-path (make-pathname :name base-name :type nil :defaults filepath))
         (meta-paths nil)
         (*standard-output* (make-broadcast-stream)))
    (when (probe-file out-path) (delete-file out-path))

    (let (;; Use a FRESH environment for each spec to ensure isolation
          (crisp.compiler::*struct-name-prefix* (format nil "S_~a_" (substitute #\_ #\- (pathname-name filepath))))
          (forms (progn
                  (crisp.compiler:initialize-compiler :log-level cl-user::*log-level*
                                                      :differentiate *compile-differentiate*
                                                      ;; Endeavour 159: the missing argument.
                                                      :hardware-profile *compile-hardware-profile*)
                  (let ((*package* (find-package :crisp-language)))
                    (with-open-file (stream filepath)
                      (loop for form = (read stream nil :eof)
                            until (eq form :eof)
                            collect form))))))
      (let* ((module (crisp.llvm-bindings:llvm-module-create (pathname-name filepath)))
             (builder (crisp.llvm-bindings:llvm-create-builder)))
        (unwind-protect
            (progn
             (let ((crisp.compiler:*target-backend* :ptx)
                   (crisp.compiler::*emit-metadata* emit-metadata))
               (crisp.compiler:compile-module forms module builder nil nil nil)
               (crisp.compiler:compile-to-ptx
                module out-path
                :compute-capability (crisp.compiler::ptx-compute-capability-string))
               (when emit-metadata
                 (setf meta-paths
                       (crisp.compiler::generate-metadata-for-file
                        filepath meta-base-path
                        :output-targets (list (list :ptx out-path))
                        :forms forms)))))
          (crisp.llvm-bindings:llvm-dispose-builder builder)
          (crisp.llvm-bindings:llvm-dispose-module module))))

    (if (probe-file out-path)
        (values out-path meta-paths)
        (values nil nil))))
