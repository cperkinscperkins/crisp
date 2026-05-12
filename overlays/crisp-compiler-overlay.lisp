;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)


;; src/compiler.lisp
;; Backward kernels emit `atomicrmw fadd` for thread-safe gradient accumulation
;; into tensor _grad cells. The default SPIR-V translator rejects this with
;; "Feature requires the following SPIR-V extension: SPV_EXT_shader_atomic_float_add".
;; When --differentiate is active, request the extension so translation succeeds.
;; Forward-mode invocations are unchanged.
(defun compile-to-spirv (module output-path &key debug-p)
  "Compiles an LLVM Module to SPIR-V using the external toolchain.
   Runs %remove-dead-array-returning-functions before translation to
   prevent IGC from miscompiling dead TypeArray-returning functions
   (bug 028 workaround Part 2)."
  (let* ((base-path (uiop:pathname-directory-pathname output-path))
         (name (pathname-name output-path))
         (ll-file (merge-pathnames (format nil "~a.temp.ll" name) base-path))
         (bc-file (merge-pathnames (format nil "~a.temp.bc" name) base-path))
         (spv-file output-path))

    (%remove-dead-array-returning-functions module)
    (llvm-set-target module "spir64-unknown-unknown")

    (let* ((ir (cffi:foreign-string-to-lisp (llvm-print-module-to-string module)))
           (ir-with-metadata (inject-spir-kernel-metadata ir)))
      (with-open-file (stream ll-file :direction :output :if-exists :supersede)
        (write-string ir-with-metadata stream)))

    (let ((tool (resolve-tool-executable "llvm-as")))
      (run-tool-command
       (list tool (namestring ll-file) "-o" (namestring bc-file))
       :log-prefix "[SPIR-V] "))

    (let* ((tool (resolve-tool-executable "llvm-spirv"))
           (debug-flags (if debug-p '("--spirv-debug-info-version=ocl-100") nil))
           (ad-flags (if *differentiate-p*
                         '("--spirv-ext=+SPV_EXT_shader_atomic_float_add")
                         nil))
           (flags (append debug-flags ad-flags)))
      (run-tool-command
       (append (list tool) flags (list (namestring bc-file) "-o" (namestring spv-file)))
       :log-prefix "[SPIR-V] "))

    (unless debug-p
      (when (probe-file ll-file) (delete-file ll-file))
      (when (probe-file bc-file) (delete-file bc-file)))

    (log:info "Generated SPIR-V: ~a" spv-file)))


;; src/metadata-val.lisp
;; New validator for the 101-revisit-autodiff endeavor: locks the invariant
;; that SROA-destructured compound-type fields (offset, stride, extent, length,
;; parent, byte-size) never surface as standalone _grad cells in the backward
;; kernel signature. Each logical declared parameter gets at most one logical
;; _grad companion of the same shape.
(defun %ends-with-grad-p (name)
  "Returns T if NAME (a string) ends with '_grad' (case-insensitive)."
  (and (stringp name)
       (>= (length name) 5)
       (string-equal "_grad" (subseq name (- (length name) 5)))))

(defun %strip-grad-suffix (name)
  "Returns NAME with the trailing 5-character '_grad' suffix removed."
  (subseq name 0 (- (length name) 5)))

(defun validate-no-sroa-grad-leak (metadata-path)
  "Locks the no-SROA-grad-leak invariant for backward kernels.

   For every entry in the kernel's :declared-signature whose :name ends in
   '_grad', the name stripped of '_grad' must also appear as an entry's
   :name in the same declared-signature.

   This catches the failure mode where SROA-expanded scalar components of a
   compound type (e.g. a tensor's offset/stride/extent/length/parent/byte-size)
   leak as standalone _grad cells in the backward kernel signature, rather
   than riding along inside the single logical _grad companion of the
   compound parameter.

   In the forward (non --differentiate) suite, no _grad entries exist in
   declared-signature at all, so the validator passes trivially. The same
   test file therefore locks the invariant under both passes."
  (unless (probe-file metadata-path)
    (log:error "validate-no-sroa-grad-leak: file not found: ~a" metadata-path)
    (return-from validate-no-sroa-grad-leak nil))
  (let* ((forms (%read-metacrisp-forms metadata-path))
         (kernels (%metacrisp-section forms :kernels))
         (ok t))
    (unless kernels
      (log:error "validate-no-sroa-grad-leak: no :kernels section in ~a" metadata-path)
      (return-from validate-no-sroa-grad-leak nil))
    (dolist (k kernels)
      (let ((k-name (getf k :name))
            (decl   (getf k :declared-signature)))
        (dolist (entry decl)
          (let ((nm (getf entry :name)))
            (when (%ends-with-grad-p nm)
              (let* ((stripped (%strip-grad-suffix nm))
                     (twin (%find-decl-entry decl stripped)))
                (unless twin
                  (log:error "validate-no-sroa-grad-leak: kernel ~a has stray _grad entry ~a -- no forward twin ~a in declared-signature ~a"
                             k-name nm stripped
                             (mapcar (lambda (e) (getf e :name)) decl))
                  (setf ok nil))))))))
    ok))

