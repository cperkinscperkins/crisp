# Phase 0 — paper verification (no code)

Two facts carry the design.  Both are answerable by reading the PTX ISA spec; neither needs
hardware.  **Do these before writing any lowering** — each one changes what gets built.

---

## Q1. Does a TMA multicast complete on each destination CTA's own mbarrier, or only the issuer's?

**Why it is load-bearing.**  The whole `:mode` ladder rests on this.  We concluded that the
data-arrival ring (`full`) stays `:mode :block` — a *workgroup-local* mbarrier — even in a
clustered kernel, because each destination CTA waits on a barrier it owns and the TMA hardware
credits that barrier as its copy lands.  Evidence for the local reading is already in our own
codegen: [src/codegen.lisp:3475](../../../src/codegen.lisp) emits
`mbarrier.arrive.expect_tx.shared::cta` and :3484 emits `mbarrier.try_wait.parity.shared::cta`.

**If the answer is "issuer only":** destination CTAs need some other notification, `full` can no
longer be `:block`, and the `:linear < :block < :cluster` ladder loses its middle rung's meaning.
The `:mode` doc section and the `cluster-size` section both need rewriting before implementation.

Read: PTX ISA `cp.async.bulk.tensor` with `.multicast::cluster` — specifically which state space
the `[mbar]` operand is interpreted in, and whether the transaction-byte completion is per-CTA.

**FINDING:**

**DATE / SOURCE:**

---

## Q2. Does `barrier.cluster.arrive` subsume intra-CTA thread convergence?

**Why it is load-bearing.**  `topology.md` now states as fact that with cluster count 1,
`sync-cluster` is *"functionally exactly the same as `sync-workgroup`"*.  That holds only if the
cluster barrier also rendezvouses the threads **within** a CTA.

**If the answer is no:** the fused `(sync-cluster)` must emit an implicit `sync-workgroup`
alongside the cluster barrier, the degrade story changes, and the sentence in `topology.md` is
wrong as written.

Read: PTX ISA `barrier.cluster.arrive` / `.wait` — participation requirements, and whether the
`.aligned` qualifier implies CTA-wide convergence or only warp-wide.

**FINDING:**

**DATE / SOURCE:**

---

## Also worth settling on paper while here

- **Portable cluster maximum.**  8 is solid.  16-on-Hopper and the exact opt-in mechanism
  (`cudaFuncAttributeNonPortableClusterSizeAllowed`?) are hedged in `topology.md` and should be
  confirmed before that text hardens.
- **Grid divisibility.**  Confirm the driver actually *requires* `gridDim % clusterDim == 0`
  rather than merely recommending it.  The `:strided`-pads / `:exact`-errors policy in
  `topology.md` is currently marked an open decision and this is the fact it turns on.
