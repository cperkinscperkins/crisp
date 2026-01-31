;; build/build.lisp

;;  sbcl --load build/build.lisp
;;  sbcl --non-interactive --load build/build.lisp
;;  or launch sbcl and then
;;  (load #P"./build/build.lisp")


(in-package :cl-user)

;; load the crisp system using Quicklisp
(format t "~&; --- Loading Crisp system via Quicklisp...~%")
(require "asdf")
;; Tell Quicklisp to find local projects in the current directory
(push *default-pathname-defaults* ql:*local-project-directories*)

(asdf:clear-system "crisp")
(asdf:clear-system "cffi")


(uiop::ensure-directories-exist "bin/")
(let ((exe (merge-pathnames "bin/crisp-compile.exe" *default-pathname-defaults*)))
  (when (probe-file exe)
        (format t "~&; Deleting old executable: ~a~%" exe)
        (delete-file exe)))

(format t "~&; Deploying Tools...~%")
(dolist (tool-info '(("llvm-spirv" "llvm-spirv")
                     ("llvm-as" "llvm-as")
                     ("llc" "llc")
                     ("LLVM-C" "LLVM-C")))
  (destructuring-bind (tool-base dest-base) tool-info
    (let* ((suffix (if (string-equal tool-base "LLVM-C")
                       (if (uiop:os-windows-p) "-windows.dll" "-linux.so")
                       (if (uiop:os-windows-p) "-windows.exe" "-linux")))
           (dest-suffix (if (string-equal tool-base "LLVM-C")
                            (if (uiop:os-windows-p) ".dll" ".so")
                            (if (uiop:os-windows-p) ".exe" "")))
           (tool-name (format nil "~a~a" tool-base suffix))
           (dest-name (if (and (string-equal tool-base "LLVM-C") (not (uiop:os-windows-p)))
                          "libLLVM.so"
                          (format nil "~a~a" dest-base dest-suffix)))
           (src (merge-pathnames (format nil "tools/~a" tool-name) *default-pathname-defaults*))
           (dest (merge-pathnames (format nil "bin/~a" dest-name) *default-pathname-defaults*)))

      (if (probe-file src)
          (with-open-file (stream src :element-type '(unsigned-byte 8))
            (let ((size (file-length stream)))
              (cond
               ((< size 1000)
                 (format t ";   WARNING: Skipping ~a (Size: ~d bytes). Likely Git LFS pointer.~%" tool-name size)
                 ;; Ensure destination does not exist so fallback logic works
                 (when (probe-file dest)
                       (delete-file dest)))
               (t
                 (format t ";   Copying ~a to bin/~%" tool-name)
                 (ignore-errors (uiop:copy-file src dest))
                 (unless (uiop:os-windows-p)
                   (uiop:run-program (list "chmod" "+x" (namestring dest))))))))
          (format t ";   WARNING: Tool ~a not found in tools/ directory.~%" tool-name)))))

;; ql:quickload will find crisp.asd, see the dependencies,
;; download cffi, and then load crisp.

;; While exceptionally rare,  it's possible to have stale FASL . Uncomment the next line to force a recompilation. Note this means a DOUBLE compilation.
;; (asdf:load-system "crisp" :force t)

(ql:quickload "crisp")
(format t "~&; --- System loaded successfully.~%")


(asdf:make "crisp" :force t)
(uiop:quit 0)