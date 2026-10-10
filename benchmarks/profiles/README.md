# `benchmarks/profiles/` — hardware profiles generated on the machine

`matmul.py --auto-profile` writes a `def-hardware-profile` here, named after the device, and
compiles every benchmark kernel against it.  See "Generating a profile on the machine" in
[`../README.md`](../README.md).

Files here are **queried, not validated**: their MEASURED keys are deliberately absent, and
results compiled against them are stamped `profile_provenance = "auto"`.  A profile becomes
validated only by sweeping those keys and moving it into `register-builtin-hardware-profiles`
in `src/mma.lisp`.

**Exception: hand-maintained profiles.**  `h100-sxm.crisp` is NOT generated.  It copies the QUERIED keys
of the H100 SXM (`h100-80gb-hbm3.crisp`, which `--auto-profile` rewrites on every run) and adds a MEASURED
key a query cannot answer -- `:stream-occupancy-target 1024` (endeavour 182).  Pass it with
`reduction.py --profile-file benchmarks/profiles/h100-sxm.crisp`; outside the harness, a profile is just
another source on the command line: `crisp-compile h100-sxm.crisp <kernel.crisp> --hardware-profile=h100-sxm`.
Results compiled against it are stamped `profile_provenance = "file"` ("supplied*" in the report).

Checked in on purpose — a published number has to be reproducible, and that means the profile
it was compiled against has to still exist.
