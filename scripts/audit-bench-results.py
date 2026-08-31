#!/usr/bin/env python3
"""Audit a benchmark run: which contenders actually produced data, and which silently did not.

WHY THIS EXISTS.  Endeavour 159's first H100 run spent a rental and came back with an empty Peer
column in every §2 table.  Nothing had failed loudly enough to notice: CUTLASS could not build
(the pod had no third-party deps) so each of its 13 configs wrote a result file containing ZERO
data points, and the report rendered that as "--" -- which reads exactly like "we measured it and
it was nothing" rather than "this never ran".  The Crisp column was empty for a different reason
entirely (no NVIDIA 16-bit kernel existed), and looked identical.

An empty cell has at least three causes that a reader cannot distinguish:
    * the contender was never built        (missing dependency)
    * the contender has no source          (nobody wrote the kernel)
    * the contender ran and failed to verify (a real, interesting result)
This tells them apart, from the artifacts, in one pass.

Run it after any sweep -- and especially as the last step of a SMOKE run, where the whole point is
to learn that something is missing while the GPU has been rented for two minutes instead of forty.

    python3 scripts/audit-bench-results.py [--results-dir benchmarks/results]
                                           [--since-epoch N] [--platform-substr H100]
"""
import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def load(p):
    try:
        return json.load(open(p, encoding="utf-8"))
    except Exception:
        return None


def npoints(d):
    """Data points that carry an actual throughput number."""
    n = 0
    for r in (d.get("results") or []):
        m = r.get("metrics") or {}
        t = (m.get("throughput") or {}).get("tflops")
        if t is not None:
            n += 1
    return n


def nverified(d):
    v = 0
    for r in (d.get("results") or []):
        if (r.get("configuration") or {}).get("verified"):
            v += 1
    return v


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results-dir", default=str(ROOT / "benchmarks" / "results"))
    ap.add_argument("--since-epoch", type=int, default=0,
                    help="only files whose trailing _<epoch>.json is >= this (0 = all)")
    ap.add_argument("--platform-substr", default="",
                    help="only files whose name contains this (e.g. H100_PCIe)")
    a = ap.parse_args()

    rows = []
    for p in sorted(Path(a.results_dir).glob("*.json")):
        if a.platform_substr and a.platform_substr not in p.name:
            continue
        m = re.search(r"_(\d{9,})\.json$", p.name)
        if a.since_epoch and (not m or int(m.group(1)) < a.since_epoch):
            continue
        d = load(p)
        if d is None:
            rows.append((p.name, "?", "?", 0, 0, "UNPARSEABLE"))
            continue
        chap = d.get("chapter") or "?"
        comp = d.get("competitor") or "?"
        pts, ver = npoints(d), nverified(d)
        if pts == 0:
            # An error recorded inside the file is the useful distinction.
            err = ""
            for r in (d.get("results") or []):
                e = r.get("error") or (r.get("metrics") or {}).get("error")
                if e:
                    err = str(e)[:70]
                    break
            status = f"NO DATA — {err}" if err else "NO DATA — no error recorded"
        elif ver == 0:
            status = "UNVERIFIED (excluded from report)"
        elif ver < pts:
            status = f"PARTIAL ({ver}/{pts} verified)"
        else:
            status = "ok"
        rows.append((p.name, chap, comp, pts, ver, status))

    by_chapter = defaultdict(list)
    for name, chap, comp, pts, ver, status in rows:
        by_chapter[chap].append((comp, pts, ver, status))

    bad = 0
    print(f"{'chapter':28} {'competitor':32} {'pts':>4} {'ver':>4}  status")
    print("-" * 108)
    for chap in sorted(by_chapter):
        for comp, pts, ver, status in sorted(by_chapter[chap]):
            if status != "ok":
                bad += 1
            print(f"{chap:28} {comp:32} {pts:>4} {ver:>4}  {status}")

    print("-" * 108)
    print(f"{len(rows)} result files, {bad} not ok")
    if bad:
        print("\nNOT-OK rows are not necessarily failures -- an UNVERIFIED row is a real finding "
              "(the kernel ran and got the wrong answer).\nA 'NO DATA' row is the dangerous one: "
              "nothing ran, and the report will render it identically to a contender that has no "
              "source at all.")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
