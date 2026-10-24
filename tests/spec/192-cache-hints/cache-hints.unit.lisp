;; tests/spec/192-cache-hints/cache-hints.unit.lisp
;; Endeavour 192 -- unit tests for the :cache parser / normalizer, the PTX opcode builder, the SPIR-V
;; control mapping, and the post-opt pointer walk.  The emitted-code claims live in the .crisp specs.
(in-package :cl-user)

(defpackage :crisp.test.cache-hints
  (:use :cl :parachute)
  (:import-from :crisp.compiler
                #:%parse-cache-hint
                #:%cache-intent-keyword
                #:%ptx-cache-op
                #:%spv-cache-controls
                #:%ll-split-top-level-commas
                #:%ll-define-info
                #:%ll-pointer-roots
                #:%ll-type-shape))

(in-package :crisp.test.cache-hints)

(define-test cache-hints)

(define-test (cache-hints parse-bare-and-list)
  "A bare intent, a list with :prefetch, and normalization of the reader's package."
  (is equal '(:streaming nil) (%parse-cache-hint :streaming 'spec))
  (is equal '(:reused 256) (%parse-cache-hint '(:reused :prefetch 256) 'spec))
  (is equal '(:default 64) (%parse-cache-hint '(:default :prefetch 64) 'spec))
  (is eq :no-l1 (%cache-intent-keyword :no-l1))
  (false (%cache-intent-keyword :sometimes)))

(define-test (cache-hints parse-refusals)
  "Each malformed value is refused (the exact messages are pinned by the errors/ specs)."
  (fail (%parse-cache-hint :sometimes 'spec))
  (fail (%parse-cache-hint '(:streaming :prefetch 100) 'spec))
  (fail (%parse-cache-hint '(:prefetch 256) 'spec))
  (fail (%parse-cache-hint '(:streaming :size 256) 'spec))
  (fail (%parse-cache-hint '(:streaming :prefetch) 'spec)))

(define-test (cache-hints ptx-opcodes)
  "The qualifier order ptxas accepts: cop, .nc, cache_hint, prefetch, vector, type."
  (is string= "ld.global.cs.nc.L2::256B.v4.f32" (%ptx-cache-op :load :streaming 256 t 4 "f32"))
  (is string= "st.global.cs.f32" (%ptx-cache-op :store :streaming 256 t 1 "f32"))
  (is string= "ld.global.cg.b64" (%ptx-cache-op :load :no-l1 nil nil 1 "b64"))
  (is string= "ld.global.nc.L2::128B.f32" (%ptx-cache-op :load nil 128 t 1 "f32")))

(define-test (cache-hints spv-controls)
  "CacheControl{Load,Store}INTEL (level . control) pairs; :default has none."
  (is equal '((0 . 2) (1 . 2)) (%spv-cache-controls :load :streaming))
  (is equal '((0 . 3) (1 . 3)) (%spv-cache-controls :store :streaming))
  (is equal '((0 . 0) (1 . 2)) (%spv-cache-controls :store :no-l1))
  (false (%spv-cache-controls :load :default)))

(define-test (cache-hints ll-parsing)
  "LLVM 21 parameter attributes contain commas inside parentheses."
  (is equal '("ptr addrspace(1) readnone captures(ret: address, provenance) %0" "i64 %1")
      (%ll-split-top-level-commas "ptr addrspace(1) readnone captures(ret: address, provenance) %0, i64 %1"))
  (multiple-value-bind (name params)
      (%ll-define-info "define ptx_kernel void @k(i64 %0, ptr addrspace(1) noalias %1) #1 {")
    (is string= "k" name)
    (is equal '(("%0") ("%1" . t)) params))
  (is equal '(4 "float") (multiple-value-list (%ll-type-shape "<4 x float>")))
  (false (%ll-type-shape "<8 x half>")))

(define-test (cache-hints pointer-roots)
  "PTX passes pointers as i64: GEP -> addrspacecast -> inttoptr -> param; a phi of two params is ambiguous."
  (let ((defs (make-hash-table :test 'equal))
        (params (make-hash-table :test 'equal)))
    (setf (gethash "%0" params) '(0) (gethash "%6" params) '(6))
    (setf (gethash "%g" defs) "inttoptr i64 %0 to ptr"
          (gethash "%a" defs) "addrspacecast ptr %g to ptr addrspace(1)"
          (gethash "%p" defs) "getelementptr inbounds i8, ptr addrspace(1) %a, i64 %off"
          (gethash "%h" defs) "inttoptr i64 %6 to ptr addrspace(1)"
          (gethash "%m" defs) "phi ptr addrspace(1) [ %p, %bb1 ], [ %h, %bb2 ]")
    (is equal '(0) (%ll-pointer-roots "%p" defs params (make-hash-table :test 'equal)))
    (is equal 2 (length (%ll-pointer-roots "%m" defs params (make-hash-table :test 'equal))))))

;; Run tests - Parachute will error if any fail
(test 'cache-hints)
