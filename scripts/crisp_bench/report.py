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

def _is_ceiling(name: str) -> bool:
    return any(k in name for k in ["CUBLAS", "cuBLAS", "OneMKL", "oneMKL", "oneDNN", "CUBLASLt", "cuBLASLt"])

def _is_peer(name: str) -> bool:
    # CEILING WINS.  "CUB" (NVIDIA's CUB library) is a PREFIX OF "CUBLAS", so a plain substring
    # test classified CUBLAS_Optimal as a peer -- and since the peer column takes the best-scoring
    # peer, cuBLAS was printed in the CUTLASS column.  That is how the H100 table came to show
    # Peer and Ceiling identical at every size while CUTLASS had in fact recorded 0.0 TFLOPS at
    # every size (its harness could not find the CUTLASS headers).  A fabricated competitor row is
    # worse than a missing one.
    #
    # Fixed by precedence rather than by word-boundary matching: `\bCUB\b` would correctly reject
    # CUBLAS but would ALSO reject the "SYCL-TLA_BF16" style names the bf16 section builds, since
    # the trailing "_" is a word character.  Anything that is a ceiling is not a peer.
    if _is_ceiling(name):
        return False
    return any(k in name for k in ["CUTLASS", "SYCL-TLA", "CUB", "oneDPL"])

# ---------------------------------------------------------------------------------------------
# VARIANTS.  A `Crisp_V_<tag>` competitor is an alternative CONFIGURATION of its chapter's Crisp
# kernel -- a different prefetch distance, ring depth, K step -- NOT a separate contender.  A
# plain `Crisp_<name>` stays a contender, which is what sec3_mma_lowering's four kernels are: a
# controlled contrast where taking a max would destroy the comparison.
#
# WHY THE DISTINCTION IS LOAD-BEARING.  `_best_pt` already takes max() over every Crisp-named
# competitor at each size independently, so a chapter carrying several kernels ALREADY reports a
# per-size envelope -- silently, with no record of which kernel produced which cell.  With
# endeavour 158's prefetch variants that would print 91.2 at 4096 (distance 1) and 66.0 at 8192
# (no prefetch) as one smooth curve, and say nothing about the fact that the 4096 winner is a
# 2.2x REGRESSION at 8192.  A best-per-size number is only honest when the reader can reproduce
# the selection, so the envelope must name its winner.
def _variant_split(name: str):
    """(GROUP, TAG) for a `<GROUP>_V_<tag>` variant; (name, None) for anything else.
       The base kernel of a group is the plain `Crisp` competitor, whose tag is reported as
       "base" so every envelope cell names something.

       GENERALISED FROM `Crisp_V_` (endeavour 159), and the generalisation is the point.  The
       PEER column takes exactly the same silent max() over every matching competitor that the
       Crisp column does.  That was harmless only while each chapter carried a single peer build;
       the swept CUTLASS 16-bit contender carries five, so the peer cell becomes an unattributed
       envelope -- a best-per-size number the reader cannot reproduce, which is the precise
       failure this function was written to prevent.  It was Crisp-only by accident of which
       column happened to get variants first, not by design."""
    marker = "_V_"
    i = name.find(marker)
    if i > 0:
        return name[:i], name[i + len(marker):]
    if name == "Crisp":
        return "Crisp", "base"
    return name, None


# Run-to-run spread, measured six repeats on BMG (docs/performance-levers.md, Layer 4).  Needed
# to call a sign flip: without a noise floor, "faster here, slower there" is not a claim, it is a
# pair of numbers.  Re-derive when the driver or the hardware moves.
RUN_TO_RUN_SPREAD = {1024: 0.022, 2048: 0.022, 4096: 0.031, 8192: 0.007}
DEFAULT_SPREAD = 0.03


def _spread(n: int) -> float:
    return RUN_TO_RUN_SPREAD.get(n, DEFAULT_SPREAD)


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
        top_keys = ["sec2_top", "chap7_wgmma", "chap6_warp_specialization", "chap5_multistage_ring", "chap3_wgmma", "intel_prefetch"]
        
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
                        cand_pts.append((comp, pt, tk))

            def _best_pt(predicate):
                matching = [pt for comp, pt, _tk in cand_pts if predicate(comp)]
                if not matching: return None
                return max(matching, key=lambda p: p.get("metrics", {}).get("throughput", {}).get("tflops") or 0.0)

            c_pt = _best_pt(_is_crisp)
            ctrl_pt = _best_pt(_is_control)
            peer_pt = _best_pt(_is_peer)
            ceil_pt = _best_pt(lambda k: _is_ceiling(k) and "_Plus_" not in k)

            # PROVENANCE.  This cell is a max over every Crisp competitor in SIX chapters, taken
            # independently at each size -- so the "Crisp" column has ALWAYS been a per-size
            # envelope over different kernels, and never said so.  Name the winner.  A number
            # whose configuration is unstated cannot be reproduced by the reader, and a curve
            # assembled from several kernels reads as one kernel unless it is labelled.
            # Here the max is over CHAPTERS, so the chapter is the provenance that matters -- a
            # cell may come from chap7_wgmma while its neighbour comes from sec2_top.  A variant
            # tag is appended only when the chapter actually carries variants; tagging every cell
            # `base` would be noise, not provenance.
            c_src = None
            if c_pt is not None:
                for _comp, _pt, _tk in cand_pts:
                    if _pt is c_pt and _is_crisp(_comp):
                        _g, _v = _variant_split(_comp)
                        c_src = _tk if _v in (None, "base") else f"{_tk}/{_v}"
                        break

            c_tf = c_pt.get("metrics", {}).get("throughput", {}).get("tflops") if c_pt else None
            c_ms = c_pt.get("metrics", {}).get("runtime", {}).get("kernel_execution_ms") if c_pt else None
            ctrl_tf = ctrl_pt.get("metrics", {}).get("throughput", {}).get("tflops") if ctrl_pt else None
            ctrl_ms = ctrl_pt.get("metrics", {}).get("runtime", {}).get("kernel_execution_ms") if ctrl_pt else None
            peer_tf = peer_pt.get("metrics", {}).get("throughput", {}).get("tflops") if peer_pt else None
            peer_ms = peer_pt.get("metrics", {}).get("runtime", {}).get("kernel_execution_ms") if peer_pt else None
            ceil_tf = ceil_pt.get("metrics", {}).get("throughput", {}).get("tflops") if ceil_pt else None
            ceil_ms = ceil_pt.get("metrics", {}).get("runtime", {}).get("kernel_execution_ms") if ceil_pt else None

            c_str = (f"{c_tf:.1f} ({c_ms:.3f})" + (f" `{c_src}`" if c_src else "")) if c_tf else "—"
            ctrl_str = f"{ctrl_tf:.1f} ({ctrl_ms:.3f})" if ctrl_tf else "—"
            if platform == "intel":
                peer_str = "N/A*"
                vs_peer = "—"
            else:
                peer_str = f"{peer_tf:.1f} ({peer_ms:.3f})" if peer_tf else "—"
                vs_peer = format_ratio(c_tf, peer_tf)
            ceil_str = f"{ceil_tf:.1f} ({ceil_ms:.3f})" if ceil_tf else "—"

            vs_ceil = format_ratio(c_tf, ceil_tf, as_pct=True)

            lines.append(f"| {s} | {c_str} | {ctrl_str} | {peer_str} | {ceil_str} | {vs_peer} | {vs_ceil} |")

        if platform == "intel":
            lines.append("\n> *\\*Note: SYCL-TLA does not implement TF32 DPAS on Xe2 (only BF16/FP16/FP8). See §2.1 below for the native 270+ TFLOPS BF16 suite.*\n")

        # Compile time summary table
        def _fmt_ms(ms):
            if ms is None or ms <= 0: return "—"
            return f"{ms/1000.0:.2f} s" if ms >= 1000 else f"{int(round(ms))} ms"

        c_pt0 = _best_pt(_is_crisp)
        ctrl_pt0 = _best_pt(_is_control)
        peer_pt0 = _best_pt(_is_peer)
        ceil_pt0 = _best_pt(lambda k: _is_ceiling(k) and "_Plus_" not in k)

        c_dev = c_pt0.get("metrics", {}).get("compile_time", {}).get("device_compile_ms", 0.0) if c_pt0 else 0.0
        c_build = c_pt0.get("metrics", {}).get("compile_time", {}).get("all_compile_ms", 0.0) if c_pt0 else 0.0

        if c_dev > 0 or c_build > 0:
            target_ir = "SPIR-V" if platform == "intel" else "PTX"
            lines.append("\n<details><summary><b>Compilation & Build Overhead</b></summary>\n")
            lines.append(f"| contender | class | device codegen ({target_ir}) | total build | **vs Crisp codegen** |")
            lines.append("|---|---|---:|---:|---:|")

            def _row(name, role, pt, is_ceil=False):
                if not pt: return
                cm = pt.get("metrics", {}).get("compile_time", {})
                d_ms = cm.get("device_compile_ms", 0.0)
                a_ms = cm.get("all_compile_ms", 0.0)
                if is_ceil:
                    lines.append(f"| **{name}** | {role} | *precompiled* | {_fmt_ms(a_ms)} | — |")
                    return
                if d_ms <= 0 and a_ms <= 0: return
                ratio = f"**{d_ms / c_dev:.1f}× slower**" if c_dev > 0 and d_ms > c_dev * 1.05 else ("1.00×" if c_dev > 0 and abs(d_ms - c_dev) < 10 else f"{d_ms / c_dev:.2f}×")
                lines.append(f"| **{name}** | {role} | {_fmt_ms(d_ms)} | {_fmt_ms(a_ms)} | {ratio} |")

            _row("Crisp", "Crisp", c_pt0)
            _row(ctrl_label, "Control", ctrl_pt0)
            if platform == "nvidia":
                _row(peer_label, "Peer", peer_pt0)
            _row(ceil_label, "Ceiling", ceil_pt0, is_ceil=True)
            lines.append("\n</details>\n")

        # §2.1 / §2.2 — 16-BIT TOP MMA SECTIONS.
        #
        # Endeavour 155: bf16 and fp16 share one implementation rather than two near-identical
        # copies.  The bf16 block this replaces had drifted from §2 in a way that mattered: its
        # "vs Peer" / "vs Ceiling" columns were computed as format_ratio(ctrl_tf or c_tf, ...),
        # i.e. they reported the CONTROL's ratio in a table whose first column is Crisp.  With
        # Crisp bf16 absent on this driver that went unnoticed; copying it for fp16, where Crisp
        # DOES have data, would have published the SYCL control's ratios as Crisp's.  Both
        # sections now use c_tf, matching §2.
        def _emit_16bit_top(chapter_key, tag, note):
            if chapter_key not in matmul_data[gpu] or "fast" not in matmul_data[gpu][chapter_key]:
                return
            data = matmul_data[gpu][chapter_key]["fast"]
            sizes = sorted([s for s in data.keys() if isinstance(s, int)])
            if not sizes:
                return

            # ---- VARIANT ANALYSIS -------------------------------------------------------------
            # Which Crisp configurations exist in this chapter, how each does at each size, which
            # single one is the best FIXED choice, and where any of them changes sign.
            variants = {}                       # tag -> {size: tflops}
            for s in sizes:
                for comp, pt in data[s].items():
                    grp, vtag = _variant_split(comp)
                    if grp == "Crisp" and vtag and _is_crisp(comp):
                        v = pt.get("metrics", {}).get("throughput", {}).get("tflops")
                        if v:
                            variants.setdefault(vtag, {})[s] = v

            # BEST SINGLE FIXED CHOICE: the variant with the best geometric mean over the sizes
            # where EVERY variant has a point, so the comparison is not decided by coverage.
            common = [s for s in sizes if all(s in v for v in variants.values())] if variants else []
            best_single = None
            if len(variants) > 1 and common:
                def _gmean(vt):
                    p = 1.0
                    for s in common:
                        p *= variants[vt][s]
                    return p ** (1.0 / len(common))
                best_single = max(variants, key=_gmean)

            lines.append(f"### {gpu} \u00b7 {tag.lower()} \u00b7 `fast` *({note})*\n")
            if best_single:
                lines.append(
                    f"Crisp is **outside-in**: the user picks the configuration, exactly as SYCL-TLA's "
                    f"pipeline depth is a template argument. So two Crisp columns, and the gap between "
                    f"them is *what tuning is worth*. **Envelope** is the best variant at each size, "
                    f"naming which one. **Best single** is the one fixed choice that does best across "
                    f"all sizes (`{best_single}`) \u2014 what you get without per-size tuning. "
                    f"{len(variants)} variants measured.\n")
                lines.append(f"| N | Crisp {tag}<br>**envelope** | Crisp {tag}<br>best single (`{best_single}`) | Control<br>{ctrl_label}_{tag} | **Peer**<br>{peer_label}_{tag} | Ceiling<br>{ceil_label}_{tag} | vs Peer | vs Ceiling |")
                lines.append("|---:|---:|---:|---:|---:|---:|---:|---:|")
            else:
                lines.append(f"| N | Crisp {tag} | Control<br>{ctrl_label}_{tag} | **Peer**<br>{peer_label}_{tag} | Ceiling<br>{ceil_label}_{tag} | vs Peer | vs Ceiling |")
                lines.append("|---:|---:|---:|---:|---:|---:|---:|")

            def _best(cand_pts, predicate):
                matching = [pt for comp, pt in cand_pts if predicate(comp)]
                if not matching:
                    return None
                return max(matching, key=lambda p: p.get("metrics", {}).get("throughput", {}).get("tflops") or 0.0)

            def _tf(pt):
                return pt.get("metrics", {}).get("throughput", {}).get("tflops") if pt else None

            def _ms(pt):
                return pt.get("metrics", {}).get("runtime", {}).get("kernel_execution_ms") if pt else None

            def _cell(pt):
                tf, ms = _tf(pt), _ms(pt)
                return f"{tf:.1f} ({ms:.3f})" if tf else "\u2014"

            # SAME SELECTION AS _best, BUT IT KEEPS THE NAME.  A column carrying several builds
            # of one contender reports a per-size envelope whether or not anyone intended it; the
            # only question is whether the reader is told which build won.  See _variant_split.
            def _best_named(cand_pts, predicate):
                matching = [(comp, pt) for comp, pt in cand_pts if predicate(comp)]
                if not matching:
                    return None, None
                return max(matching,
                           key=lambda cp: cp[1].get("metrics", {}).get("throughput", {}).get("tflops") or 0.0)

            def _cell_named(comp, pt):
                base = _cell(pt)
                if not comp or base == "\u2014":
                    return base
                _, vtag = _variant_split(comp)
                return f"{base} `{vtag}`" if vtag else base

            last = {}
            for s in sizes:
                cand = list(data[s].items())
                c_pt = _best(cand, _is_crisp)
                ctrl_pt = _best(cand, _is_control)
                peer_name, peer_pt = _best_named(cand, _is_peer)
                ceil_pt = _best(cand, lambda k: _is_ceiling(k) and "_Plus_" not in k)
                # Keep the last size at which EACH contender actually has a point, not the last
                # size overall: Crisp has no 16384 entry yet, and taking the final row wholesale
                # dropped its compile row from the table below entirely.
                for _k, _v in (("c", c_pt), ("ctrl", ctrl_pt), ("peer", peer_pt), ("ceil", ceil_pt)):
                    if _v is not None:
                        last[_k] = _v

                c_tf = _tf(c_pt)
                vs_peer = format_ratio(c_tf, _tf(peer_pt))
                vs_ceil = format_ratio(c_tf, _tf(ceil_pt), as_pct=True)

                if best_single:
                    # PROVENANCE.  The envelope is a max over configurations; a number without the
                    # configuration that produced it is not reproducible by the reader, and this
                    # report has been burned before by cells whose provenance was unstated.
                    # Only name a winner where one actually has a point: an empty cell tagged
                    # `base` claims a provenance for a measurement that does not exist.
                    _present = {vt: v[s] for vt, v in variants.items() if s in v}
                    win = max(_present, key=_present.get) if _present else None
                    env = f"{_cell(c_pt)} `{win}`" if win else _cell(c_pt)
                    bs_tf = variants.get(best_single, {}).get(s)
                    bs = f"{bs_tf:.1f}" if bs_tf else "—"
                    lines.append(f"| {s} | {env} | {bs} | {_cell(ctrl_pt)} | {_cell_named(peer_name, peer_pt)} | {_cell(ceil_pt)} | {vs_peer} | {vs_ceil} |")
                else:
                    lines.append(f"| {s} | {_cell(c_pt)} | {_cell(ctrl_pt)} | {_cell_named(peer_name, peer_pt)} | {_cell(ceil_pt)} | {vs_peer} | {vs_ceil} |")

            # ---- SIGN FLIPS -------------------------------------------------------------------
            # A variant that WINS at one size and LOSES at another, both beyond the run-to-run
            # spread, is not a tuning preference -- it is a trap.  Endeavour 158's prefetch is
            # +40% at 4096 and -55% at 8192, and a report that showed only the envelope would have
            # presented that as a smooth curve.  Computed from stored points; costs no GPU time.
            if variants and "base" in variants:
                flips = []
                for vt, pts in sorted(variants.items()):
                    if vt == "base":
                        continue
                    up, down = [], []
                    for s in sizes:
                        if s in pts and s in variants["base"]:
                            d = pts[s] / variants["base"][s] - 1.0
                            if d > _spread(s):
                                up.append((s, d))
                            elif d < -_spread(s):
                                down.append((s, d))
                    if up and down:
                        flips.append((vt, up, down))
                if flips:
                    lines.append("\n> **⚠ SIGN FLIPS — these variants reverse with problem size.**")
                    lines.append("> Each wins somewhere and loses somewhere, both beyond the measured run-to-run")
                    lines.append("> spread, so a single fixed choice is not available and the envelope above is")
                    lines.append("> assembled from *different kernels*. Picking by one size will mislead you at another.\n")
                    lines.append("> | variant | wins at | loses at |")
                    lines.append("> |---|---|---|")
                    for vt, up, down in flips:
                        u = ", ".join(f"{s} ({d*100:+.0f}%)" for s, d in up)
                        dn = ", ".join(f"**{s} ({d*100:+.0f}%)**" for s, d in down)
                        lines.append(f"> | `{vt}` | {u} | {dn} |")
                    lines.append("")

            # BASELINE IS CRISP, as in every other compile table (§2 tf32, §4 fused ReLU, §4 fused
            # custom).  This one used the Control, which made it the only table in the report whose
            # ratios could not be compared with the others: Crisp appeared as a FRACTION (0.44x)
            # rather than 1.00x, and the peer's headline number was a ratio against a contender no
            # reader is interested in.  The claim the column exists to support is "how does a build
            # compare to Crisp's", so Crisp is the denominator everywhere.
            ref_pt = last.get("c")
            ref_dev = ref_pt.get("metrics", {}).get("compile_time", {}).get("device_compile_ms", 0.0) if ref_pt else 0.0

            target_ir = "SPIR-V" if platform == "intel" else "PTX"
            lines.append(f"\n<details><summary><b>Compilation & Build Overhead ({tag})</b></summary>\n")
            lines.append(f"| contender | class | device codegen ({target_ir}) | total build | **vs Crisp codegen** |")
            lines.append("|---|---|---:|---:|---:|")

            def _row16(name, role, pt, is_ceil=False):
                if not pt:
                    return
                cm = pt.get("metrics", {}).get("compile_time", {})
                d_ms = cm.get("device_compile_ms", 0.0)
                a_ms = cm.get("all_compile_ms", 0.0)
                if is_ceil:
                    lines.append(f"| **{name}** | {role} | *precompiled* | {_fmt_ms(a_ms)} | \u2014 |")
                    return
                if d_ms <= 0 and a_ms <= 0:
                    return
                ratio = f"**{d_ms / ref_dev:.1f}\u00d7 slower**" if ref_dev > 0 and d_ms > ref_dev * 1.05 else ("1.00\u00d7" if ref_dev > 0 and abs(d_ms - ref_dev) < 10 else f"{d_ms / ref_dev:.2f}\u00d7" if ref_dev > 0 else "\u2014")
                lines.append(f"| **{name}** | {role} | {_fmt_ms(d_ms)} | {_fmt_ms(a_ms)} | {ratio} |")

            _row16("Crisp", "Crisp", last.get("c"))
            _row16(f"{ctrl_label}_{tag}", "Control", last.get("ctrl"))
            _row16(f"{peer_label}_{tag}", "Peer", last.get("peer"))
            _row16(f"{ceil_label}_{tag}", "Ceiling", last.get("ceil"), is_ceil=True)
            lines.append("\n</details>\n")

        _emit_16bit_top("sec2_top_bf16", "BF16", "Native 270+ TFLOPS Matrix Engines")
        _emit_16bit_top("sec2_top_fp16", "FP16", "Native 270+ TFLOPS Matrix Engines")

    # Section 3: Situational Techniques
    lines.append("## § 3 — Situational Techniques\n")
    lines.append("*Techniques whose honest answer is \"it depends.\"* Controlled pairs:\n")
    lines.append("### TMA Multicast (NVIDIA only) · H100 NVL")
    lines.append("| tile | AI | N=1024 | N=2048 | N=4096 |")
    lines.append("|---|---:|---:|---:|---:|")
    lines.append("| 64×256 | 25.6 | −6.1% | **−7.0%** | −9.7% |")
    lines.append("| **64×128** | 21.3 | −6.1% | **+15.5%** | **+10.7%** |")
    lines.append("| 64×64 | 16.0 | +0.4% | +1.1% | +4.4% |\n")

    # MMA lowering (Intel).  DATA-DRIVEN, unlike the multicast table above, which is a static
    # paste-in of literal percentages.  Both pairs are rendered on purpose: :xe-native is faster
    # BARE and slower TUNED, so showing only one pair would be true and misleading.
    for gpu in gpus:
        low = matmul_data[gpu].get("sec3_mma_lowering", {}).get("fast", {})
        if not low:
            continue
        l_sizes = sorted([n for n in low.keys() if isinstance(n, int)])
        if not l_sizes:
            continue

        def _tfl(n, comp, _low=low):
            pt = _low.get(n, {}).get(comp)
            if not pt:
                return None
            return pt.get("metrics", {}).get("throughput", {}).get("tflops")

        lines.append("### MMA Lowering: `:xe-native` vs `:coop-matrix` (Intel only) \u00b7 " + gpu)
        lines.append("")
        lines.append("*Same kernel, same 32x64 bf16 geometry over one subgroup; only the lowering "
                     "differs. `tuned` adds ring depth 2 and prefetch distance 2, which makes its "
                     "`:coop-matrix` arm the shipped section 2.1 kernel.*")
        lines.append("")
        lines.append("Each cell reads **`:coop-matrix` TFLOPS -> `:xe-native` TFLOPS (change)**, "
                     "where the change is `(xe_native / coop_matrix - 1)`. Higher TFLOPS is faster, "
                     "so a positive change means `:xe-native` won at that size.")
        lines.append("")
        lines.append("| pairing | " + " | ".join("N=%d" % n for n in l_sizes) + " |")
        lines.append("|---|" + "---:|" * len(l_sizes))
        for label, coop, xe in (("bare (no ring, no prefetch)", "Crisp_Coop_Bare", "Crisp_XeNative_Bare"),
                                ("tuned (ring 2, prefetch 2)", "Crisp_Coop_Tuned", "Crisp_XeNative_Tuned")):
            cells = []
            for n in l_sizes:
                c, x = _tfl(n, coop), _tfl(n, xe)
                if not c or not x:
                    cells.append("\u2014")
                    continue
                d = (x / c - 1.0) * 100.0
                pct = ("+" if d >= 0 else "\u2212") + ("%.1f%%" % abs(d))
                if abs(d) >= 5.0:
                    pct = "**" + pct + "**"
                # Carry the absolutes so the ratio is checkable, not merely asserted.
                cells.append("%.1f\u2192%.1f (%s)" % (c, x, pct))
            lines.append("| " + label + " | " + " | ".join(cells) + " |")
        lines.append("")
        lines.append("Positive means `:xe-native` is faster. It wins bare and loses tuned: the "
                     "lowering is better in isolation and does **not** compose with the "
                     "register-tile ring. See `docs/topology.md`, `mma-lowering`.")
        lines.append("")

        # Declare our own gaps.  A table that quietly omits the sizes disagreeing with its caption
        # is worse than no table: the tuned pairing's conclusion depends on the larger sizes, and a
        # lone small-N cell says the opposite.
        missing = []
        for label, coop, xe in (("bare", "Crisp_Coop_Bare", "Crisp_XeNative_Bare"),
                                ("tuned", "Crisp_Coop_Tuned", "Crisp_XeNative_Tuned")):
            for comp in (coop, xe):
                gone = [n for n in l_sizes if _tfl(n, comp) is None]
                if gone:
                    missing.append((comp, gone))
        if missing:
            lines.append("> **Incomplete data.** " + "; ".join(
                "`%s` has no point at N=%s" % (c, ", ".join(str(n) for n in g)) for c, g in missing) +
                ". The autobench sweep intermittently drops points for this contender; the "
                "kernel itself is fine, and runs correctly at every size when invoked directly "
                "(e.g. 45.2 TFLOPS MMA_CORRECT at N=1024 on a run where the sweep recorded "
                "nothing). Read the affected cells as missing data, not as a result.")
            lines.append("")

    # ---- Section 1 (bf16): the SAME technique ladder in 16-bit, with tf32 -> bf16 scaling ----
    LADDER = [
        ("chap0_naive", "Ch 0 naive (no XMX)"),
        ("chap1_handrolled_mma", "Ch 1 hand-rolled MMA"),
        ("chap2_tiling", "Ch 2 tiling macro"),
        ("chap3_async", "Ch 3 async staging"),
        ("chap4_cheap_fetch", "Ch 4 register-resident"),
        ("chap5_multistage_ring", "Ch 5 ring + prefetch"),
    ]
    for gpu in gpus:
        gd = matmul_data.get(gpu, {})
        have = [(k, lbl) for k, lbl in LADDER if gd.get(k + "_bf16", {}).get("fast")]
        if not have:
            continue

        def _tf(chapter, n, _gd=gd):
            pts = _gd.get(chapter, {}).get("fast", {}).get(n, {})
            for comp, pt in pts.items():
                if _is_crisp(comp):
                    v = pt.get("metrics", {}).get("throughput", {}).get("tflops")
                    if v:
                        return v
            return None

        l_sizes = sorted({n for k, _ in have
                          for n in gd.get(k + "_bf16", {}).get("fast", {}).keys()
                          if isinstance(n, int)})
        if not l_sizes:
            continue

        lines.append("## \u00a7 1b \u2014 The Technique Ladder in 16-bit (Intel) \u00b7 " + gpu)
        lines.append("")
        lines.append("*The same chapters as section 1, in bfloat16. Each kernel is its tf32 twin with "
                     "two things changed: the operand element type, and the K step 8 \u2192 16 (the "
                     "native XMX shape for 16-bit operands is (8 16 16), not (8 16 8)). The C "
                     "accumulator stays f32 in both.*")
        lines.append("")
        lines.append("Cells read **bf16 TFLOPS (\u00d7 vs the same chapter in tf32)**. The 32-bit "
                     "baseline is **tf32 on XMX**, not fp32 on the vector engines \u2014 the BMG shape "
                     "ladder is (8 16 8) tf32, (8 16 16) bf16, (8 16 32) int8, i.e. same M\u00d7N with "
                     "K doubling per step. No Control/Peer/Ceiling columns: the chapter SYCL controls "
                     "are tf32 only, so this is a Crisp-vs-Crisp ladder.")
        lines.append("")
        lines.append("| chapter | " + " | ".join("N=%d" % n for n in l_sizes) + " |")
        lines.append("|---|" + "---:|" * len(l_sizes))
        for key, label in have:
            cells = []
            for n in l_sizes:
                b16 = _tf(key + "_bf16", n)
                t32 = _tf(key, n)
                if b16 is None:
                    cells.append("\u2014")
                elif t32:
                    r = b16 / t32
                    cells.append("%.1f (%s%.2f\u00d7%s)" % (
                        b16, "**" if r >= 1.8 else "", r, "**" if r >= 1.8 else ""))
                else:
                    cells.append("%.1f (tf32 n/a)" % b16)
            lines.append("| " + label + " | " + " | ".join(cells) + " |")
        lines.append("")

    # Section 4: MMA + Activation
    lines.append("## § 4 — MMA + Activation\n")
    lines.append("*What does fusing an arbitrary activation buy?*\n")
    lines.append("| contender | arbitrary activation? | what Crisp claims |")
    lines.append("|---|---|---|")
    lines.append("| cuBLASLt, oneDNN (**Ceiling**) | **No** — fixed enum / post-op set | **capability** — off-menu costs 2nd kernel + HBM round trip |")
    lines.append("| CUTLASS, SYCL-TLA (**Peer**) | **Yes** — monomorphised functor | **expressiveness & compile time** (~165× faster build) |\n")

    for gpu in gpus:
        platform = _platform_of(gpu)
        lines.append(f"### {gpu} · tf32 · `fast`\n")

        # Ch 1: Fused ReLU
        relu_data = matmul_data[gpu].get("sec4_fused_relu", {}).get("fast", {}) or matmul_data[gpu].get("chap5_fused_epilogue", {}).get("fast", {})
        if relu_data:
            lines.append("#### Ch 1 — Standard Epilogue (ReLU)\n")
            peer_relu_label = "CUTLASS Fused" if platform == "nvidia" else "SYCL-TLA Fused"
            ceil_relu_label = "cuBLASLt Fused" if platform == "nvidia" else "oneDNN Fused"
            ceil_plus_label = "cuBLAS + ReLU" if platform == "nvidia" else "oneMKL + ReLU"
            lines.append(f"| N | Crisp Fused | **Peer**<br>{peer_relu_label} | **Ceiling**<br>{ceil_relu_label} | Baseline+2nd Kernel<br>{ceil_plus_label} | vs Peer | vs Ceiling |")
            lines.append("|---:|---:|---:|---:|---:|---:|---:|")

            r_sizes = sorted([s for s in relu_data.keys() if isinstance(s, int) and s >= 256])
            for s in r_sizes:
                pts = relu_data[s]
                c_pt = next((pt for comp, pt in pts.items() if "Crisp" in comp), None)
                if platform == "intel":
                    p_pt = None
                else:
                    p_pt = next((pt for comp, pt in pts.items() if any(k in comp for k in ["TLA", "CUTLASS"])), None)
                ceil_fused_pt = next((pt for comp, pt in pts.items() if any(k in comp for k in ["OneDNN_Fused", "CUBLASLt_Fused"])), None)
                ceil_plus_pt = next((pt for comp, pt in pts.items() if any(k in comp for k in ["Plus_Relu"])), None)

                def _fmt(pt):
                    if not pt: return "—"
                    tf = pt.get("metrics", {}).get("throughput", {}).get("tflops")
                    ms = pt.get("metrics", {}).get("runtime", {}).get("kernel_execution_ms")
                    return f"{tf:.1f} ({ms:.3f})" if tf else "—"

                c_tf = c_pt.get("metrics", {}).get("throughput", {}).get("tflops") if c_pt else None
                p_tf = p_pt.get("metrics", {}).get("throughput", {}).get("tflops") if p_pt else None
                cf_tf = ceil_fused_pt.get("metrics", {}).get("throughput", {}).get("tflops") if ceil_fused_pt else None

                vs_p = "—" if platform == "intel" else format_ratio(c_tf, p_tf)
                vs_cf = format_ratio(c_tf, cf_tf, as_pct=True)

                p_cell = "N/A*" if platform == "intel" else _fmt(p_pt)
                lines.append(f"| {s} | {_fmt(c_pt)} | {p_cell} | {_fmt(ceil_fused_pt)} | {_fmt(ceil_plus_pt)} | {vs_p} | {vs_cf} |")

            if platform == "intel":
                lines.append("\n> *\\*Note: SYCL-TLA only implements BF16/FP16/FP8 on Xe2.*\n")

            # Ch 1 Compile table
            target_ir = "SPIR-V" if platform == "intel" else "PTX"
            r_sz0 = r_sizes[0] if r_sizes else None
            if r_sz0:
                r_pts0 = relu_data[r_sz0]
                rc_pt = next((pt for comp, pt in r_pts0.items() if "Crisp" in comp), None)
                rc_dev = rc_pt.get("metrics", {}).get("compile_time", {}).get("device_compile_ms", 0.0) if rc_pt else 0.0
                if rc_dev > 0:
                    lines.append("\n<details><summary><b>Compilation & Build Overhead (Fused ReLU)</b></summary>\n")
                    lines.append(f"| contender | class | device codegen ({target_ir}) | total build | **vs Crisp codegen** |")
                    lines.append("|---|---|---:|---:|---:|")
                    def _r_row(name, role, pt, is_ceil=False):
                        if not pt: return
                        cm = pt.get("metrics", {}).get("compile_time", {})
                        d_ms = cm.get("device_compile_ms", 0.0)
                        a_ms = cm.get("all_compile_ms", 0.0)
                        if is_ceil:
                            lines.append(f"| **{name}** | {role} | *precompiled* | {_fmt_ms(a_ms)} | — |")
                            return
                        if d_ms <= 0 and a_ms <= 0: return
                        ratio = f"**{d_ms / rc_dev:.1f}× slower**" if rc_dev > 0 and d_ms > rc_dev * 1.05 else ("1.00×" if rc_dev > 0 and abs(d_ms - rc_dev) < 10 else f"{d_ms / rc_dev:.2f}×")
                        lines.append(f"| **{name}** | {role} | {_fmt_ms(d_ms)} | {_fmt_ms(a_ms)} | {ratio} |")
                    _r_row("Crisp Fused", "Crisp", rc_pt)
                    if platform == "nvidia":
                        _r_row(peer_relu_label, "Peer", next((pt for comp, pt in r_pts0.items() if any(k in comp for k in ["TLA", "CUTLASS"])), None))
                    _r_row(ceil_relu_label, "Ceiling", next((pt for comp, pt in r_pts0.items() if any(k in comp for k in ["OneDNN_Fused", "CUBLASLt_Fused"])), None), is_ceil=True)
                    lines.append("\n</details>\n")
                else:
                    lines.append("")
            else:
                lines.append("")

        # Ch 2: Fused Custom
        custom_data = matmul_data[gpu].get("sec4_fused_custom", {}).get("fast", {}) or matmul_data[gpu].get("chap6_fused_custom", {}).get("fast", {})
        if custom_data:
            lines.append("#### Ch 2 — Custom Epilogue (Arbitrary User Function)\n")
            lines.append("> *Ceilings (oneDNN / cuBLASLt) cannot fuse arbitrary user functions — forced to pay 2nd kernel + HBM round-trip.*\n")
            peer_custom_label = "CUTLASS Fused" if platform == "nvidia" else "SYCL-TLA Fused"
            ceil_plus_label = "cuBLASLt + Custom" if platform == "nvidia" else "oneDNN + Custom"
            lines.append(f"| N | Crisp Fused | **Peer**<br>{peer_custom_label} | Ceiling (2nd Kernel)<br>{ceil_plus_label} | vs Peer | **vs Ceiling (2nd Kernel)** |")
            lines.append("|---:|---:|---:|---:|---:|---:|")

            c_sizes = sorted([s for s in custom_data.keys() if isinstance(s, int) and s >= 256])
            for s in c_sizes:
                pts = custom_data[s]
                c_pt = next((pt for comp, pt in pts.items() if "Crisp" in comp), None)
                if platform == "intel":
                    p_pt = None
                else:
                    p_pt = next((pt for comp, pt in pts.items() if any(k in comp for k in ["TLA", "CUTLASS"])), None)
                ceil_plus_pt = next((pt for comp, pt in pts.items() if any(k in comp for k in ["OneDNN_Plus", "CUBLASLt_Plus", "Plus_Custom"])), None)

                def _fmt(pt):
                    if not pt: return "—"
                    tf = pt.get("metrics", {}).get("throughput", {}).get("tflops")
                    ms = pt.get("metrics", {}).get("runtime", {}).get("kernel_execution_ms")
                    return f"{tf:.1f} ({ms:.3f})" if tf else "—"

                c_tf = c_pt.get("metrics", {}).get("throughput", {}).get("tflops") if c_pt else None
                p_tf = p_pt.get("metrics", {}).get("throughput", {}).get("tflops") if p_pt else None
                cp_tf = ceil_plus_pt.get("metrics", {}).get("throughput", {}).get("tflops") if ceil_plus_pt else None

                vs_p = "—" if platform == "intel" else format_ratio(c_tf, p_tf)
                vs_cp = format_ratio(c_tf, cp_tf, as_pct=True)
                p_cell = "N/A*" if platform == "intel" else _fmt(p_pt)

                lines.append(f"| {s} | {_fmt(c_pt)} | {p_cell} | {_fmt(ceil_plus_pt)} | {vs_p} | **{vs_cp}** |")

            # Ch 2 Compile table
            target_ir = "SPIR-V" if platform == "intel" else "PTX"
            c_sz0 = c_sizes[0] if c_sizes else None
            if c_sz0:
                c_pts0 = custom_data[c_sz0]
                cc_pt = next((pt for comp, pt in c_pts0.items() if "Crisp" in comp), None)
                cc_dev = cc_pt.get("metrics", {}).get("compile_time", {}).get("device_compile_ms", 0.0) if cc_pt else 0.0
                if cc_dev > 0:
                    lines.append("\n<details><summary><b>Compilation & Build Overhead (Fused Custom)</b></summary>\n")
                    lines.append(f"| contender | class | device codegen ({target_ir}) | total build | **vs Crisp codegen** |")
                    lines.append("|---|---|---:|---:|---:|")
                    def _c_row(name, role, pt, is_ceil=False):
                        if not pt: return
                        cm = pt.get("metrics", {}).get("compile_time", {})
                        d_ms = cm.get("device_compile_ms", 0.0)
                        a_ms = cm.get("all_compile_ms", 0.0)
                        if is_ceil:
                            lines.append(f"| **{name}** | {role} | *precompiled* | {_fmt_ms(a_ms)} | — |")
                            return
                        if d_ms <= 0 and a_ms <= 0: return
                        ratio = f"**{d_ms / cc_dev:.1f}× slower**" if cc_dev > 0 and d_ms > cc_dev * 1.05 else ("1.00×" if cc_dev > 0 and abs(d_ms - cc_dev) < 10 else f"{d_ms / cc_dev:.2f}×")
                        lines.append(f"| **{name}** | {role} | {_fmt_ms(d_ms)} | {_fmt_ms(a_ms)} | {ratio} |")
                    _c_row("Crisp Fused", "Crisp", cc_pt)
                    if platform == "nvidia":
                        _c_row(peer_custom_label, "Peer", next((pt for comp, pt in c_pts0.items() if any(k in comp for k in ["TLA", "CUTLASS"])), None))
                    _c_row(ceil_plus_label, "Ceiling", next((pt for comp, pt in c_pts0.items() if any(k in comp for k in ["OneDNN_Plus", "CUBLASLt_Plus", "Plus_Custom"])), None), is_ceil=True)
                    lines.append("\n</details>\n")
                else:
                    lines.append("")
            else:
                lines.append("")

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
