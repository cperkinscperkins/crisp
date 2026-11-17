"""Write the crisp-gpu wheels from a staged tree (scripts/build-wheel.sh runs this in Docker).

    python3 scripts/make_wheel.py STAGE OUTDIR VERSION PLATFORM_TAG

STAGE holds crisp_gpu/ (the Python package, with bin/ inside it).  Two wheels come out, because
PyPI's limit is 100 MB per uploaded file and everything together is just over it:

  crisp-gpu        the package and every bin/ file except the hoist programs; requires crisp-gpu-hoist
  crisp-gpu-hoist  crisp_gpu/bin/crisp-hoist-{cuda,l0} only (no Python code) -- they land beside
                   crisp-compile, which is where the compiler looks for them

The wheels are written directly (zipfile + RECORD) rather than through setuptools: the contents are
prebuilt binaries, the tag is py3-none-PLATFORM (no CPython extension -- ctypes only), and the
executables need their exec bits in the zip, which pip restores on install.
"""
import base64
import hashlib
import os
import stat
import sys
import zipfile
from pathlib import Path

HOIST = ("crisp-hoist-cuda", "crisp-hoist-l0")
SUMMARY = "Crisp: a Lisp for GPU kernels (PTX and SPIR-V), with automatic differentiation -- compile at run time from Python"
LICENSE_EXPR = "Apache-2.0 WITH LLVM-exception"
URL = "https://github.com/cperkinscperkins/crisp"


def _digest(data):
    return "sha256=" + base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()


def _is_exec(path):
    return bool(path.stat().st_mode & stat.S_IXUSR)


def write_wheel(outdir, dist, version, tag, files, metadata, entry_points=None, license_files=()):
    """FILES: [(archive-name, Path)].  Returns the wheel's path."""
    norm = dist.replace("-", "_")
    distinfo = f"{norm}-{version}.dist-info"
    whl = Path(outdir) / f"{norm}-{version}-{tag}.whl"
    record = []
    with zipfile.ZipFile(whl, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        def add(arcname, data, executable=False):
            info = zipfile.ZipInfo(arcname, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = ((0o755 if executable else 0o644) | stat.S_IFREG) << 16
            z.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
            record.append(f"{arcname},{_digest(data)},{len(data)}")

        for arcname, path in sorted(files):
            add(arcname, path.read_bytes(), _is_exec(path) and not path.suffix in (".py", ".txt"))
        for lf in license_files:
            add(f"{distinfo}/licenses/{lf.name}", lf.read_bytes())
        add(f"{distinfo}/METADATA", metadata.encode())
        add(f"{distinfo}/WHEEL", ("Wheel-Version: 1.0\nGenerator: crisp make_wheel.py\n"
                                  f"Root-Is-Purelib: false\nTag: {tag}\n").encode())
        if entry_points:
            add(f"{distinfo}/entry_points.txt", entry_points.encode())
        record.append(f"{distinfo}/RECORD,,")
        z.writestr(zipfile.ZipInfo(f"{distinfo}/RECORD", date_time=(2026, 1, 1, 0, 0, 0)),
                   "\n".join(record) + "\n", compress_type=zipfile.ZIP_DEFLATED)
    return whl


def metadata(name, version, summary, requires=(), extras=None, description="", license_files=()):
    lines = ["Metadata-Version: 2.4", f"Name: {name}", f"Version: {version}", f"Summary: {summary}",
             f"License-Expression: {LICENSE_EXPR}", f"Project-URL: Homepage, {URL}",
             "Requires-Python: >=3.8",
             "Classifier: Programming Language :: Python :: 3",
             "Classifier: Programming Language :: Lisp",
             "Classifier: Operating System :: POSIX :: Linux",
             "Classifier: Environment :: GPU :: NVIDIA CUDA",
             "Classifier: Topic :: Software Development :: Compilers"]
    lines += [f"License-File: {lf.name}" for lf in license_files]
    lines += [f"Requires-Dist: {r}" for r in requires]
    for extra, reqs in (extras or {}).items():
        lines.append(f"Provides-Extra: {extra}")
        lines += [f"Requires-Dist: {r}; extra == \"{extra}\"" for r in reqs]
    if description:
        lines.append("Description-Content-Type: text/markdown")
    return "\n".join(lines) + "\n\n" + description


def main():
    stage, outdir, version, plat = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4]
    tag = f"py3-none-{plat}"
    outdir.mkdir(parents=True, exist_ok=True)
    pkg = stage / "crisp_gpu"
    lic = [p for p in (stage / "LICENSE", stage / "NOTICE", pkg / "bin" / "LICENSE-llc.txt",
                       pkg / "bin" / "LICENSE-llvm-spirv.txt") if p.exists()]
    readme = (stage / "README-pypi.md").read_text(encoding="utf-8") if (stage / "README-pypi.md").exists() else ""

    main_files, hoist_files = [], []
    for p in sorted(pkg.rglob("*")):
        if p.is_dir() or "__pycache__" in p.parts:
            continue
        arc = p.relative_to(stage).as_posix()
        (hoist_files if p.parent.name == "bin" and p.stem in HOIST else main_files).append((arc, p))
    missing = [h for h in HOIST if not any(Path(a).stem == h for a, _ in hoist_files)]
    if missing:
        sys.exit(f"make_wheel: hoist programs missing from the stage: {missing}")

    ep = ("[console_scripts]\n"
          "crisp-compile = crisp_gpu._cli:crisp_compile\n"
          "crisp-hoist-cuda = crisp_gpu._cli:crisp_hoist_cuda\n"
          "crisp-hoist-l0 = crisp_gpu._cli:crisp_hoist_l0\n")
    w1 = write_wheel(outdir, "crisp-gpu", version, tag, main_files,
                     metadata("crisp-gpu", version, SUMMARY, requires=[f"crisp-gpu-hoist=={version}"],
                              extras={"torch": ["torch"]}, description=readme, license_files=lic),
                     entry_points=ep, license_files=lic)
    w2 = write_wheel(outdir, "crisp-gpu-hoist", version, tag, hoist_files,
                     metadata("crisp-gpu-hoist", version,
                              "The hoist programs (CUDA / Level Zero launcher generators) for crisp-gpu",
                              description="Installed by `crisp-gpu`; not useful on its own.\n",
                              license_files=lic),
                     license_files=lic)
    for w in (w1, w2):
        print(f"{w.name}  {w.stat().st_size / 1e6:.1f} MB")
        if w.stat().st_size > 100 * 1000 * 1000:
            print(f"WARNING: {w.name} is over PyPI's default 100 MB file limit")


if __name__ == "__main__":
    main()
