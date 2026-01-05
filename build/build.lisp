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
                     ("llc" "llc")))
  (destructuring-bind (tool-base dest-base) tool-info
    (let* ((tool-name (if (uiop:os-windows-p)
                          (format nil "~a-windows.exe" tool-base)
                          (format nil "~a-linux" tool-base)))
           (dest-name (if (uiop:os-windows-p)
                          (format nil "~a.exe" dest-base)
                          dest-base))
           (src (merge-pathnames (format nil "tools/~a" tool-name) *default-pathname-defaults*))
           (dest (merge-pathnames (format nil "bin/~a" dest-name) *default-pathname-defaults*)))

      (if (probe-file src)
          (progn
           (format t ";   Copying ~a to bin/~%" tool-name)
           (uiop:copy-file src dest)
           (unless (uiop:os-windows-p)
             (uiop:run-program (list "chmod" "+x" (namestring dest)))))
          (format t ";   WARNING: Tool ~a not found in tools/ directory.~%" tool-name)))))

;; ql:quickload will find crisp.asd, see the dependencies,
;; download cffi, and then load crisp.
;; Force recompilation to ensure no stale FASLs with bad encodings persist
(asdf:load-system "crisp" :force t)
(ql:quickload "crisp")
(format t "~&; --- System loaded successfully.~%")


(asdf:make "crisp" :force t)
(uiop:quit 0)