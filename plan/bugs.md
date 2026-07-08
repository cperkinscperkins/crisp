
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

[/] 031 - Intel BMG OpenCL ICD breaks VERIFY-AUTODIFF forward FD step.  Level Zero
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
[ ] 033 --debug/GENERIC c-t accessor emits an env-dependent garbage-typed return.
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
