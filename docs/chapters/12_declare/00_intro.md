# `declare`


`declare` can appear as the first line in the Crisp function forms 
( `def-function`, `def-grid-function`, `def-kernel`, `def-kernel-exact` )
as well as `let`. 

`declare` can also appear in the first position following a template declaration (`with-template-type` or `<T>` syntax)
When it appears in a template it is used for type declarations involving type constraints.


It is used to declare important information to the compiler, typically about the 
function itself or the new variable closure.  The following are the valid 
directives that can appear in `declare` when used in function or `let` bindings.
For template usage, see the subequent section.

| Name          | Example                     | Fun | Let | Description |
|---------------|-----------------------------|-----| ----|-------------|
| `type`        | `(type someVar int)`        | Yes | Yes | type of parameter or variable. See below for variadic example. |
| `return-type` | `(return-type long)`        | Yes | No  | return type of a function. see below for multiple return values |
| arrow form    | `#'(int int => float)`      | Yes | No  | declare the entire function signature in one expression |
| `type-signature-of` | `(type-signature-of #'addInts)` | Yes | No | reuse type signature of another function as own | 
| `use`         | `(use +image-mask+)`        | Yes | Yes | the context requires some constant storage vector / tensor |
| `inline`      | `(inline)`                  | Yes | No  | asks that the compiler inline this function. |
| `register`    | `(register <var0> <var1> ...)` | Yes | Yes | mark this var or parameter to be kept in register. Note that this cannot be guaranteed.|
| `global-size` | see [Hoisting](#hoisting-and-enqueing-a-kernel)| Yes | No | communicate kernel `global_size` requirements back to hoisting code |
| `local-size` | see [Hoisting](#hoisting-and-enqueing-a-kernel)| Yes | No | communicate kernel `workgroup_size` requirements back to hoisting code |
| `num-groups` | see [Hoisting](#hoisting-and-enqueing-a-kernel)| Yes | No | communicate kernel enqueue requirements back to hoisting code |
| `uniform`     | `(uniform someVar)`         | Yes | Yes | declares that some param or variable must be uniform across the workgroup.  Compiler will error if it is not. |
| `constexpr`   | `(constexpr someVar)`       | Yes | Yes | delares that some param or variable must be compile time calculable. Compiler will error if it is not |
| `to-uniform`  | `(to-uniform someVar)`      | No  | Yes | tells the compiler to MAKE the newly defined variable uniform across the entire workgroup. This is non-trivial. See [to-uniform](#to-uniform-) |
| `forward-only` | see [Auto-Differentiation](#auto-differentiation-ad)| Yes | No | tells the compiler that this function is forward-only and should not be differentiated. Will not be compiled when the `-differentiate` flag is used. |
| `max-registers` | `(max-registers 64)`        | Yes | No | An opt-in static analysis usually elected at the kernel level. Compiler will analyze the number of registers a kernel requires and emit a compiler error if it exceeds. |
|`warn-max-registers` | `(warn-max-registers 64)` | Yes | No | An opt-in static analysis usually elected at the kernel level. Compiler will analyze the number of registers a kernel requires and emit a compiler warning if it exceeds. It will also name which kernel args might be candidates for `no-sroa`  |
| `no-sroa` | `(no-sroa someVar)` |             | Yes | No | The variable named (typicall a Storage Handle) will not be automatically expanded into its SROA components at the kernel boundary, but is instead brought over as a single constant memory struct. This can lower register usage, but is only available for storage handles that do NOT use mutable strides or offsets. | 


<!--
The following are under consideration and have yet to be fully defined:

- inline
- not-inline
- (critical varName 100)  // how critical is this to NOT spill. 100== never 0== ok sure.
  the problem here is that unless we have FULL control these are promises that can't
  be kept.  just use 'register' in the interim. 

-->

<!--
This is a type function. It can be used in any position  a type could.  
So, yes, it can appear _IN_ a declare, but not as a top level directive.
 return-type-of | `(return-type-of #'addInts)` | Yes | No | T
 -->

#### `type`
`(declare (type a b c double))`
`type` can be used to declare the type of parameters or variables. Note that it is
variadic and if multiple expressions are of the same type they can simply be listed with the
type itself being in the last position.

There are other ways of declaring variable types (arrows form, colon join). 

#### `return-type`
`(declare (return-type int double))`

#### arrow form

```
#'(int int => long)

#'(int => long double)

#'(int int &optional long &key :clamp float => long)

#'(in-vec &out out-vec)
```




