# Invoking Functions: `funcall` ✅


Crisp follows the Common Lisp tradition (Lisp-2) regarding function application. This means that variables and functions occupy separate namespaces.

If a variable `f` holds a function (or a compile-time resolvable entity like an `ident` or `curry` result), you cannot simply invoke it as `(f x y)`. You must use `funcall`.

```lisp
;; CORRECT
(let ((op #'+))
  (funcall op 10 20))

;; INCORRECT - Compilation Error
(let ((op #'+))
  (op 10 20))
```

#### Why `funcall`?

- Namespace Hygiene: In GPU kernels, it is extremely common to use variable names like `min`, `max`, `count`, `width`, or `index`. In a Lisp-1 (Scheme-style) language, defining a local variable named `min` would shadow the global `min` function, making it impossible to calculate a minimum value within that scope. 

- Compiler Signaling: `funcall` serves as an explicit signal to the compiler: *"The target of this call is held in a variable; please trace its origin and specialize this call site."* This makes it easier for the compiler to perform the necessary Template Instantiation and inlining required for zero-cost abstractions, distinguishing these cases from static calls to global functions.

#### Compile-Time Resolution Still Applies

The use of `funcall` does NOT imply dynamic runtime dispatch. The restriction that all functions must be resolvable at compile-time remains in effect. The compiler uses `funcall` as the insertion point for the specialized, inlined logic derived from the variable's definition.


