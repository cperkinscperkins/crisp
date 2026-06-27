// Endeavor 123 (FFI-AD) Pass 1: an integer-in / integer-out device function.
// Exercises Crisp's integer differentiation across the FFI boundary: the int
// return takes a float gradient seed and the int input yields a float returned
// gradient (the derived VJP is #'(int float => float)). Self-contained.
int c_idbl(int n) { return 2 * n; }
