## Tensors & Matrices


Tensors were introduced earlier in the [Storage Handle Types](#storage-handle-types) section.
That section covers how to declare a `tensor-type` or `matrix-type`, how to access elements, using scratch memory and more.

In this section we want to cover a few more details about tensors and matrices. 

In Crisp a `vector` is always a one dimensional contiguous blocks of memory.  
Tensors are represented by  `tensor` which is similar to a `vector` except 
that it has adjustable strides.

Tensors can have their exact size determined at runtime, but the number of their dimensions (eg. 2D matrix versus 4D hypercube )
must be known at compile time.

In Crisp, a 1D `tensor` can be used nearly anywhere a `vector` can be used.




In the example below, let's look at a 3x4 matrix `A`, with elements labeled 
`A[row][column]` (C++ notation) or `(~ A row column)` (Crisp notation)

<details>
<summary>C++ notation</summary>
<pre>
```
         Col 0     Col 1     Col 2     Col 3
       +---------+---------+---------+---------+
Row 0  | A[0][0] | A[0][1] | A[0][2] | A[0][3] |
       +---------+---------+---------+---------+
Row 1  | A[1][0] | A[1][1] | A[1][2] | A[1][3] |
       +---------+---------+---------+---------+
Row 2  | A[2][0] | A[2][1] | A[2][2] | A[2][3] |
       +---------+---------+---------+---------+
```
</pre>
</details>

<details open>
<summary>Crisp notation</summary>
<pre>
```
        Col 0       Col 1       Col 2       Col 3
       +-----------+-----------+-----------+-----------+
Row 0  | (~ A 0 0) | (~ A 0 1) | (~ A 0 2) | (~ A 0 3) |
       +-----------+-----------+-----------+-----------+
Row 1  | (~ A 1 0) | (~ A 1 1) | (~ A 1 2) | (~ A 1 3) |
       +-----------+-----------+-----------+-----------+
Row 2  | (~ A 2 0) | (~ A 2 1) | (~ A 2 2) | (~ A 2 3) |
       +-----------+-----------+-----------+-----------+
```
</pre>
</details>

Next, here is two different ways this matrix could be created.
In both methods, the coordinates above are exactly the same.
```
;; Create a row-major view of a 3x4 matrix
(make-matrix my-data-vec int 3 4 :strides #(4 1) )

;; Create a column-major view of a 3x4 matrix
(make-matrix my-data-vec int 3 4 :strides #(1 3) )
```

But, when laid out linearly, these two tensors are not the same. 
The first four entries of the data vector behind the row-major
matrix would contain the four elements of `Row 0`. 
But, for the col-major matrix, the first four elements of the data 
vector would contain the three elements of `Col 0`, plus the first 
element of `Col 1`.

Due to memory coalescing, multiplying a row-major matrix by a col-major matrix is
the MOST PERFORMANT choice. 

Lastly, the variants of these declarations that support `strideVec` should be used carefully. It's 
generally far simpler to use one of the other versions and let Crisp set up the stride vector for you.





### Overloading Element Access

It is uwise to overload `~` for all tensors. Use `def-derived-type` when overloading.

```
;; source vector is floats ranged 0-1
(def-derived-type normalized-tv (tensor 1 (vector-type :element-type float)))

;; we return int values between 0-100
;;; ~
(def-function ~ (tensor index)
  (declare #(normalized-tv ulong => int))
  (round (* (~ tensor index) 100)))

;; and store those ints back to floats
;;; ~  (setter)
(def-setter ~ ((tensor index) val)
  (declare #(normalized-tv ulong int => nil))
  (set! (~ tensor index) (/ val 100.0)))

```


### Mutable Strides ?

The strides are mutable. Normally this is done (safely and correctly) by functions like `transpose` but 
despite the horrible problems that might occur if done incorrect, we are making it available to you.

```
(set! (strides~ someTensorView) someOtherVec) ; will error if (length~ someOtherVec) is not equal to (num-dims someTensorView)
(set! (~ (strides~ someTensorView) 1) 8)
```

<!-- 

NOTE: removing 'identity-tensor' for now.

### identity-tensor

This is a specialization of the tensor, but is not a true tensor in that does NOT require
any vector data.  It is immutable. It is a Kronecker delta tensor. Every component is 0, except those
where all the indeces are equal, which are 1.

```
(identity-tensor-type &optional rank)
(make-identity-tensor rank)
(is-identity-tensor? someTensorView) ;; can be called on any tensor
```

-->

