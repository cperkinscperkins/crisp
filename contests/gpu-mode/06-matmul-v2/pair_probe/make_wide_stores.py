"""Epilogue probe (2026-11-11): regroup the epilogue's packed fast path
    cvt.rn.f16x2.f32 %rA, ..; st.global.b32 [%rdB+off], %rA;   (x16 per 32-column tcgen05.ld block)
into st.global.v4.b32 (16 B per thread per instruction) or st.global.v8.b32 (32 B = one sector, sm_100).
Assumes C rows 16 / 32-byte aligned (true for the contest: 256-B allocations, 512-B tile column steps;
the diag's exactness check confirms).  usage: python make_wide_stores.py IN.ptx OUT_PREFIX"""
import re
import sys

src = open(sys.argv[1]).read()
pair = re.compile(r"\tcvt\.rn\.f16x2\.f32 \t(%r\d+), (%r\d+), (%r\d+);\n"
                  r"\tst\.global\.b32 \t\[(%rd\d+)(?:\+(\d+))?\], \1;\n")


def widen(text, W):
    out, pos, groups = [], 0, 0
    run = []                      # consecutive (match) pairs with the same base and +4 offsets

    def flush():
        nonlocal groups
        i = 0
        while i < len(run):
            off0 = int(run[i].group(5) or 0)
            chunk = run[i:i + W]
            ok = (len(chunk) == W and off0 % (4 * W) == 0
                  and all(int(m.group(5) or 0) == off0 + 4 * j for j, m in enumerate(chunk)))
            if ok:
                for m in chunk:
                    out.append(f"\tcvt.rn.f16x2.f32 \t{m.group(1)}, {m.group(2)}, {m.group(3)};\n")
                regs = ", ".join(m.group(1) for m in chunk)
                addr = f"{chunk[0].group(4)}+{off0}" if off0 else chunk[0].group(4)
                out.append(f"\tst.global.v{W}.b32 \t[{addr}], {{{regs}}};\n")
                groups += 1
                i += W
            else:
                out.append(run[i].group(0))
                i += 1
        run.clear()

    for m in pair.finditer(text):
        if m.start() != pos or (run and (m.group(4) != run[-1].group(4)
                                         or int(m.group(5) or 0) != int(run[-1].group(5) or 0) + 4)):
            flush()
            out.append(text[pos:m.start()])
        run.append(m)
        pos = m.end()
    flush()
    out.append(text[pos:])
    return "".join(out), groups


for W in (4, 8):
    t, g = widen(src, W)
    left = t.count("st.global.b32")
    open(f"{sys.argv[2]}_v{W}.ptx", "w", newline="\n").write(t)
    print(f"v{W}: {g} wide stores, {left} st.global.b32 left")

# pass 2 (v4 only): a block's first store goes through its own base register, one instruction before the
# rest:  st [%rdA], r0;  <one line>;  st [%rdB+K], r1; st [%rdB+K+4], r2; st [%rdB+K+8], r3  with K % 16 == 4
# (the compiler's own %rdA = %rdB + K - 4) -> one st.global.v4.b32 [%rdA], {r0..r3}.
head = re.compile(r"(\tcvt\.rn\.f16x2\.f32 \t(%r\d+), %r\d+, %r\d+;\n)\tst\.global\.b32 \t\[(%rd\d+)\], \2;\n"
                  r"(\t[^\n]*\n)"
                  r"(\tcvt\.rn\.f16x2\.f32 \t(%r\d+), %r\d+, %r\d+;\n)\tst\.global\.b32 \t\[(%rd\d+)\+(\d+)\], \6;\n"
                  r"(\tcvt\.rn\.f16x2\.f32 \t(%r\d+), %r\d+, %r\d+;\n)\tst\.global\.b32 \t\[\7\+(\d+)\], \10;\n"
                  r"(\tcvt\.rn\.f16x2\.f32 \t(%r\d+), %r\d+, %r\d+;\n)\tst\.global\.b32 \t\[\7\+(\d+)\], \13;\n")


def fold(m):
    k1, k2, k3 = int(m.group(8)), int(m.group(11)), int(m.group(14))
    if not (k1 % 16 == 4 and k2 == k1 + 4 and k3 == k1 + 8):
        return m.group(0)
    return (m.group(4) + m.group(1) + m.group(5) + m.group(9) + m.group(12)
            + f"\tst.global.v4.b32 \t[{m.group(3)}], {{{m.group(2)}, {m.group(6)}, {m.group(10)}, {m.group(13)}}};\n")


t = open(f"{sys.argv[2]}_v4.ptx").read()
t2, n = head.subn(fold, t)
open(f"{sys.argv[2]}_v4.ptx", "w", newline="\n").write(t2)
print(f"v4 pass 2: {n} block heads folded, {t2.count('st.global.b32')} st.global.b32 left")
