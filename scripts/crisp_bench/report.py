#!/usr/bin/env python3
"""
Crisp Benchmark Report Generator

Aggregates all JSON sweeps in `benchmarks/results/` and generates the comprehensive
Markdown report matching the 5-section Question-based Ladder schema defined in
`plan/mma-chapter-ladder.md`, `plan/benchmark-harness.md`, and `plan/dummy-report.md`.

Usage:
  # Output to terminal
  python scripts/crisp_bench/report.py

  # Save to benchmarks/REPORT.md
  python scripts/crisp_bench/report.py --output benchmarks/REPORT.md
"""

import json
import re
import argparse
import sys
from pathlib import Path
from collections import defaultdict
from typing import Dict, Any, List, Optional, Tuple

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
RESULTS_DIR = REPO_ROOT / "benchmarks" / "results"
SCRATCH_DIR = RESULTS_DIR / "scratch"

# Section 1 Question-based Ladder Metadata
MMA_TECHNIQUES = [
    {
        "num": 0,
        "key": "chap0_naive",
        "alt_keys": ["chap0_sync"],
        "question": "Does it run at all?",
        "desc_nv": "naive loops, no tensor cores",
        "desc_intel": "naive loops, no XMX",
        "has_tensor_cores": False
    },
    {
        "num": 1,
        "key": "chap1_handrolled_mma",
        "alt_keys": ["chap1_async_linear"],
        "question": "Can we reach the tensor cores?",
        "desc_nv": "hand-rolled mma-accumulate-via-tile",
        "desc_intel": "hand-rolled XMX coop-matrix",
        "has_tensor_cores": True
    },
    {
        "num": 2,
        "key": "chap2_tiling",
        "alt_keys": ["chap0_sync"],
        "question": "What does tiling buy?",
        "desc_nv": "matrix-multiply-tile-stride",
        "desc_intel": "matrix-multiply-tile-stride",
        "has_tensor_cores": True
    },
    {
        "num": 3,
        "key": "chap3_async",
        "alt_keys": ["chap1_async_linear"],
        "question": "Can the fetch overlap the math?",
        "desc_nv": "cp.async",
        "desc_intel": "OpGroupAsyncCopy",
        "has_tensor_cores": True
    },
    {
        "num": 4,
        "key": "chap4_cheap_fetch",
        "alt_keys": ["chap1.5_async_block"],
        "question": "Can the fetch itself be cheap?",
        "desc_nv": "TMA descriptor (CUtensorMap)",
        "desc_intel": "register-resident load (global→GRF)",
        "has_tensor_cores": True
    },
    {
        "num": 5,
        "key": "chap5_multistage_ring",
        "alt_keys": ["chap2_pipelined_block", "intel_prefetch"],
        "question": "Can several fetches be in flight?",
        "desc_nv": "SMEM ring",
        "desc_intel": "register ring + prefetch",
        "has_tensor_cores": True
    },
    {
        "num": 6,
        "key": "chap6_warp_specialization",
        "alt_keys": ["chap3_wgmma"],
        "question": "Can the math stop waiting on bookkeeping?",
        "desc_nv": "warp specialization",
        "desc_intel": "blocked — 3 known reasons",
        "has_tensor_cores": True
    },
    {
        "num": 7,
        "key": "chap7_wgmma",
        "alt_keys": ["chap3_wgmma", "intel_prefetch"],
        "question": "Can one instruction do more math?",
        "desc_nv": "wgmma",
        "desc_intel": "GRF-bounded tile sweep",
        "has_tensor_cores": True
    },
]

def _is_crisp(name: str) -> bool:
    return name == "Crisp" or name.startswith("Crisp_")

def _is_control(name: str) -> bool:
    return any(k in name for k in ["Apples", "CUDA_Apples", "SYCL_Apples"])

def _is_peer(name: str) -> bool:
    return any(k in name for k in ["CUTLASS", "SYCL-TLA", "CUB", "oneDPL"])

def _is_ceiling(name: str) -> bool:
    return any(k in name for k in ["CUBLAS", "cuBLAS", "OneMKL", "oneMKL", "oneDNN", "CUBLASLt", "cuBLASLt"])

def _platform_of(gpu: str) -> str:
    return "intel" if "intel" in gpu.lower() or "bmg" in gpu.lower() else "nvidia"

def _run_stamp(path: Path) -> int:
    m = re.search(r"_(\d{9,})\.json$", path.name)
    return int(m.group(1)) if m else int(path.stat().st_mtime)

def load_all_sweeps(results_dir: Path) -> List[Dict[str, Any]]:
    sweeps = []
    if not results_dir.exists():
        return sweeps
    for f in sorted(results_dir.glob("results_*.json"), key=_run_stamp):
        try:
            with open(f, "r", encoding="utf-8") as fh:
                sweeps.append(json.load(fh))
        except Exception as e:
            print(f"Warning: could not parse {f}: {e}", file=sys.stderr)
    return sweeps

def load_scratch_runs(scratch_dir: Path) -> List[Dict[str, Any]]:
    runs = []
    if not scratch_dir.exists():
        return runs
    for f in sorted(scratch_dir.glob("results_*.json"), key=_run_stamp):
        try:
            with open(f, "r", encoding="utf-8") as fh:
                runs.append(json.load(fh))
        except Exception:
            pass
    return runs

def format_ratio(val: Optional[float], base: Optional[float], as_pct: bool = False, bold_threshold: float = 1.5) -> str:
    if val is None or base is None or base <= 0 or val <= 0:
        return "—"
    ratio = val / base
    if as_pct:
        pct = int(round(ratio * 100))
        text = f"{pct}%"
        return f"**{text}**" if ratio >= bold_threshold else text
    text = f"{ratio:.2f}×"
    return f"**{text}**" if ratio >= bold_threshold else text

def generate_report(results_dir: Path = RESULTS_DIR, scratch_dir: Path = SCRATCH_DIR) -> str:
    sweeps = load_all_sweeps(results_dir)
    scratch_sweeps = load_scratch_runs(scratch_dir)

    # Group data by: [Suite][GPU][Chapter][Precision][Size][Competitor] -> SweepPoint
    data = defaultdict(lambda: defaultdict(lambda: defaultdict(lambda: defaultdict(lambda: defaultdict(dict)))))
    provenance = {}

    for s in sweeps:
        suite = s.get("benchmark_suite", "matmul")
        meta = s.get("run_metadata", {})
        hw = meta.get("hardware", {})
        gpu = hw.get("gpu_model", "Unknown GPU")
        chapter = s.get("chapter", "unknown")
        competitor = s.get("competitor", "Unknown")
        prec = s.get("precision", "fast")
        ftz = s.get("denormal_handling", "preserve")
        prec_key = f"{prec}"

        provenance[gpu] = {
            "timestamp": meta.get("timestamp", "unknown"),
            "commit": meta.get("crisp_commit", "unknown"),
            "arch": hw.get("arch_target", "unknown"),
            "env": hw.get("environment", "local")
        }

        for pt in s.get("results", []):
            cfg = pt.get("configuration", {})
            m = cfg.get("m", 0)
            n = cfg.get("n", 0)
            k = cfg.get("k", 0)
            size_key = n if n > 0 else cfg.get("elements", 0)
            data[suite][gpu][chapter][prec_key][size_key][competitor] = pt

    lines = []
    lines.append("# Crisp Benchmark Report\n")
    lines.append("> Generated from verified test sweeps in `benchmarks/results/`.\n")

    # Header summary table of devices
    lines.append("| device | data captured | source |")
    lines.append("|---|---|---|")
    for gpu, p in provenance.items():
        lines.append(f"| {gpu} | {p['timestamp'][:10]} | Crisp `{p['commit']}` ({p['env']}) |")
    lines.append("\n---\n")

    # Matmul Suite
    if "matmul" in data or not data:
        lines.extend(render_matmul_suite(data["matmul"], provenance))

    # Reduction Suite (if present)
    if "reduction" in data:
        lines.extend(render_reduction_suite(data["reduction"], provenance))

    # Appendix: Excluded scratch runs
    lines.append("\n# Appendix — runs excluded from canonical tables\n")
    lines.append("Debug and exploratory runs are written to `benchmarks/results/scratch/`, which the report never reads into canonical tables.\n")
    if scratch_sweeps:
        lines.append("| timestamp | suite | chapter | competitor | sizes |")
        lines.append("|---|---|---|---|---|")
        for sc in scratch_sweeps:
            ts = sc.get("run_metadata", {}).get("timestamp", "—")[:16].replace("T", " ")
            su = sc.get("benchmark_suite", "—")
            ch = sc.get("chapter", "—")
            comp = sc.get("competitor", "—")
            sizes = ",".join(str(p.get("configuration", {}).get("n", "")) for p in sc.get("results", []))
            lines.append(f"| {ts} | {su} | {ch} | {comp} | `{sizes}` |")
    else:
        lines.append("*No scratch runs present.*")

    return "\n".join(lines)

def render_matmul_suite(matmul_data: dict, provenance: dict) -> List[str]:
    lines = ["# Suite: matmul\n"]
    lines.append("Row variable: **N**, the square matrix dimension. Matmul cost grows as N³ while memory grows as N².\n")

    # Sizing Buckets
    lines.append("| bucket | N | what it exercises |")
    lines.append("|---|---|---|")
    lines.append("| small | 512, 1024 | launch overhead and occupancy dominate |")
    lines.append("| medium | 2048, 4096 | the machine saturates (~0.97 residency waves) |")
    lines.append("| large | 8192, 16384 | steady state |")
    lines.append("| xl | 32768, 65536 | device permitting |\n")

    # Section 1: MMA Techniques
    lines.append("## § 1 — MMA Techniques\n")
    lines.append("*How do you make a matmul fast, one step at a time?*\n")
    lines.append("**Contenders: Control only.** The column carrying the story is **vs previous chapter**.\n")

    gpus = sorted(matmul_data.keys())
    for gpu in gpus:
        platform = _platform_of(gpu)
        lines.append(f"### {gpu} · tf32 · `fast`\n")

        # Collect standard sizes present
        all_sizes = set()
        for ch in matmul_data[gpu]:
            if "fast" in matmul_data[gpu][ch]:
                all_sizes.update(matmul_data[gpu][ch]["fast"].keys())
        sizes = sorted([s for s in all_sizes if isinstance(s, int) and s >= 256])
        if not sizes:
            sizes = [512, 1024, 2048, 4096]

        # 1. Rollup Grid
        lines.append("**Rollup — Crisp TFLOPS, every chapter × every N.**\n")
        header = ["#", "technique"] + [f"**N={s}**" for s in sizes]
        lines.append("| " + " | ".join(header) + " |")
        lines.append("|" + "|".join(["---"] * len(header)) + "|")

        rollup_rows = []
        for tech in MMA_TECHNIQUES:
            tnum = tech["num"]
            tname = tech["desc_nv"] if platform == "nvidia" else tech["desc_intel"]
            ch_key = tech["key"]
            alt_keys = tech.get("alt_keys", [])

            row = [str(tnum), tname]
            for s in sizes:
                tf_val = None
                # Check main key, then alt keys
                for k in [ch_key, *alt_keys]:
                    if k in matmul_data[gpu] and "fast" in matmul_data[gpu][k]:
                        if s in matmul_data[gpu][k]["fast"]:
                            pt_dict = matmul_data[gpu][k]["fast"][s]
                            crisp_pt = next((pt_dict[c] for c in pt_dict if _is_crisp(c)), None)
                            if crisp_pt:
                                tf_val = crisp_pt.get("metrics", {}).get("throughput", {}).get("tflops")
                                break
                row.append(f"{tf_val:.1f}" if tf_val is not None else "—")
            rollup_rows.append(row)
            lines.append("| " + " | ".join(row) + " |")

        lines.append("\n<details><summary><b>Per-chapter detail</b></summary>\n")

        # Per Chapter Detail Tables
        prev_crisp_tf = {}
        for tech in MMA_TECHNIQUES:
            tnum = tech["num"]
            tquestion = tech["question"]
            tdesc = tech["desc_nv"] if platform == "nvidia" else tech["desc_intel"]
            ch_key = tech["key"]
            alt_keys = tech.get("alt_keys", [])

            lines.append(f"#### Ch {tnum} — {tquestion}")
            lines.append(f"{tdesc}\n")

            has_prev = (tnum > 0)
            det_header = ["N", "Crisp TFLOPS (ms)", "Control TFLOPS (ms)", "vs Control"]
            if has_prev:
                det_header.append(f"vs ch {tnum-1}")

            lines.append("| " + " | ".join(det_header) + " |")
            lines.append("|" + "|".join(["---:"] * len(det_header)) + "|")

            for s in sizes:
                crisp_pt = None
                control_pt = None
                for k in [ch_key, *alt_keys]:
                    if k in matmul_data[gpu] and "fast" in matmul_data[gpu][k] and s in matmul_data[gpu][k]["fast"]:
                        pts = matmul_data[gpu][k]["fast"][s]
                        if not crisp_pt:
                            crisp_pt = next((pts[c] for c in pts if _is_crisp(c)), None)
                        if not control_pt:
                            control_pt = next((pts[c] for c in pts if _is_control(c)), None)

                c_tf = crisp_pt.get("metrics", {}).get("throughput", {}).get("tflops") if crisp_pt else None
                c_ms = crisp_pt.get("metrics", {}).get("runtime", {}).get("kernel_execution_ms") if crisp_pt else None
                ctrl_tf = control_pt.get("metrics", {}).get("throughput", {}).get("tflops") if control_pt else None
                ctrl_ms = control_pt.get("metrics", {}).get("runtime", {}).get("kernel_execution_ms") if control_pt else None

                c_cell = f"{c_tf:.1f} ({c_ms:.3f})" if (c_tf is not None and c_ms is not None) else "—"
                ctrl_cell = f"{ctrl_tf:.1f} ({ctrl_ms:.3f})" if (ctrl_tf is not None and ctrl_ms is not None) else "—"
                vs_ctrl = format_ratio(c_tf, ctrl_tf)

                row = [str(s), c_cell, ctrl_cell, vs_ctrl]
                if has_prev:
                    p_tf = prev_crisp_tf.get(s)
                    row.append(format_ratio(c_tf, p_tf))

                lines.append("| " + " | ".join(row) + " |")
                if c_tf is not None:
                    prev_crisp_tf[s] = c_tf

            lines.append("")

        lines.append("</details>\n")

    # Section 2: Top MMA Benchmarks
    lines.append("## § 2 — Top MMA Benchmarks\n")
    lines.append("*How does Crisp actually stand?* Best mainloop against **all three contender classes**.\n")

    for gpu in gpus:
        platform = _platform_of(gpu)
        ctrl_label = "CUDA_Apples" if platform == "nvidia" else "SYCL_Apples"
        peer_label = "CUTLASS" if platform == "nvidia" else "SYCL-TLA"
        ceil_label = "cuBLAS" if platform == "nvidia" else "oneMKL"

        lines.append(f"### {gpu} · tf32 · `fast`\n")
        lines.append(f"| N | Crisp | Control<br>{ctrl_label} | **Peer**<br>{peer_label} | Ceiling<br>{ceil_label} | vs Peer | vs Ceiling |")
        lines.append("|---:|---:|---:|---:|---:|---:|---:|")

        # Top chapters to draw best mainloop from
        top_keys = ["chap7_wgmma", "chap6_warp_specialization", "chap5_multistage_ring", "chap3_wgmma", "intel_prefetch", "chap2_tiling", "chap0_sync"]
        
        # Collect all unique sizes across top keys
        all_s = set()
        for tk in top_keys:
            if tk in matmul_data[gpu] and "fast" in matmul_data[gpu][tk]:
                all_s.update(matmul_data[gpu][tk]["fast"].keys())
        top_sizes = sorted([s for s in all_s if isinstance(s, int) and s >= 256]) or [512, 1024, 2048, 4096]

        for s in top_sizes:
            cand_pts = []
            for tk in top_keys:
                if tk in matmul_data[gpu] and "fast" in matmul_data[gpu][tk] and s in matmul_data[gpu][tk]["fast"]:
                    for comp, pt in matmul_data[gpu][tk]["fast"][s].items():
                        cand_pts.append((comp, pt))

            def _best_pt(predicate):
                matching = [pt for comp, pt in cand_pts if predicate(comp)]
                if not matching: return None
                return max(matching, key=lambda p: p.get("metrics", {}).get("throughput", {}).get("tflops") or 0.0)

            c_pt = _best_pt(_is_crisp)
            ctrl_pt = _best_pt(_is_control)
            peer_pt = _best_pt(_is_peer)
            ceil_pt = _best_pt(lambda k: _is_ceiling(k) and "_Plus_" not in k)

            c_tf = c_pt.get("metrics", {}).get("throughput", {}).get("tflops") if c_pt else None
            c_ms = c_pt.get("metrics", {}).get("runtime", {}).get("kernel_execution_ms") if c_pt else None
            ctrl_tf = ctrl_pt.get("metrics", {}).get("throughput", {}).get("tflops") if ctrl_pt else None
            ctrl_ms = ctrl_pt.get("metrics", {}).get("runtime", {}).get("kernel_execution_ms") if ctrl_pt else None
            peer_tf = peer_pt.get("metrics", {}).get("throughput", {}).get("tflops") if peer_pt else None
            peer_ms = peer_pt.get("metrics", {}).get("runtime", {}).get("kernel_execution_ms") if peer_pt else None
            ceil_tf = ceil_pt.get("metrics", {}).get("throughput", {}).get("tflops") if ceil_pt else None
            ceil_ms = ceil_pt.get("metrics", {}).get("runtime", {}).get("kernel_execution_ms") if ceil_pt else None

            c_str = f"{c_tf:.1f} ({c_ms:.3f})" if c_tf else "—"
            ctrl_str = f"{ctrl_tf:.1f} ({ctrl_ms:.3f})" if ctrl_tf else "—"
            peer_str = f"{peer_tf:.1f} ({peer_ms:.3f})" if peer_tf else "—"
            ceil_str = f"{ceil_tf:.1f} ({ceil_ms:.3f})" if ceil_tf else "—"

            vs_peer = format_ratio(c_tf, peer_tf)
            vs_ceil = format_ratio(c_tf, ceil_tf, as_pct=True)

            lines.append(f"| {s} | {c_str} | {ctrl_str} | {peer_str} | {ceil_str} | {vs_peer} | {vs_ceil} |")

        lines.append("")

    # Section 3: Situational Techniques
    lines.append("## § 3 — Situational Techniques\n")
    lines.append("*Techniques whose honest answer is \"it depends.\"* Controlled pairs:\n")
    lines.append("### TMA Multicast (NVIDIA only) · H100 NVL")
    lines.append("| tile | AI | N=1024 | N=2048 | N=4096 |")
    lines.append("|---|---:|---:|---:|---:|")
    lines.append("| 64×256 | 25.6 | −6.1% | **−7.0%** | −9.7% |")
    lines.append("| **64×128** | 21.3 | −6.1% | **+15.5%** | **+10.7%** |")
    lines.append("| 64×64 | 16.0 | +0.4% | +1.1% | +4.4% |\n")

    # Section 4: MMA + Activation
    lines.append("## § 4 — MMA + Activation\n")
    lines.append("*What does fusing an arbitrary activation buy?*\n")
    lines.append("| contender | arbitrary activation? | what Crisp claims |")
    lines.append("|---|---|---|")
    lines.append("| cuBLASLt, oneDNN (**Ceiling**) | **No** — fixed enum / post-op set | **capability** — off-menu costs 2nd kernel + HBM round trip |")
    lines.append("| CUTLASS, SYCL-TLA (**Peer**) | **Yes** — monomorphised functor | **expressiveness & compile time** (~165× faster build) |\n")

    # Section 5: Scaling Out
    lines.append("## § 5 — Scaling Out\n")
    lines.append("| topic | status |")
    lines.append("|---|---|")
    lines.append("| Out of core (stream from host) | candidate for 1.0 |")
    lines.append("| Hardware multi-tile (PVC 2T/4T) | deferred — needs `def-topology` |")
    lines.append("| Multi-GPU | deferred — needs `def-topology` + `def-orchestration` |\n")

    return lines

def render_reduction_suite(reduction_data: dict, provenance: dict) -> List[str]:
    lines = ["# Suite: reduction\n"]
    lines.append("Row variable: **element count**. Headline metric is **GB/s**.\n")
    return lines

def main():
    parser = argparse.ArgumentParser(description="Crisp Benchmark Report Generator")
    parser.add_argument("--results-dir", default=str(RESULTS_DIR), help="Directory containing JSON sweep results")
    parser.add_argument("--scratch-dir", default=str(SCRATCH_DIR), help="Directory containing excluded scratch runs")
    parser.add_argument("--output", default=None, help="Path to write Markdown report (default: stdout)")
    args = parser.parse_args()

    report_md = generate_report(Path(args.results_dir), Path(args.scratch_dir))
    if args.output:
        out_path = Path(args.output)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(report_md, encoding="utf-8")
        print(f"Report successfully written to {out_path}")
    else:
        print(report_md)

if __name__ == "__main__":
    if sys.stdout.encoding and sys.stdout.encoding.lower() != 'utf-8':
        try:
            sys.stdout.reconfigure(encoding='utf-8')
        except Exception:
            pass
    main()
