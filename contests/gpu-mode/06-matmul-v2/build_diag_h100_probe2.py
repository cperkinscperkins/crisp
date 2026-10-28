"""H100 probe 2: how much of the 72 us epilogue does packing the stores recover?  Writes diag_h100_probe2_sub.py.

Probe 1 (build_diag_h100_probe.py) found the epilogue -- 128 scalar st.global.b16 per thread -- costs 72 us
of the 310 us kernel.  The wgmma accumulator layout gives each thread adjacent column PAIRS (offsets 0,1 /
8,9 / ... / 248,249, then the same columns 8 rows down), and the PTX stores them in that order.  So stores
2i and 2i+1 are one contiguous, 4-byte-aligned half2 (C's base is aligned, N is even, the column is even):

  pk     each pair -> mov.b32 {lo, hi} + st.global.b32: half the store instructions, 16 contiguous bytes
         per row per warp-instruction instead of 8.  Exact-checked.
"""
import dataclasses
import re

from package_matmul import KernelSpec, build_kernel, make_diag, H100_2WG, TRANSPOSE
from build_diag_h100_probe import _declare, no_epilogue

ST16 = re.compile(r"^\tst\.global\.b16 \t\[(%rd\d+)\], (%rs\d+);$")


def packed(ptx: str) -> str:
    lines = ptx.split("\n")
    idx = [n for n, l in enumerate(lines) if ST16.match(l)]
    assert len(idx) == 128, f"expected 128 st.global.b16, got {len(idx)}"
    for p in range(64):
        i, j = idx[2 * p], idx[2 * p + 1]
        addr, lo = ST16.match(lines[i]).groups()
        _, hi = ST16.match(lines[j]).groups()
        assert int(hi[3:]) == int(lo[3:]) + 1, f"pair {p}: {lo} / {hi} are not consecutive halves"
        lines[i] = f"\tmov.b32 \t%rpk{p}, {{{lo}, {hi}}};\n\tst.global.b32 \t[{addr}], %rpk{p};"
        lines[j] = "\t// (packed into the store above)"
    return _declare("\n".join(lines), "\t.reg .b32 \t%rpk<64>;\n")


ARMS = '''
    for _k, _p in (("h100_2wg", PTX_H100_2WG), ("h100pk", PTX_H100PK), ("h100ne", PTX_H100NE),
                   ("transpose", PTX_TRANSPOSE)):
        _load(_k, _p)
    def DIAG_ARMS(a2, b2, c2):
        bt = _bt_buffer(b2)
        _mod.run_transpose(b2, b2, bt)
        torch.cuda.synchronize()
        def fresh(run):
            def f():
                c2.zero_()
                run(a2, bt, c2)
            return f
        return [
            ("kernel", lambda: _mod.run_h100_2wg(a2, bt, c2), False),
            ("pk", lambda: _mod.run_h100pk(a2, bt, c2), False),
            ("noepi", lambda: _mod.run_h100ne(a2, bt, c2), False),
            ("pk_chk", fresh(_mod.run_h100pk), True),
            ("torch", lambda: torch.matmul(a2, b2), False),
        ]
'''

if __name__ == "__main__":
    base = build_kernel(KernelSpec(**H100_2WG))
    pk = dataclasses.replace(base, key="h100pk", ptx=packed(base.ptx))
    ne = dataclasses.replace(base, key="h100ne", ptx=no_epilogue(base.ptx, base))
    ks = {"h100": base, "pk": pk, "ne": ne, "transpose": build_kernel(KernelSpec(**TRANSPOSE))}
    make_diag("diag_h100_probe2_sub.py", ks, ARMS, [(4096, 5120, 4096, 123456), (2048, 3072, 2048, 32412)],
              ["matmul_h100_2wg_deep.crisp"])
