# `store-tile-at` ✅


`(store-tile-at src dest (... y x) &key transpose transformF barrier via) => nil`

Functions identically to `store-tile`, but uses exact **Element Coordinates** rather than logical Tile IDs to position the data in the destination tensor.

`:via :tma` (NVIDIA sm_90, a wgmma accumulator converted to `half` / `bfloat16`) stores through
`stmatrix` staging and TMA stores instead of per-thread global stores — see *Storing through the TMA*
under `wgmma-accumulate-via-tile`.

