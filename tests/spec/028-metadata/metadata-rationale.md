Metadata
========

- two flags trigger metadata generation:
    - `--metadata`  (user wants the metadata files)
    - `--hoist` (user wants .cpp/.py files, metadata is likely in /tmp)

- at this time we are only worried about the `--metadata` flag.
- a metadata file is a `.metacrisp` file.
- its format is documented in `crisp/plan/ref.metacrisp`
- When hoisting (ie generating .cpp or .py files that read in and enqueue the kernels in question), the metadata file is the sole input to the hoist component.
- besides type definitions, structs and kernel info, a metadata file includes the def-orchestration.
- at this stage (028-metadata) we are ONLY worried about the .metacrisp file and only about the type definitions, structs and kernel info. No orchestration has to be included at this time.
- we may need to expand the test system have `<colon> <validator>` following the `;; TEST-WITH[--metadata]` directives.  (ie `;; TEST-WITH[--metadata] : #'validate-metadata-def-type` or possibly `;; TEST-WITH[--metadata] : validate-metadata-def-type.lisp`)