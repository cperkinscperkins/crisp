# `def-orchestration` 📝


`def-orchestration` has the basic syntax of a function. It has an argument list (often empty), a let block where variables can be bound to kernels or memory, and then it invokes those kernels with a `launch-XXXX` form and a "launch directive" (which looks like a regular function call `(<kernel-var> <mem-var0> ...)` ).

The arg list for `def-orchestration` supports `&key` arguments ONLY. Every argument to a `def-orchestration` MUST be a keyed argument. Positional args are not supported, neither are `&optional` or `&out` or `&rest`.   These arguments are provided when invoking `gen-XXXX` on the orchestration and must be compile-time known. 


`def-orchestration` CAN be templated.

If a `def-orchestration` is not templated and has no arguments, then it will be considered a "immediately realizable" orchestration, and then outputting hoisting code, the Crisp compiler will output a hoisting file for it (ie a .cpp, .cu or .py file). One file per orchestration.  Similarly, if there are multiple kernels referenced by the orchestration then the IR output (.spv or .ptx) will contain all of them. One .spv/.ptx/.ll file per orchestration.

However, if a `def-orchestration` is templated, or has arguments it will NOT be considered a "immediately realizable" orchestration and nothing will be generated for it, itself. In this case you must use place a  `gen-XXXX` form on the orchestration at the top level of a .crisp file to specialize it. Each invocation of `gen-XXXX` will result in outputting a single IR file (.spv/.ptx/.ll) and a single hoisting example file (.cpp/.cu/.py).  For example:

```
(with-template-type (T)
  (def-orchestration fancy-kernel-dance (&key node-count)
      (let ((K (gen-dance_kernel T))
             (topo (workstation-topology node-count))
            ...))))

;; gen- the orchestration
(gen-fancy-kernel-dance float :node-count 16)
;; and another!
(gen-fancy-kernel-dance long :node-count 1)
```

Using topologies is "advanced" and entirely optional. It is covered in `topology.md`     


Let's dive into some simple examples.

#### "default" orchestration ✅

```
;; assume vector_add is defined and is not templated, uses &out
;; (vector_add A B &out C)

;; -- just-vector_add --
(def-orchestration just-vector_add ()
  (let ((K (gen-vector_add))
        (A (allocate-tensor K::A))
        (B (allocate-tensor K::B))
        (C (allocate-tensor K::C)))
  (launch-sequential (K A B C))
  (copy-back C)))
```
The above is equivalent to the default orchestration Crisp would produce when hoisting
`vector_add`, if none wer provided.  It "generates" the kernel, prepares memory for each vector, enqueues it, and copies
back to the host any `&out` data.

This introductory example shows the `def-orchestration` begins with a name for the orchestration
and is followed by a series of command for how to launch kernels. 

Let's take a quick look at its pieces:

##### gen-KERNEL_NAME 📝

In the context of an orchestration you'll typically want a variable to refer to 
the kernels you intend to launch. Use `gen-KERNEL_NAME` for this. For kernels that are 
templated, this is also used to generate its type. Don't forget that in this case a
kernel name string will be required and it must obey the C language naming rules.
 `(gen-templated_kernel float "name_of_kernel")`

##### allocate-tensor and kernel_var_name::param-name 📝

`(allocate-tensor <VectorType> &key :shared <bool> :topology <topo> :location <loc> :distribution <dist>)`

For every vector argument to pass to a kernel, use `allocate-tensor` and Crisp will generate
the code to set that up when outputting the hoisting code. The `<VectorType>` should be a complete
vector type, BUT there shortcut that let's you just grab the type directly from the kernel definition:

`kernel_var_name::param-name` Using the name of the kernel _variable_ that is in scope of the
`def-orchestration`, NOT the name of the kernel itself (ie `K` in the above, not `vector_add`) 

`:shared <bool>` : whether to allocate the tensor in shared memory. Defaults to false. For simple kernels with simple deployments and not aggressive memory requirements, using shared memory is vastly simpler. But it can be a performance liability if those things aren't true.

`:topology <topo>` : Only required for doing Out of Core operations or using multiple nodes.  See topology.md for mor information. 

`:location <loc>` : Not required unless doing Out of Core operations or using multiple nodes, see topology.md for more informaation.  Specifies where to allocate the tensor, either `:device` or `:host` or a topology specifier.

`:distribution <dist>` : Only required when using multiple nodes (PGAS), see topology.md for more information. 

##### allocate-cell 📝
```
(allocate-cell <VectorType>  &key :shared <bool> :topology <topo> :location <loc> :distribution <dist>)
(allocate-cell <Type>  &key :shared <bool> :topology <topo> :location <loc> :distribution <dist>)
```

`allocate-cell` will allocate a single cell. It can take a complete vector type, or a `vector-var-name::param-name` type shortcut , or just a type like `float` or `int`.

The `:shared`, `:location`, and `:distribution` keywords are the same as in `allocate-tensor` above.


##### copy-back 📝
```
(copy-back <hoist-vector-var>)
```

For any data you expect to be modified on the GPU, if you want it copied back 
to the host use `copy-back`. Crisp will generate code for that in the hoisting example.




#### kernel template instantiation

```
;; assume both vector_add and vector_sum are templated for some element-type.
;; (vector_add A B &out C)
;; (vector_sum DATA-IN &out RESULT)

;; -- add-and-sum-doubles --
(def-orchestration add-and-sum-doubles ()
  (let ((VADD (gen-vector_add double "v_add_double"))
        (VSUM (gen-vector_sum double "v_sum_double"))
        (A (allocate-tensor VADD::A))
        (B (allocate-tensor VADD::B))
        (C (allocate-tensor VADD::C))
        (RESULT (allocate-cell VSUM::RESULT)))
  (launch-sequential
     (VADD A B C)
     (VSUM C RESULT))
  (copy-back RESULT)))

; this orchestration will cause the kernels `v_a_double` and `v_s_double` to be created in the output.
```

Recall that when a kernel is templated, `gen-KernelName` is used to specialize it and a kernel name string is required.
Here, that is leveraged. Note that this orchestration is effecting the compilation. It is generating
two kernels ( `v_a_double` and `v_s_double` ) that will appear in the output.

#### template def-orchestration 📝

`def-orchestration` can itself be templated. Within its body `${XXXX}` can appear in strings and 
evaluate to the name of the type `XXXX`.

```
(with-template-type (T)

  ;; -- add-and-sum-any --
  (def-orchestration add-and-sum-any ()
    (let ((VADD (gen-vector_add double "v_add_${T}"))
          (VSUM (gen-vector_sum double "v_sum_${T}"))
       ...))))

(gen-add-and-sum-any float)  ; kernels `v_a_float` and `v_s_float` will be created in the binary.

```
`def-orchestration` can be templated. Like kernels, nothing will be generated by the compiler 
(not for regular output nor hoisting) UNLESS one or more `gen-Orchestration-Name` appear in the .crisp file.

This is a good way for Crisp libraries to provide orchestration code, since it is ignored otherwise. 
It is then incumbent on the user of the library to explicitly put the desired `gen-XXXX` form in
their own .crisp file.


#### `_` as a dummy var placeholder. 📝

The "calls" to a vector variable in an orchestration must have the correct number of arguments for that kernel.
But you don't have to be burdened to declare and bind each and every one. For any argument position
you can't be bothered to worry about, just use `_` and Crisp will look up what type that argument should be
and make a dummy var for you and pass it.  

`(launch-sequential (VADD _ _ _))`  <-- invoke the `vector_add` from the earlier examples with dummy
placeholders. Crisp will provide the right arg type, whatever that is (vectors in this case).

#### More notes on `def-orchestration`

Hopefully those examples give you a grounding on how it can be used. It is important to remember
that the forms inside the body of `def-orchestration` are used to just generate sample code and
ensure that certain specializations are instantiated. 

Because `def-orchestration` focuses on high-level data flow using Crisp's typed views, 
it is generally not used with kernels defined via `def-kernel-exact`, which operate at a lower level with raw argument types

The forms that can appear inside `def-orchestration` are quite limited. It is NOT a Crisp 
execution environment. 

Presently, the following forms are the ONLY ones allowed within the body of a `def-orchestration`:
- `launch-sequential`
- `launch-kernel`
- `launch-parallel`
- the `dotimes` and related `dec-` / `do-` macros
- `_`  
- `let`
- `kernel_var_name::param-name` identifier 
- `allocate-tensor`
- `allocate-cell`
- `allocate-massive-tensor` (see topology.md)
- `tile-from` (topology.md)

