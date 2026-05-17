;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;; src/macros.lisp -- %generate-backward-kernel-ast
;;
;; Endeavor 103 / Phase A fix: bind *record-param-field-adjs* around the
;; backward walk for kernels with record-at-boundary inputs.  Without this,
;; accessor calls (x~ vp) inside the kernel body fall through to the generic
;; accessor rule in %handle-single-value-backward and route adj into the
;; collective vp_adj, which never propagates to the per-field vp_x_ADJ /
;; vp_y_ADJ that the input-grad-write loop expects.  Result was: backward
;; ran without error but every grad cell got written as 0.
;;
;; The fix mirrors what %generate-backward-function-ast does for sub-function
;; record params (see autodiff.lisp): build a record-sym -> (field-name-str .
;; field-adj-sym) alist and dyn-bind *record-param-field-adjs* during the
;; backward walk.  For kernel-level, the field-adj-sym is the SROA'd field
;; input's adj (e.g. VP_X_ADJ for the vp_x scalar input), which the existing
;; input-grad-write step already writes to the matching vp_x_grad cell.
;;
;; record-subs-ht entries can include `:%nested-leaf%` sentinels for nested
;; records (added in phase 5b/101); those are filtered out here.

(defun %generate-backward-kernel-ast (name params signature-types raw-body)
  "Generates the def-kernel-exact AST for the backward (gradient) pass.
   Endeavor 103 Phase A: dyn-binds *record-param-field-adjs* so record-at-
   boundary accessor calls route adj into the SROA'd field's adj sym."
  (multiple-value-bind (inputs input-types outputs output-types)
      (%split-kernel-inputs-outputs params signature-types)
    (let* ((pkg (symbol-package name))
           (bwd-name (intern (format nil "~a_GRAD" (symbol-name name)) pkg)))
      (multiple-value-bind (flat-inputs flat-input-types record-reassembly-bindings
                            rec-grad-out-params rec-grad-out-types
                            record-subs-ht record-type-ht grad-cell-syms
                            struct-shadow-info)
          (%expand-record-kernel-inputs inputs input-types pkg)
        (let ((subst-body
               (mapcar (lambda (form)
                         (%substitute-record-accessors form record-subs-ht record-type-ht))
                       raw-body)))
          (multiple-value-bind (bwd-params bwd-types diff-flat-inputs diff-flat-input-types)
              (%compute-backward-kernel-params flat-inputs flat-input-types outputs output-types
                                               record-subs-ht rec-grad-out-params rec-grad-out-types pkg inputs)
            (when (and flat-inputs
                       (null diff-flat-inputs)
                       (null struct-shadow-info)
                       (not (some #'%crisp-integer-tensor-type-p flat-input-types))
                       (not (%has-diff-capable-scalar-input-p flat-input-types)))
              (error 'crisp.compiler:crisp-compiler-error
                :message (format nil "Cannot differentiate kernel ~A: no differentiable parameters (all inputs have non-float types -- add (forward-only) declaration or use float element types)" name)))
            (multiple-value-bind (exploded-params exploded-types bwd-cell-reassembly-bindings)
                (%explode-kernel-args bwd-params bwd-types)
              (let* ((augmented-diff-flat-inputs
                      (append diff-flat-inputs
                              (mapcar #'first struct-shadow-info)))
                     (augmented-diff-flat-input-types
                      (append diff-flat-input-types
                              (loop for entry in struct-shadow-info
                                    for p = (first entry)
                                    collect (nth (position p flat-inputs :test #'eq)
                                                 flat-input-types)))))
              (if (and (null augmented-diff-flat-inputs)
                       (null struct-shadow-info))
                  `(progn
                    (eval-when (:compile-toplevel :load-toplevel :execute)
                      (setf (gethash ',bwd-name crisp.compiler::*kernel-declared-signatures*)
                        (loop for p in ',bwd-params
                                 for t-spec in ',bwd-types
                                 collect (cons p t-spec))))
                    (def-kernel-exact ,bwd-name ,exploded-params
                                      (declare #'(,@exploded-types))
                                      (return)))
                  (let* ((anf-body      (mapcar #'anf-transform subst-body))
                         (flat-anf      (flatten-anf-body anf-body))
                         (forward-bindings
                          (loop for form in flat-anf
                                when (and (consp form) (= (length form) 2) (symbolp (car form)))
                                collect form))
                         (struct-shadow-ht
                          (when struct-shadow-info
                            (let ((ht (make-hash-table :test 'eq)))
                              (dolist (entry struct-shadow-info)
                                (setf (gethash (first entry) ht)
                                      (cons (second entry)
                                            (fourth entry))))
                              (%register-shadow-anf-intermediates flat-anf ht)
                              ht)))
                         ;; --- Phase A: record-param-field-adjs for record kernel inputs ----
                         ;; record-subs-ht maps RECORD-SYM -> ((field-sym . exploded-scalar-sym) ...)
                         ;; with possible (:%nested-leaf% . leaf-sym) sentinels we filter out.
                         ;; The field adj is the SROA'd field's <SYM>_ADJ name.
                         (kernel-record-param-field-adjs-ht
                          (when (> (hash-table-count record-subs-ht) 0)
                            (let ((ht (make-hash-table :test 'eq)))
                              (maphash
                               (lambda (rsym field-alist)
                                 (let ((adj-alist
                                        (loop for entry in field-alist
                                              for fname = (car entry)
                                              for fsym  = (cdr entry)
                                              unless (eq fname :%nested-leaf%)
                                              collect (cons (symbol-name fname)
                                                            (intern (format nil "~A_ADJ" (symbol-name fsym))
                                                                    pkg)))))
                                   (setf (gethash rsym ht) adj-alist)))
                               record-subs-ht)
                              ht)))
                         (raw-backward-walk
                          (let ((*struct-kernel-param-shadows* struct-shadow-ht)
                                (*record-param-field-adjs* kernel-record-param-field-adjs-ht))
                            (generate-backward-walk flat-anf
                                                    augmented-diff-flat-inputs outputs
                                                    augmented-diff-flat-input-types output-types
                                                    :kernel-pkg pkg)))
                         (backward-walk-1
                          (%fix-record-grad-cell-emissions raw-backward-walk grad-cell-syms))
                         (backward-walk-2
                          (if struct-shadow-info
                              (let ((all-leaves
                                     (loop for entry in struct-shadow-info
                                           append (%collect-all-leaf-adj-syms (fourth entry)))))
                                (%ensure-leaf-adj-bindings backward-walk-1 all-leaves))
                              backward-walk-1))
                         (backward-walk
                          (%fix-struct-shadow-writes backward-walk-2 struct-shadow-info))
                         (all-reassembly (append bwd-cell-reassembly-bindings record-reassembly-bindings)))
                    `(progn
                      (eval-when (:compile-toplevel :load-toplevel :execute)
                        (setf (gethash ',bwd-name crisp.compiler::*kernel-declared-signatures*)
                          (loop for p in ',bwd-params
                                   for t-spec in ',bwd-types
                                   collect (cons p t-spec))))
                      (def-kernel-exact ,bwd-name ,exploded-params
                                        (declare #'(,@exploded-types))
                                        (let (,@all-reassembly)
                                          (let (,@forward-bindings)
                                            ,backward-walk))
                                        (return)))))))))))))


;; ==========================================================================
;; IGC SROA-aliasing workaround (endeavor 103 phase B, 2026-05-16):
;;   %volatile-read pseudo-op
;;
;; Symptom: when the shadow-struct write at the end of a backward kernel reads
;; two (or more) sibling float adjoint allocas (e.g. P_X_ADJ and P_Y_ADJ) into
;; a {float, float} aggregate that is then stored to addrspace(1), Intel/IGC
;; coalesces the allocas — both reads return the value of one of them.  E.g.
;; the canonical 056/01 case wrote {4.0, 4.0} instead of the IR-correct
;; {4.0, 3.0}.  The same LLVM IR translated to PTX (NVPTX backend) produces
;; the correct output, so the IR itself is well-formed — see
;; put_temp_files_here/igc-bug-report/ for the minimal reproducer.
;;
;; Workaround: emit each leaf adjoint read in the shadow-write as
;; `load volatile`, which inhibits SROA promotion of the alloca and avoids
;; the miscompilation.  We do this surgically — only the loads that feed the
;; shadow constructor — not all loads in the backward kernel.
;;
;; Implementation:
;;   1. A new Crisp pseudo-op `%volatile-read` whose analyzer is a no-op on
;;      semantics but records the underlying semantic-var-read in a side
;;      table (*volatile-var-reads*).
;;   2. The var-read codegen consults that side table and, if present,
;;      calls LLVMSetVolatile on the emitted load.
;;   3. %build-shadow-ctor-form wraps each leaf adj-sym in (%volatile-read ...).
;;
;; Remove the wrap (and ideally this whole block) once IGC ships the fix.

(defvar *volatile-var-reads*
  (make-hash-table :test 'eq :weakness :key)
  "Set of semantic-var-read nodes whose load should be emitted as volatile.
   Weak-keyed so entries vanish when the kernel's AST is GC'd.")

(defun analyze-%volatile-read-expression (expr env context location)
  "Analyzes (%volatile-read SYM): produces the same semantic node as a plain
   var-read for SYM, but tags the node in *volatile-var-reads* so codegen
   emits the load as volatile.  IGC SROA-aliasing workaround."
  (let ((inner (analyze-expression (second expr) env context
                                   (append location '(1)))))
    (setf (gethash inner *volatile-var-reads*) t)
    inner))

;; src/analysis/core.lisp — initialize-expression-analyzers.
;; Whole-function replacement (mirroring the full original) with one
;; extra registration at the end for %volatile-read (IGC workaround).
(defun initialize-expression-analyzers ()
  "Registers all expression analyzers; extended for 087-gpu-builtins.
   Endeavor 103 phase B: adds %volatile-read for the IGC workaround."
  (clrhash *expression-analyzers*)
  (register-ops-analyzers)
  (register-control-analyzers)
  (register-struct-analyzers)
  ;; ##(...) device vector literal
  (setf (gethash 'crisp-vec-literal *expression-analyzers*)
        #'analyze-crisp-dvec-literal)
  (let ((cl-pkg (find-package :crisp-language))
        (cc-pkg (find-package :crisp.compiler)))
    ;; Component accessors x~ / y~ / z~ / w~
    (dolist (name '("X~" "Y~" "Z~" "W~"))
      (let ((sym-cl (intern name cl-pkg))
            (sym-cc (intern name cc-pkg)))
        (setf (gethash sym-cl *expression-analyzers*) #'analyze-dvec-component-ref)
        (unless (eq sym-cl sym-cc)
          (setf (gethash sym-cc *expression-analyzers*) #'analyze-dvec-component-ref))))
    ;; 083 matrix helpers: transpose, col, row, transpose!
    (dolist (entry `(("TRANSPOSE"  . ,#'analyze-transpose-expression)
                     ("COL"        . ,#'analyze-col-expression)
                     ("ROW"        . ,#'analyze-row-expression)
                     ("TRANSPOSE!" . ,#'analyze-transpose-bang-expression)))
      (let ((sym-cl (intern (car entry) cl-pkg))
            (sym-cc (intern (car entry) cc-pkg))
            (fn     (cdr entry)))
        (setf (gethash sym-cl *expression-analyzers*) fn)
        (unless (eq sym-cl sym-cc)
          (setf (gethash sym-cc *expression-analyzers*) fn))))
    ;; 087 GPU built-in functions
    (dolist (entry '(("GET-GLOBAL-ID"          :get-global-id)
                     ("GET-LOCAL-ID"            :get-local-id)
                     ("GET-WORKGROUP-ID"        :get-workgroup-id)
                     ("GET-NUM-GROUPS"          :get-num-groups)
                     ("GET-LOCAL-WORK-SIZE"     :get-local-work-size)
                     ("GET-GLOBAL-WORK-SIZE"    :get-global-work-size)
                     ("GET-GLOBAL-OFFSET"       :get-global-offset)
                     ("GET-GLOBAL-ID-ABS"       :get-global-id-abs)
                     ("GET-WORK-DIM"            :get-work-dim)
                     ("GET-LOCAL-LINEAR-ID"     :get-local-linear-id)
                     ("GET-LOCAL-LINEAR-SIZE"   :get-local-linear-size)
                     ("GET-GLOBAL-LINEAR-ID"    :get-global-linear-id)
                     ("GET-GLOBAL-LINEAR-SIZE"  :get-global-linear-size)
                     ("GET-TOTAL-THREADS"       :get-total-threads)
                     ("GET-TOTAL-GROUPS"        :get-total-groups)
                     ("LOCAL-BARRIER"           :local-barrier)
                     ("MEM-FENCE"               :mem-fence)))
      (let* ((name-str (first entry))
             (kw       (second entry))
             (fn       (let ((kw0 kw) (ns0 name-str))
                         (lambda (expr env context location)
                           (%analyze-gpu-builtin kw0 ns0 expr env context location)))))
        (let ((sym-cl (intern name-str cl-pkg))
              (sym-cc (intern name-str cc-pkg)))
          (setf (gethash sym-cl *expression-analyzers*) fn)
          (unless (eq sym-cl sym-cc)
            (setf (gethash sym-cc *expression-analyzers*) fn)))))
    ;; IGC SROA-aliasing workaround (endeavor 103 phase B): %volatile-read
    (setf (gethash '%volatile-read *expression-analyzers*)
          #'analyze-%volatile-read-expression)))

;; src/codegen.lisp — generate-node-ir on semantic-var-read.
;; Whole-method replacement; only addition is the LLVMSetVolatile call when
;; the node is tagged in *volatile-var-reads*.
(defmethod generate-node-ir ((node semantic-var-read) builder module var-env
                              di-builder di-scope location-map)
  "Generates IR for reading a variable.
   IGC workaround: emits a volatile load when NODE is tagged in
   *volatile-var-reads*."
  (declare (ignore di-builder di-scope location-map))
  (log:debug "Generating IR for var-read: ~s" (semantic-var-read-name node))
  (let* ((var-name (semantic-var-read-name node))
         (alloca (gethash var-name var-env)))
    (when (null alloca)
      (log:error "CRITICAL: Var ~a not found in var-env!" var-name)
      (log:error "Var-env keys: ~a" (alexandria:hash-table-keys var-env)))
    (let* ((type (crisp-type-to-llvm-type (semantic-var-read-type node) module))
           (loaded-name (string-downcase (format nil "~a" var-name)))
           (load-inst (llvm-build-load2 builder type alloca loaded-name)))
      (log:info "Var-read: ~a. Alloca: ~a. Type: ~a" var-name alloca type)
      (when (gethash node *volatile-var-reads*)
        (log:debug "Var-read ~a marked volatile (IGC workaround)" var-name)
        (crisp.llvm-bindings::llvm-set-volatile load-inst 1))
      (values load-inst nil))))

;; src/autodiff.lisp — %build-shadow-ctor-form.
;; Whole-function replacement; the only change is wrapping each leaf adj
;; sym in (%volatile-read ...) so the var-read codegen emits a volatile
;; load.  Nested-struct fields recurse as before (their leaves get wrapped).
(defun %build-shadow-ctor-form (struct-type-name field-adj-alist pkg)
  "Builds a (MAKE-<S>_ADJ :field1 val1 :field2 val2 ...) form recursively.
   For scalar leaf fields, val is wrapped in (%volatile-read SYM) — see
   IGC SROA-aliasing workaround commentary above."
  (let ((ctor (%make-shadow-constructor-name-for struct-type-name)))
    (cons ctor
          (loop for (fname-str . field-info) in field-adj-alist
                append
                (list (intern fname-str :keyword)
                      (cond
                        ((%nested-field-info-p field-info)
                         (let* ((fields (%get-record-runtime-fields struct-type-name))
                                (fentry (find fname-str fields
                                              :key (lambda (f) (symbol-name (first f)))
                                              :test #'string-equal))
                                (inner-type (when fentry (second fentry))))
                           (if (and inner-type (%crisp-struct-type-p inner-type))
                               (%build-shadow-ctor-form inner-type field-info pkg)
                               0)))
                        (t (list '%volatile-read field-info))))))))
