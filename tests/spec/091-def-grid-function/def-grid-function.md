In this endeavor I'd like to get "def-grid-function" and the "grid-level" (and possibly "workgroup-level") declarations working.


The docs below for Top Level Execution Constructs explain the concept pretty clearly.  There are
three primary "execution contexts" that might apply to a progn.  
- thread-level  , which is the default for the progn of every def-function.
- grid-level, which is usually introduced by macros.  But, technically, just the use of atomics or 
   the GPU environment built-ins, trigger.
- dispatch-level.  This is just a context that supports anything. You can insert a grid-level macro
  into a dispatch-level context. But you cannot insert a grid-level macro into a grid-level context.

def-grid-function has  a "dispatch-level" progn.  It can technically contain multiple grid-level contexts,
just so long as they are sequential to one another, not nested.  The &out enforcement that Crisp has
would prevent "unsound" abuse of sequential grid-level contexts. 


I'm a little worried about exactly how to implement the grid-level nesting enforcement. My ideas were
 - if a macro has a progn (which would mostly likely be `let`) that has a `(declare (grid-level))` declaration at its beginning, then it's understood to introduce a grid level context.
 - This macro can be used in a "dispatch context" (like the body of most def-grid-function) 
   but the compiler refuses to nest it inside another "grid context". And certainly never in a "thread context".
 - grid functions are not callable from thread functions (def-function).


There is ALSO the bit about def-grid-function being "gen-" able to be promoted to a kernel.
Maybe that should be its own work item.


Testing
- def-grid-function: produces LLVM-IR just like a regular function
- def-grid-function body CAN call other functions defined by def-grid-function
- def-function CANNOT call functions defined by def-grid-function
- def-kernel (and def-kernel-exact) CAN call def-grid-function.
- def-kernel / def-kernel-exact ALSO have a "dispatch level" context as their default. 
- def-grid-functino CANNOT return a value.
- defmacro that produces let or maybe progn that has a (declare (grid-function)) 
- That macro CANNOT appear in a def-function body.
- That macro CANNOT appear in a progn with a (declare (grid-function))
- The macro CAN be in a def-grid-function body.
- multiple times.
- what am I overlooking for grid-level concerns?
- macro with (declare (workgroup-level))
- that macro CANNOT appear in the progn of another (declare (workgroup-level))
- but CAN be used everywhere else. Including def-function and def-grid-function



Design Docs Sections

Top Level Execution Constructs
==============================

In Crisp, nearly everything that can be put at the "top level" of a code file begins with "`def-`".  
There are a handful of exceptions (*), but that is the general rule. And every other Crisp expression
is then inside one of these definitions and cannot appear, unchaperoned, at the top level.
Of these "`def-`" expressions, there are three primary ones that serve as execution constructs:
 `def-kernel`, `def-function` and `def-grid-function`.

 (* Exceptions: `declaim`, `with-template-type`, `set-derived` )

`def-kernel`
------------

```
;; -- do_something --
(def-kernel do_something (i val VEC)
   ;; <type-declaration-here>
   (set! (~ VEC i) val)) ;; store val into index i of VEC
```
We'll discuss type declarations and type signatures later. For now, just understand that
`def-kernel` is how you define a kernel function that can be enqueued and invoked by some
host application.  The host application can only invoke kernels that you define, no other
functions.
Kernel functions
- accept arguments like a regular function (with a constrained set of available types)
- do not return values
- are not callable by other Crisp functions (see "continuation kernels" for exceptions)
- the body `progn` of the kernel function is a dispatch context
- can call both "thread level" functions and "grid level" functions.
- kernel function names (like "do_something" above) are restricted to C-style naming rules (ie "do_something" with an underscore is valid, but "do-something" with a dash is not).
- kernel function names are case sensitive - unlike nearly everything else in Crisp which is case insensitive.

`def-function`
-------------
```
;; -- do-add --
(def-function do-add (x y)
   ;; <type-declaration-here>
   (+ x y)) ; return the sum of x and y
```
`def-function` defines a function, just like you would do in nearly every other programming
language. Functions take arguments and return values, they have mandatory type declarations (see below).
The functions that are defined are "thread level" functions, meaning they are expected to operate in the context
of a single thread and not orchestrating the operation of all threads generally.

Thread level functions
- accept arguments, including higher order function args
- CAN return values
- the body of these functions are a "thread level context"
- can call other thread level functions
- but CANNOT call "grid level" functions or use grid level macros
- can use Lisp-style naming rules. (dashes ok in function names, case insensitive)

`def-grid-function`
------------------

```
;; -- vector_add --
(def-grid-function vector-add (A B &out C)
  ;; <type-declaration-here>
  (loop-vector-stride A (i)
     (set! (~ C i) (do-add (~ A i) (~ B i))))) 
```

`def-grid-function` also defines a function, much like `def-function` above. 
Grid functions have a "dispatch context" at their top level. They
are called "grid functions" because the CAN invoke grid level operations 
(as opposed to thread level functions which cannot).

Grid functions
- accept arguments, including higher order function args
- CANNOT return values
- have a "dispatch context" in the top level
- can call thread level functinos
- can call grid level functions
- can use Lisp-style naming rules (dashes ok).






ALSO
======

Grid Level Operations
---------------------

Grid-level operations are primitives that orchestrate work across the entire grid of threads. A fundamental rule in Crisp is that 
a `progn` with a grid-level context CANNOT contain other grid level operations. (ie no nesting). Attempting to do so is a semantic error that leads to incorrect calculations, massively redundant work, and incomplete coverage of the problem space.

The following Crisp functions and macros are grid level operations, they either open grid level contexts or take
higher order function arguments that must be thread level (only) operations. 

- all `-stride` functions
- all grid-wide reduction variants ( `reduce-to-1-*`, `reduce-vec-*`)
- `filter`
- `convert-layout` 
- `when-is-last-workgroup`



### `(declare (grid-level))`

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

### atomic ops

Atomic operations (see below) performed on `:global` memory are, by fiat, grid level operations. If your
`defmacro` uses any atomic operation on `:global` memory, be sure to `(declare (grid-level))`.  
Atomic operations on `:local` memory have no such requirement.

Workgroup Level Operations
--------------------------

Workgroup-level operations are a bit like grid-level, in that multiple threads are being coordinated in
the context of some `progn`, but the scope of coordination is limited to within a single workgroup.  
Workgroup level operations cannot be nested inside other workgroup-level operations, 
in this regard they are similar to grid level ops. But workgroup level
operations CAN be invoked in thread-level contexts (so long as that doesn't result in nested workgroup level contexts).

### `(declare (workgroup-level))`

`workgroup-level` is a declaration that tells the compiler (and other users) that a particular `progn` is a workgroup level
context. If you are writing a `defmacro` that is doing workgroup level coordination, then be sure to include
this declaration in its expansion.
