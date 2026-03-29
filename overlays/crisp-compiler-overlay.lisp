;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)


;; ============================================================
;; crisp.main redefinitions — multi-file compilation support
;; src/main.lisp
;; ============================================================

(in-package :crisp.main)

(defun parse-cli-args (args)
  "Parses command-line arguments and returns (values files output-file debug-p single-pass-p targets metadata-p hoist-targets).
Supports one or more .crisp source files: the last file is treated as the primary (determines output name)."
  (let* ((flags (remove-if-not (lambda (arg) (char= (char arg 0) #\-)) args))
         (files (remove-if (lambda (arg) (char= (char arg 0) #\-)) args))
         (log-level-flag (find-if (lambda (f) (alexandria:starts-with-subseq "--log-level=" f)) flags))
         (log-level (if log-level-flag
                        (intern (string-upcase (subseq log-level-flag (length "--log-level="))) :keyword)
                        :off))
         (single-pass-p (member "--single-pass" flags :test #'string=))
         (debug-p (or (member "-g" flags :test #'string=)
                      (member "--debug" flags :test #'string=)))
         (runtime-checks-p (member "--runtime-checks" flags :test #'string=))
         (differentiate-p (member "--differentiate" flags :test #'string=))

         ;; Target Parsing
         (target-flags (remove-if-not (lambda (f) (alexandria:starts-with-subseq "--ir-target=" f)) flags))
         (targets (mapcar (lambda (f)
                            (let ((val (string-upcase (subseq f (length "--ir-target=")))))
                              (cond
                               ((string= val "SPV") :spirv)
                               ((string= val "SPIRV") :spirv)
                               ((string= val "PTX") :ptx)
                               (t (intern val :keyword)))))
                      target-flags))
         ;; Hoist Parsing
         (hoist-flags (remove-if-not (lambda (f) (alexandria:starts-with-subseq "--hoist=" f)) flags))
         (hoist-targets (mapcar (lambda (f)
                                  (let ((val (string-upcase (subseq f (length "--hoist=")))))
                                    (cond
                                     ((or (string= val "L0") (string= val "LEVELZERO")) :L0)
                                     ((or (string= val "OPENCL") (string= val "CL")) :OPENCL)
                                     ((string= val "CUDA") :CUDA)
                                     (t (intern val :keyword)))))
                            hoist-flags))
         ;; Auto-enable metadata if --hoist is specified
         (metadata-p (or (member "--metadata" flags :test #'string=)
                         (and hoist-targets t))))

    (when (and differentiate-p hoist-targets)
          (format *error-output* "ERROR: --differentiate and --hoist are incompatible and cannot be used together.~%")
          (uiop:quit 1))

    ;; Initialize the compiler system.
    (crisp.compiler:initialize-compiler :log-level log-level
                                        :runtime-checks runtime-checks-p
                                        :differentiate differentiate-p)

    ;; Require at least one source file; support multiple files.
    (unless (>= (length files) 1)
      (format *error-output* "Usage: crisp-compile [flags] <file1.crisp> [file2.crisp ...]~%")
      (uiop:quit 1))

    ;; --- Hoisting Logic ---
    (when (member :L0 hoist-targets)
          (if (null targets)
              ;; Case 1: Helpful Default (L0 -> SPV)
              (progn
               (format *error-output* "; Auto-enabling --ir-target=spv (required for --hoist=L0)~%")
               (setf targets '(:spirv)))
              ;; Case 2: Validation (L0 requires SPV)
              (unless (member :spirv targets)
                (format *error-output* "ERROR: --hoist=L0 requires --ir-target=spv. Found targets: ~a~%" targets)
                (uiop:quit 1))))

    (values files nil debug-p single-pass-p targets metadata-p hoist-targets)))

(defun compile-files (files output-file debug-p single-pass-p targets metadata-p hoist-targets)
  "Compiles the given files as a single unit (in order), iterating over requested targets, then invokes hoisters.
When multiple files are given, forms are read from each file in order and compiled together as if they
had been one file.  The LAST file is the primary: its name determines output file names and the debug
compile-unit filepath."
  (declare (ignore output-file)) ; Handled per-target
  ;; The last file is the primary: determines output naming and debug context.
  (let* ((filename (car (last files)))
         (filepath (uiop:truename* filename))
         ;; For error messages, show all files (list them if more than one).
         (file-display (if (= (length files) 1)
                           filename
                           (format nil "[~{~a~^, ~}]" (mapcar #'file-namestring files))))
         ;; Default to :generic (stdout) if no targets specified
         (passes (if targets targets '(:generic))))

    (let ((generated-outputs nil)
          (captured-forms nil)
          (generated-metacrisp-files nil))
      (dolist (target-backend passes)
        (let ((crisp.compiler:*target-backend* target-backend)
              (crisp.compiler::*emit-metadata* metadata-p))
          (format *error-output* "~&; --- Starting Pass for Target: ~a ---~%" target-backend)

          (let* ((module (crisp.llvm-bindings:llvm-module-create (pathname-name filename)))
                 (builder (crisp.llvm-bindings:llvm-create-builder))
                 ;; Only create the DIBuilder if the debug flag is present.
                 (di-builder (when debug-p (crisp.llvm-bindings:llvm-create-di-builder module)))
                 (di-compile-unit (when debug-p (initialize-debug-context module di-builder filepath))))
            (unwind-protect
                (handler-case
                    (progn
                     (if single-pass-p
                         ;; --- SINGLE-PASS MODE (multiple files) ---
                         ;; Process each file's forms in order with a shared toplevel-index so that
                         ;; location indices are unique across the entire compilation unit.
                         (let ((toplevel-index 0)
                               (*package* (find-package :crisp-language)))
                           (dolist (f files)
                             (with-open-file (stream f)
                               (loop for form = (read stream nil :eof)
                                     until (eq form :eof)
                                     do (let ((location (list toplevel-index)))
                                          (crisp.compiler:compile-toplevel-form form location module builder di-builder di-compile-unit nil)
                                          (incf toplevel-index))))))
                         ;; --- MULTI-PASS MODE (DEFAULT, multiple files) ---
                         ;; Read all forms from all files in order into one flat list, then compile-module.
                         (let* ((*package* (find-package :crisp-language))
                                (forms (loop for f in files
                                             appending (with-open-file (stream f)
                                                         (loop for form = (read stream nil :eof)
                                                               until (eq form :eof)
                                                               collect form))))
                                (location-map (when debug-p (crisp.compiler:generate-location-map forms))))
                           (setf captured-forms forms)
                           (crisp.compiler:compile-module forms module builder di-builder di-compile-unit location-map)))

                     ;; Output Generation — keyed off the primary (last) file.
                     (let ((base-name (if crisp.compiler::*differentiate-p*
                                          (format nil "~a_grad" (pathname-name filepath))
                                          (pathname-name filepath))))
                       (case target-backend
                         (:spirv
                          (let ((out-path (make-pathname :name base-name :type "spv" :defaults filepath)))
                            (crisp.compiler:compile-to-spirv module out-path :debug-p debug-p)
                            (push (list :spv out-path) generated-outputs)))
                         (:ptx
                          (let ((out-path (make-pathname :name base-name :type "ptx" :defaults filepath)))
                            (crisp.compiler:compile-to-ptx module out-path :debug-p debug-p)
                            (push (list :ptx out-path) generated-outputs)))
                         (:llvmir
                          (let ((out-path (make-pathname :name base-name :type "ll" :defaults filepath)))
                            (let ((ir-ptr (crisp.llvm-bindings:llvm-print-module-to-string module)))
                              (unwind-protect
                                  (with-open-file (stream out-path :direction :output :if-exists :supersede)
                                    (write-string (cffi:foreign-string-to-lisp ir-ptr) stream))
                                (crisp.llvm-bindings:llvm-dispose-message ir-ptr)))
                            (push (list :llvmir out-path) generated-outputs)))
                         ;; Default/Generic: Print IR to stdout
                         (t
                          (let ((ir-ptr (crisp.llvm-bindings:llvm-print-module-to-string module)))
                            (unwind-protect
                                (format t "--- Generated LLVM IR (~a): ---~%~a~%" target-backend (cffi:foreign-string-to-lisp ir-ptr))
                              (crisp.llvm-bindings:llvm-dispose-message ir-ptr)))))))

                  ;; Error Handling — report all files involved.
                  (crisp.compiler:crisp-compiler-error (c)
                                                       (print-compiler-error c file-display)
                                                       (uiop:quit 1))
                  (end-of-file ()
                               (print-compiler-error (make-condition 'crisp.compiler:crisp-unexpected-eof-error) file-display)
                               (uiop:quit 1))
                  (error (c)
                    (print-compiler-error c file-display)
                    (uiop:quit 1)))

              ;; Cleanup resources
              (when debug-p
                    (crisp.llvm-bindings:llvm-di-builder-finalize di-builder)
                    (crisp.llvm-bindings:llvm-dispose-di-builder di-builder))
              (crisp.llvm-bindings:llvm-dispose-builder builder)
              (crisp.llvm-bindings:llvm-dispose-module module)))))

      ;; Metadata Generation (Once, after collecting all outputs)
      (when metadata-p
            (let* ((base-name (if crisp.compiler::*differentiate-p*
                                  (format nil "~a_grad" (pathname-name filepath))
                                  (pathname-name filepath)))
                   (meta-path (make-pathname :name base-name :type "metacrisp" :defaults filepath))
                   (meta-paths
                    (crisp.compiler::generate-metadata-for-file filepath
                                                                meta-path
                                                                :output-targets (reverse generated-outputs)
                                                                :forms captured-forms)))
              ;; Track generated metacrisp files for hoisting
              (setf generated-metacrisp-files
                (if (listp meta-paths) meta-paths (list meta-paths)))))

      (format *error-output* "; ...All compilation passes finished.~%")

      ;; Invoke hoisters if specified
      (when hoist-targets
            (format *error-output* "~&; --- Starting Hoisting Phase ---~%")
            (dolist (hoist-id hoist-targets)
              (dolist (metacrisp-file generated-metacrisp-files)
                (when (probe-file metacrisp-file)
                      (invoke-hoister hoist-id metacrisp-file))))
            (format *error-output* "; ...All hoisting finished.~%")))))

;; Return to crisp.compiler package for any subsequent overlay content.
(in-package :crisp.compiler)


;; ============================================================
;; %pre-register-differentiable-fns — add non-HOF template support
;; src/analysis/core.lisp
;; ============================================================
;;
;; The original with-template-type branch only pre-registered HOF def-functions
;; (those that use funcall). Non-HOF template functions (e.g. a simple add-three
;; defined inside with-template-type) were silently skipped, causing "function X
;; is not differentiable" errors when called from a differentiated kernel in a
;; separate file. We add an else branch: if no HOF param was found, register the
;; template function optimistically with n-float-params = (number of non-&OUT params),
;; n-return = 1. This is a placeholder; the concrete instantiation will update
;; *differentiable-functions* with the real count before the backward walk runs.

(defun %pre-register-differentiable-fns (forms)
  "When *differentiate-p* is T, walk FORMS for def-function forms and
pre-register them in *differentiable-functions* (and *differentiable-hof-store*
for HOF functions). Handles top-level def-function, progn, and with-template-type.
Guards parse-function-declarations against unknown-type errors from brand types
that are not yet registered at pre-registration time."
  (when *differentiate-p*
    (cl:dolist (form forms)
      (cond
        ;; Top-level def-function: existing HOF-aware logic
        ((and (consp form) (eq (car form) 'def-function))
         (cl:let* ((name (second form))
                   (params (third form))
                   (body-and-loc (cdddr form))
                   (declare-forms (cl:loop for f in body-and-loc
                                          while (and (listp f) (eq (car f) 'declare))
                                          collect f))
                   (declarations (cl:loop for f in declare-forms append (rest f)))
                   (is-system (member '(crisp-system-generated) declarations :test #'equal)))
           (unless (or is-system (%fn-name-is-grad-p name))
             (handler-case
               (multiple-value-bind (env return-types)
                   (parse-function-declarations params declarations)
                 (cl:let* ((float-param-entries
                            (cl:loop for pd in env
                                     when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                               (%crisp-float-type-p (parameter-def-type pd)))
                                     collect pd))
                           (n-float-params (length float-param-entries))
                           (return-types-nv (remove nil return-types))
                           (n-return (length return-types-nv))
                           (fn-param-entries
                            (cl:loop for pd in env
                                     for i from 0
                                     when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                               (%crisp-function-type-p (parameter-def-type pd)))
                                     collect (cons i pd)))
                           (is-hof (consp fn-param-entries)))
                   (when (> n-float-params 0)
                     (if is-hof
                         (cl:let* ((fn-param-idx  (car (car fn-param-entries)))
                                   (fn-param-sym  (parameter-def-name (cdr (car fn-param-entries))))
                                   (float-param-syms (mapcar #'parameter-def-name float-param-entries))
                                   (body-forms (cl:loop for f in body-and-loc
                                                        unless (and (listp f) (eq (car f) 'declare))
                                                        collect f))
                                   (clean-body  (cl:loop for f in body-forms
                                                         unless (and (atom f) (not (symbolp f)))
                                                         collect f)))
                           (log:info "AUTODIFF: Pre-registering HOF ~a (fn-param=~a idx=~a)"
                                     name fn-param-sym fn-param-idx)
                           (setf (gethash name *differentiable-hof-store*)
                                 (list :param-syms       (cl:loop for pd in env
                                                                  collect (parameter-def-name pd))
                                       :fn-param-idx     fn-param-idx
                                       :fn-param-sym     fn-param-sym
                                       :float-param-syms float-param-syms
                                       :body-forms       clean-body))
                           (setf (gethash name *differentiable-functions*)
                                 (list :hof t
                                       :n-float-params n-float-params
                                       :n-return n-return)))
                         (cl:let* ((pkg (symbol-package name))
                                   (bkwd-name (intern (format nil "~A_GRAD" (symbol-name name)) pkg)))
                           (log:info "AUTODIFF: Pre-registering ~a -> ~a (n-fp=~a n-ret=~a)"
                                     name bkwd-name n-float-params n-return)
                           (setf (gethash name *differentiable-functions*)
                                 (list :bkwd-name bkwd-name
                                       :n-float-params n-float-params
                                       :n-return n-return)))))))
               (error (e)
                 (log:debug "AUTODIFF: Skipping pre-registration of ~a -- type parse error: ~a" name e))))))

        ;; progn: recurse
        ((and (consp form) (eq (car form) 'progn))
         (%pre-register-differentiable-fns (rest form)))

        ;; with-template-type: walk body for def-functions using funcall scanning.
        ;; Cannot use parse-function-declarations here -- types contain T placeholder.
        ;; HOF branch: funcall detected -> register in *differentiable-hof-store*.
        ;; Non-HOF branch: register optimistically; concrete instantiation will update
        ;;   the entry with accurate counts before the backward walk runs.
        ((and (consp form) (eq (car form) 'with-template-type))
         (cl:dolist (bform (cddr form))   ; skip 'with-template-type' and params list
           (when (and (consp bform) (eq (car bform) 'def-function))
             (cl:let* ((name        (second bform))
                       (params      (third bform))
                       (body-and-loc (cdddr bform))
                       (declare-forms (cl:loop for f in body-and-loc
                                               while (and (listp f) (eq (cl:first f) 'declare))
                                               collect f))
                       (fn-body     (cl:nthcdr (length declare-forms) body-and-loc))
                       fn-param-idx
                       fn-param-sym)
               ;; Detect HOF param by looking for (funcall <param> ...) in body
               (cl:loop for p in params
                        for i from 0
                        do (when (%tree-has-funcall-p fn-body p)
                             (setf fn-param-idx i)
                             (setf fn-param-sym p)
                             (cl:return)))
               (cond
                 ;; HOF template: register in hof-store (existing behavior)
                 ((and fn-param-idx
                       (not (gethash name *differentiable-functions*)))
                  (log:info "AUTODIFF: Pre-registering HOF template ~a via with-template-type (fn-param=~a idx=~a)"
                            name fn-param-sym fn-param-idx)
                  (setf (gethash name *differentiable-hof-store*)
                        (list :param-syms       params
                              :fn-param-idx     fn-param-idx
                              :fn-param-sym     fn-param-sym
                              :float-param-syms (cl:loop for p in params
                                                         for i from 0
                                                         unless (= i fn-param-idx)
                                                         collect p)
                              :body-forms       fn-body))
                  (setf (gethash name *differentiable-functions*)
                        (list :hof t
                              :n-float-params (1- (length params))
                              :n-return 1)))
                 ;; Non-HOF template: register optimistically.
                 ;; Types are T placeholders so we cannot parse them; treat all
                 ;; non-&OUT params as potentially float. Concrete instantiation
                 ;; will overwrite this entry with accurate counts.
                 ((not (gethash name *differentiable-functions*))
                  (cl:let* ((n-params (cl:count-if
                                       (lambda (p)
                                         (not (string-equal (symbol-name p) "&OUT")))
                                       params))
                            (pkg      (symbol-package name))
                            (bkwd-name (intern (format nil "~A_GRAD" (symbol-name name)) pkg)))
                    (log:info "AUTODIFF: Pre-registering non-HOF template ~a via with-template-type (n-params=~a, optimistic)"
                              name n-params)
                    (setf (gethash name *differentiable-functions*)
                          (list :bkwd-name      bkwd-name
                                :n-float-params n-params
                                :n-return       1)))))))))))))


;; ============================================================
;; analyze-dvec-component-ref — resolve brand-instance types to base dvec name
;; src/analysis/core.lisp
;; ============================================================
;;
;; register-derived-type stores brand-instance gensyms (e.g. VALUE-T-204
;; derived from float2) into *crisp-types* inheriting the :device-vector
;; category.  The original analyze-dvec-component-ref extracted vector width
;; from the last character of arg-type's symbol name, which is meaningless for
;; gensym'd names like "VALUE-T-204" or "VALUE-T-220".  Fix: resolve the type
;; to its concrete base via *type-derivation-graph* before extracting width and
;; component scalar type.

(defun analyze-dvec-component-ref (expr env context location)
  "Analyzes (x~ v), (y~ v), (z~ v), (w~ v) — device-vector component accessors.
   The operator symbol determines the 0-based LLVM element index (0..3).
   Returns a semantic-extract-value node whose type is the scalar component type.

   Brand-instance gensyms (e.g. VALUE-T-204 derived from float2) are resolved
   to their concrete device-vector base type via *type-derivation-graph* before
   width and component-scalar extraction.

   In :write mode (inside a set! target), also validates that a cell-deref
   aggregate is not read-only."
  (let* ((op       (first expr))
         (op-name  (symbol-name op))
         (index    (cond ((cl:string= op-name "X~") 0)
                         ((cl:string= op-name "Y~") 1)
                         ((cl:string= op-name "Z~") 2)
                         ((cl:string= op-name "W~") 3)
                         (t (error "analyze-dvec-component-ref: unknown accessor ~a" op))))
         ;; Always read the aggregate; the write context is on the component, not the vector.
         (arg-node (let ((*analysis-access-mode* :read))
                     (analyze-expression (second expr) env context
                                         (append location '(1)))))
         (arg-type (semantic-node-type arg-node))
         (ct       (%dvec-type-lookup arg-type)))

    ;; If the argument is NOT a device-vector:
    ;; - When ct is nil (user-defined struct/record not in *crisp-types*), or
    ;;   ct is a struct/record category — fall back to the function call path
    ;;   so that user-defined x~/y~/z~/w~ struct accessors still work.
    ;; - For clearly non-aggregate built-in types (scalar, void, pointer, meta)
    ;;   signal a type error immediately so the user gets a clear message.
    (unless (and ct (eq (crisp-type-category ct) :device-vector))
      (let ((should-fallback
             (or (null ct)
                 (member (crisp-type-category ct) '(:struct :record)))))
        (if should-fallback
            (return-from analyze-dvec-component-ref
              (analyze-function-call op expr env context location))
            (error 'crisp-compiler-error
                   :message (format nil "~a requires a device-vector argument; got ~a"
                                    (cl:string-downcase op-name) arg-type)
                   :source-location location))))

    ;; Resolve brand-instance / derived types to their concrete device-vector
    ;; base type for width and component-scalar extraction.
    ;; e.g. VALUE-T-204 (descendant of float2) -> float2 -> width 2, comp "FLOAT"
    (let* ((dvec-type (let ((node (gethash arg-type *type-derivation-graph*)))
                        (if node (type-node-base-type node) arg-type)))
           (type-name (symbol-name dvec-type))
           (width     (cl:digit-char-p (cl:char type-name (cl:1- (cl:length type-name))))))

      ;; Validate: component index must be in range for this vector width.
      (unless (and width (< index width))
        (error 'crisp-compiler-error
               :message (format nil
                 "~a is out of range for ~a (width ~a); valid accessors: ~a"
                 (cl:string-downcase op-name) arg-type width
                 (subseq '("x~" "y~" "z~" "w~") 0 (or width 0)))
               :source-location location))

      ;; In write mode: check that a cell-dereference aggregate is writable.
      (when (and (eq *analysis-access-mode* :write) (semantic-aref-p arg-node))
        (%dvec-check-cell-write-access arg-node location))

      ;; Component scalar type: strip trailing width digit(s) from the CONCRETE type name.
      ;; e.g.  "FLOAT2" -> "FLOAT",  "USHORT4" -> "USHORT",  "HALF3" -> "HALF"
      (let* ((base-name (cl:string-right-trim "1234" type-name))
             (comp-sym  (intern base-name (find-package :crisp-language))))
        (log:debug "analyze-dvec-component-ref: ~a on ~a (dvec ~a) -> index ~a, comp ~a"
                   op-name arg-type dvec-type index comp-sym)
        (make-semantic-extract-value
         :type           comp-sym
         :aggregate-node arg-node
         :index          index
         :source-location location)))))

