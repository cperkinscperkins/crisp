- test with --metadata flag and ensure that tensor, matrix and various tensors are all correctly in the .metacrisp ( see 028-metadata/14-kernel-physical-signature.crisp and 16-declared-signature.crisp)
- modeling from 029-hoist-l0 tests 07-basic-cell, 08-access-modes, 09-address-space we'll need to confirm
that vectors, matrices and various tensors are all correctly represented in the .cpp and enqueued.
- need to test :align , both :compact and :std140 ( !! )
- &out copyback   

we still do not have def-orchestration so the "default" hoist behavior is still the model.

