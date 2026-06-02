

Definition of Done
=================

For any new feature, or refactoring, be sure to go through this checklist. 


- [ ] Does the feature have (or need) a unit test?  (crisp/tests/all-tests.lisp)
- [ ] E2E spec test ? ( crisp/tests/spec/XXX/YY )
- - [ ] --debug
- - [ ] --single-pass
- - [ ] crisp/tests/run-all-tests.bat
- - [ ] crisp/.github/workflows/ci.yml has E2E for CI
- - [ ] sbcl --script ./tests/run-specs.lisp
- [ ] Negative test ( crisp/tests/spec/XXX/errors/YY )
- - [ ] sbcl --script ./tests/run-error-specs.lisp
- [ ] Update status emojis in crisp/docs/ideal_001.md.  Including any new errors.
- [ ] Does crisp/docs/defmacro-utils.md need updating?
- [ ] Documentation changes to crisp/docs/ideal_001.md ?
- [ ] Regenerate "chapters" with scripts/split-docs.lisp
- [ ] Regenerate reference.md with scripts/generate-reference.lisp
- [ ] Regenerate call tree scripts/call-graph.lisp
- [ ] Regenerate table of globals.  scripts/map-globals.lisp