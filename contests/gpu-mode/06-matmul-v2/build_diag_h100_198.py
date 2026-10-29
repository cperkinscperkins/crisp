"""H100 check for endeavour 198 (wgmma transB).  Writes diag_h100_198_sub.py.

  v2path  Crisp transpose + 2wg_deep reading the (N K) copy -- today's entry (with 197's packed stores)
  tb      matmul_h100_2wg_transb reading the contest's (K N) b directly.  Exact-checked (C zeroed).
"""
from package_matmul import KernelSpec, build_kernel, make_diag, H100_2WG, H100_TRANSB, TRANSPOSE

ARMS = '''
    _load("h100_2wg", PTX_H100_2WG)
    _load("h100tb", PTX_H100TB)
    _load("transpose", PTX_TRANSPOSE)
    def DIAG_ARMS(a2, b2, c2):
        bt = _bt_buffer(b2)
        def v2path():
            _mod.run_transpose(b2, b2, bt)
            _mod.run_h100_2wg(a2, bt, c2)
        def tb_fresh():
            c2.zero_()
            _mod.run_h100tb(a2, b2, c2)
        return [
            ("v2path", v2path, True),
            ("tb", lambda: _mod.run_h100tb(a2, b2, c2), False),
            ("tb_chk", tb_fresh, True),
            ("torch", lambda: torch.matmul(a2, b2), False),
        ]
'''

if __name__ == "__main__":
    ks = {"h100": build_kernel(KernelSpec(**H100_2WG)), "tb": build_kernel(KernelSpec(**H100_TRANSB)),
          "transpose": build_kernel(KernelSpec(**TRANSPOSE))}
    make_diag("diag_h100_198_sub.py", ks, ARMS, [(4096, 5120, 4096, 123456), (2048, 3072, 2048, 32412)],
              ["matmul_h100_2wg_transb.crisp"])
