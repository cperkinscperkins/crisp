;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)


(defun validate-ptx-wgmma-group (file ptx-string)
  "Endeavour 154 — assert the wgmma k-slices are issued as WELL-FORMED GROUPS.

   THIS IS THE ASSERTION A CORRECTNESS TEST CANNOT MAKE.  The pre-154 lowering emitted
   `fence / mma_async / commit_group / wait_group 0` for EVERY k8 slice, so a K-block of 32
   emitted four of each.  That code is CORRECT -- it computes exactly the right answer -- but
   `wait_group 0` waits for ALL outstanding groups, so each async MMA was fully awaited before
   the next issued and the async in `mma_async` was defeated.  Measured cost on an H100 NVL:
   4.3% to 10.8% depending on size.  No numeric check can see it; only the emitted instruction
   sequence can.

   A well-formed group is:  fence, TWO OR MORE mma_async, commit_group, wait_group.

   The emitted opcodes must be a whole number of such groups and nothing else.  ONE group is the
   single-warpgroup case; a kernel with two consumer warpgroups emits TWO, which is equally
   correct -- the invariant is the SHAPE of each group, not how many there are.  Requiring >= 2
   mma_async per group is what stops a spec decaying into a vacuous pass: with a single-slice
   K-block the grouping property is untestable, and this must say so rather than go green."
  (declare (ignore file))
  (let ((ops '()) (pos 0))
    (loop
      (let ((i (search "wgmma." ptx-string :start2 pos)))
        (unless i (return))
        (let* ((end (or (position #\Newline ptx-string :start i) (length ptx-string)))
               (line (subseq ptx-string i end)))
          (push (cond ((eql 0 (search "wgmma.fence" line))        :fence)
                      ((eql 0 (search "wgmma.mma_async" line))    :mma)
                      ((eql 0 (search "wgmma.commit_group" line)) :commit)
                      ((eql 0 (search "wgmma.wait_group" line))   :wait)
                      (t :other))
                ops))
        (setf pos (1+ i))))
    (setf ops (nreverse (remove :other ops)))
    (if (null ops)
        (progn (format *error-output* "FAIL: no wgmma opcodes in the emitted PTX at all.~%") nil)
        (let ((rest ops) (groups 0))
          (loop
            (when (null rest) (return t))
            (unless (eq (first rest) :fence)
              (format *error-output* "FAIL: expected a wgmma.fence to open group ~a, got ~a.  Full opcode sequence: ~a~%"
                      (1+ groups) (first rest) ops)
              (return nil))
            (pop rest)
            (let ((n 0))
              (loop while (eq (first rest) :mma) do (pop rest) (incf n))
              (cond
                ((< n 2)
                 (format *error-output* "FAIL: group ~a has ~a wgmma.mma_async.  A group must hold TWO OR MORE, otherwise the grouping property is untestable -- use a MULTI-SLICE K-block (:swizzle :128b with K>8).  Pre-154 codegen produced exactly this shape: one mma per fence/commit/wait quadruple.~%"
                         (1+ groups) n)
                 (return nil))
                ((not (and (eq (first rest) :commit) (eq (second rest) :wait)))
                 (format *error-output* "FAIL: group ~a is not closed by commit_group then wait_group; found ~a then ~a.  Full opcode sequence: ~a~%"
                         (1+ groups) (first rest) (second rest) ops)
                 (return nil))
                (t (pop rest) (pop rest) (incf groups)))))))))

(defun validate-ptx-wgmma-store-direct (file ptx-string)
  "Endeavour 154 item 3 — assert a wgmma accumulator stored via `store-tile-at` took the
   REGISTER-DIRECT path, not the cooperative element-loop path.

   WHY THIS NEEDS ASSERTING.  `store-tile-at` had no wgmma overload before 154; a wgmma
   accumulator handed to it fell through to the generic cooperative store, which stages through
   memory and brackets the copy with `sync-workgroup` on both sides.  For a warpgroup-private
   accumulator that is both wrong in shape and pointless in cost -- yet it can still produce the
   right answer, so a metal MMA_CORRECT check alone would not notice which path ran.

   The distinguishing signature is the BARRIER.  The register-direct store emits the
   accumulator straight to global with no workgroup synchronization at all, so no `bar.sync`
   may appear after the final `wgmma.wait_group`.  The cooperative path always emits one."
  (declare (ignore file))
  (let ((last-wait (search "wgmma.wait_group" ptx-string :from-end t)))
    (cond
      ((null last-wait)
       (format *error-output* "FAIL: no wgmma.wait_group in the emitted PTX -- no wgmma ran, so this spec is not testing the store path it claims to.~%")
       nil)
      ((search "bar.sync" ptx-string :start2 last-wait)
       (format *error-output* "FAIL: a `bar.sync` appears AFTER the last wgmma.wait_group, which is the cooperative staged-store signature.  The wgmma accumulator store must be register-direct -- store-tile-at fell through to the generic path instead of the wgmma overload.~%")
       nil)
      (t t))))
