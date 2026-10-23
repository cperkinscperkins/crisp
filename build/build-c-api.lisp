;; build/build-c-api.lisp
;;
;; Endeavour 190: builds the Crisp compile API library (c-api/src/crisp.c) into bin/, next to
;; crisp-compile -- the layout the library expects (it finds crisp-compile beside itself).
;;   Windows: bin/crisp.dll + bin/libcrisp.dll.a (import library)
;;   Linux:   bin/libcrisp.so
;; The C compiler is $CC, else the first of gcc / clang on PATH.  With none, this WARNS and skips:
;; the compiler itself does not need it, only the compile API (tests/api/, HOIST-KERNEL: source).
;; Run from the repo root (build/build.lisp runs it).
(in-package :cl-user)

(require :uiop)

(defun %c-api-find-cc ()
  "The C compiler to use, or NIL."
  (or (let ((cc (uiop:getenv "CC"))) (and cc (plusp (length cc)) cc))
      (find-if (lambda (cc)
                 (ignore-errors
                  (zerop (nth-value 2 (uiop:run-program (list cc "--version") :output nil :error-output nil
                                                                             :ignore-error-status t)))))
               '("gcc" "clang"))))

(let ((cc (%c-api-find-cc))
      (warn-flags '("-std=c99" "-Wall" "-Wextra" "-pedantic" "-O2")))
  (ensure-directories-exist "bin/")
  (if (null cc)
      (format t "~&;;; WARNING: no C compiler (set CC, or put gcc / clang on PATH) -- the compile API library was NOT built.~%")
      (let ((args (if (uiop:os-windows-p)
                      (append (list cc) warn-flags
                              (list "-shared" "-Ic-api/include" "c-api/src/crisp.c"
                                    "-o" "bin/crisp.dll" "-Wl,--out-implib,bin/libcrisp.dll.a"))
                      (append (list cc) warn-flags
                              (list "-shared" "-fPIC" "-fvisibility=hidden" "-Ic-api/include" "c-api/src/crisp.c"
                                    "-o" "bin/libcrisp.so" "-ldl" "-lpthread")))))
        (format t "~&;;; ~{~a~^ ~}~%" args)
        (uiop:run-program args :output :interactive :error-output :interactive) ; signals on failure
        (format t ";;; built ~a~%" (if (uiop:os-windows-p) "bin/crisp.dll" "bin/libcrisp.so")))))

(uiop:quit 0)
