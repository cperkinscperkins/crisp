// Endeavor 122 (FFI) Pass 4: a foreign function taking a handle (void**).
// give_ptr writes the input global pointer into the handle slot. The
// address_space(1) attribute yields addrspace(1) (global) on both nvptx64 and
// spir64 for the data pointer; the handle (out) is a default/private pointer to
// the slot (matches a c-handle, addrspace 0).
void give_ptr(int __attribute__((address_space(1))) *in,
              int __attribute__((address_space(1))) **out) {
  *out = in;
}
