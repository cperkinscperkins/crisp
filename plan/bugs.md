
[x] 001 --debug/-g flag causes :debug log to be set. Incorrect. Those should be orthogonal.
[x] 002 function overloads are not resolving correctly. Seems to alwasy choose "last seen".
        tests/def-function-overloads.crisp demonstrates this problem.
[x] 003 %call_tmp = call <cannot get addrspace!> i32 <null operand!>(i32 %x1) 
       appears in LLVM output of let bindings with function calls.
       See bind-f-call in tests/let-bindings.crisp
       Also in the def-function-overloads add_three LLVM-IR gen

[x] 004 reading of 3.14 as a float literal is not working.
[ ] 005 reading of 314 as a long literal is not working ( defaults to int)
        ARCHITECTURAL DECISION.  Rather then infer from return-type, 
        we will probably use suffices on literals.  Need to document that and plan for it.

[x] 006 continued fallout from llvm return type being lists.
    (BUILD-CAST-IF-NEEDED #.(SB-SYS:INT-SAP #X00A501C0) #.(SB-SYS:INT-SAP #X00A00260) (INT) LONG)   <-- (int) is FROM  , whereas long is TO
    I think we need a better solution.  A helper function: get-single-return-type  or get-entire-return-type  
    And use THAT everywhere. rather than all these ad-hoc "first" and "car" calls.
    crisp-type-llvm-type-fn  

[x] 007 illegal_float_to_int_cast.crisp    UNBOUND SLOT error. 
   analyze-cast-expression /   (error 'crisp-type-error :message "Invalid cast: Cannot use 'to-...' for float-to-integer conversion. Use 'truncate', 'floor', 'ceil', or 'round' instead."
                                 :source-location location)


[x] 008  --log-level=off is not working. 


[x] 009  casting and conversion for def-type not working.  See tests/spec/018-def-type/04-casting.crisp

[x] 010  kernel type declaration throwing error when it shouldn't. tests\spec\028-metadata\04-basic-struct.crisp
   
[x] 011 - New Bug Discovered (Bug 011): ❌ When a struct uses a type-aliased field AND has setters generated (from Bug 010 fix), compilation fails with "The function CRISP.COMPILER::EXPLICIT-RETURN is undefined."
Root cause: Macro expansion ordering - setters with (return nil) are being expanded before the analyzer can intercept explicit-return
Workaround: None currently
Tests affected: Any test using both type aliases in structs AND the setter functionality
Note: Tests 04 & 06 work because they don't use type aliases; test 08 fails because it does

[x] 012 - Type Equivalence Issue: The 08-structs-and-aliases.crisp test now gets further but fails with "Type mismatch! Expected III but inferred INT" when calling the setter with an int value.
The type equivalence function (types-equivalent-p) needs to resolve aliases, but my overlay version broke builtin registration. This is getting complex - we need to carefully modify types-equivalent-p without breaking existing functionality.

[x] 013 - Recursive def-type hangs

[x] 015 - scratch cells records, when flattened, should have three slots:
          storage-ptr, storage-bytesize, and cell-offset.
          But, right now, when scratch cells are implicitly added to the parameter
          list, they only have two slots: storage-ptr and storage-bytesize.
          We should a) check that this is only true of SCRATCH CELLS, and not ALL cells.
          b) fix.

[x] 016 - This is part of the metdata for the 01-aliases.crisp
          :declared-signature (("i" :TYPE CRISP-LANGUAGE::III :RANGE (0 0)))
          Note how CRISP-LANGUAGE appears there. It should not. Crisp does
          not expose package names outside itself. 

[x] 017 - the tests\spec\028-metadata\18-implicit-scratch-cell-signature.crisp
         has a scratch cell. While it'll be in the :physical-signature, it is NOT in the :declared-signature. Therefore they are listed separately. This is almost working:
         :implicit-params (("__storage" :TYPE CRISP.COMPILER:STORAGE :ADDRESS-SPACE
                       :LOCAL :ACCESS :READ-WRITE :RANGE (0 1)))

        But note that this is "__storage". . That's wrong.  I suspect this is a consequence of bug 015, and may not be an independent bug. 

[ ] 018 - kernel names are being lower cased, not case preserved. 
        THere may not be a simple fix for this. Kernel names are most definitely interned as symbols now
        and used in tons of lookups.  Changing to string will mean touching a lot of code. 
        Decide what to do. Having lower-case is not world ending.

[ ] 019 - def-kernel-exact does not generate metadata. This is low priority because if someoen 
          id using def-kernel-exact they have their own enqueue infra and wouldn't need ours.
          It's not trivial to fix, because of ... reasons.  Also def-kernel-exact wouldn't 
          even have a :declared-signature anyway. Decide later. 

[x] 020 - make-scratch-cell defaults to :address-space :global, but it should be :local.
  - [x] need to test on CUDA BEFORE fixing. Have to be able to see before / after for both PTX and SPV
  - [x] identify which tests should be manually tested
     - 07-basic-cell.crisp
     - 13-struct-on-kernel-boundary.crisp
     - 19-implicit-scratch-cell-hoisted.crisp
  - [x] reenable 09-address-space.crisp, new validator
     - 

[x] 021 - def-kernel supports arrow type declarations, but not (type a b int) style 
          >>  I suspect valid-type-p returns nil for list-based types like (cell ...) when checked in this context, causing the parser to miss the type binding entirely.

[ ] 022 - (LOW)  seeing extra output from CL when running compiler.  

        .\bin\crisp-compile.exe --log-level=off --ir-target=ptx --metadata .\tests\spec\029-hoist-l0\07-basic-cell.crisp
        ; --- Starting Pass for Target: PTX ---
        COMMON-LISP:WARNING:
        redefining CRISP.COMPILER::MAKE-CELL_INT_GLOBAL_READ-WRITE in DEFMACRO
        COMMON-LISP:WARNING:
        redefining CRISP.COMPILER::MAKE-CELL_INT_GLOBAL_READ-WRITE in DEFMACRO
        COMMON-LISP:WARNING:
        redefining CRISP.COMPILER::MAKE-CELL_INT_GLOBAL_READ-WRITE in DEFMACRO
        ; ...All compilation passes finished.

[/] 023 - is build.lisp returning non zero even when successful?

[ ] 024 - ALL TESTS PASSED is always output from unit tests. Even when there are failures.

[x] 025 - spec unit tests/validators were broken during last feature, and 028-metadata\18-implicit-scratch-cell-signature.crisp regressed but was not caught. 
The .metacrisp names the implicit scratch cell "__storage" which is likely wrong.
What if there are TWO?  They should really be bound by their var name. THOUGH, in fairness,
two different scopes for two different vars coulud have same name.  

Damnit.  We are CONSTANTLY breaking this stuff around the implicit args. and I thought the
validators would help prevent regressions. 

[x] 026 - multiple scratch cells not working.  
I have made new spec tests @19-multiple-scratch-cells.crisp and @24-multiple-scratch-cells-hoisted.crisp 
These tests are currently failing to even compile.

        .\bin\crisp-compile.exe .\tests\spec\028-metadata\19-multiple-scratch-cells.crisp --log-level=off
        ; --- Starting Pass for Target: GENERIC ---

        Crisp compilation failed in .\tests\spec\028-metadata\19-multiple-scratch-cells.crisp:
        Compiler bug: Carrier function CRISP-LANGUAGE::FUN-A is missing implicit argument CRISP-LANGUAGE::JEREMY.


        .\bin\crisp-compile.exe .\tests\spec\029-hoist-l0\24-multiple-scratch-cells-hoisted.crisp --log-level=off
        ; --- Starting Pass for Target: GENERIC ---

        Crisp compilation failed in .\tests\spec\029-hoist-l0\24-multiple-scratch-cells-hoisted.crisp:
        Compiler bug: Carrier function CRISP-LANGUAGE::FUN-A is missing implicit argument CRISP-LANGUAGE::ABERFORTH.


 However, even after they are fixed they STILL need proper validators. THe validators should check:
  - the LLVM-IR has the right number of arguments for the kernel (seven, 3 for each scratch, plus 1 actual)
  - the .metacrisp file has the correct :physical-signature and :implicit-params. 
  - the .metacrips indicates they are :local storage.
  - the hoist version should ensure that it compiles. 



[ ] 027 - memory leak in spec runner.  The psec runner has an unwind-protect and if there are LOTS of errors then they
backup leading to a freeze. It exhausts memory during teardown ( LLVM objects bypass their cleanup handler on the error path).

[/] 028 - IGC (Intel Graphics Compiler) miscompiles functions with array return types.
    Affected tests: 060-array/15-hoist-struct-with-array, 060-array/18-hoist-cell-of-struct-with-array
    (both marked validate-l0-compile-only as a result).

    Symptom: zeModuleCreate succeeds (SPIR-V is accepted). Kernel executes without error.
    But any function that returns a TypeArray (e.g. values__data_arr returning [4 x i64])
    produces all-zero values at runtime. Functions returning scalars or structs work correctly.

    Root cause stack:
      - Crisp generates accessor helpers like `values__data_arr(%DATA-ARR) -> [4 x i64]`
        using LLVM `extractvalue` + `ret [4 x i64]`. Correct LLVM-IR.
      - llvm-spirv translates this to a SPIR-V function with TypeArray return type.
        Legal per the SPIR-V spec; zeModuleCreate accepts it.
      - IGC JITs this to GPU machine code incorrectly. Array return values are silently zero.

    Reproducers: tests/spec/060-array/15-hoist-struct-with-array.ll
                 tests/spec/060-array/15-hoist-struct-with-array.spv
    These are the minimal reproduce cases to send to Intel with a bug report.
    Bug reported to Intel: 2026-04-01.

    Compiler workaround (Part 1, 2026-04-01, overlays/crisp-compiler-overlay.lisp):
      When (~ (accessor~ s) idx) is compiled and the accessor returns (array T N), the
      codegen now emits a two-level GEP directly into the struct's alloca instead of
      calling the accessor function:
        Before: call [4 x i64] @values__data_arr(%DATA-ARR %s4) + spill + GEP
        After:  getelementptr %DATA-ARR, ptr %s, 0, field-idx (no function call)
      Implemented via %try-inline-struct-array-field-ptr + redef of generate-node-ir
      (semantic-aref). See also: tests/spec/061-place-semantics/DESIGN.md for the
      broader architectural direction this workaround points toward.

    Compiler workaround (Part 2, 2026-04-01, overlays/crisp-compiler-overlay.lisp):
      Before calling llvm-spirv, %remove-dead-array-returning-functions scans the module
      for functions with array return types that have no uses (confirmed via LLVMGetFirstUse),
      and deletes them with LLVMDeleteFunction. compile-to-spirv is redefined in the overlay
      to call this before writing the .temp.ll file. For test 15, both values__data_arr and
      _values__data_arr are found, confirmed no-uses (Part 1 removed all call sites), and
      deleted. The SPIR-V module fed to IGC contains only the kernel function.

    Hardware validation (2026-04-02): BUFFER c reads back 0. Part 2 confirmed working
    (values__data_arr and _values__data_arr deleted from SPIR-V module), but the bug is
    broader than TypeArray return types alone. IGC also miscompiles a struct kernel parameter
    whose fields include a TypeArray — i.e. %DATA-ARR = { [4 x i64] } passed by value. The
    struct arrives in the kernel as all-zeros regardless of what the host set. This is a second
    facet of the same IGC bug. LLVM-IR, SPIR-V, and host code are all correct.

    Decision: test 15 remains validate-l0-compile-only indefinitely. Crisp will not alter its
    struct-at-kernel-boundary semantics to work around an IGC JIT bug. The feature is primarily
    targeted at def-record (which uses scalar/register layout), not def-struct with array fields.
    The Intel bug report (filed 2026-04-01) should include this second reproducer.

    Test 18 (cell-of-struct-with-array) also affected by bug 029 (write-back), so it
    remains validate-l0-compile-only regardless of this fix.

    Note: This could in principle be tested on NVIDIA via PTX (--ir-target=spv not needed),
    e.g. using a Jupyter notebook with CUDA. A task for another day.
    Follow Up: It _WAS_ tested and the PTX works.

[x] 029 - Cell-of-array and cell-of-struct-with-array write-back is broken at the compiler level.
    Affected tests: 060-array/17-hoist-cell-of-array (redesigned as read-only to work around),
                    060-array/18-hoist-cell-of-struct-with-array (compile-only).

    Symptom: (set! (~ (~ c) N) val) where c is a cell-of-array, or
             (set! (~ (values~ (~ c)) N) val) where c is a cell-of-struct-with-array,
             stores to a local alloca instead of back to the global USM pointer.
             The write never reaches GPU memory.

    Root cause: The cell dereference (~ c) loads the array/struct by value into a local temp.
    The subsequent element write targets that local copy, not the original addrspace(1) pointer.
    A proper fix requires a store-back through the original pointer after the element mutation,
    similar to how a C++ reference or pointer-based write would work.

[/] 030 - IGC (Intel Graphics Compiler) SROA-aliases sibling float allocas in differentiable kernels.
    Affected tests: 056/01-basic-struct-meta (was failing on metal as part of endeavor 103 phase B,
                    now passes via the workaround below);
                    056/03-struct-with-ct-meta (still blocked — broader form of the same bug,
                    workaround not sufficient; directive omitted with a note pending Intel fix).

    Symptom: A differentiable kernel whose shadow-struct write builds a {float, float} aggregate
    from two (or more) sibling per-field-adj allocas writes the SAME value to every slot of the
    aggregate.  E.g. on 056/01 with point={x float, y int}, the chain rule produces
    p_x_adj=4.0 and p_y_adj=3.0 (verified by reading the LLVM IR), but the grad cell reads back
    as {4.0, 4.0} on Intel Arc B580 / IGC driver 32.0.101.8737.

    Cross-check: the same LLVM IR translated to PTX via the NVPTX backend produces correct
    output (two distinct register sources feed the two stores).  So the IR is well-formed; the
    bug is downstream of Crisp, in either the LLVM-SPIRV translator's optimizer or IGC's JIT.

    Minimal reproducer: put_temp_files_here/igc-bug-report/ contains
      - bug.ll      : 108-line LLVM IR with no Crisp-specific types
      - bug.spv     : translated via the bundled llvm-spirv (LLVM 22.0.0git)
      - bug.ptx    : NVPTX output proving the IR is correct
      - loader.cpp  : Level Zero host that runs bug.spv and prints the 8 output bytes
      - README.md   : description, system info, reproduce steps
    Bug to be reported to Intel 2026-05-18 (Monday).

    Compiler workaround (2026-05-16, overlays/):
      - overlays/crisp-llvm-bindings-overlay.lisp: bind LLVMSetVolatile.
      - overlays/crisp-compiler-overlay.lisp: new compiler-internal pseudo-op
        (crisp.compiler::%volatile-read SYM), an analyzer that tags the underlying
        var-read in *volatile-var-reads*, a generate-node-ir override on semantic-var-read
        that calls LLVMSetVolatile on the load when tagged, and an updated
        %build-shadow-ctor-form that wraps each leaf adj sym in (%volatile-read ...).
      Surgical: only the shadow-write's leaf-adj loads emit `load volatile`; chain-rule
      intermediates remain non-volatile.  This is enough for 056/01.

    Workaround insufficiency (2026-05-16): 056/03 has 7 chain-rule intermediate adj allocas
    plus the 4 per-field leaves.  The workaround leaves the intermediates non-volatile, and
    IGC SROA-aliases THEM too — the chain rule breaks before reaching the leaves.  Symptom:
    p1.x analytical reads back as 1.0 (= seed_grad) instead of 5.0.  Broadening the
    workaround to mark every adj load volatile is feasible but more invasive; deferred
    pending the Intel fix.

    When IGC ships the fix:
      - Remove the %volatile-read pseudo-op and LLVMSetVolatile binding from the overlays.
      - Re-tag 056/03-struct-with-ct-meta with its full VERIFY-AUTODIFF directive.
      (Location note: the workaround was folded out of overlays/ into src/ at some point
      after this was written -- it now lives in src/analysis/core.lisp (*volatile-var-reads*,
      analyze-%volatile-read-expression), src/codegen.lisp (the two LLVMSetVolatile sites)
      and src/autodiff.lisp (%build-shadow-ctor-form).  Remove it from THERE.)

    RETESTED 2026-08-14 (bug sweep).  STILL BROKEN, and the driver hypothesis is now dead:
    the GPU driver has advanced TWICE since this was filed, 32.0.101.8737 -> 32.0.101.8864
    (dated 2026-07-16), and both the minimal reproducer and the real spec fail identically.

      - Minimal repro rebuilt and rerun on 8864: still {4.0, 4.0}, expected {4.0, 3.0}.
      - 056/03 with its VERIFY-AUTODIFF directive temporarily restored, on BMG:
            p1.x: analytical=1.0            numerical=4.9972534   (expected 5.0)
            p2.x: analytical=1.05510146e-29 numerical=2.9983518   (expected 3.0)
        Note the NUMERICAL column is correct -- the forward kernel is fine, only the
        backward is miscompiled.  p1.y=6.0 came back CORRECT, so it is not a blanket
        failure; one sibling aliases and its neighbour does not.

    THE TRANSLATOR IS EXONERATED -- this was left open above ("either the LLVM-SPIRV
    translator's optimizer or IGC's JIT") and is now settled as IGC.  Three checks:
      1. bug.ll re-translated with the current bundled llvm-spirv -> output is
         BYTE-IDENTICAL to the bug.spv committed in May.  The translator has not
         changed and is not sensitive to anything we have done since.
      2. bug.spv disassembled (llvm-spirv -to-text, see igc-bug-report/bug.spt): the
         SPIR-V is CORRECT.  Four distinct `Variable`s (32 33 34 35); two distinct
         `Load`s (%55 from 34, %56 from 35) feeding CompositeInsert at indices 0 and 1.
         The distinction the device loses is still present in the SPIR-V we hand it.
      3. 056/03's backward LLVM IR at HEAD, traced by hand: anf-t-1_adj=5.0,
         anf-t-2_adj=3.0, p1_y_adj=6.0, p2_y_adj=4.0 -- all four correct.  Worth stating
         because the AD engine was rewritten underneath this bug twice since May
         (endeavour 145's VJP registry, 149's primal replay) and the old "IR is correct"
         claim could no longer be assumed.

    WHERE THE ALIASING ACTUALLY BITES (refines the note above): p1.x reads back as 1.0,
    which is the value held by anf-t-3_adj / -6_adj / -7_adj -- i.e. the INTERMEDIATE
    chain-rule adjs collide, not the leaves.  That is exactly why the leaf-only volatile
    workaround is sufficient for 056/01 and not for 056/03, and it means any broadened
    workaround has to cover intermediates.

    OPTION ON THE TABLE (not taken yet, wants a decision): broaden %volatile-read from
    the leaf adjs to EVERY adj read.  Deferred in May "pending the Intel fix"; that fix
    has now not arrived across two driver releases, so the deferral is worth revisiting.
    Cost is real -- volatile defeats mem2reg/SROA promotion of the adj allocas, so every
    Intel backward kernel gets slower, not just the broken ones.  056/03 is a direct
    pass/fail oracle for whether it even works.  Measure before adopting.

[x] 031 - Intel BMG OpenCL ICD breaks VERIFY-AUTODIFF forward FD step.  Level Zero
    CLOSED 2026-08-14 (bug sweep).  Closed as ROUTED AROUND, not as repaired: the
    OpenCL ICD defect is Intel's and was never fixed by us, but nothing in Crisp
    drives OpenCL any more (endeavor 112 ported the runner to Level Zero), so it
    cannot affect us.  Re-verified today on driver 32.0.101.8864 -- all four
    affected specs pass under --differentiate:
      092-dotimes/07-diff-float-accum            PASS
      093-loop-vector-stride/04-diff-scale       PASS
      105-tensor-and-grid-stride/12-diff-tensor-sum  PASS
      107-differentiate-loop-and-stride/01-elemwise-scale  PASS
    The bug-report folder at put_temp_files_here/intel-bmg-opencl-regression/
    remains filed-and-ready if we ever want to send it; it is optional.
    REOPEN ONLY IF an OpenCL runtime is reintroduced (VERIFY-AUTODIFF still has an
    :opencl runtime selectable by directive -- see verify-autodiff-runtime-selection).

    is unaffected — diagnosed 2026-05-23 via standalone L0 probe.  See
    put_temp_files_here/bmg-bug-031/.
    The driver update around 2026-05-19 (immediately before endeavor 111 Phase 0)
    almost certainly caused the regression on the OpenCL side.  Not yet reported to
    Intel — see Status / next steps below.

    Affected tests (all VERIFY-AUTODIFF specs that worked before the driver update):
      - 092-dotimes/07-diff-float-accum
      - 093-loop-vector-stride/04-diff-scale
      - 105-tensor-and-grid-stride/12-diff-tensor-sum
      - 107-differentiate-loop-and-stride/01-elemwise-scale
      - 109-tile-stride-hardware-stride/15-diff-tile-stride
        (deleted in endeavor 111 Phase 0; will be reintroduced after workgroup-stride lands
        and is subject to the same driver bug until then)

    Symptom: deterministic, reproduces individually with
      `sbcl --script .\tests\run-specs.lisp --differentiate --filter=07-diff-float-accum`
    The analytical gradient (read back from the backward kernel) is correct, but the
    numerical FD value computed by running the forward kernel at x ± h returns garbage.
    Example from 092/07 (expected: analytical=5.0, numerical≈5.0):
      Running Spec: 07-diff-float-accum (Verify-Autodiff)... FAIL (FD vs analytical | atol=0.005):
        x: analytical=5.0 numerical=7502.499 diff=7497.499

    Diagnosis pointers:
      - Compiler output is correct: the analytical-side backward kernel produces the
        expected gradient, so SPV generation and backward-kernel codegen are fine.
      - Failure is in forward-kernel execution on the device.  Either the output buffer
        is not being initialized between launches, or the kernel is being JIT'd with a
        bug that yields wildly wrong arithmetic.
      - Same SPV was passing before the driver update.  Pre-update baseline (per memory
        snippet) was 693/693 E2E + the same VERIFY-AUTODIFF specs PASS.

    Status (2026-05-23): standalone Level Zero loader at
    put_temp_files_here/bmg-bug-031/loader.cpp dispatches the EXACT SAME SPV pair
    (092-dotimes/07-diff-float-accum forward + _grad) on BMG and produces correct
    results:
      f(x+h) = 15.005   f(x-h) = 14.995
      FD numerical df/dx  = 4.99916  (within atol 5e-3)
      Backward analytical = 5.0      (exact)
      MATCH
    Since both runtimes JIT through IGC, the SPV and the GPU machine code are not
    the regression.  The bug is in Intel's OpenCL ICD layer (command-queue
    dispatch / argument binding / buffer state — something the L0 path skips).

    Path forward (Phase 1c.2): port tests/verify-autodiff-runner.lisp from OpenCL
    to Level Zero.  The loader.cpp covers every L0 verb the runner needs (USM alloc,
    kernel arg set, group dispatch, sync).  Once ported, all five affected specs
    should come back to life under VAD.

    No Intel bug to file as a compiler-side reproducer — the OpenCL ICD regression
    is in Intel's domain to track via their own telemetry.  Worth flagging informally
    if we have a contact, but no contained-repro report is owed.

    Update (2026-05-23): bug-report folder at put_temp_files_here/intel-bmg-opencl-regression/
    ready to file (forward.spv + backward.spv + loader_l0.cpp + loader_opencl.cpp + README.md;
    no Crisp jargon).  Runner has been ported to Level Zero (endeavor 112), all four
    affected VAD specs PASS again under --differentiate, suite back to 716/716 green on
    both passes.  Intel filing is now optional cleanup, not a blocker.

[x] 032 - AD gradient drops scalar factor through workgroup-stride inside tile
    pipeline.  Discovered 2026-05-23 while adding VERIFY-AUTODIFF coverage to the
    111 specs (endeavor 112 Phase 1c.2.f).  Fixed 2026-05-24.

    Repro: tests/spec/111-load-and-store-tile/15-ad-tile-scale-1d.crisp with the
    VERIFY-AUTODIFF directive enabled.  Kernel is

      (let ((tile (make-scratch-vector float 4)))
        (load-tile-at A tile (0))
        (workgroup-stride tile (lx)
          (set! (~ tile lx) (* 2.0f (~ tile lx))))
        (store-tile-coords tile C (0)))

    forward computes C[i] = 2 * A[i], so f(A) = sum_i C[i] = 2*sum_i A[i] and
    df/dA[k] = 2.0 for every k.

    On metal under the L0 runner: numerical (FD) reports ~2.0 correctly, but
    analytical (backward) reports exactly 1.0 — the workgroup-stride scale factor
    of 2 is silently dropped from the gradient.  The fact that the result is
    exactly 1.0 (not 0, not some small drift) suggests the scale step is being
    treated as identity by the AD pass rather than its derivative not being
    propagated.

    Suspect: %workgroup-stride-bwd interaction with load-tile-at-bwd /
    store-tile-coords-bwd.  Either the workgroup-stride body's adjoint is being
    overwritten by load-tile-at-bwd's accumulate-into-tile_ADJ step, or the
    transform-on-tile pattern is not being walked by generate-backward-walk.

    Status: not blocking.  111/15 is currently a compile-only spec (no VERIFY-AUTODIFF
    directive) with a TODO comment pointing at this bug entry; the underlying compile
    + AD passes complete, only the on-metal gradient is wrong.  Tracked for follow-up.

    Resolution (2026-05-24): the actual bug was a stack of four AD-walker holes
    around WHEN / UNLESS / local-scratch tiles, each one masking the next.  All
    four fixes are in overlays/crisp-compiler-overlay.lisp:

      1. generate-backward-walk's process-form had no WHEN or UNLESS clause, so
         workgroup-stride bodies (which expand to WHEN guards) were skipped
         entirely by the AD walker.  Added: rewrite WHEN to (if c body nil) and
         UNLESS to (if c nil body), then route to the existing IF clause.

      2. process-form's SET! clause only emitted backward when the target was
         in OUTPUTS; for set! into a local-scratch tile (target neither input
         nor output) it fell through to (t nil) and emitted nothing.  Added
         a third gated branch that emits the consume + reset pair (val_adj +=
         tile_ADJ[indices]; tile_ADJ[indices] := 0).  Gated on the new
         scratch-tile-syms hash table so unrelated targets keep old behavior.

      3. %handle-single-value-backward's (~ ...) clause routed indexed reads
         on non-input sources through the scalar fallthrough -- emitting
         (set! ,(local-adj src) ...) which both polluted adjoint-map with src
         and emitted a scalar add into what was actually a tensor.  The wrap-
         let then bound (src_ADJ 0.0), shadowing the auto-allocated scratch
         tensor binding for src_ADJ.  Added a fourth branch that emits an
         indexed add into src_ADJ when src is in scratch-tile-syms.

      4. %collect-locally-bound-vars walked LET / DOTIMES / IF / PROGN but
         not WHEN / UNLESS, so adj allocas for vars bound inside a WHEN body
         (e.g. the ANF temps for the workgroup-stride's per-iter scale step)
         were missing from the DOTIMES iter-local-reset list.  They
         accumulated across iterations and produced exactly-scaled-wrong
         gradients (numerical=2.0, analytical=6.0 for the 4-iter case).
         Added WHEN / UNLESS clauses to %collect-locally-bound-vars.

    All four functions had to be redefined whole in the overlay (lexical
    scoping means inner (cond ...) clauses can't be patched independently).
    The fixes should merge cleanly back to src/autodiff.lisp.

    Confirmed by tests/spec/111-load-and-store-tile/15-ad-tile-scale-1d.crisp
    which is now a full VERIFY-AUTODIFF spec.  Suite 716/716 on both default
    and --differentiate.
[x] 033 --debug/GENERIC c-t accessor emits an env-dependent garbage-typed return.
        FIXED 2026-08-14 — see "FIXED" below.  The title and the whole first half of this
        entry describe SYMPTOMS, not the bug: it is neither about c-t accessors nor
        env-dependent.  Kept verbatim as a record of what the symptoms looked like.
        Under `--debug` (no -O0 stripping), a 2D-float matrix's c-t accessor functions
        (align__ / contiguous_term__tensor_float_2_global_compact_last) survive to
        clang verification. Their body builds a DEAD tensor (param marshalling) then
        `ret i32 0` — but the return constant's TYPE is fragile: locally it prints
        `ret i32 0` (valid), on the CI build it printed `ret bfloat 0xR8000000000000000`
        (a mistyped constant) -> "value doesn't match function result type 'i32'".
        Surfaced by 132-mma-fundamentals/01 (first plain 2D-float-matrix GENERIC spec
        in the CI --use-binary --debug pass). NOT caused by the MMA work.
        NOT reproducible: clean + deterministic on Windows LLVM-21 AND in a CI-matching
        Linux+LLVM-21 Docker container -> appears to be build-heap-dependent
        uninitialized memory (the garbage bytes depend on the specific compiled
        crisp-compile binary, not the source). Likely fix: these dead c-t accessor
        functions should not be emitted as runtime bodies (c-t values resolve at
        compile time), OR the return constant must be built with an explicit i32 type
        rather than a resolved-type that can read uninitialized memory. Verifiable
        locally for no-regression even without reproducing the garbage.

    UPDATE (root cause narrowed): it's a null/garbage pointer into a DIBuilder call in
    generate-debug-info (src/codegen.lisp) — a genuine MEMORY FAULT under --debug, not
    mere garbage.  On CI (Linux) it corrupts into a garbage-typed `ret` that clang/llc
    reject; on our Windows build the SAME class of bug crashes ("Unhandled memory fault
    at #x6").  LOCAL REPRO FOUND: `crisp-compile --debug tests/spec/056-struct-at-kernel-
    boundary/07-struct-with-ct-hoist.crisp` memory-faults on Windows (compiles clean
    without --debug).  Which spec faults is BUILD-HEAP-DEPENDENT (CI hits 01; Windows
    hits 056/07).  The fault is in LLVMDIBuilderCreateFunction for a kernel that has a
    struct param / void return (di-file and di-fn-type are non-null at the call, so the
    bad pointer is deeper — likely the struct->di-type via create-basic-type with a
    bad size, or a null Scope).  One contributing latent bug: get-or-create-di-type
    returns a raw (cffi:null-pointer) for the :void category (codegen.lisp ~L28), which
    is packed into the DIBuilder param-type array — but replacing that alone did NOT fix
    056/07, so there's a second null source in the struct/kernel debug-type path.
    MITIGATION shipped: SKIP-WITH[--debug] on the MMA specs (01/02).  Proper fix (make
    generate-debug-info null-safe for struct params / void, and resolve enum/struct
    di-types correctly) is a focused follow-up, now locally reproducible via 056/07.

    UPDATE 2026-07-17 (Endeavor 138 — a SECOND null-site, in make-view codegen):
    The first --binary --debug CI pass over 138 memory-faulted on the RING specs
    01/03/06 (make-async-barrier-ring / ring-get).  This is the SAME --debug DIBuilder
    fault family, but NOT the function-signature path above — isolated on Windows:
      - `crisp-compile --ir-target=ptx --debug` of a rank-3 make-scratch-tensor with NO
        ring-get  -> compiles clean (exit 0).
      - the SAME kernel WITH `(ring-get ...)` in the body  -> memory fault at #x5 / #xFFF…
    So `ring-get` -> `semantic-make-view` codegen creates a bad DIBuilder node (a debug
    LOCATION or a local-var/type node) that only faults at `llvm-di-builder-finalize`
    (the crash bottoms out in COMPILE-FILES' unwind-protect CLEANUP -> finalize, not in
    codegen proper).  A plain make-scratch-matrix (no view) is fine, so the site is the
    make-view path specifically (`%get-di-location` / the offset-node debug loc, or a
    view-type di-type).  Build-heap-dependent WHICH ring spec faults: the local Windows build
    crashed on 01/03/06, but CI's Linux build crashed on 05 (which passed locally) — so the
    faulting SET varies by build; you cannot skip just the locally-observed subset.
    MITIGATION: SKIP-WITH[--debug] on ALL 138 ring/make-view specs (01/02/03/04/05/06), like
    the 132 cluster.  The errors/* specs need no skip — they fail at ANALYSIS (before any
    make-view debug codegen).  Proper fix should audit make-view codegen for null/garbage
    DIBuilder args in addition to generate-debug-info.  (General caution: any spec exercising
    make-view — incl. make-cell/vector/matrix/tensor outside 138 — could surface this on some
    build under --debug --binary until 033 is actually fixed.)

    META (why this stayed hidden): the IN-PROCESS spec runner calls compile-module with a
    NULL di-builder (run-specs.lisp:766) — so in-process `--debug` generates NO debug info
    and tests nothing.  Only `--use-binary` forwards `--debug` to crisp-compile.exe and
    actually exercises the debug path.  Wiring debug-p into the in-process runner would let
    the cheap path catch these (separate follow-up).

    2026-08-12 (endeavour 146): two more data points, and a PLATFORM SPLIT worth recording.

    - 145/18-ring-staged-vjp-bmg faults on BOTH Linux (CI, ubuntu-latest) and Windows —
      "Memory fault at address 5".  It was one of only four specs in 145 without the skip;
      the other three (14, 15, 17) are clean, so the trigger is the scratch RING under
      --debug specifically.  Now carries SKIP-WITH[--debug] like its 13 siblings.
      VERIFIED PRE-EXISTING, not assumed: reproduced identically with src/ and overlays/
      checked out at the 145 merge (5a6eebd) and rebuilt.

    - 056-struct-at-kernel-boundary/07-struct-with-ct-hoist faults on WINDOWS ONLY —
      "Memory fault at address 6" — and PASSES on the CI Linux runner (which reported
      963/964 with 145/18 as the sole failure).  Deliberately NOT skipped: a skip would
      also suppress it on Linux, where it works, and cost real coverage to silence a
      local-only symptom.  Consequence to know about: the full `--use-binary --debug`
      phase cannot go green on a Windows dev box until 033 is fixed, even when CI is green.
      Do not "fix" that by adding a skip.

    The address varying with the spec (5 here, 6 there) is consistent with the
    garbage/null DIBuilder-arg theory above rather than one specific null pointer.

    FIXED 2026-08-14.  It is NOT a DIBuilder null/garbage-argument bug.  Every theory in the
    notes above was tested and cleared; the whole "bad pointer into a DIBuilder call" framing
    was wrong, and the last paragraph's inference from the varying fault address was wrong too.

    ROOT CAUSE: LLVM's IRBuilder CONSTANT-FOLDS.  An arithmetic build call whose operands are
    both compile-time constants does not produce an instruction -- it returns a Constant.  In
    056/07 the `:c-t` struct fields make (* 2.0 3.0) fold to the Constant `float 6.000000e+00`,
    and %ATTACH-DEBUG-LOC then handed that to LLVMInstructionSetDebugLoc, whose implementation
    is an UNCHECKED unwrap<Instruction>(Inst)->setDebugLoc(...).  Undefined behaviour; on
    Windows it dereferences a garbage vtable and dies at #x6.

    MEASURED at the attach site with LLVMIsAInstruction / LLVMIsAConstant:

        [attach] node=SEMANTIC-MUL   INSTRUCTION?=NO   CONSTANT?=YES
                 value = float 6.000000e+00                      <-- the fold
        [attach] node=SEMANTIC-CALL  INSTRUCTION?=yes  CONSTANT?=no
                 value = %call_tmp = call float @x__point(%POINT %p15)

    Skipping the attach for the non-instruction let the SAME compile run to completion through
    llvm-di-builder-finalize.  Fix = bind LLVMIsAInstruction (llvm-bindings overlay) and guard
    %ATTACH-DEBUG-LOC with it (compiler overlay).  The DILocation is still created and returned,
    so callers that thread it are unaffected; a folded constant simply has no instruction to
    carry a location.

    "BUILD-HEAP-DEPENDENT" IS WRONG and cost real time -- it is deterministic, and keyed on
    whether a spec contains FOLDABLE CONSTANT ARITHMETIC.  That also unifies the symptom family
    the notes above treated as separate: the 138 make-view / ring-get faults fold constant
    offsets the same way, and CI's "garbage-typed ret" is the same UB landing differently on
    another platform.  There was never a second null source.

    HOW IT WAS FOUND, since the notes above chased the wrong call for months: wrap the DIBuilder
    bindings so each logs ITS ARGUMENTS AND FLUSHES BEFORE CALLING, then read the last line.
    The first pass "proved" the fault was inside LLVMDIBuilderCreateFunction -- but only because
    LLVM-SET-SUBPROGRAM and the debug-LOCATION calls had not been wrapped.  With those added,
    generate-debug-info returns normally and the fault moves to %ATTACH-DEBUG-LOC.  If you are
    ever tempted to conclude "the fault is in call X" from a trace, first confirm there is no
    UNWRAPPED call between X and the crash.

    A SEPARATE LATENT BUG, found on the way and NOT the cause (verified -- correcting it alone
    still faulted): every size_t length in the DIBuilder bindings is declared :unsigned-int,
    i.e. 32-bit where LLVM reads 64 -- llvm-di-builder-create-file (x2),
    -create-compile-unit (x5), -create-function (x2), -create-basic-type (x1).  Worth fixing on
    its own.  (num-parameter-types IS `unsigned` in the C API and is correct as-is.)

    RETESTED 2026-08-14 (bug sweep).  STILL BROKEN, unchanged.  The documented local repro
    still faults identically at HEAD:
        ./bin/crisp-compile.exe --debug tests/spec/056-struct-at-kernel-boundary/07-struct-with-ct-hoist.crisp
        -> Unhandled memory fault at #x6  (exit 1)
    Same address as recorded, so the faulting site has not moved with the current build heap.
    This remains the bug gating a green --use-binary --debug phase on a Windows dev box, and
    the standing instruction above still applies: do NOT silence 056/07 with a skip, because
    it passes on the CI Linux runner and a skip would cost that coverage too.

[x] 034 - CUDA multi-K-step SLM-staged tiled matmul miscomputes with non-uniform inputs.
        Discovered by the Endeavor 134 on-metal MMA test harness (host-reference C=A·B via
        the hoist's --mma-test) on RunPod (RTX), 2026-07-08.  FIXED 2026-07-08.

        ROOT CAUSE (not what the title guessed - not multi-K-step, not the kernel/codegen):
        the CUDA HOIST's %cuda-emit-local-scratch-tensor-arg hardcoded EVERY local scratch
        tile's shared-memory offset to 0, so a kernel with >1 SLM tile (06's A-tile + B-tile)
        had them fully ALIAS.  The kernel stages A-tile (128 floats), then stages B-tile at
        the same offset 0, clobbering A-tile elements 0-63 = rows 0-7.  So C's top M-half was
        wrong, bottom half (rows 8-15, elements 64-127) correct.  CUDA-only (L0 gives each
        local arg a separate zeKernelSetArgumentValue(nullptr) SLM region).  Masked by the old
        A=B=1 benchmark (clobbering A with identical B data is invisible).

        DIAGNOSIS METHOD (fast, no GPU needed): computed the host reference locally and diffed
        it against the device BUFFER c from the pod log -> rows 8-15 exact, rows 0-7 wrong with
        a period-3 (B-structure) pattern -> elements 0-63 = B-tile footprint -> checked the
        generated .cu: both a_tile_ptr=0 and b_tile_ptr=0 -> confirmed in PTX (both tile bases
        feed ld.shared from param=0).

        FIX (overlays/hoist-cuda/crisp-hoist-cuda-overlay.lisp, commit 8f3168b): give each
        local tile a running CUMULATIVE byte offset (*cuda-shared-scratch-offset*, reset per
        kernel in emit-kernel-args).  The launch already allocates the summed size
        (compute-total-shared-bytes), so no other change needed.  b-tile@0, a-tile@256,
        total 768 = launch alloc.

        VERIFIED ON METAL (RTX, RunPod, 2026-07-08): 132/06 BUFFER c now == host reference
        exactly; 132-mma-fundamentals suite 11/12 -> 12/12.  Local suite 867/867 (06 SKIPs
        without nvcc).  CAVEAT left in the overlay comment: raw cumulative sizes assume uniform
        element size across tiles; a mix of 4- and 8-byte tiles would need per-tile alignment
        plus a matching compute-total-shared-bytes.

        SYMPTOM: tests/spec/132-mma-fundamentals/06-tiled-matmul.crisp (a synchronous
        SLM-staged tiled matmul, C[16x8] = A[16xK].B[Kx8], K a runtime multiple of 8) is
        MMA_WRONG under the harness with K=16 (2 K-steps).  Hand-check C[0][0]: reference
        = 30 (Sum_{k=0..15} (k%5)*((8k)%3)), device returned 13.

        SCOPE / what still works (so this is a NARROW bug, not generic):
          - 132/04, 05, 09 (CUDA, register-only, SINGLE K-step) all MMA_CORRECT.
          - 132/09 with MMA-SCALE 2 correct (C[0]=32=2x16), so accum-op / scale path is fine.
          - 133/12-tiled-matmul-bmg (L0/BMG, ALSO SLM-staged, 2 K-steps, shape 8 16 8) is
            MMA_CORRECT.  So the fault is CUDA-specific (or (16 8 8)/M=16-tile-specific),
            NOT generic multi-K-step SLM.

        WHY IT WASN'T CAUGHT BEFORE: earlier matmul validation (benchmarks/matmul, 2026-07-05)
        used A=B=1 -> C=K, which masks layout/staging errors.  The harness's non-uniform fill
        (A[i]=i%5, B[i]=i%3) exposes them.  The reference is trustworthy: 04/05 use the same
        col-major B and the same SLM-agnostic reference and pass, so the reference math is
        correct -> the KERNEL output is genuinely wrong.

        LEADING THEORIES (CUDA multi-K-step SLM path):
          (1) 2nd-K-step staging: load-tile-at B B-tile ((* kt 8) 0) at kt=1 reads the
              wrong B slice into SLM, or the SLM tile is stale/raced across sync-workgroup.
          (2) register C-tile accumulator not carried correctly between K iterations.
          (3) an M=16 A-tile fragment-layout issue on re-load (133/12 uses M=8).

        VERIFICATION EXPERIMENT (not yet run): a K=8 SINGLE-step SLM variant of 06 -> if it
        PASSES, the bug is multi-K-step accumulation/re-staging (theory 1/2); if it FAILS,
        the bug is SLM staging itself (independent of the K-loop).  One new spec + one pod run.

        STATUS: 132/06's TEST-HOIST[CUDA] wiring is CORRECT (it went red on a real bug).
        Locally 06 SKIPs (no NVIDIA GPU), so the local suite stays green; only GPU-CI/RunPod
        sees the red.  Left wired (visible reminder) pending the morning's investigation.

[x] 035 - :contiguous-term :col-major is silently ignored by the SPV cooperative-matrix loads.

        FIXED 2026-08-14 — but the fix is a COMPILE-TIME REFUSAL, not the feature.  Read the
        "what the hardware said" section below before assuming this is a capability.

        FOUND 2026-07-28 during endeavor 145 (MMA autodiff) P3b design, while checking
        whether the backward's transposed operands could ride a ColumnMajor operand read
        instead of an explicit transposing SLM staging.  NOT chased — 145 P3b routes around
        it by staging transposes explicitly — but it is a forward-path correctness concern
        that deserves its own look.

        SYMPTOM: declare a matrix (matrix float ... :contiguous-term :col-major), load a B
        fragment from it on BMG, and the emitted CooperativeMatrixLoadKHR carries
        MemoryLayout = 0 (RowMajorKHR) — the SAME constant as the row-major A operand:

            4 Constant 15 125 0
            7 CooperativeMatrixLoadKHR 292 293 256 125 260 0   ; A, row-major
            7 CooperativeMatrixLoadKHR 294 295 265 125 260 0   ; B, declared COL-major

        Expected MemoryLayout = 1 (ColumnMajorKHR) on the second load.

        WHY IT LOOKS LIKE A REAL BUG (the chain should work):
          - :col-major DOES canonicalize to :first — src/types/validation.lisp:143.
          - %get-tensor-ct reads index 5 of the canonical 6-tuple — src/analysis/structs.lisp:1307.
          - %coop-layout-of maps :first -> 1, else 0 — src/mma.lisp:249.
        So the declared intent is being lost somewhere between the def-type and the analyzed
        tensor node that %coop-layout-of inspects.  Prime suspect: the node handed to
        %coop-layout-of does not carry the declared c-t (get-single-value-type /
        canonicalize-type-specifier returning a shorter or defaulted tuple, which
        %get-tensor-ct silently reports as :last).

        WHY IT WAS NOT CAUGHT: an on-metal probe of exactly this kernel still printed
        MMA_CORRECT.  The hoist's host reference is STRIDE-AGNOSTIC (it indexes
        b_ptr[kk*b_str0 + j*b_str1] using the same declared strides), so a wrong layout and
        wrong strides can CANCEL in the comparison.  That makes the bug invisible to the
        --mma-test harness and means "MMA_CORRECT on a col-major operand" is not evidence
        that the col-major path works.  This is the same class of masking as bug 034's
        A=B=1 fill.

        SCOPE: SPV/cooperative-matrix only.  PTX is unaffected — the layout there is baked
        into the mma.sync intrinsic variant (row.col), not read from the tensor type, which
        is why 132/02's col-major B has always been correct.  All shipped SPV MMA specs
        (133/*, 142/*, 144/*) declare B :row-major, so nothing in the suite exercises the
        broken path — which is also why no test went red.

        SUGGESTED FIRST STEP: in %coop-layout-of, log (or assert on) the canonical type it
        receives for a known col-major operand; that immediately distinguishes "the node
        lost the c-t" from "%get-tensor-ct read the wrong index".

        ROOT CAUSE (2026-08-14) — and the standing theory above was WRONG in an instructive way.
        The declared c-t was NOT being lost.  Measured leg by leg:

            :col-major -> canonicalize            (TENSOR FLOAT 2 :GLOBAL :COMPACT :FIRST)  OK
            through a def-type alias              :FIRST -> layout 1                        OK
            into the kernel param's MANGLED type  TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST       OK
            canonicalize-type-specifier of THAT   (TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST)     <-- 1-ELEMENT LIST
            %get-tensor-ct index 5 of that        :LAST (its documented default)            <-- layout 0

        The operand type arrives at the load site INTACT.  %coop-layout-of then resolved it with
        CANONICALIZE-TYPE-SPECIFIER, which cannot expand a MANGLED tensor symbol and simply wraps
        it in a list; %get-tensor-ct read index 5 of a 1-element list, found nothing, and returned
        its default.

        WHAT THE OLD BEHAVIOUR ACTUALLY WAS -- and the title's word "ignored" is exactly right,
        which I initially got wrong.  :col-major was a COMPLETE NO-OP on this path, not a
        half-applied setting: %coop-tensor-ptr+stride picks its stride FROM the layout it is
        handed (src/codegen.lisp, `(stride (if (= layout 0) s0 s1))`), so a dropped layout took
        the stride down with it and the operand was read COHERENTLY row-major.  I first read the
        A and B loads carrying different stride operand ids as evidence the stride had followed
        the declaration; they were merely different FunctionParameters for different tensors, and
        proved nothing.  The practical consequence matters: a spec that declared :col-major was
        silently compiled as :row-major, byte for byte.

        THE FIX (overlays/, belongs in src/mma.lisp): resolve with %TS-CANONICALIZE-TENSOR-TYPE
        (src/analysis/control.lisp) instead -- it already handles all three shapes, alias, list
        form, and mangled symbol via UNMANGLE-TEMPLATE-STRUCT-NAME.  Reuse, not a second
        implementation.  %GET-TENSOR-CT is deliberately UNTOUCHED: its docstring promises only to
        read "a canonical tensor type 6-tuple", which is exactly what it does; the caller was
        violating that contract.

        ONE TRAP, worth 10 minutes to whoever folds this back: UNMANGLE-TEMPLATE-STRUCT-NAME
        returns PLAIN SYMBOLS (FIRST, GLOBAL, COMPACT), not keywords.  Without the keyword
        normalisation the (eq ct :first) test still fails and the bug survives a "correct" fix.
        src/macros.lisp:699 already carries the same cond for the same reason.

        WHAT THE HARDWARE SAID — the fix works, and then Intel declines.  All measured on BMG,
        driver 32.0.101.8864, build log read via zeModuleBuildLogGetString (the dumper is at
        put_temp_files_here/b035/buildlog.cpp and is worth keeping):

            col-major A operand   zeModuleCreate 0x70000004 (MODULE_BUILD_FAILURE)
                                  undefined reference to `__builtin_spriv_OpJointMatrixLoadINTEL_
                                    PackedA_ColumnMajor_SG16_8x8_i32_4_global_v8i8_pi32_i32'
            col-major B operand   same, PackedB_ColumnMajor_SG16_8x16_i32_8_...
            col-major accumulator BUILDS FINE (that builtin exists) but computes the WRONG
                                  RESULT on metal: C[0][1]=12 against a reference of 18.

        So the docstring's long-standing claim -- "Intel has no ColumnMajor-B coop builtin" -- is
        TRUE, now with the exact missing symbol rather than folklore, and it is not B-specific:
        the A load is missing too.  The accumulator is a THIRD behaviour and its root cause is
        UNDETERMINED (ours or IGC's -- the strides reach the instruction as runtime
        FunctionParameters, so the SPIR-V does not settle it).  That question is open.

        RESOLUTION: refuse a col-major coop-matrix operand at COMPILE time on :spirv, with a
        message naming the reason and the workaround (stage an explicit transpose into scratch).
        Refusing beats failing at zeModuleCreate with a mangled builtin name, and beats silently
        transposing behind the user's back.  The accumulator is refused CONSERVATIVELY; if anyone
        chases that root cause and fixes it, flip spec 14 back to the positive on-metal version.

        SPECS: 133-mma-spv/13-col-major-operand-refused-bmg and 14-col-major-accum-refused-bmg,
        both COMPILE-WITH[...]: FAIL "cannot be :col-major".  PTX is untouched (%coop-layout-of is
        only called on the :spirv branches; 132 stays 12/12).

        DOCS: docs/topology.md "Operand layout: Intel MMA operands must be :row-major" (staged
        with the other MMA docs), plus a short cross-reference in docs/ideal_001.md's Contiguity
        section, where someone choosing :col-major will actually be reading.

        A NOTE ON THE ORIGINAL PROBE, because it nearly misled the fix: the tiled MMA kernels load
        fragments from SLM TILES, not from the global matrix, and a make-scratch-matrix tile is
        row-major by construction.  MemoryLayout=0 is CORRECT there.  Reproducing this honestly
        needs a fragment loaded DIRECTLY from a declared col-major global (133/10's shape).

        THE ENTRY ABOVE WAS WRONG ABOUT COVERAGE, and it matters.  It said "All shipped SPV MMA
        specs (133/*, 142/*, 144/*) declare B :row-major, so nothing in the suite exercises the
        broken path -- which is also why no test went red."  In fact FOUR did declare a col-major
        B: 133-mma-spv 02-hello-mma, 04-mma-via-tile, 05-mma-via-tile-multi and 09-accum-op-body.
        They passed because the declaration was a no-op (see above), so the suite was green while
        four specs asked for something the backend cannot do.  The refusal is what surfaced them --
        the guard has teeth, demonstrated the hard way rather than by a contrived test.

        Those four are ports of their 132 NVIDIA twins and inherited the col-major B along with
        its rationale, "to match the canonical row.col MMA" -- true on NVIDIA, meaningless on
        SPIR-V, and 133's own BMG specs (10/11/12) already declared B :row-major with a comment
        saying why.  All four are now :row-major, which is what they were ALREADY COMPILING TO.
        The edit is codegen-identical; that is established by reading the stride selection above,
        NOT by diffing artifacts, since the guard now prevents building the col-major version.

        RETESTED 2026-08-14 (bug sweep).  STILL BROKEN, unchanged.  Probe: spec
        145/09-verify-autodiff-matmul-bmg with b-mat's :contiguous-term flipped to
        :col-major and nothing else touched, compiled --ir-target=spv --hardware-profile=bmg
        and disassembled with llvm-spirv -to-text.  All FOUR CooperativeMatrixLoadKHR
        instructions take MemoryLayout operand id 130, and

            4 Constant 20 130 0

        so id 130 is the constant ZERO = RowMajorKHR.  The col-major B operand is loaded
        row-major exactly as described.  Still nothing in the suite exercises this path, so
        it remains silent.  Reproducer left at put_temp_files_here/b035/ (probe.crisp,
        probe.spv, probe.spt) for whoever picks it up.

[x] 036 - matrix-multiply-tile-stride never resets the C-tile accumulator between output tiles,
          so any matmul LARGER THAN ONE OUTPUT TILE is silently wrong.

        FOUND 2026-07-30 during endeavor 145 (MMA autodiff) P8, which needs a multi-tile /
        multi-workgroup matmul.  PRE-EXISTING and unrelated to the AD work — reproduced with the
        SHIPPED spec `tests/spec/135-matrix-multiply-tile-stride/04-tiled-matmul-bmg.crisp`
        completely unmodified except for widening the harness dims.

        SYMPTOM (BMG, host-reference --mma-test): widen C from one 8x16 output tile to 8x32
        (two tiles) and the SECOND tile comes back doubled:

            C[0][16]=60 ref 30
            C[0][17]=60 ref 30
            C[0][18]=60 ref 30
            C[0][19]=60 ref 30
            MMA_WRONG

        Columns 0..15 (the first tile) are correct.

        MECHANISM (confirmed structurally, then by construction):
        %mmts-lower (src/analysis/control.lisp:3754) emits

            (tile-stride C <spec> (grid-y grid-x)
              (dotimes (grid-k (/ K k-step))
                <reduction-body>)
              <epilogue-body>)

        The register C-tile is initialised ONCE, by its `make-register-tile T (M N) INIT`
        binding OUTSIDE the tile-stride loop.  Nothing re-initialises it per output tile, so a
        workgroup that visits a second tile keeps the first tile's partial sums and adds the new
        tile's contribution on top.

        CONFIRMED BY CONSTRUCTION: the identical kernel hand-rolled as an explicit `tile-stride`
        with `(fill-tile C-tile 0.0)` as the first form of the tile body is MMA_CORRECT at 8x32.

        WHY IT WAS NEVER CAUGHT: every shipped matrix-multiply-tile-stride spec uses exactly ONE
        output tile (MMA-DIMS 8 16 16 on BMG / 16 8 16 on NVIDIA), so the tile-stride loop body
        executes once per workgroup and the missing reset is invisible.  The macro's whole
        purpose is striding over many output tiles, so this is the headline path.

        SUGGESTED FIX: have %mmts-lower emit a per-tile reset as the first form inside the
        tile-stride body, before the K-loop.  Two decisions worth making deliberately rather
        than in passing:
          1. WHAT VALUE.  0.0 is the correct additive identity for a matmul accumulator, but the
             user wrote `(make-register-tile T (M N) INIT)` — should the reset use INIT?  The
             macro does not currently see the binding.  (Endeavor 132's F3 accum-op API means a
             non-zero INIT is a plausible user intent, e.g. a bias.)
          2. THE SCRATCH C-TILE PATH.  fill-tile on a scratch/SLM tile is a workgroup-collective
             write and needs a sync-workgroup before the K-loop reads it; the register path does
             not.  The lowering handles both tile kinds through the same code.

        FIXED 2026-07-30 (endeavor 145).  %mmts-lower now emits a per-output-tile reset as the
        first form inside the tile-stride body, before the K-loop.  Both decisions above were
        resolved by evidence rather than preference:

          1. RESET VALUE = the tile's DECLARED INIT, not a hardcoded 0.0.  That makes multi-tile
             behave exactly like single-tile, which is what a bug fix should do; forcing 0.0
             would silently change semantics for a non-zero init (endeavor 132's F3 accum-op API
             makes a bias-valued init a real use).  %mmts-register-dims-map now carries the INIT
             alongside the dims so the lowering can see it.

          2. REGISTER TILES ONLY — the scratch C-tile path is deliberately untouched.
             135/01-macro-envelope documents the contract in its own body: "The macro does NOT
             auto-reset a scratch C-tile -- the user owns init", and 135/02-matmul-grid-stride
             duly resets by hand with `(when (= grid-k 0) (fill-tile C-tile 0.0))`.  The measured
             bug was a REGISTER tile, whose init lives in a make-register-tile binding OUTSIDE
             the loop where the user cannot reach it per-tile.  That asymmetry is the whole
             reason the register path needs the macro to own the reset and the scratch path does
             not.  (An earlier cut auto-reset both; it contradicted the documented design AND
             broke 135/01 / 02 / 10 under --differentiate.)

        REGRESSION SPEC: tests/spec/135-matrix-multiply-tile-stride/11-multi-tile-matmul-bmg.crisp
        — 04-tiled-matmul-bmg with C widened to 8x32 so the tile-stride body runs twice.  It is
        the smallest kernel that executes the loop more than once, which is precisely what no
        shipped spec did.

[x] 037 - A backward kernel does not re-stage SLM tiles, so any gradient needing a staged
          tile's PRIMAL VALUES is silently ZERO.

        FOUND 2026-07-31 (endeavor 145 closing review, prompted by Chris asking why 135/01 was
        marked non-differentiable).  PRE-EXISTING and unrelated to MMA.

        SYMPTOM: a scalar tiled matmul differentiates and RUNS, but every input gradient comes
        back 0.0 while the finite difference is correct:

            FAIL: A: analytical=0.0  numerical=0.059999973
            FAIL: B: analytical=0.0  numerical=0.23999998

        MINIMAL REPRO (no MMA, no tile-stride macro, 4x4):

            (let ((A-tile (make-scratch-matrix float (4 4)))
                  (B-tile (make-scratch-matrix float (4 4)))
                  (C-tile (make-scratch-matrix float (4 4))))
              (load-tile-at A A-tile (0 0))
              (load-tile-at B B-tile (0 0))
              (dotimes (i 4) (dotimes (j 4) (dotimes (kk 4)
                (set! (~ C-tile i j)
                      (+ (~ C-tile i j) (* (~ A-tile i kk) (~ B-tile kk j)))))))
              (store-tile-at C-tile C (0 0)))

        BISECTED — these all PASS, which is what isolates it:
          - tile -> tile scalar OVERWRITE       (set! (~ C i j) (* (~ A i j) 2.0))     -> 2.0 exact
          - tile -> tile scalar ACCUMULATE      (set! (~ C i j) (+ (~ C i j) (* .. 2.0))) -> 2.0 exact
          - THREE nested loops, ONE tile operand (* (~ A-tile i kk) 2.0)                -> 8.0 exact
          - TWO tile operands (the repro above)                                          -> 0.0  WRONG

        ROOT CAUSE: %generate-backward-kernel-ast replays the forward's BINDINGS
        (`forward-bindings`) but NOT its STATEMENTS.  `make-scratch-matrix` is a binding, so the
        tiles exist in the backward — but `load-tile-at`, which FILLS them, is a statement and is
        never replayed.  The staged tiles are therefore EMPTY (zero) in the backward.  The
        emitted chain rule is textually correct:

            (SET! %T31_ADJ (+ %T31_ADJ (* %T32 %T33_ADJ)))     ; dA += B * dOut
            (SET! %T32_ADJ (+ %T32_ADJ (* %T31 %T33_ADJ)))     ; dB += A * dOut

        but %T31 / %T32 are replayed as `(~ A-TILE I KK)` / `(~ B-TILE KK J)` — reads of empty
        tiles — so both products are zero.  It only shows up when a gradient needs the OTHER
        operand's primal value: with a constant multiplier (the passing cases above) no primal
        is required, which is exactly why every existing AD-over-tiles spec passes.

        Endeavor 145's MMA path does not hit this because its VJP was written to read the
        ORIGINAL GLOBAL operands at their load-tile-at origins rather than the staged tiles —
        a workaround adopted there for this very reason.  The scalar path has no equivalent.

        SUGGESTED FIX: replay the forward's tile-STAGING statements at the head of the backward
        (the standard "recompute primals" step of reverse-mode AD), or generalize the 145 trick
        and have the `~`-backward resolve a staged tile read back to its global source.  The
        first is more general; the second is cheaper and already proven in the MMA VJP.

        FIXED (staged-tile case) 2026-08-01, via the SECOND option above.  A replayed primal
        `(~ A-TILE i k)` is now rewritten to read the ORIGINAL GLOBAL source at the staging
        origin, `(~ A (+ oy i) (+ ox k))`, generalising what endeavor 145's MMA VJP already did.
        Chosen over replaying the staging statements because it has the SAME coverage while
        costing no extra SLM traffic, needing no barriers in the backward, and leaving the walk's
        loop structure untouched.  Implemented in %gfw-process-let (loop-nested primals) and in
        the top-level forward-bindings replay.

        VERIFIED NUMERICALLY, not just by compiling — that distinction is the whole point of this
        bug.  tests/spec/145-mma-autodiff/14-scratch-tile-matmul-vjp.crisp:
            PASS (A: analytical=0.06  numerical=0.059999973  diff=2.6e-8)
        135/01, 135/02 and 135/10 are now un-skipped.

        STILL OPEN — a tile filled by COMPUTATION has no global source, so its primal remains
        unrecoverable:
            (set! (~ T-tile i j) (* (~ A-tile i j) 3.0))       ; T-tile is computed
            (set! (~ C-tile i j) (* (~ T-tile i j) (~ A-tile i j)))  ; dA needs T's primal
        That case now ERRORS with an actionable message naming the tile, instead of silently
        returning zero — which was the actual damage this bug did.  A pure accumulator whose old
        value is never consumed as a VALUE (an ordinary C-tile) correctly does NOT error; the
        check tests whether the backward really uses the primal.  Closing this properly needs
        genuine primal recomputation / checkpointing, which is its own design.

        CLOSED 2026-08-13 (endeavour 149) — that "own design" got built: PRIMAL REPLAY, the
        recomputation half of the suggested fix above.  The statements that fill a hand-staged
        tile are now re-run in the backward, at the scope that contains both the fill and the
        consumer, so the tile holds its primal and nothing needs inverting.  Source recovery
        (the 2026-08-01 fix) still wins when a load-tile-at source exists — it costs no SLM
        traffic — and replay is the fallback when there is none.

        The "STILL OPEN" case above is now covered: a tile filled by COMPUTATION is replayed by
        re-running the computation.  tests/spec/149-ad-primal-replay/04 is exactly that shape,
        A-tile = A*A, and gradient-checks on BMG at 6.0 against a finite difference of 6.0.

        VERIFIED NUMERICALLY five ways on BMG, all diff=0.0: hand-staged (01), through a
        non-invertible permutation (02), computed rather than copied (04), re-staged per loop
        iteration (05), and across subgroups with a replayed barrier (06).

        TWO REFUSALS REPLACE THE OLD ONE, both naming what to fix: staging that also WRITES
        observable memory would double the write (149/03), and staging that READS an &out
        parameter would recompute from a buffer the backward cannot vouch for (149/07).  The
        original "no statement fills this tile" refusal survives for tiles nothing can rebuild.

[x] 038 - A VOID sub-function call is silently DROPPED by the AD walk, so no gradient flows
          through it.

        HEADER CORRECTED 2026-08-14 (bug sweep).  The body below has said "CLOSED 2026-08-01"
        since the fix landed; only the checkbox was left stale.  Re-verified today rather than
        taken on trust:
          145/17-void-subfn-vjp-bmg  PASS on BMG -- analytical=2.0 numerical=2.0 diff=0.0
          137/04-tma-sub-function    PASS -- SKIP-WITH[--differentiate] is gone, replaced by
                                     validate-ptx-tma-grad as the body describes.

        FOUND 2026-08-01 reviewing 137-mm-async-block for --differentiate clearance.

        SYMPTOM: tests/spec/137-mm-async-block/04-tma-sub-function.crisp COMPILES under
        --differentiate (with its own flags) but the generated backward kernel performs ZERO
        global writes — it produces no gradient at all.  Its siblings are fine: 03 (kernel does
        the TMA itself) emits 1 gradient write and 05 emits 2; only the SUB-FUNCTION variant is
        empty.

        MECHANISM (from the flat-anf the walk receives):

            (TILE  (MAKE-SCRATCH-MATRIX FLOAT (4 4)))
            (STAGE A TILE)                              <- void sub-function call, a STATEMENT
            (STORE-TILE-AT TILE C (...))

        `(STAGE A TILE)` has length 3 with an all-symbol BUTLAST, so generate-backward-walk's
        MULTI-VALUE BINDING clause claims it: it reads STAGE and A as bound variables and TILE as
        the producing expression.  TILE is a symbol rather than a cons, so that clause's body
        never executes and the form is silently dropped.  Exactly the structural ambiguity that
        caused the endeavor-145 P1 replay bug — a statement and a multi-value binding are
        indistinguishable by shape after ANF.

        Note there IS already a clause for a void FOREIGN call (endeavor 123), added for the same
        reason; ordinary differentiable sub-functions never got one.

        WHAT A FIX NEEDS — two parts, and the second is the substantial one:
          1. A walk clause that recognises `(f arg ...)` as a VOID call when f is in
             *differentiable-functions*, mirroring the existing foreign-void clause, and emits
             the call to f's _GRAD companion.  Must be ordered BEFORE the multi-value-binding
             clause, which currently swallows it.
          2. `stage`'s gradient contribution is a MUTATED TILE PARAM: it fills `tile` from `src`.
             The sub-function AD convention passes handle contributions as extra `&out`
             grad-handles, so `stage_GRAD` has to accept `tile`'s adjoint and scatter it into
             `src`'s gradient — the same operation %load-tile-at-bwd performs, but crossing the
             call boundary.  Whether the existing _GRAD generation already emits that for a
             staging body is unverified.

        PROGRESS 2026-08-01 — the bug has THREE layers, not one.  Reproduced locally with a
        plain void sub-function (no TMA, no sm_90a), so it is general rather than a 137 quirk:

            (def-function scale_into (src &out dst) ... (set! (~ dst i j) (* (~ src i j) 2.0)) ...)
            (def-kernel k (A &out C) (scale_into A C))
            -> analytical=0.0, finite difference=2.0

          LAYER 1 — the missing walk clause.  FIXED.  A void differentiable sub-function call is
          now recognised before the multi-value-binding clause that used to swallow it, mirroring
          endeavor 123's void-FOREIGN clause.  Verified firing.  Suites stay green (944/944 both
          ways, 253 unit, 211 negative), so the clause is safe to keep even though the layers
          below still block the end-to-end gradient.

          LAYER 2 — TYPE ALIASES make a sub-function INVISIBLE to AD.  This is broader than 038
          and probably deserves its own number.  %crisp-tensor-param-type-p recognises the list
          form `(matrix float ...)` and mangled `TENSOR_*` symbols, but NOT a user alias from
          `def-type` — despite its docstring claiming "plain symbol naming a registered tensor
          type".  So with

              (def-type mat-t (matrix float ...))
              (def-function f (src &out dst) (declare #'(mat-t &out mat-t => ulong)) ...)

          %has-tensor-diff-param-p returns NIL, %generate-backward-function-ast bails at its
          `(zerop n-float-params)` guard, and NO _GRAD companion is generated at all — silently.
          Substituting the inline `(matrix float ...)` type makes the companion appear
          (`AUTODIFF: Generating _GRAD companion SCALE_INTO_GRAD ... n-tensor=2`).  Note
          %is-tensor-alias already exists in the same file and resolves exactly this.
          BOTH 137/04's `stage` and its `mat-t` / `tile-t` params are declared via aliases.

          LAYER 3 — emission still produces nothing.  With the inline types the companion exists
          AND the layer-1 clause fires, yet the assembled backward is `(LET ((A_ADJ 0.0)))` —
          empty.  %emit-sub-fn-backward's tensor-only branch should emit
          `(SCALE_INTO_GRAD A C A_GRAD C_GRAD)`.  Suspect the registration is overwritten between
          passes (Crisp is multi-pass; *differentiable-functions* is written both by
          %register-hof-differentiable-function and by the companion generator), so the `info`
          the walk reads may lack :tensor-param-indices.  NOT yet confirmed.

        RESOLVED 2026-08-01 (the AD half) — by INLINING instead of repairing the companion.

        Endeavor 111 Phase 1c had already put the AD splice in the right place: load-tile-at ->
        %load-tile-at-bwd, store-tile-at -> %store-tile-at-bwd.  The kernel's `store-tile` was
        already producing its backward edge.  The ONLY missing edge was the `load-tile` INSIDE
        the sub-function, which the walk never saw.  So the backward now inlines the callee's
        body at the call site (substitute actuals for formals, ANF, flatten) and walks it with
        the ORDINARY STATEMENT walker.  Every per-construct rule then applies inside a
        sub-function exactly as in a kernel, for free and for all of them.

        This dissolves layers 2 and 3 rather than fixing them: both are properties of the _GRAD
        companion path, which inlining does not use.  The companion is KEPT as the fallback —
        still the right lowering for scalar math sub-functions, and MANDATORY for FFI, where
        there is no body to inline.

        A FOURTH layer surfaced during the fix and is worth recording, because it is the same
        mistake in yet another costume.  %generate-backward-companion-ast-body rejects a callee
        that writes through a tensor parameter:

            Cannot differentiate function SCALE_INTO: it mutates parameter DST via cell write.
            This function is not valid in a differentiable kernel.  Unregistering.

        — and the UNREGISTERING then hid the call from the walk again.  The message overstates
        its case: writing through a tensor param is what a staging or fill sub-function is FOR,
        and it is not a problem for the derivative, only for a lowering that threads gradients
        through return values and &out grad-handles.  Inlining handles it natively: after
        substitution it is `(set! (~ C i j) ...)` on the caller's symbol.  So inlinability is now
        keyed on the RETAINED BODY, not on *differentiable-functions* — a failed companion must
        not veto the more expressive lowering.

        Layer 2 (%crisp-tensor-param-type-p not resolving `def-type` aliases) was fixed anyway:
        it is real on its own, since scalar sub-functions do still use companions.

        MEASURED: the analytical gradient is now CORRECT — 2.0, against a hand-derived 2.0 — on
        a locally-runnable analogue of 137/04 (spec 145/17).  Suites stay green: 944/944 both
        ways, 253 unit, 211 negative.

        STILL BLOCKED, on BUG 039 rather than on AD.  145/17's FINITE DIFFERENCE reads 0.0
        because the FORWARD kernel is wrong: 2-D indexing inside a sub-function silently drops
        the second index (see 039).  The analytical side is unaffected because the inlined body
        is differentiated in the CALLER's frame, where the tensors carry mangled types and take
        the correct 2-D path.  So 038's own machinery is done and verified as far as it can be.

        CLOSED 2026-08-01 once 039 was fixed.  145/17 now passes end to end on BMG:
        analytical 2.0, numerical 2.0, diff 0.0.  137/04's SKIP-WITH[--differentiate] is removed
        and replaced by a validator, validate-ptx-tma-grad, which asserts the backward contains
        the gradient scatter (ld.shared feeding atom.global.add.f32) and that the forward TMA
        copy survived.  That evidence is STRUCTURAL and is labelled as such in the spec: 137/04
        cannot be gradient-checked numerically anywhere (VERIFY-AUTODIFF has only :l0/:opencl so
        it cannot drive a PTX backward, and the kernel has no SPV lowering at all).  The
        MECHANISM is proven numerically by 145/17; the validator only guards against the
        backward silently going empty again, which is how this hid for a whole endeavor.
        Verified to have teeth: stubbing the inline path out makes 137/04 fail.

[x] 039 - 2-D (and N-D) tensor indexing INSIDE a def-function silently drops all but the FIRST
        index when the parameter type is declared through a `def-type` ALIAS.  Not an AD bug:
        the wrong element is read and written in ORDINARY forward code, on hardware, with no
        error.  Found while fixing 038, 2026-08-01.

        REPRO — a sub-function that fills a 4x4 matrix writes only FOUR cells:

            (def-type mat-t (matrix float :address-space :global :align :compact
                                          :contiguous-term :row-major))
            (def-function fill_seven (src dst)
              (declare #'(mat-t mat-t => ulong))
              (dotimes (i 4) (dotimes (j 4) (set! (~ dst i j) 7.0)))
              (to-ulong 0))

        Read back on BMG: sum = 28.0, i.e. 4 cells, not 112.0 / 16 cells.  The identical body
        written directly in a KERNEL gives the correct 16.  Both loops are fine; the ADDRESS is
        wrong.  Emitted IR for the sub-function:

            %i7        = load i32, ptr %i            ; i only — j is never read
            %t_flat    = sext i32 %i7 to i64
            %t_byte    = mul i64 %t_flat, sizeof(float)
            %t_ptr     = getelementptr ... i64 %t_byte
            store float 7.0, ptr addrspace(1) %t_ptr

        so `(~ dst i j)` means `dst[i]`.  The same expression in a kernel emits the proper
        Horner form (mul by the row extent, then add j).

        ROOT CAUSE.  analyze-aref-expression (src/analysis/structs.lisp:405) dispatches on
        (%get-tensor-arity array-type).  %get-tensor-arity (:250) recognises the list form
        `(tensor elem N ...)` and mangled `TENSOR_*` symbols, but NOT a `def-type` alias, so it
        returns NIL and the analyzer falls through to the "Cell / array path: single index",
        which uses only the first index and DISCARDS the rest.  Confirmed by the debug log: a
        kernel logs `AREF compact path (no offset): A (N=2)`, the sub-function logs nothing.
        %get-tensor-align (:290) has the identical hole.

        Why sub-functions specifically: kernel parameters are exploded and reassembled, so their
        semantic type is the mangled `TENSOR_*` symbol; a sub-function parameter keeps whatever
        the declare said, i.e. the alias.

        Note the failure is silent ONLY because arity is UNKNOWN — line 414 already errors on a
        known-but-mismatched arity.  A tightened version of that check would have caught this at
        compile time.

        FIX DIRECTION (not yet applied — wider blast radius than the AD overlay, wants review).
        `canonicalize-type-specifier` (src/types/validation.lisp:318) already resolves aliases
        and handles CELL/VECTOR/MATRIX/TENSOR, so the surgical change is to canonicalize the
        symbol case in %get-tensor-arity and %get-tensor-align before giving up.  The
        alternative — canonicalising parameter types once at declaration, so sub-function params
        carry the same mangled type kernels do — is more invasive but would close the whole
        FAMILY of these holes at once.  This is the THIRD alias hole found in two days
        (%crisp-tensor-param-type-p was the AD one), which argues for the second option.

        SCOPE: any def-function taking an aliased multi-dimensional tensor and indexing it with
        `~`.  Aliases are the documented style and are used throughout tests/spec, so this is
        likely reachable from well beyond 137/04.

        FIXED 2026-08-01.  Two changes, because the fix and the failure MODE are separate
        problems:

          1. %get-tensor-arity and %get-tensor-align now resolve aliases, via
             canonicalize-type-specifier — which already resolves def-type aliases and
             re-mangles, and whose output %get-tensor-arity already understood.  Guarded with
             ignore-errors and non-recursive: a type we cannot canonicalize simply has unknown
             arity, the same answer as before but now reached deliberately.

             NOT by canonicalising parameter types once at declaration, which was the other
             candidate and the one first proposed.  The emitted symbol for the repro is
             `fill_seven_mat_t_mat_t`: the ALIAS NAME is load-bearing for name mangling and
             overload resolution, so normalising param types at the declaration would change
             mangled names.  The alias must survive; only the QUERIES about it need to see
             through it.

          2. analyze-aref-expression's cell / single-index fall-through now ERRORS when handed
             more than one index, naming the type.  Silence here is not incidental — it is the
             whole reason 039 reached hardware, and this is the THIRD time this exact path has
             bitten (endeavor 138 fixed it for compound tensor targets; see the comment above
             `target-form`).  A cell or 1-D array never takes two subscripts, so this is always a
             real error.  Any future member of the family now fails at COMPILE time instead of
             computing a plausible wrong answer.

        VERIFIED: the sub-function's IR now emits the same Horner form as a kernel
        (`mul` by the row extent, then `add j`); 145/17 passes numerically end to end; suites
        944/944 both ways, 253 unit, 211 negative.

[x] 040 - MMA reading from a RING SLOT computes the WRONG RESULT on Intel/BMG.  Forward only —
        no autodiff involved.  Found 2026-08-02 while trying to build a numeric proof for ring
        gradients; reproduced at HEAD with no AD change in play, so it is pre-existing.

        REPRO — spec 09's kernel with its two staged tiles replaced by ring slots, nothing else
        changed:

            (let ((A-ring (make-scratch-matrix-ring float (8 16)  :ring-count 2))
                  (B-ring (make-scratch-matrix-ring float (16 16) :ring-count 2))
                  (C-tile (make-register-tile float (8 16) 0.0)))
              (load-tile-at A (ring-get A-ring (to-ulong 0)) (0 0))
              (load-tile-at B (ring-get B-ring (to-ulong 0)) (0 0))
              (sync-workgroup)
              (mma-accumulate-via-tile (8 16 8) C-tile
                                       (ring-get A-ring (to-ulong 0))
                                       (ring-get B-ring (to-ulong 0)))
              (store-tile C-tile C (0 0)))

        On BMG via TEST-HOIST[L0] / validate-l0-mma-run:

            C[0][0]=11 ref 30   C[0][1]=18 ref 30   C[0][2]=10 ref 30   C[0][3]=11 ref 30
            MMA_WRONG

        The identical kernel with plain `make-scratch-matrix` tiles is MMA_CORRECT (spec 09), and
        ring STAGING without MMA is correct (145/18 gradient-checks exactly, which requires a
        correct forward).  So the defect is specific to an MMA operand that is a ring VIEW.  The
        wrong values are not garbage — they are small and plausible — which suggests the operand
        is being read at a wrong offset or with a wrong row stride rather than from unwritten
        memory.  A ring slot is a view with a non-zero base offset into rank+1 scratch, and the
        fragment loads may be ignoring that offset (or the slot stride) when building their
        addresses.  UNVERIFIED — that is the first thing to check.

        WHY NOTHING CAUGHT IT: no spec combined a ring with MMA on SPIR-V.  138/05 does exactly
        that but is PTX-only, and 138/06 records that :linear rings are not implemented on SPIR-V
        at all, so the Intel path was never exercised.  The NVIDIA side is metal-verified
        (138/04 MMA_CORRECT on H100), so this may well be Intel-specific.

        BLOCKS: 145/19, and therefore the numeric proof for ring-pipelined gradients, and
        therefore un-skipping 138/04 and 138/05 under --differentiate.

        RETESTED 2026-08-14 (bug sweep).  STILL BROKEN, and the numbers are BYTE-IDENTICAL
        to the ones recorded above -- C[0][0]=11, C[0][1]=18, C[0][2]=10, C[0][3]=11 against
        a reference of 30, MMA_WRONG.  Measured with a throwaway forward-only spec (the repro
        kernel above + MMA-DIMS: 8 16 16 + TEST-HOIST[L0]: validate-l0-mma-run), deleted after
        measuring; recreate it in ten seconds from the repro block above.

        FIXED 2026-08-14.  It was NOT an addressing bug, and the base offset was never the
        problem -- the theory below is wrong and is left in place only because the reasoning is
        instructive.

        ROOT CAUSE: the operand's K EXTENT was not compile-time resolvable through a `ring-get`,
        so %MMA-K-STEPS took its documented fallback of ONE native K-step and the MMA contracted
        over K=0..7 of 0..15.  It computed HALF the dot product.  The entry's own observation --
        "the wrong values are not garbage, they are small and plausible" -- was the clue, and
        pointed away from the addressing theory the entry then adopted.

        MEASURED, by wrapping %MMA-OPERAND-EXTENT / %MMA-K-STEPS and compiling both kernels:

            plain scratch tiles   A cols=16  B rows=16  -> 2 K-steps  (4 coop loads emitted)
            ring slots            A cols=NIL B rows=NIL -> 1 K-step   (2 coop loads emitted)

        This is the SAME silent-data-drop endeavour 145 P3a exists to prevent; P3a covered
        MAKE-SCRATCH-MATRIX and rings were never covered.  TWO gaps, both required:
          1. %MMA-SCRATCH-TILE-DIMS-FROM-BINDINGS matched only "MAKE-SCRATCH-MATRIX", so a
             make-scratch-matrix-ring binding recorded nothing.
          2. %MMA-OPERAND-EXTENT's scratch arm required (symbolp ref), but a ring operand is
             the FORM (ring-get RING SLOT).
        Fix (overlays/, belongs in src/mma.lisp) records the ring's PER-SLOT shape and unwraps
        `ring-get` before the lookup.  The SLOT INDEX is deliberately not inspected: every slot
        has the same shape, and SLM -- unlike the GRF -- is runtime-indexable, so demanding a
        constant slot would reject legitimate pipelined kernels.

        NOT INTEL-SPECIFIC, contrary to the guess below.  This is analyzer code shared by SPV and
        PTX.  NVIDIA escaped it only because 138/04 stages Kt = K_n = 8 -- exactly one native
        K-step -- so the fallback was accidentally correct there.

        SPECS: 138-pipeline-ring/07-ring-mma-operand-bmg (slot 0) and
        08-ring-mma-nonzero-slot-bmg (slot 1), both MMA_CORRECT on metal.  Spec 08 exists
        because slot 0 sits at base offset ZERO and therefore could not test the offset claim
        at all; slot 1 does, and it passes -- so the offset IS honoured.  Teeth are real, not
        hypothetical: spec 07's kernel is byte-for-byte the repro that reported C[0][0]=11
        against ref 30 before the fix.

        THE "BLOCKS" LINE BELOW IS WRONG, and this is the part to carry forward: fixing 040 does
        NOT unblock 145/19.  With its skip lifted it still reports analytical=84.32 against an
        expected 1.2 -- the SAME numbers as before the fix, which moved neither.  Its finite
        difference perturbs A[1,0], which lies entirely inside K-step 0, so that measurement was
        always blind to 040's truncation.  145/19 is blocked by a separate BACKWARD defect, now
        filed as BUG 044, and its skip has been re-pointed there.

        ONE NEW DATA POINT, worth having before anyone starts: the defect is NOT uniform
        across kernels.  With 145/19's SKIP-WITH[--differentiate] temporarily lifted, its
        FINITE DIFFERENCE now reads 1.1992 -- i.e. essentially the expected 1.2, so THAT
        kernel's forward responds correctly to the perturbation -- while its analytical side
        reads 84.32.  That is the opposite of what this entry predicts ("the finite difference
        reads 0.0").  Meanwhile the plain forward probe above is still MMA_WRONG.  So ring-slot
        MMA is wrong in some shapes/access patterns and right in others, which fits the
        "wrong offset or wrong row stride" theory better than "reads unwritten memory".
        Do NOT read the 84.32 as a second bug yet -- an analytical number sitting on top of a
        forward we know to be unreliable proves nothing on its own.

[x] 041 - An AD-minted `<tile>_ADJ` SCRATCH tile was never zero-initialised, so the backward
        accumulated gradients on top of whatever was already in local/shared memory.

        FOUND BY: endeavor 147's CUDA VERIFY-AUTODIFF, spec 147/05-cuda-scratch-tile, on an
        H100.  Forward is C[i] = F*A[i] staged through an SLM tile, so df/dA[k] = F.  For
        F = 2 / 3 / 5 the backward returned 10.0 / 21.0 / 55.0 while the finite difference
        correctly returned 2 / 3 / 5.  Those are exactly (F*A[1] + 1) * F — the adjoint tile
        began life holding the FORWARD launch's leftover `F*A`.  Confirmed in the emitted PTX:
        the only `st.shared …, 0` in the module sits in the FORWARD entry (load-tile-at's
        out-of-bounds identity fill); the backward entry had no zero-store to shared at all.

        WHY IT WAS A REAL BUG AND NOT A RUNNER ARTEFACT: no API — OpenCL, Level Zero or CUDA —
        guarantees local/shared memory arrives zeroed, so generated code must not assume it.
        The intent was already explicit for the REGISTER case: %mma-ad-adj-init gives a
        register-tile adjoint an explicit 0.0 init, with the docstring "an adjoint always
        starts at zero".  Scratch adjoints never got the same treatment because make-scratch-*
        takes no init argument, so the zeroing has to be a body form.

        WHY NOTHING CAUGHT IT: on Intel each L0 kernel argument gets its own fresh SLM
        allocation, which happens to read as zero — every staged-tile AD spec since 111 has
        been passing on masked-undefined behaviour.  Under CUDA there is ONE dynamic shared
        window per block, reused across launches, and the forward's tile lands at exactly the
        offset the backward's `_ADJ` tile is handed, so the residue falls precisely on the
        adjoint.  This is the first defect found purely by having a second vendor's runtime.

        NO HOST-SIDE FIX EXISTS, which is worth recording because it is the first thing
        anyone will ask.  Shared memory has no host-visible address; the launch APIs expose
        only a byte SIZE (cuLaunchKernel's sharedMemBytes; clSetKernelArg /
        zeKernelSetArgumentValue with a null pointer), and the allocation is per-BLOCK.  Even
        a hypothetical zero-at-launch would be insufficient: once a grid has more blocks than
        fit resident, block N+1 inherits block N's shared memory WITHIN THE SAME LAUNCH.  Only
        the kernel runs per block, so only the kernel can fix it.  (The one place the
        ecosystem does offer a knob is Vulkan's shaderZeroInitializeWorkgroupMemory, which
        does not reach the OpenCL/L0 compute path or CUDA.)

        FIXED, with the UNIFORM rule rather than a narrow one: **the compiler zeroes what the
        compiler allocates, in the kernel the compiler wrote.**  %ad-backward-slm-zero-forms
        emits `(fill-tile <obj> 0.0)` for EVERY SLM scratch object bound in a BACKWARD
        kernel's let — not only the minted `_ADJ` ones — plus a `set!` for a scratch cell,
        followed by one sync-workgroup.  Injected at BOTH allocation sites: %gfw-process-let
        for a nested let, and generate-backward-walk's outer let for the ANF-lifted case
        (which is the one 147/05 actually exercises — fixing only the nested site changed
        nothing).

        The narrow rule ("zero what is read before it is fully written") is also correct, but
        it obliges every future allocation to be classified correctly forever, and BUG 041 IS
        that obligation silently going unmet since endeavor 111.  The uniform rule is
        checkable in one place and costs a workgroup-strided write pass plus one barrier
        against a backward that does MMA, primal replay and atomic scatter to global.
        Narrowing a correct baseline later is a safe optimisation; widening a wrong one is
        this bug.  FORWARD kernels are untouched — a forward tile is user-visible, the user
        owns accumulator resets there via fill-tile (135's C-tile contract, BUG 036), and a
        blanket zero pass would land on the matmul hot path.

        RINGS: no special work was needed, and an earlier note here claiming a "ring gap"
        was WRONG.  By the time the adjoint allocator runs, a ring has been canonicalised to
        a rank-(1+N) `make-scratch-tensor` — measured, from the emitted backward AST:

            (LET ((TILES_ADJ (MAKE-SCRATCH-TENSOR FLOAT 3 (2 4 4))) (A_ADJ 0.0))
              (FILL-TILE TILES_ADJ 0.0)
              (SYNC-WORKGROUP)
              ...)

        so `fill-tile` already named it and one pass already cleared every slot.  The ring
        constructor names are in the whitelist anyway, as belt-and-braces against a future
        path that reaches the allocator without canonicalising.

        The constructor list is a WHITELIST so that async barriers (mbarrier objects, not
        tensors) and register tiles (GRF; already 0.0-initialised by %mma-ad-adj-init, and no
        whole-tile symbol survives %explode-register-tiles) are never filled, and so a newly
        added allocator fails closed rather than being silently swallowed.

        fill-tile is reused rather than reinvented: it is already the sanctioned
        workgroup-collective tile clear and inserts no barrier of its own.

        VERIFIED: the tile case gradient-checked on an H100 (147/05: 10.0 -> 2.0), plus
        972/972 Intel/BMG and H100 under `--differentiate`, 211/211 negative and 253/253 unit
        on the narrow (_ADJ-only) cut; the uniform cut re-verified on Intel afterwards.  Ring
        zeroing is confirmed at the AST and PTX level (see the LET above); 147/08-cuda-ring-adjoint
        is the numeric check for it and has NOT yet run on metal — the pod was released first,
        and Intel cannot falsify this defect because it is invisible there.  Run 147/08 early
        on the next Hopper session.

[x] 042 - The full `--single-pass` spec phase CRASHES on a `TEST-WITH[--metadata]` spec.

        REPRO (deterministic, on a clean directory):
            sbcl --script tests/run-specs.lisp --use-binary --single-pass --filter=aliases

            0: (PROBE-FILE (#P".../01-aliases_address-space~.metacrisp"
                            #P".../01-aliases_die.metacrisp"
                            #P".../01-aliases_make-cell%dispatch.metacrisp" ...))
            unhandled condition in --disable-debugger mode, quitting

        CAUSE: under --single-pass the compiler emits ONE .metacrisp per function rather
        than one per module — 19 files for tests/spec/028-metadata/01-aliases.crisp.  The
        runner passes the whole wildcard `directory` result to the spec's validator, and
        `validate-01-aliases` (src/metadata.lisp:36) takes a single METADATA-PATH and calls
        PROBE-FILE on it, so it is handed a LIST and dies on the type check.  Not a memory
        fault and nothing to do with BUG 033 — a plain arity/shape mismatch between what the
        runner supplies and what the metadata validators expect.

        SCOPE: kills the whole `--single-pass` phase, so everything after 028-metadata in
        that phase is never run.  `run-all-tests.bat` runs this phase (line 49), so the local
        five-phase sweep cannot complete today.  The other four phases are unaffected:
        plain, --use-binary, --differentiate and (modulo 033 on Windows) --debug all
        complete.

        WHY IT STAYED HIDDEN: the metadata validators are only reached via
        TEST-WITH[--metadata], and nothing else in the suite combines that with
        --single-pass.  Found 2026-08-13 during endeavour 147's definition-of-done sweep,
        which was the first time the full --single-pass phase had been run end to end.

        NOT CAUSED BY 147, verified rather than assumed: `git diff 39d8d17 HEAD --
        tests/run-specs.lisp` touches nothing in the metadata-validator path, and the crash
        reproduces with a freshly cleaned spec directory.

        LIKELY FIX: have the validator caller pass one path (or have the metadata validators
        accept a list and validate each), and decide which is right — the per-function
        metacrisp fan-out under --single-pass may itself be the surprising half.

        FIXED 2026-08-14.  It was the fan-out, and the "LIKELY FIX" above was deliberately
        NOT taken: the validators and the runner were both already correct.

        ROOT CAUSE.  generate-metadata-for-file (src/metadata.lisp) chooses its kernel list as

            (if forms (extract-defined-kernels forms) (hash-table-keys *function-table*))

        and the no-FORMS arm treats EVERY FUNCTION as a kernel.  --single-pass is the only
        caller that reaches it, because main.lisp sets CAPTURED-FORMS only in its multi-pass
        branch (src/main.lisp, `(setf captured-forms forms)`), leaving it NIL otherwise.
        Measured on 028-metadata/01-aliases.crisp, which has exactly one kernel:

            multi-pass    1 metacrisp   (01-aliases_simple_kernel)
            single-pass  19 metacrisp   (+ 18 internals: _die, _make-cell%dispatch, _~parent~ ...)

        The crash was purely downstream of that: the runner passes a PATHNAME when one
        metacrisp exists and a LIST when several do (run-specs.lisp ~L1829), so the bogus
        fan-out handed a LIST to VALIDATE-01-ALIASES, which PROBE-FILEs its argument.

        WHY THE VALIDATORS WERE LEFT ALONE.  That runner convention is right and is already
        exercised: 028/12 and 028/14 are genuinely two-kernel specs, and their validators do
        take a list and find each file by name (metadata-val.lisp:65).  Only the fan-out was
        lying about how many kernels existed.  Teaching every single-kernel validator to
        accept a list would have hidden the real defect.

        THE FIX (overlays/crisp-compiler-overlay.lisp, belongs in src/metadata.lisp): the
        fallback now enumerates *COMPILED-KERNELS* -- the list the DEF-KERNEL macro itself
        maintains (src/macros.lisp) -- instead of *FUNCTION-TABLE*, filtered through a new
        %ONLY-FORWARD-KERNELS.  The filter is needed because *COMPILED-KERNELS* also holds
        the AD-minted K_GRAD twins under --differentiate, which the forms path never yields;
        unfiltered they each got an extra sidecar with an EMPTY :kernels section (the lookup
        is K_GRAD_GRAD, which does not exist).  It drops a name only when its own forward is
        in the same list, so a hypothetical user kernel FOO_GRAD with no FOO survives.

        VERIFIED: 19 -> 1 sidecar under --single-pass, multi-pass unchanged at 1, and the
        repro command above now reports 4/4 with VALIDATE-01-ALIASES PASS.

        STILL WANTED, and this is the better fix — capture the forms in main.lisp's
        --single-pass branch too, so BOTH modes read the kernel list off the actual source
        forms and neither depends on a session-global.  Not done here only because
        COMPILE-FILES lives in CRISP.MAIN, which has no overlay, and redefining a ~130-line
        function wholesale to change four lines is a poor trade; it wants a direct src patch.

        A TRAP FOR THE NEXT PERSON: when this crashed it died BEFORE the runner's cleanup, so
        it left its 19 stale .metacrisp files in tests/spec/028-metadata/.  The runner globs
        the directory, so those stale files reproduce the ORIGINAL crash against a FIXED
        compiler.  That is why the repro line above says "on a clean directory".  If a
        metadata fix looks like it did not take, `rm tests/spec/028-metadata/*.metacrisp`
        first -- they are untracked build artifacts, zero tracked files under tests/spec.

[ ] 043 - Under --single-pass --differentiate, a backward kernel's :physical-signature in the
        .metacrisp is the FORWARD kernel's, not the backward's.

        FOUND 2026-08-14, immediately behind the BUG 042 fix: with 042 repaired the
        --single-pass phase ran to completion for the first time (980/981), and this is the
        one failure it exposed.  PRE-EXISTING, not caused by the 042 fix -- verified rather
        than assumed, see below.

        REPRO:
            sbcl --script tests/run-specs.lisp --use-binary --single-pass --filter=03-record-at-boundary
            -> validate-record-grad-metadata: expected 14 physical-sig entries, got 5

        The same spec PASSES in multi-pass (`--use-binary` without `--single-pass`), so this
        is specific to the single-pass path.

        THE TELL — the two signatures in the SAME file disagree.  From the single-pass
        metacrisp for 050-differentiate-and-metadata/03-record-at-boundary:

            :physical-signature ((0 FLOAT) (1 FLOAT)
                                 (2 (C-POINTER ADDRESS-SPACE GLOBAL)) (3 ULONG) (4 ULONG))
            :declared-signature (... "c_grad" :range (5 7)
                                     "vp_x_grad" :range (8 10)
                                     "vp_y_grad" :range (11 13))

        The DECLARED signature is fully correct: six params, ranges running to 13, i.e. it
        knows about all 14 physical slots.  The PHYSICAL signature stops at 5 -- exactly the
        FORWARD kernel's parameter count (vp_x, vp_y, c_ptr, c_bytesize, c_offset).  So the
        backward's physical signature is never rebuilt; the forward's is served in its place.
        AD itself is fine here -- the _grad .spv is produced and the declared side is right.

        PRIME SUSPECT: --single-pass drives CRISP.COMPILER:COMPILE-TOPLEVEL-FORM per form and
        never calls COMPILE-MODULE (src/main.lisp), so whichever module-level pass registers
        the backward kernel's PHYSICAL signature does not run, while the declared-signature
        path (which AD writes directly) does.  UNVERIFIED -- that is the first thing to check.

        NOT CAUSED BY THE 042 FIX, verified: the 042 fix only selects WHICH kernels get a
        sidecar, never the CONTENT of one.  Confirmed empirically -- after adding
        %ONLY-FORWARD-KERNELS (which removed the spurious twin sidecar this spec was also
        emitting), the physical signature was re-measured and is STILL 5 entries.

        SCOPE: metadata only, and only under --single-pass --differentiate.  A hoist consuming
        such a metacrisp would build a launcher with 5 args for a 14-arg kernel, so it is not
        cosmetic -- but nothing does that today, since the hoist path does not use
        --single-pass.  One spec red in one phase.

[ ] 044 - The RING-PIPELINED MMA BACKWARD computes the wrong gradient on BMG.

        FOUND 2026-08-14, immediately behind the BUG 040 fix.  Split out of 040 because it is
        demonstrably NOT the same defect: fixing 040 moved neither of 044's numbers.

        REPRO: lift the SKIP-WITH[--differentiate] on
        tests/spec/145-mma-autodiff/19-ring-pipelined-vjp-bmg.crisp and run

            sbcl --script tests/run-specs.lisp --differentiate --filter=19-ring-pipelined

            FAIL (FD vs analytical | atol=0.02):
              A: analytical=84.32  numerical=1.1992188  diff=83.12078

        The NUMERICAL column is right (expected 1.2), so the FORWARD is fine -- and that is now
        independently established rather than inferred: 138/07 and 138/08 run the same ring-slot
        MMA on metal at slot 0 and slot 1 and both report MMA_CORRECT.  The ANALYTICAL column is
        the wrong one, by a factor of roughly 70.

        WHY IT IS NOT 040, verified rather than assumed: both numbers are IDENTICAL before and
        after the 040 fix.  145/19's finite difference perturbs A[1,0], which lies entirely
        inside K-step 0, so it was always blind to 040's one-K-step truncation -- which is also
        why this spec could never have detected 040 in the first place, and why 040's claim to
        "BLOCK" it was wrong.

        NOT YET INVESTIGATED.  Some starting points, in the order I would try them:
          - 84.32 / 1.2 is about 70x, close to but not exactly the 64 or 128 you would expect
            from a whole tile or workgroup being double-counted; worth pinning down what the
            factor actually is before theorising, since an exact power of two would point at
            accumulation and a ragged one at addressing.
          - The prologue fills BOTH slots and the loop then refills the slot it just consumed,
            so a given slot is written more than once per kernel.  A backward that replays or
            accumulates per WRITE rather than per CONSUMED STAGE would over-count.  Endeavour
            149's primal replay is the obvious interaction to check.
          - Compare against 145/18 (ring STAGING gradients, no MMA), which gradient-checks
            exactly.  The difference between them isolates the MMA-plus-ring combination.

        BLOCKS: 145/19, and therefore the numeric proof for ring-pipelined gradients, and
        therefore un-skipping 138/04 and 138/05 under --differentiate.  (That inheritance is
        real; 040's version of it was not.)

[ ] 045 - `funcall` is not differentiable.  A DIRECT call to the same function is.

        FOUND 2026-08-14, during endeavour 150 (fused epilogue), while checking whether the
        machinery to differentiate a user-supplied activation existed at all.  It does — but
        only through the direct call form.

        REPRO.  Two kernels differing in ONE respect, both gradient-checked on BMG:

            (set! (~ C i) (funcall #'relu7 (~ A i)))   -> backward FAILS TO COMPILE:
                "Function FUNCALL is not differentiable.  Wrap the kernel in 'forward-only'
                 if differentiation is not needed, or ensure all called functions are
                 differentiable."

            (set! (~ C i) (relu7 (~ A i)))             -> PASS [l0]
                A: analytical=1.0 numerical=1.0 diff=0.0

        Probe kernels are in put_temp_files_here/150-vjp/ (scalar-relu.crisp is the failing
        form; the direct-call variant is the sed one-liner in the same directory).

        NOTE WHAT THE PASSING CASE PROVES, because it is more than it looks: the engine walks
        INTO the user function, differentiates through its `let` and its `if` kink, and mints
        the `_GRAD` twin itself —

            @relu7_float(float)                    ; forward
            @relu7_grad_float_float(float, float)  ; (primal, seed) -> d_primal

        So nothing about user-function AD is missing.  The gap is specifically that the walk
        has no rule for the INDIRECT call form.

        SCOPE — MEASURED, and NARROWER than first assumed.  The obvious worry is store-tile's
        `:transformF`, whose lowering builds a funcall (src/analysis/control.lisp:397-398).
        That worry is WRONG, and it was checked rather than reasoned about:

            tests/spec/111-load-and-store-tile/08-store-transformF.crisp   --differentiate: OK
            a float twin of it (put_temp_files_here/150-vjp/tf-float.crisp) --differentiate: OK

        Both compile clean, so the transformF path does not reach this wall.  WHY it does not
        is unestablished — do not record a cause here until someone looks.  (111/08 alone would
        have been weak evidence since its kernel is ulong and has no gradient path at all;
        the float twin is why the claim is stated as measured.)

        So the confirmed blast radius is: hand-written `funcall` in a differentiable data path.
        Whether any shipped spec does that is not known.

        DOES NOT BLOCK ENDEAVOUR 150.  map-elements! originally lowered its fused call through
        funcall and was changed to emit a DIRECT call, reading the name off the `#'FOO` it is
        handed (%map-elements-call).  Forward stayed 10/10 with byte-identical on-metal
        numbers.  That is a workaround for one form, not a fix for this bug.

        LIKELY FIX, offered as a STARTING POINT and not a diagnosis (see the 030-sweep lesson:
        three CAUSE lines in one sweep turned out wrong).  analyze-funcall-expression
        (src/analysis/control.lisp:1228) already resolves a `#'NAME` literal to a direct
        semantic-call — sub-case 2b, which even re-dispatches primitives by rewriting the form.
        If the AD walk sees the SOURCE form rather than that lowered node, the cheapest correct
        fix may be to normalise `(funcall #'NAME args...)` -> `(NAME args...)` before the walk,
        rather than to teach the walk about funcall.  Unverified.
[x] 046 - A LOCAL scratch CELL and a LOCAL scratch TENSOR were given the SAME shared-memory
        offset by the CUDA hoister, so they silently overwrote each other on the GPU.

        FOUND BY: endeavor 152's investigation into why a clustered kernel faulted.  Found
        incidentally -- it has nothing to do with clusters and has been live on `main` for as
        long as both features have coexisted.

        BUG 034 gave scratch TENSORS a running offset allocator (*cuda-shared-scratch-offset*)
        so they would not alias one another.  Cells were never added to it:
        %cuda-emit-cell-arg emitted `<name>_local_ptr = 0` unconditionally.  Every cell
        therefore sat at offset 0, directly on top of the first scratch tile.

        DEMONSTRATED ON AN H100.  Kernel loads a tile, writes a cell, stores the tile:

            BUFFER a: 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15
            BUFFER c: 99 1 2 3 4 5 6 7 99 1 2 3 4 5 6 7   <- element 0 of every tile clobbered

        WHY IT SURVIVED SO LONG: it is ORDERING-SENSITIVE and therefore invisible in the
        obvious test.  Put the cell write BEFORE the tile-stride loop and the tile load simply
        overwrites the cell -- output is perfectly correct.  Put it AFTER the store and the
        tile has already been banked out -- also correct.  Only a cell write INTERLEAVED with
        tile use exposes it, and no spec did that.  (The first version of the regression test
        written for this bug passed against the broken compiler for exactly this reason.)

        THE DEEPER CAUSE, and what the fix actually addresses: the hoister computed its
        shared-memory layout TWICE, independently -- compute-total-shared-bytes summed bytes
        for the launch parameter while the emitters assigned offsets.  Two computations of one
        number is what allowed them to disagree, and merely teaching the cell emitter to bump
        the counter would have left that structure in place to fail again.  Both now consult a
        single %cuda-shared-layout.

        Cells are laid out ABOVE the tensors rather than interleaved, so every existing
        kernel's tensor offsets are BYTE-IDENTICAL to before the fix -- verified.

        INTEL WAS NEVER AFFECTED: the L0 hoister gives each local tensor its own
        runtime-allocated SLM argument (zeKernelSetArgumentValue(..., bytes, nullptr)) instead
        of slicing one blob, so it has nothing to alias.

        FIX: overlays/hoist-cuda/crisp-hoist-cuda-overlay.lisp -- %cuda-local-param-bytes,
        %cuda-shared-layout, compute-total-shared-bytes, %cuda-emit-cell-arg, and an
        emit-kernel-args wrapper that seeds the cell offset.
        REGRESSION: tests/spec/074-scratch-tensor/05-cell-tensor-no-alias.crisp (metal, both
        vendors).  Verified failing before the fix and passing after, on an H100.

[ ] 047 - A scratch CELL bound in a def-kernel `let` crashes the compiler under --differentiate.

        FOUND BY: writing BUG 046's regression spec, which is the first spec to bind a
        make-scratch-cell inside a def-kernel let and then differentiate it.

        %promote-scratch-init-for-ad assumes a scratch initialiser is a TENSOR.  Handed
        (make-scratch-cell float) it constructs the incomplete type specifier (tensor float)
        and %expand-tensor-type-specifier signals CRISP-INCOMPLETE-TYPE-ERROR:

            2: (ERROR CRISP-INCOMPLETE-TYPE-ERROR :TYPE-SPEC (TENSOR FLOAT))
            3: (%EXPAND-TENSOR-TYPE-SPECIFIER TENSOR FLOAT NIL (TENSOR FLOAT))
            4: (%PROMOTE-SCRATCH-INIT-FOR-AD (MAKE-SCRATCH-CELL FLOAT))
            5: (GENERATE-BACKWARD-WALK ...)

        Unrelated to BUG 046 -- it fires in the AD walk, not the hoister.  The kernel is
        differentiable in principle (in the regression spec the cell is written and never read,
        so its adjoint is zero); the promoter simply has no cell case.

        CURRENTLY SKIPPED: tests/spec/074-scratch-tensor/05-cell-tensor-no-alias.crisp carries a
        SKIP-WITH[--differentiate] pointing here.  Remove it when this is fixed.

[ ] 048 - UNVERIFIED: a ring slot used as a TMA destination may violate the 128-byte
        alignment `cp.async.bulk.tensor` requires of its shared destination.

        FILED 2026-08-17 AND IMMEDIATELY CORRECTED.  The first version of this entry claimed the
        defect had been demonstrated by spec 152/11.  IT HAD NOT, and the reasoning was wrong in
        a way worth recording, because it is the same trap this endeavour has fallen into before.

        WHAT ACTUALLY HAPPENED.  152/11 reported `misaligned address` after endeavor 152's fix B.
        The real cause was in fix B itself: the `.extern .shared` window symbol was declared
        `.align 16`, so the CTA's window base -- and therefore ring slot 0 at base+0 -- was not
        128-byte aligned.  Declaring the symbol `.align 128` fixed it, and 152/11 now PASSES on
        an H100 with the expected buffer.  Nothing about ring slot stride was involved.

        HOW THE MISDIAGNOSIS HAPPENED: two variables were changed in a single step -- the symbol
        alignment AND the spec's tile shape (2 4)->(2 16) -- and the resulting pass was credited
        to the tile shape.  It was the alignment.  Change one thing at a time.

        AND 152/11 COULD NOT HAVE SHOWN IT ANYWAY.  Its C is 4x4 with a (2 4) tile, so the column
        axis has exactly ONE tile: `grid-x` is always 0 and `slot = (mod grid-x 2)` is always 0.
        The spec never reaches slot 1.

        WHAT REMAINS, AS A HYPOTHESIS AND NOT A FINDING.  The PTX ISA does require a
        `cp.async.bulk.tensor` shared destination to be 128-byte aligned, and Crisp packs ring
        slots at a stride of one tile's byte size with nothing checking that figure.  A 32-byte
        tile would put slot 1 at base+32, which is not 128-aligned.  So the concern is grounded
        in the ISA -- but it is UNDEMONSTRATED.

        ATTEMPTED AND FAILED TO REPRODUCE: reaching slot 1 needs more than one column tile, which
        with the harness's fixed 4-element dim extents needs a tile narrower than 4 floats; but
        TMA also requires the innermost box to be a multiple of 16 bytes, so a (2 2) float tile is
        rejected by the descriptor with `invalid argument` before any alignment check runs.  The
        two constraints exclude each other at this buffer size.

        TO CLOSE THIS: build a case with larger buffers (a hoist harness with dim extents > 4)
        where a TMA-legal tile still leaves a sub-128-byte slot stride.  If it faults, decide
        between padding slots to 128 and refusing at compile time.  If it does not, delete this
        entry.  Do NOT act on it before it is reproduced.

[x] 049 - A MULTICAST kernel CRASHES when the launch grid must be PADDED to fit its cluster.

        FOUND 2026-08-18 on an H100, running the full NVIDIA matmul suite.  chap4_cluster_multicast
        (cluster (2 2), :multicast true) reports `unspecified launch failure` at N=256 and produces
        no result; every larger size runs correctly.  chap3, the same kernel without a cluster,
        runs N=256 fine.

        THE MECHANISM WAS PREDICTED BEFORE IT WAS SEEN.  Endeavor 152 noted the open question days
        earlier: the CUDA hoist pads the grid up to a multiple of the cluster shape, and PADDED
        WORKGROUPS EXIT WITHOUT PARTICIPATING.  For an ordinary kernel that is what the docs say --
        "a small amount of wasted dispatch, not correctness".  For a MULTICAST kernel it is fatal:
        the padded workgroups are still members of a cluster, so a barrier that expects arrivals
        from the whole cluster never receives them, and a multicast addressed to the whole group
        writes into a workgroup that has already left.

        At N=256 with a 64x256 output tile the grid is 4x1.  A (2 2) cluster forces the second axis
        to be padded from 1 to 2, so HALF of every cluster is padding.

        DOCUMENTATION IS CURRENTLY WRONG: docs/topology.md describes grid padding as costing only
        wasted dispatch.  That sentence must be qualified -- it is false for any kernel with a
        cluster-scoped barrier or a multicast load.

        LIKELY FIXES, in increasing order of ambition:
          (a) REFUSE at compile time when a multicast/cluster-barrier kernel's grid could require
              padding, naming the offending size relationship.  Smallest, and honest.
          (b) Have padded workgroups still participate in the cluster's barriers (arrive and
              leave) rather than exiting early.  Correct, but every barrier's arrival count then
              depends on how much padding a given launch has.
          (c) Choose the cluster shape per launch so the grid divides exactly.  That is the
              `:exact` strategy the hoist already refuses to pad for -- worth revisiting.

        DOES NOT BLOCK the endeavour's conclusion: chapter 4 is slower than chapter 3 at every
        size that runs, and 256 is far below where either kernel is interesting.

        FIXED 2026-08-18.  The compiler records `:cluster-reach` in the metacrisp when a module
        multicasts a load or declares a :mode :cluster barrier, and the CUDA hoist refuses to pad
        the grid of such a kernel -- treating it exactly like `:strategy :exact`, with a message
        naming the real constraint.  An `unspecified launch failure` becomes a refusal that says
        why.

        NOT A COMPILE-TIME REFUSAL, deliberately: the grid comes from `:derive-from C` and is only
        known at launch, so the check is emitted into the host code.

        THE FLAG IS MODULE-SCOPED and therefore conservative -- if any kernel in a module uses
        reach, every clustered kernel in it declines padding.  Precise per-kernel attribution
        would mean threading a flag through the whole analysis; over-refusing a kernel that gains
        nothing from its cluster anyway is the cheaper error, and it errs safely.

        BOTH SIDES ARE PINNED: spec 26-cluster-reach-refuses-padding asserts a multicast kernel's
        launcher REFUSES, and spec 04-cluster-size-on-metal (a cluster with no reach) still PADS.
        Verified: rung 04 emits no reach flag and keeps its padding arithmetic.

        STILL OPEN as the better long-term fix: let padded workgroups PARTICIPATE in the cluster's
        barriers rather than exiting, which would make padding safe instead of forbidden.  That
        needs the tile-stride trip count to be uniform across a cluster -- a real change.

[x] 050 - A MULTICAST load CRASHES at a narrow output tile (64x32), while the same tile without
        multicast runs fine.

        FOUND 2026-08-19 by the arithmetic-intensity probe.  `p_mc32` -- chapter 4's kernel with a
        64x32 output tile, cluster (2 1), B multicast only -- fails with `unspecified launch
        failure` at N=2048 and N=4096.  Its no-multicast control at the SAME tile runs correctly,
        and every wider multicast tile (64x64, 64x128, 64x256) runs correctly.  So it is the
        combination of multicast with this narrow shape.

        NOT BUG 049: grid divisibility is satisfied (2048/64 = 32 rows of tiles, 32 % 2 == 0), so
        no padding is required and the new refusal does not fire.

        PROBABLY NOT BUG 048 either: the B ring at this shape is 32x32 floats = 4096 bytes per
        slot, so slot 1 begins at a 128-byte aligned offset.

        WHAT IT COST: the lowest-arithmetic-intensity point of the probe (AI 10.7), which is the
        point that would best have separated the two competing explanations for why multicast
        helps at 64x128 -- lower arithmetic intensity versus higher occupancy.  Worth fixing for
        that reason alone if that question is ever pursued.

        FIXED 2026-08-19.  A CTA was RETURNING from a cluster kernel while its peers could still
        be multicasting into its shared memory.  CUDA requires a cluster sync before exit when
        distributed shared memory is in use; Crisp's fences were all emitted at BARRIER
        CONSTRUCTION -- i.e. in the prologue -- and there was none before `ret`.
        generate-function-body now emits one for any clustered PTX entry point.

        THE DIAGNOSIS TURNED ON A DETAIL WORTH REMEMBERING: under compute-sanitizer the kernel
        RAN CORRECTLY (MMA_CORRECT, 3985 GFLOPS) and failed only without it.  That is the
        signature of a RACE rather than a bad address -- the sanitizer's serialisation closes the
        window.  Checking that the kernel had actually run, rather than accepting "0 errors", is
        what turned a clean sanitizer report into evidence.

        THE SHAPE DEPENDENCE WAS THE OTHER CLUE: a narrow output tile means less work per
        workgroup, which widens the window in which one member finishes and exits while peers are
        still streaming.  That is why 64x32 failed while 64x64, 64x128 and 64x256 did not.

        VERIFIED: p_mc32 now runs MMA_CORRECT at 73.9 TFLOPS; chapter 3 (no cluster) emits zero
        cluster fences and is byte-unchanged; 1023/1023 both ways.

[ ] 051 prefetch-tile is DROPPED inside branches.  Sibling (when ...) forms each holding one
        prefetch-tile emit only ONE prefetch; a nested (if ...) chain emits ZERO.  Sibling whens
        holding load-tile are FINE (16/16), so this is specific to prefetch-tile -- the one
        statement that is void and yields no value.  CAUSE IS A HYPOTHESIS: the branching
        analyzers look value-oriented and discard a branch whose body yields nothing; same
        family as the crisp.compiler::cond quirk.
        Repro: put_temp_files_here/bug-051-repro/v1..v5 (deliberately NOT under tests/spec/ --
        the spec runner globs **/*.crisp and two of the five encode BUGGY output as expected).
        NOT a blocker for endeavour 158: the target kernel puts both prefetches inside ONE
        (when ...), which is the working v1 shape, and :warp-partitioned distributes
        BRANCH-FREE so the compiler never generates the sibling branches that trigger it.
        Latent defect in the pre-existing coordinate form; a user CAN hit it by hand.

[x] 052 CLOSED — NOT A BUG.  The wgmma no-swizzle (scatter) path is NOT implicated; all four
        failing probe arms had non-compiler causes.  Resolved 2026-09-01 WITHOUT a GPU, by
        auditing operand shapes across every wgmma kernel in the tree.

        WHAT THE FOUR ARMS ACTUALLY WERE.
          * The two SCATTER arms staged a TRANSPOSED B.  wgmma with transB=0 reads its SMEM B
            operand as (N K) -- K contiguous, i.e. B^T.  Both probes declared (K N):
                _probe_wgmma_bf16_scatter  shape (64 64 16)  B-tile (16 64)   want (64 16)
                _probe_wgmma_tf32_scatter  shape (64 64  8)  B-tile (16 64)   want (64  8)
            The tf32 arm -- the "control" whose failure at commit 3da5807a made the bug look
            pre-existing and conclusive -- is WORSE than that: its A-tile is (64 16), sized for a
            bf16 k16 slice, against a declared K of 8.  It was copy-pasted from the bf16 probe and
            the A-tile was never adjusted.  BOTH of its operands are malformed.  A kernel that is
            wrong is wrong at every commit, which is exactly the trap the downgrade note called.
          * The two SWZ arms failed on the FIXTURE, not the compiler: bench_harness.cu hardcoded
            CU_TENSOR_MAP_SWIZZLE_NONE while the kernel descriptor declared 128B.  Fixed
            2026-09-01; chapter 7 bf16 -- the same swizzle path -- now verifies bit-exact
            (max_abs_err 0) at all eight sizes 512..4096 on an H100 NVL.

        THE EVIDENCE THAT SETTLES IT.  Across all 27 wgmma-accumulate-via-tile call sites in
        tests/spec and benchmarks/matmul, the split is perfect and has no exceptions:
            every kernel EVER VERIFIED NUMERICALLY (chap7 tf32+bf16, sec2_top x3, sec3 x3,
              sec4 x2, 140/03, 154/01-03, both _swz probes -- 13 of 13) has A=(M K), B=(N K);
            every violator (12 files) is COMPILE-ONLY or a never-executed probe.
        Nothing remains that implicates %wgmma-make-desc's no-swizzle LBO=128B/SBO=256B branch.

        THE ONE TRUE CLAIM IN THE ORIGINAL ENTRY SURVIVES, and is now the follow-up: the
        scatter path has still never been executed against a host reference.  Its coverage is
        140/00-wgmma-forms, which is compile-only.  Fixing the two probes' operand shapes and
        running them is a ~2-minute metal check next time a pod is up.  Until then the path is
        UNCOVERED, which is a test gap, not a defect.

[x] 053 FIXED — wgmma-accumulate-via-tile never validated its operand tile shapes, so a
        transposed B compiled clean and computed garbage.  Endeavour 161, 2026-09-02.
        %check-wgmma-shape validated the (M N K) triple and the element type and stopped; nothing
        downstream looked either, because %wgmma-make-desc's LBO/SBO constants are HARDCODED and
        the tile extents reached neither the descriptor nor the instruction.
        THE RULE, from CUTLASS and not from inference: A is (M K), B is (N K), both K-major
        (smem_desc<GMMA::Major::K>, ABLayout<64,8>; the tf32 SS atoms exist only in the _TN form).
        NOTE THE TWO via-tile FORMS GENUINELY DISAGREE, which is why all twelve violators erred
        the same way -- mma-accumulate-via-tile takes B as (Kt Nt).  The errors say so.
        B gets TWO messages: at tf32 (K N) is not a layout the instruction can read at all; at
        16 bits it IS legal hardware via transB=1, and Crisp merely pins transA/transB to (0 0),
        so the refusal there is a fact about this compiler and says so.
        ALSO in 161: %check-wgmma-shape became profile-driven, matching %check-mma-shape's
        two-branch structure -- a new optional :wgmma-shapes profile key (WARPGROUP granularity;
        :mma-shapes is FRAGMENT granularity and is read as such in ~18 places), else the sm_90a
        constraints as a documented fallback.  See tests/spec/161-wgmma-shape-validation/.
        1057/1057 E2E + 232/232 negative + 291/291 unit.  Twelve kernels corrected, none of them
        ever numerically verified, so no measured result moved.
        OPEN FOLLOW-UPS: infer transB from tile orientation at 16 bits; enumerate sm_90a's legal
        wgmma shapes into the builtin h100 profile (deliberately not done -- an incomplete list
        would refuse working benchmark kernels).
