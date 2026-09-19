# `store-tile` ✅


`(store-tile src dest (... grid-y grid-x) &key transpose transformF barrier) => nil`

Initiates a bulk memory transfer from the `src` tensor (usually registers or SLM) back to the `dest` tensor (usually Global Memory), targeting a specific logical Tile ID.

* **`:transformF`:** An optional epilogue function (e.g., `relu`) applied to the data during the store operation.
* **`:barrier`:** If provided, delegates the write out to the async DMA engine.
* **Note:** It is strictly illegal to use `:transformF` and `:barrier` simultaneously. A hardware DMA engine cannot apply arbitrary mathematical functions; it only moves raw bytes. If you need epilogue fusion, the warp must perform the math inline before storing.

