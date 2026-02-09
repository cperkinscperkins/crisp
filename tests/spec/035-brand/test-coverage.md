

In the near future, the Storage Handles are going to be branded.  This means the whole
brand-vs-non thing is going to be widespread throughout the entire codebase.

For this reason, I think we should just add a full test pass that tests EVERY test with --differentiate,
just like we do now with --single-pass and --debug.  This wil mostly be performed by the remote CI. And 
we'll bump ./run-all-tests.bat   to behave similarly. 

If there are tests that we expect to fail in that pass, we'll mark them ( FAIL-WITH[--differentiate] : "message" ).


But we DO want the "default" spec runner to correctly test these, therefore the current strategy is

- don't use :enforce :always for most of these tests. Just use the default (which is :enforce :diff)
- add a TEST-WITH[--differentiate] directive to most tests. Then the normal spec runner will run it twice: once without and once with.
- some of the negative tests under /errors  might end up being marked TEST-EXPECT:PASS on that default run.





This is a "rich" feature because it introduces dependent types (types that depend on values/instances) into a system that is otherwise mostly static. That friction is where the bugs will hide.

Here is a brainstorming list for TDD coverage, sorted from "Mechanics" to "The Scary Stuff."

### 1. The Mechanics (Syntax & Scope)

* **Definition Scope:** Test that `brand` fails compilation if used outside of `def-struct` / `def-record`.
* **Name Collision:**
* Test defining a brand with a name that clashes with a global type (e.g., `(brand int ...)` should fail).
* Test defining the *same* brand name in two *different* structs (should succeed—this is critical for generic names like `index-t` or `id-t`).


* **The Constructor:** Verify `(make-struct)` implicitly sets up the brand capability.
* **The Type Constructor:** Verify the type `(brand-name instance)` is recognized as a valid type signature in `declare`.

### 2. The Instance Binding (The Core Logic)

* **Self-Reference:** Can I pass `(brand-of s)` to a function expecting `(brand-of s)`? (The Happy Path).
* **Instance Mismatch:**
* Create `s1` and `s2`.
* Extract `b1` from `s1` and `b2` from `s2`.
* Verify `b1` cannot be passed to a function expecting `(brand-of s2)`.


* **Aliasing (The Tricky Part):**
* `let s1 = ...`
* `let s2 = s1` (s2 is an alias).
* Does the compiler recognize `(brand-of s1)` and `(brand-of s2)` as compatible? Or does it rely on strict symbol matching? (Strict symbol matching is safer for V1, but you need a test to confirm behavior).



### 3. Enforcement Modes (`:always` vs `:diff`)

* **`:enforce :always`:**
* Verify brand mismatches cause errors in a standard compile.


* **`:enforce :diff` (The Default):**
* **Standard Compile:** Verify the brand is **erased/ignored**. Mismatches should NOT error. `(brand-of s)` should effectively behave like `int` (or whatever the base is).
* **Differentiable Compile:** You need to mock the `--differentiate` flag (or `is-differentiating?` context). Verify mismatches **DO** error here.
* *Self-check:* Does the "erasure" mean it decays to the *base* type, or just that the instance check is skipped? (Likely decays to base type).



### 4. Substitution Rules (`:subst`)

You need a test matrix for the 4 substitution types, specifically checking "Up-casting" (Brand -> Base) and "Down-casting" (Base -> Brand):

* **`:no`:** Brand != Base. Explicit `as-` casts required both ways.
* **`:equal`:** Brand == Base. Implicit casting works both ways.
* **`:descendant`:** Brand -> Base (OK). Base -> Brand (Error).
* **`:ancestor`:** Base -> Brand (OK). Brand -> Base (Error).

### 5. Arithmetic & Dominance

This is where "Type Hygiene" gets messy.

* **Dominant (`:ancestor`):** `Brand + Base = Brand`.
* **Recessive (`:descendant`):** `Brand + Base = Base`.
* **Intra-Brand Math:**
* `Brand(s1) + Brand(s1)`: Should work.
* `Brand(s1) + Brand(s2)`: Should fail (if `:subst :no`).


* **Mixed Brands (Same Struct):**
* Struct has `(brand row-t ...)` and `(brand col-t ...)`.
* Verify `row-t + col-t` fails.



### 6. Templates (The "Yikes" Category)

* **Instantiation Identity:**
* `(def-struct (box T) (brand id-t ...))`
* Create `(box int)` and `(box float)`.
* Verify `id-t` of `(box int)` is NOT compatible with `id-t` of `(box float)`.
* *Why?* Because they are distinct types at the C++ level.


* **Brand as Template Param:**
* Can I pass a branded type *into* a template? `(make-vector (index-t s) 10)`.
* *Constraint Check:* This implies the vector type depends on `s`. This likely fails or requires `s` to be constant/global. You need to test this boundary to see where it breaks.



### 7. Storage & Erosion (Cells/Vectors)

* **The "Erosion" Test:**
* Store a branded value into a standard `(cell int)`.
* Read it back.
* Verify it comes back as `int` (brand erased).
* Verify you can cast it back: `(as-brand (read-cell c) s)`.


* **The "Impossible" Container:**
* Try to define `(def-cell c (index-t s))`.
* This should likely fail compilation because `s` is not available in the global scope where cells are defined.



### 8. Boundary Testing (Kernel Params)

* **Kernel Signature:**
* Define a kernel that takes `(s some-struct)` and `(idx (index-t s))`.
* Does the compiler correctly validate the call site when invoking the kernel?
* Does the generated C++ correctly strip the brand (since C++ kernels don't know about Crisp dependent types) and just pass `int`?



### Summary of Priority


1. **Mechanics** (Get it to parse).
2. **Enforcement** (Get `:always` working).
3. **Instance Binding** (The core feature).
4. **Substitution** (The rules).
5. **Arithmetic** (The dominance logic).
6. **Templates/Storage** (The edge cases).