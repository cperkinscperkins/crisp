;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.

;; src/compiler.lisp
(in-package :crisp.compiler)

;; Initialization
;; ==============

(defun run-tool-command (args &key (log-prefix ""))
  "Runs a command using uiop:run-program."
  (log:info "~aRunning: ~{~a~^ ~}" log-prefix args)
  (let ((output (make-string-output-stream))
        (error-output (make-string-output-stream)))
    (handler-case
        (uiop:run-program args :output output :error-output error-output :force-shell t)
      (error (e)
        (let ((out-str (get-output-stream-string output))
              (err-str (get-output-stream-string error-output)))
          (log:error "Command failed: ~a" e)
          (unless (uiop:emptyp out-str) (log:error "Stdout: ~a" out-str))
          (unless (uiop:emptyp err-str) (log:error "Stderr: ~a" err-str))
          (error "Tool invocation failed: ~{~a~^ ~} (Reason: ~a)" args e))))
    (get-output-stream-string output)))

(defun resolve-tool-executable (tool-base)
  "Resolves the path to a tool executable. 
   Prefers bundled version in bin/, falls back to system PATH.
   Robustness: 
   - Checks versioned suffixes (e.g. llc-21) if base name not in path.
   - Falls back to bundled tool if system tool is missing even if CRISP_USE_SYSTEM_TOOLS is set."
  (let* ((env-key (format nil "CRISP_~a" (string-upcase (substitute #\_ #\- tool-base))))
         (env-override (uiop:getenv env-key))
         (use-system (uiop:getenv "CRISP_USE_SYSTEM_TOOLS"))
         (ext (if (uiop:os-windows-p) ".exe" ""))
         (bundled-name (format nil "bin/~a~a" tool-base ext))
         (bundled-path (merge-pathnames bundled-name *default-pathname-defaults*)))
    (cond
     (env-override env-override)
     ((and use-system (string-not-equal use-system "false"))
       (let ((versioned (unless (uiop:os-windows-p)
                          (loop for ver in '("-21" "-20" "-19" "-18" "-17" "-16" "-15" "-14" "")
                                for v-name = (format nil "~a~a" tool-base ver)
                                  ;; Manual PATH check or similar? Let's use which but ONLY on Unix.
                                  when (zerop (nth-value 2 (uiop:run-program (list "which" v-name) :ignore-error-status t)))
                                  return v-name))))
         (or versioned
             (if (probe-file bundled-path)
                 (namestring bundled-path)
                 tool-base))))
     (t
       (if (probe-file bundled-path)
           (namestring bundled-path)
           tool-base)))))

(defun find-spir-kernels (ir-text)
  "Find all SPIR kernel functions in LLVM IR text.
   Returns list of (function-name start-pos end-pos-of-signature)."
  (let ((kernels '())
        (pos 0))
    (loop
     (let ((kernel-pos (search "spir_kernel" ir-text :start2 pos)))
       (unless kernel-pos
         (cl:return kernels))

       (let* ((define-pos (search "define" ir-text :start2 (max 0 (- kernel-pos 100)) :end2 kernel-pos :from-end t))
              (at-pos (position #\@ ir-text :start (or define-pos kernel-pos)))
              (paren-pos (position #\( ir-text :start at-pos))
              (func-name (subseq ir-text (1+ at-pos) paren-pos))
              (brace-pos (position #\{ ir-text :start paren-pos)))

         (when (and func-name brace-pos)
               (push (list func-name define-pos brace-pos) kernels))

         (setf pos (1+ kernel-pos)))))))
(defun extract-kernel-params (ir-text func-start func-end)
  "Extract parameter types from a kernel function signature.
 Returns list of type strings (e.g., 'ptr addrspace(1)', 'i64')."
  (let* ((sig-text (subseq ir-text func-start func-end))
         (paren-start (position #\( sig-text))
         (paren-end (position #\) sig-text :from-end t)))

    (unless (and paren-start paren-end (< paren-start paren-end))
      (log:warn "Could not find parameter parens!")
      (return-from extract-kernel-params nil))

    (let* ((params-text (subseq sig-text (1+ paren-start) paren-end))
           (params '()))

      (log:info "extract-kernel-params: params-text = ~s" params-text)

      (dolist (param-str (uiop:split-string params-text :separator ","))
        (let ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return) param-str)))
          (when (> (length trimmed) 0)
                (let ((percent-pos (position #\% trimmed)))
                  (if percent-pos
                      (let ((type-text (string-trim '(#\Space #\Tab) (subseq trimmed 0 percent-pos))))
                        (when (> (length type-text) 0)
                              (log:info "  extracted type: ~s" type-text)
                              (push type-text params)))
                      (progn
                       (log:info "  extracted type (no name): ~s" trimmed)
                       (push trimmed params)))))))

      (nreverse params))))

(defun ir-type-to-opencl-metadata (ir-type)
  "Convert LLVM IR type to OpenCL metadata (addr-space, access-qual, type-name).
 Returns (values addr-space-int access-qual-string type-name-string)."
  (let ((addr-space 0) ; default: private
                      (access-qual "none")
                      (type-name "void*")) ; default

    (cond
     ;; Pointer types: ptr addrspace(N)
     ((search "ptr" ir-type)
       (cond
        ((search "addrspace(1)" ir-type)
          (setf addr-space 1 type-name "int*")) ; global
        ((search "addrspace(2)" ir-type)
          (setf addr-space 2 type-name "int*")) ; constant
        ((search "addrspace(3)" ir-type)
          (setf addr-space 3 type-name "int*")) ; local
        (t
          (setf addr-space 0 type-name "int*")))) ; private/generic

     ;; Integer types
     ((search "i64" ir-type)
       (setf addr-space 0 type-name "ulong"))
     ((search "i32" ir-type)
       (setf addr-space 0 type-name "uint"))
     ((search "i8" ir-type)
       (setf addr-space 0 type-name "uchar"))

     ;; Floating point
     ((search "float" ir-type)
       (setf addr-space 0 type-name "float"))
     ((search "double" ir-type)
       (setf addr-space 0 type-name "double")))

    (values addr-space access-qual type-name)))

(defun generate-kernel-metadata (params metadata-id-base)
  "Generate LLVM metadata definitions for kernel parameters.
 Returns (values metadata-refs-string metadata-defs-string next-id)."
  (let ((addr-spaces '())
        (access-quals '())
        (type-names '())
        (base-types '())
        (type-quals '()))

    ;; Extract metadata for each parameter
    (dolist (param params)
      (multiple-value-bind (addr-space access-qual type-name)
          (ir-type-to-opencl-metadata param)
        (push addr-space addr-spaces)
        (push access-qual access-quals)
        (push type-name type-names)
        (push type-name base-types) ; base-type same as type-name
        (push "" type-quals))) ; empty type qualifiers

    ;; Reverse to maintain parameter order
    (setf addr-spaces (nreverse addr-spaces))
    (setf access-quals (nreverse access-quals))
    (setf type-names (nreverse type-names))
    (setf base-types (nreverse base-types))
    (setf type-quals (nreverse type-quals))

    ;; Generate metadata IDs
    (let* ((id-addr (+ metadata-id-base 0))
           (id-access (+ metadata-id-base 1))
           (id-type (+ metadata-id-base 2))
           (id-base (+ metadata-id-base 3))
           (id-qual (+ metadata-id-base 4))
           (next-id (+ metadata-id-base 5)))

      ;; Build metadata reference string
      (let ((metadata-refs
             (format nil " !kernel_arg_addr_space !~a !kernel_arg_access_qual !~a !kernel_arg_type !~a !kernel_arg_base_type !~a !kernel_arg_type_qual !~a"
               id-addr id-access id-type id-base id-qual)))

        ;; Build metadata definitions string
        (let ((metadata-defs
               (format nil "!~a = !{~{i32 ~a~^, ~}}~%!~a = !{~{!\"~a\"~^, ~}}~%!~a = !{~{!\"~a\"~^, ~}}~%!~a = !{~{!\"~a\"~^, ~}}~%!~a = !{~{!\"~a\"~^, ~}}~%"
                 id-addr addr-spaces
                 id-access access-quals
                 id-type type-names
                 id-base base-types
                 id-qual type-quals)))

          (values metadata-refs metadata-defs next-id))))))

(defun inject-spir-kernel-metadata (ir-text)
  "Inject OpenCL kernel metadata for all SPIR kernels found in IR text.
 Returns modified IR text with metadata."
  (let ((kernels (find-spir-kernels ir-text)))
    (if (null kernels)
        ir-text
        (let ((result ir-text)
              (metadata-id-base 100)
              (all-metadata-defs ""))

          (dolist (kernel-info kernels)
            (destructuring-bind (func-name func-start brace-pos) kernel-info
              (log:info "Injecting metadata for kernel: ~a" func-name)

              (let ((params (extract-kernel-params result func-start brace-pos)))
                (log:info "  Parameters: ~a" params)

                (multiple-value-bind (metadata-refs metadata-defs next-id)
                    (generate-kernel-metadata params metadata-id-base)

                  (let* ((kernel-sig-start (search func-name result))
                         (new-brace-pos (position #\{ result :start kernel-sig-start))
                         (close-paren-pos (position #\) result :end new-brace-pos :from-end t)))

                    (setf result (concatenate 'string
                                   (subseq result 0 (1+ close-paren-pos))
                                   metadata-refs
                                   " "
                                   (string #\{)
                                   (subseq result (1+ new-brace-pos))))

                    (setf all-metadata-defs (concatenate 'string all-metadata-defs metadata-defs))
                    (setf metadata-id-base next-id))))))

          (concatenate 'string result (format nil "~%~%") all-metadata-defs)))))

(defun compile-to-spirv (module output-path &key debug-p)
  "Compiles an LLVM Module to SPIR-V using the external toolchain."
  (let* ((base-path (uiop:pathname-directory-pathname output-path))
         (name (pathname-name output-path))
         (ll-file (merge-pathnames (format nil "~a.temp.ll" name) base-path))
         (bc-file (merge-pathnames (format nil "~a.temp.bc" name) base-path))
         (spv-file output-path))

    ;; Set target triple for SPIR-V before writing IR
    (llvm-set-target module "spir64-unknown-unknown")

    ;; 1. Write Temporary .ll file
    (let* ((ir (cffi:foreign-string-to-lisp (llvm-print-module-to-string module)))
           (ir-with-metadata (inject-spir-kernel-metadata ir)))
      (with-open-file (stream ll-file :direction :output :if-exists :supersede)
        (write-string ir-with-metadata stream)))

    ;; 2. llvm-as (LL -> BC)
    (let ((tool (resolve-tool-executable "llvm-as")))
      (run-tool-command
       (list tool (namestring ll-file) "-o" (namestring bc-file))
       :log-prefix "[SPIR-V] "))

    ;; 3. llvm-spirv (BC -> SPV)
    (let ((tool (resolve-tool-executable "llvm-spirv"))
          (flags (if debug-p '("--spirv-debug-info-version=ocl-100") nil)))
      (run-tool-command
       (append (list tool) flags (list (namestring bc-file) "-o" (namestring spv-file)))
       :log-prefix "[SPIR-V] "))

    ;; Cleanup temps (only if NOT debugging, ideally, but let's keep it simple for now)
    ;; Actually, if debug-p is true, maybe we should KEEP them?
    ;; For verify step, keeping them is handy.
    (unless debug-p
      (when (probe-file ll-file) (delete-file ll-file))
      (when (probe-file bc-file) (delete-file bc-file)))

    (log:info "Generated SPIR-V: ~a" spv-file)))

(defun compile-to-ptx (module output-path &key (compute-capability "sm_50") debug-p)
  "Compiles an LLVM Module to PTX using llc.
 COMPUTE-CAPABILITY: Target GPU architecture (sm_50, sm_75, sm_86, etc.)
                     sm_50 = Maxwell (good default for compatibility)"
  (let* ((base-path (uiop:pathname-directory-pathname output-path))
         (name (pathname-name output-path))
         (ll-file (merge-pathnames (format nil "~a.temp.ll" name) base-path))
         (ptx-file output-path))

    ;; Set target triple for NVPTX before writing IR
    (llvm-set-target module "nvptx64-nvidia-cuda")

    ;; 1. Write LLVM IR to .ll file
    (let ((ir (cffi:foreign-string-to-lisp (llvm-print-module-to-string module))))
      (with-open-file (stream ll-file :direction :output :if-exists :supersede)
        (write-string ir stream)))

    ;; 2. llc: IR -> PTX
    (let ((tool (resolve-tool-executable "llc")))
      (run-tool-command
       (list tool
             "-march=nvptx64"
             (format nil "-mcpu=~a" compute-capability)
             (namestring ll-file)
             "-o" (namestring ptx-file))
       :log-prefix "[PTX] "))

    ;; Cleanup temp files
    (when (probe-file ll-file) (delete-file ll-file))

    (log:info "Generated PTX: ~a" ptx-file)))


#|
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

  ;; Reset brand definitions
  (when (boundp '*brand-definitions*) (clrhash *brand-definitions*))

  ;; Initialize built-in structs (storage)
  (register-builtins))

(defun register-builtins ()
  "Registers built-in types and structs like 'storage' using def-struct semantics."
  ;; Register built-in structs like 'storage'
  (log:info "Registering built-in structs...")

  ;; Redefine STORAGE as a TEMPLATED RECORD (Register-based, passed by value)
  ;; This replaces the old global-only storage.
  ;; Now parameterized by AddressSpace (Addr).
  (eval '(with-template-type ((Addr address-space :global))
                             (def-record storage
                                         (address (c-pointer :address-space Addr))
                                         (byte-size ulong)
                                         (address-space address-space :c-t Addr)
                                         (access access :c-t :read-write))))

  ;; Register CELL record template
  ;; CELL is an opaque handle to a storage slice.
  ;; It contains a pointer to the storage struct and an offset.
  ;; It now tracks element-type, address-space, and access as compile-time properties.

  (eval '(with-template-type ((To T) (Addr address-space :global) (Acc access :read-write))
                             (def-record cell
                                         (parent (storage Addr)) ;; Pointer to STORAGE struct (matching address space)
                                         (offset ulong)
                                         (element-type type-spec :c-t To)
                                         (address-space address-space :c-t Addr)
                                         (access access :c-t Acc))))

  ;; Register bytes~ helper (sizeof T)
  (register-template 'bytes~ '(To (Addr address-space :global) (Acc access :read-write)) nil
                     '(def-function bytes~ (c)
                                    (declare (function ((cell To Addr Acc) => ulong)))
                                    (declare (crisp-system-generated))
                                    (return (sizeof To)))
                     '((cell To Addr Acc) => ulong)))

                     |#


(defun register-builtins ()
  "Registers built-in types and structs like 'storage' and 'cell' using def-struct
   semantics.  Cell carries the value-t brand for --differentiate mode."
  (log:info "Registering built-in structs...")

  ;; Clear brand-specific state that is NOT cleared by initialize-compiler.
  ;; initialize-compiler clears *brand-definitions* but not the extra tables
  ;; introduced in the overlay.  Without this, the in-process test runner leaks
  ;; state from one test into the next (e.g., *parameterized-brand-names* from
  ;; test 01-fake-cell persists into test 02-fake-cell-value-t-no-compose,
  ;; causing value-t to be treated as parameterized when it isn't in isolation).
  (when (boundp '*parameterized-brand-names*) (clrhash *parameterized-brand-names*))
  (when (boundp '*brand-instance-cache*) (clrhash *brand-instance-cache*))
  (when (boundp '*brand-instance-types*) (clrhash *brand-instance-types*))
  (when (boundp '*brand-cache-last-function*) (setf *brand-cache-last-function* nil))

  ;; STORAGE: parameterized by address space only.
  (eval '(with-template-type ((Addr address-space :global))
                             (def-record storage
                                         (address (c-pointer :address-space Addr))
                                         (byte-size ulong)
                                         (address-space address-space :c-t Addr)
                                         (access access :c-t :read-write))))

  ;; CELL: opaque handle to a storage slice.
  ;;   value-t To -- brands element reads so different cell vars produce distinct types
  ;;   when --differentiate is active.  Only :read-write cells activate brand tracking;
  ;;   :read-only/:write-only cells have the brand registered but analyze-aref-expression
  ;;   skips instance differentiation for them (see Fix C).
  ;;
  ;; NOTE: index-t intentionally REMOVED from real cell to avoid package-symbol conflict
  ;;   with fake-cell's index-t brand (CRISP.COMPILER::ULONG vs CRISP-LANGUAGE::ULONG).
  (eval '(with-template-type ((To T) (Addr address-space :global) (Acc access :read-write))
                             (def-record cell
                                         (brand value-t To :subst :descendant :enforce :diff)
                                         (parent (storage Addr))
                                         (offset ulong)
                                         (element-type type-spec :c-t To)
                                         (address-space address-space :c-t Addr)
                                         (access access :c-t Acc))))

  ;; bytes~ helper: compile-time sizeof for cell element type.
  (register-template 'bytes~ '(To (Addr address-space :global) (Acc access :read-write)) nil
                     '(def-function bytes~ (c)
                                    (declare (function ((cell To Addr Acc) => ulong)))
                                    (declare (crisp-system-generated))
                                    (return (sizeof To)))
                     '((cell To Addr Acc) => ulong))

  (log:info "Built-in structs registered."))

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

  ;; Reset brand definitions
  (when (boundp '*brand-definitions*) (clrhash *brand-definitions*))

  ;; Reset brand instance cache and brand instance type tracking.
  ;; CRITICAL: must be cleared whenever *type-derivation-graph* is reset.
  ;; Stale gensyms in the cache are no longer registered in the fresh graph,
  ;; causing is-substitutable-for? to return NIL and crashing unmangle.
  (when (boundp '*brand-instance-cache*) (clrhash *brand-instance-cache*))
  (when (boundp '*brand-instance-types*) (clrhash *brand-instance-types*))

  ;; Clear partial template instantiations and their CL dispatch macros.
  ;; When an incomplete struct template (one with unresolved :c-t fields) is
  ;; instantiated, %instantiate-structure-template stores partial info in
  ;; *partial-template-instantiations* AND installs a CL macro for MAKE-X%DISPATCH.
  ;; initialize-templates only clears *template-registry* and *instantiated-templates*;
  ;; it does NOT touch *partial-template-instantiations* or the CL macros.
  ;; Without this cleanup, stale dispatch macros survive initialize-compiler and
  ;; misdirect MAKE-X calls in subsequent tests.
  (when (boundp '*partial-template-instantiations*)
    (loop for template-name being the hash-keys of *partial-template-instantiations*
          do (let ((dispatch-sym (intern (format nil "MAKE-~a%DISPATCH" template-name)
                                         (symbol-package template-name))))
               (when (macro-function dispatch-sym)
                 (log:info "INITIALIZE-COMPILER: clearing stale CL dispatch macro ~a" dispatch-sym)
                 ;; Use fmakunbound to remove the macro definition cleanly.
                 ;; (setf (macro-function sym) nil) is not valid in SBCL.
                 (fmakunbound dispatch-sym))))
    (clrhash *partial-template-instantiations*))

  ;; Initialize built-in structs (storage)
  (register-builtins))
