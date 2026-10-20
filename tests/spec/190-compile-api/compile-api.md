190 -- Compile API
=================

A C API that takes Crisp source strings plus flags and returns compiled kernels.  It is aimed at FFI:
the likely callers are PyTorch, or something like OpenVINO, that need forward (and BACKWARD) kernels
compiled interactively.  They bring their own enqueue code.

This replaces the spec in docs/ideal_001.md, "In-Memory Compilation API" (~L14027).  We are DROPPING
the tree-shaking / pre-preparation idea: Crisp already compiles fast, and the cache machinery
over-engineered it.  Removing the cache also removes `set_tree_shake_directory`, `get_flags`,
the flag whitelist, the SUCCESS_COMPATIBLE / SUCCESS_BREAKING_CHANGE status codes, and
"later definitions override earlier ones".

Dogfood: a hoist flag (tentative) whose generated host code holds the kernel as a STRING, calls this
API to compile it, then enqueues it.  The TEST-HOIST machinery already runs on metal, so that is
the endeavour's milestone spec.

Status: PLANNING (2026-10-19).


Findings (2026-10-19)
=====================

F1  `bin/crisp-compile.exe` IS an SBCL image (crisp.asd:76-83, ASDF `program-op`): the SBCL runtime
    plus our core, 60 MB.  So a crisp.dll/.so would be SBCL built as a shared library (SBCL's
    linkable runtime, packaged with sbcl-librarian), and the host process then carries a Lisp
    runtime: GC, exception handling, attaching foreign threads, one runtime per process, plus
    LLVM-C.dll.

F2  The backend is not in-memory.  After IR generation it writes .ll beside the output and runs
    external tools: llvm-as + llvm-spirv for SPV (compiler.lisp:745-749) and llc for PTX
    (compiler.lisp:859).  `resolve-tool-executable` finds them under bin/ relative to the CURRENT
    DIRECTORY (compiler.lisp:40-62), the same cause as "the exe must run from the repo root".  The
    exe itself loads bin\LLVM-C.dll relative to the current directory too.  Embedded in someone
    else's process, the current directory is theirs.

F3  Compiler state is global (`*compiler-session*`, the `*crisp-*` tables, `initialize-compiler`
    clrhash).  So within one Lisp image, compiles must be serialized and each starts fresh.

F4  `--differentiate` DOES write a .metacrisp, but only for the _grad kernel.  Probe:
    tests/spec/103-autodiff-testing/01-vec-sq-lit.crisp, `--ir-target=spv --metadata --differentiate`
    -> ad_grad.spv (EntryPoints "vec_sq_lit" AND "vec_sq_lit_grad") + ad_grad_vec_sq_lit.metacrisp
    (describes vec_sq_lit_grad only).  The binary holds the primal, but its launch description
    comes only from a separate plain compile.  In the grad signature, c turns :out -> :in,
    c_grad :in and a_grad :out are added, and the adjoint pairing is implied by the name only.
    (Probe files: put_temp_files_here/190/.)

F5  .metacrisp is Lisp s-expression text: `#P"C:/..."` absolute paths, `def-record` forms,
    physical argument indices.  Fine for our own hoisters (Lisp), not for an FFI caller.

F6  S0 timings (2026-10-19, Windows, this desktop; medians in ms; noisy, +/-30%).  Scripts + raw
    results: put_temp_files_here/190/s0/ (s0.sh = cold exe, s0-warm2.lisp = one warm image).
    Kernels: k = 2 tiny kernels; big = 180/14-many-unrolled-loops.crisp.

                                   cold exe    warm image
      exe startup (no args)          147          --
      initialize-compiler             --          36   (runs on EVERY compile, via parse-cli-args)
      k   -> llvmir (no tools)       186          47   (so the real front end is ~10)
      k   -> spv                     367         ~220
      k   -> ptx                     300         ~210
      big -> llvmir                  200         ~100
      big -> spv                     565         ~520
      big -> ptx                     402         ~390
      launching any LLVM tool         ~70 each  (llvm-as --version: 68)

    Reading:
    - The Crisp front end is small: ~10 ms (k) to ~65 ms (big) once initialize-compiler is out.
    - The BACKEND dominates a warm compile: in-process opt + llvm-as + llvm-spirv (SPV) or llc (PTX),
      with ~70 ms just to launch each tool.  For k->spv the two launches are ~140 of ~220.
    - A persistent process saves the ~150 ms startup and nothing else.  In-process vs
      out-of-process differs only by copying a few KB over a pipe, so speed does not decide Q1.
    - Levers if speed matters later, cheapest first: (a) llvm-as is pure overhead: the module is
      already in memory, so write bitcode directly (LLVMWriteBitcodeToFile): -70 ms per SPV compile;
      (b) initialize-compiler on every compile: 36 ms, could reset from a snapshot; (c) llc
      in-process through an LLVM-C TargetMachine (if NVPTX is in our LLVM-C.dll); (d) llvm-spirv
      has no C API, so it stays a separate process unless we move to LLVM's in-tree SPIR-V backend
      (risky: our SPV workarounds are tied to the translator).
    - Caveat: Windows process launch is expensive; on Linux the tool-launch share will be smaller.
      Not measured there.


Draft decisions (for discussion)
================================

D1  Drop the cache / tree-shaking entirely (API and docs).
D2  The contract is the C header.  Whether it is in-process or out-of-process is hidden behind it.
D3  A context = configuration + sources + results.  Every compile starts fresh; no Lisp state
    carries over between compiles.
D4  Outputs are plural: an indexed query (count; i -> kind, entry name(s), data, size).  A compile
    can yield several modules (--split, orchestrations) and both primal and _grad kernels.
D5  Diagnostics are structured (severity, file, line, column, message), plus the joined text.
D6  Flags are an argv array, not one string.  Accept every CLI flag except the ones that write
    output files.
D7  .metacrisp stays THE metadata format (no JSON; the hoisters are unchanged).  The C API exposes
    it through accessor functions (kernel count, name, args: name / direction / address space /
    type / physical range), so an FFI caller never parses text; the raw .metacrisp text is also
    available.  It must describe EVERY entry point in the binary, primal and _grad, with explicit
    adjoint pairing (F4), and the #P paths become optional (meaningless for a string compile).
    For a caller with its own enqueue code, this is the real contract.
D8  No Lisp debugger, no stdout output, no condition escapes into the host.  Logging goes to a
    callback or stays silent.
D9  The API does not return hoist code.  The dogfood hoist CALLS the API instead.
D10 Names: `crisp_` prefix, opaque handle, `crisp_api_version()`.  A Python ctypes wrapper should
    then come almost for free.


Open questions
==============

Q1  In-process (SBCL shared lib) or out-of-process (a thin C library driving a persistent crisp
    process)?  The ecosystem precedent (from memory, unverified): Triton runs ptxas as a separate
    process and caches on disk, Inductor compiles in a worker-process pool, OpenVINO has a disk
    cache, and NVRTC is the in-process outlier.  Leaning out-of-process for v1.  Step S0 informs it.
    S0 done (F6): speed does NOT separate the two (the only difference is a few KB over a pipe);
    the backend's tool launches dominate either way.  So Q1 is about robustness and packaging.
A1: OUT-OF-PROCESS for v1 (2026-10-19).  libcrisp (.dll/.so) is a thin library written in C: no
    SBCL and no LLVM in the caller's process.  It drives a persistent crisp process.  The C header
    hides this, so an in-process build stays possible later.
    Follow-on design questions (Q8).

Q2  Is "in-memory" a requirement, or is "strings in, bytes out, no files visible to the caller"
    enough?  (F2: today even the exe uses temp files and child processes.)
A2: "in-memory" is not a requirement. We'll try to fit in as seamlessly as we can, for both call and install, but a pure "in-memory only" is not realistic.

Q3  Metadata accessors: which fields, and as what C structs?  Also: write down the s-expression
    subset .metacrisp uses (lists, keywords, strings, integers, no reader macros) as a grammar, so
    the text is a contract and not "whatever Lisp prints"?
A3: No generic accessor mirroring .metacrisp (its organization stays internal and is about to change
    with def-orchestration; plan/ref.metacrisp may already be stale).  Instead, purpose-specific
    calls added AS NEEDED and documented as they land.  The grammar question is moot: the text isn't
    exposed.  The needs, roughly easiest first:
      1. kernel names in a module (the entry point for zeKernelCreate / cuModuleGetFunction)
      2. the physical argument list: slot count; each slot's kind and size
      3. declared param -> physical slots (:range; the PTR, BYTE_SIZE, OFF.., STR.., EXT.., LENGTH layout)
      4. implicit params the caller must supply: scratch + size (sizes can be symbolic, resolved
         today only in the hoister), debug log, tensor-map descriptors
      5. launch geometry: global/local size, num-groups; can be :derive-from args :strategy ..,
         so probably a call that takes argument values and returns the grid
      6. adjoint pairing for _grad kernels
    The source-mode dogfood hoist (A7) gets its launch facts FROM THE API AT RUN TIME rather than
    baking them in at generation time (CONFIRMED 2026-10-19), so its needs ARE the API, and
    the A6(A) pass tests them on metal.  First set: items 1-3 (no implicit params, fixed
    global-size).

Q4  One target per context, or several targets per compile?
A4: One target ( --ir-target=ptx ) per context.
But a string could have multiple kernels. A single .compile() from the C API compiles to one module with kernel(s) in it. The C API accessors need which module (today there is one, but tomorrow N), which kernel
    Shape:  compile -> modules[] ; module -> bytes + kernels[] ; kernel -> name + args[].
    v1 always yields exactly one module (all kernels of all added sources), but the module index is
    in the C signatures from day one (`crisp_module_count()` returns 1): a C ABI is painful to change
    once someone binds to it, and orchestrations will make it N.
    Today's layout (probe put_temp_files_here/190/two/): one file with two kernels -> ONE two.spv +
    two_k_one.metacrisp + two_k_two.metacrisp, i.e. one module per file, one .metacrisp per kernel.
    The accessors hide that grouping.  The raw-.metacrisp-text accessor (D7) is deferred until
    def-orchestration makes it one file per module.
    A multi-target CLI compile (repeated --ir-target) is untested and probably broken
    (--hardware-profile cannot be split per target).  Not a 190 dependency.

Q5  Linux .so: PyTorch mostly lives on Linux.  Which platforms does v1 ship for?
A5: Windows and Linux.  

Q6  How do we test a C API in the spec runner?  TEST-HOIST (docker gcc / metal) already compiles C.
A6: At first I thought we could make a matching directive (TEST-HOIST-DYNAMIC[L0]) that uses that `--hoist-dynamic` flag when hoisting. But will that really be enough? We'd want to test compilation flags. How are those specified? And if there are multiple sets, how do we measure the expectation for each? And we might want to test different strings for compilation too. This almost seems like an entirely DIFFERENT type of testing. 
    Decided (2026-10-19) -- two different things are under test:
    (A) Correctness on metal: a runner pass/option that re-runs every TEST-HOIST spec with
        --hoist-kernel=source and the SAME expectations (HOIST-EXPECT, VERIFY-AUTODIFF).  Source mode
        must match file mode.  Flags come from the runner's compile, so the existing --debug /
        --single-pass / --differentiate passes become flag sets through the API for free; the
        --differentiate pass compiles forward + grad at run time (the PyTorch case).  It doubles
        the L0 runs, so it is opt-in rather than every run.  It also compiles crisp.h for real
        (the generated host code includes it).
    (B) The API itself, which isn't shaped like a .crisp file:
        B1  The Lisp core behind the C entry points (sources + flags -> result object): flags,
            multiple sources, diagnostics, kernel/arg lists from .metacrisp.  .unit.lisp, in run-ci.
        B2  The boundary: marshalling, buffer ownership, sizes, nulls, exported symbols, many
            strings x many flag sets.  PYTHON (ctypes), table-driven, in tests/api/ with its own
            runner, like the negative tests.  No GPU, so it runs in CI.  (A CI dependency on Python
            is coming anyway.  ctypes never compiles crisp.h; (A) covers that.)

Q8  Out-of-process details (from A1):
    a. Finding the crisp exe and its tools: relative to libcrisp's own location (not the current
       directory, F2), with an env var override?  This sets the install layout.
    b. Protocol: length-prefixed messages over the child's stdin/stdout?  The server must never
       write anything else to stdout (logging -> stderr or a file).
    c. Lifetime: start on the first compile, or an explicit crisp_init()?  One server per process,
       or per context?
    d. Concurrency: compiles are serialized inside one image (F3), so N server processes = N
       compiles in parallel, which is what Inductor-style worker pools want.  A pool size knob?
    e. Crash recovery: the server dies -> that compile fails with a clear status, and the next one
       restarts it.
    f. Temp files: the backend still writes .ll/.bc beside the output (F2), so the server needs a
       temp directory per compile.

Q7  Name of the dogfood hoist flag (ideal_001 says `--hoist-dynamic`).
A7: `--hoist-kernel=<where>`, <where> = `file` (today's behaviour, the default) or `source` (the
    generated host code embeds the .crisp source AND the compile flags, and passes both to the API).
    "dynamic" is avoided: in GPU work it already means dynamic parallelism, dynamic shared memory,
    dynamic shapes.  A possible later value, `embedded` (the compiled .spv/.ptx as a C array in the host
    code), is out of scope for 190.
    Flags are an ARRAY (D6), and the generated host code embeds them as one.


Draft steps
===========

S0  Measure.  Time breakdown of one crisp-compile.exe run, SPV and PTX, small kernel: process
    start + core load, frontend, each tool launch.  Decides Q1/Q2 on numbers, not taste.
S1  Header draft (crisp.h) + rewrite the ideal_001 chapter; strip tree-shaking from the doc
    (L13900 --tree-shaking, L13961 Use Tree Shaking, L13977 In Memory Compilation, L14023
    --hoist-dynamic, L10781 link).
S2  Metadata: .metacrisp covers primal + grad from one --differentiate compile, with explicit adjoint
    pairing and optional paths (F4/F5); then the C accessors over it (D7).
S3  Implementation v1 (per Q1).  Tool lookup relative to the install, not the current directory
    (F2); a temp directory per context.
S4  Dogfood hoist: a host program that embeds the kernel string, calls the API, enqueues,
    validated on metal (L0 first).
S5  Python ctypes smoke test; then a toy torch.autograd.Function with a Crisp forward + _grad.
S6  Docs: writing-crisp.md, INSTALL.md, reference/call_graph regen, definition-of-done.

Progress
========
2026-10-19  S1 header draft: c-api/include/crisp.h (accepted; compiles as C99 + C++11 -pedantic).
2026-10-19  B1: src/api.lisp (NEW file, + crisp.asd line) -- crisp.main::compile-sources.
            Spec tests/spec/190-compile-api/compile-sources.unit.lisp: 72/73 pass; the 1 failure is
            the S2 claim (--differentiate describes the primal kernel too), expected until S2.
            Verified by hand: API .spv byte-identical to crisp-compile.exe's for the same source;
            slots/roles match the hoister's layout; errors -> diagnostics, nothing on stdout.
            It writes the sources into a private temp dir and reuses the CLI helpers
            (%read-crisp-forms, %emit-target-output, %generate-file-metadata); compile-files is
            NOT refactored onto it (yet).  Kernel facts are read back from the .metacrisp (D7).
            Notes: unknown flags are REJECTED (the CLI ignores them); non-crisp Lisp errors during
            a compile count as :compile-error, as the CLI treats them; diagnostic :file is the
            primary (last) source unless a reader error names its own stream.
            Inherited quirk: `--math-precision=fast` ALWAYS warns "the `preserve` request is not
            honored", because :preserve is the DEFAULT -- the CLI does the same (parse-cli-args).

Layout: the C side lives in ./c-api/ (c-api/include/crisp.h, c-api/src/...).  src/ stays Lisp.

Don't forget (definition of done)
- docs/ideal_001.md "In-Memory Compilation API" rewritten to match the API we ACTUALLY expose
  (and the tree-shaking material removed, see S1).
- TDD: specs in tests/spec/190-compile-api/ first, B1 .unit.lisp, B2 tests/api/.
- Bump tests/ci-stop.txt to 190-compile-api.
