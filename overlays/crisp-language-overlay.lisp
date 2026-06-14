(in-package :crisp.compiler)

;; ----------------------------------------------------------------------
;; TODO(ASYNC): Move these macros to src/macros.lisp when retiring this overlay.
;; ----------------------------------------------------------------------

(defmacro crisp-language:make-async-barrier ()
  "Creates an async barrier locally. For compilation analysis, returns a stub value."
  0)

(defmacro crisp-language:await (barrier)
  "Awaits an async barrier."
  (declare (ignore barrier))
  nil)

(defun %check-barrier-transformf (key-args)
  (let ((has-barrier (getf key-args :barrier))
        (has-transformf (or (getf key-args :transformf) (getf key-args :transformF))))
    (when (and has-barrier has-transformf)
      (error "Cannot use :barrier and :transformF at the same time."))))

(defmacro crisp-language:load-tile-at (src tile grid-list &rest key-args)
  "Macro wrapper to forward coordinates to the primitive, without stripping :barrier."
  (%check-barrier-transformf key-args)
  `(crisp-language::load-tile-coords ,src ,tile ,grid-list ,@key-args))

(defmacro crisp-language:store-tile-at (tile dest grid-list &rest key-args)
  "Macro wrapper to forward coordinates to the primitive, without stripping :barrier."
  (%check-barrier-transformf key-args)
  `(crisp-language::store-tile-coords ,tile ,dest ,grid-list ,@key-args))

(defmacro crisp-language:load-tile (src tile grid-list &rest key-args)
  "Helper macro to automatically compute grid index offsets dynamically
   by scaling the incoming grid-coords by the extents of the tile."
  (let ((pixel-coords
         (loop for g in grid-list
               for i from 0
               collect `(crisp-language:* ,g (crisp-language:~ (crisp-language:extents~ ,tile) ,i)))))
    `(crisp-language:load-tile-at ,src ,tile ,pixel-coords ,@key-args)))

(defmacro crisp-language:store-tile (tile dest grid-list &rest key-args)
  "Helper macro to automatically compute grid index offsets dynamically
   by scaling the incoming grid-coords by the extents of the tile."
  (let ((pixel-coords
         (loop for g in grid-list
               for i from 0
               collect `(crisp-language:* ,g (crisp-language:~ (crisp-language:extents~ ,tile) ,i)))))
    `(crisp-language:store-tile-at ,tile ,dest ,pixel-coords ,@key-args)))
