# Format Wars


There are competing formats for these microfloat blocks.

NVidia NVFP4 / Blackwell: https://developer.nvidia.com/blog/introducing-nvfp4-for-efficient-and-accurate-low-precision-inference/

OCP (Open Compute Project) MX Formats: https://www.opencompute.org/documents/ocp-microscaling-formats-mx-v1-0-spec-final-pdf

`def-microfloat-block` is parameterized, so it can describe either:

| Format | Crisp |
|---|---|
| NVFP4 | `:base fp4 :scale fp8-e4m3 :shape (16)` |
| MXFP4 | `:base fp4 :scale fp8-e8m0 :shape (32)` |
| MXFP8 | `:base fp8-e4m3 :scale fp8-e8m0 :shape (32)` (or `fp8-e5m2`) |

Decoding someone else's blocks follows the format definitions exactly. How a scale is *chosen* when
quantizing is a convention, and conventions differ: Crisp rounds the scale up (see
[quantize-to-XXXX](#quantize-to-xxxx-)), and other exporters may not. So a block Crisp writes may differ
from one another tool would write for the same input.

NVFP4's optional per-tensor global scale, in addition to the block scales, is not supported yet 📝.

