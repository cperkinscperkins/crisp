# Contributing to Crisp

Welcome to the Crisp language repository! This document provides an overview of the development tools, testing scripts, and operational scripts used to build, test, and benchmark Crisp.

## The `scripts/` Directory

The `scripts/` directory contains various operational scripts. They are loosely grouped by their function below.

### Benchmarking & Remote Execution

Testing high-performance kernels requires running code on specific hardware (e.g., Intel Battlemage, NVIDIA Hopper). These scripts orchestrate that execution.

* **Intel Benchmarking**: 
  * `bench-intel.sh`, `bench-intel-entrypoint.sh`, `bench-intel-driver.py`, `Dockerfile.bench-intel`: Automate running the benchmark suite against Intel GPUs (like the B580) using a Docker container with GPU passthrough on Windows/WSL2.
* **NVIDIA / RunPod Execution**:
  * `run-on-pod.sh`: Sets up a transient RunPod instance, installs dependencies (SBCL, LLVM, Quicklisp), and runs the CUDA test suite.
  * `bench-on-pod.sh`: Similar to the above, but specifically orchestrates running benchmarks on a RunPod instance.
  * `pull-runpod-results.sh`: Fetches the resulting benchmark JSON files from the RunPod instance.
* `cull-old-benchmarks.py`: Cleans up historical benchmark files to keep the reports tidy.
* `crisp_bench/`: Directory containing the unified cross-platform Python benchmark runner.

### Documentation & Packaging

* **Releases**:
  * `package_prerelease.py`: Gathers the necessary binaries, source files, and licenses, and packages them into a distributable zip file (e.g., `crisp-prerelease-XXX.zip`).
* **Documentation**:
  * `split_docs.py` & `split-docs.lisp`: Crisp's design spec (`ideal_001.md`) is maintained as a single file. These scripts split it into multiple pages for the MkDocs static site generator.
  * `extract_status.py`: Parses the specification to extract the implementation status (✅ ⚠️ 📝) of various features for reporting.
  * `generate-reference.lisp`: Generates reference documentation from the Lisp source code.

### Code Analysis & Code Quality

* `run-coverage.lisp`: Hooks into `sb-cover` to run the test suite and generate the HTML code coverage report.
* `call-graph.lisp` & `map-globals.lisp`: Uses SBCL introspection to map out function call graphs and global variable usage. Helpful for refactoring.
* `fix_BOM_all.ps1`: A PowerShell script to strip Byte-Order Marks (BOM) from Lisp source files, avoiding compiler warnings.
* `check-parens.lisp`: A standalone utility to verify balanced parentheses in Lisp files.

### Hardware Smoke Tests & Verifications

The scripts directory contains several ad-hoc tests used to verify that the generated PTX or SPIR-V actually runs on metal (Level Zero, OpenCL, CUDA). These are often used when bringing up a new feature before generalizing it into the main test suite.

* **Intel / SPIR-V**: 
  * `l0-smoke.lisp`, `l0-load-smoke.lisp`, `run_smoke_kernel.lisp`, `run-spirv.lisp`, `verify-autodiff-l0-smoke.lisp`, `opencl_test.lisp`
* **NVIDIA / PTX**:
  * `verify-ptx-113-01.py`, `verify_autodiff.lisp`
* **Reproductions & Utilities**:
  * `patcher.lisp`: A simple file patching script (utility).
