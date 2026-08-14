#!/usr/bin/env python3
"""
Crisp Prerelease Packaging Script

Workflow for creating a new release:
1. Update `OUTPUT_ZIP` and the tag names at the bottom of this script to reflect the new version (e.g. 002).
2. Build the Linux binaries (typically via Docker or a Linux VM) and place them in `tools/` or `bin/`.
3. Build the Windows binaries (`sbcl --non-interactive --load .\\build\\build.lisp`) and ensure they are also in `tools/` or `bin/`.
   Ensure the build processes do not clobber each other's output.
4. Run this script from the project root: `python .\\scripts\\package_prerelease.py`
5. Upload the resulting zip file to the GitHub Release.
"""

import os
import sys
import zipfile
import shutil
OUTPUT_ZIP = "crisp-prerelease-001.zip"

REQUIRED_TOOLS = [
    "LICENSE-llc.txt",
    "LICENSE-llvm-spirv.txt",
    "LLVM-C-windows.dll",
    "LLVM-C-linux.so",
    "llc-windows.exe",
    "llc-linux",
    "llvm-as-windows.exe",
    "llvm-as-linux",
    "llvm-spirv-windows.exe",
    "llvm-spirv-linux",
]

# Map required archive name -> list of possible relative file paths to search
CRISP_BINARIES = {
    "crisp-compile-windows.exe": [
        "tools/crisp-compile-windows.exe",
        "bin/crisp-compile-windows.exe",
        "bin/crisp-compile.exe",
        "dist/crisp-compile-windows.exe",
        "crisp-compile-windows.exe",
    ],
    "crisp-compile-linux": [
        "tools/crisp-compile-linux",
        "bin/crisp-compile-linux",
        "bin/crisp-compile",
        "dist/crisp-compile-linux",
        "crisp-compile-linux",
    ],
    "crisp-hoist-l0-windows.exe": [
        "tools/crisp-hoist-l0-windows.exe",
        "bin/crisp-hoist-l0-windows.exe",
        "bin/crisp-hoist-l0.exe",
        "dist/crisp-hoist-l0-windows.exe",
        "crisp-hoist-l0-windows.exe",
    ],
    "crisp-hoist-l0-linux": [
        "tools/crisp-hoist-l0-linux",
        "bin/crisp-hoist-l0-linux",
        "bin/crisp-hoist-l0",
        "dist/crisp-hoist-l0-linux",
        "crisp-hoist-l0-linux",
    ],
    "crisp-hoist-cuda-windows.exe": [
        "tools/crisp-hoist-cuda-windows.exe",
        "bin/crisp-hoist-cuda-windows.exe",
        "bin/crisp-hoist-cuda.exe",
        "dist/crisp-hoist-cuda-windows.exe",
        "crisp-hoist-cuda-windows.exe",
    ],
    "crisp-hoist-cuda-linux": [
        "tools/crisp-hoist-cuda-linux",
        "bin/crisp-hoist-cuda-linux",
        "bin/crisp-hoist-cuda",
        "dist/crisp-hoist-cuda-linux",
        "crisp-hoist-cuda-linux",
    ],
}

def find_tool_file(filename):
    for dir_name in ["tools", "bin", "dist", "."]:
        path = os.path.join(dir_name, filename)
        if os.path.exists(path):
            return path
    return None

def find_crisp_binary(archive_name, search_paths):
    for path in search_paths:
        if os.path.exists(path):
            return path
    return None

def main():
    print(f"=== Crisp Prerelease Packaging Tool ===")
    print(f"Checking for 16 required binary and tool files...\n")

    found_files = {}
    missing_files = []

    # 1. Check tools
    for tool in REQUIRED_TOOLS:
        path = find_tool_file(tool)
        if path:
            found_files[tool] = path
        else:
            missing_files.append(f"{tool} (expected in 'tools/')")

    # 2. Check Crisp binaries
    for arc_name, candidate_paths in CRISP_BINARIES.items():
        path = find_crisp_binary(arc_name, candidate_paths)
        if path:
            found_files[arc_name] = path
        else:
            missing_files.append(f"{arc_name} (checked: {', '.join(candidate_paths)})")

    print("Found Files:")
    for arc_name, path in found_files.items():
        size_mb = os.path.getsize(path) / (1024 * 1024)
        print(f"  [OK]  {arc_name:<28} <- {path} ({size_mb:.2f} MB)")

    if missing_files:
        print("\n[MISSING] The following required files were not found:")
        for missing in missing_files:
            print(f"  - {missing}")
        print("\nCannot create release archive until all 16 files are available.")
        print("Tip: Build Windows binaries using 'sbcl --load build/build.lisp' on Windows,")
        print("and Linux binaries on Linux/Docker, then place them in 'tools/' or 'bin/'.")
        sys.exit(1)

    print(f"\nAll 16 files found! Packaging into '{OUTPUT_ZIP}'...")
    if os.path.exists(OUTPUT_ZIP):
        os.remove(OUTPUT_ZIP)

    with zipfile.ZipFile(OUTPUT_ZIP, "w", compression=zipfile.ZIP_DEFLATED) as zip_ref:
        for arc_name, path in found_files.items():
            print(f"  Adding: {arc_name}...")
            zip_ref.write(path, arcname=arc_name)

    total_mb = os.path.getsize(OUTPUT_ZIP) / (1024 * 1024)
    print(f"\n[SUCCESS] Successfully created '{OUTPUT_ZIP}' ({total_mb:.2f} MB)!")
    print(f"Ready to upload to GitHub Release 'Crisp Prerelease 001' (tag: 'prerelease-001').")

if __name__ == "__main__":
    main()
