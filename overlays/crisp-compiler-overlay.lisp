;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins
;;;;
;;;; (Empty — Endeavor 130's hardware-profile logic graduated to
;;;;  src/hardware-profile.lisp.  Append new in-progress definitions here.)

(in-package :crisp.compiler)

;;; ===================================================================
;;; Endeavor 132 — register-tile RESIDENCY (2026-07-05)
;;;
;;; A `make-register-tile` accumulator was one monolithic record variable
;;; (e.g. 64x64 = a {{4xfloat}x32} nested aggregate) that the K-loop rewrote
;;; WHOLESALE via `(set! C-tile (%construct-struct ...))`.  That single
;;; loop-carried aggregate cannot be scalarized by SROA (it survives as a
;;; struct-typed PHI), so the NVPTX backend drops it to `.local` memory —
;;; measured 4896-byte stack frame, ~2300 ld/st.local around the MMAs, even
;;; under opt -O3.  Proven fix (benchmarks/matmul; verified in-process with
;;; opt -O3 -> llc: 0 vs 1024-byte depot): explode the tile into N INDIVIDUAL
;;; per-fragment mutable variables, each set! independently.  Each becomes a
;;; small {4xfloat} value that SROA/mem2reg keeps in registers.
;;;
;;; The N fragment variables must be LET-bound in the enclosing scope (so they
;;; survive the K-loop and reach the post-loop store-tile).  mma-accumulate-
;;; via-tile fires inside the loop and cannot create such bindings — so the
;;; rewrite is hosted at the `let`: a source->source transform that explodes a
;;; (V (make-register-tile T (M N) INIT)) binding into N per-fragment bindings
;;; and rewrites the body's via-tile/store-tile references to V.  We hook it by
;;; wrapping the `let`/`let*` analyzer (same table-override mechanism as the
;;; store-tile overload), deferring to the untouched analyze-let-expression.
;;; ===================================================================

(defun %head-name-eq (head name)
  "T if HEAD is a symbol whose name is NAME (package-insensitive)."
  (and (symbolp head) (string-equal (symbol-name head) name)))

(defun %register-tile-init-form-p (form)
  "T if FORM is a (make-register-tile T (M N) INIT) constructor."
  (and (consp form) (= (length form) 4) (%head-name-eq (first form) "MAKE-REGISTER-TILE")
       (listp (third form)) (= (length (third form)) 2)))

(defun %register-tile-frag-syms (var m n)
  "The N per-fragment variable symbols for tile VAR of shape MxN (row-major
   fragment grid), interned in VAR's package with a `$F<i>' suffix."
  (let ((nfrags (* (floor m 16) (floor n 8))))
    (loop for i below nfrags
          collect (intern (format nil "~a$F~d" (symbol-name var) i) (symbol-package var)))))

(defparameter *default-max-registers-per-thread* 255
  "Fallback per-thread register budget for the register-tile fit-check when no
   hardware profile pins :max-registers-per-thread.  255 = NVIDIA architectural max.")

(defun %register-tile-fit-check (m n location)
  "F1 (Endeavor 132) — register FIT-CHECK.  A register-tile accumulator is now
   register-resident (residency fix, 2026-07-06), so its size is bounded by the
   per-thread register file.  Error if the (M/16)×(N/8) accumulator fragments — 4 fp32
   regs each (tf32 m16n8k8) — exceed :max-registers-per-thread (from the active hardware
   profile, else the NVIDIA default 255).  Single-warp for now, so fragments/warp = total."
  (let* ((nfrags        (* (floor m 16) (floor n 8)))
         (regs-per-frag 4)                        ; fp32 accumulator, tf32 m16n8k8
         (total-regs    (* nfrags regs-per-frag))
         (profile       (active-hardware-profile))
         (budget        (or (and profile (getf profile :max-registers-per-thread))
                            *default-max-registers-per-thread*)))
    (when (> total-regs budget)
      (error 'crisp-compiler-error
             :message (format nil "make-register-tile: a ~ax~a accumulator tile needs ~a registers/thread (~a fragments × ~a regs), exceeding the register budget of ~a.  Use a smaller tile shape or a hardware profile with a larger :max-registers-per-thread."
                              m n total-regs nfrags regs-per-frag budget)
             :source-location location))))

(defun %emit-per-frag-accumulate (a b entry)
  "Per-fragment expansion of (mma-accumulate-via-tile _ V A B): one set!/frag,
   matching analyze-mma-accumulate-via-tile's index/layout math."
  (destructuring-bind (m n syms) (cdr entry)
    (let ((m-frags (floor m 16)) (n-frags (floor n 8)))
      `(progn
         ,@(loop for mi below m-frags append
                 (loop for nj below n-frags
                       for idx = (+ (* mi n-frags) nj)
                       collect `(set! ,(nth idx syms)
                                      (mma-accumulate ,(nth idx syms)
                                                      (load-fragment-a ,a (,mi 0))
                                                      (load-fragment-b ,b (0 ,nj))))))))))

(defun %emit-per-frag-store (dest tile-id entry)
  "Per-fragment expansion of (store-tile V DEST (BTY BTX)): one store-fragment
   per fragment, matching analyze-store-tile-mma's runtime-offset math."
  (destructuring-bind (m n syms) (cdr entry)
    (let ((m-frags (floor m 16)) (n-frags (floor n 8))
          (bty (first tile-id)) (btx (second tile-id)))
      `(progn
         ,@(loop for mi below m-frags append
                 (loop for nj below n-frags
                       for idx = (+ (* mi n-frags) nj)
                       collect `(store-fragment ,(nth idx syms)
                                                ,dest
                                                ((+ (* ,bty ,m-frags) ,mi)
                                                 (+ (* ,btx ,n-frags) ,nj)))))))))

(defun %explode-rewrite-body-form (form tiles)
  "Recursively rewrite body FORM: replace via-tile / store-tile references to
   any exploded tile in TILES (alist V -> (V m n syms)) with per-fragment progns;
   otherwise recurse structurally."
  (cond
    ((not (consp form)) form)
    ((and (%head-name-eq (first form) "MMA-ACCUMULATE-VIA-TILE") (= (length form) 5)
          (assoc (third form) tiles))
     (destructuring-bind (shape v a b) (cdr form)
       ;; Still enforce the shape check the analyzer would have run — the explosion
       ;; pre-empts analyze-mma-accumulate-via-tile, so validate here too.
       (%check-mma-shape shape nil)
       (%emit-per-frag-accumulate a b (assoc v tiles))))
    ((and (%head-name-eq (first form) "STORE-TILE") (= (length form) 4)
          (assoc (second form) tiles))
     (destructuring-bind (v dest tile-id) (cdr form)
       (%emit-per-frag-store dest tile-id (assoc v tiles))))
    (t (mapcar (lambda (f) (%explode-rewrite-body-form f tiles)) form))))

(defun %explode-register-tiles (let-expr &optional location)
  "Source->source: explode any (V (make-register-tile T (M N) INIT)) binding in
   LET-EXPR into N (V$Fi (make-register-fragment 16 8 INIT)) bindings, and rewrite
   the body's via-tile/store-tile references to V into per-fragment progns.  Runs the
   register FIT-CHECK per tile.  A no-op (returns LET-EXPR unchanged) when no
   register-tile binding is present."
  (if (not (and (consp let-expr) (>= (length let-expr) 2) (listp (second let-expr))))
      let-expr
      (let* ((head (first let-expr))
             (bindings (second let-expr))
             (body (cddr let-expr))
             (tiles '()))
        (let ((new-bindings
                (loop for b in bindings
                      append
                      (if (and (consp b) (= (length b) 2) (symbolp (first b))
                               (%register-tile-init-form-p (second b)))
                          (destructuring-bind (mrt elem dims init) (second b)
                            (declare (ignore mrt elem))
                            (destructuring-bind (m n) dims
                              (%register-tile-fit-check m n location)
                              (let ((syms (%register-tile-frag-syms (first b) m n)))
                                (push (list (first b) m n syms) tiles)
                                (loop for s in syms
                                      collect (list s `(make-register-fragment 16 8 ,init))))))
                          (list b)))))
          (if (null tiles)
              let-expr
              `(,head ,new-bindings
                      ,@(mapcar (lambda (f) (%explode-rewrite-body-form f tiles)) body)))))))

(defun analyze-let-with-tile-explosion (expr env context location)
  "let/let* analyzer wrapper: explode register-tile bindings into per-fragment
   mutable variables (register residency, Endeavor 132), then defer to the
   normal let analysis."
  (analyze-let-expression (%explode-register-tiles expr location) env context location))

(defun register-mma-analyzers ()
  "Registers the MMA expression analyzers in *expression-analyzers* for both
   :crisp-language and :crisp.compiler.  Called from initialize-expression-analyzers
   (which clrhash-es the table on every compiler init, so a load-time setf would not
   survive).  Overlay: adds the let/let* wrapper for register-tile residency."
  (let ((cl-pkg (find-package :crisp-language))
        (cc-pkg (find-package :crisp.compiler)))
    (dolist (entry (list (cons "MAKE-REGISTER-FRAGMENT" #'analyze-make-register-fragment)
                         (cons "STORE-FRAGMENT"          #'analyze-store-fragment)
                         (cons "LOAD-FRAGMENT-A"         #'analyze-load-fragment-a)
                         (cons "LOAD-FRAGMENT-B"         #'analyze-load-fragment-b)
                         (cons "MMA-ACCUMULATE"          #'analyze-mma-accumulate)
                         (cons "MAKE-REGISTER-TILE"      #'analyze-make-register-tile)
                         (cons "MMA-ACCUMULATE-VIA-TILE" #'analyze-mma-accumulate-via-tile)
                         (cons "INNER-DIMENSION"         #'analyze-inner-dimension)
                         ;; store-tile OVERLOAD: runs after register-control-analyzers,
                         ;; so this wins; it delegates to the SLM store-tile for non-tiles.
                         (cons "STORE-TILE"              #'analyze-store-tile-mma)
                         ;; let/let* WRAPPER: explode register-tile accumulators into
                         ;; per-fragment mutable vars before the normal let analysis.
                         (cons "LET"                     #'analyze-let-with-tile-explosion)
                         (cons "LET*"                    #'analyze-let-with-tile-explosion)))
      (let ((sym-cl (intern (car entry) cl-pkg))
            (sym-cc (intern (car entry) cc-pkg)))
        (setf (gethash sym-cl *expression-analyzers*) (cdr entry))
        (unless (eq sym-cl sym-cc)
          (setf (gethash sym-cc *expression-analyzers*) (cdr entry)))))))

;;; ===================================================================
;;; In-process optimizer (2026-07-06)
;;;
;;; Replaces the shell-out to an external `opt` binary with an in-process
;;; `LLVMRunPasses` call against the libLLVM we already ship (tools/LLVM-C-*).
;;; The Windows dev box has no `opt.exe`, so local PTX/SPV builds were
;;; UNoptimized (llc alone doesn't run the IR pipeline) and perf-blind.  Now
;;; every build, on every platform, runs `default<O3>` — no extra binary, no
;;; subprocess, no init_tools.py/tools-release change.
;;;
;;; %run-opt-O3 / %run-opt-pipeline keep their (input-ll output-ll [passes])
;;; signatures, so compile-to-ptx / compile-to-spirv are UNCHANGED (same file
;;; flow, same metadata-injection ordering, same +spv-opt-pipeline+ string, and
;;; the same "fall back to unoptimized IR on failure" safety).  Only the
;;; optimizer invocation swaps from `opt` subprocess to libLLVM in-process.
;;; ===================================================================

(defvar *nvptx-target-initialized* nil
  "Guard so the NVPTX target is registered at most once per image.")

(defun %ensure-nvptx-target-initialized ()
  "Register the NVPTX target/MC so LLVMGetTargetFromTriple can resolve
   nvptx64-nvidia-cuda.  Idempotent."
  (unless *nvptx-target-initialized*
    (crisp.llvm-bindings::llvm-initialize-nvptx-target-info)
    (crisp.llvm-bindings::llvm-initialize-nvptx-target)
    (crisp.llvm-bindings::llvm-initialize-nvptx-target-mc)
    (setf *nvptx-target-initialized* t)))

(defun %make-target-machine-for-module (module)
  "Best-effort TargetMachine from MODULE's triple: NVPTX -> a real TM (target-
   aware opt/TTI); an unregistered target (e.g. spir64) -> NULL, which is the
   target-independent behavior opt fell back to on the SPV path anyway."
  (%ensure-nvptx-target-initialized)
  (let ((triple (crisp.llvm-bindings::llvm-get-target module)))
    (if (or (null triple) (zerop (length triple)))
        (cffi:null-pointer)
        (cffi:with-foreign-objects ((tref :pointer) (err :pointer))
          (setf (cffi:mem-ref err :pointer) (cffi:null-pointer))
          (if (zerop (crisp.llvm-bindings::llvm-get-target-from-triple triple tref err))
              (let ((tm (crisp.llvm-bindings::llvm-create-target-machine
                         (cffi:mem-ref tref :pointer) triple "" ""
                         2 0 0)))         ; opt=Default reloc=Default codemodel=Default
                (if (cffi:null-pointer-p tm) (cffi:null-pointer) tm))
              (cffi:null-pointer))))))

(defun %run-passes-in-process (input-ll-file output-ll-file passes-string)
  "Parse INPUT-LL-FILE into a fresh context, run PASSES-STRING (new pass manager)
   in-process via the loaded libLLVM, and write the optimized IR to
   OUTPUT-LL-FILE.  Returns T on success, NIL on any failure (caller falls back
   to the unoptimized IR)."
  (handler-case
      (let ((ctx (crisp.llvm-bindings::llvm-context-create)))
        (unwind-protect
            (cffi:with-foreign-objects ((mbuf :pointer) (modout :pointer) (msg :pointer))
              (setf (cffi:mem-ref msg :pointer) (cffi:null-pointer))
              (cond
                ((not (zerop (crisp.llvm-bindings::llvm-create-memory-buffer-with-contents-of-file
                              (namestring input-ll-file) mbuf msg)))
                 (log:warn "in-process opt: read failed") nil)
                ((not (zerop (crisp.llvm-bindings::llvm-parse-ir-in-context
                              ctx (cffi:mem-ref mbuf :pointer) modout msg)))
                 (log:warn "in-process opt: parse failed") nil)
                (t
                 (let* ((module (cffi:mem-ref modout :pointer))
                        (tm     (%make-target-machine-for-module module))
                        (opts   (crisp.llvm-bindings::llvm-create-pass-builder-options)))
                   (unwind-protect
                       (let ((err (crisp.llvm-bindings::llvm-run-passes
                                   module passes-string tm opts)))
                         (if (cffi:null-pointer-p err)
                             (let ((s (crisp.llvm-bindings:llvm-print-module-to-string module)))
                               (unwind-protect
                                   (with-open-file (o output-ll-file :direction :output
                                                      :if-exists :supersede
                                                      :if-does-not-exist :create)
                                     (write-string (cffi:foreign-string-to-lisp s) o))
                                 (crisp.llvm-bindings:llvm-dispose-message s))
                               (log:info "in-process opt (~a) -> ~a" passes-string output-ll-file)
                               t)
                             (progn
                               (log:warn "in-process opt: RunPasses failed: ~a"
                                         (crisp.llvm-bindings::llvm-get-error-message err))
                               nil)))
                     (crisp.llvm-bindings::llvm-dispose-pass-builder-options opts)
                     (unless (cffi:null-pointer-p tm)
                       (crisp.llvm-bindings::llvm-dispose-target-machine tm))
                     (crisp.llvm-bindings::llvm-dispose-module module))))))
          (crisp.llvm-bindings::llvm-context-dispose ctx)))
    (error (e)
      (log:warn "in-process opt threw (~a), using unoptimized IR" e)
      nil)))

;; src/compiler.lisp — in-process replacements (were shell-outs to `opt`).
(defun %run-opt-O3 (input-ll-file output-ll-file)
  "Run default<O3> on INPUT-LL-FILE in-process (libLLVM), writing OUTPUT-LL-FILE.
   Returns T on success, NIL on failure (caller falls back to unoptimized IR)."
  (%run-passes-in-process input-ll-file output-ll-file "default<O3>"))

(defun %ll-has-spirv-illegal-int-p (ll-file)
  "T if LL-FILE mentions an integer type iN with N NOT in SPIR-V's legal set
   {1,8,16,32,64}.  opt's default<O3> can synthesize odd widths (e.g. i33 from the
   umul-high / (a*b)>>1 idiom) that llvm-spirv rejects with `InvalidBitWidth`."
  (handler-case
      (let ((text (uiop:read-file-string ll-file)))
        (block scan
          (cl-ppcre:do-register-groups ((#'parse-integer n)) ("\\bi(\\d+)\\b" text)
            (unless (member n '(1 8 16 32 64))
              (return-from scan t)))
          nil))
    (error () nil)))

(defun %run-opt-pipeline (input-ll-file output-ll-file passes-string)
  "SPV opt (in-process).  Run PASSES-STRING, but if the optimized IR contains a
   SPIR-V-illegal integer width, discard it and return NIL so the caller falls
   back to the unoptimized IR — llvm-spirv can't translate e.g. i33, whereas the
   PTX path (llc/NVPTX) legalizes it fine, so this guard is SPV-only."
  (let ((ok (%run-passes-in-process input-ll-file output-ll-file passes-string)))
    (cond
      ((not ok) nil)
      ((%ll-has-spirv-illegal-int-p output-ll-file)
       (log:warn "SPV opt produced a SPIR-V-illegal integer width; using unoptimized IR for this kernel")
       nil)
      (t t))))
