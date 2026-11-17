#!/usr/bin/env bash
# Builds the crisp-gpu Python wheels (Linux x86_64) into dist/wheels/:
#   crisp_gpu-VERSION-py3-none-manylinux_2_35_x86_64.whl        compiler, LLVM, C API, Python layer
#   crisp_gpu_hoist-VERSION-py3-none-manylinux_2_35_x86_64.whl  the hoist programs (crisp-gpu needs it)
# Two wheels because PyPI's limit is 100 MB per uploaded file (see scripts/make_wheel.py).
#
# Everything is built in Docker on Ubuntu 22.04 (Dockerfile.wheel), so the binaries need glibc 2.35
# at most.  The compiler is built from a clean copy of this tree (as scripts/build-linux-release.sh
# does), then staged as crisp_gpu/ with bin/ inside it:
#   crisp-compile, crisp-hoist-{cuda,l0}  SBCL executables (not patchelf'd: their core is appended)
#   libcrisp.so                           the C compile API (starts crisp-compile --serve beside it)
#   libLLVM.so                            apt.llvm.org's jammy LLVM 21, RUNPATH $ORIGIN
#   llc, llvm-as                          apt's thin launchers over it, relinked to bin/libLLVM.so
#   llvm-spirv                            tools/llvm-spirv-linux (apt.llvm.org has no SPIR-V translator)
#   lib*.so.N                             libLLVM's non-glibc dependencies (libffi, libxml2, ICU ...)
# then smoke-tested from an unrelated directory and zipped by scripts/make_wheel.py.
#
# Usage (repo root):  ./scripts/build-wheel.sh [VERSION]      (default 0.5.0)
# Test the result:    ./scripts/test-wheel.sh
set -euo pipefail
VERSION="${1:-0.5.0}"
IMAGE=crisp-wheel
PLAT=manylinux_2_35_x86_64
cd "$(dirname "$0")/.."
mkdir -p dist/wheels
docker build -t "$IMAGE" -f Dockerfile.wheel .
SRC_DIR=$(pwd -W 2>/dev/null || pwd)
MSYS_NO_PATHCONV=1 docker run --rm -e VERSION="$VERSION" -e PLAT="$PLAT" -v "${SRC_DIR}:/src" "$IMAGE" bash -c '
  set -euo pipefail
  # a clean copy of the tree.  GNU tar exits 1 for "file changed as we read it" (a test run writing
  # into tests/ meanwhile); that is not a failure here, a real tar error is 2.
  set +o pipefail
  tar -C /src --exclude=./put_temp_files_here --exclude=./.git --exclude=./coverage-report \
      --exclude=./dist --exclude=./bin --exclude=./third_party --exclude="*.fasl" \
      --warning=no-file-changed -cf - . | tar -C /build -xf -
  st=("${PIPESTATUS[@]}")
  set -o pipefail
  [ "${st[0]}" -le 1 ] && [ "${st[1]}" -eq 0 ] || { echo "copying the tree failed: tar ${st[*]}"; exit 1; }
  echo "tree copied ($(du -sh /build | cut -f1))"
  cd /build
  mkdir -p bin
  # the build loads the compiler, which loads bin/libLLVM.so
  LIB=$(readlink -f /usr/lib/llvm-21/lib/libLLVM.so)
  cp "$LIB" bin/libLLVM.so
  CC=gcc sbcl --non-interactive --load build/build.lisp > /tmp/build.log 2>&1 || { tail -40 /tmp/build.log; exit 1; }
  for f in crisp-compile crisp-hoist-cuda crisp-hoist-l0 libcrisp.so; do
    test -f bin/$f || { echo "build did not produce bin/$f"; tail -20 /tmp/build.log; exit 1; }
  done

  # ---- stage crisp_gpu/ ----
  S=/tmp/stage; P=$S/crisp_gpu; B=$P/bin
  rm -rf $S; mkdir -p $B
  cp python/crisp_gpu/*.py $P/
  # the wheel version (0.5.0rc1 for a TestPyPI candidate) becomes crisp_gpu.__version__
  # (no apostrophes in this script: it is one single-quoted bash -c argument)
  sed -i "s/^__version__ = .*/__version__ = \"$VERSION\"/" $P/__init__.py
  grep -q "^__version__ = \"$VERSION\"$" $P/__init__.py || { echo "could not set __version__"; exit 1; }
  cp c-api/python/crisp_ctypes.py $P/_capi.py
  cp LICENSE NOTICE $S/
  test -f python/README-pypi.md && cp python/README-pypi.md $S/
  cp bin/crisp-compile bin/crisp-hoist-cuda bin/crisp-hoist-l0 bin/libcrisp.so $B/
  cp "$LIB" $B/libLLVM.so
  for t in llc llvm-as; do
    cp "$(readlink -f /usr/lib/llvm-21/bin/$t)" $B/$t
    patchelf --replace-needed "$(basename "$LIB")" libLLVM.so --set-rpath "\$ORIGIN" $B/$t
  done
  cp tools/llvm-spirv-linux $B/llvm-spirv
  cp tools/LICENSE-llc.txt tools/LICENSE-llvm-spirv.txt $B/
  chmod 755 $B/crisp-compile $B/crisp-hoist-cuda $B/crisp-hoist-l0 $B/llc $B/llvm-as $B/llvm-spirv

  # vendor every non-glibc, non-libstdc++ dependency of the bundled ELF files (manylinux allows
  # glibc, libstdc++ and libgcc_s from the system); the SBCL executables are checked, not patched
  SKIP="linux-vdso|ld-linux|libc\.so|libm\.so|libdl\.so|librt\.so|libpthread\.so|libstdc\+\+|libgcc_s|libLLVM"
  for round in 1 2 3; do
    for f in $B/libLLVM.so $B/llc $B/llvm-as $B/llvm-spirv $B/libcrisp.so $B/lib*.so.*; do
      [ -f "$f" ] || continue
      # (grep -v exits 1 when every dependency is a system one -- not an error)
      { ldd "$f" | awk "/=> \\//{print \$3}" | grep -v -E "$SKIP" || true; } | while read -r dep; do
        [ -f "$B/$(basename "$dep")" ] || cp "$(readlink -f "$dep")" "$B/$(basename "$dep")"
      done
    done
  done
  for f in $B/libLLVM.so $B/lib*.so.*; do [ -f "$f" ] && patchelf --set-rpath "\$ORIGIN" "$f"; done
  for f in $B/crisp-compile $B/crisp-hoist-cuda $B/crisp-hoist-l0; do
    if ldd "$f" | grep -q "not found"; then echo "$f: missing libraries"; ldd "$f"; exit 1; fi
  done
  echo "--- bin/ ---"; ls -la $B | awk "{print \$5, \$9}"

  # glibc floor: no bundled ELF may need a GLIBC_ symbol newer than the tag claims
  MAXV=$(for f in $B/*; do strings -a "$f" 2>/dev/null | grep -o -E "^GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?$" ; done \
         | sed "s/GLIBC_//" | sort -t. -k1,1n -k2,2n | tail -1)
  echo "highest GLIBC_ symbol version: $MAXV (tag $PLAT)"
  python3 -c "import sys; v=tuple(map(int,\"$MAXV\".split(\".\")[:2])); sys.exit(0 if v <= (2,35) else 1)" \
    || { echo "a bundled binary needs glibc $MAXV > 2.35"; exit 1; }

  # ---- smoke test, from an unrelated directory (crisp-compile must find bin/ beside itself) ----
  mkdir -p /tmp/smoke && cd /tmp/smoke
  cp /build/tests/spec/001-def-function/01-return_7.crisp k.crisp
  $B/crisp-compile --ir-target=ptx k.crisp > ptx.log 2>&1 || { tail -20 ptx.log; exit 1; }
  grep -q "\.target sm_" k.ptx || { echo "smoke: no .target in PTX"; exit 1; }
  $B/crisp-compile --ir-target=spv k.crisp > spv.log 2>&1 || { tail -20 spv.log; exit 1; }
  test -s k.spv || { echo "smoke: no SPIR-V"; exit 1; }
  cp /build/tests/spec/029-hoist-l0/01-minimal-kernel.crisp h.crisp
  $B/crisp-compile --ir-target=spv --hoist=l0 h.crisp > hoist.log 2>&1 || { tail -20 hoist.log; exit 1; }
  ls h_*_L0.cpp > /dev/null || { echo "smoke: no hoist output"; exit 1; }
  echo "smoke: PTX, SPIR-V and an L0 hoist OK from $(pwd)"
  cd /build

  python3 scripts/make_wheel.py $S /src/dist/wheels "$VERSION" "$PLAT"
  sbcl --version
'
ls -la dist/wheels/
