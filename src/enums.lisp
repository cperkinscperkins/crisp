;;;; src/enums.lisp
;;;;
;;;; Implementation of DEF-ENUMERATION and standard enumerations.

(in-package :crisp.compiler)

(defmacro def-enumeration (name &rest specs)
  "Defines a new enumeration type.
   Usage: (def-enumeration address-space (:global 1) :local :private)"
  (let ((next-val 0)
        (members '()))
    (dolist (spec specs)
      (let ((key nil)
            (val nil))
        (if (consp spec)
            (progn
             (setf key (first spec))
             (setf val (second spec))
             (setf next-val (1+ val)))
            (progn
             (setf key spec)
             (setf val next-val)
             (incf next-val)))
        (push (cons key val) members)))
    (setf members (nreverse members))

    (let ((pred-name (intern (format nil "IS-~a?" name))))
      `(progn
        (eval-when (:compile-toplevel :load-toplevel :execute)
          (setf (gethash ',name *crisp-enums*)
            (make-enumeration-def :name ',name :members ',members))
          ;; Also register in *crisp-types* so it passes valid-type-p check? 
          ;; (setf (gethash ',name *crisp-types*) :enumeration) 
          ;; Actually *crisp-types* usually stores a struct, but :enumeration kw might suffice for simple checks.
          ;; For now, let's just use *crisp-enums* for lookups.
           )

        ;; Define the predicate function
        (defun ,pred-name (x)
          (or (assoc x ',members)
              (and (integerp x)
                   (find x ',members :key (lambda (entry) (cdr entry))))))

        ;; Helper to get integer value
        (defun ,(intern (concatenate 'string (symbol-name name) "-VALUE") :crisp.compiler) (k)
          (cdr (assoc k ',members)))

        (export ',pred-name)))))

;;; Standard Enumerations

(def-enumeration address-space
                 (:unknown 0)
                 (:global 1)
                 :local
                 :private
                 :constant)

(def-enumeration access
                 (:unknown 255)
                 :read-only
                 :write-only
                 :read-write
                 :readable
                 :writeable)
