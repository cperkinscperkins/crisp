(in-package :crisp.hoist)

(defun parse-metacrisp-file (filepath)
  "Parse a .metacrisp file and return the data structure."
  (with-open-file (stream filepath :direction :input)
    (let ((aliases '())
          (structs '())
          (records '())
          (kernels '()))
      ;; Read all forms from the file
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
                  (setf kernels (or (rest form) '())))))
      ;; Return as plist for easy access
      (list :aliases aliases :structs structs :records records :kernels kernels))))

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
