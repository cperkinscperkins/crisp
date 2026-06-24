// Endeavor 123 (FFI-AD) Pass 1: a self-contained nonlinear scalar device
// function. Compiled to a target-specific .bc by the spec harness and linked
// into the kernel module. Its derivative (3*x*x) is known and supplied on the
// Crisp side via the user backward c-cube-bwd, so the foreign call is
// differentiable. Self-contained (no libm) to keep the .bc portable.
float c_cube(float x) { return x * x * x; }
