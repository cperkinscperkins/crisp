## Side Channel Storage Handles


As was mentioned earlier, Crisp supports side channel Storage Handles, which are special purpose memory objects that
can be created in the operation of your kernel. This lets you "pretend" that the kernel is allocating 
memory, when it is actually just specifying a need for memory for some purpose and that need is expressed
to the host in the example hoisting code or metadata that the compiler outputs.

The different declarations each operate similarly. Each one results in an additional implicit argument being added to the kernel (or an additional matching "marshall" declaration appearing in a `def-kernel-exact`), plus an additionl set
of arguments (pointer, size, strides, etc) output into the hoisting code, complete with a recommended expression for calculating 
the correct allocation size.  

Each invocation must be countable by the compiler. This means they cannot appear in loops. 

The invocations take a type expression as their first argument. The "new" Storage Hnadle will have the same type as the source, except that its `:access` may be changed to `:read-write` if the original source was only `:readable` or `:read_only`.   If an existing Storage Handle VALUE is
used as the type expression, then the size will be set to be the same. This can be very handy, because if that value originates as 
a kernel argument, then the example hoisting code will specify that the size should match. 

The size of any invocation MUST be specified. It does not have to be a compile-time constant, merely specified. 
Note that there are several keyword symbols that can be used for the most common cases. 

The invocations also support a  `:name` and `:msg` keys. If using `def-kernel-exact` then `:name` is REQUIRED, 
as it will need to match a marshalling invocation.  The `:msg` key will output a comment into the hoisting code (Neat!),
which allows you to state its intended size and purpose.



### make-scratch-XXXX
```
;; cells
(make-scratch-cell element-type  &key address-space  access name msg)
(make-scratch-cell cell-type  &key address-space  access name msg)

;; vectors
(make-scratch-vector element-type sizeExpression &key address-space align access name msg)
(make-scratch-vector vector-type sizeExpression &key address-space align access name msg)

;; soa-vectors
(make-scratch-soa-vector struct-type sizeExpression &key address-space align access name msg)
(make-scratch-soa-vector soa-vector-type sizeExpression &key address-space align access name msg)

;; matrices
(make-scratch-matrix element-type sizeExpression &key strides address-space align access name msg)
(make-scratch-matrix element-type sizeExpression &key (major :row) address-space align access name msg)
(make-scratch-matrix matrix-type sizeExpression &key address-space align access name msg)

;; tensors
(make-scratch-tensor element-type sizeExpression  &key strides address-space align access name msg)
(make-scratch-tensor tensor-type sizeExpression &key address-space align access name msg)
```

The `make-scratch-XXXX` routines create "scratch" side-channel memory Storage Handles. 

Scratch memory defaults to `:local` address space,  `:read_write` access and `:std140` alignment, 
but the defaults can be overridden by either using the `&key` arguments to the `make-scratch-XXXX` function
or by using the second creation function of the pair that uses a Storage Handle type argument.

Note that `:access` is NOT set by a Storage Handle type argument. It is always set to `:read_write` unless 
directly overridden with the `:access` key.


#### `sizeExpression`

The `sizeExpression` is the magic that makes these things tick.  The most useful choices
for `sizeExpression` are the following keyword symbols that Crisp supports:

- `:match-workgroup-size`  (1 per thread in group) the scratch memory allocated will match the workgroup size (ie `wg-size * sizeof(T)` where `T` is the element type)
- `:match-num-workgroups`  (1 per group in the grid).
- `:match-total-threads`  (1 per thread total)
- `:match-warp-size`  (1 per lane in warp)
- `:match-warp-tile`  (1 per warp-size squared)
- `:match-num-warps-per-workgroup` 
- `:match-total-warps`  (global_size / warp-size)


The above `sizeExpression` choices will automatically set the `:msg` that is sent back to the hoisting code.

Alternately, the `sizeExpression` can be a compile-time known value, in which case the hoisting code will be configured with that,
or it can be any runtime value or some other Storage Handle variable.  In these cases, this will be noted in the hoisting comment,
but that may lack clarity. It is best ot use the `:msg` key as well.

#### `sizeExpression` for matrices and tensors

`:match-workgroup-size` and  `:match-grid-size` (and `:match-warp-tile`) all work well when the arity of the `local_work_size`/`global_work_size` matches
the arity of the Storage Handle view.  If it is expected that they won't match, use a scratch `vector` and reinterpret it for your needs.

Alternately, the `sizeExpression` can be a list in `(... z y x)` order. 


#### type expression argument

Usually this argument is a Storage Handle type, but an existing Storage Handle variable can be used as well, which 
can make things simpler.

#### scratch types
<!-- NOTE not sure about this -->
These type expressions are available:
```
(scratch-cell-type T &optional address-space)
(scratch-vec-type T &optional address-space)
(scratch-matrix-type T &optional address-space)
(scratch-tensor-type T &optional address-space)
```


#### Example 
Below is  a simple example
```
;; -- calc_something --
(def-kernel calc_something (A Res)
  (declare #(float-vec ulong-vec => nil))
  (let ((intermediate (make-scratch-vector A (/ (length~ A) 2) :msg "half of size of A parameter"))
        (otherIntermed (make-scratch-vector float :match-workgroup-size)))
     ...))
```

And this is an excerpt of the hoisting code that might be generated.  
```
 unsigned long intermediateScratchLen =   ; //      (/ (length~ A) 2)    half of size of A parameter 
 unsigned long otherIntermedScratchLen = local_work_size * sizeof(float);
 clSetKernelArg(calcSomethingKernel, 1, sizeof(void*), APtr);
 clSetKernelArg(calcSomethingKernel, 2, sizeof(unsigned long), &APtrLen);
 clSetKernelArg(calcSomethingKernel, 3, sizeof(void*), ResPtr);
 clSetKernelArg(calcSomethingKernel, 4, sizeof(unsigned long), &ResPtrLen);
 clSetKernelArg(calcSomethingKernel, 5, sizeof(void*), intermediateScratchPtr);
 clSetKernelArg(calcSomethingKernel, 6, sizeof(unsigned long), &intermediateScratchLen);
  clSetKernelArg(calcSomethingKernel, 7, sizeof(void*), otherIntermedScratchPtr);
 clSetKernelArg(calcSomethingKernel, 8, sizeof(unsigned long), &otherIntermedScratchLen);
 clEnqueeuNDRangeKernel( someCommandQueue, calcSomethingKernel,         
                          ...);
```
<!-- 
Implementation Notes

We'll need to modify the args up and down the call tree to get these "side channel" vars propogated.

Modifying the beginning of the arglist (of course).

-->

### Scratch Helpers

Important: There are asynchronouse variants of these helpers.  See [Async Memory Operations](#async-memory-operations) for more information. 

```
(load-local global-vec scratch-vec &optional identity)
(store-global scratch-vec global-vec &optional (transformF #'identityF))

(load-tile ...) 
(store-tile ...)

(load-chunk ...)
(store-chunk ...)
```

In `:one-thread-per` strategies, a common practice is to divide some input vec
across workgroups and have each workgroup work on the vec using a local memory
copy of the workgroups segment. These two macros handle that and even include a 
`local-barrier`.

`load-local` has an optional `identity` arg. If the global work size is
greater than `global-vec`, then it may be necessary to fill in the matching portion
of the `scratch-vec` with something, and `identity` is that something.

There are also  `load-tile` and `store-tile` helpers to assist with
similar operations in 2D strided scenarios. They are described below with Matrices.
Lastly, `load-chunk` and `store-chunk` can be used with any chunk size (so long as it is
not bigger than a single workgroup). From within  a `thread-stride` they don't require any
placement arguments, but they are perfectly usable without. See the section on [thread-stride](#general-purpose-thread-stride). 

Possible Implementation
```
(defmacro load-local (global-vec scratch-vec &optional (identity 0))
  (c-t-assert (type-equal (element-type~ global-vec) (element-type~ scratch-vec)) "type match!")
  (when identity (c-t-assert (type-equal (element-type~ global-vec) (type-of identity)) "identiy type"))
  `(let ((lid (get-local-linear-id))
         (gid (get-global-linear-id))
         (val (if (< gid (length~ ,global-vec)) (~ ,global-vec gid) ,identity)))
      (set! (~ ,scratch-vec lid) val)
      (local-barrier)))

(defmacro store-global (scratch-vec global-vec 
              &optional (transformF (get-identityF (element-type~ global-vec))))
  (c-t-assert (type-equal (element-type~ global-vec) (element-type~ scratch-vec)) "type match!")
  `(let ((lid (get-local-linear-id))
         (gid (get-global-linear-id)))
            ;; (wg-idx (get-workgroup-linear-id))) ;;<-- exists? 
      (when (< gid (length~ ,global-vec))
        (set! (~ ,global-vec gid) (funcall ,transformF (~ ,scratch-vec lid))))
      (local-barrier))

```



### make-implicit-XXXX

```
(make-implicit-cell <ID> cellType &key name msg)
(make-implicit-vector <ID> vectorType &key name msg)
(make-implicit-matrix <ID> matrixType &key name msg)
(make-implicit-tensor <ID> tensorType &key name msg)
```

Do you think the Crisp scratch memory or debug logging systems are cool, but you could do better?
Knock yourself out, deviant!  The `make-implicit-XXXX` allows you to Side Channel any Storage Handle for any 
purpose.  The `<vectorType>` et al must be complete, but it doesn't otherwise need to capture any particular
size requirement.

The `<ID>` are tracked. If the Crisp compiler sees two `make-implicit-XXXX` invocations with the same
`<ID>` for a given Storage Handle type, it will assume they are the same and only side channel enqueue one thing.

In the example below, this function, if called by a kernel, would cause two additional float array pointer to 
be hoisted, plus a pointer to a unsigned long array.  

```
(def-type float-vec (vector float :std140 :global :read_only))
(def-type ulong-vec (vector ulong :std140 :global :writeable :std140))

;; -- calc-final-result --
(def-grid-function calc-final-result (x y &out A)
  (declare #( ulong unlong &out float-vec => nil))
  (let ((gamma-1 (make-implicit-vector :gamma-1 float-vec :msg "Gamma Squad should provide these"))
        (gamma-2 (make-implicit-vector :gamma-2 float-vec))
        (haversine-3 (make-implicit-vector :haversine ulong-vec  :name "haversine")))
      ...))
```


