;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins
;;;;
;;;; (Empty — Endeavor 130's hardware-profile logic graduated to
;;;;  src/hardware-profile.lisp.  Append new in-progress definitions here.)

(in-package :crisp.compiler)

;; ======================================================================
;; Endeavor 135 — tile-stride / hardware-stride :workgroup-idx now bind
;; GRID TERMS (tile-IDs), not element origins.
;;
;; src/analysis/control.lisp
;;
;; The shared strided-outer-loop engine previously bound each loop var to
;; the ELEMENT origin of a chunk (start_i = gid_i * ts_i, stepping by
;; ts_i * ng_i over the element extent E_i).  That is wrong for the grid
;; ("bare") tile forms: (load-tile / store-tile / position-tile) already
;; scale a grid coord by the tile extent, so feeding them an element origin
;; DOUBLE-SCALES (out of bounds for any multi-tile launch; masked to date
;; only because every existing test is single-tile).
;;
;; Fixed: bind the TILE-ID (chunk index).  Per dim:
;;     NT_i    = ceil(E_i / ts_i)          ; number of tiles along dim i
;;     start_i = gid_i                     ; this WG's first tile-id
;;     stride_i= ng_i                      ; distance (in tiles) between WGs
;;     ITERS_i = exact-count(start_i, stride_i, NT_i)
;;     b_i     = start_i + k_i * stride_i  ; = gid_i, gid_i+ng_i, ...  (a TILE-ID)
;; The body's bare load-tile / store-tile then scale b_i by the tile extent,
;; landing on the correct element origin.  Shared by tile-stride (ts = tile
;; size) and hardware-stride :workgroup-idx (ts = get-local-work-size).
(defun %expand-workgroup-strided-outer-loop-with-ts-syms
    (tensor-form n bindings body-forms ts-syms tile-size-expr-fn location)
  "Workgroup-strided outer loop over TILE-IDs.  Per-workgroup exact iter
   count per dim — body runs unconditionally, with each binding bound to a
   tile-ID (0-based chunk index), grid-strided by the number of workgroups."
  (declare (ignore location))
  (let* ((cl-pkg (find-package :crisp-language))
         (let-sym (intern "LET" cl-pkg))
         (declare-sym (intern "DECLARE" cl-pkg))
         (workgroup-level-sym (intern "WORKGROUP-LEVEL" cl-pkg))
         (dotimes-sym (intern "DOTIMES" cl-pkg))
         (progn-sym (intern "PROGN" cl-pkg))
         (aref-sym (intern "~" cl-pkg))
         (extents-tilde-sym (intern "EXTENTS~" cl-pkg))
         (get-wg-id-sym (intern "GET-WORKGROUP-ID" cl-pkg))
         (get-num-groups-sym (intern "GET-NUM-GROUPS" cl-pkg))
         (to-ulong-sym (intern "TO-ULONG" cl-pkg))
         (plus-sym (intern "+" cl-pkg))
         (minus-sym (intern "-" cl-pkg))
         (mul-sym (intern "*" cl-pkg))
         (div-sym (intern "/" cl-pkg))
         (t-sym (gensym "T"))
         (ts-local-syms ts-syms)
         (e-syms (loop for i from 0 below n collect (gensym (format nil "E~A" i))))
         (nt-syms (loop for i from 0 below n collect (gensym (format nil "NT~A" i))))
         (gid-syms (loop for i from 0 below n collect (gensym (format nil "WGID~A" i))))
         (ng-syms (loop for i from 0 below n collect (gensym (format nil "NG~A" i))))
         (start-syms (loop for i from 0 below n collect (gensym (format nil "START~A" i))))
         (stride-syms (loop for i from 0 below n collect (gensym (format nil "STRIDE~A" i))))
         (iters-syms (loop for i from 0 below n collect (gensym (format nil "ITERS~A" i))))
         (k-syms (loop for i from 0 below n collect (gensym (format nil "K~A" i))))
         (inner-body (if (= (length body-forms) 1)
                         (first body-forms)
                         (cons progn-sym body-forms)))
         (nest
          (let ((acc inner-body))
            (loop for i from (1- n) downto 0
                  for b-sym = (nth i bindings)
                  for start-sym = (nth i start-syms)
                  for stride-sym = (nth i stride-syms)
                  for iters-sym = (nth i iters-syms)
                  for k-sym = (nth i k-syms)
                  do (setf acc
                       (list dotimes-sym
                             (list k-sym iters-sym)
                             (list let-sym
                                   (list (list b-sym
                                               (list plus-sym start-sym
                                                     (list mul-sym k-sym stride-sym))))
                                   acc))))
            acc))
         (outer-bindings
          (append
            (list (list t-sym tensor-form))
            ;; ts_i  = chunk size (tile size / local-work-size, from caller)
            (loop for i from 0 below n
                  for ts-sym in ts-local-syms
                  collect (list ts-sym (funcall tile-size-expr-fn i)))
            ;; e_i   = extents[i]
            (loop for i from 0 below n
                  for e-sym in e-syms
                  collect (list e-sym (list aref-sym (list extents-tilde-sym t-sym) i)))
            ;; nt_i  = ceil(e_i / ts_i) = (e_i + ts_i - 1) / ts_i   (number of tiles)
            (loop for i from 0 below n
                  for nt-sym in nt-syms
                  for e-sym in e-syms
                  for ts-sym in ts-local-syms
                  collect (list nt-sym
                                (list div-sym
                                      (list plus-sym e-sym
                                            (list minus-sym ts-sym (list to-ulong-sym 1)))
                                      ts-sym)))
            ;; gid_i = get-workgroup-id i
            (loop for i from 0 below n
                  for gid-sym in gid-syms
                  collect (list gid-sym (list get-wg-id-sym i)))
            ;; ng_i  = get-num-groups i
            (loop for i from 0 below n
                  for ng-sym in ng-syms
                  collect (list ng-sym (list get-num-groups-sym i)))
            ;; start_i  = gid_i           (this WG's first tile-id)
            (loop for i from 0 below n
                  for start-sym in start-syms
                  for gid-sym in gid-syms
                  collect (list start-sym gid-sym))
            ;; stride_i = ng_i            (grid-stride in tile units)
            (loop for i from 0 below n
                  for stride-sym in stride-syms
                  for ng-sym in ng-syms
                  collect (list stride-sym ng-sym))
            ;; iters_i  = exact count over the TILE count nt_i
            (loop for i from 0 below n
                  for iters-sym in iters-syms
                  for start-sym in start-syms
                  for stride-sym in stride-syms
                  for nt-sym in nt-syms
                  collect (list iters-sym
                                (%build-exact-iter-count-form
                                 start-sym stride-sym nt-sym cl-pkg))))))
    (list let-sym outer-bindings
          (list declare-sym (list workgroup-level-sym))
          nest)))


;; ======================================================================
;; Endeavor 135 — matrix-multiply-tile-stride
;;
;; src/analysis/control.lisp  (analyzer)  +  register in register-control-analyzers
;;
;; Envelope/body macro for tiled matmul.  Pure SUGAR over the (now grid-correct)
;; tile-stride: it strides C's output tiles — binding grid-y/grid-x as TILE-IDs via
;; C-tile's extents — runs a K/k-step reduction loop (grid-k, the fastest-changing
;; binding) for each owned tile, then AUTO-STORES C-tile back to C.  The user writes
;; the staging + MMA (or scalar) accumulation in BODY.
;;
;;   (matrix-multiply-tile-stride C C-tile K <k-step> (grid-y grid-x grid-k) BODY...)
;;     =>
;;   (tile-stride C C-tile (grid-y grid-x)
;;     (dotimes (grid-k (/ (to-ulong K) (to-ulong <k-step>)))
;;       BODY...)
;;     (store-tile C-tile C (grid-y grid-x)))
;;
;; The accumulator (C-tile) is NOT auto-reset per spatial tile — for a grid-stride
;; launch that owns >1 tile the BODY must clear it on grid-k==0 (a `clear-tile`
;; primitive is the planned sugar for that).  Single-tile launches don't need it.
;; A register-tile C-tile is a record-of-fragments that the SROA explosion
;; (%explode-register-tiles, run by analyze-let-with-tile-explosion) turns into
;; C-tile$Fi + rewrites the store-tile/mma forms that name it.  So a register-tile
;; matmul MUST be lowered to those forms BEFORE the explosion, and its outer tile-spec
;; must be a compile-time (M N) size-list (a register tile has no extents~).  A scratch
;; C-tile is a real tensor — the ordinary analyzer path lowers it with the tile-tensor.
(defun %mmts-parse (expr location)
  "Validate + destructure a matrix-multiply-tile-stride form.  Returns
   (values c-form c-tile k-form k-step grid-y grid-x grid-k body)."
  (let* ((c-tile   (third expr))
         (k-step   (fifth expr))
         (bindings (sixth expr))
         (body     (nthcdr 6 expr)))
    (declare (ignore c-tile))
    ;; Old pre-k-step 4-arg shape: the grid bindings sit in the <k-step> slot.
    (when (listp k-step)
      (error 'crisp-compiler-error
        :message "matrix-multiply-tile-stride: missing scalar <k-step> before the grid bindings — expected (matrix-multiply-tile-stride C C-tile K <k-step> (grid-y grid-x grid-k) BODY...)"
        :source-location location))
    (unless (and (listp bindings) (= (length bindings) 3) (every #'symbolp bindings))
      (error 'crisp-compiler-error
        :message "matrix-multiply-tile-stride: expected exactly three grid bindings (grid-y grid-x grid-k)"
        :source-location location))
    (unless body
      (error 'crisp-compiler-error
        :message "matrix-multiply-tile-stride: empty body"
        :source-location location))
    (values (second expr) (third expr) (fourth expr) k-step
            (first bindings) (second bindings) (third bindings) body)))

(defun %mmts-lower (c-form c-tile tile-spec k-form k-step grid-y grid-x grid-k body)
  "The tile-stride (over TILE-SPEC) + grid-k K/k-step reduction loop + auto-store s-expr."
  (let* ((cl-pkg          (find-package :crisp-language))
         (tile-stride-sym (intern "TILE-STRIDE" cl-pkg))
         (store-tile-sym  (intern "STORE-TILE" cl-pkg))
         (dotimes-sym     (intern "DOTIMES" cl-pkg))
         (div-sym         (intern "/" cl-pkg))
         (to-ulong-sym    (intern "TO-ULONG" cl-pkg))
         (to-int-sym      (intern "TO-INT" cl-pkg)))
    (list tile-stride-sym c-form tile-spec (list grid-y grid-x)
          (list* dotimes-sym
                 (list grid-k
                       (list div-sym (list to-ulong-sym k-form) (list to-ulong-sym k-step)))
                 body)
          ;; Auto-store: tile-IDs to int — the register-tile store explosion scales the
          ;; tile-ID by an INT fragment count (* bty m-frags), and the scratch store's
          ;; own to-ulong coercion accepts an int coord too.
          (list store-tile-sym c-tile c-form
                (list (list to-int-sym grid-y) (list to-int-sym grid-x))))))

(defun analyze-matrix-multiply-tile-stride-expression (expr env context location)
  "Scratch-tensor path for (matrix-multiply-tile-stride C C-tile K <k-step> (gy gx gk) BODY...).
   Lowers with the tile-tensor C-tile (tile-stride reads its extents~).  Register-tile
   C-tiles are pre-lowered in analyze-let-with-tile-explosion, before SROA explosion,
   so they never reach here."
  (multiple-value-bind (c-form c-tile k-form k-step gy gx gk body)
      (%mmts-parse expr location)
    (analyze-expression (%mmts-lower c-form c-tile c-tile k-form k-step gy gx gk body)
                        env context location)))

;; --- Register-tile pre-expansion (source->source, before SROA explosion) ---
(defun %mmts-head-p (form)
  "T if FORM is a matrix-multiply-tile-stride call."
  (and (consp form) (symbolp (car form))
       (string-equal (symbol-name (car form)) "MATRIX-MULTIPLY-TILE-STRIDE")))

(defun %mmts-register-dims-map (bindings)
  "Alist var -> (M N) for each register-tile binding in a let's BINDINGS."
  (loop for b in bindings
        when (and (consp b) (= (length b) 2) (symbolp (first b))
                  (%register-tile-init-form-p (second b)))
          collect (cons (first b) (third (second b)))))   ; (make-register-tile elem (M N) init)

(defun %expand-mmts-register-in-form (form reg-map location)
  "Rewrite matrix-multiply-tile-stride forms whose C-tile is a register tile (in REG-MAP)
   to their tile-stride + auto-store lowering with a compile-time (M N) size-list tile-spec,
   so the generated store-tile/mma are visible to the register-tile SROA explosion."
  (cond
    ((not (consp form)) form)
    ((and (%mmts-head-p form) (assoc (third form) reg-map))
     (multiple-value-bind (c-form c-tile k-form k-step gy gx gk body)
         (%mmts-parse form location)
       (%mmts-lower c-form c-tile (cdr (assoc c-tile reg-map)) k-form k-step gy gx gk
                    (mapcar (lambda (f) (%expand-mmts-register-in-form f reg-map location)) body))))
    (t (mapcar (lambda (f) (%expand-mmts-register-in-form f reg-map location)) form))))

(defun %expand-matmul-tile-stride-register-forms (let-expr location)
  "If LET-EXPR binds register tiles, pre-lower the matrix-multiply-tile-stride forms in its
   body that target them (endeavor 135).  No-op when no register tile is bound."
  (if (not (and (consp let-expr) (>= (length let-expr) 2) (listp (second let-expr))))
      let-expr
      (let ((reg-map (%mmts-register-dims-map (second let-expr))))
        (if (null reg-map)
            let-expr
            `(,(first let-expr) ,(second let-expr)
              ,@(mapcar (lambda (f) (%expand-mmts-register-in-form f reg-map location))
                        (cddr let-expr)))))))

;; MERGE NOTE: fold %expand-matmul-tile-stride-register-forms into
;; analyze-let-with-tile-explosion (src/mma.lisp), before %explode-register-tiles.
(defun analyze-let-with-tile-explosion (expr env context location)
  "let/let* wrapper: pre-lower register-tile matrix-multiply-tile-stride (endeavor 135),
   then explode register-tile bindings (endeavor 132), then normal let analysis."
  (analyze-let-expression
   (%explode-register-tiles
    (%expand-matmul-tile-stride-register-forms expr location)
    location)
   env context location))

;; Register the scratch-path analyzer for both packages, surviving initialize-compiler's clrhash.
;; MERGE NOTE: move analyze-matrix-multiply-tile-stride-expression into
;; src/analysis/control.lisp and add these two setf's to register-control-analyzers;
;; then this wrapper of initialize-expression-analyzers can be dropped.
(defun register-matmul-tile-stride-analyzer ()
  "Registers the matrix-multiply-tile-stride expression analyzer (both packages)."
  (let ((sym-cl (intern "MATRIX-MULTIPLY-TILE-STRIDE" (find-package :crisp-language)))
        (sym-cc (intern "MATRIX-MULTIPLY-TILE-STRIDE" (find-package :crisp.compiler))))
    (setf (gethash sym-cl *expression-analyzers*)
          #'analyze-matrix-multiply-tile-stride-expression)
    (unless (eq sym-cl sym-cc)
      (setf (gethash sym-cc *expression-analyzers*)
            #'analyze-matrix-multiply-tile-stride-expression))))

(defvar *orig-initialize-expression-analyzers* nil)
(unless *orig-initialize-expression-analyzers*
  (setf *orig-initialize-expression-analyzers*
        (symbol-function 'initialize-expression-analyzers)))
(defun initialize-expression-analyzers ()
  "Overlay wrapper: run the original analyzer registration, then add
   matrix-multiply-tile-stride (endeavor 135)."
  (funcall *orig-initialize-expression-analyzers*)
  (register-matmul-tile-stride-analyzer))

