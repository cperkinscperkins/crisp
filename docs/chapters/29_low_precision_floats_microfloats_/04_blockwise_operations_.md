# blockwise operations ✅


The arithmetic operations on microfloats are "blockwise". This is highly optimized.

The abbreviation `A` is used for the accumulator type, and `MFB` stands for the entire
microfloat block.  

#### widening multiplication

```
(*! MFB_1D MFB_1D) => A     ;  vector dot-product
(*! MFB_2D MFB_2D) => A     ;  matrix dot-product
```
Two microfloat blocks can be multiplied by each other, and the result is a single
float of the accumulator type.

#### addition / subtraction
```
(+ A A ) => A   
(- A A ) => A
```
Floats of the accumulator type can be added together, or subtracted.  

Note that the BLOCKS themselves CANNOT be added or subtracted from one another.

#### optimization note

The common pattern of multipling blocks and adding to an accumulator  `A = A + (B * B)` 
is compiled to one hardware intrinsic.  The compiler should detect this and substitute automatically,
but if you want to ensure this use the `mfb-mult-add` macro:
```
(mfb-mult-add block1 block2 someA) => A
```
This will ensure that the correct `@llvm.fma._` LLVM intrinsic is output into the IR, which wil then
be correctly compiled for your target.

#### max / min
`max` and `min` are NOT defined for the main MFB block type.  But they are defined
for both the base and accumulator types.
```
(max B B) => B
(max A A) => A

(min B B) => B
(min A A) => A
```

