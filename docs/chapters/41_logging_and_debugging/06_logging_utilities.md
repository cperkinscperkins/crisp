# Logging Utilities 📝


- `(line)`  evaluates at compile-time to the line number of the file where it appears.
- `(file)`  evaluates at compile-time to the name of the .crisp file where it appears.
- `(is-logging?)` is true at compile time under `--logging-output`.
- `(is-runtime-checking?)` is true at compile time under `--runtime-checks` (and therefore also
  under `--logging-output`).

Every message and every die record already carries its site, so `(line)` and `(file)` are mostly
for writing macros.


