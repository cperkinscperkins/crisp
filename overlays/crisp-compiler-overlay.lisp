;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;;
;;;; INSTRUCTIONS:
;;;; 1. APPEND new/fixed function definitions to the end of this file.
;;;; 2. Add a comment naming the original file (e.g. ;; src/compiler.lisp).
;;;; 3. Do not modify the original file in src/ until cleanup time.
;;;;
;;;; EMPTY as of 2026-10-10 -- endeavour 183 (last-man fence; BUG 082) folded: %warp-spec-check-sync
;;;;   (src/analysis/control.lisp) and the three last-man lowerings (src/analysis/ops.lisp).
;;;; Before that, 2026-10-08 -- endeavours 181 (last-man sweep) and 182 (NVIDIA register budget)
;;;; folded into src/:
;;;;   * strided final sweep      -> %181-strided-sweep-form (new), %grid-reduce-last-man-expand,
;;;;                                  %fused-grid-reduce-form, %fused-grid-reduce-dependent-form,
;;;;                                  %implicit-scratch-alloc-form (:match-num-workgroups) (src/analysis/ops.lisp)
;;;;   * profile key              -> *hardware-profile-schema* :stream-occupancy-target (src/hardware-profile.lisp)
;;;;   * occupancy target         -> *kernel-occupancy-targets*, *stream-functions*, *analyzing-function*
;;;;                                  (src/compiler.lisp); %declared-local-size-dims, %parse-occupancy-target-decl,
;;;;                                  internal-def-function binds/parses (src/analysis/core.lisp);
;;;;                                  %expand-loop-vector-stride-form marks the stream (src/analysis/control.lisp)
;;;;   * launch bounds            -> %effective-occupancy-target, %apply-occupancy-bound, called beside
;;;;                                  %apply-cluster-dims-attribute (src/codegen.lisp)
;;;;   * spec validators          -> %ptx-minnctapersm, validate-ptx-minnctapersm-4/-2, validate-ptx-no-minnctapersm
;;;;                                  (src/mma.lisp)

(in-package :crisp.compiler)

;;; =====================================================================================
;;; ADV-018 (adversarial): structs with a :c-t member that has NO default were unusable.
;;;   make-XXXX dropped the c-t values (the value was typed as the bare, incomplete NAME),
;;;   so no accessor matched it; and on a c-t-qualified type -- (my-cfg :exec :fast), or a
;;;   def-type alias of one -- %extract-struct-member / %insert-struct-member refused the
;;;   list form ("Cannot extract member from non-struct type").  Fix: the constructor carries
;;;   the required c-t values as a trailing quoted (%ct-props ...) argument, the analyzer
;;;   types the value as (NAME :k v ...), and member access resolves aliases / qualified types
;;;   to the struct NAME.
;;; =====================================================================================

;; src/structs.lisp
(defun validate-and-reorder-struct-args (struct-name defined-members args)
  "Validates and reorders keyword arguments for a struct constructor macro."
  ;; 0. Identify Runtime vs Compile-Time members
  (let* ((runtime-members (remove-if (lambda (m) (and (consp m) (eq (third m) :c-t))) defined-members))
            ;; Required CT members are those marked :c-t but have NO value (incomplete)
            (ct-required-members (remove-if-not (lambda (m) (and (consp m) (eq (third m) :c-t) (null (fourth m)))) defined-members))
            (processed-args (make-hash-table :test 'eq))
            (ordered-values '()))

    ;; 1. Parse into a hash table
    (let ((ptr args))
      (loop while ptr do
              (let ((key (first ptr))
                       (val (second ptr)))
                (unless (keywordp key)
                  (error "Struct constructor for ~a requires keyword arguments. Found: ~s" struct-name key))
                (unless (second ptr)
                  (error "Struct constructor for ~a has missing value for key: ~s" struct-name key))
                (when (gethash key processed-args)
                  (error "Struct constructor for ~a has duplicate key: ~s" struct-name key))

                (setf (gethash key processed-args) val)
                (setf ptr (cddr ptr)))))

    ;; 2. Validate and Reorder Runtime Arguments (Construction Payload)
    (loop for (member-name member-type) in runtime-members do
            (let* ((kw (intern (symbol-name member-name) :keyword))
                      (val (gethash kw processed-args)))
              (unless val
                (error "Struct constructor for ~a missing required argument: ~s" struct-name kw))
              (push val ordered-values)))

    ;; 3. Validate Compile-Time Required Arguments (Validation Only, not part of runtime payload)
    (loop for member in ct-required-members do
            (let* ((member-name (first member))
                      (kw (intern (symbol-name member-name) :keyword))
                      (val (gethash kw processed-args)))
              (unless val
                (error "Struct constructor for ~a missing required compile-time argument: ~s" struct-name kw))))

    ;; 4. Check for unknown keys (against ALL members, including compile-time ones)
    (maphash (lambda (k v)
               (declare (ignore v))
               (unless (find k defined-members :key (lambda (m) (intern (symbol-name (first m)) :keyword)))
                 (error "Struct constructor for ~a has unknown argument: ~s" struct-name k)))
             processed-args)

    ;; 5. ADV-018: carry the REQUIRED compile-time values into the construction form, so the
    ;; analyzer can type the value as (NAME :k v ...) -- a complete type -- instead of the bare,
    ;; incomplete NAME.  Encoded as trailing ATOMS, :%ct-props :k v ..., because the ANF
    ;; transform lifts any non-atomic argument (even a quoted one) into a temporary, which the AD
    ;; walk then reads as a call.  LAST, so positional consumers of the runtime args (the AD
    ;; constructor rule) never see it.  A non-atomic c-t value (a type spec, say) is not carried:
    ;; the value keeps the bare NAME, as before.  Defaulted c-t members are left out, as before.
    (let ((ct-props (loop for member in ct-required-members
                          for kw = (intern (symbol-name (first member)) :keyword)
                          append (list kw (gethash kw processed-args)))))
      (log:debug "validate-and-reorder-struct-args ~a: required c-t props ~s" struct-name ct-props)
      ;; A mangled template-instance struct (FAKE-CELL_FLOAT) keeps the bare NAME: template
      ;; inference unmangles bare names, and detect-and-register-implicit-template already treats
      ;; such names as complete (same '_' test), so qualifying them only breaks inference (037/07).
      (if (and ct-props (every #'atom ct-props)
               (not (find #\_ (symbol-name struct-name))))
          (append (nreverse ordered-values) (list :%ct-props) ct-props)
          (nreverse ordered-values)))))

(defun %split-ct-props-args (args)
  "Splits a %construct-struct argument list at the :%ct-props marker that
   validate-and-reorder-struct-args appends for a struct whose compile-time members have no
   default (ADV-018).  Returns (values runtime-args ct-plist); CT-PLIST is NIL when absent."
  (let ((pos (position :%ct-props args)))
    (if pos
        (values (subseq args 0 pos) (subseq args (1+ pos)))
        (values args nil))))

(defun %member-access-struct-name (obj-type)
  "Returns the struct/record NAME behind OBJ-TYPE for member access: OBJ-TYPE itself when
   it is a symbol naming a struct; the head of a c-t-qualified type (NAME :k v ...); and the
   same after resolving a def-type alias, e.g. (def-type fast-cfg (my-cfg :exec :fast)).
   Returns OBJ-TYPE unchanged when none of those apply, so callers' errors still name it."
  (let ((resolved (if (symbolp obj-type) (resolve-type-alias obj-type) obj-type)))
    (cond
      ((and (symbolp obj-type) (lookup-struct-definition obj-type)) obj-type)
      ((and (symbolp resolved) (lookup-struct-definition resolved)) resolved)
      ((and (consp resolved) (symbolp (car resolved)) (lookup-struct-definition (car resolved)))
       (car resolved))
      (t obj-type))))

;; src/analysis/structs.lisp
(defun analyze-struct-construction (expr env context location)
  "Analyzes a (%construct-struct type-name arg1 arg2 ...) form.
   Supports implicit promotion of base-type values to branded member types
   in struct constructors (the birthplace of branded values).
   Uses get-single-value-type to normalize function-call return type lists
   (e.g. ((STORAGE GLOBAL)) -> (STORAGE GLOBAL)) before type comparison."
  (let* ((type-name (second expr))
         (raw-args (cddr expr))
         ;; ADV-018: a trailing :%ct-props :k v ... is not runtime arguments; it makes the
         ;; constructed value's type the complete (NAME :k v ...).
         (ct-tail (nth-value 1 (%split-ct-props-args raw-args)))
         (args (values (%split-ct-props-args raw-args)))
         (result-type (if ct-tail (cons type-name ct-tail) type-name))
         (struct-def (lookup-struct-definition type-name)))
    (log:debug "analyze-struct-construction ~a: ct-tail ~s -> result type ~s" type-name ct-tail result-type)
    (unless struct-def
      (error 'crisp-unknown-type-error :type-name type-name :source-location location))

    ;; Validate argument count against original members (excluding compile-time properties)
    (let* ((all-members (crisp-struct-definition-members struct-def))
           (members (remove-if (lambda (m) (and (consp m) (eq (third m) :c-t))) all-members)))
      (unless (= (length args) (length members))
        (error "Struct constructor for ~a expects ~a arguments, got ~a."
          type-name (length members) (length args)))

      ;; Analyze arguments
      (let ((arg-nodes
             (loop for arg in args
                   for member in members
                   for i from 0
                   collect (let ((node (analyze-expression arg env context (append location (list (+ 2 i)))))
                                 (expected-type (second member)))
                             ;; get-single-value-type unwraps ((STORAGE GLOBAL)) -> (STORAGE GLOBAL)
                             ;; for function-call nodes whose semantic-call-type is a return-types list
                             (let ((arg-type (get-single-value-type node)))
                               (log:debug "STRUCT-CTOR ~a member ~a: arg-type=~a expected=~a"
                                          type-name (first member) arg-type expected-type)
                               ;; Type check with branded type promotion
                               (unless (type-equal-p arg-type expected-type)
                                 (let ((brand-def (is-brand-type-p expected-type)))
                                   (if brand-def
                                       ;; Branded member: check numeric compatibility with base type
                                       (let* ((base-type (brand-definition-base-type brand-def))
                                                 (arg-cat (numeric-type-category arg-type))
                                                 (base-cat (numeric-type-category base-type)))
                                         (if (and arg-cat base-cat)
                                             ;; Compatible numeric types - wrap in a value cast to the base type
                                             (progn
                                              (log:debug "Constructor promotion: ~a -> ~a (base ~a) for member ~a"
                                                         arg-type expected-type base-type (first member))
                                              (setf node (make-semantic-value-cast
                                                          :type base-type
                                                          :arg node
                                                          :source-location (append location (list (+ 2 i))))))
                                             ;; Not numeric-compatible
                                             (error 'crisp-type-error
                                               :expected expected-type
                                               :inferred arg-type
                                               :source-location location)))
                                       ;; Not a branded member -> real type error
                                       (error 'crisp-type-error
                                         :expected expected-type
                                         :inferred arg-type
                                         :source-location location))))
                               node)))))

        (make-semantic-struct-construction
         :type result-type
         :args arg-nodes
         :source-location location)))))

;; src/analysis/structs.lisp
(defun analyze-extract-struct-member-expression (expr env context location)
  "Analyzes a `%extract-struct-member` expression.
   Form: (%extract-struct-member object-node index-literal)"
  (let* ((obj-node (analyze-expression (second expr) env context (append location '(1))))
         (index (third expr)) ;; Expecting a raw integer literal from the macro expansion
         (obj-type (semantic-node-type obj-node)))

    ;; ADV-018: resolve a def-type alias / c-t-qualified type to the struct NAME first.
    (unless (symbolp (%member-access-struct-name obj-type))
      (error "Cannot extract member from non-struct type ~a" obj-type))

    ;; Lookup struct definition (handles derived types and package issues)
    (let* ((struct-def (lookup-struct-definition (%member-access-struct-name obj-type))))
      (unless struct-def
        (error "Unknown struct type ~a in extraction." obj-type))

      (let* ((padded-members (crisp-struct-definition-padded-members struct-def))
             ;; We need to map the "logical" index i to the "physical" index in the padded struct.
             ;; However, our macro passes the 'logical' index.
             ;; But wait, the macro loop `for i from 0` matches `parsed-members`.
             ;; `padded-members` has EXTRA fields. We need to find the Nth *non-padding* member.
             ;; Let's iterate padded-members to find the Nth logical member's actual index.
             (physical-index -1)
             (logical-count -1)
             (target-member-type nil))

        (loop for m in padded-members
              for idx from 0
              do (unless (alexandria:starts-with-subseq "_PAD" (symbol-name (first m)))
                   (incf logical-count)
                   (when (= logical-count index)
                         (setf physical-index idx)
                         (setf target-member-type (second m))
                         (cl:return))))

        (when (= physical-index -1)
              (error "Invalid member index ~a for struct ~a" index obj-type))

        (make-semantic-extract-value
         :type target-member-type
         :aggregate-node obj-node
         :index physical-index
         :source-location location)))))

;; src/analysis/structs.lisp
(defun analyze-insert-struct-member-expression (expr env context location)
  "Analyzes a `%insert-struct-member` expression.
   Form: (%insert-struct-member object-node index-literal value-node)"
  (let* ((obj-node (analyze-expression (second expr) env context (append location '(1))))
         (index (third expr)) ;; Expecting a raw integer literal from the macro expansion
         (value-node (analyze-expression (fourth expr) env context (append location '(3))))
         (obj-type (semantic-node-type obj-node)))

    ;; ADV-018: resolve a def-type alias / c-t-qualified type to the struct NAME first.
    ;; The node's own :type stays OBJ-TYPE (the qualified type is still the value's type).
    (unless (symbolp (%member-access-struct-name obj-type))
      (error "Cannot insert member into non-struct type ~a" obj-type))

    (let ((struct-def (lookup-struct-definition (%member-access-struct-name obj-type))))
      (unless struct-def
        (error "Unknown struct type ~a in insertion." obj-type))

      (let* ((padded-members (crisp-struct-definition-padded-members struct-def))
             (physical-index -1)
             (logical-count -1)
             (target-member-type nil))

        (loop for m in padded-members
              for idx from 0
              do (unless (alexandria:starts-with-subseq "_PAD" (symbol-name (first m)))
                   (incf logical-count)
                   (when (= logical-count index)
                         (setf physical-index idx)
                         (setf target-member-type (second m))
                         (cl:return))))

        (when (= physical-index -1)
              (error "Invalid member index ~a for struct ~a" index obj-type))

        ;; Type-check the value against the target member type
        (let ((value-type (semantic-node-type value-node)))
          (unless (types-compatible-p value-type target-member-type)
            (error 'crisp-type-error
              :expected target-member-type
              :inferred value-type
              :source-location location)))

        (make-semantic-insert-value
         :type obj-type
         :aggregate-node obj-node
         :index physical-index
         :value-node value-node
         :source-location location)))))

;; src/codegen.lisp
(defmethod generate-node-ir ((node semantic-struct-construction) builder module var-env di-builder di-scope location-map)
  ;; ADV-018: the node's type may be c-t-qualified, (NAME :k v ...); the LLVM layout is NAME's.
  (let* ((type-name (%member-access-struct-name (semantic-struct-construction-type node)))
         (struct-def (lookup-struct-definition type-name))
         (llvm-type (ensure-struct-llvm-type type-name))
         (agg-val (llvm-get-undef llvm-type))
         (args (semantic-struct-construction-args node))
         (original-members (crisp-struct-definition-members struct-def))
         (field-indices (crisp-struct-definition-field-indices struct-def)))

    (log:info "Struct Construction: ~a" type-name)
    (log:info "  LLVM Type: ~a" (llvm-print-type-to-string llvm-type))
    (log:info "  Agg Val Type: ~a" (llvm-print-type-to-string (llvm-type-of agg-val)))

    (loop for arg in args
          for member in original-members
          for i from 0
          for field-name = (first member)
          for field-idx = (gethash field-name field-indices)
          do (let ((val (generate-node-ir arg builder module var-env di-builder di-scope location-map)))
               (setf agg-val (llvm-build-insert-value builder agg-val val field-idx (format nil "insert_~a" field-name)))))

    ;; Phase 5: If the logical type is a Handle (ptr) (e.g. Cell), but we constructed an Aggregate,
    ;; we must return the Handle (pointer to the aggregate).
    (let ((logical-type (resolve-type-to-llvm type-name)))
      (if (and (llvm-type-kind-is-pointer? logical-type)
               (not (llvm-type-kind-is-pointer? llvm-type)))
          (let ((handle (llvm-build-alloca builder llvm-type "cell_handle")))
            (llvm-build-store builder agg-val handle)
            (values handle nil))
          (values agg-val nil)))))

;; src/macros.lisp
(defun %generate-struct-accessor (member-spec name pkg runtime-index)
  "Helper: Generates accessor (and setter) for a single struct member.
   Returns (values accessor-form new-runtime-index).
   Fix: typed-literal symbols in :c-t defaults are resolved to their numeric values."
  (let* ((member-name (first member-spec))
         (is-ct (and (consp member-spec) (eq (third member-spec) :c-t)))
         (raw-value (when is-ct (fourth member-spec)))
         ;; Resolve typed-literal symbols (e.g. 2.0F -> 2.0) for c-t defaults.
         (value (when is-ct (%parse-ct-literal raw-value)))
         (accessor-name (intern (format nil "~a~~" member-name) pkg)))
    (cond
     ;; Compile-time member with value -> constant accessor macro
     ((and is-ct value)
       (values `(defmacro ,accessor-name (obj)
                  (declare (ignore obj))
                  ',value)
         runtime-index))
     ;; Compile-time member without value -> skip (incomplete type)
     (is-ct
       (values nil runtime-index))
     ;; Runtime member -> function accessor
     (t
       (let* ((idx runtime-index)
              ;; ADV-018: when NAME has a c-t member with no default, the bare NAME is an
              ;; incomplete type, so this accessor becomes an implicit template -- and an
              ;; implicit template instantiates with an EMPTY return type unless one is declared
              ;; ("Expected (NIL) but inferred (INT)").  Declare the member's type in that case
              ;; only; every other struct keeps the accessor form it always had.
              (sd (lookup-struct-definition name))
              (incomplete-p (and sd (some (lambda (m) (and (consp m) (eq (third m) :c-t) (null (fourth m))))
                                          (crisp-struct-definition-members sd)))))
         (values (if incomplete-p
                     `(def-function ,accessor-name ((obj ,name))
                                    (declare (function ((,name) => ,(second member-spec))))
                                    (return (%extract-struct-member obj ,idx)))
                     `(def-function ,accessor-name ((obj ,name))
                                    (return (%extract-struct-member obj ,idx))))
           (1+ runtime-index)))))))

;; src/analysis/structs.lisp
(defun get-struct-member-index (struct-type-name member-name)
  "Helper to find the physical index of a struct member, accounting for padding.
   ADV-018: a def-type alias of a c-t-qualified struct, (def-type fast-cfg (my-cfg :exec :fast)),
   is resolved to the qualified type first, so set! through an accessor works on it."
  ;; ADV-018: resolve a def-type alias first (it may resolve to a symbol or a (NAME :k v) list).
  (when (and (symbolp struct-type-name)
             (not (lookup-struct-definition struct-type-name)))
    (let ((resolved (resolve-type-alias struct-type-name)))
      (unless (eq resolved struct-type-name)
        (log:debug "get-struct-member-index: alias ~a -> ~s" struct-type-name resolved)
        (setf struct-type-name resolved))))
  ;; Resolve derived types to their base type first
  (let ((original-type struct-type-name)
        (struct-type-name (if (symbolp struct-type-name)
                              (get-type-base struct-type-name)
                              struct-type-name)))
    (when (and (symbolp original-type) (not (eq original-type struct-type-name)))
      (log:debug "Resolved derived type ~a to base type ~a" original-type struct-type-name))
    (let ((search-key (if (and (consp struct-type-name) (valid-type-p struct-type-name))
                          (mangle-template-struct-name (first struct-type-name) (rest struct-type-name))
                          struct-type-name)))
    (log:info "Looking up struct member ~a in type ~a (key: ~a params?: ~a)" member-name struct-type-name search-key (valid-type-p struct-type-name))
    (let ((struct-def (or (find-struct-definition-by-name search-key)
                          ;; Fallback: If mangled name not found, try base type (for incomplete types with props)
                          (when (and (consp struct-type-name) (valid-type-p struct-type-name))
                                (find-struct-definition-by-name (first struct-type-name))))))
      ;; Robust Lookup: If not found by symbol, try by name (ignoring package)
      (unless struct-def
        (error "Unknown struct type '~a' during member lookup." struct-type-name))

      (let* ((indices (crisp-struct-definition-field-indices struct-def))
             (index (gethash member-name indices)))
        ;; Robust Member Lookup: If not found by symbol, try by name
        (unless index
          (maphash (lambda (k v)
                     (when (string-equal (symbol-name k) (symbol-name member-name))
                           (setf index v)))
                   indices))

        (unless index
          (error "Struct '~a' has no member named '~a'." struct-type-name member-name))
        index)))))

;;; =====================================================================================
;;; ADV-005 (adversarial): a keyword literal passed to a template function, e.g.
;;;   (test-enum-temp :forward) with (<T> (def-function test-enum-temp (val) #'(T => T) ...)),
;;; inferred T as the literal's singleton type (keyword :forward), which is not a type you can
;;; declare, so instantiation died with "Unknown type '(KEYWORD FORWARD)'".
;;; DECISION: when a template is instantiated from runtime argument types, a (keyword :k)
;;; argument stands for the def-enumeration that contains :k.  If no enumeration or more than
;;; one contains it, that is a clear compile error rather than a guess.
;;; Only the instantiation path changes: direct overload resolution still sees (keyword :k), so
;;; dispatch on keyword-literal types is untouched.
;;; =====================================================================================

(defun %enumerations-containing-keyword (kw)
  "Returns the names of every registered def-enumeration whose members include KW."
  (let ((names '()))
    (maphash (lambda (name def)
               (when (assoc kw (enumeration-def-members def))
                 (push name names)))
             *crisp-enums*)
    (sort names #'string< :key #'symbol-name)))

(defun %keyword-literal-type->enum (type)
  "Maps a keyword literal's singleton type (keyword :k) to the enumeration that contains :k
   (ADV-005).  Any other TYPE is returned unchanged.  Signals a crisp-compiler-error when :k
   belongs to no enumeration, or to several -- the template parameter cannot be inferred."
  (if (and (consp type) (eq (first type) 'keyword) (= (length type) 2) (keywordp (second type)))
      (let* ((kw (second type))
             (enums (%enumerations-containing-keyword kw)))
        (log:debug "%keyword-literal-type->enum ~s -> candidates ~s" kw enums)
        (cond
          ((= (length enums) 1) (first enums))
          ((null enums)
           (error 'crisp-compiler-error
                  :message (format nil "Cannot infer a template type from the keyword ~s: it is not a value of any def-enumeration" kw)))
          (t
           (error 'crisp-compiler-error
                  :message (format nil "Cannot infer a template type from the keyword ~s: it is a value of several enumerations (~{~(~a~)~^, ~}). Pass it through a parameter declared with the enumeration you mean"
                                   kw enums)))))
      type))

;; src/templates.lisp -- fold by mapping EXPLICIT-ARG-TYPES at the top of
;; ensure-template-instantiation:  (setf explicit-arg-types (mapcar #'%keyword-literal-type->enum explicit-arg-types))
(defvar *adv005-original-ensure-template-instantiation* (fdefinition 'ensure-template-instantiation)
  "The src/ ensure-template-instantiation, wrapped by the ADV-005 overlay below.")

(defun ensure-template-instantiation (name explicit-arg-types compiler-callback)
  "ADV-005 wrapper: maps keyword-literal argument types to their enumeration, then runs the
   original instantiation.  See %keyword-literal-type->enum."
  (let ((mapped (mapcar #'%keyword-literal-type->enum explicit-arg-types)))
    (unless (equal mapped explicit-arg-types)
      (log:debug "ensure-template-instantiation ~a: keyword args ~s -> ~s" name explicit-arg-types mapped))
    (funcall *adv005-original-ensure-template-instantiation* name mapped compiler-callback)))

;;; =====================================================================================
;;; ADV-019 (adversarial): two gen-XXXX instantiations given the SAME explicit kernel name,
;;;   (gen-my_call_function long  "my_colliding_kernel")
;;;   (gen-my_call_function float "my_colliding_kernel")
;;; compiled without complaint; codegen's "Redefining function ... (replacing existing
;;; definition)" path then silently kept only the LAST one.
;;; DECISION: an explicit instantiation name may be reused only by the SAME instantiation
;;; (same template, same substitutions -- macroexpansion legitimately repeats); a different
;;; instantiation under a name already taken is a compile error.  The registry is cleared by
;;; initialize-templates, i.e. once per compilation.
;;; =====================================================================================

(defvar *explicit-instantiation-names* (make-hash-table :test 'equal)
  "Explicit override name (string) -> (template-name . substitutions) of the instantiation that
   claimed it in this compilation.  ADV-019.")

;; src/templates.lisp -- fold the check into %instantiate-callable-template, the clrhash into
;; initialize-templates.
(defvar *adv019-original-instantiate-callable-template* (fdefinition '%instantiate-callable-template)
  "The src/ %instantiate-callable-template, wrapped by the ADV-019 overlay below.")

(defun %instantiate-callable-template (name body substitutions override-name)
  "ADV-019 wrapper: refuses a second, different instantiation under an explicit name already
   claimed in this compilation, then runs the original."
  (when override-name
    (let* ((key (string override-name))
           (this (cons name substitutions))
           (prior (gethash key *explicit-instantiation-names*)))
      (log:debug "%instantiate-callable-template: ~a as ~s (prior ~s)" name key prior)
      (cond
        ((null prior) (setf (gethash key *explicit-instantiation-names*) this))
        ((equal prior this) nil)
        (t (error 'crisp-compiler-error
                  :message (format nil "Kernel name ~s is already used by another instantiation of ~(~a~) (~{~(~a~)~^ ~}); this one (~{~(~a~)~^ ~}) would silently replace it. Give each instantiation its own name"
                                   key (car prior)
                                   (mapcar #'cdr (cdr prior))
                                   (mapcar #'cdr substitutions)))))))
  (funcall *adv019-original-instantiate-callable-template* name body substitutions override-name))

(defvar *adv019-original-initialize-templates* (fdefinition 'initialize-templates)
  "The src/ initialize-templates, wrapped by the ADV-019 overlay below.")

(defun initialize-templates ()
  "ADV-019 wrapper: also clears *explicit-instantiation-names*, then runs the original."
  (clrhash *explicit-instantiation-names*)
  (funcall *adv019-original-initialize-templates*))

;;; =====================================================================================
;;; ADV-014 / ADV-020 (adversarial): a kernel parameter that is a storage handle OF an
;;; incomplete struct -- (cell my-cfg :address-space :global) where my-cfg has a :c-t member
;;; with no default -- was accepted, though chapter 21 rule 2 says kernel parameters MUST be
;;; complete.  The cell itself was complete, so the existing check never looked inside it.
;;; The layout is well defined (c-t members are not stored), but the kernel is left
;;; polymorphic in the struct's c-t properties, which the boundary forbids.
;;; Fix: def-kernel parameters and marshall-cell / marshall-tensor targets reject a storage
;;; handle whose element type is an incomplete struct or record.
;;; =====================================================================================

(defun %storage-handle-incomplete-element (type-spec)
  "If TYPE-SPEC (after alias resolution; an (&out T) wrapper is looked through) is a storage
   handle -- cell / vector / matrix / tensor -- whose element type is an incomplete struct or
   record, returns that element type; otherwise NIL.  ADV-014 / ADV-020."
  (let* ((unwrapped (if (and (consp type-spec) (symbolp (car type-spec))
                             (string-equal (symbol-name (car type-spec)) "&OUT"))
                        (second type-spec)
                        type-spec))
         (resolved (if (symbolp unwrapped) (resolve-type-alias unwrapped) unwrapped)))
    (when (and (consp resolved) (symbolp (car resolved))
               (member (symbol-name (car resolved)) '("CELL" "VECTOR" "MATRIX" "TENSOR") :test #'string-equal))
      (let* ((element (second resolved))
             (element-resolved (if (symbolp element) (resolve-type-alias element) element))
             (struct-name (cond ((symbolp element-resolved) element-resolved)
                                ((and (consp element-resolved) (symbolp (car element-resolved)))
                                 (car element-resolved)))))
        (when (and struct-name
                   (lookup-struct-definition struct-name)
                   (incomplete-type-p element-resolved))
          (log:debug "%storage-handle-incomplete-element ~s -> ~s" type-spec element-resolved)
          element-resolved)))))

;; src/macros.lisp -- fold into %validate-kernel-parameters (after the storage-handle check).
(defvar *adv014-original-validate-kernel-parameters* (fdefinition '%validate-kernel-parameters)
  "The src/ %validate-kernel-parameters, wrapped by the ADV-014 overlay below.")

(defun %validate-kernel-parameters (params type-map name)
  "ADV-014 wrapper: refuses a kernel parameter that is a storage handle of an incomplete
   struct/record, then runs the original validation."
  (dolist (p params)
    (let* ((t-spec (and (symbolp p) (gethash p type-map)))
           (element (and t-spec (%storage-handle-incomplete-element t-spec))))
      (when element
        (error "def-kernel ~(~a~) parameter '~(~a~)' has type ~(~a~), whose element type ~(~a~) is incomplete: kernel parameters must be complete, so give every :c-t property of the element a value (e.g. (cell (my-struct :prop :value) ...))."
               name p t-spec element))))
  (funcall *adv014-original-validate-kernel-parameters* params type-map name))

;; src/macros.lisp -- fold into the marshall-cell / marshall-tensor macros.
(defun %adv020-wrap-marshall-macro (macro-name)
  "Wraps MACRO-NAME's expander so a TYPE-ALIAS argument naming a storage handle of an
   incomplete struct is refused before expansion (ADV-020)."
  (let ((original (macro-function macro-name)))
    (when original
      (setf (macro-function macro-name)
            (lambda (form env)
              (let* ((type-arg (second form))
                     (element (and type-arg (%storage-handle-incomplete-element type-arg))))
                (when element
                  (error "~(~a~): ~(~a~) is a storage handle of the incomplete type ~(~a~); a kernel boundary needs a complete type, so give every :c-t property of the element a value."
                         macro-name type-arg element)))
              (funcall original form env))))))

(%adv020-wrap-marshall-macro 'marshall-cell)
(%adv020-wrap-marshall-macro 'marshall-tensor)

;;; =====================================================================================
;;; ADV-007 (adversarial), AD half: a sub-function RETURNING AN ENUM got a _GRAD companion
;;; whose return-adjoint slot was typed as the enum -- (FLOAT MY-MODE => FLOAT) -- while the
;;; caller passes a float adjoint: "No matching function overload found for 'GET-MODE_GRAD'
;;; with argument types (FLOAT FLOAT)".  An int return already promoted to a float slot; an
;;; enum is an i32 in exactly the same way, so it promotes the same way.
;;; =====================================================================================

(defun %ad-enum-type-p (type-spec)
  "T if TYPE-SPEC (after alias resolution) names a def-enumeration, or is a keyword
   literal's singleton type (keyword :k).  ADV-007."
  (let ((resolved (if (symbolp type-spec) (resolve-type-alias type-spec) type-spec)))
    (or (and (symbolp resolved) (gethash resolved *crisp-enums*) t)
        (and (consp resolved) (eq (first resolved) 'keyword)))))

;; src/autodiff.lisp
(defun %promote-to-float-adjoint (type-spec)
  "Generalised float-adjoint type promotion for AD output gradient slots.
   - integer scalar      → float / double scalar
   - enum scalar         → float (an enum is an i32; ADV-007)
   - integer tensor      → float / double tensor (element-type promoted)
   - integer cell        → cell of float / double
   - everything else     → unchanged (already float, or non-numeric)
   Used to produce caller-supplied _GRAD seed types and input _GRAD output
   types that mirror the input shape with float adjoint values."
  (cond
   ((%crisp-integer-tensor-type-p type-spec) (%integer-tensor-elem-to-float type-spec))
   ((%crisp-integer-cell-type-p type-spec) (%integer-cell-elem-to-float type-spec))
   ((%crisp-integer-scalar-type-p type-spec) (%integer-scalar-to-float-scalar type-spec))
   ((%ad-enum-type-p type-spec) 'float)
   (t type-spec)))

;;; =====================================================================================
;;; ADV-007 (adversarial), forward half: (eq mode :mul) died with "Unsupported form 'EQ'
;;; found in function body."  Crisp compares enum values (and numbers) with =, which already
;;; lowers an enum compare to icmp on its i32.  DECISION: no EQ alias -- Crisp keeps one
;;; equality -- but the unsupported-form error now names the Crisp spelling for the Common
;;; Lisp forms an author (or an agent) is most likely to reach for.  The original sentence
;;; is unchanged and comes first, so existing CHECK-FAIL matches still hold.
;;; =====================================================================================

(defparameter *unsupported-form-hints*
  '(("EQ" . "compare values, including enum keywords, with =")
    ("EQL" . "compare values, including enum keywords, with =")
    ("EQUAL" . "compare values, including enum keywords, with =")
    ("EQUALP" . "compare values, including enum keywords, with =")
    ("SETF" . "assign with set!, e.g. (set! x v) or (set! (~ v i) x)")
    ("SETQ" . "assign with set!")
    ("AREF" . "index a storage handle with ~, e.g. (~ v i)")
    ("DEFUN" . "define functions at top level with def-function")
    ("LET*" . "Crisp's let is already sequential; use let")
    ("PROGN" . "a function or let body is already a sequence of forms")
    ("INCF" . "write (set! x (+ x 1))")
    ("DECF" . "write (set! x (- x 1))")
    ("DOLIST" . "loop with dotimes or one of the stride macros")
    ("LOOP" . "loop with dotimes or one of the stride macros"))
  "Common Lisp operator name -> what to write in Crisp instead.  Appended to the
   unsupported-form error (ADV-007).")

(defun %unsupported-form-hint (form)
  "The Crisp alternative for FORM's operator name, or NIL."
  (let ((name (cond ((symbolp form) (symbol-name form))
                    ((and (consp form) (symbolp (car form))) (symbol-name (car form))))))
    (and name (cdr (assoc name *unsupported-form-hints* :test #'string-equal)))))

;; src/errors.lisp
(define-condition crisp-unsupported-form-error (crisp-compiler-error)
    ((form :initarg :form :reader unsupported-form))
  (:report (lambda (condition stream)
             (format stream "Unsupported form '~a' found in function body."
               (unsupported-form condition))
             (let ((hint (%unsupported-form-hint (unsupported-form condition))))
               (when hint (format stream "  Crisp has no ~a: ~a." (unsupported-form condition) hint))))))

;;; ADV-007 (adversarial), IF half: (if c :mul :add) failed "Branch type mismatch in IF
;;; expression. Then: (KEYWORD MUL), Else: (KEYWORD ADD)" -- each keyword literal has its own
;;; singleton type.  Two enum values unify to their enumeration: keyword/keyword when exactly
;;; one enumeration holds both, keyword/enum when the enum holds the keyword.  Ambiguous or
;;; foreign keywords still reach the original mismatch error.

(defun %enum-type-for-branch (type)
  "The set of enumerations a branch of TYPE could belong to: for (keyword :k) every enum
   holding :k; for an enumeration name, just that name; otherwise NIL."
  (let ((resolved (if (symbolp type) (resolve-type-alias type) type)))
    (cond
      ((and (consp resolved) (eq (first resolved) 'keyword) (keywordp (second resolved)))
       (%enumerations-containing-keyword (second resolved)))
      ((and (symbolp resolved) (gethash resolved *crisp-enums*))
       (list resolved)))))

;; src/analysis/control.lisp -- fold as a clause of ensure-branch-compatibility's cond,
;; ahead of the final mismatch error.
(defvar *adv007-original-ensure-branch-compatibility* (fdefinition 'ensure-branch-compatibility)
  "The src/ ensure-branch-compatibility, wrapped by the ADV-007 overlay below.")

(defun ensure-branch-compatibility (then-node else-node location)
  "Unifies types of then/else branches. Returns (values unified-type new-then new-else).
   ADV-007 wrapper: two enum-valued branches unify to their single common enumeration;
   everything else goes to the original."
  (when else-node
    (let* ((t-single (get-single-value-type then-node))
           (e-single (get-single-value-type else-node)))
      (unless (equal t-single e-single)
        (let* ((t-enums (%enum-type-for-branch t-single))
               (e-enums (%enum-type-for-branch e-single))
               (common (and t-enums e-enums (intersection t-enums e-enums))))
          (when (= (length common) 1)
            (log:debug "ensure-branch-compatibility: ~s / ~s unify to enum ~s" t-single e-single (first common))
            (return-from ensure-branch-compatibility
              (values (first common) then-node else-node)))))))
  (funcall *adv007-original-ensure-branch-compatibility* then-node else-node location))

;;; ADV-015 (adversarial): (cell (cell float :address-space :global) :address-space :global)
;;; as a kernel parameter crashed deep in codegen ("Missing value for :ADDRESS-SPACE in (CELL
;;; FLOAT ADDRESS-SPACE)").  DECISION: a storage handle whose element is itself a storage handle
;;; is not supported -- the host would have to marshal device pointers INTO device memory, which
;;; nothing in the design defines -- so it is refused at the kernel boundary with a clear error.

(defun %adv015-storage-handle-spec-p (type-spec)
  "T if TYPE-SPEC (after alias resolution) is a cell / vector / matrix / tensor spec."
  (let ((resolved (if (symbolp type-spec) (resolve-type-alias type-spec) type-spec)))
    (and (consp resolved) (symbolp (car resolved))
         (member (symbol-name (car resolved)) '("CELL" "VECTOR" "MATRIX" "TENSOR") :test #'string-equal)
         t)))

(defun %storage-handle-nested-element (type-spec)
  "If TYPE-SPEC is a storage handle whose element type is itself a storage handle, returns
   that element type; otherwise NIL.  ADV-015."
  (let* ((unwrapped (if (and (consp type-spec) (symbolp (car type-spec))
                             (string-equal (symbol-name (car type-spec)) "&OUT"))
                        (second type-spec)
                        type-spec))
         (resolved (if (symbolp unwrapped) (resolve-type-alias unwrapped) unwrapped)))
    (when (%adv015-storage-handle-spec-p resolved)
      (let ((element (second resolved)))
        (when (%adv015-storage-handle-spec-p element) element)))))

(defvar *adv015-previous-validate-kernel-parameters* (fdefinition '%validate-kernel-parameters)
  "The %validate-kernel-parameters in force before the ADV-015 overlay (the ADV-014 wrapper).")

(defun %validate-kernel-parameters (params type-map name)
  "ADV-015 wrapper: refuses a kernel parameter that is a storage handle of a storage handle,
   then runs the ADV-014 wrapper (and through it the original)."
  (dolist (p params)
    (let* ((t-spec (and (symbolp p) (gethash p type-map)))
           (element (and t-spec (%storage-handle-nested-element t-spec))))
      (when element
        (error "def-kernel ~(~a~) parameter '~(~a~)' has type ~(~a~), a storage handle whose element ~(~a~) is itself a storage handle; storage handles cannot be nested.  Pass the inner handle as its own kernel parameter."
               name p t-spec element))))
  (funcall *adv015-previous-validate-kernel-parameters* params type-map name))

;;; =====================================================================================
;;; ADV-006 (adversarial): (c-t-output "msg" val) inside a template function crashed the
;;; compiler with "The variable VAL is unbound." -- c-t-output EVALs each argument at
;;; macro-expansion time, and val is a runtime parameter.  Chapter 41 says an argument that is
;;; "not evaluable at compile time ... will merely be noted", so it now prints a note in that
;;; argument's place and compilation continues.
;;; NOTE: a MACRO, redefined here because it is only ever expanded in user code (at Crisp
;;; compile time); fold it into src/macros.lisp by hand.
;;; =====================================================================================

;; src/macros.lisp
(defmacro c-t-output (&rest args)
  "Compile-Time Output. Evaluates arguments at macro-expansion time and prints them.
   An argument that cannot be evaluated at compile time (e.g. a runtime variable) is
   noted in place, per chapter 41, instead of aborting compilation (ADV-006)."
  (let ((output-string
         (with-output-to-string (s)
           (dolist (arg args)
             (let ((val (handler-case (eval arg)
                          (error (e)
                            (log:debug "c-t-output: ~s is not compile-time evaluable: ~a" arg e)
                            (format nil "<~(~a~) is not known at compile time>" arg)))))
               (format s "~a " val))))))
    (format *standard-output* "~&~a~%" output-string)
    ;; Return a no-op form for the compiler to process (and ignore)
    `(compiler-no-op)))

;;; ADV-018 follow-on: once make-XXXX types its value as (NAME :k v ...), that value must still
;;; reach a parameter declared with the BARE NAME when NAME has unspecified (no-default) c-t
;;; members -- the bare NAME means "any NAME", and c-t members are not stored, so the layout is
;;; the same.  Implicit templates already cover the usual case; this covers the bare names that
;;; are NOT made implicit templates (mangled template instances such as FAKE-CELL_FLOAT,
;;; 037/07).  A parameter that is itself qualified -- (my-cfg :exec :slow), or an alias of one --
;;; still has to match exactly.

(defun %struct-has-required-ct-member-p (struct-name)
  "T if STRUCT-NAME's struct/record definition has a :c-t member with no default."
  (let ((sd (lookup-struct-definition struct-name)))
    (and sd (some (lambda (m) (and (consp m) (eq (third m) :c-t) (null (fourth m))))
                  (crisp-struct-definition-members sd))
         t)))

(defun %ct-qualified-arg-fits-bare-param-p (arg-type param-type)
  "T when ARG-TYPE is a c-t-qualified struct type (NAME :k v ...) and PARAM-TYPE resolves to
   the bare NAME of a struct with unspecified c-t members."
  (and (consp arg-type) (symbolp (car arg-type)) (symbolp param-type)
       (let ((presolved (resolve-type-alias param-type)))
         (and (symbolp presolved)
              (string= (symbol-name presolved) (symbol-name (car arg-type)))
              (%struct-has-required-ct-member-p presolved)))))

;; src/type-checker.lisp -- fold as one more OR clause of types-compatible-p.
(defvar *adv018-original-types-compatible-p* (fdefinition 'types-compatible-p)
  "The src/ types-compatible-p, wrapped by the ADV-018 follow-on overlay below.")

(defun types-compatible-p (arg-type param-type)
  "Checks if an argument type is compatible with a parameter type.
   ADV-018 wrapper: also accepts a c-t-qualified struct value for a bare, polymorphic
   struct parameter (see %ct-qualified-arg-fits-bare-param-p)."
  (or (funcall *adv018-original-types-compatible-p* arg-type param-type)
      (let ((fits (%ct-qualified-arg-fits-bare-param-p arg-type param-type)))
        (when fits (log:debug "COMPAT-CHECK: c-t-qualified ~s fits bare ~s" arg-type param-type))
        fits)))

;;; ADV-007 (adversarial), AD body half: a value-if whose branches are enum KEYWORDS,
;;; (if (> val 0.0) :mul :add), sent each keyword down the symbol-copy rule, minting the
;;; adjoint :MUL_ADJ (in the KEYWORD package) and "(+ :MUL_ADJ ...)" -- "Type mismatch for
;;; operator +".  A keyword is a literal: it takes the no-gradient path like a number.

;; src/autodiff.lisp
(defun %backward-value-expr (v expr adjoint-map emit-fn local-adj-fn
                             &key hof-handler-fn (error-on-unknown t)
                                  tensor-inputs-ht scratch-tile-syms)
  "Backward-AD for a VALUE expression EXPR whose result is bound to V (so V's
   adjoint is the incoming seed). Endeavor 124 A1: handles the symbol-copy and
   literal cases plus compound value exprs (if / let), recursing; leaf exprs
   (math, ~, calls, accessors) delegate to %handle-single-value-backward."
  (cond
   ;; copy: v <- s  =>  s_adj += v_adj  (skip self-copy).  ADV-007: not a keyword (an enum
   ;; literal) -- that is a constant, handled by the literal clause below.
   ((and (symbolp expr) (not (keywordp expr)))
     (unless (eq expr v)
       (funcall emit-fn `(set! ,(funcall local-adj-fn expr)
                               (+ ,(funcall local-adj-fn expr) ,(funcall local-adj-fn v))))))
   ;; literal (number / non-symbol atom): no gradient
   ((not (consp expr)) nil)
   ((%value-if-p expr)
     (%handle-value-if-backward v expr adjoint-map emit-fn local-adj-fn
                                :hof-handler-fn hof-handler-fn :error-on-unknown error-on-unknown
                                :tensor-inputs-ht tensor-inputs-ht :scratch-tile-syms scratch-tile-syms))
   ((%value-let-p expr)
     (%handle-value-let-backward v expr adjoint-map emit-fn local-adj-fn
                                 :hof-handler-fn hof-handler-fn :error-on-unknown error-on-unknown
                                 :tensor-inputs-ht tensor-inputs-ht :scratch-tile-syms scratch-tile-syms))
   (t
     (%handle-single-value-backward v expr adjoint-map emit-fn local-adj-fn
                                    :hof-handler-fn hof-handler-fn :error-on-unknown error-on-unknown
                                    :tensor-inputs-ht tensor-inputs-ht :scratch-tile-syms scratch-tile-syms))))

;;; =====================================================================================
;;; ADV-001 / ADV-002 / ADV-024 (adversarial): SILENTLY WRONG GRADIENTS when a let rebinds a
;;; name already in scope inside a differentiated body:
;;;   (let ((x (~ input))) ... (let ((x (+ x 1.5))) ...))     AD 6.0, finite difference 4.0
;;;   (let ((x ..)) (if c (let ((x (* x 2.0))) (+ x 1.0)) x))   AD 0.0, finite difference 4.0
;;; %anf-normalize-let FLATTENS nested lets into one binding list, so the inner x becomes a
;;; second binding of the SAME symbol, and the AD walk -- which keys adjoints by name (X_ADJ) --
;;; merges the two variables' adjoints.
;;; Fix: before ANF, alpha-rename every let (and counted-loop) binding that would collide:
;;;   - its name is already bound by an enclosing let / loop in this form, or
;;;   - its own initial value refers to that name (this catches shadowing a PARAMETER, which
;;;     anf-transform cannot see, e.g. (let ((x (* x 2.0))) ...) with x a parameter).
;;; The new name is NAME%SHn.  Renaming is semantics-preserving, so the forward pass is
;;; unaffected; only the AD pipeline consumes anf-transform's output.
;;; =====================================================================================

(defvar *ad-shadow-rename-counter* 0
  "Counter for the NAME%SHn symbols minted by %alpha-rename-shadowed-lets (ADV-001).")

(defun %fresh-shadow-name (sym)
  "A fresh symbol NAME%SHn in SYM's package, for a renamed shadowing binding."
  (intern (format nil "~a%SH~d" (symbol-name sym) (incf *ad-shadow-rename-counter*))
          (or (symbol-package sym) *package*)))

(defun %renamable-var-p (sym)
  "T for a symbol that names a lexical variable: not a keyword, not NIL / T."
  (and (symbolp sym) sym (not (eq sym t)) (not (keywordp sym))))

(defun %alpha-rename-shadowed-lets (form &optional env bound)
  "Returns FORM with shadowing let / counted-loop bindings alpha-renamed (ADV-001).
   ENV is an alist old-symbol -> new-symbol for renamings in scope; BOUND lists the names bound
   by enclosing lets / loops of this form.  Operator positions are never renamed."
  (labels ((ren (f env bound) (%alpha-rename-shadowed-lets f env bound))
           (ren-args (args env bound) (mapcar (lambda (a) (ren a env bound)) args))
           (bind-var (var init env bound)
             ;; Returns (values new-var env bound) for one binder.
             (if (and (%renamable-var-p var)
                      ;; src/analysis/control.lisp's helper; argument order is (form sym)
                      (or (member var bound) (%form-mentions-symbol-p init var)))
                 (let ((new (%fresh-shadow-name var)))
                   (log:debug "alpha-rename: shadowing binding ~a -> ~a" var new)
                   (values new (acons var new env) (cons new bound)))
                 (values var
                         (if (assoc var env) (acons var var env) env) ; un-shadow an outer renaming
                         (cons var bound)))))
    (cond
      ((symbolp form) (let ((hit (assoc form env))) (if hit (cdr hit) form)))
      ((atom form) form)
      ((and (symbolp (car form)) (member (symbol-name (car form)) '("QUOTE" "FUNCTION") :test #'string=))
       form)
      ;; (let (BIND...) BODY...)  -- sequential; BIND is (var val), (v1 v2 ... val) or ((v1 v2) val)
      ((and (symbolp (car form)) (string-equal (symbol-name (car form)) "LET") (listp (second form)))
       (let ((new-binds '()))
         (dolist (b (second form))
           (if (and (consp b) (cdr b))
               (let* ((listy (listp (car b)))
                      (vars (if listy (car b) (butlast b)))
                      (init (if listy (second b) (car (last b))))
                      (new-init (ren init env bound))
                      (new-vars '()))
                 (dolist (v vars)
                   (multiple-value-bind (nv nenv nbound) (bind-var v init env bound)
                     (push nv new-vars) (setf env nenv bound nbound)))
                 (setf new-vars (nreverse new-vars))
                 (push (if listy (list new-vars new-init) (append new-vars (list new-init))) new-binds))
               (push b new-binds)))
         `(,(car form) ,(nreverse new-binds) ,@(ren-args (cddr form) env bound))))
      ;; counted loops: (HEAD (VAR OPERAND...) BODY...)
      ((and (%dotimes-family-head-p (car form)) (consp (second form)) (symbolp (car (second form))))
       (let* ((var (car (second form)))
              (operands (ren-args (cdr (second form)) env bound)))
         (multiple-value-bind (nv nenv nbound) (bind-var var nil env bound)
           `(,(car form) (,nv ,@operands) ,@(ren-args (cddr form) nenv nbound)))))
      ;; anything else: keep the operator, rename inside the arguments
      ((symbolp (car form)) `(,(car form) ,@(ren-args (cdr form) env bound)))
      (t (ren-args form env bound)))))

;; src/anf-transform.lisp -- fold by calling %alpha-rename-shadowed-lets at the top of anf-transform.
(defvar *adv001-original-anf-transform* (fdefinition 'anf-transform)
  "The src/ anf-transform, wrapped by the ADV-001 overlay below.")

(defun anf-transform (expr)
  "Transforms a Crisp expression into A-Normal Form.
   ADV-001 wrapper: first alpha-renames let bindings that shadow a name in scope, because ANF
   flattens nested lets and the AD walk keys adjoints by name."
  (funcall *adv001-original-anf-transform* (%alpha-rename-shadowed-lets expr)))

;;; ADV-018 follow-on (2): the same rule for RETURN values and other assignments, which are
;;; checked with types-assignable-p, not types-compatible-p.  009/errors/make-XXXX-incomplete-struct
;;; and 010/errors/make-XXXX-incomplete return (point :k-mode 20) from a function declared
;;; => point (bare, polymorphic); that must still be accepted, so the spec reaches the error it
;;; is about (the second constructor omits :k-mode).

;; src/types/hierarchy.lisp -- fold as one more OR clause of types-assignable-p.
(defvar *adv018-original-types-assignable-p* (fdefinition 'types-assignable-p)
  "The src/ types-assignable-p, wrapped by the ADV-018 follow-on overlay below.")

(defun types-assignable-p (from-type to-type)
  "ADV-018 wrapper: also accepts a c-t-qualified struct value where the bare, polymorphic
   struct NAME is expected (see %ct-qualified-arg-fits-bare-param-p)."
  (or (funcall *adv018-original-types-assignable-p* from-type to-type)
      (%ct-qualified-arg-fits-bare-param-p from-type to-type)))
