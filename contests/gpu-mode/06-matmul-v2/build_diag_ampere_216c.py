"""Endeavour 216 diag 3: the price of shared-memory bank conflicts, with NO compiler change.

A scratch tile's base offset, row stride and byte size are launch literals (the hoist passes them), so a
PADDED twin is the same PTX with different literals: A's row pitch 32 -> 40 halves (80 B) and B's
128 -> 136 (272 B) put the 8 rows an ldmatrix 8x8 matrix reads in 8 different 16-byte bank groups
(today: A 64 B pitch -> 4-way conflict, B 256 B -> 8-way).  Arms: k32ldm / k32pad (one stage) and
ring3 / ring3pad (3-slot cp.async ring).  Writes diag_ampere_216c_sub.py."""
import copy
from package_matmul import KernelSpec, build_kernel, make_diag, SMALL, AMPERE4W, AMPERE4W_K32

AMPRING = dict(AMPERE4W, key="ampring", crisp="matmul_ampere_4w_ring.crisp", k_step=32)


def padded(spec, key, a_pfx, b_pfx, a_pitch, b_pitch):
    """SPEC with B at offset 0 then A, each row pitch widened (and, for a ring, the slot stride with it)."""
    s = copy.deepcopy(spec)
    s.key = key
    L = s.literals
    ring = (a_pfx + "_str2") in L
    def lay(pfx, pitch, base):
        if ring:
            slots, rows = int(L[pfx + "_ext0"]), int(L[pfx + "_ext1"])
            L[pfx + "_str1"] = str(pitch)
            L[pfx + "_str0"] = str(rows * pitch)
            size = slots * rows * pitch * 2
        else:
            rows = int(L[pfx + "_ext0"])
            L[pfx + "_str0"] = str(pitch)
            size = rows * pitch * 2
        L[pfx + "_ptr"] = str(base)
        L[pfx + "_byte_size"] = str(size)
        return base + size
    end = lay(a_pfx, a_pitch, lay(b_pfx, b_pitch, 0))
    s.smem = end
    print(f"  {key}: smem {spec.smem} -> {end}", {k: v for k, v in L.items() if k.endswith(('_ptr', '_str0', '_str1', '_byte_size'))})
    return s


ks = {"small": build_kernel(KernelSpec(**SMALL)),
      "ampk32": build_kernel(KernelSpec(**AMPERE4W_K32)),
      "ampring": build_kernel(KernelSpec(**AMPRING))}
ks["ampk32pad"] = padded(ks["ampk32"], "ampk32pad", "a_tile_from_matmul_ampere_4w_1", "b_tile_from_matmul_ampere_4w_2", 40, 136)
ks["ampringpad"] = padded(ks["ampring"], "ampringpad", "a_ring_from_matmul_ampere_4w_ring_1",
                          "b_ring_from_matmul_ampere_4w_ring_2", 40, 136)
ARMS = '''
    _load("ampk32", PTX_AMPK32)
    _load("ampk32pad", PTX_AMPK32PAD)
    _load("ampring", PTX_AMPRING)
    _load("ampringpad", PTX_AMPRINGPAD)
    def DIAG_ARMS(a2, b2, c2):
        return [
            ("k32ldm", lambda: _mod.run_ampk32(a2, b2, c2), True),
            ("k32pad", lambda: _mod.run_ampk32pad(a2, b2, c2), True),
            ("ring3", lambda: _mod.run_ampring(a2, b2, c2), True),
            ("ring3pad", lambda: _mod.run_ampringpad(a2, b2, c2), True),
            ("torch", lambda: torch.matmul(a2, b2), False),
        ]
'''
make_diag("diag_ampere_216c_sub.py", ks, ARMS, [(4096, 5120, 4096, 123456), (2048, 3072, 2048, 32412)],
          ["matmul_ampere_4w_ring.crisp"])
