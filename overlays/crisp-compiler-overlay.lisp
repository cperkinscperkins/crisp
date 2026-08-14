;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Late-binding overrides for CRISP.COMPILER.
;;;;
;;;; EMPTY BY DESIGN.  Definitions live here only while a feature or bug fix is in
;;;; flight; once it settles they are folded back into their home file in src/ so
;;;; that the source of truth is one place.  Folded 2026-08-02 (endeavour 145),
;;;; and again 2026-08-09 (endeavour 146).
;;;;
;;;; To add one: APPEND a complete definition with a `;; src/<file>.lisp` comment
;;;; above it saying where it belongs.  Do not patch definitions already here.
;;;; Note that macros and structs CANNOT be overridden this way -- they are not
;;;; late-bound -- and must be patched in src/ directly.
;;;;
;;;; A NOTE ON WRAPPERS, learned the hard way in 146.  Capturing an original with
;;;;     (defvar *orig-foo* (symbol-function 'foo))
;;;; and then redefining FOO works beautifully in an overlay and does NOT survive
;;;; copy-paste into src/ -- there is no "original" there to capture.  Each such
;;;; wrapper has to be MERGED INTO the real function body when it is folded back.
;;;; If you reach for that pattern, note in the header which src function the
;;;; wrapper's body ultimately belongs inside.
;;;;
;;;; IN FLIGHT: endeavour 149, AD PRIMAL REPLAY.  One wrapper is used, on
;;;; GENERATE-BACKWARD-WALK; see the note above %AD-REPLAY-FINISH for exactly where
;;;; its two lines belong when this is folded into src/autodiff.lisp.

(in-package :crisp.compiler)

;;; ===================================================================
;;; ENDEAVOUR 149 -- AD PRIMAL REPLAY
;;;
;;; THE PROBLEM, in one sentence that has been in the source since bug 037:
;;;
;;;     A backward kernel replays the forward's BINDINGS but not its STATEMENTS --
;;;     the staged tiles are empty.
;;;
;;; `(A-TILE (make-scratch-vector float 4))` is a BINDING, so A-TILE exists in the
;;; backward.  The `set!`s that FILL it are STATEMENTS, and were never re-run.  So the
;;; chain rule, which needs primal values --
;;;
;;;     dA-tile[i] = B-tile[i] * dC[i]
;;;
;;; -- read an empty tile and got zero.  037 closed the case where the tile came from
;;; `load-tile-at` by rewriting the read to its ORIGINAL GLOBAL SOURCE (the tile knows
;;; where it came from).  Hand-staged tiles have no such record, and a swizzle the
;;; compiler did not author cannot be inverted, so those were REFUSED outright.
;;;
;;; This is the other half: RECOMPUTATION.  Re-run the fill in the backward and read
;;; the tile directly, inverting nothing.
;;;
;;; WHERE THE REPLAY GOES, which is the whole design.  Not "at the top of the
;;; backward" -- that is right only for kernels that stage once.  140/02 re-stages
;;; inside its k loop, where there is no such thing as "the" primal value of A-TILE:
;;; iteration kk needs what the tile held DURING kk.  So replay is emitted at the
;;; STATEMENT SEQUENCE that contains the fill, at whatever depth that is:
;;;
;;;   - a scope walks its body as usual;
;;;   - an unresolvable primal read registers a REQUEST (%AD-REPLAY-PENDING) instead
;;;     of erroring;
;;;   - each enclosing scope, as it closes, satisfies whatever requests IT can fill
;;;     from its own forward statements, and passes the rest outward;
;;;   - anything still pending when the kernel's top-level sequence closes is the old
;;;     refusal, unchanged.
;;;
;;; Because every scope walks its statements in REVERSE, a replay emitted at the head
;;; of a scope's backward body lands ahead of the consumer that needs it -- and inside
;;; a loop body it lands inside the loop, per iteration, which is 140/02 solved by
;;; construction rather than by special-casing.
;;;
;;; TWO THINGS REPLAY MUST NOT DO, both of which would be silent:
;;;
;;;   1. RE-RUN AN OBSERVABLE WRITE.  A staging statement that also writes global
;;;      memory would have its effect happen twice.  Refused, naming the write.
;;;   2. RECOMPUTE FROM MUTATED MEMORY.  The backward is a separate launch; a
;;;      statement that reads an `&out` parameter would recompute the tile from
;;;      whatever that buffer holds NOW, not what the forward staged.  Refused,
;;;      naming the parameter.  (Under --differentiate inputs are read-only, so the
;;;      globals the forward might have mutated are exactly its `&out` params -- the
;;;      check is a signature lookup, not a dataflow analysis.)
;;;
;;; AND ONE THING THE CALLER MUST NOT DO: the replayed copy is emitted STRAIGHT into
;;; the output form list, never through the walk's PROCESS-FORM-FN.  The backward
;;; already contains these statements once, walked in reverse for the tile adjoint;
;;; letting the walk see a second forward-direction copy would differentiate the
;;; staging twice and DOUBLE every gradient through it.  Spec 04 is the tripwire.
;;; ===================================================================

;; src/autodiff.lisp
(defvar *ad-replay-pending* nil
  "Endeavour 149.  Scratch-tile symbols whose PRIMAL value the backward needs but
   could not resolve -- neither from the tile (empty in the backward) nor from a
   load-tile-at source map.  Pushed by %AD-CHECK-UNRESOLVED-PRIMALS as the walk
   discovers them; drained by %AD-REPLAY-FORMS-FOR-SCOPE as enclosing scopes prove
   able to refill them.  Non-empty when the kernel's top-level sequence closes means
   nothing could fill the tile, which is the pre-149 refusal.")

;; src/autodiff.lisp
(defvar *ad-output-syms* nil
  "Endeavour 149.  The &out parameter symbols of the kernel being differentiated.
   These are the only globals the forward may have mutated (inputs are read-only
   under --differentiate), so a replayed statement that READS one of these is
   recomputing from memory whose contents the backward cannot vouch for.")

;; src/autodiff.lisp
(defun %ad-replay-op-name-p (form name)
  "T when FORM is a call to an operator whose symbol-name is NAME.  Compared by name
   because the AD walk sees symbols from :crisp-language while this code is read in
   :crisp.compiler."
  (and (consp form) (symbolp (car form))
       (string= (symbol-name (car form)) name)))

;; src/autodiff.lisp
(defun %ad-replay-barrier-p (form)
  "T when FORM is a synchronisation statement.  Barriers are carried into a replayed
   slice verbatim: staging that needed a barrier in the forward needs the same barrier
   when it is re-run, and replay must never INVENT one (a barrier synthesised inside a
   thread-dependent loop would deadlock)."
  (or (%ad-replay-op-name-p form "SYNC-WORKGROUP")
      (%ad-replay-op-name-p form "SYNC-SUBGROUP")
      (%ad-replay-op-name-p form "BARRIER")))

;; src/autodiff.lisp
(defun %ad-replay-place-sym (place)
  "The symbol a write PLACE targets: SYM for `(~ SYM i ...)`, or NIL when the place is
   not an indexed access on a symbol."
  (when (and (consp place) (symbolp (car place))
             (string= (symbol-name (car place)) "~")
             (symbolp (second place)) (second place))
    (second place)))

;; src/autodiff.lisp
(defun %ad-replay-fill-targets (form)
  "Symbols FORM writes through an INDEXED or whole-tile store, at any depth.

   These are the writes that can FILL a tile, so this drives slice selection; it is
   also what decides observability, since an indexed write to something that is not
   scratch is a write to memory somebody else can see.

   Bare `(set! SYM v)` is deliberately NOT collected here -- an ANF scalar temp is
   assigned constantly and none of it is observable.  Scalar writes are checked
   separately, and only against the &out list."
  (let ((acc nil))
    (labels ((walk (f)
               (when (consp f)
                 (let ((op (and (symbolp (car f)) (symbol-name (car f)))))
                   (cond
                     ((and op (member op '("SET!" "ATOMIC-ADD!" "ATOMIC-SUB!" "ATOMIC-MIN!"
                                           "ATOMIC-MAX!" "ATOMIC-EXCHANGE!" "ATOMIC-CAS!")
                                      :test #'string=))
                      (let ((s (%ad-replay-place-sym (second f))))
                        (when s (pushnew s acc))))
                     ;; (store-tile SRC DST ...) / (store-tile-at SRC DST ...)
                     ((and op (member op '("STORE-TILE" "STORE-TILE-AT") :test #'string=))
                      (let ((dst (third f)))
                        (cond ((symbolp dst) (when dst (pushnew dst acc)))
                              (t (let ((s (%ad-replay-place-sym dst)))
                                   (when s (pushnew s acc)))))))
                     ((and op (string= op "FILL-TILE"))
                      (let ((dst (second f)))
                        (when (symbolp dst) (pushnew dst acc)))))
                   ;; Descend into EVERY element, the head included.  Not (cdr f):
                   ;; a LET's binding list is itself a list whose CAR is the first
                   ;; binding, so skipping cars makes single-binding LETs -- which is
                   ;; what ANF produces constantly -- invisible to the walk.
                   (loop for sub = f then (cdr sub)
                         while (consp sub)
                         do (walk (car sub)))))))
      (walk form))
    acc))

;; src/autodiff.lisp
(defun %ad-replay-scalar-write-targets (form)
  "Symbols FORM assigns as a bare `(set! SYM v)`, at any depth.  Used only to catch an
   assignment to an &out parameter; ANF temps land here too and are ignored."
  (let ((acc nil))
    (labels ((walk (f)
               (when (consp f)
                 (when (and (%ad-replay-op-name-p f "SET!") (symbolp (second f)) (second f))
                   (pushnew (second f) acc))
                 ;; every element, head included -- see the note in %ad-replay-fill-targets
                 (loop for sub = f then (cdr sub)
                       while (consp sub)
                       do (walk (car sub))))))
      (walk form))
    acc))

;; src/autodiff.lisp
(defun %ad-replay-read-syms (form)
  "Symbols FORM READS, at any depth: the operand of `(~ SYM ...)` other than in a write
   place, and the SOURCE operand of load-tile / load-tile-at.

   The write place is skipped deliberately -- `(set! (~ D i) v)` reads nothing from D,
   and counting it would make every fill look like a read of its own destination."
  (let ((acc nil))
    (labels ((walk (f)
               (when (consp f)
                 (let ((op (and (symbolp (car f)) (symbol-name (car f)))))
                   (cond
                     ;; a write: skip the place, walk only the value operands
                     ((and op (member op '("SET!" "ATOMIC-ADD!" "ATOMIC-SUB!" "ATOMIC-MIN!"
                                           "ATOMIC-MAX!" "ATOMIC-EXCHANGE!" "ATOMIC-CAS!")
                                      :test #'string=))
                      ;; an index expression inside the place IS read; walk the place's
                      ;; subscripts but not its head symbol.
                      (when (consp (second f))
                        (dolist (idx (cddr (second f))) (walk idx)))
                      (dolist (sub (cddr f)) (walk sub)))
                     ((and op (member op '("LOAD-TILE" "LOAD-TILE-AT") :test #'string=))
                      (when (symbolp (second f)) (pushnew (second f) acc))
                      (dolist (sub (cdr f)) (walk sub)))
                     (t
                      (when (and op (string= op "~") (symbolp (second f)) (second f))
                        (pushnew (second f) acc))
                      ;; every element, head included.  This one is why rung 07 was
                      ;; missed at first: the read that made the slice unreplayable was
                      ;; `(%anf-t-N (~ D i))`, the sole binding of a LET, and a walk that
                      ;; skipped cars never saw it.  The kernel compiled, and the wrong
                      ;; gradient it would have produced was the exact silent failure the
                      ;; check exists to prevent.
                      (loop for sub = f then (cdr sub)
                            while (consp sub)
                            do (walk (car sub)))))))))
      (walk form))
    acc))

;; src/autodiff.lisp
(defun %ad-replay-slice (forms tiles)
  "The statements of FORMS that must be re-run to refill TILES, in forward order, or
   NIL when this sequence does not fill any of them.

   Taken as the SPAN from the first filling statement to the last, keeping the fillers
   and any barriers between them, plus any barriers immediately following the last
   filler.  Two reasons for a span rather than a bare filter: a barrier that sat
   between two fills was there for a reason, and the barrier that follows the staging
   is the one that makes the tile visible to the threads that read it.  Statements
   inside the span that fill nothing are dropped -- they cannot affect the tiles
   (anything that wrote them would be a filler) and dropping them keeps unrelated work
   out of the backward."
  (let ((idxs (loop for f in forms
                    for i from 0
                    when (intersection tiles (%ad-replay-fill-targets f))
                      collect i)))
    (when idxs
      (let* ((first-i (first idxs))
             (last-i (car (last idxs)))
             (span (subseq forms first-i (1+ last-i)))
             (kept (loop for f in span
                         when (or (intersection tiles (%ad-replay-fill-targets f))
                                  (%ad-replay-barrier-p f))
                           collect f))
             (trailing (loop for f in (nthcdr (1+ last-i) forms)
                             while (%ad-replay-barrier-p f)
                             collect f)))
        (append kept trailing)))))

;; src/autodiff.lisp
(defun %ad-replay-check-safe (slice tiles)
  "Signals if SLICE cannot be safely re-run in the backward.  TILES is what it fills,
   used only to make the diagnostic name the value the gradient was after.

   Both refusals name the offending symbol, because a diagnostic the user cannot act
   on is barely better than a wrong answer."
  (let* ((all-fills (reduce #'append (mapcar #'%ad-replay-fill-targets slice)))
         (observable-writes
           (remove-if (lambda (s)
                        (and *ad-scratch-syms* (gethash s *ad-scratch-syms*)))
                      all-fills))
         (scalar-out-writes
           (intersection (reduce #'append (mapcar #'%ad-replay-scalar-write-targets slice))
                         *ad-output-syms*))
         (bad-writes (union observable-writes scalar-out-writes))
         (stale-reads
           (intersection (reduce #'append (mapcar #'%ad-replay-read-syms slice))
                         *ad-output-syms*)))
    (when bad-writes
      (log:debug "149: refusing replay of ~a -- observable write(s) to ~a" tiles bad-writes)
      (error 'crisp-compiler-error
             :message
             (format nil "cannot differentiate: the backward needs the PRIMAL value of ~{~a~^, ~}, which means re-running the statements that fill ~:[it~;them~] -- but ~:[that statement~;those statements~] also write~p ~{~a~^, ~}, so replaying would repeat an observable side effect (the forward's write would happen twice for one logical execution).  Move the write out of the staging block so the staging is a pure fill, or mark the kernel forward-only."
                     tiles (cdr tiles) (cdr slice) (length bad-writes) bad-writes)
             :source-location nil))
    (when stale-reads
      (log:debug "149: refusing replay of ~a -- reads &out param(s) ~a" tiles stale-reads)
      (error 'crisp-compiler-error
             :message
             (format nil "cannot differentiate: the backward needs the PRIMAL value of ~{~a~^, ~}, which means re-running the statements that fill ~:[it~;them~] -- but those statements READ ~{~a~^, ~}, ~:[which is an &out parameter~;which are &out parameters~].  The backward is a SEPARATE kernel launch, so an &out buffer no longer holds what the forward staged from, and the replay would rebuild the tile from the wrong values.  Stage from an input parameter instead, or mark the kernel forward-only."
                     tiles (cdr tiles) stale-reads (cdr stale-reads))
             :source-location nil))))

;; src/autodiff.lisp
(defun %ad-replay-forms-for-scope (forms &optional inherited)
  "Replay statements this scope can contribute, or NIL.

   FORMS is the scope's FORWARD statement sequence.  Any pending tile this sequence
   fills is refilled here and struck from *AD-REPLAY-PENDING*; the rest stay pending
   for an enclosing scope.  Returns forms to splice at the HEAD of the scope's
   backward body -- ahead of every consumer, because the walk reverses each sequence.

   INHERITED is *AD-REPLAY-PENDING* as it stood when this scope STARTED walking its
   body, and it is what makes the placement correct rather than merely plausible.  A
   request already pending on entry was raised by a consumer OUTSIDE this scope, so
   satisfying it here would put the refill somewhere that does not reach that
   consumer.  The staging statement's own scope is exactly this case: it contains the
   fill, but the consumer that needs it is a sibling further along the sequence, and
   because sequences are emitted in reverse, a refill emitted inside the staging
   statement's backward runs AFTER the consumer that wanted it -- one iteration late
   in a loop, never at all outside one.  So only requests raised DURING this scope's
   own body walk are eligible; everything else travels outward to a scope that
   encloses both the fill and the consumer."
  (let ((eligible (set-difference *ad-replay-pending* inherited)))
    (when eligible
    (let* ((tiles eligible)
           (slice (%ad-replay-slice forms tiles)))
      (when slice
        (let ((filled (intersection tiles
                                    (reduce #'append (mapcar #'%ad-replay-fill-targets slice)))))
          (%ad-replay-check-safe slice filled)
          (setf *ad-replay-pending* (set-difference *ad-replay-pending* filled))
          (log:debug "149: replaying ~a statement(s) to restore primal(s) ~a; ~a still pending"
                     (length slice) filled *ad-replay-pending*)
          slice))))))

;;; -------------------------------------------------------------------
;;; The three statement-sequence sites.  Each is the src definition with the same
;;; two additions: ask for replay forms, splice them at the head of the backward body.
;;; -------------------------------------------------------------------

;; src/autodiff.lisp
(defun %ad-check-unresolved-primals (bindings body)
  "Records a REPLAY REQUEST for each primal bound to an unresolvable scratch-tile read
   that the backward BODY actually uses as a value.

   Endeavour 149 changed this from an immediate ERROR to a request.  The error was
   correct as far as it went -- silence here is what bug 037 was, an unavailable primal
   read as zero -- but this scope cannot know whether an ENCLOSING one is able to refill
   the tile.  So it registers the need and lets the walk answer it; the refusal now
   happens at the top-level sequence, where the answer is finally known.

   A tile whose primal is never consumed (a pure accumulator like C-tile, whose old
   value matters only for its adjoint) is fine and must NOT be requested -- hence the
   usage test rather than a blanket check."
  (dolist (b bindings)
    (when (and (consp b) (= (length b) 2)
               (%ad-tile-read-p (second b))
               *ad-scratch-syms*
               (gethash (second (second b)) *ad-scratch-syms*)
               (null (assoc (second (second b)) *ad-tile-src-map*))
               (%vjp-form-mentions-any-p body (list (first b))))
      (log:debug "149: primal of ~a is unresolved; requesting replay" (second (second b)))
      (pushnew (second (second b)) *ad-replay-pending*))))

;; src/autodiff.lisp
(defun %gfw-process-let (form emit-fn process-form-fn bindings augmented-bindings body)
  "BUG 037: the replayed primal bindings now read staged tiles from their ORIGINAL GLOBAL source
   instead of from the (empty) tile, and an unrecoverable primal that the backward actually uses
   is a hard error rather than a silent zero.

   BUG 041 (endeavor 147): every SLM scratch object this LET allocates is
   zeroed before the backward body runs.  See the header note above
   %ad-backward-slm-zero-forms -- shared memory is not guaranteed zero on any
   backend, and under CUDA it demonstrably is not.

   ENDEAVOUR 149: if a primal this LET could not resolve is filled by statements in
   THIS scope's forward body, re-run them here, ahead of the backward body.  The
   replay is spliced in directly and never handed to PROCESS-FORM-FN -- it is primal
   recomputation, not something to differentiate a second time."
  (declare (ignore form))
  (let ((local-forms nil)
        (inherited-replay-requests (copy-list *ad-replay-pending*)))
    (flet ((local-emit (f) (push f local-forms)))
      (dolist (b (reverse body))
        (funcall process-form-fn b #'local-emit))
      (dolist (b (reverse bindings))
        (when (and (consp b) (= (length b) 2) (symbolp (car b)))
              (funcall process-form-fn b #'local-emit))))
    (let* ((backward-body (nreverse local-forms))
           (emitted-bindings (%ad-rewrite-primal-bindings augmented-bindings))
           (zero-forms (%ad-backward-slm-zero-forms emitted-bindings)))
      (%ad-check-unresolved-primals augmented-bindings backward-body)
      (let ((replay (%ad-replay-forms-for-scope body inherited-replay-requests)))
        (funcall emit-fn `(let ,emitted-bindings
                            ,@zero-forms
                            ,@replay
                            ,@backward-body))))))

;; src/autodiff.lisp
(defun %gfw-process-dotimes (form emit-fn process-form-fn binding body local-vars adjoint-map intermediate-zero)
  "Unchanged except that it publishes the loop variable in *ad-loop-vars* while walking the
   body, so a VJP dispatched inside can ask what coordinate it is being evaluated at.  A
   pipelined ring operand needs this: its primal lives at the CONSUMING iteration, and the
   forward's load sites record other stages' origins.

   ENDEAVOUR 149: a tile re-staged each iteration has no single primal value, so its replay
   belongs HERE -- inside the loop body, ahead of the consumers, evaluated afresh for each
   value of the loop variable.  That falls out of emitting at this scope: the replayed
   statements close over BINDING exactly as the forward's did."
  (declare (ignore form))
  (let ((local-forms nil)
        (inherited-replay-requests (copy-list *ad-replay-pending*))
        (*ad-loop-vars* (if (and (consp binding) (symbolp (car binding)))
                            (cons (car binding) *ad-loop-vars*)
                            *ad-loop-vars*)))
    (flet ((local-emit (f) (push f local-forms)))
      (dolist (b (reverse body))
        (funcall process-form-fn b #'local-emit)))
    (let ((zero-resets
           (loop for v in local-vars
                 for adv = (gethash v adjoint-map)
                   when adv
                 collect `(set! ,adv ,intermediate-zero)))
          (replay (%ad-replay-forms-for-scope body inherited-replay-requests)))
      (funcall emit-fn `(dotimes ,binding ,@zero-resets ,@replay ,@(nreverse local-forms))))))

;;; -------------------------------------------------------------------
;;; The top-level sequence.
;;;
;;; WHEN FOLDING INTO src/: this wrapper exists only because the kernel's top-level
;;; statement sequence is walked INSIDE generate-backward-walk (src/autodiff.lisp,
;;; the `(dolist (form reversed-body) (process-form form #'emit))` near its end).
;;; The two things it does belong in that function directly:
;;;
;;;   - at the TOP of generate-backward-walk, alongside the existing
;;;     `(setf *ad-tile-src-map* ...)`:
;;;         (setf *ad-replay-pending* nil
;;;               *ad-output-syms*   outputs)
;;;   - where `result` is built, replace it with (%ad-replay-finish result flat-anf).
;;;
;;; No part of %AD-REPLAY-FINISH itself needs to change when it moves.
;;; -------------------------------------------------------------------

;; src/autodiff.lisp
(defun %ad-replay-finish (result flat-anf)
  "Closes the kernel's top-level sequence: splices any remaining replay into the head
   of the assembled backward RESULT, and refuses if a primal is still unaccounted for.

   This is where the pre-149 refusal now lives.  Reaching it means no scope, top-level
   included, contained statements that fill the tile -- a tile built by something the
   backward genuinely cannot reconstruct.  Refusing is still strictly better than the
   alternative it replaced: a backward that reads an empty tile and returns zero."
  (let ((replay (%ad-replay-forms-for-scope flat-anf)))
    (when *ad-replay-pending*
      (error 'crisp-compiler-error
             :message (format nil "cannot differentiate: the backward needs the PRIMAL value of ~a, a scratch tile that is not filled by load-tile-at, so its contents cannot be recovered (a backward kernel replays the forward's bindings but not its statements).  Tiles staged with load-tile-at are read back from their global source automatically, and hand-staged tiles are refilled by replaying the statements that stage them -- but no statement in this kernel fills ~:*~a.  Restructure so the value the gradient needs comes from a staged or global operand, or mark the kernel forward-only.  See plan/bugs.md #037."
                               (first *ad-replay-pending*))
             :source-location nil))
    (cond
      ((null replay) result)
      ((and (consp result) (symbolp (car result))
            (string= (symbol-name (car result)) "LET"))
       (log:debug "149: splicing ~a top-level replay statement(s) into the backward"
                  (length replay))
       (list* (first result) (second result) (append replay (cddr result))))
      (t `(progn ,@replay ,result)))))

;; src/autodiff.lisp -- see the folding note above; this wrapper's body belongs
;; INSIDE generate-backward-walk.
(defvar *%ad-orig-generate-backward-walk* nil
  "The pre-149 GENERATE-BACKWARD-WALK, captured once so the overlay can wrap it.")

(unless *%ad-orig-generate-backward-walk*
  (setf *%ad-orig-generate-backward-walk* (symbol-function 'generate-backward-walk)))

(setf (fdefinition 'generate-backward-walk)
      (lambda (flat-anf inputs outputs input-types output-types &rest keys)
        (setf *ad-replay-pending* nil
              *ad-output-syms* outputs)
        (let ((result (apply *%ad-orig-generate-backward-walk*
                             flat-anf inputs outputs input-types output-types keys)))
          (%ad-replay-finish result flat-anf))))
