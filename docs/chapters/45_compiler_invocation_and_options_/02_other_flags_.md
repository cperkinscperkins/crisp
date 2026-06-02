# Other Flags ✅


### `--runtime-checks`
This flag enables various runtime checks that Crips is able to generate. Bounds checks, etc. 
The exact checks are documented in thei relevant sections. <!-- NOTE: gather them up --> 
In the initial implementation, this flag is useless without also enabling `--logging-output` and the
compiler will emit an error if that flag is not also elected. 

### `--logging-output`
This enables the debugging output side channel as well as enabling the runtime checks ( `r-t-check` ). When this 
option is used, the kernel may run significantly slower. Note that the code that actually hoists
the kernels built with this flag has to be updated as well so that the debug output side channel vector
is created and added as an argument. It is up to the calling application to decide what to
do with the debug output once it is retrieved. The hoisting code typically models writing it to a file.


### `--debug` or `-g`
When outputting LLVM-IR, include DWARF symbols

### `--hoist-unified-memory`
If this flag is present then the memory that is prepared in the hoisting code will be
CUDA Unified Memory, LevelZero Unified Shared Memory, or OpenCL Shared Virtual Memory, as appropriate to the hoisting 
target.  Otherwise, the memory operations will use regular memory. 

### `--hoist-dynamic=<KERNELNAME>`
This flag can be used repeatedly, each occurrence with a different KERNELNAME.  For each kernel named, the hoisting 
code will demonstrate how to compile that same kernel by invoking the in-memory compilation API on the string that is that
kernel. 

### `--re-output-crisp=<DIRECTORY>`
This flag is passed a directory. The .crisp files that are being compiled will be copied into that directory. But they will 
be modified in three ways: 
 - any types that were inferred by the compiler will now be explicitly declared in the updated .crisp file.
 - the file will be output in dependency order, compatible with single pass compilation. 
 - any static analysis "opt-in"s will be removed. 


### `--no-inference`
Type inference is turned off. The compiler will output an error for missing types.

### `--no-static-analysis`
Any opt-in static analysis (see above) will be skipped. 

### `--single-pass`
By default, the Crisp compiler performs "multi-pass" compilation, which means that the compiler first reads the .crisp files, gets an understanding
of everything that will need to be compiled how how they depend upon each other, and then it takes a second pass and actually compiles everything. 
When the `--single-pass` flag is present the compiler compiles items as it encounters them. But this requires that your .crisp file is in reverse
 dependency order. Meaning that if  `calc-two-things` calls `calc-one-thing` that `calc-one-thing` MUST appear in the .crisp file BEFORE `calc-two-things`.
 In other words, when any function is being compiled, every subfunction and macro that it uses MUST have been previously declared. This often means that
 entry points and kernels appear last in a .crisp file. 
 If this is an inconvenient way of working for you, don't let it crimp your style. Don't bother with the `--single-pass` flag
  or use the `--re-output-crisp` flag to have your .crisp files converted to single pass order. 

### `--skip-c-t-checks`  

The compile-time checks are skipped. This is very dangerous but does make the act of compilation much faster. 
It is meant to be used when doing runtime compilation of Crisp kernels, probably from some sort of code template that you know is sound.
It is possible to output invalid kernels with this option. 
Note that this not only skips the `c-t-check` entries that you put into your own code, but ALSO many routine checks that the compiler
regularly performs, including error checks that the documentation elsewhere says might be performed.
When this flag is on, the compiler only performs the minimal checks required to
move forward. This is inherently unsafe. 

### `--tree-shaking`

The `--tree-shaking` flag causes the compiler to carefully evaluate which functions and subfunctions are ACTUALLY 
called by the kernels and only incorporate those into the final binaries.  This can make the compilation pass
a little slower, but makes the kernel smaller, faster, and faster to load.

But there is a second side effect that happens when tree shaking. Both the functions used and not from any 
library files are precompiled for the compilation targets into .crisp_lib and .crisp_libc files and these
files will make any future compilations that use these same libraries to these same targets MUCH
faster. 

<!--  Do we need flags to control where these lib files get written / read ?  Answer: YES -->

<!-- NOTE
1 - .crisp files with no kernels are automatically identified as "library" files.
2a. - the user invokes the full compilation command. There is a --tree-shaking flag. It runs slow. We compile for whatever targets they specified, be they IR or binary.
2b - when tree shaking, each "library" gets its entry point functions (*) compiled into their own little thing, one for each target. Bound up with a map into a big blob.
2c - and the entry point functions that are actually used by my_kernel also get put into a second little thing, one for each target. blobbed together.
     if a function is inlined when tree shaking, that is noted too. 
3 - the NEXT invocation of the compiler we lean on 2c to really speed things up and fall back to 2b if necessary. If something was inlined before, 
    we just do it again.
4 - assuming the output target profile is the same, other kernel .crisp files could benefit from 2b at very least. 
-->

<!--  (declare entry-point inline)  both need definitions -->

