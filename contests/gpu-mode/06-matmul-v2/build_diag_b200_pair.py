"""Endeavour 214 step 1: B200 A/B of v7 against v7's PTX hand-edited to cta_group::2 (an SM pair per
256 x 256 output block; put_temp_files_here/214/make_pair_ptx.py).  Same launch ABI and grid as v7; the
PTX's .reqnctapercluster 2, 1, 1 makes the plain cuLaunchKernel launch pairs.  Writes diag_b200_pair_sub.py."""
import copy
from package_matmul import KernelSpec, build_kernel, make_diag, SMALL, B200_TCMN

v7 = build_kernel(KernelSpec(**B200_TCMN))
pair = copy.deepcopy(v7)
pair.key = "b200pair"
pair.ptx = open("../../../put_temp_files_here/214/pair.ptx").read()
rings = {}
for V, R in (("L", 2), ("LR3", 3), ("LR4", 4), ("LR6", 6)):
    r = copy.deepcopy(v7); r.key = f"b200p{V.lower()}"; r.smem = max(R * 32768, v7.smem)
    r.ptx = open(f"../../../put_temp_files_here/214/pair{V}.ptx").read(); rings[r.key] = r
ks = {**rings, "small": build_kernel(KernelSpec(**SMALL)), "b200mn": v7, "b200pair": pair}
ARMS = '''
    _load("b200mn", PTX_B200MN)
    _load("b200pair", PTX_B200PAIR)
    for _k in ("b200pl", "b200plr3", "b200plr4", "b200plr6"):
        _load(_k, globals()["PTX_" + _k.upper()])
    def DIAG_ARMS(a2, b2, c2):
        return [
            ("v7", lambda: _mod.run_b200mn(a2, b2, c2), True),
            ("pairL_r3", lambda: _mod.run_b200plr3(a2, b2, c2), True),
            ("torch", lambda: torch.matmul(a2, b2), False),
        ]
'''
make_diag("diag_b200_pair_sub.py", ks, ARMS, [(4096, 5120, 4096, 123456), (9472, 2048, 4096, 777), (9472, 3072, 4096, 778), (8192, 8192, 8192, 32412)],
          ["matmul_b200_tcgen05_mn.crisp"])
