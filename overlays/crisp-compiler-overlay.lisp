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
