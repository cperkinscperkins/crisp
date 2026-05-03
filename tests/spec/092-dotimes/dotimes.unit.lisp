;; tests/spec/092-dotimes/dotimes.unit.lisp
(in-package :crisp.compiler)

(parachute:define-test dotimes-semantic-test
                       :parent :crisp.tests)

(parachute:define-test (dotimes-semantic-test anf-passthrough)
  "ANF transform already handles dotimes: limit is hoisted, body is ANF'd."
  (parachute:is equal
    '(let ((%anf-t-1 (+ n 1)))
       (dotimes (i %anf-t-1)
         (let ((%anf-t-2 (* i 2)))
           (foo %anf-t-2))))
    (anf-transform '(dotimes (i (+ n 1)) (foo (* i 2))))))

(parachute:define-test (dotimes-semantic-test produces-semantic-dotimes)
  "Compiling a dotimes form produces a semantic-dotimes node."
  (initialize-compiler :log-level :error)
  (let* ((result (compile-crisp-form-to-ir-string
                   '(def-kernel dt_check (n &out r)
                      (declare #'(int &out (cell int :address-space :global ) => nil))
                      (dotimes (i n)
                        (set! (~ r) (+ (~ r) i))))
                   :debug-p nil))
         (has-loop (search "br label" result)))
    (parachute:true has-loop)))

(parachute:define-test (dotimes-semantic-test var-type-matches-limit)
  "The loop variable takes the type of the limit expression (int -> int, ulong -> ulong)."
  (initialize-compiler :log-level :error)
  (let ((result (compile-crisp-form-to-ir-string
                  '(def-kernel dt_ulong (n &out r)
                     (declare #'(ulong &out (cell ulong :address-space :global ) => nil))
                     (dotimes (i n)
                       (set! (~ r) (+ (~ r) i))))
                  :debug-p nil)))
    ;; ulong is i64 in LLVM IR
    (parachute:true (search "i64" result))))

(parachute:define-test (dotimes-semantic-test zero-iterations-when-limit-zero)
  "dotimes with literal 0 limit compiles without error (loop body never runs)."
  (initialize-compiler :log-level :error)
  (parachute:false
    (handler-case
        (progn
          (compile-crisp-form-to-ir-string
            '(def-kernel dt_zero (&out r)
               (declare #'(&out (cell int :address-space :global ) => nil))
               (dotimes (i 0)
                 (set! (~ r) 99)))
            :debug-p nil)
          nil)
      (error (e) (declare (ignore e)) t))))
