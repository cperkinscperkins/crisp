# `op-pack-rgb-9e5` (Shared Exponent)  Pack only.

- What it does: Packs three floats into a 32-bit integer using a shared 5-bit exponent for all three channels.
- Use case: HDR lighting/color. It has no sign bit (positive only) but handles large dynamic ranges better than standard fixed-point. It is often an alternative to the `11-11-10` format of `op-pack-11`


-->

