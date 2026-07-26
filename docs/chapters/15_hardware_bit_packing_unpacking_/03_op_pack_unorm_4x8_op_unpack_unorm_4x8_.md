# `op-pack-unorm-4x8` / `op-unpack-unorm-4x8` 📝

```
(op-pack-unorm-4x8 float float float float) => uint
(op-unpack-unorm-4x8 uint) => float float float float
```
- What it does: Packs four 32-bit floats (clamped to 0.0-1.0 range) into four 8-bit unsigned integers inside a single `uint`.
- Use case: Standard RGBA8 color data. This handles the float-to-int conversion and packing in one fast hardware instruction.

