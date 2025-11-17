;; build/build.lisp

;;  sbcl --load build/build.lisp
;;  sbcl --non-interactive --load build/build.lisp
;;  or launch sbcl and then
;;  (load #P"./build/build.lisp")


(in-package :cl-user)

;; load the crisp system using Quicklisp
(format t "~&; --- Loading Crisp system via Quicklisp...~%")
;; Tell Quicklisp to find local projects in the current directory
(push *default-pathname-defaults* ql:*local-project-directories*)

(asdf:clear-system "crisp")
(asdf:clear-system "cffi")

;; ql:quickload will find crisp.asd, see the dependencies,
;; download cffi, and then load crisp.
(ql:quickload "crisp")
(format t "~&; --- System loaded successfully.~%")

(uiop::ensure-directories-exist "bin/")
(asdf:make "crisp")
(uiop:quit 0)