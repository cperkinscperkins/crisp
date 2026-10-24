;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;;
;;;; INSTRUCTIONS:
;;;; 1. APPEND new/fixed function definitions to the end of this file.
;;;; 2. Add a comment naming the original file (e.g. ;; src/compiler.lisp).
;;;; 3. Do not modify the original file in src/ until cleanup time.
;;;;
;;;; EMPTY as of 2026-10-22 -- endeavour 190 (compile API) folded into src/:
;;;;   * BUG 066 on PTX  -> ensure-opencl-kernel-metadata calls %173-ensure-grad-dispatch-decls on every backend (src/codegen.lisp)
;;;;   * BUG 133         -> %physical-array-split (new), %enumerate-physical-types (src/metadata-val.lisp);
;;;;                        get-physical-width, generate-physical-signature (src/metadata.lisp)
;;;;   (spec-runner-overlay.lisp -> tests/run-specs.lisp the same day: --hoist-kernel=source)
;;;; Before that, EMPTY as of 2026-10-13 -- the "/=" entry in *unsupported-form-hints* folded into src/errors.lisp.
;;;; Before that, 2026-10-12 (later) -- endeavour 185 (math-ops) folded into src/:
;;;;   * overrides          -> analyze-let-expression (src/analysis/control.lisp); register-ops-analyzers,
;;;;                           analyze-mod-expression, analyze-rem-expression (src/analysis/ops.lisp);
;;;;                           %handle-single-value-backward (src/autodiff.lisp); semantic-div written out
;;;;                           in place of its def-binary-op-codegen line (src/codegen.lisp)
;;;;   * analyzers          -> the %185-* / analyze-185-* block before register-ops-analyzers (src/analysis/ops.lisp)
;;;;   * lowering           -> the %185-* block + %hw-lower methods after %hw-sat-interior (src/codegen.lisp)
;;;;   * AD                 -> %185-math-backward (src/autodiff.lisp)
;;;;   * bindings           -> select xor srem urem ashr not enum-attribute frem (src/llvm-bindings.lisp)
;;;; EMPTY as of 2026-10-12 -- adversarial sweep (tests/adversarial/issues.md, Resolved) folded:
;;;;   * c-t struct values (ADV-018) -> validate-and-reorder-struct-args, %split-ct-props-args,
;;;;                                  %member-access-struct-name (src/structs.lisp); analyze-struct-construction,
;;;;                                  analyze-extract/insert-struct-member-expression, get-struct-member-index
;;;;                                  (src/analysis/structs.lisp); generate-node-ir semantic-struct-construction
;;;;                                  (src/codegen.lisp); %generate-struct-accessor (src/macros.lisp);
;;;;                                  types-compatible-p (src/type-checker.lisp); types-assignable-p +
;;;;                                  %ct-qualified-arg-fits-bare-param-p (src/types/hierarchy.lisp)
;;;;   * enums (ADV-005/007)       -> ensure-template-instantiation, %keyword-literal-type->enum (src/templates.lisp);
;;;;                                  ensure-branch-compatibility, %enum-type-for-branch (src/analysis/control.lisp);
;;;;                                  %promote-to-float-adjoint, %ad-enum-type-p, %backward-value-expr (src/autodiff.lisp);
;;;;                                  crisp-unsupported-form-error + *unsupported-form-hints* (src/errors.lisp)
;;;;   * kernel boundary (014/015/019/020) -> %validate-kernel-parameters, marshall-cell/-tensor + helpers
;;;;                                  (src/macros.lisp); %instantiate-callable-template, initialize-templates,
;;;;                                  *explicit-instantiation-names* (src/templates.lisp)
;;;;   * c-t-output (ADV-006)      -> src/macros.lisp
;;;;   * shadowed lets in AD (ADV-001/002) -> anf-transform + %alpha-rename-shadowed-lets (src/anf-transform.lisp)
;;;; Before that, 2026-10-10 -- endeavour 183 (last-man fence; BUG 082) folded: %warp-spec-check-sync
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

;; src/mma.lisp  (beside the other SPIR-V spec validators, %spv-disasm / %spv-tokens)
(defun %spv-cache-control-census (spv-path)
  "Endeavour 192.  Read SPV-PATH (llvm-spirv --to-text) and return, as a plist:
     :load-deco  hash id -> list of (level control) from `Decorate ID CacheControlLoadINTEL L C`
     :store-deco hash id -> list of (level control) from `Decorate ID CacheControlStoreINTEL L C`
     :load-ptrs  pointer ids of every OpLoad   (`N Load TYPE RESULT PTR ...`)
     :store-ptrs pointer ids of every OpStore  (`N Store PTR VALUE ...`)
   or NIL when llvm-spirv is unavailable."
  (let ((txt (%spv-disasm spv-path)))
    (when txt
      (let ((ld (make-hash-table :test 'equal)) (st (make-hash-table :test 'equal))
            (load-ptrs '()) (store-ptrs '()))
        (with-input-from-string (s txt)
          (loop for line = (read-line s nil) while line
                do (let ((toks (%spv-tokens line)))
                     (cond ((and (>= (length toks) 6) (string= (second toks) "Decorate")
                                 (member (fourth toks) '("CacheControlLoadINTEL" "6442") :test #'string=))
                            (push (list (fifth toks) (sixth toks)) (gethash (third toks) ld)))
                           ((and (>= (length toks) 6) (string= (second toks) "Decorate")
                                 (member (fourth toks) '("CacheControlStoreINTEL" "6443") :test #'string=))
                            (push (list (fifth toks) (sixth toks)) (gethash (third toks) st)))
                           ((and (>= (length toks) 5) (string= (second toks) "Load"))
                            (push (fifth toks) load-ptrs))
                           ((and (>= (length toks) 4) (string= (second toks) "Store"))
                            (push (third toks) store-ptrs))))))
        (log:debug "192: ~a: ~d load-decorated id(s), ~d store-decorated id(s), ~d load(s), ~d store(s)"
                   spv-path (hash-table-count ld) (hash-table-count st) (length load-ptrs) (length store-ptrs))
        (list :load-deco ld :store-deco st :load-ptrs load-ptrs :store-ptrs store-ptrs)))))

(defun %spv-cache-fail (fmt &rest args)
  "Endeavour 192.  Print a FAIL line (the SPIR-V validators report on stdout, like 180's) and return NIL."
  (format t "FAIL: ~?~%" fmt args)
  nil)

(defun %spv-deco-is (deco level control)
  "Endeavour 192.  T when the decoration list DECO contains (LEVEL CONTROL)."
  (member (list (princ-to-string level) (princ-to-string control)) deco :test #'equal))

(defun validate-spv-cache-streaming-loads (spv-path)
  "Endeavour 192 / spec 11: A is :streaming, B is not.  Some load goes through a CacheControlLoadINTEL
   pointer; every such pointer is L1 Streaming + L3 Streaming (0 2 / 1 2); no pointer is
   store-decorated."
  (let ((c (%spv-cache-control-census spv-path)))
    (if (null c)
        (progn (format t "  (llvm-spirv unavailable -- cache-control check skipped)~%") t)
        (let* ((ld (getf c :load-deco)) (st (getf c :store-deco))
               (hinted (remove-if-not (lambda (p) (gethash p ld)) (getf c :load-ptrs)))
               (plain (remove-if (lambda (p) (gethash p ld)) (getf c :load-ptrs))))
          (cond ((null hinted) (%spv-cache-fail "no load through a CacheControlLoadINTEL pointer"))
                ((null plain) (%spv-cache-fail "every load is decorated; B is not :streaming"))
                ((notevery (lambda (p) (and (%spv-deco-is (gethash p ld) 0 2) (%spv-deco-is (gethash p ld) 1 2)))
                           hinted)
                 (%spv-cache-fail "a decorated load is not L1 Streaming + L3 Streaming (0 2 / 1 2)"))
                ((plusp (hash-table-count st)) (%spv-cache-fail "a store is decorated (only A, an input, is :streaming)"))
                (t t))))))

(defun validate-spv-cache-streaming-stores (spv-path)
  "Endeavour 192 / spec 12: C is :streaming.  Some store goes through a CacheControlStoreINTEL pointer;
   every such pointer is L1 Streaming + L3 Streaming (0 3 / 1 3); no pointer is load-decorated."
  (let ((c (%spv-cache-control-census spv-path)))
    (if (null c)
        (progn (format t "  (llvm-spirv unavailable -- cache-control check skipped)~%") t)
        (let* ((ld (getf c :load-deco)) (st (getf c :store-deco))
               (hinted (remove-if-not (lambda (p) (gethash p st)) (getf c :store-ptrs))))
          (cond ((null hinted) (%spv-cache-fail "no store through a CacheControlStoreINTEL pointer"))
                ((notevery (lambda (p) (and (%spv-deco-is (gethash p st) 0 3) (%spv-deco-is (gethash p st) 1 3)))
                           hinted)
                 (%spv-cache-fail "a decorated store is not L1 Streaming + L3 Streaming (0 3 / 1 3)"))
                ((plusp (hash-table-count ld)) (%spv-cache-fail "a load is decorated (only C, the output, is :streaming)"))
                (t t))))))

;;;; ======================================================================
;;;; Endeavour 192 -- cache hints.  `:cache INTENT` / `:cache (INTENT :prefetch N)` on a
;;;; storage-handle type.  See tests/spec/192-cache-hints/cache-hints.md.
;;;;
;;;; Shape:
;;;;   1. The type expanders validate and STRIP :cache (it is never part of the canonical type,
;;;;      so it is not part of type identity -- like C's restrict).  def-type keeps the RAW spec in
;;;;      *crisp-type-aliases*, which is where %cache-hint-of-type reads it back.
;;;;   2. Codegen records, per entry point, PHYSICAL-PARAM-INDEX -> hint (+ read-only-ness) in
;;;;      *kernel-cache-hint-table* (ensure-opencl-kernel-metadata wrapper below).
;;;;   3. After -O3 (which drops metadata and splits lane-accessed vector loads -- BUG 134), a text
;;;;      pass over the optimized .ll walks every addrspace(1) load/store pointer back to its kernel
;;;;      argument and lowers the hint: PTX -> inline-asm ld/st with qualifiers (plus
;;;;      !invariant.load for read-only arguments); SPIR-V -> CacheControl{Load,Store}INTEL
;;;;      !spirv.Decorations on a fresh zero-offset GEP.
;;;; ======================================================================

;; src/types/validation.lisp
(defparameter +cache-intents+ '(:default :streaming :reused :no-l1)
  "Endeavour 192: the intents a storage-handle type may declare with :cache.")

;; src/types/validation.lisp
(defun %cache-intent-keyword (x)
  "Endeavour 192.  X as one of +CACHE-INTENTS+ (compared by name, so the reader package does not
   matter), or NIL."
  (and x (symbolp x)
       (find (symbol-name x) +cache-intents+ :key #'symbol-name :test #'string-equal)))

;; src/types/validation.lisp
(defun %parse-cache-hint (value spec)
  "Endeavour 192.  Validate the value of a :cache option in SPEC and return the normalized hint
   (INTENT PREFETCH): INTENT one of +CACHE-INTENTS+, PREFETCH 64 / 128 / 256 or NIL.
   Accepts a bare intent (:streaming) or a list (:streaming :prefetch 256).  Refuses anything
   else with a message naming the legal values."
  (cond
    ((consp value)
     (let ((intent (%cache-intent-keyword (first value)))
           (prefetch nil))
       (unless intent
         (error ":cache list must start with an intent (:default :streaming :reused :no-l1); got ~s in ~s"
                value spec))
       (unless (evenp (length (rest value)))
         (error ":cache list is (INTENT :prefetch N); got ~s in ~s" value spec))
       (loop for (k v) on (rest value) by #'cddr
             do (cond ((and k (symbolp k) (string-equal (symbol-name k) "PREFETCH"))
                       (unless (member v '(64 128 256))
                         (error ":prefetch must be 64, 128 or 256 (the L2 prefetch size in bytes); got ~s in ~s"
                                v spec))
                       (setf prefetch v))
                      (t (error ":cache list takes only :prefetch after the intent; got ~s in ~s" k spec))))
       (list intent prefetch)))
    (t
     (let ((intent (%cache-intent-keyword value)))
       (unless intent
         (error ":cache must be one of :default :streaming :reused :no-l1, or (INTENT :prefetch N); got ~s in ~s"
                value spec))
       (list intent nil)))))

;; src/types/validation.lisp
(defun %check-cache-hint-address-space (hint addr spec)
  "Endeavour 192.  Refuse a :cache HINT on a storage handle whose address space ADDR is not
   :global.  :local (shared memory) gets its own message: L1/L2 hints mean nothing there, and a
   silently dropped hint would be worse than a refusal.  ADDR NIL (incomplete type) is let through."
  (when hint
    (cond ((eq addr :local)
           (error ":cache does not apply to :local memory -- L1/L2 cache hints are for :global storage; in ~s"
                  spec))
          ((and addr (not (eq addr :global)))
           (error ":cache applies only to :address-space :global; got ~s in ~s" addr spec)))))

;; src/types/validation.lisp
(defun %cache-hint-of-type (type-spec)
  "Endeavour 192.  The normalized (INTENT PREFETCH) :cache hint carried by a DECLARED type, or NIL.
   TYPE-SPEC is what a kernel signature declares: an alias symbol, followed through
   *CRISP-TYPE-ALIASES* (whose values are the RAW specs, :cache included), or a raw storage-handle
   list.  (:default NIL) -- no intent, no prefetch -- normalizes to NIL, i.e. exactly 'no key'."
  (let ((spec type-spec))
    (loop repeat 32
          while (and spec (symbolp spec))
          do (let ((next (gethash spec *crisp-type-aliases*)))
               (if next (setf spec next) (return))))
    (when (consp spec)
      (let ((tail (member-if (lambda (x) (and x (symbolp x) (string-equal (symbol-name x) "CACHE")))
                             spec)))
        (when (and tail (rest tail))
          (let ((hint (%parse-cache-hint (second tail) spec)))
            (unless (and (eq (first hint) :default) (null (second hint)))
              hint)))))))

;; src/codegen.lisp
(defvar *kernel-cache-hint-table* (make-hash-table :test 'equal)
  "Endeavour 192.  LLVM entry-point name (string) -> list of
   (PHYSICAL-PARAM-INDEX INTENT PREFETCH READONLY-P), one entry per storage-handle POINTER
   parameter that carries a :cache hint and/or is read-only (read-only-ness lets the post-opt pass
   re-apply !invariant.load, which -O3 drops on lane-accessed vector loads -- BUG 134).
   Written by ensure-opencl-kernel-metadata for every entry point (an empty list overwrites a
   stale entry); read by %apply-cache-hints-to-ll.")

;; src/codegen.lisp
(defun %kernel-llvm-name (semantic-function)
  "Endeavour 192.  The LLVM function name generate-function-prototype gives an ENTRY POINT."
  (substitute #\_ #\~ (substitute #\_ #\- (string-downcase
                                            (symbol-name (semantic-function-name semantic-function))))))

;; src/codegen.lisp
(defun %compute-kernel-cache-hints (semantic-function)
  "Endeavour 192.  The *KERNEL-CACHE-HINT-TABLE* entries for SEMANTIC-FUNCTION (an entry point).

   Physical parameters are the flattened handle fields (INPUT_PTR INPUT_BYTE_SIZE ...); the
   POINTER field <NAME>_PTR is matched to the declared parameter NAME in
   *KERNEL-DECLARED-SIGNATURES*, whose types are the declared (alias or raw) specs.  Implicit
   scratch parameters have no declared entry and are skipped.

   Adjoints inherit nothing: in a *_GRAD kernel a parameter P_GRAD whose P is also declared is a
   gradient (shadow) buffer -- its access pattern is not the forward pass's, so it gets no hint
   even though it is declared with the same alias type (decision 2026-10-23)."
  (let* ((fn-name  (semantic-function-name semantic-function))
         (declared (remove-if (lambda (p) (string= (symbol-name (car p)) "&OUT"))
                              (gethash fn-name *kernel-declared-signatures*)))
         (names    (mapcar (lambda (p) (symbol-name (car p))) declared))
         (grad-p   (alexandria:ends-with-subseq "_GRAD" (symbol-name fn-name)))
         (readonly (ignore-errors (%collect-readonly-tensor-param-syms semantic-function)))
         (entries  '()))
    (loop for node in (semantic-function-param-list semantic-function)
          for i from 0
          do (let ((pname (symbol-name (semantic-param-name node))))
               (when (alexandria:ends-with-subseq "_PTR" pname)
                 (let* ((logical (subseq pname 0 (- (length pname) 4)))
                        (decl    (find logical declared :key (lambda (p) (symbol-name (car p)))
                                                        :test #'string=)))
                   (when decl
                     (let* ((adjoint-p (and grad-p
                                            (alexandria:ends-with-subseq "_GRAD" logical)
                                            (member (subseq logical 0 (- (length logical) 5)) names
                                                    :test #'string=)))
                            (hint (unless adjoint-p (%cache-hint-of-type (cdr decl))))
                            (ro   (and (hash-table-p readonly) (gethash (car decl) readonly) t)))
                       (when adjoint-p
                         (log:debug "192: ~a: ~a is an adjoint -- no cache hint" fn-name logical))
                       (when (or hint ro)
                         (push (list i (first hint) (second hint) ro) entries))))))))
    (nreverse entries)))

;; src/codegen.lisp  -- FOLD: add the table write at the end of ensure-opencl-kernel-metadata
(defvar *%192-orig-ensure-opencl-kernel-metadata* (fdefinition 'ensure-opencl-kernel-metadata)
  "Endeavour 192.  The pre-192 ensure-opencl-kernel-metadata, wrapped below.")

;; src/codegen.lisp
(defun ensure-opencl-kernel-metadata (func semantic-function module)
  "Marks a function as a SPIR-V/PTX kernel if it's an entry point (see the wrapped original for
   the full contract).  Endeavour 192: also records the entry point's cache-hint table
   (*KERNEL-CACHE-HINT-TABLE*) for the post-opt pass."
  (prog1 (funcall *%192-orig-ensure-opencl-kernel-metadata* func semantic-function module)
    (when (semantic-function-is-entry-point semantic-function)
      (let ((entries (%compute-kernel-cache-hints semantic-function))
            (name (%kernel-llvm-name semantic-function)))
        (setf (gethash name *kernel-cache-hint-table*) entries)
        (when entries
          (log:info "192: ~a cache-hint table (index intent prefetch readonly): ~s" name entries))))))

;;; ---------------------------------------------------------------- post-opt pass

;; src/compiler.lisp
(defparameter +ll-ssa-name-re+ "%[-a-zA-Z$._0-9]+"
  "Endeavour 192.  An unquoted LLVM SSA name (named or numbered).")

;; src/compiler.lisp
(defun %ll-split-top-level-commas (s)
  "Endeavour 192.  Split S on commas outside () [] {} <> -- LLVM 21 parameter attributes such as
   captures(ret: address, provenance) contain commas."
  (let ((out '()) (depth 0) (start 0))
    (loop for i from 0 below (length s)
          for c = (char s i)
          do (case c
               ((#\( #\[ #\{ #\<) (incf depth))
               ((#\) #\] #\} #\>) (decf depth))
               (#\, (when (zerop depth)
                      (push (subseq s start i) out)
                      (setf start (1+ i))))))
    (push (subseq s start) out)
    (mapcar (lambda (x) (string-trim " " x)) (nreverse out))))

;; src/compiler.lisp
(defun %ll-define-info (line)
  "Endeavour 192.  For a `define ... @NAME(PARAMS) ...` line return (values NAME PARAMS), PARAMS a
   list of (SSA-NAME . POINTER-ADDRSPACE1-P) in order; NIL for any other line."
  (when (alexandria:starts-with-subseq "define " line)
    (let ((at (search " @" line)))
      (when at
        (let* ((open (position #\( line :start at))
               (name (and open (string-trim "\"" (subseq line (+ at 2) open)))))
          (when open
            (let ((depth 0) (close nil))
              (loop for i from open below (length line)
                    for c = (char line i)
                    do (case c
                         (#\( (incf depth))
                         (#\) (decf depth) (when (zerop depth) (setf close i) (return)))))
              (when close
                (values name
                        (loop for chunk in (%ll-split-top-level-commas (subseq line (1+ open) close))
                              for ssa = (car (last (cl-ppcre:all-matches-as-strings +ll-ssa-name-re+ chunk)))
                              collect (cons ssa (alexandria:starts-with-subseq "ptr addrspace(1)" chunk))))))))))))

;; src/compiler.lisp
(defun %ll-pointer-roots (name defs params memo)
  "Endeavour 192.  The set (list) of addrspace(1) POINTER-parameter indices that the SSA value NAME
   is derived from, walking getelementptr / bitcast / addrspacecast / phi / select.  DEFS: SSA name
   -> right-hand side text.  PARAMS: SSA name -> (index . pointer-p).  MEMO guards cycles (a phi
   reached again contributes nothing)."
  (multiple-value-bind (cached found) (gethash name memo)
    (when found (return-from %ll-pointer-roots cached)))
  (setf (gethash name memo) nil)
  (let* ((param (gethash name params))
         (rhs (gethash name defs))
         (roots
           (cond
             (param (when (cdr param) (list (car param))))
             ((null rhs) nil)
             ((or (alexandria:starts-with-subseq "getelementptr" rhs)
                  (alexandria:starts-with-subseq "bitcast" rhs)
                  (alexandria:starts-with-subseq "addrspacecast" rhs))
              (let ((base (cl-ppcre:scan-to-strings
                           "ptr(?: addrspace\\(\\d+\\))? (%[-a-zA-Z$._0-9]+)" rhs)))
                (when base
                  (%ll-pointer-roots (subseq base (position #\% base)) defs params memo))))
             ((or (alexandria:starts-with-subseq "phi ptr" rhs)
                  (alexandria:starts-with-subseq "select" rhs))
              (let ((ops (if (alexandria:starts-with-subseq "phi" rhs)
                             (mapcar (lambda (m) (string-trim "[ " (subseq m 0 (position #\, m))))
                                     (cl-ppcre:all-matches-as-strings "\\[ *[^,\\]]+," rhs))
                             (mapcar (lambda (m) (subseq m (position #\% m)))
                                     (cl-ppcre:all-matches-as-strings
                                      "ptr(?: addrspace\\(\\d+\\))? %[-a-zA-Z$._0-9]+" rhs)))))
                (remove-duplicates
                 (loop for op in ops
                       when (char= (char op 0) #\%)
                         append (%ll-pointer-roots op defs params memo)))))
             (t nil))))
    (setf (gethash name memo) roots)
    roots))

;; src/compiler.lisp
(defun %ptx-elem-asm (elem)
  "Endeavour 192.  (values PTX-SUFFIX ASM-CONSTRAINT) for an LLVM scalar type the hinted ld/st
   handles, or NIL (that access is left unhinted)."
  (cond ((string= elem "float")  (values "f32" "f"))
        ((string= elem "double") (values "f64" "d"))
        ((string= elem "i32")    (values "b32" "r"))
        ((string= elem "i64")    (values "b64" "l"))
        (t nil)))

;; src/compiler.lisp
(defun %ll-type-shape (type)
  "Endeavour 192.  For an LLVM type string return (values LANES ELEM): LANES 1 for a scalar,
   2 or 4 for <N x ELEM>; NIL for anything else."
  (let ((m (nth-value 1 (cl-ppcre:scan-to-strings "^<(\\d+) x ([a-z0-9]+)>$" type))))
    (cond (m (let ((n (parse-integer (aref m 0))))
               (when (member n '(2 4)) (values n (aref m 1)))))
          ((cl-ppcre:scan "^[a-z0-9]+$" type) (values 1 type))
          (t nil))))

;; src/compiler.lisp
(defun %ptx-cache-op (kind intent prefetch readonly lanes suffix)
  "Endeavour 192.  The PTX opcode for a hinted access.  KIND :load / :store.  Qualifier order
   follows the PTX grammar: cache operator, .nc, L1 / L2 eviction priority, prefetch size, vector,
   type.  :streaming -> L1::no_allocate.L2::evict_first; :reused -> L2::evict_last; :no-l1 -> .cg;
   PREFETCH (loads only) -> L2::NB; READONLY (loads only) -> .nc."
  (let ((parts (list (if (eq kind :load) "ld" "st") "global")))
    (flet ((add (x) (setf parts (append parts (list x)))))
      (when (eq intent :no-l1) (add "cg"))
      (when (and readonly (eq kind :load)) (add "nc"))
      (case intent
        (:streaming (add "L1::no_allocate") (add "L2::evict_first"))
        (:reused    (add "L2::evict_last")))
      (when (and prefetch (eq kind :load)) (add (format nil "L2::~dB" prefetch)))
      (when (> lanes 1) (add (format nil "v~d" lanes)))
      (add suffix))
    (format nil "~{~a~^.~}" parts)))

;; src/compiler.lisp
(defun %ll-align-of (tail)
  "Endeavour 192.  The `align N` value in an instruction TAIL, or NIL."
  (let ((m (nth-value 1 (cl-ppcre:scan-to-strings "align (\\d+)" tail))))
    (when m (parse-integer (aref m 0)))))

;; src/compiler.lisp
(defun %ptx-hinted-load-lines (result type ptr intent prefetch readonly tail counter)
  "Endeavour 192.  Replacement lines for `RESULT = load TYPE, ptr addrspace(1) PTR TAIL`, or NIL
   when the access cannot be hinted (unsupported type, or a vector load not naturally aligned --
   a .v4 ld needs 16-byte alignment, and LLVM marks a weaker one by splitting it).  COUNTER makes
   the helper names unique within the file."
  (multiple-value-bind (lanes elem) (%ll-type-shape type)
    (when lanes
      (multiple-value-bind (sfx con) (%ptx-elem-asm elem)
        (when sfx
          (let* ((elem-bytes (if (member elem '("double" "i64") :test #'string=) 8 4))
                 (align (or (%ll-align-of tail) 0)))
            (when (or (= lanes 1) (>= align (* lanes elem-bytes)))
              (let ((op (%ptx-cache-op :load intent prefetch readonly lanes sfx)))
                (if (= lanes 1)
                    (list (format nil "  ~a = call ~a asm sideeffect \"~a $0, [$1];\", \"=~a,l,~~{memory}\"(ptr addrspace(1) ~a)"
                                  result type op con ptr))
                    (let* ((base (format nil "%cr.l~d" counter))
                           (struct (format nil "{ ~{~a~^, ~} }" (make-list lanes :initial-element elem)))
                           (outs (format nil "{~{$~d~^, ~}}" (loop for i below lanes collect i)))
                           (cons-str (format nil "~{=~a,~}l,~~{memory}" (make-list lanes :initial-element con)))
                           (lines (list (format nil "  ~a = call ~a asm sideeffect \"~a ~a, [$~d];\", \"~a\"(ptr addrspace(1) ~a)"
                                                base struct op outs lanes cons-str ptr))))
                      (dotimes (i lanes)
                        (push (format nil "  ~a.e~d = extractvalue ~a ~a, ~d" base i struct base i) lines))
                      (dotimes (i lanes)
                        (push (format nil "  ~a = insertelement ~a ~a, ~a ~a.e~d, i32 ~d"
                                      (if (= i (1- lanes)) result (format nil "~a.v~d" base i))
                                      type (if (zerop i) "poison" (format nil "~a.v~d" base (1- i)))
                                      elem base i i)
                              lines))
                      (nreverse lines)))))))))))

;; src/compiler.lisp
(defun %ptx-hinted-store-lines (type value ptr intent tail counter)
  "Endeavour 192.  Replacement lines for `store TYPE VALUE, ptr addrspace(1) PTR TAIL`, or NIL when
   the access cannot be hinted (see %ptx-hinted-load-lines)."
  (multiple-value-bind (lanes elem) (%ll-type-shape type)
    (when lanes
      (multiple-value-bind (sfx con) (%ptx-elem-asm elem)
        (when sfx
          (let* ((elem-bytes (if (member elem '("double" "i64") :test #'string=) 8 4))
                 (align (or (%ll-align-of tail) 0)))
            (when (or (= lanes 1) (>= align (* lanes elem-bytes)))
              (let ((op (%ptx-cache-op :store intent nil nil lanes sfx)))
                (if (= lanes 1)
                    (list (format nil "  call void asm sideeffect \"~a [$0], $1;\", \"l,~a,~~{memory}\"(ptr addrspace(1) ~a, ~a ~a)"
                                  op con ptr type value))
                    (let ((base (format nil "%cr.s~d" counter))
                          (lines '()))
                      (dotimes (i lanes)
                        (push (format nil "  ~a.e~d = extractelement ~a ~a, i32 ~d" base i type value i) lines))
                      (push (format nil "  call void asm sideeffect \"~a [$0], {~{$~d~^, ~}};\", \"l,~{~a~^,~},~~{memory}\"(ptr addrspace(1) ~a~{, ~a~})"
                                    op (loop for i from 1 to lanes collect i)
                                    (make-list lanes :initial-element con) ptr
                                    (loop for i below lanes collect (format nil "~a ~a.e~d" elem base i)))
                            lines)
                      (nreverse lines)))))))))))

;; src/compiler.lisp
(defun %spv-cache-controls (kind intent)
  "Endeavour 192.  ((LEVEL . CONTROL) ...) for a SPIR-V CacheControl{Load,Store}INTEL decoration,
   level 0 = L1, 1 = L3.  Load controls: Uncached 0, Cached 1, Streaming 2.  Store controls:
   Uncached 0, WriteThrough 1, WriteBack 2, Streaming 3.  NIL for :default (no decoration)."
  (if (eq kind :load)
      (case intent
        (:streaming '((0 . 2) (1 . 2)))
        (:reused    '((0 . 1) (1 . 1)))
        (:no-l1     '((0 . 0) (1 . 1))))
      (case intent
        (:streaming '((0 . 3) (1 . 3)))
        (:reused    '((0 . 2) (1 . 2)))
        (:no-l1     '((0 . 0) (1 . 2))))))

;; src/compiler.lisp
(defun %ll-max-metadata-id (lines)
  "Endeavour 192.  The largest N of a `!N = ` definition in LINES (0 when none)."
  (let ((mx 0))
    (loop for l across lines
          do (cl-ppcre:register-groups-bind ((#'parse-integer n)) ("^!(\\d+) = " l)
               (when (> n mx) (setf mx n))))
    mx))

;; src/compiler.lisp
(defun %ll-kernels-with-cache-entries (lines)
  "Endeavour 192.  T when some `define` in LINES names an entry point with a non-empty
   *KERNEL-CACHE-HINT-TABLE* entry -- so the pass (and the extra vectorizer run) costs nothing for
   kernels that carry no hint and no read-only argument."
  (loop for l across lines
        thereis (let ((name (%ll-define-info l)))
                  (and name (gethash name *kernel-cache-hint-table*)))))

;; src/compiler.lisp
(defun %ll-read-lines (path)
  "Endeavour 192.  The lines of the text file PATH, as a vector."
  (with-open-file (in path :direction :input)
    (coerce (loop for l = (read-line in nil nil) while l collect l) 'vector)))

;; src/compiler.lisp
(defun %apply-cache-hints-to-ll (ll-path backend)
  "Endeavour 192.  Lower :cache hints in the POST-OPT LLVM IR at LL-PATH, in place, for BACKEND
   (:ptx or :spirv).  Returns the number of accesses rewritten.

   Every addrspace(1) load / store inside an entry point listed in *KERNEL-CACHE-HINT-TABLE* has its
   pointer walked back to a kernel argument (%ll-pointer-roots); the argument's entry decides:
     PTX   -- a :cache hint (intent or prefetch) replaces the access with an `asm sideeffect` ld/st
              carrying the qualifiers (memory-clobbered for ordering; ptxas still schedules it as
              an ordinary load).  A read-only argument without a hint gets !invariant.load back,
              which -O3 drops when it narrows a lane-accessed vector load (BUG 134).  The
              load/store vectorizer is run FIRST, so hinted accesses are already vector-width.
     SPIRV -- a :cache intent decorates a fresh zero-offset GEP of the pointer with
              CacheControl{Load,Store}INTEL !spirv.Decorations (llvm-spirv keeps them; -O3 would not
              have).  Prefetch size and read-only-ness have no SPIR-V mapping here.
   Accesses whose pointer has no single root, and types the asm path does not handle, are left as
   they are (a hint is never required for correctness)."
  (unless (and ll-path (probe-file ll-path))
    (return-from %apply-cache-hints-to-ll 0))
  (let ((lines (%ll-read-lines ll-path)))
    (unless (%ll-kernels-with-cache-entries lines)
      (return-from %apply-cache-hints-to-ll 0))
    (when (eq backend :ptx)
      ;; Vector width first: once an access is inline asm, llc's own vectorizer can no longer merge it.
      (let ((vec (make-pathname :type "lsv.ll" :defaults ll-path)))
        (if (%run-passes-in-process ll-path vec "function(load-store-vectorizer)")
            (progn (setf lines (%ll-read-lines vec)) (ignore-errors (delete-file vec)))
            (log:warn "192: load-store-vectorizer failed on ~a; hinting the unvectorized IR" ll-path))))
    (let* ((out '()) (rewritten 0) (counter 0)
           (next-md (1+ (%ll-max-metadata-id lines)))
           (invariant-md nil)
           (deco-mds (make-hash-table :test 'equal))   ; (kind . intent) -> metadata id
           (extra-md '())
           (i 0) (n (length lines)))
      (labels ((emit (l) (push l out))
               (md-id () (prog1 next-md (incf next-md)))
               (deco-md (kind intent)
                 (or (gethash (cons kind intent) deco-mds)
                     (let* ((outer (md-id))
                            (pairs (%spv-cache-controls kind intent))
                            (inner (loop repeat (length pairs) collect (md-id))))
                       (push (format nil "!~d = !{~{!~d~^, ~}}" outer inner) extra-md)
                       (loop for p in pairs for id in inner
                             do (push (format nil "!~d = !{i32 ~d, i32 ~d, i32 ~d}"
                                              id (if (eq kind :load) 6442 6443) (car p) (cdr p))
                                      extra-md))
                       (setf (gethash (cons kind intent) deco-mds) outer)))))
        (loop while (< i n)
              do (let ((line (aref lines i)))
                   (multiple-value-bind (fname fparams) (%ll-define-info line)
                     (let ((entries (and fname (gethash fname *kernel-cache-hint-table*))))
                       (if (null entries)
                           (progn (emit line) (incf i))
                           ;; ---- an entry point with hints: collect its body, then rewrite.
                           (let ((body '()) (defs (make-hash-table :test 'equal))
                                 (params (make-hash-table :test 'equal)) (memo (make-hash-table :test 'equal)))
                             (emit line) (incf i)
                             (loop for (ssa . ptr-p) in fparams for k from 0
                                   when ssa do (setf (gethash ssa params) (cons k ptr-p)))
                             (loop while (and (< i n) (not (string= (aref lines i) "}")))
                                   do (let ((b (aref lines i)))
                                        (cl-ppcre:register-groups-bind (lhs rhs)
                                            ("^\\s*(%[-a-zA-Z$._0-9]+) = (.*)$" b)
                                          (setf (gethash lhs defs) rhs))
                                        (push b body) (incf i)))
                             (dolist (b (nreverse body))
                               (let ((done nil))
                                 ;; LOAD:  %r = load T, ptr addrspace(1) %p, tail
                                 (cl-ppcre:register-groups-bind (result type ptr tail)
                                     ("^\\s*(%[-a-zA-Z$._0-9]+) = load ([^,]+), ptr addrspace\\(1\\) (%[-a-zA-Z$._0-9]+)(.*)$" b)
                                   (unless (or (search "atomic" type) (search "volatile" type))
                                     (let* ((roots (%ll-pointer-roots ptr defs params memo))
                                            (e (and (= (length roots) 1) (assoc (first roots) entries))))
                                       (when e
                                         (destructuring-bind (idx intent prefetch ro) e
                                           (declare (ignore idx))
                                           (cond
                                             ((and (eq backend :ptx) (or intent prefetch))
                                              (let ((new (%ptx-hinted-load-lines result type ptr intent prefetch ro
                                                                                 tail (incf counter))))
                                                (cond (new (mapc #'emit new) (incf rewritten) (setf done t))
                                                      (t (log:debug "192: unhinted (type/alignment): ~a" b)))))
                                             ((and (eq backend :spirv) intent (%spv-cache-controls :load intent))
                                              (let ((g (format nil "%cr.d~d" (incf counter))))
                                                (emit (format nil "  ~a = getelementptr inbounds i8, ptr addrspace(1) ~a, i64 0, !spirv.Decorations !~d"
                                                              g ptr (deco-md :load intent)))
                                                (emit (format nil "  ~a = load ~a, ptr addrspace(1) ~a~a" result type g tail))
                                                (incf rewritten) (setf done t))))
                                           ;; read-only, PTX, not turned into asm: put !invariant.load back
                                           (when (and (not done) ro (eq backend :ptx)
                                                      (not (search "!invariant.load" tail)))
                                             (unless invariant-md
                                               (setf invariant-md (md-id))
                                               (push (format nil "!~d = !{}" invariant-md) extra-md))
                                             (emit (format nil "  ~a = load ~a, ptr addrspace(1) ~a~a, !invariant.load !~d"
                                                           result type ptr tail invariant-md))
                                             (incf rewritten) (setf done t)))))))
                                 ;; STORE: store T VALUE, ptr addrspace(1) %p, tail
                                 (unless done
                                   (cl-ppcre:register-groups-bind (tv ptr tail)
                                       ("^\\s*store (.+), ptr addrspace\\(1\\) (%[-a-zA-Z$._0-9]+)(.*)$" b)
                                     (unless (or (search "atomic" tv) (search "volatile" tv))
                                       (let* ((type (if (char= (char tv 0) #\<)
                                                        (subseq tv 0 (1+ (position #\> tv)))
                                                        (subseq tv 0 (position #\Space tv))))
                                              (value (string-trim " " (subseq tv (length type))))
                                              (roots (%ll-pointer-roots ptr defs params memo))
                                              (e (and (= (length roots) 1) (assoc (first roots) entries)))
                                              (intent (second e)))
                                         (when intent
                                           (cond
                                             ((eq backend :ptx)
                                              (let ((new (%ptx-hinted-store-lines type value ptr intent tail (incf counter))))
                                                (cond (new (mapc #'emit new) (incf rewritten) (setf done t))
                                                      (t (log:debug "192: unhinted store (type/alignment): ~a" b)))))
                                             ((%spv-cache-controls :store intent)
                                              (let ((g (format nil "%cr.d~d" (incf counter))))
                                                (emit (format nil "  ~a = getelementptr inbounds i8, ptr addrspace(1) ~a, i64 0, !spirv.Decorations !~d"
                                                              g ptr (deco-md :store intent)))
                                                (emit (format nil "  store ~a, ptr addrspace(1) ~a~a" tv g tail))
                                                (incf rewritten) (setf done t)))))))))
                                 (unless done (emit b)))))))))))
      (with-open-file (o ll-path :direction :output :if-exists :supersede)
        (dolist (l (nreverse out)) (write-line l o))
        (dolist (l (nreverse extra-md)) (write-line l o)))
      (log:info "192: ~d access(es) rewritten for ~a in ~a" rewritten backend (file-namestring ll-path))
      rewritten)))

;; src/compiler.lisp
(defun %ll-uses-cache-control-decorations-p (ll-path)
  "Endeavour 192.  T when the .ll text at LL-PATH carries a CacheControl{Load,Store}INTEL
   !spirv.Decorations node (6442 / 6443), so llvm-spirv must be given SPV_INTEL_cache_controls."
  (when (and ll-path (probe-file ll-path))
    (with-open-file (s ll-path :direction :input :if-does-not-exist nil)
      (when s
        (loop for line = (read-line s nil nil)
              while line
              thereis (or (search "!{i32 6442," line) (search "!{i32 6443," line)))))))

;;;; ======================================================================
;;;; Endeavour 192 -- type expanders: accept, validate and STRIP :cache.  FOLD: each is the src
;;;; definition plus a CACHE clause and a %check-cache-hint-address-space call.
;;;; ======================================================================

;; src/types/validation.lisp
(defun %expand-vector-type-specifier (element-type rest-args spec)
  (let* ((addr      nil)   ;; no default: must be supplied
         (aln       nil)   ;; no default: must be supplied
         (ct        :last) ;; the only auto-default
         (cache-hint nil)   ;; endeavour 192: validated and stripped, never canonical
         (remaining rest-args))
    (when (and remaining (not (keywordp (first remaining))))
      (error "Invalid type option ~s in vector spec ~s. Vector takes no arity argument; use (tensor ~s N) for N > 2."
             (first remaining) spec element-type))
    (loop while remaining do
      (let ((item (pop remaining)))
        (cond
          ((string-equal (string item) "ADDRESS-SPACE")
           (unless remaining (error "Missing value for :ADDRESS-SPACE in ~s" spec))
           (setf addr (intern (string-upcase (string (pop remaining))) :keyword)))
          ((string-equal (string item) "ACCESS")
           ;; :access has been removed; skip the value but signal a warning
           (unless remaining (error "Missing value for :ACCESS in ~s" spec))
           (pop remaining)
           (log:warn "EXPAND-STORAGE-HANDLE: :access is no longer supported in ~s; ignoring." spec))
          ((string-equal (string item) "ALIGN")
           (unless remaining (error "Missing value for :ALIGN in ~s" spec))
           (let ((v (intern (string-upcase (string (pop remaining))) :keyword)))
             (unless (member v '(:compact :compact-offset :strided))
               (error "Invalid :align value ~s in ~s. Expected :compact, :compact-offset, or :strided." v spec))
             (setf aln v)))
          ((string-equal (string item) "CONTIGUOUS-TERM")
           (unless remaining (error "Missing value for :CONTIGUOUS-TERM in ~s" spec))
           (let ((v (intern (string-upcase (string (pop remaining))) :keyword)))
             (cond
               ((member v '(:last :first)) (setf ct v))
               ((member v '(:row-major :col-major))
                (error "Invalid :contiguous-term value ~s in ~s. :row-major and :col-major are only valid for 2D matrix types." v spec))
               (t (error "Invalid :contiguous-term value ~s in ~s. Expected :last or :first." v spec)))))
          ((string-equal (string item) "CACHE")
           (unless remaining (error "Missing value for :CACHE in ~s" spec))
           (setf cache-hint (%parse-cache-hint (pop remaining) spec)))
          ((string-equal (string item) "DIRECTION")
           (when remaining (pop remaining)))
          (t (%bare-storage-handle-value-error item spec)))))
    (%check-cache-hint-address-space cache-hint addr spec)
    (list (find-symbol "TENSOR" :crisp.compiler)
          element-type 1 addr aln ct)))


;; src/types/validation.lisp
(defun %expand-matrix-type-specifier (element-type rest-args spec)
  (let* ((addr      nil)   ;; no default
         (aln       nil)   ;; no default
         (ct        :last) ;; auto-default
         (cache-hint nil)   ;; endeavour 192: validated and stripped, never canonical
         (remaining rest-args))
    (when (and remaining (not (keywordp (first remaining))))
      (error "Invalid type option ~s in matrix spec ~s. Matrix takes no arity argument; use (tensor ~s N) for arbitrary arity."
             (first remaining) spec element-type))
    (loop while remaining do
      (let ((item (pop remaining)))
        (cond
          ((string-equal (string item) "ADDRESS-SPACE")
           (unless remaining (error "Missing value for :ADDRESS-SPACE in ~s" spec))
           (setf addr (intern (string-upcase (string (pop remaining))) :keyword)))
          ((string-equal (string item) "ACCESS")
           (unless remaining (error "Missing value for :ACCESS in ~s" spec))
           (pop remaining)
           (log:warn "EXPAND-STORAGE-HANDLE: :access is no longer supported in ~s; ignoring." spec))
          ((string-equal (string item) "ALIGN")
           (unless remaining (error "Missing value for :ALIGN in ~s" spec))
           (let ((v (intern (string-upcase (string (pop remaining))) :keyword)))
             (unless (member v '(:compact :compact-offset :strided))
               (error "Invalid :align value ~s in ~s. Expected :compact, :compact-offset, or :strided." v spec))
             (setf aln v)))
          ((string-equal (string item) "CONTIGUOUS-TERM")
           (unless remaining (error "Missing value for :CONTIGUOUS-TERM in ~s" spec))
           (let ((v (intern (string-upcase (string (pop remaining))) :keyword)))
             (cond
               ((member v '(:last :first)) (setf ct v))
               ((eq v :row-major) (setf ct :last))
               ((eq v :col-major) (setf ct :first))
               (t (error "Invalid :contiguous-term value ~s in ~s. Expected :last, :first, :row-major, or :col-major." v spec)))))
          ((string-equal (string item) "CACHE")
           (unless remaining (error "Missing value for :CACHE in ~s" spec))
           (setf cache-hint (%parse-cache-hint (pop remaining) spec)))
          ((string-equal (string item) "DIRECTION")
           (when remaining (pop remaining)))
          (t (%bare-storage-handle-value-error item spec)))))
    (%check-cache-hint-address-space cache-hint addr spec)
    (list (find-symbol "TENSOR" :crisp.compiler)
          element-type 2 addr aln ct)))


;; src/types/validation.lisp
(defun %expand-tensor-type-specifier (base element-type rest-args spec)
  (let* ((n-arg        (and rest-args
                            (not (keywordp (first rest-args)))
                            (first rest-args)))
         (rest-after-n (if n-arg (rest rest-args) rest-args))
         (addr         nil)   ;; no default: must be supplied
         (aln          nil)   ;; no default: must be supplied
         (ct           :last) ;; auto-default
         (cache-hint   nil)   ;; endeavour 192: validated and stripped, never canonical
         (remaining    rest-after-n))
    (unless n-arg
      (error 'crisp-incomplete-type-error :type-spec spec))
    (loop while remaining do
      (let ((item (pop remaining)))
        (cond
          ;; nil placeholder for unspecified slot in canonical
          ;; positional form — preserve as nil (incomplete).
          ((null item) nil)
          ;; bare address-space values (canonical form idempotency)
          ((member (string item)
                   '("GLOBAL" "LOCAL" "PRIVATE" "CONSTANT" "GENERIC")
                   :test #'string-equal)
           (setf addr (intern (string-upcase (string item)) :keyword)))
          ;; bare access values — ignore silently (canonical idempotency for old forms)
          ((member (string item)
                   '("READ-WRITE" "READ-ONLY" "WRITE-ONLY"
                     "READABLE" "WRITEABLE")
                   :test #'string-equal)
           (log:debug "EXPAND-STORAGE-HANDLE: ignoring bare access value ~s in ~s" item spec))
          ;; bare align values (canonical form idempotency)
          ((member (string item) '("COMPACT" "COMPACT-OFFSET" "STRIDED")
                   :test #'string-equal)
           (setf aln (intern (string-upcase (string item)) :keyword)))
          ;; bare contiguous-term values (canonical form idempotency)
          ((member (string item) '("LAST" "FIRST")
                   :test #'string-equal)
           (setf ct (intern (string-upcase (string item)) :keyword)))
          ((string-equal (string item) "ADDRESS-SPACE")
           (unless remaining (error "Missing value for :ADDRESS-SPACE in ~s" spec))
           (setf addr (intern (string-upcase (string (pop remaining))) :keyword)))
          ((string-equal (string item) "ACCESS")
           (unless remaining (error "Missing value for :ACCESS in ~s" spec))
           (pop remaining)
           (log:warn "EXPAND-STORAGE-HANDLE: :access is no longer supported in ~s; ignoring." spec))
          ((string-equal (string item) "ALIGN")
           (unless remaining (error "Missing value for :ALIGN in ~s" spec))
           (let ((v (intern (string-upcase (string (pop remaining))) :keyword)))
             (unless (member v '(:compact :compact-offset :strided))
               (error "Invalid :align value ~s in ~s. Expected :compact, :compact-offset, or :strided." v spec))
             (setf aln v)))
          ((string-equal (string item) "CONTIGUOUS-TERM")
           (unless remaining (error "Missing value for :CONTIGUOUS-TERM in ~s" spec))
           (let ((v (intern (string-upcase (string (pop remaining))) :keyword)))
             (cond
               ((member v '(:last :first)) (setf ct v))
               ((eq v :row-major)
                (let ((n (if (integerp n-arg) n-arg
                             (ignore-errors (parse-integer (string n-arg))))))
                  (unless (eql n 2)
                    (error "Invalid :contiguous-term value ~s in ~s. :row-major and :col-major are only valid for 2D matrix types." v spec)))
                (setf ct :last))
               ((eq v :col-major)
                (let ((n (if (integerp n-arg) n-arg
                             (ignore-errors (parse-integer (string n-arg))))))
                  (unless (eql n 2)
                    (error "Invalid :contiguous-term value ~s in ~s. :row-major and :col-major are only valid for 2D matrix types." v spec)))
                (setf ct :first))
               (t (error "Invalid :contiguous-term value ~s in ~s. Expected :last, :first, :row-major (2D only), or :col-major (2D only)." v spec)))))
          ((string-equal (string item) "CACHE")
           (unless remaining (error "Missing value for :CACHE in ~s" spec))
           (setf cache-hint (%parse-cache-hint (pop remaining) spec)))
          ((string-equal (string item) "DIRECTION")
           (when remaining (pop remaining)))
          (t (error "Invalid type option: ~s in tensor spec ~s" item spec)))))
    (%check-cache-hint-address-space cache-hint addr spec)
    (list base element-type n-arg addr aln ct)))


;; src/types/validation.lisp
(defun %expand-cell-type-specifier (base element-type rest-args spec)
  (if (null rest-args)
      (list base element-type nil)  ;; addr nil → incomplete
      (let ((addr      nil)         ;; no default
            (cache-hint nil)   ;; endeavour 192: validated and stripped, never canonical
            (remaining rest-args))
        (loop while remaining do
          (let ((item (pop remaining)))
            (cond
              ;; nil placeholder for unspecified slot in canonical
              ;; positional form — preserve as nil (incomplete).
              ((null item) nil)
              ((member (string item)
                       '("GLOBAL" "LOCAL" "PRIVATE" "CONSTANT" "GENERIC")
                       :test #'string-equal)
               (setf addr (intern (string-upcase (string item)) :keyword)))
              ((member (string item)
                       '("READ-WRITE" "READ-ONLY" "WRITE-ONLY"
                         "READABLE" "WRITEABLE")
                       :test #'string-equal)
               (log:debug "EXPAND-STORAGE-HANDLE: ignoring bare access value ~s in ~s" item spec))
              ((string-equal (string item) "ADDRESS-SPACE")
               (unless remaining (error "Missing value for :ADDRESS-SPACE in ~s" spec))
               (setf addr (intern (string-upcase (string (pop remaining))) :keyword)))
              ((string-equal (string item) "ACCESS")
               (unless remaining (error "Missing value for :ACCESS in ~s" spec))
               (pop remaining)
               (log:warn "EXPAND-STORAGE-HANDLE: :access is no longer supported in ~s; ignoring." spec))
              ((string-equal (string item) "DIRECTION")
               (when remaining (pop remaining)))
              ((string-equal (string item) "CACHE")
               (unless remaining (error "Missing value for :CACHE in ~s" spec))
               (setf cache-hint (%parse-cache-hint (pop remaining) spec)))
              (t (error "Invalid type option: ~s in spec ~s" item spec)))))
        (%check-cache-hint-address-space cache-hint addr spec)
        (list base element-type addr))))

;;;; Endeavour 192 -- backend hook points.  FOLD: the src definitions plus the marked 192 lines.

;; src/compiler.lisp

;; src/compiler.lisp
(defun compile-to-ptx (module output-path &key (compute-capability "sm_80") debug-p)
  "Compiles an LLVM Module to PTX using llc.
   Pipeline: IR -> opt -O3 (if available) -> llc -> PTX.
   COMPUTE-CAPABILITY: Target GPU architecture (sm_50, sm_75, sm_86, etc.)
                       sm_80 = Ampere (required for endeavor 114's cp.async path).
                       Pre-Ampere targets can pass an explicit value if needed,
                       but kernels using request-load-tile / await-request will
                       fail to compile on anything earlier."
  (declare (ignore debug-p))
  (let* ((base-path (uiop:pathname-directory-pathname output-path))
         (name (pathname-name output-path))
         (ll-file     (merge-pathnames (format nil "~a.temp.ll" name) base-path))
         (ll-opt-file (merge-pathnames (format nil "~a.opt.ll"  name) base-path))
         (ptx-file output-path))

    ;; Set target triple for NVPTX before writing IR
    (llvm-set-target module "nvptx64-nvidia-cuda")

    ;; Endeavor 128 (Phase 4): if any transcendental was lowered to a libdevice
    ;; __nv_* symbol, verify libdevice.10.bc was linked (else a clear error) and set
    ;; the nvvm-reflect-ftz module flag so llc's NVVMReflect resolves __CUDA_FTZ.
    (%ptx-finalize-libdevice module)

    ;; 1. Write raw LLVM IR to .ll file
    (let ((ir (cffi:foreign-string-to-lisp (llvm-print-module-to-string module))))
      (with-open-file (stream ll-file :direction :output :if-exists :supersede)
        (write-string ir stream)))

    ;; 2. Try opt -O3 on the IR.  If it succeeds, feed the optimized IR
    ;;    to llc; otherwise fall back to the raw IR.
    (let* ((opt-ok  (%run-opt-O3 ll-file ll-opt-file))
           (llc-input (if opt-ok ll-opt-file ll-file))
           ;; Endeavour 192: lower :cache hints on the FINAL (post-opt) IR -- -O3 drops metadata, so
           ;; nothing placed in codegen survives -- and re-apply !invariant.load (BUG 134).
           (hint-count (%apply-cache-hints-to-ll llc-input :ptx)))

      ;; 3. llc: IR -> PTX
      (let ((tool (resolve-tool-executable "llc")))
        (run-tool-command
         (append
          (list tool
                "-march=nvptx64"
                (format nil "-mcpu=~a" compute-capability))
          ;; Endeavour 192: eviction priorities and L2::NNNB need PTX ISA 7.4.  +ptx74 only ever
          ;; RAISES the version (sm_80 7.0 -> 7.4; sm_90 stays 7.8, sm_100 8.6).
          (when (plusp hint-count) (list "-mattr=+ptx74"))
          (list (namestring llc-input)
                "-o" (namestring ptx-file)))
         :log-prefix "[PTX] ")))

    ;; Cleanup temp files
    (when (probe-file ll-file)     (delete-file ll-file))
    (when (probe-file ll-opt-file) (delete-file ll-opt-file))

    (log:info "Generated PTX: ~a" ptx-file)))

(defun compile-to-spirv (module output-path &key debug-p)
  "Compiles an LLVM Module to SPIR-V via opt (full -O3) -> llvm-as -> llvm-spirv."
  (let* ((base-path (uiop:pathname-directory-pathname output-path))
         (name (pathname-name output-path))
         (ll-file     (merge-pathnames (format nil "~a.temp.ll" name) base-path))
         (ll-opt-file (merge-pathnames (format nil "~a.opt.ll"  name) base-path))
         (bc-file     (merge-pathnames (format nil "~a.temp.bc" name) base-path))
         (spv-file output-path))
    (%remove-dead-array-returning-functions module)
    (llvm-set-target module "spir64-unknown-unknown")
    (when (or (%module-uses-native-builtin-p module)
              (%module-uses-async-copy-builtin-p module))
      (%emit-opencl-version-metadata module))
    (let* ((ir (cffi:foreign-string-to-lisp (llvm-print-module-to-string module)))
           (ir-with-metadata (inject-spir-kernel-metadata ir)))
      (with-open-file (stream ll-file :direction :output :if-exists :supersede)
        (write-string ir-with-metadata stream)))
    (let* ((opt-ok        (%run-opt-pipeline ll-file ll-opt-file +spv-opt-pipeline+))
           (llvm-as-input (if opt-ok ll-opt-file ll-file)))
      ;; ARM A: -O3 has just discarded the decorations codegen attached, so put them back on
      ;; the FINAL address arithmetic.  Inert unless CRISP_CACHE_CONTROL is set.
      (%inject-cache-control-decorations llvm-as-input)
      ;; Endeavour 192: :cache hints -> CacheControl{Load,Store}INTEL on the post-opt IR.
      (%apply-cache-hints-to-ll llvm-as-input :spirv)
      (let ((tool (resolve-tool-executable "llvm-as")))
        (run-tool-command
         (list tool (namestring llvm-as-input) "-o" (namestring bc-file))
         :log-prefix "[SPIR-V] ")))
    (let* ((tool (resolve-tool-executable "llvm-spirv"))
           (debug-flags (if debug-p '("--spirv-debug-info-version=ocl-100") nil))
           (ext-flags (append '("--spirv-ext=+SPV_EXT_shader_atomic_float_add")
                              (when (%ll-uses-fp16-atomic-fadd-p
                                     (if (probe-file ll-opt-file) ll-opt-file ll-file))
                                '("--spirv-ext=+SPV_EXT_shader_atomic_float16_add"))
                              ;; Endeavour 175: a FLOAT atomic min/max needs its own extension.
                              ;; Without it llvm-spirv exits 18 on any kernel using atomic-min! /
                              ;; atomic-max! on floats -- i.e. every grid-reduce-atomic! with
                              ;; #'min or #'max.
                              (when (%175-ll-uses-float-atomic-minmax-p
                                     (if (probe-file ll-opt-file) ll-opt-file ll-file))
                                '("--spirv-ext=+SPV_EXT_shader_atomic_float_min_max"))
                              (when (%module-uses-coop-matrix-p module)
                                '("--spirv-ext=+SPV_KHR_cooperative_matrix"))
                              (when (%module-uses-2d-block-io-p module)
                                '("--spirv-ext=+SPV_INTEL_2d_block_io"))
                              (when (%module-uses-subgroup-mma-p module)
                                '("--spirv-ext=+SPV_INTEL_subgroup_matrix_multiply_accumulate"))
                              (when (%module-uses-split-barrier-p module)
                                '("--spirv-ext=+SPV_INTEL_split_barrier"))
                              (when (%module-uses-bfloat-p module)
                                '("--spirv-ext=+SPV_KHR_bfloat16"))
                              (when (or (and (%cache-control-spec)
                                             (%module-uses-coop-matrix-p module))
                                        ;; Endeavour 192: :cache hints decorated the IR.
                                        (%ll-uses-cache-control-decorations-p
                                         (if (probe-file ll-opt-file) ll-opt-file ll-file)))
                                '("--spirv-ext=+SPV_INTEL_cache_controls"))))
           (flags (append debug-flags ext-flags)))
      (run-tool-command
       (append (list tool) flags (list (namestring bc-file) "-o" (namestring spv-file)))
       :log-prefix "[SPIR-V] "))
    (unless debug-p
      (when (probe-file ll-file)     (delete-file ll-file))
      (when (probe-file ll-opt-file) (delete-file ll-opt-file))
      (when (probe-file bc-file)     (delete-file bc-file)))
    (log:info "Generated SPIR-V: ~a" spv-file)))

;;;; Endeavour 192 -- corrected copies (char -> cl:char; in :crisp.compiler CHAR is the Crisp type).
;;;; FOLD: only these LAST copies are live; take them, not the ones above.

;; src/compiler.lisp
(defun %ll-split-top-level-commas (s)
  "Endeavour 192.  Split S on commas outside () [] {} <> -- LLVM 21 parameter attributes such as
   captures(ret: address, provenance) contain commas."
  (let ((out '()) (depth 0) (start 0))
    (loop for i from 0 below (length s)
          for c = (cl:char s i)
          do (case c
               ((#\( #\[ #\{ #\<) (incf depth))
               ((#\) #\] #\} #\>) (decf depth))
               (#\, (when (zerop depth)
                      (push (subseq s start i) out)
                      (setf start (1+ i))))))
    (push (subseq s start) out)
    (mapcar (lambda (x) (string-trim " " x)) (nreverse out))))

;; src/compiler.lisp
(defun %ll-define-info (line)
  "Endeavour 192.  For a `define ... @NAME(PARAMS) ...` line return (values NAME PARAMS), PARAMS a
   list of (SSA-NAME . POINTER-ADDRSPACE1-P) in order; NIL for any other line."
  (when (alexandria:starts-with-subseq "define " line)
    (let ((at (search " @" line)))
      (when at
        (let* ((open (position #\( line :start at))
               (name (and open (string-trim "\"" (subseq line (+ at 2) open)))))
          (when open
            (let ((depth 0) (close nil))
              (loop for i from open below (length line)
                    for c = (cl:char line i)
                    do (case c
                         (#\( (incf depth))
                         (#\) (decf depth) (when (zerop depth) (setf close i) (return)))))
              (when close
                (values name
                        (loop for chunk in (%ll-split-top-level-commas (subseq line (1+ open) close))
                              for ssa = (car (last (cl-ppcre:all-matches-as-strings +ll-ssa-name-re+ chunk)))
                              collect (cons ssa (alexandria:starts-with-subseq "ptr addrspace(1)" chunk))))))))))))

;; src/compiler.lisp
(defun %ll-pointer-roots (name defs params memo)
  "Endeavour 192.  The set (list) of addrspace(1) POINTER-parameter indices that the SSA value NAME
   is derived from, walking getelementptr / bitcast / addrspacecast / phi / select.  DEFS: SSA name
   -> right-hand side text.  PARAMS: SSA name -> (index . pointer-p).  MEMO guards cycles (a phi
   reached again contributes nothing)."
  (multiple-value-bind (cached found) (gethash name memo)
    (when found (return-from %ll-pointer-roots cached)))
  (setf (gethash name memo) nil)
  (let* ((param (gethash name params))
         (rhs (gethash name defs))
         (roots
           (cond
             (param (when (cdr param) (list (car param))))
             ((null rhs) nil)
             ((or (alexandria:starts-with-subseq "getelementptr" rhs)
                  (alexandria:starts-with-subseq "bitcast" rhs)
                  (alexandria:starts-with-subseq "addrspacecast" rhs))
              (let ((base (cl-ppcre:scan-to-strings
                           "ptr(?: addrspace\\(\\d+\\))? (%[-a-zA-Z$._0-9]+)" rhs)))
                (when base
                  (%ll-pointer-roots (subseq base (position #\% base)) defs params memo))))
             ((or (alexandria:starts-with-subseq "phi ptr" rhs)
                  (alexandria:starts-with-subseq "select" rhs))
              (let ((ops (if (alexandria:starts-with-subseq "phi" rhs)
                             (mapcar (lambda (m) (string-trim "[ " (subseq m 0 (position #\, m))))
                                     (cl-ppcre:all-matches-as-strings "\\[ *[^,\\]]+," rhs))
                             (mapcar (lambda (m) (subseq m (position #\% m)))
                                     (cl-ppcre:all-matches-as-strings
                                      "ptr(?: addrspace\\(\\d+\\))? %[-a-zA-Z$._0-9]+" rhs)))))
                (remove-duplicates
                 (loop for op in ops
                       when (char= (cl:char op 0) #\%)
                         append (%ll-pointer-roots op defs params memo)))))
             (t nil))))
    (setf (gethash name memo) roots)
    roots))

;; src/compiler.lisp
(defun %apply-cache-hints-to-ll (ll-path backend)
  "Endeavour 192.  Lower :cache hints in the POST-OPT LLVM IR at LL-PATH, in place, for BACKEND
   (:ptx or :spirv).  Returns the number of accesses rewritten.

   Every addrspace(1) load / store inside an entry point listed in *KERNEL-CACHE-HINT-TABLE* has its
   pointer walked back to a kernel argument (%ll-pointer-roots); the argument's entry decides:
     PTX   -- a :cache hint (intent or prefetch) replaces the access with an `asm sideeffect` ld/st
              carrying the qualifiers (memory-clobbered for ordering; ptxas still schedules it as
              an ordinary load).  A read-only argument without a hint gets !invariant.load back,
              which -O3 drops when it narrows a lane-accessed vector load (BUG 134).  The
              load/store vectorizer is run FIRST, so hinted accesses are already vector-width.
     SPIRV -- a :cache intent decorates a fresh zero-offset GEP of the pointer with
              CacheControl{Load,Store}INTEL !spirv.Decorations (llvm-spirv keeps them; -O3 would not
              have).  Prefetch size and read-only-ness have no SPIR-V mapping here.
   Accesses whose pointer has no single root, and types the asm path does not handle, are left as
   they are (a hint is never required for correctness)."
  (unless (and ll-path (probe-file ll-path))
    (return-from %apply-cache-hints-to-ll 0))
  (let ((lines (%ll-read-lines ll-path)))
    (unless (%ll-kernels-with-cache-entries lines)
      (return-from %apply-cache-hints-to-ll 0))
    (when (eq backend :ptx)
      ;; Vector width first: once an access is inline asm, llc's own vectorizer can no longer merge it.
      (let ((vec (make-pathname :type "lsv.ll" :defaults ll-path)))
        (if (%run-passes-in-process ll-path vec "function(load-store-vectorizer)")
            (progn (setf lines (%ll-read-lines vec)) (ignore-errors (delete-file vec)))
            (log:warn "192: load-store-vectorizer failed on ~a; hinting the unvectorized IR" ll-path))))
    (let* ((out '()) (rewritten 0) (counter 0)
           (next-md (1+ (%ll-max-metadata-id lines)))
           (invariant-md nil)
           (deco-mds (make-hash-table :test 'equal))   ; (kind . intent) -> metadata id
           (extra-md '())
           (i 0) (n (length lines)))
      (labels ((emit (l) (push l out))
               (md-id () (prog1 next-md (incf next-md)))
               (deco-md (kind intent)
                 (or (gethash (cons kind intent) deco-mds)
                     (let* ((outer (md-id))
                            (pairs (%spv-cache-controls kind intent))
                            (inner (loop repeat (length pairs) collect (md-id))))
                       (push (format nil "!~d = !{~{!~d~^, ~}}" outer inner) extra-md)
                       (loop for p in pairs for id in inner
                             do (push (format nil "!~d = !{i32 ~d, i32 ~d, i32 ~d}"
                                              id (if (eq kind :load) 6442 6443) (car p) (cdr p))
                                      extra-md))
                       (setf (gethash (cons kind intent) deco-mds) outer)))))
        (loop while (< i n)
              do (let ((line (aref lines i)))
                   (multiple-value-bind (fname fparams) (%ll-define-info line)
                     (let ((entries (and fname (gethash fname *kernel-cache-hint-table*))))
                       (if (null entries)
                           (progn (emit line) (incf i))
                           ;; ---- an entry point with hints: collect its body, then rewrite.
                           (let ((body '()) (defs (make-hash-table :test 'equal))
                                 (params (make-hash-table :test 'equal)) (memo (make-hash-table :test 'equal)))
                             (emit line) (incf i)
                             (loop for (ssa . ptr-p) in fparams for k from 0
                                   when ssa do (setf (gethash ssa params) (cons k ptr-p)))
                             (loop while (and (< i n) (not (string= (aref lines i) "}")))
                                   do (let ((b (aref lines i)))
                                        (cl-ppcre:register-groups-bind (lhs rhs)
                                            ("^\\s*(%[-a-zA-Z$._0-9]+) = (.*)$" b)
                                          (setf (gethash lhs defs) rhs))
                                        (push b body) (incf i)))
                             (dolist (b (nreverse body))
                               (let ((done nil))
                                 ;; LOAD:  %r = load T, ptr addrspace(1) %p, tail
                                 (cl-ppcre:register-groups-bind (result type ptr tail)
                                     ("^\\s*(%[-a-zA-Z$._0-9]+) = load ([^,]+), ptr addrspace\\(1\\) (%[-a-zA-Z$._0-9]+)(.*)$" b)
                                   (unless (or (search "atomic" type) (search "volatile" type))
                                     (let* ((roots (%ll-pointer-roots ptr defs params memo))
                                            (e (and (= (length roots) 1) (assoc (first roots) entries))))
                                       (when e
                                         (destructuring-bind (idx intent prefetch ro) e
                                           (declare (ignore idx))
                                           (cond
                                             ((and (eq backend :ptx) (or intent prefetch))
                                              (let ((new (%ptx-hinted-load-lines result type ptr intent prefetch ro
                                                                                 tail (incf counter))))
                                                (cond (new (mapc #'emit new) (incf rewritten) (setf done t))
                                                      (t (log:debug "192: unhinted (type/alignment): ~a" b)))))
                                             ((and (eq backend :spirv) intent (%spv-cache-controls :load intent))
                                              (let ((g (format nil "%cr.d~d" (incf counter))))
                                                (emit (format nil "  ~a = getelementptr inbounds i8, ptr addrspace(1) ~a, i64 0, !spirv.Decorations !~d"
                                                              g ptr (deco-md :load intent)))
                                                (emit (format nil "  ~a = load ~a, ptr addrspace(1) ~a~a" result type g tail))
                                                (incf rewritten) (setf done t))))
                                           ;; read-only, PTX, not turned into asm: put !invariant.load back
                                           (when (and (not done) ro (eq backend :ptx)
                                                      (not (search "!invariant.load" tail)))
                                             (unless invariant-md
                                               (setf invariant-md (md-id))
                                               (push (format nil "!~d = !{}" invariant-md) extra-md))
                                             (emit (format nil "  ~a = load ~a, ptr addrspace(1) ~a~a, !invariant.load !~d"
                                                           result type ptr tail invariant-md))
                                             (incf rewritten) (setf done t)))))))
                                 ;; STORE: store T VALUE, ptr addrspace(1) %p, tail
                                 (unless done
                                   (cl-ppcre:register-groups-bind (tv ptr tail)
                                       ("^\\s*store (.+), ptr addrspace\\(1\\) (%[-a-zA-Z$._0-9]+)(.*)$" b)
                                     (unless (or (search "atomic" tv) (search "volatile" tv))
                                       (let* ((type (if (char= (cl:char tv 0) #\<)
                                                        (subseq tv 0 (1+ (position #\> tv)))
                                                        (subseq tv 0 (position #\Space tv))))
                                              (value (string-trim " " (subseq tv (length type))))
                                              (roots (%ll-pointer-roots ptr defs params memo))
                                              (e (and (= (length roots) 1) (assoc (first roots) entries)))
                                              (intent (second e)))
                                         (when intent
                                           (cond
                                             ((eq backend :ptx)
                                              (let ((new (%ptx-hinted-store-lines type value ptr intent tail (incf counter))))
                                                (cond (new (mapc #'emit new) (incf rewritten) (setf done t))
                                                      (t (log:debug "192: unhinted store (type/alignment): ~a" b)))))
                                             ((%spv-cache-controls :store intent)
                                              (let ((g (format nil "%cr.d~d" (incf counter))))
                                                (emit (format nil "  ~a = getelementptr inbounds i8, ptr addrspace(1) ~a, i64 0, !spirv.Decorations !~d"
                                                              g ptr (deco-md :store intent)))
                                                (emit (format nil "  store ~a, ptr addrspace(1) ~a~a" tv g tail))
                                                (incf rewritten) (setf done t)))))))))
                                 (unless done (emit b)))))))))))
      (with-open-file (o ll-path :direction :output :if-exists :supersede)
        (dolist (l (nreverse out)) (write-line l o))
        (dolist (l (nreverse extra-md)) (write-line l o)))
      (log:info "192: ~d access(es) rewritten for ~a in ~a" rewritten backend (file-namestring ll-path))
      rewritten)))

;;;; Endeavour 192 -- corrected copies ((return) -> (cl:return); RETURN is shadowed in :crisp.compiler).
;;;; FOLD: only these LAST copies are live.
;; src/types/validation.lisp
(defun %cache-hint-of-type (type-spec)
  "Endeavour 192.  The normalized (INTENT PREFETCH) :cache hint carried by a DECLARED type, or NIL.
   TYPE-SPEC is what a kernel signature declares: an alias symbol, followed through
   *CRISP-TYPE-ALIASES* (whose values are the RAW specs, :cache included), or a raw storage-handle
   list.  (:default NIL) -- no intent, no prefetch -- normalizes to NIL, i.e. exactly 'no key'."
  (let ((spec type-spec))
    (loop repeat 32
          while (and spec (symbolp spec))
          do (let ((next (gethash spec *crisp-type-aliases*)))
               (if next (setf spec next) (cl:return))))
    (when (consp spec)
      (let ((tail (member-if (lambda (x) (and x (symbolp x) (string-equal (symbol-name x) "CACHE")))
                             spec)))
        (when (and tail (rest tail))
          (let ((hint (%parse-cache-hint (second tail) spec)))
            (unless (and (eq (first hint) :default) (null (second hint)))
              hint)))))))

;; src/compiler.lisp
(defun %ll-define-info (line)
  "Endeavour 192.  For a `define ... @NAME(PARAMS) ...` line return (values NAME PARAMS), PARAMS a
   list of (SSA-NAME . POINTER-ADDRSPACE1-P) in order; NIL for any other line."
  (when (alexandria:starts-with-subseq "define " line)
    (let ((at (search " @" line)))
      (when at
        (let* ((open (position #\( line :start at))
               (name (and open (string-trim "\"" (subseq line (+ at 2) open)))))
          (when open
            (let ((depth 0) (close nil))
              (loop for i from open below (length line)
                    for c = (cl:char line i)
                    do (case c
                         (#\( (incf depth))
                         (#\) (decf depth) (when (zerop depth) (setf close i) (cl:return)))))
              (when close
                (values name
                        (loop for chunk in (%ll-split-top-level-commas (subseq line (1+ open) close))
                              for ssa = (car (last (cl-ppcre:all-matches-as-strings +ll-ssa-name-re+ chunk)))
                              collect (cons ssa (alexandria:starts-with-subseq "ptr addrspace(1)" chunk))))))))))))

;;;; Endeavour 192 -- corrected copy: walk inttoptr (PTX kernels take every handle field as i64).
;;;; FOLD: only this LAST copy is live.
;; src/compiler.lisp
(defun %ll-pointer-roots (name defs params memo)
  "Endeavour 192.  The set (list) of addrspace(1) POINTER-parameter indices that the SSA value NAME
   is derived from, walking getelementptr / bitcast / addrspacecast / inttoptr / phi / select.  DEFS: SSA name
   -> right-hand side text.  PARAMS: SSA name -> (index . pointer-p).  MEMO guards cycles (a phi
   reached again contributes nothing)."
  (multiple-value-bind (cached found) (gethash name memo)
    (when found (return-from %ll-pointer-roots cached)))
  (setf (gethash name memo) nil)
  (let* ((param (gethash name params))
         (rhs (gethash name defs))
         (roots
           (cond
             (param (list (car param)))   ; PTX passes every handle field as i64, so any root counts
             ((null rhs) nil)
             ((or (alexandria:starts-with-subseq "getelementptr" rhs)
                  (alexandria:starts-with-subseq "bitcast" rhs)
                  (alexandria:starts-with-subseq "addrspacecast" rhs))
              (let ((base (cl-ppcre:scan-to-strings
                           "ptr(?: addrspace\\(\\d+\\))? (%[-a-zA-Z$._0-9]+)" rhs)))
                (when base
                  (%ll-pointer-roots (subseq base (position #\% base)) defs params memo))))
             ;; PTX: the kernel receives pointers as i64 and rebuilds them with inttoptr.
             ((alexandria:starts-with-subseq "inttoptr" rhs)
              (let ((op (cl-ppcre:scan-to-strings "^inttoptr i64 (%[-a-zA-Z$._0-9]+)" rhs)))
                (when op
                  (%ll-pointer-roots (subseq op (position #\% op)) defs params memo))))
             ((or (alexandria:starts-with-subseq "phi ptr" rhs)
                  (alexandria:starts-with-subseq "select" rhs))
              (let ((ops (if (alexandria:starts-with-subseq "phi" rhs)
                             (mapcar (lambda (m) (string-trim "[ " (subseq m 0 (position #\, m))))
                                     (cl-ppcre:all-matches-as-strings "\\[ *[^,\\]]+," rhs))
                             (mapcar (lambda (m) (subseq m (position #\% m)))
                                     (cl-ppcre:all-matches-as-strings
                                      "ptr(?: addrspace\\(\\d+\\))? %[-a-zA-Z$._0-9]+" rhs)))))
                (remove-duplicates
                 (loop for op in ops
                       when (char= (cl:char op 0) #\%)
                         append (%ll-pointer-roots op defs params memo)))))
             (t nil))))
    (setf (gethash name memo) roots)
    roots))

;;;; Endeavour 192 -- corrected copy: the SPIR-V decoration GEP is typed with the accessed type.
;;;; FOLD: only this LAST copy is live.
;; src/compiler.lisp
(defun %apply-cache-hints-to-ll (ll-path backend)
  "Endeavour 192.  Lower :cache hints in the POST-OPT LLVM IR at LL-PATH, in place, for BACKEND
   (:ptx or :spirv).  Returns the number of accesses rewritten.

   Every addrspace(1) load / store inside an entry point listed in *KERNEL-CACHE-HINT-TABLE* has its
   pointer walked back to a kernel argument (%ll-pointer-roots); the argument's entry decides:
     PTX   -- a :cache hint (intent or prefetch) replaces the access with an `asm sideeffect` ld/st
              carrying the qualifiers (memory-clobbered for ordering; ptxas still schedules it as
              an ordinary load).  A read-only argument without a hint gets !invariant.load back,
              which -O3 drops when it narrows a lane-accessed vector load (BUG 134).  The
              load/store vectorizer is run FIRST, so hinted accesses are already vector-width.
     SPIRV -- a :cache intent decorates a fresh zero-offset GEP of the pointer with
              CacheControl{Load,Store}INTEL !spirv.Decorations (llvm-spirv keeps them; -O3 would not
              have).  The GEP is typed with the ACCESSED type: an i8 GEP makes llvm-spirv insert a
              pointer bitcast, and the access then goes through the undecorated bitcast.  Prefetch size and read-only-ness have no SPIR-V mapping here.
   Accesses whose pointer has no single root, and types the asm path does not handle, are left as
   they are (a hint is never required for correctness)."
  (unless (and ll-path (probe-file ll-path))
    (return-from %apply-cache-hints-to-ll 0))
  (let ((lines (%ll-read-lines ll-path)))
    (unless (%ll-kernels-with-cache-entries lines)
      (return-from %apply-cache-hints-to-ll 0))
    (when (eq backend :ptx)
      ;; Vector width first: once an access is inline asm, llc's own vectorizer can no longer merge it.
      (let ((vec (make-pathname :type "lsv.ll" :defaults ll-path)))
        (if (%run-passes-in-process ll-path vec "function(load-store-vectorizer)")
            (progn (setf lines (%ll-read-lines vec)) (ignore-errors (delete-file vec)))
            (log:warn "192: load-store-vectorizer failed on ~a; hinting the unvectorized IR" ll-path))))
    (let* ((out '()) (rewritten 0) (counter 0)
           (next-md (1+ (%ll-max-metadata-id lines)))
           (invariant-md nil)
           (deco-mds (make-hash-table :test 'equal))   ; (kind . intent) -> metadata id
           (extra-md '())
           (i 0) (n (length lines)))
      (labels ((emit (l) (push l out))
               (md-id () (prog1 next-md (incf next-md)))
               (deco-md (kind intent)
                 (or (gethash (cons kind intent) deco-mds)
                     (let* ((outer (md-id))
                            (pairs (%spv-cache-controls kind intent))
                            (inner (loop repeat (length pairs) collect (md-id))))
                       (push (format nil "!~d = !{~{!~d~^, ~}}" outer inner) extra-md)
                       (loop for p in pairs for id in inner
                             do (push (format nil "!~d = !{i32 ~d, i32 ~d, i32 ~d}"
                                              id (if (eq kind :load) 6442 6443) (car p) (cdr p))
                                      extra-md))
                       (setf (gethash (cons kind intent) deco-mds) outer)))))
        (loop while (< i n)
              do (let ((line (aref lines i)))
                   (multiple-value-bind (fname fparams) (%ll-define-info line)
                     (let ((entries (and fname (gethash fname *kernel-cache-hint-table*))))
                       (if (null entries)
                           (progn (emit line) (incf i))
                           ;; ---- an entry point with hints: collect its body, then rewrite.
                           (let ((body '()) (defs (make-hash-table :test 'equal))
                                 (params (make-hash-table :test 'equal)) (memo (make-hash-table :test 'equal)))
                             (emit line) (incf i)
                             (loop for (ssa . ptr-p) in fparams for k from 0
                                   when ssa do (setf (gethash ssa params) (cons k ptr-p)))
                             (loop while (and (< i n) (not (string= (aref lines i) "}")))
                                   do (let ((b (aref lines i)))
                                        (cl-ppcre:register-groups-bind (lhs rhs)
                                            ("^\\s*(%[-a-zA-Z$._0-9]+) = (.*)$" b)
                                          (setf (gethash lhs defs) rhs))
                                        (push b body) (incf i)))
                             (dolist (b (nreverse body))
                               (let ((done nil))
                                 ;; LOAD:  %r = load T, ptr addrspace(1) %p, tail
                                 (cl-ppcre:register-groups-bind (result type ptr tail)
                                     ("^\\s*(%[-a-zA-Z$._0-9]+) = load ([^,]+), ptr addrspace\\(1\\) (%[-a-zA-Z$._0-9]+)(.*)$" b)
                                   (unless (or (search "atomic" type) (search "volatile" type))
                                     (let* ((roots (%ll-pointer-roots ptr defs params memo))
                                            (e (and (= (length roots) 1) (assoc (first roots) entries))))
                                       (when e
                                         (destructuring-bind (idx intent prefetch ro) e
                                           (declare (ignore idx))
                                           (cond
                                             ((and (eq backend :ptx) (or intent prefetch))
                                              (let ((new (%ptx-hinted-load-lines result type ptr intent prefetch ro
                                                                                 tail (incf counter))))
                                                (cond (new (mapc #'emit new) (incf rewritten) (setf done t))
                                                      (t (log:debug "192: unhinted (type/alignment): ~a" b)))))
                                             ((and (eq backend :spirv) intent (%spv-cache-controls :load intent))
                                              (let ((g (format nil "%cr.d~d" (incf counter))))
                                                (emit (format nil "  ~a = getelementptr inbounds ~a, ptr addrspace(1) ~a, i64 0, !spirv.Decorations !~d"
                                                              g type ptr (deco-md :load intent)))
                                                (emit (format nil "  ~a = load ~a, ptr addrspace(1) ~a~a" result type g tail))
                                                (incf rewritten) (setf done t))))
                                           ;; read-only, PTX, not turned into asm: put !invariant.load back
                                           (when (and (not done) ro (eq backend :ptx)
                                                      (not (search "!invariant.load" tail)))
                                             (unless invariant-md
                                               (setf invariant-md (md-id))
                                               (push (format nil "!~d = !{}" invariant-md) extra-md))
                                             (emit (format nil "  ~a = load ~a, ptr addrspace(1) ~a~a, !invariant.load !~d"
                                                           result type ptr tail invariant-md))
                                             (incf rewritten) (setf done t)))))))
                                 ;; STORE: store T VALUE, ptr addrspace(1) %p, tail
                                 (unless done
                                   (cl-ppcre:register-groups-bind (tv ptr tail)
                                       ("^\\s*store (.+), ptr addrspace\\(1\\) (%[-a-zA-Z$._0-9]+)(.*)$" b)
                                     (unless (or (search "atomic" tv) (search "volatile" tv))
                                       (let* ((type (if (char= (cl:char tv 0) #\<)
                                                        (subseq tv 0 (1+ (position #\> tv)))
                                                        (subseq tv 0 (position #\Space tv))))
                                              (value (string-trim " " (subseq tv (length type))))
                                              (roots (%ll-pointer-roots ptr defs params memo))
                                              (e (and (= (length roots) 1) (assoc (first roots) entries)))
                                              (intent (second e)))
                                         (when intent
                                           (cond
                                             ((eq backend :ptx)
                                              (let ((new (%ptx-hinted-store-lines type value ptr intent tail (incf counter))))
                                                (cond (new (mapc #'emit new) (incf rewritten) (setf done t))
                                                      (t (log:debug "192: unhinted store (type/alignment): ~a" b)))))
                                             ((%spv-cache-controls :store intent)
                                              (let ((g (format nil "%cr.d~d" (incf counter))))
                                                (emit (format nil "  ~a = getelementptr inbounds ~a, ptr addrspace(1) ~a, i64 0, !spirv.Decorations !~d"
                                                              g type ptr (deco-md :store intent)))
                                                (emit (format nil "  store ~a, ptr addrspace(1) ~a~a" tv g tail))
                                                (incf rewritten) (setf done t)))))))))
                                 (unless done (emit b)))))))))))
      (with-open-file (o ll-path :direction :output :if-exists :supersede)
        (dolist (l (nreverse out)) (write-line l o))
        (dolist (l (nreverse extra-md)) (write-line l o)))
      (log:info "192: ~d access(es) rewritten for ~a in ~a" rewritten backend (file-namestring ll-path))
      rewritten)))

;;;; Endeavour 192 -- corrected PTX mapping (decision 2, 2026-10-24).  CUDA 12.4 ptxas REJECTS
;;;; `L1::no_allocate.L2::evict_first` ("Multiple cache eviction priority modifiers") and a bare
;;;; `L2::evict_last` ("'.L1::eviction_priority' syntax expected").  Verified-legal forms (sm_80 and
;;;; sm_90, put_temp_files_here/192-spike/combos.ll):
;;;;   :streaming -> .cs                       (LDG.E.EF / STG.E.EF: evict-first in L1 AND L2)
;;;;   :reused    -> createpolicy.fractional.L2::evict_last + .L2::cache_hint   (sm_80+)
;;;;                 L1::evict_last on loads below sm_80 (createpolicy needs sm_80)
;;;;   :no-l1     -> .cg
;;;;   prefetch N -> .L2::NB (loads);  read-only -> .nc;  all of them combine.
;;;; FOLD: only these LAST copies are live.

;; src/compiler.lisp
(defun %ptx-target-sm ()
  "Endeavour 192.  The PTX target's SM number (sm_90a -> 90), defaulting to 80."
  (or (ignore-errors
       (parse-integer (string-left-trim "smSM_" (ptx-compute-capability-string)) :junk-allowed t))
      80))

;; src/compiler.lisp
(defun %ptx-cache-op (kind intent prefetch readonly lanes suffix)
  "Endeavour 192.  (values OPCODE POLICY-P) for a hinted PTX access.  KIND :load / :store.
   Qualifier order follows the PTX grammar ld.global{.cop}{.nc}{.L1::evict_last}{.L2::cache_hint}
   {.L2::NB}{.vN}.type: :streaming -> .cs; :no-l1 -> .cg; :reused -> .L2::cache_hint with an
   evict_last policy register (POLICY-P true: the caller emits the createpolicy and passes %crp) on
   sm_80+, else L1::evict_last (loads only); PREFETCH (loads) -> .L2::NB; READONLY (loads) -> .nc.
   Every combination this produces was assembled by CUDA 12.4 ptxas for sm_80 and sm_90."
  (let ((parts (list (if (eq kind :load) "ld" "st") "global"))
        (policy nil))
    (flet ((add (x) (setf parts (append parts (list x)))))
      (case intent
        (:streaming (add "cs"))
        (:no-l1     (add "cg")))
      (when (and readonly (eq kind :load)) (add "nc"))
      (when (eq intent :reused)
        (cond ((>= (%ptx-target-sm) 80) (add "L2::cache_hint") (setf policy t))
              ((eq kind :load) (add "L1::evict_last"))))
      (when (and prefetch (eq kind :load)) (add (format nil "L2::~dB" prefetch)))
      (when (> lanes 1) (add (format nil "v~d" lanes)))
      (add suffix))
    (values (format nil "~{~a~^.~}" parts) policy)))

;; src/compiler.lisp
(defun %ptx-policy-wrap (policy-p body)
  "Endeavour 192.  BODY (one PTX instruction, ending in ;) wrapped in its own scope with an
   L2 evict_last access policy in %crp when POLICY-P; BODY unchanged otherwise."
  (if policy-p
      (format nil "{ .reg .b64 %crp; createpolicy.fractional.L2::evict_last.b64 %crp, 1.0; ~a }" body)
      body))

;; src/compiler.lisp
(defun %ptx-hinted-load-lines (result type ptr intent prefetch readonly tail counter)
  "Endeavour 192.  Replacement lines for `RESULT = load TYPE, ptr addrspace(1) PTR TAIL`, or NIL
   when the access cannot be hinted (unsupported type, or a vector load not naturally aligned --
   a .v4 ld needs 16-byte alignment, and LLVM marks a weaker one by splitting it).  COUNTER makes
   the helper names unique within the file."
  (multiple-value-bind (lanes elem) (%ll-type-shape type)
    (when lanes
      (multiple-value-bind (sfx con) (%ptx-elem-asm elem)
        (when sfx
          (let* ((elem-bytes (if (member elem '("double" "i64") :test #'string=) 8 4))
                 (align (or (%ll-align-of tail) 0)))
            (when (or (= lanes 1) (>= align (* lanes elem-bytes)))
              (multiple-value-bind (op policy) (%ptx-cache-op :load intent prefetch readonly lanes sfx)
                (let ((pol (if policy ", %crp" "")))
                  (if (= lanes 1)
                      (list (format nil "  ~a = call ~a asm sideeffect \"~a\", \"=~a,l,~~{memory}\"(ptr addrspace(1) ~a)"
                                    result type
                                    (%ptx-policy-wrap policy (format nil "~a $0, [$1]~a;" op pol))
                                    con ptr))
                      (let* ((base (format nil "%cr.l~d" counter))
                             (struct (format nil "{ ~{~a~^, ~} }" (make-list lanes :initial-element elem)))
                             (outs (format nil "{~{$~d~^, ~}}" (loop for i below lanes collect i)))
                             (cons-str (format nil "~{=~a,~}l,~~{memory}" (make-list lanes :initial-element con)))
                             (lines (list (format nil "  ~a = call ~a asm sideeffect \"~a\", \"~a\"(ptr addrspace(1) ~a)"
                                                  base struct
                                                  (%ptx-policy-wrap policy (format nil "~a ~a, [$~d]~a;" op outs lanes pol))
                                                  cons-str ptr))))
                        (dotimes (i lanes)
                          (push (format nil "  ~a.e~d = extractvalue ~a ~a, ~d" base i struct base i) lines))
                        (dotimes (i lanes)
                          (push (format nil "  ~a = insertelement ~a ~a, ~a ~a.e~d, i32 ~d"
                                        (if (= i (1- lanes)) result (format nil "~a.v~d" base i))
                                        type (if (zerop i) "poison" (format nil "~a.v~d" base (1- i)))
                                        elem base i i)
                                lines))
                        (nreverse lines))))))))))))

;; src/compiler.lisp
(defun %ptx-hinted-store-lines (type value ptr intent tail counter)
  "Endeavour 192.  Replacement lines for `store TYPE VALUE, ptr addrspace(1) PTR TAIL`, or NIL when
   the access cannot be hinted (see %ptx-hinted-load-lines; :reused below sm_80 has no store form)."
  (multiple-value-bind (lanes elem) (%ll-type-shape type)
    (when lanes
      (multiple-value-bind (sfx con) (%ptx-elem-asm elem)
        (when sfx
          (let* ((elem-bytes (if (member elem '("double" "i64") :test #'string=) 8 4))
                 (align (or (%ll-align-of tail) 0)))
            (when (or (= lanes 1) (>= align (* lanes elem-bytes)))
              (multiple-value-bind (op policy) (%ptx-cache-op :store intent nil nil lanes sfx)
                (let ((pol (if policy ", %crp" "")))
                  (when (or policy (not (eq intent :reused)))
                    (if (= lanes 1)
                        (list (format nil "  call void asm sideeffect \"~a\", \"l,~a,~~{memory}\"(ptr addrspace(1) ~a, ~a ~a)"
                                      (%ptx-policy-wrap policy (format nil "~a [$0], $1~a;" op pol))
                                      con ptr type value))
                        (let ((base (format nil "%cr.s~d" counter))
                              (lines '()))
                          (dotimes (i lanes)
                            (push (format nil "  ~a.e~d = extractelement ~a ~a, i32 ~d" base i type value i) lines))
                          (push (format nil "  call void asm sideeffect \"~a\", \"l,~{~a~^,~},~~{memory}\"(ptr addrspace(1) ~a~{, ~a~})"
                                        (%ptx-policy-wrap policy
                                                          (format nil "~a [$0], {~{$~d~^, ~}}~a;"
                                                                  op (loop for i from 1 to lanes collect i) pol))
                                        (make-list lanes :initial-element con) ptr
                                        (loop for i below lanes collect (format nil "~a ~a.e~d" elem base i)))
                                lines)
                          (nreverse lines)))))))))))))

;;;; Endeavour 192 -- corrected copy: the policy block is emitted one instruction per PTX line
;;;; (LLVM string escapes \0A newline, \09 tab), so the PTX reads like llc's own and every ld/st
;;;; still starts its line.  FOLD: only this LAST copy is live.
;; src/compiler.lisp
(defun %ptx-policy-wrap (policy-p body)
  "Endeavour 192.  BODY (one PTX instruction, ending in ;) wrapped in its own scope with an
   L2 evict_last access policy in %crp when POLICY-P; BODY unchanged otherwise.  Lines are
   separated with the LLVM string escapes \\0A\\09 (newline, tab)."
  (if policy-p
      (format nil "{\\0A\\09.reg .b64 %crp;\\0A\\09createpolicy.fractional.L2::evict_last.b64 %crp, 1.0;\\0A\\09~a\\0A\\09}"
              body)
      body))

;;;; Endeavour 192 -- CONSOLIDATED final copy of %apply-cache-hints-to-ll (char -> cl:char, typed
;;;; SPIR-V decoration GEP, and the write guard on read-only re-marking).  FOLD: this is the one to take.
;; src/compiler.lisp
(defun %apply-cache-hints-to-ll (ll-path backend)
  "Endeavour 192.  Lower :cache hints in the POST-OPT LLVM IR at LL-PATH, in place, for BACKEND
   (:ptx or :spirv).  Returns the number of accesses rewritten.

   Every addrspace(1) load / store inside an entry point listed in *KERNEL-CACHE-HINT-TABLE* has its
   pointer walked back to a kernel argument (%ll-pointer-roots); the argument's entry decides:
     PTX   -- a :cache hint (intent or prefetch) replaces the access with an `asm sideeffect` ld/st
              carrying the qualifiers (memory-clobbered for ordering; ptxas still schedules it as
              an ordinary load).  A read-only argument without a hint gets !invariant.load back,
              which -O3 drops when it narrows a lane-accessed vector load (BUG 134).  The
              load/store vectorizer is run FIRST, so hinted accesses are already vector-width.
     SPIRV -- a :cache intent decorates a fresh zero-offset GEP of the pointer with
              CacheControl{Load,Store}INTEL !spirv.Decorations (llvm-spirv keeps them; -O3 would not
              have).  The GEP is typed with the ACCESSED type: an i8 GEP makes llvm-spirv insert a
              pointer bitcast, and the access then goes through the undecorated bitcast.  Prefetch size and read-only-ness have no SPIR-V mapping here.
   Accesses whose pointer has no single root, and types the asm path does not handle, are left as
   they are (a hint is never required for correctness).  An argument the function stores to,
   updates atomically, or passes to a call is never (re-)marked read-only, whatever its position."
  (unless (and ll-path (probe-file ll-path))
    (return-from %apply-cache-hints-to-ll 0))
  (let ((lines (%ll-read-lines ll-path)))
    (unless (%ll-kernels-with-cache-entries lines)
      (return-from %apply-cache-hints-to-ll 0))
    (when (eq backend :ptx)
      ;; Vector width first: once an access is inline asm, llc's own vectorizer can no longer merge it.
      (let ((vec (make-pathname :type "lsv.ll" :defaults ll-path)))
        (if (%run-passes-in-process ll-path vec "function(load-store-vectorizer)")
            (progn (setf lines (%ll-read-lines vec)) (ignore-errors (delete-file vec)))
            (log:warn "192: load-store-vectorizer failed on ~a; hinting the unvectorized IR" ll-path))))
    (let* ((out '()) (rewritten 0) (counter 0)
           (next-md (1+ (%ll-max-metadata-id lines)))
           (invariant-md nil)
           (deco-mds (make-hash-table :test 'equal))   ; (kind . intent) -> metadata id
           (extra-md '())
           (i 0) (n (length lines)))
      (labels ((emit (l) (push l out))
               (md-id () (prog1 next-md (incf next-md)))
               (deco-md (kind intent)
                 (or (gethash (cons kind intent) deco-mds)
                     (let* ((outer (md-id))
                            (pairs (%spv-cache-controls kind intent))
                            (inner (loop repeat (length pairs) collect (md-id))))
                       (push (format nil "!~d = !{~{!~d~^, ~}}" outer inner) extra-md)
                       (loop for p in pairs for id in inner
                             do (push (format nil "!~d = !{i32 ~d, i32 ~d, i32 ~d}"
                                              id (if (eq kind :load) 6442 6443) (car p) (cdr p))
                                      extra-md))
                       (setf (gethash (cons kind intent) deco-mds) outer)))))
        (loop while (< i n)
              do (let ((line (aref lines i)))
                   (multiple-value-bind (fname fparams) (%ll-define-info line)
                     (let ((entries (and fname (gethash fname *kernel-cache-hint-table*))))
                       (if (null entries)
                           (progn (emit line) (incf i))
                           ;; ---- an entry point with hints: collect its body, then rewrite.
                           (let ((body '()) (defs (make-hash-table :test 'equal)) (written (make-hash-table))
                                 (params (make-hash-table :test 'equal)) (memo (make-hash-table :test 'equal)))
                             (emit line) (incf i)
                             (loop for (ssa . ptr-p) in fparams for k from 0
                                   when ssa do (setf (gethash ssa params) (cons k ptr-p)))
                             (loop while (and (< i n) (not (string= (aref lines i) "}")))
                                   do (let ((b (aref lines i)))
                                        (cl-ppcre:register-groups-bind (lhs rhs)
                                            ("^\\s*(%[-a-zA-Z$._0-9]+) = (.*)$" b)
                                          (setf (gethash lhs defs) rhs))
                                        (push b body) (incf i)))
                             ;; Arguments this function may WRITE (store / atomicrmw / cmpxchg / a call
                             ;; that is handed the pointer): never re-mark those read-only.
                             (setf body (nreverse body))
                             (dolist (b body)
                               (when (or (search "store " b) (search "atomicrmw" b)
                                         (search "cmpxchg" b) (search "call " b))
                                 (dolist (m (cl-ppcre:all-matches-as-strings
                                             "ptr addrspace\(1\) %[-a-zA-Z$._0-9]+" b))
                                   (dolist (r (%ll-pointer-roots (subseq m (position #\% m)) defs params memo))
                                     (setf (gethash r written) t)))))
                             (dolist (b body)
                               (let ((done nil))
                                 ;; LOAD:  %r = load T, ptr addrspace(1) %p, tail
                                 (cl-ppcre:register-groups-bind (result type ptr tail)
                                     ("^\\s*(%[-a-zA-Z$._0-9]+) = load ([^,]+), ptr addrspace\\(1\\) (%[-a-zA-Z$._0-9]+)(.*)$" b)
                                   (unless (or (search "atomic" type) (search "volatile" type))
                                     (let* ((roots (%ll-pointer-roots ptr defs params memo))
                                            (e (and (= (length roots) 1) (assoc (first roots) entries))))
                                       (when e
                                         (destructuring-bind (idx intent prefetch ro-declared) e
                                           (let ((ro (and ro-declared (not (gethash idx written)))))
                                           (when (and ro-declared (not ro))
                                             (log:debug "192: ~a writes argument ~d -- not re-marked read-only" fname idx))
                                           (cond
                                             ((and (eq backend :ptx) (or intent prefetch))
                                              (let ((new (%ptx-hinted-load-lines result type ptr intent prefetch ro
                                                                                 tail (incf counter))))
                                                (cond (new (mapc #'emit new) (incf rewritten) (setf done t))
                                                      (t (log:debug "192: unhinted (type/alignment): ~a" b)))))
                                             ((and (eq backend :spirv) intent (%spv-cache-controls :load intent))
                                              (let ((g (format nil "%cr.d~d" (incf counter))))
                                                (emit (format nil "  ~a = getelementptr inbounds ~a, ptr addrspace(1) ~a, i64 0, !spirv.Decorations !~d"
                                                              g type ptr (deco-md :load intent)))
                                                (emit (format nil "  ~a = load ~a, ptr addrspace(1) ~a~a" result type g tail))
                                                (incf rewritten) (setf done t))))
                                           ;; read-only, PTX, not turned into asm: put !invariant.load back
                                           (when (and (not done) ro (eq backend :ptx)
                                                      (not (search "!invariant.load" tail)))
                                             (unless invariant-md
                                               (setf invariant-md (md-id))
                                               (push (format nil "!~d = !{}" invariant-md) extra-md))
                                             (emit (format nil "  ~a = load ~a, ptr addrspace(1) ~a~a, !invariant.load !~d"
                                                           result type ptr tail invariant-md))
                                             (incf rewritten) (setf done t))))))))
                                 ;; STORE: store T VALUE, ptr addrspace(1) %p, tail
                                 (unless done
                                   (cl-ppcre:register-groups-bind (tv ptr tail)
                                       ("^\\s*store (.+), ptr addrspace\\(1\\) (%[-a-zA-Z$._0-9]+)(.*)$" b)
                                     (unless (or (search "atomic" tv) (search "volatile" tv))
                                       (let* ((type (if (char= (cl:char tv 0) #\<)
                                                        (subseq tv 0 (1+ (position #\> tv)))
                                                        (subseq tv 0 (position #\Space tv))))
                                              (value (string-trim " " (subseq tv (length type))))
                                              (roots (%ll-pointer-roots ptr defs params memo))
                                              (e (and (= (length roots) 1) (assoc (first roots) entries)))
                                              (intent (second e)))
                                         (when intent
                                           (cond
                                             ((eq backend :ptx)
                                              (let ((new (%ptx-hinted-store-lines type value ptr intent tail (incf counter))))
                                                (cond (new (mapc #'emit new) (incf rewritten) (setf done t))
                                                      (t (log:debug "192: unhinted store (type/alignment): ~a" b)))))
                                             ((%spv-cache-controls :store intent)
                                              (let ((g (format nil "%cr.d~d" (incf counter))))
                                                (emit (format nil "  ~a = getelementptr inbounds ~a, ptr addrspace(1) ~a, i64 0, !spirv.Decorations !~d"
                                                              g type ptr (deco-md :store intent)))
                                                (emit (format nil "  store ~a, ptr addrspace(1) ~a~a" tv g tail))
                                                (incf rewritten) (setf done t)))))))))
                                 (unless done (emit b)))))))))))
      (with-open-file (o ll-path :direction :output :if-exists :supersede)
        (dolist (l (nreverse out)) (write-line l o))
        (dolist (l (nreverse extra-md)) (write-line l o)))
      (log:info "192: ~d access(es) rewritten for ~a in ~a" rewritten backend (file-namestring ll-path))
      rewritten)))

;;;; Endeavour 192 -- CONSOLIDATED final copy of %apply-cache-hints-to-ll, now also decorating the
;;;; pointer arguments of SPIR-V block / coop-matrix builtins.  FOLD: THIS is the one to take.
;; src/compiler.lisp
(defun %apply-cache-hints-to-ll (ll-path backend)
  "Endeavour 192.  Lower :cache hints in the POST-OPT LLVM IR at LL-PATH, in place, for BACKEND
   (:ptx or :spirv).  Returns the number of accesses rewritten.

   Every addrspace(1) load / store inside an entry point listed in *KERNEL-CACHE-HINT-TABLE* has its
   pointer walked back to a kernel argument (%ll-pointer-roots); the argument's entry decides:
     PTX   -- a :cache hint (intent or prefetch) replaces the access with an `asm sideeffect` ld/st
              carrying the qualifiers (memory-clobbered for ordering; ptxas still schedules it as
              an ordinary load).  A read-only argument without a hint gets !invariant.load back,
              which -O3 drops when it narrows a lane-accessed vector load (BUG 134).  The
              load/store vectorizer is run FIRST, so hinted accesses are already vector-width.
     SPIRV -- a :cache intent decorates a fresh zero-offset GEP of the pointer with
              CacheControl{Load,Store}INTEL !spirv.Decorations (llvm-spirv keeps them; -O3 would not
              have).  The GEP is typed with the ACCESSED type: an i8 GEP makes llvm-spirv insert a
              pointer bitcast, and the access then goes through the undecorated bitcast.  Prefetch size and read-only-ness have no SPIR-V mapping here.
   Accesses whose pointer has no single root, and types the asm path does not handle, are left as
   they are (a hint is never required for correctness).  An argument the function stores to,
   updates atomically, or passes to a call is never (re-)marked read-only, whatever its position."
  (unless (and ll-path (probe-file ll-path))
    (return-from %apply-cache-hints-to-ll 0))
  (let ((lines (%ll-read-lines ll-path)))
    (unless (%ll-kernels-with-cache-entries lines)
      (return-from %apply-cache-hints-to-ll 0))
    (when (eq backend :ptx)
      ;; Vector width first: once an access is inline asm, llc's own vectorizer can no longer merge it.
      (let ((vec (make-pathname :type "lsv.ll" :defaults ll-path)))
        (if (%run-passes-in-process ll-path vec "function(load-store-vectorizer)")
            (progn (setf lines (%ll-read-lines vec)) (ignore-errors (delete-file vec)))
            (log:warn "192: load-store-vectorizer failed on ~a; hinting the unvectorized IR" ll-path))))
    (let* ((out '()) (rewritten 0) (counter 0)
           (next-md (1+ (%ll-max-metadata-id lines)))
           (invariant-md nil)
           (deco-mds (make-hash-table :test 'equal))   ; (kind . intent) -> metadata id
           (extra-md '())
           (i 0) (n (length lines)))
      (labels ((emit (l) (push l out))
               (md-id () (prog1 next-md (incf next-md)))
               (deco-md (kind intent)
                 (or (gethash (cons kind intent) deco-mds)
                     (let* ((outer (md-id))
                            (pairs (%spv-cache-controls kind intent))
                            (inner (loop repeat (length pairs) collect (md-id))))
                       (push (format nil "!~d = !{~{!~d~^, ~}}" outer inner) extra-md)
                       (loop for p in pairs for id in inner
                             do (push (format nil "!~d = !{i32 ~d, i32 ~d, i32 ~d}"
                                              id (if (eq kind :load) 6442 6443) (car p) (cdr p))
                                      extra-md))
                       (setf (gethash (cons kind intent) deco-mds) outer)))))
        (loop while (< i n)
              do (let ((line (aref lines i)))
                   (multiple-value-bind (fname fparams) (%ll-define-info line)
                     (let ((entries (and fname (gethash fname *kernel-cache-hint-table*))))
                       (if (null entries)
                           (progn (emit line) (incf i))
                           ;; ---- an entry point with hints: collect its body, then rewrite.
                           (let ((body '()) (defs (make-hash-table :test 'equal)) (written (make-hash-table))
                                 (call-decos (make-hash-table :test 'equal))
                                 (params (make-hash-table :test 'equal)) (memo (make-hash-table :test 'equal)))
                             (emit line) (incf i)
                             (loop for (ssa . ptr-p) in fparams for k from 0
                                   when ssa do (setf (gethash ssa params) (cons k ptr-p)))
                             (loop while (and (< i n) (not (string= (aref lines i) "}")))
                                   do (let ((b (aref lines i)))
                                        (cl-ppcre:register-groups-bind (lhs rhs)
                                            ("^\\s*(%[-a-zA-Z$._0-9]+) = (.*)$" b)
                                          (setf (gethash lhs defs) rhs))
                                        (push b body) (incf i)))
                             ;; Arguments this function may WRITE (store / atomicrmw / cmpxchg / a call
                             ;; that is handed the pointer): never re-mark those read-only.
                             (setf body (nreverse body))
                             (dolist (b body)
                               (when (or (search "store " b) (search "atomicrmw" b)
                                         (search "cmpxchg" b) (search "call " b))
                                 (dolist (m (cl-ppcre:all-matches-as-strings
                                             "ptr addrspace\\(1\\) %[-a-zA-Z$._0-9]+" b))
                                   (dolist (r (%ll-pointer-roots (subseq m (position #\% m)) defs params memo))
                                     (setf (gethash r written) t)))))
                             ;; SPIR-V block / coop-matrix builtins (2D block load / store / prefetch,
                             ;; CooperativeMatrixLoad/StoreKHR): their global pointer ARGUMENT is decorated
                             ;; on its DEFINING instruction, the placement the 2026-08-27 probe verified IGC
                             ;; accepts.  (prefetch-tile lowers to Subgroup2DBlockPrefetchINTEL.)
                             (when (eq backend :spirv)
                               (dolist (b body)
                                 (when (and (search "call " b) (search "@__spirv_" b))
                                   (let ((kind (cond ((search "Store" b) :store)
                                                     ((or (search "Load" b) (search "Prefetch" b)) :load))))
                                     (when kind
                                       (dolist (m (cl-ppcre:all-matches-as-strings
                                                   "ptr addrspace\\(1\\) %[-a-zA-Z$._0-9]+" b))
                                         (let* ((p (subseq m (position #\% m)))
                                                (roots (%ll-pointer-roots p defs params memo))
                                                (e (and (= (length roots) 1) (assoc (first roots) entries))))
                                           (when (and e (second e) (%spv-cache-controls kind (second e))
                                                      (gethash p defs))
                                             (setf (gethash p call-decos) (cons kind (second e)))))))))))
                             (dolist (b body)
                               (let ((done nil))
                                 ;; LOAD:  %r = load T, ptr addrspace(1) %p, tail
                                 (cl-ppcre:register-groups-bind (result type ptr tail)
                                     ("^\\s*(%[-a-zA-Z$._0-9]+) = load ([^,]+), ptr addrspace\\(1\\) (%[-a-zA-Z$._0-9]+)(.*)$" b)
                                   (unless (or (search "atomic" type) (search "volatile" type))
                                     (let* ((roots (%ll-pointer-roots ptr defs params memo))
                                            (e (and (= (length roots) 1) (assoc (first roots) entries))))
                                       (when e
                                         (destructuring-bind (idx intent prefetch ro-declared) e
                                           (let ((ro (and ro-declared (not (gethash idx written)))))
                                           (when (and ro-declared (not ro))
                                             (log:debug "192: ~a writes argument ~d -- not re-marked read-only" fname idx))
                                           (cond
                                             ((and (eq backend :ptx) (or intent prefetch))
                                              (let ((new (%ptx-hinted-load-lines result type ptr intent prefetch ro
                                                                                 tail (incf counter))))
                                                (cond (new (mapc #'emit new) (incf rewritten) (setf done t))
                                                      (t (log:debug "192: unhinted (type/alignment): ~a" b)))))
                                             ((and (eq backend :spirv) intent (%spv-cache-controls :load intent))
                                              (let ((g (format nil "%cr.d~d" (incf counter))))
                                                (emit (format nil "  ~a = getelementptr inbounds ~a, ptr addrspace(1) ~a, i64 0, !spirv.Decorations !~d"
                                                              g type ptr (deco-md :load intent)))
                                                (emit (format nil "  ~a = load ~a, ptr addrspace(1) ~a~a" result type g tail))
                                                (incf rewritten) (setf done t))))
                                           ;; read-only, PTX, not turned into asm: put !invariant.load back
                                           (when (and (not done) ro (eq backend :ptx)
                                                      (not (search "!invariant.load" tail)))
                                             (unless invariant-md
                                               (setf invariant-md (md-id))
                                               (push (format nil "!~d = !{}" invariant-md) extra-md))
                                             (emit (format nil "  ~a = load ~a, ptr addrspace(1) ~a~a, !invariant.load !~d"
                                                           result type ptr tail invariant-md))
                                             (incf rewritten) (setf done t))))))))
                                 ;; STORE: store T VALUE, ptr addrspace(1) %p, tail
                                 (unless done
                                   (cl-ppcre:register-groups-bind (tv ptr tail)
                                       ("^\\s*store (.+), ptr addrspace\\(1\\) (%[-a-zA-Z$._0-9]+)(.*)$" b)
                                     (unless (or (search "atomic" tv) (search "volatile" tv))
                                       (let* ((type (if (char= (cl:char tv 0) #\<)
                                                        (subseq tv 0 (1+ (position #\> tv)))
                                                        (subseq tv 0 (position #\Space tv))))
                                              (value (string-trim " " (subseq tv (length type))))
                                              (roots (%ll-pointer-roots ptr defs params memo))
                                              (e (and (= (length roots) 1) (assoc (first roots) entries)))
                                              (intent (second e)))
                                         (when intent
                                           (cond
                                             ((eq backend :ptx)
                                              (let ((new (%ptx-hinted-store-lines type value ptr intent tail (incf counter))))
                                                (cond (new (mapc #'emit new) (incf rewritten) (setf done t))
                                                      (t (log:debug "192: unhinted store (type/alignment): ~a" b)))))
                                             ((%spv-cache-controls :store intent)
                                              (let ((g (format nil "%cr.d~d" (incf counter))))
                                                (emit (format nil "  ~a = getelementptr inbounds ~a, ptr addrspace(1) ~a, i64 0, !spirv.Decorations !~d"
                                                              g type ptr (deco-md :store intent)))
                                                (emit (format nil "  store ~a, ptr addrspace(1) ~a~a" tv g tail))
                                                (incf rewritten) (setf done t)))))))))
                                 (unless done
                                   (let* ((lhs (cl-ppcre:register-groups-bind (l) ("^\\s*(%[-a-zA-Z$._0-9]+) = " b) l))
                                          (cd (and lhs (gethash lhs call-decos))))
                                     (cond ((and cd (not (search "!spirv.Decorations" b)))
                                            (emit (format nil "~a, !spirv.Decorations !~d" b (deco-md (car cd) (cdr cd))))
                                            (incf rewritten))
                                           (t (emit b))))))))))))))
      (with-open-file (o ll-path :direction :output :if-exists :supersede)
        (dolist (l (nreverse out)) (write-line l o))
        (dolist (l (nreverse extra-md)) (write-line l o)))
      (log:info "192: ~d access(es) rewritten for ~a in ~a" rewritten backend (file-namestring ll-path))
      rewritten)))

;;;; Endeavour 192 -- tile operations take their cache hint from the storage handle's TYPE (their
;;;; element accesses trace back to the argument like any other).  A :cache key on the OPERATION is
;;;; refused, not silently ignored: a per-operation override needs a construct that survives -O3
;;;; (decision 3, 2026-10-24; follow-up in tests/spec/192-cache-hints/cache-hints.md).
;;;; FOLD: put the %refuse-per-operation-cache call at the top of each analyzer.

;; src/analysis/control.lisp
(defun %refuse-per-operation-cache (op-name key-args location)
  "Endeavour 192.  Signal a crisp-compiler-error when KEY-ARGS (a keyword plist) carries :cache."
  (loop for (k nil) on key-args by #'cddr
        when (and k (symbolp k) (string-equal (symbol-name k) "CACHE"))
          do (error 'crisp-compiler-error
                    :message (format nil "~a: per-operation :cache is not supported -- declare :cache on the tensor's TYPE (e.g. (vector float :address-space :global ... :cache :streaming)); every tile operation honours the type's hint."
                                     op-name)
                    :source-location location)))

;; src/analysis/control.lisp  -- FOLD: first form of analyze-load-tile-at-expression
(defvar *%192-orig-analyze-load-tile-at* (fdefinition 'analyze-load-tile-at-expression)
  "Endeavour 192.  The pre-192 analyze-load-tile-at-expression, wrapped below.")

;; src/analysis/control.lisp
(defun analyze-load-tile-at-expression (expr env context location)
  "Analyzer for load-tile-at (see the wrapped original).  Endeavour 192: refuses a per-operation
   :cache key."
  (%refuse-per-operation-cache "load-tile-at" (nthcdr 4 expr) location)
  (funcall *%192-orig-analyze-load-tile-at* expr env context location))

;; src/analysis/control.lisp  -- FOLD: first form of analyze-store-tile-at-expression
(defvar *%192-orig-analyze-store-tile-at* (fdefinition 'analyze-store-tile-at-expression)
  "Endeavour 192.  The pre-192 analyze-store-tile-at-expression, wrapped below.")

;; src/analysis/control.lisp
(defun analyze-store-tile-at-expression (expr env context location)
  "Analyzer for store-tile-at (see the wrapped original).  Endeavour 192: refuses a per-operation
   :cache key."
  (%refuse-per-operation-cache "store-tile-at" (nthcdr 4 expr) location)
  (funcall *%192-orig-analyze-store-tile-at* expr env context location))

;; src/mma.lisp  -- FOLD: first form of analyze-prefetch-tile
(defvar *%192-orig-analyze-prefetch-tile* (fdefinition 'analyze-prefetch-tile)
  "Endeavour 192.  The pre-192 analyze-prefetch-tile, wrapped below.")

;; src/mma.lisp
(defun analyze-prefetch-tile (expr env context location)
  "Analyzer for prefetch-tile (see the wrapped original).  Endeavour 192: refuses a per-operation
   :cache key with a real message (the original's destructuring-bind would die on the unknown key)."
  (%refuse-per-operation-cache "prefetch-tile" (nthcdr 3 expr) location)
  (funcall *%192-orig-analyze-prefetch-tile* expr env context location))

;; src/mma.lisp
(defun validate-spv-cache-coop-streaming (spv-path)
  "Endeavour 192 / spec 16: an Intel XMX matmul whose A, B, C are :streaming.  Some id carries
   CacheControlLoadINTEL L1+L3 Streaming (0 2 / 1 2) and some id CacheControlStoreINTEL L1+L3
   Streaming (0 3 / 1 3); no decoration names any other control."
  (let ((c (%spv-cache-control-census spv-path)))
    (if (null c)
        (progn (format t "  (llvm-spirv unavailable -- cache-control check skipped)~%") t)
        (let ((ld (getf c :load-deco)) (st (getf c :store-deco)))
          (flet ((streaming-ids (table l c3)
                   (loop for id being the hash-keys of table using (hash-value deco)
                         when (and (%spv-deco-is deco 0 l) (%spv-deco-is deco 1 c3)) collect id))
                 (odd-ids (table good)
                   (loop for id being the hash-keys of table using (hash-value deco)
                         unless (every (lambda (d) (string= (second d) good)) deco) collect id)))
            (cond ((null (streaming-ids ld 2 2))
                   (%spv-cache-fail "no CacheControlLoadINTEL 0 2 / 1 2 (streaming) decoration"))
                  ((null (streaming-ids st 3 3))
                   (%spv-cache-fail "no CacheControlStoreINTEL 0 3 / 1 3 (streaming) decoration"))
                  ((or (odd-ids ld "2") (odd-ids st "3"))
                   (%spv-cache-fail "a cache-control decoration names a non-streaming control"))
                  (t t)))))))

;;;; Endeavour 192 -- corrected copies: a semantic parameter can expand to several LLVM parameters
;;;; (an implicit scratch tile is ONE struct-typed node and SIX LLVM params), so the physical index is
;;;; the running sum of get-expanded-types widths -- exactly what create-llvm-function-type does.
;;;; Found by spec 15 (two scratch tiles ahead of V).  FOLD: only these LAST copies are live.

;; src/codegen.lisp
(defun %compute-kernel-cache-hints (semantic-function &optional module)
  "Endeavour 192.  The *KERNEL-CACHE-HINT-TABLE* entries for SEMANTIC-FUNCTION (an entry point).

   Physical parameters are the flattened handle fields (INPUT_PTR INPUT_BYTE_SIZE ...); the
   POINTER field <NAME>_PTR is matched to the declared parameter NAME in
   *KERNEL-DECLARED-SIGNATURES*, whose types are the declared (alias or raw) specs.  Each semantic
   parameter's LLVM width is (length (get-expanded-types TYPE MODULE)) -- the same expansion
   create-llvm-function-type performs -- so the recorded index is the LLVM parameter's position even
   when struct-typed nodes (implicit scratch tiles) precede it.  Without MODULE every node counts 1.

   Adjoints inherit nothing: in a *_GRAD kernel a parameter P_GRAD whose P is also declared is a
   gradient (shadow) buffer -- its access pattern is not the forward pass's, so it gets no hint
   even though it is declared with the same alias type (decision 2026-10-23)."
  (let* ((fn-name  (semantic-function-name semantic-function))
         (declared (remove-if (lambda (p) (string= (symbol-name (car p)) "&OUT"))
                              (gethash fn-name *kernel-declared-signatures*)))
         (names    (mapcar (lambda (p) (symbol-name (car p))) declared))
         (grad-p   (alexandria:ends-with-subseq "_GRAD" (symbol-name fn-name)))
         (readonly (ignore-errors (%collect-readonly-tensor-param-syms semantic-function)))
         (phys     0)
         (entries  '()))
    (dolist (node (semantic-function-param-list semantic-function))
      (let ((pname (symbol-name (semantic-param-name node)))
            (width (or (and module
                            (ignore-errors (length (get-expanded-types (semantic-param-type node) module))))
                       1)))
        (when (alexandria:ends-with-subseq "_PTR" pname)
          (let* ((logical (subseq pname 0 (- (length pname) 4)))
                 (decl    (find logical declared :key (lambda (p) (symbol-name (car p)))
                                                 :test #'string=)))
            (when decl
              (let* ((adjoint-p (and grad-p
                                     (alexandria:ends-with-subseq "_GRAD" logical)
                                     (member (subseq logical 0 (- (length logical) 5)) names
                                             :test #'string=)))
                     (hint (unless adjoint-p (%cache-hint-of-type (cdr decl))))
                     (ro   (and (hash-table-p readonly) (gethash (car decl) readonly) t)))
                (when adjoint-p
                  (log:debug "192: ~a: ~a is an adjoint -- no cache hint" fn-name logical))
                (when (or hint ro)
                  (push (list phys (first hint) (second hint) ro) entries))))))
        (incf phys width)))
    (nreverse entries)))

;; src/codegen.lisp
(defun ensure-opencl-kernel-metadata (func semantic-function module)
  "Marks a function as a SPIR-V/PTX kernel if it's an entry point (see the wrapped original for
   the full contract).  Endeavour 192: also records the entry point's cache-hint table
   (*KERNEL-CACHE-HINT-TABLE*) for the post-opt pass, indexed by LLVM parameter position."
  (prog1 (funcall *%192-orig-ensure-opencl-kernel-metadata* func semantic-function module)
    (when (semantic-function-is-entry-point semantic-function)
      (let ((entries (%compute-kernel-cache-hints semantic-function module))
            (name (%kernel-llvm-name semantic-function)))
        (setf (gethash name *kernel-cache-hint-table*) entries)
        (when entries
          (log:info "192: ~a cache-hint table (index intent prefetch readonly): ~s" name entries))))))
