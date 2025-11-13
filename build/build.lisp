;; build/build.lisp

;;
;;  to use this, launch sbcl from the crisp repo root directory
;;  (load #P"./build/build.lisp")


(in-package :cl-user)

;; load the crisp system using Quicklisp
(format t "~&; --- Loading Crisp system via Quicklisp...~%")
;; Tell Quicklisp to find local projects in the current directory
(push *default-pathname-defaults* ql:*local-project-directories*)

(asdf:clear-system "crisp")
(asdf:clear-system "eclector")
(asdf:clear-system "eclector-concrete-syntax-tree")
(asdf:clear-system "concrete-syntax-tree")
(asdf:clear-system "cffi")

;; ql:quickload will find crisp.asd, see the dependencies,
;; download cffi and eclector, and then load crisp.
(ql:quickload "crisp")
(format t "~&; --- System loaded successfully.~%")

(uiop::ensure-directories-exist "bin/")
(asdf:make "crisp")
;(exit)