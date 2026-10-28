"""H100 check for endeavour 197 (packed accumulator stores).  Writes diag_h100_197_sub.py.

  old    the pre-197 PTX (_build/pre197_2wg_deep.ptx, scalar st.global.b16) -- same ABI
  new    2wg_deep as the compiler now emits it (st.global.v2.b16 pairs under %pair-ok-p).  Exact-checked.
  probe  build_diag_h100_probe2's hand-packed PTX -- what the compiler should match
"""
import dataclasses
from pathlib import Path

from package_matmul import KernelSpec, build_kernel, make_diag, H100_2WG, TRANSPOSE
from build_diag_h100_probe2 import packed

ARMS = '''
    for _k, _p in (("h100_2wg", PTX_H100_2WG), ("h100old", PTX_H100OLD), ("h100pk", PTX_H100PK),
                   ("transpose", PTX_TRANSPOSE)):
        _load(_k, _p)
    def DIAG_ARMS(a2, b2, c2):
        bt = _bt_buffer(b2)
        _mod.run_transpose(b2, b2, bt)
        torch.cuda.synchronize()
        def fresh(run):
            def f():
                c2.zero_()
                run(a2, bt, c2)
            return f
        return [
            ("old", lambda: _mod.run_h100old(a2, bt, c2), False),
            ("new", lambda: _mod.run_h100_2wg(a2, bt, c2), False),
            ("probe_pk", lambda: _mod.run_h100pk(a2, bt, c2), False),
            ("new_chk", fresh(_mod.run_h100_2wg), True),
            ("torch", lambda: torch.matmul(a2, b2), False),
        ]
'''

if __name__ == "__main__":
    new = build_kernel(KernelSpec(**H100_2WG))
    old_ptx = (Path(__file__).parent / "_build" / "pre197_2wg_deep.ptx").read_text(encoding="utf-8")
    old = dataclasses.replace(new, key="h100old", ptx=old_ptx)
    pk = dataclasses.replace(new, key="h100pk", ptx=packed(old_ptx))
    ks = {"h100": new, "old": old, "pk": pk, "transpose": build_kernel(KernelSpec(**TRANSPOSE))}
    make_diag("diag_h100_197_sub.py", ks, ARMS, [(4096, 5120, 4096, 123456), (2048, 3072, 2048, 32412)],
              ["matmul_h100_2wg_deep.crisp"])
