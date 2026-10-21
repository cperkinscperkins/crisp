"""crisp_ctypes -- a thin ctypes binding of c-api/include/crisp.h, for tests/api/.

Every function gets explicit argtypes/restype: ctypes' default (int) would truncate size_t and
pointers on 64-bit.  This is deliberately a 1:1 binding, not a Pythonic wrapper -- the tests
exercise the C boundary as a C caller sees it.

The library is found at $CRISP_LIB, else bin/crisp.dll (Windows) / bin/libcrisp.so (elsewhere),
relative to the repo root (two directories above this file).
"""
import ctypes
import os
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

# enums (crisp.h)
OK, ERROR_COMPILE, ERROR_INVALID_ARGUMENT, ERROR_NO_RESULT, ERROR_IO, \
    ERROR_COMPILER_PROCESS, ERROR_OUT_OF_MEMORY, ERROR_INTERNAL = range(8)
SEVERITY_INVALID, SEVERITY_ERROR, SEVERITY_WARNING, SEVERITY_NOTE = range(4)
TYPE = {name: i for i, name in enumerate(
    ["invalid", "char", "uchar", "short", "ushort", "int", "uint", "long", "ulong",
     "half", "bfloat16", "float", "double", "pointer"])}
ADDRESS_SPACE = {"invalid": 0, "global": 1, "constant": 2, "local": 3}
PARAM_KIND = {"invalid": 0, "scalar": 1, "cell": 2, "tensor": 3, "record": 4}
DIRECTION = {"invalid": 0, "in": 1, "out": 2}
LAYOUT = {"invalid": 0, "compact": 1, "compact-offset": 2, "strided": 3}
PURPOSE = {"invalid": 0, "declared": 1, "scratch": 2, "debug-log": 3, "tensor-map": 4}
ROLE = {"invalid": 0, "value": 1, "pointer": 2, "byte-size": 3, "offset": 4, "stride": 5,
        "extent": 6, "length": 7, "field": 8}
NO_SLOT = ctypes.c_size_t(-1).value


def library_path():
    env = os.environ.get("CRISP_LIB")
    if env:
        return env
    name = "crisp.dll" if sys.platform == "win32" else "libcrisp.so"
    return os.path.join(REPO, "bin", name)


def load(path=None):
    lib = ctypes.CDLL(path or library_path())
    ctx_p = ctypes.c_void_p
    S, P, U32, CS, I = ctypes.c_size_t, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_char_p, ctypes.c_int

    def fn(name, restype, *argtypes):
        f = getattr(lib, name)
        f.restype = restype
        f.argtypes = list(argtypes)

    fn("crisp_api_version", U32)
    fn("crisp_status_string", CS, I)
    fn("crisp_context_create", I, CS, ctypes.POINTER(ctx_p))
    fn("crisp_context_destroy", None, ctx_p)
    fn("crisp_set_flags", I, ctx_p, ctypes.POINTER(CS), S)
    fn("crisp_add_source", I, ctx_p, CS, CS)
    fn("crisp_add_source_file", I, ctx_p, CS)
    fn("crisp_clear_sources", I, ctx_p)
    fn("crisp_compile", I, ctx_p)
    fn("crisp_shutdown", None)
    fn("crisp_diagnostic_count", S, ctx_p)
    fn("crisp_diagnostic_severity", I, ctx_p, S)
    fn("crisp_diagnostic_message", CS, ctx_p, S)
    fn("crisp_diagnostic_file", CS, ctx_p, S)
    fn("crisp_diagnostic_line", U32, ctx_p, S)
    fn("crisp_diagnostic_column", U32, ctx_p, S)
    fn("crisp_diagnostics_text", CS, ctx_p)
    fn("crisp_module_count", S, ctx_p)
    fn("crisp_module_binary", I, ctx_p, S, ctypes.POINTER(P), ctypes.POINTER(S))
    fn("crisp_kernel_count", S, ctx_p, S)
    fn("crisp_kernel_name", CS, ctx_p, S, S)
    fn("crisp_kernel_grad_of", CS, ctx_p, S, S)
    fn("crisp_slot_count", S, ctx_p, S, S)
    fn("crisp_slot_type", I, ctx_p, S, S, S)
    fn("crisp_slot_size", S, ctx_p, S, S, S)
    fn("crisp_slot_address_space", I, ctx_p, S, S, S)
    fn("crisp_param_count", S, ctx_p, S, S)
    fn("crisp_param_purpose", I, ctx_p, S, S, S)
    fn("crisp_param_zero_before_launch", I, ctx_p, S, S, S)
    fn("crisp_param_name", CS, ctx_p, S, S, S)
    fn("crisp_param_kind_of", I, ctx_p, S, S, S)
    fn("crisp_param_direction", I, ctx_p, S, S, S)
    fn("crisp_param_element_type", I, ctx_p, S, S, S)
    fn("crisp_param_rank", U32, ctx_p, S, S, S)
    fn("crisp_param_layout", I, ctx_p, S, S, S)
    fn("crisp_param_address_space", I, ctx_p, S, S, S)
    fn("crisp_param_adjoint_of", CS, ctx_p, S, S, S)
    fn("crisp_param_slot", S, ctx_p, S, S, S, I, U32)
    U64 = ctypes.c_uint64
    fn("crisp_launch_create", I, ctx_p, S, S, ctypes.POINTER(ctypes.c_void_p))
    fn("crisp_launch_destroy", None, P)
    fn("crisp_launch_set_extent", I, P, S, U32, U64)
    fn("crisp_launch_set_scalar", I, P, S, U64)
    fn("crisp_launch_set_resident_groups", I, P, U64)
    fn("crisp_launch_set_warp_size", I, P, U32)
    fn("crisp_launch_set_max_group_count", I, P, U32, U32, U32)
    fn("crisp_launch_compute", I, P)
    fn("crisp_launch_message", CS, P)
    fn("crisp_launch_declared", I, P)
    fn("crisp_launch_local_size", U32, P, U32)
    fn("crisp_launch_group_count", U32, P, U32)
    fn("crisp_launch_param_bytes", U64, P, S)
    fn("crisp_launch_shared_bytes", U64, P)
    return lib


def flags_array(flags):
    """A (const char* const*, count) pair for crisp_set_flags."""
    arr = (ctypes.c_char_p * len(flags))(*[f.encode() for f in flags])
    return arr, len(flags)


def module_bytes(lib, ctx, module=0):
    """(status, bytes-or-None).  The bytes include ONE extra byte past the reported size, so a test
    can check the NUL terminator the header promises."""
    data, size = ctypes.c_void_p(), ctypes.c_size_t()
    st = lib.crisp_module_binary(ctx, module, ctypes.byref(data), ctypes.byref(size))
    if st != OK:
        return st, None
    return st, ctypes.string_at(data.value, size.value + 1)
