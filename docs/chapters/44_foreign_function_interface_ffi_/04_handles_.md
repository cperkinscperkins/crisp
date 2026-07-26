# handles ✅


A handle is a `void**`: it has TWO address spaces — the slot's (outer, where the
`void*` lives) and the held pointer's (inner, where the data lives) — and they
are generally DIFFERENT. 

```
;; handle type declaration
(c-handle <held-pointer-type>)


(c-handle (c-pointer :address-space :global))

;; handle creation
(make-c-hanlde <pointer-type>)

;; dereference handle to pointer
(get-pointer <c-handle-obj>)

```


#### Example

In the example below, there is a C library function called `pool_alloc` takes a pointer, a size, and a handle.

```
// C 
// Atomically reserves 'size' bytes from the pool.
// Returns 0 on success, and writes the allocated pointer into 'out_ptr'.
__device__ int pool_alloc(memory_pool_t* pool, size_t size, void** out_ptr);
```

```
(def-type float-vec-t (vector float :address-space :global :align :compact))

(def-type ptr-t (c-pointer :address-space :global))

(def-foreign-function pool_alloc #'(ptr-t ulong (c-handle ptr-t) => int))

(def-kernel-exact use_pool_alloc (pool pool-size)
  (declare #'(voidp ulong => nil))
  (let ((vph (make-c-handle ptr-t))
        (bytes (* 16 (byte-size float)))
        (err (pool_alloc pool bytes vph)))
    (when  (= err 0)
      (let ((v (marshall-vector (get-pointer  vph) 16 float-vec-t)))
        ...))))
```

