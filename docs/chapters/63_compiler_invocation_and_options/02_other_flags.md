# Other Flags ⚠️


#### `--runtime-checks` ✅
This flag enables various runtime checks that Crips is able to generate. Bounds checks, etc. 
The exact checks are documented in thei relevant sections. <!-- NOTE: gather them up --> 
In the initial implementation, this flag is useless without also enabling `--logging-output` and the
compiler will emit an error if that flag is not also elected. 

#### `--logging-output` 📝
This enables the debugging output side channel as well as enabling the runtime checks ( `r-t-check` ). When this 
option is used, the kernel may run significantly slower. Note that the code that actually hoists
the kernels built with this flag has to be updated as well so that the debug output side channel vector
is created and added as an argument. It is up to the calling application to decide what to
do with the debug output once it is retrieved. The hoisting code typically models writing it to a file.


#### `--debug` or `-g` ✅
When outputting LLVM-IR, include DWARF symbols


#### `--hoist-kernel=file|source` ✅
With `--hoist=l0`: where the generated launcher gets its kernel.  `file` (the default) loads the
compiled `.spv`.  `source` embeds the `.crisp` source and the compile flags, compiles them at run
time through the [Compile API](#compile-api), and takes every argument slot from the API.

#### `--re-output-crisp=<DIRECTORY>` 📝
This flag is passed a directory. The .crisp files that are being compiled will be copied into that directory. But they will 
be modified in three ways: 
 - any types that were inferred by the compiler will now be explicitly declared in the updated .crisp file.
 - the file will be output in dependency order, compatible with single pass compilation. 
 - any static analysis "opt-in"s will be removed. 


#### `--no-inference` 📝
Type inference is turned off. The compiler will output an error for missing types.

#### `--no-static-analysis` 📝
Any opt-in static analysis (see above) will be skipped. 

#### `--single-pass` ✅
By default, the Crisp compiler performs "multi-pass" compilation, which means that the compiler first reads the .crisp files, gets an understanding
of everything that will need to be compiled how how they depend upon each other, and then it takes a second pass and actually compiles everything. 
When the `--single-pass` flag is present the compiler compiles items as it encounters them. But this requires that your .crisp file is in reverse
 dependency order. Meaning that if  `calc-two-things` calls `calc-one-thing` that `calc-one-thing` MUST appear in the .crisp file BEFORE `calc-two-things`.
 In other words, when any function is being compiled, every subfunction and macro that it uses MUST have been previously declared. This often means that
 entry points and kernels appear last in a .crisp file. 
 If this is an inconvenient way of working for you, don't let it crimp your style. Don't bother with the `--single-pass` flag
  or use the `--re-output-crisp` flag to have your .crisp files converted to single pass order. 

**Interprocedural uniformity and `--single-pass`.** Multi-pass compilation lets the compiler *infer* that a scalar kernel input threaded through a call is workgroup-uniform — so a sub-function using `if+`/`dotimes+` on that parameter compiles with no annotation, purely from the proof that every call site passes a uniform argument. This inference needs the whole call graph, which `--single-pass` does not build (a callee is compiled before its callers are seen). Under `--single-pass`, assert it explicitly on the callee with `(declare (uniform x))`; otherwise the `+` form reports its condition as `UNKNOWN` and errors.

#### `--skip-c-t-checks`  📝 

The compile-time checks are skipped. This is very dangerous but does make the act of compilation much faster. 
It is meant to be used when doing runtime compilation of Crisp kernels, probably from some sort of code template that you know is sound.
It is possible to output invalid kernels with this option. 
Note that this not only skips the `c-t-check` entries that you put into your own code, but ALSO many routine checks that the compiler
regularly performs, including error checks that the documentation elsewhere says might be performed.
When this flag is on, the compiler only performs the minimal checks required to
move forward. This is inherently unsafe. 

