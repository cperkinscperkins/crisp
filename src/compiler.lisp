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
Returns list of type strings (e.g., 'ptr addrspace(1)', 'i64', '%POINT')."
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
                      (if (zerop percent-pos)
                          ;; Struct type: starts with %, e.g. "%POINT %0".
                          ;; Use the LAST % as the name boundary.
                          (let* ((last-percent (position #\% trimmed :from-end t))
                                 (type-text (string-trim '(#\Space #\Tab)
                                                         (subseq trimmed 0 last-percent))))
                            (when (> (length type-text) 0)
                                  (log:info "  extracted struct type: ~s" type-text)
                                  (push type-text params)))
                          ;; Normal case: type precedes the first %.
                          (let ((type-text (string-trim '(#\Space #\Tab)
                                                        (subseq trimmed 0 percent-pos))))
                            (when (> (length type-text) 0)
                                  (log:info "  extracted type: ~s" type-text)
                                  (push type-text params))))
                      (progn
                       (log:info "  extracted type (no name): ~s" trimmed)
                       (push trimmed params)))))))

      (nreverse params))))

(defun ir-type-to-opencl-metadata (ir-type)
  "Convert LLVM IR type to OpenCL metadata (addr-space, access-qual, type-name).
Returns (values addr-space-int access-qual-string type-name-string)."
  (let ((addr-space 0)
        (access-qual "none")
        (type-name "void*"))

    (cond
     ;; Struct types: start with % (e.g. \"%POINT\")
     ;; Passed by value, addr-space 0, type-name is the struct name without %
     ((and (> (length ir-type) 0) (char= (cl:char ir-type 0) #\%))
       (setf addr-space 0
             type-name (subseq ir-type 1)))

     ;; Pointer types: ptr addrspace(N)
     ((search "ptr" ir-type)
       (cond
        ((search "addrspace(1)" ir-type)
          (setf addr-space 1 type-name "int*"))
        ((search "addrspace(2)" ir-type)
          (setf addr-space 2 type-name "int*"))
        ((search "addrspace(3)" ir-type)
          (setf addr-space 3 type-name "int*"))
        (t
          (setf addr-space 0 type-name "int*"))))

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
  "Compiles an LLVM Module to SPIR-V using the external toolchain.
   Runs %remove-dead-array-returning-functions before translation to
   prevent IGC from miscompiling dead TypeArray-returning functions
   (bug 028 workaround Part 2)."
  (let* ((base-path (uiop:pathname-directory-pathname output-path))
         (name (pathname-name output-path))
         (ll-file (merge-pathnames (format nil "~a.temp.ll" name) base-path))
         (bc-file (merge-pathnames (format nil "~a.temp.bc" name) base-path))
         (spv-file output-path))

    ;; Bug 028 Part 2: remove dead array-returning functions before SPIR-V
    ;; so IGC never sees a TypeArray return type, even in dead code.
    (%remove-dead-array-returning-functions module)

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

    (unless debug-p
      (when (probe-file ll-file) (delete-file ll-file))
      (when (probe-file bc-file) (delete-file bc-file)))

    (log:info "Generated SPIR-V: ~a" spv-file)))


;;;; ============================================================
;;;; Bug 028 Part 2 — diagnostic redef: verbose logging to confirm
;;;; %remove-dead-array-returning-functions is called and what it sees.
;;;; Remove once confirmed working.
;;;; ============================================================

;; src/compiler.lisp
(defun %remove-dead-array-returning-functions (module)
  "Scans MODULE for functions whose return type is an LLVM array type
   ([N x T]) and that have no uses (no callers in this module).
   Deletes each such function.

   This is Part 2 of the IGC bug 028 workaround.
   Returns the number of functions deleted."
  (log:info "028-cleanup: starting scan of module for dead array-returning functions")
  (let ((to-delete '())
        (fn-count 0)
        (fn (crisp.llvm-bindings::llvm-get-first-function module)))
    (loop while (and fn (not (cffi:null-pointer-p fn))) do
      (incf fn-count)
      (let* ((fn-name  (crisp.llvm-bindings::llvm-get-value-name fn))
             (fn-type  (crisp.llvm-bindings::llvm-global-get-value-type fn))
             (ret-type (crisp.llvm-bindings::llvm-get-return-type fn-type))
             (is-arr   (crisp.llvm-bindings::llvm-type-kind-is-array? ret-type))
             (no-uses  (cffi:null-pointer-p (crisp.llvm-bindings::llvm-get-first-use fn))))
        (log:info "028-cleanup: fn=~a is-array-ret=~a no-uses=~a" fn-name is-arr no-uses)
        (when (and is-arr no-uses)
          (log:info "028-cleanup: queuing dead array-returning fn ~a for deletion" fn-name)
          (push fn to-delete)))
      (setf fn (crisp.llvm-bindings::llvm-get-next-function fn)))
    (log:info "028-cleanup: scanned ~a function(s), queued ~a for deletion" fn-count (length to-delete))
    (dolist (fn to-delete)
      (crisp.llvm-bindings::llvm-delete-function fn))
    (let ((n (length to-delete)))
      (when (> n 0)
        (log:info "028-cleanup: deleted ~a dead array-returning function(s)" n))
      n)))

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



(defun register-builtins ()
  "Registers built-in types: storage, cell, and tensor def-record templates.
   Cell and tensor carry the value-t brand for --differentiate mode.
   Tensor: N-dimensional strided view; offset/strides/extents are virtual
   fixed arrays of length N (SROA to N ulong registers each at boundaries)."
  (log:info "Registering built-in structs (storage, cell, tensor)...")

  ;; Clear brand-specific state that is NOT cleared by initialize-compiler.
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
  ;;   value-t brand enables --differentiate provenance tracking.
  ;;   NOTE: index-t intentionally omitted (package-symbol conflict avoidance with fake-cell).
  (eval '(with-template-type ((To T) (Addr address-space :global) (Acc access :read-write))
           (def-record cell
             (brand value-t To :subst :descendant :enforce :diff)
             (parent (storage Addr))
             (offset ulong)
             (element-type type-spec :c-t To)
             (address-space address-space :c-t Addr)
             (access access :c-t Acc))))

  ;; bytes~ helper for cell.
  (register-template 'bytes~ '(To (Addr address-space :global) (Acc access :read-write)) nil
    '(def-function bytes~ (c)
       (declare (function ((cell To Addr Acc) => ulong)))
       (declare (crisp-system-generated))
       (return (sizeof To)))
    '((cell To Addr Acc) => ulong))

  ;; TENSOR: N-dimensional strided view over a storage handle.
  ;;   offset, strides, extents: virtual fixed arrays of length N.
  ;;   length: product of extents, stored as a field for O(1) (length~ t).
  ;;   value-t brand follows the same pattern as cell.
  (eval '(with-template-type ((To T) (N integer 1) (Addr address-space :global)
                               (Acc access :read-write) (Aln align :compact))
           (def-record tensor
             (brand value-t To :subst :descendant :enforce :diff)
             (parent  (storage Addr))
             (offset (array ulong N))
             (strides (array ulong N))
             (extents (array ulong N))
             (length  ulong)
             (element-type  type-spec     :c-t To)
             (num-dims      ulong         :c-t N)
             (address-space address-space :c-t Addr)
             (access        access        :c-t Acc)
             (align         align         :c-t Aln))))

  ;; bytes~ helper for tensor.
  (register-template 'bytes~
    '(To (N integer 1) (Addr address-space :global)
      (Acc access :read-write) (Aln align :compact)) nil
    '(def-function bytes~ (t1)
       (declare (function ((tensor To N Addr Acc Aln) => ulong)))
       (declare (crisp-system-generated))
       (return (sizeof To)))
    '((tensor To N Addr Acc Aln) => ulong))

  (log:info "Built-in structs registered."))


(defvar *differentiable-hof-store* (make-hash-table :test 'eq)
  "Maps HOF function name to info plist for inline backward differentiation.")


(defvar *implicit-scratch-size-expr-map* (make-hash-table)
  "Maps implicit scratch tensor param-name → size-expr form as written by the user
   (e.g. :match-warp-tile, 1, 4).  Used by generate-implicit-signature for metadata.")



  


(defun initialize-compiler (&key (log-level :off) (runtime-checks nil) (differentiate nil))
  "Initializes the compiler state.
   Extended to also clear *implicit-scratch-size-expr-map* for scratch tensor support."
  (setf *runtime-checks-enabled* runtime-checks)
  (setf *differentiate-p* differentiate)
  (cffi:use-foreign-library crisp.llvm-bindings::libllvm)

  (if (eq log-level :off)
      (log:config :off)
      (log:config :sane :stream *error-output* log-level))

  (initialize-crisp-types)
  (initialize-crisp-types)
  (initialize-type-hierarchy)
  (clrhash *function-table*)
  (clrhash *crisp-structs*)
  (clrhash *crisp-type-aliases*)
  (clrhash *crisp-template-aliases*)
  (clrhash *generic-functions*)
  (clrhash *kernel-declared-signatures*)
  (when (boundp '*record-definitions*) (clrhash *record-definitions*))

  (setf *compiled-kernels* nil)

  (clrhash *differentiable-functions*)
  (clrhash *differentiable-hof-store*)

  (initialize-expression-analyzers)
  (clrhash *implicit-arg-map*)
  (initialize-advisements)

  (setf (gethash 'die *function-table*)
        (list (make-function-signature :name 'die :parameters nil :return-types '(nil))))

  (setf (symbol-function 'truncate) #'cl:truncate)
  (setf (symbol-function 'floor) #'cl:floor)
  (setf (symbol-function 'ceil) #'cl:ceiling)
  (setf (symbol-function 'round) #'cl:round)

  (if (fboundp 'initialize-templates)
      (funcall 'initialize-templates)
      (log:warn "Template system not loaded/initialized."))

  (when (boundp '*brand-definitions*) (clrhash *brand-definitions*))
  (when (boundp '*brand-instance-cache*) (clrhash *brand-instance-cache*))
  (when (boundp '*brand-instance-types*) (clrhash *brand-instance-types*))

  (when (boundp '*partial-template-instantiations*)
        (loop for template-name being the hash-keys of *partial-template-instantiations*
              do (let ((dispatch-sym (intern (format nil "MAKE-~a%DISPATCH" template-name)
                                             (symbol-package template-name))))
                   (when (macro-function dispatch-sym)
                         (fmakunbound dispatch-sym))))
        (clrhash *partial-template-instantiations*))

  (when (boundp '*struct-mutating-functions*)
        (clrhash *struct-mutating-functions*))

  ;; NEW: clear scratch tensor size-expr side table
  (clrhash *implicit-scratch-size-expr-map*)

  (register-builtins)

  (log:info "Compiler initialized. differentiate=~a" differentiate))
