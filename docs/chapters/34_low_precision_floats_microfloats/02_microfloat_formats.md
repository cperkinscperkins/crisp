# Microfloat Formats ✅


| Format | Bits | Largest finite value | Notes |
|---|---|---|---|
| `fp4` | 4 | 6.0 | E2M1.  No infinity, no NaN |
| `fp8-e4m3` | 8 | 448.0 | No infinity.  `0x7F` / `0xFF` are NaN |
| `fp8-e5m2` | 8 | 57344.0 | Has infinity and NaN, like IEEE |
| `fp8-e8m0` | 8 | 2^127 | `2^(code - 127)`, and 255 is NaN.  No zero and no sign, so it is a scale only |

`fp8-e8m0` is the scale of the OCP MX formats. The design's `fp16` and `fp32` are dropped because they
duplicate `half` and `float`, and `f8-e8m0` is renamed `fp8-e8m0` to match the others.

These formats are types (each is a `:subst :no` derived type over `uchar`), so they can be the element of
a storage handle. But a code is not a number until it is decoded: arithmetic on codes is refused.

