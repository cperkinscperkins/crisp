"""H100 probe: where does the 2wg_deep kernel's time go?  Writes diag_h100_probe_sub.py.

The Nsight profile route (popcorn --profile) produced no report on 2026-10-28, even for pure torch, so
this answers the same questions with hand-edited PTX arms timed side by side on one GPU:

  w1     wgmma wait depth 1.  The kernel does commit -> wait_group 0 -> release slot every k-step, so the
         tensor pipe drains 64 times per tile.  The arm waits with depth 1 and releases the PREVIOUS
         slot ((k-1)&3, skipped at k=0); at loop exit it drains (wait_group 0) and releases the last
         slot.  Correct by construction -- the arm is exact-checked.
  noepi  every st.global predicated on c_byte_size == 0 (never true at run time, so the mainloop and
         cvt's stay live): what the exposed epilogue -- 128 scalar st.global.b16 -- costs.  Timing only.

Every rewrite asserts its match count, so a recompiled kernel whose PTX drifted fails here, not on the GPU.
"""
import dataclasses
import re

from package_matmul import KernelSpec, build_kernel, make_diag, H100_2WG, TRANSPOSE

# (loop counter, arrive-address reg, slot-offset reg, mbar_1 reg, arrive token reg, loop-exit label)
CONSUMERS = [("%rd589", "%rd34", "%rd33", "%rd133", "%rd134", "$L__BB71_37"),
             ("%rd590", "%rd39", "%rd38", "%rd108", "%rd109", "$L__BB71_27")]


def _declare(ptx: str, decls: str) -> str:
    """Add register declarations after the entry's .reg .b64 %rd<N> line."""
    entry = ptx.index(".visible .entry matmul(")
    m = re.compile(r"\t\.reg \.b64 \t%rd<\d+>;\n").search(ptx, entry)
    assert m, "entry .reg .b64 line not found"
    return ptx[:m.end()] + decls + ptx[m.end():]


def depth1(ptx: str) -> str:
    assert ptx.count("wgmma.wait_group.sync.aligned 0;") == 2, "expected one wait_group 0 per consumer"
    ptx = ptx.replace("wgmma.wait_group.sync.aligned 0;", "wgmma.wait_group.sync.aligned 1;")
    for i, (ctr, addr, off, mbar, tok, exit_label) in enumerate(CONSUMERS):
        r0, r1, r2, r3 = (f"%rdw{4 * i + j}" for j in range(4))
        old = (f"\tadd.s64 \t{addr}, {off}, {mbar};\n"
               f"\tmbarrier.arrive.shared.b64 \t{tok}, [{addr}];\n")
        assert ptx.count(old) == 1, f"consumer {i}: arrive block not found"
        new = (f"\tsetp.ne.u64 \t%pw{i}, {ctr}, 0;\n"
               f"\tadd.s64 \t{r0}, {ctr}, -1;\n"
               f"\tand.b64 \t{r0}, {r0}, 3;\n"
               f"\tshl.b64 \t{r0}, {r0}, 3;\n"
               f"\tadd.s64 \t{addr}, {r0}, {mbar};\n"
               f"\t@%pw{i} mbarrier.arrive.shared.b64 \t{tok}, [{addr}];\n")
        ptx = ptx.replace(old, new)
        # the loop-exit block must be reached only by a branch (no fallthrough from the block above)
        lines = ptx.split("\n")
        k = next(n for n, l in enumerate(lines) if l.startswith(exit_label + ":"))
        assert lines[k - 1].lstrip().startswith("bra.uni"), f"{exit_label} has a fallthrough predecessor"
        drain = [f"\twgmma.wait_group.sync.aligned 0;",
                 f"\t@%p21 bra \t$L__W1X{i};",
                 f"\tadd.s64 \t{r1}, {ctr}, -1;",
                 f"\tand.b64 \t{r1}, {r1}, 3;",
                 f"\tshl.b64 \t{r1}, {r1}, 3;",
                 f"\tmov.b64 \t{r2}, __crisp_mbar_1;",
                 f"\tadd.s64 \t{r2}, {r2}, {r1};",
                 f"\tmbarrier.arrive.shared.b64 \t{r3}, [{r2}];",
                 f"$L__W1X{i}:"]
        ptx = "\n".join(lines[:k + 1] + drain + lines[k + 1:])
    return _declare(ptx, "\t.reg .pred \t%pw<2>;\n\t.reg .b64 \t%rdw<8>;\n")


def no_epilogue(ptx: str, spec: KernelSpec) -> str:
    assert spec.params[57] == "c_byte_size", f"param 57 is {spec.params[57]}"
    n = len(re.findall(r"(?m)^\tst\.global", ptx))
    assert n == 128, f"expected 128 unpredicated st.global, got {n}"
    ptx = re.sub(r"(?m)^\tst\.global", "\t@%pq st.global", ptx)
    ptx = _declare(ptx, "\t.reg .pred \t%pq;\n\t.reg .b64 \t%rdq;\n")
    anchor = "// %bb.0:                               // %entry\n"
    entry = ptx.index(".visible .entry matmul(")
    k = ptx.index(anchor, entry) + len(anchor)
    return ptx[:k] + "\tld.param.u64 \t%rdq, [matmul_param_57];\n\tsetp.eq.u64 \t%pq, %rdq, 0;\n" + ptx[k:]


ARMS = '''
    for _k, _p in (("h100_2wg", PTX_H100_2WG), ("h100w1", PTX_H100W1), ("h100ne", PTX_H100NE),
                   ("h100w1ne", PTX_H100W1NE), ("transpose", PTX_TRANSPOSE)):
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
            ("w1", lambda: _mod.run_h100w1(a2, bt, c2), False),
            ("noepi", lambda: _mod.run_h100ne(a2, bt, c2), False),
            ("w1_noepi", lambda: _mod.run_h100w1ne(a2, bt, c2), False),
            ("kernel_chk", fresh(_mod.run_h100_2wg), True),
            ("w1_chk", fresh(_mod.run_h100w1), True),
            ("torch", lambda: torch.matmul(a2, b2), False),
        ]
'''
if __name__ == "__main__":
    # result 2026-10-28 (submission 968382), us at 4096x5120x4096 / 2048x3072x2048:
    #   kernel 310.1 / 82.6, w1 309.1 / 81.9, noepi 238.5 / 54.6, w1_noepi 237.5 / 53.9, torch 224.9 / 40.2
    base = build_kernel(KernelSpec(**H100_2WG))
    w1 = dataclasses.replace(base, key="h100w1", ptx=depth1(base.ptx))
    ne = dataclasses.replace(base, key="h100ne", ptx=no_epilogue(base.ptx, base))
    w1ne = dataclasses.replace(base, key="h100w1ne", ptx=no_epilogue(depth1(base.ptx), base))
    ks = {"h100": base, "w1": w1, "ne": ne, "w1ne": w1ne, "transpose": build_kernel(KernelSpec(**TRANSPOSE))}
    make_diag("diag_h100_probe_sub.py", ks, ARMS, [(4096, 5120, 4096, 123456), (2048, 3072, 2048, 32412)],
              ["matmul_h100_2wg_deep.crisp"])
