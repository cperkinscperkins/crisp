
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