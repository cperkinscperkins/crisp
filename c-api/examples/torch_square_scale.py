"""A Crisp kernel as a PyTorch autograd Function -- through the Crisp compile API.  (Endeavour 190, S5.)

ONE --differentiate compile (c-api/examples/square_scale.crisp, y = x * x * w) gives the forward
kernel AND its gradient kernel.  Both run on PyTorch's own CUDA tensors, in PyTorch's own context
and stream, via the CUDA driver API.  Nothing here knows the kernels' argument layout: every
argument is placed by ROLE (crisp_param_slot), the grid comes from a launch object, and the gradient
kernel is wired by the API's adjoint PAIRING (crisp_param_adjoint_of) -- so the same code would
launch any Crisp kernel made of tensors.

The check: values and gradients against PyTorch's own autograd of the same expression.

Needs: Linux + an NVIDIA GPU + torch with CUDA; the compiler built (build/build.lisp also builds
bin/libcrisp.so).  Run from the repo root:  python c-api/examples/torch_square_scale.py
"""
import ctypes
import os
import sys

import torch

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(REPO, "c-api", "python"))
import crisp_ctypes as C  # noqa: E402

LIB = C.load()
CUDA = ctypes.CDLL("libcuda.so.1")
_P, _U = ctypes.c_void_p, ctypes.c_uint
for _name, _args in (("cuDeviceGet", [ctypes.POINTER(ctypes.c_int), ctypes.c_int]),
                     ("cuDevicePrimaryCtxRetain", [ctypes.POINTER(_P), ctypes.c_int]),
                     ("cuCtxSetCurrent", [_P]),
                     ("cuModuleLoadData", [ctypes.POINTER(_P), ctypes.c_char_p]),
                     ("cuModuleGetFunction", [ctypes.POINTER(_P), _P, ctypes.c_char_p]),
                     ("cuLaunchKernel", [_P, _U, _U, _U, _U, _U, _U, _U, _P, ctypes.POINTER(_P), ctypes.POINTER(_P)])):
    getattr(CUDA, _name).argtypes = _args        # 64-bit handles: never ctypes' default int
    getattr(CUDA, _name).restype = ctypes.c_int


def cu(rc, what):
    if rc != 0:
        raise RuntimeError(f"{what} failed: CUresult {rc}")


class CrispModule:
    """One compiled Crisp module, loaded into PyTorch's CUDA context."""

    def __init__(self, source, name, flags=()):
        self.ctx = ctypes.c_void_p()
        assert LIB.crisp_context_create(b"ptx", ctypes.byref(self.ctx)) == C.OK
        arr, n = C.flags_array(list(flags))
        LIB.crisp_set_flags(self.ctx, arr, n)
        LIB.crisp_add_source(self.ctx, source.encode(), name.encode())
        st = LIB.crisp_compile(self.ctx)
        if st != C.OK:
            raise RuntimeError("Crisp compile failed:\n" + LIB.crisp_diagnostics_text(self.ctx).decode())
        data, size = ctypes.c_void_p(), ctypes.c_size_t()
        assert LIB.crisp_module_binary(self.ctx, 0, ctypes.byref(data), ctypes.byref(size)) == C.OK
        ptx = ctypes.string_at(data.value, size.value + 1)          # NUL-terminated PTX
        # PyTorch's context: the device's primary context, current on this thread
        torch.cuda.init()
        dev = ctypes.c_int()
        cu(CUDA.cuDeviceGet(ctypes.byref(dev), torch.cuda.current_device()), "cuDeviceGet")
        pctx = ctypes.c_void_p()
        cu(CUDA.cuDevicePrimaryCtxRetain(ctypes.byref(pctx), dev), "cuDevicePrimaryCtxRetain")
        cu(CUDA.cuCtxSetCurrent(pctx), "cuCtxSetCurrent")
        self.module = ctypes.c_void_p()
        cu(CUDA.cuModuleLoadData(ctypes.byref(self.module), ptx), "cuModuleLoadData")
        self.kernels = {}
        for k in range(LIB.crisp_kernel_count(self.ctx, 0)):
            kname = LIB.crisp_kernel_name(self.ctx, 0, k)
            fn = ctypes.c_void_p()
            cu(CUDA.cuModuleGetFunction(ctypes.byref(fn), self.module, kname), "cuModuleGetFunction")
            self.kernels[kname.decode()] = (k, fn)

    def params(self, kname):
        """[(index, name, kind, direction, adjoint_of)] of kernel KNAME, in slot order."""
        k = self.kernels[kname][0]
        out = []
        for p in range(LIB.crisp_param_count(self.ctx, 0, k)):
            adj = LIB.crisp_param_adjoint_of(self.ctx, 0, k, p)
            out.append((p, LIB.crisp_param_name(self.ctx, 0, k, p).decode(),
                        LIB.crisp_param_kind_of(self.ctx, 0, k, p), LIB.crisp_param_direction(self.ctx, 0, k, p),
                        adj.decode() if adj else None))
        return out

    def launch(self, kname, tensors):
        """Launch kernel KNAME with TENSORS (parameter name -> contiguous CUDA tensor)."""
        k, fn = self.kernels[kname]
        ctx = self.ctx
        nslots = LIB.crisp_slot_count(ctx, 0, k)
        slots = [ctypes.c_uint64(0) for _ in range(nslots)]   # every slot of these kernels is 8 bytes
        L = ctypes.c_void_p()
        assert LIB.crisp_launch_create(ctx, 0, k, ctypes.byref(L)) == C.OK
        try:
            keep = []
            for p, name, kind, _, _ in self.params(kname):
                purpose = LIB.crisp_param_purpose(ctx, 0, k, p)
                if purpose != C.PURPOSE["declared"]:
                    raise NotImplementedError(f"{kname}: implicit parameter {name} (scratch) -- not needed by this example")
                if kind != C.PARAM_KIND["tensor"]:
                    raise NotImplementedError(f"{kname}: parameter {name} is not a tensor")
                t = tensors[name]
                assert t.is_cuda and t.is_contiguous() and t.dtype == torch.float32, name
                assert LIB.crisp_param_layout(ctx, 0, k, p) == C.LAYOUT["compact"]   # contiguous is what it reads
                rank = LIB.crisp_param_rank(ctx, 0, k, p)
                assert t.dim() == rank, (name, t.dim(), rank)

                def put(role, axis, value):
                    s = LIB.crisp_param_slot(ctx, 0, k, p, C.ROLE[role], axis)
                    assert s != C.NO_SLOT, (name, role, axis)
                    assert LIB.crisp_slot_size(ctx, 0, k, s) == 8
                    slots[s].value = value

                put("pointer", 0, t.data_ptr())
                put("byte-size", 0, t.numel() * t.element_size())
                for a in range(rank):
                    put("offset", a, 0)
                    put("stride", a, t.stride(a))
                    put("extent", a, t.shape[a])
                    LIB.crisp_launch_set_extent(L, p, a, t.shape[a])
                put("length", 0, t.numel())
                keep.append(t)
            st = LIB.crisp_launch_compute(L)
            if st != C.OK:
                raise RuntimeError(f"{kname}: launch: {LIB.crisp_launch_message(L).decode()}")
            if not LIB.crisp_launch_declared(L):
                raise RuntimeError(f"{kname}: declares no launch geometry (a _grad kernel inherits its "
                                   "forward kernel's -- if this fires, BUG 066 is back on PTX)")
            g = [LIB.crisp_launch_group_count(L, a) for a in range(3)]
            b = [LIB.crisp_launch_local_size(L, a) for a in range(3)]
            shared = LIB.crisp_launch_shared_bytes(L)
            params = (ctypes.c_void_p * nslots)(*[ctypes.addressof(s) for s in slots])
            stream = ctypes.c_void_p(torch.cuda.current_stream().cuda_stream)
            cu(CUDA.cuLaunchKernel(fn, g[0], g[1], g[2], b[0], b[1], b[2], shared, stream,
                                   params, None), f"cuLaunchKernel({kname})")
            return g, b
        finally:
            LIB.crisp_launch_destroy(L)


SRC = open(os.path.join(REPO, "c-api", "examples", "square_scale.crisp"), encoding="utf-8").read()
MOD = CrispModule(SRC, "square_scale.crisp", flags=["--differentiate"])
FWD = "square_scale"
# the gradient kernel is the one the API says differentiates FWD
GRAD = next(n for n, (k, _) in MOD.kernels.items() if LIB.crisp_kernel_grad_of(MOD.ctx, 0, k) == FWD.encode())


class SquareScale(torch.autograd.Function):
    """y = x * x * w, forward and backward both Crisp kernels."""

    @staticmethod
    def forward(ctx, x, w):
        x, w = x.contiguous(), w.contiguous()
        ins = {"x": x, "w": w}
        outs = {name: torch.empty_like(x)
                for _, name, _, d, _ in MOD.params(FWD) if d == C.DIRECTION["out"]}
        MOD.launch(FWD, {**ins, **outs})
        ctx.save_for_backward(x, w, *outs.values())
        ctx.out_names = list(outs)
        return outs["y"]

    @staticmethod
    def backward(ctx, gy):
        x, w, *outs = ctx.saved_tensors
        primal = {"x": x, "w": w, **dict(zip(ctx.out_names, outs))}
        incoming = {"y": gy.contiguous()}
        args, results = {}, {}
        # Wire the gradient kernel by the API's pairing, not by name convention:
        #   a primal parameter            -> the saved forward value
        #   an IN adjoint of output q      -> the incoming gradient of q
        #   an OUT adjoint of input q      -> a zeroed buffer that receives q's gradient
        for _, name, _, d, adj in MOD.params(GRAD):
            if adj is None:
                args[name] = primal[name]
            elif d == C.DIRECTION["in"]:
                args[name] = incoming[adj]
            else:
                results[adj] = args[name] = torch.zeros_like(primal[adj])
        MOD.launch(GRAD, args)
        return results["x"], results["w"]


def check(n):
    torch.manual_seed(n)
    x = torch.randn(n, device="cuda", requires_grad=True)
    w = torch.randn(n, device="cuda", requires_grad=True)
    g = torch.randn(n, device="cuda")
    y = SquareScale.apply(x, w)
    (y * g).sum().backward()
    xr = x.detach().clone().requires_grad_()
    wr = w.detach().clone().requires_grad_()
    yr = xr * xr * wr
    (yr * g).sum().backward()
    torch.cuda.synchronize()
    ok = (torch.allclose(y, yr, rtol=1e-5, atol=1e-6) and
          torch.allclose(x.grad, xr.grad, rtol=1e-5, atol=1e-6) and
          torch.allclose(w.grad, wr.grad, rtol=1e-5, atol=1e-6))
    err = max((y - yr).abs().max().item(), (x.grad - xr.grad).abs().max().item(), (w.grad - wr.grad).abs().max().item())
    print(f"n={n:>9}: {'OK  ' if ok else 'FAIL'} max |crisp - torch| = {err:.3g}")
    return ok


if __name__ == "__main__":
    print(f"forward kernel {FWD}, gradient kernel {GRAD}  (one --differentiate compile, {torch.cuda.get_device_name()})")
    results = [check(n) for n in (1, 7, 1000, 1 << 20, (1 << 20) + 3)]
    LIB.crisp_shutdown()
    print("TORCH-TOY: " + ("PASS" if all(results) else "FAIL"))
    sys.exit(0 if all(results) else 1)
