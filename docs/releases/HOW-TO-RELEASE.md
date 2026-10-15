# How to make a Crisp prerelease

A prerelease is a git tag `prerelease-NNN` plus a GitHub release of the same name carrying
`crisp-prerelease-NNN.zip` (Windows + Linux binaries and the LLVM 21 tools).  `init_bin.py` in a checkout
of that tag downloads exactly that zip, so the tag, `RELEASE` in `init_bin.py` and the zip name must agree.

## Steps (NNN = the new number, e.g. 002)

1. **Green.**  On the branch being released: unit, E2E, negative and `--differentiate` suites pass locally
   (CLAUDE.md, "Running Tests"), and CI is green.
2. **Version.**  Set `RELEASE = "NNN"` in `init_bin.py`; update the release number in `INSTALL.md`
   ("Fetch & Deploy Binaries"); write `docs/releases/prerelease-NNN.md` (highlights since the last tag:
   `git log --oneline prerelease-<last>..HEAD`).
3. **Windows binaries.**  `sbcl --non-interactive --load .\build\build.lisp` — fills `bin/`.
4. **Linux binaries.**  `bash scripts/build-linux-release.sh` — builds in Docker (Ubuntu 24.04, SBCL from apt,
   LLVM 21), smoke-tests the compiler (LLVM IR, SPV, PTX), and writes `dist/crisp-compile-linux`,
   `dist/crisp-hoist-l0-linux`, `dist/crisp-hoist-cuda-linux`, `dist/LLVM-C-linux.so` and `dist/llc-linux`
   (apt's `llc-21`, relinked with `patchelf` to load the `libLLVM.so` beside it).
5. **Package.**  `python scripts/package_prerelease.py --version NNN` — checks all 16 files
   (`dist/`, `tools/`, `bin/`) and writes `crisp-prerelease-NNN.zip`.
6. **Commit and merge** the version changes to `main`.
7. **Tag** the merge commit and push the tag:
   ```
   git tag -a prerelease-NNN -m "Crisp Prerelease NNN"
   git push origin prerelease-NNN
   ```
8. **Publish** the GitHub release from the tag:
   ```
   gh release create prerelease-NNN crisp-prerelease-NNN.zip --prerelease \
      --title "Crisp Prerelease NNN" --notes-file docs/releases/prerelease-NNN.md
   ```
9. **Verify** from a fresh clone of the tag: `python init_bin.py`, then
   `bin/crisp-compile tests/spec/001-def-function/01-return_7.crisp` prints LLVM IR, and `--ir-target=spv`
   and `--ir-target=ptx` each write their output — on Windows and on Linux (a bare `ubuntu:24.04` container
   with `python3 libedit2 libxml2` is a fair stand-in for a user's machine).

The remaining LLVM tool binaries in `tools/` (`llvm-as`, `llvm-spirv` for both platforms, `llc` for Windows)
change only when the LLVM major version does.  The old `tools/llc-linux` (an LLVM 22-git build with only the
SPIR-V and X86 targets) cannot emit PTX; `dist/llc-linux` takes precedence over it in the packager.  `opt` is
not needed (the compiler runs its optimization passes in-process).
