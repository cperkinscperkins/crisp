(in-package :crisp.hoist.l0)

;;;; =====================================================================================
;;;; ENDEAVOUR 193 (logging-output) -- PHASE B: the die report.
;;;; After the kernel runs, a launcher whose .metacrisp has a (:die-sites ...) section reads the
;;;; module-scope @__crisp_die_record by name (zeModuleGetGlobalPointer) and, if site_id != 0,
;;;; prints   DIE <file>:<line> group <g> local <l>[: <message>]
;;;; The record is zero from module load, and this launcher launches once, so no pre-launch zeroing.
;;;; =====================================================================================

;; src/hoist-l0/main.lisp (endeavour 193)
(defvar *193-die-sites* nil
  "Endeavour 193.  The (:die-sites ...) plist of the .metacrisp being hoisted, or NIL.")

;; src/hoist/common.lisp (endeavour 193)
(defun %193-read-die-sites (metacrisp-path)
  "Endeavour 193.  The plist of the (:die-sites :record NAME :sites (...)) section, or NIL."
  (with-open-file (stream metacrisp-path :direction :input)
    (loop for form = (read stream nil :eof)
          until (eq form :eof)
          when (and (consp form) (eq (first form) :die-sites))
            return (rest form))))

;; src/hoist/common.lisp (endeavour 193)
(defun %193-c-string (s)
  "Endeavour 193.  S as the body of a C string literal (backslashes and quotes escaped)."
  (with-output-to-string (out)
    (loop for c across s
          do (when (member c '(#\\ #\")) (write-char #\\ out))
             (write-char c out))))

;; src/hoist-l0/main.lisp (endeavour 193)
(defun %193-l0-emit-die-report (stream)
  "Endeavour 193.  C++ that reads the die record and prints the DIE line from the site table."
  (let ((record (getf *193-die-sites* :record))
        (sites (getf *193-die-sites* :sites)))
    (format stream "    {   // Endeavour 193: the die record (~d site~:p)~%" (length sites))
    (format stream "        void* _dieRecDev = nullptr; size_t _dieRecSize = 0;~%")
    (format stream "        if (zeModuleGetGlobalPointer(module, \"~a\", &_dieRecSize, &_dieRecDev) == ZE_RESULT_SUCCESS && _dieRecSize >= 16) {~%" record)
    (format stream "            uint32_t* _dieRec = nullptr;~%")
    (format stream "            ze_host_mem_alloc_desc_t _dieHostDesc = { ZE_STRUCTURE_TYPE_HOST_MEM_ALLOC_DESC };~%")
    (format stream "            zeMemAllocHost(context, &_dieHostDesc, 16, 16, (void**)&_dieRec);~%")
    (format stream "            ze_command_list_handle_t _dieList;~%")
    (format stream "            zeCommandListCreate(context, device, &cmdListDesc, &_dieList);~%")
    (format stream "            zeCommandListAppendMemoryCopy(_dieList, _dieRec, _dieRecDev, 16, nullptr, 0, nullptr);~%")
    (format stream "            zeCommandListClose(_dieList);~%")
    (format stream "            zeCommandQueueExecuteCommandLists(cmdQueue, 1, &_dieList, nullptr);~%")
    (format stream "            zeCommandQueueSynchronize(cmdQueue, UINT64_MAX);~%")
    (format stream "            zeCommandListDestroy(_dieList);~%")
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
    (format stream "            zeMemFree(context, _dieRec);~%")
    (format stream "        } else {~%")
    (format stream "            std::cerr << \"WARNING: die record ~a not found in the module\" << std::endl;~%" record)
    (format stream "        }~%")
    (format stream "    }~%~%")))

;; src/hoist-l0/main.lisp (endeavour 193) -- FOLD: bind *193-die-sites* in generate-l0-launcher.
(defvar *193-orig-generate-l0-launcher* (fdefinition 'generate-l0-launcher))
(defun generate-l0-launcher (metacrisp-path)
  "Generate Level Zero C++ launcher code from metacrisp file.
   Endeavour 193 wrapper: makes the file's (:die-sites ...) section available to the emitters."
  (let ((*193-die-sites* (%193-read-die-sites metacrisp-path)))
    (when *193-die-sites*
      (format t "  Die sites: ~d~%" (length (getf *193-die-sites* :sites))))
    (funcall *193-orig-generate-l0-launcher* metacrisp-path)))

;; src/hoist-l0/main.lisp (endeavour 193) -- FOLD: call %193-l0-emit-die-report at the end of
;; generate-kernel-launch, after "Kernel executed successfully".
(defvar *193-orig-generate-kernel-launch* (fdefinition 'generate-kernel-launch))
(defun generate-kernel-launch (stream kernel-name declared-sig aliases records &optional dispatch-info)
  "Generate kernel creation and launch code. Returns list of USM allocations.
   Endeavour 193 wrapper: then, for a module that can die, the die report."
  (prog1 (funcall *193-orig-generate-kernel-launch* stream kernel-name declared-sig aliases records dispatch-info)
    (when *193-die-sites*
      (%193-l0-emit-die-report stream))))

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

;; src/hoist-l0/main.lisp (endeavour 193)
(defun %193-l0-emit-log-report (stream)
  "Endeavour 193.  C++ that reads @__crisp_log by name (zeModuleGetGlobalPointer) and prints it."
  (let ((record (getf *193-log-sites* :record)))
    (format stream "    {   // Endeavour 193: the log (~d site~:p)~%" (length (getf *193-log-sites* :sites)))
    (format stream "        void* _logDev = nullptr; size_t _logSize = 0;~%")
    (format stream "        if (zeModuleGetGlobalPointer(module, \"~a\", &_logSize, &_logDev) == ZE_RESULT_SUCCESS && _logSize >= 16) {~%" record)
    (format stream "            uint32_t* _log = nullptr;~%")
    (format stream "            ze_host_mem_alloc_desc_t _logHostDesc = { ZE_STRUCTURE_TYPE_HOST_MEM_ALLOC_DESC };~%")
    (format stream "            zeMemAllocHost(context, &_logHostDesc, _logSize, 16, (void**)&_log);~%")
    (format stream "            ze_command_list_handle_t _logList;~%")
    (format stream "            zeCommandListCreate(context, device, &cmdListDesc, &_logList);~%")
    (format stream "            zeCommandListAppendMemoryCopy(_logList, _log, _logDev, _logSize, nullptr, 0, nullptr);~%")
    (format stream "            zeCommandListClose(_logList);~%")
    (format stream "            zeCommandQueueExecuteCommandLists(cmdQueue, 1, &_logList, nullptr);~%")
    (format stream "            zeCommandQueueSynchronize(cmdQueue, UINT64_MAX);~%")
    (format stream "            zeCommandListDestroy(_logList);~%")
    (%193-emit-log-decode stream)
    (format stream "            zeMemFree(context, _log);~%")
    (format stream "        } else {~%")
    (format stream "            std::cerr << \"WARNING: log ~a not found in the module\" << std::endl;~%" record)
    (format stream "        }~%")
    (format stream "    }~%~%")))

;; src/hoist-l0/main.lisp (endeavour 193) -- supersedes the copy above: both sections.
(defun generate-l0-launcher (metacrisp-path)
  "Generate Level Zero C++ launcher code from metacrisp file.
   Endeavour 193 wrapper: makes the file's (:die-sites ...) and (:log-sites ...) sections available
   to the emitters."
  (let ((*193-die-sites* (%193-read-metacrisp-section metacrisp-path :die-sites))
        (*193-log-sites* (%193-read-metacrisp-section metacrisp-path :log-sites)))
    (when *193-die-sites*
      (format t "  Die sites: ~d~%" (length (getf *193-die-sites* :sites))))
    (when *193-log-sites*
      (format t "  Log sites: ~d~%" (length (getf *193-log-sites* :sites))))
    (funcall *193-orig-generate-l0-launcher* metacrisp-path)))

;; src/hoist-l0/main.lisp (endeavour 193) -- supersedes the copy above: the log, then the die report.
(defun generate-kernel-launch (stream kernel-name declared-sig aliases records &optional dispatch-info)
  "Generate kernel creation and launch code. Returns list of USM allocations.
   Endeavour 193 wrapper: then the log (if the module logs) and the die report (if it can die)."
  (prog1 (funcall *193-orig-generate-kernel-launch* stream kernel-name declared-sig aliases records dispatch-info)
    (when *193-log-sites*
      (%193-l0-emit-log-report stream))
    (when *193-die-sites*
      (%193-l0-emit-die-report stream))))

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
