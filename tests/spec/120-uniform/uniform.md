

Crisp can compile time check that a variable might be uniform or divergent.

The base compile-time routines for this are these:

(uniformity-state <var>) => :uniform | :divergent | :unknown   <-- these three are from some uniformity-state Crisp enum.

(provably-uniform? <var>)  -->  (eq (uniformity-state <var>) :uniform)

(provably-divergent? <var>)  -->  (eq (uniformity-state <var>) :divergent)



Quick Summary
=============
[/]
(uniformity-state <var>) => :uniform | :divergent | :unknown 
 compile-time determination of the variable uniformity. For variables this can be checked to see if the variable originates as a scalar/arg at the kernel boundary itself. Go up the tree. There are other things as well, discussed below.



(declare (uniform <someVar>))    can be used in a let block or function/kernel progn.  Declares that <someVar> will be uniform in the workgroup. If the compiler detects otherwise, it'll be an error. But mostly user is taken at their word.  Not sure about this.

(to-workgroup-uniform <expression>) => <var>    used in a let block (exclusively), The variable will be MADE uniform (by evaluating in only one wg thread, use barrier, prop out?)
example: (let ((u (to-uniform (some-expression ...))))
Cannot be used as a function arg expression, etc. Only as a let binding 

(to-warp-uniform <expression>) => <var>   used in a let block (exclusively), The variable will be MADE uniform (by evaluating in only one warp thread, use fast warp-wide register shuffle)
example: (let ((u (to-warp-uniform (some-expression ...))))
Cannot be used as a function arg expression, etc. Only as a let binding 

There is a longer discussion of this feature below.

The Work
========
[ ] - TESTS.   We will need TDD tests.
- -  [ ] - (uniformity-state <expr>)
    - - all three cases
    - - uniform roots (wg id, etc)
    - - divergent roots (local id, etc)
    - - unkonwn
    - - originate at kernel param boundary (uniform)
    - - - including sub-functions
    - - contagion trait through math.
    - - memory reads are divergent ("not uniform")
    - - mutation (set!) of a uniform variable inside a divergent block (like a standard when) permanently taints the variable as divergent.
- - [ ] - (declare (uniform ...))
    - - works in let blocks
    - - works in kernel progn
    - - some compile-time check and error if programmer is obviously wrong.
    - - otherwis, this drives/shortcuts the (uniformity-state ) calculation.
    - - 
- -  [ ] - (to-warp-uniform ...) (Uses fast register shuffles)
- -  [ ] - (to-workgroup-uniform ...) (Allocates hidden shared memory and emits sync-workgroup)
    - - BOTH CAN ONLY BE USED IN LET blocks. Not as function arg expression, etc.

- - [ ] - plus variants for if+,when+,dotimes+ etc

[ ] IMPLEMENTATION.
    [ ] - Implement *divergent-scope-depth* tracker in the environment during semantic analysis.
    [ ] - (uniformity-state <expr>)
    [ ] - provably-uniform?
    [ ] - provably-divergent?
    [ ] - (declare (uniform ...))
    [ ] - (to-warp-uniform ...)
    [ ] - (to-workgroup-uniform ...)
    [ ] - plus variants
    - - plus variants for if+, when+, dotimes+ must STRICTLY require (provably-uniform? <expr>). If the state is :unknown, they must throw a compiler error prompting the user to use (declare (uniform ...)).
    If the state is :divergent, then compiler error, but no suggestion (except use "normal" when etc.)



Longer Discussion from Gemini
=============================

Tackling divergence analysis (uniformity) is a massive step forward for a GPU compiler. It is the exact threshold where a compiler graduates from "translating syntax" to "understanding the hardware execution model."

Your proposed API forms a very cohesive system, but you are right to feel a bit shaky about the boundaries. In traditional GPU compilers (like LLVM's internal `DivergenceAnalysis` pass), uniformity isn't just a trait you query; it's a contagion that flows through the data-dependency graph.

Here is a breakdown of your proposed API and how these pieces should interact with each other.

### 1. ` (uniformity-state <expr>)` — The Foundation

You mentioned this is a compile-time check. You are absolutely right that this requires walking up the tree, but it should be formalized as **Taint Analysis**.

You start with known "Uniform Roots" and known "Divergent Roots":

* **Uniform Roots:** Literals, kernel arguments (passed by value), `workgroup-id`, `workgroup-size`, and `warp-size`.
* **Divergent Roots:** `local-id`, `global-id`, and atomic returns.
* **The Contagion Rule:** Any math or function applied exclusively to uniform values produces a uniform value. The moment a divergent value touches an expression (e.g., `(+ uniform-var local-id)`), the result is permanently tainted as divergent.
* **Memory Reads:** Reading from memory is the tricky part. Even if the pointer is uniform, the data loaded from it might be divergent if different threads previously wrote different values to it. Without deep control-flow analysis, it is safest to assume that reading from a pointer yields a divergent value *unless* proven otherwise.

### 2. The `+` Variants (`when+`, `dotimes+`)

These are excellent language design choices. By making the programmer explicitly type `+`, you force them to acknowledge the control flow.

Should they use `(provably-uniform? <expr>)`? **Yes, absolutely.**
When the compiler encounters a `when+` or `dotimes+`, it should immediately run `(uniformity-state condition)`.

* If the compiler proves it is uniform ➡️ Compile successful.
* If the compiler proves it is divergent ➡️ Hard compiler error.
* If the compiler is unsure (e.g., it involves a memory read it can't track) ➡️ Throw a warning or require a `(declare (uniform ...))` to proceed.

### 3. `(declare (uniform <someVar>))` — The Escape Hatch

Because static analysis isn't perfect (especially around memory reads), you *need* an escape hatch.

You should treat `declare uniform` exactly like an `unsafe` block in Rust or an `__assume()` intrinsic in C++. It tells the compiler: *"Stop the taint analysis here. I, the programmer, guarantee that across the execution scope, every thread holds the exact same bit-pattern for this variable."*

You mentioned "mostly the user is taken at their word." That is the correct approach. If the user lies and the variable is actually divergent, the result isn't a compiler error; it is **Undefined Behavior (UB)** at runtime. The threads will diverge inside a `when+` block, breaking the execution mask, and the kernel will likely hang or produce garbage. That is the cost of the escape hatch.

### 4. `(to-workgroup-uniform <expression>)` — The Active Synchronizer

This is the most dangerous and powerful form in your API, because it is not a passive check—it generates physical synchronization code.

If a user writes `(let ((u (to-workgroup-uniform divergent-expr))) ...)`, the compiler has to actively heal the divergence. This implies a massive hidden cost. To broadcast a divergent value to all threads in a workgroup, the compiler must under the hood:

1. Elect a leader thread (e.g., `if (local-id == 0)`).
2. Have the leader write its value to a hidden shared memory allocation.
3. Issue a workgroup barrier `(sync-workgroup)`.
4. Have all threads read from that shared memory.

**The Scope Problem:** You need to be extremely specific about the scope of `to-workgroup-uniform` and `to-warp-uniform`. Is it broadcasting to the **warp**, or the **workgroup**?

* If it is warp-level, you can just emit a fast register-level shuffle (e.g., `__shfl_sync` in CUDA).
* If it is workgroup-level, you must allocate shared memory and emit barriers.

I highly recommend having both `(to-warp-uniform <expr>)` and `(to-workgroup-uniform <expr>)` so the developer knows exactly how much latency they are asking the hardware to incur.

### Summary: The Lifecycle of a Crisp Variable

If you build the system this way, the API stops feeling shaky and forms a rigid logical pipeline:

1. A variable is naturally **uniform** or **divergent** based on the hardware physics (`uniformity-state` tracks this).
2. If it is naturally uniform, `when+` and `dotimes+` consume it safely.
3. If it is divergent, but the programmer *knows* a specific memory read actually returns uniform data, they use `(declare (uniform ...))` to override the compiler's ignorance.
4. If it is actually divergent, and the programmer explicitly *wants* to broadcast one thread's value to the whole group, they pay the hardware cost and call `(to-workgroup-uniform ...)` to physically change the data.


