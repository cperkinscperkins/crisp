"""Endeavour 217 F-217-2: crisp_matmul_v12.py -- v11 rebuilt by the compiler with the count-correct ring await
(tests/spec/217-swizzle/swizzle.md F-217-2, spec 06).  v11's A100 / L4 ring waited with one static
cp.async.wait_group 4, which waits for nothing in the last two K iterations (the refill is skipped there):
L4 ranked validation failed.  Same Crisp source, same dispatch.  Only the ring kernel may change -- every
other kernel's PTX must be byte-identical to v11's, checked here -- and the ring must now hold the counted
wait chain (wait_group 4, 2 and 0)."""
import re
import package_matmul as pm
from package_matmul import (KernelSpec, build_kernel, make_submission, SMALL, H100_TMA, B200_TCMN,
                            B200_TCMN128, AMPERE4W_RING, DISPATCH_V10, HERE)

ks = {"small": build_kernel(KernelSpec(**SMALL)),
      "h100tma": build_kernel(KernelSpec(**H100_TMA)),
      "b200mn": build_kernel(KernelSpec(**B200_TCMN)),
      "b200mn128": build_kernel(KernelSpec(**B200_TCMN128)),
      "ampring": build_kernel(KernelSpec(**AMPERE4W_RING))}

v11 = (HERE / "crisp_matmul_v11.py").read_text(encoding="utf-8")
make_submission(
    "crisp_matmul_v12.py",
    "matmul_v2 v12: v11 (swizzled ldmatrix tiles) with the count-correct cp.async ring await (F-217-2)",
    ks, DISPATCH_V10,
    ["matmul_h100_2wg_tma.crisp", "matmul_b200_tcgen05_mn.crisp", "matmul_b200_tcgen05_mn_128.crisp",
     "matmul_ampere_4w_ring.crisp", "matmul_small_mma.crisp"])
v12 = (HERE / "crisp_matmul_v12.py").read_text(encoding="utf-8")


def ptx_block(text, key):
    m = re.search(r"^PTX_%s = (r?\"\"\".*?\"\"\")" % key.upper(), text, re.S | re.M)
    return m.group(1) if m else None


for key in ks:
    a, b = ptx_block(v11, key), ptx_block(v12, key)
    waits = sorted(set(re.findall(r"cp\.async\.wait_group \t(\d+);", b or "")))
    print(f"{key:10s} v11 {'found' if a else 'MISSING'}  identical={a == b}  v12 waits={waits}")
