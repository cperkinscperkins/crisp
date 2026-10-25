(in-package :crisp.hoist)

(defun parse-metacrisp-file (filepath)
  "Parse a .metacrisp file and return the data structure.

   Endeavor 130 Phase 5: the active hardware profile (only the selected one) travels in as
   (:hardware-profile (:name \"X\" ...)) and is returned whole under :hardware-profile.

   NOTE: this file is shared by BOTH hoist backends, so it must not reference anything in a
   backend package.  Backend-specific caching of profile values belongs in that backend — see
   %l0-latch-hardware-profile in src/hoist-l0/main.lisp."
  (with-open-file (stream filepath :direction :input)
    (let ((aliases '())
          (structs '())
          (records '())
          (kernels '())
          (hardware-profile nil))
      (loop for form = (read stream nil :eof)
            until (eq form :eof)
            do (cond
                ((and (consp form) (eq (first form) :aliases))
                  (setf aliases (or (rest form) '())))
                ((and (consp form) (eq (first form) :structs))
                  (setf structs (or (rest form) '())))
                ((and (consp form) (eq (first form) :records))
                  (setf records (or (rest form) '())))
                ((and (consp form) (eq (first form) :kernels))
                  (setf kernels (or (rest form) '())))
                ((and (consp form) (eq (first form) :hardware-profile))
                  (setf hardware-profile (second form)))))
      (list :aliases aliases :structs structs :records records :kernels kernels
            :hardware-profile hardware-profile))))

(defun metacrisp-kernels (metacrisp-data)
  "Extract kernels list from metacrisp data."
  (getf metacrisp-data :kernels))

(defun metacrisp-aliases (metacrisp-data)
  "Extract type aliases from metacrisp data."
  (getf metacrisp-data :aliases))

(defun metacrisp-structs (metacrisp-data)
  "Extract struct definitions from metacrisp data."
  (getf metacrisp-data :structs))

(defun metacrisp-records (metacrisp-data)
  "Extract def-record definitions from metacrisp data."
  (getf metacrisp-data :records))

(defun metacrisp-hardware-profile (metacrisp-data)
  "Extract the active hardware profile plist (or NIL) from metacrisp data.
The plist keeps its :name plus every registered key, e.g.
  (:name \"GPU-A\" :COMPUTE-UNITS 132 ...)."
  (getf metacrisp-data :hardware-profile))


;;;; Endeavour 193: the die and log reports -- the site tables come from the .metacrisp's top-level
;;;; (:die-sites ...) / (:log-sites ...) sections; both launchers emit the same decoding.

(defvar *193-die-sites* nil
  "Endeavour 193.  The (:die-sites ...) plist of the .metacrisp being hoisted, or NIL.")

(defvar *193-log-sites* nil
  "Endeavour 193.  The (:log-sites ...) plist of the .metacrisp being hoisted, or NIL.")

(defun %193-read-metacrisp-section (metacrisp-path key)
  "Endeavour 193.  The plist of the top-level (KEY ...) section of the .metacrisp, or NIL."
  (with-open-file (stream metacrisp-path :direction :input)
    (loop for form = (read stream nil :eof)
          until (eq form :eof)
          when (and (consp form) (eq (first form) key))
            return (rest form))))

(defun %193-c-string (s)
  "Endeavour 193.  S as the body of a C string literal (backslashes and quotes escaped)."
  (with-output-to-string (out)
    (loop for c across s
          do (when (member c '(#\\ #\")) (write-char #\\ out))
             (write-char c out))))

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
