"""Endeavour 190, B2 -- the compile API at its C boundary, driven through ctypes.

What only the boundary can show: argument marshalling, ownership (inputs copied, outputs owned by
the context), sizes and NUL termination, NULL / bad-index handling, the exported symbols, many
strings x many flag sets, the helper-process pool (reuse, shutdown, a missing compiler), and
parallel compiles from several threads.  The compiler's own correctness is B1's job
(tests/spec/190-compile-api/compile-sources.unit.lisp) and A6(A)'s (on metal).

Run from the repo root after building the compiler and the library:
    sbcl --non-interactive --load ./build/build.lisp
    bash c-api/build.sh
    python tests/api/test_crisp_api.py
No GPU needed.  stdlib only (unittest + ctypes).
"""
import ctypes
import os
import re
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "c-api", "python"))
import crisp_ctypes as C  # noqa: E402

LIB = C.load()

TWO_KERNELS = """(def-type fvec (vector float :address-space :global :align :compact))
(def-kernel k_one (A &out B)
  (declare #'(fvec &out fvec => nil))
  (set! (~ B 0) (* (~ A 0) 2.0)))
(def-kernel k_two (A &out B)
  (declare #'(fvec &out fvec => nil))
  (set! (~ B 0) (+ (~ A 0) 1.0)))
"""

TYPES_ONLY = "(def-type fvec (vector float :address-space :global :align :compact))\n"
KERNEL_USING_TYPES = """(def-kernel k_use (A &out B)
  (declare #'(fvec &out fvec => nil))
  (set! (~ B 0) (~ A 0)))
"""

VEC_SQ_LIT = """(def-type in-vec (vector float :address-space :global :align :compact))
(def-type out-c  (cell float :address-space :global))
(def-kernel vec_sq_lit (A &out C)
  (declare #'(in-vec &out out-c))
  (set! (~ C) (* (~ A 2) (~ A 2))))
"""

BROKEN = """(def-type fvec (vector float :address-space :global :align :compact))
(def-kernel k_bad (A &out B)
  (declare #'(fvec &out fvec => nil))
  (set! (~ B 0) no_such_variable))
"""


class Ctx:
    """A context for one test, destroyed on exit."""

    def __init__(self, target="spv"):
        self.p = ctypes.c_void_p()
        st = LIB.crisp_context_create(target.encode(), ctypes.byref(self.p))
        assert st == C.OK, f"crisp_context_create({target}) -> {st}"

    def __enter__(self):
        return self.p

    def __exit__(self, *exc):
        LIB.crisp_context_destroy(self.p)


def _spirv_tools_present():
    """Can this machine compile to SPIR-V?  A CUDA-only box (an H100 pod) has no llvm-spirv (BUG 128);
    the SPIR-V-dependent tests then SKIP instead of failing, and the PTX ones still run."""
    p = ctypes.c_void_p()
    LIB.crisp_context_create(b"spv", ctypes.byref(p))
    try:
        LIB.crisp_add_source(p, TWO_KERNELS.encode(), b"probe.crisp")
        return LIB.crisp_compile(p) == C.OK
    finally:
        LIB.crisp_context_destroy(p)


SPV = _spirv_tools_present()
TARGETS = ("spv", "ptx") if SPV else ("ptx",)
requires_spv = unittest.skipUnless(SPV, "no SPIR-V toolchain on this machine (BUG 128)")


def s(b):
    return None if b is None else b.decode("utf-8")


def compile_text(ctx, text, name="test.crisp", flags=()):
    LIB.crisp_clear_sources(ctx)
    arr, n = C.flags_array(list(flags))
    assert LIB.crisp_set_flags(ctx, arr, n) == C.OK
    assert LIB.crisp_add_source(ctx, text.encode(), name.encode()) == C.OK
    return LIB.crisp_compile(ctx)


def kernel_names(ctx, module=0):
    return [s(LIB.crisp_kernel_name(ctx, module, k)) for k in range(LIB.crisp_kernel_count(ctx, module))]


def param_index(ctx, kernel, name, module=0):
    for p in range(LIB.crisp_param_count(ctx, module, kernel)):
        if s(LIB.crisp_param_name(ctx, module, kernel, p)) == name:
            return p
    raise AssertionError(f"no parameter {name}")


def diagnostics(ctx):
    return [(LIB.crisp_diagnostic_severity(ctx, i), s(LIB.crisp_diagnostic_message(ctx, i)),
             s(LIB.crisp_diagnostic_file(ctx, i)))
            for i in range(LIB.crisp_diagnostic_count(ctx))]


class Basics(unittest.TestCase):

    def test_version(self):
        v = LIB.crisp_api_version()
        self.assertEqual(v >> 16, 0, "major must match CRISP_API_VERSION_MAJOR")
        self.assertEqual(v & 0xFFFF, 5, "minor 5: CRISP_TYPE_AGGREGATE")

    def test_status_strings(self):
        for st in range(8):
            self.assertTrue(LIB.crisp_status_string(st))
        self.assertEqual(LIB.crisp_status_string(99), b"unknown status")

    def test_context_create_rejects(self):
        p = ctypes.c_void_p(1234)
        self.assertEqual(LIB.crisp_context_create(b"gpu", ctypes.byref(p)), C.ERROR_INVALID_ARGUMENT)
        self.assertIsNone(p.value, "out pointer cleared on failure")
        self.assertEqual(LIB.crisp_context_create(None, ctypes.byref(p)), C.ERROR_INVALID_ARGUMENT)
        self.assertEqual(LIB.crisp_context_create(b"spv", None), C.ERROR_INVALID_ARGUMENT)

    def test_nulls_are_safe(self):
        LIB.crisp_context_destroy(None)
        self.assertEqual(LIB.crisp_compile(None), C.ERROR_INVALID_ARGUMENT)
        self.assertEqual(LIB.crisp_add_source(None, b"x", None), C.ERROR_INVALID_ARGUMENT)
        self.assertEqual(LIB.crisp_module_count(None), 0)
        self.assertEqual(LIB.crisp_diagnostics_text(None), b"")
        with Ctx() as ctx:
            self.assertEqual(LIB.crisp_add_source(ctx, None, None), C.ERROR_INVALID_ARGUMENT)
            self.assertEqual(LIB.crisp_set_flags(ctx, None, 1), C.ERROR_INVALID_ARGUMENT)
            arr = (ctypes.c_char_p * 2)(b"--single-pass", None)
            self.assertEqual(LIB.crisp_set_flags(ctx, arr, 2), C.ERROR_INVALID_ARGUMENT)

    def test_no_result_before_compile(self):
        with Ctx() as ctx:
            self.assertEqual(LIB.crisp_module_count(ctx), 0)
            st, _ = C.module_bytes(LIB, ctx)
            self.assertEqual(st, C.ERROR_NO_RESULT)
            self.assertIsNone(LIB.crisp_kernel_name(ctx, 0, 0))

    def test_no_sources(self):
        with Ctx() as ctx:
            self.assertEqual(LIB.crisp_compile(ctx), C.ERROR_INVALID_ARGUMENT)
            self.assertIn("no sources", s(LIB.crisp_diagnostics_text(ctx)))


@requires_spv
class Compile(unittest.TestCase):

    def test_spv_two_kernels(self):
        with Ctx("spv") as ctx:
            self.assertEqual(compile_text(ctx, TWO_KERNELS, "two.crisp"), C.OK, s(LIB.crisp_diagnostics_text(ctx)))
            self.assertEqual(LIB.crisp_module_count(ctx), 1)
            st, data = C.module_bytes(LIB, ctx)
            self.assertEqual(st, C.OK)
            self.assertEqual(data[:4], b"\x03\x02\x23\x07", "SPIR-V magic")
            self.assertEqual(data[-1], 0, "NUL past the end, not counted")
            self.assertEqual(kernel_names(ctx), ["k_one", "k_two"])
            self.assertIsNone(LIB.crisp_kernel_grad_of(ctx, 0, 0))

    def test_ptx_binary_is_nul_terminated_text(self):
        with Ctx("ptx") as ctx:
            self.assertEqual(compile_text(ctx, TWO_KERNELS, "two.crisp"), C.OK)
            st, data = C.module_bytes(LIB, ctx)
            self.assertEqual(data[-1], 0)
            self.assertIn(b".entry k_one", data)
            self.assertEqual(LIB.crisp_slot_type(ctx, 0, 0, 0), C.TYPE["pointer"],
                             "PTX passes the pointer as .b64, the API still says pointer")

    def test_slots_params_roles(self):
        with Ctx() as ctx:
            self.assertEqual(compile_text(ctx, TWO_KERNELS), C.OK)
            k = 0
            self.assertEqual(LIB.crisp_slot_count(ctx, 0, k), 12)
            self.assertEqual(LIB.crisp_slot_type(ctx, 0, k, 0), C.TYPE["pointer"])
            self.assertEqual(LIB.crisp_slot_size(ctx, 0, k, 0), 8)
            self.assertEqual(LIB.crisp_slot_address_space(ctx, 0, k, 0), C.ADDRESS_SPACE["global"])
            self.assertEqual(LIB.crisp_slot_type(ctx, 0, k, 1), C.TYPE["ulong"])
            self.assertEqual(LIB.crisp_slot_address_space(ctx, 0, k, 1), C.ADDRESS_SPACE["invalid"])
            self.assertEqual(LIB.crisp_param_count(ctx, 0, k), 2)
            a, b = param_index(ctx, k, "a"), param_index(ctx, k, "b")
            self.assertEqual(LIB.crisp_param_kind_of(ctx, 0, k, a), C.PARAM_KIND["tensor"])
            self.assertEqual(LIB.crisp_param_direction(ctx, 0, k, a), C.DIRECTION["in"])
            self.assertEqual(LIB.crisp_param_direction(ctx, 0, k, b), C.DIRECTION["out"])
            self.assertEqual(LIB.crisp_param_element_type(ctx, 0, k, a), C.TYPE["float"])
            self.assertEqual(LIB.crisp_param_rank(ctx, 0, k, a), 1)
            self.assertEqual(LIB.crisp_param_layout(ctx, 0, k, a), C.LAYOUT["compact"])
            self.assertEqual(LIB.crisp_param_address_space(ctx, 0, k, a), C.ADDRESS_SPACE["global"])
            roles = [("pointer", 0, 0), ("byte-size", 0, 1), ("offset", 0, 2), ("stride", 0, 3),
                     ("extent", 0, 4), ("length", 0, 5)]
            for role, axis, slot in roles:
                self.assertEqual(LIB.crisp_param_slot(ctx, 0, k, a, C.ROLE[role], axis), slot, role)
                self.assertEqual(LIB.crisp_param_slot(ctx, 0, k, b, C.ROLE[role], axis), slot + 6, role)
            self.assertEqual(LIB.crisp_param_slot(ctx, 0, k, a, C.ROLE["stride"], 1), C.NO_SLOT)
            self.assertEqual(LIB.crisp_param_slot(ctx, 0, k, a, C.ROLE["value"], 0), C.NO_SLOT)

    def test_bad_indexes(self):
        with Ctx() as ctx:
            self.assertEqual(compile_text(ctx, TWO_KERNELS), C.OK)
            self.assertEqual(LIB.crisp_kernel_count(ctx, 1), 0)
            self.assertIsNone(LIB.crisp_kernel_name(ctx, 0, 2))
            self.assertIsNone(LIB.crisp_kernel_name(ctx, 1, 0))
            self.assertEqual(LIB.crisp_slot_type(ctx, 0, 0, 12), C.TYPE["invalid"])
            self.assertEqual(LIB.crisp_slot_size(ctx, 0, 0, 999), 0)
            self.assertIsNone(LIB.crisp_param_name(ctx, 0, 0, 2))
            self.assertEqual(LIB.crisp_param_kind_of(ctx, 0, 9, 0), C.PARAM_KIND["invalid"])
            self.assertEqual(LIB.crisp_param_slot(ctx, 0, 0, 5, C.ROLE["pointer"], 0), C.NO_SLOT)
            self.assertIsNone(LIB.crisp_diagnostic_message(ctx, 0))
            st, _ = C.module_bytes(LIB, ctx, module=1)
            self.assertEqual(st, C.ERROR_INVALID_ARGUMENT)

    def test_compile_error(self):
        with Ctx() as ctx:
            self.assertEqual(compile_text(ctx, BROKEN, "broken.crisp"), C.ERROR_COMPILE)
            self.assertEqual(LIB.crisp_module_count(ctx), 0)
            st, _ = C.module_bytes(LIB, ctx)
            self.assertEqual(st, C.ERROR_NO_RESULT)
            diags = diagnostics(ctx)
            self.assertTrue(diags)
            sev, msg, file = diags[0]
            self.assertEqual(sev, C.SEVERITY_ERROR)
            self.assertTrue(msg)
            self.assertEqual(file, "broken.crisp")
            self.assertIn("broken.crisp: error:", s(LIB.crisp_diagnostics_text(ctx)))
            self.assertEqual(LIB.crisp_diagnostic_line(ctx, 0), 0, "line is unknown (TODO(190))")

    def test_results_replaced_by_next_compile(self):
        with Ctx() as ctx:
            self.assertEqual(compile_text(ctx, BROKEN, "broken.crisp"), C.ERROR_COMPILE)
            self.assertEqual(compile_text(ctx, TWO_KERNELS), C.OK)
            self.assertEqual(LIB.crisp_diagnostic_count(ctx), 0)
            self.assertEqual(kernel_names(ctx), ["k_one", "k_two"])

    def test_multiple_sources(self):
        with Ctx() as ctx:
            LIB.crisp_add_source(ctx, TYPES_ONLY.encode(), b"types.crisp")
            LIB.crisp_add_source(ctx, KERNEL_USING_TYPES.encode(), b"kern.crisp")
            self.assertEqual(LIB.crisp_compile(ctx), C.OK, s(LIB.crisp_diagnostics_text(ctx)))
            self.assertEqual(kernel_names(ctx), ["k_use"])

    def test_source_file(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "from_disk.crisp")
            with open(path, "w", encoding="utf-8") as f:
                f.write(TWO_KERNELS)
            with Ctx() as ctx:
                self.assertEqual(LIB.crisp_add_source_file(ctx, path.encode()), C.OK)
                self.assertEqual(LIB.crisp_compile(ctx), C.OK)
                self.assertEqual(kernel_names(ctx), ["k_one", "k_two"])
                self.assertEqual(LIB.crisp_add_source_file(ctx, os.path.join(d, "missing.crisp").encode()), C.ERROR_IO)

    def test_inputs_are_copied(self):
        with Ctx() as ctx:
            buf = ctypes.create_string_buffer(TWO_KERNELS.encode())
            name = ctypes.create_string_buffer(b"two.crisp")
            self.assertEqual(LIB.crisp_add_source(ctx, buf, name), C.OK)
            ctypes.memset(buf, ord("("), len(TWO_KERNELS))       # trash the caller's copy
            ctypes.memset(name, ord("x"), 5)
            self.assertEqual(LIB.crisp_compile(ctx), C.OK)
            self.assertEqual(kernel_names(ctx), ["k_one", "k_two"])

    def test_unicode_name_and_text(self):
        with Ctx() as ctx:
            text = ";; café — ünïcode comment\n" + BROKEN
            self.assertEqual(compile_text(ctx, text, "ünïcode.crisp"), C.ERROR_COMPILE)
            self.assertEqual(diagnostics(ctx)[0][2], "ünïcode.crisp")

    def test_clear_sources_keeps_flags(self):
        with Ctx() as ctx:
            arr, n = C.flags_array(["--no-such-flag"])
            LIB.crisp_set_flags(ctx, arr, n)
            LIB.crisp_add_source(ctx, TWO_KERNELS.encode(), None)
            LIB.crisp_clear_sources(ctx)
            LIB.crisp_add_source(ctx, TWO_KERNELS.encode(), None)
            self.assertEqual(LIB.crisp_compile(ctx), C.ERROR_INVALID_ARGUMENT, "the bad flag survived the clear")


@requires_spv
class Flags(unittest.TestCase):

    REJECTED = ["--hoist=l0", "--metadata", "--ir-target=ptx", "--log-level=debug", "--no-such-flag",
                "--math-precision=sloppy", "--denormal-handling=maybe", "--hardware-profile="]
    ACCEPTED = [[], ["--single-pass"], ["--runtime-checks"], ["--math-precision=ieee"],
                ["--math-precision=fast"], ["--math-precision=fast", "--denormal-handling=ftz"],
                ["--single-pass", "--runtime-checks", "--math-precision=fast"]]

    def test_rejected(self):
        with Ctx() as ctx:
            for flag in self.REJECTED:
                with self.subTest(flag=flag):
                    self.assertEqual(compile_text(ctx, TWO_KERNELS, flags=[flag]), C.ERROR_INVALID_ARGUMENT)
                    self.assertIn(flag, s(LIB.crisp_diagnostics_text(ctx)))
                    self.assertEqual(LIB.crisp_module_count(ctx), 0)

    def test_accepted(self):
        with Ctx() as ctx:
            for flags in self.ACCEPTED:
                with self.subTest(flags=flags):
                    self.assertEqual(compile_text(ctx, TWO_KERNELS, flags=flags), C.OK, s(LIB.crisp_diagnostics_text(ctx)))
                    self.assertEqual(kernel_names(ctx), ["k_one", "k_two"])

    def test_set_flags_replaces(self):
        with Ctx() as ctx:
            self.assertEqual(compile_text(ctx, TWO_KERNELS, flags=["--no-such-flag"]), C.ERROR_INVALID_ARGUMENT)
            self.assertEqual(compile_text(ctx, TWO_KERNELS, flags=["--single-pass"]), C.OK, "not additive")

    def test_fast_warns_only_on_explicit_preserve(self):
        with Ctx() as ctx:
            compile_text(ctx, TWO_KERNELS, flags=["--math-precision=fast"])
            self.assertEqual(LIB.crisp_diagnostic_count(ctx), 0)
            self.assertEqual(compile_text(ctx, TWO_KERNELS, flags=["--math-precision=fast", "--denormal-handling=preserve"]), C.OK)
            self.assertEqual([d[0] for d in diagnostics(ctx)], [C.SEVERITY_WARNING])


@requires_spv
class Differentiate(unittest.TestCase):

    def test_primal_grad_and_pairing(self):
        with Ctx() as ctx:
            self.assertEqual(compile_text(ctx, VEC_SQ_LIT, "vsl.crisp", flags=["--differentiate"]), C.OK)
            self.assertEqual(kernel_names(ctx), ["vec_sq_lit", "vec_sq_lit_grad"])
            self.assertIsNone(LIB.crisp_kernel_grad_of(ctx, 0, 0))
            self.assertEqual(s(LIB.crisp_kernel_grad_of(ctx, 0, 1)), "vec_sq_lit")
            names = [s(LIB.crisp_param_name(ctx, 0, 1, p)) for p in range(LIB.crisp_param_count(ctx, 0, 1))]
            self.assertEqual(names, ["a", "c", "c_grad", "a_grad"])
            adj = {n: s(LIB.crisp_param_adjoint_of(ctx, 0, 1, i)) for i, n in enumerate(names)}
            self.assertEqual(adj, {"a": None, "c": None, "c_grad": "c", "a_grad": "a"})
            st, data = C.module_bytes(LIB, ctx)
            self.assertIn(b"vec_sq_lit_grad", data, "both entry points are in the one module")


@requires_spv
class ImplicitParams(unittest.TestCase):
    """Item 2, step 1: scratch the compiler added is in the parameter list, with its purpose."""

    def test_grid_reduce_scratch(self):
        src = spec_source("175-reductions/25-grid-reduce-last-man-metal.crisp")
        with Ctx() as ctx:
            self.assertEqual(compile_text(ctx, src, "grid.crisp", flags=["--hardware-profile=bmg"]), C.OK,
                             s(LIB.crisp_diagnostics_text(ctx)))
            n = LIB.crisp_param_count(ctx, 0, 0)
            self.assertEqual(n, 5)
            names = [s(LIB.crisp_param_name(ctx, 0, 0, p)) for p in range(n)]
            purposes = [LIB.crisp_param_purpose(ctx, 0, 0, p) for p in range(n)]
            self.assertEqual(purposes, [C.PURPOSE["scratch"]] * 4 + [C.PURPOSE["declared"]])
            self.assertEqual(names[4], "out")
            zero = {nm.split("_")[0]: LIB.crisp_param_zero_before_launch(ctx, 0, 0, p) for p, nm in enumerate(names)}
            self.assertEqual(zero, {"flag": 0, "ctr": 1, "gv": 1, "sv": 0, "out": 0},
                             "global scratch is zeroed before every launch")
            pointers = [LIB.crisp_param_slot(ctx, 0, 0, p, C.ROLE["pointer"], 0) for p in range(n)]
            self.assertEqual(pointers, [0, 3, 6, 12, 18], "slot order")
            sv = names.index(next(nm for nm in names if nm.startswith("sv_")))
            self.assertEqual(LIB.crisp_param_address_space(ctx, 0, 0, sv), C.ADDRESS_SPACE["local"])
            self.assertEqual(LIB.crisp_param_direction(ctx, 0, 0, sv), C.DIRECTION["invalid"])
            self.assertEqual(LIB.crisp_slot_address_space(ctx, 0, 0, 12), C.ADDRESS_SPACE["local"])


def spec_source(rel):
    with open(os.path.join(C.REPO, "tests", "spec", rel), encoding="utf-8") as f:
        return f.read()


class Launch:
    """A launch object for kernel K of the context, destroyed on exit."""

    def __init__(self, ctx, k=0):
        self.p = ctypes.c_void_p()
        st = LIB.crisp_launch_create(ctx, 0, k, ctypes.byref(self.p))
        assert st == C.OK, st

    def __enter__(self):
        return self.p

    def __exit__(self, *exc):
        LIB.crisp_launch_destroy(self.p)


def groups(L):
    return tuple(LIB.crisp_launch_group_count(L, a) for a in range(3))


def local(L):
    return tuple(LIB.crisp_launch_local_size(L, a) for a in range(3))


@requires_spv
class LaunchGeometry(unittest.TestCase):
    """Item 2, step 2: the launch object does the geometry arithmetic (A10) -- the L0 hoister's
    rules, checked here case by case on the 089-strategy kernels."""

    def compiled(self, ctx, spec, flags=()):
        st = compile_text(ctx, spec_source("089-strategy/" + spec + ".crisp"), spec + ".crisp", flags=list(flags))
        self.assertEqual(st, C.OK, s(LIB.crisp_diagnostics_text(ctx)))

    def test_set_to_with_local(self):
        with Ctx() as ctx:
            self.compiled(ctx, "13-hoist-local-global-exact")          # global 1024, local 64
            with Launch(ctx) as L:
                self.assertEqual(local(L), (64, 1, 1), "known before compute")
                self.assertEqual(LIB.crisp_launch_compute(L), C.OK)
                self.assertTrue(LIB.crisp_launch_declared(L))
                self.assertEqual(groups(L), (16, 1, 1))

    def test_set_to_scalar_names(self):
        with Ctx() as ctx:
            self.compiled(ctx, "11-hoist-set-to-dims")                  # :set-to (width height)
            w, h = param_index(ctx, 0, "width"), param_index(ctx, 0, "height")
            with Launch(ctx) as L:
                self.assertEqual(LIB.crisp_launch_compute(L), C.ERROR_INVALID_ARGUMENT)
                self.assertIn("width", s(LIB.crisp_launch_message(L)), "names the missing input")
                LIB.crisp_launch_set_scalar(L, w, 100)
                LIB.crisp_launch_set_scalar(L, h, 50)
                self.assertEqual(LIB.crisp_launch_compute(L), C.OK, s(LIB.crisp_launch_message(L)))
                self.assertEqual(groups(L), (100, 50, 1), "local 1x1: one group per item")
                self.assertEqual(LIB.crisp_launch_message(L), b"")

    def test_one_thread_per_tensor(self):
        with Ctx() as ctx:
            self.compiled(ctx, "22-derive-from-vector-one-thread-per")  # local 256
            with Launch(ctx) as L:
                LIB.crisp_launch_set_extent(L, param_index(ctx, 0, "input"), 0, 1000)
                self.assertEqual(LIB.crisp_launch_compute(L), C.OK, s(LIB.crisp_launch_message(L)))
                self.assertEqual(groups(L), (4, 1, 1), "ceil(1000 / 256)")

    def test_one_thread_per_scalars(self):
        with Ctx() as ctx:
            self.compiled(ctx, "12-hoist-one-thread-per")
            with Launch(ctx) as L:
                LIB.crisp_launch_set_scalar(L, param_index(ctx, 0, "width"), 640)
                LIB.crisp_launch_set_scalar(L, param_index(ctx, 0, "height"), 480)
                self.assertEqual(LIB.crisp_launch_compute(L), C.OK, s(LIB.crisp_launch_message(L)))
                self.assertEqual(groups(L), (640, 480, 1))

    def test_strided_occupancy(self):
        with Ctx() as ctx:
            self.compiled(ctx, "23-strided-with-occupancy")             # :occupancy 0.5
            with Launch(ctx) as L:
                self.assertEqual(LIB.crisp_launch_compute(L), C.ERROR_INVALID_ARGUMENT)
                self.assertIn("resident", s(LIB.crisp_launch_message(L)))
                LIB.crisp_launch_set_resident_groups(L, 640)
                self.assertEqual(LIB.crisp_launch_compute(L), C.OK)
                self.assertEqual(groups(L), (320, 1, 1), "half of 640")

    def test_exact_tile_grid_scalars(self):
        with Ctx() as ctx:
            self.compiled(ctx, "15-hoist-exact-tiled")                  # tile 16x16, local 16x16
            with Launch(ctx) as L:
                self.assertEqual(local(L), (16, 16, 1))
                LIB.crisp_launch_set_scalar(L, param_index(ctx, 0, "width"), 100)
                LIB.crisp_launch_set_scalar(L, param_index(ctx, 0, "height"), 33)
                self.assertEqual(LIB.crisp_launch_compute(L), C.OK, s(LIB.crisp_launch_message(L)))
                self.assertEqual(groups(L), (7, 3, 1))

    def test_tile_grid_uses_extents_and_limits(self):
        with Ctx() as ctx:
            self.compiled(ctx, "26-tile-grid-uses-extents-not-length")  # :exact, tile 32x32, from C
            c = param_index(ctx, 0, "c")
            with Launch(ctx) as L:
                LIB.crisp_launch_set_extent(L, c, 0, 100)
                LIB.crisp_launch_set_extent(L, c, 1, 70)
                self.assertEqual(LIB.crisp_launch_compute(L), C.OK, s(LIB.crisp_launch_message(L)))
                self.assertEqual(groups(L), (4, 3, 1), "per-axis extents, not the flat length")
                LIB.crisp_launch_set_max_group_count(L, 2, 2, 2)
                self.assertEqual(LIB.crisp_launch_compute(L), C.ERROR_INVALID_ARGUMENT, ":exact must not clamp")
                self.assertIn("exact", s(LIB.crisp_launch_message(L)))
        with Ctx() as ctx:
            self.compiled(ctx, "25-tile-shape-explicit-wins")           # :strided, tile 64x64, from C
            c = param_index(ctx, 0, "c")
            with Launch(ctx) as L:
                LIB.crisp_launch_set_extent(L, c, 0, 200)
                LIB.crisp_launch_set_extent(L, c, 1, 130)
                LIB.crisp_launch_set_max_group_count(L, 2, 2, 2)
                self.assertEqual(LIB.crisp_launch_compute(L), C.OK, "a tile grid needs no occupancy")
                self.assertEqual(groups(L), (2, 2, 1), ":strided clamps (4, 3) -- its stride loop covers the rest")

    def test_interleaved_and_undeclared(self):
        with Ctx() as ctx:
            self.compiled(ctx, "18-hoist-interleaved-comment")
            with Launch(ctx) as L:
                self.assertEqual(LIB.crisp_launch_compute(L), C.OK)
                self.assertEqual(groups(L), (1, 1, 1))
        with Ctx() as ctx:
            self.assertEqual(compile_text(ctx, TWO_KERNELS), C.OK)
            with Launch(ctx) as L:
                self.assertEqual(LIB.crisp_launch_compute(L), C.OK)
                self.assertFalse(LIB.crisp_launch_declared(L))
                self.assertEqual(groups(L), (1, 1, 1))
                self.assertEqual(local(L), (1, 1, 1))

    def test_scratch_bytes(self):
        with Ctx() as ctx:
            self.assertEqual(compile_text(ctx, spec_source("175-reductions/25-grid-reduce-last-man-metal.crisp"),
                                          "grid.crisp", flags=["--hardware-profile=bmg"]), C.OK)
            names = [s(LIB.crisp_param_name(ctx, 0, 0, p)) for p in range(LIB.crisp_param_count(ctx, 0, 0))]
            ix = {nm.split("_")[0]: i for i, nm in enumerate(names)}
            with Launch(ctx) as L:
                self.assertEqual(LIB.crisp_launch_compute(L), C.OK, s(LIB.crisp_launch_message(L)))
                self.assertEqual(groups(L), (4, 1, 1), "global 256 / local 64")
                b = {k: LIB.crisp_launch_param_bytes(L, i) for k, i in ix.items()}
                self.assertEqual(b, {"flag": 4, "ctr": 4, "gv": 16, "sv": 16, "out": 0},
                                 "sv: ceil(64 / 16 BMG lanes) = 4 floats")
                LIB.crisp_launch_set_warp_size(L, 32)
                LIB.crisp_launch_compute(L)
                self.assertEqual(LIB.crisp_launch_param_bytes(L, ix["sv"]), 8, "ceil(64 / 32) = 2 floats")
                self.assertEqual(LIB.crisp_launch_shared_bytes(L), 0, "SPIR-V: no shared block")

    def test_scratch_per_workgroup(self):
        with Ctx() as ctx:
            self.assertEqual(compile_text(ctx, spec_source("181-last-man-sweep/02-last-man-match-num-workgroups-metal.crisp"),
                                          "lm.crisp", flags=["--hardware-profile=bmg"]), C.OK)
            names = [s(LIB.crisp_param_name(ctx, 0, 0, p)) for p in range(LIB.crisp_param_count(ctx, 0, 0))]
            gv = next(i for i, nm in enumerate(names) if nm.startswith("gv_"))
            with Launch(ctx) as L:
                self.assertEqual(LIB.crisp_launch_compute(L), C.OK, s(LIB.crisp_launch_message(L)))
                self.assertEqual(groups(L), (128, 1, 1), "4096 / 32")
                self.assertEqual(LIB.crisp_launch_param_bytes(L, gv), 128 * 4, "one float per workgroup")

    def test_launch_bad_arguments(self):
        with Ctx() as ctx:
            p = ctypes.c_void_p()
            self.assertEqual(LIB.crisp_launch_create(ctx, 0, 0, ctypes.byref(p)), C.ERROR_NO_RESULT)
            self.assertEqual(compile_text(ctx, TWO_KERNELS), C.OK)
            self.assertEqual(LIB.crisp_launch_create(ctx, 0, 9, ctypes.byref(p)), C.ERROR_INVALID_ARGUMENT)
            with Launch(ctx) as L:
                self.assertEqual(LIB.crisp_launch_group_count(L, 0), 0, "nothing before compute")
                self.assertEqual(LIB.crisp_launch_set_extent(L, 99, 0, 1), C.ERROR_INVALID_ARGUMENT)
                self.assertEqual(LIB.crisp_launch_set_warp_size(L, 0), C.ERROR_INVALID_ARGUMENT)
            LIB.crisp_launch_destroy(None)


class Aggregates(unittest.TestCase):
    """By-value structs and fixed arrays (found on the H100: their slots were sized 0, which a Level
    Zero caller passes straight to zeKernelSetArgumentValue)."""

    def test_struct_and_array_slot_sizes(self):
        for target in TARGETS:
            with self.subTest(target=target), Ctx(target) as ctx:
                # (def-struct point (x fff) (y int)) passed by value: float + int, natural alignment = 8
                self.assertEqual(compile_text(ctx, spec_source("056-struct-at-kernel-boundary/05-basic-strut-hoist.crisp"),
                                              "s.crisp"), C.OK, s(LIB.crisp_diagnostics_text(ctx)))
                self.assertEqual(LIB.crisp_slot_type(ctx, 0, 0, 0), C.TYPE["aggregate"])
                self.assertEqual(LIB.crisp_slot_size(ctx, 0, 0, 0), 8)
            with self.subTest(target=target, case="array"), Ctx(target) as ctx:
                # (def-record data-rec (counts (array int 4))): the array field is one 16-byte slot
                self.assertEqual(compile_text(ctx, spec_source("060-array/16-hoist-record-with-array.crisp"),
                                              "a.crisp"), C.OK, s(LIB.crisp_diagnostics_text(ctx)))
                self.assertEqual(LIB.crisp_slot_type(ctx, 0, 0, 0), C.TYPE["aggregate"])
                self.assertEqual(LIB.crisp_slot_size(ctx, 0, 0, 0), 16)


class PtxLaunch(unittest.TestCase):
    """The PTX rules (hoist-cuda %emit-launch-base): where CUDA differs from L0, local scratch as
    offsets into one dynamic shared block, and thread-block clusters."""

    def compiled(self, ctx, rel, flags=()):
        name = os.path.basename(rel)
        st = compile_text(ctx, spec_source(rel), name, flags=list(flags))
        self.assertEqual(st, C.OK, s(LIB.crisp_diagnostics_text(ctx)))

    def test_cuda_sizes_two_axes(self):
        for target, expect in [c for c in (("spv", (640, 480, 7)), ("ptx", (640, 480, 1))) if c[0] in TARGETS]:
            with self.subTest(target=target), Ctx(target) as ctx:
                self.compiled(ctx, "089-strategy/17-hoist-3d.crisp")      # :derive-from (w h d)
                with Launch(ctx) as L:
                    for nm, v in (("w", 640), ("h", 480), ("d", 7)):
                        LIB.crisp_launch_set_scalar(L, param_index(ctx, 0, nm), v)
                    self.assertEqual(LIB.crisp_launch_compute(L), C.OK, s(LIB.crisp_launch_message(L)))
                    self.assertEqual(groups(L), expect, "CUDA leaves gridZ = 1")

    def test_cuda_interleaved_takes_ordinary_rules(self):
        for target, expect in [c for c in (("spv", (1, 1, 1)), ("ptx", (1000, 1, 1))) if c[0] in TARGETS]:
            with self.subTest(target=target), Ctx(target) as ctx:
                self.compiled(ctx, "089-strategy/18-hoist-interleaved-comment.crisp")   # :derive-from (n)
                with Launch(ctx) as L:
                    LIB.crisp_launch_set_scalar(L, param_index(ctx, 0, "n"), 1000)
                    self.assertEqual(LIB.crisp_launch_compute(L), C.OK, s(LIB.crisp_launch_message(L)))
                    self.assertEqual(groups(L), expect)

    def test_shared_block_layout(self):
        with Ctx("ptx") as ctx:
            self.compiled(ctx, "175-reductions/25-grid-reduce-last-man-metal.crisp")
            names = [s(LIB.crisp_param_name(ctx, 0, 0, p)) for p in range(LIB.crisp_param_count(ctx, 0, 0))]
            ix = {nm.split("_")[0]: i for i, nm in enumerate(names)}
            with Launch(ctx) as L:
                self.assertEqual(LIB.crisp_launch_compute(L), C.OK, s(LIB.crisp_launch_message(L)))
                # sv: a LOCAL tensor of ceil(64/32) = 2 floats (no profile: 32 lanes) at offset 0;
                # flag: a LOCAL uint cell after the tensors, from round8(8) = 8; block = 12 bytes
                self.assertEqual(LIB.crisp_launch_param_bytes(L, ix["sv"]), 8)
                self.assertEqual(LIB.crisp_launch_param_shared_offset(L, ix["sv"]), 0)
                self.assertEqual(LIB.crisp_launch_param_shared_offset(L, ix["flag"]), 8)
                self.assertEqual(LIB.crisp_launch_shared_bytes(L), 12)
                self.assertEqual(LIB.crisp_launch_param_shared_offset(L, ix["ctr"]), C.NO_SHARED_OFFSET, "global")
                self.assertEqual(LIB.crisp_launch_param_shared_offset(L, ix["out"]), C.NO_SHARED_OFFSET)
        if not SPV:
            return
        with Ctx("spv") as ctx:
            self.compiled(ctx, "175-reductions/25-grid-reduce-last-man-metal.crisp")
            with Launch(ctx) as L:
                LIB.crisp_launch_compute(L)
                self.assertEqual(LIB.crisp_launch_shared_bytes(L), 0, "SPIR-V: no shared block")
                self.assertEqual(LIB.crisp_launch_param_shared_offset(L, 0), C.NO_SHARED_OFFSET)

    def test_cluster_pads_strided(self):
        with Ctx("ptx") as ctx:
            self.compiled(ctx, "152-DSMEM-Cluster/02-cluster-size-shape.crisp", flags=["--ir-target-arch=sm_90"])
            c = param_index(ctx, 0, "c")
            with Launch(ctx) as L:
                self.assertEqual((LIB.crisp_launch_cluster_size(L, 0), LIB.crisp_launch_cluster_size(L, 1)), (2, 1))
                LIB.crisp_launch_set_extent(L, c, 0, 24)      # tile 8x8: grid (3, 2)
                LIB.crisp_launch_set_extent(L, c, 1, 16)
                self.assertEqual(LIB.crisp_launch_compute(L), C.OK, s(LIB.crisp_launch_message(L)))
                self.assertEqual(groups(L), (4, 2, 1), "x padded 3 -> 4 for the 2-wide cluster")

    def test_cluster_reach_refuses_padding(self):
        with Ctx("ptx") as ctx:
            self.compiled(ctx, "152-DSMEM-Cluster/26-cluster-reach-refuses-padding.crisp", flags=["--ir-target-arch=sm_90"])
            c = param_index(ctx, 0, "c")
            with Launch(ctx) as L:
                LIB.crisp_launch_set_extent(L, c, 0, 48)      # tile 16x16: grid (3, 3), cluster (2, 2)
                LIB.crisp_launch_set_extent(L, c, 1, 48)
                self.assertEqual(LIB.crisp_launch_compute(L), C.ERROR_INVALID_ARGUMENT)
                self.assertIn("cluster", s(LIB.crisp_launch_message(L)))
                LIB.crisp_launch_set_extent(L, c, 0, 64)      # grid (4, 4): divisible, fine
                LIB.crisp_launch_set_extent(L, c, 1, 64)
                self.assertEqual(LIB.crisp_launch_compute(L), C.OK, s(LIB.crisp_launch_message(L)))
                self.assertEqual(groups(L), (4, 4, 1))


@requires_spv
class Processes(unittest.TestCase):

    def test_parallel_contexts(self):
        results = {}

        def work(i):
            with Ctx("ptx" if i % 2 else "spv") as ctx:
                results[i] = (compile_text(ctx, TWO_KERNELS, f"t{i}.crisp"), kernel_names(ctx))

        threads = [threading.Thread(target=work, args=(i,)) for i in range(6)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=600)
        self.assertEqual(sorted(results), list(range(6)))
        for i, (st, names) in results.items():
            self.assertEqual(st, C.OK, f"thread {i}")
            self.assertEqual(names, ["k_one", "k_two"])

    def test_shutdown_then_compile_again(self):
        with Ctx() as ctx:
            self.assertEqual(compile_text(ctx, TWO_KERNELS), C.OK)
            LIB.crisp_shutdown()
            self.assertEqual(compile_text(ctx, TWO_KERNELS), C.OK, "a fresh helper starts")

    def test_missing_compiler(self):
        LIB.crisp_shutdown()                       # no idle helper may answer for the bogus one
        old = os.environ.get("CRISP_COMPILE_EXE")
        os.environ["CRISP_COMPILE_EXE"] = os.path.join(C.REPO, "bin", "no-such-compiler.exe")
        try:
            with Ctx() as ctx:
                self.assertEqual(compile_text(ctx, TWO_KERNELS), C.ERROR_COMPILER_PROCESS)
                self.assertIn("no-such-compiler", s(LIB.crisp_diagnostics_text(ctx)))
        finally:
            if old is None:
                del os.environ["CRISP_COMPILE_EXE"]
            else:
                os.environ["CRISP_COMPILE_EXE"] = old
        with Ctx() as ctx:
            self.assertEqual(compile_text(ctx, TWO_KERNELS), C.OK, "recovers once the compiler is findable")


if __name__ == "__main__":
    result = unittest.main(exit=False, verbosity=2).result
    LIB.crisp_shutdown()
    sys.exit(0 if result.wasSuccessful() else 1)
