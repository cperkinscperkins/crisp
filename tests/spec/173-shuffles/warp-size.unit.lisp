;; tests/spec/173-shuffles/warp-size.unit.lisp
;;
;; Endeavour 173 — (warp-size) unit test.
;;
;; WHY THIS EXISTS, and why spec 01 cannot do its job.
;;
;; (warp-size) resolves to a DIFFERENT VALUE per hardware profile -- 32 with none active, 16
;; under bmg -- so no single E2E spec can assert the value portably.  01-warp-size-uniform
;; therefore asserts the PROPERTY (that it folds, and is uniform enough to serve as a `+`
;; loop limit) and leaves the VALUE to this file, which can bind a profile in process.
;;
;; Two claims, the second being the subtle one:
;;
;;   1. (warp-size) FOLDS TO A LITERAL, and to the profile's :simd-width.  Not "returns the
;;      right number at runtime" -- there is no runtime here.  D2's whole point is that it is
;;      a compile-time constant, because a literal is legal where a runtime value is not (a
;;      loop limit, a (local-size :set-to ...), an operand of a uniformity-checked `+` form).
;;      Asserting `ret i32 16` in the IR is what distinguishes folding from a builtin call.
;;
;;   2. ON PTX THE PROFILE DOES NOT GOVERN.  NVIDIA's warp is 32 lanes by architecture, and
;;      the shfl.sync `c` operand is encoded against the hardware rather than against whatever
;;      profile is selected.  A dual-backend spec compiles the same source with
;;      --hardware-profile=bmg for BOTH targets, so this rule is reachable in ordinary use,
;;      and getting it wrong would silently encode a segment mask against 16 lanes on a
;;      32-lane warp -- wrong answers, not a crash.
;;
;; IN-PACKAGE :crisp.compiler ON PURPOSE.  Parachute resolves :parent in the test's HOME
;; package, so a file with its own package cannot name crisp.compiler::crisp.tests as parent
;; (it fails at LOAD with "Could not find a parent by the name of CRISP.TESTS").  015-cell
;; does the same thing for the same reason.
;;
;; AND THE :parent IS WHAT MAKES IT RUN.  run-specs executes exactly one suite --
;; (parachute:test 'crisp.compiler::crisp.tests).  A define-test without a parent LOADS
;; cleanly, prints PASS for the load, and is then never executed: the unit summary reads
;; Passed: 0 / Failed: 0 while the file asserts nothing at all.
;;
;; RESTORE THE PROFILE AFTERWARDS.  initialize-compiler SETFs the global
;; *requested-hardware-profile*; it is a defvar, not rebound per compile, and unit tests run
;; BEFORE the specs -- so leaving "bmg" set here would leak into every spec that follows.
;; 167's unit test documents the same trap after it cost four unrelated failures in 048.

(in-package :crisp.compiler)

(defun %173-unit-read-crisp (text)
  "Read TEXT as Crisp source -- i.e. in :crisp-language, the package the compiler reads
   kernels in.  Reading it anywhere else interns the operators into the wrong package and
   they are not found."
  (let ((*package* (find-package :crisp-language)))
    (with-input-from-string (s text)
      (loop for f = (read s nil :eof) until (eq f :eof) collect f))))

(defun %173-unit-warp-size-ir (profile)
  "LLVM IR for a function whose entire body is (warp-size), compiled under PROFILE (a
   profile name string, or NIL for none).  Restores the previously requested profile."
  (let ((prior *requested-hardware-profile*))
    (unwind-protect
         (progn
           (initialize-compiler :log-level :off :hardware-profile profile)
           (compile-crisp-form-to-ir-string
            (first (%173-unit-read-crisp
                    "(def-function ws () (declare (return-type uint)) (warp-size))"))))
      (initialize-compiler :log-level :off :hardware-profile prior))))

(defun %173-unit-warp-size-for (profile backend)
  "The resolved lanes-per-warp under PROFILE when compiling for BACKEND."
  (let ((prior *requested-hardware-profile*))
    (unwind-protect
         (progn
           (initialize-compiler :log-level :off :hardware-profile profile)
           (let ((*target-backend* backend))
             (%173-warp-size)))
      (initialize-compiler :log-level :off :hardware-profile prior))))

(parachute:define-test warp-size-tests
                       :parent crisp.compiler::crisp.tests)

(parachute:define-test (warp-size-tests folds-to-the-profile-width)
  ;; No profile: the documented default.
  (let ((ir (%173-unit-warp-size-ir nil)))
    (parachute:true (search "ret i32 32" ir)
                    "no profile: (warp-size) must fold to the literal 32"))

  ;; bmg names :simd-width 16, so the same source folds to a different constant.
  (let ((ir (%173-unit-warp-size-ir "bmg")))
    (parachute:true (search "ret i32 16" ir)
                    "bmg (:simd-width 16): (warp-size) must fold to the literal 16")
    (parachute:false (search "ret i32 32" ir)
                     "bmg: the 32 default must not survive when a profile names a width")
    ;; A folded constant leaves NO call behind.  This is exactly what separates D2 from a
    ;; runtime SubgroupSize builtin, and every downstream use depends on it.
    (parachute:false (search "call" ir)
                     "(warp-size) must fold at analysis time, leaving no call instruction")))

(parachute:define-test (warp-size-tests ptx-is-governed-by-the-architecture)
  (parachute:is = 16 (%173-unit-warp-size-for "bmg" :spirv)
                "SPIR-V under bmg: the subgroup width is the profile's :simd-width")
  (parachute:is = 32 (%173-unit-warp-size-for "bmg" :ptx)
                "PTX under bmg: NVIDIA's warp is 32 by architecture; the profile must not govern")
  (parachute:is = 32 (%173-unit-warp-size-for nil :spirv)
                "no profile on SPIR-V: 32 is the documented default")
  (parachute:is = 32 (%173-unit-warp-size-for nil :ptx)
                "no profile on PTX: 32 either way"))
