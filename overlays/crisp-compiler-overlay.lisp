;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;;; ============================================================
;;; 087 — GPU Built-in Functions
;;; ============================================================

;;; ----- Dynamic variable: dispatch context -----

(defvar *in-dispatch-context* nil
  "T when the analyzer is inside a def-kernel/def-grid-function body.
   Used to restrict GPU built-in calls to kernel entry points only.")

;;; ----- Redefine internal-def-function (adds *in-dispatch-context* binding) -----
;; src/analysis/core.lisp

(defun internal-def-function (name params declarations body location)
  "Wrapper around internal-compile-function. Detects kernel entry-points and
   binds *boundary-struct-params*, *boundary-array-params*, and
   *in-dispatch-context* to enforce kernel-boundary rules."
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
      (internal-compile-function name explicit-env return-type params body declarations location *compiler-context*))))

;;; ----- GPU builtin metadata table -----

(defun %gpu-builtin-info (builtin-kw)
  "Returns (base-return-type accepts-dim-p) for a GPU builtin keyword.
   BASE-RETURN-TYPE: return type when called with no args (nil = void).
   ACCEPTS-DIM-P: T if the builtin accepts a scalar dimension arg 0/1/2."
  (case builtin-kw
    ((:get-global-id :get-local-id :get-workgroup-id :get-num-groups
      :get-local-work-size :get-global-work-size :get-global-offset
      :get-global-id-abs)
     (list 'ulong3 t))
    (:get-work-dim          (list 'uint  nil))
    ((:get-local-linear-id :get-local-linear-size
      :get-global-linear-id :get-global-linear-size
      :get-total-threads :get-total-groups)
     (list 'ulong nil))
    ((:local-barrier :mem-fence)
     (list nil nil))
    (t (error "Unknown GPU builtin: ~a" builtin-kw))))

;;; ----- Analyzer -----

(defun %analyze-gpu-builtin (builtin-kw name-str expr env context location)
  "Analyzer for all GPU built-in function forms."
  (declare (ignore env context))
  (unless *in-dispatch-context*
    (error "GPU built-in '~a' is only valid inside a kernel (dispatch context)" name-str))
  (let* ((info     (%gpu-builtin-info builtin-kw))
         (base-ty  (first info))
         (acc-dim  (second info))
         (args     (rest expr)))
    (cond
      ((null args)
       (make-semantic-gpu-builtin :builtin-name builtin-kw
                                  :dimension nil
                                  :type base-ty
                                  :source-location location))
      ((= (length args) 1)
       (let ((dim-arg (first args)))
         (unless acc-dim
           (error "GPU built-in '~a' does not accept a dimension argument" name-str))
         (unless (integerp dim-arg)
           (error "GPU built-in '~a': dimension must be a compile-time integer constant (0, 1, or 2), got: ~a"
                  name-str dim-arg))
         (unless (member dim-arg '(0 1 2))
           (error "GPU built-in '~a': dimension ~a is out of valid range (must be 0, 1, or 2)"
                  name-str dim-arg))
         (make-semantic-gpu-builtin :builtin-name builtin-kw
                                    :dimension dim-arg
                                    :type 'ulong
                                    :source-location location)))
      (t
       (error "GPU built-in '~a' takes 0 or 1 arguments, got ~a" name-str (length args))))))

;;; ----- Redefine initialize-expression-analyzers (adds GPU builtins) -----
;; src/analysis/core.lisp

(defun initialize-expression-analyzers ()
  "Registers all expression analyzers; extended for 087-gpu-builtins."
  (clrhash *expression-analyzers*)
  (register-ops-analyzers)
  (register-control-analyzers)
  (register-struct-analyzers)
  ;; ##(...) device vector literal
  (setf (gethash 'crisp-vec-literal *expression-analyzers*)
        #'analyze-crisp-dvec-literal)
  (let ((cl-pkg (find-package :crisp-language))
        (cc-pkg (find-package :crisp.compiler)))
    ;; Component accessors x~ / y~ / z~ / w~
    (dolist (name '("X~" "Y~" "Z~" "W~"))
      (let ((sym-cl (intern name cl-pkg))
            (sym-cc (intern name cc-pkg)))
        (setf (gethash sym-cl *expression-analyzers*) #'analyze-dvec-component-ref)
        (unless (eq sym-cl sym-cc)
          (setf (gethash sym-cc *expression-analyzers*) #'analyze-dvec-component-ref))))
    ;; 083 matrix helpers: transpose, col, row, transpose!
    (dolist (entry `(("TRANSPOSE"  . ,#'analyze-transpose-expression)
                     ("COL"        . ,#'analyze-col-expression)
                     ("ROW"        . ,#'analyze-row-expression)
                     ("TRANSPOSE!" . ,#'analyze-transpose-bang-expression)))
      (let ((sym-cl (intern (car entry) cl-pkg))
            (sym-cc (intern (car entry) cc-pkg))
            (fn     (cdr entry)))
        (setf (gethash sym-cl *expression-analyzers*) fn)
        (unless (eq sym-cl sym-cc)
          (setf (gethash sym-cc *expression-analyzers*) fn))))
    ;; 087 GPU built-in functions
    (dolist (entry '(("GET-GLOBAL-ID"          :get-global-id)
                     ("GET-LOCAL-ID"            :get-local-id)
                     ("GET-WORKGROUP-ID"        :get-workgroup-id)
                     ("GET-NUM-GROUPS"          :get-num-groups)
                     ("GET-LOCAL-WORK-SIZE"     :get-local-work-size)
                     ("GET-GLOBAL-WORK-SIZE"    :get-global-work-size)
                     ("GET-GLOBAL-OFFSET"       :get-global-offset)
                     ("GET-GLOBAL-ID-ABS"       :get-global-id-abs)
                     ("GET-WORK-DIM"            :get-work-dim)
                     ("GET-LOCAL-LINEAR-ID"     :get-local-linear-id)
                     ("GET-LOCAL-LINEAR-SIZE"   :get-local-linear-size)
                     ("GET-GLOBAL-LINEAR-ID"    :get-global-linear-id)
                     ("GET-GLOBAL-LINEAR-SIZE"  :get-global-linear-size)
                     ("GET-TOTAL-THREADS"       :get-total-threads)
                     ("GET-TOTAL-GROUPS"        :get-total-groups)
                     ("LOCAL-BARRIER"           :local-barrier)
                     ("MEM-FENCE"               :mem-fence)))
      (let* ((name-str (first entry))
             (kw       (second entry))
             (fn       (let ((kw0 kw) (ns0 name-str))
                         (lambda (expr env context location)
                           (%analyze-gpu-builtin kw0 ns0 expr env context location)))))
        (let ((sym-cl (intern name-str cl-pkg))
              (sym-cc (intern name-str cc-pkg)))
          (setf (gethash sym-cl *expression-analyzers*) fn)
          (unless (eq sym-cl sym-cc)
            (setf (gethash sym-cc *expression-analyzers*) fn)))))))

;;; ----- Redefine semantic-node-type (adds semantic-gpu-builtin) -----
;; src/analysis/core.lisp

(defun semantic-node-type (node)
  "Returns the Crisp type of a semantic node.
Extended for 087-gpu-builtins."
  (etypecase node
    (semantic-literal (semantic-literal-value-type node))
    (semantic-device-vec-literal (semantic-device-vec-literal-vec-type node))
    (semantic-var-read (semantic-var-read-type node))
    (semantic-add (semantic-add-type node))
    (semantic-sub (semantic-sub-type node))
    (semantic-mul (semantic-mul-type node))
    (semantic-div (semantic-div-type node))
    (semantic-sin (semantic-sin-type node))
    (semantic-cos (semantic-cos-type node))
    (semantic-lt 'int)
    (semantic-gt 'int)
    (semantic-le 'int)
    (semantic-ge 'int)
    (semantic-eq 'int)
    (semantic-neq 'int)
    (semantic-if (semantic-if-type node))
    (semantic-set! 'void)
    (semantic-aref (semantic-aref-type node))
    (semantic-value-cast (semantic-value-cast-type node))
    (semantic-let (semantic-let-type node))
    (semantic-bitcast (semantic-bitcast-type node))
    (semantic-fp-truncate-cast (semantic-fp-truncate-cast-type node))
    (semantic-truncate (semantic-truncate-type node))
    (semantic-explicit-return (semantic-explicit-return-type node))
    (semantic-call (semantic-call-type node))
    (semantic-funcall (semantic-funcall-type node))
    (semantic-extract-value (semantic-extract-value-type node))
    (semantic-insert-value (semantic-insert-value-type node))
    (semantic-struct-construction (semantic-struct-construction-type node))
    (semantic-ct-array (semantic-ct-array-type node))
    (semantic-progn (semantic-progn-type node))
    (semantic-struct-member-update (semantic-struct-member-update-type node))
    (semantic-sizeof (semantic-sizeof-type node))
    (semantic-make-view (semantic-make-view-type node))
    (semantic-atomic-rmw (semantic-atomic-rmw-type node))
    (semantic-stride-view (semantic-stride-view-type node))
    (semantic-gpu-builtin (semantic-gpu-builtin-type node))))

;;; ----- Redefine semantic-node-source-location (adds semantic-gpu-builtin) -----
;; src/analysis/core.lisp

(defun semantic-node-source-location (node)
  "Returns the source location of a semantic node.
Extended for 087-gpu-builtins."
  (etypecase node
    (semantic-literal (semantic-literal-source-location node))
    (semantic-device-vec-literal (semantic-device-vec-literal-source-location node))
    (semantic-var-read (semantic-var-read-source-location node))
    (semantic-value-cast (semantic-value-cast-source-location node))
    (semantic-bitcast (semantic-bitcast-source-location node))
    (semantic-let (semantic-let-source-location node))
    (semantic-fp-truncate-cast (semantic-fp-truncate-cast-source-location node))
    (semantic-truncate (semantic-truncate-source-location node))
    (semantic-add (semantic-add-source-location node))
    (semantic-sub (semantic-sub-source-location node))
    (semantic-mul (semantic-mul-source-location node))
    (semantic-div (semantic-div-source-location node))
    (semantic-sin (semantic-sin-source-location node))
    (semantic-cos (semantic-cos-source-location node))
    (semantic-lt (semantic-lt-source-location node))
    (semantic-gt (semantic-gt-source-location node))
    (semantic-le (semantic-le-source-location node))
    (semantic-ge (semantic-ge-source-location node))
    (semantic-sizeof (semantic-sizeof-source-location node))
    (semantic-eq (semantic-eq-source-location node))
    (semantic-neq (semantic-neq-source-location node))
    (semantic-if (semantic-if-source-location node))
    (semantic-set! (semantic-set!-source-location node))
    (semantic-aref (semantic-aref-source-location node))
    (semantic-explicit-return (semantic-explicit-return-source-location node))
    (semantic-call (semantic-call-source-location node))
    (semantic-funcall (semantic-funcall-source-location node))
    (semantic-extract-value (semantic-extract-value-source-location node))
    (semantic-insert-value (semantic-insert-value-source-location node))
    (semantic-struct-construction (semantic-struct-construction-source-location node))
    (semantic-ct-array (semantic-ct-array-source-location node))
    (semantic-progn (semantic-progn-source-location node))
    (semantic-struct-member-update (semantic-struct-member-update-source-location node))
    (semantic-make-view (semantic-make-view-source-location node))
    (semantic-atomic-rmw (semantic-atomic-rmw-source-location node))
    (semantic-stride-view (semantic-stride-view-source-location node))
    (semantic-gpu-builtin (semantic-gpu-builtin-source-location node))))

;;; ----- LLVM IR generation helpers -----

(defun %spirv-get-or-create-fn (module fn-name llvm-ret-type param-types param-count)
  "Gets or creates an LLVM function declaration in MODULE."
  (let ((existing (llvm-get-named-function module fn-name)))
    (if (cffi:null-pointer-p existing)
        (let ((ft (llvm-function-type llvm-ret-type param-types param-count nil)))
          (llvm-add-function module fn-name ft))
        existing)))

(defun %call-spirv-vec3-builtin (builder module spirv-name)
  "Emits a call to @__spirv_BuiltIn<SPIRV-NAME>() returning <3 x i64> (ulong3).
   Example: spirv-name=\"GlobalInvocationId\" -> @__spirv_BuiltInGlobalInvocationId"
  (let* ((fn-name   (format nil "__spirv_BuiltIn~a" spirv-name))
         (vec3-type (crisp-type-to-llvm-type 'ulong3 module))
         (fn        (%spirv-get-or-create-fn module fn-name vec3-type (cffi:null-pointer) 0)))
    (llvm-build-call2 builder
                      (llvm-function-type vec3-type (cffi:null-pointer) 0 nil)
                      fn (cffi:null-pointer) 0
                      (string-downcase spirv-name))))

(defun %call-spirv-uint-builtin (builder module spirv-name)
  "Emits a call to @__spirv_BuiltIn<SPIRV-NAME>() returning i32 (uint)."
  (let* ((fn-name  (format nil "__spirv_BuiltIn~a" spirv-name))
         (i32-type (llvm-int32-type))
         (fn       (%spirv-get-or-create-fn module fn-name i32-type (cffi:null-pointer) 0)))
    (llvm-build-call2 builder
                      (llvm-function-type i32-type (cffi:null-pointer) 0 nil)
                      fn (cffi:null-pointer) 0
                      (string-downcase spirv-name))))

(defun %extract-vec3-i64 (builder vec-val dim name-suffix)
  "Extracts element at DIM (0/1/2) from a <3 x i64> LLVM value."
  (llvm-build-extract-element builder vec-val
                               (llvm-const-int (llvm-int32-type) dim nil)
                               name-suffix))

(defun %gen-product-of-vec3 (builder module spirv-name result-name)
  "Computes x*y*z for the <3 x i64> builtin @__spirv_BuiltIn<SPIRV-NAME>."
  (let* ((vec (%call-spirv-vec3-builtin builder module spirv-name))
         (x   (%extract-vec3-i64 builder vec 0 "x"))
         (y   (%extract-vec3-i64 builder vec 1 "y"))
         (z   (%extract-vec3-i64 builder vec 2 "z"))
         (xy  (llvm-build-mul builder x y "xy")))
    (llvm-build-mul builder xy z result-name)))

(defun %gen-flat-linear-id-from-vecs (builder lid-vec lws-vec name)
  "Synthesizes z*lws.y*lws.x + y*lws.x + x from two <3 x i64> values."
  (let* ((x    (%extract-vec3-i64 builder lid-vec 0 "lx"))
         (y    (%extract-vec3-i64 builder lid-vec 1 "ly"))
         (z    (%extract-vec3-i64 builder lid-vec 2 "lz"))
         (lwsx (%extract-vec3-i64 builder lws-vec 0 "lwsx"))
         (lwsy (%extract-vec3-i64 builder lws-vec 1 "lwsy"))
         (lwsy_lwsx (llvm-build-mul builder lwsy lwsx "lwsy_x"))
         (z_part    (llvm-build-mul builder z lwsy_lwsx "z_part"))
         (y_part    (llvm-build-mul builder y lwsx "y_part"))
         (yx        (llvm-build-add builder y_part x "yx")))
    (llvm-build-add builder z_part yx name)))

(defun %gen-local-linear-id (builder module)
  "Synthesizes get-local-linear-id: z*lws.y*lws.x + y*lws.x + x."
  (let ((lid-vec (%call-spirv-vec3-builtin builder module "LocalInvocationId"))
        (lws-vec (%call-spirv-vec3-builtin builder module "WorkgroupSize")))
    (%gen-flat-linear-id-from-vecs builder lid-vec lws-vec "local_linear_id")))

(defun %gen-global-linear-id (builder module)
  "Synthesizes get-global-linear-id: flat_wg * lws_total + flat_lid."
  (let* (;; Flat local ID
         (lid-vec  (%call-spirv-vec3-builtin builder module "LocalInvocationId"))
         (lws-vec  (%call-spirv-vec3-builtin builder module "WorkgroupSize"))
         (flat-lid (%gen-flat-linear-id-from-vecs builder lid-vec lws-vec "flat_lid"))
         ;; LWS total
         (lwsx     (%extract-vec3-i64 builder lws-vec 0 "lwsx"))
         (lwsy     (%extract-vec3-i64 builder lws-vec 1 "lwsy"))
         (lwsz     (%extract-vec3-i64 builder lws-vec 2 "lwsz"))
         (lws-xy   (llvm-build-mul builder lwsx lwsy "lws_xy"))
         (lws-tot  (llvm-build-mul builder lws-xy lwsz "lws_tot"))
         ;; Flat workgroup ID
         (wgid-vec (%call-spirv-vec3-builtin builder module "WorkgroupId"))
         (ng-vec   (%call-spirv-vec3-builtin builder module "NumWorkgroups"))
         (flat-wg  (%gen-flat-linear-id-from-vecs builder wgid-vec ng-vec "flat_wg"))
         ;; result = flat_wg * lws_tot + flat_lid
         (base     (llvm-build-mul builder flat-wg lws-tot "base")))
    (llvm-build-add builder base flat-lid "global_linear_id")))

(defun %gen-spirv-control-barrier (builder module)
  "Emits @__spirv_ControlBarrier(i32 2, i32 2, i32 264).
   Scope=Workgroup(2) MemScope=Workgroup(2) Semantics=AcquireRelease(8)|WorkgroupMemory(256)."
  (let* ((i32-type (llvm-int32-type))
         (fn-name  "__spirv_ControlBarrier")
         (param-types (let ((arr (cffi:foreign-alloc 'llvm-type-ref :count 3)))
                        (setf (cffi:mem-aref arr 'llvm-type-ref 0) i32-type)
                        (setf (cffi:mem-aref arr 'llvm-type-ref 1) i32-type)
                        (setf (cffi:mem-aref arr 'llvm-type-ref 2) i32-type)
                        arr))
         (fn-type  (llvm-function-type (llvm-void-type) param-types 3 nil))
         (fn       (let ((ex (llvm-get-named-function module fn-name)))
                     (if (cffi:null-pointer-p ex)
                         (llvm-add-function module fn-name fn-type)
                         ex)))
         (args     (let ((arr (cffi:foreign-alloc 'llvm-value-ref :count 3)))
                     (setf (cffi:mem-aref arr 'llvm-value-ref 0) (llvm-const-int i32-type 2 nil))
                     (setf (cffi:mem-aref arr 'llvm-value-ref 1) (llvm-const-int i32-type 2 nil))
                     (setf (cffi:mem-aref arr 'llvm-value-ref 2) (llvm-const-int i32-type 264 nil))
                     arr)))
    (llvm-build-call2 builder fn-type fn args 3 "")
    (values nil nil)))

(defun %gen-spirv-memory-barrier (builder module)
  "Emits @__spirv_MemoryBarrier(i32 1, i32 520).
   MemScope=CrossWorkgroup(1) Semantics=AcquireRelease(8)|CrossWorkgroupMemory(512)."
  (let* ((i32-type (llvm-int32-type))
         (fn-name  "__spirv_MemoryBarrier")
         (param-types (let ((arr (cffi:foreign-alloc 'llvm-type-ref :count 2)))
                        (setf (cffi:mem-aref arr 'llvm-type-ref 0) i32-type)
                        (setf (cffi:mem-aref arr 'llvm-type-ref 1) i32-type)
                        arr))
         (fn-type  (llvm-function-type (llvm-void-type) param-types 2 nil))
         (fn       (let ((ex (llvm-get-named-function module fn-name)))
                     (if (cffi:null-pointer-p ex)
                         (llvm-add-function module fn-name fn-type)
                         ex)))
         (args     (let ((arr (cffi:foreign-alloc 'llvm-value-ref :count 2)))
                     (setf (cffi:mem-aref arr 'llvm-value-ref 0) (llvm-const-int i32-type 1 nil))
                     (setf (cffi:mem-aref arr 'llvm-value-ref 1) (llvm-const-int i32-type 520 nil))
                     arr)))
    (llvm-build-call2 builder fn-type fn args 2 "")
    (values nil nil)))

;;; ----- generate-node-ir for semantic-gpu-builtin -----
;; src/codegen.lisp

(defmethod generate-node-ir ((node semantic-gpu-builtin) builder module var-env di-builder di-scope location-map)
  "Generates LLVM IR for a GPU built-in function call."
  (declare (ignore var-env di-builder di-scope location-map))
  (let* ((bname (semantic-gpu-builtin-builtin-name node))
         (dim   (semantic-gpu-builtin-dimension node)))
    (log:info "Generating GPU builtin IR: ~a dim=~a" bname dim)
    (labels
        ;; Helper: call primitive vec3 builtin and optionally extractelement
        ((vec3-or-scalar (spirv-name)
           (let ((vec (%call-spirv-vec3-builtin builder module spirv-name)))
             (if dim
                 (values (%extract-vec3-i64 builder vec dim (format nil "~a_~a" (string-downcase spirv-name) dim)) nil)
                 (values vec nil)))))
      (case bname
        ;; --- Primitive 3D/scalar vector builtins ---
        (:get-global-id       (vec3-or-scalar "GlobalInvocationId"))
        (:get-local-id        (vec3-or-scalar "LocalInvocationId"))
        (:get-workgroup-id    (vec3-or-scalar "WorkgroupId"))
        (:get-num-groups      (vec3-or-scalar "NumWorkgroups"))
        (:get-local-work-size (vec3-or-scalar "WorkgroupSize"))
        (:get-global-work-size (vec3-or-scalar "GlobalSize"))
        (:get-global-offset   (vec3-or-scalar "GlobalOffset"))
        ;; --- Synthesized: GlobalInvocationId + GlobalOffset ---
        (:get-global-id-abs
         (let* ((gid  (%call-spirv-vec3-builtin builder module "GlobalInvocationId"))
                (goff (%call-spirv-vec3-builtin builder module "GlobalOffset")))
           (if dim
               (let* ((gid-n  (%extract-vec3-i64 builder gid  dim "gid_n"))
                      (goff-n (%extract-vec3-i64 builder goff dim "goff_n")))
                 (values (llvm-build-add builder gid-n goff-n "gid_abs_n") nil))
               ;; 3D: vector add (<3 x i64> + <3 x i64>)
               (values (llvm-build-add builder gid goff "gid_abs") nil))))
        ;; --- WorkDim (hidden kernel parameter, uint) ---
        (:get-work-dim
         (values (%call-spirv-uint-builtin builder module "WorkDim") nil))
        ;; --- Synthesized scalar builtins ---
        (:get-local-linear-id
         (values (%gen-local-linear-id builder module) nil))
        (:get-local-linear-size
         (values (%gen-product-of-vec3 builder module "WorkgroupSize" "local_linear_size") nil))
        (:get-global-linear-id
         (values (%gen-global-linear-id builder module) nil))
        ((:get-global-linear-size :get-total-threads)
         (values (%gen-product-of-vec3 builder module "GlobalSize" "total_threads") nil))
        (:get-total-groups
         (values (%gen-product-of-vec3 builder module "NumWorkgroups" "total_groups") nil))
        ;; --- Barriers (void) ---
        (:local-barrier (%gen-spirv-control-barrier builder module))
        (:mem-fence     (%gen-spirv-memory-barrier  builder module))
        (t (error "generate-node-ir: unknown GPU builtin ~a" bname))))))

