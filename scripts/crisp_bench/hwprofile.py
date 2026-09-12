"""Hardware-profile gate for the benchmark harness.

WHY THIS EXISTS.  The benchmark suite used to pick its hardware profile from a two-valued
`--platform` flag: anything NVIDIA got `h100` (an H100 *PCIe* profile, 114 SMs), anything Intel
got `bmg` (an Arc B580 profile).  Nothing checked that the profile described the machine.  So a
DG2, an H200, an A100 or an H100 SXM all compiled against a profile for a different part, and
the only symptom was numbers that looked bad.  `:compute-units` in particular OVERRIDES the
device SM query in the generated launch grid, so a wrong value mis-sizes every dispatch.

Worse, the harness already knew: it calls `nvidia-smi` to stamp `gpu_model` into every result
file, then compiled with `h100` regardless.  The information needed to refuse was in hand and
being discarded.

WHAT THIS MODULE DOES, and what it deliberately does NOT do.  It refuses to sweep on a device
Crisp has no validated profile for, and prints a skeleton to start from.  It does NOT try to
synthesise a profile and run anyway, because the keys that matter most cannot be discovered:

  * `:tile-visit-strip-width` is MEASURED -- 4 is +63% on BMG at N=2048 and -14.4% on H100 at
    W=16.  No query and no amount of reasoning yields it.
  * Intel's `:max-registers-per-thread` is a selectable MODE LIST `(128 256)`, not a scalar,
    and L0 cannot report it.  Collapsing it to a scalar costs 1.55-2.01x on BMG.

A profile assembled by guessing those is worse than no profile, and published numbers built on
one are worse still -- they look exactly like a real result.  Hence: refuse, and say why.

The compiler is deliberately NOT asked to do this.  `crisp-compile` links no device runtime; it
is a cross-compiler (we build sm_90 PTX on a laptop with no NVIDIA card, and CI has no GPU at
all).  A hardware profile is deployment-time metadata, orthogonal to architecture by design.
The harness is the piece that actually runs on the target, so the check belongs here.
"""
from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# ---------------------------------------------------------------------------------------------
# Device -> profile.  An EXPLICIT allow-list, not a heuristic.
#
# Being in this table is a claim that the named profile was validated against that device -- by
# running scripts/hw-profile/query-*, comparing its QUERIED keys, and measuring the MEASURED
# ones.  A device that is merely *similar* to a listed one does not belong here: H100 PCIe and
# H100 NVL are the same die and differ only in SM count (114 vs 132), and that single key is
# enough to mis-size every dispatch.
#
# Matching is case-insensitive substring, FIRST match wins, so put the more specific patterns
# first ("H100 NVL" before "H100").
# ---------------------------------------------------------------------------------------------
DEVICE_PROFILE_MAP: List[Tuple[str, str]] = [
    # --- Intel ---
    ("B580",         "bmg"),      # Arc B580 (Battlemage / Xe2) -- the profile's own device
    ("BMG",          "bmg"),
    ("Battlemage",   "bmg"),
    # --- NVIDIA ---
    ("H100 PCIE",    "h100"),     # the built-in `h100` IS the PCIe part (114 SMs)
    # H100 NVL / H100 SXM / H200 are deliberately ABSENT until a profile is validated for them.
    # They are 132-SM parts; `h100` says 114.  See the endeavour note in benchmarks/README.md.
]


class UnprofiledDevice(Exception):
    """Raised when the detected device has no validated hardware profile."""

    def __init__(self, device: str, wanted: Optional[str], available: List[str], message: str):
        super().__init__(message)
        self.device = device
        self.wanted = wanted
        self.available = available


# ---------------------------------------------------------------------------------------------
# Which profiles does the COMPILER actually have?
# ---------------------------------------------------------------------------------------------

_known_cache: Optional[List[str]] = None


def known_profiles(crisp_compiler: str) -> List[str]:
    """The profile names the compiler has registered, lowercased.

    Asked of the COMPILER rather than hardcoded here, because a list in this file would be one
    more thing to drift: `active-hardware-profile` already reports "Known profiles: BMG H100."
    when handed a name it does not have, so a deliberately bogus request is an exact, always
    current answer.  Returns [] if the compiler cannot be run (the caller then degrades rather
    than blocking a sweep on a parsing failure).
    """
    global _known_cache
    if _known_cache is not None:
        return _known_cache

    _known_cache = []
    try:
        import tempfile
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "_profile_probe.crisp"
            src.write_text("(def-function k ()\n  (declare (return-type int))\n  7)\n",
                           encoding="utf-8")
            # RUN FROM THE REPO ROOT.  crisp-compile resolves `bin/LLVM-C.dll` relative to the
            # CWD, so invoking it from scripts/crisp_bench dies in CFFI before it ever parses
            # the flag -- and this function would then silently report "no profiles".  The root
            # is the parent of the compiler's own bin/ directory.
            root = Path(crisp_compiler).resolve().parent.parent
            p = subprocess.run(
                [crisp_compiler, "--ir-target=spv",
                 "--hardware-profile=--crisp-bench-nonexistent--",
                 "--log-level=off", str(src)],
                capture_output=True, text=True, timeout=180, cwd=str(root))
        blob = (p.stdout or "") + (p.stderr or "")
        m = re.search(r"Known profiles:\s*([^.\n]+)", blob)
        if m:
            _known_cache = [w.strip().lower() for w in m.group(1).split() if w.strip()]
    except Exception:
        pass
    return _known_cache


# ---------------------------------------------------------------------------------------------
# What device are we on?
# ---------------------------------------------------------------------------------------------

def detect_device(platform: str, pretend: Optional[str] = None) -> Optional[str]:
    """The GPU's own name, or None if it cannot be determined.

    `pretend` (from --pretend-device, or CRISP_BENCH_PRETEND_DEVICE) short-circuits everything,
    so the gate is testable with no GPU present -- which matters because the gate's whole job is
    what happens on hardware we do not have.
    """
    pretend = pretend or os.environ.get("CRISP_BENCH_PRETEND_DEVICE")
    if pretend:
        return pretend.strip()

    if platform == "nvidia":
        return _detect_nvidia()
    return _detect_intel()


def _run(cmd: List[str], timeout: float = 30.0) -> Optional[str]:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        if p.returncode == 0 and p.stdout.strip():
            return p.stdout
    except Exception:
        pass
    return None


def _detect_nvidia() -> Optional[str]:
    out = _run(["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"])
    if out:
        first = out.strip().splitlines()[0].strip()
        if first:
            return first
    return None


def _detect_intel() -> Optional[str]:
    """Intel device name, via sycl-ls then clinfo.

    There is no `nvidia-smi` equivalent, and building scripts/hw-profile/query-l0.cpp needs the
    Level Zero headers, so this uses whatever the benchmarking container already has.  sycl-ls
    is present wherever the SYCL controls are built, which is every Intel benchmark run.
    """
    out = _run(["sycl-ls"])
    if out:
        for line in out.splitlines():
            # e.g. "[level_zero:gpu][level_zero:0] ... , Intel(R) Arc(TM) B580 Graphics 12.71.4 [...]"
            if "gpu" not in line.lower():
                continue
            m = re.search(r"Intel\(R\)\s+([^,\[]+)", line)
            if m:
                return ("Intel " + m.group(1).strip()).strip()
    out = _run(["clinfo", "--raw"])
    if out:
        for line in out.splitlines():
            if "CL_DEVICE_NAME" in line:
                parts = line.split(None, 2)
                if len(parts) >= 3:
                    return parts[2].strip()
    return None


# ---------------------------------------------------------------------------------------------
# The gate
# ---------------------------------------------------------------------------------------------

def profile_for_device(device: str) -> Optional[str]:
    """The profile validated for DEVICE, or None.  First substring match wins."""
    up = device.upper()
    for pattern, profile in DEVICE_PROFILE_MAP:
        if pattern.upper() in up:
            return profile
    return None


def _skeleton(device: str, platform: str) -> str:
    """A starting-point profile, with each key labelled by how to obtain it.

    Deliberately does NOT invent values.  The probe programs print queried numbers; this is the
    text shown when they have not been run, so every line says where its value comes from
    instead of guessing one.
    """
    name = re.sub(r"[^a-z0-9]+", "-", device.lower()).strip("-") or "my-device"
    name = re.sub(r"^nvidia-", "", name)
    probe = ("scripts/hw-profile/query-cuda.cu" if platform == "nvidia"
             else "scripts/hw-profile/query-l0.cpp")
    intel = platform != "nvidia"
    lines = [
        "(def-hardware-profile %s" % name,
        "  ;; QUERIED -- run %s and paste its values" % probe,
        "  :simd-width <N>",
        "  :compute-units <N>                    ; OVERRIDES the device SM query in the launch",
        "                                        ;   grid -- a wrong value mis-sizes EVERY dispatch",
        "  :max-total-threads-per-block <N>",
        "  :max-work-group-dims '(<X> <Y> <Z>)",
        "  :max-shared-memory-per-block <N>KB    ; NVIDIA: the OPT-IN cap, not the 48KB default",
        "  :l2-cache-size <N>MB",
        "  ;; ARCH -- an ISA fact; look it up for YOUR part",
        "  :native-cache-line-size %s" % ("64   ; Xe2 LSC line" if intel else "128  ; NVIDIA"),
    ]
    if intel:
        lines += [
            "  :max-registers-per-thread '(128 256)  ; a LIST: ascending selectable GRF modes.",
            "                                        ;   A SCALAR forfeits large-GRF (1.55-2.01x).",
            "  :mma-shapes '((8 16 8) (8 16 16) (8 16 32))  ; tf32 / bf16-fp16 / int8.  Listing only",
            "                                        ;   the first REFUSES every 16-bit MMA kernel.",
            "  :mma-lowerings '(:coop-matrix)        ; add :xe-native ONLY on Xe2+ (DPAS + Block2D)",
        ]
    else:
        lines += [
            "  :max-registers-per-thread 255         ; a SCALAR on NVIDIA",
            "  :mma-shapes '((16 8 8) (16 8 4) (16 8 16) (:double 8 8 4))",
            "                                        ; the TYPED fp64 entry is required: without it",
            "                                        ; `double` picks a non-intrinsic shape and emits",
            "                                        ; an .extern .func call with NO diagnostic.",
        ]
    lines += [
        "  ;; MEASURED -- OMIT these unless you have actually swept them.",
        "  ;; :tile-visit-strip-width is +63% on BMG at N=2048 and -14.4% on H100 at W=16;",
        "  ;; absent means linear, which is safe.  A guess here can make your numbers WORSE.",
        "  )",
    ]
    return "\n".join(lines)


# ---------------------------------------------------------------------------------------------
# Generating a profile ON the machine, from the probe programs
#
# WHY.  The gate above refuses correctly but leaves the operator stuck on a rented pod: a
# profile had to be compiled INTO crisp-compile, so a new device cost an edit, a push, a
# re-clone and a rebuild before the first kernel compiled -- all on the clock, and RunPod does
# not offer the same part twice in a row.  Crisp already supports the cheaper route
# (`crisp-compile profile.crisp kernel.crisp --hardware-profile=NAME`); the harness simply never
# passed a profile SOURCE file, only the flag.
#
# WHAT IT DOES NOT DO.  A generated profile is not a validated one, and this module refuses to
# blur that.  `query-cuda.cu` answers the QUERIED tier and states the ARCH tier for the part it
# knows; nothing can answer the MEASURED tier without a sweep, so those keys stay ABSENT -- the
# probe never emits a value for `:tile-visit-strip-width`, and absent means linear, which is
# safe.  Results are stamped `profile_provenance = "auto"` so a reader can tell a profile that
# was swept from one that was merely queried.  That distinction is the entire reason the gate
# exists; automating the easy half must not quietly erase it.
# ---------------------------------------------------------------------------------------------

def _blank_lisp_comments(text: str) -> str:
    """TEXT with `;`-to-end-of-line comments replaced by SPACES, same length, same offsets.

    Blanked rather than removed so every index into the result is also a valid index into the
    original -- which is what lets the caller slice the form out of TEXT with its comments
    intact after balancing parens over this.

    Required, not defensive: the probe's own comments contain parentheses.  "a SCALAR on NVIDIA
    (D4)" and "(M=64, N mult of 8 in [8,256])" both appear inside the emitted form, and counting
    parens over the raw text closes the form in the middle of a comment -- truncating the
    profile to something that still parses.
    """
    out = []
    for line in text.splitlines(keepends=True):
        in_str = False
        cut = None
        for i, ch in enumerate(line):
            if ch == '"' and (i == 0 or line[i - 1] != "\\"):
                in_str = not in_str
            elif ch == ";" and not in_str:
                cut = i
                break
        if cut is None:
            out.append(line)
        else:
            tail = line[cut:]
            keep_nl = "\n" if tail.endswith("\n") else ""
            out.append(line[:cut] + " " * (len(tail) - len(keep_nl)) + keep_nl)
    return "".join(out)


def extract_profile_form(text: str) -> Optional[str]:
    """The first complete `(def-hardware-profile ...)` s-expression in TEXT, or None.

    Returned with its comments INTACT -- they carry the QUERIED/ARCH/MEASURED provenance that
    makes the file reviewable, and a profile whose values cannot be audited is the thing this
    whole module exists to prevent.  Only the paren-balancing scan ignores them.
    """
    scan = _blank_lisp_comments(text)
    start = scan.find("(def-hardware-profile")
    if start < 0:
        return None
    depth = 0
    for i in range(start, len(scan)):
        if scan[i] == "(":
            depth += 1
        elif scan[i] == ")":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return None            # unbalanced: truncated output, and a partial profile is worse than none


def profile_name_of(form: str) -> Optional[str]:
    """The profile name a `def-hardware-profile` form declares."""
    m = re.search(r"\(def-hardware-profile\s+([^\s()]+)", form)
    return m.group(1).strip().lower() if m else None


def find_nvcc() -> Optional[str]:
    """`nvcc`, looking where cloud images actually put it.

    On typical RunPod/NGC images CUDA is installed but nvcc is NOT on PATH -- it lives under
    /usr/local/cuda/bin.  A profile generator that gives up because `nvcc` is not on PATH would
    fail on the exact machines it was written for.
    """
    from shutil import which
    found = which("nvcc")
    if found:
        return found
    for cand in ("/usr/local/cuda/bin/nvcc", "/opt/cuda/bin/nvcc"):
        if os.path.exists(cand):
            return cand
    import glob as _glob
    for cand in sorted(_glob.glob("/usr/local/cuda-*/bin/nvcc"), reverse=True):
        return cand
    return None


def generate_profile(platform: str, repo_root: Path, out_dir: Path) -> Tuple[str, Path]:
    """Build and run the device probe, write the profile it prints, return (name, path).

    Raises RuntimeError with a message the operator can act on -- this runs on a pod where the
    next step costs money, so "it didn't work" is not an acceptable diagnostic.
    """
    if platform != "nvidia":
        raise RuntimeError(
            "--auto-profile is implemented for NVIDIA only.\n"
            "The Intel probe (scripts/hw-profile/query-l0.cpp) needs the Level Zero headers to\n"
            "build, which the benchmark container does not carry, and Intel's `bmg` profile is\n"
            "already validated -- so the case this automates does not arise there.")

    probe_src = repo_root / "scripts" / "hw-profile" / "query-cuda.cu"
    if not probe_src.exists():
        raise RuntimeError("device probe not found: %s" % probe_src)

    nvcc = find_nvcc()
    if not nvcc:
        raise RuntimeError(
            "nvcc not found (checked PATH, /usr/local/cuda/bin, /opt/cuda/bin, /usr/local/cuda-*).\n"
            "The profile is generated by compiling scripts/hw-profile/query-cuda.cu, so CUDA's\n"
            "toolkit -- not just its driver -- has to be present.")

    import tempfile
    with tempfile.TemporaryDirectory() as td:
        exe = Path(td) / "query-cuda"
        b = subprocess.run([nvcc, str(probe_src), "-o", str(exe)],
                           capture_output=True, text=True, timeout=600)
        if b.returncode != 0:
            raise RuntimeError("could not build the device probe:\n%s"
                               % ((b.stderr or b.stdout or "").strip()[:2000]))
        r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=120)
        if r.returncode != 0 or not r.stdout.strip():
            raise RuntimeError("the device probe did not run:\n%s"
                               % ((r.stderr or r.stdout or "").strip()[:2000]))

    form = extract_profile_form(r.stdout)
    if not form:
        raise RuntimeError(
            "the device probe ran but printed no (def-hardware-profile ...) form.\n"
            "Its raw output is above; paste the profile into a .crisp file and pass\n"
            "--profile-file instead.")
    name = profile_name_of(form)
    if not name:
        raise RuntimeError("could not read the profile name out of the probe's output.")

    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / ("%s.crisp" % name)
    header = (
        ";;;; GENERATED by scripts/crisp_bench/hwprofile.py --auto-profile.\n"
        ";;;; Source: scripts/hw-profile/query-cuda.cu, run on this machine.\n"
        ";;;;\n"
        ";;;; This profile is QUERIED, not VALIDATED.  Its MEASURED keys are deliberately\n"
        ";;;; ABSENT -- :tile-visit-strip-width above all, which is +63%% on BMG and -14.4%% on\n"
        ";;;; H100 and which no query can answer.  Absent means linear, which is safe.\n"
        ";;;; Results compiled against it are stamped profile_provenance=\"auto\".\n"
        ";;;;\n"
        ";;;; To PROMOTE it to a validated builtin: sweep the measured keys, add them here, move\n"
        ";;;; the form into register-builtin-hardware-profiles (src/mma.lisp) and add the device\n"
        ";;;; to DEVICE_PROFILE_MAP in this directory's hwprofile.py.\n\n")
    path.write_text(header + form + "\n", encoding="utf-8")
    return name, path


def load_profile_file(path: Path) -> Tuple[str, Path]:
    """(profile_name, path) for an operator-supplied profile file."""
    if not path.exists():
        raise RuntimeError("--profile-file: no such file: %s" % path)
    form = extract_profile_form(path.read_text(encoding="utf-8", errors="replace"))
    if not form:
        raise RuntimeError("--profile-file: %s contains no (def-hardware-profile ...) form." % path)
    name = profile_name_of(form)
    if not name:
        raise RuntimeError("--profile-file: could not read the profile name from %s." % path)
    return name, path


def gate(platform: str,
         crisp_compiler: str,
         pretend: Optional[str] = None,
         allow_unprofiled: bool = False,
         auto_profile: bool = False,
         profile_file: Optional[str] = None,
         repo_root: Optional[Path] = None,
         profile_out_dir: Optional[Path] = None) -> Tuple[Optional[str], str, bool, str, Optional[str]]:
    """Decide which hardware profile this sweep may use.

    Returns (profile_name, device_name, matched, provenance, profile_source_path).

    `matched` stays True ONLY for a builtin profile validated for this device; `provenance`
    distinguishes the weaker cases ("file", "auto") from it and from "none".  Callers stamp
    both, so a result file says not just WHICH profile it used but how much that profile was
    known to be right.  Raises UnprofiledDevice when nothing can be established.
    """
    device = detect_device(platform, pretend)
    available = known_profiles(crisp_compiler)

    # An explicit file wins outright: the operator has said what this machine is, and a
    # DEVICE_PROFILE_MAP entry cannot be a precondition for benchmarking a part nobody has
    # benchmarked yet.
    if profile_file:
        name, path = load_profile_file(Path(profile_file))
        return name, (device or "unknown"), False, "file", str(path)

    if not device:
        msg = (
            "Could not determine which GPU this is.\n"
            "  %s\n"
            "Benchmarks need a hardware profile matched to the device, and without the device\n"
            "name there is nothing to match.  Pass --pretend-device='<name>' if you know what\n"
            "this machine is, or --allow-unprofiled to sweep with no profile at all (results\n"
            "will be stamped unprofiled and are NOT comparable to published figures)."
            % ("`nvidia-smi` is not on PATH or reported nothing."
               if platform == "nvidia" else
               "Neither `sycl-ls` nor `clinfo` reported a GPU.")
        )
        if allow_unprofiled:
            return None, "unknown", False, "none", None
        raise UnprofiledDevice("unknown", None, available, msg)

    wanted = profile_for_device(device)

    if wanted and wanted in available:
        return wanted, device, True, "builtin", None

    # No validated profile.  Before refusing, offer the route that does not need one: query the
    # device and compile against what it says.  Opt-in (--auto-profile) rather than automatic,
    # because it produces a WEAKER claim than a builtin and that has to be a decision somebody
    # made, not a default that quietly happened.
    if auto_profile:
        root = Path(repo_root) if repo_root else Path(crisp_compiler).resolve().parent.parent
        out_dir = Path(profile_out_dir) if profile_out_dir else (root / "benchmarks" / "profiles")
        try:
            name, path = generate_profile(platform, root, out_dir)
        except Exception as exc:
            raise UnprofiledDevice(
                device, wanted, available,
                "\n--auto-profile could not build a profile for %s:\n\n  %s\n\n"
                "Nothing has been swept.  Fix the above, or pass --profile-file with a profile\n"
                "you wrote by hand (see \"Custom Profiles\" in benchmarks/README.md).\n"
                % (device, str(exc).replace("\n", "\n  ")))
        return name, device, False, "auto", str(path)

    # Either no profile is claimed for this device, or one is claimed but the compiler does not
    # have it.  Both are the same outcome for the user and get the same message; the reason line
    # differs so we can tell a missing MAPPING from a missing PROFILE.
    if wanted:
        reason = ("Crisp expects profile `%s` for this device, but the compiler has no such\n"
                  "profile registered (known: %s)."
                  % (wanted, ", ".join(available) if available else "<none reported>"))
    else:
        reason = ("Crisp has no validated hardware profile for this device.\n"
                  "Known profiles: %s -- none of them describes it."
                  % (", ".join(available) if available else "<none reported>"))

    msg = (
        "\n"
        "================================================================================\n"
        " Hardware detected: %s\n"
        "================================================================================\n"
        "%s\n"
        "\n"
        "Benchmarks REFUSE to run unprofiled, because every published Crisp figure assumes a\n"
        "profile matched to the device.  A profile for the wrong part does not merely lose\n"
        "performance -- `:compute-units` overrides the device SM query when sizing the launch\n"
        "grid, so the numbers would be wrong in a way no verifier catches.\n"
        "\n"
        "  -> See \"Custom Profiles\" in benchmarks/README.md\n"
        "  -> Run the probe for measured values: %s\n"
        "\n"
        "Starting point (values NOT invented -- each line says where to get it):\n"
        "\n"
        "%s\n"
        "\n"
        "Then:  crisp-compile <your-profile>.crisp <kernel>.crisp --hardware-profile=%s\n"
        "       ...and add your device to DEVICE_PROFILE_MAP in scripts/crisp_bench/hwprofile.py\n"
        "\n"
        "OR, to do all of that automatically on THIS machine (the usual answer on a rented pod):\n"
        "\n"
        "  --auto-profile      build and run the probe above, write the profile it prints to\n"
        "                      benchmarks/profiles/, and compile every kernel against it.\n"
        "                      Its MEASURED keys stay ABSENT (absent = linear = safe), so the\n"
        "                      results are stamped profile_provenance=\"auto\": queried, not\n"
        "                      validated.  Good enough to publish a RATIO; not the same claim\n"
        "                      as a swept builtin.\n"
        "  --profile-file=P    compile against the profile in P instead.\n"
        "\n"
        "To sweep anyway with NO profile (results stamped unprofiled, NOT comparable to\n"
        "published figures):  --allow-unprofiled\n"
        "================================================================================\n"
        % (device, reason,
           "scripts/hw-profile/query-cuda.cu" if platform == "nvidia"
           else "scripts/hw-profile/query-l0.cpp",
           _skeleton(device, platform),
           re.sub(r"^nvidia-", "", re.sub(r"[^a-z0-9]+", "-", device.lower()).strip("-")) or "my-device")
    )

    if allow_unprofiled:
        return None, device, False, "none", None
    raise UnprofiledDevice(device, wanted, available, msg)
