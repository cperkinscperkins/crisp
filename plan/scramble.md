
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
- [x] compile
- [x] test? golden string or using ORC?
- [x] Make a new "in-progress" doc and check "[ ] minimal def-function" ?

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
- [x] Level Zero Backend C++ Generation
- [x] CUDA Backend

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
- [x] def-grid-function
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
- [x] vectors
- [x] def-struct
- [x] cond  ( we can make all other divergent control flows from that: when, if, unless)
- [ ] bool true false.  ( macros can still use T/nil ? )
- [ ] precision selections (declare / declaim / flags )
- [x] .crisp files.  basic flag for crisp-compiler.exe
- [x] SIDE CHANNEL MECHANISM.  probably sooner, rather than later. 
- [x] Literals: use suffix ?   0.0f  INSTEAD of (type a float) in a let clause?


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
- - [/] anaphoric support
- - [ ] star `*` variants - uniform across warp
- - [x] plus `+` variants - compile time calculable
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
- [x] damn literal numbers are long overdue.  1.0f 1i 2l  something.
- - [ ] also, give up on "no (to-int )" already. geebus
- [ ] DENY setf and aref.  
- [ ] &out has no verification that the argument is NOT READ FROM.
- [x] fix STYLE-WARNINGS. Too many unused vars.
- [x] Refactor:
   x valid-parameterized-type-p   in types/validation.lisp
   x register-function-signature in environment.lisp
   - compile-def-function in analysis/core.lisp. triple nested let?

- [x] WTF: mark-carriers-pass in core.lisp has *reverse-call-graph* which does not exist.
- [/] unit tests aren't picking up overlay?  Fix that. (I think this is not true)
- [ ] make-implicit-XXXX with :msg and :name
- [ ] make-scratch-cell should use make-implicit-cell  => tests for :name / :msg in the metadata
- [ ] move validators all to one file (or some files). And change compilation
      so that the compiler doesn't load them. Only the spec runner?
- [ ] .metacrisp review.  :name, maybe others.
- [x] new test ( tests\spec\010-def-record\17-record-compare-struct.crisp ) needs validation and kernel?
- [x] we aren't testing explosion of def-record, etc.  The metadata support will give us that opportutnity.
     otherwise, need to either --ir-target=llvm-ir or something more complicated for the validators
- [x] review the validators in the 028-metadata directory.  I have a feeling they are only cursory. (probably just listp or something)
- [x] Storage Handles. Or at least a proper cell. In theory, this could be the first 'crisp-in-crisp' construct.
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
- - [x] Tensor Properties ( can be set)
- - - [x] length~ ( number of elements)
- - - [x] parent~
- - - [x] alignment~ <-- compile time.
- - - [x] offset~
- - - [x] num-dims~   <-- compile time. 
- - - [x] strides~
- - - [x] extents~
- - - [x] element-type~
- - [x] Pass Through
- - - (access~ someCellOrTensor)
- - - (address-space~ someCellOrTensor)
- - [x] built atop def-record 
- [x] def-kernel-exact 
- [x] def-kernel  <-- 
- [ ] expand variadics (+, * etc).  Maybe up to 5 or 7?  (+ a b c d e)
- [x] def-function has strict return type checking. Meaning, if it declares nil as return type,
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
- - [x] llvm-ir
- - [x] spirv
- - [x] ptx?
- [ ] --binary-gpu-target
- [x] test on BMG
- [x] metadata
- [x] hoisting
- [x] .cpp gen
- [x] add overlay to spec runner. 
- [x] how to run on CI
- [x] .cpp gen using buffer 16 always. not sized correctly?
- [x] .cpp gen errrors: incompatible flags
- - [ ] flags will need to be recorded in metadata
- [x] .cpp gen temp files ? (ie .metacrisp) Given In Memory Compilation API, I'd actually like to avoid temp files as much as possible.
- [x] clean up files during hoist validation.
- [x] shorten names?
- [x] use log4cl in spec runner.
- [x] bundle libLLVM.dll shared library
- [x] build_all.lisp
- [x] try using llvm-mingw which is smaller than LLVM and works on windows
- [ ] oneAPI docker image for oneapi-gdb to test our DWARF gen.
- [x] double check debug symbols get passed throught to ptx
- [ ] at some point, get opencl:cpu device on CI.
- - [ ] this would mean an opencl hoister, no?
- [x] consider having regression failures name the folder as well as the test.
- [x] map out global vars. 
- [x] bugs 021 important
- [x] move tools somewhere and make them part of "release". Will need to scrub LFS entries.
- [x] refactor single pass vs. multi.  We are getting too much duplication
      constant source of bugs. At minimum, do an evaluation. 
- [x] re-examine def-rec-vec. Maybe just general "rec-vec" type? No need to be defining new types
      became fixed array, only usable in structs and records. no "def-"
- [x] def-derived-type => expand specification for numerics ("contagion"). 
- [/] def-record : probably should decide and document that these CANNOT appear on the 
      kernel boundary. Obviously, we do for Storage Handles. But no general case marshalling.
      If a user WANTS to pass them individually and use marshall-XXXX they are welcome to do so.
      They CAN and ARE supported at kernel boundary.
- [x] set-derived: probably should take TWO structs as args. Disallow "derived" structs.
      Should it support def-record? Probably not. 

Assault On Pytorch
==================
- [x] def-derived-type 
- - [x] validators in 031-def-derived-test not written yet.
- - [x] clean up of .ll and .metacrisp files 
- - [x] tests\spec\031-def-derived-type\errors\13-illegal-enum-collision.crisp
        is PASSING, but probably should not. 
- - [x] tests\spec\031-def-derived-type\errors\07-ancestor-not-subst-for-descendant.crisp
        is PASSING, but definitely should not.
- - [x] errors\09- and 10- are FAIL (which they should) but arguably
        the message could be better, especially for 10-
- - [x] what does (def-derived-type A B) with NO :subst key become?
        It should BE a Compile Error!  
        Decide Document TEST and Implement  test is 15-
- - [x] test 19-duplicate-type.crisp is PASSing but should FAIL.

- - [x] changed it so that validators can run with --use-binary.  
        but the exact mechanism is unclear.
- - [x] run-specs.lisp - custom build is broken.  Using --use-binary now?
        can this be fixed? Or should we abandon the custom build?

- - [ ] 031-def-derived-test/errors/05-equal-does-not-mena-yes is PASSING, but it should be failing.
        See comment in test. May not be easy to implement.
- - [x] most error tests in 031-def-derived-test/errors do not have "<meaningful error messages>" yet.
        possibly because we aren't generating such.
- - [x] def-derived-type should probably NOT support enums.  add test
- - [x] error on existing types. error on existing derived types.
- - [ ] def-derived-type design doc says no templating. Test? Might have to change that limitation though.  ( branded types CAN be templated )
- - [ ] bool?  
- - [x] OVERLAY for spec-runner.  HANDLE!!!
- [x] set-derived  
- [x] brand -- 
- - [x] requires documentation and decisions before work can begin.
- [x] --differentiate
- - [x] brand cell
- - [x] ANF transform.
- - [x] generate shadow signatures
- - [x] wengert list
- - [x] kernel and function transforms
- - [x] A/D

- [x] --lax was added, but probably ;; SKIP-WITH[--differentiate] would have been better. Makes no sense to have two systems.
      remove --lax.

- [x] --differentiate and --ir-target=spv outputs the SAME .spv path as when not using differentiate. Should be named _grad.
- [x] --differentiate should not work with --hoist.  Error or skip hoist.
- [x] branded types. expand syntax to capture "always" vs. "when differentiating"
- [x] --differentiate flag and testing. square cell could be simple test
- [ ] math intermediaries - this also strongly pushes to more explicit passes and testing. expand user macros / desugar Crisp macros / nodes / analyze / compile ?

- [ ] more testing: sub-functions (both with return values and &out params)

TECHNICAL DEBT AND OVERSIGHTS
============================
- [x] def-record SHOULD be supportable at kernel boundary. We already do it for cell, might 
      as well general case that.
- - records on kernel boundary cannot be in &out positon.  
    Technically, threads CAN change record values as the record is passed down the call stack,
    but those changes are NOT shared with other threads OR communicated back to the host.
    Not sure what is the name for those semantics. "read only" ?? 
- - [x] &out some_rec is compilation ERROR. <-- EXCEPT STORAGE HANDLES (cell, vector, matrix, tensor)
- - [x] metadata decision & test
- - - [x] records support branding. including :enforce :always
- - - A: but that will be elided. No issue.
- - [x] hoisting decision & test

- [x] def-record at kernel boundary and --differentiate:  NEED AUTODIFF SUPPORT

- [x] we have tests with ;; HOIST-EXPECT: BUFFER c: <something>  that SHOULD fail, but don't
      they output a FAIL, but don't trip
- [x] --metadata and --differentiate.  These SHOULD work together (unlike --hoist).


- [x] auto-diff only works with FLAT kernels. Chooose between
- - [/] documenting that limitation
- - [x] extending auto-diff down through call chain. This isn't impossible, but it is a
        bit tricky. We are collecting A_grad, B_grad as they contribute to C.
- - [ ] def-function with &out param <-- NOT correctly handled for "sub-function differentiation" at this
        time.  We assume def-function returns value and differentiate off that.  
        

- [x] what happens to cell in metadata if --metadata combined with --differentiate ?
- - is that allowed? We do NOT allow with --hoist.   However, it should work fine.  
    The branding is elided.
- [x] what happens to struct with branding when IT appears in metacrisp?
- - Answer: the branding does NOT appear in the metadata. It is elided.

- [x] def-struct can ALSO be at the kernel boundary. (If it's less than 4K?)
- -   the struct is READ-ONLY <-- another damn thing.
- -   the READ-ONLY thing means we need to walk struct params "up" the call
      stack to see if they originate at the kernel param boundary or not. 
      We need to be able to do this for other vars as well, to determine if they 
      are uniform or not.  So maybe for any function param (originates-at-kernel-boundary? v)
      is needed?
- - [x] we need tests for both mutation of def-record at kernel boundary
        and immutability of def-struct at kernel boundary
- - [x] update docs too.

- [ ] Auto-Diff and structs as direct kernel params.
;; the most likely future scenario is that auto-diff will NEVER support structs that appear
;; on the kernel boundary. Maybe they could be welcome in forward kernels, but if they actually
;; contribute to the calculation of any &out forward param, then we should probably just error
;; if someone tries to differentiate.  
;;  NOTE: while technically if the struct is bound in a Storage Handle (like cell) then we COULD
;;        take its gradient, that complicates things a lot. Probably just limit A|D to 
;;        scalars. 
;; ALSO NOTE: we DO support differentiation of records. This is because they are SROA flatted
;;            at the kernel boundary, so the auto-diff is just an extension of that. It doesn't
;;            even know those scalar args 'were together'. 

- [ ] scratch cells as OPTIONAL/KEY args.  TEST 
- [ ] r-t-assert and --runtime-checks NEED TESTING  
- [ ] 009-def-struct/04-def-struct-mixed-types.crisp needs a validator!! (or to become a unit test?)   
- [ ] for errors involving the return type, make sure the error message
      very clearly states what return type the compiler thinks it is (if any).
- [ ] audit errors: some are NOT showing the location.
- [ ] ;; FAIL-WITH[--differentiate]: "message!"  <-- message isn't getting checked for "normal" tests.
- [ ] 02-kernel-illegal-voidp and friends. no CHECK-FAIL header.   Other negative tests same
- [ ] Visual Code to use "lisp" syntax highlighting with .crisp files?
- [x] script to generate Table of Contents for docs?  It's woefully out of date.
- [x] do the docs on "declare" include "forward-only" ? (YES)
- [x] refactor. warnings when compiling, running tests. (string-downcase (symbol-name ...)) if over let, etc.
- [ ] LLVM-IR can only bitcast same size. So (as-ulong 12345) is a problem. (to-ulong 12345) works.
      Should revisit docs and decide how to handle this.
- [x] literals overlooked double and char (d / c) 
- [x] switch spec runner to default to `--log-level=off` ... but CI should still using something...

- [x] device vectors ( float4, int2, etc).  Time to support them.  (054: type registration, ##() construction, basic param/return types)
- - [x] support at kernel boundary 
- - [x] make sure hoisting works
- - [x] even if we don't do all swizzles, need some sort of access to elements, for set! too
        maybe just x~, y~, z~ and w~.  
        or (~ v <index>)

- [x] AutoDiff fix: Redesign so gradient storage handles are always  floating point regardless of primal type, and generate zero backward kernels for integer inputs. This is the "mathematically correct" approach but requires more work.
- - [x] Would allow re-enable of tests in 083 and other places that skip --differentiate pass for this reason

- [ ] crisp-compile.exe as a release?

Miscelleny
==========
- [x] multi-file support
- [ ] TEST-FILES[ 01-basic.crisp 11-app.crisp]  
- [ ] ieee / fast accuracy support
- [ ] is-uniform? and if*/when* variants
- [x] what is going on with validation.lisp? why does everything need cl:cond ?
      same with autodiff.lisp  . FIX 
- [ ] i64 and ui64 as types and literals!!
- [ ] also i128 and friends! 
- [ ] some "strategy" work can result in `reqd_work_group_size` LLVM IR.  Support
- [ ] atomic-binop! deferred. Needs dotimes+
- [ ] compilation error when trying to mutate `offset` or `stride` in a `:compact` aligned storage handle.
      or `stride` in `:compact-offset`
      and everything OK in `:stride` alignment. 
      `extent` ?? <== needs documentation if not always mutable.
- [ ] src/stdlib/matrix.crisp  -- Time to start thinking about a "standard library" of Crisp support
      and what it wouuld take to enable it in the compiler. 
      In the meantime, just note which functions might be good candidates.
- [ ] DAMN - Need soa-matrix and soa-tensor N.  But it's not so bad. If struct was {int, float}, now we have {tensor<int>, tensor<float>}

Standard Library Candidates
===========================
- transpose / transpose!


Tensors Vectors and Matrices
============================
- [x] (array T N)
- - [x] rename and update docs
- - [x] can ONLY be a member of def-record? like brand?
- - [x] test and support
- - [x] HOIST tests
- [ ] tensors and vectors and matrices
- - [x] initial tests based off cell
- - [x] introduce vector and matrix
- - [x] tensors at kernel boundary
- - - [x] marshall-tensor N    (macro or template or something else?)
- - [ ] is :align :strided / :compact being handled correctly? Unit test
- - [x] hoisting
- - [x] OPTIMIZATION: vector can compile-time optimize ~ to NOT use stride and dispatch simply based
      off :align :compact. This would ignore stride. But when :align :strided OR when the type is
      incomplete and no alignment provided, we'd have to use the stride. 
- - [ ] test offsets, strides really SET by hoisting code (instead of always jsut 0). for both align
        would we need some sort of .cpp fixture?
- - [x] scratch tensors / matrix / vector
- - [ ] scratch tensor sizeExpression - but we need strategy etc support first.  <==== (!!!!)
- - [ ] CUDA support for :local ( need cu hoist)
- - [x] "view" manipulation - changing offset, make-xxxx etc
- - [ ] double check branding
- - [x] differentiate support!!
- - - [x] atomic-add! deferred. Need to add atomics and ensure differntiation is updated
- - - [x] sub-function tensor AD deferred
- - - [x] non-float tensors. Limitation. We have good readable compilation error?
- - [x] vector helpers
- - [x] matrix helpers
- - [ ] tile?
- - [ ] no-sroa ?
- [x] :contiguous-term  As a compile-time property of tensor? <-- would require some refactor
                   Is optional. Defaults to :last 
   Matrix: 
   :contiguous-term :first  <-- col major matrix.  
   :contiguous-term :last  <-- row major matrix.  
   ALSO
   :contiguous-term :row-major / :col-major 


   ALSO  contiguous-term~  function
   
   REXAMINE make-scratch-matrix 






Preperatory
===========
- [x] get-global-id or whatever and friends. 
- [x] remove "+warp-size+" from design doc. Use (get-warp-size)
      it MIGHT be compile-time constant replaced, if compiling for known target.
- [ ] strategy
- - [ ] DEFER :interleaved  .. until we tackle def-orchestration.
- - [ ] FOLLOW UP: check-thread-bounds check-wg-bounds
- - [x] document :num-groups in ref.metacrisp
- - [ ] some strategy choices can result in `reqd_work_group_size` being in LLVM-IR
- - [ ] Check single-task!  It should be a strategy, no?  Strategy helps set the relationship to some input data.  I think the original (declare single-task) might be better.
- [x] REVISIT 085.  We are apparently STILL refusing kernels with long/int input args or whatever.
      Look at 092, 089, possibly others that seem like they should be differentiable, but are being
      refused. 
- - [x] improve errors: should have "kernel does not have input params: cannot differentiate"
                 and   "no &out params, cannot differentiate"
- [x] revisit incomplete types. Too many defaults in Storage Handles.  Might be difficult.
- [x] drop :access.  It has zero bearing on any of the kernel code that is generated.
      It only effects the hoisting code. If needed we can do something like :requires-write in the metadata, 
      determined FROM usage.  But, honestly, I don't even think we need that.
- [x] ensure (def-type some-t <COMPLETE-TYPE>) ... #'(some-t some-t) works
      and    (def-type other-t <INCOMPLETE-TYPE>) ... #'((other-t :missing :val)  other-t) also works
      DECIDE how to handle :contiguous-term . :contiguous-term :undecided ??
      DECIDE how to handle :c-t props with defaults.
      for Storage Handles, all def-struct, def-record 
- [ ] scan design doc for :size :length :extent  , are we doing to actually use that :c-t with vectors or not?
- [ ] look at make-scratch-XXXX  definitions in doc and as realized. Are they in sync? Do any need :contiguous-term ?
- [x] should the branded storage handles be :subst :descendant or :ancestor?  I think it got 
changed to :descendant to make the tests pass at some point. Or not. Check though.
- - according to Gemini, we aren't actually using the branding for provenance, and instead the ANF-transform is enough. The branding could be dropped!
- [x] auto-diff needs "on metal" testing. add new directives etc.
- [ ] double check with Claude that the "volatile" hack we use to get around bug 030
      only affects the differentiating kernels. If it affects the forward kernels ... oof.
      Also, see if it's sequested to --ir-target=spv only. NVidia doesn't have the same bug
      so when --ir-target is .ptx we don't need the "volatile" workaround. Check to make sure.

- [ ] 031 address
- [ ] literal "true" (and "nil" / "false"?) and bool type. avoid "t" or "T".

Grid vs Thread Context
=======================
- [x] def-grid-function / dispatch/grid/thread context checking.
- [ ] gen-XXXX promotion to kernel

Grid Stride
===========
- [x] loop-vector-stride
- [x] tensor-stride
- [x] grid-stride
- [x] tile-stride
- [x] hardware-stride
- [x] A|D of all above
- [x] load-tile / store-tile
- - [ ] update docs: synchronous load-tile / store-tile FASTER than async for very small tiles.
- - [x] async variations of same
- - [x] probably have to revisit async API. Sorry. No transform or identity (see strategy below)
- [ ] convert-layout (in Crisp)
- [ ] :strategy :tiled and :tile-shape declarations. 
- - [ ] metadata
- - [ ] hoisting
- - [ ] when hoisting we need to make sure the total tensor size is an even multiple of the tile. "oversubscribe" it and ideally fill with an identity value, which maybe we should have the :strategy ddeclare.
- - [ ] with --runtime-checks we should validate that tensor IS an even multiple of tile.
- - [ ] update documentation with this "oversubscribe and assert" behavior.
- [x] workgroup-stride


NEXT
====
- [x] rename load-tile-coords => load-tile-at
- [x] lose request-load-tile and all request-xxxx variants. 
- - [x] Instead make-barrier and :barrier key
- - [x] lose (await-request <req>) .  Now just (await <barrier>)
- [x] load-tile/store-tile API from topology.md.   
- [x] lose "helper" load-tile / store-tile
- [ ] (await barrier) maps to cp.async.wait_all , not individual barriers.
- [ ] strategy :tiled so we can get hoist testing. 
- [ ] rename local-barrier => sync-workgroup
- [ ] sync-warp
- [ ] make-arrival-sync
- [ ] update ideal_001.md
- [ ] revisit request-load-local in ideal_001.md.  Do we need a new variant? Or delete?
- [ ] matrix-mult-stride ?  if we do this do we need mma-accumulate-via-tile / load-fragment etc.
- [ ] we need position-tile-grid and position-tile-ad to adjust a tile view "into" a space.

--runtime-checks
================
- [ ] --debug-logging ? 
- [ ] Audit routines implemented so far. Which should have --runtime-checks support?
- [ ] test


Looping Constructs
==================
- [ ] dotimes 
- - [ ]  dotimes+ / dotimes*
- [ ] dec-times / dec-times+ / dec-times*
- [ ] do-times-by-doubling
- [ ] &c.

Precision: ieee vs fast vs ieee-ftz
===================================
- [ ] `(with-precision (<KEY>) ...)`
- [ ]  `(declaim (precision <KEY>))`
- [ ] `--math-precision`
- [ ] `--force-math-precision`
- [/] `--denormal-handling [ieee | flush]`
- [x] CHange to precision: ieee | fast | ieee-ftz

Reductions
==========
- [ ] revisit Phase 1 vs Phase 2.
- [ ] need to compose correctly
- [ ] out of core.  ( def-orchestration ? )

Async Ops \ Named Barriers \ Rings
===================================
- [ ] def-topology
- [ ] def-orchestration
- [ ] primitives
- [ ] TESTING?  
- [ ] rings
- [ ] warp specializations
- [ ] out of core orchestration 


FFI / C API / "tree shaking" / recompile
========================================




Technical Debt
==============
- [x] MkDocs
- - [x] markup ideal_001.md with what is Implemented, or partially implemented. (could be Emoji or CSS)
- - [x] MkDocs produces TOC on side, with Implemtened.
- - [x] retire realized_001.md
- - [x] remove outdated "TOC" section from ideal_001.md
- - [x] audit emojis - some are right, but not all...  (✅ Completed, ⚠️ Partially Implemented, 📝 Planned).
- [x] refactor overly long functions
- [x] refactor build - Warning unused var.
- [x] refactor build - reverse dependency order for most .lisp. ( warning undefined function)
- other refactoring?
- [ ] review previous "technical debt"
- [x] 089 :derive-from support looks incomplete. It should support TENSORS and result
      in the number of threads for size of the tensor. BUT if :strided then calc max number of thread
      available for the hardware, and use that (if less than the size of the tensor).
- [ ] double check the :derive-from / :strided with tensors of any arity. 
- [x] also new kernel in sum-reduce-tree.crisp crashes compiler when --ir-target=spv. Works ptx though.
- [x] run-on-pod.sh / bench-on-pod.sh always reinstall SBCL. 
- [x] --device-only flag for SYCL to get kernel only timing?
- [x] update docs with &out "input" read-only vs "output" requirement (in flux)
- [x] drop oneDPL and use SYCL built-in reductions instead for benchmark
- [x] occupancy.
- [/] rename --binary-gpu-target flag and expand docs 
- [ ] consider renaming `local-barrier` to `workgroup-sync` ?

PERFORMANCE TESTING
===================
- setup RunPod AI .  ( guess we should write the CUDA hoist app too then).
ssh root@213.173.108.8 -p 10435 -i ~/.ssh/id_ed25519  
scp ~/Documents/crisp-man/tests/spec/113-async-load-tile-store-tile/01-request-load-tile-coords-1d.ptx root@213.173.108.8
scp C:\Users\cperk\Documents\crisp-man\tests\spec\113-async-load-tile-store-tile\01-request-load-tile-coords-1d.ptx root@213.173.108.8
scp C:\Users\cperk\Documents\crisp-man\scripts\verify-ptx-113-01.py root@213.173.108.8

- [/] leverage RunPod as a GitHub Actions target.  Maybe only for the hoisting tests? Separate .yml likely.
- choose some "realizable" algorithms and get them for a series of platforms
 - CUTLASS
 - Cuda
 - SYCL (OneAPI, not SYCLOS)
 - SYCL-TLA
 - Crisp
- Nvidia compare: CUTLASS | Cuda | Crisp
- Intel compare: SYCL-TLA | SYCL | Crisp
- Algorithms
- - [ ] SAXPY
- - [ ] Tiled GEMM
- - [x] Add / Sum Reduction
- More Algorithms
- - Bitonic Sort
- - Radix Sort ( but might be best with PGAS ?)

- [x] CUDA_CHECK is in Crisp .cu harness, but not CUDA or CUB. Wall time impact?
- [x] compile time comparison maybe not fair. crisp compile is device only. others are device + host.  Break out?
- [x] crisp_tree optimizes occupancy, but CUDA and CUB do not. Seems unfair.
- [x] drop atomic-heavy crisp test, just use crisp_tree. Rename?
- [x] improve? loop pattern — done 2026-05-29/30. All 6 stride macros (loop-vector-stride / tensor-stride / grid-stride / hardware-stride :warp-idx / workgroup-stride / tile-stride+hw :workgroup-idx) rewritten to use exact-iter-count + single-counter dotimes with unconditional body. Shared helper `%build-exact-iter-count-form` in overlay. Loop-vector-stride alone gave ~50% kernel-time win on the reduction bench; transfer to the other macros assumed (PTX shape verified for each, but no perf measurement yet). 732/732 default + 732/732 --differentiate.

- [x] !invariant.load metadata for read-only tensor params — next biggest, still tractable.

The change is in src/codegen.lisp wherever we emit load instructions for tensor element accesses. Add a check: "is this tensor parameter never written (no set! reaching it)?" If yes, attach !invariant.load metadata to the LLVM load instruction. The NVPTX backend recognizes this and emits ld.global.nc.f32 (texture cache path) instead of ld.global.b32 (L1 path).

Done 2026-05-29. Inference rule: when the kernel's declared signature has `&out`, every tensor param before `&out` (positional / `&optional` / `&key`) is read-only and its `(~ T i)` loads get `!invariant.load !{}` → PTX `ld.global.nc.b32`. Lookup is via `*kernel-declared-signatures*` (the pre-flatten signature retains `&out`). Limitations: direct refs only — let-bound aliases lose the marking (no miscompile, just slower); kernels with no `&out` get nothing. Reduction-bench perf delta was in the noise — this kernel has no data reuse, so the texture-cache path is a wash. Expected to matter on GEMM B-tile broadcast / stencils.

- [x] compile-time known scratch/local mem opt.

These initial "first generation" algorithms might not be expressible on CUTLASS/SYCL-TLA

Other Platforms: OpenCL. Huawei.  Triton? Mojo?


PGAS / SHMem, UALink, and Asyc Operations
=========================================
- [x] Update Design Doc
- - PGAS has three levels: Complete Compile Time Topology, Compile Time Shape and Runtime Extent, Runtime Topology
- - :address-space :pgas   is new address space.
- - may have to subclass Storage Handles so type system can do enforcement. Not sure.
- - For Complete Compile Time Topology, almost all access stays the same because the compiler
     can detect local vs. "remote" PE ops and lower accordingly. 
- - For Mix Topology, we need to insert (if PE-is-local <store> <put>) and possible barrierrs.
- - for runtime only, the user will need to mostly use <put> operations, barriers, etc.
- [x] Async
 - - right now our async operations focus on local=>global and global=>local  "requests"
 - - with tokens and (await someToken &optinal otherTokens...)
 - - But we might need to expand that to PGAS/SHMem.  Maybe rename?
 - [x] pipelining macros for advanced async
 - - the N-fold symmetry of PGAS can benefit from pipelining 2, 3, 4+ async operations
     provide some defmacro for this and show users how to set up their own. Makes the whole
     shebang MUCH simpler (and safer).


QUESTIONS
- [x] should log4CL be used ONLY for logging? Or should it be used for general compiler output 
      like error messages and warnings and the like?
- [ ] why are the log:debug and the like not showing up in Alive REPL even if the log level is set?

- [ ] commutative-op-type instead of binop-type requirement for reductions? Would require users
      to define a type constraint for their own functions.  Annoying or useful?

LANGUAGE CHANGES
- [ ] PGAS / SHMEM!!
- [ ] rework Quantized and Microfloats. 
- [x] lose declare local/global. Too complex
- [x] instead use (make-single-result T :global) . Might want to consider renaming 'single-result'
- [x] How to initialize the single-result? It has to be done by hoisting code for :global.
      And cannot be done for :local. So maybe the user just has to (set! ) or (atomic-xchg! ) it 
      themselves.
- [x] Shore up set! and atomic-ops
- - (atomic-inc! someVar)                 <--
- - (atomic-inc! someTensor (x y z ...))
- - (atomic-inc! someCell)           
- - atomic-set! would just be atomic-xchg!  .  
- - (atomic-set! someCell val)   
- - (atomic-set! someTensor (x y z ...) val)
- - (atomic-set! someVar val)  
- - (set! someVar someVal)
- - (set! (~ someTensor x y z)  val) 
- - (set! (~ someCell) val)  <--  cell doesn't need '0'  


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
- - [x] llvm-lit does warnings as well as errors.   a bit brittle though.

- [x] flags. no way to capture WHEN any particular flag should be developed.
- - [x] no way to declare their usage in the spec test.
- [x] unit tests. Unit tests need to be broken up across the spine too.

What other things are not properly captured in the spine?

Better Spine Testing - Three Proposals
--------------------------------------
Filename based.

[x] XXXX.unit.lisp    <-- a parachute unit test. Can do anything. Very flexible.
[ ] XXXX.expected.xx  <-- (xx is .ll  .meta  .spv .spt .ptx .cpp).  Expectation artifact.
                       There are /tests/validators/validate-xx.lisp   for each
                       type that decide how to validate.
[ ] XXXX-l0.cpp       <-- gets compiled and run after kernel.  returns 0 for succes.
                      -ocl -l0 -cuda.
                      maybe also -bmg  -gpu -cpu  . Not sure.

[ ]XXXX.perf         <-- performance boundaries?  

Errors are handled like they are now. ;; CHECK-FAIL: "<err-msg>"

Warnings like errors.  ;; CHECK-WARN "<msg>"

Comments at header can also include other expectations:
      ;; FAIL-WITH[--single-pass]: "<error message>"
      ;; PASS-WITH[target=spv]

PASS-WITH also triggers custom test passes for that test.
      ;; PASS-ONLY-WITH[--allow-redefinition]
      ;; TEST-WITH[--metadata]    <--  the --metadata is not normally run with EVERY test. 


;; test.crisp
[x];; TEST-EXPECT: PASS                           ← Default outcome
[x];; FAIL-WITH[--single-pass]: "error message"   ← Expected failure
[ ];; PASS-ONLY-WITH[--allow-redefinition]        ← Requires flag
[x];; TEST-WITH[--metadata]                       ← Run additional test pass 
[ ];; TEST-WITH[--force-math-precision=fast] : validate_smoke_fast.lisp   ← custom script --load
[ ];; TEST-WITH[--math-precision=ieee]  : #'validate-ieee                 ← standard function provided by test runner.
[ ];; CHECK-WARN: "warning text"                  ← Inline warning check
[ ];; CHECK-FAIL: "failure message" 
[x];; TEST-HOIST[L0]: validate-l0-compile-only

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
- [x] Get logging under control
- - [x] Log4CL.  Probably the best choice. Mostly "compiles away".   There is also Verbose

- [ ] proper bug tracker?
- - [ ] GitHub Issues?  

- [ ] Investigate Google Antigravity: https://antigravity.google   <-- serious IDE
- [ ] Investigate Google AI Studio: https://aistudio.google.com    <-- in-browser prototyping and "prompt engineering"

Milestones
==========
- **2026-01-03**: Compiled first `.spv` from Crisp and successfully ran it with a bespoke OpenCL script. Massive milestone.
- **2026-01-22**: Crisp toolset can now generate (hoist) `.cpp` files for those kernels, and the testing system runs them on actual GPU iron via Level Zero.
- **2026-04-29** `loop-vector-stride` joins the toolkit, along with def-grid-function, strategy declarations, tensors/vectors/matrices, and more. With this Crisp can now be used FOR REAL to write
reductions, matrix multiply, stencil operations, convolutions and more. 
- **2026-05-27**: CUDA hoisting, runpod.io e2e testing AND performance comparisons. Crisp is fastest to compile, by far (order of magnitude).  While not yet fastest, it is breathing down the neck of CUDA and CUB.





