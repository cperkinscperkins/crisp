
INSTALL and BUILD
=================

You can install Crisp using pre-built binaries (quickest) or build from source using SBCL.

Clone This
----------
`git clone https://github.com/cperkinscperkins/crisp.git`
`cd crisp`

INSTALL BINARY (Recommended)
============================

Crisp provides pre-compiled binary releases for Windows and Linux x86_64.

### 1. Fetch & Deploy Binaries

Run the binary initialization script from the root of the repository:
```
python init_bin.py
```
*(Alternatively, you can run `init_bin.bat` on Windows or `./init_bin.sh` on Linux).*

This script will:
- Download **Crisp Prerelease 001** (`crisp-prerelease-001.zip`) from GitHub Releases.
- Extract the platform tools into `./tools/`.
- Automatically create `./bin/` and populate it with the Crisp compiler (`crisp-compile`), hoisting applications (`crisp-hoist-l0`, `crisp-hoist-cuda`), and required LLVM supporting tools (`LLVM-C`, `llc`, `llvm-as`, `llvm-spirv`) configured for your operating system.

### 2. Verify Installation

Test that the Crisp compiler is working:
```
# Windows
.\bin\crisp-compile.exe ./tests/return_7.crisp

# Linux
./bin/crisp-compile ./tests/return_7.crisp
```

You are ready to compile kernels and generate hoisting C++ code! Skip down to **INVOKING THE COMPILER** below.


INSTALL FROM SOURCE
===================

Supporting Tools
----------------
Crisp uses some supporting tools from LLVM (LLVM-C.dll/.so, llc.exe and llvm-spirv.exe)
These are release as a tools download. After cloning Crisp, `cd` to its directory and run
`python init_tools.py`  to fetch the supporting tools and their license files.

Or, simply download https://github.com/cperkinscperkins/crisp/releases/tag/tools-v1 and unzip the .zip to a directory named `tools`.  (ie  `crisp/tools/`)



🚀 Dependencies
----------------

Building Crisp from source requires **SBCL**

### 1 Install SBCL

- **macOS:** `brew install sbcl`
- **Linux (Ubuntu/Debian):** `sudo apt-get install sbcl`
- **Windows:** Download and run the installer from [sbcl.org](https://sbcl.org).

(Note: The Windows/macOS installers bundle ASDF. The Linux apt package does not, but Step 3 will handle this.)


### 2 Install Lisp Dependencies (CFFI)

Your Lisp environment needs the **CFFI** library.

#### Method 1: Quicklisp (Recommended for all platforms)
This is the standard way to manage Lisp libraries. If you don't have Quicklisp, you can install it from [quicklisp.org](http://quicklisp.org).

. Launch SBCL.
. Install CFFI by running:
```
(ql:quickload "cffi")
```
Quicklisp will download and install them and their dependencies (including ASDF).

#### Method 2: Linux System Packages (Alternative)
If you are on Linux and do not want to use Quicklisp, you can install the system packages for ASDF and CFFI:
```
sudo apt-get install -y cl-asdf cl-cffi
```

(Note: If you use this method, your "Build" Lisp commands must begin with `(require "asdf")`.)



Build Instantly
---------------
The `build.lisp` script will build the compiler and hoist-l0.
```
$ sbcl --non-interactive --load build/build.lisp
```

Build Interactively
-------------------

- from a terminal, `cd` to the `crisp` directory.
- launch SBCL  (invoke `sbcl` from the shell)

Now we are in SBCL.  
We will 
- add the current working directory to the ASDF registry,
- load crisp
- test the basic installion
- make a 'bin' directory
- build the crisp compiler.

```
(require "asdf")
(push *default-pathname-defaults* asdf:*central-registry*)
(asdf:clear-system "crisp")
(ql:quickload "crisp")


;; to build the compiler
(uiop::ensure-directories-exist "bin/")
(asdf:make "crisp")
(exit)
```

INVOKING THE COMPILER
---------------------
Let's try out the compiler
```
$   ./bin/crisp-compile.exe ./tests/return_7.crisp
    -- come and see --

```

The compiler supports a number of flags now:
- `--ir-target=spv`
- `--ir-target=ptx`
- `--ir-target=llvmir`
- `--ir-target-arch` ;; sm_80, xe2 and many others
- `--hoist=L0`
- `--hoist=CUDA`
- `--metadata`
- `--single-pass`
- `-g`
- `--debug`
- `--log-level=off`  ;; also `error`, `warn`, `info`, `debug`, `trace`
- `--differentiate` 
- `--runtime-checks`
- `--math-precision=fast`
- `--math-precision=ieee`
- `--denormal-handling=preserve` ;; also `ftz`

Run Tests
---------

All the E2E and error tests are organized "in order". 

## Benchmark peer libraries (optional)

Only needed if you intend to RUN the benchmark suite; the compiler and the test suites do not
depend on these.

Crisp's benchmark ladder compares against three contender classes: a **Control** (a hand-written
kernel), a **Ceiling** (a closed vendor library — cuBLAS / oneMKL), and a **Peer** — a composable
template library you write kernels with, which is the same kind of thing Crisp is:

| vendor | peer | upstream |
|---|---|---|
| NVIDIA | CUTLASS | https://github.com/NVIDIA/cutlass |
| Intel | SYCL-TLA | https://github.com/intel/sycl-tla |

The peer is the contender that answers *"is 77% of cuBLAS good?"* — a Ceiling alone cannot,
because it is closed, hand-tuned, and dispatches over dozens of kernels. Without a peer the
report's Peer column is empty.

```
# provision whatever this machine can use (detected from nvcc / icpx on PATH)
$ bash scripts/setup-third-party.sh

# or name one explicitly
$ bash scripts/setup-third-party.sh cutlass

# report what is present, change nothing
$ bash scripts/setup-third-party.sh --check
```

They land in `third_party/`, which is **gitignored** — so the checkout is per-machine and never
committed. `scripts/setup-third-party.sh` writes `third_party/versions.txt` recording the exact
SHA of each, which is the only record of what a given benchmark run compared against; quote it
alongside any published peer number.

Revisions are **not pinned by default** — the script clones each project's default branch. Set
`CUTLASS_REF` / `SYCL_TLA_REF` to pin once a known-good revision is established, and do so before
publishing a peer comparison anyone will rely on.

The pod and Docker benchmark flows (`scripts/bench-on-pod.sh`, `scripts/bench-intel.sh`) call
this script themselves, so you only need it for a local benchmark run.

The file ./tests/ci-stop.txt   names a directory inside ./tests/spec
that the E2E tests will be run up to (inclusive), but no futher.



```
# run the unit tests
$ sbcl --non-interactive --load .\tests\run-ci.lisp     

# run the E2E tests (see tests.md for additional flags)
$ sbcl  --non-interactive --load .\tests\run-specs.lisp

# run the negative tests (errors)
$ sbcl --non-interactive --load .\tests\run-error-specs.lisp
```

### Windows: 

```
.\tests\run-all-tests.bat
```

### Linux:

```
# instructions coming soon
```

Test interactively from SBCL
---------------------------
```lisp
(push *default-pathname-defaults* asdf:*central-registry*)
(asdf:clear-system "crisp")
(ql:quickload "crisp")
(in-package crisp.compiler)
(initialize-compiler :log-level :debug)

; Want to run tests?
; first load them
(load #P"./tests/all-tests.lisp")
;; then run one
(parachute:test 'crisp.tests::fadd-generation)
; or run all the tests
(parachute:test :crisp.tests)


;; generate some LLVM-IR (and DWARF) from functions
(compile-crisp-form-to-ir-string '(def-function wow () (declare (return-type int)) 7) :debug-p T)

;; or run the CI tests and quit after
(load #P"./tests/run-ci.lisp")
(sb-ext:quit)
```

Generate C++ Code
=================

The Crisp compiler can generate C++ "hoisting" code. Crisp supports both LevelZero and CUDA.

Level Zero
----------

```
# this will compile the kernel to .spv and also output a .c file which can "hoist" it .
.\bin\crisp-compile.exe --ir-target=spv --hoist=l0 ./tests/spec/029-hoist-l0/01-minimal-kernel.crisp

# use any C compiler.  If docker is available, this Crisp installation can use that 
# with it's own crisp-c-validator image.

clang++ -o my_kernel_launcher -I<path-to-level-zero-include> <path-to-generated-c-file> <path-to-ze_loader-lib>
```

### Example


```
..\llvm-mingw-20251216-ucrt-x86_64\bin\clang++.exe .\tests\spec\029-hoist-l0\13-struct-on-kernel-boundary_struct_on_kernel_boundary_struct_on_kernel_boundary_hoist_L0.cpp C:\Windows\System32\ze_loader.dll -I..\level-zero\include -o fancy_three.exe
```

CUDA
----

```
# this will compile the kernel to .ptx and also output a .cpp file which can "hoist" it.
.\bin\crisp-compile.exe --ir-target=ptx --hoist=CUDA ./tests/spec/116-cuda-hoist/02-minimal-kernel.crisp

# use nvcc or a standard C++ compiler (like g++ or clang++).
# If using a standard C++ compiler, you just need to link against the CUDA driver library.

nvcc -o my_kernel_launcher <path-to-generated-cpp-file> -lcuda
```

### Example


```
nvcc .\tests\spec\116-cuda-hoist\04-tensor-kernel_copy_vec_hoist_CUDA.cpp -lcuda -o copy_vec.exe
```

Working with the Docker C Validator
===================================

Crisp is using a docker image `crisp-c-validator` to build and test the .cpp hoist files it generates.

```
# Rebuild the validator image (one time setup)
docker build -f Dockerfile.validator -t crisp-c-validator .

# run the validator
# Syntax check only (what the test validator does)
docker run --rm `
  -v "${PWD}:/workspace" `
  -v "C:\Users\cperk\Documents\level-zero\include:/usr/local/include" `
  crisp-c-validator gcc -fsyntax-only -I/usr/local/include `
  /workspace/tests/spec/029-hoist-l0/01-minimal-kernel_noop_noop_hoist_L0.cpp

# Compile to object file (verifies more thoroughly)
docker run --rm `
  -v "${PWD}:/workspace" `
  -v "C:\Users\cperk\Documents\level-zero\include:/usr/local/include" `
  crisp-c-validator gcc -c -I/usr/local/include `
  /workspace/tests/spec/029-hoist-l0/01-minimal-kernel_noop_noop_hoist_L0.cpp
```