In Crisp, the Storage Handles are all just "views" into memory. These views can be manipulated and reinterpreted.


This is discussed in docs\chapters\10_storage_handle_types\09_creating_storage_handle_views.md
The relevant section of that appears below

We'll want TDD tests 
- of all the (make-XXXX <source> ...) variants below
- with and without the :length key for vector (without the length is at calculated at runtime).
- with and without :offset, including where the <source> has non-zero offset itself.
- :major :row and :col
- <extents-list>
- compile time enforcement of all the restrictions. 
- assert when using --runtime-checks (*)

- remember :align is   :compact, :compact-offset and :strided



(*) --runtime-checks flag is supported.  But I think assert may just be a placeholder. Need to check.


FROM DESIGN DOC
===============


### reinterpret storage . make-XXXX
If you have a Storage Handle type, it can be reinterpreted to another type using make- with the four Storage Handle types.

(make-cell <source> <new-element-type> &key offset)
(make-vector <source> <new-element-type> &key length offset)
(make-matrix <source> <new-element-type> width height &key offset strides)
(make-matrix <source> <new-element-type> width height &key (major :row) (offset 0))
(make-tensor <source> <new-element-type> <extents-list> &key offset strides)
A new cell obviously has length=1. For a vector, if the :length key is not used, then the resulting new vector will have its size calculated automatically (byte size of the original storage / new element size, minus offset). If the source byte size is not a multiple of the new element size, the result is truncated. But the other types (tensor and matrix) need to have their extents provided.

For the 2D matrix, one of the declarations supports a :major key which can be :row or :col. Alternately, the :strides key can set the strides. Setting the strides directly is how to get "row major" vs "col major" (versus "plane major" etc) tensor in higher dimensions.

There are some restrictions. They are enforced at compile time:

if the original and new element types don't match, then the source element type cannot be a struct type
If the original and new element types don't match, the source Storage Handle must have a :compact or :compact-offset layout. Reinterpreting element types on :strided views is mathematically undefined and will trigger a compile-time error.
The returned Storage Handle inherits the address-space and access permissions from the source. It also inherits the alignmnet (:compact, :compact-offset or :strided), with one exception: if the :strides key is explicitly provided during the reinterpretation, the resulting handle is automatically typed as :strided.

The runtime will assert that the number of source bytes is sufficient for the new requirements, but this assertion requires compiler flags (like --runtime-checks).

:compact layout is generally more amenable to reinterpretation.

(def-type vec-floats-t (vector float :align :compact :address-space :local :access :read-write ))
(def-type vec-ints-t (literal-vector int))

;; -- do_things --
(def-kernel do_things (hundred-floats)
  (declare (type hundred-floats (vecl-floats-t 100)))
  (let ((some-ints #(0 1 2 3 4 5)) ;; <-- compiler will attempt to infer typ
        (three-cell (make-cell some-ints 'int :offset 3))
        (ten-floats-view (make-vector hundred-floats float :length 10)))
    (declare (type some-ints vec-ints-t))
    ...))

