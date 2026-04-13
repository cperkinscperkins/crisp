;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;;;; ── 071-compact-aref-opt ─────────────────────────────────────────────────
;;;; Compact tensor aref optimization.
;;;; When :align is :compact and fully resolved at compile time, generate
;;;; a Horner / stride=1 flat-index formula that avoids stride array reads.
;;;; Destination: src/analysis/structs.lisp

(defun %get-tensor-align (type)
  "Extracts the :align keyword from a tensor type specifier.
   TYPE may be a list form (tensor elem N addr access align) or a
   mangled symbol TENSOR_ELEM_N_ADDR_ACCESS_ALIGN.
   Returns :compact, :strided, or NIL (unknown / template variable)."
  (labels ((coerce-aln (raw)
             ;; List form has keyword (:compact/:strided); mangled form has bare symbol
             (cond
               ((eq raw :compact)  :compact)
               ((eq raw :strided)  :strided)
               ((and (symbolp raw) (string-equal (symbol-name raw) "COMPACT"))  :compact)
               ((and (symbolp raw) (string-equal (symbol-name raw) "STRIDED"))  :strided)
               (t nil))))
    (cond
      ((and (listp type) (symbolp (cl:first type))
            (string-equal (symbol-name (cl:first type)) "TENSOR"))
       (coerce-aln (cl:sixth type)))
      ((symbolp type)
       (let ((unmangled (unmangle-template-struct-name type)))
         (when (and (consp unmangled) (symbolp (cl:first unmangled))
                    (string-equal (symbol-name (cl:first unmangled)) "TENSOR"))
           (coerce-aln (cl:sixth unmangled)))))
      (t nil))))

(defun %build-tensor-compact-flat-index-form (target-sym index-forms)
  "Builds the compact flat-index Crisp form for a :compact tensor access.
   N=1 (vector): flat = offset[0] + i_0              (no stride read, no multiply)
   N>=2 (matrix/tensor): Horner's method using extents:
     flat = (...((i_0 * ext[1] + i_1) * ext[2] + i_2)...) + sum(offsets)
   Returns a Crisp form ready for analyze-expression."
  (let ((n (cl:length index-forms)))
    (if (= n 1)
        ;; Vector: offset[0] + i_0
        `(+ (~ (offset~ ,target-sym) 0)
            (to-ulong ,(cl:first index-forms)))
        ;; Matrix / tensor: Horner on extents, then add all offsets
        (let* (;; Horner accumulator: start with i_0, multiply-add for each remaining dim.
               ;; Uses do-loop + setf so each iteration definitely applies the step.
               ;; (for acc = INIT then STEP would leave INIT in `finally` for N=2.)
               (horner
                (cl:let ((acc `(to-ulong ,(cl:first index-forms))))
                  (loop for k from 1 below n
                        do (setf acc `(+ (* ,acc (~ (extents~ ,target-sym) ,k))
                                         (to-ulong ,(cl:nth k index-forms)))))
                  acc))
               ;; Sum of all per-dimension offsets
               (offset-sum
                (reduce (lambda (a b) `(+ ,a ,b))
                        (loop for k from 0 below n
                              collect `(~ (offset~ ,target-sym) ,k)))))
          `(+ ,horner ,offset-sum)))))

;; src/analysis/structs.lisp
(defun analyze-aref-expression (expr env context location)
  "Analyzes (~ target [index...]) or (~ref~ ...) expressions.
   Cell/array path: single index, brand-aware type resolution (unchanged).
   Tensor path: N index forms from (cddr expr) are desugared to a flat element
   index.  When the tensor's :align is :compact (fully resolved at compile time),
   %build-tensor-compact-flat-index-form is used (no stride reads, Horner method).
   Otherwise %build-tensor-flat-index-form (strided path) is used."
  (let* ((op          (cl:first expr))
         (target-sym  (if (symbolp (cl:second expr)) (cl:second expr) nil))
         (array-node  (analyze-expression (cl:second expr) env context (append location '(1))))
         (index-expr  (cl:third expr))
         (index-node  (if index-expr
                          (analyze-expression index-expr env context (append location '(2)))
                          (make-semantic-literal :value-type 'int :value 0
                                                 :source-location location)))
         (array-type  (semantic-node-type array-node))
         (elem-type   (get-array-element-type array-type)))

    ;; Guard: no read from &out parameters
    (when (and target-sym (not (eq *analysis-access-mode* :write)))
      (let ((binding (find-variable-in-env target-sym env)))
        (when (and binding (eq (parameter-def-kind binding) :out))
          (error 'crisp-illegal-access-error
            :message (format nil "Cannot read from Output Parameter '~a'. Output parameters are write-only."
                             target-sym)
            :source-location location))))

    (if elem-type
        (progn
          ;; Guard: void element type
          (let ((is-void (or (eq elem-type 'void) (eq elem-type 'T)
                             (and (symbolp elem-type)
                                  (string-equal (symbol-name elem-type) "VOID"))
                             (and (symbolp elem-type)
                                  (string-equal (symbol-name elem-type) "T"))
                             (and (consp elem-type)
                                  (let ((head (cl:first elem-type)))
                                    (or (eq head 'void) (eq head 'T)
                                        (and (symbolp head)
                                             (string-equal (symbol-name head) "VOID"))))))))
            (when is-void
              (error "Cannot dereference a Cell of type VOID. Specify an element type (e.g. (cell int)) or avoid using the dereference operator (~~).")))

          (let ((tensor-n (%get-tensor-arity array-type)))
            (if (and tensor-n target-sym)

                ;; ── Tensor path ──────────────────────────────────────────────
                (let* ((index-forms (cddr expr)))
                  (unless (= (cl:length index-forms) tensor-n)
                    (error "Tensor ~a requires ~a index~:p (arity ~a), got ~a."
                           target-sym tensor-n tensor-n (cl:length index-forms)))
                  (let* ((align      (%get-tensor-align array-type))
                         (flat-form  (if (eq align :compact)
                                         (progn
                                           (log:debug "AREF compact path: ~a (N=~a)" target-sym tensor-n)
                                           (%build-tensor-compact-flat-index-form target-sym index-forms))
                                         (progn
                                           (log:debug "AREF strided path: ~a (align=~s)" target-sym align)
                                           (%build-tensor-flat-index-form target-sym index-forms))))
                         (flat-node  (analyze-expression flat-form env context location))
                         ;; Brand-aware type resolution (same pattern as cell)
                         (brand-def  (and (not (eq *analysis-access-mode* :write))
                                          (not (consp elem-type))
                                          (find-brand-for-owner 'value-t array-type)))
                         (is-rw      (and brand-def
                                          (let ((owner (brand-definition-owner-struct brand-def)))
                                            (and (symbolp owner)
                                                 (search "READ-WRITE" (symbol-name owner))))))
                         (resolved-type (if (and is-rw (brand-active-p brand-def))
                                            (resolve-brand-type 'value-t target-sym elem-type)
                                            elem-type)))
                    (make-semantic-aref :type resolved-type
                                        :array-node array-node
                                        :index-node flat-node
                                        :source-location location)))

                ;; ── Cell / array path: single index, brand-aware (unchanged) ──
                (let* ((cell-type    array-type)
                       (brand-def    (and target-sym
                                          (not (eq *analysis-access-mode* :write))
                                          (not (consp elem-type))
                                          (find-brand-for-owner 'value-t cell-type)))
                       (is-rw-cell   (and brand-def
                                          (let ((owner (brand-definition-owner-struct brand-def)))
                                            (and (symbolp owner)
                                                 (search "READ-WRITE" (symbol-name owner))))))
                       (resolved-type (if (and is-rw-cell (brand-active-p brand-def))
                                          (progn
                                            (log:info "AREF: brand-aware read (~a) -> resolve-brand-type value-t ~a [elem: ~a]"
                                                      cell-type target-sym elem-type)
                                            (resolve-brand-type 'value-t target-sym elem-type))
                                          elem-type)))
                  (make-semantic-aref :type resolved-type
                                      :array-node array-node
                                      :index-node index-node
                                      :source-location location)))))

        ;; Fallback: not a known array/cell/tensor type → try as overloadable call
        (let ((op-name (symbol-name op)))
          (if (or (string= op-name "~") (string= op-name "~REF~"))
              (analyze-function-call op expr env context location)
              (error "Invalid type for aref: ~a" (semantic-node-type array-node)))))))

