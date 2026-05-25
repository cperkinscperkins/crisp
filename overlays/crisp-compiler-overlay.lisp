;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)


;; ======================================================================
;; Endeavor 114 Phase A — SPV native async tile copy: BLOCKED, reverted
;; ======================================================================
;;
;; The SPV codegen path was attempted but ran into an IGC BiFModule
;; linkage gap.  Documented in
;; tests/spec/114-async-tile-codegen/async-tile-codegen.md under
;; "SPV Phase A blocker."  SPV stays at the 113 fallback (sync
;; cooperative loop + barrier) for now.


;; ======================================================================
;; Endeavor 114 Phase B — NVPTX cp.async-based async tile copy
;; ======================================================================
;;
;; Replaces 113's fallback when *target-backend* is :ptx with a real
;; cp.async per-thread + cp.async.commit_group + cp.async.wait_group
;; sequence.  Uses direct LLVM NVVM intrinsics — no linkage hazard
;; (validated end-to-end Phase 0 via llc-spv-smoke and llc-ptx-smoke).
;;
;; Phase B.1 scope: simple case where tile.length == workgroup_size
;; (one cp.async per thread, no inner loop).  Bigger tiles need a
;; cooperative loop — B.2 follow-up.  Element type must be 4 or 8 bytes
;; (cp.async supports 4 / 8 / 16 byte payloads; 1- and 2-byte elements
;; would need coalescing).
;;
;; Hardware target: cp.async requires sm_80+ (Ampere).  Crisp's default
;; was sm_50 (Maxwell) — bumped to sm_80 in src/compiler.lisp.


;; src/codegen.lisp — NVVM intrinsic call helpers.

(defun %gen-nvvm-cp-async-elem (builder module dst-ptr src-ptr elem-bytes)
  "Emits @llvm.nvvm.cp.async.ca.shared.global.{4|8|16}(dst, src).
   ELEM-BYTES picks the right intrinsic variant."
  (let* ((fn-name (case elem-bytes
                    (4  "llvm.nvvm.cp.async.ca.shared.global.4")
                    (8  "llvm.nvvm.cp.async.ca.shared.global.8")
                    (16 "llvm.nvvm.cp.async.ca.shared.global.16")
                    (t (error "%gen-nvvm-cp-async-elem: unsupported elem-bytes ~A (need 4, 8, or 16)"
                              elem-bytes))))
         (i8-type    (llvm-int8-type))
         (ptr-as3    (llvm-pointer-type i8-type 3))
         (ptr-as1    (llvm-pointer-type i8-type 1))
         (param-types (let ((arr (cffi:foreign-alloc 'llvm-type-ref :count 2)))
                        (setf (cffi:mem-aref arr 'llvm-type-ref 0) ptr-as3)
                        (setf (cffi:mem-aref arr 'llvm-type-ref 1) ptr-as1)
                        arr))
         (fn-type    (llvm-function-type (llvm-void-type) param-types 2 nil))
         (fn         (%spirv-get-or-create-fn module fn-name (llvm-void-type) param-types 2))
         (args       (cffi:foreign-alloc 'llvm-value-ref :count 2)))
    (setf (cffi:mem-aref args 'llvm-value-ref 0) dst-ptr)
    (setf (cffi:mem-aref args 'llvm-value-ref 1) src-ptr)
    (llvm-build-call2 builder fn-type fn args 2 "")))

(defun %gen-nvvm-cp-async-commit-group (builder module)
  "Emits @llvm.nvvm.cp.async.commit.group()."
  (let* ((fn-name  "llvm.nvvm.cp.async.commit.group")
         (fn-type  (llvm-function-type (llvm-void-type) (cffi:null-pointer) 0 nil))
         (fn       (%spirv-get-or-create-fn module fn-name (llvm-void-type)
                                            (cffi:null-pointer) 0)))
    (llvm-build-call2 builder fn-type fn (cffi:null-pointer) 0 "")))

(defun %gen-nvvm-cp-async-wait-group (builder module)
  "Emits @llvm.nvvm.cp.async.wait.group(i32 0).  i32 must be an immarg."
  (let* ((fn-name    "llvm.nvvm.cp.async.wait.group")
         (i32-type   (llvm-int32-type))
         (param-types (let ((arr (cffi:foreign-alloc 'llvm-type-ref :count 1)))
                        (setf (cffi:mem-aref arr 'llvm-type-ref 0) i32-type)
                        arr))
         (fn-type    (llvm-function-type (llvm-void-type) param-types 1 nil))
         (fn         (%spirv-get-or-create-fn module fn-name (llvm-void-type) param-types 1))
         (args       (cffi:foreign-alloc 'llvm-value-ref :count 1)))
    (setf (cffi:mem-aref args 'llvm-value-ref 0)
          (llvm-const-int i32-type 0 nil))   ;; wait for all groups
    (llvm-build-call2 builder fn-type fn args 1 "")))

(defun %gen-nvvm-read-tid-x (builder module)
  "Emits @llvm.nvvm.read.ptx.sreg.tid.x() → i32 (per-thread tid in X)."
  (let* ((fn-name  "llvm.nvvm.read.ptx.sreg.tid.x")
         (i32-type (llvm-int32-type))
         (fn-type  (llvm-function-type i32-type (cffi:null-pointer) 0 nil))
         (fn       (%spirv-get-or-create-fn module fn-name i32-type
                                            (cffi:null-pointer) 0)))
    (llvm-build-call2 builder fn-type fn (cffi:null-pointer) 0 "tid_x")))


;; src/codegen.lisp — generate-node-ir methods for the two new semantic nodes.

(defun %vector-elem-type (tile-type-spec)
  "Returns the element type symbol from a (vector ELEM ...) or (tensor
   ELEM ...) type spec, walking through aliases."
  (let* ((resolved (resolve-type-alias tile-type-spec))
         (canon    (canonicalize-type-specifier resolved)))
    (cond
     ((and (listp canon) (>= (length canon) 2)
           (symbolp (first canon))
           (or (string-equal (symbol-name (first canon)) "VECTOR")
               (string-equal (symbol-name (first canon)) "TENSOR")))
      (second canon))
     (t (error "%vector-elem-type: can't extract element type from ~S" canon)))))

(defmethod generate-node-ir ((node semantic-nvvm-cp-async-tile-copy) builder module var-env
                              di-builder di-scope location-map)
  "Phase B.1 NVPTX: emit per-thread cp.async.ca.shared.global +
   cp.async.commit.group.  Assumes tile.length == workgroup_size so
   each thread copies exactly one element (no inner loop).  Returns
   the phantom ulong 0 for the surrounding let-binding."
  (let* ((src-node     (semantic-nvvm-cp-async-tile-copy-src-node node))
         (tile-node    (semantic-nvvm-cp-async-tile-copy-tile-node node))
         (origin-nodes (semantic-nvvm-cp-async-tile-copy-origin-nodes node))
         (origin-node  (first origin-nodes))
         (src-val      (generate-node-ir src-node builder module var-env
                                         di-builder di-scope location-map))
         (tile-val     (generate-node-ir tile-node builder module var-env
                                         di-builder di-scope location-map))
         (origin-raw   (generate-node-ir origin-node builder module var-env
                                         di-builder di-scope location-map))
         (elem-type    (%vector-elem-type (semantic-node-type tile-node)))
         (elem-bytes   (case elem-type
                         ((int uint float) 4)
                         ((long ulong double) 8)
                         (t (error "nvvm cp.async: unsupported element type ~S (need 4 or 8 bytes)"
                                   elem-type))))
         ;; Extract base ptrs from the tensor struct values.
         (src-parent   (llvm-build-extract-value builder src-val 0 "src_parent"))
         (src-base     (llvm-build-extract-value builder src-parent 0 "src_base"))
         (tile-parent  (llvm-build-extract-value builder tile-val 0 "tile_parent"))
         (tile-base    (llvm-build-extract-value builder tile-parent 0 "tile_base"))
         (i32-type     (llvm-int32-type))
         (i64-type     (llvm-int64-type))
         (elem-bytes-v (llvm-const-int i64-type elem-bytes nil))
         ;; tid (per-thread index in X dim).
         (tid-i32      (%gen-nvvm-read-tid-x builder module))
         (tid-i64      (llvm-build-sext builder tid-i32 i64-type "tid_i64"))
         ;; Origin is the global problem-space start.  Coerce to i64.
         (origin-i64   (llvm-build-sext builder origin-raw i64-type "origin_i64"))
         ;; src-elt = src-base + (origin + tid) * elem-bytes
         (src-flat     (llvm-build-add builder origin-i64 tid-i64 "src_flat"))
         (src-byte-off (llvm-build-mul builder src-flat elem-bytes-v "src_byte_off"))
         (src-elt-ptr  (let ((indices (cffi:foreign-alloc :pointer :count 1)))
                         (setf (cffi:mem-aref indices :pointer 0) src-byte-off)
                         (llvm-build-in-bounds-gep2
                          builder (llvm-int8-type) src-base indices 1 "src_elt_ptr")))
         ;; tile-elt = tile-base + tid * elem-bytes
         (tile-byte-off (llvm-build-mul builder tid-i64 elem-bytes-v "tile_byte_off"))
         (tile-elt-ptr  (let ((indices (cffi:foreign-alloc :pointer :count 1)))
                          (setf (cffi:mem-aref indices :pointer 0) tile-byte-off)
                          (llvm-build-in-bounds-gep2
                           builder (llvm-int8-type) tile-base indices 1 "tile_elt_ptr"))))
    (declare (ignore i32-type))
    (%gen-nvvm-cp-async-elem builder module tile-elt-ptr src-elt-ptr elem-bytes)
    (%gen-nvvm-cp-async-commit-group builder module)
    (values (llvm-const-int i64-type 0 nil) nil)))

(defmethod generate-node-ir ((node semantic-nvvm-cp-async-wait) builder module var-env
                              di-builder di-scope location-map)
  "Phase B.1 NVPTX: emit cp.async.wait.group(0)."
  (declare (ignore var-env di-builder di-scope location-map))
  (%gen-nvvm-cp-async-wait-group builder module)
  (values (llvm-const-int (llvm-int64-type) 0 nil) nil))


;; src/analysis/core.lisp — extend semantic-node-type / semantic-node-source-location
;; for the two new semantic node types.  Whole-function redefine.

(defun semantic-node-type (node)
  "Returns the Crisp type of a semantic node.
   Extended for 092-dotimes and 114 Phase B (semantic-nvvm-cp-async-*)."
  (etypecase node
    (semantic-dotimes (semantic-dotimes-type node))
    (semantic-literal (semantic-literal-value-type node))
    (semantic-device-vec-literal (semantic-device-vec-literal-vec-type node))
    (semantic-var-read (semantic-var-read-type node))
    (semantic-add (semantic-add-type node))
    (semantic-sub (semantic-sub-type node))
    (semantic-mul (semantic-mul-type node))
    (semantic-div (semantic-div-type node))
    (semantic-sin (semantic-sin-type node))
    (semantic-cos (semantic-cos-type node))
    (semantic-lt 'int)
    (semantic-gt 'int)
    (semantic-le 'int)
    (semantic-ge 'int)
    (semantic-eq 'int)
    (semantic-neq 'int)
    (semantic-if (semantic-if-type node))
    (semantic-set! 'void)
    (semantic-aref (semantic-aref-type node))
    (semantic-value-cast (semantic-value-cast-type node))
    (semantic-let (semantic-let-type node))
    (semantic-bitcast (semantic-bitcast-type node))
    (semantic-fp-truncate-cast (semantic-fp-truncate-cast-type node))
    (semantic-truncate (semantic-truncate-type node))
    (semantic-explicit-return (semantic-explicit-return-type node))
    (semantic-call (semantic-call-type node))
    (semantic-funcall (semantic-funcall-type node))
    (semantic-extract-value (semantic-extract-value-type node))
    (semantic-insert-value (semantic-insert-value-type node))
    (semantic-struct-construction (semantic-struct-construction-type node))
    (semantic-ct-array (semantic-ct-array-type node))
    (semantic-progn (semantic-progn-type node))
    (semantic-struct-member-update (semantic-struct-member-update-type node))
    (semantic-sizeof (semantic-sizeof-type node))
    (semantic-make-view (semantic-make-view-type node))
    (semantic-atomic-rmw (semantic-atomic-rmw-type node))
    (semantic-stride-view (semantic-stride-view-type node))
    (semantic-gpu-builtin (semantic-gpu-builtin-type node))
    (semantic-nvvm-cp-async-tile-copy (semantic-nvvm-cp-async-tile-copy-type node))
    (semantic-nvvm-cp-async-wait      (semantic-nvvm-cp-async-wait-type node))))

(defun semantic-node-source-location (node)
  "Returns the source location of a semantic node.
   Extended for 092-dotimes and 114 Phase B."
  (etypecase node
    (semantic-dotimes (semantic-dotimes-source-location node))
    (semantic-literal (semantic-literal-source-location node))
    (semantic-device-vec-literal (semantic-device-vec-literal-source-location node))
    (semantic-var-read (semantic-var-read-source-location node))
    (semantic-value-cast (semantic-value-cast-source-location node))
    (semantic-bitcast (semantic-bitcast-source-location node))
    (semantic-let (semantic-let-source-location node))
    (semantic-fp-truncate-cast (semantic-fp-truncate-cast-source-location node))
    (semantic-truncate (semantic-truncate-source-location node))
    (semantic-add (semantic-add-source-location node))
    (semantic-sub (semantic-sub-source-location node))
    (semantic-mul (semantic-mul-source-location node))
    (semantic-div (semantic-div-source-location node))
    (semantic-sin (semantic-sin-source-location node))
    (semantic-cos (semantic-cos-source-location node))
    (semantic-lt (semantic-lt-source-location node))
    (semantic-gt (semantic-gt-source-location node))
    (semantic-le (semantic-le-source-location node))
    (semantic-ge (semantic-ge-source-location node))
    (semantic-eq (semantic-eq-source-location node))
    (semantic-neq (semantic-neq-source-location node))
    (semantic-if (semantic-if-source-location node))
    (semantic-set! (semantic-set!-source-location node))
    (semantic-aref (semantic-aref-source-location node))
    (semantic-explicit-return (semantic-explicit-return-source-location node))
    (semantic-call (semantic-call-source-location node))
    (semantic-funcall (semantic-funcall-source-location node))
    (semantic-extract-value (semantic-extract-value-source-location node))
    (semantic-insert-value (semantic-insert-value-source-location node))
    (semantic-struct-construction (semantic-struct-construction-source-location node))
    (semantic-ct-array (semantic-ct-array-source-location node))
    (semantic-progn (semantic-progn-source-location node))
    (semantic-struct-member-update (semantic-struct-member-update-source-location node))
    (semantic-sizeof (semantic-sizeof-source-location node))
    (semantic-make-view (semantic-make-view-source-location node))
    (semantic-atomic-rmw (semantic-atomic-rmw-source-location node))
    (semantic-stride-view (semantic-stride-view-source-location node))
    (semantic-gpu-builtin (semantic-gpu-builtin-source-location node))
    (semantic-nvvm-cp-async-tile-copy (semantic-nvvm-cp-async-tile-copy-source-location node))
    (semantic-nvvm-cp-async-wait      (semantic-nvvm-cp-async-wait-source-location node))))


;; src/analysis/control.lisp — analyzer dispatch on *target-backend*.

(defun analyze-request-load-tile-coords-expression (expr env context location)
  "114 Phase B: emit semantic-nvvm-cp-async-tile-copy on :ptx target;
   fall back to sync expansion elsewhere (including :spirv, which is
   blocked — see 114 Phase A notes)."
  (%tlc-check-not-divergent "request-load-tile-coords" location)
  (case *target-backend*
    (:ptx
     (let* ((src-form    (second expr))
            (tile-form   (third expr))
            (origin-list (fourth expr))
            (src-node    (analyze-expression src-form env context (append location '(1))))
            (tile-node   (analyze-expression tile-form env context (append location '(2))))
            (origin-nodes (loop for o in origin-list for i from 0
                                collect (analyze-expression
                                         o env context
                                         (append location (list 3 i))))))
       (make-semantic-nvvm-cp-async-tile-copy
        :src-node     src-node
        :tile-node    tile-node
        :origin-nodes origin-nodes
        :type         'ulong
        :source-location location)))
    (t
     (analyze-expression (%expand-request-load-tile-coords-form expr location)
                         env context location))))

(defun analyze-await-request-expression (expr env context location)
  "114 Phase B: emit semantic-nvvm-cp-async-wait on :ptx; no-op fallback elsewhere."
  (unless (= (length expr) 2)
    (error 'crisp-compiler-error
           :message (format nil "await-request: expected (await-request TOKEN), got ~S" expr)
           :source-location location))
  (case *target-backend*
    (:ptx
     (make-semantic-nvvm-cp-async-wait
      :type 'ulong
      :source-location location))
    (t
     (analyze-expression
      (list (intern "TO-ULONG" (find-package :crisp-language)) 0)
      env context location))))
