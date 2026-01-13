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
                   ;; Just push all elements that might be types
                   (dolist (sub (rest type-spec))
                     (push sub work-list)))))))

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

(defun serialize-kernels (stream kernel-names)
  (format stream "(:kernels~%")
  (dolist (k kernel-names)
    (let ((sig (first (gethash k *function-table*)))
          (declared-types (gethash k *kernel-declared-signatures*)))

      (when sig
            (format stream "  (~a~%" (function-signature-name sig))

            ;; Physical Signature (Exploded)
            (format stream "    (:physical-signature ~a)~%"
              (mapcar #'canonicalize-type-specifier (function-signature-parameters sig)))

            ;; Declared Signature (High Level)
            (when declared-types
                  (format stream "    (:declared-signature ~a)~%"
                    ;; Filter out &out keywords from the list?
                    ;; declared-types includes symbols like &out.
                    ;; We should probably keep them or remove them depending on what 'declared signature' means.
                    ;; The ref.metacrisp implies structured output.
                    ;; For now, let's dump the sequence. 
                    (loop for t-spec in declared-types
                            unless (and (symbolp t-spec) (string-equal (symbol-name t-spec) "&OUT"))
                          collect t-spec)))

            (format stream "  )~%"))))
  (format stream "  )~%~%"))

;;; Main Entry Point
;;; ----------------

(defun generate-metadata-for-file (source-path output-path)
  "Generates a .metacrisp file containing type definitions, structs, and kernel info."

  (log:info "Generating Metadata for ~a -> ~a" source-path output-path)

  ;; Collect dependencies for ALL compiled kernels (in *compiled-kernels*)
  ;; In a real orchestration, we'd only filter relevant ones.
  ;; For now, loose kernels = all compiled kernels?
  ;; Note: compiling multiple files in one session accumulates *compiled-kernels*.
  ;; But run-specs.lisp isolates each run.

  (multiple-value-bind (aliases structs) (collect-kernel-dependencies *compiled-kernels*)

    (with-open-file (stream output-path :direction :output :if-exists :supersede)
      (format stream ";; Metadata for ~a~%" (file-namestring source-path))
      (format stream ";; Generated by Crisp Compiler~%~%")

      (serialize-aliases stream aliases)
      (serialize-structs stream structs)
      (serialize-kernels stream *compiled-kernels*))))
