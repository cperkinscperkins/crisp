"""A100 / L4: 1-warp 64x64 vs 4-warp 128x128 cp.async kernels.  Writes diag_ampere_sub.py."""
from package_matmul import KernelSpec, build_kernel, make_diag, SMALL, AMPERE

A4 = dict(AMPERE, key="ampere4w", crisp="matmul_ampere_4w.crisp", tile=(128, 128))
ks = {"small": build_kernel(KernelSpec(**SMALL)), "ampere": build_kernel(KernelSpec(**AMPERE)),
      "ampere4w": build_kernel(KernelSpec(**A4))}
ARMS = '''
    _load("ampere", PTX_AMPERE)
    _load("ampere4w", PTX_AMPERE4W)
    def DIAG_ARMS(a2, b2, c2):
        return [
            ("ampere_1w", lambda: _mod.run_ampere(a2, b2, c2), True),
            ("ampere_4w", lambda: _mod.run_ampere4w(a2, b2, c2), True),
            ("torch", lambda: torch.matmul(a2, b2), False),
        ]
'''
make_diag("diag_ampere_sub.py", ks, ARMS, [(4096, 5120, 4096, 123456), (2048, 3072, 2048, 32412)],
          ["matmul_ampere_cp_async.crisp", "matmul_ampere_4w.crisp"])
