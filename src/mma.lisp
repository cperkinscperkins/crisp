;;;; src/mma.lisp
;;;;
;;;; Endeavor 132 — MMA fundamentals (tensor-core / DPAS matrix multiply).
;;;;
;;;; This file owns the register-fragment type family and the MMA forms:
;;;;   make-register-fragment / store-fragment  (P1)
;;;;   load-fragment-a / load-fragment-b / mma-accumulate   (P2, later)
;;;;   make-register-tile / mma-accumulate-via-tile         (P3, later)
;;;;
;;;; A register-fragment is a WARP-COLLECTIVE MMA operand/accumulator represented as
;;;; a record — "a collection of registers", non-contiguous (records are registers;
;;;; structs are contiguous memory). One warp's worth of the logical fragment is
;;;; distributed across its lanes (for m16n8 fp32 accumulate: 16*8 / 32 lanes = 4
;;;; fp32 per lane). The warp-collective meaning lives in the ops (store-fragment,
;;;; later mma-accumulate / ldmatrix), NOT in the data — so the storage is a plain
;;;; thread-local record.

(in-package :crisp.compiler)


;;; ===================================================================
;;; P1 — the register-fragment record type.
;;;
;;; Concrete first shape: a 16x8 fp32 ACCUMULATOR fragment for a 32-lane warp
;;; (4 fp32 registers per lane). Generalized minting per (role, dtype, M, N,
;;; simd-width) comes later; P1 pins one shape to drive the vertical slice.
;;; ===================================================================

;; P1 slice: minimal record — just the 4 per-lane accumulator registers.
;;
;; NOTE: we register the record type PROGRAMMATICALLY rather than via the def-record
;; macro.  def-record emits user-facing MAKE-/accessor def-functions that compile
;; immediately; loaded from a build-time src file (no active compiler session) those
;; accessors fail to analyze.  A *system* type needs none of that — codegen builds and
;; reads fields with the low-level %construct-struct / %extract-struct-member primitives
;; — so we call register-struct-definition directly.
;;
;; MMA metadata (role / shape / regs-per-lane / layout) is carried by the analyzer +
;; codegen keyed on the record NAME for now (it encodes acc / f32 / 16x8 / 4-regs);
;; it graduates to a richer minting when we generalize across shapes.
(defun register-mma-types ()
  "Registers the MMA register-fragment record types.  Called from initialize-compiler
   AFTER register-builtins (initialize-compiler clrhash-es *crisp-structs* on every
   init, so a load-time registration would not survive).

   tf32 m16n8k8 register counts: A (16x8) -> 4 regs, B (8x8) -> 2 regs, C/D (16x8) -> 4
   regs.  tf32 is fp32-stored, so all fragment fields are float."
  (register-struct-definition 'register-fragment-acc-f32-16x8
                              '((r0 float) (r1 float) (r2 float) (r3 float))
                              :record)
  (register-struct-definition 'register-fragment-a-tf32-16x8
                              '((a0 float) (a1 float) (a2 float) (a3 float))
                              :record)
  (register-struct-definition 'register-fragment-b-tf32-8x8
                              '((b0 float) (b1 float))
                              :record))


;;; ===================================================================
;;; P1 — make-register-fragment analyzer.
;;;
;;; (make-register-fragment M N INIT) mints a warp-collective accumulator fragment.
;;; We rewrite it to the low-level %construct-struct primitive (splatting INIT across
;;; the per-lane registers) and analyze that, so all the existing record
;;; construction / typing / codegen machinery is reused for free.
;;; ===================================================================

(defun analyze-make-register-fragment (expr env context location)
  "P1: (make-register-fragment M N INIT) -> a register-fragment accumulator record.
   Only the 16x8 fp32 shape is minted for now; rewrite to %construct-struct with INIT
   splatted across the 4 per-lane registers and analyze that."
  (destructuring-bind (m n init) (cdr expr)
    (unless (and (eql m 16) (eql n 8))
      (error 'crisp-compiler-error
             :message (format nil "make-register-fragment: only 16x8 is supported in P1 (got ~a x ~a)." m n)))
    (analyze-expression
     `(%construct-struct register-fragment-acc-f32-16x8 ,init ,init ,init ,init)
     env context location)))

;;; ===================================================================
;;; P1 — store-fragment analyzer.
;;;
;;; (store-fragment FRAG DEST (TY TX)) writes a 16x8 fp32 accumulator fragment to the
;;; DEST matrix at logical tile (TY TX).  Like make-register-fragment, it REWRITES to
;;; existing forms (warp-lane / arithmetic / matrix element set / %extract-struct-member)
;;; — no new codegen.
;;;
;;; The real m16n8 fp32 accumulator layout: with lane in 0..31,
;;;   g = lane/4 (group), t = lane%4 (thread-in-group), the lane's 4 registers land at
;;;   (g, 2t) (g, 2t+1) (g+8, 2t) (g+8, 2t+1)  — a 16x8 tile — offset by the tile
;;;   origin (TY*16, TX*8).  (A uniform fragment makes P1's 01 pass regardless of this
;;;   mapping; the real layout is here so P2's non-uniform load->store validates it.)
;;; ===================================================================

(defun analyze-store-fragment (expr env context location)
  "P1: rewrite (store-fragment FRAG DEST (TY TX)) to per-lane matrix element writes
   using the m16n8 fp32 accumulator layout, then analyze that."
  (destructuring-bind (frag dest tile-id) (cdr expr)
    (let ((ty (first tile-id))
          (tx (second tile-id)))
      (analyze-expression
       `(let ((lane (to-int (warp-lane))))
          (let ((g  (/ lane 4))
                (t2 (* 2 (rem lane 4))))
            (let ((row (+ (* ,ty 16) g))
                  (col (+ (* ,tx 8) t2)))
              (set! (~ ,dest row col)               (%extract-struct-member ,frag 0))
              (set! (~ ,dest row (+ col 1))         (%extract-struct-member ,frag 1))
              (set! (~ ,dest (+ row 8) col)         (%extract-struct-member ,frag 2))
              (set! (~ ,dest (+ row 8) (+ col 1))   (%extract-struct-member ,frag 3)))))
       env context location))))

;;; ===================================================================
;;; P2 — load-fragment-a / load-fragment-b analyzers.
;;;
;;; (load-fragment-a SRC (TY TK)) / (load-fragment-b SRC (TK TX)) read this lane's
;;; tf32 A / B fragment elements from SRC (global or SLM — the layout is the same) at
;;; the m16n8k8 operand layout, and construct the A / B fragment record.  Rewrites to
;;; per-lane matrix reads (ldmatrix is a later perf optimization).
;;;
;;; m16n8k8 tf32 operand layouts (g = lane/4, tg = lane%4):
;;;   A (16x8, row): a0=(g,tg) a1=(g+8,tg) a2=(g,tg+4) a3=(g+8,tg+4)
;;;   B (8x8, col):  b0=(tg,g) b1=(tg+4,g)
;;; ===================================================================

(defun analyze-load-fragment-a (expr env context location)
  "P2: rewrite (load-fragment-a SRC (TY TK)) to a per-lane read of the 16x8 tf32 A
   fragment, offset by the tile origin (TY*16, TK*8), then analyze."
  (destructuring-bind (src tile-id) (cdr expr)
    (let ((ty (first tile-id)) (tk (second tile-id)))
      (analyze-expression
       `(let ((lane (to-int (warp-lane))))
          (let ((g (/ lane 4)) (tg (rem lane 4)))
            (let ((r (+ (* ,ty 16) g)) (c (+ (* ,tk 8) tg)))
              (%construct-struct register-fragment-a-tf32-16x8
                (~ ,src r       c)
                (~ ,src (+ r 8) c)
                (~ ,src r       (+ c 4))
                (~ ,src (+ r 8) (+ c 4))))))
       env context location))))

(defun analyze-load-fragment-b (expr env context location)
  "P2: rewrite (load-fragment-b SRC (TK TX)) to a per-lane read of the 8x8 tf32 B
   fragment, offset by the tile origin (TK*8, TX*8), then analyze."
  (destructuring-bind (src tile-id) (cdr expr)
    (let ((tk (first tile-id)) (tx (second tile-id)))
      (analyze-expression
       `(let ((lane (to-int (warp-lane))))
          (let ((g (/ lane 4)) (tg (rem lane 4)))
            (let ((r (+ (* ,tk 8) tg)) (c (+ (* ,tx 8) g)))
              (%construct-struct register-fragment-b-tf32-8x8
                (~ ,src r       c)
                (~ ,src (+ r 4) c)))))
       env context location))))

(defun register-mma-analyzers ()
  "Registers the MMA expression analyzers in *expression-analyzers* for both
   :crisp-language and :crisp.compiler.  Called from initialize-expression-analyzers
   (which clrhash-es the table on every compiler init, so a load-time setf would not
   survive)."
  (let ((cl-pkg (find-package :crisp-language))
        (cc-pkg (find-package :crisp.compiler)))
    (dolist (entry (list (cons "MAKE-REGISTER-FRAGMENT" #'analyze-make-register-fragment)
                         (cons "STORE-FRAGMENT"          #'analyze-store-fragment)
                         (cons "LOAD-FRAGMENT-A"         #'analyze-load-fragment-a)
                         (cons "LOAD-FRAGMENT-B"         #'analyze-load-fragment-b)))
      (let ((sym-cl (intern (car entry) cl-pkg))
            (sym-cc (intern (car entry) cc-pkg)))
        (setf (gethash sym-cl *expression-analyzers*) (cdr entry))
        (unless (eq sym-cl sym-cc)
          (setf (gethash sym-cc *expression-analyzers*) (cdr entry)))))))
