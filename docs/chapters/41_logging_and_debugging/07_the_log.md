# The Log ✅


Under `--logging-output` the log is a module-scope global, `__crisp_log`, just like the die
record: no kernel argument, no host allocation, nothing passed down the call chain.  A launcher
finds it by name after the kernel finishes (`zeModuleGetGlobalPointer` / `cuModuleGetGlobal`).
Adding logging to a kernel needs no change to the host code that launches it.

Its size is fixed at compile time by `--logging-size=<bytes>` (K, M and G suffixes; default `4M`).
It is zero at module load, and reserved only in modules compiled with `--logging-output`.  It is per
module: kernels of one module running at once share it, and a host that launches more than once
zeroes it in between (the generated launchers launch once).

The log is a 16-byte header followed by messages:

| header | meaning |
|---|---|
| `cursor` (64 bits) | words claimed so far.  Every message adds its length atomically -- even one that does not fit. |
| reserved | |

Each message is a packet of 32-bit words,
`[SITE][GROUP][LOCAL][v1 lo][v1 hi] ... [vN lo][vN hi]`: the site id, the writer's linear
workgroup and local ids, then each runtime value in a 64-bit slot.  Compile-time strings never
travel through the log; the site table in the metadata holds them (see
[Runtime Strings](#runtime-strings)).

A writer claims its whole packet with one atomic add on `cursor`.  If the packet does not fit, it
writes nothing.  The log therefore holds the first messages to arrive, complete, in claim order.
Because `cursor` keeps counting past the end, its final value is exactly how many words the launch
wanted, and the launcher says so:
```
LOG FULL: kept 4194304 bytes; the launch wanted 38797312 (recompile with --logging-size=37M)
```

The launcher prints each message as `LOG <file>:<line> group <g> local <l>: <message>`, then the
die report, if there is one.



