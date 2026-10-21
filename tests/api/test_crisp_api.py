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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
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
        self.assertEqual(v & 0xFFFF, 2, "minor 2: implicit params (purpose, zero-before-launch)")

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


class ImplicitParams(unittest.TestCase):
    """Item 2, step 1: scratch the compiler added is in the parameter list, with its purpose."""

    def test_grid_reduce_scratch(self):
        src = open(os.path.join(C.REPO, "tests", "spec", "175-reductions", "25-grid-reduce-last-man-metal.crisp"),
                   encoding="utf-8").read()
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
