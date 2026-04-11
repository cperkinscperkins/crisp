;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

(defun validate-070-03-matrix-metadata (meta-path)
  "Validates .metacrisp for test 03-metadata-matrix.
   Matrix (N=2): 3*2+3=9 slots for v (indices 0-8), then val at index 9.
   :physical-signature — 10 entries
   :declared-signature — v :rank 2 :align :compact :range (0 8); val :range (9 9)"
  (unless (and meta-path (probe-file meta-path))
    (log:error "validate-070-03-matrix-metadata: metacrisp not found: ~a" meta-path)
    (return-from validate-070-03-matrix-metadata nil))
  (let* ((forms   (uiop:read-file-forms meta-path))
         (kernels (rest (find :kernels forms :key #'car)))
         (k-def   (find "mat_set_elem" kernels
                        :key (lambda (k) (getf k :name)) :test #'string-equal)))
    (unless k-def
      (log:error "validate-070-03-matrix-metadata: kernel mat_set_elem not found")
      (return-from validate-070-03-matrix-metadata nil))

    ;; physical-signature: 10 slots
    (let ((phys-sig (getf k-def :physical-signature)))
      (unless (= (length phys-sig) 10)
        (log:error "validate-070-03-matrix-metadata: physical-sig has ~d slots, expected 10" (length phys-sig))
        (return-from validate-070-03-matrix-metadata nil)))

    ;; declared-signature: v with rank=2, align=:compact, range=(0 8)
    (let* ((decl-sig (getf k-def :declared-signature))
           (v-entry  (find "v" decl-sig :key (lambda (e) (getf e :name)) :test #'string-equal)))
      (unless (and v-entry
                   (= (getf v-entry :rank) 2)
                   (eq (getf v-entry :align) :compact)
                   (equal (getf v-entry :range) '(0 8)))
        (log:error "validate-070-03-matrix-metadata: v entry wrong: ~s" v-entry)
        (return-from validate-070-03-matrix-metadata nil)))

    (log:info "validate-070-03-matrix-metadata: PASS")
    t))

;;; -----------------------------------------------------------------------
;;; 070-hoist-tensors metadata validators
;;; src/metadata-val.lisp
;;; -----------------------------------------------------------------------

(defun validate-070-01-vector-metadata (meta-path)
  "Validates .metacrisp for test 01-metadata-vector.
   Checks:
     - physical-signature: (0 LONG) (1 (C-POINTER...)) (2 ULONG) x 5 = 7 slots
     - declared-signature: val :range (0 0), v :range (1 6) :rank 1 :align :compact
     - aliases: OUT-VEC-T with keyword-form type spec"
  (unless (and meta-path (probe-file meta-path))
    (log:error "validate-070-01-vector-metadata: metacrisp not found: ~a" meta-path)
    (return-from validate-070-01-vector-metadata nil))
  (let* ((forms    (uiop:read-file-forms meta-path))
         (aliases  (rest (find :aliases  forms :key #'car)))
         (kernels  (rest (find :kernels  forms :key #'car)))
         (k-def    (find "vec_set_first" kernels
                         :key (lambda (k) (getf k :name))
                         :test #'string-equal)))
    (unless k-def
      (log:error "validate-070-01-vector-metadata: kernel vec_set_first not found")
      (return-from validate-070-01-vector-metadata nil))

    ;; Check alias keyword form: (def-type out-vec-t (vector long :address-space :global ...))
    (let ((alias (find "out-vec-t" aliases
                       :key (lambda (a) (and (consp a) (symbol-name (second a))))
                       :test #'string-equal)))
      (unless alias
        (log:error "validate-070-01-vector-metadata: alias OUT-VEC-T not found")
        (return-from validate-070-01-vector-metadata nil))
      ;; The type spec should have keywords like :address-space, :global, etc.
      (let ((type-spec (third alias)))
        (unless (and (consp type-spec)
                     (string-equal (symbol-name (first type-spec)) "VECTOR")
                     (member :address-space type-spec))
          (log:error "validate-070-01-vector-metadata: alias type spec missing keywords: ~s" type-spec)
          (return-from validate-070-01-vector-metadata nil))))

    ;; Check physical-signature: 7 slots
    (let ((phys-sig (getf k-def :physical-signature)))
      (unless (= (length phys-sig) 7)
        (log:error "validate-070-01-vector-metadata: physical-signature has ~d slots, expected 7" (length phys-sig))
        (return-from validate-070-01-vector-metadata nil))
      ;; slot 0 = long (val)
      (unless (string-equal (symbol-name (second (nth 0 phys-sig))) "LONG")
        (log:error "validate-070-01-vector-metadata: slot 0 should be LONG, got ~s" (nth 0 phys-sig))
        (return-from validate-070-01-vector-metadata nil))
      ;; slot 1 = pointer (ptr)
      (unless (and (consp (second (nth 1 phys-sig)))
                   (string-equal (symbol-name (first (second (nth 1 phys-sig)))) "C-POINTER"))
        (log:error "validate-070-01-vector-metadata: slot 1 should be C-POINTER, got ~s" (nth 1 phys-sig))
        (return-from validate-070-01-vector-metadata nil))
      ;; slots 2-6 = ulong
      (loop for i from 2 to 6 do
        (unless (string-equal (symbol-name (second (nth i phys-sig))) "ULONG")
          (log:error "validate-070-01-vector-metadata: slot ~d should be ULONG, got ~s" i (nth i phys-sig))
          (return-from validate-070-01-vector-metadata nil))))

    ;; Check declared-signature
    (let ((decl-sig (getf k-def :declared-signature)))
      (unless (= (length decl-sig) 2)
        (log:error "validate-070-01-vector-metadata: declared-sig has ~d entries, expected 2" (length decl-sig))
        (return-from validate-070-01-vector-metadata nil))
      ;; val: :range (0 0)
      (let ((val-entry (find "val" decl-sig :key (lambda (e) (getf e :name)) :test #'string-equal)))
        (unless (and val-entry (equal (getf val-entry :range) '(0 0)))
          (log:error "validate-070-01-vector-metadata: val entry wrong: ~s" val-entry)
          (return-from validate-070-01-vector-metadata nil)))
      ;; v: :range (1 6), :rank 1, :align :compact
      (let ((v-entry (find "v" decl-sig :key (lambda (e) (getf e :name)) :test #'string-equal)))
        (unless (and v-entry
                     (equal (getf v-entry :range) '(1 6))
                     (= (getf v-entry :rank) 1)
                     (eq (getf v-entry :align) :compact))
          (log:error "validate-070-01-vector-metadata: v entry wrong: ~s" v-entry)
          (return-from validate-070-01-vector-metadata nil))))

    (log:info "validate-070-01-vector-metadata: PASS")
    t))

