"""Wave-quantization probe (2026-11-11; run make_n128.py first -- it regenerates the probe kernels this reads).
Writes diag_b200_n128_sub.py."""
from package_matmul import KernelSpec, build_kernel, make_diag, SMALL, B200_TCMN
ks = {"small": build_kernel(KernelSpec(**SMALL)), "b200mn": build_kernel(KernelSpec(**B200_TCMN))}
for key, tile, crisp in (("n128r2", (128, 128), "matmul_b200_tcgen05_mn_n128_r2.crisp"),
                         ("v7p296", (128, 256), "matmul_b200_tcgen05_mn_p296.crisp"),
                         ("n128p444", (128, 128), "matmul_b200_tcgen05_mn_n128_r2_p444.crisp")):
    ks[key] = build_kernel(KernelSpec(**dict(B200_TCMN, key=key, tile=tile, crisp=crisp)))
ARMS = '''
    for _k in ("b200mn", "n128r2", "v7p296", "n128p444"):
        _load(_k, globals()["PTX_" + _k.upper()])
    def DIAG_ARMS(a2, b2, c2):
        return [
            ("v7", lambda: _mod.run_b200mn(a2, b2, c2), True),
            ("n128_r2", lambda: _mod.run_n128r2(a2, b2, c2), True),
            ("v7_p296", lambda: _mod.run_v7p296_grid(a2, b2, c2, 296, 1), True),
            ("n128_p444", lambda: _mod.run_n128p444_grid(a2, b2, c2, 444, 1), True),
            ("torch", lambda: torch.matmul(a2, b2), False),
        ]
'''
make_diag("diag_b200_n128_sub.py", ks, ARMS,
          [(4096, 5120, 4096, 123456), (9472, 2048, 4096, 777), (8192, 8192, 8192, 32412)],
          ["matmul_b200_tcgen05_mn.crisp", "matmul_b200_tcgen05_mn_n128_r2.crisp", "matmul_b200_tcgen05_mn_p296.crisp", "matmul_b200_tcgen05_mn_n128_r2_p444.crisp"])
