# `op-find-msb` / `op-find-lsb` 📝

`op-find-msb` returns the *index* (0-31) of the most significant bit set.
Note: This is NOT the same as `op-count-leading-zeros`.
It is calculated as `31 - clz(value)`.

`op-find-lsb` is exactly the same as `op-count-trailing-zeros` above, and it will 
 sometimes get mapped to `CTZ` on hardware.

```
(op-find-msb #b00001100) -> 3
(op-find-lsb #b00001100) -> 2
```


