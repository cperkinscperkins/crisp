;;;; src/parameters.lisp
(in-package :crisp.compiler)

;;; =========================================================
;;; Parameter Encapsulation
;;; =========================================================

(defstruct parameter-def
  "Represents a function parameter with its type, kind, and metadata.
   Replaces the legacy list format: (name type :kind kind ...)"
  (name nil :type symbol)
  (type 't :type (or symbol list))
  (kind :in :type keyword) ;; :in, :out, :in-out
  (is-optional nil :type boolean)
  (is-key nil :type boolean)
  (default-value nil)
  (uniformity :unknown :type keyword)
  (source-location nil))

(defmethod print-object ((obj parameter-def) stream)
  (print-unreadable-object (obj stream :type t :identity nil)
    (format stream "~a ~a~@[ :kind ~a~]"
            (parameter-def-name obj)
            (parameter-def-type obj)
            (unless (eq (parameter-def-kind obj) :in)
              (parameter-def-kind obj)))))
