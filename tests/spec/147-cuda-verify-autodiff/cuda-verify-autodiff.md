As is documented in ./docs/tests.md, VERIFY-AUTODIFF is one of the spec test directives that the Crisp spec runner supports.  Unfortunately, it is limited to BMG only right now.

I'd like to get VERIFY-AUTODIFF working with CUDA / PTX.

We have several tests in the CUDA specific MMA test directories ( 136, 137, 138, 139, 140 ) that are skipping differentiation today simply because there is no way to verify the results.

Since the directive already exists and works today (on BMG), it should be straightforward to port it.

The plan I was hoping to follow

1 - write any TDD tests necessary for this feature in the 147 direcotry
2 - rent an H100 from runpod.io to test everything.
3 - implement the feature
4 - remove the SKIP-WITH[--differentiate] directive from tests that should otherwise be working and ensure they are tested.

