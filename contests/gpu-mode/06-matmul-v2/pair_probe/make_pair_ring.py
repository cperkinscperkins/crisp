"""Endeavour 214 step 1b: pair.ptx with a deeper TMA ring, now that a B slot holds only this CTA's half
(64 x 128 = 16 KB).  pairR{R}.ptx: A ring at dynamic-smem 0 (R x 16 KB), B ring after it (R x 16 KB);
dynamic smem = R x 32 KB (R = 3: 96 KB, two CTAs per SM as in v7; R = 4: 128 KB, one)."""
import sys


def make(R, base="pair"):
    src = open(f"{base}.ptx").read()

    def rep(old, new, count=1):
        nonlocal src
        n = src.count(old)
        if n != count:
            sys.exit(f"R={R}: expected {count} x {old!r}, found {n}")
        src = src.replace(old, new)

    # slot = k mod R (both loops call this helper)
    rep("\tand.b64 \t%rd2, %rd1, 1;\n",
        "\tand.b64 \t%rd2, %rd1, 3;\n" if R == 4 else f"\trem.u64 \t%rd2, %rd1, {R};\n")
    # R barrier slots per ring
    for m in ("1", "2"):
        rep(f".visible .shared .align 8 .b8 __crisp_mbar_{m}[16];", f".visible .shared .align 8 .b8 __crisp_mbar_{m}[{8 * R}];")
    for m, reg in (("1", "%r313"), ("2", "%r314")):
        extra = "".join(f"\tmbarrier.init.shared.b64 \t[__crisp_mbar_{m}+{8 * j}], {reg};\n" for j in range(2, R))
        rep(f"\tmbarrier.init.shared.b64 \t[__crisp_mbar_{m}+8], {reg};\n",
            f"\tmbarrier.init.shared.b64 \t[__crisp_mbar_{m}+8], {reg};\n" + extra)
    # B slot stride 32 KB -> 16 KB (producer and MMA)
    rep("\tshl.b64 \t%rd104, %rd96, 15;\n", "\tshl.b64 \t%rd104, %rd96, 14;\n")
    rep("\tshl.b64 \t%rd82, %rd71, 15;\n", "\tshl.b64 \t%rd82, %rd71, 14;\n")
    # ring bases: A at 0, B after A's R slots (both 1024-aligned for SWIZZLE_128B)
    rep("\tld.param.b64 \t%rd50, [matmul_param_2];\n", f"\tmov.b64 \t%rd50, {R * 16384};\n")
    rep("\tld.param.b64 \t%rd52, [matmul_param_14];\n", "\tmov.b64 \t%rd52, 0;\n")
    open(f"{base}R{R}.ptx", "w", newline="\n").write(src)
    print(f"wrote {base}R{R}.ptx (dynamic smem {R * 32768})")


for R in (3, 4):
    make(R)
    make(R, "pairL")
make(6, "pairL")
