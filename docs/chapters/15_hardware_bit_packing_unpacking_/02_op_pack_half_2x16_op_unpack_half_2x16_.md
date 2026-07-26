# `op-pack-half-2x16` / `op-unpack-half-2x16` 📝


```
(op-pack-half-2x16 float float) => uint
(op-unpack-half-2x16 uint) => float float
```
- What it does: Packs two 32-bit floats into two 16-bit floats (half precision) inside a single `uint`.
- Use case: Storing UV coordinates, normals, or colors where 32-bit precision is overkill but 8-bit is too low. This is probably the most widely used packing op after 8-bit color.

Obviously, if you are using `half` you don't need this, you can just bit-shift and cast.

