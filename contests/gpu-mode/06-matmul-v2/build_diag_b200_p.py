"""B200 A/B: v7 (tile grid, 2 workgroups per SM) vs a persistent v7 (148 workgroups, 2-slot accumulator ring,
TMA ring 4).  Writes diag_b200_p_sub.py."""
from package_matmul import KernelSpec, build_kernel, make_diag, SMALL, B200_TCMN
PERS = dict(B200_TCMN, key="b200mnp", crisp="matmul_b200_tcgen05_mn_p.crisp")
ks = {"small": build_kernel(KernelSpec(**SMALL)), "b200mn": build_kernel(KernelSpec(**B200_TCMN)),
      "b200mnp": build_kernel(KernelSpec(**PERS))}
ARMS = '''
    _load("b200mn", PTX_B200MN)
    _load("b200mnp", PTX_B200MNP)
    def DIAG_ARMS(a2, b2, c2):
        return [
            ("v7_tilegrid", lambda: _mod.run_b200mn(a2, b2, c2), True),
            ("persistent", lambda: _mod.run_b200mnp_grid(a2, b2, c2, 148, 1), True),
            ("torch", lambda: torch.matmul(a2, b2), False),
        ]
'''
make_diag("diag_b200_p_sub.py", ks, ARMS, [(4096, 5120, 4096, 123456), (8192, 8192, 8192, 32412)],
          ["matmul_b200_tcgen05_mn.crisp", "matmul_b200_tcgen05_mn_p.crisp"])
