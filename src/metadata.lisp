;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.

;; src/metadata.lisp
(in-package :crisp.compiler)

;;; =========================================================
;;; Metadata Generation (.metacrisp)
;;; =========================================================

(defvar *emit-metadata* nil
        "If T, the compiler will generate a .metacrisp sidecar file for each orchestration/kernel.")

;;; Validators
;;; ----------

(defun validate-metadata-def-type (metadata-path type-name target-type)
  (unless (probe-file metadata-path)
    (log:error "Metadata file not found: ~a" metadata-path)
    (return-from validate-metadata-def-type nil))

  (let ((content (uiop:read-file-forms metadata-path)))
    (let* ((aliases-form (find :aliases content :key #'car))
           (definitions (cdr aliases-form)))
      (dolist (def definitions)
        (when (and (string-equal (symbol-name (first def)) "def-type")
                   (string-equal (symbol-name (second def)) (symbol-name type-name))
                   (string-equal (symbol-name (third def)) (symbol-name target-type)))
              (return-from validate-metadata-def-type t)))

      (log:error "Metadata Validation Failed: Could not find alias ~a -> ~a" type-name target-type)
      nil)))

(defun validate-01-aliases (metadata-path)
  (validate-metadata-def-type metadata-path 'iii 'int))

(defun validate-struct-presence (metadata-path expected-structs &key (unexpected-structs nil))
  (unless (probe-file metadata-path)
    (log:error "Metadata file not found: ~a" metadata-path)
    (return-from validate-struct-presence nil))

  (let ((content (uiop:read-file-forms metadata-path)))
    (let* ((structs-form (find :structs content :key #'car))
           (definitions (cdr structs-form))
           (found-names (mapcar #'second definitions)))
      (dolist (un unexpected-structs)
        (when (member (symbol-name un) found-names :test #'string-equal :key #'symbol-name)
              (log:error "Validation Failed: Found unexpected struct ~a" un)
              (return-from validate-struct-presence nil)))

      (let ((current-ptr found-names))
        (dolist (ex expected-structs)
          (let ((pos (position (symbol-name ex) current-ptr :test #'string-equal :key #'symbol-name)))
            (unless pos
              (log:error "Validation Failed: Expected struct ~a not found (or out of order). Remaining: ~a" ex current-ptr)
              (return-from validate-struct-presence nil))
            (setf current-ptr (subseq current-ptr (1+ pos))))))
      t)))

(defun validate-04-basic-struct (metadata-path)
  (validate-struct-presence metadata-path '(point) :unexpected-structs '(skipped)))

(defun validate-06-nested-structs (metadata-path)
  (validate-struct-presence metadata-path '(point rect)))

;;; Dependency Collection
;;; ---------------------

(defun collect-kernel-dependencies (kernel-names)
  (let ((used-aliases (make-hash-table :test 'eq))
        (used-structs (make-hash-table :test 'eq))
        (seen-types (make-hash-table :test 'equal))
        (work-list nil))

    (dolist (k-name kernel-names)
      (let ((sigs (gethash k-name *function-table*)))
        (let ((declared-types (gethash k-name *kernel-declared-signatures*)))
          (if declared-types
              (dolist (param-pair declared-types)
                (let ((t-spec (if (consp param-pair) (cdr param-pair) param-pair)))
                  (push t-spec work-list)))
              (dolist (sig sigs)
                (dolist (param-def (function-signature-parameters sig))
                  (let ((param-type (parameter-def-type param-def)))
                    (push param-type work-list))))))))

    (loop while work-list do
            (let ((type-spec (pop work-list)))
              (unless (gethash type-spec seen-types)
                (setf (gethash type-spec seen-types) t)
                (when (and (symbolp type-spec) (string-equal (symbol-name type-spec) "&OUT")))
                (cond
                 ((symbolp type-spec)
                   ;; Handle type aliases (def-type)
                   (let ((target (gethash type-spec *crisp-type-aliases*)))
                     (when target
                           (setf (gethash type-spec used-aliases) t)
                           (push target work-list)))

                   ;; Resolve derived types to their base type for struct lookup
                   ;; This ensures the base struct is included in metadata, not the derived type
                   (let* ((base-type (get-type-base type-spec))
                          ;; Package-agnostic struct lookup
                          (def-direct (gethash base-type *crisp-structs*))
                          (def-alt (when (and (not def-direct) (symbolp base-type))
                                     (gethash (intern (symbol-name base-type)
                                                      (find-package :crisp-language))
                                              *crisp-structs*)))
                          (def (or def-direct def-alt))
                          ;; Use the actual key that was found
                          (struct-key (if def-direct base-type
                                        (intern (symbol-name base-type)
                                                (find-package :crisp-language)))))
                     (when def
                           ;; Register the BASE struct, not the derived type
                           (setf (gethash struct-key used-structs) t)
                           (loop for (name m-type) in (crisp-struct-definition-members def)
                                 do (push m-type work-list)))))
                 ((consp type-spec)
                   (dolist (sub (rest type-spec))
                     (push sub work-list))
                   (let* ((canon (canonicalize-type-specifier type-spec))
                          (base (first canon))
                          (args (rest canon)))
                     (when (symbolp base)
                           (let ((mangled (mangle-template-struct-name base args)))
                             (when (and (gethash mangled *crisp-structs*)
                                        (not (string-equal (symbol-name mangled) "STORAGE"))
                                        (not (alexandria:starts-with-subseq "CELL_" (symbol-name mangled))))
                                   (push mangled work-list))))))))))
    (values used-aliases used-structs)))

(defun sort-structs-by-dependency (struct-names)
  (let ((sorted nil)
        (visited (make-hash-table :test 'eq))
        (temp-visited (make-hash-table :test 'eq)))

    (labels ((visit (name)
                    (cond
                     ((gethash name temp-visited)
                       (log:warn "Circular struct dependency detected involving ~a" name))
                     ((not (gethash name visited))
                       (setf (gethash name temp-visited) t)
                       (let ((def (gethash name *crisp-structs*)))
                         (when def
                               (dolist (member (crisp-struct-definition-members def))
                                 (let ((type (second member)))
                                   (let ((base-type (resolve-type-alias type)))
                                     (loop while (and (consp base-type)
                                                      (or (eq (first base-type) 'cell)
                                                          (eq (first base-type) 'vector)
                                                          (eq (first base-type) 'array)))
                                           do (setf base-type (if (consp (second base-type))
                                                                  (second base-type)
                                                                  (resolve-type-alias (second base-type)))))
                                     (when (and (symbolp base-type) (gethash base-type *crisp-structs*))
                                           (visit base-type)))))))
                       (setf (gethash name temp-visited) nil)
                       (setf (gethash name visited) t)
                       (push name sorted)))))
      (dolist (n struct-names)
        (visit n)))
    (nreverse sorted)))

;;; Serialization
;;; -------------

(defun strip-package-qualifiers (type-spec)
  "Recursively strips package qualifiers from symbols in a type specification.
   Returns the type spec with bare symbol names (no CRISP.COMPILER:: prefixes).
   
   Examples:
     CRISP.COMPILER:INT -> INT
     (CRISP.COMPILER:CELL CRISP.COMPILER:FLOAT :GLOBAL :READ-WRITE) 
       -> (CELL FLOAT :GLOBAL :READ-WRITE)
     (C-POINTER ADDRESS-SPACE GLOBAL) -> (C-POINTER ADDRESS-SPACE GLOBAL)"
  (cond
   ;; Nil/empty
   ((null type-spec) nil)

   ;; Symbol: strip package, return just name as unqualified symbol
   ((symbolp type-spec)
     (intern (symbol-name type-spec) :crisp-language))

   ;; String: return as-is
   ((stringp type-spec) type-spec)

   ;; Number: return as-is
   ((numberp type-spec) type-spec)

   ;; List: recursively process each element
   ((consp type-spec)
     (mapcar #'strip-package-qualifiers type-spec))

   ;; Fallback
   (t type-spec)))

(defun print-without-packages (obj stream)
  "Prints an object to stream without any package qualifiers.
   Uses *package* context to avoid printing qualifiers."
  (let ((*package* (find-package :crisp-language))
        (*print-case* :downcase))
    (prin1 obj stream)))

(defun serialize-aliases (stream aliases-hash)
  (format stream "(:aliases~%")
  (let ((aliases (alexandria:hash-table-keys aliases-hash)))
    (setf aliases (sort aliases #'string< :key #'symbol-name))
    (dolist (alias aliases)
      (let ((target (gethash alias *crisp-type-aliases*)))
        (format stream "  (def-type ~a ~a)~%"
          (strip-package-qualifiers alias)
          (strip-package-qualifiers target)))))
  (format stream "  )~%~%"))

(defun serialize-structs (stream structs-hash)
  (format stream "(:structs~%")
  (let ((struct-names (alexandria:hash-table-keys structs-hash)))
    (let ((sorted-names (sort-structs-by-dependency struct-names)))
      (dolist (name sorted-names)
        (let ((def (gethash name *crisp-structs*)))
          (when def
                (format stream "  (def-struct ~a" (strip-package-qualifiers name))
                (dolist (m (crisp-struct-definition-members def))
                  (format stream " (~a ~a)"
                    (strip-package-qualifiers (first m))
                    (strip-package-qualifiers (second m))))
                (format stream ")~%"))))))
  (format stream "  )~%~%"))

(defun extract-defined-kernels (forms)
  (let ((names nil))
    (dolist (f forms)
      (when (and (consp f) (eq (first f) 'def-kernel))
            (push (second f) names)))
    (nreverse names)))

;;; Main Entry Point
;;; ----------------
#|
(defun generate-metadata-for-file (input-path output-path &key (output-targets nil) (source-file nil) (forms nil))
  (let ((kernel-names (if forms
                          (extract-defined-kernels forms)
                          (alexandria:hash-table-keys *function-table*)))
        (generated-files nil))

    (let ((src-path (or source-file
                        (namestring input-path))))

      (when (null kernel-names)
            (multiple-value-bind (aliases structs)
                (collect-kernel-dependencies nil)
              (with-open-file (stream output-path :direction :output :if-exists :supersede)
                (format stream ";; generated by crisp-compile~%~%")))
            (push output-path generated-files))

      (dolist (k kernel-names)
        (let* ((suffix (format nil "_~a.metacrisp" (string-downcase (symbol-name k))))
               (final-path (make-pathname :name (format nil "~a_~a" (pathname-name output-path) (string-downcase (symbol-name k)))
                                          :type "metacrisp"
                                          :defaults output-path)))

          (multiple-value-bind (aliases structs)
              (collect-kernel-dependencies (list k))

            (with-open-file (stream final-path :direction :output :if-exists :supersede)
              (format stream ";; generated by crisp-compile~%~%")
              (serialize-aliases stream aliases)
              (serialize-structs stream structs)
              (serialize-kernels stream (list k) :source src-path :output-targets output-targets))) ;; FIXED CALL SITE MATCH

          (push final-path generated-files)))

      (nreverse generated-files))))
      |#

;; REDEFINITION: generate-metadata-for-file to ensure it uses the NEW serialize-structs
(defun generate-metadata-for-file (input-path output-path &key (output-targets nil) (source-file nil) (forms nil))
  (let ((kernel-names (if forms
                          (extract-defined-kernels forms)
                          (alexandria:hash-table-keys *function-table*)))
        (generated-files nil))

    (let ((src-path (or source-file
                        (namestring input-path))))

      (when (null kernel-names)
            (multiple-value-bind (aliases structs)
                (collect-kernel-dependencies nil)
              (with-open-file (stream output-path :direction :output :if-exists :supersede)
                (format stream ";; generated by crisp-compile~%~%")))
            (push output-path generated-files))

      (dolist (k kernel-names)
        (let* ((suffix (format nil "_~a.metacrisp" (string-downcase (symbol-name k))))
               (final-path (make-pathname :name (format nil "~a_~a" (pathname-name output-path) (string-downcase (symbol-name k)))
                                          :type "metacrisp"
                                          :defaults output-path)))

          (multiple-value-bind (aliases structs)
              (collect-kernel-dependencies (list k))

            (with-open-file (stream final-path :direction :output :if-exists :supersede)
              (format stream ";; generated by crisp-compile~%~%")
              (serialize-aliases stream aliases)
              (serialize-structs stream structs)
              (serialize-kernels stream (list k) :source src-path :output-targets output-targets)))

          (push final-path generated-files)))

      (nreverse generated-files))))


(defun get-physical-width (type)
  (cond
   ((%storage-handle-type-p type)
     (let* ((canonical (canonicalize-type-specifier type))
            (base (if (consp canonical) (first canonical) canonical)))
       (cond
        ((and (symbolp base) (string-equal (symbol-name base) "CELL"))
          3)
        (t 1))))
   ;; STORAGE is a buffer (ptr) + size (i64) -> 2 args
   ((or (and (symbolp type) (string-equal (symbol-name type) "STORAGE"))
        (and (consp type) (string-equal (symbol-name (car type)) "STORAGE")))
     2)
   (t 1)))

(defun generate-physical-signature (sig-or-params)
  (let ((params (if (typep sig-or-params 'function-signature)
                    ;; IMPLICITS FIRST based on IR observation
                    (append (function-signature-implicit-parameters sig-or-params)
                      (function-signature-parameters sig-or-params))
                    sig-or-params))
        (physical-args nil)
        (current-index 0))
    (dolist (param params)
      (let ((type (if (typep param 'parameter-def)
                      (parameter-def-type param)
                      param)))
        (unless (and (symbolp type) (string-equal (symbol-name type) "&OUT"))
          (cond
           ;; Handle STORAGE specially - flatten to PTR + I64
           ((or (and (symbolp type) (string-equal (symbol-name type) "STORAGE"))
                (and (consp type) (string-equal (symbol-name (car type)) "STORAGE")))
             (push (list current-index (strip-package-qualifiers '(c-pointer address-space global))) physical-args) ;; Flattened Arg 1
             (incf current-index)
             (push (list current-index (strip-package-qualifiers 'ulong)) physical-args) ;; Flattened Arg 2
             (incf current-index))

           ((%storage-handle-type-p type)
             (let* ((canonical (canonicalize-type-specifier type))
                    (base (if (consp canonical) (first canonical) canonical)))
               (cond
                ((and (symbolp base) (string-equal (symbol-name base) "CELL"))
                  (push (list current-index (strip-package-qualifiers 'ulong)) physical-args)
                  (incf current-index)
                  (push (list current-index (strip-package-qualifiers 'voidp)) physical-args)
                  (incf current-index)
                  (push (list current-index (strip-package-qualifiers 'ulong)) physical-args)
                  (incf current-index))
                (t
                  (push (list current-index (strip-package-qualifiers type)) physical-args)
                  (incf current-index)))))
           (t
             (push (list current-index (strip-package-qualifiers type)) physical-args)
             (incf current-index))))))
    (nreverse physical-args)))

(defun validate-14-physical-signature (paths)
  (let ((meta-path (find "complex_signature_kernel.metacrisp" paths :test #'search :key #'namestring)))
    (unless meta-path
      (return-from validate-14-physical-signature nil))
    (let ((content (uiop:read-file-forms meta-path)))
      (let* ((kernels (find :kernels content :key #'car))
             (k-def (block find-kernel
                      (dolist (k (cdr kernels))
                        (when (string-equal (getf k :name) "complex_signature_kernel")
                              (return-from find-kernel k))))))
        (unless k-def
          (return-from validate-14-physical-signature nil))
        (let ((phys-sig (getf k-def :physical-signature)))
          (labels ((loose-equal (a b)
                                (cond ((and (symbolp a) (symbolp b))
                                        (string-equal (symbol-name a) (symbol-name b)))
                                      ((and (consp a) (consp b))
                                        (and (loose-equal (car a) (car b))
                                             (loose-equal (cdr a) (cdr b))))
                                      (t (equal a b)))))
            (unless (and (= (length phys-sig) 7)
                         (loose-equal (nth 0 phys-sig) '(0 FLOAT))
                         (loose-equal (nth 1 phys-sig) '(1 (C-POINTER ADDRESS-SPACE GLOBAL)))
                         (loose-equal (nth 2 phys-sig) '(2 ULONG))
                         (loose-equal (nth 3 phys-sig) '(3 ULONG))
                         (loose-equal (nth 4 phys-sig) '(4 (C-POINTER ADDRESS-SPACE GLOBAL)))
                         (loose-equal (nth 5 phys-sig) '(5 ULONG))
                         (loose-equal (nth 6 phys-sig) '(6 ULONG)))
              (return-from validate-14-physical-signature nil))))
        t))))


(defun generate-declared-signature (sig &optional declared-params)
  (let ((declared-args nil)
        (current-phys-index 0)
        (out-mode nil) ;; Track if we've encountered &out
        (params-to-use (or declared-params (function-signature-parameters sig))))

    ;; Implicits come first, so offset the start index for declared params
    (dolist (p (function-signature-implicit-parameters sig))
      (incf current-phys-index (get-physical-width (parameter-def-type p))))

    (dolist (param-def params-to-use)
      (let* ((name (if (consp param-def) (car param-def) (parameter-def-name param-def)))
             (type (if (consp param-def) (cdr param-def) (parameter-def-type param-def))))

        ;; Check if this is the &out marker
        (if (and (symbolp name) (string-equal (symbol-name name) "&OUT"))
            (setf out-mode t) ;; Switch to output mode
            ;; Not &out marker, so it's a real parameter
            (let* ((width (get-physical-width type))
                   (start current-phys-index)
                   (end (+ start (max 0 (1- width))))
                   (entry (list :name (string-downcase (symbol-name name)))))

              ;; Add type
              (setf entry (append entry (list :type (strip-package-qualifiers type))))

              ;; Add direction (:in or :out)
              (setf entry (append entry (list :direction (if out-mode :out :in))))

              ;; Add storage handle specific fields (address-space, access)
              (when (%storage-handle-type-p type)
                    (let* ((canonical (canonicalize-type-specifier type))
                           (base (if (consp canonical) (first canonical) canonical))
                           (is-cell (and (symbolp base) (string-equal (symbol-name base) "CELL")))
                           ;; Canonical form is positional: (CELL T Addr Acc)
                           (as (if (and (consp canonical) is-cell (>= (length canonical) 3))
                                   (nth 2 canonical)
                                   (if (consp canonical)
                                       (let ((found (member :address-space canonical)))
                                         (if found (second found) :global))
                                       :global)))
                           (acc (if (and (consp canonical) is-cell (>= (length canonical) 4))
                                    (nth 3 canonical)
                                    (if (consp canonical)
                                        (let ((found (member :access canonical)))
                                          (if found (second found) :read-write))
                                        :read-write))))
                      (setf entry (append entry (list :address-space as :access acc)))))

              ;; Add range
              (setf entry (append entry (list :range (list start end))))
              (push entry declared-args)
              (incf current-phys-index width)))))
    (nreverse declared-args)))

;; ...

(defun generate-implicit-signature (sig declared-params)
  (declare (ignore declared-params))
  (let ((implicit-args nil)
        (phys-index 0)
        (implicit-params (function-signature-implicit-parameters sig)))

    ;; Implicit params START at 0 now.

    (dolist (param-def implicit-params)
      (let* ((name (parameter-def-name param-def))
             (type (parameter-def-type param-def))
             (width (get-physical-width type))
             (start phys-index)
             (end (+ phys-index width -1))
             ;; Parse cell types: (CELL inner-type address-space access)
             (address-space (if (and (consp type)
                                     (symbolp (first type))
                                     (string-equal (symbol-name (first type)) "CELL")
                                     (>= (length type) 3))
                                (nth 2 type) ; Position 2 is address-space
                                :local))
             (access (if (and (consp type)
                              (symbolp (first type))
                              (string-equal (symbol-name (first type)) "CELL")
                              (>= (length type) 4))
                         (nth 3 type) ; Position 3 is access
                         :read-write)))
        (let ((entry (list :name (string-downcase (symbol-name name))
                           :type (strip-package-qualifiers type)
                           :address-space address-space
                           :access access
                           :range (list start end))))
          (push entry implicit-args))
        (incf phys-index width)))
    (nreverse implicit-args)))

(defun serialize-kernels (output-stream kernel-names &key source output-targets)
  (when kernel-names
        (format output-stream "(:kernels~%")
        (dolist (k-name (sort (copy-list kernel-names) #'string< :key #'symbol-name))
          (let ((sigs (gethash k-name *function-table*))
                (blocks-to-emit nil))
            ;; Use only the FIRST signature (Pass 1 registered, Pass 2 updated)
            ;; The last one is likely a stale duplicate from macro expansion.
            (dolist (actual-sig (list (first sigs)))
              (when actual-sig
                    (let* ((phys-sig-str (generate-physical-signature actual-sig))
                           (declared-types (gethash k-name *kernel-declared-signatures*))
                           (decl-sig-list (generate-declared-signature actual-sig declared-types))
                           (implicit-sig-list (generate-implicit-signature actual-sig declared-types))
                           (source-loc (if source source
                                           (namestring (uiop/filesystem:native-namestring (first (function-signature-source-location actual-sig)))))))

                      ;; Construct the block structure for deduplication
                      (push (list :name (string-downcase (symbol-name k-name))
                                  :source source-loc
                                  :output output-targets
                                  :phys phys-sig-str
                                  :decl decl-sig-list
                                  :impl implicit-sig-list)
                            blocks-to-emit))))

            ;; Valid deduplication on the content we care about
            (setf blocks-to-emit (remove-duplicates (nreverse blocks-to-emit) :test #'equalp))

            (dolist (blk blocks-to-emit)
              (format output-stream "  (:name ~s~%" (getf blk :name))
              (format output-stream "    :source ~s~%" (pathname (getf blk :source)))
              (when (getf blk :output) (format output-stream "    :output-targets ~s~%" (getf blk :output)))
              (format output-stream "    :physical-signature ~a~%" (getf blk :phys))
              (format output-stream "    :declared-signature ")
              (print-without-packages (getf blk :decl) output-stream)
              (format output-stream "~%")
              (when (getf blk :impl)
                    (format output-stream "    :implicit-params ")
                    (print-without-packages (getf blk :impl) output-stream)
                    (format output-stream "~%"))
              (format output-stream "  )~%"))))
        (format output-stream "  )~%")))
