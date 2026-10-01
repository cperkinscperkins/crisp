# outer-dimensions ✅

`(outer-dimensions A B) => M N`

Companion to `inner-dimension`: returns the two **non**-contracted extents of a matrix multiply —
`M` is `A`'s row extent and `N` is `B`'s column extent.  It returns two values, so bind it with a
multi-value `let`: `(let ((M N (outer-dimensions A B))) ...)`.  Like `inner-dimension` it is a
gradient-inert shape query, so it costs nothing under `--differentiate`.

