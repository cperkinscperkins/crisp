
[x] 001 --debug/-g flag causes :debug log to be set. Incorrect. Those should be orthogonal.
[x] 002 function overloads are not resolving correctly. Seems to alwasy choose "last seen".
        tests/def-function-overloads.crisp demonstrates this problem.
[x] 003 %call_tmp = call <cannot get addrspace!> i32 <null operand!>(i32 %x1) 
       appears in LLVM output of let bindings with function calls.
       See bind-f-call in tests/let-bindings.crisp
       Also in the def-function-overloads add_three LLVM-IR gen

[ ] 004 reading of 3.14 as a float literal is not working.
[ ] 005 reading of 314 as a long literal is not working ( defaults to int)