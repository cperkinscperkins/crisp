;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;;; =========================================================
;;; 048-record-at-kernel-boundary  --  Metadata Validators
;;; src/metadata-val.lisp
;;; =========================================================

;;; Helpers

(defun %read-metacrisp-forms (path)
  "Reads all top-level forms from a .metacrisp file. Returns NIL if file missing."
  (when (probe-file path)
    (uiop:read-file-forms path)))

(defun %metacrisp-section (forms key)
  "Returns the cdr of the first top-level form whose car is KEY."
  (rest (find key forms :key #'car)))

(defun %metacrisp-find-kernel (forms kernel-name)
  "Returns the plist for the named kernel, or NIL."
  (block find-k
    (dolist (k (%metacrisp-section forms :kernels))
      (when (string-equal (getf k :name) kernel-name)
            (return-from find-k k)))))

(defun %find-record-def (records-section name)
  "Finds (def-record NAME ...) in a list of forms. Returns the form or NIL."
  (find name records-section
        :test (lambda (n f)
                (and (consp f)
                     (symbolp (second f))
                     (string-equal (symbol-name (second f)) n)))))

(defun %record-member-count (rec-form)
  "Counts the members listed in a (def-record NAME member...) form."
  (length (cddr rec-form)))

(defun %find-decl-entry (decl-sig name)
  "Finds the declared-signature entry whose :name matches (case-insensitive)."
  (find name decl-sig
        :test (lambda (n e) (string-equal (getf e :name) n))))

;;; Validator: 01-basic-rec-meta
;;; Tests that a flat def-record at the kernel boundary appears in :records,
;;; has the correct physical width, and shows up correctly in the declared sig.

(defun validate-def-record-in-metadata (metadata-path)
  "Validates 01-basic-rec-meta: v-point at kernel boundary.
   Checks :records section, physical width (2+3=5), and declared sig."
  (unless (probe-file metadata-path)
    (log:error "validate-def-record-in-metadata: file not found: ~a" metadata-path)
    (return-from validate-def-record-in-metadata nil))

  (let* ((forms (%read-metacrisp-forms metadata-path))
         (records (%metacrisp-section forms :records))
         (k-def (%metacrisp-find-kernel forms "record_on_boundary_k")))

    ;; :records section must exist
    (unless records
      (log:error "validate-def-record-in-metadata: no :records section")
      (return-from validate-def-record-in-metadata nil))

    ;; v-point must appear
    (let ((vp (%find-record-def records "v-point")))
      (unless vp
        (log:error "validate-def-record-in-metadata: v-point not in :records section")
        (return-from validate-def-record-in-metadata nil))
      ;; exactly 2 runtime members (x, y)
      (unless (= (%record-member-count vp) 2)
        (log:error "validate-def-record-in-metadata: expected 2 members for v-point, got ~a: ~a"
          (%record-member-count vp) (cddr vp))
        (return-from validate-def-record-in-metadata nil)))

    ;; v-rect must NOT appear (it is not at the kernel boundary)
    (when (%find-record-def records "v-rect")
      (log:error "validate-def-record-in-metadata: v-rect should NOT be in :records")
      (return-from validate-def-record-in-metadata nil))

    ;; kernel must be found
    (unless k-def
      (log:error "validate-def-record-in-metadata: kernel record_on_boundary_k not found")
      (return-from validate-def-record-in-metadata nil))

    ;; physical sig: 5 entries (2 for v-point fields + 3 for cell)
    (let ((phys (getf k-def :physical-signature)))
      (unless (= (length phys) 5)
        (log:error "validate-def-record-in-metadata: expected 5 physical-sig entries, got ~a: ~a"
          (length phys) phys)
        (return-from validate-def-record-in-metadata nil)))

    ;; declared sig: "vp" :in v-point, "c" :out
    (let ((decl (getf k-def :declared-signature)))
      (let ((vp-e (%find-decl-entry decl "vp")))
        (unless vp-e
          (log:error "validate-def-record-in-metadata: no 'vp' entry in declared-signature")
          (return-from validate-def-record-in-metadata nil))
        (unless (eq (getf vp-e :direction) :in)
          (log:error "validate-def-record-in-metadata: vp direction should be :in, got ~a"
            (getf vp-e :direction))
          (return-from validate-def-record-in-metadata nil))
        (unless (and (symbolp (getf vp-e :type))
                     (string-equal (symbol-name (getf vp-e :type)) "v-point"))
          (log:error "validate-def-record-in-metadata: vp :type should be v-point, got ~a"
            (getf vp-e :type))
          (return-from validate-def-record-in-metadata nil)))
      (let ((c-e (%find-decl-entry decl "c")))
        (unless c-e
          (log:error "validate-def-record-in-metadata: no 'c' entry in declared-signature")
          (return-from validate-def-record-in-metadata nil))
        (unless (eq (getf c-e :direction) :out)
          (log:error "validate-def-record-in-metadata: c direction should be :out, got ~a"
            (getf c-e :direction))
          (return-from validate-def-record-in-metadata nil))))

    (log:info "validate-def-record-in-metadata: PASS")
    t))


;;; Validator: 03-record-with-ct-meta
;;; Tests that a record with :c-t members shows only runtime members in :records,
;;; and that the c-t spec appears in the declared signature type.

(defun validate-def-rec-with-ct-in-metadata (metadata-path)
  "Validates 03-record-with-ct-meta: v-point with :c-t earnestness at kernel boundary.
   Checks :records shows only 2 runtime members, physical width is 2+2+3=7,
   and declared sig shows the full (v-point :earnestness 3.0) type for vp-2."
  (unless (probe-file metadata-path)
    (log:error "validate-def-rec-with-ct-in-metadata: file not found: ~a" metadata-path)
    (return-from validate-def-rec-with-ct-in-metadata nil))

  (let* ((forms (%read-metacrisp-forms metadata-path))
         (records (%metacrisp-section forms :records))
         (k-def (%metacrisp-find-kernel forms "record_on_boundary_k")))

    ;; :records section must exist and have v-point
    (unless records
      (log:error "validate-def-rec-with-ct-in-metadata: no :records section")
      (return-from validate-def-rec-with-ct-in-metadata nil))

    (let ((vp (%find-record-def records "v-point")))
      (unless vp
        (log:error "validate-def-rec-with-ct-in-metadata: v-point not in :records")
        (return-from validate-def-rec-with-ct-in-metadata nil))
      ;; earnestness is :c-t -- must NOT appear in the records section (runtime members only)
      (unless (= (%record-member-count vp) 2)
        (log:error "validate-def-rec-with-ct-in-metadata: expected 2 runtime members for v-point (no earnestness), got ~a: ~a"
          (%record-member-count vp) (cddr vp))
        (return-from validate-def-rec-with-ct-in-metadata nil)))

    (unless k-def
      (log:error "validate-def-rec-with-ct-in-metadata: kernel record_on_boundary_k not found")
      (return-from validate-def-rec-with-ct-in-metadata nil))

    ;; physical sig: 7 entries (2 + 2 + 3)
    (let ((phys (getf k-def :physical-signature)))
      (unless (= (length phys) 7)
        (log:error "validate-def-rec-with-ct-in-metadata: expected 7 physical-sig entries (2+2+3), got ~a: ~a"
          (length phys) phys)
        (return-from validate-def-rec-with-ct-in-metadata nil)))

    ;; declared sig: vp-1 :in v-point, vp-2 :in with list type (v-point :earnestness ...), c :out
    (let ((decl (getf k-def :declared-signature)))
      (let ((vp1 (%find-decl-entry decl "vp-1")))
        (unless (and vp1 (eq (getf vp1 :direction) :in))
          (log:error "validate-def-rec-with-ct-in-metadata: vp-1 not found or not :in")
          (return-from validate-def-rec-with-ct-in-metadata nil)))
      ;; vp-2 type should be a list form (v-point :earnestness ...)
      (let ((vp2 (%find-decl-entry decl "vp-2")))
        (unless vp2
          (log:error "validate-def-rec-with-ct-in-metadata: vp-2 not found in declared-signature")
          (return-from validate-def-rec-with-ct-in-metadata nil))
        (let ((typ (getf vp2 :type)))
          (unless (and (consp typ)
                       (symbolp (first typ))
                       (string-equal (symbol-name (first typ)) "v-point"))
            (log:error "validate-def-rec-with-ct-in-metadata: vp-2 :type should be (v-point ...), got ~a" typ)
            (return-from validate-def-rec-with-ct-in-metadata nil))))
      (let ((c-e (%find-decl-entry decl "c")))
        (unless (and c-e (eq (getf c-e :direction) :out))
          (log:error "validate-def-rec-with-ct-in-metadata: c not found or not :out")
          (return-from validate-def-rec-with-ct-in-metadata nil))))

    (log:info "validate-def-rec-with-ct-in-metadata: PASS")
    t))


;;; Validator: 04-nested-records-meta
;;; Tests that nested records (v-rect containing v-point) at the kernel boundary
;;; cause both records to appear in :records, and that the physical sig is
;;; fully flattened to primitive types.

(defun validate-nested-rec-in-metadata (metadata-path)
  "Validates 04-nested-records-meta: v-rect (containing v-point) at kernel boundary.
   Checks both records in :records section, physical width is 4+3=7,
   and declared sig shows vr with type v-rect and range (0 3)."
  (unless (probe-file metadata-path)
    (log:error "validate-nested-rec-in-metadata: file not found: ~a" metadata-path)
    (return-from validate-nested-rec-in-metadata nil))

  (let* ((forms (%read-metacrisp-forms metadata-path))
         (records (%metacrisp-section forms :records))
         (k-def (%metacrisp-find-kernel forms "rect_on_boundary_k")))

    (unless records
      (log:error "validate-nested-rec-in-metadata: no :records section")
      (return-from validate-nested-rec-in-metadata nil))

    ;; Both v-point and v-rect must appear
    (unless (%find-record-def records "v-point")
      (log:error "validate-nested-rec-in-metadata: v-point missing from :records (needed by v-rect)")
      (return-from validate-nested-rec-in-metadata nil))

    (unless (%find-record-def records "v-rect")
      (log:error "validate-nested-rec-in-metadata: v-rect missing from :records")
      (return-from validate-nested-rec-in-metadata nil))

    (unless k-def
      (log:error "validate-nested-rec-in-metadata: kernel rect_on_boundary_k not found")
      (return-from validate-nested-rec-in-metadata nil))

    ;; physical sig: 7 entries (v-rect flattens to 4 ints, cell = 3)
    (let ((phys (getf k-def :physical-signature)))
      (unless (= (length phys) 7)
        (log:error "validate-nested-rec-in-metadata: expected 7 physical-sig entries (4+3), got ~a: ~a"
          (length phys) phys)
        (return-from validate-nested-rec-in-metadata nil)))

    ;; declared sig: vr :in v-rect with range starting at 0 and spanning 4 slots
    (let* ((decl (getf k-def :declared-signature))
           (vr-e (%find-decl-entry decl "vr")))
      (unless vr-e
        (log:error "validate-nested-rec-in-metadata: no 'vr' in declared-signature")
        (return-from validate-nested-rec-in-metadata nil))
      (unless (eq (getf vr-e :direction) :in)
        (log:error "validate-nested-rec-in-metadata: vr direction should be :in, got ~a"
          (getf vr-e :direction))
        (return-from validate-nested-rec-in-metadata nil))
      (unless (and (symbolp (getf vr-e :type))
                   (string-equal (symbol-name (getf vr-e :type)) "v-rect"))
        (log:error "validate-nested-rec-in-metadata: vr :type should be v-rect, got ~a"
          (getf vr-e :type))
        (return-from validate-nested-rec-in-metadata nil))
      ;; range should be (0 3) -- 4 physical slots indexed 0..3
      (let ((range (getf vr-e :range)))
        (unless (and (listp range) (= (length range) 2)
                     (= (first range) 0) (= (second range) 3))
          (log:error "validate-nested-rec-in-metadata: vr :range should be (0 3), got ~a" range)
          (return-from validate-nested-rec-in-metadata nil))))

    (log:info "validate-nested-rec-in-metadata: PASS")
    t))


;;; Validator: 09-branded-rec-elide
;;; Tests that brand declarations are elided when a def-record with branding
;;; appears in the :records section -- only the base type is shown.

(defun validate-no-brand-in-metadata (metadata-path)
  "Validates 09-branded-rec-elide: branded def-record at kernel boundary.
   Checks that the :records section shows the base type (ulong) for branded
   fields, not the brand type (token-t), and no brand declarations appear."
  (unless (probe-file metadata-path)
    (log:error "validate-no-brand-in-metadata: file not found: ~a" metadata-path)
    (return-from validate-no-brand-in-metadata nil))

  (let* ((forms (%read-metacrisp-forms metadata-path))
         (records (%metacrisp-section forms :records))
         (k-def (%metacrisp-find-kernel forms "record_on_boundary_k")))

    (unless records
      (log:error "validate-no-brand-in-metadata: no :records section")
      (return-from validate-no-brand-in-metadata nil))

    (let ((vp (%find-record-def records "v-point")))
      (unless vp
        (log:error "validate-no-brand-in-metadata: v-point not in :records")
        (return-from validate-no-brand-in-metadata nil))

      ;; No member should be named "brand" -- brand declarations must be elided
      (dolist (m (cddr vp))
        (when (and (consp m) (symbolp (first m))
                   (string-equal (symbol-name (first m)) "brand"))
          (log:error "validate-no-brand-in-metadata: brand declaration found in :records -- should be elided: ~a" m)
          (return-from validate-no-brand-in-metadata nil)))

      ;; The x field should have ulong type (base of token-t brand), not token-t
      (let ((x-member (find "x" (cddr vp)
                            :test (lambda (n m) (and (consp m) (symbolp (first m))
                                                     (string-equal (symbol-name (first m)) n))))))
        (when x-member
          (let ((x-type (second x-member)))
            (when (and (symbolp x-type)
                       (string-equal (symbol-name x-type) "token-t"))
              (log:error "validate-no-brand-in-metadata: x field still shows brand type 'token-t', expected base type 'ulong'")
              (return-from validate-no-brand-in-metadata nil))))))

    (unless k-def
      (log:error "validate-no-brand-in-metadata: kernel record_on_boundary_k not found")
      (return-from validate-no-brand-in-metadata nil))

    (log:info "validate-no-brand-in-metadata: PASS")
    t))


;;; =========================================================
;;; 048-record-at-kernel-boundary  --  Core Implementation
;;; src/macros.lisp  (for %validate-kernel-parameters)
;;; src/metadata.lisp (for get-physical-width, generate-physical-signature,
;;;                       serialize-structs, generate-metadata-for-file)
;;; =========================================================

;;; --- Helpers ---

(defun %user-record-type-p (type-spec)
  "Returns T if TYPE-SPEC refers to a user-defined def-record (not a storage handle or primitive).
   Handles both bare symbols and list forms like (v-point :earnestness 3.0)."
  (when (%storage-handle-type-p type-spec)
    (return-from %user-record-type-p nil))
  (let* ((base-sym (cond
                     ((and (consp type-spec) (symbolp (car type-spec))) (car type-spec))
                     ((symbolp type-spec) (get-type-base type-spec))
                     (t nil)))
         (type-rec (when (and base-sym (symbolp base-sym))
                     (or (gethash base-sym *crisp-types*)
                         (gethash (intern (symbol-name base-sym) :crisp-language)
                                  *crisp-types*)))))
    (and type-rec (eq (crisp-type-category type-rec) :record))))

(defun %enumerate-physical-types (type-spec)
  "Returns a flat list of primitive Crisp type-specs for TYPE-SPEC.
   Records are recursively flattened to their runtime members (excluding :c-t members).
   List forms like (v-point :earnestness 3.0) use the base record type.
   Brand-typed members are resolved to their base types."
  (let* ((base-sym (cond
                     ((and (consp type-spec) (symbolp (car type-spec))
                           (not (%storage-handle-type-p type-spec)))
                      (car type-spec))
                     ((symbolp type-spec) type-spec)
                     (t nil)))
         (struct-def (when (and base-sym (symbolp base-sym))
                       (lookup-struct-definition base-sym)))
         (type-rec (when (and base-sym (symbolp base-sym))
                     (or (gethash base-sym *crisp-types*)
                         (gethash (intern (symbol-name base-sym) :crisp-language)
                                  *crisp-types*)))))
    (if (and type-rec (eq (crisp-type-category type-rec) :record) struct-def)
        ;; Record: flatten runtime members recursively
        (let* ((all-members (crisp-struct-definition-members struct-def))
               (runtime-members (remove-if (lambda (m) (and (consp m) (eq (third m) :c-t)))
                                           all-members)))
          (mapcan (lambda (m) (%enumerate-physical-types (second m))) runtime-members))
        ;; Not a record: resolve brand to base type if applicable
        (let* ((brand-def (and (symbolp type-spec) (is-brand-type-p type-spec)))
               (final-type (if brand-def (brand-definition-base-type brand-def) type-spec)))
          (list final-type)))))


;;; --- Redefine: get-physical-width
;;; src/metadata.lisp

(defun get-physical-width (type)
  "Returns the number of physical ABI slots for TYPE.
   Cell -> 3, Storage -> 2, user-defined records -> recursively counted, others -> 1."
  (cond
   ((%storage-handle-type-p type)
     (let* ((canonical (canonicalize-type-specifier type))
            (base (if (consp canonical) (first canonical) canonical)))
       (cond
        ((and (symbolp base) (string-equal (symbol-name base) "CELL"))
          3)
        (t 1))))
   ((or (and (symbolp type) (string-equal (symbol-name type) "STORAGE"))
        (and (consp type) (string-equal (symbol-name (car type)) "STORAGE")))
     2)
   ((%user-record-type-p type)
     (length (%enumerate-physical-types type)))
   (t 1)))


;;; --- Redefine: generate-physical-signature
;;; src/metadata.lisp

(defun generate-physical-signature (sig-or-params)
  "Generates the physical ABI signature from kernel parameters.
   Records are flattened to primitive scalar entries."
  (let ((params (if (typep sig-or-params 'function-signature)
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
           ;; STORAGE: flatten to PTR + I64
           ((or (and (symbolp type) (string-equal (symbol-name type) "STORAGE"))
                (and (consp type) (string-equal (symbol-name (car type)) "STORAGE")))
             (push (list current-index (strip-package-qualifiers '(c-pointer address-space global))) physical-args)
             (incf current-index)
             (push (list current-index (strip-package-qualifiers 'ulong)) physical-args)
             (incf current-index))

           ;; CELL: ptr + size + offset
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

           ;; User-defined record: flatten to primitive fields
           ((%user-record-type-p type)
             (dolist (prim-type (%enumerate-physical-types type))
               (push (list current-index (strip-package-qualifiers prim-type)) physical-args)
               (incf current-index)))

           ;; Scalar/other
           (t
             (push (list current-index (strip-package-qualifiers type)) physical-args)
             (incf current-index))))))
    (nreverse physical-args)))


;;; --- New: %serialize-records
;;; src/metadata.lisp

(defun %serialize-records (stream structs-hash)
  "Emits the (:records ...) section for user-defined records found in STRUCTS-HASH.
   Only runtime members are emitted (no :c-t members). Brand types resolved to base."
  (let ((record-names
          (loop for name being the hash-keys of structs-hash
                when (let* ((type-rec (or (gethash name *crisp-types*)
                                          (gethash (intern (symbol-name name) :crisp-language)
                                                   *crisp-types*))))
                       (and type-rec (eq (crisp-type-category type-rec) :record)))
                collect name)))
    (when record-names
      (format stream "(:records~%")
      (let ((sorted-names (sort-structs-by-dependency record-names)))
        (dolist (name sorted-names)
          (let ((def (gethash name *crisp-structs*)))
            (when def
              (format stream "  (def-record ~a" (strip-package-qualifiers name))
              (dolist (m (crisp-struct-definition-members def))
                (let* ((member-name (first m))
                       (member-type (second m))
                       (member-tag  (third m)))
                  ;; Skip :c-t compile-time members
                  (unless (eq member-tag :c-t)
                    (let* ((brand-def  (is-brand-type-p member-type))
                           (final-type (if brand-def
                                           (brand-definition-base-type brand-def)
                                           member-type)))
                      (format stream " (~a ~a)"
                        (strip-package-qualifiers member-name)
                        (strip-package-qualifiers final-type))))))
              (format stream ")~%")))))
      (format stream "  )~%~%"))))


;;; --- Redefine: serialize-structs
;;; src/metadata.lisp

(defun serialize-structs (stream structs-hash)
  "Emits (:records ...) for def-records and (:structs ...) for def-structs.
   Records are split into their own section; brand and :c-t members handled appropriately."
  ;; Records section first
  (%serialize-records stream structs-hash)
  ;; Then structs section (non-record types only)
  (let ((struct-names
          (loop for name being the hash-keys of structs-hash
                unless (let* ((type-rec (or (gethash name *crisp-types*)
                                            (gethash (intern (symbol-name name) :crisp-language)
                                                     *crisp-types*))))
                          (and type-rec (eq (crisp-type-category type-rec) :record)))
                collect name)))
    (format stream "(:structs~%")
    (let ((sorted-names (sort-structs-by-dependency struct-names)))
      (dolist (name sorted-names)
        (let ((def (gethash name *crisp-structs*)))
          (when def
            (format stream "  (def-struct ~a" (strip-package-qualifiers name))
            (dolist (m (crisp-struct-definition-members def))
              (let* ((member-name (first m))
                     (member-type (second m))
                     (brand-def   (is-brand-type-p member-type))
                     (final-type  (if brand-def
                                      (brand-definition-base-type brand-def)
                                      member-type)))
                (format stream " (~a ~a)"
                  (strip-package-qualifiers member-name)
                  (strip-package-qualifiers final-type))))
            (format stream ")~%")))))
    (format stream "  )~%~%")))


;;; --- Redefine: generate-declared-signature (debug wrapper)
;;; src/metadata.lisp
;;; Wraps each step with diagnostic output to track the (INTEGER 1 3) crash.

(defun generate-declared-signature (sig &optional declared-params)
  "Generates the declared-signature plist for a kernel's metadata.
   Handles user-defined records by using the corrected get-physical-width."
  (let ((declared-args nil)
        (current-phys-index 0)
        (out-mode nil)
        (params-to-use (or declared-params (function-signature-parameters sig))))

    ;; Count implicit params
    (dolist (p (function-signature-implicit-parameters sig))
      (incf current-phys-index (get-physical-width (parameter-def-type p))))

    (dolist (param-def params-to-use)
      (let* ((name (if (consp param-def) (car param-def) (parameter-def-name param-def)))
             (type (if (consp param-def) (cdr param-def) (parameter-def-type param-def))))

        (if (and (symbolp name) (string-equal (symbol-name name) "&OUT"))
            (setf out-mode t)
            (let* ((width (get-physical-width type))
                   (start current-phys-index)
                   (end (+ start (max 0 (1- width))))
                   (entry (list :name (string-downcase (symbol-name name)))))

              (setf entry (append entry (list :type (strip-package-qualifiers type))))
              (setf entry (append entry (list :direction (if out-mode :out :in))))

              (when (%storage-handle-type-p type)
                    (let* ((canonical (canonicalize-type-specifier type))
                           (base (if (consp canonical) (first canonical) canonical))
                           (is-cell (and (symbolp base) (string-equal (symbol-name base) "CELL")))
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

              (setf entry (append entry (list :range (list start end))))
              (push entry declared-args)
              (incf current-phys-index width)))))
    (nreverse declared-args)))


;;; --- Redefine: %validate-kernel-parameters
;;; src/macros.lisp

(defun %validate-kernel-parameters (params type-map name)
  "Helper: Validates that kernel parameters are complete, not voidp,
   and that records do not appear in &out position."
  (dolist (p params)
    (let ((t-spec (gethash p type-map)))
      (when (and t-spec (%incomplete-storage-handle-p t-spec))
            (error "def-kernel parameter '~a' has incomplete storage handle type ~a. Kernels require fully specified types (e.g. specify :address-space and :access)."
              p t-spec))))

  ;; Build signature types
  (let ((signature-types nil)
        (p-ptr params))
    (loop while p-ptr do
            (let ((p (pop p-ptr)))
              (if (and (symbolp p) (string-equal (symbol-name p) "&OUT"))
                  (let* ((real-p (pop p-ptr))
                         (type (gethash real-p type-map)))
                    (push '&out signature-types)
                    (push (if (and (consp type) (eq (car type) '&out)) (second type) type) signature-types))
                  (push (gethash p type-map) signature-types))))
    (setf signature-types (nreverse signature-types))

    ;; Check all params have types
    (unless (every #'identity signature-types)
      (error "def-kernel ~a: Missing type declarations for parameters: ~a" name
        (loop for p in params for t-spec in signature-types unless t-spec collect p)))

    ;; Validate each type (completeness and voidp)
    (loop for t-spec in signature-types
          do (when (incomplete-type-p t-spec)
                   (error "Kernel parameters must be COMPLETE types. Found incomplete: ~a" t-spec))
            (let ((canon (canonicalize-type-specifier t-spec)))
              (when (or (eq canon 'voidp)
                        (and (symbolp canon) (string-equal (symbol-name canon) "VOIDP")))
                    (error "Kernel parameters cannot be of type 'voidp'. Use a specific pointer type with address space or a storage handle."))))

    ;; Records must NOT appear in &out position
    (let ((sig-ptr (copy-list signature-types)))
      (loop while sig-ptr do
              (let ((t-spec (pop sig-ptr)))
                (when (and (symbolp t-spec) (string-equal (symbol-name t-spec) "&OUT"))
                  (let ((next-type (first sig-ptr)))
                    (when (and next-type (%user-record-type-p next-type))
                      (error "Record type ~a cannot appear in &out position at the kernel boundary. Only storage handles (cell, vector, matrix) support &out position."
                        next-type)))))))

    signature-types))


;;; --- Redefine: get-expanded-types, explode-value, implode-value
;;; src/codegen/abi.lisp
;;; Fix: handle list-form record types like (v-point :earnestness 3.0).
;;; Previously, non-storage list forms used the whole list as the hash key,
;;; so gethash returned NIL and the type was not recognised as a record.
;;; Fix: when type-spec is a non-storage cons, peek at (car type-spec);
;;; if the base is a user record type, use it as the lookup key.
;;; Plain symbols and storage list forms are handled exactly as before.

(defun %record-base-from-list-form (type-spec)
  "If TYPE-SPEC is a non-storage list form like (V-POINT :EARNESTNESS 3.0),
   returns the base symbol V-POINT if it resolves to a user record type.
   Otherwise returns NIL.  Plain symbols and storage list forms return NIL."
  (when (and (consp type-spec)
             (symbolp (first type-spec))
             ;; Not a storage handle list form
             (not (member (symbol-name (first type-spec))
                          '("CELL" "STORAGE" "VECTOR" "MATRIX" "TENSOR")
                          :test #'string-equal)))
    (let* ((base (first type-spec))
           (type-rec (or (gethash base *crisp-types*)
                         (let ((alt (intern (symbol-name base) (find-package :crisp-language))))
                           (gethash alt *crisp-types*)))))
      (when (and type-rec (eq (crisp-type-category type-rec) :record))
        base))))

(defun get-expanded-types (type-spec module)
  "Returns a list of LLVM types for a given Crisp type spec.
   For 'cell', returns (ptr i64 i64). For 'storage', returns (ptr i64).
   For records, explodes recursively. For others, returns (type).
   Handles list-form parameterised record types like (V-POINT :EARNESTNESS 3.0).
   If *target-backend* is :spirv or :ptx, upgrades pointers to Global Address Space (1)."
  (let* (;; Detect non-storage record list form: (V-POINT :EARNESTNESS 3.0) -> V-POINT
         (record-base (%record-base-from-list-form type-spec))
         (is-storage-list (and (consp type-spec)
                               (symbolp (first type-spec))
                               (member (symbol-name (first type-spec)) '("CELL" "STORAGE" "VECTOR" "MATRIX" "TENSOR")
                                       :test #'string-equal)))
         (lookup-spec (cond
                        (record-base record-base)             ;; NEW: strip to base for record list forms
                        (is-storage-list
                         (progn
                          (log:debug "GET-EXPANDED-TYPES: Storage handle list form detected: ~s" type-spec)
                          (let ((mangled (mangle-template-struct-name (first type-spec) (rest type-spec))))
                            (log:debug "  Mangled to: ~s (package: ~a)" mangled (package-name (symbol-package mangled)))
                            mangled)))
                        (t type-spec)))
         ;; Ensure type is instantiated/registered
         (ignored (ignore-errors (resolve-type-to-llvm lookup-spec)))
         ;; Type lookup: for the new record-base case, also try crisp-language package
         (type-rec (or (gethash lookup-spec *crisp-types*)
                       (when (and record-base (symbolp lookup-spec))
                         (let ((alt (intern (symbol-name lookup-spec) (find-package :crisp-language))))
                           (gethash alt *crisp-types*)))
                       (when (and is-storage-list (symbolp lookup-spec))
                         (let ((alt-symbol (intern (symbol-name lookup-spec) (find-package :crisp-language))))
                           (gethash alt-symbol *crisp-types*)))))
         (struct-def (lookup-struct-definition lookup-spec))
         (actual-key (cond
                       ((gethash lookup-spec *crisp-types*) lookup-spec)
                       ((and (or record-base is-storage-list) (symbolp lookup-spec))
                        (let ((alt (intern (symbol-name lookup-spec) (find-package :crisp-language))))
                          (if (gethash alt *crisp-types*) alt lookup-spec)))
                       (t lookup-spec)))
         (expanded
          (progn
            (log:debug "GET-EXPANDED-TYPES: type-spec=~s lookup=~s found-type=~a found-struct=~a category=~a"
                       type-spec actual-key
                       (if type-rec "YES" "NO")
                       (if struct-def "YES" "NO")
                       (when type-rec (crisp-type-category type-rec)))
            (cond
              ;; Case 1: Record Type -> Explode recursively
              ((and type-rec (eq (crisp-type-category type-rec) :record))
               (when struct-def
                 (let* ((members (crisp-struct-definition-members struct-def))
                        (runtime-members (remove-if (lambda (m) (and (consp m) (eq (third m) :c-t))) members)))
                   (mapcan (lambda (m) (get-expanded-types (second m) module)) runtime-members))))
              ;; Case 2: Standard Type (Struct/Scalar) -> Return as is
              (t (list (crisp-type-to-llvm-type actual-key module)))))))

    ;; Post-Processing: Apply Address Spaces for GPU Backends
    (if (and (or (eq *target-backend* :spirv) (eq *target-backend* :ptx))
             (is-global-storage-handle-p type-spec))
        (mapcar (lambda (ty)
                  (if (llvm-type-kind-is-pointer? ty)
                      (llvm-pointer-type (llvm-int8-type-in-context (llvm-get-module-context module))
                                         (encode-address-space :global))
                      ty))
                expanded)
        expanded)))

(defun explode-value (builder agg-val type-spec)
  "Extracts components from an aggregate value if necessary.
   Returns a list of LLVM values.
   Handles list-form parameterised record types like (V-POINT :EARNESTNESS 3.0)."
  (let* ((record-base (%record-base-from-list-form type-spec))
         (lookup-spec (if record-base
                          record-base
                          (if (and (consp type-spec)
                                   (symbolp (first type-spec))
                                   (member (symbol-name (first type-spec)) '("CELL" "STORAGE" "VECTOR" "MATRIX" "TENSOR")
                                           :test #'string-equal))
                              (mangle-template-struct-name (first type-spec) (rest type-spec))
                              type-spec)))
         (type-rec (or (gethash lookup-spec *crisp-types*)
                       ;; For record-base case, try crisp-language
                       (when record-base
                         (gethash (intern (symbol-name lookup-spec) (find-package :crisp-language))
                                  *crisp-types*)))))
    (cond
      ((and type-rec (eq (crisp-type-category type-rec) :record))
       (let* ((struct-def (lookup-struct-definition lookup-spec))
              (members (crisp-struct-definition-members struct-def))
              (runtime-members (remove-if (lambda (m) (and (consp m) (eq (third m) :c-t))) members))
              (values '()))
         (loop for m in runtime-members
               for i from 0
               do (let* ((member-type (second m))
                         (extracted (llvm-build-extract-value builder agg-val i (format nil "~a_val" (first m)))))
                    (setf values (append values (explode-value builder extracted member-type)))))
         values))
      (t (list agg-val)))))

(defun implode-value (builder components type-spec module)
  "Combines components into an aggregate value if necessary.
   Returns a single LLVM value.
   Handles list-form parameterised record types like (V-POINT :EARNESTNESS 3.0)."
  (let* ((record-base (%record-base-from-list-form type-spec))
         (lookup-spec (if record-base
                          record-base
                          (if (and (consp type-spec)
                                   (symbolp (first type-spec))
                                   (member (symbol-name (first type-spec)) '("CELL" "STORAGE" "VECTOR" "MATRIX" "TENSOR")
                                           :test #'string-equal))
                              (mangle-template-struct-name (first type-spec) (rest type-spec))
                              type-spec)))
         (type-rec (or (gethash lookup-spec *crisp-types*)
                       ;; For record-base case, try crisp-language
                       (when record-base
                         (gethash (intern (symbol-name lookup-spec) (find-package :crisp-language))
                                  *crisp-types*)))))
    (cond
      ((and type-rec (eq (crisp-type-category type-rec) :record))
       (let* ((struct-def (lookup-struct-definition lookup-spec))
              (members (crisp-struct-definition-members struct-def))
              (runtime-members (remove-if (lambda (m) (and (consp m) (eq (third m) :c-t))) members))
              (record-type (crisp-type-to-llvm-type lookup-spec module))
              (agg (llvm-get-undef record-type))
              (current-components components))
         (loop for m in runtime-members
               for i from 0
               do (let* ((member-type (second m))
                         (member-val (implode-value builder current-components member-type module))
                         (consumed-count (length (get-expanded-types member-type module))))
                    (setf agg (llvm-build-insert-value builder agg member-val i (format nil "~a_ins" (first m))))
                    (setf current-components (subseq current-components consumed-count))))
         agg))
      (t (first components)))))


;;; --- Redefine: %generate-struct-accessor
;;; src/macros.lisp
;;; Fix: typed-literal symbols (e.g. 2.0f read as a symbol by SBCL) in :c-t
;;; default values were embedded as-is in the constant accessor macro.
;;; The type checker then inferred SYMBOL instead of FLOAT, causing a type
;;; mismatch when the accessor was used in a kernel body.
;;; Fix: resolve known typed-literal suffixes to their numeric values before
;;; embedding them in the generated defmacro.

(defun %parse-ct-literal (value)
  "If VALUE is a symbol whose name looks like a typed numeric literal (e.g. 2.0F,
   100UC), parse and return the underlying number.  Otherwise return VALUE unchanged."
  (if (not (symbolp value))
      value
      (let* ((name (symbol-name value))
             ;; Longest-first so BF is checked before F, UL before L, etc.
             (suffixes '("BF" "UC" "UL" "US" "U" "S" "L" "H" "F"))
             (suffix (some (lambda (s)
                             (let ((sl (length s)) (nl (length name)))
                               (when (and (> nl sl)
                                          (string= s (subseq name (- nl sl))))
                                 s)))
                           suffixes)))
        (if suffix
            (let* ((num-str (subseq name 0 (- (length name) (length suffix))))
                   (parsed  (ignore-errors (read-from-string num-str))))
              (if (numberp parsed) parsed value))
            value))))

(defun %generate-struct-accessor (member-spec name pkg runtime-index)
  "Helper: Generates accessor (and setter) for a single struct member.
   Returns (values accessor-form new-runtime-index).
   Fix: typed-literal symbols in :c-t defaults are resolved to their numeric values."
  (let* ((member-name (first member-spec))
         (is-ct (and (consp member-spec) (eq (third member-spec) :c-t)))
         (raw-value (when is-ct (fourth member-spec)))
         ;; Resolve typed-literal symbols (e.g. 2.0F -> 2.0) for c-t defaults.
         (value (when is-ct (%parse-ct-literal raw-value)))
         (accessor-name (intern (format nil "~a~~" member-name) pkg)))
    (cond
     ;; Compile-time member with value -> constant accessor macro
     ((and is-ct value)
       (values `(defmacro ,accessor-name (obj)
                  (declare (ignore obj))
                  ',value)
         runtime-index))
     ;; Compile-time member without value -> skip (incomplete type)
     (is-ct
       (values nil runtime-index))
     ;; Runtime member -> function accessor
     (t
       (let ((idx runtime-index))
         (values `(def-function ,accessor-name ((obj ,name))
                                (return (%extract-struct-member obj ,idx)))
           (1+ runtime-index)))))))

;;; =========================================================
;;; 048-record-at-kernel-boundary -- Fix float c-t literal in parameterized type
;;; src/analysis/structs.lisp
;;;
;;; analyze-incomplete-type-accessor fell through to value-type 'quote
;;; for float values (e.g. (v-point :earnestness 3.0)).  Add a float case.

(defun analyze-incomplete-type-accessor (op expr env context location)
  "Attempts to resolve a call like (color~ obj) where obj is (shirt :color :blue).
   Returns a semantic-node (literal) if resolved, or NIL if not applicable.

   Fix: float values now return value-type 'float instead of 'quote."
  (let ((op-name (symbol-name op)))
    (when (and (> (length op-name) 1) (alexandria:ends-with #\~ op-name))
          (let* ((member-name (intern (string-trim "~" op-name) (symbol-package op)))
                 (obj-expr (second expr)))
            (when obj-expr
                  (let* ((obj-node (analyze-expression obj-expr env context (append location '(1))))
                         (obj-type (semantic-node-type obj-node)))
                    (when (and (consp obj-type) (valid-type-p obj-type))
                          (let* ((canon (canonicalize-type-specifier obj-type))
                                 (base (first canon))
                                 (params (rest canon)))
                            (log:info "  ObjType: ~s Canon: ~s Params: ~s" obj-type canon params)
                            (when (or (gethash base *crisp-structs*) (gethash base *crisp-types*))
                                  (let ((kw (intern (symbol-name member-name) "KEYWORD")))
                                    (let ((val (getf params kw)))
                                      (when val
                                            (cond
                                             ((keywordp val) (make-semantic-literal :value-type 'keyword :value val :source-location location))
                                             ((symbolp val)  (make-semantic-literal :value-type 'symbol  :value val :source-location location))
                                             ((integerp val) (make-semantic-literal :value-type 'int     :value val :source-location location))
                                             ((floatp val)   (make-semantic-literal :value-type 'float   :value val :source-location location))
                                             (t (make-semantic-literal :value-type 'quote :value val :source-location location)))))))))))))))

