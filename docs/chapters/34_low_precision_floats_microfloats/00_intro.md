# Low Precision Floats ("microfloats") ✅


Similar to Quantized Integers, Crisp supports "microfloats". These are very small (half byte, one byte!)
storage formats for floats.

But there is a significant difference: microfloats are grouped into blocks, and each block has its own
individual scale. For example, a not uncommon (*) organization is sixteen 4-bit values sharing one 8-bit
scale:

`[fp8_scale_0] [16 x fp4_data] [fp8_scale_1] [16 x fp4_data] ...`

So microfloats don't have independent scaling factors in the way that quantized integers do: the scales
are part of the data.

In memory, the codes and the scales are kept in two separate buffers. That is how NVFP4 checkpoints
store them, and how Blackwell's block-scaled multiply reads them. A microfloat block in Crisp is
therefore a record over two storage handles: one of packed codes and one of scales.

(*) - This "not uncommon" organization is the one used by the NVIDIA Blackwell NVFP4 format.

