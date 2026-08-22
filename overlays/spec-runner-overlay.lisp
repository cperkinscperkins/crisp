;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)


(defun validate-ptx-wgmma-group (file ptx-string)
  "Endeavour 154 — assert the wgmma k-slices are issued as ONE GROUP.

   THIS IS THE ASSERTION A CORRECTNESS TEST CANNOT MAKE.  The pre-154 lowering emitted
   `fence / mma_async / commit_group / wait_group 0` for EVERY k8 slice, so a K-block of 32
   emitted four of each.  That code is CORRECT -- it computes exactly the right answer -- but
   `wait_group 0` waits for ALL outstanding groups, so each async MMA was fully awaited before
   the next issued and the async in `mma_async` was defeated.  Measured cost on an H100 NVL:
   4.3% to 10.4% depending on size.  No numeric check can see it; only the emitted instruction
   sequence can.

   The required shape, which is also CUTLASS's:  one fence, N mma_async, one commit_group,
   one wait_group.  A fence is needed only before the FIRST wgmma of a sequence; back-to-back
   wgmmas within a group need none, and the accumulator RAW between them is honoured in issue
   order by the hardware.

   Asserts, over the wgmma opcodes in emitted order:
     1. at least TWO mma_async (otherwise the grouping property is vacuous and this spec is
        silently not testing what it claims)
     2. exactly one fence, one commit_group, one wait_group
     3. the order is fence ... all mma_async ... commit_group, wait_group"
  (declare (ignore file))
  (let ((ops '()) (pos 0))
    ;; collect the wgmma opcodes in emission order
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
    (let ((n-mma    (count :mma ops))
          (n-fence  (count :fence ops))
          (n-commit (count :commit ops))
          (n-wait   (count :wait ops)))
      (cond
        ((null ops)
         (format *error-output* "FAIL: no wgmma opcodes in the emitted PTX at all.~%") nil)
        ((< n-mma 2)
         (format *error-output* "FAIL: only ~a wgmma.mma_async emitted.  This spec must use a MULTI-SLICE K-block (:swizzle :128b with K>8) or it cannot test grouping at all.~%" n-mma)
         nil)
        ((not (and (= n-fence 1) (= n-commit 1) (= n-wait 1)))
         (format *error-output* "FAIL: wgmma group brackets are PER-SLICE, not per-group: ~a fence / ~a mma_async / ~a commit_group / ~a wait_group.  Expected 1 / ~a / 1 / 1.  Each `wait_group 0` awaits every outstanding group, so the MMAs cannot pipeline -- correct output, ~~4-10% slower.~%"
                 n-fence n-mma n-commit n-wait n-mma)
         nil)
        ((not (equal ops (append (list :fence) (make-list n-mma :initial-element :mma)
                                 (list :commit :wait))))
         (format *error-output* "FAIL: wgmma opcodes are in the wrong order: ~a.  Expected fence, ~a x mma_async, commit_group, wait_group.~%" ops n-mma)
         nil)
        (t t)))))

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
