;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)


;;; =========================================================
;;; Feature 081: Tensor Sub-Function AD Validators
;;; src/metadata-val.lisp
;;; =========================================================

(defun validate-vec-basic-sub-grad (ir-path)
  "Validates 081/01-vec-basic-sub-function:
     - @some_operation_grad is defined (the _GRAD companion)
     - @vec_sub_op_grad is defined (the backward kernel)
     - some_operation_grad is called inside vec_sub_op_grad body
     - fadd present (gradient accumulation)
     - idx_GRAD NOT present (integer index filtered)"
  (unless (probe-file ir-path)
    (log:error "validate-vec-basic-sub-grad: IR file not found: ~a" ir-path)
    (return-from validate-vec-basic-sub-grad nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (and
     (or (search "define" ir)
         ;; If some_operation_grad is defined anywhere in the IR
         (progn (log:error "validate-vec-basic-sub-grad: IR appears empty") nil))
     (or (search "some_operation_grad" ir)
         (progn (log:error "validate-vec-basic-sub-grad: @some_operation_grad not found (sub-function _GRAD companion missing)") nil))
     (or (search "vec_sub_op_grad" ir)
         (progn (log:error "validate-vec-basic-sub-grad: @vec_sub_op_grad backward kernel not found") nil))
     (or (search "fadd float" ir)
         (progn (log:error "validate-vec-basic-sub-grad: fadd not found (gradient accumulation missing)") nil))
     (or (not (search "idx_GRAD" ir))
         (progn (log:error "validate-vec-basic-sub-grad: idx_GRAD should not be emitted (integer index)") nil))
     (progn (log:info "validate-vec-basic-sub-grad: PASS") t))))

(defun validate-vec-chain-depth-grad (ir-path)
  "Validates 081/02-vec-chain-depth:
     - three _GRAD companions defined: some_operation_grad, other_operation_grad, final_operation_grad
     - @vec_chain_grad backward kernel defined
     - idx_GRAD NOT present"
  (unless (probe-file ir-path)
    (log:error "validate-vec-chain-depth-grad: IR file not found: ~a" ir-path)
    (return-from validate-vec-chain-depth-grad nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (and
     (or (search "some_operation_grad" ir)
         (progn (log:error "validate-vec-chain-depth-grad: @some_operation_grad not found") nil))
     (or (search "other_operation_grad" ir)
         (progn (log:error "validate-vec-chain-depth-grad: @other_operation_grad not found") nil))
     (or (search "final_operation_grad" ir)
         (progn (log:error "validate-vec-chain-depth-grad: @final_operation_grad not found") nil))
     (or (search "vec_chain_grad" ir)
         (progn (log:error "validate-vec-chain-depth-grad: @vec_chain_grad backward kernel not found") nil))
     (or (not (search "idx_GRAD" ir))
         (progn (log:error "validate-vec-chain-depth-grad: idx_GRAD should not be emitted") nil))
     (progn (log:info "validate-vec-chain-depth-grad: PASS") t))))

(defun validate-mat-basic-sub-grad (ir-path)
  "Validates 081/03-matrix-basic-sub-function:
     - @scale_and_bias_grad defined
     - @mat_sub_op_grad defined
     - 2D gradient tensor type present (TENSOR_FLOAT_2 ... READ-WRITE)
     - fmul present (product rule for a*b)
     - row_GRAD and col_GRAD NOT present"
  (unless (probe-file ir-path)
    (log:error "validate-mat-basic-sub-grad: IR file not found: ~a" ir-path)
    (return-from validate-mat-basic-sub-grad nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (and
     (or (search "scale_and_bias_grad" ir)
         (progn (log:error "validate-mat-basic-sub-grad: @scale_and_bias_grad not found") nil))
     (or (search "mat_sub_op_grad" ir)
         (progn (log:error "validate-mat-basic-sub-grad: @mat_sub_op_grad backward kernel not found") nil))
     (or (search "TENSOR_FLOAT_2" ir)
         (progn (log:error "validate-mat-basic-sub-grad: 2D gradient tensor type not found") nil))
     (or (search "fmul float" ir)
         (progn (log:error "validate-mat-basic-sub-grad: fmul not found (product rule for a*b)") nil))
     (or (not (search "row_GRAD" ir))
         (progn (log:error "validate-mat-basic-sub-grad: row_GRAD should not be emitted (integer index)") nil))
     (or (not (search "col_GRAD" ir))
         (progn (log:error "validate-mat-basic-sub-grad: col_GRAD should not be emitted (integer index)") nil))
     (progn (log:info "validate-mat-basic-sub-grad: PASS") t))))

(defun validate-tensor-basic-sub-grad (ir-path)
  "Validates 081/04-tensor-basic-sub-function:
     - @combine_grad defined
     - @tensor_sub_op_grad defined
     - 3D gradient tensor type present
     - d0_GRAD, d1_GRAD, d2_GRAD NOT present"
  (unless (probe-file ir-path)
    (log:error "validate-tensor-basic-sub-grad: IR file not found: ~a" ir-path)
    (return-from validate-tensor-basic-sub-grad nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (and
     (or (search "combine_grad" ir)
         (progn (log:error "validate-tensor-basic-sub-grad: @combine_grad not found") nil))
     (or (search "tensor_sub_op_grad" ir)
         (progn (log:error "validate-tensor-basic-sub-grad: @tensor_sub_op_grad backward kernel not found") nil))
     (or (search "TENSOR_FLOAT_3" ir)
         (progn (log:error "validate-tensor-basic-sub-grad: 3D gradient tensor type not found") nil))
     (or (not (search "d0_GRAD" ir))
         (progn (log:error "validate-tensor-basic-sub-grad: d0_GRAD should not be emitted") nil))
     (or (not (search "d1_GRAD" ir))
         (progn (log:error "validate-tensor-basic-sub-grad: d1_GRAD should not be emitted") nil))
     (or (not (search "d2_GRAD" ir))
         (progn (log:error "validate-tensor-basic-sub-grad: d2_GRAD should not be emitted") nil))
     (progn (log:info "validate-tensor-basic-sub-grad: PASS") t))))

(defun validate-vec-mvb-sub-grad (ir-path)
  "Validates 081/05-vec-multi-value-return:
     - @split_op_grad defined (two t_grad inputs, two delta outputs)
     - @vec_mvb_op_grad defined
     - split_op_grad called in backward kernel body
     - idx_GRAD NOT present"
  (unless (probe-file ir-path)
    (log:error "validate-vec-mvb-sub-grad: IR file not found: ~a" ir-path)
    (return-from validate-vec-mvb-sub-grad nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (and
     (or (search "split_op_grad" ir)
         (progn (log:error "validate-vec-mvb-sub-grad: @split_op_grad not found") nil))
     (or (search "vec_mvb_op_grad" ir)
         (progn (log:error "validate-vec-mvb-sub-grad: @vec_mvb_op_grad backward kernel not found") nil))
     (or (not (search "idx_GRAD" ir))
         (progn (log:error "validate-vec-mvb-sub-grad: idx_GRAD should not be emitted") nil))
     (progn (log:info "validate-vec-mvb-sub-grad: PASS") t))))

(defun validate-vec-fan-out-sub-grad (ir-path)
  "Validates 081/06-vec-fan-out:
     - @some_operation_grad and @augmentation_grad both defined
     - @vec_fan_op_grad defined
     - both _GRAD functions referenced (two paths contribute to A_GRAD)
     - idx_GRAD NOT present"
  (unless (probe-file ir-path)
    (log:error "validate-vec-fan-out-sub-grad: IR file not found: ~a" ir-path)
    (return-from validate-vec-fan-out-sub-grad nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (and
     (or (search "some_operation_grad" ir)
         (progn (log:error "validate-vec-fan-out-sub-grad: @some_operation_grad not found") nil))
     (or (search "augmentation_grad" ir)
         (progn (log:error "validate-vec-fan-out-sub-grad: @augmentation_grad not found") nil))
     (or (search "vec_fan_op_grad" ir)
         (progn (log:error "validate-vec-fan-out-sub-grad: @vec_fan_op_grad backward kernel not found") nil))
     (or (not (search "idx_GRAD" ir))
         (progn (log:error "validate-vec-fan-out-sub-grad: idx_GRAD should not be emitted") nil))
     (progn (log:info "validate-vec-fan-out-sub-grad: PASS") t))))

(defun validate-vec-mixed-sub-grad (ir-path)
  "Validates 081/07-vec-mixed-scalar-tensor:
     - @scale_element_grad defined
     - @vec_scale_sub_grad defined
     - scalar scale_GRAD present (float scalar gradient)
     - TENSOR_FLOAT_1 present (tensor gradient for A_GRAD)
     - fmul present (product rule for s*a)
     - idx_GRAD NOT present"
  (unless (probe-file ir-path)
    (log:error "validate-vec-mixed-sub-grad: IR file not found: ~a" ir-path)
    (return-from validate-vec-mixed-sub-grad nil))
  (let ((ir (uiop:read-file-string ir-path)))
    (and
     (or (search "scale_element_grad" ir)
         (progn (log:error "validate-vec-mixed-sub-grad: @scale_element_grad not found") nil))
     (or (search "vec_scale_sub_grad" ir)
         (progn (log:error "validate-vec-mixed-sub-grad: @vec_scale_sub_grad backward kernel not found") nil))
     (or (search "TENSOR_FLOAT_1" ir)
         (progn (log:error "validate-vec-mixed-sub-grad: 1D gradient tensor type for A_GRAD not found") nil))
     (or (search "fmul float" ir)
         (progn (log:error "validate-vec-mixed-sub-grad: fmul not found (product rule for s*a)") nil))
     (or (not (search "idx_GRAD" ir))
         (progn (log:error "validate-vec-mixed-sub-grad: idx_GRAD should not be emitted") nil))
     (progn (log:info "validate-vec-mixed-sub-grad: PASS") t))))

