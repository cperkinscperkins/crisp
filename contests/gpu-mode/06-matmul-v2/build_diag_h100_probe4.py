"""H100 probe 4: what is a stmatrix + TMA-store epilogue worth?  Writes diag_h100_probe4_sub.py.

Hand-edited PTX of the v4 transB kernel (matmul_h100_2wg_transb.crisp).  Each consumer's epilogue -- the
guarded block of 64 st.global.v2.b16 per thread (endeavour 197) -- is replaced, per warp, by:

  for each half of the warp's 16 x 256 slab (cols 0..127, then 128..255):
    lane 0 waits for the staging buffer's previous TMA reads (cp.async.bulk.wait_group.read 0)
    8 x stmatrix.x4 into a 4 KB staging buffer laid out as two 16 x 64 boxes, 128B-swizzled
    fence.proxy.async; bar.warp.sync
    lane 0: two cp.async.bulk.tensor stores through a C tensor map (box {64, 16}, SWIZZLE_128B); commit

Only warp-level syncs: each warp owns its 16 rows, its staging buffer and its bulk group.  Staging is 8
warps x 4 KB = 32 KB after the ring's 192 KB (1 KB alignment pad; 227 KB is the limit).  The exit block
waits for every thread's outstanding reads before ret.  The cvt.rn.f16.f32 block is kept (the probe
packs the existing %rs pairs), so this measures the store path, not the conversion.

  tb          the ranked v4 kernel
  tbe         tb with the TMA-store epilogue.  Exact-checked in tbe_chk (C zeroed first).
  tb_pers / tbe_pers   the same on probe 3's persistent grid (CTA walks several tiles); tbe_pers_chk.
"""
import dataclasses
import re
import sys

from package_matmul import KernelSpec, build_kernel, make_diag, H100_TRANSB

STAGE_OFF = 196608          # the ring's dynamic smem; staging goes after it
STAGE_BYTES = 8 * 4096
TMAP = "c_tmap_probe"

INSN = re.compile(r"^\s*([\w.:]+)\s+(%\w+),\s*(.*?);")
ST2 = re.compile(r"^\s*st\.global\.v2\.b16\s+\[(%\w+)\],\s*\{(%\w+),\s*(%\w+)\};")
LABEL = re.compile(r"^(\$L__\w+):")


def _blocks(lines, lo, hi):
    """label -> (first line, end line exclusive) for the labelled blocks in lines[lo:hi]."""
    starts = [(n, LABEL.match(lines[n]).group(1)) for n in range(lo, hi) if LABEL.match(lines[n])]
    out = {}
    for i, (n, lab) in enumerate(starts):
        out[lab] = (n, starts[i + 1][0] if i + 1 < len(starts) else hi)
    return out


def _body(lines, rng):
    return [l for l in lines[rng[0] + 1:rng[1]] if l.strip() and not l.strip().startswith("//")]


def _def(lines, lo, hi, reg):
    """The (op, args) of the instruction defining reg in lines[lo:hi]."""
    for l in lines[lo:hi]:
        m = INSN.match(l)
        if m and m.group(2) == reg:
            return m.group(1), [a.strip() for a in m.group(3).split(",")]
    raise ValueError(f"no definition of {reg}")


def _pairs(hdr, then):
    """(h, k) -> (lo, hi): h = row half (0: rows r, 1: r+8), k = column offset of the thread's pair.
    A tiny symbolic evaluation of the header + packed branch's address arithmetic."""
    # header shape: cvt.u32.u64 A, GRIDX; shl.b32 B, A, 8; or.b32 COL, B, %rLANE2 ...
    sym, pairs = {}, {}
    ops = [INSN.match(l) for l in hdr]
    ops = [(m.group(1), m.group(2), [a.strip() for a in m.group(3).split(",")]) for m in ops if m]
    col = next(d for op, d, a in ops if op == "or.b32" and a[1].startswith("%r"))
    sym[col] = ("c", 0)
    row0 = row8 = cbase = None
    for op, d, a in ops:
        if op in ("cvt.s64.s32", "cvt.u32.u64") and a[0] in sym:
            sym[d] = sym[a[0]]
        if op == "add.s64" and sym.get(a[1], ("",))[0] == "c":
            if row0 is None:
                row0 = a[0]
            elif a[0] != row0 and row8 is None:
                row8 = a[0]
        if op == "add.s64" and a[0] not in (row0, row8) and a[1] in sym and sym[a[1]][0] == "s":
            cbase = a[0]
        if op == "add.s64" and a[0] in (row0, row8) and sym.get(a[1], ("",))[0] == "c":
            sym[d] = ("r", 0 if a[0] == row0 else 1, sym[a[1]][1])
        if op == "shl.b64" and sym.get(a[0], ("",))[0] == "r" and a[1] == "1":
            sym[d] = ("s",) + sym[a[0]][1:]
    assert row0 and row8 and cbase, (row0, row8, cbase)
    for l in hdr + then:
        s = ST2.match(l)
        if s:
            t = sym[s.group(1)]
            assert t[0] == "a", (l, t)
            pairs[t[1:]] = (s.group(2), s.group(3))
            continue
        m = INSN.match(l)
        if not m:
            continue
        op, d, a = m.group(1), m.group(2), [x.strip() for x in m.group(3).split(",")]
        if op in ("or.b32", "add.s32") and a[0] in sym and sym[a[0]][0] == "c" and a[1].isdigit():
            sym[d] = ("c", sym[a[0]][1] + int(a[1]))
        elif op in ("cvt.s64.s32", "cvt.u32.u64", "mov.b64", "mov.b32") and a[0] in sym:
            sym[d] = sym[a[0]]
        elif op == "add.s64" and a[0] in (row0, row8) and sym.get(a[1], ("",))[0] == "c":
            sym[d] = ("r", 0 if a[0] == row0 else 1, sym[a[1]][1])
        elif op == "shl.b64" and sym.get(a[0], ("",))[0] == "r":
            sym[d] = ("s",) + sym[a[0]][1:]
        elif op == "add.s64" and a[0] == cbase and sym.get(a[1], ("",))[0] == "s":
            sym[d] = ("a",) + sym[a[1]][1:]
    want = {(h, k) for h in (0, 1) for k in range(0, 256, 8)}
    assert set(pairs) == want, f"pair map incomplete: {sorted(want - set(pairs))[:6]}"
    return pairs


def _epilogue(tag, pairs, gridx, row13, tid, lane, param, exit_label):
    """PTX for one consumer's TMA-store epilogue.  Registers %q<tag>_*."""
    r = lambda n: f"%q{tag}_{n}"
    o = [f"\t// ---- probe4: stmatrix + TMA-store epilogue ({tag}) ----",
         f"\tmov.b64 \t%qd{tag}_0, __crisp_dynamic_smem;",
         f"\tcvt.u32.u64 \t{r(0)}, %qd{tag}_0;",
         f"\tadd.s32 \t{r(0)}, {r(0)}, {STAGE_OFF + 1023};",
         f"\tand.b32 \t{r(0)}, {r(0)}, -1024;",
         f"\tshr.u32 \t{r(1)}, {tid}, 5;",                       # warp 0..7
         f"\tshl.b32 \t{r(2)}, {r(1)}, 12;",
         f"\tadd.s32 \t{r(3)}, {r(0)}, {r(2)};",                 # this warp's staging base
         f"\tshl.b32 \t{r(4)}, {r(1)}, 4;",
         f"\tadd.s32 \t{r(5)}, {row13}, {r(4)};",                # y: the warp's first row in C
         f"\tcvt.u32.u64 \t{r(6)}, {gridx};",
         f"\tshl.b32 \t{r(7)}, {r(6)}, 8;",                      # x0: the tile's first column
         f"\tand.b32 \t{r(8)}, {lane}, 7;",                      # i: row within the 8x8 matrix
         f"\tbfe.u32 \t{r(9)}, {lane}, 3, 1;",                   # h: row half
         f"\tshr.u32 \t{r(10)}, {lane}, 4;",                     # dj: second n8 block
         f"\tshl.b32 \t{r(11)}, {r(9)}, 3;",
         f"\tadd.s32 \t{r(11)}, {r(11)}, {r(8)};",
         f"\tshl.b32 \t{r(11)}, {r(11)}, 7;",                    # (8h + i) * 128
         f"\tsetp.eq.u32 \t%qp{tag}_0, {lane}, 0;",
         f"\tld.param.u64 \t%qd{tag}_1, [{param}];",
         f"\tcvta.global.u64 \t%qd{tag}_1, %qd{tag}_1;"]
    addr = {}
    for m in range(4):
        t = r(12 + m)
        o += [f"\tadd.s32 \t{t}, {r(10)}, {2 * m};",
              f"\txor.b32 \t{t}, {t}, {r(8)};",
              f"\tshl.b32 \t{t}, {t}, 4;",
              f"\tadd.s32 \t{t}, {t}, {r(11)};",
              f"\tadd.s32 \t{r(16 + m)}, {r(3)}, {t};",
              f"\tadd.s32 \t{r(20 + m)}, {r(16 + m)}, 2048;"]
        addr[(0, m)], addr[(1, m)] = r(16 + m), r(20 + m)
    packed = {}
    for (h, k), (lo, hi) in sorted(pairs.items()):
        reg = r(32 + h * 32 + k // 8)
        o.append(f"\tmov.b32 \t{reg}, {{{lo}, {hi}}};")
        packed[(h, k // 8)] = reg
    for p in range(2):
        o += [f"\t@%qp{tag}_0 cp.async.bulk.wait_group.read 0;",
              "\tbar.warp.sync \t-1;"]
        for j in range(16 * p, 16 * p + 16, 2):
            a = addr[((j - 16 * p) >> 3, (j % 8) // 2)]
            regs = ", ".join(packed[(h, jj)] for jj in (j, j + 1) for h in (0, 1))
            o.append(f"\tstmatrix.sync.aligned.m8n8.x4.shared.b16 \t[{a}], {{{regs}}};")
        o += ["\tfence.proxy.async.shared::cta;",
              "\tbar.warp.sync \t-1;",
              f"\tadd.s32 \t{r(24)}, {r(7)}, {128 * p};",
              f"\tadd.s32 \t{r(25)}, {r(7)}, {128 * p + 64};",
              f"\tadd.s32 \t{r(26)}, {r(3)}, 2048;",
              f"\t@%qp{tag}_0 cp.async.bulk.tensor.2d.global.shared::cta.bulk_group "
              f"[%qd{tag}_1, {{{r(24)}, {r(5)}}}], [{r(3)}];",
              f"\t@%qp{tag}_0 cp.async.bulk.tensor.2d.global.shared::cta.bulk_group "
              f"[%qd{tag}_1, {{{r(25)}, {r(5)}}}], [{r(26)}];",
              f"\t@%qp{tag}_0 cp.async.bulk.commit_group;"]
    o.append(f"\tbra.uni \t{exit_label};")
    return o


def tma_epilogue(ptx: str) -> str:
    lines = ptx.split("\n")
    e0 = next(n for n, l in enumerate(lines) if l.startswith(".visible .entry matmul("))
    e1 = next(n for n in range(e0, len(lines)) if lines[n].startswith("}"))
    params = [n for n in range(e0, e1) if re.match(r"\s*\.param .*matmul_param_(\d+)", lines[n])]
    last = int(re.search(r"matmul_param_(\d+)", lines[params[-1]]).group(1))
    param = f"matmul_param_{last + 1}"
    bl = _blocks(lines, e0, e1)
    text = "\n".join(lines[e0:e1])
    tid = re.search(r"setp\.lt\.u32\s+%p\d+,\s*(%r\d+),\s*128;", text).group(1)
    lane = re.search(r"mov\.u32\s+(%r\d+),\s*%laneid;", text).group(1)

    # headers: blocks ending '@%p bra THEN; bra.uni ELSE' where THEN opens with a packed store
    headers = []
    for lab, rng in bl.items():
        body = _body(lines, rng)
        if len(body) >= 2:
            m1 = re.match(r"\s*@%p\d+ bra\s+(\$L__\w+);", body[-2])
            m2 = re.match(r"\s*bra\.uni\s+(\$L__\w+);", body[-1])
            if m1 and m2 and m1.group(1) in bl and ST2.match(_body(lines, bl[m1.group(1)])[0]):
                headers.append((lab, m1.group(1), m2.group(1)))
    assert len(headers) == 2, headers
    replace, delete = {}, []
    for tag, (hlab, tlab, elab) in zip("ab", headers):
        hdr, then = _body(lines, bl[hlab]), _body(lines, bl[tlab])
        exit_label = re.match(r"\s*bra\.uni\s+(\$L__\w+);", then[-1]).group(1)
        pairs = _pairs(hdr, then)
        sh = next(l for l in hdr if l.strip().startswith("cvt.u32.u64"))
        gridx = sh.split(",")[1].strip().rstrip(";")
        # the tile's first row: rd25 = N * cvt(%r9 + %r13); %r13 = (...) << 7
        row0 = next(INSN.match(l).group(3).split(",")[0].strip() for l in hdr
                    if INSN.match(l) and INSN.match(l).group(1) == "add.s64")
        _, mul = _def(lines, e0, e1, row0)                       # mul.lo.s64 row0, N, %rdX
        _, cv = _def(lines, e0, e1, mul[1])                      # cvt.s64.s32 %rdX, %rY
        _, ad = _def(lines, e0, e1, cv[0])                       # add.s32 %rY, %r9, %r13
        row13 = next(x for x in ad if _def(lines, e0, e1, x)[0] == "shl.b32"
                     and _def(lines, e0, e1, x)[1][1] == "7")
        print(f"  {tag}: header {hlab} then {tlab} else {elab} exit {exit_label} gridx {gridx} row {row13} "
              f"tid {tid} lane {lane}")
        replace[bl[hlab]] = _epilogue(tag, pairs, gridx, row13, tid, lane, param, exit_label)
        delete += [bl[tlab], bl[elab]]
    out = []
    n = 0
    skip = {r[0]: r[1] for r in delete}
    rep = {r[0]: (r[1], v) for r, v in replace.items()}
    regs_done = False
    while n < len(lines):
        if n in skip:
            n = skip[n]
            continue
        if n in rep:
            end, body = rep[n]
            out.append(lines[n])
            out += body
            n = end
            continue
        l = lines[n]
        if e0 <= n < e1 and n == params[-1]:
            out.append(l + ",")
            out.append(f"\t.param .u64 {param}")
            n += 1
            continue
        if e0 <= n < e1 and not regs_done and l.strip().startswith(".reg .b64") and "%rd<" in l:
            out.append(l)
            for t in "ab":
                out += [f"\t.reg .b32 \t%q{t}_<100>;", f"\t.reg .b64 \t%qd{t}_<2>;", f"\t.reg .pred \t%qp{t}_<1>;"]
            regs_done = True
            n += 1
            continue
        if e0 <= n < e1 and l.strip() == "ret;":
            out.append("\tcp.async.bulk.wait_group.read 0;")
        out.append(l)
        n += 1
    assert regs_done
    return "\n".join(out)


def tbe_spec(base: KernelSpec) -> KernelSpec:
    s = dataclasses.replace(base, key="h100tbe", ptx=tma_epilogue(base.ptx),
                            params=base.params + [TMAP], tensormaps=list(base.tensormaps),
                            smem=STAGE_OFF + STAGE_BYTES + 1024)
    assert base.smem == STAGE_OFF, base.smem
    s.tensormaps.append({"name": TMAP, "gdim": "c_ext1, c_ext0", "gstr": "c_str0 * 2", "box": "64, 16",
                         "dtype": "CU_TENSOR_MAP_DATA_TYPE_FLOAT16", "ptr": "c_ptr",
                         "swizzle": "CU_TENSOR_MAP_SWIZZLE_128B"})
    return s


ARMS = '''
    for _k, _p in (("h100tb", PTX_H100TB), ("h100tbe", PTX_H100TBE)):
        _load(_k, _p)
    def DIAG_ARMS(a2, b2, c2):
        tx, ty = a2.size(0) // 128, c2.size(1) // 256
        gx, gy = max(((x, y) for x in range(1, tx + 1) if tx % x == 0
                      for y in range(1, ty + 1) if ty % y == 0 and x * y <= 132), key=lambda g: g[0] * g[1])
        def fresh(run):
            def f():
                c2.zero_()
                run()
            return f
        tbe = lambda: _mod.run_h100tbe(a2, b2, c2)
        tbe_pers = lambda: _mod.run_h100tbe_grid(a2, b2, c2, gx, gy)
        return [
            (f"grid{gx}x{gy}", lambda: None, False),
            ("tb", lambda: _mod.run_h100tb(a2, b2, c2), False),
            ("tbe", tbe, False),
            ("tb_pers", lambda: _mod.run_h100tb_grid(a2, b2, c2, gx, gy), False),
            ("tbe_pers", tbe_pers, False),
            ("tbe_chk", fresh(tbe), True),
            ("tbe_pers_chk", fresh(tbe_pers), True),
            ("torch", lambda: torch.matmul(a2, b2), False),
        ]
'''

if __name__ == "__main__":
    base = build_kernel(KernelSpec(**H100_TRANSB))
    tbe = tbe_spec(base)
    if "--ptx-only" in sys.argv:
        from pathlib import Path
        Path("_build/probe4_tbe.ptx").write_text(tbe.ptx, encoding="utf-8")
        sys.exit(0)
    make_diag("diag_h100_probe4_sub.py", {"tb": base, "tbe": tbe}, ARMS,
              [(4096, 5120, 4096, 123456), (2048, 3072, 2048, 32412)], ["matmul_h100_2wg_transb.crisp"])
