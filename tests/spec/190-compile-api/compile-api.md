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
R5  Tensor layout is REPORTED (crisp_param_layout): the :align the kernel's author declared.  No
    compiler behaviour changed -- :compact keeps its fast path (extents only, no offset/stride
    reads), so its caller must pass contiguous data; a :strided kernel takes a PyTorch view's
    strides and offset uncopied.  The author chooses; the API just stops the caller guessing
    (passing a view to a :compact kernel would otherwise be silently wrong).  Not in A3's original
    list; added because PyTorch-style callers hit it at once.  (Wording clarified 2026-10-20 with
    Chris.)
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

Item 2: implicit parameters + launch geometry (PROPOSAL, 2026-10-20 -- for discussion)
=====================================================================================
Survey (the L0 hoister is the inventory; it handles every case today):
- Implicit params arrive in the metacrisp's :implicit-params, interleaved by :range with the
  declared ones.  Scratch cells / tensors, :local or :global, sized by :size-expr = an integer, a
  list of per-axis integers, or a SYMBOL: :match-workgroup-size (one element per thread),
  :match-num-warps-per-workgroup (ceil(wg / warp)), :match-num-workgroups (GLOBAL only, one per
  group -- needs the group count first: hoister ~L1719 "deferred").  Also a debug log, and (CUDA)
  :kind :tensor-map descriptors.
- Workgroup-LOCAL memory binds differently per runtime: L0 passes each local param as its pointer
  slot with (size = bytes, value = nullptr); CUDA carves ALL local scratch out of one dynamic
  shared block (sharedMemBytes) at byte offsets (hoist-cuda ~L440-L860).
- Global scratch is zero-filled ahead of the launch.  CONTRADICTION to settle: ideal_001.md L6597
  says an implicit :atomic-counter needs zeroing before the FIRST launch only; BUG 084 (memory
  vad-global-scratch-and-stale-scratch) found grid-reduce-last-man's counter stateful across
  launches -- VAD only worked once it re-zeroed per launch.
- Geometry = (global-size | local-size | num-groups) declarations: :set-to N, or :derive-from a
  tensor (its length/extents) or scalar params, with :strategy :one-thread-per | :exact | :strided
  | :interleaved, optionally :tile-shape (rank-N tile grid) and :occupancy.  :strided needs device
  facts (L0: numSlices x subslices x EUs x threads; CUDA: the occupancy API).  Today the hoisters
  turn these into C++ at hoist time.

Proposal:
P1  Implicit params JOIN the parameter list (crisp_param_count counts them; crisp_param_slot works
    on them unchanged), told apart by crisp_param_purpose: DECLARED | SCRATCH | DEBUG_LOG |
    TENSOR_MAP.  The last two: reported, not yet supported (a caller can refuse cleanly).
P2  A LAUNCH object, evaluated inside libcrisp (C) -- no server round trip at launch time:
      crisp_launch_create(ctx, m, k, &L)
      crisp_launch_set_extent(L, param, axis, n)      crisp_launch_set_scalar(L, param, value)
      crisp_launch_set_device(L, compute_units, threads_per_unit, simd_width)  (defaults: the
                                                       compile's --hardware-profile, if any)
      crisp_launch_compute(L) -> status + diagnostic naming any missing input
      crisp_launch_local_size(L, axis)   crisp_launch_group_count(L, axis)
      crisp_launch_param_bytes(L, p)     -- a scratch param's allocation, symbolic sizes resolved
      crisp_launch_shared_bytes(L)       -- PTX: the dynamic shared block; SPV: 0
      crisp_launch_param_zero(L, p)      -- NEVER | BEFORE_FIRST_LAUNCH | BEFORE_EVERY_LAUNCH
    The server sends the declarations normalised; libcrisp holds a C port of the strategies.
P3  Per-runtime binding stated by the API, not guessed: SPV local scratch = (bytes, NULL) in its
    pointer slot; PTX local scratch = its offset into the shared block (to confirm against
    hoist-cuda).
P4  Verification: the dogfood launcher takes geometry + scratch sizes from the launch object, so
    the whole-suite --hoist-kernel=source pass checks libcrisp's port of the strategies on metal
    against unchanged expectations -- the 69 partially-mapped launchers become fully mapped.
P5  Scope: SPV/L0 first (verifiable on the BMG); PTX semantics next (needs a pod to verify on
    metal); tensor maps + debug log deferred.

Questions for Chris:
Q9   One parameter list with a purpose, or a separate implicit list?
A9:  One list, with a purpose (2026-10-20).
Q10  Geometry evaluated in libcrisp (a THIRD home for the strategy semantics, after the two
     hoisters), or expose the raw declarations and let callers evaluate?  (Recommend libcrisp; the
     dogfood pass guards it, and the hoisters could later lean on it.)
A10: (a) -- the API does the arithmetic (2026-10-20): the caller supplies launch-time values
     (tensor extents, scalars), the launch object returns the numbers.  A kernel with no geometry
     declarations is reported as such; the caller chooses.
Q11  The zeroing contract: first launch only, or every launch?  (Safe default: every launch.)
A11: Every launch (2026-10-20).  ideal_001.md L6597's "first launch only" is likely a leftover of
     the tree-shaking era; fix the doc when this lands.
Q12  :strided on CUDA uses cuOccupancyMaxActiveBlocksPerMultiprocessor -- needs the CUDA runtime.
     Have the caller pass the occupancy in, or let PTX callers compute group counts themselves?
A12: The caller passes it in, the same on both runtimes (2026-10-20):
     crisp_launch_set_resident_groups(L, n).  CUDA: n = cuOccupancyMaxActiveBlocksPerMultiprocessor
     (using crisp_launch_shared_bytes) x SM count.  L0: from device properties, as the hoister does.
     Unset: the compile's hardware profile if any, else :strided reports the missing input.
Order: (1) implicit params in the list, (2) the launch object for SPV/L0 + the dogfood launcher on
it, (3) the whole-suite pass on the BMG.

2026-10-20  Step 1 DONE.  Implicit params join the list in slot order with :purpose (declared /
            scratch / debug-log / tensor-map), :zero-before-launch (global scratch, A11) and a
            :size rule ((:elements N ...) or (:rule :match-...)) kept for the launch object.  Rank,
            element type and :align come from the TYPE FORM for scratch (no :rank key).  Header:
            crisp_purpose, crisp_param_purpose, crisp_param_zero_before_launch; API minor -> 2.
            Bug found + fixed: the private metacrisp-reading package read `nil` as ITS OWN symbol
            (true!) -- it now imports CL:NIL / CL:T.  Only the new :size-expr nil exposed it.
            Unit spec 149/149, Python 26/26, Linux build clean.  On the BMG in source mode the
            scratch launchers are now FULLY mapped (grid-reduce 24 of 24, last-man 21 of 21,
            reduce-workgroup 12 of 12; were "6 of 24" etc.) and pass.
2026-10-21  Step 2: the LAUNCH OBJECT (A10/A12).  crisp_launch_* in crisp.h (API minor -> 3); a C
            port of the L0 hoister's dispatch rules in c-api/src/crisp.c (tile grid incl. device
            limits -- clamp under :strided, error under :exact; :strided via caller-supplied resident
            groups x :occupancy; :interleaved / undeclared -> 1x1x1; :exact / :one-thread-per /
            :set-to / scalar :derive-from; scratch bytes incl. per-warp and per-workgroup rules).
            Geometry travels from the .metacrisp (so a compiler-INFERRED :tile-shape is seen).
            Lisp: %api-geometry; unit spec 169/169.  Python: 11 launch tests on the 089-strategy
            kernels + reductions, 37/37.
            Dogfood: source-mode launchers now route every argument through crisp_set_arg (recorded)
            and the group size through crisp_set_group_size, then -- just before the launch -- feed
            a launch object the values they ACTUALLY passed (extents, scalars, resident groups),
            CHECK local size, group counts and every scratch BYTE_SIZE against their own (any
            MISMATCH fails the run), and launch with the API's group counts.  File mode still
            byte-identical.
            Found: validate-l0-mma-run RE-hoists with --mma-test and dropped source mode, so the 27
            MMA metal specs never went through the API in the earlier A6(A) runs (the 183 count was
            honest -- counted from "compiled at run time" lines -- but excluded them).  Fixed in the
            runner overlay (%hoist-kernel-source-hoister-args); 14-pipeline-bench now runs via the
            API: tile grid 32x32 from the API, MMA_CORRECT.
            A6(A) with launch checks: Spec Summary 1500/1500.  209 launchers through the API (MMA now
            included), all slots mapped, every one ran the launch check: 0 MISMATCH (the log's 214
            "MISMATCH" hits are kernel names like STORE_MISMATCH in expected-fail backtraces; the
            baseline has 214 too), 194 scratch sizes checked, 0 compute errors.  run-ci passes,
            negative 354/354.
            HONEST COVERAGE NOTE: on metal the geometry is mostly simple -- 164 of 209 launches are
            1x1x1; the rest 4/2/128/640 groups on one axis and ONE 32x32 tile grid.  The richer
            strategy cases (2-D :exact, scalar :one-thread-per, device limits, :occupancy) are
            covered by the Python tests against the hoister's formulas, not on hardware.
2026-10-21  PTX + the PyTorch toy (all local; the pod runs them -- see the pod plan below).
            Step 1-2: the launch object's PTX rules (hoist-cuda %emit-launch-base): CUDA sizes at
            most two axes from :set-to / scalar :derive-from / scalar :exact (gridZ = 1) and has no
            :interleaved special case; thread-block CLUSTERS (pad under :strided, refuse under
            :exact or :cluster-reach); the dynamic-shared LAYOUT (local scratch tensors from 0, cells
            after round8, crisp_launch_param_shared_offset = the pointer slot's value).  API minor 4.
            Cross-checked against the CUDA hoister's own generated launcher (offsets 0/8, 12 bytes).
            Python 42/42.
            Step 3: CUDA hoister source mode (%cuda-hk-rewrite: kernelParams permuted into
            crisp_params by slot; launch check before the launch lambda, after the cluster fix-up:
            grid, block, shared bytes, scratch sizes, shared offsets).  The shared source-mode code
            moved to src/hoist/source-mode.lisp (R25) -- L0 output byte-identical after the move.
            LOCAL nvcc check (nvidia/cuda docker, put_temp_files_here/190/cuda_source_compile_check.py):
            all 132 source-mode CUDA launchers (every spec whose CUDA validator runs it, MMA re-hoists
            included) compile, as do the 132 file-mode controls; all 132 carry the launch check.
            Runner overlay: CUDA source mode (validate-cuda-host-run links libcrisp.so with an rpath;
            validate-cuda-mma-run keeps source mode).
            COMPILER BUG FOUND + FIXED (A, Chris 2026-10-21): BUG 066's inherit ran only inside the
            SPIR-V subgroup emitter, so every PTX _grad kernel had NO launch geometry.  Now in
            ensure-opencl-kernel-metadata for every backend (compiler overlay -> src/codegen.lisp).
            Measured first: PTX of all 903 --differentiate specs byte-identical; 379 _grad kernels
            gain geometry in their metadata only.  Regression check in the unit spec (181/181).
            The toy: c-api/examples/square_scale.crisp + torch_square_scale.py -- a generic launcher
            (every argument by ROLE, grid from a launch object, the gradient kernel wired by
            crisp_param_adjoint_of) inside a torch.autograd.Function, checked against PyTorch's own
            autograd at n = 1, 7, 1000, 2^20, 2^20+3.  Syntax-checked only (no torch/GPU here).
            The ctypes binding moved to c-api/python/crisp_ctypes.py (R26).
            After the compiler fix: E2E 1500/1500, negative 354/354.
            LINUX, first real run (put_temp_files_here/190/linux_api_check.sh: crisp built from this
            tree in crisp-linux-release, libcrisp.so built with glibc gcc in nvidia/cuda): the Python
            API suite 42/42 -- the fork/socketpair path, parallel contexts, shutdown/restart, missing
            compiler all work; 3.9 s vs ~10 s on Windows (process launch is cheap there, as S0 said).
            (The first attempt built the .so in crisp-c-validator, which is Alpine/musl -- unloadable
            on glibc.  Not a library bug, but worth knowing: build the .so where it will run.)

2026-10-22  H100 NVL run (branch in-mem-compilation-api, COMPILE_API=1).  Logs: put_temp_files_here/190/podlogs/.
            ENVIRONMENT (not 190): the pod has no llvm-spirv -> all 136 --differentiate failures are
            VERIFY-AUTODIFF falling back to a SPIR-V forward compile (no Level Zero) and dying at
            llvm-spirv (exit 127); the API suite's SPIR-V tests failed the same way.  (bugs.md
            candidate: VAD should SKIP, not compile SPIR-V, when there is no Level Zero.)
            PRE-EXISTING, file mode (5): "PTX JIT compilation failed" for 122/07-ffi-libdevice,
            128/13-sin-ptx-metal, 128/14-sin-fast-ptx-metal, 170/43-approx-metal-cuda; and
            154/03-wgmma-two-warpgroups MMA mismatch.  190 does not touch forward-kernel code.
            REAL, caught by the launch check (22 source-mode failures) -- fixed locally:
              - scratch CELL byte size "API 4, launcher 0": the PTX .metacrisp types a scratch cell's
                slots (ULONG VOIDP ULONG) though they are pointer/bytes/offset; the API sized VOIDP 0
                so the check read 0 bytes.  Fix: non-pointer cell/tensor slots are ulong BY ROLE.
              - "no slot for hoisted argument" (11): (a) TMA descriptors -- the HOISTER treated the
                :rank-carrying tensor-map entry as a tensor; it is one slot (:range (0 0)) typed
                (TENSOR-MAP A).  (b) parameterised records/structs (v-point :earnestness 3.0) were not
                recognised as records by the API; record slot types are aliases (FFF).  (c) by-value
                structs / fixed arrays had slot size 0 -> new CRISP_TYPE_AGGREGATE sized by C layout
                (R27; API minor 5).
              Offline check that now catches both classes WITHOUT a GPU:
              put_temp_files_here/190/slotmap_check.py (every launcher's slot map vs the API).
            THE TOY found a COMPILER BUG (not API): def-binary-op-analyzer (src/analysis/ops.lisp:8)
            builds + - * / from (second expr) (third expr) and SILENTLY DROPS further operands, so
            (* x x w) compiled as (* x x).  Confirmed in LLVM IR for float and int, * and +.  Fix
            needs Chris: n-ary (left fold) or an error.
2026-10-22  BUG 127 FIXED (Chris: Common Lisp's table; min/max too -- #'min stays a binary binop, since
            %175-apply-binop always applies it to exactly two).  The analyzer folds + - * / min max and
            chains < <= > >= =; refuses (/ x), (+), an n-ary !=, (max x), and wrong arity for the math
            operators (src/analysis/ops.lisp -- MACROS, so edited in src: R28).  AD reads source, so
            anf-transform normalises n-ary calls first (%nary-normalize, rebuilding only what changed --
            a full rebuild broke EQ-keyed passes).  Specs: 03-nary-operators-metal (BMG: every value
            right), 04-nary-product-ad (VERIFY-AUTODIFF on L0: analytical 12 = numerical 12; it was 3),
            errors/01-06 (negative 360/360).  03 SKIP-WITH[--differentiate]: AD has no min/max rule
            (BUG 132, pre-existing).  bugs.md: 127 (fixed), 128 VAD compiles SPIR-V with no Level Zero,
            129 PTX metacrisp scratch-cell slot types, 130 SUSPECT cluster `return;` in int main,
            131 the CLI fast/preserve warning, 132 no AD rule for min/max.

Pod plan (190) -- needs Chris: push a branch, rent the pod
==========================================================
GPU: H100 (sm_90) -- 16 CUDA hoist specs are Hopper-only and the runner does not gate by arch.
Image: a RunPod PyTorch image (torch + nvcc + gcc present; gcc builds bin/libcrisp.so).
Run ONE command:   COMPILE_API=1 ./scripts/run-on-pod.sh <host> <port> <branch>
  existing phases: specs (binary), --differentiate (incl. VERIFY-AUTODIFF[CUDA] -- regression
                   cover for the BUG 066 PTX fix), negative specs
  190 phases:      specs with --hoist-kernel=source (132 CUDA launchers through the API, each
                   checking grid / block / shared bytes / scratch / shared offsets), the C API suite
                   on Linux, the PyTorch toy (TORCH-TOY: PASS/FAIL)
What would WASTE the rental, and what was done locally to rule it out:
  - Linux build or libcrisp load failure   -> built + ran on Linux in docker: 42/42
  - generated CUDA launchers not compiling -> nvcc in docker: 132/132 source-mode compile
  - no torch / nvcc on the pod             -> use the PyTorch image
  - a non-Hopper GPU                       -> 16 sm_90 specs fail in BOTH modes (noise, not API)
NOT a waste: a launch-check MISMATCH or a toy FAIL -- that is what the run is for.

Rerun (after the H100 fixes + BUG 127), SHORT:
  ONLY_COMPILE_API=1 COMPILE_API=1 ./scripts/run-on-pod.sh <host> <port> in-mem-compilation-api ~/.ssh/id_ed25519
  (skips specs / --differentiate / negative -- nothing new there, and --differentiate cannot run on a
  CUDA-only pod: BUG 128).  Expect: the source-mode pass green except the 5 PRE-EXISTING file-mode
  failures (BUG 089's four PTX JIT failures + 154/03 wgmma two-warpgroups), which fail in both modes;
  the API suite 12 run / 31 skipped (no SPIR-V tools on the pod -- skipped, not failed); TORCH-TOY: PASS.
  Locally verified first: all 132 CUDA source-mode launchers compile with nvcc AND their slot maps agree
  with the API (slotmap_check.py: 132/132); E2E 1508/1508, negative 360/360, unit, API 43/43.

  RESULT 2026-10-22 (put_temp_files_here/190/pod-run2.log): API suite 43 ran, 12 ok / 31 skipped;
  TORCH-TOY: PASS (exact match to torch at n = 1, 7, 1000, 2^20, 2^20+3).  Source-mode pass 1502/1508:
  the 5 expected + 060-array/16-hoist-record-with-array, a segfault (exit 11) -- it had crashed in run 1
  too, and I missed it in the 22.  That is BUG 133: a def-record's array member is ONE slot in the
  metacrisp but N kernel parameters, so the launcher's crisp_slot[] (sized from the metacrisp) was
  indexed past its end.  The BMG never ran it in source mode: its `TEST-HOIST[L0] :` (space before
  the colon) slipped past %hoist-runs-launcher-p, as did 16 other launcher-running specs -- the L0
  "1500/1500" pass was missing them; fixed.  slotmap_check could not catch it -- the
  launcher and the API both read the same wrong metacrisp, so they agreed.  The lesson: check the slot
  map against the KERNEL's own parameter list, which is what the new hoist-time guard does.
  FIXED (R29 below); needs the H100 again only to see 060/16 run.

  R29 (2026-10-22, agreed with Chris): fix %enumerate-physical-types to split record array members
  (overlay; fold to src/metadata-val.lisp) -- and, found while fixing it, a BARE array parameter too
  (get-physical-width / generate-physical-signature, overlay; fold to src/metadata.lisp; API + hoister
  roles FIELD 0..N-1) -- and make source-mode launchers refuse at hoist time when
  their argument count disagrees with the metacrisp (%hk-check-argument-count, src/hoist/source-mode.lisp).
  CRISP_TYPE_AGGREGATE stays: a def-struct by value really is one aggregate parameter (probe: PTX
  .param .align 4 .b8 k_sa_param_0[16]); only the record-with-array test case was wrong.

  FOLD (2026-10-22, at Chris's request): both overlays emptied into src/ by a script (verbatim copies,
  last copy of a duplicate wins -- %hoist-runs-launcher-p had two): crisp-compiler-overlay ->
  src/codegen.lisp (BUG 066 inherit), src/metadata-val.lisp + src/metadata.lisp (BUG 133);
  spec-runner-overlay -> tests/run-specs.lisp (11 functions).  Script + pre-fold backups:
  put_temp_files_here/190/fold/.

Layout: the C side lives in ./c-api/ (c-api/include/crisp.h, c-api/src/...).  src/ stays Lisp.

Don't forget (definition of done)
- docs/ideal_001.md "In-Memory Compilation API" rewritten to match the API we ACTUALLY expose
  (and the tree-shaking material removed, see S1).
- TDD: specs in tests/spec/190-compile-api/ first, B1 .unit.lisp, B2 tests/api/.
- Bump tests/ci-stop.txt to 190-compile-api.
