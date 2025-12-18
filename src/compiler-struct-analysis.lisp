(defun analyze-struct-construction (expr env location)
  "Analyzes a (%construct-struct type-name arg1 arg2 ...) form."
  (let* ((type-name (second expr))
         (args (cddr expr))
         (struct-def (gethash type-name *crisp-structs*)))
    (unless struct-def
      (error 'crisp-unknown-type-error :type-name type-name :source-location location))

    ;; Validate argument count against original members
    (let ((members (crisp-struct-definition-members struct-def)))
      (unless (= (length args) (length members))
        (error "Struct constructor for ~a expects ~a arguments, got ~a."
          type-name (length members) (length args))))

    ;; Analyze arguments
    (let ((arg-nodes
           (loop for arg in args
                 for member in (crisp-struct-definition-members struct-def)
                 for i from 0
                 collect (let ((node (analyze-expression arg env (append location (list (+ 2 i)))))
                               (expected-type (second member)))
                           ;; Type check
                           (unless (eq (semantic-node-type node) expected-type)
                             (error 'crisp-type-error
                               :expected expected-type
                               :inferred (semantic-node-type node)
                               :source-location location))
                           node))))

      (make-semantic-struct-construction
       :type type-name
       :args arg-nodes
       :source-location location))))
