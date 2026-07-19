#!/usr/bin/env python3
"""
Benchmark Report Generator

Aggregates all JSON sweeps in `benchmarks/results/` and generates a Markdown table
comparing the different algorithms across configurations. Groups by hardware and applies
vendor optimal results as a universal ceiling.

Usage:
  # Output to terminal
  python scripts/crisp_bench/report.py

  # Save to a file
  python scripts/crisp_bench/report.py --output benchmarks/results/REPORT.md
"""
import json
import argparse
import sys
from pathlib import Path
from collections import defaultdict

def generate_markdown(results_dir: Path, out_file: Path = None):
    # Group results by [GPU] -> [Chapter] -> [Size] -> [Competitor] -> Metrics
    # Metrics: (tflops, kernel_ms, dev_compile_ms, all_compile_ms)
    hardware_groups = defaultdict(lambda: defaultdict(lambda: defaultdict(dict)))
    
    # Store vendor ceiling data separately to append to all chapters
    # [GPU] -> [Size] -> [Competitor] -> Metrics
    vendor_ceilings = defaultdict(lambda: defaultdict(dict))

    for f in results_dir.glob("results_*.json"):
        with open(f, "r") as fh:
            data = json.load(fh)
            gpu = data["run_metadata"]["hardware"]["gpu_model"]
            chapter = data["chapter"]
            competitor = data["competitor"]
            
            for point in data["results"]:
                sz = f"{point['configuration']['m']}x{point['configuration']['n']}x{point['configuration']['k']}"
                tflops = point["metrics"]["throughput"]["tflops"]
                k_ms = point["metrics"]["runtime"]["kernel_execution_ms"]
                dev_c_ms = point["metrics"]["compile_time"]["device_compile_ms"]
                all_c_ms = point["metrics"]["compile_time"]["all_compile_ms"]
                metrics = (tflops, k_ms, dev_c_ms, all_c_ms)
                
                if chapter == "vendor_ceiling":
                    vendor_ceilings[gpu][sz][competitor] = metrics
                else:
                    hardware_groups[gpu][chapter][sz][competitor] = metrics

    lines = ["# Crisp Benchmark Report\n"]
    
    for gpu in sorted(hardware_groups.keys()):
        lines.append(f"## Hardware: {gpu}\n")
        
        for chapter in sorted(hardware_groups[gpu].keys()):
            lines.append(f"### {chapter}")
            
            competitors = set()
            for sz, comps in hardware_groups[gpu][chapter].items():
                competitors.update(comps.keys())
            
            comp_order = ["Crisp", "CUDA_Apples", "SYCL_Apples"]
            comp_order += [c for c in sorted(competitors) if c not in comp_order]
            comp_list = [c for c in comp_order if c in competitors]
            
            # Add vendor ceilings to this chapter's columns
            ceilings_present = set()
            for sz, comps in vendor_ceilings[gpu].items():
                ceilings_present.update(comps.keys())
            ceiling_list = sorted(list(ceilings_present))

            # Header
            header_cols = ["Size"]
            sep_cols = ["---"]
            
            for c in comp_list:
                header_cols.extend([f"{c} (TFLOPS)", f"{c} (Exec ms)", f"{c} (Compile ms)"])
                sep_cols.extend(["---:", "---:", "---:"])
                
            for c in ceiling_list:
                header_cols.extend([f"Optimal: {c} (TFLOPS)", f"Optimal: {c} (Exec ms)"])
                sep_cols.extend(["---:", "---:"])
                
            lines.append("| " + " | ".join(header_cols) + " |")
            lines.append("|" + "|".join(sep_cols) + "|")
            
            def size_key(sz_str):
                return int(sz_str.split("x")[0])
                
            all_sizes = set(hardware_groups[gpu][chapter].keys()).union(vendor_ceilings[gpu].keys())
            
            for sz in sorted(all_sizes, key=size_key):
                # Skip sizes that don't exist in this chapter
                if sz not in hardware_groups[gpu][chapter] and not ceiling_list:
                    continue
                    
                row_cols = [sz]
                
                for c in comp_list:
                    if sz in hardware_groups[gpu][chapter] and c in hardware_groups[gpu][chapter][sz]:
                        tflops, k_ms, dev_c, all_c = hardware_groups[gpu][chapter][sz][c]
                        row_cols.extend([f"{tflops:.2f}", f"{k_ms:.2f}", f"{all_c:.1f}"])
                    else:
                        row_cols.extend(["-", "-", "-"])
                        
                for c in ceiling_list:
                    if sz in vendor_ceilings[gpu] and c in vendor_ceilings[gpu][sz]:
                        tflops, k_ms, dev_c, all_c = vendor_ceilings[gpu][sz][c]
                        row_cols.extend([f"{tflops:.2f}", f"{k_ms:.2f}"])
                    else:
                        row_cols.extend(["-", "-"])
                        
                lines.append("| " + " | ".join(row_cols) + " |")
            
            lines.append("\n")

    report_text = "\n".join(lines)
    
    if out_file:
        out_file.write_text(report_text)
        print(f"Report saved to {out_file}")
    else:
        print(report_text)

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--results-dir", default=str(Path(__file__).resolve().parent.parent.parent / "benchmarks" / "results"))
    ap.add_argument("--output", default=None, help="File to save the markdown report to (default: stdout)")
    a = ap.parse_args()
    generate_markdown(Path(a.results_dir), Path(a.output) if a.output else None)
