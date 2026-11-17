# crisp-gpu

**Crisp** is a Lisp for writing GPU kernels.  It compiles to PTX (NVIDIA) and SPIR-V (Intel), and
it can differentiate a kernel automatically: compiling with `--differentiate` adds the gradient
(backward) kernel alongside the forward one, so a single module holds both.

Try it on a free Colab GPU first:
<https://colab.research.google.com/github/cperkinscperkins/crisp/blob/main/notebooks/crisp-gpu-intro.ipynb>

This package is the Crisp compiler plus a Python layer for compiling kernels **at run time**:

```python
import crisp_gpu

src = """
(def-type vec-t (vector float :address-space :global :align :compact))

(def-kernel square_scale (X W &out Y)
  (declare #'(vec-t vec-t &out vec-t => nil)
           (global-size :derive-from X :strategy :one-thread-per)
           (local-size  :set-to 256))
  (loop-vector-stride X (i)
    (set! (~ Y i) (* (~ X i) (~ X i) (~ W i)))))
"""
mod = crisp_gpu.compile(src, target="ptx", flags=["--differentiate"])
print(mod.kernels)          # square_scale and its gradient kernel
mod.binary                  # PTX, ready for cuModuleLoadData
```

With PyTorch (`pip install crisp-gpu[torch]`), `crisp_gpu.torch` compiles for the GPU you have, runs
the kernels on CUDA tensors, and turns a forward kernel and its Crisp-made gradient into an autograd
function:

```python
import torch, crisp_gpu.torch as ct
mod = ct.compile(src, flags=["--differentiate"])      # PTX for this GPU (sm_75 on a T4 ...)
f = ct.autograd_function(mod, "square_scale")
x = torch.randn(1 << 20, device="cuda", requires_grad=True)
w = torch.randn(1 << 20, device="cuda", requires_grad=True)
f(x, w).sum().backward()    # x.grad and w.grad computed by Crisp's gradient kernel
```

Kernels that call `exp`, `log`, `tanh` and the other transcendentals need NVIDIA's `libdevice.10.bc`
on the PTX target.  `crisp_gpu` finds it by itself in the CUDA toolkit (`CUDA_HOME`, `/usr/local/cuda`)
or in Triton's copy; set `CRISP_LIBDEVICE=/path/to/libdevice.10.bc` to point at another.

The `crisp-compile` command is installed too.  Linux x86_64, glibc 2.35+ (Ubuntu 22.04 or newer).

* Source, docs and the language guide: <https://github.com/cperkinscperkins/crisp>
* License: Apache-2.0 WITH LLVM-exception.  Bundles LLVM 21 (same license) and the
  SPIRV-LLVM-Translator (University of Illinois/NCSA).
