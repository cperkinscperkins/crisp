In this next endeavor we are going to realize reductions. 

These are documented in the Crisp design doc, but I've excerpted the relative section into reductions-excerpt.md which is alongside this file.

Reductions will need significant benchmarking, which will likely need its own endeavors. Just like MMA we'll want a ladder of reduction techniques compared, plus comparisons against peers.



[ ] TDD tests
[ ] Autodifferentiaton? Discuss. Plan. Test.
[ ] tests that compose phase 1 with phase 2 . all combinations.
[ ] implement
[ ] update docs if there were API changes/casualties.  (starts near ideal_001.md line 6300)

[ ] update docs with "implemented/partial/not-implemented" emojis

Doc Update Example:
```
&key better than &optional. Spec needs updating. 
(grid-reduce-last-man! #'+ contrib 0.0 out
                             :local-scratch-vec sv
                             :global-scratch-vec gv
                             :atomic-counter ctr
                             :election-flag-cell flag)
```