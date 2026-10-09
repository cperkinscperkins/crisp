(in-package :cl-user)

(defpackage :crisp.test.last-man-fence
  (:use :cl :parachute))

(in-package :crisp.test.last-man-fence)

;;; ENDEAVOUR 183 -- last-man's fence: thread 0 RELEASES, the elected workgroup ACQUIRES.
;;;
;;; In all three last-man lowerings: (a) no mem-fence is executed by every thread before the ticket --
;;; the expansion's top-level body has none; (b) thread 0's block does, in program order, the partial
;;; store, ONE mem-fence, the ticket draw (atomic-add!); (c) the elected (when+) branch begins with a
;;; mem-fence -- the acquire, which pre-183 code did not have at all.

(defun %read-crisp (string)
  (let ((*package* (find-package :crisp-language))) (read-from-string string)))

(defun %named-p (x name) (and (symbolp x) (string-equal (symbol-name x) name)))

(defun %subforms (tree)
  (when (consp tree)
    (cons tree (loop for x on tree while (consp x) append (%subforms (car x))))))

(defun %mentions-p (tree name)
  (cond ((symbolp tree) (%named-p tree name))
        ((consp tree) (or (%mentions-p (car tree) name) (%mentions-p (cdr tree) name)))))

(defun %fence-p (f) (and (consp f) (%named-p (car f) "MEM-FENCE")))

(defun %top-level-body (expansion)
  "The forms of the expansion's outer PROGN (inside a LET of implicit scratch, if there is one)."
  (let ((e expansion))
    (when (%named-p (car e) "LET") (setf e (car (last e))))
    (assert (%named-p (car e) "PROGN"))
    (rest e)))

(defun %check (expansion)
  (let* ((top (%top-level-body expansion))
         (t0 (find-if (lambda (f) (and (consp f) (%named-p (car f) "WHEN-THREAD-IN-GROUP-IS")
                                       (%mentions-p f "ATOMIC-ADD!")))
                      top))
         (elected (find-if (lambda (f) (and (consp f) (%named-p (car f) "WHEN+"))) top)))
    (false (some #'%fence-p top) "no mem-fence executed by every thread at the top level")
    (true t0 "a thread-0 block draws the ticket")
    (when t0
      (let* ((body (cddr t0))
             (fence-at (position-if #'%fence-p body))
             (store-at (position-if (lambda (f) (and (consp f) (%named-p (car f) "SET!")
                                                     (not (%mentions-p f "ATOMIC-ADD!"))))
                                    body))
             (ticket-at (position-if (lambda (f) (%mentions-p f "ATOMIC-ADD!")) body)))
        (is = 1 (count-if #'%fence-p body) "exactly one fence in thread 0's block")
        (true (and store-at fence-at ticket-at (< store-at fence-at ticket-at))
              "thread 0's order is store, fence, ticket (store ~a, fence ~a, ticket ~a)"
              store-at fence-at ticket-at)))
    (true elected "an elected-workgroup branch")
    (when elected
      (true (%fence-p (third elected)) "the elected branch begins with the acquire fence"))))

(define-test last-man-fence)

(define-test (last-man-fence single-variable)
  (%check (crisp.compiler::%grid-reduce-last-man-expand
           (%read-crisp "(grid-reduce-last-man! #'+ v 0.0 out :local-scratch-vec sv :global-scratch-vec gv :atomic-counter ctr :election-flag-cell flag)"))))

(define-test (last-man-fence independent)
  (%check (crisp.compiler::%fused-grid-reduce-form
           (%read-crisp "(grid-reduce! ((#'+ a 0.0 o1) (#'max b 0ul o2)))"))))

(define-test (last-man-fence dependent)
  (%check (crisp.compiler::%fused-grid-reduce-dependent-form
           (%read-crisp "(grid-reduce! #'argmax-combine ((v (type-min float) outv) (i (type-max ulong) outi)))"))))

;; A quiet `is` failure does not fail the load, and the runner only sees load errors -- so error here.
(let* ((report (test 'last-man-fence))
       (failures (parachute:results-with-status :failed report)))
  (when failures
    (error "last-man-fence: ~d result(s) failed:~{~%    ~a~}" (length failures)
           (mapcar (lambda (r) (let ((s (princ-to-string r))) (subseq s 0 (min 160 (length s)))))
                   failures))))
