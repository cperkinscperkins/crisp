;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.

;; src/types/registry.lisp
(in-package :crisp.compiler)

;; Global Compiler State
;; =====================

(defvar *generic-functions* (make-hash-table :test 'equal)
        "Registry of generic function templates (functions with &optional or &key parameters) 
   that are instantiated lazily. Key: function name symbol. Value: generic-function-def struct.")

(defvar *function-table* (make-hash-table)
        "A hash table mapping function names (symbols) to a list of
  FUNCTION-SIGNATURE structs. This supports overloading.")

(defvar *differentiable-functions* (make-hash-table :test 'eq)
  "Registry of user def-functions for which a _GRAD backward companion has been generated.
Maps function-name -> (:bkwd-name sym :n-float-params N :n-return M).")

(defvar *foreign-functions* (make-hash-table :test 'eq)
  "Endeavor 122 (FFI). Registry of functions declared via def-foreign-function.
Maps the function-name symbol -> the verbatim C name string to emit (no Crisp
mangling). Presence here also tells codegen to give the external declaration the
target-appropriate calling convention so it matches the linked .bc definition.")


(defvar *call-graph* nil
        "A hash table representing the call graph of functions.
  Keys are caller function names, values are lists of callee names.")

(defvar *template-instantiator-fn* nil
        "Hook for template instantiation.
   Called as (funcall *template-instantiator-fn* name arg-types callback).
   The callback is (funcall callback form location).")

(defvar *template-registry* (make-hash-table)
        "Maps template names (symbols) to a LIST of template-data structs.
This supports overloading templates by arity or other factors.")

(defvar *instantiated-templates* (make-hash-table :test 'equal)
        "Tracks which specializations have already been generated.")

(defvar *side-channel-originators* '(make-scratch-cell make-scratch-vector make-scratch-matrix make-scratch-tensor)
        "A list of function names that trigger the implicit side-channel argument passing mechanism.")

(defvar *originator-functions* nil
        "A hash table containing the names of all functions that directly use a side-channel originator.")

(defvar *implicit-arg-map* (make-hash-table)
        "A hash table mapping function names to the implicit side-channel arguments they require.")

(defvar *runtime-checks-enabled* nil
        "If true, runtime assertions (r-t-assert) are compiled.")

;;; =========================================================
;;; Branded Types - Infrastructure
;;; =========================================================


(defvar *brand-definitions* (make-hash-table :test 'equal)
        "Maps (brand-name . struct-type) to brand-definition records.
   Populated when def-struct / def-record with brand declarations are processed.")

;;; =========================================================
;;; --differentiate flag support (branded types prerequisite)
;;; =========================================================

(defvar *differentiate-p* nil
        "If T, enable differentiation mode. Activates branded type enforcement
   for brands declared with :enforce :diff (the default).")


;; (defvar *current-module* nil) -> Moved to session
(define-symbol-macro *current-module* (compiler-session-module *compiler-session*))
;; (defvar *current-builder* nil) -> Moved to session
(define-symbol-macro *current-builder* (compiler-session-builder *compiler-session*))
;; (defvar *current-di-builder* nil) -> Moved to session
(define-symbol-macro *current-di-builder* (compiler-session-di-builder *compiler-session*))
;; (defvar *current-di-compile-unit* nil) -> Moved to session
(define-symbol-macro *current-di-compile-unit* (compiler-session-di-compile-unit *compiler-session*))
;; (defvar *current-location-map* nil) -> Moved to session
(define-symbol-macro *current-location-map* (compiler-session-location-map *compiler-session*))


(defvar *compiled-kernels* nil "List of kernel names (symbols) compiled in the current session.")
(defvar *emit-metadata* nil "If T, generate .metacrisp file.")


;; Type System Globals
;; ===================

(defvar *target-backend* :generic
        "The active target backend for compilation.
   Supported values: :generic, :cpu, :spirv, :ptx.")

;; Endeavor 137 — target architecture (--ir-target-arch).  See docs/topology.md for the ID
;; table (sm_80/sm_86/sm_89/sm_90/sm_100/sm_120 for NVIDIA; gen12/dg2/pvc/xe2 for Intel).
(defvar *ir-target-arch* nil
        "The raw --ir-target-arch value as a keyword (e.g. :sm_90, :dg2), or NIL if unset.
   Use (resolved-target-arch) for the effective arch (applies per-backend defaults).")

(defun resolved-target-arch ()
  "The effective target architecture keyword.  When --ir-target-arch is unset it defaults
   per backend (Endeavor 137): sm_80 for :ptx, dg2 for :spirv, NIL otherwise."
  (or *ir-target-arch*
      (case *target-backend*
        (:ptx   :sm_80)
        (:spirv :dg2)
        (t nil))))

(defun %arch-name-string (arch)
  (and arch (string-downcase (symbol-name arch))))

(defun %arch-has-prefix-p (arch prefix)
  (let ((name (%arch-name-string arch)))
    (and name (>= (length name) (length prefix))
         (string= (subseq name 0 (length prefix)) prefix))))

(defun %arch-vendor (arch)
  "Vendor of an arch keyword: :nvidia for sm_*, :intel for gen12/dg2/pvc/xe2, else NIL."
  (cond ((%arch-has-prefix-p arch "sm_") :nvidia)
        ((member arch '(:gen12 :dg2 :pvc :xe2)) :intel)
        (t nil)))

(defun %arch-sm-number (arch)
  "Numeric SM level for an sm_NN[a|f] arch (:sm_90 / :sm_90a -> 90), or NIL for non-NVIDIA.
   Tolerates the architecture-specific `a`/`f` suffix (junk-allowed strips it)."
  (when (%arch-has-prefix-p arch "sm_")
    (ignore-errors (parse-integer (%arch-name-string arch) :start 3 :junk-allowed t))))

(defun %arch-supports-block-p (arch)
  "T if ARCH can realize :mode :block: NVIDIA TMA needs sm_90+; Intel LSC 2D block loads
   need DG2 or newer (i.e. any Intel arch except Gen12)."
  (case (%arch-vendor arch)
    (:nvidia (let ((n (%arch-sm-number arch))) (and n (>= n 90))))
    (:intel  (not (eq arch :gen12)))
    (t nil)))

(defun ptx-compute-capability-string ()
  "The llc -mcpu string for the PTX backend, from --ir-target-arch (default sm_80).
   Endeavor 137: a bare sm_90 request is upgraded to sm_90a — Hopper's architecture-specific
   features (TMA cp.async.bulk.tensor, wgmma) are gated behind the `a` target variant, and a
   plain `.target sm_90` PTX JIT-rejects them at cuModuleLoad.  An explicit sm_90a/sm_90f (or
   any other sm_*) passes through unchanged."
  (let* ((arch (or *ir-target-arch* :sm_80))
         (name (if (%arch-has-prefix-p arch "sm_") (%arch-name-string arch) "sm_80")))
    (if (string= name "sm_90") "sm_90a" name)))

(defvar *crisp-types* (make-hash-table)
        "A hash table mapping type names (symbols) to CRISP-TYPE structs.")

(defvar *crisp-structs* (make-hash-table)
        "A hash table mapping struct names to CRISP-STRUCT-DEFINITION structs.")

(defvar *crisp-type-aliases* (make-hash-table)
        "A hash table mapping alias symbols to their target type specifiers.")

(defvar *crisp-template-aliases* (make-hash-table)
        "A hash table mapping template alias names to (params . body-type-spec).")

;; Recursive / Multipass Support Globals
(defvar *defer-struct-validation* nil
        "If T, register-struct-definition will not error on unknown types but instead queue the definition.")

(defvar *pending-struct-definitions* nil
        "A list of (name members category) tuples that are waiting for types to be defined.")


(defvar *crisp-enums* (make-hash-table :test 'eq))

(defvar *expression-analyzers* (make-hash-table)
        "A dispatch table mapping operator symbols to their analyzer functions.")

(defmacro def-expression-analyzer (operator handler-fn)
  "A helper macro to register an operator's analyzer function."
  `(setf (gethash ',operator *expression-analyzers*) ',handler-fn))



(defvar *inert-functions* (make-hash-table :test 'eq)
  "Set of user functions intentionally skipped from _GRAD generation because
   they have no differentiable parameters (their gradient is identically
   zero). Calls to these are gradient-inert and are silently skipped during
   the AD backward walk -- in contrast to genuinely non-differentiable
   functions, whose _GRAD generation errored and which must still error if
   called from a differentiable kernel. Cleared per-module in
   analyze-signatures-pass.")

(defvar *fn-normalized-info* (make-hash-table :test 'eq)
  "Per-module map: function name -> plist (:params :body :entry-point-p),
   captured during analyze-signatures-pass from the macro-expanded
   def-function forms. Consumed by infer-param-uniformity. Cleared per-module.")

(defvar *inferred-param-uniformity* (make-hash-table :test 'eq)
  "Per-module map: function name -> alist (param-name . :uniform|:divergent|
   :unknown), the result of infer-param-uniformity. Applied (upgrade-only) to
   the body-compilation environment by inject-implicit-arguments. Cleared
   per-module.")

(defvar *uni-meet-table* nil
  "Dynamic: hash callee-name -> (hash param-name -> accumulated meet state).
   Bound for the duration of infer-param-uniformity.")

;; Initialization
;; ==============

(defun initialize-crisp-types ()
  "Populates *crisp-types* with built-in scalar types and device vector types."
  (clrhash *crisp-types*)
  ;; --- Scalar types (unchanged from original) ---
  (let ((types
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
          (let* ((vec-name-cl   (intern (format nil "~a~a" (symbol-name base-sym) width) cl-pkg))
                 ;; Also intern in :crisp.compiler so cell/template machinery can resolve.
                 ;; Use explicit package (not *package*) since this fn may be called with any *package*.
                 (vec-name-comp (intern (format nil "~a~a" (symbol-name base-sym) width)
                                       (find-package :crisp.compiler)))
                 ;; Capture loop variables for the lambda
                 (fn   elem-fn)
                 (w    width)
                 (entry (make-crisp-type
                         :name        vec-name-cl
                         :llvm-type-fn (lambda () (llvm-vector-type (funcall fn) w))
                         :size        (* elem-bits width)
                         :category    :device-vector)))
            (setf (gethash vec-name-cl   *crisp-types*) entry)
            (setf (gethash vec-name-comp *crisp-types*) entry)))))))
