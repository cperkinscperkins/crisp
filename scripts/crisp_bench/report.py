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
    # hardware_groups: [GPU] -> [Chapter] -> [Precision] -> [Size] -> [Competitor] -> Metrics
    # Metrics: (tflops, kernel_ms, wall_ms)
    hardware_groups = defaultdict(lambda: defaultdict(lambda: defaultdict(lambda: defaultdict(dict))))
    vendor_ceilings = defaultdict(lambda: defaultdict(lambda: defaultdict(dict)))

    # For compile time table: [GPU] -> [Chapter] -> [Precision] -> [Competitor] -> (list of dev_c_ms, list of all_c_ms)
    compile_times = defaultdict(lambda: defaultdict(lambda: defaultdict(lambda: defaultdict(lambda: {'dev': [], 'all': []}))))

    for f in results_dir.glob("results_*.json"):
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
                wall_ms = point["metrics"]["runtime"].get("wall_time_ms", 0.0)
                dev_c_ms = point["metrics"]["compile_time"]["device_compile_ms"]
                all_c_ms = point["metrics"]["compile_time"]["all_compile_ms"]
                
                metrics = (tflops, k_ms, wall_ms)
                
                compile_times[gpu][chapter][prec_key][competitor]['dev'].append(dev_c_ms)
                compile_times[gpu][chapter][prec_key][competitor]['all'].append(all_c_ms)
                
                if chapter == "vendor_ceiling":
                    vendor_ceilings[gpu][prec_key][sz][competitor] = metrics
                else:
                    hardware_groups[gpu][chapter][prec_key][sz][competitor] = metrics

    lines = ["# Crisp Benchmark Report\n"]
    
    for gpu in sorted(hardware_groups.keys()):
        lines.append(f"## Hardware: {gpu}\n")
        
        for chapter in sorted(hardware_groups[gpu].keys()):
            lines.append(f"### {chapter}")
            
            for prec_key in sorted(hardware_groups[gpu][chapter].keys()):
                lines.append(f"\n#### Precision: {prec_key}\n")
                
                competitors = set()
                for sz, comps in hardware_groups[gpu][chapter][prec_key].items():
                    competitors.update(comps.keys())
                
                # Ceiling competitors
                ceiling_list = []
                if prec_key in vendor_ceilings[gpu]:
                    ceilings_present = set()
                    for sz, comps in vendor_ceilings[gpu][prec_key].items():
                        ceilings_present.update(comps.keys())
                    ceiling_list = sorted(list(ceilings_present))
                
                # Determine columns to show in order: Optimal -> Apples -> Crisp
                comp_order = []
                comp_order.extend(ceiling_list)
                base_order = ["CUDA_Apples", "SYCL_Apples", "Crisp"]
                for b in base_order:
                    if b in competitors:
                        comp_order.append(b)
                for c in sorted(competitors):
                    if c not in comp_order and c not in ceiling_list:
                        comp_order.append(c)
                
                # Header
                header_cols = ["Size"]
                sep_cols = ["---"]
                
                for c in comp_order:
                    header_cols.extend([f"{c} (TFLOPS)", f"{c} (Kernel ms)", f"{c} (Wall ms)"])
                    sep_cols.extend(["---:", "---:", "---:"])
                
                # Add percentage columns if Crisp and Apples/Optimal exist
                has_crisp = "Crisp" in competitors
                has_apples = "CUDA_Apples" in competitors or "SYCL_Apples" in competitors
                has_optimal = len(ceiling_list) > 0
                
                if has_crisp and has_optimal:
                    header_cols.append("Crisp vs Optimal (%)")
                    sep_cols.append("---:")
                if has_crisp and has_apples:
                    header_cols.append("Crisp vs Apples (%)")
                    sep_cols.append("---:")
                    
                lines.append("| " + " | ".join(header_cols) + " |")
                lines.append("|" + "|".join(sep_cols) + "|")
                
                def size_key(sz_str):
                    return int(sz_str.split("x")[0])
                    
                all_sizes = set(hardware_groups[gpu][chapter][prec_key].keys())
                if prec_key in vendor_ceilings[gpu]:
                    all_sizes = all_sizes.union(vendor_ceilings[gpu][prec_key].keys())
                
                for sz in sorted(all_sizes, key=size_key):
                    if sz not in hardware_groups[gpu][chapter][prec_key] and not ceiling_list:
                        continue
                        
                    row_cols = [sz]
                    
                    crisp_tflops = None
                    apples_tflops = None
                    optimal_tflops = None
                    
                    for c in comp_order:
                        # Find metrics
                        tflops, k_ms, wall_ms = None, None, None
                        if c in ceiling_list:
                            if prec_key in vendor_ceilings[gpu] and sz in vendor_ceilings[gpu][prec_key] and c in vendor_ceilings[gpu][prec_key][sz]:
                                tflops, k_ms, wall_ms = vendor_ceilings[gpu][prec_key][sz][c]
                                optimal_tflops = tflops if optimal_tflops is None else max(optimal_tflops, tflops)
                        else:
                            if sz in hardware_groups[gpu][chapter][prec_key] and c in hardware_groups[gpu][chapter][prec_key][sz]:
                                tflops, k_ms, wall_ms = hardware_groups[gpu][chapter][prec_key][sz][c]
                                if c == "Crisp":
                                    crisp_tflops = tflops
                                elif c in ["CUDA_Apples", "SYCL_Apples"]:
                                    apples_tflops = tflops if apples_tflops is None else max(apples_tflops, tflops)
                        
                        if tflops is not None:
                            row_cols.extend([f"{tflops:.2f}", f"{k_ms:.2f}", f"{wall_ms:.2f}"])
                        else:
                            row_cols.extend(["-", "-", "-"])
                            
                    # Percentages
                    if has_crisp and has_optimal:
                        if crisp_tflops and optimal_tflops:
                            row_cols.append(f"{(crisp_tflops / optimal_tflops * 100):.1f}%")
                        else:
                            row_cols.append("-")
                            
                    if has_crisp and has_apples:
                        if crisp_tflops and apples_tflops:
                            row_cols.append(f"{(crisp_tflops / apples_tflops * 100):.1f}%")
                        else:
                            row_cols.append("-")
                            
                    lines.append("| " + " | ".join(row_cols) + " |")
                
                lines.append("\n")
                
        # Compile times section per GPU
        lines.append(f"### Compile Times\n")
        lines.append("| Chapter | Precision | Competitor | Avg Device Compile (ms) | Avg All Compile (ms) |")
        lines.append("|---|---|---|---:|---:|")
        
        for chapter in sorted(compile_times[gpu].keys()):
            for prec_key in sorted(compile_times[gpu][chapter].keys()):
                for comp in sorted(compile_times[gpu][chapter][prec_key].keys()):
                    dev_list = compile_times[gpu][chapter][prec_key][comp]['dev']
                    all_list = compile_times[gpu][chapter][prec_key][comp]['all']
                    
                    avg_dev = sum(dev_list) / len(dev_list) if dev_list else 0.0
                    avg_all = sum(all_list) / len(all_list) if all_list else 0.0
                    
                    lines.append(f"| {chapter} | {prec_key} | {comp} | {avg_dev:.2f} | {avg_all:.2f} |")
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
