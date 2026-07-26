# member data rules


A struct can contain any type that has a fixed, known size at compile time.
This would include:
- Scalar types (`int`, `float`, etc)
- Hardware vector types (`float4` etc)
- Other structs
- Compile time sized `array` 
- Views to large data (`cell`, `vector`, `tensor`, `matrix`)

But it excludes:
- `functions` and `kernels`
- Crisp specific internals, like `storage`

Note also that views can't be exchanged with the host directly. A struct that contains a view
cannot use the C interop for data exchange with host. Marshalling would be required.

