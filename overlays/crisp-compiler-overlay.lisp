;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;; src/codegen.lisp
;; Fix: semantic-struct-member-update codegen — cast the new value to the field's
;; LLVM type when they differ (e.g. i32 literal into a ulong/i64 field).
;; Root cause: (set! (offset~ c) 2) — literal 2 is int/i32, but offset field is ulong/i64.
;; llvm-build-insert-value requires exact type match; we must zext/trunc as appropriate.
(defmethod generate-node-ir ((node semantic-struct-member-update) builder module var-env di-builder di-scope location-map)
  "Generates IR for updating a struct member: inserts value into struct and returns new struct.
   Casts the new value to match the field's LLVM type if they differ (e.g. i32 -> i64)."
  (let* ((struct-node  (semantic-struct-member-update-struct-node node))
         (member-index (semantic-struct-member-update-member-index node))
         (value-node   (semantic-struct-member-update-value-node node))
         ;; Generate the ORIGINAL struct value (load it)
         (struct-val (generate-node-ir struct-node builder module var-env di-builder di-scope location-map))
         ;; Generate the NEW member value
         (new-member-val-raw (generate-node-ir value-node builder module var-env di-builder di-scope location-map))
         (new-member-val (extract-primary-value builder new-member-val-raw (semantic-node-type value-node)))
         ;; Determine expected field LLVM type by extracting the existing member
         (existing-member (crisp.llvm-bindings:llvm-build-extract-value builder struct-val member-index "existing_field"))
         (expected-type   (crisp.llvm-bindings:llvm-type-of existing-member))
         (actual-type     (crisp.llvm-bindings:llvm-type-of new-member-val))
         ;; Cast if both are integers of different widths
         (cast-val
          (let ((expected-kind (crisp.llvm-bindings:llvm-get-type-kind expected-type))
                (actual-kind   (crisp.llvm-bindings:llvm-get-type-kind actual-type)))
            ;; Integer type kind = 8 in LLVM
            (if (and (= expected-kind 8) (= actual-kind 8))
                (let ((expected-width (crisp.llvm-bindings::llvm-get-int-type-width expected-type))
                      (actual-width   (crisp.llvm-bindings::llvm-get-int-type-width actual-type)))
                  (cond
                   ((= expected-width actual-width) new-member-val)
                   ((> expected-width actual-width)
                    (log:debug "struct-member-update: zext from ~a to ~a bits at index ~a" actual-width expected-width member-index)
                    (crisp.llvm-bindings:llvm-build-zext builder new-member-val expected-type "field_cast"))
                   (t
                    (log:debug "struct-member-update: trunc from ~a to ~a bits at index ~a" actual-width expected-width member-index)
                    (crisp.llvm-bindings:llvm-build-trunc builder new-member-val expected-type "field_cast"))))
                ;; Non-integer types: use as-is (pointer/float fields shouldn't need casting here)
                new-member-val)))
         ;; Insert the (possibly cast) value
         (new-struct-val (crisp.llvm-bindings:llvm-build-insert-value builder struct-val cast-val member-index "struct_update")))

    ;; Runtime bounds check: when *runtime-checks-enabled*, verify the new value doesn't
    ;; exceed the storage capacity.
    ;;   CELL,   member-index=1 (offset, bytes): cast-val < extractvalue(parent, 1)
    ;;   TENSOR, member-index=4 (length, elems): cast-val * sizeof(elem) <= extractvalue(parent, 1)
    (when *runtime-checks-enabled*
      (let* ((struct-type (semantic-struct-member-update-type node))
             (resolved-type (if (symbolp struct-type)
                                (unmangle-template-struct-name struct-type)
                                struct-type))
             (sh-head (when (and (consp resolved-type) (symbolp (first resolved-type)))
                        (first resolved-type)))
             (is-cell   (and sh-head (string-equal (symbol-name sh-head) "CELL")))
             (is-tensor (and sh-head (not is-cell)
                             (member (symbol-name sh-head) '("TENSOR" "VECTOR" "MATRIX")
                                     :test #'string-equal)))
             ;; Only check cell-offset (index 1) and tensor-length (index 4)
             (should-check (or (and is-cell   (= member-index 1))
                               (and is-tensor (= member-index 4)))))
        (when should-check
          (let* (;; Extract parent storage byte-capacity: extractvalue(extractvalue(struct_val,0),1)
                 (parent-val    (llvm-build-extract-value builder struct-val 0 "rt_parent"))
                 (storage-bytes (llvm-build-extract-value builder parent-val 1 "rt_capacity"))
                 ;; For cell offset (bytes): compare cast-val < storage-bytes  [strict less-than]
                 ;; For tensor length (elems): compare cast-val*sizeof(elem) <= storage-bytes
                 (check-lhs
                  (if is-cell
                      cast-val
                      (let* ((elem-type-sym (second resolved-type))
                             (elem-llvm-t   (crisp-type-to-llvm-type elem-type-sym module))
                             (elem-size     (llvm-size-of elem-llvm-t)))
                        (llvm-build-mul builder cast-val elem-size "rt_total_bytes"))))
                 (pred  (if is-cell +llvm-int-ult+ +llvm-int-ule+))
                 (cmp   (llvm-build-icmp builder pred check-lhs storage-bytes "rt_bounds_ok"))
                 (curr-fn    (llvm-get-basic-block-parent (llvm-get-insert-block builder)))
                 (trap-block (llvm-append-basic-block curr-fn "rt_trap"))
                 (ok-block   (llvm-append-basic-block curr-fn "rt_ok")))
            ;; cmp=true means in-bounds → go to ok; false means OOB → go to trap
            (llvm-build-cond-br builder cmp ok-block trap-block)
            ;; Trap block: call llvm.trap then fall through (unreachable in practice)
            (llvm-position-builder-at-end builder trap-block)
            (%handle-die-intrinsic builder module)
            (llvm-build-br builder ok-block)
            ;; Resume in ok block
            (llvm-position-builder-at-end builder ok-block)
            (log:debug "rt-bounds-check emitted: ~a member-index=~a" sh-head member-index)))))

    (values new-struct-val nil)))


;; src/codegen.lisp
;; Add runtime bounds check to make-cell / make-vector / make-matrix / make-tensor.
;; When *runtime-checks-enabled*, verifies that the requested view fits within the
;; source storage: (offset_bytes + view_bytes) <= src_bytesize.
;; This implements the assertion mentioned in 078/21-runtime-checks.crisp.
(defmethod generate-node-ir ((node semantic-make-view)
                               builder module var-env
                               di-builder di-scope location-map)
  "Generates IR for make-cell / make-vector / make-matrix / make-tensor.
   Extended: emits a bounds-check (llvm.trap) when *runtime-checks-enabled* is T."
  (cl:let* ((result-type   (semantic-make-view-type node))
             (src-node      (semantic-make-view-source-node node))
             (elem-type-sym (semantic-make-view-element-type node))
             (rank          (semantic-make-view-rank node))
             (offset-elems  (or (semantic-make-view-offset node) 0))
             (explicit-len  (semantic-make-view-length node))
             (extents       (semantic-make-view-extents node))
             (strides       (semantic-make-view-strides node))

             (src-val (generate-node-ir src-node builder module var-env
                                        di-builder di-scope location-map))

             (src-parent   (llvm-build-extract-value builder src-val 0 "mv_src_parent"))
             (src-ptr      (llvm-build-extract-value builder src-parent 0 "mv_src_ptr"))
             (src-bytesize (llvm-build-extract-value builder src-parent 1 "mv_src_bs"))

             (elem-llvm-type (crisp-type-to-llvm-type elem-type-sym module))
             (elem-size      (llvm-size-of elem-llvm-type))

             (offset-bytes
              (if (zerop offset-elems)
                  (llvm-const-int (llvm-int64-type) 0 nil)
                  (llvm-build-mul builder
                                  (llvm-const-int (llvm-int64-type) offset-elems nil)
                                  elem-size "mv_off_bytes")))
             (new-ptr
              (if (zerop offset-elems)
                  src-ptr
                  (%mv-bump-ptr builder src-ptr offset-bytes
                                (%mv-source-addr (list (cl:first result-type) nil
                                                       (cl:third result-type))))))
             (new-bytesize
              (if (zerop offset-elems)
                  src-bytesize
                  (llvm-build-sub builder src-bytesize offset-bytes "mv_new_bs")))

             (addr-space (cond ((string-equal (symbol-name (cl:first result-type)) "CELL")
                                (cl:third result-type))
                               (t (cl:fourth result-type))))

             (new-storage (%mv-build-storage builder module addr-space
                                             src-parent new-ptr new-bytesize))

             (mangled-name (mangle-template-struct-name (cl:first result-type)
                                                        (cl:rest result-type)))
             (result-struct-type (ensure-struct-llvm-type mangled-name))
             (result-undef (llvm-get-undef result-struct-type)))

    (log:info "make-view: op=~a rank=~d elem=~a mangled=~a offset=~d"
              (cl:first result-type) rank elem-type-sym mangled-name offset-elems)

    ;; Runtime bounds check: verify (offset_bytes + view_bytes) <= src_bytesize.
    ;; view_bytes = len_elems * sizeof(elem):
    ;;   make-cell: 1 element
    ;;   make-vector/matrix/tensor with explicit-len: that count
    ;;   auto-length: 1 element (just verify offset fits)
    (when *runtime-checks-enabled*
      (let* ((len-elems (cond ((= rank 0) 1)
                              (explicit-len explicit-len)
                              (t 1)))
             (len-bytes    (llvm-build-mul builder
                                           (llvm-const-int (llvm-int64-type) len-elems nil)
                                           elem-size "mv_len_bytes"))
             (required     (llvm-build-add builder offset-bytes len-bytes "mv_required"))
             (cmp          (llvm-build-icmp builder +llvm-int-ule+
                                            required src-bytesize "mv_bounds_ok"))
             (curr-fn      (llvm-get-basic-block-parent (llvm-get-insert-block builder)))
             (trap-block   (llvm-append-basic-block curr-fn "mv_trap"))
             (ok-block     (llvm-append-basic-block curr-fn "mv_ok")))
        (llvm-build-cond-br builder cmp ok-block trap-block)
        (llvm-position-builder-at-end builder trap-block)
        (%handle-die-intrinsic builder module)
        (llvm-build-br builder ok-block)
        (llvm-position-builder-at-end builder ok-block)
        (log:debug "make-view rt-bounds-check emitted: rank=~a offset=~a len=~a"
                   rank offset-elems len-elems)))

    (cond

     ;; ── cell (rank=0): { STORAGE, byte-offset-i64 } ──────────────────
     ((= rank 0)
      (cl:let* ((orig-storage (%mv-build-storage builder module addr-space
                                                 src-parent src-ptr src-bytesize))
                (byte-offset-val
                 (if (zerop offset-elems)
                     (llvm-const-int (llvm-int64-type) 0 nil)
                     (llvm-build-mul builder
                                     (llvm-const-int (llvm-int64-type) offset-elems nil)
                                     elem-size "mv_cell_off_bytes")))
                (c0 (llvm-build-insert-value builder result-undef orig-storage 0 "mv_cell_parent"))
                (c1 (llvm-build-insert-value builder c0 byte-offset-val 1 "mv_cell_offset")))
        c1))

     ;; ── tensor/vector/matrix (rank>=1) ────────────────────────────────
     (t
      (cl:let* ((zero-offsets (%mv-build-zero-i64-array rank))
                (stride-vals (or strides (%mv-row-major-strides (or extents (make-list rank :initial-element 1)))))
                (stride-arr  (%mv-build-const-i64-array builder rank stride-vals))
                (extent-vals (or extents (make-list rank :initial-element 0)))
                (extent-arr  (%mv-build-const-i64-array builder rank extent-vals))
                (length-val
                 (if explicit-len
                     (llvm-const-int (llvm-int64-type) explicit-len nil)
                     (llvm-build-udiv builder new-bytesize elem-size "mv_auto_len")))
                (t0 (llvm-build-insert-value builder result-undef new-storage  0 "mv_t_parent"))
                (t1 (llvm-build-insert-value builder t0 zero-offsets  1 "mv_t_offsets"))
                (t2 (llvm-build-insert-value builder t1 stride-arr    2 "mv_t_strides"))
                (t3 (llvm-build-insert-value builder t2 extent-arr    3 "mv_t_extents"))
                (t4 (llvm-build-insert-value builder t3 length-val    4 "mv_t_length")))
        t4)))))

