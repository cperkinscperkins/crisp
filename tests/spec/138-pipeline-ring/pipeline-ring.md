We've been working our way through the MMA "Chapter" in .\docs\topology.md . Note in the last endeavor we had to pivot a bit to do the whole async tile loading NVidia only, and we'll come back around for Intel.  We updated topology.md with the updated APIs and description.

Now we are on to Chapter 2: pipelining the async loads via rings (make-async-barrier-ring and make-scratch-matrix-ring, and others).

This is covered in topology.md

For this endeavor we'll likely

[ ] write TDD tests and implement make-async-barrier-ring
[ ] write TDD tests and implement the make-scratch-XXXX-ring variants for the Storage Handles.
[ ] make a test that roughly matches the "Chapter 2" MMA code and make sure that it works.
[ ] add a benchmark.

Presumably we'll need an H100 or equivalent at some point. Let me know when. They are a lot more expensive to rent  than the consumer grade GPUs, so let's try to keep that time focused.

Also, just a minor thing, the run-on-pod.sh script runs fine, but it doesn't seem to present a summary of all the test results at the end anymore. It just outputs each test pass individually, which makes an early failure much harder to find. We should likely fix that too.

