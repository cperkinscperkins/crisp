import os
import urllib.request
import zipfile
import shutil

# --- CONFIGURATION ---
TOOLS_DIR = "tools"
ZIP_URL = "https://github.com/cperkinscperkins/crisp/releases/download/tools-v1/crisp-tools.zip"
ZIP_FILENAME = "crisp-tools.zip"

def main():
    # 1. Check if tools already exist to avoid redundant work
    if os.path.exists(TOOLS_DIR) and os.path.isdir(TOOLS_DIR):
        print(f"'{TOOLS_DIR}/' directory already exists.")
        # Optional: Check for specific binary to confirm validity
        if os.path.exists(os.path.join(TOOLS_DIR, "llc.exe")):
            print("Tools appear to be installed. Skipping download.")
            return

    print(f"Tools not found. Downloading from Release...")
    
    # 2. Download the zip file
    try:
        with urllib.request.urlopen(ZIP_URL) as response, open(ZIP_FILENAME, 'wb') as out_file:
            shutil.copyfileobj(response, out_file)
        print("Download complete.")
    except Exception as e:
        print(f"Error downloading tools: {e}")
        return

    # 3. Unzip the file
    print(f"Extracting {ZIP_FILENAME}...")
    try:
        with zipfile.ZipFile(ZIP_FILENAME, 'r') as zip_ref:
            zip_ref.extractall(TOOLS_DIR)
        print("Extraction complete.")
    except zipfile.BadZipFile:
        print("Error: The downloaded file is not a valid zip archive.")
        return

    # 4. Cleanup (Delete the zip file)
    if os.path.exists(ZIP_FILENAME):
        os.remove(ZIP_FILENAME)
        print(f"Removed temporary file {ZIP_FILENAME}.")

    print("Success! Tools are ready.")

if __name__ == "__main__":
    main()