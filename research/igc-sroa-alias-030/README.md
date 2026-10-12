# IGC SROA-aliasing bug — minimal reproducer

A small SPIR-V kernel containing two sibling `float` allocas with
independent stores produces incorrect output on Intel Arc B580 via
the Level Zero / IGC stack.  The same LLVM IR translated to PTX via
the NVPTX backend produces correct output, so the IR itself is
well-formed.

## Files

| File | Purpose |
|---|---|
| `bug.ll` | LLVM IR for the failing kernel (SPIR target). |
| `bug.spv` | SPIR-V translation via `llvm-spirv` (LLVM 22.0.0git). |
| `bug.ptx` | NVPTX translation via `llc -mtriple=nvptx64`, demonstrating the correct semantics. |
| `loader.cpp` | Level Zero host that runs `bug.spv` and prints the 8 output bytes. |

## System

* **GPU:** Intel(R) Arc(TM) B580 Graphics
* **Driver:** 32.0.101.8737
* **OS:** Windows 11 Home, build 10.0.26200
* **Translator:** `llvm-spirv` (LLVM 22.0.0git)
* **Runtime:** Level Zero (oneAPI Loader)

## Kernel summary

```llvm
%PT     = type { float, i32 }
%PT_ADJ = type { float, float }

define spir_kernel void @bug(%PT %p,
                             ptr addrspace(1) %seed_ptr,
                             ptr addrspace(1) %out_ptr) {
entry:
  ; Four float allocas, zero-initialized
  %ax_inter = alloca float, align 4
  %ay_inter = alloca float, align 4
  %ax       = alloca float, align 4
  %ay       = alloca float, align 4
  store float 0.0, ptr %ax_inter
  store float 0.0, ptr %ay_inter
  store float 0.0, ptr %ax
  store float 0.0, ptr %ay

  %px = call float @x__pt(%PT %p)   ; px = 3.0
  %py = call i32   @y__pt(%PT %p)   ; py = 4
  %py_f = sitofp i32 %py to float    ; py_f = 4.0
  %seed = load float, ptr addrspace(1) %seed_ptr   ; seed = 1.0

  ; Stage 1: deposit per-field intermediates
  %tx0 = load float, ptr %ax_inter
  %tx1 = fadd float %tx0, (fmul %py_f, %seed)
  store float %tx1, ptr %ax_inter             ; ax_inter = 4.0

  %ty0 = load float, ptr %ay_inter
  %ty1 = fadd float %ty0, (fmul %px, %seed)
  store float %ty1, ptr %ay_inter             ; ay_inter = 3.0

  ; Stage 2: fold intermediates into per-field totals
  store float (load ax_inter + load ax), ptr %ax  ; ax = 4.0
  store float (load ay_inter + load ay), ptr %ay  ; ay = 3.0

  ; Stage 3: read totals, build aggregate, store
  %vx = load float, ptr %ax                   ; expected 4.0
  %vy = load float, ptr %ay                   ; expected 3.0
  %s  = insertvalue %PT_ADJ { %vx, %vy }
  store %PT_ADJ %s, ptr addrspace(1) %out_ptr
  ret void
}
```

## Expected behavior

With kernel inputs `p = {3.0, 4}` and `*seed_ptr = 1.0`:

```
out[0]  =  py * seed  =  4.0 * 1.0  =  4.0
out[1]  =  px * seed  =  3.0 * 1.0  =  3.0
```

So `out_ptr` should hold `{4.0, 3.0}` as raw bytes
`00 00 80 40 00 00 40 40`.

## Observed behavior on Intel Arc B580

`out_ptr` holds **`{4.0, 4.0}`** — raw bytes `00 00 80 40 00 00 80 40`.
The Stage 3 read of `%ay` returns the value of `%ax` instead of its
own contents.

## Cross-check: NVPTX backend handles the same IR correctly

`bug.ptx` (produced from the same `bug.ll` via
`llc -mtriple=nvptx64-nvidia-cuda -mcpu=sm_80`) shows two distinct
register sources for the two stores:

```
mul.rn.f32  %r9,  %r7, %r8         ; %r9  = py_f * seed = 4.0
add.rn.f32  %r10, %r9, 0f00000000  ; %r10 = 4.0
mul.rn.f32  %r11, %r3, %r8         ; %r11 = px * seed   = 3.0
add.rn.f32  %r12, %r11, 0f00000000 ; %r12 = 3.0
st.global.b32 [%rd2+4], %r12       ; out[1] = 3.0
st.global.b32 [%rd2],   %r10       ; out[0] = 4.0
```

Two distinct register sources (`%r12`, `%r10`) feed the two `st.global`
instructions.  The IR is unambiguous — the SPV/IGC pipeline is
miscompiling it.

## Reproducing

1. Translate `bug.ll` to SPV (already supplied):

   ```
   llvm-as bug.ll -o bug.bc
   llvm-spirv bug.bc -o bug.spv
   ```

2. Build the loader:

   ```
   g++ -std=c++17 -O0 -o loader loader.cpp -I<level-zero>/include -lze_loader
   ```

3. Run:

   ```
   ./loader bug.spv
   ```

   Expected:

   ```
   out[0] = 4   (expected 4.0)
   out[1] = 3   (expected 3.0)
   PASS
   ```

   Observed:

   ```
   out[0] = 4   (expected 4.0)
   out[1] = 4   (expected 3.0)
   FAIL (bug reproduces)
   ```

## Notes from upstream investigation

In larger autodiff-generated kernels (several hundred lines, six or
more sibling `float` allocas), marking the two final loads of the
per-field-total allocas as `load volatile` reliably restores the
correct output.  In the minimal reproducer above (four allocas),
adding `volatile` does **not** restore correct output — the same
`{4.0, 4.0}` is produced regardless.  This suggests the optimization
that miscompiles here is sensitive to the surrounding code and not
purely an alloca-promotion (SROA) issue, but the same symptom — two
sibling `float` allocas aliasing into a single slot — appears in both
contexts.
