// Endeavor 122 (FFI) Pass 3: a foreign function that writes through a global
// pointer. __attribute__((address_space(1))) yields LLVM addrspace(1) (global)
// on BOTH nvptx64 and spir64, matching a Crisp (cell ... :address-space :global)
// base pointer with no cast needed.
void write_seven(int __attribute__((address_space(1))) *p) { p[0] = 7; }
