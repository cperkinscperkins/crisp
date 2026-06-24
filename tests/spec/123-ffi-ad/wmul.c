// Endeavor 123 (FFI-AD) Pass 1: a two-input scalar device function. Exercises
// the ordering of the two returned gradients in the derived VJP (df/da = b,
// df/db = a). Self-contained (no libm).
float c_wmul(float a, float b) { return a * b; }
