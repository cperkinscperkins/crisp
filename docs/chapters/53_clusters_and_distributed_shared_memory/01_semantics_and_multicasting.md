# Semantics and multicasting


A declared cluster makes multicasting possible; **individual loads must opt in with `:multicast`
on `load-tile`.**  Without a declared cluster, asking for `:multicast` is a compile error.

* **Axes follow `:tile-shape`.**  Axis 0 tracks dimension 0 — for a row-major output tile, axis 0
  is rows and axis 1 is columns.
* **The multicast group is inferred, not declared.**  The compiler reads each load’s tile
  coordinates against the clustered axes: a load whose coordinates do not vary along a clustered
  axis is multicast across that axis.  You never write a destination mask or elect an issuing
  workgroup.
* **A load that varies along every clustered axis has no group** and is refused, naming the
  coordinate that conflicts.

```lisp
(declare (global-size :derive-from C :strategy :strided :tile-shape (64 256))
         (cluster-size :set-to (2 1)))    ; 2 workgroups along ROWS

;; In the kernel body:
(load-tile A (ring-get A-ring slot) (grid-y grid-k) :barrier ... )
(load-tile B (ring-get B-ring slot) (grid-x grid-k) :barrier ... :multicast true)
```

The cluster spans rows, so both workgroups compute the same columns.  `B` depends only on
`grid-x`, so it is invariant across the cluster and multicasts; `A` varies across it, so asking
for `:multicast` on `A` would be rejected.

**A 2-D cluster multicasts both operands.**  A matmul is symmetric — `A` does not depend on `n`,
`B` does not depend on `m` — so a `(2 2)` cluster lets each operand be fetched once per group
instead of once per workgroup.  Those are *different* sets of workgroups, which is exactly why the
multicast group is a property of the **load** rather than of the cluster.

**Multicast is narrower than it looks.**  It pays only when the machine is saturated (below full
occupancy there is no bandwidth contention to relieve) *and* the kernel is fetch-limited rather
than compute-limited (a well-pipelined kernel already hides the fetch that multicast makes
cheaper, while multicast’s bookkeeping stays on the critical path).  The same `:multicast true`
that wins **+15.7%** on a 64×128 tile at N=2048 *loses* **7–10%** on a 64×256 tile that is equally
saturated but has enough arithmetic per byte to hide its loads.  Worked measurement of both sides:
`benchmarks/matmul/sec3_cluster_multicast/cluster-multicast.md`.  Treat `:multicast` as something
to measure, not to assume — Crisp is built so that measuring it is a one-keyword change.

```lisp
;; -- matmul --
;; 64x256 output tiles, two workgroups per cluster stacked along rows.
;; Both workgroups need the same 256 columns of B, so B is fetched once and multicast into both.
(def-kernel matmul (A B &out C)
  (declare #'(a-mat b-mat &out c-mat)
           (local-size   :set-to 160)
           (global-size  :derive-from C :strategy :strided :tile-shape (64 256))
           (cluster-size :set-to (2 1) :msg "share the B tile across the row pair"))
  ...
  (load-tile B (ring-get B-ring slot) (grid-x grid-k) :barrier b-bar :multicast true)
  ...)
```


