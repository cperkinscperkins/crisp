# crisp-gpu

**Crisp** is a Lisp for writing GPU kernels.  It compiles to PTX (NVIDIA) and SPIR-V (Intel), and
it can differentiate a kernel automatically: one `--differentiate` compile gives you the forward
kernel *and* its gradient kernel.

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

The `crisp-compile` command is installed too.  Linux x86_64, glibc 2.35+ (Ubuntu 22.04 or newer).

* Source, docs and the language guide: <https://github.com/cperkinscperkins/crisp>
* License: Apache-2.0 WITH LLVM-exception.  Bundles LLVM 21 (same license) and the
  SPIRV-LLVM-Translator (University of Illinois/NCSA).
