# `benchmarks/profiles/` — hardware profiles generated on the machine

`matmul.py --auto-profile` writes a `def-hardware-profile` here, named after the device, and
compiles every benchmark kernel against it.  See "Generating a profile on the machine" in
[`../README.md`](../README.md).

Files here are **queried, not validated**: their MEASURED keys are deliberately absent, and
results compiled against them are stamped `profile_provenance = "auto"`.  A profile becomes
validated only by sweeping those keys and moving it into `register-builtin-hardware-profiles`
in `src/mma.lisp`.

Checked in on purpose — a published number has to be reproducible, and that means the profile
it was compiled against has to still exist.
