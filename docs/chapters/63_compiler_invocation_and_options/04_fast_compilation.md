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

#### Compile API

To compile kernels from a running program -- strings in, binaries and launch facts out -- use
the [Compile API](#compile-api).  It keeps compiler processes warm between compiles.

#### Danger
If you are confident that the code you are compiling is completely ready and error free, use the flag that skips the compile time
checks. 

