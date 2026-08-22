#!/usr/bin/env python3
"""
Unified Crisp Benchmark CLI Entrypoint

Decouples transport (local, Docker, RunPod) from benchmark suites (matmul, reduction).

Usage:
  # Local native run
  python scripts/bench.py --suite=matmul --target=local

  # Docker Intel BMG run
  python scripts/bench.py --suite=matmul --target=docker

  # RunPod NVIDIA GPU run
  python scripts/bench.py --suite=matmul --target=pod --host=157.157.221.29 --port=24405

  # Run exploratory / debug run (automatically isolated in results/scratch/)
  python scripts/bench.py --suite=matmul --target=pod --host=... --scratch --sizes=512,1024
"""

import argparse
import os
import sys
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

def run_local(suite: str, extra_args: list, scratch: bool = False, dry_run: bool = False):
    print(f"=== Running suite '{suite}' locally ===")
    if suite == "matmul":
        cmd = [sys.executable, str(REPO_ROOT / "scripts" / "crisp_bench" / "matmul.py"), *extra_args]
        if scratch:
            cmd.append("--scratch")
        print(f"Executing: {' '.join(cmd)}")
        if not dry_run:
            subprocess.run(cmd, cwd=REPO_ROOT, check=True)
    elif suite == "reduction":
        cmd = [sys.executable, str(REPO_ROOT / "benchmarks" / "reduction" / "run.py"), *extra_args]
        print(f"Executing: {' '.join(cmd)}")
        if not dry_run:
            subprocess.run(cmd, cwd=REPO_ROOT, check=True)
    else:
        sys.exit(f"Unknown suite: {suite}")

def run_docker(suite: str, extra_args: list, scratch: bool = False, dry_run: bool = False):
    print(f"=== Running suite '{suite}' in Docker (Intel BMG) ===")
    # bench-intel.sh handles container lifecycle and binds
    script = REPO_ROOT / "scripts" / "bench-intel.sh"
    cmd = ["bash", str(script), *extra_args]
    print(f"Executing: {' '.join(cmd)}")
    if not dry_run:
        subprocess.run(cmd, cwd=REPO_ROOT, check=True)

def run_pod(host: str, port: str, branch: str, ssh_key: str, suite: str, extra_args: list, scratch: bool = False, dry_run: bool = False):
    print(f"=== Running suite '{suite}' on RunPod ({host}:{port}) ===")
    script = REPO_ROOT / "scripts" / "bench-on-pod.sh"
    cmd = ["bash", str(script), host, port, branch, ssh_key, f"--bench={suite}"]
    if scratch:
        cmd.append("--scratch")
    cmd.extend(extra_args)
    print(f"Executing: {' '.join(cmd)}")
    if not dry_run:
        subprocess.run(cmd, cwd=REPO_ROOT, check=True)

def main():
    parser = argparse.ArgumentParser(description="Unified Crisp Benchmark Runner")
    parser.add_argument("--suite", choices=["matmul", "reduction", "all"], default="matmul",
                        help="Benchmark suite to run (default: matmul)")
    parser.add_argument("--target", choices=["local", "docker", "pod"], default="local",
                        help="Target execution environment (default: local)")
    parser.add_argument("--scratch", action="store_true",
                        help="Route output directly to benchmarks/results/scratch/ (quarantine debug data)")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print command without executing")
    
    # RunPod specific arguments
    parser.add_argument("--host", default=None, help="RunPod host IP")
    parser.add_argument("--port", default=None, help="RunPod SSH port")
    parser.add_argument("--branch", default="main", help="Git branch to test on pod")
    parser.add_argument("--ssh-key", default=str(Path.home() / ".ssh" / "id_ed25519"), help="SSH identity file")

    # Suite filter options (forwarded)
    parser.add_argument("--chapters", default=None, help="Comma-separated chapter filter")
    parser.add_argument("--sizes", default=None, help="Comma-separated size list override")
    parser.add_argument("--precision", default=None, help="Precision override (fast, ieee, all)")
    parser.add_argument("--platform", default=None, choices=["nvidia", "intel"], help="Platform target override")

    args, unknown = parser.parse_known_args()

    forwarded = []
    if args.chapters:
        forwarded.append(f"--chapters={args.chapters}")
    if args.sizes:
        forwarded.append(f"--sizes={args.sizes}")
    if args.precision:
        forwarded.append(f"--precision={args.precision}")
    if args.platform:
        forwarded.append(f"--platform={args.platform}")
    forwarded.extend(unknown)

    # Any manual override of sizes or chapters flags a non-canonical run if not explicitly requested
    is_scratch = args.scratch or bool(args.sizes)

    suites = ["matmul", "reduction"] if args.suite == "all" else [args.suite]

    for s in suites:
        if args.target == "local":
            run_local(s, forwarded, scratch=is_scratch, dry_run=args.dry_run)
        elif args.target == "docker":
            run_docker(s, forwarded, scratch=is_scratch, dry_run=args.dry_run)
        elif args.target == "pod":
            if not args.host or not args.port:
                parser.error("--host and --port are required when --target=pod")
            run_pod(args.host, args.port, args.branch, args.ssh_key, s, forwarded, scratch=is_scratch, dry_run=args.dry_run)

if __name__ == "__main__":
    main()
