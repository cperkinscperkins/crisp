;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.


;; src/reader.lisp
(in-package :crisp.compiler)


;; Both the defun and the registration must be inside eval-when so the
;; function exists at compile time when ASDF compiles this overlay to fasl.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun %read-device-vec-literal (stream char n)
    "Reader macro for ##(...). Transforms ##(e1 e2 ...) into
     (crisp-vec-literal e1 e2 ...) for the Crisp analyzer."
    (declare (ignore char n))
    (let ((elements (read stream t nil t)))
      (unless (listp elements)
        (error "##(...) device vector literal requires a list of elements, e.g. ##(1 2 3)"))
      (cons 'crisp-vec-literal elements)))
  (set-dispatch-macro-character #\# #\# #'%read-device-vec-literal))

;;;; Endeavour 193: real source lines for die / log sites -- while crisp.main reads a .crisp file,
;;;; the `(` reader records each list it reads (cons -> (file . line)) in *193-form-sites*.

(defvar *193-read-file* nil
  "Endeavour 193.  While crisp.main reads a .crisp file: (FILE-NAMESTRING . NEWLINE-OCTET-OFFSETS).
   NIL otherwise, and the `(` reader then does nothing extra.")

(defun %193-newline-offsets (path)
  "Endeavour 193.  A vector of the octet offsets of every LF in the file at PATH."
  (with-open-file (s path :element-type '(unsigned-byte 8))
    (let ((buf (make-array (file-length s) :element-type '(unsigned-byte 8)))
          (out (make-array 64 :adjustable t :fill-pointer 0)))
      (read-sequence buf s)
      (loop for i from 0 below (length buf)
            when (= (aref buf i) 10) do (vector-push-extend i out))
      out)))

(defun %193-line-of (offset newlines)
  "Endeavour 193.  1-based line of octet OFFSET, given the LF offsets NEWLINES (sorted)."
  (1+ (or (position-if (lambda (nl) (>= nl offset)) newlines) (length newlines))))

(defvar *193-orig-paren-reader* (get-macro-character #\())

(defun %193-paren-reader (stream char)
  "Endeavour 193.  The `(` reader macro, recording where each list came from while a .crisp file is
   read (*193-read-file*).  FILE-POSITION is just past the `(`."
  (if *193-read-file*
      (let* ((pos (ignore-errors (file-position stream)))
             (form (funcall *193-orig-paren-reader* stream char)))
        (when (and pos (consp form))
          (setf (gethash form *193-form-sites*)
                (cons (car *193-read-file*) (%193-line-of (1- pos) (cdr *193-read-file*)))))
        form)
      (funcall *193-orig-paren-reader* stream char)))

(set-macro-character #\( #'%193-paren-reader)

(defmacro %193-with-read-file ((path) &body body)
  "Endeavour 193.  Runs BODY with *193-read-file* bound for the .crisp file at PATH."
  `(let ((*193-read-file* (cons (file-namestring ,path) (%193-newline-offsets ,path))))
     ,@body))
