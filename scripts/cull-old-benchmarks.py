#!/usr/bin/env python3
import argparse
import os
import re
from pathlib import Path
from collections import defaultdict

def main():
    ap = argparse.ArgumentParser(description="Prunes the benchmarks/results/ directory, keeping only the N most recent sweeps per GPU/Chapter/Competitor combination.")
    ap.add_argument("--results-dir", default=str(Path(__file__).resolve().parent.parent / "benchmarks" / "results"))
    ap.add_argument("--keep", type=int, default=5, help="Number of recent runs to keep per category (default: 5)")
    ap.add_argument("--dry-run", action="store_true", help="Print what would be deleted without actually deleting")
    a = ap.parse_args()

    results_dir = Path(a.results_dir)
    if not results_dir.exists():
        print(f"Directory {results_dir} does not exist.")
        return

    # Pattern: results_{GPU_MODEL}_{CHAPTER}_{COMPETITOR}_{TIMESTAMP}.json
    pattern = re.compile(r"results_(.+)_(chap[0-9a-zA-Z_\.]+)_([a-zA-Z_]+)_([0-9]+)\.json")

    # Group by (GPU, Chapter, Competitor) -> list of (timestamp, filepath)
    groups = defaultdict(list)

    for f in results_dir.glob("results_*.json"):
        match = pattern.match(f.name)
        if match:
            gpu = match.group(1)
            chapter = match.group(2)
            competitor = match.group(3)
            timestamp = int(match.group(4))
            groups[(gpu, chapter, competitor)].append((timestamp, f))

    deleted_count = 0
    for group_key, files in groups.items():
        # Sort by timestamp descending (newest first)
        files.sort(key=lambda x: x[0], reverse=True)

        if len(files) > a.keep:
            to_delete = files[a.keep:]
            for ts, file_path in to_delete:
                if a.dry_run:
                    print(f"[Dry Run] Would delete: {file_path.name}")
                else:
                    os.remove(file_path)
                    print(f"Deleted: {file_path.name}")
                deleted_count += 1

    if deleted_count == 0:
        print("No old benchmarks to cull.")
    else:
        action = "Would delete" if a.dry_run else "Deleted"
        print(f"{action} {deleted_count} old benchmark files.")

if __name__ == "__main__":
    main()
