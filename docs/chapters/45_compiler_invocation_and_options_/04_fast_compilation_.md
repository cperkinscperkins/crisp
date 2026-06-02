# Fast Compilation ✅

Compilation speed is one of the prime goals of the Crisp compiler. There are things you can 
do to maximize compilation performance.

#### Single Pass

`--single-pass` compilation is faster than multi-pass. Use `--re-output-crisp` if necessary to prepare for this.

#### No Static Analysis

Static analysis is slow. If you have opt-in static analysis in your .crisp file, use `--no-static-analysis` to skip them.

#### No Type Inference

Type inference slows the compiler down. Declare all types if possible.  Use the `--no-inference` or `--re-output-crisp` flags to help
kick the habit.

#### Use Tree Shaking

The `--tree-shaking` flag makes for a slow compilation.  BUT the benefit for any future compilations to the same set of targets, especially
for the same set of libraries or kernels, is extreme. Be sure to use tree shaking from time to time to update the lib caches for your files.
Tree shaking can make the compilation of OTHER kernels faster too if they use some of the same libraries. It's clutch.

The `--tree-shaking` flag can be used with library .crisp files and no kernels at all. Given a set of targets it can still generate .crisp_lib files
for those libraries which will speed up future compilations of anything to any of those targets.  Note that many of the compilation flags
must be used consistently by both the tree shaking and future compilation passes:
- `-DXXXX`
- `--IR-target`
- `--binary-GPU-target`
- `--logging-output`
- `--runtime-checks`
- `--math-precision`

#### In Memory Compilation

There is ( soon? ) both a Python and a C++ API for performing in-memory compilation, including support for in-memory lib and lib caches. 
With this there is no disk IO and compilation can be performed nearly instantaneaously. 

#### Danger
If you are confident that the code you are compiling is completely ready and error free, use the flag that skips the compile time
checks. 

