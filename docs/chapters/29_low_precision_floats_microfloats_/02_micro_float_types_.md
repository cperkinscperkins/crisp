## Micro Float Types ✅


Crisp provides these base types for you:

| Type   | Size    | 
|--------|---------|
| fp4  | 4 bits (half byte)  | 
| fp8-e4m3 | one byte - 4 bit exponent, 3 bit mantissa |
| fp8-e5m2 | one byte - 5 bit exponent, 2 bit mantissa | 
| f8-e8m0 | one byte - 8 bit exponent, 0 bit mantissa. This has faster, but less precise dequantizing |
| fp16 | 2 bytes |
| fp32 | 4 bytes | 

The `f8-e8m0` type is used for the OCP MX formats ( MXFP8, MXFP6, and MXFP4 )

