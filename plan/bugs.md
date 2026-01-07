
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


[ ] 009  casting and conversion for def-type not working.  See tests/spec/018-def-type/04-casting.crisp

[ ] 010  kernel type declaration throwing error when it shouldn't. tests\spec\028-metadata\04-basic-struct.crisp
   