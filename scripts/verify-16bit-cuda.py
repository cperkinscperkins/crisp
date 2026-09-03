#!/usr/bin/env python3
"""Verify Crisp's 16-bit NVIDIA MMA on real hardware, through the reviewed CUDA fixture.

WHAT THIS IS FOR.  Endeavour 159 Phase B taught the PTX backend to emit the 16-bit sync MMA
(mma.sync.aligned.m16n8k16.row.col.f32.{f16,bf16}.*.f32).  That the INSTRUCTION is emitted is
checked locally by tests/spec/159-nvidia-16bit/0{1,2}; that its OPERANDS land in the right lanes
cannot be.  A store/load roundtrip cannot see a wrong-but-self-consistent fragment layout -- it
roundtrips perfectly -- so only an MMA compared against a host reference can, and that needs a GPU.

WHY THE FIXTURE AND NOT `--mma-test`.  The generated per-kernel harness is both the thing measured
and the apparatus measuring it; on Intel it reported MMA_WRONG for a kernel that was always correct
and let a kernel that stored nothing post the second-best number in its section.  It is also
16-bit-broken on CUDA: it fills A/B by writing the small integers 0..4 as RAW BIT PATTERNS (fp16
denormals, effectively zero) and reads them back as hardcoded `float`, so its verdict for a 16-bit
kernel means nothing whichever way it comes out.  benchmarks/matmul/crisp/bench_harness.cu is one
reviewed harness, shared by every kernel, and it encodes and decodes 16-bit properly.

RUN THIS ON THE POD.  It needs nvcc and a GPU; everything else it does is local work already
verified on the dev box.  Prints ONE JSON object to stdout -- keep the pod's stdout out of the
conversation and read this instead.

    python3 scripts/verify-16bit-cuda.py [--arch sm_90] [--sizes 256,512] > 159-verify.json
"""
import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts" / "crisp_bench"))

# The rungs under test: (spec stem, kernel name, expected PTX mnemonic).
RUNGS = [
    ("01-sync-mma-fp16-ptx", "fp16_sync_mma",
     "mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32"),
    ("02-sync-mma-bf16-ptx", "bf16_sync_mma",
     "mma.sync.aligned.m16n8k16.row.col.f32.bf16.bf16.f32"),
]
SPEC_DIR = ROOT / "tests" / "spec" / "159-nvidia-16bit"


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arch", default="sm_90")
    ap.add_argument("--sizes", default="256,512")
    ap.add_argument("--warmup", type=int, default=3)
    ap.add_argument("--iters", type=int, default=10)
    ap.add_argument("--compiler", default=str(ROOT / "bin" / "crisp-compile"))
    a = ap.parse_args()

    import matmul  # noqa: E402  (needs the sys.path insert above)

    report = {"arch": a.arch, "rungs": [], "ok": True}

    # --- build the fixture once -----------------------------------------------------------
    harness_src = ROOT / "benchmarks" / "matmul" / "crisp" / "bench_harness.cu"
    harness_bin = ROOT / "benchmarks" / "matmul" / "crisp" / "matmul_crisp"
    c = run(["nvcc", "-O3", f"-arch={a.arch}", str(harness_src), "-lcuda", "-o", str(harness_bin)])
    report["fixture_build"] = {"ok": c.returncode == 0, "stderr": c.stderr[-1500:] if c.returncode else ""}
    if c.returncode != 0:
        report["ok"] = False
        print(json.dumps(report, indent=2))
        return 1

    for stem, kernel, want in RUNGS:
        entry = {"spec": stem, "kernel": kernel, "expected_mnemonic": want}
        src = SPEC_DIR / f"{stem}.crisp"

        # --- compile to PTX + metacrisp ---------------------------------------------------
        c = run([a.compiler, "--ir-target=ptx", "--hardware-profile=h100",
                 "--metadata", str(src)])
        ptx = SPEC_DIR / f"{stem}.ptx"
        meta = SPEC_DIR / f"{stem}_{kernel}.metacrisp"
        entry["compiled"] = c.returncode == 0 and ptx.exists()
        if not entry["compiled"]:
            entry["error"] = (c.stderr or c.stdout)[-1200:]
            report["rungs"].append(entry); report["ok"] = False
            continue

        # --- the instruction is present, and no tf32 survives ------------------------------
        text = ptx.read_text(errors="replace")
        entry["mnemonic_present"] = want in text
        entry["tf32_present"] = "tf32" in text
        if not entry["mnemonic_present"] or entry["tf32_present"]:
            entry["error"] = "PTX does not carry the expected 16-bit MMA (or tf32 survives)"
            report["rungs"].append(entry); report["ok"] = False
            continue

        # --- run the fixture at each size --------------------------------------------------
        env = dict(os.environ)
        env.update(matmul.cuda_fixture_env(src, meta, ptx))
        entry["env"] = {k: v for k, v in env.items() if k.startswith("CRISP_MATMUL_")}
        entry["runs"] = []
        for s in [int(x) for x in a.sizes.split(",") if x]:
            # K must be a multiple of the 16-bit K-step (16); M/N multiples of the 16x8 tile.
            r = run([str(harness_bin), str(s), str(s), str(s), str(a.warmup), str(a.iters)], env=env)
            obj = None
            m = re.search(r"\{.*\}", r.stdout, re.S)
            if m:
                try:
                    obj = json.loads(m.group(0))
                except Exception:
                    obj = None
            run_entry = {"size": s, "exit": r.returncode}
            if obj:
                run_entry.update({k: obj.get(k) for k in
                                  ("correct", "max_abs_err", "verify_samples",
                                   "kernel_median_us", "gflops", "shared_bytes", "grid", "block")})
            else:
                run_entry["stderr"] = r.stderr[-800:]
                run_entry["stdout"] = r.stdout[-400:]
            if not run_entry.get("correct"):
                report["ok"] = False
            entry["runs"].append(run_entry)

        report["rungs"].append(entry)

    print(json.dumps(report, indent=2))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
