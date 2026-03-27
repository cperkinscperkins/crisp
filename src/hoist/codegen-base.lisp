(in-package :crisp.hoist)

(defun crisp-type-to-cpp-type (crisp-type)
  "Convert a Crisp type to C++ type string."
  (cond
   ((symbolp crisp-type)
     (case crisp-type
       (int "int")
       (uint "unsigned int")
       (long "long")
       (ulong "unsigned long")
       (float "float")
       (double "double")
       (voidp "void*")
       (t (string-downcase (symbol-name crisp-type)))))
   ((consp crisp-type)
     ;; Handle complex types like (cell int ...)
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
        (format stream "};~%~%" type-str)))))

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


;; moving here


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