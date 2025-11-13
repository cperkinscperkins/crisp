
INSTALL and BUILD
=================

These instructions are, ummm, "fresh".

Clone This
----------
`git clone https://github.com/cperkinscperkins/crisp.git`



🚀 Dependencies
----------------

Crisp requires **SBCL** and the **LLVM development libraries** (version 15 or newer is recommended).

### 1 Install SBCL

- **macOS:** `brew install sbcl`
- **Linux (Ubuntu/Debian):** `sudo apt-get install sbcl`
- **Windows:** Download and run the installer from [sbcl.org](https://sbcl.org).

(Note: The Windows/macOS installers bundle ASDF. The Linux apt package does not, but Step 3 will handle this.)

### 2 Install LLVM Dev Libraries

- C libraries (`.so`, `.dylib`, `.dll`)
- C API header files (`llvm-c/*.h`)
- `llvm-config` tool.

#### On Linux (Ubuntu/Debian)

Use `apt` to get the `llvm-dev` package.

```
sudo apt-get install llvm-21-dev
```

This package automatically installs the libraries, headers, and `llvm-config-21`.

Or just get `llvm-dev` if version 21 isn't configured for your Linux.

#### On macOS

Use Homebrew. It installs everything, but you must manually update your `PATH`.

```
brew install llvm
```

Homebrew installs LLVM "keg-only," which means it's not on your default path (to avoid conflicts with Apple's built-in Clang). You must add it to your `.zshrc` or `.bash_profile`:

```
# Add this to your ~/.zshrc or ~/.bash_profile
export PATH="/usr/local/opt/llvm/bin:$PATH"
```

After this, running `llvm-config --version` in a new terminal should show the version you just installed.

#### On Windows

This is the trickiest. The best method is to use the official pre-compiled binaries from the LLVM GitHub page.

1.  Go to the [LLVM GitHub Releases](https://github.com/llvm/llvm-project/releases) page.
2.  Find the version you want
3.  Download the **"Windows (64-bit)"** installer (e.g., `LLVM-21.1.4-win64.exe`).
4.  **Run the installer.** During setup, you **must** check the box that says:
      * **"Add LLVM to the system PATH for all users"** (or "current user").

Alternatively, you can use `winget`:

```powershell
winget install LLVM.LLVM
```

-----

### 3 Install Lisp Dependencies (CFFI and Eclector)

Your Lisp environment needs the **CFFI** and **Eclector** libraries.

#### Method 1: Quicklisp (Recommended for all platforms)
This is the standard way to manage Lisp libraries. If you don't have Quicklisp, you can install it from [quicklisp.org](http://quicklisp.org).

. Launch SBCL.
. Install CFFI by running:
```
(ql:quickload "cffi")
(ql:quickload "eclector")
```
Quicklisp will download and install them and their dependencies (including ASDF).

#### Method 2: Linux System Packages (Alternative)
If you are on Linux and do not want to use Quicklisp, you can install the system packages for ASDF and CFFI:
```
sudo apt-get install -y cl-asdf cl-cffi cl-eclector
```

(Note: If you use this method, your "Build" Lisp commands must begin with `(require "asdf")`.)

### Verify LLVM Installation 

If you are on Linux or Mac, then after installing, open a new terminal and run:

```bash
llvm-config --version
```

If this prints a version number (e.g., `21.1.4`), you're all set.

If you are on Windows, then rummage around where you installed it and make sure things are ok.


Build
-----

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
(ql:quickload "crisp")
;; (asdf:load-system "crisp")

;; if you want to quickly test, this will use LLVM lib to gen IR for a small function.
(cffi:use-foreign-library crisp.llvm-bindings::libllvm)
(crisp.compiler:test-llvm-hello-world) 

;; to build the compiler
(uiop::ensure-directories-exist "bin/")
(asdf:make "crisp")
(exit)
```

Back to shell.  Let's try out the compiler
```
$   ./bin/crisp-compile.exe ./tests/return_7.crisp
    -- come and see --

```

Other tests: Generate some LLVM-IR
```
(in-package crisp.compiler)
(generate-llvm-ir (def-function wow () (declare (return-type int)) 7))
(generate-llvm-ir (def-function adds (a b) (declare (type a b int) (return-type int)) (+ a b)))

;; or run the CI tests and quit after
(load #P"./tests/run-ci.lisp")
```
