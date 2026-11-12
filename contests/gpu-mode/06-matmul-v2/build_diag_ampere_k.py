"""A100 / L4 A/B of the 4-warp mma.sync kernel's K tile: 16 (v5) vs 32 vs 64 per cp.async stage.
Writes diag_ampere_k_sub.py."""
from package_matmul import KernelSpec, build_kernel, make_diag, SMALL, AMPERE4W

ks = {"small": build_kernel(KernelSpec(**SMALL)), "ampere4w": build_kernel(KernelSpec(**AMPERE4W))}
for kt in (32, 64):
    ks[f"ampk{kt}"] = build_kernel(KernelSpec(**dict(AMPERE4W, key=f"ampk{kt}", crisp=f"matmul_ampere_4w_k{kt}.crisp",
                                                     k_step=kt)))
ARMS = '''
    _load("ampere4w", PTX_AMPERE4W)
    _load("ampk32", PTX_AMPK32)
    _load("ampk64", PTX_AMPK64)
    def DIAG_ARMS(a2, b2, c2):
        return [
            ("k16", lambda: _mod.run_ampere4w(a2, b2, c2), True),
            ("k32", lambda: _mod.run_ampk32(a2, b2, c2), True),
            ("k64", lambda: _mod.run_ampk64(a2, b2, c2), True),
            ("torch", lambda: torch.matmul(a2, b2), False),
        ]
'''
make_diag("diag_ampere_k_sub.py", ks, ARMS, [(4096, 5120, 4096, 123456), (2048, 3072, 2048, 32412)],
          ["matmul_ampere_4w_k64.crisp"])
