# `op-popcount`

`(op-popcount uint) => uint`

`op-popcount` counts the number of set bits in a binary integer.
```
(op-popcount 3) -> (op-popcount  #b00000011) -> 2
(op-popcount 255) -> (op-popcount #b11111111) -> 8
(op-popcount #xAA) -> (op-popcount #b10101010) -> 4
```
`op-popcount` is the engine of parallel prefix sums on bitmasks. When you combine `warp-ballot` (which gives you a bitmask of "who is active") with popcount (which tells you "how many people are active"), you can calculate offsets and indices in constant time without loops.

