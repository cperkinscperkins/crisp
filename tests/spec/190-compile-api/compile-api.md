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
            (Chris's read: the denormal default is :preserve, so the warning can't tell asked-for
            from defaulted.  Fixed in the API -- see R3; the CLI is unchanged, BUG candidate.)
2026-10-19  S2 (API side): a --differentiate compile describes each primal kernel AND its _grad,
            with explicit :grad-of / :adjoint-of; tensor :layout added.  Spec 103/103.
            Verified by hand: primal from a --differentiate compile == plain compile's (slots +
            params); user param `w_grad` stays an input, `w_grad_grad` pairs with it.
            Header: + crisp_kernel_grad_of, crisp_param_adjoint_of, crisp_param_layout; units
            documented.  Build 0 warnings; run-ci passes.
2026-10-19  S3: the server, the C library, the Python suite.
            - `crisp-compile --serve` (src/api.lisp serve-main; 2-line dispatch in src/main.lisp main).
              Framing documented at the top of api.lisp's server section.  Probe: hello in ~0.3-0.5 s
              cold; warm compiles ~250 ms; the server's .spv is byte-identical to the CLI's.
            - c-api/src/crisp.c + c-api/build.sh -> bin/crisp.dll (Windows) / bin/libcrisp.so
              (Linux).  -Wall -Wextra -pedantic clean on both (Linux built in crisp-c-validator);
              Linux exports exactly the 36 CRISP_API functions.
            - tests/api/test_crisp_api.py (+ crisp_ctypes.py): 25 tests, all pass, ~6 s, Windows.
              Covers NULLs/bad indexes, NO_RESULT, copies, NUL-terminated PTX, unicode names, the
              flag table, --differentiate pairing, 6 parallel threads, shutdown + restart, a
              missing compiler + recovery.  No helper processes or temp dirs left behind.
            - Found + fixed on the way: (1) log4cl writes to the REAL stdout -> the server turns
              logging off (TODO: opt-in log to stderr/file); (2) every compile after the first in
              an image re-runs template DEFMACROs -> SBCL "redefining" warnings became caller
              diagnostics -> muffled in compile-sources; (3) PTX's .metacrisp records pointer
              slots as ULONG -> pointer-ness now comes from the param roles (R10).
            NOT verified: the Linux library at RUN time (no Linux crisp-compile build locally; CI
            builds one -- step 13.5 will be the first real Linux run).
2026-10-20  S4: the dogfood launcher, ON METAL (BMG).  Specs 01 (one kernel) and 02 (two kernels
            in one source + a scalar; each launcher finds its own kernel by name) PASS: "Kernel
            compiled at run time through the Crisp compile API", "Argument slots from the compile
            API: 12 of 12" / "13 of 13", expected buffers.  The FILE-mode launcher is byte-identical
            to the pre-190 hoister's output (checked on 006-branching/10).
            Before S4: E2E 1498/1498, negative 354/354 (the --serve dispatch broke nothing).
            A6(A), first full run: 150 L0 launchers compiled their kernel through the API and took
            their slots from it; the API never moved a slot ("NOTE ... moved": 0).  Failures were
            all the PASS'S fault, not the API's: 4 FFI specs (source mode refuses .bc, R18) and
            10-tile-stride (a TEXT validator expecting literal `kernel, 0,`).  Then the runner
            itself died (exit 139) in an in-process Default compile of
            176/14-diff-grid-reduce-independent, ~3/4 through; that spec passes alone, also under
            the pass.  Cause unknown.  Suspect removed anyway: the runner had been setenv'ing PATH
            ~300 times; launchers now get an explicit :environment instead (R24).
            A6(A), second full run: Spec Summary 1500/1500 (incl. the two 190 specs).  183 L0
            launchers compiled through the API and ran on the BMG against UNCHANGED expectations;
            slots moved by the API: 0.  114 fully mapped; 69 also take implicit params (scratch
            ...) that stay identity until the API describes them -- the next API facts.  No crash.
            Final: run-ci passes, negative 354/354, Python API suite 25/25, no stray helpers.
            S6: ideal_001.md chapter rewritten as "Compile API" (tree-shaking, --hoist-dynamic and
            the old status codes removed; --hoist-kernel documented); chapters, reference.md,
            call graph, globals and specials regenerated; INSTALL.md section; ci.yml step 13.5 +
            run-all-tests.bat run the Python suite; build/build.lisp builds the library.
            ci-stop.txt -> 190-compile-api.


Decisions for review (made while Chris was away, 2026-10-19 night)
==================================================================
Each one is reversible; say the word and it changes.

R1  S2 lives in the API, NOT in crisp-compile's .metacrisp files.  Under --differentiate the API
    writes the primal's .metacrisp into its private temp dir with the same serializer
    (src/api.lisp %api-write-kernel-metacrisp).  Why: tests/run-specs.lisp tells a backward
    metacrisp by searching its TEXT for `_grad"` and then asserts (by text) it has no forward
    scheduling declarations (%152-backward-metacrisp-p, %152-assert-no-schedule-leak); a primal
    added to that file would trip it, and a separate primal file next to it would confuse
    %152-find-metacrisp.  Alternative: change the CLI files + those runner helpers.
R2  Adjoint pairing is DERIVED in the API from the AD pass's naming (<p>_grad), guarded so a
    user's own `x_grad` parameter is not misread (P pairs with Q iff P = Q_grad, Q is a primal
    param, P is not).  Alternative: have the AD pass emit :adjoint-of into the metacrisp.
R3  The fast-vs-preserve warning fires only on an EXPLICIT --denormal-handling=preserve (API only).
    The CLI still warns on every --math-precision=fast.  Candidate for bugs.md.
R4  Unknown flags are rejected by the API (the CLI silently ignores them).
R5  Tensor layout is exposed (crisp_param_layout): a :compact kernel IGNORES offsets and strides
    (analyze-aref-expression), so a caller holding a non-contiguous view must know.  Not in A3's
    original list; added because PyTorch-style callers will hit it at once.
R6  Kernel order under --differentiate: each forward kernel, then its _grad.
R7  compile-files is NOT rebuilt on compile-sources (yet); they share helpers.  The byte-identical
    .spv check and the A6(A) pass guard against drift.
R8  The server is `crisp-compile --serve` (one binary to ship).  The dispatch is a 2-line edit to
    `main` IN src/main.lisp, not an override: a later (defun main) in api.lisp put a "redefining
    CRISP.MAIN:MAIN" WARNING into the build, crisp.main has no overlay, and muffling warnings for
    all of api.lisp would hide real ones.
R9  Protocol: one framing both ways, `<tag> <len>\n<bytes>\n`; a hello record with a protocol
    version on start.  Binary-safe; unknown response tags are skipped by the client (a newer server
    can add fields).  A malformed request ends the server (stream out of sync); the client kills it.
R10 A slot's pointer-ness comes from the parameter roles, not the target's .metacrisp (PTX writes
    ULONG for a pointer).
R11 crisp_set_flags only copies; the SERVER validates flags at compile time, so the flag list lives
    in one place (Lisp).  Header comment updated.
R12 Finding the compiler: $CRISP_COMPILE_EXE, else $CRISP_HOME/bin/, else next to the library.  The
    helper's working directory = the exe's directory's parent (today's bin/ layout, no compiler
    change).  So the install is <root>/bin/{crisp-compile, LLVM-C.dll, llvm tools, crisp.dll}.
R13 Helpers live in an idle POOL shared by all contexts (max 4 idle).  A compile takes one or starts
    one (outside the lock), gives it back if healthy; a broken one is killed, never reused.
R14 Linux: a socketpair, not pipes, so send(MSG_NOSIGNAL) cannot raise SIGPIPE in the caller.  Both
    platforms: the helper's stderr goes to the null device (a pipe nobody drains could block it).
R15 The C client builds results as plain arrays; returned strings are the payload buffers
    themselves (already NUL-terminated), so a module binary is NUL-terminated for free.
R16 Python suite uses stdlib unittest + ctypes only (no pytest dependency).
R17 `--hoist-kernel=source` plumbing: crisp-compile's main strips the flag and hands the hoister
    `--hoist-kernel=source --kernel-source=<abs path>... --kernel-flag=<flag>...` (invoke-hoister
    appends *hoister-extra-args*).  The forwarded flags are the invocation's own minus
    --hoist*/--metadata/--ir-target=/--log-level= (the API refuses those).  Nothing is added to
    the .metacrisp.
R18 Only the L0 hoister has a source mode; `--hoist-kernel=source` without --hoist=l0 is an error.
    Foreign .bc libraries cannot be embedded -> error.
R19 The launcher's slot map: the hoister emits the ordinary launcher, then rewrites every
    `zeKernelSetArgumentValue(kernel, N,` to `crisp_slot[N]` (all 48 emit sites share that exact
    spelling), and crisp_slot[] is filled at run time from crisp_param_slot for every DECLARED
    param's slot.  Implicit params (scratch, debug log, tensor maps) stay identity until the API
    describes them (crisp.h PLANNED).  The launcher also checks crisp_slot_count, prints a NOTE if
    the API moves a slot, and fails if the API has no slot for one.
R20 I edited src/hoist-l0/main.lisp and src/main.lisp DIRECTLY (additive: new functions + small
    dispatch edits), not via overlays/hoist-l0/ -- I only found that overlay directory afterwards.
    The runner changes DID go to overlays/spec-runner-overlay.lisp (script-extracted copies of
    run-spec-with-hoist and validate-l0-host-run, then edited).  Happy to move the hoister ones.
R21 Runner: per-spec directive `HOIST-KERNEL: source|file`, plus a runner option
    `--hoist-kernel=source` that puts EVERY L0 hoist spec through the API (the A6(A) pass); a spec
    saying `file` opts out.  A compile-API launcher is linked with -I c-api/include + the import
    library, and run with bin/ on PATH.
R22 tests/ci-stop.txt bumped to 190-compile-api now (your done-list item): the runner would not
    see the 190 specs otherwise.  On CI the L0 metal specs skip (no Intel GPU), so CI runs the
    unit spec and the default/--debug/--single-pass/--differentiate compiles of 01/02.
R23 The C library is built by build/build-c-api.lisp, which build/build.lisp now runs: $CC, else
    gcc, else clang; NO compiler -> warning + skip (the compiler itself does not need it).
    c-api/build.sh just calls it.  On Windows a running launcher locks bin/crisp.dll, so a
    rebuild during a hoist run can fail (seen once tonight; harmless, retry).
R24 The A6(A) pass (runner --hoist-kernel=source) applies source mode only where it means
    something: specs whose TEST-HOIST[L0] validator RUNS the launcher (validate-l0-host-run /
    validate-l0-mma-run) and that link no FFI .bc.  Text-inspecting validators keep file mode.
    A HOIST-KERNEL directive still overrides.  Launchers get PATH via an explicit :environment
    (sb-ext:run-program); the runner never setenv's.
NOTE The --differentiate pass SKIPS hoists, so A6(A)'s "forward + grad at run time" cannot come
    through TEST-HOIST; it needs VERIFY-AUTODIFF to use the API.  Open.

Layout: the C side lives in ./c-api/ (c-api/include/crisp.h, c-api/src/...).  src/ stays Lisp.

Don't forget (definition of done)
- docs/ideal_001.md "In-Memory Compilation API" rewritten to match the API we ACTUALLY expose
  (and the tree-shaking material removed, see S1).
- TDD: specs in tests/spec/190-compile-api/ first, B1 .unit.lisp, B2 tests/api/.
- Bump tests/ci-stop.txt to 190-compile-api.
