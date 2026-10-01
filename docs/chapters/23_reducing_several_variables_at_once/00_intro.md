# **Reducing Several Variables at Once ✅**


Algorithms often need more than one reduction over the same data: a minimum *and* a sum, or a
maximum *and* the index where it occurred. Running separate reductions one after another pays
for every shuffle, barrier, and grid election again. The three reduction constructs,
`reduce-warp`, `reduce-workgroup`, and `grid-reduce!`, each accept several variables in a single
call, in one of two forms:

* **Independent:** each variable has its own function and identity. The variables share the
  traversal but never influence one another (e.g. a `min` and a `+`).
* **Dependent:** one *combiner* reduces all the variables together, because they are
  entangled (e.g. a value and its index, or a count, mean, and M2 for streaming variance).

