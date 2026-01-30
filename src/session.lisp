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

(defvar *compiler-session* nil
        "The active compiler session state. Bound dynamically during compilation passes.")
