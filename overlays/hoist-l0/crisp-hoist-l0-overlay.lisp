(in-package :crisp.hoist.l0)

;; Overlay file for crisp-hoist-l0
;; Add late-binding fixes here as needed

;; Fix for robust SPIR-V path resolution and ghost hoisting warning
(defun generate-l0-launcher (metacrisp-path)
  "Generate Level Zero C++ launcher code from metacrisp file"
  (let* ((data (parse-metacrisp-file metacrisp-path))
         (kernels (metacrisp-kernels data))
         (aliases (metacrisp-aliases data))
         (base-name (pathname-name metacrisp-path)))

    (format t "Processing ~a~%" metacrisp-path)
    (format t "  Kernels: ~a~%" (length kernels))

    ;; [Fix] Warn if no kernels found
    (when (null kernels)
      (format t "WARNING: No kernels found in ~a. Nothing to hoist.~%" metacrisp-path))

    ;; Generate one .cpp file per kernel
    (dolist (kernel kernels)
      (let* ((kernel-name (getf kernel :name))
             (declared-sig (getf kernel :declared-signature))
             (implicit-sig (getf kernel :implicit-params))
             ;; Robustly extract range start for sorting
             (comparable-range-start (lambda (param)
                                       (let ((r (getf param :range)))
                                         (if (listp r) (first r) -1))))
             (full-sig (sort (append declared-sig implicit-sig) #'<
                         :key comparable-range-start))
             (output-targets (getf kernel :output-targets)))
             
        (let* (;; [Fix] Explicitly find SPIR-V target path
               (spv-path-entry (or (assoc :spirv output-targets)
                                   (assoc :spv output-targets)))
               (spv-path (when spv-path-entry (second spv-path-entry)))
               
               ;; Deduplicate kernel name in filename if present
               (suffix (format nil "_~a" kernel-name))
               (name-part (if (uiop:string-suffix-p base-name suffix)
                              base-name
                              (format nil "~a~a" base-name suffix)))
               
               (output-name (format nil "~a_L0.cpp" name-part))
               (output-path (make-pathname :name (pathname-name output-name)
                                           :type "cpp"
                                           :defaults metacrisp-path)))

          ;; [Fix] Skip if no SPIR-V target found for this kernel
          (if (null spv-path)
              (format t "WARNING: No SPIR-V target found for kernel ~a. Skipping host generation.~%" kernel-name)
              (progn
                (format t "  Generating: ~a~%" output-name)

                ;; Generate Level Zero C++ launcher
                (with-open-file (stream output-path :direction :output :if-exists :supersede)
                  (generate-cpp-preamble stream metacrisp-path kernel-name output-name)
                  (generate-cpp-includes stream)
                  (generate-cpp-typedefs stream aliases)
                  (generate-cpp-structs stream (metacrisp-structs data))
                  (generate-cpp-helpers stream)
                  (generate-cpp-main stream kernel-name spv-path full-sig aliases))

                (format t "  Done: ~a~%" (namestring output-path)))))))))
