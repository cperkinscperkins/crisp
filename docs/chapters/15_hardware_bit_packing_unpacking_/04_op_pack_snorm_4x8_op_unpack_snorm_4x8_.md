# `op-pack-snorm-4x8` / `op-unpack-snorm-4x8` 📝

```
(op-pack-snorm-4x8 float float float float) => uint
(op-unpack-snorm-4x8 uint) => float float float float
```
- What it does: Same as above, but for SIGNED normalized values (-1.0 to 1.0).
- Use case: Storing normals (nx, ny, nz) or vectors in 8-bit precision.

