// Endeavor 122 (FFI) Pass 2: foreign functions over advanced scalar (SIMD
// vector) types. Compiled to a target-specific .bc by the spec harness and
// linked into the kernel module. Vector args pass by value as <N x T>, matching
// Crisp's device-vector representation (alignment handled by the target ABI).
typedef float        float4 __attribute__((ext_vector_type(4)));
typedef int          int4   __attribute__((ext_vector_type(4)));
typedef unsigned int uint2  __attribute__((ext_vector_type(2)));

float4 my_vadd (float4 a, float4 b) { return a + b; }
int4   my_ivadd(int4   a, int4   b) { return a + b; }
uint2  my_u2add(uint2  a, uint2  b) { return a + b; }
