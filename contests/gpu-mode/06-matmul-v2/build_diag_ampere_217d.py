"""Endeavour 217 F-217-2 (metal, A100): the ring await tail race -- K = 64 / 96 put most stages in the unwaited tail -- the REAL swizzle (put_temp_files_here/217/impl.lisp) vs today.
ring3 = matmul_ampere_4w_ring.crisp on today's compiler (ldmatrix, unswizzled tiles); ring3swz = the same kernel
through put_temp_files_here/217/cc_impl.bat, which decides per scratch tile at its LET and swizzles EVERY
accessor (aref path + ldmatrix), not only the two the step-1 probe touched.
The ragged cases reach load-tile's per-element fallback and zero fill (the probe's hole): ring3swz must be as
exact as ring3 there too.
Writes diag_ampere_217d_sub.py."""
import package_matmul as pm
from package_matmul import KernelSpec, build_kernel, make_diag, SMALL, AMPERE4W

AMPRING = dict(AMPERE4W, key="ampring", crisp="matmul_ampere_4w_ring.crisp", k_step=32)
# bin/crisp-compile.exe now carries the 217 overlay: the PLAIN twin is compiled with *217-swizzle* NIL.
PLAIN = pm.REPO_ROOT / "put_temp_files_here" / "217" / "cc_plain.bat"
ks = {"small": build_kernel(KernelSpec(**SMALL)),
      "ampringswz": build_kernel(KernelSpec(**dict(AMPRING, key="ampringswz")))}
saved, pm.CRISP_COMPILE = pm.CRISP_COMPILE, PLAIN
ks["ampring"] = build_kernel(KernelSpec(**AMPRING))
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
            ("ring3b", lambda: _mod.run_ampring(a2, b2, c2), True),
            ("ring3c", lambda: _mod.run_ampring(a2, b2, c2), True),
            ("swz", lambda: _mod.run_ampringswz(a2, b2, c2), True),
            ("swzb", lambda: _mod.run_ampringswz(a2, b2, c2), True),
            ("swzc", lambda: _mod.run_ampringswz(a2, b2, c2), True),
            ("swzd", lambda: _mod.run_ampringswz(a2, b2, c2), True),
        ]
'''
make_diag("diag_ampere_217d_sub.py", ks, ARMS,
          [(8192, 8192, 64, 1), (8192, 8192, 96, 2), (4096, 4096, 64, 3), (4096, 4096, 4096, 4)],
          ["matmul_ampere_4w_ring.crisp"])
