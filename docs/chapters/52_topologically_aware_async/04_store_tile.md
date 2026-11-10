# `store-tile` ✅


`(store-tile src dest (... grid-y grid-x) &key transpose transformF barrier) => nil`

Initiates a bulk memory transfer from the `src` tensor (usually registers or SLM) back to the `dest` tensor (usually Global Memory), targeting a specific logical Tile ID.

* **`:transformF`:** An optional epilogue function (e.g., `relu`) applied to the data during the store operation.
* **`:barrier`:** If provided, delegates the write out to the async DMA engine.
* **Note:** It is strictly illegal to use `:transformF` and `:barrier` simultaneously. A hardware DMA engine cannot apply arbitrary mathematical functions; it only moves raw bytes. If you need epilogue fusion, the warp must perform the math inline before storing.

**On an MMA accumulator** ✅ (endeavour 210).  `:transformF` works when `src` is any accumulator: a
register tile (PTX fragments or SPIR-V cooperative matrices), a wgmma accumulator, or a tcgen05
accumulator.  The function is applied to each raw `float` (or `int`) element *before* any conversion
on the source, so `(store-tile-at (to-bfloat16 D) C (row col) :transformF #'relu)` is relu, then round.
On a tcgen05 accumulator it is the only fused epilogue: the accumulator lives in tensor memory and the
store is its only reader, so `map-elements!` on it is refused with a message naming `:transformF`.
An accumulator store takes no other option (`store-tile-at` also takes `:via`).  Anything else, such as
`:transpose` or `:barrier`, is refused by name, never ignored.  Two limits: `:via :tma` with a
`:transformF` is refused on a tcgen05 accumulator (that store has no per-element step yet), and a
floating-point `:transformF` is refused under `--differentiate`, because its backward is not built
(BUG 159).  An integer-valued function carries no gradient and is accepted.

