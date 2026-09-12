# `make-register-tile-ring` ✅


```
(make-register-tile-ring <elem> (<M> <N>) :ring-count <n> &key operand warps)

(make-register-tile-ring float (16 8)  :ring-count 2 :operand :a)
(make-register-tile-ring half  (32 16) :ring-count 2 :operand :b :warps '(false true true))
```

A ring of register-resident MMA tiles — the GRF counterpart of `make-scratch-matrix-ring`, used to
prefetch the next K-step's operand into registers while the current one multiplies.

- **`:operand`** — `:a`, `:b` or `:acc` (default `:acc`).  It selects the fragment shape from the
  active profile's MMA shape, so `(<M> <N>)` must tile evenly into fragments of that shape.
- **`:warps`** — the warp participation mask, exactly as on [`make-register-tile`](#make-register-tile),
  applied per slot.
- There is **no initial-value argument**.  Unlike `make-register-tile`, every slot's fragments
  start at zero.

Unlike a barrier ring, a register tile ring works on both backends.

