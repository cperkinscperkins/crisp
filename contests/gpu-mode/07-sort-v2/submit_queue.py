"""Submit (file, gpu, mode) jobs in order, waiting out popcorn's 6-per-hour rate limit.

usage: python submit_queue.py file:gpu:mode [file:gpu:mode ...]
Each run is recorded in results/sort_v2.json by package_sort.submit_popcorn; a one-line summary per job
is printed.
"""
import re
import sys
import time

import package_sort as p

for job in sys.argv[1:]:
    f, gpu, mode = job.split(":")
    for attempt in range(8):
        out = p.submit_popcorn(p.HERE / f, gpu, mode)
        wait = re.search(r"Try again in (\d+)s", out or "")
        if not wait:
            log = (p.HERE / "_build" / f"popcorn_{f[:-3]}_{gpu}_{mode}.log").read_text(encoding="utf-8", errors="replace")
            keys = [l.strip() for l in log.splitlines()
                    if re.search(r"Geomean score|⏱|✅|❌|rror", l)][:8]
            print(f"{job}: " + " | ".join(keys), flush=True)
            break
        time.sleep(int(wait.group(1)) + 20)
