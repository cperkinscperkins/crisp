;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;; -----------------------------------------------------------------------
;; src/metadata-val.lisp
;; Validators for 046-literals tests
;; -----------------------------------------------------------------------

(defun validate-integer-literals-ir (ir-path)
  "Validates that integer literal suffixes produce the correct LLVM integer types.
   Expects:  ret-uchar->i8, ret-short/ret-ushort->i16, ret-uint->i32, ret-long/ret-ulong->i64."
  (unless (probe-file ir-path)
    (log:error "IR file not found: ~a" ir-path)
    (return-from validate-integer-literals-ir nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (and
     (or (search "define i8 @ret_uchar" ir)
         (progn (log:error "No i8 ret_uchar function found in IR") nil))
     (or (search "define i16 @ret_short" ir)
         (progn (log:error "No i16 ret_short function found in IR") nil))
     (or (search "define i16 @ret_ushort" ir)
         (progn (log:error "No i16 ret_ushort function found in IR") nil))
     (or (search "define i32 @ret_uint" ir)
         (progn (log:error "No i32 ret_uint function found in IR") nil))
     (or (search "define i64 @ret_long" ir)
         (progn (log:error "No i64 ret_long function found in IR") nil))
     (or (search "define i64 @ret_ulong" ir)
         (progn (log:error "No i64 ret_ulong function found in IR") nil))
     t)))

(defun validate-float-literals-ir (ir-path)
  "Validates that float literal suffixes produce the correct LLVM float types.
   Expects: ret-half->half, ret-float->float, ret-bfloat16->bfloat."
  (unless (probe-file ir-path)
    (log:error "IR file not found: ~a" ir-path)
    (return-from validate-float-literals-ir nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (and
     (or (search "define half @ret_half" ir)
         (progn (log:error "No half ret_half function found in IR") nil))
     (or (search "define float @ret_float" ir)
         (progn (log:error "No float ret_float function found in IR") nil))
     (or (search "define bfloat @ret_bfloat16" ir)
         (progn (log:error "No bfloat ret_bfloat16 function found in IR") nil))
     t)))

;; -----------------------------------------------------------------------
;; src/analysis/core.lisp
;; Typed numeric literal support: 255uc, 100s, 1000UL, 1.5f, 1.5bf, etc.
;; -----------------------------------------------------------------------

(defun %try-parse-typed-literal (expr location)
  "If EXPR is a symbol whose name matches <integer><suffix> or <number><suffix>,
   returns a semantic-literal node with the appropriate Crisp type and value.
   Suffixes (symbols are already upcased by the SBCL reader):
     BF -> bfloat16   UC -> uchar   UL -> ulong   US -> ushort
     U  -> uint       S  -> short   L  -> long
     H  -> half       F  -> float
   Multi-character suffixes are tested first to avoid BF matching F,
   UL matching L, etc.  Returns NIL if EXPR does not match."
  (unless (symbolp expr)
    (return-from %try-parse-typed-literal nil))
  (let ((name (symbol-name expr)))
    (flet ((try-int (suffix type)
             (let ((slen (length suffix)))
               (when (and (> (length name) slen)
                          (string= name suffix :start1 (- (length name) slen)))
                 (let ((num-str (subseq name 0 (- (length name) slen))))
                   (multiple-value-bind (val end)
                       (parse-integer num-str :junk-allowed t)
                     (when (and val (= end (length num-str)))
                       (log:debug "%try-parse-typed-literal: ~a -> (~a ~a)" name type val)
                       (make-semantic-literal :value-type type
                                              :value val
                                              :source-location location)))))))
           (try-float (suffix type)
             (let ((slen (length suffix)))
               (when (and (> (length name) slen)
                          (string= name suffix :start1 (- (length name) slen)))
                 (let* ((num-str (subseq name 0 (- (length name) slen)))
                        (val (ignore-errors
                               (let ((v (with-input-from-string (in num-str)
                                          (read in nil nil))))
                                 (when (realp v) v)))))
                   (when val
                     (log:debug "%try-parse-typed-literal: ~a -> (~a ~a)" name type val)
                     (make-semantic-literal :value-type type
                                            :value val
                                            :source-location location)))))))
      ;; Multi-char suffixes first to prevent substring ambiguity
      (or (try-float "BF" 'bfloat16)
          (try-int   "UC" 'uchar)
          (try-int   "UL" 'ulong)
          (try-int   "US" 'ushort)
          (try-int   "U"  'uint)
          (try-int   "S"  'short)
          (try-int   "L"  'long)
          (try-float "H"  'half)
          (try-float "F"  'float)))))

(defun analyze-expression (expr env context location)
  "Recursively analyzes a *single* expression."
  (log:debug "analyze-expression expr: ~s location: ~s" expr location)
  ;; Handle empty body case, which `read` can return as NIL
  (when (null expr)
        (return-from analyze-expression (make-semantic-progn :type '(nil) :body nil :source-location location)))

  (let ((res
         (cond
          ;; Case 1: It's a literal, like 7
          ((integerp expr)
            (make-semantic-literal :value-type 'int :value expr :source-location location))

          ;; Case 1.1: It's a float literal, like 3.14
          ((floatp expr)
            ;; For now, all floating point literals default to the 'float' type.
            (make-semantic-literal :value-type 'float :value expr :source-location location))

          ;; Case 1.5: It's a keyword symbol, like :foo
          ((keywordp expr)
            (make-semantic-literal :value-type (list 'keyword expr) :value expr :source-location location))

          ;; Case 2: It's a typed numeric literal (e.g. 255uc, 1000UL, 1.5f) or a variable.
          ;; Try the literal parser first; fall through to env lookup if it doesn't match.
          ((symbolp expr)
            (let ((literal-node (%try-parse-typed-literal expr location)))
              (if literal-node
                  literal-node
                  (let ((found (find-variable-in-env expr env)))
                    (if found
                        (let ((type-val (parameter-def-type found)))
                          (log:warn "ANALYZE-EXPR VAR: ~a -> Type: ~a" expr type-val)
                          (make-semantic-var-read :name expr :type type-val :source-location location))
                        (progn
                         (log:error "Unknown Variable Lookup: ~a (pkg: ~a)" expr (package-name (symbol-package expr)))
                         (log:error "Env Keys: ~a" (mapcar (lambda (p) (let ((s (parameter-def-name p))) (if (symbolp s) (format nil "~a (pkg: ~a)" s (package-name (symbol-package s))) (format nil "NON-SYMBOL-KEY: ~a" s)))) env))
                         (error 'crisp-unknown-variable
                           :name expr
                           :source-location location)))))))

          ;; Case 3: It's a function call, like '(+ a b)'
          ((listp expr) (let ((op (first expr)))
                          (log:warn "analyze-expression list op: ~a (pkg: ~a) macro-function: ~a" op (package-name (symbol-package op)) (macro-function op))
                          (when (eq op 'quote)
                                (log:warn "ANALYZE-EXPR (NEW): QUOTE check. Analyzer: ~a" (gethash op *expression-analyzers*)))
                          (log:debug "analyze-expression list op: ~a~%  *expression-analyzers*: ~a~% *function-table*: ~a~%" op *expression-analyzers* *function-table*)

                          ;; HOISTED CHECK: Try incomplete accessor first
                          (let ((hook-res (analyze-incomplete-type-accessor op expr env context location)))
                            (if hook-res
                                hook-res
                                ;; Otherwise continue with standard checks
                                (cond ;; Case 3a: Is there a specific handler for this operator (e.g., '+', 'to-char')?
                                     ((gethash op *expression-analyzers*)
                                       (funcall (gethash op *expression-analyzers*) expr env context location))
                                     ;; Case 3b: Is it a macro?
                                     ((macro-function op)
                                       (let ((expanded (macroexpand-1 expr)))
                                         (log:warn "ANALYZE-EXPR MACRO: ~s -> ~s" expr expanded)
                                         (analyze-expression expanded env context location)))
                                     ;; Case 3c: Is it a call to a known user-defined function?
                                     ;; Also check implicit *template-registry* for overloading
                                     ;; AND *generic-functions* for lazy instantiation
                                     ((or (gethash op *function-table*)
                                          (gethash op *template-registry*)
                                          (gethash op *generic-functions*))
                                       (analyze-function-call op expr env context location))
                                     ;; Case 3e: Otherwise, we don't know what this is.
                                     (t
                                       (let ((pkg (symbol-package op)))
                                         (log:debug "  UNSUPPORTED FORM: ~s (pkg: ~a)" op (if pkg (package-name pkg) "NIL"))
                                         (log:debug "  Macro Function? ~a" (macro-function op))
                                         (log:debug "  Bound Function? ~a" (fboundp op)))
                                       (log:debug "  Function Table Keys: ~a" (alexandria:hash-table-keys *function-table*))
                                       (error 'crisp-unsupported-form-error
                                         :form op
                                         :source-location (append location '(0)))))))))
          (t (error 'crisp-unsupported-form-error
               :form expr
               :source-location location)))))
    res))
