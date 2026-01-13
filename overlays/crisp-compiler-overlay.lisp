;;; Fix for Bug 013: Recursive def-type hangs
;;; v8: Added fix for parse-type-specifier in environment.lisp

(in-package :crisp.compiler)

(defun parse-function-declarations (params declarations)
  "Parses a function's declarations and returns its environment and return type.
   Supports interleaved type syntax: ((p type))"
  (log:debug "PARSE PARAMS: ~s Type: ~a Length: ~a" params (type-of params) (length params))

  ;; Defensive patch: unwrap double nested params (bug in def-record)
  (when (and (= (length params) 1) (listp (first params)) (listp (first (first params))) (symbolp (first (first (first params)))))
        (log:warn "Deeply nested params detected! Unwrapping.")
        (setf params (first params)))

  (let* ((fn-decl (find "FUNCTION" declarations :key (lambda (x) (symbol-name (car x))) :test #'string-equal))

         (return-types (if fn-decl
                           (analyze-return-type-from-spec (second fn-decl))
                           (analyze-return-type-from-list declarations)))

         (env nil)
         (optional-idx nil)
         (defaults nil)
         (key-idx nil))

    ;; Analyze Environment (and Optional Index)
    (cond
     ;; Case 1: #'(...) signature
     (fn-decl
       (log:debug "PARSE CASE 1: Function decl found: ~s" fn-decl)
       (multiple-value-setq (env optional-idx defaults key-idx)
                            (analyze-environment-from-spec params (second fn-decl))))

     ;; Case 2: Interleaved syntax ((a int) (b float))
     ((some #'listp params)
       (log:debug "PARSE CASE 2: Interleaved syntax detected. Params: ~s" params)
       ;; TODO: Support &optional in interleaved syntax if needed.
       (setf env (loop for p in params
                       collect (if (listp p)
                                   (progn
                                    (unless (>= (length p) 2)
                                      (error "Invalid parameter spec: ~a" p))
                                    (let ((name (first p)) (type (second p)))
                                      (unless (valid-type-p type)
                                        (error 'crisp-unknown-type-error :type-name type))
                                      (let ((parsed (parse-type-specifier type)))
                                        (make-parameter-def :name name :type parsed :kind :in))))
                                   (error "Mixed bare and typed parameters not allowed.")))))

     ;; Case 3: Standard declarations
     (t
       (log:debug "PARSE CASE 3: Standard declarations. Params: ~s" params)
       (setf env (analyze-environment-from-list params declarations))))

    (values env return-types optional-idx defaults key-idx)))
