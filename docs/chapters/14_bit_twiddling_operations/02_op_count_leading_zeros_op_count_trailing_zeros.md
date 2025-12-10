## `op-count-leading-zeros` / `op-count-trailing-zeros`

`op-count-leading-zeros` returns the number of zero bits before the first 1 bit in a `uint`.
This can be very handy for finding the index of the first active thread in a ballot mask. 

`op-count-trailing-zeros` returnst the number of zero bits after the last 1 bit in a `uint`.

In hardware these get mapped to `CLZ` and `CTZ`

```
(op-count-leading-zeros #b00000011) -> 6
(op-count-trailing-zeros #b10101010) -> 1
```

