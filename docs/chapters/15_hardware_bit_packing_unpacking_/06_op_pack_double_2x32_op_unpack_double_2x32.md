# `op-pack-double-2x32` / `op-unpack-double-2x32`

```
(op-pack-double-2x32 uint uint) => double
(op-unpack-double-2x32 double) => uint uint
```
- What it does: Packs two 32-bit unsigned integers into a single 64-bit double.
- Use case: Mostly for passing 64-bit data through pipelines that might be restricted to 32-bit registers, or bit-casting.

<!--

These are used fairly common in shaders, but there is usually no hardware level unpacker for them.

Plus, the "shared exponent" thing makes them more akin to the microfloat-blocks.  

If we wanted to provide unpacking, we'd have to do it ourselves, likely with no hardware acceleration.

For that reason, I'm keeping this out of the spec until later.

