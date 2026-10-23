#!/usr/bin/env python3
"""
Autonomous driver for vectorsum_v2 contest submissions.
Submits leaderboard runs across H100, B200, A100, and L4, then refreshes the contest report.
"""

import subprocess
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
PKG_SCRIPT = Path(__file__).resolve().parent / "package_vectorsum.py"
REPORT_SCRIPT = Path(__file__).resolve().parents[1] / "report.py"

def run_cmd(cmd: list[str]) -> tuple[int, str]:
    print(f"\n>>> Running: {' '.join(cmd)}", flush=True)
    proc = subprocess.run(
        cmd,
        cwd=str(REPO_ROOT),
        text=True,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
    )
    print(proc.stdout, flush=True)
    if proc.stderr:
        print(proc.stderr, flush=True)
    return proc.returncode, proc.stdout + "\n" + proc.stderr

def main() -> None:
    # 1. Regenerate submission files with prefixed registers
    print("=== Step 1: Regenerating Submission Files ===")
    code, out = run_cmd([sys.executable, str(PKG_SCRIPT)])
    if code != 0:
        print("Failed to regenerate submission files!", file=sys.stderr)
        sys.exit(code)

    gpus = ["H100", "B200", "A100", "L4"]
    for gpu in gpus:
        print(f"\n==================================================")
        print(f"=== Submitting Leaderboard Run on {gpu} ===")
        print(f"==================================================")
        flag = f"--{gpu.lower()}"
        code, out = run_cmd([sys.executable, str(PKG_SCRIPT), "--leaderboard", flag])
        
        # Check if rate limited
        if "429 Too Many Requests" in out or "Rate limit exceeded" in out:
            print(f"Rate limited on {gpu}! Output:\n{out}", file=sys.stderr)
            break
        
        time.sleep(5)

    # 3. Refresh contest reports
    print("\n=== Step 3: Refreshing Contest Reports ===")
    run_cmd([sys.executable, str(REPORT_SCRIPT), "--refresh", "--all"])
    print("\n=== Autonomous Submission Run Complete ===")

if __name__ == "__main__":
    main()

