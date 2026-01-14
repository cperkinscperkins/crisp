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
  "Validator for 01-aliases.crisp.
   Checks if (:aliases ... (def-type type-name target-type) ...) exists."
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
  "Wrapper for 01-aliases test."
  (validate-metadata-def-type metadata-path 'iii 'int))

(defun validate-struct-presence (metadata-path expected-structs &key (unexpected-structs nil))
  "Validates that expected structs are present in order, and unexpected ones are absent."
  (unless (probe-file metadata-path)
    (log:error "Metadata file not found: ~a" metadata-path)
    (return-from validate-struct-presence nil))

  (let ((content (uiop:read-file-forms metadata-path)))
    (let* ((structs-form (find :structs content :key #'car))
           (definitions (cdr structs-form))
           (found-names (mapcar #'second definitions))) ;; (def-struct NAME ...)

      ;; 1. Check Unexpected
      (dolist (un unexpected-structs)
        (when (member (symbol-name un) found-names :test #'string-equal :key #'symbol-name)
              (log:error "Validation Failed: Found unexpected struct ~a" un)
              (return-from validate-struct-presence nil)))

      ;; 2. Check Expected & Order
      (let ((current-ptr found-names))
        (dolist (ex expected-structs)
          ;; Find ex in current-ptr
          (let ((pos (position (symbol-name ex) current-ptr :test #'string-equal :key #'symbol-name)))
            (unless pos
              (log:error "Validation Failed: Expected struct ~a not found (or out of order). Remaining: ~a" ex current-ptr)
              (return-from validate-struct-presence nil))

            ;; Advance pointer to just after found item (enforcing order if strictly sequential? 
            ;; or just relative order? Topological sort implies relative order.
            ;; For now, let's assume loose relative order is sufficient, but finding subsequent items 
            ;; must be AFTER the current one.)
            (setf current-ptr (subseq current-ptr (1+ pos))))))

      t)))

(defun validate-04-basic-struct (metadata-path)
  (validate-struct-presence metadata-path '(point) :unexpected-structs '(skipped)))

(defun validate-06-nested-structs (metadata-path)
  ;; Point must come BEFORE Rect because Rect uses Point.
  (validate-struct-presence metadata-path '(point rect)))

;;; Dependency Collection
;;; ---------------------

(defun collect-kernel-dependencies (kernel-names)
  "Walks the signatures of the given kernels and returns lists of used aliases and structs.
   Returns (values used-aliases used-structs)"
  (let ((used-aliases (make-hash-table :test 'eq))
        (used-structs (make-hash-table :test 'eq))
        (seen-types (make-hash-table :test 'equal)) ; Prevent cycles/redundancy
        (work-list nil))

    ;; 1. Seed work-list with kernel parameters
    (dolist (k-name kernel-names)
      (let ((sigs (gethash k-name *function-table*)))
        ;; Prefer declared signature (recursive/high-level types) if available
        (let ((declared-types (gethash k-name *kernel-declared-signatures*)))
          (if declared-types
              (dolist (t-spec declared-types)
                (push t-spec work-list))
              ;; Fallback to physical signatures (likely pointers/voids, but better than nothing)
              (dolist (sig sigs)
                (dolist (param-type (function-signature-parameters sig))
                  (push param-type work-list)))))))

    ;; 2. Process Work List
    (loop while work-list do
            (let ((type-spec (pop work-list)))
              (unless (gethash type-spec seen-types)
                (setf (gethash type-spec seen-types) t)

                ;; Handle &out keyword (skip)
                (when (and (symbolp type-spec) (string-equal (symbol-name type-spec) "&OUT"))
                      ;; Skip
                      )

                ;; Recursively examine type
                (cond
                 ((symbolp type-spec)
                   ;; Is it an alias?
                   (let ((target (gethash type-spec *crisp-type-aliases*)))
                     (when target
                           (setf (gethash type-spec used-aliases) t)
                           (push target work-list)))

                   ;; Is it a struct?
                   (let ((def (gethash type-spec *crisp-structs*)))
                     (when def
                           (setf (gethash type-spec used-structs) t)
                           ;; Add members to work list
                           (loop for (name m-type) in (crisp-struct-definition-members def)
                                 do (push m-type work-list)))))

                 ((consp type-spec)
                   ;; Handle composite types: (cell T ...), (vector T ...)
                   ;; 1. Push all sub-elements to ensure we catch recursive types
                   (dolist (sub (rest type-spec))
                     (push sub work-list))

                   ;; 2. Canonicalize and check if this list maps to a generated struct
                   ;; e.g. (CELL FLOAT) -> CELL_FLOAT_GLOBAL_READ-WRITE
                   (let* ((canon (canonicalize-type-specifier type-spec))
                          (base (first canon))
                          (args (rest canon)))
                     (when (symbolp base)
                           (let ((mangled (mangle-template-struct-name base args)))
                             (when (and (gethash mangled *crisp-structs*)
                                        ;; FILTER: Exclude system structs (CELL_*, STORAGE)
                                        (not (string-equal (symbol-name mangled) "STORAGE"))
                                        (not (alexandria:starts-with-subseq "CELL_" (symbol-name mangled))))
                                   (push mangled work-list))))))))))

    (values used-aliases used-structs)))

(defun sort-structs-by-dependency (struct-names)
  "Topologically sorts struct names so dependencies appear first."
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
                                 ;; Member is (name type)
                                 (let ((type (second member)))
                                   ;; Resolve aliases/containers to find struct dependencies
                                   ;; We duplicate some logic from collect-dependencies here but focused on direct struct refs
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

(defun serialize-aliases (stream aliases-hash)
  (format stream "(:aliases~%")
  (let ((aliases (alexandria:hash-table-keys aliases-hash)))
    (setf aliases (sort aliases #'string< :key #'symbol-name))
    (dolist (alias aliases)
      (let ((target (gethash alias *crisp-type-aliases*)))
        (format stream "  (def-type ~a ~a)~%" alias target))))
  (format stream "  )~%~%"))

(defun serialize-structs (stream structs-hash)
  (format stream "(:structs~%")
  (let ((struct-names (alexandria:hash-table-keys structs-hash)))
    (let ((sorted-names (sort-structs-by-dependency struct-names)))
      (dolist (name sorted-names)
        (let ((def (gethash name *crisp-structs*)))
          (when def
                (format stream "  (def-struct ~a" name)
                (dolist (m (crisp-struct-definition-members def))
                  (format stream " (~a ~a)" (first m) (second m)))
                (format stream ")~%"))))))
  (format stream "  )~%~%"))

(defun serialize-kernels (stream kernel-names &key source output-targets)
  (format stream "(:kernels~%")
  (dolist (k kernel-names)
    (let ((sig (first (gethash k *function-table*)))
          (declared-types (gethash k *kernel-declared-signatures*)))

      (when sig
            ;; Name: downcase symbol name for convention
            (let ((k-name (string-downcase (symbol-name (function-signature-name sig)))))
              (format stream "  (~s~%" k-name) ;; Use ~s to quote string

              ;; Source Path
              (when source
                    (format stream "    :source ~s~%" source))

              ;; Output Targets
              (when output-targets
                    (format stream "    :output-targets (")
                    (dolist (target output-targets)
                      ;; target is (:spv "path")
                      (format stream " (~s ~s)" (first target) (second target)))
                    (format stream ")~%"))

              ;; Physical Signature (Exploded)
              (format stream "    :physical-signature ~a~%"
                (mapcar #'canonicalize-type-specifier (function-signature-parameters sig)))

              ;; Declared Signature (High Level)
              (when declared-types
                    (format stream "    :declared-signature ~a~%"
                      ;; Filter out &out keywords from the list?
                      (loop for t-spec in declared-types
                              unless (and (symbolp t-spec) (string-equal (symbol-name t-spec) "&OUT"))
                            collect t-spec)))

              (format stream "  )~%")))))
  (format stream "  )~%~%"))

;;; Extraction
;;; ----------

(defun extract-defined-kernels (forms)
  "Scans a list of forms for (def-kernel name ...) and returns a list of names."
  (let ((names nil))
    (dolist (f forms)
      (when (and (consp f) (eq (first f) 'def-kernel))
            (push (second f) names)))
    (nreverse names)))

;;; Main Entry Point
;;; ----------------

(defun generate-metadata-for-file (input-path output-path &key (output-targets nil) (source-file nil) (forms nil))
  "Generates a .metacrisp file for the given input."

  ;; Determine kernels to process:
  ;; 1. If forms provided, extract explicitly defined kernels.
  ;; 2. Fallback: Dump everything (Legacy/Debug behavior, but deprecated for clean builds)
  (let ((kernel-names (if forms
                          (extract-defined-kernels forms)
                          (alexandria:hash-table-keys *function-table*))))

    ;; Determine source to record
    (let ((src-path (or source-file
                        (let ((native-input (uiop:native-namestring input-path)))
                          (namestring input-path)))))

      (multiple-value-bind (aliases structs)
          (collect-kernel-dependencies kernel-names)

        (with-open-file (stream output-path :direction :output :if-exists :supersede)
          (format stream ";; generated by crisp-compile~%~%")

          (when (> (hash-table-count aliases) 0)
                (serialize-aliases stream aliases))

          (when (> (hash-table-count structs) 0)
                (serialize-structs stream structs))

          (when kernel-names
                (serialize-kernels stream kernel-names :source src-path :output-targets output-targets)))))))

;;; Validation
;;; ----------

(defun validate-kernel-metadata (metadata-path kernel-name &key (targets nil targets-p))
  (let ((forms (uiop:read-file-forms metadata-path)))
    (unless forms
      (log:error "Validation Failed: Empty metadata file ~a" metadata-path)
      (return-from validate-kernel-metadata nil))

    (let ((kernels (rest (assoc :kernels forms))))
      (unless kernels
        (log:error "Validation Failed: No :kernels section found")
        (return-from validate-kernel-metadata nil))

      (let ((k-def (find kernel-name kernels :key #'first :test #'string=)))
        (unless k-def
          (log:error "Validation Failed: Kernel ~s not found" kernel-name)
          (return-from validate-kernel-metadata nil))

        ;; Check Source
        (let ((src (getf (rest k-def) :source)))
          (unless src
            (log:error "Validation Failed: No :source found for kernel ~s" kernel-name)
            (return-from validate-kernel-metadata nil)))

        ;; Check Output Targets
        (let ((output-targets (getf (rest k-def) :output-targets)))
          (when targets-p
                (let ((found-targets (mapcar #'first output-targets)))
                  (dolist (req targets)
                    (unless (member req found-targets)
                      (log:error "Validation Failed: Expected target ~s not found in ~s" req found-targets)
                      (return-from validate-kernel-metadata nil))))))))
    t))

(defun validate-10-basics-meta (path)
  (validate-kernel-metadata path "basic_kernel" :targets nil))

(defun validate-10-basics-spv (path)
  (validate-kernel-metadata path "basic_kernel" :targets '(:spv)))

(defun validate-10-basics-multi (path)
  (validate-kernel-metadata path "basic_kernel" :targets '(:spv)))
