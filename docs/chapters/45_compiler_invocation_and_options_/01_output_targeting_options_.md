# Output Targeting Options 📝


#### `--output-dir=<DIRECTORY_PATH>`

Where the output of the crisp compiler should go. If not provided it is assumed to be the current working directory.

#### `--output-base=<NAME>` 📝

This base name will be used for all outputs, with the file extension uniquely identifying them.
If not provided the base name is the name of the last .crisp file passed to the compiler (minus any extension).

#### `--transpile-to=<ID>` 📝

The compiler will transpile the .crisp file to some other Kernel language. At the moment `oclc` is the only supported
transpilation target.

| ID       | Extension |  Description       |
|----------|-----------|--------------------|
| `oclc`   | `c`       | OpenCL C           | 

#### `--ir-target=<ID>` ✅

This flag can be used repeatedly, each occurrence with a different ID. The compiler will compile the .crisp files 
to an IR (Intermediate Representation) file. One file per occurrence of the `--ir-target` flag.
`ID` can be one of

| ID       | Extension |  Description       |
|----------|-----------|--------------------|
| `llvmir` | `ll`      | human readable LLVM-iR |
| `ptx`    | `ptx`     | CUDA Parallel Thread Execution IR |
| `spv`    | `spv`     | Khronos SPIR-V IR  |

Unless the `--merge` or `--join` flags are used, one target file (e.g. `spv`) is output per `def-orchestration`.  Loose kernels outside of any orchestration have a default one generated for them.

#### `--ir-target-arch=<ID>` 📝

This flag tells the Crisp compiler which architecture the IR should target. It is optional, but
matches the use of `--ir-target` flag. (ie, if `--ir-target=ptx` then `--ir-target-arch` should 
be an NVidia architecture.).



| ID       | Description                    |
|----------|--------------------------------|
| `sm_75`  | NVIDIA Turing (RTX 2000 Series / T4) |
| `sm_80`  | NVIDIA Ampere (A100)           |
| `sm_86`  | NVIDIA Ampere (RTX 3000 Series)  |
| `sm_89`  | NVIDIA Ada Lovelace (RTX 4000 Series / L40) |
| `sm_90`  | NVIDIA Hopper (H100 / H200)      |
| `sm_100` | NVIDIA Blackwell Datacenter (B100 / B200 / GB200) |
| `sm_120` | NVIDIA Blackwell Consumer (RTX 5000 Series / PRO 6000) |
| `gen12`  | Intel Gen12                    |
| `dg2`    | Intel DG2 / Alchemist          |
| `pvc`    | Intel Ponte Vecchio            |
| `xe2`    | Intel BattleMage / Lunar Lake  |


#### `--binary-gpu-target=<ID>` 📝

This flag can be used repeatedly, each occurrence with a different ID. The compiler will compile the .crisp files to a different binary file for each binary target. The binary file name will be `<output-base-name>_<ID>.<extension>`

`ID` can be one of the `--ir-target-arch` flags

Unless the `--merge` or `--join` flags are used, one target file (e.g. `cubin`) is output per `def-orchestration`.  Loose kernels outside of any orchestration have a default one generated for them.

#### `--fat-binary` 📝

This flag requires that the `--binary-gpu-target` flag also be used, or it is ignored.
Whe present the binaries that Crisp produces will be  fat binaries and will also contain the matching IR code (PTX or SPIR-V).

#### `--hoist=<ID>`  ⚠️

This flag can be used repeatedly, each occurrence with a different ID. The compiler will generate a hoisting example code files for each occurence.
The hoist options are paired against their matching IR and Binary targets automatically. You'll get a warning from the compiler if it detects
incompatible pairings.  Note that if outputting BOTH binary and IR targets then the hoisting code will demonstrate both.

The hoist file name will be `<output-base-name>_<orchestration>_<ID>.<extension>`

`ID` can be one of

| ID              | Extension |  Description       |
|-----------------|-----------|--------------------|
| `OpenCL`        | `cpp`     | OpenCL 3.0 API     |
| `L0`            | `cpp`     | LevelZero 1.9 API  |
| `CUDA`          | `cpp`     | CUDA 12 API        |
| `PyOpenCL`      | `py`      | PyOpenCL           |
| `PyLevelZero`   | `py`      | Python LevelZero   |
| `PyCUDA`        | `py`      | PyCUDA             |

There are other flags that interoperate with the hoisting, such as `--hoist-dynamic`

One hoisting file is output per orchestration.

#### `--metadata` ✅

If this flag is present, the compiler will output a metadata file. This file has a lot of the necessary 
hoisting information about the kernels and their arguments and 
can be parsed programmatically if desired.

The metadata files are output one per `def-orchestration`. If a kernel does not appear in a `def-orchestration`, a default one is generated for it. 

#### Example
```
$ crisp.exe --output-base=v_add --ir-target=spv --hoist=L0 ../vector-add.crisp
$ ls
v_add.spv
v_add_hoist_L0.cpp
```

```
$ crisp.exe  --binary-gpu-target=sm_90 --binary-gpu-target=pvc --hoist=CUDA --hoist=PyLevelZero --metadata ../reduce-vector.crisp
$ ls
reduce-vector_sm_90.cubin
reduce-vector_pvc.bin
reduce-vector_hoist_CUDA.cpp
reduce-vector_hoist_PyLevelZero.py
reduce-vector.metacrisp

```


#### `--differentiate` ✅

This flag is discussed in the [Auto Differentiation (AD)](#auto-differentiation-ad) section above.
When used the kernels are assumed to be "forward" kernels and the compiler will generate "backward" kernels for them with "backward" signatures.  The compiler will emit an error if the kernel is not differentiable.

Use `(declare forward-only)` to opt out of differentiation for a specific kernel.

Also note that at this time `--differentiate` and `--hoist` are mutually exclusive.  The compiler will emit an error if both flags are used.

