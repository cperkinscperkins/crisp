#!/usr/bin/env python3
"""
Benchmark Report Generator

Aggregates all JSON sweeps in `benchmarks/results/` and generates a Markdown report
comparing the implementations across configurations. Groups by hardware and applies
vendor optimal results (cuBLAS / OneMKL) as a universal ceiling.

Usage:
  # Output to terminal
  python scripts/crisp_bench/report.py

  # Save to a file
  python scripts/crisp_bench/report.py --output benchmarks/REPORT.md
"""
import json
import re
import argparse
import sys
from pathlib import Path
from collections import defaultdict

# Logical chapter order + human labels (the optimization ladder).  Anything not
# listed sorts after these, alphabetically.
CHAPTER_ORDER = [
    "chap0_sync",
    "chap1_async_linear",
    "chap1.5_async_block",
    "chap2_pipelined_block",
    "chap3_wgmma",
    "intel_prefetch",
    "chap5_fused_epilogue",
    "chap6_fused_custom",
]

# Endeavor 150: chapters that fuse an ACTIVATION into the matmul epilogue.  Their ceiling is NOT
# the plain-GEMM library number — that is a different amount of work, and dividing by it flatters
# the fused kernel.  The honest denominator is the library run doing the SAME job (GEMM + its own
# activation pass), which is a chapter-local competitor rather than a global ceiling.
ACTIVATION_CHAPTERS = {"chap5_fused_epilogue", "chap6_fused_custom"}
CHAPTER_LABEL = {
    "chap0_sync":            "Synchronous tiling (fp32, no tensor cores)",
    "chap1_async_linear":    "Async linear pipelining (fp32)",
    "chap1.5_async_block":   "Block TMA load + tf32 MMA",
    "chap2_pipelined_block": "Pipelined block + tf32 MMA",
    "chap3_wgmma":           "Hopper warpgroup MMA (wgmma, tf32)",
    "chap4_cluster_multicast": "Cluster + TMA multicast / DSMEM (wgmma, tf32)",
    "intel_prefetch":        "Register-ring + Subgroup2DBlockPrefetch (XMX tf32)",
    "chap5_fused_epilogue":  "Fused ReLU epilogue (tf32)",
    "chap6_fused_custom":    "Fused CUSTOM activation (tf32)",
}
# Intel/BMG technique overrides (Endeavor 143): the shared chapter keys mean DIFFERENT things per
# platform — Intel chap0/chap1 use XMX coop-matrix tf32 tensor cores, not the fp32 non-tensor-core
# NVIDIA path — so the label must differ by hardware section.
INTEL_CHAPTER_LABEL = {
    "chap0_sync":         "Synchronous coop-matrix tiling (XMX tf32)",
    "chap1_async_linear": "OpGroupAsyncCopy staging (XMX tf32)",
    "intel_prefetch":     "Register-ring + Subgroup2DBlockPrefetch (XMX tf32)",
    "chap5_fused_epilogue": "Fused ReLU epilogue on the prefetch kernel (XMX tf32)",
    "chap6_fused_custom":   "Fused CUSTOM activation on the prefetch kernel (XMX tf32)",
}
# Chapters whose Crisp kernel uses tf32 tensor cores — so an IEEE (fp32) vendor ceiling is an
# apples-to-oranges comparison for those precision tables.  On Intel EVERY chapter is XMX tf32
# (see _is_mma_chapter); this NVIDIA set only lists NVIDIA's tensor-core chapters.
MMA_CHAPTERS = {"chap1.5_async_block", "chap2_pipelined_block", "chap3_wgmma",
                "chap5_fused_epilogue", "chap6_fused_custom"}
# Chapters where CUDA_Apples is a *naive* kernel, not a tensor-core mirror.
NAIVE_APPLES_CHAPTERS = {"chap1.5_async_block", "chap2_pipelined_block"}


def _is_crisp(name):
    return name == "Crisp" or name.startswith("Crisp_")

def _platform_of(gpu):
    """Derive the platform from the hardware section's gpu_model (report.py groups by GPU)."""
    return "intel" if "intel" in gpu.lower() else "nvidia"

def _vendor_label(platform):
    """Human name of the vendor-library ceiling for this platform."""
    return "oneMKL" if platform == "intel" else "cuBLAS"

def _vendor_competitor(platform):
    """The competitor key that carries the vendor ceiling in the JSON."""
    return "OneMKL_Optimal" if platform == "intel" else "CUBLAS_Optimal"

def _chapter_label(platform, chapter):
    if platform == "intel" and chapter in INTEL_CHAPTER_LABEL:
        return INTEL_CHAPTER_LABEL[chapter]
    return CHAPTER_LABEL.get(chapter, "")

def _is_mma_chapter(platform, chapter):
    """True if this chapter's Crisp kernel is tf32 tensor-core (so an IEEE-fp32 ceiling is
    apples-to-oranges).  Intel: always (XMX).  NVIDIA: only the listed tensor-core chapters."""
    return True if platform == "intel" else (chapter in MMA_CHAPTERS)


def chapter_sort_key(ch):
    return (CHAPTER_ORDER.index(ch) if ch in CHAPTER_ORDER else len(CHAPTER_ORDER), ch)


def generate_markdown(results_dir: Path, out_file: Path = None):
    # hardware_groups: [GPU][Chapter][Precision][Size][Competitor] -> (tflops, kernel_ms)
    hardware_groups = defaultdict(lambda: defaultdict(lambda: defaultdict(lambda: defaultdict(dict))))
    vendor_ceilings = defaultdict(lambda: defaultdict(lambda: defaultdict(dict)))
    # compile_times: [GPU][Chapter][Competitor] -> list of DEVICE compile ms (avg across precision).
    # Endeavor 144: this used to read all_compile_ms, which for the vendor toolchains was a full
    # source->linked-executable build (host C++ + linking -lcublas / -qmkl) while Crisp's was
    # source->IR.  device_compile_ms is the like-for-like quantity on both sides.
    compile_times = defaultdict(lambda: defaultdict(lambda: defaultdict(list)))

    # Endeavor 144: process files OLDEST-FIRST so that when two runs cover the same
    # (gpu, chapter, competitor, precision, size) the NEWEST wins deterministically.
    #
    # The assignments below overwrite rather than reduce, and `glob` returns filesystem order,
    # so previously the winner between duplicate runs was ARBITRARY — which is why regenerating
    # this report could change numbers with no code or data change.  The results filenames end
    # in a unix timestamp; sort on it, falling back to mtime for any file that lacks one.
    def _run_stamp(path):
        m = re.search(r"_(\d{9,})\.json$", path.name)
        return int(m.group(1)) if m else int(path.stat().st_mtime)

    for f in sorted(results_dir.glob("results_*.json"), key=_run_stamp):
        with open(f, "r") as fh:
            data = json.load(fh)
        gpu = data["run_metadata"]["hardware"]["gpu_model"]
        chapter = data["chapter"]
        competitor = data["competitor"]
        prec = data.get("precision", "unknown")
        ftz = data.get("denormal_handling", "unknown")
        prec_key = f"{prec} (ftz={ftz})"

        for point in data["results"]:
            sz = f"{point['configuration']['m']}x{point['configuration']['n']}x{point['configuration']['k']}"
            tflops = point["metrics"]["throughput"]["tflops"]
            k_ms = point["metrics"]["runtime"]["kernel_execution_ms"]
            dev_c_ms = point["metrics"]["compile_time"]["device_compile_ms"]
            metrics = (tflops, k_ms)

            compile_times[gpu][chapter][competitor].append(dev_c_ms)

            # Endeavor 150: a "+Relu" / "+Custom" library run is a CONTENDER, not a ceiling —
            # it belongs only to the chapter that measured it.  Treating it as a ceiling leaked
            # OneMKL_Plus_Relu into every chapter's table, including ones with no activation.
            _plain_ceiling = ((competitor.startswith("CUBLAS_") or competitor.startswith("OneMKL_"))
                              and "_Plus_" not in competitor)
            if chapter == "vendor_ceiling" or _plain_ceiling:
                vendor_ceilings[gpu][prec_key][sz][competitor] = metrics
            else:
                hardware_groups[gpu][chapter][prec_key][sz][competitor] = metrics

    lines = ["# Crisp Benchmark Report\n"]

    for gpu in sorted(hardware_groups.keys()):
        platform = _platform_of(gpu)
        lines.append(f"## Hardware: {gpu}\n")

        # ---- Summary (the optimization ladder) --------------------------------
        lines.extend(_summary_section(gpu, hardware_groups, vendor_ceilings))

        # ---- Per-chapter throughput tables ------------------------------------
        for chapter in sorted(hardware_groups[gpu].keys(), key=chapter_sort_key):
            label = _chapter_label(platform, chapter)
            lines.append(f"### {chapter}" + (f" — {label}" if label else ""))

            for prec_key in _precision_order(hardware_groups[gpu][chapter].keys()):
                lines.append(f"\n#### Precision: {prec_key}\n")
                lines.extend(_throughput_table(gpu, chapter, prec_key, hardware_groups, vendor_ceilings))
                lines.extend(_annotations(platform, chapter, prec_key))
            lines.append("")

        # ---- Compile times (collapsed across precision) -----------------------
        lines.extend(_compile_section(gpu, compile_times))

    report_text = "\n".join(lines)
    if out_file:
        out_file.write_text(report_text, encoding="utf-8")
        print(f"Report saved to {out_file}")
    else:
        print(report_text)


def _precision_order(prec_keys):
    """fast first, then ieee+ftz, then ieee+preserve — most-permissive to strictest."""
    def key(pk):
        fast = 0 if pk.startswith("fast") else 1
        ftz = 0 if "ftz=ftz" in pk else 1
        return (fast, ftz, pk)
    return sorted(prec_keys, key=key)


def _fast_key(gpu, chapter, hardware_groups):
    for pk in hardware_groups[gpu][chapter].keys():
        if pk.startswith("fast"):
            return pk
    return None


def _summary_section(gpu, hardware_groups, vendor_ceilings):
    """One row per chapter at the largest common size under the `fast` precision:
    Crisp throughput and its fraction of the vendor tf32 ceiling — the headline ladder."""
    platform = _platform_of(gpu)
    vendor = _vendor_label(platform)                 # cuBLAS (NVIDIA) / oneMKL (Intel)
    vcomp  = _vendor_competitor(platform)            # CUBLAS_Optimal / OneMKL_Optimal
    out = [f"### Summary — Crisp vs. {vendor} ceiling (fast / tf32)\n"]
    out.append(f"| Chapter | Technique | Size | Crisp (TFLOPS) | {vendor} (TFLOPS) | Crisp % of {vendor} |")
    out.append("|---|---|---:|---:|---:|---:|")
    any_row = False
    for chapter in sorted(hardware_groups[gpu].keys(), key=chapter_sort_key):
        fk = _fast_key(gpu, chapter, hardware_groups)
        if not fk:
            continue
        sizes = hardware_groups[gpu][chapter][fk].keys()
        if not sizes:
            continue
        # largest size present for this chapter under fast
        big = max(sizes, key=lambda s: int(s.split("x")[0]))
        # Endeavor 150: match any Crisp* kernel, not the literal name — the fused chapters
        # are Crisp_Fused_Relu / Crisp_Fused_Custom and were dropping out of the summary.
        _row = hardware_groups[gpu][chapter][fk][big]
        _cn = next((c for c in sorted(_row) if _is_crisp(c)), None)
        crisp = _row.get(_cn) if _cn else None
        if not crisp:
            continue
        crisp_t = crisp[0]
        # matching vendor ceiling at the same size/precision
        cub = None
        if fk in vendor_ceilings[gpu] and big in vendor_ceilings[gpu][fk]:
            c = vendor_ceilings[gpu][fk][big].get(vcomp)
            cub = c[0] if c else None
        pct = f"{crisp_t / cub * 100:.1f}%" if (cub and crisp_t) else "—"
        label = _chapter_label(platform, chapter)
        out.append(f"| {chapter} | {label} | {big.split('x')[0]} | {crisp_t:.1f} | "
                   f"{cub:.1f} | {pct}" if cub else
                   f"| {chapter} | {label} | {big.split('x')[0]} | {crisp_t:.1f} | — | —")
        out[-1] += " |"
        any_row = True
    out.append(f"\n> Largest measured size per chapter, `fast` precision (Crisp and {vendor} both tf32). "
               "The ladder runs low-to-high on the optimization axis for this hardware.\n")
    return out if any_row else []


# Endeavor 150: a chapter may carry MORE THAN ONE Crisp kernel (e.g. chap5's fused-relu and
# fused-custom), and hand-written competitors likewise (SYCL_Apples_Relu / _Custom).  The old
# code matched the literal name "Crisp", so every variant fell through to the generic branch:
# no "vs Optimal" / "vs Apples" columns and no compile-time ratio.  Match by PREFIX instead.
def _is_apples(name):
    return name.startswith("CUDA_Apples") or name.startswith("SYCL_Apples")

def _variant(name):
    """The trailing variant tag (Relu / Custom / ...) used to pair a Crisp kernel with the
    hand-written competitor running the SAME activation.  None when the name carries no tag."""
    tail = name.rsplit("_", 1)[-1]
    return tail if tail not in ("Crisp", "Apples", "Fused", "Optimal") and "_" in name else None


def _throughput_table(gpu, chapter, prec_key, hardware_groups, vendor_ceilings):
    lines = []
    competitors = set()
    for sz, comps in hardware_groups[gpu][chapter][prec_key].items():
        competitors.update(comps.keys())

    # `ceiling_list` is initialised HERE, before the branches below, because it used to be
    # assigned only inside two conditionals: a chapter that is NOT an activation chapter and
    # has no vendor ceiling recorded for this GPU+precision fell through both, and
    # `list(ceiling_list)` raised UnboundLocalError.  That is not an exotic case -- it is what
    # every result set looks like before anyone has run the vendor baseline on that machine.
    ceiling_list = []

    # Endeavor 150: an activation chapter's denominator is its own library contender (the one
    # that also applies the activation), so the global plain-GEMM ceiling is excluded entirely.
    if chapter in ACTIVATION_CHAPTERS:
        # The denominator is the BEST a library can do on this exact job — so oneDNN (which
        # fuses relu) counts alongside oneMKL (which cannot).  max() over these picks the
        # strongest, which is the only ceiling worth being measured against.
        lib_local = sorted(c for c in competitors
                           if c.startswith(("OneMKL_", "OneDNN_", "CUBLAS")))
        ceiling_list = []
        local_optimal = lib_local
    else:
        local_optimal = []
    if chapter not in ACTIVATION_CHAPTERS and prec_key in vendor_ceilings[gpu]:
        present = set()
        for sz, comps in vendor_ceilings[gpu][prec_key].items():
            present.update(comps.keys())
        ceiling_list = sorted(present)

    comp_order = list(ceiling_list)
    for b in ["CUDA_Apples", "SYCL_Apples", "Crisp"]:
        if b in competitors:
            comp_order.append(b)
    for c in sorted(competitors):
        if c not in comp_order and c not in ceiling_list:
            comp_order.append(c)

    header = ["Size"]
    sep = ["---"]
    for c in comp_order:
        header += [f"{c} (TFLOPS)", f"{c} (Kernel ms)"]
        sep += ["---:", "---:"]

    crisp_names = sorted(c for c in competitors if _is_crisp(c))
    apples_names = sorted(c for c in competitors if _is_apples(c))
    has_optimal = len(ceiling_list) > 0 or len(local_optimal) > 0
    # Pair each Crisp kernel with the hand-written competitor running the SAME activation, so
    # "vs Apples" compares like with like when a chapter carries several variants.
    pairing = {}
    for cn in crisp_names:
        v = _variant(cn)
        match = next((a for a in apples_names if _variant(a) == v), None) if v else None
        pairing[cn] = match or (apples_names[0] if apples_names else None)
    pct_cols = []
    for cn in crisp_names:
        short = cn if len(crisp_names) > 1 else "Crisp"
        if has_optimal:
            header.append(f"{short} vs Optimal (%)"); sep.append("---:")
            pct_cols.append((cn, "optimal", None))
        if pairing.get(cn):
            header.append(f"{short} vs Apples (%)"); sep.append("---:")
            pct_cols.append((cn, "apples", pairing[cn]))

    lines.append("| " + " | ".join(header) + " |")
    lines.append("|" + "|".join(sep) + "|")

    all_sizes = set(hardware_groups[gpu][chapter][prec_key].keys())
    if prec_key in vendor_ceilings[gpu]:
        all_sizes |= set(vendor_ceilings[gpu][prec_key].keys())

    for sz in sorted(all_sizes, key=lambda s: int(s.split("x")[0])):
        if sz not in hardware_groups[gpu][chapter][prec_key] and not ceiling_list:
            continue
        row = [sz]
        optimal_t = None
        seen = {}
        for c in comp_order:
            tflops = k_ms = None
            if c in ceiling_list:
                cd = vendor_ceilings[gpu].get(prec_key, {}).get(sz, {}).get(c)
                if cd:
                    tflops, k_ms = cd
                    optimal_t = tflops if optimal_t is None else max(optimal_t, tflops)
            else:
                hd = hardware_groups[gpu][chapter][prec_key].get(sz, {}).get(c)
                if hd:
                    tflops, k_ms = hd
                    seen[c] = tflops
                    if c in local_optimal:
                        optimal_t = tflops if optimal_t is None else max(optimal_t, tflops)
            row += ([f"{tflops:.2f}", f"{k_ms:.2f}"] if tflops is not None else ["-", "-"])

        for cn, kind, partner in pct_cols:
            num = seen.get(cn)
            den = optimal_t if kind == "optimal" else seen.get(partner)
            row.append(f"{num / den * 100:.1f}%" if (num and den) else "-")
        lines.append("| " + " | ".join(row) + " |")
    return lines


def _annotations(platform, chapter, prec_key):
    notes = []
    vendor = _vendor_label(platform)
    if _is_mma_chapter(platform, chapter) and not prec_key.startswith("fast"):
        notes.append("> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 "
                     "tensor cores by construction, so it does *not* honor the IEEE request (a Crisp "
                     f"kernel would emit a precision warning); meanwhile IEEE {vendor} drops to true fp32. "
                     "So the \">100% of Optimal\" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` "
                     "table is the only honest tensor-core comparison.")
    if chapter == "chap6_fused_custom":
        if platform == "intel":
            notes.append("> ⚠️ **No vendor library fuses this activation.** oneMKL BLAS has no epilogue "
                         "parameter at all, so it pays a separate kernel and a full HBM round trip of C "
                         "for *any* activation — relu included (see chap5). **oneDNN** does offer post-ops, "
                         "but from a fixed set of eltwise primitives, and a quadratic sub-threshold tail is "
                         "not one of them: it drops from 14.04 TF fused (chap5) to 13.54 here, while Crisp "
                         "moves 24.11 → 24.03. The claim is measured, not argued.")
        else:
            notes.append("> ⚠️ **cuBLASLt cannot fuse this activation.** Its epilogues are a fixed enum; "
                         "CUBLASLT_EPILOGUE_RELU covers chap5 but a quadratic sub-threshold tail is not in "
                         "the set, so cuBLASLt falls back to a second kernel and a full HBM round trip of C. "
                         "That costs it ~13-18% (418.45 → 361.83 TF at 4096; 307.31 → 251.34 at 2048), which "
                         "matches the H100's HBM3 bandwidth for a 2·N² round trip. Crisp pays ~0% because its "
                         "epilogue is a function the user wrote. **The gap to the best library therefore "
                         "narrows from 67.4% (chap5) to 78.1% (chap6) at 4096** — that shift, not the "
                         "absolute number, is what this chapter measures.")
    if chapter in NAIVE_APPLES_CHAPTERS:
        notes.append("> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a "
                     "tensor-core mirror of the Crisp algorithm — the \"Crisp vs Apples\" figures are not "
                     "apples-to-apples.")
    if notes:
        return ["\n".join(notes), ""]
    return []


def _compile_section(gpu, compile_times):
    """One row per (chapter, competitor), averaged across precision (compile time is
    ~precision-invariant), with each competitor's slowdown relative to Crisp."""
    platform = _platform_of(gpu)
    lines = ["### Compile Times (avg across precision)\n"]
    lines.append("| Chapter | Competitor | Avg Compile (ms) | × vs Crisp |")
    lines.append("|---|---|---:|---:|")
    for chapter in sorted(compile_times[gpu].keys(), key=chapter_sort_key):
        comps = compile_times[gpu][chapter]
        # Endeavor 150: the baseline is whichever Crisp kernel this chapter has, not the
        # literal name "Crisp" — otherwise a chapter whose kernels are Crisp_Fused_* gets no
        # ratio at all, which is what silently happened to chap5.
        _crisp_comps = sorted(c for c in comps if _is_crisp(c))
        _base = _crisp_comps[0] if _crisp_comps else None
        crisp_avg = (sum(comps[_base]) / len(comps[_base])) if _base else None
        # Crisp first, then the rest alphabetically
        # Endeavor 144: EXCLUDE the library ceilings (cuBLAS / oneMKL).  Their GEMM kernels ship
        # precompiled inside the vendor library, so a device-only compile of the caller measures
        # essentially nothing -- reporting it would flatter them as much as the old full-build
        # number unfairly penalised them.  The meaningful compile comparison is against the
        # hand-written kernel competitors, which contain real device code.
        ordered = _crisp_comps + sorted(
            c for c in comps
            if not _is_crisp(c) and not (c.startswith("CUBLAS_") or c.startswith("OneMKL_")))
        for comp in ordered:
            vals = [v for v in comps[comp] if v and v > 0.0]
            if not vals:
                continue          # device-only compile unavailable; omit rather than print 0
            avg = sum(vals) / len(vals)
            if comp == _base:
                ratio = "1.0× (baseline)"
            elif _is_crisp(comp):
                # A SIBLING Crisp kernel (e.g. chap5's fused-relu next to fused-custom) is a
                # peer, not a competitor — labelling it "slower" against an arbitrarily chosen
                # sibling is meaningless, and read as a regression when it is a different kernel.
                ratio = "— (Crisp variant)"
            elif crisp_avg:
                ratio = f"{avg / crisp_avg:.1f}× slower"
            else:
                ratio = "—"
            lines.append(f"| {chapter} | {comp} | {avg:.0f} | {ratio} |")
    if platform == "intel":
        footnote = ("\n> **Device-only compilation on both sides.**  Crisp `--ir-target=spv`; the "
                    "competitor `icpx -fsycl -fsycl-device-only -fsycl-targets=spir64`.  Neither "
                    "figure includes host-code compilation, linking, or the runtime JIT of the "
                    "resulting IR.  Library ceilings (oneMKL) are omitted — their kernels ship "
                    "precompiled inside the library, so there is no device compile to measure.  "
                    "Lower is better.\n")
    else:
        footnote = ("\n> **Device-only compilation on both sides.**  Crisp `--ir-target=ptx`; the "
                    "competitor `nvcc -ptx`.  Neither figure includes host-code compilation, "
                    "linking, or the driver's JIT of the resulting IR.  Library ceilings (cuBLAS) "
                    "are omitted — their kernels ship precompiled inside the library, so there is "
                    "no device compile to measure.  Lower is better.\n")
    lines.append(footnote)
    return lines


if __name__ == "__main__":
    # The report contains non-ASCII (⚠, ×, —).  On Windows, stdout defaults to cp1252, so
    # `report.py > REPORT.md` crashes with UnicodeEncodeError.  Force UTF-8 on stdout so the
    # print path doesn't die.  (NOTE: PowerShell `>` still re-encodes the captured text to
    # UTF-16 — prefer `--output REPORT.md`, which writes UTF-8 directly and bypasses the shell.)
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except (AttributeError, ValueError):
        pass
    ap = argparse.ArgumentParser()
    ap.add_argument("--results-dir", default=str(Path(__file__).resolve().parent.parent.parent / "benchmarks" / "results"))
    ap.add_argument("--output", default=None, help="File to save the markdown report to (UTF-8; recommended over `>`).")
    a = ap.parse_args()
    generate_markdown(Path(a.results_dir), Path(a.output) if a.output else None)
