# ANF Transformation Rules (Draft)

This document formalizes the input-to-output mapping for the A-Normal Form (ANF) transformation phase in the Crisp compiler. It categorizes the constructs discovered in the documentation (both realized and planned) and defines how the transformation should handle them.

## General Principle
ANF ensures that all arguments to functions, primitives, or conditionals are trivially evaluatable (i.e. atoms: variables or literals, or forms that do not contain further nested computations). Complex sub-expressions are hoisted into `let` bindings that enforce sequential execution limits.

---

## 1. Atoms & Literals
The base cases. They simply pass through the evaluation intact.
*Applies to: numbers (`1.0`, `42`), booleans, keywords (`:foo`), symbols (`x`), function references (`#'+`).*

| In Form | ANF Form |
| :--- | :--- |
| `x` | `x` |
| `42` | `42` |


## 2. Standard Function Calls, Math, and Hardware Operators
Arguments are evaluated sequentially left-to-right. Variables hold the result of nested expressions. If an argument is already atomic, it need not be bound to a temporary.
*Applies to: `+`, `-`, `*`, `/`, `funcall`, `<, <=, >`, bitwise ops (`op-popcount`), and standard function calls.*

| In Form | ANF Form |
| :--- | :--- |
| `(+ a b)` | `(+ a b)` |
| `(* (+ a b) (- c d))` | `(let ((t1 (+ a b)) (t2 (- c d))) (* t1 t2))` |
| `(foo (bar x) y)` | `(let ((t1 (bar x))) (foo t1 y))` |


## 3. Assignment (`set!`)
The right-hand side is evaluated to an atom. If the left-hand side is a "place" (e.g. an accessor like `~` or `x~`), its inner reference must also be evaluated to an atom.

| In Form | ANF Form |
| :--- | :--- |
| `(set! var (foo x))` | `(let ((t1 (foo x))) (set! var t1))` |
| `(set! (x~ (get-point)) 42)` | `(let ((t1 (get-point))) (set! (x~ t1) 42))` |
| `(set! (~ (get-cell)) (* a b))` | `(let ((t1 (get-cell)) (t2 (* a b))) (set! (~ t1) t2))` |


## 4. Struct & Memory Accessors
The parent object is evaluated to an atom before the accessor is applied.
*Applies to: `~`, `~ref~`, `x~`, `y~`, `length~`, `extents~`, `strides~`, `num-cols`, etc.*

| In Form | ANF Form |
| :--- | :--- |
| `(x~ (get-point))` | `(let ((t1 (get-point))) (x~ t1))` |
| `(~ (get-cell))` | `(let ((t1 (get-cell))) (~ t1))` |


## 5. Control Flow: `if`, `when`, `unless`
The condition is hoisted and evaluated to an atom. The branches themselves are recursively ANF-normalized *in place* (we do not lift expressions *out* of branches to preserve the branching logic).
*Applies to: `if`, `when`, `unless`, and their compile-time variants (`if+`, `when*`, etc.).*

| In Form | ANF Form |
| :--- | :--- |
| `(if (p? x) (f y) (g z))` | `(let ((t1 (p? x))) (if t1 (let ((t2 (f y))) t2) (let ((t3 (g z))) t3)))` |

*Note: If the `if` form itself is in a non-tail position, the result of the `if` is bound to a temporary:*
| In Form | ANF Form |
| :--- | :--- |
| `(+ (if a b c) 1)` | `(let ((t1 (if a b c))) (+ t1 1))` |


## 6. Control Flow: `cond`
Unlike `if`, `cond` handles a series of predicates. Because the second predicate must strictly only evaluate if the first predicate fails, we *cannot* hoisting all predicates to the top level simultaneously. 
**Strategy:** Either we expand `cond` into nested `if` forms as a macro-expansion *prior* to ANF, or we normalize each clause recursively. Expanding to `if` is highly recommended.

Assuming `cond` remains:
| In Form | ANF Form |
| :--- | :--- |
| `(cond ((p1? x) (f x)) (else (g x)))` | `(cond ((let ((t1 (p1? x))) t1) (let ((t2 (f x))) t2)) (else (let ((t3 (g x))) t3)))` |


## 7. `let` Bindings
Crisp `let` evaluates bindings sequentially (like `let*`). It also supports multi-value bindings (`(let ((q r (/ 10 3))) ...)`).
**Strategy:** We flatten complex forms in bindings. As an optimization, if a `let` binds a simple variable, we use that variable name directly rather than inventing a temporary `tX` followed by a trivial assignment.

| In Form | ANF Form |
| :--- | :--- |
| `(let ((x (+ a b)) (y (* x c))) (f y))` | `(let ((x (+ a b))) (let ((t1 (* x c))) (let ((y t1)) (f y))))` *or just optimized to:* `(let ((x (+ a b)) (y (* x c))) (f y))` |
| `(let ((q r (foo x))) (+ q r))` | `(let ((q r (foo x))) (+ q r))` (Assuming `(foo x)` only has atomic arguments. If it had `(foo (bar x))`, it would be hoisted first). |


## 8. Planned Forms
- **Bounded Loops (`dotimes`, `dec-times`, etc.):** The upper limit / step arguments are normalized. The body blocks are recursively ANF-transformed.
- **Higher-Order Functions (`map-stride`, `reduce-to-warp`, `filter`):** The arguments representing the data structures or indices are evaluated to atoms. The function argument (`#'op`) is an atom.
- **`declare` & Types (`type`, `return-type`, `inline`):** Ignored or passed through unchanged.
- **`return`:** Its argument is evaluated to an atom. `(return (foo x))` -> `(let ((t1 (foo x))) (return t1))`.
