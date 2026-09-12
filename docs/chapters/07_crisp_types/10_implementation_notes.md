# Implementation Notes

"vector" and "storage" at the kernel boundary is just a collection of registers from the call interface.
`marshall-vector` is just a macro that associates them.

In reality even `(def-kernel k (someVector) ...)` just expands to 

```
(def-kernel-exact k (sv-len sv-mem)
  (let ((someVector (marshall-vector sv-len sv-mem))) ...)
```


#### implicit Storage Handle arguments

If the kernel or any of its subfunctions use the Crisp side channel convenience functions
like `make-scratch-XXXX` , `make-implicit-XXXX` OR if the kernel was/will be compiled with the debug logging option, then these Storage Handles will have
to be  explicitly passed by the host and marshalled.  

- `marshall-scratch-XXXX`
- `marshall-implicit-XXXX`
- `marshall-debug-logging-vector`

Note that both the metadata and the example hoisting code that the compiler outputs will have size expressions gathered 
by the compiler for all of these. Be sure to incorporate them into your own enqueueing/hoisting code.





Struct Types ✅
------------

`def-struct` defines a structure and makes a new type. 

It also generates functions to create instances of struct (`make-XXXX`), and to access its members.
Additionally, the type constraint function `is-XXXX?` is also generated.

Storage Handles can be specialized to struct types. If a struct needs to be passed directly to a 
kernel, that is the most common way of doing so for both input and output arguments. Note that structs CAN be passed directly to a kernel, without being wrapped by a Storage Handle. But in that
case the struct is configured with constant memory and is read only, immutable. 


```
(def-struct point
    (x float)
    (y float))


;; make-XXXX
(make-point :x 3 :y 4)
;; type signature of make-point is #'(&key :x float :y float => point)
```

