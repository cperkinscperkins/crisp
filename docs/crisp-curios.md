Curious Things To Know About Crisp
==================================

- recursion (and mutual recursion) are DISALLOWED.
- template support
- passing functions as first order arguments means the function is implicitly promoted to a template (if not already templated), specialized on <F>, and then we monomorphically instantiate the actual function arg.
- functions with &optional and &key parameters have their combinations monomorphically templated. lazy instantiated though to fulfill actual calls.
- def-struct maps to a linear block of memory (std140 aligned), whereas def-record maps to individual register addresses.  def-struct and def-record have the same affordances (property accessors, etc) but very different approaches
- all def-record based items lead to Architectural Scalar Replacement of Aggregates (SROA).  When anything based off def-record as passed as a function argument, in the LLVM-IR it gets exploded to the individual properties, each one passed as an argument, and implicitly reassembled by the callee.  
- def-kernel-exact uses marshall-XXXXX functions to take individual parameters passed by the host to the kernel and "marshall-XXXX" them into Storage Handles (which are based on def-record)
- def-kernel usually has Storage Handles are parameters, it gets macroexpanded into def-kernel-exact.
- Crisp does not have the Common Lisp `let` or `let*`. It has its own `let` which is like `let*` except it supports multiple value bind directly.
- Crisp leverages Common Lisp's macro support. Thus users can use defmacro and some Common Lisp forms to expand to Crisp forms. The supported Common Lisp forms are documented in defmacro-utils.md
- Crisp also uses Common Lisp macros to expand some of its own forms (def-function and others) into semantic nodes.
- the Spir-V metatadata is injected manually, rather than using LLVM Dev bindings.  
