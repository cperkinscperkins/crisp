"""Endeavour 214 step 1c: the full-barrier arrive.  pair.ptx has BOTH producers arrive remotely on the
leader's full[slot] with .release.cluster (2 per CTA per k step, count 4).  Two arms:
  pairL.ptx  CUTLASS's way: only the leader arrives, locally, expecting both CTAs' bytes (2 x 32 KB);
             the peer's TMA just completes on the leader's barrier; count back to 2.
  pairX.ptx  same remote arrives, but .relaxed.cluster (no cluster-scope release)."""
import sys

base = open("pair.ptx").read()
REMOTE = "\tmbarrier.arrive.expect_tx.release.cluster.shared::cluster.b64 _, [%qd1], 16384;\n"


def check(src, old, count):
    n = src.count(old)
    if n != count:
        sys.exit(f"expected {count} x {old!r}, found {n}")


check(base, REMOTE, 2)
check(base, "\tmov.b32 \t%r314, 4;\n", 1)
L = base.replace(REMOTE, "\t@%qp1 mbarrier.arrive.expect_tx.shared::cta.b64 _, [%rd99], 32768;\n")
L = L.replace("\tmov.b32 \t%r314, 4;\n", "\tmov.b32 \t%r314, 2;\n")
open("pairL.ptx", "w", newline="\n").write(L)
X = base.replace(REMOTE, REMOTE.replace(".release.cluster", ".relaxed.cluster"))
open("pairX.ptx", "w", newline="\n").write(X)
print("wrote pairL.ptx pairX.ptx")
