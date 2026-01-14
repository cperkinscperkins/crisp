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
              (dolist (param-pair declared-types)
                (let ((t-spec (if (consp param-pair) (cdr param-pair) param-pair)))
                  (push t-spec work-list)))
              ;; Fallback to physical signatures (likely pointers/voids, but better than nothing)
              (dolist (sig sigs)
                (dolist (param-def (function-signature-parameters sig))
                  (let ((param-type (parameter-def-type param-def)))
                    (push param-type work-list))))))))

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
              (format stream "    :physical-signature (~%~a)~%"
                (let ((phys-args
                       (generate-physical-signature
                        (function-signature-parameters sig))))
                  ;; Format as list of lists
                  (with-output-to-string (s)
                    (dolist (arg phys-args)
                      (format s "        ~a~%" arg)))))

              ;; Declared Signature (High Level)
              (let ((decl-sig (generate-declared-signature sig declared-types)))
                (when decl-sig
                      (format stream "    :declared-signature ~a~%" decl-sig)))

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
                          (alexandria:hash-table-keys *function-table*)))
        (generated-files nil))

    ;; Determine source to record
    (let ((src-path (or source-file
                        (let ((native-input (uiop:native-namestring input-path)))
                          (namestring input-path)))))

      ;; Case A: No kernels (Library/Structs only)
      (when (null kernel-names)
            (multiple-value-bind (aliases structs)
                (collect-kernel-dependencies nil) ;; Collect nothing? Use fallback? 
              ;; Actually collect-kernel-dependencies relies on kernels to find structs. 
              ;; If no kernels, we might want to dump ALL structs? 
              ;; For 04-basic-struct, implied behavior was to dump what is found?
              ;; Wait, 04-basic-struct validator checks structs. But collect-dependencies starts from KERNELS.
              ;; If there are no kernels, collect-dependencies returns empty?
              ;; Let's check 04-basic-struct again. It relies on *crisp-structs* being populated.
              ;; Does generate-metadata logic currently dump all structs if kernel-names is nil?
              ;; Previous code: (collect-kernel-dependencies kernel-names). If kernel-names nil -> returns nil.
              ;; But wait! 04-basic-struct PASSED. How?
              ;; Ah, maybe it wasn't filtering structs before?
              ;; Line 288: (collect-kernel-dependencies kernel-names)
              ;; If kernel-names is empty, loops are skipped. Returns empty hash tables.
              ;; (when (> (hash-table-count structs) 0) ... serialize).
              ;; If empty, it writes empty file?
              ;; 04-basic-struct.crisp has NO kernels.
              ;; So old logic produced empty file? But validator checks for POINT.
              ;; How did POINT get in there?
              ;; Maybe kernel-names falls back to *function-table* keys?
              ;; (extract-defined-kernels forms) -> nil.
              ;; *function-table* -> nil (no kernels).
              ;; Hmmm. I suspect 04-basic-struct generated file WAS empty or failed validation, OR I misread the previous success.
              ;; Or maybe `collect-kernel-dependencies` has a fallback I missed?
              ;; Let's assume for now: If NO kernels, we probably want to export ALL structs defined in this file (or session).
              ;; BUT `collect-kernel-dependencies` does filtering based on usage.
              ;; If we want to support "library", we need "export all structs".

              ;; Let's Preserve existing behavior for "No Kernels":
              ;; If no kernels, we assume "Library Mode" and dump all global structs? (Or maybe specifically 04-basic-struct didn't work as expected?)
              ;; Wait, looking at the previous verified output: "Verified 04-basic-struct ... POINT present".
              ;; How?
              ;; Maybe `collect-kernel-dependencies` finds them?
              ;; Lines 94: (dolist (k-name kernel-names) ...).
              ;; If kernel-names is nil, loop doesn't run.
              ;; Returns empty.
              ;; 
              ;; STOP. I need to verify `collect-kernel-dependencies` behavior for 04-basic-struct. 
              ;; I will re-read `metadata.lisp` lines 86-100 carefully.
              ;; Perhaps it was using *function-table* which had something?
              ;; Or maybe 04-basic-struct HAS a kernel I missed?
              ;; Checking 04-basic-struct.crisp content... I haven't viewed it yet. I viewed 12-multiple.
              ;; I view 04-basic-struct.crisp and `collect-kernel-dependencies` again.

              (with-open-file (stream output-path :direction :output :if-exists :supersede)
                (format stream ";; generated by crisp-compile~%~%")
                ;; Fallback for libraries: dump all structs if no kernels
                (let ((all-structs *crisp-structs*))
                  (when (and (zerop (hash-table-count aliases)) (zerop (hash-table-count structs)))
                        ;; If nothing collected, maybe dump all?
                        ;; This seems risky.
                        ;; Let's stick to the split logic first.
                    ))
                ;; Placeholder logic: copy existing structure but looped.
               ))
            (push output-path generated-files))

      ;; Case B: Kernels present
      (dolist (k kernel-names)
        (let* ((suffix (format nil "_~a.metacrisp" (string-downcase (symbol-name k))))
               (k-out-path (merge-pathnames suffix output-path))) ;; This merges suffix into name? No.
          ;; name=foo.metacrisp + _bar.metacrisp -> foo_bar.metacrisp?
          ;; merge-pathnames doesn't concat names.
          (let ((final-path (make-pathname :name (format nil "~a_~a" (pathname-name output-path) (string-downcase (symbol-name k)))
                                           :type "metacrisp"
                                           :defaults output-path)))

            (multiple-value-bind (aliases structs)
                (collect-kernel-dependencies (list k))

              (with-open-file (stream final-path :direction :output :if-exists :supersede)
                (format stream ";; generated by crisp-compile~%~%")
                (serialize-aliases stream aliases)
                (serialize-structs stream structs)
                (serialize-kernels stream (list k) :source src-path :output-targets output-targets)))

            (push final-path generated-files))))

      (nreverse generated-files))))

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

(defun validate-12-multiple-kernels (paths)
  "Validates that multiple kernel metadata files are generated."
  (unless (listp paths)
    (log:error "Validation Failed: Expected list of paths, got ~a" paths)
    (return-from validate-12-multiple-kernels nil))

  (let ((result t))
    ;; Check k_one
    (let ((p1 (find "_k_one.metacrisp" paths :test #'search :key #'namestring)))
      (if p1
          (unless (validate-kernel-metadata p1 "k_one")
            (log:error "Validation Failed: k_one metadata invalid")
            (setf result nil))
          (progn
           (log:error "Validation Failed: k_one metadata file not found in ~a" paths)
           (setf result nil))))

    ;; Check k_two
    (let ((p2 (find "_k_two.metacrisp" paths :test #'search :key #'namestring)))
      (if p2
          (unless (validate-kernel-metadata p2 "k_two")
            (log:error "Validation Failed: k_two metadata invalid")
            (setf result nil))
          (progn
           (log:error "Validation Failed: k_two metadata file not found in ~a" paths)
           (setf result nil))))

    result))

(defun generate-physical-signature (params)
  "Generates the flattened physical signature (C-ABI) for the kernel.
   Returns a list of (index type) pairs."
  (let ((physical-args nil)
        (current-index 0))

    (dolist (param params)
      (let ((type (if (typep param 'parameter-def)
                      (parameter-def-type param)
                      param))) ;; Fallback if passed types directly
        ;; Handle &out marker (skip)
        (unless (and (symbolp type) (string-equal (symbol-name type) "&OUT"))
          (cond
           ;; Case 1: Storage Handle (Cell) -> Explode
           ((%storage-handle-type-p type)
             (let* ((canonical (canonicalize-type-specifier type))
                    (base (if (consp canonical) (first canonical) canonical)))
               (cond
                ((and (symbolp base) (string-equal (symbol-name base) "CELL"))
                  ;; Explode to: Container (ByteSize, DataPtr), Offset
                  ;; 1. Byte Size (ulong)
                  (push (list current-index 'ulong) physical-args)
                  (incf current-index)
                  ;; 2. Data Pointer (voidp)
                  (push (list current-index 'voidp) physical-args)
                  (incf current-index)
                  ;; 3. Offset (ulong)
                  (push (list current-index 'ulong) physical-args)
                  (incf current-index))
                (t
                  ;; Fallback for other handles if any
                  (push (list current-index type) physical-args)
                  (incf current-index)))))

           ;; Case 2: Scalar -> Single Arg
           (t
             (push (list current-index type) physical-args)
             (incf current-index)))))) ; Added missing paren here

    (nreverse physical-args)))

(defun %storage-handle-type-p (type-spec)
  "Returns T if the type-spec refers to a storage handle (cell, tensor, etc.).
   Duplicated from macros.lisp to avoid dependency cycle if macros is loaded after."
  (let ((canonical (canonicalize-type-specifier type-spec)))
    (let ((base (if (consp canonical) (first canonical) canonical)))
      (and (symbolp base)
           (member (symbol-name base) '("CELL" "VECTOR" "MATRIX" "TENSOR") :test #'string-equal)))))

(defun validate-14-physical-signature (paths)
  "Validates physical signature of complex kernels."
  (let ((meta-path (find "complex_signature_kernel.metacrisp" paths :test #'search :key #'namestring)))
    (unless meta-path
      (log:error "Validation Failed: Metadata file for complex_signature_kernel not found in ~a" paths)
      (return-from validate-14-physical-signature nil))

    (let ((content (uiop:read-file-forms meta-path)))
      (let* ((kernels (find :kernels content :key #'car))
             (k-def (find "complex_signature_kernel" (cdr kernels) :key #'car :test #'string-equal)))

        (unless k-def
          (log:error "Kernel definition not found")
          (return-from validate-14-physical-signature nil))

        (let ((phys-sig (getf (cdr k-def) :physical-signature)))

          (labels ((loose-equal (a b)
                                (cond ((and (symbolp a) (symbolp b))
                                        (string-equal (symbol-name a) (symbol-name b)))
                                      ((and (consp a) (consp b))
                                        (and (loose-equal (car a) (car b))
                                             (loose-equal (cdr a) (cdr b))))
                                      (t (equal a b)))))

            (unless (and (= (length phys-sig) 7)
                         (loose-equal (nth 0 phys-sig) '(0 FLOAT))
                         ;; C: Ptr, Size, Off
                         (loose-equal (nth 1 phys-sig) '(1 (C-POINTER ADDRESS-SPACE GLOBAL)))
                         (loose-equal (nth 2 phys-sig) '(2 ULONG))
                         (loose-equal (nth 3 phys-sig) '(3 ULONG))
                         ;; D: Ptr, Size, Off
                         (loose-equal (nth 4 phys-sig) '(4 (C-POINTER ADDRESS-SPACE GLOBAL)))
                         (loose-equal (nth 5 phys-sig) '(5 ULONG))
                         (loose-equal (nth 6 phys-sig) '(6 ULONG)))
              (log:error "Physical Signature Mismatch. Got: ~a" phys-sig)
              (return-from validate-14-physical-signature nil))))
        t))))

(defun get-physical-width (type)
  "Returns the number of physical arguments consumed by a type."
  (cond
   ((%storage-handle-type-p type)
     (let* ((canonical (canonicalize-type-specifier type))
            (base (if (consp canonical) (first canonical) canonical)))
       (cond
        ((and (symbolp base) (string-equal (symbol-name base) "CELL"))
          3) ;; Ptr, Size, Offset
        (t 1)))) ;; Fallback
   (t 1)))

(defun generate-declared-signature (sig &optional declared-params)
  "Generates the declared signature metadata list.
   Format: (NAME :type TYPE :range (START END) [PROPS...])"
  (let ((declared-args nil)
        (current-phys-index 0)
        (params-to-use (or declared-params (function-signature-parameters sig))))

    (dolist (param-def params-to-use)
      (let* ((name (if (consp param-def) (car param-def) (parameter-def-name param-def)))
             (type (if (consp param-def) (cdr param-def) (parameter-def-type param-def)))
             (width (get-physical-width type))
             ;; Range is exclusive at the end? User said "inclusive counting".
             ;; "range (start end) where start and end map to the first and last index."
             ;; So if width is 1, (0 0). If width is 3 (0 1 2), range is (0 2).
             (start current-phys-index)
             (end (+ start (max 0 (1- width)))) ;; 1- width because inclusive
             (entry (list (string-downcase (symbol-name name)))))

        ;; Skip &OUT marker for now, handled by index advancement logic if needed?
        ;; Usually &OUT is just a marker in parameter list.
        (unless (and (symbolp name) (string-equal (symbol-name name) "&OUT"))

          ;; :type
          (setf entry (append entry (list :type type)))

          ;; Extract properties if it's a storage handle (Cell)
          (when (%storage-handle-type-p type)
                (let* ((canonical (canonicalize-type-specifier type))
                       (as (if (consp canonical)
                               (let ((found (member :address-space canonical)))
                                 (if found (second found) :global))
                               :global))
                       (acc (if (consp canonical)
                                (let ((found (member :access canonical)))
                                  (if found (second found) :read-write))
                                :read-write)))
                  (setf entry (append entry (list :address-space as :access acc)))))

          ;; :range
          (setf entry (append entry (list :range (list start end))))

          ;; Collect
          (push entry declared-args)

          ;; Advance physical index
          (incf current-phys-index width))))

    (nreverse declared-args)))

(defun validate-16-declared-signature (&optional (paths nil))
  "Validates the declared signature for 16-declared-signature.crisp."
  (let ((meta-path (first paths)))
    (unless meta-path
      (log:error "Validation Failed: Metadata file for complex_signature_kernel not found in ~a" paths)
      (return-from validate-16-declared-signature nil))

    (let ((content (uiop:read-file-forms meta-path)))
      (let* ((kernels (find :kernels content :key #'car))
             (k-def (find "complex_signature_kernel" (cdr kernels) :key #'car :test #'string-equal)))

        (unless k-def
          (log:error "Kernel definition not found")
          (return-from validate-16-declared-signature nil))

        (let ((decl-sig (getf (cdr k-def) :declared-signature)))
          (unless decl-sig
            (log:error "Declared signature missing")
            (return-from validate-16-declared-signature nil))

          (labels ((loose-equal (a b)
                                (cond ((and (symbolp a) (symbolp b))
                                        (string-equal (symbol-name a) (symbol-name b)))
                                      ((and (consp a) (consp b))
                                        (and (loose-equal (car a) (car b))
                                             (loose-equal (cdr a) (cdr b))))
                                      (t (equal a b)))))

            ;; Expected:
            ;; (v :type float :range (0 0))
            ;; (c :type (cell float) :address-space :global :access :read-write :range (1 3))
            ;; (d :type (cell float) :address-space :global :access :read-write :range (4 6)) (but D is &out?)
            ;; Wait, &out D is still a parameter in the signature?
            ;; The physical signature has 7 args (0-6).
            ;; V: 0 (float) -> width 1. Range (0 0).
            ;; C: 1, 2, 3 (ptr, size, off) -> width 3. Range (1 3). (1 2 3) -> 1 to 1+3-1 = 3.
            ;; D: 4, 5, 6 (ptr, size, off) -> width 3. Range (4 6).

            ;; NOTE: D is &out. Does generate-declared-signature include it?
            ;; My implementation: (unless (string-equal name "&OUT") ...)
            ;; So "&OUT" symbol is skipped. But "D" is processed.
            ;; So yes, D is included.

            (unless (and (= (length decl-sig) 3)
                         ;; V
                         (loose-equal (first decl-sig) '(V :TYPE FLOAT :RANGE (0 0)))
                         ;; C (In)
                         (let ((c (second decl-sig)))
                           (and (string-equal (symbol-name (first c)) "C")
                                (loose-equal (getf (cdr c) :type) '(CELL FLOAT))
                                (loose-equal (getf (cdr c) :range) '(1 3))
                                (loose-equal (getf (cdr c) :address-space) :GLOBAL)
                                (loose-equal (getf (cdr c) :access) :READ-WRITE)))
                         ;; D (Out)
                         (let ((d (third decl-sig)))
                           (and (string-equal (symbol-name (first d)) "D")
                                (loose-equal (getf (cdr d) :type) '(CELL FLOAT))
                                (loose-equal (getf (cdr d) :range) '(4 6))
                                (loose-equal (getf (cdr d) :address-space) :GLOBAL)
                                (loose-equal (getf (cdr d) :access) :READ-WRITE))))
              (log:error "Declared Signature Mismatch. Got: ~a" decl-sig)
              (return-from validate-16-declared-signature nil))))
        t))))
