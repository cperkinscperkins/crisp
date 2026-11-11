"""B200 timing breakdown of the v6 path (see package_matmul.make_diag).  Writes diag_b200_sub.py.

Arms: the whole v6 path (transpose + tcgen05 kernel), the transpose alone, the kernel alone on a
pre-transposed B, and torch.matmul (cuBLAS) -- how much of v6's time is the per-call transpose?"""
from package_matmul import KernelSpec, build_kernel, make_diag, SMALL, B200_TC, TRANSPOSE

ks = {"small": build_kernel(KernelSpec(**SMALL)), "b200tc": build_kernel(KernelSpec(**B200_TC)),
      "transpose": build_kernel(KernelSpec(**TRANSPOSE))}
ARMS = '''
    _load("b200tc", PTX_B200TC)
    _load("transpose", PTX_TRANSPOSE)
    def DIAG_ARMS(a2, b2, c2):
        bt = _bt_buffer(b2)
        def full():
            _mod.run_transpose(b2, b2, bt)
            _mod.run_b200tc(a2, bt, c2)
        def tr_check():
            _mod.run_transpose(b2, b2, bt)
            if not torch.equal(b2.t().contiguous(), bt):
                raise RuntimeError("crisp transpose WRONG")
        def torch_tr():
            bt.copy_(b2.t())
        return [
            ("full_v6", full, True),
            ("crisp_transpose", lambda: _mod.run_transpose(b2, b2, bt), False),
            ("torch_transpose_copy", torch_tr, False),
            ("tr_exact", tr_check, False),
            ("kernel_only", lambda: _mod.run_b200tc(a2, bt, c2), True),
            ("torch", lambda: torch.matmul(a2, b2), False),
        ]
'''
make_diag("diag_b200_sub.py", ks, ARMS, [(4096, 5120, 4096, 123456), (8192, 8192, 8192, 32412)],
          ["matmul_b200_tcgen05.crisp", "transpose_b.crisp"])
