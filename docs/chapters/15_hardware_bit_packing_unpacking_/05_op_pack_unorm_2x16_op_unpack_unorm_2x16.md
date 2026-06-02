# `op-pack-unorm-2x16` / `op-unpack-unorm-2x16`

```
(op-pack-unorm-2x16 float float) => uint
(op-unpack-unorm-2x16 uint) => float float
```
- What it does: Takes two 32-bit floats (0.0-1.0), converts them to 16-bit unsigned integers, and packs them into one 32 bit `uint`
- Use case: High-precision texture coordinates or depth values.

