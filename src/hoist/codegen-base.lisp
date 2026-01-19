(in-package :crisp.hoist)

(defun crisp-type-to-cpp-type (crisp-type)
  "Convert a Crisp type to C++ type string."
  (cond
   ((symbolp crisp-type)
     (case crisp-type
       (int "int")
       (uint "unsigned int")
       (long "long")
       (ulong "unsigned long")
       (float "float")
       (double "double")
       (voidp "void*")
       (t (string-downcase (symbol-name crisp-type)))))
   ((consp crisp-type)
     ;; Handle complex types like (cell int ...)
     (format nil "/* TODO: ~a */" crisp-type))
   (t (format nil "/* UNKNOWN: ~a */" crisp-type))))

(defun format-cpp-identifier (lisp-symbol)
  "Convert Lisp symbol to C++-safe identifier."
  (let ((name (if (symbolp lisp-symbol)
                  (symbol-name lisp-symbol)
                  (string lisp-symbol))))
    (substitute #\_ #\- (string-downcase name))))
