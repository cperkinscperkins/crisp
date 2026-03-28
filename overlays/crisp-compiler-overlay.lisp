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


;;; ============================================================
;;; Struct Immutability at Kernel Boundary
;;; src/analysis/core.lisp, src/analysis/structs.lisp
;;; ============================================================
;;; def-struct parameters at the kernel boundary are semantically
;;; immutable (SPIR-V constant memory). Two dynamic variables and
;;; checks in the analysis phase enforce this.
;;;
;;; *boundary-struct-params* — list of uppercase param-name strings
;;;   for def-struct-typed parameters of the current entry-point kernel.
;;;   Nil when compiling regular functions.
;;;
;;; *struct-mutating-functions* — hash table mapping uppercase
;;;   function names -> T for functions that (directly or indirectly)
;;;   mutate a struct-typed :in parameter.
;;;
;;; Enforcement paths:
;;;   1. Direct: (set! (x~ p) val) in kernel where p is boundary → error
;;;   2. Indirect: (f p) in kernel where f is struct-mutating → error
;;;   3. Propagation: f mutates :in param → register f as struct-mutating
;;; ============================================================

(defvar *boundary-struct-params* nil
  "Dynamic variable: list of uppercase param name strings that are def-struct
   params at the current kernel boundary. Non-nil only when compiling an
   entry-point kernel body. Nil in regular functions.")

(defvar *struct-mutating-functions* (make-hash-table :test #'equal)
  "Maps uppercase function name (string) -> T for functions that directly or
   indirectly mutate a struct-typed :in parameter.")

;; Helper: check if a type symbol names a registered def-struct (not def-record, package-safe)
(defun %boundary-struct-type-p (type)
  "Returns T if TYPE is a symbol naming a registered def-struct (category :struct)
   in *crisp-structs*. Returns NIL for def-record types (category :record).
   Uses string-equal for package-agnostic comparison."
  (when (symbolp type)
    (let ((type-name (symbol-name type)))
      (loop for k being the hash-keys of *crisp-structs*
            thereis (and (symbolp k)
                         (string-equal (symbol-name k) type-name)
                         ;; Only match actual def-struct entries (not def-record)
                         (let ((ct (gethash k *crisp-types*)))
                           (and ct (eq (crisp-type-category ct) :struct))))))))

;; Helper: enforce immutability or mark current function as struct-mutating
(defun %check-struct-boundary-mutation (struct-node env context location)
  "Called when a struct member update is about to be emitted.
   In kernel context (*boundary-struct-params* bound): error if the struct
   being mutated is a kernel boundary parameter.
   In function context: mark the current function as struct-mutating if it is
   mutating an :in parameter."
  (when (semantic-var-read-p struct-node)
    (let* ((vname     (semantic-var-read-name struct-node))
           (vname-str (string-upcase (symbol-name vname))))
      (if *boundary-struct-params*
          ;; Kernel context: check if this var is a boundary struct param
          (when (member vname-str *boundary-struct-params* :test #'string=)
            (error 'crisp-compiler-error
                   :message (format nil "Cannot mutate struct parameter '~a': struct parameters at kernel boundary are immutable"
                                    vname)
                   :source-location location))
          ;; Regular function context: mark as struct-mutating if mutating :in param
          (let ((var-info (find-variable-in-env vname env)))
            (when (and var-info (eq (parameter-def-kind var-info) :in))
              (let ((fn-name (compiler-context-current-compiling-function context)))
                (when fn-name
                  (log:debug "Marking ~a as struct-mutating (mutates :in param ~a)" fn-name vname)
                  (setf (gethash (string-upcase (symbol-name fn-name)) *struct-mutating-functions*) t)))))))))

;; Helper: check if a function call passes a boundary struct to a mutating function
(defun %check-struct-mutating-call (op explicit-arg-nodes env context location)
  "Called during function call analysis when OP is in *struct-mutating-functions*.
   Kernel context: error if any arg is a boundary struct param.
   Function context: propagate struct-mutating mark if any :in struct param is passed."
  (when (and (symbolp op)
             (gethash (string-upcase (symbol-name op)) *struct-mutating-functions*))
    (dolist (arg-node explicit-arg-nodes)
      (when (semantic-var-read-p arg-node)
        (let* ((vname     (semantic-var-read-name arg-node))
               (vname-str (string-upcase (symbol-name vname))))
          (if *boundary-struct-params*
              ;; Kernel context: error if passing a boundary param to struct-mutating fn
              (when (member vname-str *boundary-struct-params* :test #'string=)
                (error 'crisp-compiler-error
                       :message (format nil "Cannot pass boundary struct '~a' to '~a' which mutates its struct argument: struct parameters at kernel boundary are immutable"
                                        vname op)
                       :source-location location))
              ;; Regular function context: propagate struct-mutating mark
              (let ((var-info (find-variable-in-env vname env)))
                (when (and var-info
                           (eq (parameter-def-kind var-info) :in)
                           (%boundary-struct-type-p (parameter-def-type var-info)))
                  (let ((fn-name (compiler-context-current-compiling-function context)))
                    (when fn-name
                      (log:debug "Marking ~a as struct-mutating (passes :in param ~a to ~a)" fn-name vname op)
                      (setf (gethash (string-upcase (symbol-name fn-name)) *struct-mutating-functions*) t)))))))))))


;;; -----------------------------------------------------------------------
;;; Redefine internal-def-function to bind *boundary-struct-params* for
;;; entry-point kernels.
;;; src/analysis/core.lisp
;;; -----------------------------------------------------------------------

;; src/analysis/core.lisp
(defun internal-def-function (name params declarations body location)
  "Wrapper around internal-compile-function. Detects kernel entry-points and
   binds *boundary-struct-params* to enforce struct immutability at the boundary."
  (log:info "Analyzing function ~s" name)

  (when *differentiate-p*
        (log:info "Applying ANF to function body")
        (let* ((progn-body `(progn ,@body))
               (anf-body (anf-normalize progn-body nil))
               (unwrapped-body (if (and (consp anf-body) (eq (car anf-body) 'progn))
                                   (cdr anf-body)
                                   (list anf-body))))
          (setf body unwrapped-body)))

  (multiple-value-bind (explicit-env return-type)
      (parse-function-declarations params declarations)
    (let* ((*compiler-context* (or *compiler-context* (make-compiler-context)))
           (is-entry-p (loop for d in declarations
                             thereis (and (listp d)
                                          (symbolp (first d))
                                          (string-equal (symbol-name (first d)) "ENTRY-POINT"))))
           (*boundary-struct-params*
             (if is-entry-p
                 (loop for param in explicit-env
                       when (%boundary-struct-type-p (parameter-def-type param))
                       collect (string-upcase (symbol-name (parameter-def-name param))))
                 *boundary-struct-params*)))
      (when (and is-entry-p *boundary-struct-params*)
            (log:debug "Kernel ~a has boundary struct params: ~a" name *boundary-struct-params*))
      (internal-compile-function name explicit-env return-type params body declarations location *compiler-context*))))


;;; -----------------------------------------------------------------------
;;; Redefine analyze-set!-expression to call %check-struct-boundary-mutation
;;; src/analysis/structs.lisp
;;; -----------------------------------------------------------------------

;; src/analysis/structs.lisp
(defun analyze-set!-expression (expr env context location)
  "Analyzes a (set! target value) expression.
   Enforces struct immutability at kernel boundary via *boundary-struct-params*."
  (let* ((target-form (second expr))
         (value-form  (third expr))
         (value-node  (analyze-expression value-form env context (append location '(2)))))

    (cond
     ;; Case 1: Simple variable assignment  (set! x v)
     ((symbolp target-form)
       (let ((var-info (find-variable-in-env target-form env)))
         (unless var-info
           (error 'crisp-unknown-variable :name target-form :source-location location))
         (let ((var-type (parameter-def-type var-info))
               (val-type (semantic-node-type value-node)))
           (unless (types-compatible-p val-type var-type)
             (error 'crisp-type-error :expected var-type :inferred val-type
                    :source-location location)))
         (make-semantic-set!
          :target-node (make-semantic-var-read
                        :name target-form
                        :type (parameter-def-type var-info)
                        :source-location location)
          :value-node value-node
          :source-location location)))

     ;; Case 2: Function call / struct accessor
     ((and (listp target-form) (>= (length target-form) 1) (symbolp (first target-form)))
       (let* ((op           (first target-form))
              (op-args      (rest target-form))
              (arg-nodes    (loop for arg in op-args
                                  for i from 1
                                  collect (analyze-expression arg env context
                                                              (append location (list 1 i)))))
              (all-arg-nodes  (append arg-nodes (list value-node)))
              (all-arg-types  (mapcar #'semantic-node-type all-arg-nodes))
              (full-setter-name (intern (format nil "~a_SET!" op) (symbol-package op)))
              (signatures   (append (gethash op *function-table*)
                                    (gethash full-setter-name *function-table*)))
              (match        (find-if (lambda (sig)
                                       (types-list-compatible-p
                                        all-arg-types
                                        (mapcar #'parameter-def-type
                                                (function-signature-parameters sig))))
                                     signatures)))

         ;; Try template instantiation if no direct match
         (unless match
           (let ((template-op (if (gethash full-setter-name *template-registry*)
                                  full-setter-name op)))
             (when (gethash template-op *template-registry*)
               (ensure-template-instantiation
                template-op all-arg-types
                (lambda (f l) (declare (ignore l)) (eval f)))
               (setf signatures (append (gethash op *function-table*)
                                        (gethash full-setter-name *function-table*)))
               (setf match (find-if
                            (lambda (sig)
                              (types-list-compatible-p
                               all-arg-types
                               (mapcar #'parameter-def-type
                                       (function-signature-parameters sig))))
                            signatures)))))

         (cond
          ;; Sub-case 2a: Found an overloaded setter function -> call it.
          (match
            (make-semantic-call
             :name (function-signature-name match)
             :type (function-signature-return-types match)
             :args all-arg-nodes
             :signature match
             :source-location location))

          ;; Sub-case 2b: Expression analyzer — only if result is an assignable lvalue.
          ;; Device-vector component write (semantic-extract-value) and cell deref
          ;; (semantic-aref) are assignable.  Struct accessor fallbacks return
          ;; semantic-call which is NOT assignable — fall through to 2c in that case.
          ((gethash op *expression-analyzers*)
            (let ((target-node
                   (let ((*analysis-access-mode* :write))
                     (analyze-expression target-form env context (append location '(1))))))
              (if (or (semantic-extract-value-p target-node)
                      (semantic-aref-p target-node))
                  (make-semantic-set!
                   :target-node target-node
                   :value-node value-node
                   :source-location location)
                  ;; Not an assignable lvalue — fall through to Sub-case 2c.
                  (let* ((op-name (symbol-name op))
                         (is-accessor
                          (or (alexandria:ends-with #\~ op-name)
                              (and (alexandria:starts-with #\~ op-name)
                                   (alexandria:ends-with #\~ op-name)))))
                    (unless is-accessor
                      (error "Invalid set! target: ~a. No matching setter function found and not a struct accessor."
                             target-form))
                    (unless (= (length arg-nodes) 1)
                      (error "Struct accessor ~a expects exactly 1 argument (the struct), got ~a."
                             op (length arg-nodes)))
                    (let* ((clean-name  (cl:string-trim "~" op-name))
                           (member-sym  (intern clean-name (symbol-package op)))
                           (struct-node (first arg-nodes))
                           (struct-type (semantic-node-type struct-node)))
                      (unless (or (semantic-var-read-p struct-node)
                                  (semantic-aref-p struct-node))
                        (error "Cannot set member of non-variable/non-reference struct form: ~a"
                               (second target-form)))
                      ;; Immutability check
                      (%check-struct-boundary-mutation struct-node env context location)
                      (let ((update-node
                             (make-semantic-struct-member-update
                              :type struct-type
                              :struct-node struct-node
                              :member-index (get-struct-member-index struct-type member-sym)
                              :value-node value-node
                              :source-location location)))
                        (make-semantic-set!
                         :target-node struct-node
                         :value-node update-node
                         :source-location location)))))))

          ;; Sub-case 2c: Struct member update (legacy accessor logic).
          (t
            (let* ((op-name (symbol-name op))
                   (is-accessor
                    (or (alexandria:ends-with #\~ op-name)
                        (and (alexandria:starts-with #\~ op-name)
                             (alexandria:ends-with #\~ op-name)))))
              (unless is-accessor
                (error "Invalid set! target: ~a. No matching setter function found and not a struct accessor."
                       target-form))
              (unless (= (length arg-nodes) 1)
                (error "Struct accessor ~a expects exactly 1 argument (the struct), got ~a."
                       op (length arg-nodes)))
              (let* ((clean-name  (cl:string-trim "~" op-name))
                     (member-sym  (intern clean-name (symbol-package op)))
                     (struct-node (first arg-nodes))
                     (struct-type (semantic-node-type struct-node)))
                (unless (or (semantic-var-read-p struct-node)
                            (semantic-aref-p struct-node))
                  (error "Cannot set member of non-variable/non-reference struct form: ~a"
                         (second target-form)))
                ;; Immutability check
                (%check-struct-boundary-mutation struct-node env context location)
                (let ((update-node
                       (make-semantic-struct-member-update
                        :type struct-type
                        :struct-node struct-node
                        :member-index (get-struct-member-index struct-type member-sym)
                        :value-node value-node
                        :source-location location)))
                  (make-semantic-set!
                   :target-node struct-node
                   :value-node update-node
                   :source-location location))))))))

     (t (error "Invalid set! target structure: ~a" target-form)))))


;;; -----------------------------------------------------------------------
;;; Redefine analyze-function-call to call %check-struct-mutating-call
;;; src/analysis/core.lisp
;;; -----------------------------------------------------------------------

;; src/analysis/core.lisp
(defun analyze-function-call (op expr env context location)
  "Analyzes a function call expression.
   Checks for struct immutability violations via %check-struct-mutating-call."
  (log:debug "Analyzing function call to ~s. Current function: ~s" op (compiler-context-current-compiling-function context))

  ;; Recursion / call-graph tracking
  (if (multi-pass-mode-p)
      (when (compiler-context-current-compiling-function context)
            (pushnew op (gethash (compiler-context-current-compiling-function context) *call-graph*)))
      (when (eq op (compiler-context-current-compiling-function context))
            (error 'crisp-recursion-error :form op :source-location (append location '(0)))))

  ;; Implicit args
  (let ((implicit-args-required (gethash op *implicit-arg-map*)))
    (when (and (single-pass-mode-p) implicit-args-required)
          (setf (gethash (compiler-context-current-compiling-function context) *implicit-arg-map*) implicit-args-required))

    (let* ((arg-forms (rest expr))
           (explicit-arg-nodes (loop for arg-form in arg-forms
                                     for i from 1
                                     collect (analyze-expression arg-form env context (append location (list i)))))
           (explicit-arg-types (mapcar #'get-single-value-type explicit-arg-nodes))
           (signature (resolve-best-signature op explicit-arg-types context)))

      ;; Struct mutating function check
      (%check-struct-mutating-call op explicit-arg-nodes env context location)

      (let ((final-arg-nodes
             (if implicit-args-required
                 (let ((implicit-arg-nodes
                        (loop for (param-name . param-type) in implicit-args-required
                              collect (let ((found (find-variable-in-env param-name env)))
                                        (if found
                                            (make-semantic-var-read :name param-name :type (parameter-def-type found) :source-location location)
                                            (error "Compiler bug: Carrier function ~s is missing implicit argument ~s."
                                              (compiler-context-current-compiling-function context) param-name))))))
                   (append implicit-arg-nodes explicit-arg-nodes))
                 explicit-arg-nodes)))

        (unless (= (length explicit-arg-types) (length (function-signature-parameters signature)))
          (error 'crisp-signature-arity-error
            :expected (length (function-signature-parameters signature))
            :inferred (length explicit-arg-types)
            :source-location location))

        (let ((augmented-signature
               (if implicit-args-required
                   (let ((implicit-params (loop for (param-name . param-type) in implicit-args-required
                                                collect (make-parameter-def :name param-name :type param-type :kind :in))))
                     (make-function-signature
                      :name (function-signature-name signature)
                      :parameters (append implicit-params (function-signature-parameters signature))
                      :return-types (function-signature-return-types signature)
                      :source-location (function-signature-source-location signature)
                      :is-template-p (function-signature-is-template-p signature)
                      :template-params (function-signature-template-params signature)))
                   signature)))

          ;; === Brand Instance Type Checking (when --differentiate is active) ===
          (let ((refined-return-types (function-signature-return-types augmented-signature)))

            (cl:when *differentiate-p*
              (let ((sig-params (function-signature-parameters augmented-signature)))

                ;; 1. Brand parameter type checking
                (loop for param in sig-params
                      for arg-node in final-arg-nodes
                      for param-type = (parameter-def-type param)
                      do (cl:let ((brand-def (is-brand-type-p param-type)))
                           (cl:when (and brand-def (brand-active-p brand-def))
                             ;; FIX: Use brand-name to find owner, supporting shared brands
                             (cl:let ((owner-var (%find-brand-owner-var (brand-definition-brand-name brand-def)
                                                                        sig-params final-arg-nodes)))
                               (cl:when owner-var
                                 (cl:let* ((expected-type (resolve-brand-type param-type owner-var))
                                           (actual-type (get-single-value-type arg-node)))
                                   (unless (or (eq actual-type expected-type)
                                               (is-substitutable-for? actual-type expected-type))
                                     (error 'crisp-type-error
                                       :expected (list expected-type)
                                       :inferred (list actual-type)
                                       :source-location location))))))))

                ;; 2. Brand return type refinement
                (setf refined-return-types
                  (loop for ret-type in (function-signature-return-types augmented-signature)
                        collect (cl:let ((brand-def (is-brand-type-p ret-type)))
                                  (if (and brand-def (brand-active-p brand-def))
                                      (cl:let ((owner-var (%find-brand-owner-var (brand-definition-brand-name brand-def)
                                                                                 sig-params final-arg-nodes)))
                                        (if owner-var
                                            (resolve-brand-type ret-type owner-var)
                                            ret-type))
                                      ret-type))))))

            (make-semantic-call :name (function-signature-name augmented-signature)
                                :type refined-return-types
                                :args final-arg-nodes
                                :signature augmented-signature
                                :source-location location)))))))


;;; -----------------------------------------------------------------------
;;; Redefine initialize-compiler to clear *struct-mutating-functions*
;;; src/compiler.lisp
;;; -----------------------------------------------------------------------

;; src/compiler.lisp
(defun initialize-compiler (&key (log-level :off) (runtime-checks nil) (differentiate nil))
  "A master initialization function for the Crisp compiler.
This should be called by any entry point into the system (REPL, executable, CI).
Extended to clear *struct-mutating-functions* between compilations."
  (setf *runtime-checks-enabled* runtime-checks)
  (setf *differentiate-p* differentiate)
  (cffi:use-foreign-library crisp.llvm-bindings::libllvm)

  (if (eq log-level :off)
      (log:config :off)
      (log:config :sane :stream *error-output* log-level))

  (initialize-crisp-types)
  (initialize-crisp-types)
  (initialize-type-hierarchy)
  (clrhash *function-table*)
  (clrhash *crisp-structs*)
  (clrhash *crisp-type-aliases*)
  (clrhash *crisp-template-aliases*)
  (clrhash *generic-functions*)
  (clrhash *kernel-declared-signatures*)
  (when (boundp '*record-definitions*) (clrhash *record-definitions*))

  (setf *compiled-kernels* nil)

  ;; Feature 052: clear both registries on each compile.
  (clrhash *differentiable-functions*)
  (clrhash *differentiable-hof-store*)

  (initialize-expression-analyzers)
  (clrhash *implicit-arg-map*)
  (initialize-advisements)

  (setf (gethash 'die *function-table*)
    (list (make-function-signature :name 'die :parameters nil :return-types '(nil))))

  (setf (symbol-function 'truncate) #'cl:truncate)
  (setf (symbol-function 'floor) #'cl:floor)
  (setf (symbol-function 'ceil) #'cl:ceiling)
  (setf (symbol-function 'round) #'cl:round)

  ;; Auto-initialize templates if available (runtime check)
  (if (fboundp 'initialize-templates)
      (funcall 'initialize-templates)
      (log:warn "Template system not loaded/initialized."))

  ;; Reset brand definitions
  (when (boundp '*brand-definitions*) (clrhash *brand-definitions*))

  ;; Reset brand instance cache and brand instance type tracking.
  (when (boundp '*brand-instance-cache*) (clrhash *brand-instance-cache*))
  (when (boundp '*brand-instance-types*) (clrhash *brand-instance-types*))

  ;; Clear partial template instantiations and their CL dispatch macros.
  (when (boundp '*partial-template-instantiations*)
        (loop for template-name being the hash-keys of *partial-template-instantiations*
              do (let ((dispatch-sym (intern (format nil "MAKE-~a%DISPATCH" template-name)
                                             (symbol-package template-name))))
                   (when (macro-function dispatch-sym)
                         (log:info "INITIALIZE-COMPILER: clearing stale CL dispatch macro ~a" dispatch-sym)
                         (fmakunbound dispatch-sym))))
        (clrhash *partial-template-instantiations*))

  ;; Clear struct-mutating function registry (feature 056).
  (when (boundp '*struct-mutating-functions*)
        (clrhash *struct-mutating-functions*))

  ;; Initialize built-in structs (storage) — includes cell, vector, matrix templates
  (register-builtins)

  (log:info "Compiler initialized. differentiate=~a" differentiate))
