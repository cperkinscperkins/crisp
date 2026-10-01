# Warp Specialization ✅


```
(with-warp-specialization (:producer 1 :consumer 2)
  
  (:producer 
    ...
  )
  
  (:consumer
    ...
  ))
```

Warp specialization splits one kernel into distinct behaviours that run on different warps of the
same workgroup — typically a **producer** warp that does nothing but fetch tiles, and **consumer**
warps that do nothing but compute on them.

In the example above one warp runs the `:producer` body and two run the `:consumer` body, so the
workgroup must be sized to 3 × `(get-warp-size)`.  You may declare as many roles as you like, so
long as the workgroup is a multiple of their sum.  With `--runtime-checks` the compiler inserts a
check that the workgroup size actually matches.

**The roles talk to each other through barrier rings, not through a shared barrier.**  The
producer fills a slot and the consumer signals it free again, which is what
[`:initial-state`](#make-async-barrier-ring) on a barrier ring is for: the data-arrival ring
starts `:waiting` (block until a slot is filled) and the buffer-free ring starts `:signaled`
(every slot free at launch).

**`sync-workgroup` inside a role block is a compile error.**  It is a workgroup collective and
only one role reaches it, so it deadlocks rather than computing a wrong answer.  Synchronize
through `await` / `signal` on the rings instead; `sync-warp` is fine for intra-warp ordering.

**A register tile shared by the consumers needs a `:warps` mask** naming exactly the consumer
warps — see [`:warps`](#warps--the-warp-participation-mask-for-warp-specialization).  Without
it the tile distributes across *every* warp, including the producer, whose fragments are then
never computed.

**Two consumers is the measured sweet spot.**  On an H100, 1 producer + 2 consumers is the
fastest Crisp matmul at the sizes benchmarked (2× the plain pipeline at N=1024, +6% at N=4096);
four consumers regresses.  More consumers sharing one C-tile means fewer registers per thread and
higher occupancy, but the split has its own cost — measure it.

