"""crisp_gpu -- compile Crisp GPU kernels from Python, at run time.

    import crisp_gpu
    mod = crisp_gpu.compile(source, target="ptx", flags=["--hardware-profile=h100"])
    mod.binary            # PTX text (bytes) -> cuModuleLoadData;  SPIR-V for target="spv"
    for k in mod.kernels:
        print(k.name, [(p.name, p.direction, p.element_type) for p in k.params])

`crisp_gpu.torch` launches the compiled kernels on PyTorch CUDA tensors.

This is a thin layer over Crisp's C compile API (c-api/include/crisp.h).  The compiler itself runs
in helper processes (`crisp-compile --serve`) that start on the first compile and stop when Python
exits.  The binaries live in this package's bin/ directory.
"""
import atexit
import ctypes
import os
import stat
import sys
from collections import namedtuple

from . import _capi

__version__ = "0.5.0"
__all__ = ["compile", "compile_file", "Module", "Kernel", "Param", "Diagnostic", "CompileError",
           "bin_dir", "shutdown", "__version__"]

_HERE = os.path.dirname(os.path.abspath(__file__))
_EXE = ".exe" if sys.platform == "win32" else ""


def bin_dir():
    """The directory holding crisp-compile, libcrisp, libLLVM and the LLVM tools."""
    return os.path.join(_HERE, "bin")


def _ensure_executable(path):
    """pip keeps a wheel's exec bits, but a copied or unpacked tree may not: restore them."""
    try:
        mode = os.stat(path).st_mode
        if os.path.isfile(path) and not mode & stat.S_IXUSR:
            os.chmod(path, mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    except OSError:
        pass


def _prepare_bin():
    if sys.platform != "win32":
        for name in os.listdir(bin_dir()):
            if not name.endswith((".so", ".txt")) and ".so." not in name:
                _ensure_executable(os.path.join(bin_dir(), name))


_lib = None


def _library():
    global _lib
    if _lib is None:
        _prepare_bin()
        name = "crisp.dll" if sys.platform == "win32" else "libcrisp.so"
        _lib = _capi.load(os.environ.get("CRISP_LIB") or os.path.join(bin_dir(), name))
        major = _lib.crisp_api_version() >> 16
        if major != 0:
            raise ImportError(f"crisp_gpu {__version__} needs compile API 0.x, found {major}.x")
        atexit.register(shutdown)
    return _lib


def shutdown():
    """Stop the compiler helper processes now (optional: they also stop when Python exits)."""
    if _lib is not None:
        _lib.crisp_shutdown()


def _enum_name(table, value):
    for k, v in table.items():
        if v == value:
            return k
    return None


def _s(b):
    return b.decode("utf-8", "replace") if b is not None else None


Diagnostic = namedtuple("Diagnostic", "severity message file line column")
Diagnostic.__doc__ = "One compiler message: severity is 'error', 'warning' or 'note'."

Param = namedtuple("Param", "index name kind direction element_type rank layout address_space "
                            "purpose adjoint_of zero_before_launch")
Param.__doc__ = """One kernel parameter, as the compiler describes it.
    kind:         'scalar' | 'tensor' | 'cell' | 'record'
    direction:    'in' | 'out' (None when not applicable)
    element_type: 'float', 'half', 'int', ... ('pointer' / 'aggregate' for compound values)
    purpose:      'declared' (written by you) or an implicit one the compiler added ('scratch', ...)
    adjoint_of:   for a gradient kernel's adjoint parameter, the primal parameter it belongs to"""


class CompileError(Exception):
    """A compile that did not succeed.  .diagnostics holds the messages, .text the formatted report."""

    def __init__(self, text, diagnostics):
        super().__init__(text)
        self.text = text
        self.diagnostics = diagnostics


class Kernel:
    """One compiled kernel: its entry-point name, its parameters, and (for a gradient kernel made by
    --differentiate) the name of the forward kernel it differentiates."""

    def __init__(self, module, index):
        lib, ctx = module._lib, module._ctx
        self.module = module
        self.index = index
        self.name = _s(lib.crisp_kernel_name(ctx, 0, index))
        self.grad_of = _s(lib.crisp_kernel_grad_of(ctx, 0, index))
        self.params = [self._param(lib, ctx, p) for p in range(lib.crisp_param_count(ctx, 0, index))]

    def _param(self, lib, ctx, p):
        k = self.index
        return Param(index=p,
                     name=_s(lib.crisp_param_name(ctx, 0, k, p)),
                     kind=_enum_name(_capi.PARAM_KIND, lib.crisp_param_kind_of(ctx, 0, k, p)),
                     direction=_enum_name(_capi.DIRECTION, lib.crisp_param_direction(ctx, 0, k, p)),
                     element_type=_enum_name(_capi.TYPE, lib.crisp_param_element_type(ctx, 0, k, p)),
                     rank=lib.crisp_param_rank(ctx, 0, k, p),
                     layout=_enum_name(_capi.LAYOUT, lib.crisp_param_layout(ctx, 0, k, p)),
                     address_space=_enum_name(_capi.ADDRESS_SPACE, lib.crisp_param_address_space(ctx, 0, k, p)),
                     purpose=_enum_name(_capi.PURPOSE, lib.crisp_param_purpose(ctx, 0, k, p)),
                     adjoint_of=_s(lib.crisp_param_adjoint_of(ctx, 0, k, p)),
                     zero_before_launch=bool(lib.crisp_param_zero_before_launch(ctx, 0, k, p)))

    def param(self, name):
        """The parameter called NAME (Crisp names are case-insensitive)."""
        for p in self.params:
            if p.name.lower() == name.lower():
                return p
        raise KeyError(f"{self.name} has no parameter {name!r}")

    def __repr__(self):
        return f"<crisp_gpu.Kernel {self.name} ({', '.join(p.name for p in self.params)})>"


class Module:
    """The result of one successful compile: a GPU binary plus a description of its kernels.

    .target       'ptx' or 'spv'
    .binary       the PTX text or SPIR-V words, as bytes
    .kernels      [Kernel, ...]
    .diagnostics  warnings and notes from the compile

    The module keeps its compile-API context open (launch geometry and argument placement are asked
    of it); close() releases it early, otherwise it goes with the object."""

    def __init__(self, lib, ctx, target):
        self._lib, self._ctx, self.target = lib, ctx, target
        data, size = ctypes.c_void_p(), ctypes.c_size_t()
        st = lib.crisp_module_binary(ctx, 0, ctypes.byref(data), ctypes.byref(size))
        if st != _capi.OK:
            raise RuntimeError(f"crisp_module_binary: {_s(lib.crisp_status_string(st))}")
        self.binary = ctypes.string_at(data.value, size.value)
        self.diagnostics = _diagnostics(lib, ctx)
        self.kernels = [Kernel(self, k) for k in range(lib.crisp_kernel_count(ctx, 0))]

    def kernel(self, name):
        """The kernel called NAME."""
        for k in self.kernels:
            if k.name == name or k.name.lower() == name.lower():
                return k
        raise KeyError(f"no kernel {name!r}; have {[k.name for k in self.kernels]}")

    def grad_kernel(self, forward_name):
        """The gradient kernel --differentiate made for FORWARD_NAME."""
        for k in self.kernels:
            if k.grad_of and k.grad_of.lower() == forward_name.lower():
                return k
        raise KeyError(f"no gradient kernel for {forward_name!r} (was it compiled with --differentiate?)")

    def close(self):
        if self._ctx:
            self._lib.crisp_context_destroy(self._ctx)
            self._ctx = None

    def __del__(self):
        try:
            self.close()
        except Exception:
            pass

    def __repr__(self):
        return f"<crisp_gpu.Module {self.target} {len(self.binary)} bytes, kernels {[k.name for k in self.kernels]}>"


_SEVERITY = {_capi.SEVERITY_ERROR: "error", _capi.SEVERITY_WARNING: "warning", _capi.SEVERITY_NOTE: "note"}


def _diagnostics(lib, ctx):
    out = []
    for i in range(lib.crisp_diagnostic_count(ctx)):
        out.append(Diagnostic(severity=_SEVERITY.get(lib.crisp_diagnostic_severity(ctx, i)),
                              message=_s(lib.crisp_diagnostic_message(ctx, i)),
                              file=_s(lib.crisp_diagnostic_file(ctx, i)),
                              line=lib.crisp_diagnostic_line(ctx, i),
                              column=lib.crisp_diagnostic_column(ctx, i)))
    return out


def _compile(target, flags, add_sources):
    if target not in ("ptx", "spv"):
        raise ValueError(f"target must be 'ptx' or 'spv', not {target!r}")
    lib = _library()
    ctx = ctypes.c_void_p()
    st = lib.crisp_context_create(target.encode(), ctypes.byref(ctx))
    if st != _capi.OK:
        raise RuntimeError(f"crisp_context_create: {_s(lib.crisp_status_string(st))}")
    try:
        flags = list(flags)
        arr, n = _capi.flags_array(flags)
        st = lib.crisp_set_flags(ctx, arr, n)
        if st != _capi.OK:
            raise ValueError(f"flags {flags}: {_s(lib.crisp_diagnostics_text(ctx)) or _s(lib.crisp_status_string(st))}")
        add_sources(lib, ctx)
        st = lib.crisp_compile(ctx)
        if st != _capi.OK:
            text = _s(lib.crisp_diagnostics_text(ctx)) or _s(lib.crisp_status_string(st))
            raise CompileError(text, _diagnostics(lib, ctx))
        return Module(lib, ctx, target)
    except BaseException:
        lib.crisp_context_destroy(ctx)
        raise


def compile(source, target="ptx", flags=(), name="kernel.crisp"):
    """Compile Crisp SOURCE (a string, or a list of strings compiled together) for TARGET ('ptx' for
    NVIDIA, 'spv' for SPIR-V / Intel).  FLAGS are crisp-compile's flags, e.g. '--differentiate',
    '--hardware-profile=h100', '--ir-target-arch=sm_90a', '-DN=64'.  NAME is the file name used in
    messages.  Returns a Module; raises CompileError with the compiler's messages."""
    sources = [source] if isinstance(source, str) else list(source)

    def add(lib, ctx):
        for i, s in enumerate(sources):
            nm = name if len(sources) == 1 else f"{i}-{name}"
            st = lib.crisp_add_source(ctx, s.encode("utf-8"), nm.encode())
            if st != _capi.OK:
                raise RuntimeError(f"crisp_add_source: {_s(lib.crisp_status_string(st))}")
    return _compile(target, flags, add)


def compile_file(path, target="ptx", flags=()):
    """Compile the .crisp file(s) at PATH (a path or a list of paths).  See compile()."""
    paths = [path] if isinstance(path, (str, os.PathLike)) else list(path)

    def add(lib, ctx):
        for p in paths:
            st = lib.crisp_add_source_file(ctx, os.fspath(os.path.abspath(p)).encode())
            if st != _capi.OK:
                raise FileNotFoundError(f"{p}: {_s(lib.crisp_status_string(st))}")
    return _compile(target, flags, add)
