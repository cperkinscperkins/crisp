"""B200 A/B of the v7 kernel's epilogue: direct stores vs :via :tma.  Writes diag_b200_v7_sub.py."""
from package_matmul import KernelSpec, build_kernel, make_diag, SMALL, B200_TCMN

TMA = dict(B200_TCMN, key="b200mntma", crisp="matmul_b200_tcgen05_mn_tma.crisp")
ks = {"small": build_kernel(KernelSpec(**SMALL)), "b200mn": build_kernel(KernelSpec(**B200_TCMN)),
      "b200mntma": build_kernel(KernelSpec(**TMA))}
ARMS = '''
    _load("b200mn", PTX_B200MN)
    _load("b200mntma", PTX_B200MNTMA)
    def DIAG_ARMS(a2, b2, c2):
        return [
            ("v7_direct", lambda: _mod.run_b200mn(a2, b2, c2), True),
            ("v7_tma", lambda: _mod.run_b200mntma(a2, b2, c2), True),
            ("torch", lambda: torch.matmul(a2, b2), False),
        ]
'''
make_diag("diag_b200_v7_sub.py", ks, ARMS, [(4096, 5120, 4096, 123456), (8192, 8192, 8192, 32412)],
          ["matmul_b200_tcgen05_mn.crisp", "matmul_b200_tcgen05_mn_tma.crisp"])
