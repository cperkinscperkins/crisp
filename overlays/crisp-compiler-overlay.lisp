;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;;; ==========================================================================
;;; Native Scalar Struct Layout
;;; Replaces the old std140 struct layout with compact "native scalar" rules:
;;;   - Members at their natural alignment (unchanged from std140)
;;;   - Array fields: N * elem_size, no per-element 16-byte padding
;;;   - Struct total size: padded to max-member-alignment (not to 16)
;;;
;;; src/structs.lisp  (replace get-std140-base-alignment, get-std140-size,
;;;                    compute-std140-layout; add %struct-native-alignment)
;;; ==========================================================================

(defun %struct-native-alignment (struct-name)
  "Returns the native scalar alignment of a struct: the maximum alignment of
   all its runtime members (recursively resolved).  This is the struct's
   own alignment requirement under native scalar layout rules."
  (cl:let* ((def (find-struct-definition-by-name struct-name))
             (members (cl:when def (crisp-struct-definition-members def)))
             (runtime-members (remove-if
                                (lambda (m) (and (consp m) (eq (third m) :c-t)))
                                members)))
    (cl:if runtime-members
           (apply #'cl:max
                  (mapcar (lambda (m) (get-std140-base-alignment (second m)))
                          runtime-members))
           4))) ; default 4-byte alignment for empty structs

(defun get-std140-base-alignment (type-spec)
  "Returns the base alignment (in bytes) for TYPE-SPEC under native scalar rules.
   Scalars: natural size.  Arrays: element alignment.  Structs: max member alignment."
  (cl:let* ((alias-resolved (resolve-type-alias type-spec))
             (resolved-type (get-type-base alias-resolved)))
    (cl:cond
      ;; (array T N) -> element alignment (compact, not vec4)
      ((%array-type-p type-spec)
       (get-std140-base-alignment (cl:second type-spec)))
      ((%array-type-p alias-resolved)
       (get-std140-base-alignment (cl:second alias-resolved)))
      ;; scalars — natural size (unchanged)
      ((or (eq resolved-type 'float) (eq resolved-type 'int) (eq resolved-type 'uint)) 4)
      ((or (eq resolved-type 'double) (eq resolved-type 'long) (eq resolved-type 'ulong)) 8)
      ((or (eq resolved-type 'char) (eq resolved-type 'uchar)) 1)
      ((or (eq resolved-type 'short) (eq resolved-type 'ushort)
           (eq resolved-type 'half) (eq resolved-type 'bfloat16)) 2)
      ((or (eq resolved-type 'bool)) 4)
      ((eq type-spec 'c-pointer) 8)
      ((and (consp type-spec) (eq (cl:first type-spec) 'c-pointer)) 8)
      ((and (symbolp type-spec)
            (> (cl:length (symbol-name type-spec)) 5)
            (string-equal (cl:subseq (symbol-name type-spec) 0 5) "CELL_"))
       8)
      ;; structs — max member alignment (native scalar rule, not 16)
      ((gethash type-spec *crisp-structs*)
       (%struct-native-alignment type-spec))
      ((and (consp type-spec) (valid-type-p type-spec))
       (cl:let ((base (cl:first type-spec)))
         (cl:cond
           ((string-equal (symbol-name base) "CELL") 8)
           (t
            (cl:let ((mangled (mangle-template-struct-name
                                (cl:first type-spec) (cl:rest type-spec))))
              (if (gethash mangled *crisp-structs*)
                  (%struct-native-alignment mangled)
                  (error "Valid type ~a but struct def not found for alignment."
                         type-spec)))))))
      (t (error "Unknown type for alignment: ~a" type-spec)))))

(defun get-std140-size (type-spec)
  "Returns the size (in bytes) of TYPE-SPEC under native scalar rules.
   Arrays: N * elem-size (compact, no per-element 16-byte padding).
   Structs: total-size as recorded (compact layout).  Scalars: natural size."
  (cl:let* ((alias-resolved (resolve-type-alias type-spec))
             (resolved-type (get-type-base alias-resolved)))
    (cl:cond
      ;; (array T N) -> N * elem-size, no per-element std140 stride
      ((%array-type-p type-spec)
       (cl:let* ((elem-type (cl:second type-spec))
                 (n         (cl:third type-spec))
                 (elem-size (get-std140-size elem-type)))
         (* n elem-size)))
      ((%array-type-p alias-resolved)
       (get-std140-size alias-resolved))
      ;; scalars (unchanged)
      ((or (eq resolved-type 'float) (eq resolved-type 'int) (eq resolved-type 'uint)) 4)
      ((or (eq resolved-type 'double) (eq resolved-type 'long) (eq resolved-type 'ulong)) 8)
      ((or (eq resolved-type 'char) (eq resolved-type 'uchar)) 1)
      ((or (eq resolved-type 'short) (eq resolved-type 'ushort)
           (eq resolved-type 'half) (eq resolved-type 'bfloat16)) 2)
      ((eq resolved-type 'bool) 4)
      ((eq resolved-type 'c-pointer) 8)
      ((and (consp type-spec) (eq (cl:first type-spec) 'c-pointer)) 8)
      ((and (symbolp type-spec)
            (> (cl:length (symbol-name type-spec)) 5)
            (string-equal (cl:subseq (symbol-name type-spec) 0 5) "CELL_"))
       8)
      ((gethash type-spec *crisp-structs*)
       (crisp-struct-definition-total-size (gethash type-spec *crisp-structs*)))
      ((and (consp type-spec) (valid-type-p type-spec))
       (cl:let ((base (cl:first type-spec)))
         (cl:cond
           ((string-equal (symbol-name base) "CELL") 8)
           (t
            (cl:let* ((mangled (mangle-template-struct-name
                                 (cl:first type-spec) (cl:rest type-spec)))
                       (struct-info (gethash mangled *crisp-structs*)))
              (if struct-info
                  (crisp-struct-definition-total-size struct-info)
                  (error "Valid type ~a but struct def not found for size."
                         type-spec)))))))
      (t (error "Unknown type for size: ~a" type-spec)))))

(defun compute-std140-layout (members)
  "Computes native scalar layout for a struct.
   Members are placed at their natural alignment boundaries (same as before).
   Total struct size is padded to the struct's overall alignment, which equals
   the maximum alignment of any member — NOT to 16.
   Returns (values expanded-members total-size)."
  (cl:let* ((runtime-members (remove-if
                               (lambda (m) (and (consp m) (eq (third m) :c-t)))
                               members))
             (current-offset 0)
             (max-alignment  1)
             (expanded-members '()))
    (dolist (member runtime-members)
      (cl:let* ((name      (first member))
                (type      (second member))
                (alignment (get-std140-base-alignment type))
                (size      (get-std140-size type))
                (padding   (calculate-std140-padding current-offset alignment)))
        (declare (ignore name))

        ;; Track overall struct alignment
        (cl:when (> alignment max-alignment)
          (setf max-alignment alignment))

        ;; Insert inter-member padding if needed
        (cl:when (> padding 0)
          (cl:let ((pad-remaining padding)
                   (pad-idx 0)
                   (pad-current-offset current-offset))
            (loop while (> pad-remaining 0) do
              (cl:let* ((pad-member
                          (cl:cond
                            ((and (>= pad-remaining 8)
                                  (zerop (mod pad-current-offset 8))) (list 'double 8))
                            ((and (>= pad-remaining 4)
                                  (zerop (mod pad-current-offset 4))) (list 'int 4))
                            ((and (>= pad-remaining 2)
                                  (zerop (mod pad-current-offset 2))) (list 'short 2))
                            (t (list 'char 1))))
                         (pad-type (first pad-member))
                         (pad-size (second pad-member))
                         (pad-name (intern (format nil "_PAD_~a_~a"
                                                   current-offset pad-idx))))
                (push (list pad-name pad-type) expanded-members)
                (decf pad-remaining pad-size)
                (incf pad-current-offset pad-size)
                (incf pad-idx))))
          (incf current-offset padding))

        ;; Add the member itself
        (push member expanded-members)
        (incf current-offset size)))

    ;; Trailing padding to max-member-alignment (native scalar rule)
    (cl:let ((final-padding (calculate-std140-padding current-offset max-alignment)))
      (cl:when (> final-padding 0)
        (cl:let ((pad-remaining final-padding)
                 (pad-idx 0)
                 (pad-current-offset current-offset))
          (loop while (> pad-remaining 0) do
            (cl:let* ((pad-member
                        (cl:cond
                          ((and (>= pad-remaining 8)
                                (zerop (mod pad-current-offset 8))) (list 'double 8))
                          ((and (>= pad-remaining 4)
                                (zerop (mod pad-current-offset 4))) (list 'int 4))
                          ((and (>= pad-remaining 2)
                                (zerop (mod pad-current-offset 2))) (list 'short 2))
                          (t (list 'char 1))))
                       (pad-type (first pad-member))
                       (pad-size (second pad-member))
                       (pad-name (intern (format nil "_PAD_EA_~a" pad-idx))))
              (push (list pad-name pad-type) expanded-members)
              (decf pad-remaining pad-size)
              (incf pad-current-offset pad-size)
              (incf pad-idx)))))
      (incf current-offset final-padding))

    (values (nreverse expanded-members) current-offset)))
