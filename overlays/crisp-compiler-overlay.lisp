;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;; ============================================================
;; DEVICE VECTORS (054-device-vectors)
;; ============================================================

;; ----------------------------------------------------------
;; 1. Type registration — extend initialize-crisp-types with
;;    the 33 device vector types (11 base × widths 2 3 4).
;;    Symbols are interned in :crisp-language so Crisp source
;;    files (read in that package) find them via gethash.
;; ----------------------------------------------------------

;; src/types/registry.lisp
(defun initialize-crisp-types ()
  "Populates *crisp-types* with built-in scalar types and device vector types."
  (clrhash *crisp-types*)
  ;; --- Scalar types (unchanged from original) ---
  (cl:let ((types
            `(;; Signed Integers
              (char ,#'llvm-int8-type 8 :signed-int)
              (short ,#'llvm-int16-type 16 :signed-int)
              (int ,(lambda () (llvm-int32-type)) 32 :signed-int)
              (long ,#'llvm-int64-type 64 :signed-int)
              ;; Unsigned Integers
              (uchar ,#'llvm-int8-type 8 :unsigned-int)
              (ushort ,#'llvm-int16-type 16 :unsigned-int)
              (uint ,(lambda () (llvm-int32-type)) 32 :unsigned-int)
              (ulong ,#'llvm-int64-type 64 :unsigned-int)
              ;; Floating Point
              (half ,#'llvm-half-type 16 :float)
              (bfloat16 ,#'llvm-bfloat-type 16 :float)
              (float ,#'llvm-float-type 32 :float)
              (double ,#'llvm-double-type 64 :float)
              ;; Void
              (void ,#'llvm-void-type 0 :void)
              (voidp ,(lambda () (llvm-pointer-type (llvm-int8-type) 0)) 64 :pointer)
              ;; Meta Types
              (type-spec ,#'llvm-void-type 0 :meta)
              ;; Pointer
              (c-pointer ,(lambda () (llvm-pointer-type (llvm-int8-type) 0)) 8 :pointer))))
    (loop for (name llvm-fn size category) in types
          do (setf (gethash name *crisp-types*)
               (make-crisp-type :name name
                                :llvm-type-fn llvm-fn
                                :size size
                                :category category))))
  ;; --- Device vector types ---
  ;; Each base type paired with its element-llvm-fn, element size (bits), and category.
  ;; Symbols are interned in :crisp-language so Crisp source lookups succeed.
  (let ((cl-pkg (find-package :crisp-language))
        (base-specs
         (list (list 'char   #'llvm-int8-type   8  :signed-int)
               (list 'uchar  #'llvm-int8-type   8  :unsigned-int)
               (list 'short  #'llvm-int16-type  16 :signed-int)
               (list 'ushort #'llvm-int16-type  16 :unsigned-int)
               (list 'int    (lambda () (llvm-int32-type)) 32 :signed-int)
               (list 'uint   (lambda () (llvm-int32-type)) 32 :unsigned-int)
               (list 'long   #'llvm-int64-type  64 :signed-int)
               (list 'ulong  #'llvm-int64-type  64 :unsigned-int)
               (list 'half   #'llvm-half-type   16 :float)
               (list 'float  #'llvm-float-type  32 :float)
               (list 'double #'llvm-double-type 64 :float))))
    (dolist (spec base-specs)
      (destructuring-bind (base-sym elem-fn elem-bits _cat) spec
        (declare (ignore _cat))
        (dolist (width '(2 3 4))
          (let* ((vec-name (intern (format nil "~a~a" (symbol-name base-sym) width) cl-pkg))
                 ;; Capture loop variables for the lambda
                 (fn   elem-fn)
                 (w    width))
            (setf (gethash vec-name *crisp-types*)
                  (make-crisp-type
                   :name        vec-name
                   :llvm-type-fn (lambda () (llvm-vector-type (funcall fn) w))
                   :size        (* elem-bits width)
                   :category    :device-vector))))))))

;; ----------------------------------------------------------
;; 2. ##(...) reader macro
;;    Registers #\# as a sub-dispatch of #\# so ##(...) is
;;    read as (crisp-vec-literal e1 e2 ...).
;; ----------------------------------------------------------

;; src/reader.lisp (new concept; lives here for now)
;; Both the defun and the registration must be inside eval-when so the
;; function exists at compile time when ASDF compiles this overlay to fasl.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun %read-device-vec-literal (stream char n)
    "Reader macro for ##(...). Transforms ##(e1 e2 ...) into
     (crisp-vec-literal e1 e2 ...) for the Crisp analyzer."
    (declare (ignore char n))
    (let ((elements (read stream t nil t)))
      (unless (listp elements)
        (error "##(...) device vector literal requires a list of elements, e.g. ##(1 2 3)"))
      (cons 'crisp-vec-literal elements)))
  (set-dispatch-macro-character #\# #\# #'%read-device-vec-literal))

;; ----------------------------------------------------------
;; 3. semantic-node-type — add semantic-device-vec-literal case
;; ----------------------------------------------------------

;; src/analysis/core.lisp
(defun semantic-node-type (node)
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
    (semantic-progn (semantic-progn-type node))
    (semantic-struct-member-update (semantic-struct-member-update-type node))
    (semantic-sizeof (semantic-sizeof-type node))))

;; src/analysis/core.lisp
(defun semantic-node-source-location (node)
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
    (semantic-progn (semantic-progn-source-location node))
    (semantic-struct-member-update (semantic-struct-member-update-source-location node))))

;; ----------------------------------------------------------
;; 4. Analysis — crisp-vec-literal handler
;; ----------------------------------------------------------

;; src/analysis/core.lisp
(defun %dvec-integral-type-p (type-sym)
  "Returns T if TYPE-SYM is a registered integer (signed or unsigned) Crisp type."
  (let ((ct (gethash type-sym *crisp-types*)))
    (and ct (member (crisp-type-category ct) '(:signed-int :unsigned-int)))))

(defun %dvec-float-type-p (type-sym)
  "Returns T if TYPE-SYM is a registered floating-point Crisp type."
  (let ((ct (gethash type-sym *crisp-types*)))
    (and ct (eq (crisp-type-category ct) :float))))

(defun %dvec-infer-comp-type (elem-node location)
  "Returns the component type symbol for a device vector element node.
   Plain int literals -> 'int, plain float literals -> 'float,
   typed literals -> their explicit type.
   Signals crisp-compiler-error for device-vector or unknown types."
  (let ((ty (semantic-node-type elem-node)))
    (cond
      ((eq ty 'int)   'int)
      ((eq ty 'float) 'float)
      ((and (gethash ty *crisp-types*)
            (not (eq (crisp-type-category (gethash ty *crisp-types*)) :device-vector)))
       ty)
      ((eq (crisp-type-category (gethash ty *crisp-types*)) :device-vector)
       (error 'crisp-compiler-error
              :message "##(...) elements cannot themselves be device vectors"
              :source-location location))
      (t
       (error 'crisp-compiler-error
              :message (format nil "##(...) first element has unrecognised type ~a" ty)
              :source-location location)))))

(defun %dvec-element-compatible-p (elem-type comp-type)
  "Returns T if ELEM-TYPE (of a subsequent element) is compatible with COMP-TYPE
   under the first-term coercion rule:
   - Exact match always passes.
   - Plain 'int is coercible to any integral comp-type.
   - Plain 'float is coercible to any float comp-type."
  (or (eq elem-type comp-type)
      (and (eq elem-type 'int)   (%dvec-integral-type-p comp-type))
      (and (eq elem-type 'float) (%dvec-float-type-p    comp-type))))

(defun analyze-crisp-dvec-literal (expr env context location)
  "Analyzes (crisp-vec-literal e1 e2 ...) — produced by the ##(...) reader macro.
   Infers the component type from the first element, validates width (2-4) and
   element type compatibility, then returns a semantic-device-vec-literal node."
  (let* ((raw-elements (rest expr))
         (width        (length raw-elements)))
    ;; Width check
    (unless (member width '(2 3 4))
      (error 'crisp-compiler-error
             :message (format nil "##(...) must have 2, 3, or 4 elements; got ~a" width)
             :source-location location))
    ;; Analyze all elements
    (let* ((analyzed  (mapcar (lambda (e) (analyze-expression e env context location))
                              raw-elements))
           (comp-type (%dvec-infer-comp-type (first analyzed) location)))
      ;; Validate remaining elements
      (dolist (elem (rest analyzed))
        (let ((et (semantic-node-type elem)))
          (unless (%dvec-element-compatible-p et comp-type)
            (error 'crisp-compiler-error
                   :message (format nil "##(...) has mixed element types: component type is ~a but got ~a"
                                    comp-type et)
                   :source-location location))))
      ;; Look up the NxT type (e.g. float4, int3) in :crisp-language
      (let* ((vec-name (intern (format nil "~a~a" (symbol-name comp-type) width)
                               (find-package :crisp-language)))
             (vec-ct   (gethash vec-name *crisp-types*)))
        (unless vec-ct
          (error 'crisp-compiler-error
                 :message (format nil "##(...) no registered device vector type ~a" vec-name)
                 :source-location location))
        (log:debug "analyze-crisp-dvec-literal: ~a width=~a comp=~a -> ~a"
                   expr width comp-type vec-name)
        (make-semantic-device-vec-literal
         :vec-type     vec-name
         :element-type comp-type
         :width        width
         :elements     analyzed
         :source-location location)))))

;; src/analysis/core.lisp
;; Redefine to include crisp-vec-literal alongside the built-in registrations.
(defun initialize-expression-analyzers ()
  "Registers all expression analyzers, including device vector support."
  (clrhash *expression-analyzers*)
  (register-ops-analyzers)
  (register-control-analyzers)
  (register-struct-analyzers)
  (setf (gethash 'crisp-vec-literal *expression-analyzers*)
        #'analyze-crisp-dvec-literal))

;; ----------------------------------------------------------
;; 5. Codegen — generate-node-ir for semantic-device-vec-literal
;; ----------------------------------------------------------

;; src/codegen.lisp
(defun %dvec-coerce-element-ir (elem-node comp-type comp-llvm-type builder module var-env di-builder di-scope location-map)
  "Generates the LLVM value for one element of a ##(...) literal.
   If the element type already matches COMP-TYPE, generates normally.
   If the element is a plain-int or plain-float constant being coerced to
   a different integral/float type, produces the correctly-typed constant
   directly without emitting a conversion instruction."
  (let ((elem-type (semantic-node-type elem-node)))
    (if (eq elem-type comp-type)
        ;; Exact match — generate normally
        (nth-value 0 (generate-node-ir elem-node builder module var-env
                                       di-builder di-scope location-map))
        ;; Coercion needed — only constant literals are supported here
        (if (typep elem-node 'semantic-literal)
            (let* ((val (semantic-literal-value elem-node))
                   (ct  (gethash comp-type *crisp-types*)))
              (cond
                ((member (crisp-type-category ct) '(:signed-int :unsigned-int))
                 (llvm-const-int comp-llvm-type val nil))
                ((eq (crisp-type-category ct) :float)
                 (llvm-const-real comp-llvm-type (coerce val 'double-float)))
                (t
                 (error "##(...): cannot coerce element of type ~a to ~a" elem-type comp-type))))
            (error "##(...): non-literal element of type ~a cannot be coerced to ~a"
                   elem-type comp-type)))))

(defmethod generate-node-ir ((node semantic-device-vec-literal) builder module var-env di-builder di-scope location-map)
  "Generates LLVM IR for a ##(...) device vector literal via insertelement chain."
  (let* ((vec-type-sym  (semantic-device-vec-literal-vec-type node))
         (elem-type-sym (semantic-device-vec-literal-element-type node))
         (elements      (semantic-device-vec-literal-elements node))
         (llvm-vec-type (crisp-type-to-llvm-type vec-type-sym module))
         (llvm-elem-type (crisp-type-to-llvm-type elem-type-sym module))
         ;; Start from an undef vector and fold insertions left-to-right
         (result (llvm-get-undef llvm-vec-type)))
    (log:debug "generate-node-ir dvec: ~a" vec-type-sym)
    (loop for elem-node in elements
          for i from 0
          do (let* ((elem-ir (%dvec-coerce-element-ir elem-node elem-type-sym llvm-elem-type
                                                      builder module var-env
                                                      di-builder di-scope location-map))
                    (idx-ir  (llvm-const-int (llvm-int32-type) i nil))
                    (name    (format nil "dvec_~a" i)))
               (setf result
                     (llvm-build-insert-element builder result elem-ir idx-ir name))))
    (values result nil)))



