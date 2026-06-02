# target-has / device-has ✅


### `(target-has <prop> &optional might:bool)`
`(target-has :fp64 T)`

`target-has` is a compile time ONLY macro that accepts a single keyword symbol for some
property. If the current compilation target definitively supports that property, it is T. 
If the compilation target definitively does NOT support it, it is nil.  But if the compilation
target is flexible (like SPIR-V) where it might or might not be supported,  then if the third
`might` argument is provided it evalutes to that.  In that case, were `might` not provided, it would be a compilation error.

### `(device-has :fp64)`

`device-has` acts like `target-has` at compile time. If the target definitively supports
the capability (or not) then the expression evalutes similarly.  But in the event the
answer is not definitive at compile time, then the expression is replace by a runtime check.
At runtime it will detect the property and evaluate accordingly. 

In the event that some future exotic feature is neither compile time nor runtime determinable, the compiler
will error. 

```
Implementation Notes: for SPIR-V, device-has will require specialization constants, which means
coordination with the hoisting code.
```

