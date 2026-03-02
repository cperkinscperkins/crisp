## Compiler Invocations and Files

Each target (for example .spv) has one file output per orchestration. Loose kernels that
are not named in an orchestration are also output, one target file apiece. 

### `--merge` and `--split`
The `--merge` flag can be used to ensure all the kernels are output into one file for any given target type (like all the kernels in one .spv or one .ptx).
Contrarily, the `--split` flag ensures each kernel gets its won individuaul target file and is 
not joined with any other, regardless of any `def-orchestration`.
It is an error to use both these flags together.

Also note that the metadata and hoisting output is always output per-orchestration. They are unaffected by either flag. 



