;;;; src/session.lisp
;;;;
;;;; Defines the Compiler Session state which groups formerly global environment variables.

(in-package :crisp.compiler)

(defstruct compiler-session
  "Holds the state for a single compilation session or pass."
  (module nil :type (or null cffi:foreign-pointer))
  (builder nil :type (or null cffi:foreign-pointer))
  (di-builder nil :type (or null cffi:foreign-pointer))
  (di-compile-unit nil :type (or null cffi:foreign-pointer))
  (location-map nil :type (or null hash-table)))

(defstruct compiler-context
  "Holds the mutable state for the current analysis pass, replacing global variables."
  (single-pass-call-stack nil :type list)
  (current-compiling-function nil :type symbol)
  (declarations nil :type list)
  (scanning-function-name nil :type symbol)
  (current-binding-name nil :type symbol)
  (allow-nested-def-function nil :type boolean))

(defvar *compiler-session* nil
        "The active compiler session state. Bound dynamically during compilation passes.")

(defvar *compiler-context* nil
        "The active analysis context context. Bound dynamically during compilation passes.")

(declaim (special *brand-instance-types*
                  *crisp-enums*
                  *crisp-structs*
                  *crisp-template-aliases*
                  *crisp-type-aliases*
                  *crisp-types*
                  *differentiate-p*
                  *kernel-declared-signatures*
                  *parameterized-brand-names*
                  *partial-template-instantiations*
                  *pending-struct-definitions*
                  *record-param-field-adjs*
                  *runtime-checks-enabled*
                  *scanning-function-name*
                  *scratch-cell-counter*
                  *struct-kernel-param-shadows*
                  *struct-mutating-functions*
                  *target-backend*
                  *type-derivation-graph*))

