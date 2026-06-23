// Endeavor 122 (FFI) Pass 1: a trivial device function bound via
// def-foreign-function. Compiled to a target-specific .bc by the spec harness
// (clang --target=nvptx64-... for ptx, --target=spir64-... for spv) and linked
// into the kernel module at compile time.
float my_add(float a, float b) { return a + b; }
