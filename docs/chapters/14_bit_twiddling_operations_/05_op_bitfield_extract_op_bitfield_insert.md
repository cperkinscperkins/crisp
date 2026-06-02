# `op-bitfield-extract` / `op-bitfield-insert`

These two operations are precision tools for slicing and splicing bits within an integer. They are incredibly useful for packing multiple small values (like 5-bit, 6-bit, or 10-bit numbers) into a single 32-bit integer without messy shifting and masking math.

`(op-bitfield-extract value offset bits) -> uint`

`op-bitfield-extract` grabs a specific sequence of bits from `value`, starting at 
`offset` and taking `bits` number of them, returns that sequence as a new integer (right-aligned).

Like `substring` but for bits.


`(op-bitfield-insert base insert offset bits) -> uint`
`op-bitfield-insert` takes a `base` integer and replaces a chunk of its bits with
the first `bits` from the `insert` value, starting at `offset`. 

#### Example: update RGB565

This example is a bit contrived, but it shows how `op-bitfield-insert` 
could be used.
```
(let ((packed-color #b1111100000011111)
      (green        #b0000000000111111))
  (declare (type packed-color green short))
  (op-bitfield-insert packed-color green 5 6)
  ;; NOW packed-color is #b1111111111111111 )
```





