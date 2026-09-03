"""
Crisp Benchmark Harness Core Data Structures & Helpers

Defines the core data structures, metadata, contender classifications,
dynamic time-budgeted iteration calculation, and result persistence.
"""
import json
import time
import math
import subprocess
import os
import sys
from datetime import datetime
from pathlib import Path
from dataclasses import dataclass, asdict, field
from enum import Enum
from typing import Dict, Any, List, Optional, Tuple

class ContenderClass(str, Enum):
    CRISP = "Crisp"
    CONTROL = "Control"  # CUDA_Apples, SYCL_Apples: test abstraction cost
    PEER = "Peer"        # CUTLASS, SYCL-TLA, CUB: test expression & compile time
    CEILING = "Ceiling"  # cuBLAS, oneMKL, cuBLASLt, oneDNN: absolute speed ceiling

def classify_contender(name: str) -> ContenderClass:
    """Classifies a benchmark competitor into Crisp, Control, Peer, or Ceiling."""
    name_clean = name.strip()
    if name_clean == "Crisp" or name_clean.startswith("Crisp_"):
        return ContenderClass.CRISP
    if any(k in name_clean for k in ["Apples", "cuda_apples", "sycl_apples"]):
        return ContenderClass.CONTROL
    # CEILING IS TESTED FIRST, deliberately.  "CUB" (NVIDIA's CUB library) is a PREFIX OF
    # "CUBLAS", so with PEER first every cuBLAS/cuBLASLt contender classified as a PEER.  See the
    # note on report.py::_is_peer for what that did to the published table.
    if any(k in name_clean for k in ["CUBLAS", "cuBLAS", "OneMKL", "oneMKL", "oneDNN", "CUBLASLt", "cuBLASLt"]):
        return ContenderClass.CEILING
    if any(k in name_clean for k in ["CUTLASS", "SYCL-TLA", "CUB", "oneDPL"]):
        return ContenderClass.PEER
    return ContenderClass.CONTROL

@dataclass
class HardwareInfo:
    gpu_model: str
    arch_target: str
    environment: str
    vram_bytes: Optional[int] = None
    sm_count: Optional[int] = None

@dataclass
class RunMetadata:
    timestamp: str
    hardware: HardwareInfo
    crisp_commit: Optional[str] = None
    cuda_version: Optional[str] = None
    driver_version: Optional[str] = None

@dataclass
class CompileTimeMetrics:
    device_compile_ms: float
    all_compile_ms: float

@dataclass
class RuntimeMetrics:
    wall_time_ms: float
    kernel_execution_ms: float

@dataclass
class ThroughputMetrics:
    tflops: Optional[float] = None
    bandwidth_gbps: Optional[float] = None

@dataclass
class VerificationMetrics:
    verified: bool = True
    mode: str = "full"  # "full", "spot_check", "inherited", "none"
    relative_error: Optional[float] = None
    # Endeavour 162 follow-up: the harnesses COMPUTE these and print them, and the collector
    # threw them away -- so a large-N failure could not be told from a near-miss after the
    # fact.  Every big-matrix point that failed verification lost the one number that would
    # have diagnosed it.  Persisted now.
    max_abs_err: Optional[float] = None
    samples: Optional[int] = None

@dataclass
class BenchmarkMetrics:
    compile_time: CompileTimeMetrics
    runtime: RuntimeMetrics
    throughput: ThroughputMetrics
    verification: Optional[VerificationMetrics] = None

@dataclass
class SweepPoint:
    configuration: Dict[str, Any]
    metrics: BenchmarkMetrics

@dataclass
class BenchmarkSweep:
    run_metadata: RunMetadata
    benchmark_suite: str
    chapter: str
    competitor: str
    precision: str
    denormal_handling: str
    results: List[SweepPoint] = field(default_factory=list)
    is_canonical: bool = True

    def to_json(self) -> str:
        return json.dumps(asdict(self), indent=2)

    def save(self, base_dir: Optional[Path] = None, force_scratch: bool = False) -> Path:
        if base_dir is None:
            base_dir = Path(__file__).resolve().parent.parent.parent / "benchmarks" / "results"
        
        if force_scratch or not self.is_canonical:
            target_dir = base_dir / "scratch"
        else:
            target_dir = base_dir

        target_dir.mkdir(parents=True, exist_ok=True)
        gpu = self.run_metadata.hardware.gpu_model.replace(" ", "_").replace("/", "_")
        filename = f"results_{gpu}_{self.chapter}_{self.competitor}_{int(time.time())}.json"
        out_path = target_dir / filename
        with open(out_path, 'w', encoding='utf-8') as f:
            f.write(self.to_json())
        return out_path

def compute_time_budgeted_counts(measured_ms: float) -> Tuple[int, int]:
    """
    Computes warmup and iteration counts based on measured single-iteration time in ms.
    warmup = clamp(3, 20, ceil(50ms / measured_ms))
    iters  = clamp(3, 100, ceil(500ms / measured_ms))
    """
    if measured_ms <= 0:
        return 20, 100
    warmup = max(3, min(20, int(math.ceil(50.0 / measured_ms))))
    iters = max(3, min(100, int(math.ceil(500.0 / measured_ms))))
    return warmup, iters

def query_device_vram_bytes() -> Optional[int]:
    """Queries total VRAM in bytes via nvidia-smi if available."""
    try:
        p = subprocess.run(
            ["nvidia-smi", "--query-gpu=memory.total", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=10
        )
        if p.returncode == 0 and p.stdout.strip():
            mb = float(p.stdout.strip().splitlines()[0].strip())
            return int(mb * 1024 * 1024)
    except Exception:
        pass
    return None

def compute_max_matmul_n(vram_bytes: Optional[int], headroom: float = 0.6) -> int:
    """
    Calculates the largest square matrix size N that safely fits in VRAM.
    Assuming 3 matrices A, B, C in fp32 (3 * 4 * N^2 = 12 * N^2 bytes).
    """
    if not vram_bytes:
        return 32768  # Sensible default
    usable_bytes = vram_bytes * headroom
    max_n = int(math.sqrt(usable_bytes / 12.0))
    return (max_n // 64) * 64

def should_full_verify_matmul(n: int) -> bool:
    """Per §5 of benchmark-harness.md: Full host reference verification only for N <= 2048."""
    return n <= 2048

def get_git_commit() -> Optional[str]:
    try:
        p = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True, timeout=5)
        if p.returncode == 0:
            return p.stdout.strip()
    except Exception:
        pass
    return None

def create_metadata(gpu_model: str = "Unknown", arch_target: str = "unknown", environment: str = "local") -> RunMetadata:
    vram = query_device_vram_bytes()
    return RunMetadata(
        timestamp=datetime.utcnow().isoformat() + "Z",
        hardware=HardwareInfo(
            gpu_model=gpu_model,
            arch_target=arch_target,
            environment=environment,
            vram_bytes=vram
        ),
        crisp_commit=get_git_commit()
    )
