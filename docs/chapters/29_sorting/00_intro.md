# Sorting 📝


**Status (endeavour 200, 2026-10-30).**  Both sorts below now have a WORKING implementation -- the GPU MODE
`sort_v2` entries in `contests/gpu-mode/07-sort-v2/`, verified bit-exact against a reference sort on the
Intel Arc B580 (SPIR-V) and the H100 (PTX).  The working code is shown in each section (✅).  The library
"toolkit" and orchestration forms (`bitonic-sort-workgroup`, `gen-bitonic-sort-vector`, `histogram-pass`,
...) are still 📝: they are the API these kernels would become.

