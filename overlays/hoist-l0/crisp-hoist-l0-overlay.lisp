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
