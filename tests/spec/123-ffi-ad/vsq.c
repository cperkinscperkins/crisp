// Endeavor 123 (FFI-AD) Pass 2: a foreign elementwise op over global buffers,
// used to exercise gradient SHADOW routing across the FFI boundary.
//   out[i] = in[i]^2   (self-contained, no libm)
// __attribute__((address_space(1))) yields LLVM addrspace(1) (global) on BOTH
// nvptx64 and spir64, matching Crisp (c-pointer :address-space :global) with no
// cast (same pattern as 122-ffi/ptr.c).
void c_vsq(int n,
           const float __attribute__((address_space(1))) *in,
           float __attribute__((address_space(1))) *out) {
  for (int i = 0; i < n; ++i) out[i] = in[i] * in[i];
}
