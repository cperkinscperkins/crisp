"""Endeavour 215 metal check (2026-11-11): v7 and the 128 x 128 tile built by the compiler with 16-byte tcgen05
epilogue stores, plus the two fallback arms forced by a misaligned C: a contiguous C carved out of a larger
buffer at +1 half (2 bytes: neither 16- nor 4-byte aligned -> the scalar arm) and +2 halves (4 bytes:
the 197 pair arm).  Each misaligned arm writes its view and copies it into c2 for the exactness check.
Writes diag_b200_215_sub.py."""
from package_matmul import KernelSpec, build_kernel, make_diag, SMALL, B200_TCMN
ks = {"small": build_kernel(KernelSpec(**SMALL)), "b200mn": build_kernel(KernelSpec(**B200_TCMN)),
      "n128r2": build_kernel(KernelSpec(**dict(B200_TCMN, key="n128r2", tile=(128, 128),
                                                crisp="matmul_b200_tcgen05_mn_n128_r2.crisp")))}
ARMS = '''
    for _k in ("b200mn", "n128r2"):
        _load(_k, globals()["PTX_" + _k.upper()])
    def DIAG_ARMS(a2, b2, c2):
        n = c2.numel()
        buf = torch.empty(n + 16, dtype=c2.dtype, device=c2.device)
        c_off1 = buf[1:1 + n].view(c2.shape)      # 2-byte aligned: scalar arm
        c_off2 = buf[2:2 + n].view(c2.shape)      # 4-byte aligned: pair arm
        return [
            ("v7", lambda: _mod.run_b200mn(a2, b2, c2), True),
            ("v7_c+2B", lambda: (_mod.run_b200mn(a2, b2, c_off1), c2.copy_(c_off1)), True),
            ("v7_c+4B", lambda: (_mod.run_b200mn(a2, b2, c_off2), c2.copy_(c_off2)), True),
            ("n128", lambda: _mod.run_n128r2(a2, b2, c2), True),
            ("torch", lambda: torch.matmul(a2, b2), False),
        ]
'''
make_diag("diag_b200_215_sub.py", ks, ARMS,
          [(4096, 5120, 4096, 123456), (9472, 2048, 4096, 777), (8192, 8192, 8192, 32412)],
          ["matmul_b200_tcgen05_mn.crisp", "matmul_b200_tcgen05_mn_n128_r2.crisp"])
