Crisp has a "release" on GitHub called "Binary Tools Bundle". https://github.com/cperkinscperkins/crisp
This is a collection of the ./tools  (llc, llvm-as, llvm-spirv) that is used by the Crisp compiler to work with LLVM-IR and help convert it to SPIR-V and PTX. It works in conjunciton with ./init_tools.py  .

We need to add a SECOND release type, which will be "Crisp Prerelease 001". This will be everything in the "Binary Tools Bundle" PLUS the Linux and Windows variants of the Crisp compiler and the hoisting apps (L0 and CUDA, Lin and Win each).  When building Crisp from source, we usually put the compiler (and the tools) in a ./bin directory.  We'll need something similar for the Crisp Prerelease.  Maybe another .py file?  Or .sh and .bat??

I can navigate the github site and set stuff up, I'll just need explicit instructions and everything ready.

Other things
[x] The INSTALL.md should probably have a new opening "INSTALL BINARY" section with instructions. Maybe renmae the next section as "INTSALL FROM SOURCE"?
[x] Added `init_bin.py` (plus `init_bin.bat` and `init_bin.sh` wrappers) to download `crisp-prerelease-001.zip`, extract to `./tools/`, and deploy OS-specific binaries into `./bin/`.
[x] Added `scripts/package_prerelease.py` helper tool to check for all 16 required files and bundle `crisp-prerelease-001.zip`.

---

## Preparation: Building & Packaging `crisp-prerelease-001.zip`

Before publishing on GitHub, you need to create the single `crisp-prerelease-001.zip` archive containing all 16 files:
1. Ensure your `./tools/` directory contains the 10 LLVM tool files (`LLVM-C`, `llc`, `llvm-as`, `llvm-spirv` for Windows & Linux + licenses).
2. Build or place the 6 Crisp executables into `./bin/` or `./tools/`:
   - `crisp-compile-windows.exe`, `crisp-compile-linux`
   - `crisp-hoist-l0-windows.exe`, `crisp-hoist-l0-linux`
   - `crisp-hoist-cuda-windows.exe`, `crisp-hoist-cuda-linux`
3. Run the automated packaging helper from the repository root:
   ```cmd
   python scripts/package_prerelease.py
   ```
   - If any files are missing, it will report exactly which ones are needed.
   - Once all 16 files are found, it will automatically package them into `crisp-prerelease-001.zip` at the root of the repository.

---

## Instructions for GitHub Website

Once `crisp-prerelease-001.zip` is generated, follow these steps on GitHub:

1. Navigate to your repository on GitHub: https://github.com/cperkinscperkins/crisp
2. On the right-hand sidebar, click **Releases** (or go to `https://github.com/cperkinscperkins/crisp/releases`).
3. Click the **Draft a new release** button at the top right.
4. **Choose a tag**:
   - Type: `prerelease-001`
   - Click **Create new tag: prerelease-001 on publish** (target branch: your default branch or release branch).
5. **Release title**:
   - Enter: `Crisp Prerelease 001`
6. **Describe this release** (Markdown):
   ```markdown
   # Crisp Prerelease 001

   This prerelease bundle contains pre-compiled binaries for **Windows** and **Linux (x86_64)**, including:
   - `crisp-compile` (Crisp Compiler)
   - `crisp-hoist-l0` (Level Zero C++ Hoisting Generator)
   - `crisp-hoist-cuda` (CUDA C++ Hoisting Generator)
   - Complete LLVM supporting toolset (`LLVM-C`, `llc`, `llvm-as`, `llvm-spirv`)

   ## Quick Install
   Clone the repository and run:
   ```bash
   python init_bin.py
   ```
   *(Or double-click `init_bin.bat` on Windows / run `./init_bin.sh` on Linux).*
   ```
7. **Attach binaries by dropping them here**:
   - Drag and drop `crisp-prerelease-001.zip` into the attach assets box (or click to browse and select it).
8. Check the **Set as a pre-release** checkbox.
9. Click **Publish release**!
