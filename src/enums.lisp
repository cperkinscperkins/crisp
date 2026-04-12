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
            (make-enumeration-def :name ',name :members ',members)))

        ;; Define the predicate function
        (defun ,pred-name (x)
          (or (assoc x ',members)
              (and (integerp x)
                   (find x ',members :key (lambda (entry) (cdr entry))))))

        (deftype ,name () '(satisfies ,pred-name))

        ;; Helper to get integer value
        (defun ,(intern (concatenate 'string (symbol-name name) "-VALUE") :crisp.compiler) (k)
          (cdr (assoc k ',members)))

        (export ',pred-name)))))

;;; Standard Enumerations

;;; Standard Enumerations
;;; Note: We manually define address-space to support target-sensitive value resolution
;;; while keeping the enumeration registry populated for validation.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (setf (gethash 'address-space *crisp-enums*)
    (make-enumeration-def :name 'address-space
                          :members '((:private . 0)
                                     (:global . 1)
                                     (:constant . 2)
                                     (:local . 3)
                                     (:generic . 4)))))
(deftype address-space () '(satisfies is-address-space?))

(defun is-address-space? (x)
  (or (assoc x '((:private . 0) (:global . 1) (:constant . 2) (:local . 3) (:generic . 4)))
      (and (integerp x)
           (find x '(0 1 2 3 4)))))

(defun address-space-value (k)
  "Returns the integer value for an address space keyword, sensitive to *target-backend*."
  (encode-address-space k))

(export 'is-address-space?)

(def-enumeration access
                 (:unknown 255)
                 :read-only
                 :write-only
                 :read-write
                 :readable
                 :writeable)

(def-enumeration align :compact :strided)
