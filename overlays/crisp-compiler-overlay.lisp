;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; HOT-PATCH OVERLAY for CRISP.COMPILER -- append late definitions here and the build
;;;; picks them up after src/, so a fix can be made without editing src directly.
;;;;
;;;; EMPTY BY DESIGN.  Its 128 definitions were folded into src/ on 2026-08-26, and
;;;; endeavour 163's 23 definitions were folded in on 2026-09-06 (15 replaced their src
;;;; originals in place, 8 new helpers were appended to their target files, and a
;;;; duplicate *ad-ring-slot-marker* identical to src/autodiff.lisp's was dropped).
;;;;
;;;; When you fold future contents back out, three things bite:
;;;;   * VARIABLES belong in src/specials.lisp.  A `let` on a special compiled before its
;;;;     defvar is seen becomes a LEXICAL binding, silently.  Overlay variables are safe
;;;;     only because the overlay loads last; that protection disappears on the way in.
;;;;   * A definition that REPLACES one in src must overwrite it in place, not be
;;;;     appended -- otherwise both are live and ASDF order picks the winner.
;;;;   * A FORMAT string using ~<newline> continuation works in an LF overlay and DIES
;;;;     when folded into CRLF src/, and the error names the wrong place.  Both files are
;;;;     CRLF today, so this is only a hazard if an overlay is ever written as LF.

(in-package :crisp.compiler)


;;; ===================================================================
;;; Endeavour 165 — a register tile that cannot hold a fragment must REFUSE, not vanish.
;;;
;;; THE DEFECT.  `analyze-make-register-tile` and the store/mma walks size a tile as
;;; (floor m 16) x (floor n 8) fragments, so ANY tile with M < 16 or N < 8 yields ZERO
;;; fragments.  There is nothing to fill, nothing to store and nothing to multiply, so the
;;; kernel legitimately optimises down to `ret;` -- and the compiler reports success.
;;; Demonstrated on the dev box with a plain fp32 8x8 tile (put_temp_files_here/165/probe/):
;;; a fill + store-tile kernel emitted an empty body and exit code 0.
;;;
;;; `%ensure-register-tile-type` ALREADY guards exactly this and says so.  It never fires,
;;; because a LET-bound tile -- which is what every real kernel writes -- goes through
;;; `%explode-register-tiles` instead, and that path never re-checks.  The guard existed and
;;; was bypassed by the only route anyone uses.
;;;
;;; THE FIX.  One shared predicate, called from BOTH paths, so they cannot drift apart again.
;;; It is hooked into `%register-tile-fit-check` rather than into `%explode-register-tiles`
;;; because the fit-check is already invoked exactly once per register-tile binding on that
;;; path and already receives (m n location) -- a 15-line append instead of transcribing a
;;; 124-line function, which is its own class of risk.
;;;
;;; SCOPED TO THE NVIDIA PATH, deliberately.  On PTX `%frag-mn-for-operand` returns a
;;; hardcoded 16x8 for every operand and element type, so the geometry is unambiguous here.
;;; On SPIR-V it is derived per-element from `%spv-mma-shape`, and the fit-check does not
;;; receive the tile's element type or operand role -- guessing :acc would false-refuse a
;;; legitimate A or B tile and break shipped kernels.  SPIR-V can hit the same zero-fragment
;;; case with a mismatched shape; closing it there needs the elem threaded through, and is
;;; left as its own step rather than smuggled in behind a wrong default.
;;;
;;; NOTE FOR THE SRC PATCH: %register-tile-dims-must-divide is new (src/mma.lisp);
;;; %ensure-register-tile-type REPLACES src/mma.lisp:1001; %register-tile-fit-check
;;; REPLACES src/mma.lisp:1307.
;;; ===================================================================

;; src/mma.lisp
(defun %register-tile-dims-must-divide (m n location &optional (fr 16) (fc 8))
  "Refuse a register tile whose dims do not cover at least one whole FR x FC fragment.

   A tile of (M N) holds (floor M FR) x (floor N FC) fragments.  When either floor is zero the
   tile holds NOTHING, and every construct that walks it -- store-tile, fill-tile,
   mma-accumulate-via-tile -- expands to no code, so the kernel compiles clean and does nothing.
   That is the one outcome a compiler must never produce silently, so this is an error and not a
   warning: there is no reading of a zero-fragment tile under which the user got what they asked
   for.

   Endeavour 165.  fp64's only tensor-core shape is m8n8k4, whose accumulator is 8x8 -- under the
   hardcoded 16x8 fragment in BOTH dimensions -- so every fp64 MMA kernel would have walked into
   this.  The defect itself is older and has nothing to do with fp64: a plain fp32 8x8 tile
   reproduces it exactly."
  (unless (and (integerp m) (integerp n) (plusp m) (plusp n)
               (zerop (mod m fr)) (zerop (mod n fc)))
    (error 'crisp-compiler-error
           :message (format nil "make-register-tile: dims (~a ~a) must be multiples of the ~ax~a accumulator fragment. (~a ~a) holds ~a fragments, so the tile would carry no values and every store-tile / fill-tile / mma-accumulate-via-tile over it would expand to no code at all."
                            m n fr fc m n
                            (* (floor m fr) (floor n fc)))
           :source-location location)))

;; src/mma.lisp
(defun %ensure-register-tile-type (m n)
  "Mint (once) the register-tile-acc-f32-MxN record — (M/16)x(N/8) fragment fields —
   and record its dims.  Returns the type symbol.

   Endeavour 165: the divisibility guard now delegates to %register-tile-dims-must-divide, which
   the LET-bound path checks too.  Previously this guard lived here alone and the explode path
   never consulted it, so the check was live only for the one form nobody writes."
  (%register-tile-dims-must-divide m n nil)
  (let ((name (%register-tile-type-name m n)))
    (unless (gethash name *crisp-structs*)
      (let ((nfrags (* (floor m 16) (floor n 8))))
        (register-struct-definition
         name
         (loop for i below nfrags
               collect (list (intern (format nil "F~d" i) (find-package :crisp.compiler))
                             'register-fragment-acc-f32-16x8))
         :record)))
    (setf (gethash name *register-tile-dims*) (list m n))
    name))

;; src/mma.lisp
(defun %register-tile-fit-check (m n location)
  "F1 register FIT-CHECK — NVIDIA per-thread register model only.  On :spirv the tile is opaque
   cooperative matrices (the driver owns register residency), so SKIP — Intel GRF accounting is
   separate (Phase 4).  Else: (M/16)x(N/8) accumulator fragments x 4 fp32 regs <=
   :max-registers-per-thread.

   Endeavor 144 (D4): reads the budget through %hp-registers-per-thread-default, since
   :max-registers-per-thread may be a scalar OR a list of selectable modes.

   Endeavour 165: also refuses a tile too SMALL to hold one fragment.  Both bounds now live in
   the one function the explode path already calls -- a tile that overflows the register budget
   and a tile that holds nothing are the same kind of mistake, and both must be named at compile
   time rather than discovered as a spill or as an empty kernel."
  (unless (eq *target-backend* :spirv)
    (%register-tile-dims-must-divide m n location)
    (let* ((nfrags        (* (floor m 16) (floor n 8)))
           (regs-per-frag 4)
           (total-regs    (* nfrags regs-per-frag))
           (budget        (or (%hp-registers-per-thread-default)
                              *default-max-registers-per-thread*)))
      (when (> total-regs budget)
        (error 'crisp-compiler-error
               :message (format nil "make-register-tile: a ~ax~a accumulator tile needs ~a registers/thread (~a fragments × ~a regs), exceeding the register budget of ~a.  Use a smaller tile shape or a hardware profile with a larger :max-registers-per-thread."
                                m n total-regs nfrags regs-per-frag budget)
               :source-location location)))))
