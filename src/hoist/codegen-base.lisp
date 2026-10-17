(in-package :crisp.hoist)



(defun crisp-type-to-cpp-type (crisp-type)
  "Convert a Crisp type to a C++ type string.
   Uses string-equal for package-agnostic symbol comparison so that
   symbols interned in any package (e.g. :crisp.hoist.l0 during metacrisp
   parsing) are handled correctly.
   Maps long→int64_t, ulong→uint64_t (64-bit on all platforms).
   Fallback: hyphens converted to underscores (safe for C++ identifiers).
   For (array T N): resolves element type."
  (cond
    ((null crisp-type) "void")
    ((symbolp crisp-type)
     (let ((name (symbol-name crisp-type)))
       (cond
         ((string-equal name "INT")    "int")
         ((string-equal name "UINT")   "unsigned int")
         ((string-equal name "LONG")   "int64_t")
         ((string-equal name "ULONG")  "uint64_t")
         ((string-equal name "FLOAT")  "float")
         ((string-equal name "DOUBLE") "double")
         ((string-equal name "BFLOAT16") "uint16_t")
         ((string-equal name "HALF")   "uint16_t")
         ((string-equal name "CHAR")   "char")
         ((string-equal name "UCHAR")  "unsigned char")
         ((string-equal name "SHORT")  "short")
         ((string-equal name "USHORT") "unsigned short")
         ((string-equal name "BOOL")   "bool")
         ((string-equal name "VOIDP")  "void*")
         (t (substitute #\_ #\- (string-downcase name))))))
    ;; (array T N) — resolve to element C++ type
    ((and (consp crisp-type)
          (symbolp (first crisp-type))
          (string-equal (symbol-name (first crisp-type)) "ARRAY"))
     (crisp-type-to-cpp-type (second crisp-type)))
    ((consp crisp-type)
     (format nil "/* TODO: ~a */" crisp-type))
    (t (format nil "/* UNKNOWN: ~a */" crisp-type))))

(defun format-cpp-identifier (lisp-symbol)
  "Convert Lisp symbol to C++-safe identifier."
  (let ((name (if (symbolp lisp-symbol)
                  (symbol-name lisp-symbol)
                  (string lisp-symbol))))
    (substitute #\_ #\- (string-downcase name))))


(defun %dvec-parse (type-sym)
  "If TYPE-SYM names a device vector type (e.g. USHORT2, FLOAT4), returns
   (values base-name width) where base-name is a lowercase string (e.g. \"ushort\")
   and width is an integer (2, 3, or 4).  Returns NIL if not a device vector type."
  (when (symbolp type-sym)
    (let* ((name (string-downcase (symbol-name type-sym)))
           (len (length name)))
      (when (> len 1)
        (let ((last-ch (char name (1- len))))
          (when (member last-ch (list #\2 #\3 #\4))
            (let* ((width (digit-char-p last-ch))
                   (base (subseq name 0 (1- len))))
              (when (member base
                            '("char" "uchar" "short" "ushort" "int" "uint"
                              "long" "ulong" "half" "float" "double")
                            :test #'string=)
                (values base width)))))))))

(defun %dvec-cpp-scalar-type (base-name)
  "Map a Crisp scalar base name (e.g. \"ushort\") to a C++ <cstdint> type string."
  (cond
    ((string= base-name "char")   "int8_t")
    ((string= base-name "uchar")  "uint8_t")
    ((string= base-name "short")  "int16_t")
    ((string= base-name "ushort") "uint16_t")
    ((string= base-name "int")    "int32_t")
    ((string= base-name "uint")   "uint32_t")
    ((string= base-name "long")   "int64_t")
    ((string= base-name "ulong")  "uint64_t")
    ((string= base-name "half")   "uint16_t")
    ((string= base-name "float")  "float")
    ((string= base-name "double") "double")
    (t base-name)))

(defun %emit-dvec-typedef (stream type-sym)
  "Emit a C++ struct definition for a device vector type (e.g. ushort2).
   Uses <cstdint> types for the members.
   Uses 'struct NAME { };' (not typedef struct) so that the type name is in scope
   inside the body, which is required for the friend operator<< declaration.
   The operator<< prints space-separated components, matching the HOIST-EXPECT
   substring-match convention."
  (multiple-value-bind (base width) (%dvec-parse type-sym)
    (when base
      (let* ((type-str (string-downcase (symbol-name type-sym)))
             (scalar-type (%dvec-cpp-scalar-type base))
             (member-names (subseq (list "x" "y" "z" "w") 0 width)))
        (format stream "struct ~a {~%" type-str)
        (dolist (m member-names)
          (format stream "    ~a ~a;~%" scalar-type m))
        (format stream "    friend std::ostream& operator<<(std::ostream& os, const ~a& v) {~%" type-str)
        (let ((firstp t))
          (dolist (m member-names)
            (if firstp
                (format stream "        os << v.~a" m)
                (format stream " << \" \" << v.~a" m))
            (setf firstp nil)))
        (format stream ";~%")
        (format stream "        return os;~%")
        (format stream "    }~%")
        (format stream "};~%~%")))))

(defun %collect-dvec-types (declared-sig aliases)
  "Collect all distinct device vector type symbols used in DECLARED-SIG and ALIASES.
   Checks cell element types from aliases and direct scalar param types.
   Returns a deduplicated list ordered by first appearance."
  (let ((seen (make-hash-table :test #'equal))
        (result '()))
    (flet ((add-if-dvec (type-sym)
             (when (and (symbolp type-sym)
                        (%dvec-parse type-sym)
                        (not (gethash (symbol-name type-sym) seen)))
               (setf (gethash (symbol-name type-sym) seen) t)
               (push type-sym result))))
      ;; From aliases: (def-type NAME (CELL TYPE ...)) — extract cell element type
      (dolist (alias aliases)
        (when (and (listp alias) (>= (length alias) 3))
          (let ((cell-spec (third alias)))
            (when (cell-type-p cell-spec)
              (add-if-dvec (second cell-spec))))))
      ;; From declared-sig: direct scalar params whose type is a device vector
      (dolist (param declared-sig)
        (add-if-dvec (getf param :type))))
    (nreverse result)))

(defun generate-cpp-dvec-typedefs (stream dvec-types)
  "Emit C++ typedef structs for all device vector types in DVEC-TYPES.
   Called from generate-l0-launcher after generate-cpp-typedefs."
  (when dvec-types
    (format stream "// Device vector type definitions~%")
    (dolist (type-sym dvec-types)
      (%emit-dvec-typedef stream type-sym))))



;; Helper function to check if a type is a cell
(defun resolve-type-alias (type aliases)
  (if (symbolp type)
      (let ((alias-def (find type aliases :key #'second)))
        (if alias-def
            (resolve-type-alias (third alias-def) aliases)
            type))
      type))

;; Helper function to check if a type is a cell
(defun cell-type-p (param-type)
  "Check if a parameter type is a cell type"
  (and (listp param-type)
       (symbolp (first param-type))
       (string-equal (symbol-name (first param-type)) "CELL")))

;; Helper function to extract base type from cell
(defun cell-base-type (param-type)
  "Extract the base type from a cell type like (cell int ...)"
  (when (cell-type-p param-type)
        (second param-type)))

;;; ------------------------------------------------------------------------------------------
;;; Helpers shared by BOTH hoisters (refactor-oct, 2026-10-16).  Each was defined twice --
;;; identically, or differing only in docstrings / an -l0 suffix -- in src/hoist-l0/main.lisp and
;;; src/hoist-cuda/main.lisp.  Moved here verbatim (L0's docstrings where they were fuller) and
;;; exported, so the two hoisters cannot drift apart again.
;;; ------------------------------------------------------------------------------------------

(defvar *mma-test-dims* nil "(M N K) when --mma-test=M,N,K is passed to the hoist; else NIL.")

(defvar *mma-input-counter* 0 "Per-kernel input-tensor counter for A(0)/B(1) role assignment.")

(defvar *mma-scale* 1 "Reference scale factor (--mma-scale=S): expected C = S·(A·B).  Default 1.
   Used by kernels that fire the MMA more than once per fragment (e.g. accum-op body).")

(defvar *hoist-current-structs* nil
        "Dynamic variable: list of (def-struct NAME ...) forms from the current
   metacrisp :structs section.  Bound by each hoister's launcher generator.")

(defun %mma-out-dir-p (dir)
  "T if the param direction is an output (&out)."
  (and dir (search "out" (string-downcase (string dir)))))

(defun %array-type-p (type)
  "Returns T if TYPE is an (array T N) form."
  (and (consp type)
       (symbolp (first type))
       (string-equal (symbol-name (first type)) "ARRAY")))

(defun %array-element-type (array-type)
  "Returns the element type T from an (array T N) form."
  (second array-type))

(defun %array-size (array-type)
  "Returns the compile-time size N from an (array T N) form."
  (third array-type))

(defun %struct-base-type (param-type)
  "Extract the base struct name from PARAM-TYPE (symbol or list form)."
  (if (symbolp param-type) param-type (first param-type)))

(defun record-base-type (type)
  "Extract the base record type symbol from a plain symbol or a list-form like (V-POINT EARNESTNESS 3.0)."
  (if (symbolp type) type (first type)))

(defun find-record-def (type records)
  "Find the def-record entry matching TYPE in RECORDS.
   TYPE may be a plain symbol or a parameterized list form."
  (let ((base (record-base-type type)))
    (find base records
      :key #'second
      :test (lambda (a b) (string-equal (symbol-name a) (symbol-name b))))))

(defun record-type-p (type records)
  "Returns true if TYPE refers to a def-record in RECORDS."
  (and (not (cell-type-p type))
       (not (null (find-record-def type records)))))

(defun tensor-type-p (param-type)
  "Returns T if PARAM-TYPE is a tensor/vector/matrix type specifier."
  (and (consp param-type)
       (symbolp (first param-type))
       (member (symbol-name (first param-type))
               '("TENSOR" "VECTOR" "MATRIX") :test #'string-equal)))

(defun %tensor-compact-extents-strides (n extents-list)
  "Returns (values extents strides) for a compact N-dim tensor.
   Strides are in elements; innermost stride = 1."
  (let* ((extents (copy-list extents-list))
         (strides (make-list n :initial-element 1)))
    (loop for k from (- n 2) downto 0 do
            (setf (nth k strides) (* (nth (1+ k) strides) (nth (1+ k) extents))))
    (values extents strides)))

(defun %dispatch-sym-to-cpp-var (sym)
  "Convert a dispatch param symbol (e.g. 'WIDTH or 'width) to C++ variable name 'width_arg'."
  (format nil "~a_arg" (substitute #\_ #\- (string-downcase (symbol-name sym)))))

(defun %find-struct-def (name)
  "Find (def-struct NAME ...) in *hoist-current-structs*."
  (find name *hoist-current-structs*
        :test (lambda (n f)
                (and (consp f)
                     (symbolp (first f))
                     (string-equal (symbol-name (first f)) "DEF-STRUCT")
                     (symbolp (second f))
                     (string-equal (symbol-name n) (symbol-name (second f)))))))

(defun struct-type-p (type)
  "Returns T if TYPE names a def-struct in *hoist-current-structs*."
  (let ((base (cond ((symbolp type) type)
                    ((and (consp type) (symbolp (first type))) (first type))
                    (t nil))))
    (and base (not (null (%find-struct-def base))))))

(defun %struct-emit-fields (stream var-path members aliases)
  "Recursively emit C++ field assignments for a struct variable."
  (dolist (member members)
    (let* ((field-name     (first member))
           (field-type-raw (second member))
           (field-name-cpp (format-cpp-identifier field-name))
           (field-path     (format nil "~a.~a" var-path field-name-cpp))
           (field-type     (resolve-type-alias field-type-raw aliases)))
      (cond
       ((%array-type-p field-type)
        (let* ((elem-type (%array-element-type field-type))
               (arr-size  (%array-size field-type))
               (elem-str  (crisp-type-to-cpp-type elem-type)))
          (format stream "    for (int _i = 0; _i < ~a; _i++) ~a[_i] = (~a)_i;~%"
                  arr-size field-path elem-str)))
       ((struct-type-p field-type)
        (let* ((nested-def     (%find-struct-def field-type))
               (nested-members (cddr nested-def)))
          (%struct-emit-fields stream field-path nested-members aliases)))
       (t
        (let* ((cpp-type (crisp-type-to-cpp-type field-type))
               (init-val (cond ((string= cpp-type "float")  "1.0f")
                               ((string= cpp-type "double") "1.0")
                               (t "1"))))
          (format stream "    ~a = ~a;~%" field-path init-val)))))))
