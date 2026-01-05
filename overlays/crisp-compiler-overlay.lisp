;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;; ---------------------------------------------------------------------------
;;; INSTRUCTIONS:
;;; 1. Append new/fixed function definitions to the end of this file.
;;; 2. Add a comment referencing the original file (e.g. ;;; FROM: src/environment.lisp)
;;; 3. Do not modify the original file in src/ until cleanup time.

(in-package :crisp.compiler)

;;; --- START PATCHES ---
;; src/compiler.lisp - Fixed metadata injection to put everything on one line
(defun inject-spir-kernel-metadata (ir-text)
  "Inject OpenCL kernel metadata for all SPIR kernels found in IR text.
   Returns modified IR text with metadata."
  (let ((kernels (find-spir-kernels ir-text)))
    (if (null kernels)
        ir-text
        (let ((result ir-text)
              (metadata-id-base 100)
              (all-metadata-defs ""))

          (dolist (kernel-info kernels)
            (destructuring-bind (func-name func-start brace-pos) kernel-info
              (log:info "Injecting metadata for kernel: ~a" func-name)

              (let ((params (extract-kernel-params result func-start brace-pos)))
                (log:info "  Parameters: ~a" params)

                (multiple-value-bind (metadata-refs metadata-defs next-id)
                    (generate-kernel-metadata params metadata-id-base)

                  (let* ((kernel-sig-start (search func-name result))
                         (new-brace-pos (position #\{ result :start kernel-sig-start))
                         (close-paren-pos (position #\) result :end new-brace-pos :from-end t)))

                    (setf result (concatenate 'string
                                   (subseq result 0 (1+ close-paren-pos))
                                   metadata-refs
                                   " "
                                   (string #\{)
                                   (subseq result (1+ new-brace-pos))))

                    (setf all-metadata-defs (concatenate 'string all-metadata-defs metadata-defs))
                    (setf metadata-id-base next-id))))))

          (concatenate 'string result (format nil "~%~%") all-metadata-defs)))))

;; src/compiler.lisp - Fixed parameter extraction to handle types with spaces
(defun extract-kernel-params (ir-text func-start func-end)
  "Extract parameter types from a kernel function signature.
   Returns list of type strings (e.g., 'ptr addrspace(1)', 'i64')."
  (let* ((sig-text (subseq ir-text func-start func-end))
         (paren-start (position #\( sig-text))
         (paren-end (position #\) sig-text :from-end t)))

    (unless (and paren-start paren-end (< paren-start paren-end))
      (log:warn "Could not find parameter parens!")
      (return-from extract-kernel-params nil))

    (let* ((params-text (subseq sig-text (1+ paren-start) paren-end))
           (params '()))

      (log:info "extract-kernel-params: params-text = ~s" params-text)

      (dolist (param-str (uiop:split-string params-text :separator ","))
        (let ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return) param-str)))
          (when (> (length trimmed) 0)
                (let ((percent-pos (position #\% trimmed)))
                  (if percent-pos
                      (let ((type-text (string-trim '(#\Space #\Tab) (subseq trimmed 0 percent-pos))))
                        (when (> (length type-text) 0)
                              (log:info "  extracted type: ~s" type-text)
                              (push type-text params)))
                      (progn
                       (log:info "  extracted type (no name): ~s" trimmed)
                       (push trimmed params)))))))

      (nreverse params))))
