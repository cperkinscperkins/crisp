"""A100 / L4 check for endeavour 197 (packed mma.sync fragment stores).  Writes diag_ampere_197_sub.py.

  old   the pre-197 4-warp PTX (_build/pre197_ampere_4w.ptx: 128 scalar st.global.b16) -- same ABI
  new   matmul_ampere_4w as the compiler now emits it (st.global.v2.b16 pairs, per-fragment guard).
        Exact-checked (C zeroed first).
"""
import dataclasses
from pathlib import Path

from package_matmul import KernelSpec, build_kernel, make_diag, AMPERE

A4 = dict(AMPERE, key="ampere4w", crisp="matmul_ampere_4w.crisp", tile=(128, 128))

ARMS = '''
    _load("ampere4w", PTX_AMPERE4W)
    _load("ampere4wold", PTX_AMPERE4WOLD)
    def DIAG_ARMS(a2, b2, c2):
        def fresh(run):
            def f():
                c2.zero_()
                run(a2, b2, c2)
            return f
        return [
            ("old", lambda: _mod.run_ampere4wold(a2, b2, c2), False),
            ("new", lambda: _mod.run_ampere4w(a2, b2, c2), False),
            ("new_chk", fresh(_mod.run_ampere4w), True),
            ("torch", lambda: torch.matmul(a2, b2), False),
        ]
'''

if __name__ == "__main__":
    new = build_kernel(KernelSpec(**A4))
    old_ptx = (Path(__file__).parent / "_build" / "pre197_ampere_4w.ptx").read_text(encoding="utf-8")
    old = dataclasses.replace(new, key="ampere4wold", ptx=old_ptx)
    make_diag("diag_ampere_197_sub.py", {"new": new, "old": old}, ARMS,
              [(4096, 5120, 4096, 123456), (2048, 3072, 2048, 32412)], ["matmul_ampere_4w.crisp"])
