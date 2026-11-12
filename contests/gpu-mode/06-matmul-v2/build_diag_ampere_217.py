"""Endeavour 217 step 1 (probe): A100 / L4 -- price the shared-memory bank conflicts left by 216.
ring3 = matmul_ampere_4w_ring.crisp on today's compiler (ldmatrix, unswizzled tiles); ring3swz = the same
kernel through put_temp_files_here/217/cc_swz.bat, which XOR-swizzles the 16-byte chunks of its scratch
tiles on both the cp.async writer and the ldmatrix reader.  Same PTX otherwise (instruction counts equal
but for the swizzle's xor).  Exactness of ring3swz is the probe's correctness guard.
Writes diag_ampere_217_sub.py."""
import package_matmul as pm
from package_matmul import KernelSpec, build_kernel, make_diag, SMALL, AMPERE4W

AMPRING = dict(AMPERE4W, key="ampring", crisp="matmul_ampere_4w_ring.crisp", k_step=32)
ks = {"small": build_kernel(KernelSpec(**SMALL)),
      "ampring": build_kernel(KernelSpec(**AMPRING))}
SWZ = pm.REPO_ROOT / "put_temp_files_here" / "217" / "cc_swz.bat"
saved, pm.CRISP_COMPILE = pm.CRISP_COMPILE, SWZ
ks["ampringswz"] = build_kernel(KernelSpec(**dict(AMPRING, key="ampringswz")))
pm.CRISP_COMPILE = saved
for k, s in ks.items():
    ptx = s[0] if isinstance(s, tuple) else getattr(s, "ptx", "")
    print(k, "xor.b" in ptx if ptx else "?")
ARMS = '''
    _load("ampring", PTX_AMPRING)
    _load("ampringswz", PTX_AMPRINGSWZ)
    def DIAG_ARMS(a2, b2, c2):
        return [
            ("ring3", lambda: _mod.run_ampring(a2, b2, c2), True),
            ("ring3swz", lambda: _mod.run_ampringswz(a2, b2, c2), True),
            ("torch", lambda: torch.matmul(a2, b2), False),
        ]
'''
make_diag("diag_ampere_217_sub.py", ks, ARMS, [(4096, 5120, 4096, 123456), (2048, 3072, 2048, 32412)],
          ["matmul_ampere_4w_ring.crisp"])
