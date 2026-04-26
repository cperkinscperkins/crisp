## Matrices


`(def-type matrix (tensor T 2))`

Matrices are simply 2D tensor views. The type alias `matrix` is defined to make coding easier, but any 2D `tensor` can automatically be considered a matrix. It is not a "derived" type.


Additionally, there are special functions specifically for matrices.

### col

`(col x:ulong A:matrix) => 1D tensor`

Given an index `x` and a 2D `tensor` matrix `A`   this returns a 1D `tensor` of that column of the matrix.

Note that the `tensor` (aka `vector`) that is returned will have `:align :strided`, regardless of the original `:align` of the matrix. 

### row

`(row y:ulong A:matrix) => 1D tensor` 

Given an index `y` and a 2D `tensor` matrix `A`   this returns a 1D `tensor` of that row of the matrix.

Note that the `tensor` (aka `vector`) that is returned will have `:align :strided`, regardless of the original `:align` of the matrix. 

### num-cols / num-rows

`(num-cols A:matrix) => ulong`
`(num-rows A:matrix) => ulong`

These utility functions return the number of columns or rows of the matrix.

### get-layout
```
(get-layout M:matrix) => :row-major or :col-major or :other-layout
```

`get-layout` analyses the strides of some 2D matrix and returns a value from the
`matrix-layout` enumeration. This can be `:row-major`, `:col-major` or `:other-layout`

### transpose

```
(transpose M) ; returns a new tensor, leaving M alone.
(transpose! M) ; M is transposed, strides updated in place
```

The `transpose` operations swap the logical "shape" of the matrix. For example, starting with a 3x4 matrix
and ending with a 4x3 matrix. This is done simply by updating the strides. It is instant and zero cost.

Note that the while data is not moved it does mean that a "row major" matrix will now be "col major", and vice versa.

The matrix returned by `transpose` will always be `:align :strided` , regardless of the original matrix argument `:align`.

#### transpose! notes

`transpose!` mutates the matrix in place. This can only work for matrices that are `:align :strided`. 
Attempting to call `transpose!` on a matrix with any other `:align` is a compiliation error.

AlsoNote also, that due to the way Storage Handles wrap data, that `transpose!` will only effect the matrix in the scope of the function that is making the call (and any children it passes the matrix to after). 
It does NOT change the transposition of the matrix by the caller. 

> Implementation Note: consider dropping transpose!

#### understanding transposition
Here is a quick example with a 2x3 matrix:
```
        Col 0   Col 1   Col 2
       +-------+-------+-------+
Row 0  |   1   |   2   |   3   |
       +-------+-------+-------+
Row 1  |   4   |   5   |   6   |
       +-------+-------+-------+

Transposed:
        Col 0   Col 1
       +-------+-------+
Row 0  |   1   |   4   |
       +-------+-------+
Row 1  |   2   |   5   |
       +-------+-------+
Row 2  |   3   |   6   |
       +-------+-------+
```

Remember, NO DATA IS MOVED.

Possible Implemenation
```
;; -- transpose! --
(def-function transpose! (M)
  (declare #((matrix) => nil))

  (let ((dims-vec (dims~ M))
        (strides-vec (strides~ M)))
        (temp-dim0 (~ dims-vec 0))
        (temp-stride0 (~ strides-vec 0))
    ;; Swap the dimensions: (num_rows, num_cols) -> (num_cols, num_rows)
    (set! (~ dims-vec 0) (~ dims-vec 1))
    (set! (~ dims-vec 1) temp-dim0)

    ;; Swap the strides: (row_stride, col_stride) -> (col_stride, row_stride)
    (set! (~ strides-vec 0) (~ strides-vec 1))
    (set! (~ strides-vec 1) temp-stride0)))

```

### load-tile / store-tile

```
(load-tile source-M dest-tile tile-y tile-x &key transpose)
(store-tile source-tile dest-M tile-y tile-x &key transpose)
```
When working with matrices, we often want coalesced memory access, but that is limited
to the `:row-major` / `:col-major` choice.  For this reason, a very common
usage pattern when working with matrices is to use local memory tiles.
These are typically `32x32` (ie `(get-warp-size)` squared ).

The `load-tile` and `store-tile` macros can help with that. They presume the kernel
has been enqueued with 2D arity and just use the local-id x and y for the target IN the tile.  

The tile will simply lift the data right out of the source-M, whether it is
`:col-major` or `:row-major`, and so have the same layout, just smaller.  

But the `:transpose` argument can be used to change that. If `true` then
the `x` and `y` coordinates will be swapped. 

Remember dest-tile should be `:local` memory.

Here are possible implementations
```
;; -- load-tile --
(defmacro load-tile (source-M dest-tile tile-y tile-x &key transpose)
  `(let ((tile-dim (num-cols ,dest-tile))
         (local-id-x (get-local-id 0))
         (local-id-y (get-local-id 1)))

     ;; Calculate Source Coords for a COALESCED READ 
     ;; This pattern is always the same: threads in a warp read adjacent columns.
     (let ((source-x (+ (* ,tile-x tile-dim) local-id-x))
           (source-y (+ (* ,tile-y tile-dim) local-id-y)))

       ;; Read from Global Memory
       (when (and (< source-y (num-rows ,source-M)) (< source-x (num-cols ,source-M)))
         (let ((val (~ ,source-M source-y source-x)))

           ;; Write to Local Memory (Transposed or Direct)
           (if ,transpose
               ;; If transposing, write to the swapped local coordinates.
               (set! (~ ,dest-tile local-id-x local-id-y) val)
               ;; Otherwise, do a direct copy.
               (set! (~ ,dest-tile local-id-y local-id-x) val)))))))
```



### convert-layout

```
(convert-layout source-M dest-M choice) ; conversion is loaded into dest-M, leaving source-M alone

```
Crisp provides a layout conversion routine which can be used to convert a matrix into a specific layout choice.
If you are having to do this a lot, then some suboptimal decisions might have been made and should
be revisited. But, we live in the real world where we often have to deal with things as they are, and 
not necessarily like we want them to be.  

```
;; this routine assumes a 2D global_work_size

;; helpers (not fully defined yet)
;; (make-tile-scratch-vector T)
;; (make-tile dim T)

(def-const TILE_DIM:ulong (get-warp-size))

;; -- convert-layout --
(def-function convert-layout (source-M dest-M choice &optional (scratch (make-scratch-matrix (element-type~ source-M) :match-warp-tile)))
  ;; scratch is usuallly 32x32 (TILE_DIM x TILE_DIM)
  (declare #(matrix matrix matrix-layout &optional (vector (element-type~ source-M)) => nil)
            (global-size :strategy :strided))
  (c-t-assert (!= choice :other-layout) "dude")
  (r-t-assert-0 (!= choice :other-layout) "??")

  (unless (= (get-layout source-M) choice)
    (let ((temp-tile scratch))

      ;; This loop makes each workgroup process multiple tiles.
      (thread-stride M '(TILE_DIM TILE_DIM) (tile-idx-y tile-idx-x) 

        ;; load tile  - coalesced read
        (load-tile M temp-tile tile-idx-y tile-idx-x :transpose (= (get-layout M) :col-major))
        
        (local-barrier)

        ;; store transposed tile coalesced write
        (store-tile temp-tile dest-M tile-idx-y tile-idx-x :transpose (= (get-layout dest-M) :row-major))))))
```



