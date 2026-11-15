"""Smoke test of an INSTALLED crisp-gpu (scripts/test-wheel.sh runs it in clean containers; no GPU).

Checks: import, a PTX and a SPIR-V compile from a string, the kernel/parameter description, a
--differentiate compile's gradient pairing, a CompileError carrying diagnostics, and the
crisp-compile console script (including --hoist=cuda, which needs crisp-gpu-hoist) run from a
directory that is not the install root.
"""
import os
import subprocess
import sys
import tempfile

import crisp_gpu

SRC = """
(def-type vec-t (vector float :address-space :global :align :compact))

(def-kernel square_scale (X W &out Y)
  (declare #'(vec-t vec-t &out vec-t => nil)
           (global-size :derive-from X :strategy :one-thread-per)
           (local-size  :set-to 256))
  (loop-vector-stride X (i)
    (set! (~ Y i) (* (~ X i) (~ X i) (~ W i)))))
"""
fails = []


def check(cond, what):
    print(("ok    " if cond else "FAIL  ") + what)
    if not cond:
        fails.append(what)


print(f"crisp_gpu {crisp_gpu.__version__} at {os.path.dirname(crisp_gpu.__file__)}")

ptx = crisp_gpu.compile(SRC, target="ptx", flags=["--ir-target-arch=sm_80"])
check(b".target sm_80" in ptx.binary and b".entry" in ptx.binary, "PTX compile")
k = ptx.kernel("square_scale")
check([p.name.lower() for p in k.params] == ["x", "w", "y"], f"params {[p.name for p in k.params]}")
check(k.param("y").direction == "out" and k.param("x").element_type == "float"
      and k.param("x").kind == "tensor" and k.param("x").rank == 1, f"param facts {k.param('y')}")

spv = crisp_gpu.compile(SRC, target="spv")
check(spv.binary[:4] == b"\x03\x02\x23\x07", "SPIR-V compile (magic number)")

ad = crisp_gpu.compile(SRC, target="ptx", flags=["--differentiate"])
g = ad.grad_kernel("square_scale")
adj = {p.name.lower(): (p.direction, p.adjoint_of and p.adjoint_of.lower()) for p in g.params}
check(len(ad.kernels) == 2 and any(v == ("in", "y") for v in adj.values())
      and any(v == ("out", "x") for v in adj.values()), f"--differentiate pairing {g.name} {adj}")

try:
    crisp_gpu.compile("(def-kernel broken (X) (declare #'(int => nil)) (set! Q 1))")
    check(False, "CompileError raised")
except crisp_gpu.CompileError as e:
    check(bool(e.diagnostics) and e.diagnostics[0].severity == "error", f"CompileError: {e.diagnostics[0].message[:60]!r}")

with tempfile.TemporaryDirectory() as d:
    with open(os.path.join(d, "k.crisp"), "w") as f:
        f.write(SRC)
    r = subprocess.run(["crisp-compile", "--ir-target=ptx", "--hoist=cuda", "k.crisp"], cwd=d,
                       capture_output=True, text=True)
    out = sorted(os.listdir(d))
    check(r.returncode == 0 and "k.ptx" in out and any(n.endswith(".cu") for n in out),
          f"crisp-compile CLI + CUDA hoist from {d}: rc={r.returncode} {out} {r.stderr[-300:] if r.returncode else ''}")

crisp_gpu.shutdown()
print("WHEEL-SMOKE: " + ("PASS" if not fails else f"FAIL ({len(fails)})"))
sys.exit(1 if fails else 0)
