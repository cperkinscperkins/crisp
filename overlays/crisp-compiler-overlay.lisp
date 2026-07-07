;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins
;;;;
;;;; (Empty — Endeavor 130's hardware-profile logic graduated to
;;;;  src/hardware-profile.lisp.  Append new in-progress definitions here.)

(in-package :crisp.compiler)

;;; ===================================================================
;;; Endeavor 133 (MMA on SPV) — cooperative-matrix codegen emitters.
;;;
;;; Derived from the validated IR contract (put_temp_files_here/coop*.ll round-trips):
;;;   type   target("spirv.CooperativeMatrixKHR", <elem>, 3, <rows>, <cols>, <use>)
;;;   fill   %acc = __spirv_CompositeConstruct(<init scalar>)
;;;   load   %m   = __spirv_CooperativeMatrixLoadKHR_<suffix>(ptr as(1), i32 layout, i64 stride, i32 0)
;;;   mma    %d   = __spirv_CooperativeMatrixMulAddKHR(%a, %b, %c, i32 0)
;;;   store        __spirv_CooperativeMatrixStoreKHR(ptr as(1), %m, i32 layout, i64 stride, i32 0)
;;; use: 0=A 1=B 2=Accumulator ; scope 3=Subgroup ; layout 0=RowMajor 1=ColMajor.
;;; ===================================================================

(defun %coop-type (module elem-llvm rows cols use)
  "Build target(\"spirv.CooperativeMatrixKHR\", ELEM-LLVM, 3, ROWS, COLS, USE)."
  (let ((ctx (crisp.llvm-bindings::llvm-get-module-context module)))
    (cffi:with-foreign-objects ((tps :pointer 1) (ips :unsigned-int 4))
      (setf (cffi:mem-aref tps :pointer 0) elem-llvm
            (cffi:mem-aref ips :unsigned-int 0) 3          ; Subgroup scope
            (cffi:mem-aref ips :unsigned-int 1) rows
            (cffi:mem-aref ips :unsigned-int 2) cols
            (cffi:mem-aref ips :unsigned-int 3) use)
      (crisp.llvm-bindings::llvm-target-ext-type-in-context
       ctx "spirv.CooperativeMatrixKHR" tps 1 ips 4))))

(defun %coop-call (builder module name ret-type param-types arg-vals)
  "Declare (once) NAME : RET-TYPE(PARAM-TYPES…) and build a call with ARG-VALS."
  (let ((np (length param-types)) (na (length arg-vals)))
    (cffi:with-foreign-objects ((ptypes :pointer (max 1 np)) (args :pointer (max 1 na)))
      (loop for i from 0 for ty in param-types do (setf (cffi:mem-aref ptypes :pointer i) ty))
      (loop for i from 0 for v in arg-vals do (setf (cffi:mem-aref args :pointer i) v))
      (let* ((fnty (crisp.llvm-bindings::llvm-function-type ret-type ptypes np nil))
             (existing (crisp.llvm-bindings::llvm-get-named-function module name))
             (fn (if (cffi:null-pointer-p existing)
                     (crisp.llvm-bindings::llvm-add-function module name fnty)
                     existing)))
        (crisp.llvm-bindings::llvm-build-call2 builder fnty fn args na "")))))

(defun %coop-ptr-type ()
  "ptr addrspace(1) — global-memory pointer for coop load/store."
  (crisp.llvm-bindings::llvm-pointer-type (crisp.llvm-bindings::llvm-int8-type) 1))

(defun %coop-fill (builder module init-val elem-llvm rows cols use)
  "Construct a coop matrix filled with INIT-VAL (scalar) via __spirv_CompositeConstruct."
  (%coop-call builder module
              (format nil "__spirv_CompositeConstruct_~d_~d_~d" use rows cols)
              (%coop-type module elem-llvm rows cols use)
              (list elem-llvm) (list init-val)))

(defun %coop-load (builder module ptr stride-val elem-llvm rows cols use layout)
  "Emit CooperativeMatrixLoadKHR(PTR, LAYOUT, STRIDE, 0) -> coop(elem,rows,cols,use).
   STRIDE-VAL is an i64 LLVM value (leading dimension in elements)."
  (let ((i32 (crisp.llvm-bindings::llvm-int32-type))
        (i64 (crisp.llvm-bindings::llvm-int64-type)))
    (%coop-call builder module
                (format nil "__spirv_CooperativeMatrixLoadKHR_~d_~d_~d" use rows cols)
                (%coop-type module elem-llvm rows cols use)
                (list (%coop-ptr-type) i32 i64 i32)
                (list ptr
                      (crisp.llvm-bindings::llvm-const-int i32 layout nil)
                      stride-val
                      (crisp.llvm-bindings::llvm-const-int i32 0 nil)))))

(defun %coop-mma (builder module a-val b-val c-val elem-llvm m n k)
  "Emit CooperativeMatrixMulAddKHR(A, B, C, 0) -> the MxN accumulator coop matrix."
  (let* ((a-ty (%coop-type module elem-llvm m k 0))
         (b-ty (%coop-type module elem-llvm k n 1))
         (c-ty (%coop-type module elem-llvm m n 2))
         (i32  (crisp.llvm-bindings::llvm-int32-type)))
    (%coop-call builder module "__spirv_CooperativeMatrixMulAddKHR"
                c-ty (list a-ty b-ty c-ty i32)
                (list a-val b-val c-val (crisp.llvm-bindings::llvm-const-int i32 0 nil)))))

(defun %coop-store (builder module ptr matrix-val stride-val elem-llvm rows cols use layout)
  "Emit CooperativeMatrixStoreKHR(PTR, MATRIX, LAYOUT, STRIDE, 0)."
  (let ((i32 (crisp.llvm-bindings::llvm-int32-type))
        (i64 (crisp.llvm-bindings::llvm-int64-type)))
    (%coop-call builder module "__spirv_CooperativeMatrixStoreKHR"
                (crisp.llvm-bindings::llvm-void-type)
                (list (%coop-ptr-type) (%coop-type module elem-llvm rows cols use) i32 i64 i32)
                (list ptr matrix-val
                      (crisp.llvm-bindings::llvm-const-int i32 layout nil)
                      stride-val
                      (crisp.llvm-bindings::llvm-const-int i32 0 nil)))))

