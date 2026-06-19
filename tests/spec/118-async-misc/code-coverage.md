The next endeavor is to add code coverage reporting to the tests.

I am not opening a new spec directory becuase I don't think there will be a need for specific tests of this testing feature. Please let me know if this is short-sighted.

SBCL has a code-coverage ability, sb:cover , but I'm unfamiliar with how to use it.

Crisp has several tests systems and passes:
- tests/run-ci.lisp  - the unit tests
- tests/run-error-specs.lisp  - the negative tests. (ensures correct error messages appear)
- tests/run-specs.lisp - main testing harness

The spec runner supports the --differentiate and --single-pass and --debug flags. The CI runs all of these. I usually just run the main specs and --differentiate locally.

This machine has a BMG GPU so we can run the TEST-HOIST[L0] directives in the spec tests that have them.  and the scripts/run-on-pod.sh is used to run the TEST-HOIST[CUDA] directive.




 `sb-cover` is extremely invasive. It requires globally altering SBCL's optimization policies and forcing a total ASDF recompilation of the entire Crisp compiler *before* any tests run. If you try to bake this into `--coverage` flags inside `run-specs.lisp` and `run-ci.lisp`, you will end up compiling the compiler multiple times, and the coverage data won't aggregate correctly across the different test suites.

We want a single master orchestrator script (e.g., `scripts/run-coverage.lisp`) that sets the environment, compiles the instrumented compiler, runs all three of the existing test scripts in sequence to accumulate a unified coverage map, dumps the report, and then cleans up.



**Objective:** Implement code coverage reporting using `sb-cover`.

**Context:** Crisp has three primary test systems (`tests/run-ci.lisp`, `tests/run-error-specs.lisp`, `tests/run-specs.lisp`). I do not want these individual runners modified to handle coverage state.

**Architecture & Execution:**
Create a new master orchestration script at `scripts/run-coverage.lisp`. This script must perform the following exact sequence:

1. **Initialization:** Require `:sb-cover` and set the global optimization policy: `(declaim (optimize sb-cover:store-coverage-data))`.
2. **Instrumentation:** Force a clean recompilation of the entire Crisp system so the FASLs are instrumented. `(asdf:load-system :crisp :force t)`
3. **Execution (Aggregation):** Programmatically invoke the entry points or load the following test suites in sequence within the same Lisp image:
* `tests/run-ci.lisp`
* `tests/run-error-specs.lisp`
* `tests/run-specs.lisp` (Execute the main specs without any heavy metal/L0/CUDA flags to keep the coverage run purely CPU-bound and fast).


4. **Reporting:** Generate the HTML coverage report into a new, git-ignored directory: `(sb-cover:report "coverage-report/")`.
5. **Teardown:** Reset the optimization policy to `(optimize (sb-cover:store-coverage-data 0))` and force a final `(asdf:load-system :crisp :force t)` to strip the instrumentation from the local environment so subsequent normal runs are not degraded.

**Constraints:** * Do NOT create a new `spec/` directory for this feature.

* Do NOT add a `--coverage` flag to the existing test runners. The coverage script must wrap the runners, not the other way around.
* Ensure the `coverage-report/` directory is added to `.gitignore`.



While I will want to test the code coverage script here on this machine before we finish the endeavor, ultimately the script should be incorporated into the CI, which is managed by .github/workflows/ci.yml.  

As a later phase of this endeavor, we should use cl-coveralls and generate a code-coverage report at https://cperkinscperkins.github.io/crisp/coverage/

And, we should add a link to that report in the README.md


