(in-package :cl-user)

(defpackage :crisp.test.reduce-vec
  (:use :cl :parachute))

(in-package :crisp.test.reduce-vec)

;;; ENDEAVOUR 178 -- the pure pieces of reduce-vec and of the loop-carried SET! fix it needed.
;;;
;;; Every on-metal check in this directory needs a GPU and skips on a CI runner, so the parts that
;;; are plain functions are pinned here: the VERIFY-AUTODIFF 1-D vector generator the AD specs depend
;;; on, the shape of reduce-vec's expansion (its partial must be named deterministically, never a
;;; gensym, or Pass 1 and Pass 2 disagree on the implicit scratch), and the taint analysis that
;;; decides whether a loop-carried variable makes a loop's backward unsound.

(unless (find-symbol "%VAD-PARSE-GENERATED-VECTOR" :cl-user)
  (load (merge-pathnames "tests/verify-autodiff-parse.lisp" (uiop:getcwd))))

(define-test reduce-vec-test
  "Endeavour 178: reduce-vec and the loop-carried set! backward.")

;;; --- the VERIFY-AUTODIFF 1-D generator ------------------------------

(define-test (reduce-vec-test vector-generator-is-a-ramp)
  "N@START:STEP yields N floats, element i = START + STEP*i."
  (let ((v (cl-user::%vad-parse-generated-vector "5@1:0.5" "A=5@1:0.5")))
    (is = 5 (length v))
    (is = 1.0 (first v))
    (is = 3.0 (fifth v))))

(define-test (reduce-vec-test vector-generator-is-not-the-matrix-form)
  "RxC@.. stays a matrix; N@.. is a vector; a plain number is neither."
  (true  (cl-user::%vad-generated-vector-p "300@0:0.01"))
  (false (cl-user::%vad-generated-vector-p "4x16@0:0.01"))
  (true  (cl-user::%vad-generated-matrix-p "4x16@0:0.01"))
  (false (cl-user::%vad-generated-vector-p "3.0")))

(define-test (reduce-vec-test vector-generator-reaches-the-inputs)
  "A whole directive with the generator puts a 300-element list under A."
  (let* ((parsed (cl-user::parse-verify-autodiff
                  (list "VERIFY-AUTODIFF: A=300@0:0.01 at.A=257 atol=1e-2")))
         (a (cdr (assoc "A" (getf parsed :inputs) :test #'string=))))
    (is = 300 (length a))))

;;; --- the expansion --------------------------------------------------

(defun %expand (form-string)
  (let ((*package* (find-package :crisp-language)))
    (crisp.compiler::%reduce-vec-expand (read-from-string form-string))))

(define-test (reduce-vec-test expansion-folds-then-grid-reduces)
  "(let ((A-INTO-OUT id)) (check) (loop-vector-stride A ..) (grid-reduce! ..)), keys passed through."
  (let ((e (%expand "(reduce-vec #'+ A 0.0 out :strategy :atomic :message \"m\")")))
    (is string= "LET" (symbol-name (first e)))
    (is string= "A-INTO-OUT" (symbol-name (first (first (second e)))))
    (is string= "LOOP-VECTOR-STRIDE" (symbol-name (first (fourth e))))
    (let ((gr (fifth e)))
      (is string= "GRID-REDUCE!" (symbol-name (first gr)))
      (is equal '(:strategy :atomic :message "m") (nthcdr 5 gr)))))

(define-test (reduce-vec-test partial-name-is-deterministic)
  "Two expansions of the same call name the partial identically (no gensym)."
  (is eq (first (first (second (%expand "(reduce-vec #'+ A 0.0 out)"))))
         (first (first (second (%expand "(reduce-vec #'+ A 0.0 out)"))))))

(define-test (reduce-vec-test refusals-name-reduce-vec)
  "Strategy and shape errors are raised at expansion, naming reduce-vec."
  (fail (%expand "(reduce-vec #'+ A 0.0 out :strategy :second-stage)"))
  (fail (%expand "(reduce-vec #'+ A 0.0 out :strategy :atomic :atomic-counter c)"))
  (fail (%expand "(reduce-vec ((#'+ A 0.0 out)))")))

;;; --- loop-carried taint ---------------------------------------------

(defun %sym (name) (intern name :crisp-language))

(define-test (reduce-vec-test running-sum-reads-no-stale-primal)
  "p := p + a: the backward of the + reads only adjoints, so nothing is stale."
  (let* ((p (%sym "P")) (a (%sym "A")) (t2 (%sym "T2")) (t3 (%sym "T3"))
         (body `((let ((,t2 (crisp.compiler::~ ,a 0))) (let ((,t3 (+ ,p ,t2))) (crisp.compiler::set! ,p ,t3)))))
         (tainted (crisp.compiler::%ad-loop-carried-tainted body (list t2 t3))))
    (true (member p tainted))
    (true (member t3 tainted))
    (false (crisp.compiler::%ad-stale-primal-reads
            `((crisp.compiler::set! ,(%sym "T3_ADJ") (+ ,(%sym "T3_ADJ") ,(%sym "P_ADJ")))
              (let ((,t3 (+ ,p ,t2))) (crisp.compiler::set! ,(%sym "T2_ADJ") ,(%sym "T3_ADJ"))))
            tainted))))

(define-test (reduce-vec-test running-product-reads-a-stale-primal)
  "p := p * a: the backward of the * reads p, which the backward loop never updates."
  (let* ((p (%sym "P")) (t2 (%sym "T2")) (t3 (%sym "T3"))
         (tainted (list p t3)))
    (true (member p (crisp.compiler::%ad-stale-primal-reads
                     `((crisp.compiler::set! ,(%sym "T2_ADJ") (* ,(%sym "T3_ADJ") ,p)))
                     tainted)))
    (false (member t2 tainted))))

;;; The runner only reports a unit FILE as passing if it loads (its aggregate parachute gate is
;;; effectively empty), so run this suite here and turn a quiet assertion failure into a load error.
(let* ((report (test 'reduce-vec-test))
       (failures (parachute:tests-with-status :failed report)))
  (when failures
    (error "reduce-vec-test: ~d failed" (length failures))))
