"""H100 probe 3: does running the SAME kernel persistently help?  Writes diag_h100_probe3_sub.py.

2wg_deep is a tile-stride kernel, and its ring-barrier parity counter runs across tiles, so launching fewer
CTAs than tiles makes each CTA walk several tiles (run_<k>_grid).  While the consumers run a tile's
epilogue, the producer warp is free to fill the ring for the NEXT tile -- the prologue fill and the CTA
launch stop being exposed; the epilogue itself still is (no ping-pong).

  pers      grid = the largest (gx, gy) dividing the tile grid evenly with gx*gy <= 132 (H100 SXM SMs):
            4096x5120 -> 32x4 = 128 CTAs x 5 tiles; 2048x3072 -> 16x6 = 96 CTAs x 2 tiles.  Exact-checked.
  pk_pers   the same, with probe 2's packed half2 stores.
"""
import dataclasses

from package_matmul import KernelSpec, build_kernel, make_diag, H100_2WG, TRANSPOSE
from build_diag_h100_probe2 import packed

ARMS = '''
    for _k, _p in (("h100_2wg", PTX_H100_2WG), ("h100pk", PTX_H100PK), ("transpose", PTX_TRANSPOSE)):
        _load(_k, _p)
    def DIAG_ARMS(a2, b2, c2):
        bt = _bt_buffer(b2)
        _mod.run_transpose(b2, b2, bt)
        torch.cuda.synchronize()
        tx, ty = a2.size(0) // 128, c2.size(1) // 256
        gx, gy = max(((x, y) for x in range(1, tx + 1) if tx % x == 0
                      for y in range(1, ty + 1) if ty % y == 0 and x * y <= 132), key=lambda g: g[0] * g[1])
        def fresh(run):
            def f():
                c2.zero_()
                run()
            return f
        pers = lambda: _mod.run_h100_2wg_grid(a2, bt, c2, gx, gy)
        pk_pers = lambda: _mod.run_h100pk_grid(a2, bt, c2, gx, gy)
        return [
            (f"grid{gx}x{gy}", lambda: None, False),
            ("kernel", lambda: _mod.run_h100_2wg(a2, bt, c2), False),
            ("pers", pers, False),
            ("pk", lambda: _mod.run_h100pk(a2, bt, c2), False),
            ("pk_pers", pk_pers, False),
            ("pers_chk", fresh(pers), True),
            ("pk_pers_chk", fresh(pk_pers), True),
            ("torch", lambda: torch.matmul(a2, b2), False),
        ]
'''

if __name__ == "__main__":
    base = build_kernel(KernelSpec(**H100_2WG))
    pk = dataclasses.replace(base, key="h100pk", ptx=packed(base.ptx))
    ks = {"h100": base, "pk": pk, "transpose": build_kernel(KernelSpec(**TRANSPOSE))}
    make_diag("diag_h100_probe3_sub.py", ks, ARMS, [(4096, 5120, 4096, 123456), (2048, 3072, 2048, 32412)],
              ["matmul_h100_2wg_deep.crisp"])
