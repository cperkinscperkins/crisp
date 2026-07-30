import os
import sys
import stat
import shutil
import zipfile
import urllib.request
import argparse

# --- CONFIGURATION ---
TOOLS_DIR = "tools"
BIN_DIR = "bin"
ZIP_URL = "https://github.com/cperkinscperkins/crisp/releases/download/prerelease-001/crisp-prerelease-001.zip"
ZIP_FILENAME = "crisp-prerelease-001.zip"

WINDOWS_MAPPING = [
    ("crisp-compile-windows.exe", "crisp-compile.exe"),
    ("crisp-hoist-l0-windows.exe", "crisp-hoist-l0.exe"),
    ("crisp-hoist-cuda-windows.exe", "crisp-hoist-cuda.exe"),
    ("LLVM-C-windows.dll", "LLVM-C.dll"),
    ("llc-windows.exe", "llc.exe"),
    ("llvm-as-windows.exe", "llvm-as.exe"),
    ("llvm-spirv-windows.exe", "llvm-spirv.exe"),
    ("LICENSE-llc.txt", "LICENSE-llc.txt"),
    ("LICENSE-llvm-spirv.txt", "LICENSE-llvm-spirv.txt"),
]

LINUX_MAPPING = [
    ("crisp-compile-linux", "crisp-compile"),
    ("crisp-hoist-l0-linux", "crisp-hoist-l0"),
    ("crisp-hoist-cuda-linux", "crisp-hoist-cuda"),
    ("LLVM-C-linux.so", "libLLVM.so"),
    ("llc-linux", "llc"),
    ("llvm-as-linux", "llvm-as"),
    ("llvm-spirv-linux", "llvm-spirv"),
    ("LICENSE-llc.txt", "LICENSE-llc.txt"),
    ("LICENSE-llvm-spirv.txt", "LICENSE-llvm-spirv.txt"),
]

EXECUTABLES_UNIX = {
    "crisp-compile",
    "crisp-hoist-l0",
    "crisp-hoist-cuda",
    "llc",
    "llvm-as",
    "llvm-spirv",
}

def is_windows():
    return sys.platform.startswith("win")

def check_already_installed(mapping):
    for _, dest_name in mapping:
        dest_path = os.path.join(BIN_DIR, dest_name)
        if not os.path.exists(dest_path):
            return False
    return True

def download_file(url, target_filename):
    print(f"Downloading Crisp Prerelease from:\n  {url}")
    try:
        with urllib.request.urlopen(url) as response, open(target_filename, "wb") as out_file:
            shutil.copyfileobj(response, out_file)
        print("Download complete.")
        return True
    except Exception as e:
        print(f"Error downloading binary release: {e}")
        return False

def extract_zip(zip_path, target_dir):
    print(f"Extracting {zip_path} into '{target_dir}/'...")
    try:
        os.makedirs(target_dir, exist_ok=True)
        with zipfile.ZipFile(zip_path, "r") as zip_ref:
            zip_ref.extractall(target_dir)
        print("Extraction complete.")
        return True
    except zipfile.BadZipFile:
        print("Error: The downloaded file is not a valid zip archive.")
        return False
    except Exception as e:
        print(f"Error extracting archive: {e}")
        return False

def deploy_to_bin(mapping):
    os.makedirs(BIN_DIR, exist_ok=True)
    print(f"Deploying platform binaries to '{BIN_DIR}/'...")
    missing_tools = []

    for src_name, dest_name in mapping:
        src_path = os.path.join(TOOLS_DIR, src_name)
        dest_path = os.path.join(BIN_DIR, dest_name)

        if not os.path.exists(src_path):
            missing_tools.append(src_name)
            continue

        shutil.copy2(src_path, dest_path)
        print(f"  Copied: {src_name} -> {BIN_DIR}/{dest_name}")

        if not is_windows() and dest_name in EXECUTABLES_UNIX:
            try:
                st = os.stat(dest_path)
                os.chmod(dest_path, st.st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
            except Exception as e:
                print(f"  Warning: Could not set executable permission on {dest_path}: {e}")

    if missing_tools:
        print(f"\nWarning: The following expected files were missing from '{TOOLS_DIR}/':")
        for tool in missing_tools:
            print(f"  - {tool}")
        return False

    return True

def main():
    parser = argparse.ArgumentParser(description="Initialize Crisp Pre-built Binaries")
    parser.add_argument("-f", "--force", action="store_true", help="Force download and reinstall binaries")
    args = parser.parse_args()

    mapping = WINDOWS_MAPPING if is_windows() else LINUX_MAPPING

    if not args.force and check_already_installed(mapping):
        exe_name = "crisp-compile.exe" if is_windows() else "crisp-compile"
        print(f"Crisp binaries appear to be installed in '{BIN_DIR}/' ({BIN_DIR}/{exe_name} present).")
        print("Use 'python init_bin.py --force' to re-download and reinstall.")
        return

    # 1. Use local zip if available, otherwise download
    zip_path = ZIP_FILENAME
    downloaded_temp = False

    if os.path.exists(zip_path):
        print(f"Using local release archive: {zip_path}")
    else:
        if not download_file(ZIP_URL, zip_path):
            print("\nFailed to obtain Crisp release binaries.")
            print(f"You can manually download {ZIP_FILENAME} from the GitHub release page")
            print(f"and place it in this directory, then re-run 'python init_bin.py'.")
            return
        downloaded_temp = True

    # 2. Extract into tools/
    if not extract_zip(zip_path, TOOLS_DIR):
        if downloaded_temp and os.path.exists(zip_path):
            os.remove(zip_path)
        return

    # 3. Deploy OS-specific files to bin/
    success = deploy_to_bin(mapping)

    # 4. Cleanup temporary download
    if downloaded_temp and os.path.exists(zip_path):
        try:
            os.remove(zip_path)
            print(f"Removed temporary archive {zip_path}.")
        except Exception as e:
            print(f"Warning: Could not remove temporary file {zip_path}: {e}")

    if success:
        print(f"\nSuccess! Crisp binaries are ready in '{BIN_DIR}/'.")
        test_exe = f"{BIN_DIR}\\\\crisp-compile.exe" if is_windows() else f"./{BIN_DIR}/crisp-compile"
        print(f"Try running:\n  {test_exe} --help")
    else:
        print(f"\nBinaries deployed with some missing files. Check warning messages above.")

if __name__ == "__main__":
    main()
