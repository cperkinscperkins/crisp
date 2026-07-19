import json
import time
import platform
import subprocess
from datetime import datetime
from pathlib import Path
from dataclasses import dataclass, asdict
from typing import Dict, Any, List, Optional

@dataclass
class HardwareInfo:
    gpu_model: str
    arch_target: str
    environment: str

@dataclass
class RunMetadata:
    timestamp: str
    hardware: HardwareInfo

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
class BenchmarkMetrics:
    compile_time: CompileTimeMetrics
    runtime: RuntimeMetrics
    throughput: ThroughputMetrics

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
    results: List[SweepPoint]

    def to_json(self) -> str:
        return json.dumps(asdict(self), indent=2)

    def save(self, output_dir: Path):
        output_dir.mkdir(parents=True, exist_ok=True)
        gpu = self.run_metadata.hardware.gpu_model.replace(" ", "_")
        filename = f"results_{gpu}_{self.chapter}_{self.competitor}_{int(time.time())}.json"
        with open(output_dir / filename, 'w', encoding='utf-8') as f:
            f.write(self.to_json())

def get_hardware_info() -> HardwareInfo:
    # TODO: Implement actual nvidia-smi / sycl-ls parsing here
    # For now, returning dummy info
    return HardwareInfo(
        gpu_model="Unknown",
        arch_target="unknown",
        environment="local"
    )

def create_metadata() -> RunMetadata:
    return RunMetadata(
        timestamp=datetime.utcnow().isoformat() + "Z",
        hardware=get_hardware_info()
    )

if __name__ == "__main__":
    # Example usage
    meta = create_metadata()
    sweep = BenchmarkSweep(
        run_metadata=meta,
        benchmark_suite="matmul",
        chapter="chap0_sync",
        competitor="Crisp",
        precision="fast",
        denormal_handling="ftz",
        results=[
            SweepPoint(
                configuration={"m": 1024, "n": 1024, "k": 1024},
                metrics=BenchmarkMetrics(
                    compile_time=CompileTimeMetrics(device_compile_ms=12.1, all_compile_ms=38.5),
                    runtime=RuntimeMetrics(wall_time_ms=25.1, kernel_execution_ms=1.1),
                    throughput=ThroughputMetrics(tflops=1.8)
                )
            ),
            SweepPoint(
                configuration={"m": 8192, "n": 8192, "k": 8192},
                metrics=BenchmarkMetrics(
                    compile_time=CompileTimeMetrics(device_compile_ms=15.2, all_compile_ms=42.1),
                    runtime=RuntimeMetrics(wall_time_ms=215.3, kernel_execution_ms=45.1),
                    throughput=ThroughputMetrics(tflops=24.3)
                )
            )
        ]
    )
    print(sweep.to_json())
