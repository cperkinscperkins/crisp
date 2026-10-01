# Full Reductions Made Easy: strategy


In most of the reduction interfaces we've seen so far there are requirements for local or global scratch memory, maybe an election cell. But Crisp has its implicit "side channel" scratch memory support. Those arguments are always optional and if elided Crisp will just ensure the kernel implicit parameter slots for them and pass them down to the call chain wherever they are needed.  This makes using the routines above a lot simpler.

There is one condition. Crisp sizes and types that scratch memory before it has analyzed your code, so it
takes the element type from the **identity**, which must already have the variable's type. When you let
Crisp allocate the scratch, write the identity so its type is visible on its face: a literal (`0`, `0.0`,
`0ul`, `1.5f`), `(type-min T)`, `(type-max T)`, `(type-infinity T)` or its negation, or a conversion such
as `(to-ulong x)`. An identity whose type cannot be seen (a variable, say), or whose type differs from
the variable being reduced (`0` for a `ulong`, where `0ul` is meant), is a compilation error. Passing
the scratch arguments yourself lifts the requirement.

Another thing Crisp can do to make things simpler is to simply elect a Phase 2 strategy by name.  We see this in `grid-reduce!`, and in the multi-variable and vector reductions below.

```
(def-enum reduction-strategy :atomic :last-man-standing :cas )
```

