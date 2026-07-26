# Segmented Reduction 📝


With the common use of prefix-sum scans, GPU programmers often find themselves using "segment maps".
These are very common for "ragged edged" data.  Essentially, you have a source vector of data
accompanied by a vector of flags, where "1" means start a segment, and "0" continue the segment.

`segmented-reduction` will perform a reduction on each segment, storing the result in a result vector.

In addition to the source data and the flags, this algorithm also needs an `incl-scan` variable which
is an inclusive scan of the flags.  The inclusive scan will be the indeces of the segment vec were it using
1 based counting. But since this isn't Visual Basic, we'll subtract one to make it match our 0 based counting.

Note that the output `segment-vec` is also expected to be the correct length, so yet another preperatory step
will be to reduce the `flags-vec` to count them. 

```
source-vec  #( 3  1  5  2  8  4  7  9)
flags-vec   #( 1  0  0  1  0  1  0  0) <- '1' marks the start of each segment
incl-scan   #( 1  1  1  2  2  3  3  3) <-- inclusive-scan of flags-vec produces this.
segment-vec #( 9        10    20)      <-- final output
```

| Data:     | `[3,`     | `1,` | `5,` | `2,`    | `8,` | `4,`      | `7,` | `9]` |
| :---      | :---      | :--- | :--- | :---    | :--- | :---      | :--- | :--- |
| Flags:    | `[1,`     | `0,` | `0,` | `1,`    | `0,` | `1,`      | `0,` | `0]` |
| incl-scan:| `1`       | `1`  | `1`  | `2`     | `2`  | `3`       | `3`  | `3`  |
| Segments: | `(3+1+5)` |      |      | `(2+8)` |      | `(4+7+9)` |      |      |
| Goal:     | `[9,`     |      |      | `10,`   |      | `20]`     |      |      |


```
;; -- segmented-reduction
(<T A>
  (def-grid-function segmented-reduction (source-vec flags-vec incl-scan someFunction identity &out segments-vec)
    (declare #'((in-vec T A) (in-vec uint A) (in-vec uint A) (binop-type T) T &out (out-vec T A))
      (global-size :derive-from source-vec :strategy :strided))
    (loop-vector-stride source-vec (i)
      (let ((val (~ source-vec i))
            (segment-id (1- (~ incl-scan i))))
        ;; each thread just atomically modifies its index in segments-vec
        (atomic-binop! (~ segments-vec segment-id) someFunction val))))) 
```





