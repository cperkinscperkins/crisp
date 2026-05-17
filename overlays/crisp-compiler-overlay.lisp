;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;; ==========================================================================
;; Endeavor 105 — tensor-stride and grid-stride.
;;
;; Phase A (this commit): safe `tensor-stride` analyzer.  Mirrors
;; analyze-loop-vector-stride-expression in src/analysis/control.lisp but
;; generalizes to N dimensions.  Form:
;;
;;   (tensor-stride T (b0 b1 ... b_{N-1}) BODY...)
;;
;; Expands to a single linear dotimes over total length, then decodes
;; multi-D coords from the flat index.  Decode direction depends on the
;; tensor's static contiguous-term (CT):
;;   :last  — warp varies last binding (row-major-style).
;;            flat = i0*s0 + i1*s1 + ... + i_{N-1}
;;            s_k = product(extents[k+1..N-1]); s_{N-1} = 1
;;   :first — warp varies first binding (col-major-style).
;;            flat = i_{N-1}*s_{N-1} + ... + i_0
;;            s_k = product(extents[0..k-1]); s_0 = 1
;;
;; Decode without `mod` (no user-facing op): i = flat / s; rem = flat - i*s.

(defun %ts-build-decode-bindings (flat-sym binding-syms stride-syms ct)
  "Builds the let* binding list that decodes FLAT-SYM into BINDING-SYMS using
   STRIDE-SYMS (per-iteration-strides for each dim, length N or N-1) under
   contiguous-term CT (:last or :first).

   For CT :last:  i0 = flat/s0; rem1 = flat - i0*s0; i1 = rem1/s1; ...; i_{N-1} = rem_{N-1}
   For CT :first: i_{N-1} = flat/s_{N-1}; rem1 = flat - i_{N-1}*s_{N-1}; ...; i_0 = rem_{N-1}"
  (let* ((cl-pkg  (find-package :crisp-language))
         (div-sym (intern "/"  cl-pkg))
         (sub-sym (intern "-"  cl-pkg))
         (mul-sym (intern "*"  cl-pkg))
         (n       (length binding-syms))
         (ordered-bindings (if (eq ct :first)
                               (reverse binding-syms)
                               binding-syms)))
    ;; ordered-bindings[k] gets stride-syms[k] for k < N-1; last gets rem.
    ;; For N=1, no decode needed — caller handles that case separately.
    (let ((bindings nil)
          (current-flat flat-sym))
      (loop for k from 0 below (1- n)
            for bsym = (nth k ordered-bindings)
            for s    = (nth k stride-syms)
            for next-rem = (gensym "REM")
            do (push (list bsym (list div-sym current-flat s)) bindings)
               (push (list next-rem (list sub-sym current-flat
                                          (list mul-sym bsym s)))
                     bindings)
               (setf current-flat next-rem))
      ;; Last binding takes the final remainder
      (push (list (nth (1- n) ordered-bindings) current-flat) bindings)
      (nreverse bindings))))

(defun %ts-build-stride-bindings (extents-syms ct)
  "Returns a list of (stride-sym stride-form) bindings for the per-iteration
   strides, in dim-index order (s_0 .. s_{N-2}).  For N=1, returns NIL.

   For CT :last:  s_k = product(E_{k+1} .. E_{N-1})
   For CT :first: s_k = product(E_0     .. E_{k-1})  but iteration uses these
                  in reverse, so we build s_{N-1} .. s_1 instead.
   Returned bindings have the same indexing convention as %ts-build-decode-bindings."
  (let* ((cl-pkg  (find-package :crisp-language))
         (mul-sym (intern "*" cl-pkg))
         (n       (length extents-syms))
         (result  nil))
    (when (= n 1)
      (return-from %ts-build-stride-bindings nil))
    (case ct
      (:last
       ;; ordered-bindings[k] corresponds to dim k; needs s_k = E_{k+1} * .. * E_{N-1}
       (loop for k from 0 below (1- n)
             for sym = (gensym (format nil "S~A" k))
             for factors = (subseq extents-syms (1+ k))
             for form = (if (= (length factors) 1)
                            (first factors)
                            (reduce (lambda (a b) (list mul-sym a b)) factors))
             do (push (list sym form) result)))
      (:first
       ;; ordered-bindings is reversed; ordered-bindings[k] corresponds to dim N-1-k.
       ;; Needs s = E_0 * .. * E_{N-2-k} for k = 0 .. N-2.
       (loop for k from 0 below (1- n)
             for dim-idx = (- n 2 k)
             for sym = (gensym (format nil "S~A" k))
             for factors = (subseq extents-syms 0 (1+ dim-idx))
             for form = (if (= (length factors) 1)
                            (first factors)
                            (reduce (lambda (a b) (list mul-sym a b)) factors))
             do (push (list sym form) result))))
    (nreverse result)))

(defun %ts-canonicalize-tensor-type (raw-type)
  "Resolves RAW-TYPE down to the canonical 6-tuple (TENSOR elem N addr aln ct).
   Mirrors %083-require-2d-tensor's normalisation but is arity-agnostic.
   Returns the 6-tuple, or NIL when RAW-TYPE isn't a tensor."
  (let* ((resolved (resolve-type-alias raw-type))
         (resolved (if (and (listp resolved) (= (length resolved) 1) (listp (first resolved)))
                       (first resolved)
                       resolved))
         (canon (cond
                  ((and (listp resolved)
                        (symbolp (first resolved))
                        (string-equal (symbol-name (first resolved)) "TENSOR"))
                   resolved)
                  ((symbolp resolved)
                   (let ((u (unmangle-template-struct-name resolved)))
                     (if (and (listp u) (symbolp (first u))
                              (string-equal (symbol-name (first u)) "TENSOR"))
                         u nil)))
                  ((and (listp resolved)
                        (symbolp (first resolved))
                        (member (symbol-name (first resolved))
                                '("VECTOR" "MATRIX") :test #'string-equal))
                   (canonicalize-type-specifier resolved))
                  (t nil))))
    canon))

(defun %ts-layout-tag-to-ct (tag n location)
  "Maps a strict layout-tag to its effective contiguous-term (:last or :first).
   Validates the tag and (for :row-major / :col-major) the 2D restriction."
  (case tag
    (:row-major
     (unless (= n 2)
       (error 'crisp-compiler-error
              :message (format nil "tensor-stride :row-major requires a 2D tensor, got ~A bindings" n)
              :source-location location))
     :last)
    (:col-major
     (unless (= n 2)
       (error 'crisp-compiler-error
              :message (format nil "tensor-stride :col-major requires a 2D tensor, got ~A bindings" n)
              :source-location location))
     :first)
    (:contiguous-last  :last)
    (:contiguous-first :first)
    (otherwise
     (error 'crisp-compiler-error
            :message (format nil "tensor-stride: unknown layout-tag ~S (expected :row-major, :col-major, :contiguous-last, or :contiguous-first)" tag)
            :source-location location))))

(defun analyze-tensor-stride-expression (expr env context location)
  "Analyzes the tensor-stride form, both variants:
     safe:   (tensor-stride T (BINDINGS...) BODY...)
     strict: (tensor-stride T LAYOUT-TAG (BINDINGS...) BODY...)

   For an N-D tensor with contiguous-term CT, expands to a single linear
   dotimes over total length, then decodes multi-D coords from the flat
   index.  Strict variant: validates LAYOUT-TAG against the tensor's static
   CT — disagreement is a compile-time error.

   The (declare (grid-level)) enforces dispatch context and prevents nesting."
  ;; Distinguish safe vs strict by whether (third expr) is a keyword.
  (let* ((strict-p   (keywordp (third expr)))
         (layout-tag (when strict-p (third expr)))
         (bindings   (if strict-p (fourth expr) (third expr)))
         (body-forms (if strict-p (cddddr expr) (cdddr expr)))
         (tensor-form (second expr)))
    (unless (and bindings
                 (listp bindings)
                 (every #'symbolp bindings)
                 (>= (length bindings) 1))
      (error 'crisp-compiler-error
             :message (if strict-p
                          "Malformed tensor-stride: expected (tensor-stride TENSOR LAYOUT-TAG (BINDING ...) BODY...)"
                          "Malformed tensor-stride: expected (tensor-stride TENSOR (BINDING ...) BODY...)")
             :source-location location))
  (let* ((n           (length bindings))
         ;; Pre-analyze tensor expression to read its static type — only the
         ;; type info is used; the form will be re-analyzed inside the let.
         (probe-node  (analyze-expression tensor-form env context (append location '(1))))
         (raw-type    (semantic-node-type probe-node))
         (canon-type  (%ts-canonicalize-tensor-type raw-type))
         (declared-n  (when (and (listp canon-type) (>= (length canon-type) 3))
                        (third canon-type)))
         ;; %get-tensor-ct may return the CT slot as a non-keyword symbol
         ;; (when canon-type came from unmangling).  Normalise to keyword.
         (static-ct-raw (if (listp canon-type)
                            (%get-tensor-ct canon-type)
                            :last))
         (static-ct   (cond
                        ((keywordp static-ct-raw) static-ct-raw)
                        ((symbolp static-ct-raw)
                         (intern (symbol-name static-ct-raw) :keyword))
                        (t :last)))
         (tag-ct      (when strict-p
                        (%ts-layout-tag-to-ct layout-tag n location)))
         ;; Strict variant: validate tag agrees with the tensor's static CT.
         (ct          (cond
                        ((not strict-p) static-ct)
                        ((null static-ct) tag-ct)
                        ((eq tag-ct static-ct) tag-ct)
                        (t
                         (error 'crisp-compiler-error
                                :message (format nil
                                                 "tensor-stride: layout-tag ~S implies contiguous-term ~S but the tensor's static type has contiguous-term ~S"
                                                 layout-tag tag-ct static-ct)
                                :source-location location)))))
    ;; Validate: declared-N must match bindings count when known.
    (when (and (integerp declared-n) (/= declared-n n))
      (error 'crisp-compiler-error
             :message (format nil
                              "tensor-stride: tensor has ~A dimension(s) but ~A binding(s) provided"
                              declared-n n)
             :source-location location))
    ;; Gensym names for internal vars
    (let* ((t-sym     (gensym "T"))
           (gid-sym   (gensym "GID"))
           (gsize-sym (gensym "GSIZE"))
           (len-sym   (gensym "LEN"))
           (k-sym     (gensym "K"))
           (flat-sym  (gensym "FLAT"))
           (extents-syms (loop for i from 0 below n collect (gensym (format nil "E~A" i))))
           ;; Use crisp-language symbols for the recognised operators
           (cl-pkg         (find-package :crisp-language))
           (let-sym        (intern "LET"                  cl-pkg))
           (let*-sym       (intern "LET"                  cl-pkg))
           (declare-sym    (intern "DECLARE"              cl-pkg))
           (grid-level-sym (intern "GRID-LEVEL"           cl-pkg))
           (dotimes-sym    (intern "DOTIMES"              cl-pkg))
           (if-sym         (intern "IF"                   cl-pkg))
           (progn-sym      (intern "PROGN"                cl-pkg))
           (get-gid-sym    (intern "GET-GLOBAL-ID"        cl-pkg))
           (get-gsize-sym  (intern "GET-GLOBAL-WORK-SIZE" cl-pkg))
           (len-tilde-sym  (intern "LENGTH~"              cl-pkg))
           (extents-tilde  (intern "EXTENTS~"             cl-pkg))
           (aref-sym       (intern "~"                    cl-pkg))
           (plus-sym       (intern "+"                    cl-pkg))
           (lt-sym         (intern "<"                    cl-pkg))
           ;; extent reads: (~ (extents~ T) i)
           (extent-bindings
            (loop for esym in extents-syms
                  for i from 0
                  collect (list esym (list aref-sym
                                           (list extents-tilde t-sym)
                                           i))))
           (stride-bindings (%ts-build-stride-bindings extents-syms ct))
           (decode-bindings (if (= n 1)
                                ;; 1D: single binding gets the flat directly
                                (list (list (first bindings) flat-sym))
                                (%ts-build-decode-bindings
                                 flat-sym bindings
                                 (mapcar #'first stride-bindings)
                                 ct))))
      (let* ((inner-let
              ;; (let* (<decode-bindings>) BODY...)
              (list* let*-sym decode-bindings body-forms))
             (inner-when
              ;; (if (< flat len) <inner-let>) — using IF instead of WHEN so
              ;; the AD backward walker recognises the conditional (it has
              ;; an IF branch but no WHEN branch in %handle-single-value-backward).
              (list if-sym (list lt-sym flat-sym len-sym) inner-let))
             (flat-let
              ;; (let ((flat (+ k gid))) <inner-when>)
              (list let-sym
                    (list (list flat-sym (list plus-sym k-sym gid-sym)))
                    inner-when))
             (dotimes-form
              ;; (dotimes (k len gsize) <flat-let>)
              (list dotimes-sym
                    (list k-sym len-sym gsize-sym)
                    flat-let))
             (outer-let
              ;; (let* ((__t T) (gid ...) (gsize ...) (len ...) <extents> <strides>)
              ;;   (declare (grid-level))
              ;;   <dotimes-form>)
              (list* let*-sym
                     (append (list (list t-sym tensor-form)
                                   (list gid-sym   (list get-gid-sym 0))
                                   (list gsize-sym (list get-gsize-sym 0))
                                   (list len-sym   (list len-tilde-sym t-sym)))
                             extent-bindings
                             stride-bindings)
                     (list (list declare-sym (list grid-level-sym))
                           dotimes-form))))
        (analyze-expression outer-let env context location))))))

;; ==========================================================================
;; Phase C — grid-stride.  No tensor: a size-list and a bindings-list.
;; Total iteration = product of sizes.  Iteration is always row-major
;; (rightmost binding gets the warp).  Equivalent to safe tensor-stride
;; with CT=:last, but bypasses tensor introspection.
;;
;;   (grid-stride (<size-list>) (<bindings>) BODY...)

(defun analyze-grid-stride-expression (expr env context location)
  "Analyzes (grid-stride (SIZE-LIST) (BINDINGS) BODY...).
   Both lists must have the same arity (>= 1).  Expands to a single linear
   dotimes over the total iteration count (product of sizes), then decodes
   multi-D coords with rightmost-binding-gets-warp ordering."
  (unless (and (>= (length expr) 4)
               (listp (second expr))
               (listp (third expr))
               (every #'symbolp (third expr))
               (>= (length (second expr)) 1)
               (= (length (second expr)) (length (third expr))))
    (error 'crisp-compiler-error
           :message "Malformed grid-stride: expected (grid-stride (SIZE ...) (BINDING ...) BODY...) with size and binding arity matching and >= 1"
           :source-location location))
  (let* ((size-forms  (second expr))
         (bindings    (third expr))
         (body-forms  (cdddr expr))
         (n           (length bindings))
         (cl-pkg      (find-package :crisp-language))
         (let-sym         (intern "LET"                  cl-pkg))
         (let*-sym        (intern "LET"                  cl-pkg))
         (declare-sym     (intern "DECLARE"              cl-pkg))
         (grid-level-sym  (intern "GRID-LEVEL"           cl-pkg))
         (dotimes-sym     (intern "DOTIMES"              cl-pkg))
         (if-sym          (intern "IF"                   cl-pkg))
         (get-gid-sym     (intern "GET-GLOBAL-ID"        cl-pkg))
         (get-gsize-sym   (intern "GET-GLOBAL-WORK-SIZE" cl-pkg))
         (plus-sym        (intern "+"                    cl-pkg))
         (mul-sym         (intern "*"                    cl-pkg))
         (lt-sym          (intern "<"                    cl-pkg))
         (to-ulong-sym    (intern "TO-ULONG"             cl-pkg))
         (gid-sym         (gensym "GID"))
         (gsize-sym       (gensym "GSIZE"))
         (len-sym         (gensym "LEN"))
         (k-sym           (gensym "K"))
         (flat-sym        (gensym "FLAT"))
         (extents-syms    (loop for i from 0 below n collect (gensym (format nil "E~A" i))))
         (size-bindings   (loop for esym in extents-syms
                                for form in size-forms
                                collect (list esym (list to-ulong-sym form))))
         (len-form        (if (= n 1)
                              (first extents-syms)
                              (reduce (lambda (a b) (list mul-sym a b))
                                      extents-syms)))
         (stride-bindings (%ts-build-stride-bindings extents-syms :last))
         (decode-bindings (if (= n 1)
                              (list (list (first bindings) flat-sym))
                              (%ts-build-decode-bindings
                               flat-sym bindings
                               (mapcar #'first stride-bindings)
                               :last)))
         (inner-let       (list* let*-sym decode-bindings body-forms))
         (inner-if        (list if-sym (list lt-sym flat-sym len-sym) inner-let))
         (flat-let        (list let-sym
                                (list (list flat-sym (list plus-sym k-sym gid-sym)))
                                inner-if))
         (dotimes-form    (list dotimes-sym
                                (list k-sym len-sym gsize-sym)
                                flat-let))
         (outer-let
          (list* let*-sym
                 (append (list (list gid-sym   (list get-gid-sym 0))
                               (list gsize-sym (list get-gsize-sym 0)))
                         size-bindings
                         (list (list len-sym len-form))
                         stride-bindings)
                 (list (list declare-sym (list grid-level-sym))
                       dotimes-form))))
    (analyze-expression outer-let env context location)))

;; src/autodiff.lisp — %backward-skip-fn-p.
;;
;; Endeavor 105 follow-up: the AD backward walker had no skip entries for the
;; 17 GPU built-ins added in endeavor 087 (get-global-id, get-global-work-size,
;; etc.).  These return per-launch constants — gradient is zero, sink-style —
;; so they should be silently skipped, the same way other metadata helpers
;; (length~, extents~, etc.) are.  Without this, any kernel that uses
;; tensor-stride / grid-stride / loop-vector-stride could not differentiate
;; even when its body's chain rule was otherwise valid.
;;
;; Whole-function replacement (preserves all original cases + adds GPU builtins).
(defun %backward-skip-fn-p (fn-sym)
  "Returns T if FN-SYM should be silently skipped in the AD backward walk.
Skips:
  - System-generated functions (name contains %)
  - AS / AS-* type casts and derived-type coercions
  - TO-<int-type> integer conversions
  - 101 endeavor: built-in metadata helpers and view constructors.
  - 105 endeavor: 087 GPU built-ins (per-launch constants and sync primitives)."
  (let ((name (symbol-name fn-sym)))
    (cl:flet ((prefix-or-mangled-p (prefix)
                (let ((plen (length prefix)))
                  (or (string= name prefix)
                      (and (> (length name) plen)
                           (string= (subseq name 0 plen) prefix)
                           (cl:char= (cl:char name plen) #\_))))))
      (or
       (find #\% name)
       (string= name "AS")
       (and (>= (length name) 3) (string= (subseq name 0 3) "AS-"))
       (loop for suffix in '("ULONG" "LONG" "UINT" "INT" "USHORT" "SHORT" "UCHAR" "CHAR" "BOOL")
                when (and (>= (length name) (+ 3 (length suffix)))
                          (string= (subseq name 0 3) "TO-")
                          (string= (subseq name (- (length name) (length suffix))) suffix))
                return t)
       (loop for prefix in '("NUM-ROWS" "NUM-COLS" "GET-LAYOUT" "BYTES~"
                             "LENGTH~" "EXTENTS~" "STRIDES~" "PARENT~"
                             "CONTIGUOUS-TERM~" "ELEMENT-TYPE~" "ADDRESS-SPACE~"
                             "ALIGN~" "NUM-DIMS~" "OFFSET~"
                             "MAKE-MATRIX" "MAKE-VECTOR" "MAKE-CELL" "MAKE-TENSOR"
                             "TRANSPOSE" "TRANSPOSE!" "ROW" "COL" "SLICE"
                             ;; 105 follow-up: 087 GPU built-ins.  All 17 return
                             ;; per-launch constants (sizes, indices) or are
                             ;; synchronization primitives; none carry gradient.
                             "GET-GLOBAL-ID" "GET-LOCAL-ID" "GET-WORKGROUP-ID"
                             "GET-NUM-GROUPS" "GET-LOCAL-WORK-SIZE"
                             "GET-GLOBAL-WORK-SIZE" "GET-GLOBAL-OFFSET"
                             "GET-GLOBAL-ID-ABS" "GET-WORK-DIM"
                             "GET-LOCAL-LINEAR-ID" "GET-LOCAL-LINEAR-SIZE"
                             "GET-GLOBAL-LINEAR-ID" "GET-GLOBAL-LINEAR-SIZE"
                             "GET-TOTAL-THREADS" "GET-TOTAL-GROUPS"
                             "LOCAL-BARRIER" "MEM-FENCE")
             when (prefix-or-mangled-p prefix) return t)))))

;; src/analysis/control.lisp — register-control-analyzers.
;; Whole-function replacement (mirroring the full original) with one extra
;; registration block at the end for tensor-stride (endeavor 105 Phase A).
(defun register-control-analyzers ()
  "Registers all control flow expression analyzers, including loop-vector-stride
   and (endeavor 105) tensor-stride."
  (def-expression-analyzer function analyze-function-literal)
  (def-expression-analyzer common-lisp:function analyze-function-literal)
  (def-expression-analyzer funcall analyze-funcall-expression)
  (def-expression-analyzer let analyze-let-expression)
  (def-expression-analyzer common-lisp:let analyze-let-expression)
  (def-expression-analyzer let* analyze-let-expression)
  (def-expression-analyzer common-lisp:let* analyze-let-expression)
  (def-expression-analyzer progn analyze-progn-expression)
  (def-expression-analyzer sizeof analyze-sizeof-expression)
  (def-expression-analyzer compiler-no-op analyze-compiler-no-op)
  (def-expression-analyzer is-set? analyze-is-set-expression)
  (def-expression-analyzer if analyze-if-expression)
  (def-expression-analyzer when analyze-when-expression)
  (def-expression-analyzer common-lisp:when analyze-when-expression)
  (def-expression-analyzer unless analyze-unless-expression)
  (def-expression-analyzer common-lisp:unless analyze-unless-expression)
  (def-expression-analyzer return analyze-return-expression)
  (def-expression-analyzer explicit-return analyze-return-expression)
  (def-expression-analyzer semantic-return analyze-return-expression)
  (def-expression-analyzer quote analyze-quote)
  (def-expression-analyzer if+ analyze-static-if-expression)
  (def-expression-analyzer when+ analyze-static-when-expression)
  (def-expression-analyzer unless+ analyze-static-unless-expression)
  (def-expression-analyzer def-function analyze-nested-def-function)
  (def-expression-analyzer template-instantiation analyze-template-instantiation)
  (def-expression-analyzer common-lisp:eval-when analyze-eval-when)
  ;; length~
  (let ((sym-cl (intern "LENGTH~" (find-package :crisp-language)))
        (sym-cc (intern "LENGTH~" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-length-tilde-expression)
    (setf (gethash sym-cc *expression-analyzers*) #'analyze-length-tilde-expression))
  ;; dotimes
  (let ((sym-cl (intern "DOTIMES" (find-package :crisp-language)))
        (sym-cc (intern "DOTIMES" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-dotimes-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-dotimes-expression)))
  ;; loop-vector-stride — dual-package registration
  (let ((sym-cl (intern "LOOP-VECTOR-STRIDE" (find-package :crisp-language)))
        (sym-cc (intern "LOOP-VECTOR-STRIDE" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-loop-vector-stride-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-loop-vector-stride-expression)))
  ;; tensor-stride (105 Phase A) — dual-package registration
  (let ((sym-cl (intern "TENSOR-STRIDE" (find-package :crisp-language)))
        (sym-cc (intern "TENSOR-STRIDE" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-tensor-stride-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-tensor-stride-expression)))
  ;; grid-stride (105 Phase C) — dual-package registration
  (let ((sym-cl (intern "GRID-STRIDE" (find-package :crisp-language)))
        (sym-cc (intern "GRID-STRIDE" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*) #'analyze-grid-stride-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*) #'analyze-grid-stride-expression))))
