## Vector Numeric Types


| Base Type | 2 | 3 | 4 |
|-----------|---|---|---|
| char   | char2   | char3   | char4   |
| uchar  | uchar2  | uchar3  | uchar4  |
| short  | short2  | short3  | short4  |
| ushort | ushort2 | ushort3 | ushort4 |
| int    | int2    | int3    | int4    | 
| uint   | uint2   | uint3   | uint4   |
| long   | long2   | long3   | long4   | 
| ulong  | ulong2  | ulong3  | ulong4  |
| half   | half2   | half3   | half4   |
| float  | float2  | float3  | float4  |
| double | double2 | double3 | double4 |


These vector types can be directly instantiated using `##( ...)`.  If using this syntax, it is 
wisest to explicitly declare the type, rather than rely on type inference on the part of the compiler.

Example:
```
(let ((my-svec:short3 ##(5 6 7))
      (my-dvec ##(3.0 4.0 5.1 6.0)))
  (declare (type my-dvec double4)) 
  ...)
```

### Dereferencing and Swizzles
The subelements can be dereferences with the `x~`, `y~`, `z~` and `w~` functions.
Furthermore, Crisp supports "swizzles" (like `xyyy~`)

```
(let ((my-svec:short4 ##(5 6 7 9))
      (all-six          (yyyy~ my-svec))
      (tail-part      #(0 0)))
  (declare (type tail-part short2))
  (set! (xy~ tail-part) (zw~ my-svec))
  ; OR
  (set! tail-part (zw~ my-svec))
   ...  )
```

