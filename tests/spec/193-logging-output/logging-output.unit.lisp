;; tests/spec/193-logging-output/logging-output.unit.lisp
;; Endeavour 193 -- structural checks on the UNOPTIMIZED LLVM-IR for the die lowering.  The metal
;; specs prove the behaviour, but CI has no GPU, so BUG 136 (die was llvm.trap -> OpUnreachable,
;; deleted by IGC) is pinned here as well.
(in-package :cl-user)

(defpackage :crisp.test.logging-output
  (:use :cl :parachute))

(in-package :crisp.test.logging-output)

(defun %ir (spec)
  "The LLVM-IR of tests/spec/193-logging-output/SPEC.crisp."
  (crisp.spec-runner::compile-crisp-file-to-ir-string
   (format nil "tests/spec/193-logging-output/~a.crisp" spec)))

(define-test logging-output)

(define-test (logging-output die-is-not-a-trap)
  "die lowers to a CAS on the module-scope record plus a flag store and a return -- never llvm.trap."
  (let ((ir (%ir "01-die-halts-thread-metal")))
    (false (search "llvm.trap" ir) "die must not lower to llvm.trap (BUG 136).")
    (true (search "@__crisp_die_record = addrspace(1) global [4 x i32] zeroinitializer" ir)
          "The die record is a zero-initialised addrspace(1) module global.")
    (true (search "cmpxchg ptr addrspace(1) @__crisp_die_record, i32 0, i32 1 monotonic" ir)
          "The first die site claims the record with a relaxed CAS of site id 1 over 0.")
    (true (search "%die_flag = alloca i32" ir) "A kernel that may die allocates its die flag.")
    (true (search "br i1 %die_won, label %die_fill, label %die_done" ir)
          "Only the CAS winner fills in the record.")
    (true (search "getelementptr inbounds ([4 x i32], ptr addrspace(1) @__crisp_die_record, i32 0, i32 2)" ir)
          "The winner writes its local id into word 2.")))

(define-test (logging-output callee-takes-and-caller-checks-the-flag)
  "A may-die function takes the flag as a trailing ptr; its caller passes it and bails if it is set."
  (let ((ir (%ir "02-die-in-callee-metal")))
    (true (search "@give_up_on_two_ulong(i64 %0, ptr %1)" ir)
          "The may-die callee has the trailing die-flag parameter.")
    (true (search "@give_up_on_two_ulong(i64 %localinvocationid_0, ptr %die_flag)" ir)
          "The kernel passes its die flag to the call.")
    (true (search "%died = icmp ne i32 %die_flag_val, 0" ir)
          "After the call the caller tests the flag.")
    (true (search "die_bail:" ir) "... and has a bail-out block.")))

(define-test (logging-output bounds-checks-die-not-trap)
  "Under --runtime-checks the codegen bounds checks (make-view here) lower through die -- they were
   llvm.trap, a silent no-op on L0 (BUG 136)."
  (let ((ir (let ((crisp.spec-runner::*compile-runtime-checks* t))
              (%ir "23-bounds-check-halts-metal"))))
    (false (search "llvm.trap" ir) "A bounds check must not lower to llvm.trap.")
    (true (search "cmpxchg ptr addrspace(1) @__crisp_die_record" ir)
          "A failed bounds check claims the die record.")))

(define-test (logging-output log-is-a-module-global)
  "Under --logging-output, r-t-output claims its packet with one relaxed 64-bit atomic add on the
   cursor of the module-scope @__crisp_log, and writes only if the packet fits.  Without the flag
   there is no log at all."
  (let ((ir (let ((crisp.spec-runner::*compile-logging-output* t))
              (%ir "31-output-values-metal"))))
    (true (search "@__crisp_log = addrspace(1) global [" ir) "The log is an addrspace(1) module global.")
    (true (search "atomicrmw add ptr addrspace(1) @__crisp_log, i64 7 monotonic" ir)
          "A 7-word message (3 header words + 2 values) is claimed with one relaxed atomic add.")
    (true (search "br i1 %log_fits, label %log_write, label %log_done" ir)
          "The packet is written only if it fits."))
  (false (search "__crisp_log" (%ir "31-output-values-metal"))
         "Without --logging-output, r-t-output compiles away and there is no log."))

(define-test (logging-output no-die-no-machinery)
  "A kernel that cannot die gets no record, no flag and no checks (here: an r-t-assert compiled
   without --runtime-checks, which compiles away)."
  (let ((ir (%ir "20-assert-gone-by-default-metal")))
    (false (search "__crisp_die_record" ir) "No die record without a die.")
    (false (search "die_flag" ir) "No die flag without a die.")))

;;; A quiet parachute failure does NOT gate the runner -- it only notices a LOAD error (see the
;;; unit-test gating note in 120-uniform).  So run the test here and signal on failure.
(let* ((report (test 'logging-output))
       (failures (parachute:tests-with-status :failed report)))
  (when failures
    (error "logging-output: ~d test(s) failed -- the die lowering changed (endeavour 193 / BUG 136)."
           (length failures))))
