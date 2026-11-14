"""Endeavour 216 diag 2: A100 / L4 -- the ldmatrix K32 kernel vs the 3-stage cp.async ring kernel
(matmul_ampere_4w_ring.crisp).  Writes diag_ampere_216b_sub.py."""
from package_matmul import KernelSpec, build_kernel, make_diag, SMALL, AMPERE4W, AMPERE4W_K32

AMPRING = dict(AMPERE4W, key="ampring", crisp="matmul_ampere_4w_ring.crisp", k_step=32)
ks = {"small": build_kernel(KernelSpec(**SMALL)),
      "ampk32": build_kernel(KernelSpec(**AMPERE4W_K32)),
      "ampring": build_kernel(KernelSpec(**AMPRING))}
ARMS = '''
    _load("ampk32", PTX_AMPK32)
    _load("ampring", PTX_AMPRING)
    def DIAG_ARMS(a2, b2, c2):
        return [
            ("k32ldm", lambda: _mod.run_ampk32(a2, b2, c2), True),
            ("ring3", lambda: _mod.run_ampring(a2, b2, c2), True),
            ("torch", lambda: torch.matmul(a2, b2), False),
        ]
'''
make_diag("diag_ampere_216b_sub.py", ks, ARMS, [(4096, 5120, 4096, 123456), (2048, 3072, 2048, 32412)],
          ["matmul_ampere_4w_ring.crisp"])
