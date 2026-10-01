# To Do

- implementation notes for each, esp vector and def-const-vec, def-function, def-kernel
- [x] is our "hoist" code going to include reading the compiled kernel from disk? Seems like it should.
- [x] multiple kernel invocation
- [x] multiple kernels in a single .crisp file.  what does that mean for binary reading and hoist code and compilation?
- [x] tension between vector-type declarations with and without length.  Possible solutions: (user-vector-t-wo-length 20)  or (add-length #'user-vector-t-wo-length 20) ? 
     The "twist" of using the type in the function position is very Clojure, but, honestly, too much of it makes things confusing. 
- [x] SBCL vs C++ ?
- [x] type "narrowing" suggested in with-template-type examples.
- [x] dependent types ( we've introduced them somewhat with tensor-type which takes both a number (dims) and a whole other type)
- [x] maybe type.  on-error-continue   <-- not sure we need on-error-continue.  (or-else <someexpr> <proxy-expr>) should work everywhere, right?
- [x] string formatting? ->  NO.  Just output things with spaces between. Default. 
+ [x] "side channel" implementation notes
- 'safe' types : numeric with overflow notifications/strategies. vector with boundary notifications. User elected? Automatic? I like compiler flag (or possibly `proclaim` )
- [x] lambda and types => DECISION: lambdas and labels are NOT supported
- index of Common Lisp/Scheme things we WILL be taking. defmacro, inc! 
- consider abbreviations: -type => -t    vector => vec  function => func , workgroup => wg
- [x] nd-vector-view and image-view for 2D and 3D ( and ND?) traversal.  convolution  .  image means multi-channel pixel. Defer image.
+ [ ] vector functions: copy, fill, iota. 
+ [ ] tensor functions: transpose , is-abelian? .gather() / .contiguous() 
                    "transpose" operation can often be done without moving any data. Just change the strides of the tensor.
      tensors handle most slicing/shaping needs.  also "broadcasting" which is setting one of the strides to 0. So the "next row" calculation goes nowhere. It's a simple way of taking a [1 2 3 ] and making into [[1 2 3] [1 2 3] [1 2 3]...]
- [ ] is-symmetric?  symmetric tensors only need to store upper triangle ( which may be more than half ).  How to map that to/from a linear vector? 
    would it have to be immutable?    Might need custom  `aref`/`.` than knows how to "mirror" indeces.  
- [ ] make-identity/is-identity   <-- square matrix with 0 everywhere but 1 on diagonal.  Once again, a fle
- [x]ROW MAJOR / COL MAJOR - should we borrow?
- [x] 1D tensor needs to pun for a vector.  Can our sub-type system handle or does it need special support?

- [ ] rename def-const-vec to def-compile-const-vec OR def-device-const-vec  to further separate it from other "def-" things.
- [ ] TILES? No.  SAMPLER? Yes, but not advised.
- [ ] declare "side-effect-free" or maybe "function" or "procedure" ?
- [ ] Matrix Operations: (matmul A B) (transpose A)    
    [ ] (m*v M v) - convenience function for matrix-vector multiplication. Very common special case of matmul
    [ ]  (make-identity-matrix N) -- square.    (make-zero-matrix rows cols)
    [ ]  (determinant A)   (inverse A)  -- slightly advanced. but common
- [ ] sparse tensors / sparse matrix  : OUT OF SCOPE FOR NOW
- [x] VARIADIC!! ( how could I forget ? )  &rest ArgList  <--  uses List. Is this a good match? I have reservations.
   for defmacro it seems like this might be useful, central maybe.  But it would make def-function etc difficult to realize.
   OTOH OpenCL C does not support variadics. So it could be a win if achieved. 
   Maybe TEMPLATES could be variadic, but at compile time the interface for a function is compiled exactly. (aref vec x &rest coords) => (aref vec x y z w) for a 4D vector-view ? 
- [x] Might need to reexamine variadics anyway. Is + going to be variadic like in Common Lisp? That means an implicit reduce, plus difficult to do without CONS cells,  
  which I do not want to introduce.  Maybe just overload + for 2, 3, and 4 args and call it a day?
    DECISION: defmacro is variadic, functions are not
- [ ] C++ has "explicit" for constructors to prevent them from participating in automatic type conversion.  Do we need anything like that?
- [ ] `identity-tensor` and `maybe` both have the risk of introducing too much "logic" code, which will not be performant
   Same goes for "safe" numeric types.
- [ ] metadata:  'bifurcation count' and 'cognitive load'.  Not sure. 
- [ ] give more thought to "events". Not sure what CUDA does. 
- [x] in-warp / in-XXXXX  =>  is this really better than just (let ((lane-id (get-lane-id))) ...)  &c.  Esp consider: (let (in-warp (let ...)))  which is a lot of nesting versus ONE  (let ...)
+ [ ] OTHER reductions: scan / boolean (all, any none?) / Segmented
- [x] reduce-vec ?
- [ ] pronounce "shuffle" as "shoo-FLAY"
- = specialization constants? More of a host thing.  Host runtime access to crisp compiler seems more powerful.
- = How will compiler work?  Multi-pass is simplest? macro-expansions. Tree shaking? Can libraries be built for faster compilation time? 
- = Compile Time Properties?  We have `num-dims-of`  already, possibly `address-space~` , `element-type-of` 
    Tension between `someProp~` and `someProp-of` .  
If so, what does THAT look like?   Imagine libraries with many functions, not all used.  We have a dependency of A -> B -> C, where A has the main changing kernel code.  Someone wants to recompile A _fast_ . Can we avoid recompiling C? or B?  Can the USER prepare something so that minimal compilation is required? If so, how?
- = is member-get/set! the best way?  Will we then need atomic variations on them as well?
    maybe we have (. someVec i)   and (.! someVec i)   where .! is not overrideable?
- = rename . (again)?  PROPOSAL: use ~ for vector access ~x  for struct access.  And maybe ~= for Non-overideable variants or maybe ~~ or maybe ~ref and ~x~   ( though, I think double tilde might be reserved in  markdown for strikethrough).   This helps make them ALL useful for (atomic-add (~x~ somePoint) delta)
+ `+` variants should use shuffles instead of local memory
- other things
- - [ ] fp rounding mode
- - [ ] general register file configurable?
- + [x]complex numbers
- + [ ] group barriers
- - [ ] prefetching
- - [ ] marshalling / directing of workgroups.  Seems like host should do this. But perhaps I lack imagination. reduce_over_group ? 
- - [ ] thread block clusters  ( CUDA only? )
+ - [x] atomics 
- + [x] conditional compilation of kernel functions for device aspects.  or maybe `(when+  (device-supports-fp16?) ... )` ?  (device-has? :fp16)
+ - [ ] dot product and accumulate for matrices, and maybe all tensors?

FUNCALL vs DIRECT USE. -- Let's try for direct use?  funcall was always confusing. 

[x] NO RECURSION. NO MUTUAL RECURSION 

[X] VARIADICS REVISIT -  Macros could be variadic.  But runtime functions no.  This might be a good compromise.

[x] DERIVED TYPE REVISIT - how to extend with new properties?  What would that mean vis-a-vis :subst options?
      ANSWER: no extending. a. Make two types:  struct-A { int }  struct-B {int, float}  
                            b. (set-derived struct-A-type struct-B-type :subst :pass-orig) 

[X] C interop with structs/vectors 

[x] LAMBDA REVISIT - uniform lambdas OK?  

[ ] OVERLOAD REVISIT - how will overloaded functions, especially getters/setters, be useful if there is no var capture or globals?
                   (def-function make-xxxx ()   (def-function overload-of-something () ...))  ?  

[x] DEF-KERNEL-EXACT ?  - our def-kernel assumes someone will be using our hoisting code.  BUT for people that have hoisting code already and know
                      the exact interface, they should be able to define it.
                      QUESTION:  how do THEY get vectors over then? void* data and size_t bytecount / versus / double* data and size_t count.
                      A1:  special declare?
                      A2:  marshall-vector call and voidp type.

[x] vector-view that changes element type. (like casting a vector of double to long) "reinterpret"

[ ] DATA-POOL   - could be a real value add here. Kernels can't really dynamically allocate memory, so a pool system would be handy.
              Also very handy if we can calculate how much scratch will be needed and communicate that back in the hoisting code.
              Could be in terms of kernel args.  DataPoolSize = sizeof(double) * vector-A.lenth * 1.7 

              This also suggests that "scratch" and "return"  data-pool entries are handled.  via type sig? declare? proclaim? 

[X] COPY-BACK   - are "result" vectors automatically copied back? (As opposed to "implicit"?)  Assuming no (safe assumption), 
              what is the mechanism for this? Often times it is a separate kernel. Need to understand this better.
              How will users doing their own result kernel args get things copied back?  Unified Memory vs Non vs Buffer vs ??

[X] MACROEXPAND - where to put this? A REPL tool? compiler flag?


[x] SORTING  ( [ ]radix & [x]bitonic   - probably over warp, workgroup, global, vector)

[X] PROFILING ? yet another side channel?   advise?  -- is mostly a host side issue, correct?  
    DECISION: hoisting example code will have commented out code that enables profling. 
              (get-timestamp) function available.   
              That's enough to help a user.  Later we can add "advise" 

[x] IN MEMORY COMPILATION API -- needs to be specified. 

[ ] ENTRYPOINT

[x] fused softmax ( whatever T F that is.)

[x] Am not totally loving the reduction macros. with-template-type wrapped over function seems better?  Or maybe defmacro should be   
    statically typed.  Having it slip through the cracks seems weird, and dangerous.

[x] REVISIT / CLEAN UP MEMORY / SUMMARYIZE and COMPARE .  a) make-vector with compile-time known size: fully supported.  
      b) various "scratch" local/global . d) def-constant-vec/use 
      e) communicate with hoisting, derive-from f) side-channels g) #( 1 2 3)  
      h) (declare (shared someVar) (uniform otherVar))   "shared" could be "local" or "slm" ?  This declare is for let clauses
         difference between "shared" and "uniform"

[x] Pretend we introduce 'while' or something. If a kernel does run infinitely, how can it be stopped?
    presumably some 'terminate()' call from within kernel. But what about from host? A: Not easily from host. Requires reset. 

[ ] OTHERS
   -Mojo    ( https://www.modular.com/mojo )  One language, any hardware.  Bare metal performance. Pythonic Code.  
    -Triton  ( https://openai.com/index/triton ) open source gpu programming for neural networks. 
    -Cutlass  ( https://github.com/NVIDIA/cutlass ) CUDA Templates and Python DSLs for High-Performance Linear Algebra
    -Hillisp ( https://github.com/michelp/hillisp )   tiny Lisp implementation written in CUDA.  Drives the GPU.  Queues up "fill" kernels, "+" kernels, etc. 
    -CL GPU ( https://www.cliki.net/cl-gpu )  subset of Common Lisp on GPU
    -cl-gpu ( https://github.com/angavrilov/cl-gpu ) A library for writing GPU (CUDA) kernels in a subset of Common Lisp.
    -ATen ( https://github.com/zdevito/ATen )

[x] Debugging Story - Give more attention.  A REAL pain point with developers.

[no] Generate Crisp from Python.

[x] FFT 

[ ] warp scheduling and [x] memory coalescing

[x] def-orchestration / calls kernels and some prebuilt affordances: cuBLAS, possibly oneMKL?.  "soft description". basic vector declarations, data passing, looping.
    probably need a (TBD ...) and (hoist-comment ...) macro.   Templates?  Gen?  


#### To Do (SHORT)
- [x] FFT
- [x] Radix Sort
- [x] Debugging Story
- [x] Compile-time introspection first-class citizen: 
    [x] get-struct-members   / with-struct-accessors
    [x] ~is-grid-level?~  / is-thread-level?
    [x] get-return-type
    [x] get-member-types
- [x] reduction macros -> templates
- [ ] OTHER reductions: 
- - [x] scan 
- - [x] boolean (all, any none?) 
- - [x] Segmented
- [x] Math: sqrt / rsqrt / pow / exp / log / log2 / sin / cos / tan / asin / acos / atan / abs / min / max / clamp
- [x] ENTRYPOINT - for libraries
- [x] fused softmax
- [ ] use maybe something "real" (texel ?)
- [ ] data pool
- [x] vector-view that changes element-type
- [ ] dot product and accumulate for matrices
- [ ] / group barriers
- [x] complex numbers - need for FFT
- [ ] matrix ops / vector ops
    [x] (m*v M v) - convenience function for matrix-vector multiplication. Very common special case of matmul
    [ ] / (determinant M)
    [x] fill
    [x] copy
    [x] iota
    [ ] gather
    [ ] (is-contiguous? M)
- [ ] / (declare (critical name V)) ; if fighting "spill", how important is one value vs. another.
- [x] / def-orchestration
- [ ] / (hoist-comment )
- [x] / (declare (const var-name))
- [x] Kernel IPC
- [x] Data interleaving. Mostly host side, but kernel needs to be able to work in chunks. 
      Kernel typically takes an "offset" into the data. (vector-view vibes).
      Works well with "embarassingly parallel" ops like: vector_add, convert-layout (matrix transpose), grid-strides,
      But won't work with: reductions, filter (and prefix-sum-scan), sorting (radix/bitonic). 
      [ ] Merge sort, however, chunks.  (Could be done using bitonic/radix for the smaller sets)
      There is a REAL need here. Data interleaving has a lot of reqs.  So setting up a sample might 
      be fire.

#### SHORTEST
[x] Entrypoint
[x] Strings (too much handwaving)
[x] mapping and composition
[x] update all old routines and remove them.
[x] workgroup-level  -- is-thread-level? might be impacted
[ ] ident / (identity-of #'max T) => -INF or wahtever.
[ ] (supports-max? T) or (supports? #'max T) ?
[x] Segmented (b.c. hard)
[x] Quantized Ints
- [x] dot-prod
- [x] matmul
- [x] mat-vect-mul
- [x] convolution
- [x] pooling (average / max)
- [x] activation functions ( ReLu etc)
[x] FP4 / FP8 -- microfloat blocks
[x] (declare (convergent)) (ragged-edge) ? and friends
[x] matrices and tensors as first class kernel args? Yes: Document. 
[x] rename "vector" as "storage". "vector-view" -> "vector", etc tensor matrix.
    and, yes, the NEW vector, matrix, tensor are first class kernel args.
    dumb storage is the storage but access is via views. the ex-views ALL
    have "offset" and "stride". 
    [x] update "Member Data Rules" for vector
    


Three things:
- maybe type in loops?  I'm just NOT using it. 
- where can these new bad boys be used? gather-all/scatter-all!
- maybe GLOBAL vector alignment?  <-- not for Crisp itself or libraries maybe?
  the constant capturing of A is noisy.
x FRANKLY, the constant templating of vectors is noisy. HMMMMM  (<T>  (def-fun..))
x gen-XXXXX on ANY grid-function to generate a kernel? (that doesn't take a function arg)
x these vectors of 1.  HMMMMM
- send code to Gemini?  AWESOME feature
x curry/lambda for word_count. f*ck
x lose make-vector and gen-make- and use make-scratch-vector instead. Defaults to :local, can be overriden.
- concepts / type classes / type collections.  microfloats and quantized integers
  seem like they should be leveraging a generalizable pattern.

  -->

<!-- PUT THIS LITTLE SUMMARY ON MEMORY SOMEPLACE 
