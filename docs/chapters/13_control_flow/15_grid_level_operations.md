# Grid Level Operations ✅


Grid-level operations are primitives that orchestrate work across the entire grid of threads. A fundamental rule in Crisp is that 
a `progn` with a grid-level context CANNOT contain other grid level operations. (ie no nesting). Attempting to do so is a semantic error that leads to incorrect calculations, massively redundant work, and incomplete coverage of the problem space.

The following Crisp functions and macros are grid level operations, they either open grid level contexts or take
higher order function arguments that must be thread level (only) operations. 

- all `-stride` functions
- all grid-wide reduction variants ( `reduce-to-1-*`, `reduce-vec-*`)
- `filter`
- `convert-layout` 
- `when-is-last-workgroup`



#### `(declare (grid-level))` ✅

`grid-level` is a declaration that tells the compiler (and other users) that a particular `progn` is a grid level
context. If you are writing a `defmacro` that is doing grid level coordination, then be sure to include
this declaration in its expansion.

Look for these patterns in your macros:
- calls to `get_global_id()` or `get_global_linear_id()`
- using atomic operations on `:global` memory.
- calling OTHER grid level operations 

This declaration isn't just busywork. With it in place, the compiler will check your macros usage and ensure
that it isn't incorrectly nested or invoked by thread level functions. Otherwise it will almost certainly 
result in incorrect calculations and/or slow performance.

#### atomic ops

Atomic operations (see below) performed on `:global` memory are, by fiat, grid level operations. If your
`defmacro` uses any atomic operation on `:global` memory, be sure to `(declare (grid-level))`.  
Atomic operations on `:local` memory have no such requirement.

