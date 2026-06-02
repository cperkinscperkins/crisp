## Member Data Rules ✅


A  Storage Handle can contain any type that has a fixed, known size at compile time.
This would include:
- Scalar types (`int`, `float`, etc)
- Small vector types (`float4` etc)
- Structs
- Views to large data (`cell`, `vector`, `tensor`, `matrix`)

But it excludes:
- `storage`
- `functions` and `kernels`
- `def-record` and `def-rec-vec`




