
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
- [x] def-function
- [x] (def-function () (declare (return-type int)) 7) ; a function that returns 7.
- [x] parsing #'
- [x] macroexpansion
- [x] walk AST, construct data struc
- [x] walk DATA STUCT, analyze types

Target #6 - LLVM IR
- [x] walk DATA STUCT, gen LLVM IR
- [ ] compile
- [ ] test? golden string or using ORC?
- [ ] Make a new "in-progress" doc and check "[ ] minimal def-function" ?

Target #7 - Transpile
- [ ] walk DATA STRUC, gen OpenCL C.
- [ ] compile
- [ ] test?
- [ ] update "in-progress" doc

Target #8  - Continuous Integration
- [x] github actions. 
- [x] Intermediate testing? Of Lisp macros etc
- [x] Honestly, this is ongoing. Will need a more serious test infra soon likely

Target #9 - Deploy Crisp on QuickLisp
- [ ] ?

Target #10 - Hoisting

Target #11 - C API for Compilation

Target #12 - def-orchestration


Compilation Steps
=================

- Parse ( free )
- Macro Expansion (free)
- Semantic Analysys - build symbol table with "meaning" of every symbol in AST.
- Type Inference and Type Checking
- Function Resolution ( Overloads and Templates )
- Contextual Validation ( grid-level vs thread etc) <-- might be doable at different stages.
- Generate IR / Transpile


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


Next Priorities
===============
- [x] lose  (a i32)
- [x] (declare #'(int int => int))
- [x] lowercase function names ("wow" not "WOW").
- [x] GHA CI
- [ ] Error Handling and Reporting 
- - [x] line number and file -> moved to tree.leaf.branch
- - [ ] our internal errors? (we will have a LOT of defmacro)
- - [ ] errors from LLVM ?
- - [ ] bad defmacro from user
- - [x] type mismatch
- - [ ] failure to infer 
- - [x] misspelling
- - [ ] bad syntax / paren
- - [x] wrong number/type args
- - [ ] keep eye on use cases Tests, Compiler.exe, C API
- - [ ] How to test our own error system?

ERRORS
- [x] incomplete type signature: no (type b int).  I guess if no return-type we just assume nil?
- [x] (def-function (def-function)) illegal nesting'
- [x] unknown function/symbol call (whack ..)
- [x] unbound argument (+ whack adoodle)
- [ ] macro stuff?
- [ ] malformed -  ?? => => 
- [x] missing paren
- [x] recursion
- [x] mutual recursion
- [x] call fn with wrong number of args
- [ ] unrecognized flags

LOOSE PRIORITIES
- [x] Linux?
- [x] DWARF
- [ ] def-grid-function
- [ ] def-kernel - case-sensitive
- [ ] Hoisting
- [ ] E2E Test?
- [ ] with-template-type
- [ ] funcction overloading
- [ ] multiple return values
- [ ] let with mv bindings
- [ ] first order functions & funcall
- [x] add more types
- - [ ] bool type decisions
- - [ ] hardware vector types
- [x] type promotion &c.
- - [ ] type promotion in + ? - maybe this requires let to test
- [ ] &optional &key 
- [ ] &out
- [ ] defmacro
- [ ] variadic + < = etc
- [ ] vectors
- [ ] def-struct
- [ ] cond  ( we can make all other divergent control flows from that: when, if, unless)
- [ ] bool true false.  ( macros can still use T/nil ? )
- [ ] precision selections (declare / declaim / flags )
- [ ] .crisp files.  basic flag for crisp-compiler.exe
- [ ] SIDE CHANNEL MECHANISM.  probably sooner, rather than later. 


SHORT TERM PLAN
- [x] let
- - [ ] declare (type ) ?
- - [ ] hella testing
- [x] function overloads
- - [x] testing
- [ ] more let: multiple value return and bind
- [ ] templates as macros
- [ ] higher order functions as templates
- [ ] need to move more of our old erstaz logging to log4cl. 
- [ ] Side Channel / Implicit Args. Can we start this BEFORE def-kernel? 


M-V-R
- [ ]add a variadic (return a b c ...) so multiple values can actually be returned.
- [x]decide how we want to support that at the LLVM-IR level
- [ ]implement the above and add tests.
- [ ]update "let" support so it supports the bindings. (let ((quot rem (/ a b))) ...)
- [ ]test that.


QUESTIONS
- [ ] should log4CL be used ONLY for logging? Or should it be used for general compiler output 
      like error messages and warnings and the like?






- [ ] SEO (even the _AIs_ can't find us, completely unsearchable today)

- [ ] Testing Next Stages
- - [x] Rove or _Parachute_ for tests. Integrated with our GHA
- - [ ] Prepare Intel OpenCL CPU Runtime to test kernels
- - [ ] POCL (portable OpenCL) ??
- - [ ] buy PC w/ GPU and hook up as Self Hosted runner. 
- [ ] Get logging under control
- - [x] Log4CL.  Probably the best choice. Mostly "compiles away".   There is also Verbose

- [ ] proper bug tracker?
- - [ ] GitHub Issues?  