## soa-vector


`soa-vector` is a special type of vector, with a special memory layout. They are used for vectors of structs (only).

`soa-vector` are templated over `S` where `S` is some struct type. But rather than a contiguous block of 
memmory consisting of repeating structs, `soa-vector`s are "Structs of Arrays". 

For example, using our `point` type from before, `(vector point :length 4)` would layout in memory
like this:
`|x0|y0|x1|y1|x2|y2|x3|y3|`.
Or in C++ we can think of it like this:
```
struct Point { float x, y; };
Point points[4];
```


But a `(soa-vector  point :lenth 4)` lays out like this:
`|x0|x1|x2|x3|y0|y1|y2|y3|`.
In C++ with can think of it like this:
```
struct Points {
    float x[4];
    float y[4];
};
```



### Alignment & Layout
Crisp supports three alignment schemes for `soa-vector`: `:compact`, `:compact-offset` and `:strided`.

`:compact` means the `soa-vector` is a primary allocation. The base pointer is 16-byte aligned. The internal arrays are perfectly contiguous and concatenated back-to-back. The compiler will only insert padding between the arrays if required to satisfy the natural alignment of the next element type.

`:compact-offset` would be a subview into a larger `:compact` view.

`:strided` means the `soa-vector` is a view or a slice. The internal arrays are no longer guaranteed to be perfectly contiguous, and accesses will rely on dynamic strides.

### Base Properties

A `soa-vector` has these properties:

| Property     | Type         | Description      |
|--------------|--------------|------------------|
| align        | align        | one of `:strided` or `:compact`. This dictates the layout of the inner vectors. |
| length       | ulong        | the number of elements in the `soa-vector`. Its bytes cannot be greater than its parent `storage` |
| parent       | storage      | address of"parent storage |
| offset       | ulong        | offset into parent. |

### Struct Properties

Additionally,  `soa-vector` also inherits the properties of their struct element type. 


Example
```
(def-struct point (x long) (y long))

(let ((sv      (make-soa-vector point :address-space :local :align :compact :length 20))
      (y       (y~ sv 9))
      (x-vec   (x~ sv)))
    ...)
```

#### `XXXX~` with index.

In the example above, `y` is gotten via `(y~ sv 9)` which means it is the value of the y vector at index 9.

Owning to memory coalesence, when the index is a thread id from parallel threads,  this will be very high-performance access. 

#### `XXXX~` without index

In contrast, `(x~ sv)` returns the ENTIRE VECTOR of X as a standard vector Storage Handle. The returned vector inherits the alignment of the `soa-vector`. If `sv` is `:compact`, `x-vec` will be `(vector long :compact :length 20)`, allowing for ultra-fast vectorized loads. If `sv` is `:strided`, the resulting vector will also be `:strided`. 

Its primary purpose is to pass a single, contiguous stream of data to another high-performance primitive, like `reduce-vec`

### Element Access

The struct properties (see above) with index arguments are the primary way of accessing `soa-vector` data.
If you want a particular struct as singular construct, it can be gotten with `get-struct`.  Note that this requires
creation of a new structure to hold the value.
`(let ((some-point (get-struct sv 3))))`   

`soa-vector` does NOT support the `~` or `~ref~` element access functions like a regular `vector`.

### Helper Functions

Like `vector`, `soa-vector`  supports `element-type` and `bytes` helpers.
`(bytes my-soa-vec)` returns the total memory footprint, which is the sum of the sizes of all its tightly-packed component arrays, plus any inter-array alignment padding required by the C ABI. Remember, the `soa-vector` is a view into some storage. Use `(byte-size~ (parent~ someSoaVec))` to get the full storage bytes.

### Member Data Rules

`soa-vector` are ONLY defined over structs (see `def-struct` above). And any candidate struct type can only consist of either
 - Scalar types (`int`, `float`, etc)
 - Small vector types ( `float4` etc)

Unlike regular structs, they cannot include other structs or views.
This rule is in place to prevent overly complex nested SoA layouts and to ensure a simple, predictable memory model that maps efficiently to the hardware.

### Defining 

```
(soa-vector element-type &key address-space align length)
```

### Creating

`soa-vector` have parallel creation routines to `vector` and abide by the same requirements.

- `(make-soa-vector <source> <struct-type> length &optional offset)`



### Converting between SoA and AoS vectors.

If you put yourself in a situation where you need to convert an AoS `vector` to an SoA `soa-vector`, 
or vice versa, then it might be time to reflect on the decisions in your life that have
brought you to this point. 
Fortunately, this is something that the GPU can do fairly well. Not optimized with perfect memory
coalescing, but well enough. Crisp provides routines that can help you out.

```
(convert-soa-to-aos input-soa-vector output-vector)
(convert-aos-to-soa input-vector output-soa-vector)
```

Possible Implementation
```
;; NOTE: convert-soa-to-aos should be implemented as a macro like convert-aos-to-soa below.
;; The will take the "temporary struct" creation out of runtime, making it marginally faster.
(with-template-type (T)

    ;; -- convert-soa-to-aos --
    (def-function convert-soa-to-aos (input-soa-vector output-vector)
        (declare #((soa-vector T) (vector T) => nil))
        (loop-soa-stride input-soa-vector (i)
            (let ((temp-struct (get-struct input-soa-vector i)))
                (set! (~ output-vector i) temp-struct)))))

;; -- convert-aos-to-soa --
(defmacro convert-aos-to-soa (input-vector output-soa-vector)
    (c-t-assert (type-equal (element-type~ input-vector) (element-type~ output-soa-vector)))
    (let ((T (element-type~ input-vector))
          (set-forms (with-struct-accessors T (aos-accF soa-accF)
                       ;; body generates one form for each member
                       ;; "i" and "temp-struct" TBD below.
                       `(set! (,soa-accF ,output-soa-vector i (,aos-accF temp-struct))))))
        `(def-function convert-aos-to-soa (input-vector output-soa-vector)
            (declare #((vector ,T) (soa-vector ,T)))
            (loop-vector-stride ,input-vector (i)
                (let ((temp-struct (~ ,input-vector i)))
                    ;; expand the forms we gathered
                    ,@set-forms)))))
```



### C++ / Python interop

The hoisting code that the compiler generates includes helper functions that give the same property-to-vector and property-index-to-element 
access that Crisp enjoys, making it easy to initialize or inspect data and interoperate with Crisp kernels.




