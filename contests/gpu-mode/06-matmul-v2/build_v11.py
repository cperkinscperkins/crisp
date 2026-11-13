"""Endeavour 217: crisp_matmul_v11.py -- v10 rebuilt by the compiler with the compiler-owned XOR swizzle of the
shared-memory tiles an ldmatrix reads (tests/spec/217-swizzle/swizzle.md).  Same Crisp source, same dispatch.
The H100 (wgmma + TMA) and B200 (tcgen05) kernels have no ldmatrix reader, so their PTX must be byte-identical
to v10's -- checked here before anything is written.  The A100 / L4 ring and the small fallback change."""
import re
import package_matmul as pm
from package_matmul import (KernelSpec, build_kernel, make_submission, SMALL, H100_TMA, B200_TCMN,
                            B200_TCMN128, AMPERE4W_RING, DISPATCH_V10, HERE)

ks = {"small": build_kernel(KernelSpec(**SMALL)),
      "h100tma": build_kernel(KernelSpec(**H100_TMA)),
      "b200mn": build_kernel(KernelSpec(**B200_TCMN)),
      "b200mn128": build_kernel(KernelSpec(**B200_TCMN128)),
      "ampring": build_kernel(KernelSpec(**AMPERE4W_RING))}

v10 = (HERE / "crisp_matmul_v10.py").read_text(encoding="utf-8")
make_submission(
    "crisp_matmul_v11.py",
    "matmul_v2 v11: v10 with the compiler-owned XOR swizzle of the A100 / L4 ring's (and the small fallback's) ldmatrix tiles",
    ks, DISPATCH_V10,
    ["matmul_h100_2wg_tma.crisp", "matmul_b200_tcgen05_mn.crisp", "matmul_b200_tcgen05_mn_128.crisp",
     "matmul_ampere_4w_ring.crisp", "matmul_small_mma.crisp"])
v11 = (HERE / "crisp_matmul_v11.py").read_text(encoding="utf-8")


def ptx_block(text, key):
    m = re.search(r"^PTX_%s = (r?\"\"\".*?\"\"\")" % key.upper(), text, re.S | re.M)
    return m.group(1) if m else None


for key in ks:
    a, b = ptx_block(v10, key), ptx_block(v11, key)
    print(f"{key:10s} v10 {'found' if a else 'MISSING'}  identical={a == b}  xor_in_v11={'xor.b' in (b or '')}")
