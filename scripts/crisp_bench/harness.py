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
    # Which hardware profile the kernels were COMPILED against, and whether it is one validated
    # for this device.  Recorded because a profile for the wrong part produces numbers that look
    # exactly like real ones: `:compute-units` overrides the device SM query when sizing the
    # launch grid, so no verifier catches it.  A result file that does not say which profile it
    # used cannot be compared with one that does -- which is why these are stamped, not derived.
    hardware_profile: Optional[str] = None
    profile_matched: Optional[bool] = None
    # HOW that profile was obtained, because "matched" is not one thing.  A builtin profile has
    # been validated against the device -- queried keys compared AND measured keys swept.  A
    # profile generated on a pod by scripts/hw-profile/query-* has done only the first: its
    # MEASURED keys are deliberately absent.  Both beat compiling against the wrong part, but
    # they are not the same claim, and a reader cannot reconstruct the difference later.
    #   "builtin" -- a profile shipped in the compiler and validated for this device
    #   "file"    -- supplied by --profile-file
    #   "auto"    -- generated on this machine by --auto-profile (measured keys omitted)
    #   "none"    -- --allow-unprofiled
    profile_provenance: Optional[str] = None
    profile_source: Optional[str] = None

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
        
        # A FENCED chapter (leading underscore: _probe_*, _variant_*, _iso, _kdepth) is a
        # diagnostic, some of them numerically wrong by construction, so it can never write a
        # canonical result -- whatever flag the caller did or did not pass.  `is_canonical` existed
        # for this and nothing ever set it, so fenced results went to results/ for months.
        if force_scratch or not self.is_canonical or str(self.chapter).startswith("_"):
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

# Device bytes that ONE element position costs across the three matrices A, B and C, per ladder.
#
# This is not decoration.  The same size list drives three ladders of different element width,
# so a single fp32 answer is wrong in both directions: it walks the f64 ladder off the end of
# HBM while leaving a third of the card unused on the 16-bit one.  On an 80 GB H100 at the
# headroom below, the three ladders top out around 65k / 80k / 46k respectively.
#
# Every benchmark matrix lives in DEVICE memory (nothing here is out-of-core), so exceeding VRAM
# is a hard failure, not a slowdown.
MATMUL_ELEM_BYTES_DEFAULT = 12   # tf32 / fp32: A, B, C all 4-byte
MATMUL_ELEM_BYTES = (
    ("_f64",  24),   # A, B, C all IEEE double
    ("_bf16",  8),   # A, B at 2 bytes; C ACCUMULATES in fp32, so 2 + 2 + 4
    ("_fp16",  8),
)

def matmul_elem_bytes(chapter: str) -> int:
    """Device bytes per element position for CHAPTER's ladder, from its name suffix.

    Substring rather than suffix matching, because the variant and probe directories carry the
    width in the middle of the name (`_variant_wgmma_bf16_2wg`, `_probe_wgmma_bf16_swz`).
    """
    c = (chapter or "").lower()
    for tag, nbytes in MATMUL_ELEM_BYTES:
        if tag in c:
            return nbytes
    return MATMUL_ELEM_BYTES_DEFAULT

# 0.6, and the 0.4 left behind is NOT slack for its own sake.  The three matrices are the floor,
# not the total: cuBLAS and CUTLASS both request workspaces on top of them (split-k especially),
# the L0 and CUDA fixtures stage their own buffers, and a pod's card is not always empty when we
# arrive.  A too-generous headroom costs one rung at the top of the ladder; a too-tight one costs
# the whole point with an allocation failure, after paying for the compile.
MATMUL_VRAM_HEADROOM = 0.6

def compute_max_matmul_n(vram_bytes: Optional[int],
                         elem_bytes: int = MATMUL_ELEM_BYTES_DEFAULT,
                         headroom: float = MATMUL_VRAM_HEADROOM,
                         align: int = 64) -> Optional[int]:
    """The largest square N whose A, B and C fit in VRAM at ELEM_BYTES per element position.

    Returns None when VRAM is unknown, rather than a "sensible default" -- a guessed ceiling is
    indistinguishable from a measured one at the call site, and the caller can decline to clamp
    far more safely than it can un-clamp a wrong number.  ALIGN keeps the result a multiple of
    the tile geometry (64 is the coarsest tile dimension the ladders use).
    """
    if not vram_bytes or vram_bytes <= 0 or elem_bytes <= 0:
        return None
    max_n = int(math.sqrt((vram_bytes * headroom) / float(elem_bytes)))
    return (max_n // align) * align

def clamp_sizes_to_vram(sizes, vram_bytes: Optional[int], elem_bytes: int,
                        headroom: float = MATMUL_VRAM_HEADROOM):
    """(kept_sizes, dropped_sizes, max_n) -- sizes that do not fit are dropped, not attempted.

    When VRAM is unknown nothing is dropped: this exists to avoid a certain OOM, not to second-
    guess a card it could not measure.
    """
    max_n = compute_max_matmul_n(vram_bytes, elem_bytes, headroom)
    if max_n is None:
        return list(sizes), [], None
    kept, dropped = [], []
    for s in sizes:
        (kept if int(s) <= max_n else dropped).append(s)
    return kept, dropped, max_n

def device_max_matmul_size(vram_bytes: Optional[int], elem_bytes: int,
                           headroom: float = MATMUL_VRAM_HEADROOM,
                           legible: int = 4096) -> Optional[int]:
    """The `devmax` rung: the biggest size this card can hold, rounded DOWN to something legible.

    A ladder reading ...16384, 32768, 45056 is readable; one ending 46208 invites the question
    of what was special about 46208.  LEGIBLE is a multiple of every tile dimension the ladders
    use, so rounding cannot produce a size the geometry rejects.
    """
    max_n = compute_max_matmul_n(vram_bytes, elem_bytes, headroom, align=legible)
    return max_n if max_n and max_n > 0 else None

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

def create_metadata(gpu_model: str = "Unknown", arch_target: str = "unknown", environment: str = "local",
                    hardware_profile: Optional[str] = None,
                    profile_matched: Optional[bool] = None,
                    profile_provenance: Optional[str] = None,
                    profile_source: Optional[str] = None) -> RunMetadata:
    vram = query_device_vram_bytes()
    return RunMetadata(
        timestamp=datetime.utcnow().isoformat() + "Z",
        hardware=HardwareInfo(
            gpu_model=gpu_model,
            arch_target=arch_target,
            environment=environment,
            vram_bytes=vram,
            hardware_profile=hardware_profile,
            profile_matched=profile_matched,
            profile_provenance=profile_provenance,
            profile_source=profile_source
        ),
        crisp_commit=get_git_commit()
    )
