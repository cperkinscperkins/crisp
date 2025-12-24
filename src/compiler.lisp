;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.

;; src/compiler.lisp
(in-package :crisp.compiler)

;; Initialization
;; ==============

(defun initialize-compiler (&key (log-level :info) (runtime-checks nil))
  "A master initialization function for the Crisp compiler.
  This should be called by any entry point into the system (REPL, executable, CI)."

  (setf *runtime-checks-enabled* runtime-checks)
  ;; Load the LLVM shared library.
  (cffi:use-foreign-library crisp.llvm-bindings::libllvm)

  ;; Configure the logging system.
  (log:config :sane2 log-level)

  ;; Initialize the compiler's internal state.
  (initialize-crisp-types)
  (initialize-expression-analyzers) ;; In analysis.lisp, but usually registered.
  ;; Note: analysis.lisp initializes *expression-analyzers* entries via def-expression-analyzer.
  ;; Wait, where is initialize-expression-analyzers defined?
  ;; It is usually in analysis.lisp.
  (clrhash *implicit-arg-map*)
  (initialize-advisements)

  ;; Register intrinsic `die`
  (setf (gethash 'die *function-table*)
    (list (make-function-signature :name 'die :parameters nil :return-types '(nil))))

  ;; Bind shadowed symbols to their CL equivalents so they work in macros
  (setf (symbol-function 'truncate) #'cl:truncate)
  (setf (symbol-function 'floor) #'cl:floor)
  (setf (symbol-function 'ceil) #'cl:ceiling)
  (setf (symbol-function 'round) #'cl:round)

  ;; Auto-initialize templates if available (runtime check)
  (if (fboundp 'initialize-templates)
      (funcall 'initialize-templates)
      (log:warn "Template system not loaded/initialized."))

  ;; Initialize built-in structs (storage)
  (register-builtins))

(defun register-builtins ()
  "Registers built-in types and structs like 'storage' using def-struct semantics."
  (log:info "Registering built-in structs...")
  ;; EVAL the form so it is processed by the macros in the current runtime environment
  (eval '(def-struct storage
                     (address c-pointer)
                     (byte-size ulong)
                     (address-space address-space :c-t)
                     (access access :c-t)))

  ;; Register CELL struct template
  ;; CELL is an opaque handle to a storage slice.
  ;; It contains a pointer to the storage struct and an offset.
  (eval '(with-template-type (To Addr Acc)
                             (def-struct cell
                                         (parent storage) ;; Pointer to STORAGE struct
                                         (offset ulong))))

  ;; Register default ~ accessor as a template
  (register-template '~ '(To Addr Acc) nil
                     '(def-function ~ (c)
                                    (declare (function ((cell To Addr Acc) => To)))
                                    (declare (crisp-system-generated))
                                    (return (~ref~ c)))
                     '((cell To Addr Acc) => To))
  (register-template '~_SET! '(To Addr Acc) nil
                     '(def-function ~_SET! (c v)
                                    (declare (function ((cell To Addr Acc) To) => nil))
                                    (declare (crisp-system-generated))
                                    (set! (~ref~ c) v)
                                    (return))
                     '((cell To Addr Acc) To => nil)))


;; Helpers (Analysis Placeholder)
;; ==============================

(defun analyze-function-literal (expr env location)
  "Analyzes a (function name) form, e.g., #'foo."
  (declare (ignore env))
  (cl:let ((fn-name (second expr)))
    ;; Check if the function exists (simplistic check for now)
    (cl:unless (or (fboundp fn-name) (gethash fn-name *function-table*))
      (log:warn "Function literal ~a refers to unknown function (at compile time)." fn-name))

    (make-semantic-literal
     :value-type `(:function-literal ,fn-name)
     :value fn-name
     :source-location location)))
