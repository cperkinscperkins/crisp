# Overview


Crisp is a Lisp dialect for developing GPU Kernels.
The Crisp compiler takes .crisp files and can output SPIR-V, PTX, or a binary for a specific GPU. 
The compiler can ALSO output C++ or Python code snippets that can "hoist" that same kernel. 
The snippets can be targeted to: OpenCL, LevelZero, or CUDA, as well as whether to use
Unified Memory/USM/SVM.

Someday soon.


