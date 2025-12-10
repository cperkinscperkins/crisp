## def-const-vec


Memory in the constant address space is read only and it must be 
initialized BEFORE the kernel that wishes to use it is called. 
The host can obviously set that up and pass it as an argument to 
the kernel. Or a .crisp file can declare and initialize them on its 
own and the compiler will take care of it. 

The `def-const-vec` takes two arguments: 
- a name for the vector 
- a progn which returns the initialized vector.  Think of it as just a function that does not accept arguments.

`def-const-vec` may return only one value. It cannot return multiple const-vecs.

`def-const-vec` will usually not require a `declare` with a type signature.  The compiler should be able to
infer it in nearly all cases. 

If you want the vector to be responsive to some other calculations, have the host initialize it and pass it to the kernel as a regular argument instead.

### Declare Use In Kernels
If anything wants to read from that vec during the execution of some kernel,
that kernel needs to add a `(use <const-vec-name>)` to its `declare` directive. 
Then it, or functions it calls, can simply refer to the const-vec, like one would a global variable.  

### Works with SoA
Returning a `soa-vector` from `def-const-vec` is fully supported. 

### make-vector / make-soa-vector
```
(make-vector vectorType size)
(make-soa-vector soaVectorType size)
```
In the context of `def-const-vec` there are two additional overrides available. `make-vector`
and `make-soa-vector`.  Both take the appropriate vector type, which allows you to define
element type, layout, etc and a size. 


### Constant Vec Using Other Constant Vec

When preparing masks, sometimes the construction of one mask depends on another. So long
as all this is predeterminable at compile time, CRISP can support it.

The `(declare (use +xxx+))` declaration can be put inside a `def-const-vec` to allow it to 
refer to an earlier `def-const-vec` .  The requirement is that the named const vec in the `use`
clause MUST have been defined earlier in the translation unit. 

### Type Function
CRISP also has two type functions for `:constant :read-only` vectors returned by `const-vec-type`
`(const-vec-type <element-type> <align> &optional length)` 
and
`(const-soa-vec-type <element-type> <align> &optional length)`


```
(def-type image-mask-t (const-vec-type uchar :compact))
(def-const-vec +image-mask-32+ 
  (let ((image-mask-vec (make-vector image-mask-t 32)))
    (dotimes (x 32)
      (set! (~ image-mask-vec x) x))
    (return image-mask-vec)))

(def-const-vec +image-mask-8+
  (declare (use +image-mask-32+))
  (let ((small-image-mask-vec (make-vector image-mask-t 8))
        (small-view  (make-vector small-image-mask-vec 2))
        (big-view    (make-vector +image-mask-32+ 2)))
    (dotimes (x 4)
      (copy-vec :from big-view :to small-view)
      (inc! (offset~ small-view) 2)
      (inc! (offset~ big-view) 8))
    (return small-image-mask-vec)))

;; -- my_image_kernel --
(def-kernel my_image_kernel ()
  (declare (use +image-mask-8+))
  ;; this kernel and the functions it calls can 
  ;; refer directly to +image-mask-8+
  ;; Better, the kernel can pass it as an argument
  ;; to those other functions.  
  (do-something-magical +image-mask-8+))

  ;; note that my_image_kernel did NOT declare that it used +image-mask-32+. 
  ;; Normally, that would mean that vec would not be prepared when the kernel is loaded
  ;; but due to the 'use' from +image-mask-8+ it will be.  So the code from BOTH def-const-vec 
  ;; will execute before my_image_kernel is loaded.
  ;; But, loaded or not, my_image_kernel cannot access +image-mask-32+ because it did
  ;; not declare use for it. 

```

### reinterpet for other Storage Handle types

`def-constant-vec` sets up vectors or soa vectors only. If you need some other Storage Handle type
(like `matrix`) then the appropriate `make-XXXX` function to reinterpreset it.


