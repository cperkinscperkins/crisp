# Low Precision Floats ("microfloats") 📝


Similar to Quantized Integers, Crisp supports "microfloats".  These are
very small (half byte, one byte!) storage options for floats that need a
widened accumulator for multiplication. 

But there is a significant difference, microfloats are grouped into blocks, 
and each block has its own individual scaling factor. For example,
a not uncommon (*) organizations is one 8-bit scale factor followed by sixteen
individual 4-bit values :

`[fp8_scale_0] [16 x fp4_data] [fp8_scale_1] [16 x fp4_data] ...`

So microfloats don't have independent scaling factors in the way that quantized integers do.

(*) - This "not uncommon" organization is the one used by the NVIDIA Blackwell NVFP4 format.
It is 72 bits total and is usually padded out to 128 bits. 

