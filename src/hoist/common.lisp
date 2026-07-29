(in-package :crisp.hoist)

(defun parse-metacrisp-file (filepath)
  "Parse a .metacrisp file and return the data structure.

   Endeavor 130 Phase 5: the active hardware profile (only the selected one) travels in as
   (:hardware-profile (:name \"X\" ...)) and is returned whole under :hardware-profile.

   NOTE: this file is shared by BOTH hoist backends, so it must not reference anything in a
   backend package.  Backend-specific caching of profile values belongs in that backend — see
   %l0-latch-hardware-profile in src/hoist-l0/main.lisp."
  (with-open-file (stream filepath :direction :input)
    (let ((aliases '())
          (structs '())
          (records '())
          (kernels '())
          (hardware-profile nil))
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
                  (setf kernels (or (rest form) '())))
                ((and (consp form) (eq (first form) :hardware-profile))
                  (setf hardware-profile (second form)))))
      (list :aliases aliases :structs structs :records records :kernels kernels
            :hardware-profile hardware-profile))))

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

(defun metacrisp-hardware-profile (metacrisp-data)
  "Extract the active hardware profile plist (or NIL) from metacrisp data.
The plist keeps its :name plus every registered key, e.g.
  (:name \"GPU-A\" :COMPUTE-UNITS 132 ...)."
  (getf metacrisp-data :hardware-profile))
