
SBCL / LLVM Dev / C2FFI / CFFI

Target #1: Download
- [x] install SBCL
- [x] install LLVM Dev
- Q: anything add to the repo?
- A: YES - [x] instructions on install SBCL and LLVM Dev

~~Target #2: Generate bindings~~
~~[ ] C2FFI~~
~~[ ] using clang run against LLVM Dev headers~~
~~[ ] check those into repo.~~
~~[ ] Add instructions for how to Generate Bindings~~

Target #3: Start Lisp Project
- [x] ASDF
- [x] start with some of our dependencies.
- [ ] Whatever is needed for QuickLisp
- [x] hello world?
- [x] INSTALL.md:  where/how to get QuickLisp


Target 3.5 Hook Up Bindings
- [/] cffi-grovel
- [x] use cffi and just hook them up manually.
- [x] This works: `(crisp.llvm-bindings:llvm-module-create "my_test_module")`  
    Should we put it in a test?

Target #4: Protected Namespace
We can't have reader macros inserted into Crisp
code to trigger behavior.
- [x] locked down namespace

Target #5: Our first Crisp Expression.
- : declaim? def-kernel ? with-template-type? def-function?
- [ ] def-function
- [ ] (def-function () (declare (return-type int)) 7) ; a function that returns 7.
- [ ] parsing #'
- [ ] macroexpansion
- [ ] walk AST, construct data struc
- [ ] walk DATA STUCT, analyze types

Target #6 - LLVM IR
- [ ] walk DATA STUCT, gen LLVM IR
- [ ] compile
- [ ] test? golden string or using ORC?
- [ ] Make a new "in-progress" doc and check "[ ] minimal def-function" ?

Target #7 - Transpile
- [ ] walk DATA STRUC, gen OpenCL C.
- [ ] compile
- [ ] test?
- [ ] update "in-progress" doc

Target #8  - Continuous Integration
- [ ] github actions. 
- [ ] Intermediate testing? Of Lisp macros etc

Target #9 - Deploy Crisp on QuickLisp
- [ ] ?


Compilation Steps
=================

1 - Parse ( free )
2 - Macro Expansion (free)
3 - Semantic Analysys - build symbol table with "meaning" of every symbol in AST.
4 - Type Inference and Type Checking
5 - Function Resolution ( Overloads and Templates )
6 - Contextual Validation ( grid-level vs thread etc) <-- might be doable at different stages.
7 - Generate IR / Transpile


LLVM IR
=======

- handle ALL the template logic and compile the specializations that need to be generated.
- make inline decisions? : mostly NO. LLVM will do that for us.
- handle functions overloading (somehow) for functions that aren't being inlined. Use "inlinehint"
- compile the arithmetic expressions for all supported types
- figure out the variables, and their SSA, especially for assignments.
  : NOTE "alloca" is an alternate. store in register
- loops (dotimes and grid strides and whatnot)
- memory deref for (~ someVec idx) and setting
- property accessors
- binding GPU functions (get-global-id )
- function interfaces (params and return vars) : virtual registers %a %b
- function calls (when not inlining)
- if / etc control flow
- currying : wrap in func, thunk
- type promotion
- def-constant-vector and other constant memory expressions
- shuffles : provided intrinsics
- atomics : provided
- HOF stuff
- some low-level macro affordances like kernel-halt! and some others
- structs : LLVMStuctType::create(...) and Type context
- DWARF meta for EVERYTHING

