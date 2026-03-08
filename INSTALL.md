
INSTALL and BUILD
=================

These instructions are, ummm, "fresh".

Clone This
----------
`git clone https://github.com/cperkinscperkins/crisp.git`

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
- `--hoist=L0`
- `--metadata`
- `--single-pass`
- `-g`
- `--debug`
- `--log-level=off`  ;; also `error`, `warn`, `info`, `debug`, `trace`
- `--differentiate` 

Run Tests
---------

All the E2E and error tests are organized "in order". 

The file ./tests/ci-stop.txt   names a directory inside ./tests/spec
that the E2E tests will be run up to (inclusive), but no futher.



```
# run the unit tests
$ sbcl --load .\tests\run-ci.lisp     

# run the E2E tests
$ sbcl --script .\tests\run-specs.lisp  --log-level=off

# run the negative tests (errors)
$ sbcl --script .\tests\run-error-specs.lisp
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

The Crisp compiler can generate C++ "hoisting" code. Presently, LevelZero is the only backend, but
others will follow.

```
# this will compile the kernel to .spv and also output a .c file which can "hoist" it .
.\bin\crisp-compile.exe --ir-target=spv --hoist=l0 ./tests/spec/029-hoist-l0/01-minimal-kernel.crisp

# use any C compiler.  If docker is available, this Crisp installation can use that 
# with it's own crisp-c-validator image.

clang++ -o my_kernel_launcher -I<path-to-level-zero-include> <path-to-generated-c-file> <path-to-ze_loader-lib>
```

Example
-------

```
..\llvm-mingw-20251216-ucrt-x86_64\bin\clang++.exe .\tests\spec\029-hoist-l0\13-struct-on-kernel-boundary_struct_on_kernel_boundary_struct_on_kernel_boundary_hoist_L0.cpp C:\Windows\System32\ze_loader.dll -I..\level-zero\include -o fancy_three.exe
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