# `&out` and differentiation


Crisp's auto-differentiation feature (`--differentiate` flag), can only differentiate kernels
that use clear "input" and "output" parameters.  Use of `&out` is required, and the non-out paramters
must be read-only.

