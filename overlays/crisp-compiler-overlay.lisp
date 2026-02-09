;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;;; =========================================================
;;; --differentiate flag support (branded types prerequisite)
;;; =========================================================

;; src/types/registry.lisp
(defvar *differentiate-p* nil
  "If T, enable differentiation mode. Activates branded type enforcement
   for brands declared with :enforce :diff (the default).")

;; src/compiler.lisp
(defun initialize-compiler (&key (log-level :info) (runtime-checks nil) (differentiate nil))
  "A master initialization function for the Crisp compiler.
This should be called by any entry point into the system (REPL, executable, CI)."

  (setf *runtime-checks-enabled* runtime-checks)
  (setf *differentiate-p* differentiate)
  ;; Load the LLVM shared library.
  (cffi:use-foreign-library crisp.llvm-bindings::libllvm)

  ;; Configure the logging system to use stderr (important for stdout IR capture)
  (if (eq log-level :off)
      (log:config :off)
      (log:config :sane :stream *error-output* log-level))

  ;; Initialize the compiler's internal state.
  (initialize-crisp-types)
  (initialize-crisp-types)
  (initialize-type-hierarchy) ;; Initialize type derivation graph (DAG)
  (clrhash *function-table*) ;; Reset function table
  (clrhash *crisp-structs*) ;; Reset struct definitions
  (clrhash *crisp-type-aliases*) ;; Reset type aliases
  (clrhash *crisp-template-aliases*) ;; Reset template aliases
  (clrhash *generic-functions*) ;; Reset generic functions
  (clrhash *kernel-declared-signatures*) ;; Reset kernel signatures
  (when (boundp '*record-definitions*) (clrhash *record-definitions*)) ;; Reset records (if defined)

  (setf *compiled-kernels* nil) ;; Reset compiled kernels list

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

