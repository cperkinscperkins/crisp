#!/usr/bin/env bash
# Builds the Crisp compile API library into bin/ (crisp.dll / libcrisp.so), next to crisp-compile.
# The real build is build/build-c-api.lisp, which build/build.lisp also runs; this is a shortcut.
# Run from the repo root.  CC selects the C compiler (default: gcc, else clang).
set -euo pipefail
sbcl --non-interactive --load build/build-c-api.lisp
