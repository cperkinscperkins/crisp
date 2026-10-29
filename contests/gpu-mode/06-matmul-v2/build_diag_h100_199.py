"""H100 check for endeavour 199 (store-tile-at ... :via :tma).  Writes diag_h100_199_sub.py.

  tb     matmul_h100_2wg_transb -- v4 as ranked (packed st.global.v2.b16 epilogue)
  tma    matmul_h100_2wg_tma -- the same kernel with both stores :via :tma (compiler-emitted
         stmatrix + TMA store).  Exact-checked in tma_chk (C zeroed first).
  tbe    probe 4's hand-edited PTX of tb (build_diag_h100_probe4.py) -- what the compiler should match.
"""
from package_matmul import KernelSpec, build_kernel, make_diag, H100_TRANSB, H100_TMA
from build_diag_h100_probe4 import tbe_spec

ARMS = '''
    for _k, _p in (("h100tb", PTX_H100TB), ("h100tma", PTX_H100TMA), ("h100tbe", PTX_H100TBE)):
        _load(_k, _p)
    def DIAG_ARMS(a2, b2, c2):
        def fresh(run):
            def f():
                c2.zero_()
                run()
            return f
        tma = lambda: _mod.run_h100tma(a2, b2, c2)
        return [
            ("tb", lambda: _mod.run_h100tb(a2, b2, c2), False),
            ("tma", tma, False),
            ("tbe", lambda: _mod.run_h100tbe(a2, b2, c2), False),
            ("tma_chk", fresh(tma), True),
            ("torch", lambda: torch.matmul(a2, b2), False),
        ]
'''

if __name__ == "__main__":
    tb = build_kernel(KernelSpec(**H100_TRANSB))
    tma = build_kernel(KernelSpec(**H100_TMA))
    print(f"  h100tma smem={tma.smem} (tb {tb.smem}); tensormaps={[t['name'] for t in tma.tensormaps]}")
    make_diag("diag_h100_199_sub.py", {"tb": tb, "tma": tma, "tbe": tbe_spec(tb)}, ARMS,
              [(4096, 5120, 4096, 123456), (2048, 3072, 2048, 32412)], ["matmul_h100_2wg_tma.crisp"])
