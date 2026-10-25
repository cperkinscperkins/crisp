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

;;;; =====================================================================================
;;;; ENDEAVOUR 193 -- PHASE D: the log report.  The same code is appended to the L0 and CUDA hoist
;;;; overlays (FOLD once, into src/hoist/common.lisp -- the hoist-common overlay is not loaded by
;;;; the hoist builds).
;;;; =====================================================================================

;; src/hoist/common.lisp (endeavour 193)
(defvar *193-log-sites* nil
  "Endeavour 193.  The (:log-sites ...) plist of the .metacrisp being hoisted, or NIL.")

;; src/hoist/common.lisp (endeavour 193)
(defun %193-read-metacrisp-section (metacrisp-path key)
  "Endeavour 193.  The plist of the top-level (KEY ...) section of the .metacrisp, or NIL."
  (with-open-file (stream metacrisp-path :direction :input)
    (loop for form = (read stream nil :eof)
          until (eq form :eof)
          when (and (consp form) (eq (first form) key))
            return (rest form))))

;; src/hoist/common.lisp (endeavour 193)
(defun %193-emit-log-value (stream kind slot-index)
  "Endeavour 193.  C++ printing one log value: KIND's decoding of 64-bit slot SLOT-INDEX of the
   message at _logData[_p]."
  (let ((lo (format nil "_logData[_p + ~d]" (+ 3 (* 2 slot-index))))
        (hi (format nil "_logData[_p + ~d]" (+ 4 (* 2 slot-index)))))
    (ecase (intern (string-upcase (symbol-name kind)) :keyword)
      (:int    (format stream "                        std::cout << \" \" << (int32_t)~a;~%" lo))
      (:uint   (format stream "                        std::cout << \" \" << (uint32_t)~a;~%" lo))
      (:long   (format stream "                        std::cout << \" \" << (int64_t)((uint64_t)~a | ((uint64_t)~a << 32));~%" lo hi))
      (:ulong  (format stream "                        std::cout << \" \" << ((uint64_t)~a | ((uint64_t)~a << 32));~%" lo hi))
      (:float  (format stream "                        { uint32_t _b = ~a; float _f; std::memcpy(&_f, &_b, 4); std::cout << \" \" << _f; }~%" lo))
      (:double (format stream "                        { uint64_t _b = (uint64_t)~a | ((uint64_t)~a << 32); double _d; std::memcpy(&_d, &_b, 8); std::cout << \" \" << _d; }~%" lo hi)))))

;; src/hoist/common.lisp (endeavour 193)
(defun %193-emit-log-decode (stream)
  "Endeavour 193.  C++ that decodes the host copy of the log (uint32_t* _log) with the site table
   and prints each message as LOG <file>:<line> group <g> local <l>: <message>, then LOG FULL if
   the launch claimed more than the capacity."
  (let ((cap (getf *193-log-sites* :capacity-words))
        (sites (getf *193-log-sites* :sites)))
    (format stream "            uint64_t _logCursor = (uint64_t)_log[0] | ((uint64_t)_log[1] << 32);~%")
    (format stream "            const uint64_t _logCap = ~dULL;~%" cap)
    (format stream "            const uint64_t _logUsed = _logCursor < _logCap ? _logCursor : _logCap;~%")
    (format stream "            const uint32_t* _logData = _log + 4;~%")
    (format stream "            uint64_t _p = 0;~%")
    (format stream "            while (_p < _logUsed && _logData[_p] != 0) {~%")
    (format stream "                switch (_logData[_p]) {~%")
    (dolist (s sites)
      (destructuring-bind (id file line pieces) s
        (let ((nvals (count-if-not #'stringp pieces)))
          (format stream "                    case ~d: {~%" id)
          (format stream "                        std::cout << \"LOG ~a:~d group \" << _logData[_p + 1] << \" local \" << _logData[_p + 2] << \":\";~%"
                  (%193-c-string file) line)
          (let ((slot 0))
            (dolist (piece pieces)
              (if (stringp piece)
                  (format stream "                        std::cout << \" ~a\";~%" (%193-c-string piece))
                  (progn (%193-emit-log-value stream piece slot)
                         (incf slot)))))
          (format stream "                        std::cout << std::endl;~%")
          (format stream "                        _p += ~d;~%" (+ 3 (* 2 nvals)))
          (format stream "                        break;~%")
          (format stream "                    }~%"))))
    (format stream "                    default:~%")
    (format stream "                        std::cout << \"LOG <unknown site \" << _logData[_p] << \">\" << std::endl;~%")
    (format stream "                        _p = _logUsed;~%")
    (format stream "                        break;~%")
    (format stream "                }~%")
    (format stream "            }~%")
    (format stream "            if (_logCursor > _logCap) {~%")
    (format stream "                const uint64_t _wanted = 16 + _logCursor * 4;~%")
    (format stream "                std::cout << \"LOG FULL: kept \" << (16 + _logCap * 4) << \" bytes; the launch wanted \" << _wanted~%")
    (format stream "                          << \" (recompile with --logging-size=\" << ((_wanted + 1048575) >> 20) << \"M)\" << std::endl;~%")
    (format stream "            }~%")))

;; src/hoist-cuda/main.lisp (endeavour 193)
(defun %193-cuda-emit-log-report (stream)
  "Endeavour 193.  C++ that reads __crisp_log by name (cuModuleGetGlobal) and prints it."
  (let ((record (getf *193-log-sites* :record)))
    (format stream "    {   // Endeavour 193: the log (~d site~:p)~%" (length (getf *193-log-sites* :sites)))
    (format stream "        CUdeviceptr _logDev = 0; size_t _logSize = 0;~%")
    (format stream "        if (cuModuleGetGlobal(&_logDev, &_logSize, module, \"~a\") == CUDA_SUCCESS && _logSize >= 16) {~%" record)
    (format stream "            std::vector<uint32_t> _logHost(_logSize / 4);~%")
    (format stream "            CUDA_CHECK(cuMemcpyDtoH(_logHost.data(), _logDev, _logSize));~%")
    (format stream "            const uint32_t* _log = _logHost.data();~%")
    (%193-emit-log-decode stream)
    (format stream "        } else {~%")
    (format stream "            std::cerr << \"WARNING: log ~a not found in the module\" << std::endl;~%" record)
    (format stream "        }~%")
    (format stream "    }~%~%")))

;; src/hoist-cuda/main.lisp (endeavour 193) -- supersedes the copy above: both sections.
(defun generate-cuda-launcher (metacrisp-path)
  "Endeavour 193 wrapper: makes the file's (:die-sites ...) and (:log-sites ...) sections available
   to the emitters."
  (let ((*193-die-sites* (%193-read-metacrisp-section metacrisp-path :die-sites))
        (*193-log-sites* (%193-read-metacrisp-section metacrisp-path :log-sites)))
    (when *193-die-sites*
      (format t "  Die sites: ~d~%" (length (getf *193-die-sites* :sites))))
    (when *193-log-sites*
      (format t "  Log sites: ~d~%" (length (getf *193-log-sites* :sites))))
    (funcall *193-orig-generate-cuda-launcher* metacrisp-path)))

;; src/hoist-cuda/main.lisp (endeavour 193) -- supersedes the copy above: the log, then the die report.
(defun emit-readback (stream allocations)
  "Endeavour 193 wrapper: the log and the die report first (the kernel has synchronised), then the
   readback."
  (when *193-log-sites*
    (%193-cuda-emit-log-report stream))
  (when *193-die-sites*
    (%193-cuda-emit-die-report stream))
  (funcall *193-orig-emit-readback* stream allocations))

;; src/hoist/common.lisp (endeavour 193) -- supersedes the copy above: the LOG FULL suggestion is in K below 1M.
(defun %193-emit-log-decode (stream)
  "Endeavour 193.  C++ that decodes the host copy of the log (uint32_t* _log) with the site table
   and prints each message as LOG <file>:<line> group <g> local <l>: <message>, then LOG FULL if
   the launch claimed more than the capacity."
  (let ((cap (getf *193-log-sites* :capacity-words))
        (sites (getf *193-log-sites* :sites)))
    (format stream "            uint64_t _logCursor = (uint64_t)_log[0] | ((uint64_t)_log[1] << 32);~%")
    (format stream "            const uint64_t _logCap = ~dULL;~%" cap)
    (format stream "            const uint64_t _logUsed = _logCursor < _logCap ? _logCursor : _logCap;~%")
    (format stream "            const uint32_t* _logData = _log + 4;~%")
    (format stream "            uint64_t _p = 0;~%")
    (format stream "            while (_p < _logUsed && _logData[_p] != 0) {~%")
    (format stream "                switch (_logData[_p]) {~%")
    (dolist (s sites)
      (destructuring-bind (id file line pieces) s
        (let ((nvals (count-if-not #'stringp pieces)))
          (format stream "                    case ~d: {~%" id)
          (format stream "                        std::cout << \"LOG ~a:~d group \" << _logData[_p + 1] << \" local \" << _logData[_p + 2] << \":\";~%"
                  (%193-c-string file) line)
          (let ((slot 0))
            (dolist (piece pieces)
              (if (stringp piece)
                  (format stream "                        std::cout << \" ~a\";~%" (%193-c-string piece))
                  (progn (%193-emit-log-value stream piece slot)
                         (incf slot)))))
          (format stream "                        std::cout << std::endl;~%")
          (format stream "                        _p += ~d;~%" (+ 3 (* 2 nvals)))
          (format stream "                        break;~%")
          (format stream "                    }~%"))))
    (format stream "                    default:~%")
    (format stream "                        std::cout << \"LOG <unknown site \" << _logData[_p] << \">\" << std::endl;~%")
    (format stream "                        _p = _logUsed;~%")
    (format stream "                        break;~%")
    (format stream "                }~%")
    (format stream "            }~%")
    (format stream "            if (_logCursor > _logCap) {~%")
    (format stream "                const uint64_t _wanted = 16 + _logCursor * 4;~%")
    (format stream "                std::cout << \"LOG FULL: kept \" << (16 + _logCap * 4) << \" bytes; the launch wanted \" << _wanted~%")
    (format stream "                          << \" (recompile with --logging-size=\";~%")
    (format stream "                if (_wanted < (1ULL << 20)) std::cout << ((_wanted + 1023) >> 10) << \"K)\" << std::endl;~%")
    (format stream "                else std::cout << ((_wanted + 1048575) >> 20) << \"M)\" << std::endl;~%")
    (format stream "            }~%")))
