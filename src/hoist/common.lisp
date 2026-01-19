(in-package :crisp.hoist)

(defun parse-metacrisp-file (filepath)
  "Parse a .metacrisp file and return the data structure."
  (with-open-file (stream filepath :direction :input)
    (read stream)))

(defun metacrisp-kernels (metacrisp-data)
  "Extract kernels list from metacrisp data."
  (rest (assoc :kernels metacrisp-data)))

(defun metacrisp-aliases (metacrisp-data)
  "Extract type aliases from metacrisp data."
  (rest (assoc :aliases metacrisp-data)))

(defun metacrisp-structs (metacrisp-data)
  "Extract struct definitions from metacrisp data."
  (rest (assoc :structs metacrisp-data)))
