# Other Flags ⚠️


#### `--runtime-checks` ⚠️
Compiles the runtime asserts (`r-t-assert`, `r-t-assert-0`) and the compiler's own runtime checks
(bounds checks etc., documented in their relevant sections) as `(unless <test> (die))`.  Their messages
are dropped; add `--logging-output` to keep them.  Without this flag they are compiled away entirely.
See [Logging and Debugging](#logging-and-debugging).

> **Implementation status**: on L0 a failed check does not halt the thread (BUG 136).

#### `--logging-output` 📝
Adds the log side channel.  `r-t-output` forms are compiled, and asserts and `die` also write their
messages into the log.  Implies `--runtime-checks`.  Kernels that log may run noticeably slower.
The hoisting code has to take part: it allocates the log, passes it as an implicit argument, and decodes
it after the kernel finishes.  See [The Log](#the-log).


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

