;;;; overlays/hoist-cuda/crisp-hoist-cuda-overlay.lisp
;;;;
;;;; Runtime patches for the CUDA hoister.  Applied via late binding -- last definition wins.
;;;;
;;;; NOTE THE SHAPE CONSTRAINT, learned when this file was last emptied (2026-08-26): a
;;;; late-binding wrapper that captures (fdefinition 'f) into a defvar and then redefines f
;;;; CANNOT be pasted into src/ as-is, because there the capture would grab the function being
;;;; replaced and recurse forever.  Folding one back means splitting it into a base plus a
;;;; wrapper that calls the base BY NAME, as emit-launch / %emit-launch-base already are.
;;;;
;;;; EMPTY AGAIN as of 2026-09-22.  Endeavour 175 (symbolic scratch sizes, CUDA side) folded
;;;; into src/hoist-cuda/main.lisp:
;;;;   emit-main               -- split per the constraint above into %emit-main-base plus a
;;;;                             wrapper that binds *cuda-wg-size* and calls the base by name
;;;;   %cuda-scratch-dims     -- symbolic branch is now its first cond clause
;;;;   %cuda-local-param-bytes-- symbolic clause added to its inner count cond, so the sizer
;;;;                             and the emitters still resolve the size the same way

;;;;
;;;; EMPTY AGAIN as of 2026-10-08.  Endeavour 181 (:match-num-workgroups scratch) folded into
;;;; src/hoist-cuda/main.lisp: *cuda-deferred-scratch*, %cuda-num-workgroups-size-p,
;;;; %cuda-emit-num-workgroups-scratch-arg (the wrapper's branch, now a named function that
;;;; %cuda-emit-global-scratch-tensor-arg returns early into), and emit-launch (injects the
;;;; deferred blocks at the _crisp_launch anchor, after the cluster fix-up).

(in-package :crisp.hoist.cuda)

;;;; =====================================================================================
;;;; ENDEAVOUR 193 (logging-output) -- PHASE B: the die report (CUDA).
;;;; After cuCtxSynchronize, a launcher whose .metacrisp has a (:die-sites ...) section reads the
;;;; module-scope __crisp_die_record by name (cuModuleGetGlobal) and, if site_id != 0, prints
;;;;   DIE <file>:<line> group <g> local <l>[: <message>]
;;;; =====================================================================================

;; src/hoist-cuda/main.lisp (endeavour 193)
(defvar *193-die-sites* nil
  "Endeavour 193.  The (:die-sites ...) plist of the .metacrisp being hoisted, or NIL.")

;; src/hoist/common.lisp (endeavour 193) -- same as the L0 overlay's; FOLD into hoist-common once.
(defun %193-read-die-sites (metacrisp-path)
  "Endeavour 193.  The plist of the (:die-sites :record NAME :sites (...)) section, or NIL."
  (with-open-file (stream metacrisp-path :direction :input)
    (loop for form = (read stream nil :eof)
          until (eq form :eof)
          when (and (consp form) (eq (first form) :die-sites))
            return (rest form))))

;; src/hoist/common.lisp (endeavour 193) -- same as the L0 overlay's; FOLD into hoist-common once.
(defun %193-c-string (s)
  "Endeavour 193.  S as the body of a C string literal (backslashes and quotes escaped)."
  (with-output-to-string (out)
    (loop for c across s
          do (when (member c '(#\\ #\")) (write-char #\\ out))
             (write-char c out))))

;; src/hoist-cuda/main.lisp (endeavour 193)
(defun %193-cuda-emit-die-report (stream)
  "Endeavour 193.  C++ that reads the die record and prints the DIE line from the site table."
  (let ((record (getf *193-die-sites* :record))
        (sites (getf *193-die-sites* :sites)))
    (format stream "    {   // Endeavour 193: the die record (~d site~:p)~%" (length sites))
    (format stream "        CUdeviceptr _dieRecDev = 0; size_t _dieRecSize = 0;~%")
    (format stream "        if (cuModuleGetGlobal(&_dieRecDev, &_dieRecSize, module, \"~a\") == CUDA_SUCCESS && _dieRecSize >= 16) {~%" record)
    (format stream "            uint32_t _dieRec[4] = {0, 0, 0, 0};~%")
    (format stream "            CUDA_CHECK(cuMemcpyDtoH(_dieRec, _dieRecDev, 16));~%")
    (format stream "            if (_dieRec[0] != 0) {~%")
    (format stream "                std::cout << \"DIE \";~%")
    (format stream "                switch (_dieRec[0]) {~%")
    (dolist (s sites)
      (destructuring-bind (id file line message) s
        (declare (ignore message))
        (format stream "                    case ~d: std::cout << \"~a:~d\"; break;~%" id (%193-c-string file) line)))
    (format stream "                    default: std::cout << \"<unknown site \" << _dieRec[0] << \">\"; break;~%")
    (format stream "                }~%")
    (format stream "                std::cout << \" group \" << _dieRec[1] << \" local \" << _dieRec[2];~%")
    (format stream "                switch (_dieRec[0]) {~%")
    (dolist (s sites)
      (destructuring-bind (id file line message) s
        (declare (ignore file line))
        (when message
          (format stream "                    case ~d: std::cout << \": ~a\"; break;~%" id (%193-c-string message)))))
    (format stream "                    default: break;~%")
    (format stream "                }~%")
    (format stream "                std::cout << std::endl;~%")
    (format stream "            }~%")
    (format stream "        } else {~%")
    (format stream "            std::cerr << \"WARNING: die record ~a not found in the module\" << std::endl;~%" record)
    (format stream "        }~%")
    (format stream "    }~%~%")))

;; src/hoist-cuda/main.lisp (endeavour 193) -- FOLD: bind *193-die-sites* in generate-cuda-launcher.
(defvar *193-orig-generate-cuda-launcher* (fdefinition 'generate-cuda-launcher))
(defun generate-cuda-launcher (metacrisp-path)
  "Endeavour 193 wrapper: makes the file's (:die-sites ...) section available to the emitters."
  (let ((*193-die-sites* (%193-read-die-sites metacrisp-path)))
    (when *193-die-sites*
      (format t "  Die sites: ~d~%" (length (getf *193-die-sites* :sites))))
    (funcall *193-orig-generate-cuda-launcher* metacrisp-path)))

;; src/hoist-cuda/main.lisp (endeavour 193) -- FOLD: call %193-cuda-emit-die-report in %emit-main-base,
;; between "Kernel executed successfully" and emit-readback.
(defvar *193-orig-emit-readback* (fdefinition 'emit-readback))
(defun emit-readback (stream allocations)
  "Endeavour 193 wrapper: the die report first (the kernel has synchronised), then the readback."
  (when *193-die-sites*
    (%193-cuda-emit-die-report stream))
  (funcall *193-orig-emit-readback* stream allocations))
