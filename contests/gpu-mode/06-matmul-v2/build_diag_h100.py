"""H100 timing breakdown (see package_matmul.make_diag).  Writes diag_h100_sub.py."""
from package_matmul import KernelSpec, build_kernel, make_diag, SMALL, H100_2WG, TRANSPOSE

ks = {"small": build_kernel(KernelSpec(**SMALL)), "h100": build_kernel(KernelSpec(**H100_2WG)),
      "transpose": build_kernel(KernelSpec(**TRANSPOSE))}
ARMS = '''
    _load("h100_2wg", PTX_H100_2WG)
    _load("transpose", PTX_TRANSPOSE)
    def DIAG_ARMS(a2, b2, c2):
        bt = _bt_buffer(b2)
        def full():
            _mod.run_transpose(b2, b2, bt)
            _mod.run_h100_2wg(a2, bt, c2)
        def tr_check():
            _mod.run_transpose(b2, b2, bt)
            ref = b2.t().contiguous()
            if not torch.equal(ref, bt):
                raise RuntimeError("crisp transpose WRONG")
        return [
            ("full_crisp_tr", full, True),
            ("crisp_transpose", lambda: _mod.run_transpose(b2, b2, bt), False),
            ("tr_exact", tr_check, False),
            ("kernel", lambda: _mod.run_h100_2wg(a2, bt, c2), True),
            ("torch", lambda: torch.matmul(a2, b2), False),
        ]
'''
make_diag("diag_h100_sub.py", ks, ARMS, [(4096, 5120, 4096, 123456), (2048, 3072, 2048, 32412)],
          ["matmul_h100_2wg_deep.crisp", "transpose_b.crisp"])
