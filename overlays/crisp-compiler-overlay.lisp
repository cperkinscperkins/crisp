;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)


;; ======================================================================
;; Endeavor 114 Phase A — SPV native async tile copy (__spirv_GroupAsyncCopy)
;; ======================================================================
;;
;; Replaces 113's fallback-to-sync lowering when *target-backend* is
;; :spirv with a real call to __spirv_GroupAsyncCopy + __spirv_GroupWaitEvents,
;; which the LLVM-SPIRV translator (22.0.0-git) lowers to the native
;; OpGroupAsyncCopy / OpGroupWaitEvents SPIR-V opcodes.  Empirically
;; validated by hand-crafted IR roundtrip in Phase 0 research.
;;
;; The "phantom token" design carries over from 113: the source-level
;; `(let ((tok (request-load-tile-coords ...))) (await-request tok))`
;; let-binding has no runtime carrier.  Internally the codegen
;; allocates a single per-kernel ptr slot to hold the event handle;
;; request-* writes to it, await-* reads from it.  Single-outstanding
;; is implicit (one slot per function); multi-outstanding lands later.


;; src/codegen.lisp
;;
;; Per-function event slot map.  Keyed on the LLVM function pointer's
;; address (a fixnum), value is the LLVM alloca'd slot ptr.  Cleared per
;; compile in INITIALIZE-COMPILER... actually keep it process-lifetime
;; (stale entries are keyed on now-dead function ptrs and are harmless
;; until SBCL grows them too large; reset on rebuild).

(defvar *spirv-async-event-slot-map* (make-hash-table :test 'eql)
  "Per-function event slot lookup for request-load-tile-coords / await-request.
   Keys are (CFFI:POINTER-ADDRESS llvm-function-value); values are the alloca'd
   ptr slot the event handle gets stashed into.  Phase A single-outstanding:
   one slot per function.")

(defun %get-or-allocate-spirv-event-slot (builder)
  "Returns (and lazily allocates) the per-function event slot for the
   function containing BUILDER's current insert block.  The slot is an
   alloca'd `ptr` (addrspace 0) — the type that __spirv_GroupAsyncCopy
   returns and __spirv_GroupWaitEvents reads back."
  (let* ((block (llvm-get-insert-block builder))
         (fn    (llvm-get-basic-block-parent block))
         (key   (cffi:pointer-address fn))
         (slot  (gethash key *spirv-async-event-slot-map*)))
    (or slot
        (let ((new-slot (llvm-build-alloca
                         builder
                         (llvm-pointer-type
                          (llvm-int8-type) 0)
                         "async_evt_slot")))
          (setf (gethash key *spirv-async-event-slot-map*) new-slot)
          new-slot))))

(defun %ocl-elem-mangle (elem-type-spec)
  "Returns the Itanium C++ mangling letter for an OpenCL element type.
   Used to build the per-element-type async_work_group_copy mangled name."
  (case elem-type-spec
    ((char)   "c")
    ((uchar)  "h")
    ((short)  "s")
    ((ushort) "t")
    ((int)    "i")
    ((uint)   "j")
    ((long)   "l")
    ((ulong)  "m")
    ((float)  "f")
    ((double) "d")
    (t (error "%ocl-elem-mangle: no Itanium mangling for ~S" elem-type-spec))))

(defun %ocl-async-work-group-copy-mangled-name (elem-type-spec)
  "Builds the mangled OpenCL builtin name for async_work_group_copy with
   ELEM-TYPE-SPEC element type, LOAD direction (local <- global).
   Format:
     _Z21async_work_group_copyPU3AS3<E>PU3AS1K<E>j9ocl_event
   where <E> is the element-type mangle letter (m for ulong, f for float, etc.).
   Confirmed by smoke test (scripts/l0-load-smoke.lisp) that IGC's BiF
   module resolves this against its internal builtins library at SPV
   load time — unlike the direct __spirv_GroupAsyncCopy form, which
   translates cleanly but fails IGC linkage."
  (let ((e (%ocl-elem-mangle elem-type-spec)))
    (format nil "_Z21async_work_group_copyPU3AS3~APU3AS1K~Aj9ocl_event" e e)))

(defun %gen-spirv-group-async-copy (builder module elem-type-spec dst-ptr src-ptr count-i32)
  "Emits the per-element-type mangled async_work_group_copy(dst<local>,
   src<global>, count, prev=null) call.  Returns the event handle."
  (let* ((i32-type   (llvm-int32-type))
         (i8-type    (llvm-int8-type))
         (ptr-as3    (llvm-pointer-type i8-type 3))
         (ptr-as1    (llvm-pointer-type i8-type 1))
         (ptr-as0    (llvm-pointer-type i8-type 0))
         (fn-name    (%ocl-async-work-group-copy-mangled-name elem-type-spec))
         (param-types (let ((arr (cffi:foreign-alloc 'llvm-type-ref :count 4)))
                        (setf (cffi:mem-aref arr 'llvm-type-ref 0) ptr-as3)
                        (setf (cffi:mem-aref arr 'llvm-type-ref 1) ptr-as1)
                        (setf (cffi:mem-aref arr 'llvm-type-ref 2) i32-type)
                        (setf (cffi:mem-aref arr 'llvm-type-ref 3) ptr-as0)
                        arr))
         (fn-type    (llvm-function-type ptr-as0 param-types 4 nil))
         (fn         (%spirv-get-or-create-fn module fn-name ptr-as0 param-types 4))
         (args       (cffi:foreign-alloc 'llvm-value-ref :count 4)))
    (declare (ignore module))
    (setf (cffi:mem-aref args 'llvm-value-ref 0) dst-ptr)
    (setf (cffi:mem-aref args 'llvm-value-ref 1) src-ptr)
    (setf (cffi:mem-aref args 'llvm-value-ref 2) count-i32)
    (setf (cffi:mem-aref args 'llvm-value-ref 3)
          (llvm-const-null ptr-as0))
    (llvm-build-call2 builder fn-type fn args 4 "async_evt")))

(defun %gen-spirv-group-wait-events (builder module event-slot)
  "Emits the mangled wait_group_events(n=1, &event) call.  EVENT-SLOT
   is the alloca'd addrspace(0) ptr that holds the event handle; we
   addrspacecast it to addrspace(4) (generic) for the call."
  (let* ((i32-type   (llvm-int32-type))
         (i8-type    (llvm-int8-type))
         (ptr-as4    (llvm-pointer-type i8-type 4))
         (fn-name    "_Z17wait_group_eventsiPU3AS49ocl_event")
         (slot-as-generic (llvm-build-addrspace-cast
                          builder event-slot ptr-as4 "evt_slot_gen"))
         (param-types (let ((arr (cffi:foreign-alloc 'llvm-type-ref :count 2)))
                        (setf (cffi:mem-aref arr 'llvm-type-ref 0) i32-type)
                        (setf (cffi:mem-aref arr 'llvm-type-ref 1) ptr-as4)
                        arr))
         (fn-type    (llvm-function-type (llvm-void-type) param-types 2 nil))
         (fn         (%spirv-get-or-create-fn module fn-name (llvm-void-type) param-types 2))
         (args       (cffi:foreign-alloc 'llvm-value-ref :count 2)))
    (declare (ignore module))
    (setf (cffi:mem-aref args 'llvm-value-ref 0)
          (llvm-const-int i32-type 1 nil))  ;; n = 1
    (setf (cffi:mem-aref args 'llvm-value-ref 1) slot-as-generic)
    (llvm-build-call2 builder fn-type fn args 2 "")))


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

(defmethod generate-node-ir ((node semantic-spirv-async-tile-copy) builder module var-env
                              di-builder di-scope location-map)
  "Phase A SPV native: emit the per-element-type mangled
   async_work_group_copy(dst<local>, src<global>, count, prev=null) call.
   Stashes the returned event handle in the per-function slot.
   Returns the phantom ulong 0 for the surrounding let-binding."
  (let* ((src-node     (semantic-spirv-async-tile-copy-src-node node))
         (tile-node    (semantic-spirv-async-tile-copy-tile-node node))
         (origin-nodes (semantic-spirv-async-tile-copy-origin-nodes node))
         (origin-node  (first origin-nodes))
         (src-val      (generate-node-ir src-node builder module var-env
                                         di-builder di-scope location-map))
         (tile-val     (generate-node-ir tile-node builder module var-env
                                         di-builder di-scope location-map))
         (origin-raw   (generate-node-ir origin-node builder module var-env
                                         di-builder di-scope location-map))
         (elem-type    (%vector-elem-type (semantic-node-type tile-node)))
         (elem-bytes   (case elem-type
                         ((char uchar) 1)
                         ((short ushort) 2)
                         ((int uint float) 4)
                         ((long ulong double) 8)
                         (t (error "spirv async copy: unsupported element type ~S" elem-type))))
         ;; Extract base ptrs from the tensor struct values.
         (src-parent   (llvm-build-extract-value builder src-val 0 "src_parent"))
         (src-base     (llvm-build-extract-value builder src-parent 0 "src_base"))
         (tile-parent  (llvm-build-extract-value builder tile-val 0 "tile_parent"))
         (tile-base    (llvm-build-extract-value builder tile-parent 0 "tile_base"))
         (i32-type     (llvm-int32-type))
         (i64-type     (llvm-int64-type))
         (elem-bytes-v (llvm-const-int i64-type elem-bytes nil))
         ;; Source base + origin*elem-bytes byte offset.  Origin may be
         ;; int or ulong; sext to i64.
         (origin-i64   (llvm-build-sext builder origin-raw i64-type "origin_i64"))
         (src-byte-off (llvm-build-mul builder origin-i64 elem-bytes-v "src_byte_off"))
         (src-ptr      (let ((indices (cffi:foreign-alloc :pointer :count 1)))
                         (setf (cffi:mem-aref indices :pointer 0) src-byte-off)
                         (llvm-build-in-bounds-gep2
                          builder (llvm-int8-type) src-base indices 1 "src_ptr_off")))
         ;; Count is number of ELEMENTS (OpenCL's size_t = uint32 here).
         (tile-length  (llvm-build-extract-value builder tile-val 4 "tile_length"))
         (count-i32    (llvm-build-trunc builder tile-length i32-type "count_i32"))
         (evt          (%gen-spirv-group-async-copy builder module elem-type
                                                    tile-base src-ptr count-i32))
         (slot         (%get-or-allocate-spirv-event-slot builder)))
    (llvm-build-store builder evt slot)
    (values (llvm-const-int i64-type 0 nil) nil)))

(defmethod generate-node-ir ((node semantic-spirv-await-request) builder module var-env
                              di-builder di-scope location-map)
  "Phase A SPV native: emit __spirv_GroupWaitEvents on the per-function
   event slot.  Returns phantom ulong 0."
  (declare (ignore var-env di-builder di-scope location-map))
  (let ((slot (%get-or-allocate-spirv-event-slot builder)))
    (%gen-spirv-group-wait-events builder module slot)
    (values (llvm-const-int (llvm-int64-type) 0 nil)
            nil)))


;; src/analysis/core.lisp — extend semantic-node-type / semantic-node-source-location
;; etypecase to know about the two new semantic-spirv-* nodes.
;; Whole-function redefine; verbatim from src plus the two new clauses.

(defun semantic-node-type (node)
  "Returns the Crisp type of a semantic node.
Extended for 092-dotimes and 114 (semantic-spirv-async-tile-copy /
semantic-spirv-await-request)."
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
    (semantic-spirv-async-tile-copy (semantic-spirv-async-tile-copy-type node))
    (semantic-spirv-await-request   (semantic-spirv-await-request-type node))))

(defun semantic-node-source-location (node)
  "Returns the source location of a semantic node.
Extended for 092-dotimes and 114 (semantic-spirv-async-tile-copy /
semantic-spirv-await-request)."
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
    (semantic-spirv-async-tile-copy (semantic-spirv-async-tile-copy-source-location node))
    (semantic-spirv-await-request   (semantic-spirv-await-request-source-location node))))


;; src/analysis/control.lisp — analyzers dispatching on *target-backend*.
;; Replaces the 113 Phase 1a fallback-only analyzers.

(defun analyze-request-load-tile-coords-expression (expr env context location)
  "114 Phase A: native SPV codegen on :spirv, fallback to sync elsewhere."
  (%tlc-check-not-divergent "request-load-tile-coords" location)
  (case *target-backend*
    (:spirv
     (let* ((src-form    (second expr))
            (tile-form   (third expr))
            (origin-list (fourth expr))
            (src-node    (analyze-expression src-form env context
                                             (append location '(1))))
            (tile-node   (analyze-expression tile-form env context
                                             (append location '(2))))
            (origin-nodes (loop for o in origin-list for i from 0
                                collect (analyze-expression
                                         o env context
                                         (append location (list 3 i))))))
       (make-semantic-spirv-async-tile-copy
        :src-node     src-node
        :tile-node    tile-node
        :origin-nodes origin-nodes
        :type         'ulong
        :source-location location)))
    (t
     ;; Fallback (sync expansion + phantom token).
     (analyze-expression (%expand-request-load-tile-coords-form expr location)
                         env context location))))

(defun analyze-await-request-expression (expr env context location)
  "114 Phase A: native SPV codegen on :spirv, fallback to no-op elsewhere."
  (unless (= (length expr) 2)
    (error 'crisp-compiler-error
           :message (format nil "await-request: expected (await-request TOKEN), got ~S" expr)
           :source-location location))
  (case *target-backend*
    (:spirv
     ;; The token arg is phantom — codegen consults the per-function
     ;; event slot instead.  The sub-expression isn't analyzed here.
     (make-semantic-spirv-await-request
      :type 'ulong
      :source-location location))
    (t
     (analyze-expression
      (list (intern "TO-ULONG" (find-package :crisp-language)) 0)
      env context location))))
