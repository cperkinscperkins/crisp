
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

