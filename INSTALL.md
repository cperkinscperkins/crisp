
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

  * **macOS:** `brew install sbcl`
  * **Linux (Ubuntu/Debian):** `sudo apt-get install sbcl`
  * **Windows:** Download and run the installer from [sbcl.org](http://www.sbcl.org/platform-table.html).

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
2.  Find the version you want (e.g., 17.0.6).
3.  Download the **"Windows (64-bit)"** installer (e.g., `LLVM-21.1.4-win64.exe`).
4.  **Run the installer.** During setup, you **must** check the box that says:
      * **"Add LLVM to the system PATH for all users"** (or "current user").

Alternatively, you can use `winget`:

```powershell
winget install LLVM.LLVM
```

-----

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
(push *default-pathname-defaults* asdf:*central-registry*)
(asdf:load-system "crisp")
(crisp.compiler:test-llvm-hello-world) ; <-- this will call the LLVM lib to gen IR for a small function and print it out.

(uiop::ensure-directories-exist "bin/")
(asdf:make "crisp")
(exit)
```

Back to shell.  Let's try out the compiler
```
$   ./bin/crisp-compile.exe
=>  Hello, Crisp Compiler v0.0.1!
```

Other tests: compile a function that returns 7.
```
(in-package crisp.compiler)
(generate-llvm-ir (def-function wow () (declare (return-type int)) 7))
```
