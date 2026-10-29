"""H100: 2wg_deep vs 2wg_deep + 2x2 cluster TMA multicast.  Writes diag_h100_mc_sub.py."""
from package_matmul import KernelSpec, build_kernel, make_diag, SMALL, H100_2WG, TRANSPOSE

MC = dict(H100_2WG, key="h100_mc", crisp="matmul_h100_2wg_mc.crisp")
ks = {"small": build_kernel(KernelSpec(**SMALL)), "h100": build_kernel(KernelSpec(**H100_2WG)),
      "mc": build_kernel(KernelSpec(**MC)), "transpose": build_kernel(KernelSpec(**TRANSPOSE))}
ARMS = '''
    _load("h100_2wg", PTX_H100_2WG)
    _load("h100_mc", PTX_H100_MC)
    _load("transpose", PTX_TRANSPOSE)
    def DIAG_ARMS(a2, b2, c2):
        bt = _bt_buffer(b2)
        _mod.run_transpose(b2, b2, bt)
        return [
            ("kernel_2wg", lambda: _mod.run_h100_2wg(a2, bt, c2), True),
            ("kernel_mc",  lambda: _mod.run_h100_mc(a2, bt, c2), True),
        ]
'''
make_diag("diag_h100_mc_sub.py", ks, ARMS, [(4096, 5120, 4096, 123456), (2048, 3072, 2048, 32412)],
          ["matmul_h100_2wg_mc.crisp"])
