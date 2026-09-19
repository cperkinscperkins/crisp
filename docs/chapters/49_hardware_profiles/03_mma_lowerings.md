# `:mma-lowerings` ✅


`:mma-lowerings` names the code-generation strategies this hardware can drive its matrix engines
with, **most-preferred first**. The first entry is the default for kernels that do not ask for one.

```
:mma-lowerings '(:coop-matrix :xe-native)
```

The key is optional. A profile without it offers `(:coop-matrix)` — the portable path every backend
has always used — so existing profiles need no change.

The lowerings Crisp knows:

| name | what it is | where |
|---|---|---|
| `:coop-matrix` | `SPV_KHR_cooperative_matrix` — opaque cooperative-matrix values, `CooperativeMatrixMulAddKHR`, pointer-form loads. The portable path, and the default. | every backend |
| `:xe-native` | Intel Xe: `SubgroupMatrixMultiplyAccumulateINTEL` over concrete vectors, with 2D block loads (and the VNNI-packing *transform* load for the B operand). | Intel SPIR-V only |

A name outside that list is a compile error at `def-hardware-profile` time, so a typo is caught where
it is written rather than surfacing later as a kernel that mysteriously never selects its lowering.

A profile is selected at the command line with
`--hardware-profile=<NAME>`, or named by a `compute-unit` in a
`def-topology` (see [`topology.md`](topology.md)).

