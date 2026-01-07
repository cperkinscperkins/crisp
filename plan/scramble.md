
SBCL / LLVM Dev / C2FFI / CFFI

Target #1: Download
- [x] install SBCL
- [x] install LLVM Dev
- Q: anything add to the repo?
- A: YES - [x] instructions on install SBCL and LLVM Dev

Instead of Generating all bindings automatically, we just lift them
individuall from the headers and manually update llvm-bindings.lisp

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

Transpiling is no longer a target.  Targeting LLVM-IR is general purpose and powerful
enough for our needs.  Plus, we add Dwarf symbols from the beginning, so that leaves
little purpose to transpiling.
~~Target #7 - Transpile~~
~~- [ ] walk DATA STRUC, gen OpenCL C.~~
~~- [ ] compile~~
~~- [ ] test?~~
~~- [ ] update "in-progress" doc~~

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
- [x] def-kernel - case-sensitive
- [ ] Hoisting
- [x] E2E Test?
- [x] with-template-type
- [x] funcction overloading
- [x] multiple return values
- [x] let with mv bindings
- [x] first order functions & funcall
- [x] add more types
- - [ ] bool type decisions
- - [ ] hardware vector types
- [x] type promotion &c.
- - [ ] type promotion in + ? - maybe this requires let to test
- [x] &optional &key 
- [x] &out
- [x] defmacro
- [ ] variadic + < = etc
- [ ] vectors
- [x] def-struct
- [x] cond  ( we can make all other divergent control flows from that: when, if, unless)
- [ ] bool true false.  ( macros can still use T/nil ? )
- [ ] precision selections (declare / declaim / flags )
- [x] .crisp files.  basic flag for crisp-compiler.exe
- [x] SIDE CHANNEL MECHANISM.  probably sooner, rather than later. 
- [ ] Literals: use suffix ?   0.0f  INSTEAD of (type a float) in a let clause?


SHORT TERM PLAN
- [x] let
- - [ ] declare (type ) ?
- - [ ] hella testing
- [x] function overloads
- - [x] testing
- [x] more let: multiple value return and bind
- [x] templates as macros
- [x] higher order functions as templates
      binop-type ? 
- [ ] need to move more of our old erstaz logging to log4cl. 
- [x] Side Channel / Implicit Args. Can we start this BEFORE def-kernel? 
- - [x] last test that Side Channel ptr/size is showing up in the IR of correct leves Kernel->A->(B!!!)->C->D
- - [x] ALSO, if scratch-cell IS passed to C and D then it is explicit, but STILL two args (not one). Damnit - forgot to handle/check this.
- [ ] Crisp IR. Some operations (async loading mostly) are not available in LLVM-IR and require
      target platform intrinsics to be supported.  We should probably generalize this sooner rather than later.
      I'm not keen on having a whole IR.  Maybe we start with op-fma or something as POC?
      Would require `--ir-target=SPIRV` or `--ir-target=PTX` at minimum.

- [x] defmacro - Get it in now. Shouldn't be difficult, paves way to "crisp in crisp"
- [x] conditionals - LLVM Blocks and branches. Will be needed for "crisp-in-crisp" vectors etc.
- - [ ] anaphoric support
- - [ ] star `*` variants
- [x] def-struct - :std140 , property accessors, ADVANCED member lookup, setter and getter?  A BIG lift.
- [x] compile time assert mightn't be the worst idea. Pretty handy. 
- [x] refactor? compiler.lisp is nearly 2000 lines. maybe analysis.lisp and compiler.lisp ?
- [x] neq is /= , but probably should be != 
- [ ] refactor.  reevalute ALL uses of symbolp looking for implicit expectation that (symbolp nil) is false (it's actually true)
- [x] def-enumeration
- - address space
- - access
- [x] compile time struct properties
- [x] runtime assert and --runtime-checks flag
- [x] def-record 
- [x] revisit "implicit" and "exploded" args - def-record FTW
- [x] error handling
- [x] &optional , &key and defaults and is-set?
- [x] &out

- [x] def-type  <--  we will need this to create vector from tensor, etc.
                       I'm tempted to do def-derived-type too
- [ ] damn literal numbers are long overdue.  1.0f 1i 2l  something.
- - [ ] also, give up on "no (to-int )" already. geebus
- [ ] Storage Handles. Or at least a proper cell. In theory, this could be the first 'crisp-in-crisp' construct.
- - [x] Storage Properties  (cannot be set)
- - - [x] address-space
- - - [x] access
- - - [x] bytes
- - [x] Cell Properties ( CAN be set )
- - - [x] offset~
- - - [x] parent~ 
- - [x] Compile Time Cell Properties
- - - [x] element-type~
- - [x] Cell Operations
- - - [x] (~ someCell)
- - - [x] (set! (~ someCell) newValue)
- - - [ ] (atomic-xchg! (~ someCell) newValue)
- - [x] def-setter
- - [x] overload ~
- - [x] cell type constructors (&optional first, maybe not &key quite yet)
- - [ ] insertion of r-t-assert when set! offset~ or parent~ ?
- - - [ ] validation against --runtime-checks flag
- - [x] incomplete types: formalize and test.
- - - [x] polymorphism
- - - [x] compile errors if conflict.  
- - [x] type constructors for all def-struct / def-record with :c-t props
        This _might_ be tested already, check.
- - [ ] Tensor Properties ( can be set)
- - - [ ] length~ ( number of elements)
- - - [ ] parent~
- - - [ ] alignment~ <-- compile time.
- - - [ ] offset~
- - - [ ] num-dims~   <-- compile time. 
- - - [ ] strides~
- - - [ ] extents~
- - - [ ] element-type~
- - [ ] Pass Through
- - - (access~ someCellOrTensor)
- - - (address-space~ someCellOrTensor)
- - [ ] built atop def-struct ? 
- [x] def-kernel-exact 
- [x] def-kernel  <-- 
- [ ] expand variadics (+, * etc).  Maybe up to 5 or 7?  (+ a b c d e)
- [ ] def-function has strict return type checking. Meaning, if it declares nil as return type,
      it has to return nil ( just add `(return)` ).  This is not necessarily optimal.
      For def-grid-function and def-kernel, we can have the macro amend that `(return)` so it's a
      non-issue.  If we want, consider enhancing analyze-body-expressions to correctly handle nil literals as valid void-return expressions (currently they are filtered out).


M-V-R
- [x]add a variadic (return a b c ...) so multiple values can actually be returned.
- [x]decide how we want to support that at the LLVM-IR level
- [x]implement the above and add tests.
- [x]update "let" support so it supports the bindings. (let ((quot rem (/ a b))) ...)
- [x]test that.

Debugging
- [x] advise any function? Maybe advise-these at startup
- [x] let-d  that logs each binding?
- [x] refactor generate-llvm-ir  
- [x] .bat to run all .crisp tests from compiler. local E2E easier
- [x] dump-env to print out all the bindings in an environemnt
- [ ] plus similar for *function-table* and others

Kernels
- [x] def-kernel-exact
- [x] gen-some_kernel T "name"
- [x] error messages
- - 06 - kernels can't declare they return values
- [x] refactor
- [x] deferred errors
- - [x] 03 no casting of voidp
- - [x] 04 invalid return (return 0)
- - [x] 08  complete types for marshall  <-- reoprioritize this highly
- - [x] all the def-kernel-exact errors need to be revived for def-kernel.
- - [x] and I should probably just write the damn def-kernel transformation macro
- [x] def-kernel
- [x] --ir-target
- - [ ] llvm-ir
- - [x] spirv
- - [x] ptx?
- [ ] --binary-gpu-target
- [x] test on BMG
- [ ] metadata
- [ ] hoisting


QUESTIONS
- [ ] should log4CL be used ONLY for logging? Or should it be used for general compiler output 
      like error messages and warnings and the like?
- [ ] why are the log:debug and the like not showing up in Alive REPL even if the log level is set?

- [ ] commutative-op-type instead of binop-type requirement for reductions? Would require users
      to define a type constraint for their own functions.  Annoying or useful?

LANGUAGE CHANGES
- [x] lose declare local/global. Too complex
- [ ] instead use (make-single-result T :global) . Might want to consider renaming 'single-result'
- [ ] How to initialize the single-result? It has to be done by hoisting code for :global.
      And cannot be done for :local. So maybe the user just has to (set! ) or (atomic-xchg! ) it 
      themselves.
- [x] Shore up set! and atomic-ops
- - (atomic-inc! someVar)                 <--
- - (atomic-inc! someTensor (x y z ...))
- - (atomic-inc! someSingleRes)           <--   hmmm. atomic-inc-result! ?
- - atomic-set! would just be atomic-xchg!  .  
- - (atomic-set-result! someSingleRes val)   
- - (atomic-set! someTensor (x y z ...) val)
- - (atomic-set! someVar val)  
- - (set! someVar someVal)
- - (set! (~ someTensor x y z)  val) 
- - (set! (~ someCell) val)  <--  cell doesn't need '0'  
- - (set-result! someSingleRes val)  ;; Q: should this compile error if :global ?
                                     ;; A: no. It is totaly valid to (when (= id 0) (set! ...))

- [x] suggestion: rename single-result to 'cell'.  (make-cell int :local)
- [x] use (~ someCell) without 0 to get and set its value.
- [x] atomic ops should be uniform (more or less), but DO expand for tensors (atomic-op! someTensor (x y z...) <val?>)
- [x] (make-scratch-cell T :global &key msg) 
      (make-scratch-vector VectorT size &key msg) 
      (make-scratch-tensor tensorT (size size size..) &key msg)
      IMPORTANT: is SIZE compile time calculable only?  
              A:  No. That gets communicated back to the host. So it would be ideal that it NOT be 
                  a random runtime value.  
      NOTE: don't do make-scratch-matrix at this time. Use make-scratch-tensor. 

 - [x] IDEA: instead of separate functions for common topologies, flag them?
      These are for the `size` arg.
      :match-workgroup-size
      :match-num-workgroups
      :match-total-threads
      :match-warp-size
      :match-num-warps-per-workgroup
      :match-total-warps
      That way we stop the explosion of helper functions. make-scratch-cell/vector/tensor are the ONLY ones.
       ...well, maybe tiles?

      A tensor matching the above just has the total allocation that matches the total size of that thing.
      I guess. Might need to think what it means when they don't align. (2D workgroup, 4D tensor)

- [x] TODO: go through docs changing generic Vector to Storage Handle.
- - side channel
- [ ] Revisit `def-constant-vector` . `def-contstant-storage` ??

- [x] Resolve `vector-type` vs. `vector` etc.  UPDATE: implementation is using 'cell' not 'cell-type'

- [ ] FML - +warp-size+ is 32 throughout the doc, but ideal warp size
            on BattleMage might be 16.  How is that set/handled?

- [x] remove x:int style type declarations. Just use : for namespaces at some later date.
- [ ] if-reorder <-- see google doc.
- [ ] change => nil to => void ?? 
- [x] :read_write vs :read-write 
- [ ] `--allow-redefinition` . Crisp gets Common Lisp super power of "last defined rules".  Will require a COMPLETE extra preperatory pass. Document with the other Code Transformation flags ( --re-output-crisp and --tree-shaking )
Won't work with defmacro (obviously). But should work with templates. 


THE SPINE - testing and ci
==========================
Ultimate Goal: given the design document, and the step-by-step series of tests,
be able to have AntiGravity (or comparable) build the compiler in any language (though, defmacro support might be a reach for non-Lisps)

Issues and Shortcomings
-----------------------
- [x] "negative tests".  The error files still not split out along the spine.
- - [ ] exactly one failure per file seems suboptimal. unpleasant.
- - [x] it'd be nice to declare the expected error right with the test.  Sort of like llvm-lit.  
- - [ ] llvm-lit does warnings as well as errors.   a bit brittle though.

- [ ] flags. no way to capture WHEN any particular flag should be developed.
- - [ ] no way to declare their usage in the spec test.
- [ ] unit tests. Unit tests need to be broken up across the spine too.

What other things are not properly captured in the spine?

Better Spine Testing - Three Proposals
--------------------------------------
Filename based.

XXXX.unit.lisp    <-- a parachute unit test. Can do anything. Very flexible.
XXXX.expected.xx  <-- (xx is .ll  .meta  .spv .spt .ptx .cpp).  Expectation artifact.
                       There are /tests/validators/validate-xx.lisp   for each
                       type that decide how to validate.
XXXX-l0.cpp       <-- gets compiled and run after kernel.  returns 0 for succes.
                      -ocl -l0 -cuda.
                      maybe also -bmg  -gpu -cpu  . Not sure.

XXXX.perf         <-- performance boundaries?  

Errors are handled like they are now. ;; CHECK-FAIL: "<err-msg>"

Warnings like errors.  ;; CHECK-WARN "<msg>"

Comments at header can also include other expectations:
      ;; FAIL-WITH[--single-pass]: "<error message>"
      ;; PASS-WITH[target=spv]

PASS-WITH also triggers custom test passes for that test.
      ;; PASS-ONLY-WITH[--allow-redefinition]
      ;; TEST-WITH[--metadata]    <--  the --metadata is not normally run with EVERY test. 


;; test.crisp
;; TEST-EXPECT: PASS                           ← Default outcome
;; FAIL-WITH[--single-pass]: "error message"   ← Expected failure
;; PASS-WITH[target=spirv]                     ← Conditional success
;; PASS-ONLY-WITH[--allow-redefinition]        ← Requires flag
;; TEST-WITH[--metadata]                       ← Run additional test pass 
;; TEST-WITH[--force-math-precision=fast] : validate_smoke_fast.lisp   ← custom script --load
;; TEST-WITH[--math-precision=ieee]  : #'validate-ieee                 ← standard function provided by test runner.
;; CHECK-WARN: "warning text"                  ← Inline warning check

Architecture
============

more pass driven? We could isolate the "expansion and desugar" phase from the "create semantic AST nodes" phase from the analysis from the codegen. In theory each one could have an input sink and an output sink and be its own standalone application.

And, of course, there would be strict input/output formats at each stage. Which could also mean testing at each stage.  The isolation would allow AntiGravity to focus on just one stage and not need to absorb the whole codebase.

But, on the other hand, most features are "cross cutting" and wishing otherwise doesn't change that.  If a new feature is added (like def-record) it has to be added to every pass.  

However, even if we do NOT rearchitect in this fashion, we could have a --sanity flag that makes each pass output some sort of s-expression (or LLVM-IR) out.

Not sure how difficult that would be. 







- [ ] SEO (even the _AIs_ can't find us, completely unsearchable today)
- - [ ] logo
- - [x] add google site verification  
- - [ ] should now be discoverable at : https://cperkinscperkins.github.io/crisp/
- - [ ] check at https://search.google.com/search-console?resource_id=https%3A%2F%2Fcperkinscperkins.github.io%2Fcrisp%2F

- [ ] Testing Next Stages
- - [x] Rove or _Parachute_ for tests. Integrated with our GHA
- - [ ] Prepare Intel OpenCL CPU Runtime to test kernels
- - [ ] POCL (portable OpenCL) ??
- - [ ] buy PC w/ GPU and hook up as Self Hosted runner. 
- [ ] Get logging under control
- - [x] Log4CL.  Probably the best choice. Mostly "compiles away".   There is also Verbose

- [ ] proper bug tracker?
- - [ ] GitHub Issues?  

- [ ] Investigate Google Antigravity: https://antigravity.google   <-- serious IDE
- [ ] Investigate Google AI Studio: https://aistudio.google.com    <-- in-browser prototyping and "prompt engineering"




