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
    (values new-struct-val nil)))

