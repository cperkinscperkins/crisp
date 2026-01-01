;;; src/analysis/ops.lisp
(in-package :crisp.compiler)

;; --- #'(...) Syntax Parsers ---

(defmacro def-binary-op-analyzer (name node-constructor op-string)
  `(defun ,name (expr env location)
     ,(format nil "Analyzes a `(~a ...)` expression." op-string)
     (let* ((left-node (analyze-expression (second expr) env (append location '(1))))
            (right-node (analyze-expression (third expr) env (append location '(2))))
            (left-type (get-single-value-type left-node))
            (right-type (get-single-value-type right-node))
            (promoted-type (get-promoted-type left-type right-type)))

       (if promoted-type
           (let ((result-crisp-type (gethash promoted-type *crisp-types*)))
             ;; Ensure the resulting type is numeric and supports the op.
             (unless (and result-crisp-type (member (crisp-type-category result-crisp-type)
                                                    '(:signed-int :unsigned-int :float)))
               (error 'crisp-type-error
                 :message (format nil "Type mismatch for operator '~a'. Cannot operate on ~a and ~a." ,op-string left-type right-type)
                 :source-location location))
             (,node-constructor :type promoted-type :left-arg left-node :right-arg right-node :source-location location))
           (error 'crisp-type-error
             :message (format nil "Type mismatch for operator '~a'. Cannot operate on ~a and ~a." ,op-string left-type right-type)
             :source-location location)))))

(def-binary-op-analyzer analyze-add-expression make-semantic-add "+")
(def-binary-op-analyzer analyze-sub-expression make-semantic-sub "-")
(def-binary-op-analyzer analyze-mul-expression make-semantic-mul "*")
(def-binary-op-analyzer analyze-div-expression make-semantic-div "/")

(defun try-constant-fold (node)
  "Attempts to reduce a semantic node to a semantic-literal if possible."
  (typecase node
    (semantic-lt
     (let ((l (try-constant-fold (semantic-lt-left-arg node)))
           (r (try-constant-fold (semantic-lt-right-arg node))))
       (if (and (typep l 'semantic-literal) (typep r 'semantic-literal))
           (make-semantic-literal :value-type 'int
                                  :value (if (< (semantic-literal-value l) (semantic-literal-value r)) 1 0)
                                  :source-location (semantic-lt-source-location node))
           node)))
    (semantic-gt
     (let ((l (try-constant-fold (semantic-gt-left-arg node)))
           (r (try-constant-fold (semantic-gt-right-arg node))))
       (if (and (typep l 'semantic-literal) (typep r 'semantic-literal))
           (make-semantic-literal :value-type 'int
                                  :value (if (> (semantic-literal-value l) (semantic-literal-value r)) 1 0)
                                  :source-location (semantic-gt-source-location node))
           node)))
    (semantic-le
     (let ((l (try-constant-fold (semantic-le-left-arg node)))
           (r (try-constant-fold (semantic-le-right-arg node))))
       (if (and (typep l 'semantic-literal) (typep r 'semantic-literal))
           (make-semantic-literal :value-type 'int
                                  :value (if (<= (semantic-literal-value l) (semantic-literal-value r)) 1 0)
                                  :source-location (semantic-le-source-location node))
           node)))
    (semantic-ge
     (let ((l (try-constant-fold (semantic-ge-left-arg node)))
           (r (try-constant-fold (semantic-ge-right-arg node))))
       (if (and (typep l 'semantic-literal) (typep r 'semantic-literal))
           (make-semantic-literal :value-type 'int
                                  :value (if (>= (semantic-literal-value l) (semantic-literal-value r)) 1 0)
                                  :source-location (semantic-ge-source-location node))
           node)))
    (semantic-eq
     (let ((l (try-constant-fold (semantic-eq-left-arg node)))
           (r (try-constant-fold (semantic-eq-right-arg node))))
       (if (and (typep l 'semantic-literal) (typep r 'semantic-literal))
           (make-semantic-literal :value-type 'int
                                  :value (if (= (semantic-literal-value l) (semantic-literal-value r)) 1 0)
                                  :source-location (semantic-eq-source-location node))
           node)))
    (semantic-neq
     (let ((l (try-constant-fold (semantic-neq-left-arg node)))
           (r (try-constant-fold (semantic-neq-right-arg node))))
       (if (and (typep l 'semantic-literal) (typep r 'semantic-literal))
           (make-semantic-literal :value-type 'int
                                  :value (if (/= (semantic-literal-value l) (semantic-literal-value r)) 1 0)
                                  :source-location (semantic-neq-source-location node))
           node)))
    (t node)))

(defun analyze-lt-expression (expr env location)
  (let* ((left-node (analyze-expression (second expr) env (append location '(1))))
         (right-node (analyze-expression (third expr) env (append location '(2)))))
    (make-semantic-lt :type 'int :left-arg left-node :right-arg right-node :source-location location)))

(defun analyze-gt-expression (expr env location)
  (let* ((left-node (analyze-expression (second expr) env (append location '(1))))
         (right-node (analyze-expression (third expr) env (append location '(2)))))
    (make-semantic-gt :type 'int :left-arg left-node :right-arg right-node :source-location location)))

(defun analyze-le-expression (expr env location)
  (let* ((left-node (analyze-expression (second expr) env (append location '(1))))
         (right-node (analyze-expression (third expr) env (append location '(2)))))
    (make-semantic-le :type 'int :left-arg left-node :right-arg right-node :source-location location)))

(defun analyze-ge-expression (expr env location)
  (let* ((left-node (analyze-expression (second expr) env (append location '(1))))
         (right-node (analyze-expression (third expr) env (append location '(2)))))
    (make-semantic-ge :type 'int :left-arg left-node :right-arg right-node :source-location location)))

(defun analyze-eq-expression (expr env location)
  (let* ((left-node (analyze-expression (second expr) env (append location '(1))))
         (right-node (analyze-expression (third expr) env (append location '(2)))))
    (make-semantic-eq :type 'int :left-arg left-node :right-arg right-node :source-location location)))

(defun analyze-neq-expression (expr env location)
  (let* ((left-node (analyze-expression (second expr) env (append location '(1))))
         (right-node (analyze-expression (third expr) env (append location '(2)))))
    (make-semantic-neq :type 'int :left-arg left-node :right-arg right-node :source-location location)))

(defun analyze-inc!-expression (expr env location)
  (declare (ignore expr env location))
  (error "inc! not implemented"))
(defun analyze-dec!-expression (expr env location)
  (declare (ignore expr env location))
  (error "dec! not implemented"))
(defun analyze-atomic-add!-expression (expr env location)
  (declare (ignore expr env location))
  (error "atomic-add! not implemented"))

(defun analyze-cast-expression (expr env location)
  "Analyzes a to-XXXX or as-XXXX cast expression."
  (let* ((op (first expr))
         (op-name (symbol-name op))
         (arg-form (second expr))
         (target-type-name
          (cond
           ((alexandria:starts-with-subseq "TO-" op-name) (intern (subseq op-name 3)))
           ((alexandria:starts-with-subseq "AS-" op-name) (intern (subseq op-name 3)))
           ;; For floor, ceil, etc., the target is always 'int' for now.
           ((member op '(floor ceil round)) 'int)
           (t (error "Internal compiler error: analyze-cast-expression called with invalid operator ~a" op))))
         (target-crisp-type (gethash target-type-name *crisp-types*))
         (arg-node (analyze-expression arg-form env (append location '(1)))))

    (unless target-crisp-type
      (error 'crisp-unknown-type-error :type-name target-type-name :source-location location))

    (let* ((source-type-name (get-single-value-type arg-node))
           (source-crisp-type (gethash source-type-name *crisp-types*)))

      (when (and (alexandria:starts-with-subseq "TO-" op-name)
                 (eq (crisp-type-category source-crisp-type) :float)
                 (member (crisp-type-category target-crisp-type) '(:signed-int :unsigned-int)))
            (error 'crisp-type-error :message "Invalid cast: Cannot use 'to-...' for float-to-integer conversion. Use 'truncate', 'floor', 'ceil', or 'round' instead."
              :source-location location))

      (let ((is-value-cast (or (alexandria:starts-with-subseq "TO-" op-name)
                               ;; An 'as-' cast between two integer types or two float types is a value cast (sext/zext/fpext), not a bitcast.
                               (and (alexandria:starts-with-subseq "AS-" op-name)
                                    (eq (crisp-type-category source-crisp-type)
                                        (crisp-type-category target-crisp-type))))))

        (cond
         ;; Handle `to-` casts and safe `as-` casts (like int->long)
         (is-value-cast
           (make-semantic-value-cast :type target-type-name :arg arg-node :source-location location))
         ((eq op 'truncate)
           (make-semantic-fp-truncate-cast :type target-type-name :arg arg-node :source-location location))
         ;; Handle unsafe `as-` bit reinterpretations
         (t ; Default for "AS-" and other currently unhandled float-to-int ops
           (make-semantic-bitcast :type target-type-name :arg arg-node :source-location location)))))))

(defun analyze-truncate-expression (expr env location)
  "Analyzes (truncate val) -> (values int rem)."
  (let* ((arg-form (second expr))
         (arg-node (analyze-expression arg-form env (append location '(1))))
         (arg-type (get-single-value-type arg-node))) ;; e.g. 'float
    (make-semantic-truncate :type (list 'int arg-type) ;; Returns (int float)
                            :arg arg-node
                            :source-location location)))

(defun analyze-value-cast-expression (expr env location)
  "Analyzes the generic (to type value) form."
  (let* ((type-form (second expr))
         (value-form (third expr))
         (type-name (if (symbolp type-form) type-form (error "Generic TO expects a type symbol, got ~a" type-form)))
         (target-type (gethash type-name *crisp-types*)))

    (unless target-type
      (error 'crisp-unknown-type-error :type-name type-name :source-location location))

    (let ((arg-node (analyze-expression value-form env (append location '(2)))))
      (make-semantic-value-cast :type type-name :arg arg-node :source-location location))))

(defun analyze-generic-as-expression (expr env location)
  "Analyzes the generic (as type value) form."
  (let* ((type-form (second expr))
         (value-form (third expr))
         (type-name (if (symbolp type-form) type-form (error "Generic AS expects a type symbol, got ~a" type-form)))
         (target-type (gethash type-name *crisp-types*))
         (arg-node (analyze-expression value-form env (append location '(2)))))

    (log:warn "ANALYZE-AS: ~s -> Type: ~a. Arg Type: ~a" type-name target-type (semantic-node-type arg-node))

    (unless target-type
      (error 'crisp-unknown-type-error :type-name type-name :source-location location))

    (make-semantic-value-cast :type type-name :arg arg-node :source-location location)))

(defun create-implicit-cast (node target-type location)
  "Wraps node in an implicit cast to target-type."
  (make-semantic-value-cast :type target-type
                            :arg node
                            :source-location location))

(defun analyze-bitcast-expression (expr env location)
  "Handler for explicit (as-bits type val) or aliased calls."
  ;; Re-use logic or define simple wrapper.
  ;; The original file had a def-expression-analyzer for this but no distinct function body
  ;; other than what analyze-cast-expression does.
  ;; But wait, analyze-cast-expression expects "AS-..." or "TO-..." name.
  ;; If we call it for `as-bits`, the name doesn't match.
  ;; Let's implement specific logic here or delegate.
  (let* ((type-form (second expr))
         (val-form (third expr))
         (target-type (if (symbolp type-form) type-form (error "Invalid type")))
         (arg-node (analyze-expression val-form env (append location '(2)))))
    (make-semantic-bitcast :type target-type :arg arg-node :source-location location)))

(defun register-ops-analyzers ()
  (def-expression-analyzer + analyze-add-expression)
  (def-expression-analyzer - analyze-sub-expression)
  (def-expression-analyzer * analyze-mul-expression)
  (def-expression-analyzer / analyze-div-expression)
  (def-expression-analyzer < analyze-lt-expression)
  (def-expression-analyzer > analyze-gt-expression)
  (def-expression-analyzer <= analyze-le-expression)
  (def-expression-analyzer >= analyze-ge-expression)
  (def-expression-analyzer = analyze-eq-expression)
  (def-expression-analyzer != analyze-neq-expression)

  (def-expression-analyzer atomic-add! analyze-atomic-add!-expression)
  (def-expression-analyzer to analyze-value-cast-expression)
  ;; Duplicate 'to' in original? Yes.
  (def-expression-analyzer as analyze-generic-as-expression)
  (def-expression-analyzer as-bits analyze-bitcast-expression)
  (def-expression-analyzer inc! analyze-inc!-expression)
  (def-expression-analyzer dec! analyze-dec!-expression)

  ;; Register cast operators dymaically
  (log:info "Registering cast operators. *crisp-types* count: ~a" (hash-table-count *crisp-types*))
  (dolist (type-name (alexandria:hash-table-keys *crisp-types*))
    (when (symbolp type-name)
          (let* ((type-str (symbol-name type-name))
                 (pkg (symbol-package type-name))
                 (to-name (intern (concatenate 'string "TO-" type-str) pkg))
                 (as-name (intern (concatenate 'string "AS-" type-str) pkg)))
            (log:debug "Registering cast/bitcast: ~s / ~s" to-name as-name)
            (setf (gethash to-name *expression-analyzers*) #'analyze-cast-expression)
            (setf (gethash as-name *expression-analyzers*) #'analyze-cast-expression))))

  ;; Float-to-int
  (setf (gethash 'truncate *expression-analyzers*) #'analyze-truncate-expression)
  (setf (gethash 'floor *expression-analyzers*) #'analyze-cast-expression)
  (setf (gethash 'ceil *expression-analyzers*) #'analyze-cast-expression)
  (setf (gethash 'round *expression-analyzers*) #'analyze-cast-expression))
