

Definition of Done
=================

For any new feature, or refactoring, be sure to go through this checklist. 

- [ ] Were there a series of TDD tests (xxx-01.crisp, xxx-02.crisp, etc.)?  
    If so, let's consolidate them into one or two .crisp E2E tests and delete the TDD tests.
- [ ] Does the feature have (or need) a unit test?  (crisp/tests/all-tests.lisp)
- [ ] E2E test ? ( crisp/tests/)
- - [ ] --debug
- - [ ] --single-pass
- - [ ] crisp/tests/run-all-tests.bat
- - [ ] crisp/.github/workflows/ci.yml has E2E for CI
- [ ] Negative test ( crisp/tests/errors/)
- - [ ] .github/workflows/ci.yml has negative tests for CI.
- - [ ] as does run-all-tests.bat
- [ ] Update crisp/docs/realized_001.md with description.  Including any new errors.
- [ ] Does crips/docs/defmacro-utils.md need updating?
- [ ] Documentation changes to crisp/docs/ideal_001.md ?
- [ ] Regenerate "chapters" with scripts/split-docs.lisp
- [ ] Regenerate reference.md with scripts/generate-reference.lisp