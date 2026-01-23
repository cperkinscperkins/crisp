(in-package :crisp.hoist)

(defun parse-metacrisp-file (filepath)
  "Parse a .metacrisp file and return the data structure."
  (with-open-file (stream filepath :direction :input)
    (let ((aliases '()) ; Use empty list instead of nil
                       (structs '()) ; Use empty list instead of nil
                       (kernels '())) ; Use empty list instead of nil
      ;; Read all forms from the file
      (loop for form = (read stream nil :eof)
            until (eq form :eof)
            do (cond
                ((and (consp form) (eq (first form) :aliases))
                  (setf aliases (or (rest form) '()))) ; Ensure empty list if nil
                ((and (consp form) (eq (first form) :structs))
                  (setf structs (or (rest form) '()))) ; Ensure empty list if nil
                ((and (consp form) (eq (first form) :kernels))
                  (setf kernels (or (rest form) '()))))) ; Ensure empty list if nil
      ;; Return as plist for easy access
      (list :aliases aliases :structs structs :kernels kernels))))

(defun metacrisp-kernels (metacrisp-data)
  "Extract kernels list from metacrisp data."
  (getf metacrisp-data :kernels))

(defun metacrisp-aliases (metacrisp-data)
  "Extract type aliases from metacrisp data."
  (getf metacrisp-data :aliases))

(defun metacrisp-structs (metacrisp-data)
  "Extract struct definitions from metacrisp data."
  (getf metacrisp-data :structs))
