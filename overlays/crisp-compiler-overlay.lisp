;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)


;;; -----------------------------------------------------------------------
;;; FIX: extract-kernel-params and ir-type-to-opencl-metadata
;;; src/compiler.lisp
;;;
;;; extract-kernel-params dropped struct-typed params because LLVM IR
;;; struct types start with %, e.g. "%POINT %0". The original code used
;;; the first % as the type/name boundary, yielding an empty type string
;;; that was then silently skipped.
;;;
;;; ir-type-to-opencl-metadata had no clause for struct types, falling
;;; through to the default "void*" name.
;;;
;;; Both bugs caused llvm-spirv to reject the .bc with a metadata count
;;; mismatch when a def-struct appeared directly as a kernel parameter.
;;; -----------------------------------------------------------------------

;; src/compiler.lisp
(defun extract-kernel-params (ir-text func-start func-end)
  "Extract parameter types from a kernel function signature.
Returns list of type strings (e.g., 'ptr addrspace(1)', 'i64', '%POINT')."
  (let* ((sig-text (subseq ir-text func-start func-end))
         (paren-start (position #\( sig-text))
         (paren-end (position #\) sig-text :from-end t)))

    (unless (and paren-start paren-end (< paren-start paren-end))
      (log:warn "Could not find parameter parens!")
      (return-from extract-kernel-params nil))

    (let* ((params-text (subseq sig-text (1+ paren-start) paren-end))
           (params '()))

      (log:info "extract-kernel-params: params-text = ~s" params-text)

      (dolist (param-str (uiop:split-string params-text :separator ","))
        (let ((trimmed (string-trim '(#\Space #\Tab #\Newline #\Return) param-str)))
          (when (> (length trimmed) 0)
                (let ((percent-pos (position #\% trimmed)))
                  (if percent-pos
                      (if (zerop percent-pos)
                          ;; Struct type: starts with %, e.g. "%POINT %0".
                          ;; Use the LAST % as the name boundary.
                          (let* ((last-percent (position #\% trimmed :from-end t))
                                 (type-text (string-trim '(#\Space #\Tab)
                                                         (subseq trimmed 0 last-percent))))
                            (when (> (length type-text) 0)
                                  (log:info "  extracted struct type: ~s" type-text)
                                  (push type-text params)))
                          ;; Normal case: type precedes the first %.
                          (let ((type-text (string-trim '(#\Space #\Tab)
                                                        (subseq trimmed 0 percent-pos))))
                            (when (> (length type-text) 0)
                                  (log:info "  extracted type: ~s" type-text)
                                  (push type-text params))))
                      (progn
                       (log:info "  extracted type (no name): ~s" trimmed)
                       (push trimmed params)))))))

      (nreverse params))))

;; src/compiler.lisp
(defun ir-type-to-opencl-metadata (ir-type)
  "Convert LLVM IR type to OpenCL metadata (addr-space, access-qual, type-name).
Returns (values addr-space-int access-qual-string type-name-string)."
  (let ((addr-space 0)
        (access-qual "none")
        (type-name "void*"))

    (cond
     ;; Struct types: start with % (e.g. \"%POINT\")
     ;; Passed by value, addr-space 0, type-name is the struct name without %
     ((and (> (length ir-type) 0) (char= (cl:char ir-type 0) #\%))
       (setf addr-space 0
             type-name (subseq ir-type 1)))

     ;; Pointer types: ptr addrspace(N)
     ((search "ptr" ir-type)
       (cond
        ((search "addrspace(1)" ir-type)
          (setf addr-space 1 type-name "int*"))
        ((search "addrspace(2)" ir-type)
          (setf addr-space 2 type-name "int*"))
        ((search "addrspace(3)" ir-type)
          (setf addr-space 3 type-name "int*"))
        (t
          (setf addr-space 0 type-name "int*"))))

     ;; Integer types
     ((search "i64" ir-type)
       (setf addr-space 0 type-name "ulong"))
     ((search "i32" ir-type)
       (setf addr-space 0 type-name "uint"))
     ((search "i8" ir-type)
       (setf addr-space 0 type-name "uchar"))

     ;; Floating point
     ((search "float" ir-type)
       (setf addr-space 0 type-name "float"))
     ((search "double" ir-type)
       (setf addr-space 0 type-name "double")))

    (values addr-space access-qual type-name)))

;;; -----------------------------------------------------------------------
;;; Validators: 056-struct-at-kernel-boundary metadata tests
;;; src/metadata-val.lisp
;;;
;;; Helper: %find-struct-def is the struct counterpart to %find-record-def.
;;; It finds (def-struct NAME ...) in a :structs section list.
;;; Note: %find-record-def already works generically (doesn't enforce
;;; def-record vs def-struct), so %find-struct-def is a named alias for
;;; clarity.
;;; -----------------------------------------------------------------------

;; src/metadata-val.lisp
(defun %find-struct-def (structs-section name)
  "Finds (def-struct NAME ...) in a list of forms from a :structs section.
Returns the form or NIL."
  (find name structs-section
        :test (lambda (n f)
                (and (consp f)
                     (symbolp (second f))
                     (string-equal (symbol-name (second f)) n)))))

;;; Validator: 056/01-basic-struct-meta
;;; Tests that a plain def-struct at the kernel boundary appears in :structs,
;;; has the correct 2 members, and shows up as a single physical slot.

;; src/metadata-val.lisp
(defun validate-def-struct-in-metadata (metadata-path)
  "Validates 056/01-basic-struct-meta: point at kernel boundary.
   Checks :structs contains POINT (2 members) but NOT RECT,
   physical-signature has 4 entries (1 struct + 3 cell), and
   declared-signature shows p :in with type point."
  (unless (probe-file metadata-path)
    (log:error "validate-def-struct-in-metadata: file not found: ~a" metadata-path)
    (return-from validate-def-struct-in-metadata nil))

  (let* ((forms (%read-metacrisp-forms metadata-path))
         (structs (%metacrisp-section forms :structs))
         (k-def (%metacrisp-find-kernel forms "struct_on_boundary_k")))

    ;; :structs section must exist
    (unless structs
      (log:error "validate-def-struct-in-metadata: no :structs section")
      (return-from validate-def-struct-in-metadata nil))

    ;; POINT must appear with 2 members (X, Y)
    (let ((pt (%find-struct-def structs "point")))
      (unless pt
        (log:error "validate-def-struct-in-metadata: point not in :structs")
        (return-from validate-def-struct-in-metadata nil))
      (unless (= (%record-member-count pt) 2)
        (log:error "validate-def-struct-in-metadata: expected 2 members for point, got ~a: ~a"
          (%record-member-count pt) (cddr pt))
        (return-from validate-def-struct-in-metadata nil)))

    ;; RECT must NOT appear (not at the kernel boundary)
    (when (%find-struct-def structs "rect")
      (log:error "validate-def-struct-in-metadata: rect should NOT be in :structs")
      (return-from validate-def-struct-in-metadata nil))

    ;; kernel must be found
    (unless k-def
      (log:error "validate-def-struct-in-metadata: kernel struct_on_boundary_k not found")
      (return-from validate-def-struct-in-metadata nil))

    ;; physical sig: 4 entries (1 struct + 3 cell)
    (let ((phys (getf k-def :physical-signature)))
      (unless (= (length phys) 4)
        (log:error "validate-def-struct-in-metadata: expected 4 physical-sig entries (1 struct + 3 cell), got ~a: ~a"
          (length phys) phys)
        (return-from validate-def-struct-in-metadata nil))
      ;; first entry should be the struct type
      (unless (and (consp (first phys))
                   (string-equal (symbol-name (second (first phys))) "point"))
        (log:error "validate-def-struct-in-metadata: expected first physical-sig entry to be (0 POINT), got ~a"
          (first phys))
        (return-from validate-def-struct-in-metadata nil)))

    ;; declared sig: p :in point, c :out
    (let* ((decl (getf k-def :declared-signature))
           (p-e (%find-decl-entry decl "p"))
           (c-e (%find-decl-entry decl "c")))
      (unless p-e
        (log:error "validate-def-struct-in-metadata: no 'p' entry in declared-signature")
        (return-from validate-def-struct-in-metadata nil))
      (unless (eq (getf p-e :direction) :in)
        (log:error "validate-def-struct-in-metadata: p direction should be :in, got ~a"
          (getf p-e :direction))
        (return-from validate-def-struct-in-metadata nil))
      (unless (and (symbolp (getf p-e :type))
                   (string-equal (symbol-name (getf p-e :type)) "point"))
        (log:error "validate-def-struct-in-metadata: p :type should be point, got ~a"
          (getf p-e :type))
        (return-from validate-def-struct-in-metadata nil))
      (unless c-e
        (log:error "validate-def-struct-in-metadata: no 'c' entry in declared-signature")
        (return-from validate-def-struct-in-metadata nil))
      (unless (eq (getf c-e :direction) :out)
        (log:error "validate-def-struct-in-metadata: c direction should be :out, got ~a"
          (getf c-e :direction))
        (return-from validate-def-struct-in-metadata nil)))

    (log:info "validate-def-struct-in-metadata: PASS")
    t))


;;; Validator: 056/03-struct-with-ct-meta
;;; Tests that a struct with a :c-t field appears correctly in :structs.
;;; c-t fields are compile-time constants (not in the runtime layout), so
;;; they must be excluded from the :structs section (same as compute-std140-layout
;;; excludes them).  Only the 2 runtime members (x, y) should appear.
;;; The parameterized type (point :earnestness 3.0) still appears in declared-sig.

;; src/metadata-val.lisp
(defun validate-def-struct-with-ct-in-metadata (metadata-path)
  "Validates 056/03-struct-with-ct-meta: point with :c-t earnestness.
   Checks :structs shows 2 runtime members only (c-t earnestness excluded),
   physical-signature has 5 entries (2 struct + 3 cell), and
   declared-sig shows (point earnestness 3.0) for p2."
  (unless (probe-file metadata-path)
    (log:error "validate-def-struct-with-ct-in-metadata: file not found: ~a" metadata-path)
    (return-from validate-def-struct-with-ct-in-metadata nil))

  (let* ((forms (%read-metacrisp-forms metadata-path))
         (structs (%metacrisp-section forms :structs))
         (k-def (%metacrisp-find-kernel forms "struct_on_boundary_k")))

    (unless structs
      (log:error "validate-def-struct-with-ct-in-metadata: no :structs section")
      (return-from validate-def-struct-with-ct-in-metadata nil))

    ;; POINT must appear with 2 runtime members (x, y) — earnestness is c-t, excluded
    (let ((pt (%find-struct-def structs "point")))
      (unless pt
        (log:error "validate-def-struct-with-ct-in-metadata: point not in :structs")
        (return-from validate-def-struct-with-ct-in-metadata nil))
      (unless (= (%record-member-count pt) 2)
        (log:error "validate-def-struct-with-ct-in-metadata: expected 2 runtime members for point (c-t earnestness excluded), got ~a: ~a"
          (%record-member-count pt) (cddr pt))
        (return-from validate-def-struct-with-ct-in-metadata nil)))

    (unless k-def
      (log:error "validate-def-struct-with-ct-in-metadata: kernel struct_on_boundary_k not found")
      (return-from validate-def-struct-with-ct-in-metadata nil))

    ;; physical sig: 5 entries (p1 + p2 as structs + 3 cell)
    (let ((phys (getf k-def :physical-signature)))
      (unless (= (length phys) 5)
        (log:error "validate-def-struct-with-ct-in-metadata: expected 5 physical-sig entries (2 structs + 3 cell), got ~a: ~a"
          (length phys) phys)
        (return-from validate-def-struct-with-ct-in-metadata nil)))

    ;; declared sig: p1 :in point, p2 :in (point earnestness 3.0), c :out
    (let* ((decl (getf k-def :declared-signature))
           (p2-e (%find-decl-entry decl "p2")))
      (unless p2-e
        (log:error "validate-def-struct-with-ct-in-metadata: no 'p2' entry in declared-signature")
        (return-from validate-def-struct-with-ct-in-metadata nil))
      ;; p2 type must be a parameterized form (point earnestness 3.0)
      (unless (and (consp (getf p2-e :type))
                   (string-equal (symbol-name (first (getf p2-e :type))) "point"))
        (log:error "validate-def-struct-with-ct-in-metadata: p2 type should be (point ...), got ~a"
          (getf p2-e :type))
        (return-from validate-def-struct-with-ct-in-metadata nil)))

    (log:info "validate-def-struct-with-ct-in-metadata: PASS")
    t))


;;; Validator: 056/04-nested-structs-meta
;;; Tests that when a struct containing another struct is at the kernel
;;; boundary, BOTH structs appear in :structs via dependency collection.

;; src/metadata-val.lisp
(defun validate-nested-struct-in-metadata (metadata-path)
  "Validates 056/04-nested-structs-meta: rect (containing point) at kernel boundary.
   Checks :structs contains both RECT and POINT (dependency),
   physical-signature has 4 entries (1 struct + 3 cell), and
   declared-sig shows r :in rect."
  (unless (probe-file metadata-path)
    (log:error "validate-nested-struct-in-metadata: file not found: ~a" metadata-path)
    (return-from validate-nested-struct-in-metadata nil))

  (let* ((forms (%read-metacrisp-forms metadata-path))
         (structs (%metacrisp-section forms :structs))
         (k-def (%metacrisp-find-kernel forms "rect_on_boundary_k")))

    (unless structs
      (log:error "validate-nested-struct-in-metadata: no :structs section")
      (return-from validate-nested-struct-in-metadata nil))

    ;; Both POINT and RECT must appear (dependency collection)
    (unless (%find-struct-def structs "point")
      (log:error "validate-nested-struct-in-metadata: point not in :structs (expected via dependency)")
      (return-from validate-nested-struct-in-metadata nil))
    (unless (%find-struct-def structs "rect")
      (log:error "validate-nested-struct-in-metadata: rect not in :structs")
      (return-from validate-nested-struct-in-metadata nil))

    (unless k-def
      (log:error "validate-nested-struct-in-metadata: kernel rect_on_boundary_k not found")
      (return-from validate-nested-struct-in-metadata nil))

    ;; physical sig: 4 entries (1 struct + 3 cell)
    (let ((phys (getf k-def :physical-signature)))
      (unless (= (length phys) 4)
        (log:error "validate-nested-struct-in-metadata: expected 4 physical-sig entries (1 struct + 3 cell), got ~a: ~a"
          (length phys) phys)
        (return-from validate-nested-struct-in-metadata nil))
      ;; first entry should be RECT
      (unless (and (consp (first phys))
                   (string-equal (symbol-name (second (first phys))) "rect"))
        (log:error "validate-nested-struct-in-metadata: expected first physical-sig entry to be (0 RECT), got ~a"
          (first phys))
        (return-from validate-nested-struct-in-metadata nil)))

    ;; declared sig: r :in rect, c :out
    (let* ((decl (getf k-def :declared-signature))
           (r-e (%find-decl-entry decl "r")))
      (unless r-e
        (log:error "validate-nested-struct-in-metadata: no 'r' entry in declared-signature")
        (return-from validate-nested-struct-in-metadata nil))
      (unless (and (symbolp (getf r-e :type))
                   (string-equal (symbol-name (getf r-e :type)) "rect"))
        (log:error "validate-nested-struct-in-metadata: r :type should be rect, got ~a"
          (getf r-e :type))
        (return-from validate-nested-struct-in-metadata nil))
      (unless (eq (getf r-e :direction) :in)
        (log:error "validate-nested-struct-in-metadata: r direction should be :in, got ~a"
          (getf r-e :direction))
        (return-from validate-nested-struct-in-metadata nil)))

    (log:info "validate-nested-struct-in-metadata: PASS")
    t))


;;; -----------------------------------------------------------------------
;;; Validator: 056/09-branded-struct-elide
;;; Tests that brand declarations and brand types are elided in :structs
;;; metadata, leaving only the base type (ulong instead of token-t).
;;; -----------------------------------------------------------------------

;; src/metadata-val.lisp
(defun validate-struct-no-brand-in-metadata (metadata-path)
  "Validates 056/09-branded-struct-elide: branded def-struct at kernel boundary.
   Checks that the :structs section shows the base type (ulong) for branded
   fields (not token-t), no brand declarations appear, and the kernel is present."
  (unless (probe-file metadata-path)
    (log:error "validate-struct-no-brand-in-metadata: file not found: ~a" metadata-path)
    (return-from validate-struct-no-brand-in-metadata nil))

  (let* ((forms (%read-metacrisp-forms metadata-path))
         (structs (%metacrisp-section forms :structs))
         (k-def (%metacrisp-find-kernel forms "struct_on_boundary_k")))

    (unless structs
      (log:error "validate-struct-no-brand-in-metadata: no :structs section")
      (return-from validate-struct-no-brand-in-metadata nil))

    (let ((pt (%find-struct-def structs "point")))
      (unless pt
        (log:error "validate-struct-no-brand-in-metadata: point not in :structs")
        (return-from validate-struct-no-brand-in-metadata nil))

      ;; No member should be named "brand" -- brand declarations must be elided
      (dolist (m (cddr pt))
        (when (and (consp m) (symbolp (first m))
                   (string-equal (symbol-name (first m)) "brand"))
          (log:error "validate-struct-no-brand-in-metadata: brand declaration found in :structs -- should be elided: ~a" m)
          (return-from validate-struct-no-brand-in-metadata nil)))

      ;; The x field should have ulong type (base of token-t brand), not token-t
      (let ((x-member (find "x" (cddr pt)
                            :test (lambda (n m)
                                    (and (consp m) (symbolp (first m))
                                         (string-equal (symbol-name (first m)) n))))))
        (when x-member
          (let ((x-type (second x-member)))
            (when (and (symbolp x-type)
                       (string-equal (symbol-name x-type) "token-t"))
              (log:error "validate-struct-no-brand-in-metadata: x field still shows brand type 'token-t', expected base type 'ulong'")
              (return-from validate-struct-no-brand-in-metadata nil))))))

    (unless k-def
      (log:error "validate-struct-no-brand-in-metadata: kernel struct_on_boundary_k not found")
      (return-from validate-struct-no-brand-in-metadata nil))

    (log:info "validate-struct-no-brand-in-metadata: PASS")
    t))


;;; -----------------------------------------------------------------------
;;; Fix: serialize-structs — exclude c-t members from :structs section
;;; src/metadata.lisp
;;;
;;; def-struct c-t members are compile-time constants, NOT part of the
;;; struct memory layout (compute-std140-layout already excludes them).
;;; The metacrisp :structs section must reflect the actual runtime layout
;;; so the C++ hoist generates the correct sizeof() and field assignments.
;;; -----------------------------------------------------------------------

;; src/metadata.lisp
(defun serialize-structs (stream structs-hash)
  "Emits (:records ...) for def-records and (:structs ...) for def-structs.
   Records are split into their own section; brand and :c-t members handled.
   For def-structs: c-t members are excluded (they are compile-time constants
   not in the runtime memory layout)."
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
              ;; Skip compile-time members — they are not part of the runtime layout
              (unless (and (consp m) (eq (third m) :c-t))
                (let* ((member-name (first m))
                       (member-type (second m))
                       (brand-def   (is-brand-type-p member-type))
                       (final-type  (if brand-def
                                        (brand-definition-base-type brand-def)
                                        member-type)))
                  (format stream " (~a ~a)"
                    (strip-package-qualifiers member-name)
                    (strip-package-qualifiers final-type)))))
            (format stream ")~%")))))
    (format stream "  )~%~%")))

