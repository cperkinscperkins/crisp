# `:mma-shapes` ✅


`:mma-shapes` the matrix-multiply-accumulate (tensor-core / DPAS) instruction shapes the hardware natively supports, each an (M N K) triple. An MMA computes D[M×N] = A[M×K]·B[K×N] + C[M×N], so all three dimensions identify it, and the same M×N typically comes in several K variants for different operand precisions (NVIDIA m16n8k8 for tf32, m16n8k16 for fp16, m16n8k32 for int8; Intel similarly). The form is vendor-neutral, mapping to NVIDIA mma.mMnNkK and Intel joint_matrix shapes alike.

```
:mma-shapes '((16 8 16) (16 8 8) (8 8 128))
```

