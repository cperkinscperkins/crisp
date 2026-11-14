"""Endeavour 216: A100 / L4 A/B of ldmatrix fragment loads in the 4-warp mma.sync kernel.
k16 / k32 = today's compiler (ldmatrix.x4 for A, ldmatrix.x2.trans for B); k32off = the same compiler with
*216-ldmatrix* off (put_temp_files_here/216/cc_off.bat), i.e. the per-element ld.shared.b16 twin.
Writes diag_ampere_216_sub.py."""
from pathlib import Path
import package_matmul as pm
from package_matmul import KernelSpec, build_kernel, make_diag, SMALL, AMPERE4W, AMPERE4W_K32

ks = {"small": build_kernel(KernelSpec(**SMALL)),
      "ampere4w": build_kernel(KernelSpec(**AMPERE4W)),
      "ampk32": build_kernel(KernelSpec(**AMPERE4W_K32))}
OFF = pm.REPO_ROOT / "put_temp_files_here" / "216" / "cc_off.bat"
if OFF.exists():
    saved, pm.CRISP_COMPILE = pm.CRISP_COMPILE, OFF
    ks["ampk32off"] = build_kernel(KernelSpec(**dict(AMPERE4W_K32, key="ampk32off")))
    pm.CRISP_COMPILE = saved
for k, s in ks.items():
    print(k, "ldmatrix" in s.ptx if hasattr(s, "ptx") else "?")
ARMS = '''
    _load("ampere4w", PTX_AMPERE4W)
    _load("ampk32", PTX_AMPK32)
    _load("ampk32off", PTX_AMPK32OFF)
    def DIAG_ARMS(a2, b2, c2):
        return [
            ("k16ldm", lambda: _mod.run_ampere4w(a2, b2, c2), True),
            ("k32ldm", lambda: _mod.run_ampk32(a2, b2, c2), True),
            ("k32off", lambda: _mod.run_ampk32off(a2, b2, c2), True),
            ("torch", lambda: torch.matmul(a2, b2), False),
        ]
'''
make_diag("diag_ampere_216_sub.py", ks, ARMS, [(4096, 5120, 4096, 123456), (2048, 3072, 2048, 32412)],
          ["matmul_ampere_4w_k32.crisp"])
