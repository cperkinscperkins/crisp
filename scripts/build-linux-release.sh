#!/usr/bin/env bash
# Build the Linux x86_64 release binaries in Docker and drop them into dist/ for
# scripts/package_prerelease.py:
#   dist/crisp-compile-linux  dist/crisp-hoist-l0-linux  dist/crisp-hoist-cuda-linux  dist/LLVM-C-linux.so
#   dist/llc-linux
# The container builds from a COPY of the working tree (put_temp_files_here, .git and other bulk excluded),
# so nothing in the checkout is touched except dist/.  Smoke-tests the compiler before copying out.
#
# Usage (from the repository root):   bash scripts/build-linux-release.sh
set -euo pipefail

IMAGE=crisp-linux-release
cd "$(dirname "$0")/.."
mkdir -p dist

docker build -t "$IMAGE" -f Dockerfile.linux-release .

# Git Bash on Windows rewrites "/src"-style arguments into Windows paths; turn that off and give
# docker a C:/... source path instead (pwd -W).  On Linux / macOS pwd -W fails and pwd is used.
SRC_DIR=$(pwd -W 2>/dev/null || pwd)
MSYS_NO_PATHCONV=1 docker run --rm -v "${SRC_DIR}:/src" "$IMAGE" bash -c '
  set -euo pipefail
  # a clean copy of the tree, without the bulky or irrelevant parts
  tar -C /src --exclude=./put_temp_files_here --exclude=./.git --exclude=./coverage-report \
      --exclude=./dist --exclude=./bin --exclude="*.fasl" -cf - . | tar -C /build -xf -
  cd /build
  sbcl --non-interactive --load build/build.lisp > /tmp/build.log 2>&1 || { tail -40 /tmp/build.log; exit 1; }
  # libLLVM for the release: the apt LLVM 21 shared library, as LLVM-C-linux.so
  LIB=$(readlink -f /usr/lib/llvm-21/lib/libLLVM.so)
  cp "$LIB" bin/libLLVM.so
  # llc for the release: apt llc-21 (all targets, NVPTX included) is a thin launcher over libLLVM.so.21.1
  # found via $ORIGIN/../lib; relink it to the libLLVM.so beside it in bin/.
  cp "$(readlink -f /usr/lib/llvm-21/bin/llc)" bin/llc
  patchelf --replace-needed "$(basename "$LIB")" libLLVM.so --set-rpath "\$ORIGIN" bin/llc
  ./bin/llc --version | grep -q nvptx64 || { echo "llc has no NVPTX target"; exit 1; }
  # smoke test: the release compiler, loading the release libLLVM
  ./bin/crisp-compile tests/spec/001-def-function/01-return_7.crisp > /tmp/smoke.ll
  grep -q "define" /tmp/smoke.ll || { echo "smoke test FAILED"; cat /tmp/smoke.ll | head -20; exit 1; }
  ./bin/crisp-compile --ir-target=spv tests/spec/001-def-function/01-return_7.crisp > /tmp/smoke-spv.log 2>&1 || { tail -20 /tmp/smoke-spv.log; exit 1; }
  ./bin/crisp-compile --ir-target=ptx tests/spec/001-def-function/01-return_7.crisp > /tmp/smoke-ptx.log 2>&1 || { tail -20 /tmp/smoke-ptx.log; exit 1; }
  grep -q "\.target sm_" tests/spec/001-def-function/01-return_7.ptx || { echo "no .target in PTX"; exit 1; }
  cp bin/crisp-compile      /src/dist/crisp-compile-linux
  cp bin/crisp-hoist-l0     /src/dist/crisp-hoist-l0-linux
  cp bin/crisp-hoist-cuda   /src/dist/crisp-hoist-cuda-linux
  cp "$LIB"                 /src/dist/LLVM-C-linux.so
  cp bin/llc                /src/dist/llc-linux
  echo "libLLVM: $LIB"
  sbcl --version
'
ls -la dist/
