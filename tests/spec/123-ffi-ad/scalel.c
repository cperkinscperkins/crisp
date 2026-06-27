// Endeavor 123 (FFI-AD) Pass 1: a long (64-bit) return. This is the case that
// pins the seed-promotion rule: a `long` return must take a `double` gradient
// seed (not float), per %promote-to-float-adjoint. The derived VJP is
// #'(float double => float). Self-contained.
long c_scalel(float x) { return (long)(x * 1000.0f); }
