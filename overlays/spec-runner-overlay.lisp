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


;; Endeavour 155.  The spec runner resolves validator names in DIFFERENT packages depending on
;; which pass invokes them — :crisp.compiler for the --ir-target=spv binary path, and
;; :crisp.spec-runner for the in-process paths.  Endeavour 152 hit this with
;; validate-cluster-degrade-warning and settled it the same way: define the name in BOTH,
;; delegating to ONE shared body so the two can never drift.
(defun validate-spv-bf16-coop (spv-path)
  (funcall (find-symbol "VALIDATE-SPV-BF16-COOP" :crisp.compiler) spv-path))

;; tests/run-specs.lisp
;; Endeavour 155.  Same two-package dance as validate-spv-bf16-coop above: --ir-target=spv
;; resolves the validator in :CRISP.COMPILER, while the in-process paths resolve it here, so the
;; name has to exist in both.  The body lives in the compiler overlay next to the SPIR-V text
;; helpers it needs.
(defun validate-spv-fp16-coop (spv-path)
  (funcall (find-symbol "VALIDATE-SPV-FP16-COOP" :crisp.compiler) spv-path))
;; tests/run-specs.lisp  (REPLACES run-single-spec-pass at line 934)
(defun run-single-spec-pass (file flags &optional validator)
  "Execute a single pass of a spec file with specific flags active.
   Extended: --runtime-checks routes to run-spec-runtime-checks-pass;
   --*-math-precision=KEY routes to run-spec-precision-pass."
  ;; NEW: --runtime-checks is handled as a dedicated path — compile with
  ;; runtime assertions enabled and call the validator with the IR string.
  (when (member "--runtime-checks" flags :test #'string=)
    (format t "(RT-Checks)... ")
    (return-from run-single-spec-pass
      (run-spec-runtime-checks-pass file validator)))

  ;; Endeavor 126: precision runs — compile and hand the IR to a precision validator.
  (when (some (lambda (f) (or (search "--force-math-precision=" f)
                              (search "--math-precision=" f)
                              (search "--denormal-handling=" f)))
              flags)
    (format t "(Precision)... ")
    (return-from run-single-spec-pass
      (run-spec-precision-pass file flags validator)))

  ;; Original dispatch (unchanged from base run-specs.lisp):
  (let ((*use-binary*         (or *use-binary*         (member "--use-binary"    flags :test #'string=)))
        (*compile-single-pass* (or *compile-single-pass* (member "--single-pass"  flags :test #'string=)))
        (*compile-debug*       (or *compile-debug*       (member "--debug"        flags :test #'string=)))
        (*compile-differentiate* (or *compile-differentiate* (member "--differentiate" flags :test #'string=)))
        ;; Endeavour 155: honor --hardware-profile=<NAME> in TEST-WITH flags.  Without this the
        ;; flag is SILENTLY DROPPED, and a spec that names a profile compiles without one -- which
        ;; fails with "load-tile into a register-tile requires a hardware profile" while the same
        ;; command line succeeds by hand.  This is the THIRD instance of the class: endeavour 137
        ;; added --ir-target-arch here for the same reason, and 152 found run-spec-ptx-binary
        ;; forwarding exactly one flag and dropping the rest.  Flags in a TEST-WITH list are a
        ;; promise; anything not forwarded should be refused, not ignored.
        (*compile-hardware-profile*
          (let ((hf (find-if (lambda (f) (and (stringp f) (search "--hardware-profile=" f))) flags)))
            (if hf (subseq hf (length "--hardware-profile=")) *compile-hardware-profile*)))
        ;; Endeavor 137: honor --ir-target-arch=<ID> in TEST-WITH flags so the in-process
        ;; PTX/SPV compile gates + compute-capability match the CLI (else :block gates on sm_80).
        (crisp.compiler::*ir-target-arch*
          (let ((af (find-if (lambda (f) (and (stringp f) (search "--ir-target-arch=" f))) flags)))
            (if af
                (intern (string-upcase (subseq af (length "--ir-target-arch="))) :keyword)
                crisp.compiler::*ir-target-arch*)))
        (emit-metadata (member "--metadata" flags :test #'string=))
        (ir-target (cond
                     ((member "--ir-target=spv"    flags :test #'string=) :spirv)
                     ((member "--ir-target=ptx"    flags :test #'string=) :ptx)
                     ((member "--ir-target=llvmir" flags :test #'string=) :llvmir)
                     ((member "--metadata"         flags :test #'string=) :spirv)
                     (t nil))))

    ;; Endeavor 144: skip a SPIR-V pass when this machine cannot do one — either because
    ;; SKIP_SPIRV_TESTS says so, or because the translator is not actually invocable (a
    ;; CUDA-only box: bin/ is gitignored, so llvm-spirv is simply absent).  Detection keeps
    ;; the three SPIR-V entry points (here, COMPILE-WITH, EXPECT-STDERR) consistent.
    (when (and (eq ir-target :spirv)
               (or (and (uiop:getenv "SKIP_SPIRV_TESTS") t)
                   (not (spirv-toolchain-available-p))))
      (format t "SKIP (no SPIR-V toolchain on this machine)~%")
      (return-from run-single-spec-pass t))

    (if *use-binary*
        (cond
          ((eq ir-target :spirv)  (run-spec-spirv-binary file :emit-metadata emit-metadata :validator validator))
          ((eq ir-target :ptx)    (run-spec-ptx-binary file :validator validator :flags flags))
          ((eq ir-target :llvmir) (run-spec-llvmir-binary file :validator validator))
          (t (run-spec-binary file)))
        (cond
          ((eq ir-target :spirv)  (run-spec-spirv-in-process file :emit-metadata emit-metadata :validator validator))
          ((eq ir-target :ptx)    (run-spec-ptx-in-process file :emit-metadata emit-metadata :validator validator))
          ((eq ir-target :llvmir) (run-spec-llvmir-in-process file :validator validator))
          (t (run-spec-lisp-loader file))))))

;; tests/run-specs.lisp  (REPLACES run-spec-spirv-binary at line 1935)
(defun run-spec-spirv-binary (file &key (emit-metadata nil) (validator nil))
  "Runs the binary compiler with --ir-target=spv. Optionally emits metadata and runs a validator."
  (let* ((base-name (if *compile-differentiate* (format nil "~a_grad" (pathname-name file)) (pathname-name file)))
         (bin (get-binary-path))
         (out-path (make-pathname :name base-name :type "spv" :defaults file))
         (args (list (uiop:native-namestring file) "--ir-target=spv"
                     (format nil "--log-level=~a" cl-user::*log-level*))))
    (when (probe-file out-path) (delete-file out-path))
    (when *compile-debug* (push "--debug" args))
    (when *compile-differentiate* (push "--differentiate" args))
    (when *compile-single-pass* (push "--single-pass" args))
    (when emit-metadata (push "--metadata" args))
    ;; Endeavour 155: forward the selected hardware profile.  run-single-spec-pass binds it from
    ;; a TEST-WITH --hardware-profile= flag; without this push the BINARY path would still drop
    ;; it, so --use-binary and the in-process runner would disagree about which profile is active.
    (when *compile-hardware-profile*
      (push (format nil "--hardware-profile=~a" *compile-hardware-profile*) args))

    (multiple-value-bind (output error-output exit-code)
        (uiop:run-program (cons (uiop:native-namestring bin) args)
          :output :string
          :error-output :string
          :ignore-error-status t)
      (declare (ignore output))
      (cond
       ((not (zerop exit-code))
         (format *error-output* "FAIL (Compiler Exit Code ~a)~%~a~%" exit-code error-output)
         nil)
       ((probe-file out-path)
         ;; File generated - now run validator if provided
         (let ((res (if validator
                        (progn
                         (format t "(Validator: ~a)... " validator)
                         ;; For metadata validators, collect .metacrisp files matching this test
                         (let* ((all-meta-files (directory (make-pathname :directory (pathname-directory file)
                                                                          :name :wild
                                                                          :type "metacrisp")))
                                ;; Filter to only files matching this test's name prefix
                                (meta-files (remove-if-not
                                                (lambda (mf)
                                                  (uiop:string-prefix-p (pathname-name file)
                                                                        (pathname-name mf)))
                                                all-meta-files))
                                ;; Match in-process behavior: single file -> pathname, multiple -> list
                                (val-arg (if emit-metadata
                                             (cond
                                              ((null meta-files) out-path)
                                              ((= (length meta-files) 1) (first meta-files))
                                              (t meta-files))
                                             out-path))
                                (sym (find-symbol (symbol-name validator) :crisp.compiler)))
                           (if (and sym (fboundp sym))
                               (if (funcall sym val-arg)
                                   (progn (format t "Validator PASS.~%") t)
                                   (progn (format *error-output* "Validator FAIL.~%") nil))
                               (progn (format *error-output* "Validator fn ~a not found.~%" validator) nil))))
                        (progn (format t "PASS (Generated .spv)~%") t))))
           ;; Cleanup
           (when (probe-file out-path)
                 (unless *keep-work* (delete-file out-path)))
           (dolist (mf (directory (make-pathname :directory (pathname-directory file)
                                                 :name :wild
                                                 :type "metacrisp")))
             (when (uiop:string-prefix-p (pathname-name file) (pathname-name mf))
                   (unless *keep-work* (delete-file mf))))
           res))
       (t
         (format *error-output* "FAIL (No SPV generated)~%~a~%" error-output)
         nil)))))


;; tests/run-specs.lisp  (REPLACES compile-crisp-file-to-spirv)
;;
;; Endeavour 155 -- make --hardware-profile in a TEST-WITH actually REACH the compiler.
;;
;; THE SYMPTOM, and why it was confusing.  A spec whose directive reads
;;     TEST-WITH[--ir-target=spv --hardware-profile=bmg] : validate-spv-fp16-coop
;; failed with
;;     load-tile into a register-tile requires a hardware profile (pass --hardware-profile)
;; while the IDENTICAL flags on the command line compiled fine.  The runner even PRINTS the flag
;; in the pass name, so it is plainly parsed -- it just never arrives.
;;
;; WHY MY FIRST FIX DID NOT WORK.  The earlier override of run-single-spec-pass bound
;; *compile-hardware-profile*, which is the spec runner's own variable for HOIST runs.  The
;; compiler reads a different one, crisp.compiler::*requested-hardware-profile*, and binding THAT
;; in a let would not have worked either: initialize-compiler SETFs it
;;     (setf *requested-hardware-profile* hardware-profile)      ; src/compiler.lisp:1033
;; from its :hardware-profile argument, clobbering any surrounding binding with NIL.  So the value
;; has to travel as an ARGUMENT to initialize-compiler; no binding survives.
;;
;; That is the whole fix.  compile-crisp-file-to-spirv is the in-process SPIR-V entry point (via
;; run-spec-spirv-in-process), and was the one initialize-compiler call site in the runner that
;; needed the profile and did not pass it.
;;
;; THE FOURTH INSTANCE OF THIS EXACT CLASS.  137 found --ir-target-arch dropped, 152 found
;; --metadata dropped, rung 01 found --hardware-profile dropped, and this is its actual cause.
;; The shape is always the same: a flag is parsed for DISPLAY and for routing, but the in-process
;; compile is invoked without it, so the spec silently tests something other than what it says.
;; A directive flag that no code path consumes should be an ERROR rather than a no-op -- worth
;; doing once instead of rediscovering a fifth time.
;;
;; NOTE: compile-crisp-file-to-ptx and compile-crisp-file-to-llvmir have the same omission.  They
;; are deliberately NOT changed here -- no spec currently needs a profile on those paths, and
;; changing an entry point that no failing test exercises is how silent breakage gets introduced.
;; When one does need it, this is the pattern.
(defun compile-crisp-file-to-spirv (filepath &key (emit-metadata nil))
  "Compiles a .crisp file to .spv and returns the output path and metadata paths if successful."
  (let* ((base-name (if *compile-differentiate* (format nil "~a_grad" (pathname-name filepath)) (pathname-name filepath)))
         (out-path (make-pathname :name base-name :type "spv" :defaults filepath))
         (meta-base-path (make-pathname :name base-name :type "metacrisp" :defaults filepath))
         (meta-paths nil)
         (*standard-output* (make-broadcast-stream)))
    (when (probe-file out-path) (delete-file out-path))

    (let (;; Use a FRESH environment for each spec to ensure isolation
          (crisp.compiler::*struct-name-prefix* (format nil "S_~a_" (substitute #\_ #\- (pathname-name filepath))))
          (forms (progn
                  ;; Initialize for SPIR-V, passing differentiate flag so *differentiate-p* is set
                  (crisp.compiler:initialize-compiler :log-level cl-user::*log-level*
                                                      :differentiate *compile-differentiate*
                                                      ;; Endeavour 155: the missing argument -- see header.
                                                      :hardware-profile *compile-hardware-profile*)
                  ;; FIX: Set *package* to :crisp-language to match binary compiler behavior
                  (let ((*package* (find-package :crisp-language)))
                    (with-open-file (stream filepath)
                      (loop for form = (read stream nil :eof)
                            until (eq form :eof)
                            collect form))))))
      (let* ((module (crisp.llvm-bindings:llvm-module-create (pathname-name filepath)))
             (builder (crisp.llvm-bindings:llvm-create-builder)))
        (unwind-protect
            (progn
             (let ((crisp.compiler:*target-backend* :spirv)
                   (crisp.compiler::*emit-metadata* emit-metadata))
               (crisp.compiler:compile-module forms module builder nil nil nil)
               (crisp.compiler:compile-to-spirv module out-path)

               (when emit-metadata
                     (setf meta-paths
                       (crisp.compiler::generate-metadata-for-file filepath meta-base-path
                                                                   :output-targets (list (list :spv out-path))
                                                                   :forms forms))))
             (crisp.llvm-bindings:llvm-dispose-builder builder)
             (crisp.llvm-bindings:llvm-dispose-module module)))))

    (if (probe-file out-path)
        (values out-path meta-paths)
        nil)))


;; tests/run-specs.lisp  (REPLACES run-spec-spirv-in-process)
;;
;; Endeavour 155 -- let a validator on an --ir-target=spv pass actually receive the .spv.
;;
;; THE GAP.  The in-process SPIR-V runner handed the validator META-PATHS, the .metacrisp files.
;; Those only exist when --metadata is on the directive, so a spec written as
;;     TEST-WITH[--ir-target=spv --hardware-profile=bmg] : validate-spv-fp16-coop
;; produced meta-paths = NIL, and NIL flowed straight into (probe-file val-arg).  The result was
;; not a clean diagnostic but an opaque type error from deep inside the runner:
;;     The value NIL is not of type VECTOR when binding #:N-ARRAY
;; which says nothing whatsoever about the actual problem.
;;
;; So there was NO working way to validate an emitted SPIR-V module in process.  The binary path
;; (run-spec-spirv-binary) does pass the .spv, which is why the two paths disagreed and why rung
;; 01 recorded 'the validator is resolved in a different package' as obstacle 1 -- the package was
;; a red herring; the ARGUMENT was the problem.
;;
;; WHY THE FALLBACK IS SAFE.  Any spec reaching this cond branch with no metadata ALREADY crashed,
;; every time, with the type error above.  Nothing can depend on the old behaviour, so falling
;; back to OUT-PATH strictly converts a crash into a working validation.  Specs that do request
;; --metadata are untouched: they still take the first branch.
;;
;; The second added clause covers (NIL) -- a one-element list whose single element is NIL, which
;; the length-1 branch would otherwise pass through as a NIL val-arg.
(defun run-spec-spirv-in-process (file &key (emit-metadata nil) (validator nil))
  (block :runner
    (handler-bind ((error (lambda (e)
                            (format *error-output* "FAIL (Condition: ~a)~%" e)
                            (return-from :runner nil))))
      (multiple-value-bind (out-path meta-paths)
          (compile-crisp-file-to-spirv file :emit-metadata emit-metadata)
        (if out-path
            (let ((res (if validator
                           (progn
                            (log:info "Running Validator: ~a" validator)
                            ;; Determine validation target
                            (let ((val-arg (cond
                                            ((and (listp meta-paths) (= (length meta-paths) 1)) (first meta-paths))
                                            ;; Endeavour 155: no metadata was requested, so the
                                            ;; thing worth validating is the MODULE.  See header.
                                            ((null meta-paths) out-path)
                                            ((and (listp meta-paths) (null (remove nil meta-paths))) out-path)
                                            (t meta-paths))))

                              (if (or (and (pathnamep val-arg) (probe-file val-arg))
                                      (and (listp val-arg) (every #'probe-file val-arg)))
                                  (progn
                                   ;; Dispatch validator
                                   (if (fboundp validator)
                                       (if (funcall validator val-arg)
                                           (progn (format t "Validator PASS. ") t)
                                           (progn (format *error-output* "Validator FAIL. ") nil))
                                       (progn
                                        ;; Try finding it in crisp.compiler package if symbol has no package
                                        (let ((sym (find-symbol (symbol-name validator) :crisp.compiler)))
                                          (if (and sym (fboundp sym))
                                              (if (funcall sym val-arg)
                                                  (progn (format t "Validator PASS. ") t)
                                                  (progn (format *error-output* "Validator FAIL. ") nil))
                                              (progn (format *error-output* "Validator fn ~a not found. " validator) nil))))))
                                  (progn (format *error-output* "FAIL (Metadata Missing: ~a)~%" val-arg) nil))))
                           (progn
                            (format t "PASS (Generated ~a)~%" (file-namestring out-path))
                            t))))

              ;; Cleanup generated artifacts
              (unless *keep-work*
                (when (probe-file out-path) (delete-file out-path))
                (dolist (mp (if (listp meta-paths) meta-paths (list meta-paths)))
                  (when (probe-file mp) (delete-file mp))))

              res)
            (progn (format *error-output* "FAIL (No SPV generated)~%") nil))))))

;; tests/run-specs.lisp
;; Endeavour 155 rung 04: same two-package dance as the other .spv validators.
(defun validate-spv-tile-address-arith (spv-path)
  (funcall (find-symbol "VALIDATE-SPV-TILE-ADDRESS-ARITH" :crisp.compiler) spv-path))

;; tests/run-specs.lisp
;; Endeavour 157.  Same two-package delegation as the 155 coop validators: the spec runner resolves
;; validator names in its own package, while the implementation lives in :crisp.compiler.
(defun validate-spv-split-barrier (spv-path)
  (funcall (find-symbol "VALIDATE-SPV-SPLIT-BARRIER" :crisp.compiler) spv-path))

;; tests/run-specs.lisp
(defun validate-spv-fused-barrier-unchanged (spv-path)
  (funcall (find-symbol "VALIDATE-SPV-FUSED-BARRIER-UNCHANGED" :crisp.compiler) spv-path))
