"""crisp_gpu.torch -- run compiled Crisp kernels on PyTorch CUDA tensors.

    import torch, crisp_gpu, crisp_gpu.torch as ct
    mod = ct.load(crisp_gpu.compile(src, flags=["--differentiate"]))
    mod.launch("square_scale", x=x, w=w, y=y)              # by parameter name
    f = ct.autograd_function(mod, "square_scale")           # forward AND gradient are Crisp kernels
    y = f(x, w); y.sum().backward()

Kernels run in PyTorch's own CUDA context and current stream, through the CUDA driver API.  Nothing
here knows a kernel's argument layout: every argument is placed by ROLE (crisp_param_slot), the grid
comes from the compile API's launch object, and a gradient kernel is wired by the API's adjoint
pairing.  Supported parameters: tensors (any element type the API reports), scalars, and the
compiler's implicit scratch buffers.  Thread-block clusters (sm_90 DSMEM kernels) are not launched
from here yet.
"""
import ctypes
import struct

import torch

from . import _capi, Module

_P, _U = ctypes.c_void_p, ctypes.c_uint
_cuda = None

_DTYPES = {"float": torch.float32, "double": torch.float64, "half": torch.float16,
           "bfloat16": torch.bfloat16, "char": torch.int8, "uchar": torch.uint8,
           "short": torch.int16, "int": torch.int32, "long": torch.int64}
for _n, _a in (("ushort", "uint16"), ("uint", "uint32"), ("ulong", "uint64")):
    if hasattr(torch, _a):
        _DTYPES[_n] = getattr(torch, _a)

# struct formats by slot type, for scalar values
_PACK = {"char": "b", "uchar": "B", "short": "h", "ushort": "H", "int": "i", "uint": "I",
         "long": "q", "ulong": "Q", "half": "e", "float": "f", "double": "d", "pointer": "Q"}

_CU_FUNC_ATTRIBUTE_MAX_DYNAMIC_SHARED_SIZE_BYTES = 8


def _driver():
    global _cuda
    if _cuda is None:
        cuda = ctypes.CDLL("libcuda.so.1" if not hasattr(ctypes, "WinDLL") else "nvcuda.dll")
        for name, args in (("cuDeviceGet", [ctypes.POINTER(ctypes.c_int), ctypes.c_int]),
                           ("cuDevicePrimaryCtxRetain", [ctypes.POINTER(_P), ctypes.c_int]),
                           ("cuCtxSetCurrent", [_P]),
                           ("cuModuleLoadData", [ctypes.POINTER(_P), ctypes.c_char_p]),
                           ("cuModuleUnload", [_P]),
                           ("cuModuleGetFunction", [ctypes.POINTER(_P), _P, ctypes.c_char_p]),
                           ("cuFuncSetAttribute", [_P, ctypes.c_int, ctypes.c_int]),
                           ("cuGetErrorString", [ctypes.c_int, ctypes.POINTER(ctypes.c_char_p)]),
                           ("cuLaunchKernel", [_P, _U, _U, _U, _U, _U, _U, _U, _P,
                                               ctypes.POINTER(_P), ctypes.POINTER(_P)])):
            getattr(cuda, name).argtypes = args      # 64-bit handles: never ctypes' default int
            getattr(cuda, name).restype = ctypes.c_int
        _cuda = cuda
    return _cuda


def _cu(rc, what):
    if rc != 0:
        msg = ctypes.c_char_p()
        _driver().cuGetErrorString(rc, ctypes.byref(msg))
        raise RuntimeError(f"{what} failed: CUresult {rc} ({msg.value.decode() if msg.value else '?'})")


def dtype_of(param):
    """The torch dtype matching a Param's element_type (None when there is no single one)."""
    return _DTYPES.get(param.element_type)


class CudaModule:
    """A crisp_gpu.Module (target 'ptx') loaded into PyTorch's CUDA context on DEVICE."""

    def __init__(self, module, device=None):
        if not isinstance(module, Module) or module.target != "ptx":
            raise TypeError("crisp_gpu.torch.load needs a Module compiled with target='ptx'")
        cuda = _driver()
        self.module = module
        torch.cuda.init()
        self.device = torch.device("cuda", torch.cuda.current_device() if device is None
                                   else torch.device(device).index or 0)
        dev = ctypes.c_int()
        _cu(cuda.cuDeviceGet(ctypes.byref(dev), self.device.index), "cuDeviceGet")
        pctx = _P()
        _cu(cuda.cuDevicePrimaryCtxRetain(ctypes.byref(pctx), dev), "cuDevicePrimaryCtxRetain")
        _cu(cuda.cuCtxSetCurrent(pctx), "cuCtxSetCurrent")
        self._handle = _P()
        _cu(cuda.cuModuleLoadData(ctypes.byref(self._handle), module.binary + b"\0"), "cuModuleLoadData")
        self._fns = {}
        for k in module.kernels:
            fn = _P()
            _cu(cuda.cuModuleGetFunction(ctypes.byref(fn), self._handle, k.name.encode()),
                f"cuModuleGetFunction({k.name})")
            self._fns[k.name] = fn

    def kernel(self, name):
        return self.module.kernel(name)

    def launch(self, kernel, args=None, stream=None, **kwargs):
        """Launch KERNEL (a name or a Kernel).  Arguments are given by parameter name, as a dict
        ARGS and/or keywords: CUDA tensors for tensor parameters, numbers for scalars.  The compiler's
        implicit parameters (scratch) are allocated here.  Returns ((gx, gy, gz), (bx, by, bz))."""
        k = self.module.kernel(kernel) if isinstance(kernel, str) else kernel
        given = {n.lower(): v for n, v in {**(args or {}), **kwargs}.items()}
        lib, ctx, m = self.module._lib, self.module._ctx, 0
        nslots = lib.crisp_slot_count(ctx, m, k.index)
        slots = [ctypes.create_string_buffer(max(8, lib.crisp_slot_size(ctx, m, k.index, s)))
                 for s in range(nslots)]
        slot_type = [_enum(_capi.TYPE, lib.crisp_slot_type(ctx, m, k.index, s)) for s in range(nslots)]
        keep = []

        def put(p, role, axis, value, required=True):
            s = lib.crisp_param_slot(ctx, m, k.index, p.index, _capi.ROLE[role], axis)
            if s == _capi.NO_SLOT:
                if required:
                    raise RuntimeError(f"{k.name}: {p.name} has no {role} slot (axis {axis})")
                return
            size = lib.crisp_slot_size(ctx, m, k.index, s)
            fmt = _PACK.get(slot_type[s]) or {1: "B", 2: "H", 4: "I", 8: "Q"}[size]
            if fmt in "bhiq" or fmt in "BHIQ":
                value = int(value)
            struct.pack_into("<" + fmt, slots[s], 0, value)

        L = _P()
        st = lib.crisp_launch_create(ctx, m, k.index, ctypes.byref(L))
        if st != _capi.OK:
            raise RuntimeError(f"{k.name}: crisp_launch_create: {lib.crisp_status_string(st).decode()}")
        try:
            implicit = []
            for p in k.params:
                if p.purpose != "declared":
                    implicit.append(p)
                    continue
                if p.name.lower() not in given:
                    raise TypeError(f"{k.name}: missing argument {p.name!r}")
                v = given[p.name.lower()]
                if p.kind == "scalar":
                    put(p, "value", 0, v)
                    if isinstance(v, int) or (hasattr(v, "is_integer") and float(v).is_integer()):
                        lib.crisp_launch_set_scalar(L, p.index, int(v) & 0xFFFFFFFFFFFFFFFF)
                elif p.kind == "tensor":
                    self._put_tensor(k, p, v, put, L)
                    keep.append(v)
                else:
                    raise NotImplementedError(f"{k.name}: parameter {p.name} is a {p.kind}; "
                                              "crisp_gpu.torch launches tensors and scalars")
            st = lib.crisp_launch_compute(L)
            if st != _capi.OK:
                raise RuntimeError(f"{k.name}: launch: {lib.crisp_launch_message(L).decode()}")
            if not lib.crisp_launch_declared(L):
                raise RuntimeError(f"{k.name}: the kernel declares no launch geometry "
                                   "(add a global-size / local-size declaration)")
            for p in implicit:
                if p.purpose != "scratch":
                    raise NotImplementedError(f"{k.name}: implicit parameter {p.name} ({p.purpose})")
                nbytes = lib.crisp_launch_param_bytes(L, p.index)
                buf = torch.zeros(max(1, nbytes), dtype=torch.uint8, device=self.device)
                put(p, "pointer", 0, buf.data_ptr())
                put(p, "byte-size", 0, nbytes, required=False)
                keep.append(buf)
            if any(lib.crisp_launch_cluster_size(L, a) > 1 for a in range(3)):
                raise NotImplementedError(f"{k.name}: thread-block clusters are not launched by crisp_gpu.torch yet")
            g = tuple(lib.crisp_launch_group_count(L, a) for a in range(3))
            b = tuple(lib.crisp_launch_local_size(L, a) for a in range(3))
            shared = lib.crisp_launch_shared_bytes(L)
        finally:
            lib.crisp_launch_destroy(L)
        fn = self._fns[k.name]
        cuda = _driver()
        if shared > 48 * 1024:
            _cu(cuda.cuFuncSetAttribute(fn, _CU_FUNC_ATTRIBUTE_MAX_DYNAMIC_SHARED_SIZE_BYTES, shared),
                f"cuFuncSetAttribute({k.name}, {shared} B shared)")
        params = (_P * nslots)(*[ctypes.cast(s, _P) for s in slots])
        stream = stream if stream is not None else torch.cuda.current_stream(self.device)
        _cu(cuda.cuLaunchKernel(fn, g[0], g[1], g[2], b[0], b[1], b[2], shared,
                                _P(stream.cuda_stream), params, None), f"cuLaunchKernel({k.name})")
        return g, b

    def _put_tensor(self, k, p, t, put, L):
        lib = self.module._lib
        if not (isinstance(t, torch.Tensor) and t.is_cuda):
            raise TypeError(f"{k.name}: {p.name} must be a CUDA tensor")
        want = dtype_of(p)
        if want is not None and t.dtype != want:
            raise TypeError(f"{k.name}: {p.name} is {p.element_type}; got a {t.dtype} tensor")
        if t.dim() != p.rank:
            raise ValueError(f"{k.name}: {p.name} has rank {p.rank}; got a {t.dim()}-d tensor")
        if p.layout in ("compact", "compact-offset") and not t.is_contiguous():
            raise ValueError(f"{k.name}: {p.name} is compact: pass a contiguous tensor (.contiguous())")
        put(p, "pointer", 0, t.data_ptr())
        put(p, "byte-size", 0, t.numel() * t.element_size(), required=False)
        for a in range(p.rank):
            put(p, "offset", a, 0, required=False)
            put(p, "stride", a, t.stride(a), required=False)
            put(p, "extent", a, t.shape[a], required=False)
            lib.crisp_launch_set_extent(L, p.index, a, t.shape[a])
        put(p, "length", 0, t.numel(), required=False)

    def __del__(self):
        try:
            if self._handle:
                _driver().cuModuleUnload(self._handle)
        except Exception:
            pass


def _enum(table, value):
    for k, v in table.items():
        if v == value:
            return k
    return None


def load(module, device=None):
    """Load a ptx Module into PyTorch's CUDA context: returns a CudaModule."""
    return CudaModule(module, device)


def autograd_function(cmod, forward, outputs=None):
    """A function of the FORWARD kernel's declared inputs (positionally, in parameter order) that
    returns its outputs, with the gradient kernel --differentiate made as its backward.

    OUTPUTS maps an output parameter's name to a function of the input tensors returning a new
    tensor for it; by default each output is torch.empty_like(the first tensor input)."""
    if isinstance(cmod, Module):
        cmod = load(cmod)
    fk = cmod.module.kernel(forward)
    gk = cmod.module.grad_kernel(fk.name)
    ins = [p for p in fk.params if p.purpose == "declared" and p.direction != "out"]
    outs = [p for p in fk.params if p.purpose == "declared" and p.direction == "out"]
    outputs = {n.lower(): f for n, f in (outputs or {}).items()}

    class _Fn(torch.autograd.Function):
        @staticmethod
        def forward(ctx, *xs):
            if len(xs) != len(ins):
                raise TypeError(f"{fk.name} takes {len(ins)} inputs ({', '.join(p.name for p in ins)}); got {len(xs)}")
            xs = [x.contiguous() if isinstance(x, torch.Tensor) else x for x in xs]
            first = next((x for x in xs if isinstance(x, torch.Tensor)), None)
            made = {}
            for p in outs:
                f = outputs.get(p.name.lower())
                made[p.name] = f(*xs) if f else torch.empty_like(first, dtype=dtype_of(p) or first.dtype)
            cmod.launch(fk, {**{p.name: x for p, x in zip(ins, xs)}, **made})
            ctx.save_for_backward(*[x for x in xs if isinstance(x, torch.Tensor)], *made.values())
            ctx.scalars = {p.name: x for p, x in zip(ins, xs) if not isinstance(x, torch.Tensor)}
            ctx.names = [p.name for p, x in zip(ins, xs) if isinstance(x, torch.Tensor)] + list(made)
            return tuple(made.values()) if len(made) != 1 else next(iter(made.values()))

        @staticmethod
        def backward(ctx, *gouts):
            primal = {**dict(zip(ctx.names, ctx.saved_tensors)), **ctx.scalars}
            primal = {n.lower(): v for n, v in primal.items()}
            incoming = {p.name.lower(): g.contiguous() for p, g in zip(outs, gouts)}
            args, results = {}, {}
            # a primal parameter -> its saved forward value; an IN adjoint of output q -> q's incoming
            # gradient; an OUT adjoint of input q -> a zeroed buffer that receives q's gradient
            for p in gk.params:
                if p.purpose != "declared":
                    continue
                if p.adjoint_of is None:
                    args[p.name] = primal[p.name.lower()]
                elif p.direction == "in":
                    args[p.name] = incoming[p.adjoint_of.lower()]
                else:
                    results[p.adjoint_of.lower()] = args[p.name] = torch.zeros_like(primal[p.adjoint_of.lower()])
            cmod.launch(gk, args)
            return tuple(results.get(p.name.lower()) for p in ins)

    def apply(*xs):
        return _Fn.apply(*xs)
    apply.__name__ = fk.name
    apply.__doc__ = f"Crisp kernel {fk.name} ({', '.join(p.name for p in ins)}) with gradient {gk.name}."
    return apply
