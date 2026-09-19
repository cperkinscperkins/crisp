# `make-async-barrier-ring` ✅


```
(make-async-barrier-ring :ring-count <n> &key mode arrivals initial-state)
```

- **`:ring-count`** — required.  The pipeline depth: how many stages are in flight at once.
- **`:mode`** — exactly as `make-async-barrier` (`:linear` / `:block` / `:cluster`; omit for
  arch-automatic).  Every slot in the ring shares the mode.
- **`:arrivals`** — **required.**  How many transfers **each slot** tracks *per pipeline stage* —
  i.e. how many `load-tile`s name that one slot in a single stage.  The classic A+B staging is `2`.
  It is explicit rather than inferred because a ring's prologue and main loop both load the same
  ring, so the textual tally (2 + 2) is not the per-stage count (2).  **The number must be exact:
  too high and a `:block` barrier never completes and the kernel hangs; too low and you read a
  half-arrived tile.**  Under `:mode :cluster` you still write the **per-workgroup** number — the
  compiler multiplies it by the declared cluster extent.
- **`:initial-state`** — `:waiting` or `:signaled`: the awaiter's starting phase.  Omit it for an
  ordinary pipeline ring, whose `await` re-arms each slot as it goes.  Supplying it marks the ring
  as a warp-specialization handshake — the data-arrival ring starts `:waiting` (block until the
  producer fills a slot), the buffer-free ring starts `:signaled` (every slot is free at launch).

**Barrier rings are NVIDIA-only today.**  `:block` and `:cluster` are compile errors on SPIR-V, and
a genuine `:linear` ring (`ring-count > 1`) is not yet implemented there — it would need per-slot
`spirv.Event` chaining.  A single `(make-async-barrier :mode :linear)` is fine on Intel, as are
scratch and register tile rings.

```
;; three stages in flight; each stage stages an A-tile and a B-tile under its own barrier slot.
(make-async-barrier-ring :ring-count 3 :mode :block  :arrivals 2)   ; NVIDIA sm_90+ (TMA mbarriers)
(make-async-barrier-ring :ring-count 3 :mode :linear :arrivals 2)   ; sm_80+ (cp.async wait_group)

;; a warp-specialized pipeline: the full/empty handshake between producer and consumer warps.
(make-async-barrier-ring :ring-count 3 :mode :block :arrivals 2 :initial-state :waiting)
(make-async-barrier-ring :ring-count 3 :mode :block :arrivals 2 :initial-state :signaled)
```


