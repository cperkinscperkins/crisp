# Contiguity  (aka row-major vs col-major) ✅


 Except `cell`, all Storage Handles have compile-time known "contiguity".  This tells the compiler
 in which dimension the data is contiguous. 
 The compiler time property to specify this is `:contiguous-term`. It defaults to `:last` for
 all types, and by virtue of there being a default it means this is optional. Many users will
 never need it, or need to know about it.

```
 (tensor float 6 :address-space :global :align :compact :contiguous-term :last)

;; usable with any tensor of any arity
 :contiguous-term  :last   ;; for a matrix, this is same as :row-major
 :contiguous-term  :first  ;; same as :col-major for a matrix

;; usable only with matrices
 :contiguous-term  :row-major
 :contiguous-term  :col-major

 (tensor-stride someMatrix (row-y col-x) ...)
```

 **One restriction, and it is per-vendor.** A matrix used as an operand of an Intel MMA
 (tensor-core) instruction must be `:row-major`; `:col-major` is refused at compile time
 because Intel's graphics compiler ships no column-major variant of the operand-load
 builtin. NVIDIA is unaffected — there `:col-major` **B** is in fact the canonical form.
 Nothing else in the language cares: `:col-major` is fully supported everywhere outside an
 MMA operand, including views, `tensor-stride`, and `get-layout`. If you need a column-major
 operand for an Intel MMA, stage the transpose explicitly into scratch. See "Operand layout"
 under *Optimizing Intel MMA* for the measurements and the workaround.


