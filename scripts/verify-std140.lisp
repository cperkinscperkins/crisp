(load "~/quicklisp/setup.lisp")
(push *default-pathname-defaults* ql:*local-project-directories*)
(ql:quickload :crisp :silent t)
(in-package :crisp.compiler)
(initialize-compiler)

(format t "~%--- Debugging std140 Layout ---~%")

(defun test-pad (name members exp-size)
  (format t "Testing ~a... " name)
  (finish-output)
  (handler-case
      (multiple-value-bind (padded size) (compute-std140-layout members)
        (if (= size exp-size)
            (format t "OK. Size=~a. Members: ~a~%" size (length padded))
            (format t "FAIL. Size=~a (expected ~a).~%" size exp-size))
        (format t "  Layout: ~a~%" (mapcar #'first padded))
        (format t "  Types:  ~a~%" (mapcar #'second padded)))
    (error (c)
      (format t "CRASH: ~a~%" c)))
  (finish-output))

;; Test 1: Mixed (3 bytes pad)
(test-pad "Mixed (char, int)" '((a char) (b int)) 16)

;; Test 2: Stress (7 bytes pad)
(test-pad "Stress (char, double)" '((a char) (b double)) 16)

;; Test 3: Stress Inner (15 bytes pad)
;; Need to register Inner first
(eval '(def-struct Inner (x float)))
(test-pad "Stress (char, Inner)" '((a char) (b Inner)) 32)
