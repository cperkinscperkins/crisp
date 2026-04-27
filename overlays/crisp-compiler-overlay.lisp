;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)


;;; =========================================================
;;; 089-strategy: side table for kernel dispatch declarations
;;; =========================================================

(defvar *kernel-dispatch-declarations* (make-hash-table :test #'eq)
  "Maps kernel name symbol → plist of dispatch declarations extracted from def-kernel.
   Keys: :global-size, :local-size, :num-groups. Values: the raw s-expression forms
   e.g. :global-size = (global-size :derive-from (width height) :strategy :one-thread-per).")


;;; src/compiler.lisp
(defun initialize-compiler (&key (log-level :off) (runtime-checks nil) (differentiate nil))
  "Initializes the compiler state.
   Extended to also clear *kernel-dispatch-declarations* for strategy support."
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

  ;; clear scratch tensor size-expr side table
  (clrhash *implicit-scratch-size-expr-map*)

  ;; clear dispatch declarations side table
  (clrhash *kernel-dispatch-declarations*)

  (register-builtins)

  (log:info "Compiler initialized. differentiate=~a" differentiate))


;;; src/analysis/core.lisp
(defun internal-def-function (name params declarations body location)
  "Wrapper around internal-compile-function. Detects kernel entry-points and
   binds *boundary-struct-params*, *boundary-array-params*, and
   *in-dispatch-context* to enforce kernel-boundary rules.
   Extended to capture global-size/local-size/num-groups dispatch declarations."
  (log:info "Analyzing function ~s" name)

  (when (and *differentiate-p*
             (not (find "NON-DIFFERENTIABLE" declarations
                        :key (lambda (x) (when (consp x) (symbol-name (car x))))
                        :test #'string-equal)))
        (log:info "Applying ANF to function body")
        (let* ((progn-body `(progn ,@body))
               (anf-body (anf-normalize progn-body nil))
               (unwrapped-body (if (and (consp anf-body) (eq (car anf-body) 'progn))
                                   (cdr anf-body)
                                   (list anf-body))))
          (setf body unwrapped-body)))

  (multiple-value-bind (explicit-env return-type)
      (parse-function-declarations params declarations)
    (let* ((*compiler-context* (or *compiler-context* (make-compiler-context)))
           (is-entry-p (loop for d in declarations
                             thereis (and (listp d)
                                          (symbolp (first d))
                                          (string-equal (symbol-name (first d)) "ENTRY-POINT"))))
           (*in-dispatch-context* is-entry-p)
           (*boundary-struct-params*
             (if is-entry-p
                 (loop for param in explicit-env
                       when (%boundary-struct-type-p (parameter-def-type param))
                       collect (string-upcase (symbol-name (parameter-def-name param))))
                 *boundary-struct-params*))
           (*boundary-array-params*
             (if is-entry-p
                 (loop for param in explicit-env
                       when (%array-type-p (parameter-def-type param))
                       collect (string-upcase (symbol-name (parameter-def-name param))))
                 *boundary-array-params*)))
      (when (and is-entry-p *boundary-struct-params*)
            (log:debug "Kernel ~a has boundary struct params: ~a" name *boundary-struct-params*))
      (when (and is-entry-p *boundary-array-params*)
            (log:debug "Kernel ~a has boundary array params: ~a" name *boundary-array-params*))

      ;; Extract and store dispatch declarations for entry-point kernels
      (when is-entry-p
        (let ((global-size-decl (find "GLOBAL-SIZE" declarations
                                      :key (lambda (x) (when (consp x) (symbol-name (car x))))
                                      :test #'string-equal))
              (local-size-decl  (find "LOCAL-SIZE" declarations
                                      :key (lambda (x) (when (consp x) (symbol-name (car x))))
                                      :test #'string-equal))
              (num-groups-decl  (find "NUM-GROUPS" declarations
                                      :key (lambda (x) (when (consp x) (symbol-name (car x))))
                                      :test #'string-equal)))
          (when (or global-size-decl local-size-decl num-groups-decl)
            (let ((dispatch-plist
                    (append (when global-size-decl (list :global-size global-size-decl))
                            (when local-size-decl  (list :local-size  local-size-decl))
                            (when num-groups-decl  (list :num-groups  num-groups-decl)))))
              (log:info "Kernel ~a: storing dispatch declarations ~a" name dispatch-plist)
              (setf (gethash name *kernel-dispatch-declarations*) dispatch-plist)))))

      (internal-compile-function name explicit-env return-type params body declarations location *compiler-context*))))


;;; src/metadata.lisp
(defun serialize-kernels (output-stream kernel-names &key source output-targets)
  "Emits the (:kernels ...) section of the metacrisp file.
   Extended to include :global-size, :local-size, :num-groups dispatch declarations."
  (when kernel-names
        (format output-stream "(:kernels~%")
        (dolist (k-name (sort (copy-list kernel-names) #'string< :key #'symbol-name))
          (let ((sigs (gethash k-name *function-table*))
                (blocks-to-emit nil))
            ;; Use only the FIRST signature (Pass 1 registered, Pass 2 updated)
            (dolist (actual-sig (list (first sigs)))
              (when actual-sig
                    (let* ((phys-sig-str (generate-physical-signature actual-sig))
                           (declared-types (gethash k-name *kernel-declared-signatures*))
                           (decl-sig-list (generate-declared-signature actual-sig declared-types))
                           (implicit-sig-list (generate-implicit-signature actual-sig declared-types))
                           (dispatch-info (gethash k-name *kernel-dispatch-declarations*))
                           (source-loc (if source source
                                           (namestring (uiop/filesystem:native-namestring (first (function-signature-source-location actual-sig)))))))

                      (push (list :name (string-downcase (symbol-name k-name))
                                  :source source-loc
                                  :output output-targets
                                  :phys phys-sig-str
                                  :decl decl-sig-list
                                  :impl implicit-sig-list
                                  :dispatch dispatch-info)
                            blocks-to-emit))))

            (setf blocks-to-emit (remove-duplicates (nreverse blocks-to-emit) :test #'equalp))

            (dolist (blk blocks-to-emit)
              (let ((dispatch (getf blk :dispatch)))
                (format output-stream "  (:name ~s~%" (getf blk :name))
                (format output-stream "    :source ~s~%" (pathname (getf blk :source)))
                (when (getf blk :output) (format output-stream "    :output-targets ~s~%" (getf blk :output)))
                ;; Emit dispatch declarations before physical/declared signatures
                (let ((global-size-decl (getf dispatch :global-size))
                      (local-size-decl  (getf dispatch :local-size))
                      (num-groups-decl  (getf dispatch :num-groups)))
                  (when global-size-decl
                    (format output-stream "    :global-size ")
                    (print-without-packages global-size-decl output-stream)
                    (format output-stream "~%"))
                  (when local-size-decl
                    (format output-stream "    :local-size ")
                    (print-without-packages local-size-decl output-stream)
                    (format output-stream "~%"))
                  (when num-groups-decl
                    (format output-stream "    :num-groups ")
                    (print-without-packages num-groups-decl output-stream)
                    (format output-stream "~%")))
                (format output-stream "    :physical-signature ~a~%" (getf blk :phys))
                (format output-stream "    :declared-signature ")
                (print-without-packages (getf blk :decl) output-stream)
                (format output-stream "~%")
                (when (getf blk :impl)
                      (format output-stream "    :implicit-params ")
                      (print-without-packages (getf blk :impl) output-stream)
                      (format output-stream "~%"))
                (format output-stream "  )~%"))))
        (format output-stream "  )~%"))))

;; src/compiler.lisp
;; Fix: inject-spir-kernel-metadata used (search func-name result) which matched
;; func-name inside struct type names (e.g. S_01_global_size_set_to_scalar_CELL
;; contains "set_to_scalar"). This caused new-brace-pos to point to the struct
;; type's { rather than the function body's {, making close-paren-pos NIL and
;; then (1+ close-paren-pos) throwing "The value NIL is not of type NUMBER".
;; Fix: search for "@funcname(" to precisely locate the function definition.
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

                  (let* (;; Search for @funcname( to find the definition, not occurrences
                         ;; of func-name inside struct type names like S_file_funcname_TYPE
                         (at-name-str (format nil "@~a(" func-name))
                         (kernel-sig-start (search at-name-str result))
                         (new-brace-pos (when kernel-sig-start
                                          (position #\{ result :start kernel-sig-start)))
                         ;; Search for ) only AFTER kernel-sig-start to stay within the signature
                         (close-paren-pos (when (and kernel-sig-start new-brace-pos)
                                            (position #\) result
                                                      :start kernel-sig-start
                                                      :end new-brace-pos
                                                      :from-end t))))

                    (log:info "  at-name-str=~s kernel-sig-start=~a new-brace-pos=~a close-paren-pos=~a"
                              at-name-str kernel-sig-start new-brace-pos close-paren-pos)

                    (if (null close-paren-pos)
                        (log:warn "inject-spir-kernel-metadata: could not find ) for ~a, skipping" func-name)
                        (progn
                          (setf result (concatenate 'string
                                         (subseq result 0 (1+ close-paren-pos))
                                         metadata-refs
                                         " "
                                         (string #\{)
                                         (subseq result (1+ new-brace-pos))))
                          (setf all-metadata-defs (concatenate 'string all-metadata-defs metadata-defs))
                          (setf metadata-id-base next-id))))))))

          (concatenate 'string result (format nil "~%~%") all-metadata-defs)))))

